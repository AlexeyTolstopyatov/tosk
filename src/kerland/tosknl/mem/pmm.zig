//! Physial Memory Allocator module
const BootInfo = @import("../boot/boot_info.zig").BootInfo;
const EfiMemoryDescriptor = @import("uefi.zig").EfiDescriptor;
const EfiMemoryType = @import("uefi.zig").EfiMemoryType;
const text = @import("../text/debug.zig");
/// Little abstraction under the kernel logic.
/// This type contains pure unsigned long long but we operate physical addresses
/// in this module, that's why I need to cover it 
pub const PhysicalAddress = u64;

const PAGE_SIZE = 4096;
pub const MAX_PHYS_ADDR: u64 = 0x100000000; // 4GB
const PHYSMAP_SIZE = (MAX_PHYS_ADDR / PAGE_SIZE + 7) / 8;

var bitmap: [PHYSMAP_SIZE]u8 = .{0} ** PHYSMAP_SIZE;
var total_pages: usize = 0;
var last_alloc_page: usize = 0;

/// Initializes physical memory allocator and puts 
/// state in the debug port. (QEMU stdout) 
pub fn init(boot: *BootInfo) void {
    // Zero step, as GNU EFI services says: 
    // All memory are allocated for something. (I can't give it for any purposes)
    @memset(&bitmap, 0xFF);
    // Then, despite the fact that EFI services placed my kernel code/data
    // in the EfiMemoryType.loader_data objects -> I'll reserve anything what
    // are defines an address space of kernel image.
    reserve(boot.module_start, boot.module_end - boot.module_start);
    // Then free all not-reserved pages
    total_pages = MAX_PHYS_ADDR / PAGE_SIZE;
    text.kprintbf("Defined {} memory pages\n", .{total_pages});
    // Firstly reserve kernel memory pages. 
    // Secondary free conventional memory pages. (idk how EFI boot services mapped my kernel pages) 
    var ptr = boot.memory_map;
    const end = ptr + boot.memory_map_size;
    
    while (@intFromPtr(ptr) < @intFromPtr(end)) : (ptr += boot.memory_map_desc_size) {
        const desc: *EfiMemoryDescriptor = @ptrCast(@alignCast(ptr));
        if (desc.memory_type == EfiMemoryType.conventional) {
            const start_page = desc.physical_address / PAGE_SIZE;
            const num_pages = desc.number_of_pages;
            bmpSetRange(start_page, num_pages, false); // false = freed
        }
    }

    reserve(boot.module_start, boot.module_end - boot.module_start);
    text.kprintbf("Last allocated: Page #{}\n", .{last_alloc_page + 1});
}
/// Tries to allocate physical memory page and returns
/// address (or not). If given address is None -> allocation failed.  
pub fn alloc() ?PhysicalAddress {
    var page = last_alloc_page;
    while (page < total_pages) : (page += 1) {
        if (!bmpGet(page)) {
            // Found free page
            bmpSet(page, true);
            last_alloc_page = page + 1;
            return @as(PhysicalAddress, page * PAGE_SIZE);
        }
    }
    // Not found but try again from the start.
    page = 0;
    while (page < last_alloc_page) : (page += 1) {
        if (!bmpGet(page)) {
            bmpSet(page, true);
            last_alloc_page = page + 1;
            return @as(PhysicalAddress, page * PAGE_SIZE);
        }
    }
    return null; // all pages reserved :3
}
/// Mark page as unused and rewrites the bitmap of it
pub fn free(addr: PhysicalAddress) void {
    const page = addr / PAGE_SIZE;
    bmpSet(page, false);
    // make sure that [last_alloc_page] stays correct
}
/// This function might call many times -> I embed it in the body of caller
inline fn bmpGet(page: usize) bool {
    const byte = bitmap[page / 8];
    return (byte & (@as(u8, 1) << @as(u3, @truncate(page % 8)))) != 0;
}
/// This function might call many times -> I embed it in the body of caller
inline fn bmpSet(page: usize, occupied: bool) void {
    const byte_index = page / 8;
    const bit_index = @as(u3, @truncate(page % 8));
    if (occupied) {
        bitmap[byte_index] |= (@as(u8, 1) << bit_index);
    } else {
        bitmap[byte_index] &= ~(@as(u8, 1) << bit_index);
    }
}
/// Reserves pages by given address and size 
pub fn reserve(start_addr: PhysicalAddress, size: usize) void {
    const start_page = start_addr / PAGE_SIZE;
    const page_count = (size + PAGE_SIZE - 1) / PAGE_SIZE;
    bmpSetRange(start_page, page_count, true);
}

fn bmpSetRange(start: usize, count: usize, occupied: bool) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        bmpSet(start + i, occupied);
    }
}