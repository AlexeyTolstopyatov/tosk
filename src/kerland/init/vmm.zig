//!
//! Virtual memory allocator.
//!
//! The VMM owns a x86-64 4-level page tree (PML4 -> PDP -> PD -> PT) on top of
//! the physical allocator (`pmm`) and exposes two services:
//!
//!   1. `init()`  - builds an *identity* mapping (virt == phys) for the low
//!                  physical range the running kernel still executes from
//!                  (code, stack, PMM bitmap, video framebuffer), then switches
//!                  CR3 to the freshly loaded tree.
//!   2. `alloc()` - a linear (bump) heap in the *high half* address space.
//!                  Every 4 KiB virtual page is backed by a fresh physical page
//!                  taken from `pmm`, so virtual != physical: the heap is NOT an
//!                  identity mapping.
//!
const pmm = @import("pmm.zig");
const console = @import("video.zig").VideoLogger;

pub const PhysicalAddress = pmm.PhysicalAddress;

pub const PAGE_SIZE = 4096;
pub const PAGE_SHIFT = 12;
pub const ENTRIES_PER_TABLE = 512;

/// First canonical address of the upper half. The heap lives here, far away
/// from the identity-mapped low region, so paging for it never collides with
/// the huge (2 MB) pages used by the identity map.
pub const HEAP_BASE: u64 = 0xFFFF800000000000;
pub const HEAP_LENGTH: u64 = 128 * 1024 * 1024; // 128 MiB

/// Flush the TLB entry for one canonical virtual address.
fn vmm_invalidate_tlb(address: u64) void {
    asm volatile (
        "invlpg (%[addr])"
        :
        : [addr] "r" (address),
    );
}

/// Load a physical PML4 address into CR3 (this also drops the whole TLB).
fn setPml4(address: PhysicalAddress) void {
    asm volatile (
        "mov %[addr], %%cr3"
        :
        : [addr] "r" (address),
    );
}

pub const PageFlags = struct {
    pub const PRESENT = 1 << 0;
    pub const WRITE = 1 << 1;
    pub const USER = 1 << 2;
    pub const WT = 1 << 3;
    pub const CD = 1 << 4;
    pub const ACCESS = 1 << 5;
    pub const DIRTY = 1 << 6;
    pub const HUGE = 1 << 7;
    pub const GLOBAL = 1 << 8;
    pub const NO_EXEC = 1 << 63;
};

pub const PageEntry = packed struct(u64) {
    present: bool,
    writeable: bool,
    user: bool,
    write_through: bool,
    cache_disable: bool,
    accessed: bool,
    dirty: bool,
    huge: bool,
    global: bool,
    _reserved1: u3,
    phys_addr: u40,
    _reserved2: u11,
    nx: bool,

    pub fn init(phys: PhysicalAddress, flags: u64) PageEntry {
        return .{
            .present = (flags & PageFlags.PRESENT) != 0,
            .writeable = (flags & PageFlags.WRITE) != 0,
            .user = (flags & PageFlags.USER) != 0,
            .write_through = (flags & PageFlags.WT) != 0,
            .cache_disable = (flags & PageFlags.CD) != 0,
            .accessed = false,
            .dirty = false,
            .huge = (flags & PageFlags.HUGE) != 0,
            .global = (flags & PageFlags.GLOBAL) != 0,
            ._reserved1 = 0,
            .phys_addr = @as(u40, @truncate(phys >> 12)),
            ._reserved2 = 0,
            .nx = (flags & PageFlags.NO_EXEC) != 0,
        };
    }
    /// Physical address this entry points at (frame * 4096).
    pub fn get(self: *const PageEntry) PhysicalAddress {
        return @as(PhysicalAddress, self.phys_addr) << 12;
    }
};

pub const PML4 = [ENTRIES_PER_TABLE]PageEntry;
pub const PDP = [ENTRIES_PER_TABLE]PageEntry;
pub const PD = [ENTRIES_PER_TABLE]PageEntry;
pub const PT = [ENTRIES_PER_TABLE]PageEntry;

inline fn pml4Index(virt: u64) usize {
    return @as(usize, (virt >> 39) & 0x1FF);
}
inline fn pdpIndex(virt: u64) usize {
    return @as(usize, (virt >> 30) & 0x1FF);
}
inline fn pdIndex(virt: u64) usize {
    return @as(usize, (virt >> 21) & 0x1FF);
}
inline fn ptIndex(virt: u64) usize {
    return @as(usize, (virt >> 12) & 0x1FF);
}

var current_pml4_phys: PhysicalAddress = 0;

var heap_start: u64 = 0;
var heap_end: u64 = 0;
var heap_current: u64 = 0;

/// Wipe one whole physical page (used for freshly handed out page tables).
fn zeroPage(phys: PhysicalAddress) void {
    @memset(
        @as([*]u8, @ptrFromInt(phys))[0..PAGE_SIZE],
        0,
    );
}
/// Allocate `size` bytes in the heap address space and back every 4 KiB chunk
/// with its own fresh physical page. Works like a simple bump allocator.
pub fn alloc(size: usize) ?[*]u8 {
    if (size == 0) return null;

    const aligned = (heap_current + PAGE_SIZE - 1) & ~@as(u64, PAGE_SIZE - 1);
    const pages_needed = (size + PAGE_SIZE - 1) >> PAGE_SHIFT;
    const total = @as(u64, pages_needed) * PAGE_SIZE;
    if (aligned + total > heap_end) return null;

    var addr = aligned;
    var i: usize = 0;
    while (i < pages_needed) : (i += 1) {
        const phys = pmm.alloc() orelse return null;
        mapCurrent(
            addr,
            phys,
            PageFlags.PRESENT | PageFlags.WRITE,
        ) catch return null;
        addr += PAGE_SIZE;
    }

    heap_current = aligned + total;
    return @as([*]u8, @ptrFromInt(aligned));
}

/// Release given space.
// pub fn free(space: []u8) void {
//     // Bump allocator doesn't need it.
// }

/// Walk/carve the tree and return the table entry that governs `virtual`.
/// Intermediate tables that do not exist yet are allocated from the PMM.
/// Descending through an entry whose `huge` bit is set (a huge page lower in
/// the tree) is rejected: there is no smaller table to descend into.
fn getPageEntry(
    _: enum { PML4, PDP, PD, PT },
    pml4_phys: PhysicalAddress,
    virtual: u64,
) !*PageEntry {
    const pml4 = @as(*PML4, @ptrFromInt(pml4_phys));
    const pml4_idx = pml4Index(virtual);
    if (!pml4[pml4_idx].present) {
        const page = pmm.alloc() orelse return error.OutOfMemory;
        zeroPage(page);
        pml4[pml4_idx] = PageEntry.init(
            page,
            PageFlags.PRESENT | PageFlags.WRITE,
        );
    }
    if (pml4[pml4_idx].huge) return error.MapUnderHugePage;

    const pdp_phys = pml4[pml4_idx].get();
    const pdp = @as(*PDP, @ptrFromInt(pdp_phys));
    const pdp_idx = pdpIndex(virtual);
    if (!pdp[pdp_idx].present) {
        const page = pmm.alloc() orelse return error.OutOfMemory;
        zeroPage(page);
        pdp[pdp_idx] = PageEntry.init(
            page,
            PageFlags.PRESENT | PageFlags.WRITE,
        );
    }
    if (pdp[pdp_idx].huge) return error.MapUnderHugePage; // 1 GiB page

    const pd_phys = pdp[pdp_idx].get();
    const pd = @as(*PD, @ptrFromInt(pd_phys));
    const pd_idx = pdIndex(virtual);
    if (!pd[pd_idx].present) {
        const page = pmm.alloc() orelse return error.OutOfMemory;
        zeroPage(page);
        pd[pd_idx] = PageEntry.init(
            page,
            PageFlags.PRESENT | PageFlags.WRITE,
        );
    }
    if (pd[pd_idx].huge) return error.MapUnderHugePage; // 2 MiB page

    const pt_phys = pd[pd_idx].get();
    const pt = @as(*PT, @ptrFromInt(pt_phys));
    const pt_idx = ptIndex(virtual);
    return &pt[pt_idx];
}

/// Map a default 4 KiB page.
pub fn map4K(
    pml4_phys: PhysicalAddress,
    virtual: u64,
    phys: PhysicalAddress,
    flags: u64,
) !void {
    const pt_entry = try getPageEntry(.PT, pml4_phys, virtual);
    pt_entry.* = PageEntry.init(phys, flags);
    vmm_invalidate_tlb(virtual);
}

/// Map a 2 MiB huge page (lives in the PD).
pub fn map2M(
    pml4_phys: PhysicalAddress,
    virtual: u64,
    physical: PhysicalAddress,
    flags: u64,
) !void {
    const pml4 = @as(*PML4, @ptrFromInt(pml4_phys));
    const pml4_idx = pml4Index(virtual);
    if (!pml4[pml4_idx].present) {
        const page = pmm.alloc() orelse return error.OutOfMemory;
        zeroPage(page);
        pml4[pml4_idx] = PageEntry.init(
            page,
            PageFlags.PRESENT | PageFlags.WRITE,
        );
    }

    const pdp_phys = pml4[pml4_idx].get();
    const pdp = @as(*PDP, @ptrFromInt(pdp_phys));
    const pdp_idx = pdpIndex(virtual);
    if (!pdp[pdp_idx].present) {
        const page = pmm.alloc() orelse return error.OutOfMemory;
        zeroPage(page);
        pdp[pdp_idx] = PageEntry.init(
            page,
            PageFlags.PRESENT | PageFlags.WRITE,
        );
    }

    const pd_phys = pdp[pdp_idx].get();
    const pd = @as(*PD, @ptrFromInt(pd_phys));
    const pd_idx = pdIndex(virtual);
    pd[pd_idx] = PageEntry.init(
        physical,
        flags | PageFlags.HUGE,
    );
    vmm_invalidate_tlb(virtual);
}
/// Turn on paging with our own tree:
///   * identity-map the low range [0, identity_end) with 2 MiB huge pages so the
///     already running kernel (code, stack, PMM bitmap, framebuffer) stays
///     reachable after CR3 is switched;
///   * place the heap in the high half.
pub fn init(
    max_phys: PhysicalAddress,
    fb_base: usize,
    fb_len: usize,
) !PhysicalAddress {
    // Cover at least: all detected RAM, the video framebuffer, and 1 GiB.
    const need = @max(
        max_phys,
        @max(fb_base + fb_len, 0x40000000),
    );
    const identity_end = @as(u64, (need + 0x1FFFFF) & ~@as(usize, 0x1FFFFF));
    console.printf(
        "mapping 0 -> 0x{X}\n",
        .{identity_end},
    );

    // PML4[0] -> PDP; each PDP[i] -> one PD covering 1 GiB; PD entries carry
    // 2 MiB huge pages for the identity range.
    const pml4_phys = pmm.alloc() orelse return error.OutOfMemory;
    const pdp_phys = pmm.alloc() orelse return error.OutOfMemory;
    zeroPage(pml4_phys);
    zeroPage(pdp_phys);

    const pml4 = @as(*PML4, @ptrFromInt(pml4_phys));
    const pdp = @as(*PDP, @ptrFromInt(pdp_phys));
    pml4[0] = PageEntry.init(
        pdp_phys,
        PageFlags.PRESENT | PageFlags.WRITE,
    );
    console.tracef("PML4 @ 0x{X}, PDP @ 0x{X}\n", .{ pml4_phys, pdp_phys });

    var chunk: usize = 0;
    while (chunk < ENTRIES_PER_TABLE) : (chunk += 1) {
        const chunk_base = @as(u64, chunk) * 0x40000000; // 1 GiB slot
        if (chunk_base >= identity_end) break;

        const pd_phys = pmm.alloc() orelse return error.OutOfMemory;
        zeroPage(pd_phys);
        const pd = @as(*PD, @ptrFromInt(pd_phys));
        pdp[chunk] = PageEntry.init(
            pd_phys,
            PageFlags.PRESENT | PageFlags.WRITE,
        );

        var entry: usize = 0;
        while (entry < ENTRIES_PER_TABLE) : (entry += 1) {
            const base = chunk_base + @as(u64, entry) * 0x200000; // 2 MiB
            if (base >= identity_end) break;
            pd[entry] = PageEntry.init(
                @as(PhysicalAddress, base),
                PageFlags.PRESENT | PageFlags.WRITE | PageFlags.HUGE,
            );
        }
    }

    current_pml4_phys = pml4_phys;
    setPml4(pml4_phys);
    console.tracef(
        "CR3 loaded, {} 2MB pages mapped\n",
        .{identity_end / 0x200000},
    );

    // Heap occupies the high (canonical) half, well clear of identity.
    heap_start = HEAP_BASE;
    heap_end = HEAP_BASE + HEAP_LENGTH;
    heap_current = heap_start;
    console.tracef(
        "Virtual heap range: 0x{X}-0x{X}\n",
        .{ heap_start, heap_end },
    );

    return pml4_phys;
}

/// Point CR3 at another already-prepared page tree.
pub fn switchToPml4(pml4_phys: PhysicalAddress) void {
    setPml4(pml4_phys);
    current_pml4_phys = pml4_phys;
}

/// Map a 4 KiB page in the currently active tree.
pub fn mapCurrent(
    virt: u64,
    phys: PhysicalAddress,
    flags: u64,
) !void {
    try map4K(current_pml4_phys, virt, phys, flags);
}