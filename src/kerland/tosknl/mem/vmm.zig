//! vmm.zig – Virtual Memory Manager
const std = @import("std");
const pmm = @import("pmm.zig");
const mem = @import("core.zig");
const console = &@import("../text/console.zig").console;
const PhysicalAddress = pmm.PhysicalAddress;

pub const PAGE_SIZE = 4096;
pub const PAGE_SHIFT = 12;
pub const ENTRIES_PER_TABLE = 512;

extern fn vmm_invalidate_tlb(address: u64) void;
extern fn vmm_set_pml4(address: u64) void;

pub const PageFlags = struct {
    pub const PRESENT = 1 << 0;
    pub const WRITE   = 1 << 1;
    pub const USER    = 1 << 2;
    pub const WT      = 1 << 3;
    pub const CD      = 1 << 4;
    pub const ACCESS  = 1 << 5;
    pub const DIRTY   = 1 << 6;
    pub const HUGE    = 1 << 7;
    pub const GLOBAL  = 1 << 8;
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
pub const PDP  = [ENTRIES_PER_TABLE]PageEntry;
pub const PD   = [ENTRIES_PER_TABLE]PageEntry;
pub const PT   = [ENTRIES_PER_TABLE]PageEntry;

inline fn pml4Index(virt: u64) usize { return @as(usize, (virt >> 39) & 0x1FF); }
inline fn pdpIndex(virt: u64) usize  { return @as(usize, (virt >> 30) & 0x1FF); }
inline fn pdIndex(virt: u64) usize   { return @as(usize, (virt >> 21) & 0x1FF); }
inline fn ptIndex(virt: u64) usize   { return @as(usize, (virt >> 12) & 0x1FF); }

var current_pml4_phys: PhysicalAddress = 0;

/// Returns a pointer to the record in the matching table for each virtual address
/// If table is missing -> makes it (not PML4 which must be presented already!)
/// Makes an "Identity Mapping"
fn getTableEntry(level: enum { PML4, PDP, PD, PT }, pml4_phys: PhysicalAddress, virtual: u64) !*PageEntry {
    console.printf("Given request: {}\n", .{level});
    const pml4 = @as(*PML4, @ptrFromInt(pml4_phys));
    const pml4_idx = pml4Index(virtual);

    console.printf("PML4#{} located @0x{X}\n", .{pml4_idx + 1, virtual});    

    if (!pml4[pml4_idx].present) {
        console.printf("PML4 not present!\n", .{});
        // make page directory (PDP)
        const pdp_location = pmm.alloc() orelse return error.OutOfMemory;

        //@memset(@as([*]u8, @ptrFromInt(new_pdp)), 0, PAGE_SIZE);
        mem.set(u8, @ptrFromInt(pdp_location), PAGE_SIZE, 0);

        pml4[pml4_idx] = PageEntry.init(pdp_location, PageFlags.PRESENT | PageFlags.WRITE);
        console.printf("Page initialized @0x{X}\n", .{pdp_location});
    }
    
    const pdp_location = pml4[pml4_idx].get();
    const pdp = @as(*PDP, @ptrFromInt(pdp_location));
    const pdp_idx = pdpIndex(virtual);
    
    console.printf("PDP#{} located @0x{X}\n", .{pdp_idx + 1, pdp_location});

    if (!pdp[pdp_idx].present) {
        console.printf("PDP not present!\n", .{});
        
        const pd_location = pmm.alloc() orelse return error.OutOfMemory;
        //@memset(@as([*]u8, @ptrFromInt(new_pd)), 0, PAGE_SIZE);
        mem.set(u8, @ptrFromInt(pd_location), PAGE_SIZE, 0);
        pdp[pdp_idx] = PageEntry.init(pd_location, PageFlags.PRESENT | PageFlags.WRITE);

        console.printf("Page initialized @0x{X}\n", .{pd_location});
    }
    
    const pd_location = pdp[pdp_idx].get();
    const pd = @as(*PD, @ptrFromInt(pd_location));
    const pd_idx = pdIndex(virtual);

    console.printf("PD#{} located @0x{X}\n", .{pd_idx + 1, pd_location});

    if (!pd[pd_idx].present) {
        console.printf("PD not present!\n", .{});
        
        const new_pt = pmm.alloc() orelse return error.OutOfMemory;
        
        //@memset(@as([*]u8, @ptrFromInt(new_pt)), 0);
        mem.set(u8, @ptrFromInt(new_pt), PAGE_SIZE, 0);
        
        pd[pd_idx] = PageEntry.init(new_pt, PageFlags.PRESENT | PageFlags.WRITE);
        console.printf("Page initialized @0x{X}\n", .{pdp_location});
    }
    
    const pt_location = pd[pd_idx].get();
    const pt = @as(*PT, @ptrFromInt(pt_location));
    const pt_idx = ptIndex(virtual);
    
    console.printf("PT#{} located @0x{X}\n", .{pt_idx + 1, pt_location});
    console.printf("PTs located @0x{X}\n", .{@intFromPtr(&pt[pd_idx])});
    return &pt[pt_idx];
}
/// Map default page
pub fn map4K(pml4_phys: PhysicalAddress, virtual: u64, phys: PhysicalAddress, flags: u64) !void {
    // Give a PT record
    const pt_entry = try getTableEntry(.PT, pml4_phys, virtual);
    pt_entry.* = PageEntry.init(phys, flags);
    vmm_invalidate_tlb(virtual);
}

/// Mapping of `HUGE` page. (2MiB)
pub fn map2M(pml4_phys: PhysicalAddress, virtual: u64, physical: PhysicalAddress, flags: u64) !void {
    // 2MiB page means the record of PD with a HUGE flag.
    // Walking through the pages: PAGE -> PDP -> PD
    const pml4 = @as(*PML4, @ptrFromInt(pml4_phys));
    const pml4_idx = pml4Index(virtual);
    if (!pml4[pml4_idx].present) {
        const new_pdp = pmm.alloc() orelse return error.OutOfMemory;
        //@memset(@as([*]u8, @ptrFromInt(new_pdp)), 0, PAGE_SIZE);
        mem.set(u8, @ptrFromInt(new_pdp), PAGE_SIZE, 0);
        pml4[pml4_idx] = PageEntry.init(new_pdp, PageFlags.PRESENT | PageFlags.WRITE);
    }
    const pdp_phys = pml4[pml4_idx].get();
    const pdp = @as(*PDP, @ptrFromInt(pdp_phys));
    const pdp_idx = pdpIndex(virtual);
    if (!pdp[pdp_idx].present) {
        const new_pd = pmm.alloc() orelse return error.OutOfMemory;
        //@memset(@as([*]u8, @ptrFromInt(new_pd)), 0, PAGE_SIZE);
        mem.set(u8, @ptrFromInt(new_pd), PAGE_SIZE, 0);
        pdp[pdp_idx] = PageEntry.init(new_pd, PageFlags.PRESENT | PageFlags.WRITE);
    }
    const pd_phys = pdp[pdp_idx].get();
    const pd = @as(*PD, @ptrFromInt(pd_phys));
    const pd_idx = pdIndex(virtual);
    // Set a record in the page directory -> about HUGE page
    pd[pd_idx] = PageEntry.init(physical, flags | PageFlags.HUGE);
    vmm_invalidate_tlb(virtual);
}
/// Initial identity mapping. It means that all virtual address space 
/// will be 1:1 with the physical memory map
pub fn init(max_address: PhysicalAddress) !PhysicalAddress {
    // Firstly I need to make a page map level=4.

    const pml4_location = pmm.alloc() orelse return error.OutOfMemory;
    console.printf("PML4 init location @0x{X}\n", .{pml4_location});
    
    mem.set(u8, @ptrFromInt(pml4_location), PAGE_SIZE, 0);
    
    // Then map all physical memory.
    // One problem what I have: I don't know actual memory size.
    // UEFI services represents this info -> depending on this we need to define
    // how huge memory mapping should be. (4GB map by 4K pages will be very bad.)
    var virtual: u64 = 0;
    while (virtual < max_address) {
        // Can I use a 2 MiB page? 
        const remaining = max_address - virtual;
        if ((virtual & 0x1FFFFF) == 0 and remaining >= 0x200000) {
            try map2M(pml4_location, virtual, virtual, PageFlags.PRESENT | PageFlags.WRITE);
            virtual += 0x200000;
        } else {
            try map4K(pml4_location, virtual, virtual, PageFlags.PRESENT | PageFlags.WRITE);
            virtual += PAGE_SIZE;
        }
    }
    console.printf("Mapped @0x{X}\n", .{virtual});
    // save all changes and place current 4th level page in the CR3
    // (register in the x86-64 specific)
    console.printf("Current PML4 page located @0x{X}\n", .{pml4_location});
    current_pml4_phys = pml4_location;
    vmm_set_pml4(pml4_location);

    return pml4_location;
}
/// Write an address of another page in the CR3
pub fn switchToPml4(pml4_phys: PhysicalAddress) void {
    vmm_set_pml4(pml4_phys);
    current_pml4_phys = pml4_phys;
}

pub fn mapCurrent(virt: u64, phys: PhysicalAddress, flags: u64) !void {
    try map4K(current_pml4_phys, virt, phys, flags);
}