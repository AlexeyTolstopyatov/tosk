//! Virtual memory allocator
const std = @import("std");
const pmm = @import("pmm.zig");
const mem = @import("core.zig");
const console = &@import("video.zig").Video;
const PhysicalAddress = pmm.PhysicalAddress;

pub const PAGE_SIZE = 4096;
pub const PAGE_SHIFT = 12;
pub const ENTRIES_PER_TABLE = 512;

extern fn vmm_invalidate_tlb(address: u64) void;
extern fn vmm_set_pml4(address: u64) void;

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
    /// Returns a physical address of current page
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

var heap_start: u64 = 0x100000000; // ??? example, 4GB
var heap_end: u64 = 0x200000000; // 8GB
var heap_current: u64 = undefined;

/// Allocate space by given size in the heap address space.
/// (Works like a pretty simple Bump Allocator)
pub fn alloc(size: usize) ?[*]u8 {
    // align address by the PAGE_SIZE bound
    const aligned = (heap_current + 4095) & ~4095;
    if (aligned + size > heap_end) return null;

    var address: PhysicalAddress = aligned;
    while (address < (aligned + size)) : (address += PAGE_SIZE) {
        const page = pmm.alloc() orelse return null;
        mapCurrent(
            address,
            page,
            PageFlags.PRESENT | PageFlags.WRITE,
        );
    }

    heap_current = aligned + size;
    // Finally take a C-like array from the computed address
    return @as([*]u8, @ptrFromInt(aligned));
}
/// Release given space
// pub fn free(space: []u8) void {
//     // Bump allocator doesn't need it.
// }
/// Returns a pointer to the record in the matching table for each virtual address
/// If table is missing -> makes it (not PML4 which must be presented already!)
/// Makes an "Identity Mapping"
fn getPageEntry(
    _: enum { PML4, PDP, PD, PT },
    pml4_phys: PhysicalAddress,
    virtual: u64,
) !*PageEntry {
    const pml4 = @as(*PML4, @ptrFromInt(pml4_phys));
    const pml4_idx = pml4Index(virtual);

    if (!pml4[pml4_idx].present) {
        // make page directory (PDP)
        const pdp_location = pmm.alloc()
            orelse return error.OutOfMemory;

        //@memset(@as([*]u8, @ptrFromInt(new_pdp)), 0, PAGE_SIZE);
        mem.set(u8, @ptrFromInt(pdp_location), PAGE_SIZE, 0);

        pml4[pml4_idx] = PageEntry.init(
            pdp_location,
            PageFlags.PRESENT | PageFlags.WRITE,
        );
    }

    const pdp_location = pml4[pml4_idx].get();
    const pdp = @as(*PDP, @ptrFromInt(pdp_location));
    const pdp_idx = pdpIndex(virtual);

    if (!pdp[pdp_idx].present) {
        const pd_location = pmm.alloc()
            orelse return error.OutOfMemory;
        //@memset(@as([*]u8, @ptrFromInt(new_pd)), 0, PAGE_SIZE);
        mem.set(u8, @ptrFromInt(pd_location), PAGE_SIZE, 0);
        pdp[pdp_idx] = PageEntry.init(
            pd_location,
            PageFlags.PRESENT | PageFlags.WRITE,
        );
    }

    const pd_location = pdp[pdp_idx].get();
    const pd = @as(*PD, @ptrFromInt(pd_location));
    const pd_idx = pdIndex(virtual);

    if (!pd[pd_idx].present) {
        const new_pt = pmm.alloc()
            orelse return error.OutOfMemory;

        //@memset(@as([*]u8, @ptrFromInt(new_pt)), 0);
        mem.set(u8, @ptrFromInt(new_pt), PAGE_SIZE, 0);

        pd[pd_idx] = PageEntry.init(
            new_pt,
            PageFlags.PRESENT | PageFlags.WRITE,
        );
    }

    const pt_location = pd[pd_idx].get();
    const pt = @as(*PT, @ptrFromInt(pt_location));
    const pt_idx = ptIndex(virtual);

    return &pt[pt_idx];
}
/// Map default page
pub fn map4K(
    pml4_phys: PhysicalAddress,
    virtual: u64,
    phys: PhysicalAddress,
    flags: u64,
) !void {
    // Give a PT record
    const pt_entry = try getPageEntry(.PT, pml4_phys, virtual);
    pt_entry.* = PageEntry.init(phys, flags);
    vmm_invalidate_tlb(virtual);
}

/// Mapping of `HUGE` page. (2MiB)
pub fn map2M(
    pml4_phys: PhysicalAddress,
    virtual: u64,
    physical: PhysicalAddress,
    flags: u64,
) !void {
    // 2MiB page means the record of PD with a HUGE flag.
    // Walking through the pages: PAGE -> PDP -> PD
    const pml4 = @as(*PML4, @ptrFromInt(pml4_phys));
    const pml4_idx = pml4Index(virtual);
    if (!pml4[pml4_idx].present) {
        const new_pdp = pmm.alloc()
            orelse return error.OutOfMemory;
        //@memset(@as([*]u8, @ptrFromInt(new_pdp)), 0, PAGE_SIZE);
        mem.set(u8, @ptrFromInt(new_pdp), PAGE_SIZE, 0);
        pml4[pml4_idx] = PageEntry.init(
            new_pdp,
            PageFlags.PRESENT | PageFlags.WRITE,
        );
    }
    const pdp_phys = pml4[pml4_idx].get();
    const pdp = @as(*PDP, @ptrFromInt(pdp_phys));
    const pdp_idx = pdpIndex(virtual);
    if (!pdp[pdp_idx].present) {
        const new_pd = pmm.alloc()
            orelse return error.OutOfMemory;
        //@memset(@as([*]u8, @ptrFromInt(new_pd)), 0, PAGE_SIZE);
        mem.set(u8, @ptrFromInt(new_pd), PAGE_SIZE, 0);
        pdp[pdp_idx] = PageEntry.init(
            new_pd,
            PageFlags.PRESENT | PageFlags.WRITE,
        );
    }
    const pd_phys = pdp[pdp_idx].get();
    const pd = @as(*PD, @ptrFromInt(pd_phys));
    const pd_idx = pdIndex(virtual);
    // Set a record in the page directory -> about HUGE page
    pd[pd_idx] = PageEntry.init(
        physical,
        flags | PageFlags.HUGE,
    );
    vmm_invalidate_tlb(virtual);
}
/// Initial identity mapping. It means that all virtual address space
/// will be 1:1 with the physical memory map
pub fn init(max_phys: PhysicalAddress) !PhysicalAddress {
    // Identity mapping: от 0 до at least 1GB (0x40000000)
    const identity_end = @max(max_phys, 0x40000000);
    console.printf(
        "VMM: identity map 0 -> 0x{X}\n",
        .{identity_end},
    );

    // x86-64 4-level paging: PML4 -> PDP -> PD (2MB pages) -> PT (4KB)
    // Fast identity mapping -> 2MB huge pages
    //   PML4[0] -> PDP
    //   PDP[i]  -> 2MB page (if i < identity_end / 0x200000)
    //   PDP[i]  -> PD + PT
    //
    // PML4[0] -> PDP (1 стр.)
    // PDP[0]  -> 1GB page (huge=1) covers 0..0x40000000
    // Summary: 2 pages!

    const pml4 = pmm.alloc() orelse return error.OutOfMemory;
    const pdp_page = pmm.alloc() orelse return error.OutOfMemory;

    mem.set(u8, @ptrFromInt(pml4), PAGE_SIZE, 0);
    mem.set(u8, @ptrFromInt(pdp_page), PAGE_SIZE, 0);
    console.printf(
        "VMM: PML4 @0x{X}, PDP @0x{X}\n",
        .{ pml4, pdp_page },
    );

    // PML4[0] -> PDP (present, writeable)
    const pml4_array: *volatile PML4 = @ptrFromInt(pml4);
    pml4_array[0] = PageEntry.init(
        pdp_page,
        PageFlags.PRESENT | PageFlags.WRITE,
    );
    console.printf("VMM: PML4[0] set\n", .{});

    // PDP[0..] -> 2MB huge pages для всего identity диапазона
    const pdp_array: *volatile PDP = @ptrFromInt(pdp_page);
    var addr: u64 = 0;
    while (addr < identity_end) : (addr += 0x200000) {
        const idx = pdpIndex(addr);
        pdp_array[idx] = PageEntry.init(
            addr,
            PageFlags.PRESENT | PageFlags.WRITE | PageFlags.HUGE,
        );
    }
    console.printf(
        "VMM: mapped {} 2MB pages\n",
        .{addr / 0x200000},
    );

    current_pml4_phys = pml4;
    console.printf("VMM: loading CR3...\n", .{});
    vmm_set_pml4(pml4);
    console.printf("VMM: CR3 loaded\n", .{});

    // Init memory heap
    const heap = pmm.locateFree();
    heap_start = heap.start * PAGE_SIZE;
    heap_end = heap_start + (heap.count * PAGE_SIZE);
    heap_current = heap_start;
    console.printf(
        "Heap location: 0x{X}-0x{X}\n",
        .{ heap_start, heap_end },
    );
    return pml4;
}
/// Write an address of another page in the CR3
pub fn switchToPml4(pml4_phys: PhysicalAddress) void {
    vmm_set_pml4(pml4_phys);
    current_pml4_phys = pml4_phys;
}

pub fn mapCurrent(
    virt: u64,
    phys: PhysicalAddress,
    flags: u64,
) !void {
    try map4K(current_pml4_phys, virt, phys, flags);
}
