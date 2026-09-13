const FirmwareInterface = @import("fi.zig").FirmwareInterface;
const uefi = @import("std").os.uefi;

pub const MemoryKind = enum {
    Free,
    Reserved,
    Kernel,
    BadMemory,
};

pub const MemorySegment = struct {
    base: usize,
    len: usize,
    page_count: usize,
    type: MemoryKind,
};

pub const MemoryMap = struct {
    regions: [512]MemorySegment = undefined,
    count: usize = 0,
};

// Physical bitmap: one bit per 4096-byte page. It is the source of truth for
// "used vs free" and is kept consistent with the free list.
var map: [*]u8 = undefined;
var map_size: usize = 0;

// Highest address (exclusive) covered by the map and the derived page count.
var phys_max_address: usize = 0;
var pages: usize = 0;

// Head of the singly-linked free list, addressed in physical bytes, 0 = empty.
// The "next" pointer of every free page lives at the start of that page itself.
var free_head: usize = 0;
var free_count: usize = 0;

// Base of the region that holds the bitmap (kept for debugging / accounting).
var free_start: usize = 0;

// Single spinlock guarding the allocator. On a single core the first `xchg`
// wins immediately, so it is effectively a no-op until SMP lands.
var lock_: u8 = 0;

fn lock() void {
    while (@atomicRmw(u8, &lock_, .Xchg, 1, .seq_cst) != 0) {}
}

fn unlock() void {
    @atomicStore(u8, &lock_, 0, .seq_cst);
}

// Free-list plumbing. The next free page's address is stored at the start of
// each free page, so we read/write an unaligned `usize` at the page base.
fn nextOf(page: usize) usize {
    const cell: *align(1) usize = @ptrFromInt(page);
    return cell.*;
}

fn setNext(page: usize, next: usize) void {
    const cell: *align(1) usize = @ptrFromInt(page);
    cell.* = next;
}

/// Returns the base address where the page bitmap can live. Prefers the lowest
/// free region that is big enough to hold `need` bytes, rounded up to a page.
fn bitmapBase(regions: *MemoryMap, need: usize) usize {
    var i: usize = 0;
    while (i < regions.count) : (i += 1) {
        const region = &regions.regions[i];
        if (region.type == .Free) {
            const start = up(region.base);
            const end = region.base + region.len;
            if (need == 0 or start + need <= end) {
                return start;
            }
        }
        i += 1;
    }

    return 0;
}

///
/// Initializes a physical memory allocator
///
pub fn init(b: *FirmwareInterface) void {
    var mmap: MemoryMap = .{};
    phys_max_address = getmem(
        &mmap,
        b.map,
        b.map_size,
        b.desc_size,
    );

    pages = phys_max_address / 4096;
    map_size = (pages + 7) / 8;

    // The bitmap needs real RAM to live in, so carve a slab out of the lowest
    // free region and point the bitmap at it. `free_start` keeps the base.
    const base = bitmapBase(&mmap, map_size);
    free_start = base;
    map = @as([*]u8, @ptrFromInt(base));

    // Default to "everything is taken". Any region UEFI did not describe, plus
    // the kernel image and reserved/bad memory, will never be handed out.
    var i: usize = 0;
    while (i < map_size) : (i += 1) map[i] = 0xFF;

    // Only explicitly free regions become allocatable.
    i = 0;
    while (i < mmap.count) : (i += 1) {
        const region = &mmap.regions[i];
        if (region.type == .Free) {
            resetSegment(region.base, region.len);
        }
        i += 1;
    }

    // The allocator must not hand out the very memory the bitmap occupies.
    setSegment(base, map_size);

    // Build the free list by walking the bitmap. Every page whose bit is still
    // clear is empty, so chain them together through their own first `usize`.
    free_head = 0;
    free_count = 0;
    i = 0;
    while (i < pages) : (i += 1) {
        if (!@"test"(i)) {
            const addr = i * 4096;
            setNext(addr, free_head);
            free_head = addr;
            free_count += 1;
        }
        i += 1;
    }
}

///
/// Returns allocated by UEFI memory in bytes.
///
pub fn getMemorySize() usize {
    return phys_max_address;
}

/// Total number of 4096-byte pages that fit in physical memory.
pub fn getPageCount() usize {
    return pages;
}

/// Number of pages currently available for allocation (not including the bitmap).
pub fn getFreePages() usize {
    return free_count;
}

fn set(b: usize) void {
    map[b / 8] |= @as(u8, 1) << @intCast(b % 8);
}

fn reset(b: usize) void {
    map[b / 8] &= ~(@as(u8, 1) << @intCast(b % 8));
}

fn @"test"(b: usize) bool {
    return (map[b / 8] & (@as(u8, 1) << @intCast(b % 8))) != 0;
}

fn up(address: usize) usize {
    if (address % 4096 == 0) {
        return address;
    }

    return (address + 4096) - (address % 4096);
}

fn resetSegment(start: usize, len: usize) void {
    var pagei = start / 4096;
    const pagec = len / 4096;
    var i: usize = 0;

    while (i < pagec) : (i += 1) {
        reset(pagei);
        pagei += 1;
    }
}

fn setSegment(start: usize, len: usize) void {
    var pagei = start / 4096;
    const pagec = (len + 4096 - 1) / 4096;
    var i: usize = 0;

    while (i < pagec) : (i += 1) {
        set(pagei);
        pagei += 1;
    }
}

pub fn alloc() ?usize {
    lock();
    if (free_head == 0) {
        unlock();
        return null; // out of physical page frames
    }
    const page = free_head;
    free_head = nextOf(page);
    free_count -= 1;
    set(page / 4096);
    unlock();
    return page;
}

pub fn free(page: usize) void {
    lock();
    const pagei = page / 4096;
    if (pagei >= pages) {
        unlock();
        return;
    }
    if (!@"test"(pagei)) {
        unlock();
        return; // already free -> ignore double free
    }
    setNext(page, free_head);
    free_head = page;
    free_count += 1;
    reset(pagei);
    unlock();
}

fn getmem(
    global_map: *MemoryMap,
    descs: [*]uefi.tables.MemoryDescriptor,
    size: usize,
    desc_size: usize,
) usize {
    var offset: usize = 0;
    const base_ptr = @as([*]u8, @ptrCast(descs));
    var idx: usize = 0;
    var max_ram: usize = 0;

    while (offset < size) : (offset += desc_size) {
        if (idx >= global_map.regions.len) {
            break;
        }
        // const desc: *uefi.tables.MemoryDescriptor = @ptrFromInt(base_ptr + offset);
        const desc = @as(
            *align(1) uefi.tables.MemoryDescriptor,
            @ptrCast(base_ptr + offset),
        );

        if (desc.number_of_pages == 0) continue;

        const kind: MemoryKind = switch (desc.type) {
            .conventional_memory => .Free,
            .boot_services_code,
            .boot_services_data => .Reserved,
            .loader_code, .loader_data => .Kernel,
            .acpi_reclaim_memory => .Reserved,
            .acpi_memory_nvs => .Reserved,
            .unusable_memory => .BadMemory,
            else => .Reserved,
        };
        var region = &global_map.regions[idx];
        region.base = desc.physical_start;
        region.type = kind;
        region.page_count = desc.number_of_pages;
        region.len = desc.number_of_pages * 4096;
        if (kind == .Free or kind == .Kernel) {
            const region_end = desc.physical_start
                + (desc.number_of_pages * 4096);
            if (region_end > max_ram) {
                max_ram = region_end;
            }
        }
        idx += 1;
    }
    global_map.count = idx;
    return max_ram;
}
