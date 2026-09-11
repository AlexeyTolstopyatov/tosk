//!
//! UEFI bootloader for x86-64.
//!
//! Boots `\init`, a freestanding ELF64 x86-64 image, straight off the EFI
//! System Partition. The image's `PT_LOAD` segments are materialised at their
//! `p_vaddr`s (the canonical 1MiB-ish layout from `src/kerland/init/linker.ld`),
//! BSS is zero-filled, then control is handed to `e_entry` with a single
//! pointer to a `BootInfo` struct once the UEFI boot services have been torn
//! down.
//!
const std = @import("std");
const uefi = std.os.uefi;
const elf = @import("elf.zig");
const FirmwareInterface = @import("fi.zig").FirmwareInterface;

/// Physical page size UEFI allocates in (and what we align vaddrs on).
const PAGE_SIZE: u64 = 0x1000;

/// Scratch pool buffer holding the ELF payload while it is being read off the
/// ESP. `init` is small; 8MiB is generous headroom.
const STAGING_SIZE: usize = 8 * 1024 * 1024;

/// Maps a single `PT_LOAD` segment from the file image into physical memory at
/// its virtual address. Returns `Status.success` on success.
fn loadSegment(
    boot_services: *uefi.tables.BootServices,
    image: []const u8,
    seg: elf.Segment,
) uefi.Status {
    if (seg.virtual == 0) return .load_error;
    if (seg.mem_size == 0) return .load_error;

    // Cover [vaddr, vaddr + memsz) with whole, page aligned pages.
    const page_start = seg.virtual & ~(PAGE_SIZE - 1);
    const mem_end = seg.virtual + seg.mem_size;
    const page_end = (mem_end + PAGE_SIZE - 1)
        & ~(PAGE_SIZE - 1);
    const npages: usize = @intCast(
        (page_end - page_start) / PAGE_SIZE,
    );
    if (npages == 0) return .load_error;

    const pages = boot_services.allocatePages(
        .{ .address = @ptrFromInt(page_start) },
        .loader_code,
        npages,
    )
        catch return .aborted;

    const dst = std.mem.sliceAsBytes(pages);
    const off: usize = @intCast(seg.virtual - page_start);

    const file_off: usize = @intCast(seg.offset);
    const file_len: usize = @intCast(seg.filesz);
    if (file_off + file_len > image.len) return .load_error;

    // Copy the on-disk bytes of the segment.
    for (0..file_len) |k| {
        dst[off + k] = image[file_off + k];
    }

    // Zero the portion that only exists in memory (BSS / uninitialised data).
    const mem_len: usize = @intCast(seg.mem_size);
    if (mem_len > file_len) {
        @memset(dst[off + file_len..off + mem_len], 0);
    }

    return .success;
}

pub fn main() uefi.Status {
    const boot_services = uefi.system_table.boot_services
        orelse return .load_error;
    const con_out = uefi.system_table.con_out
        orelse return .load_error;

    _ = con_out.outputString(
        &[_:0]u16{ 'i', 'n', 'i', 't', ':', ':', ':', '\n' },
    ) catch {
        return .device_error;
    };

    // --- locate ACPI 2.0 RSDP while boot services are still alive ---
    var rsdp_addr: u64 = 0;
    const config_tables = uefi.system_table.configuration_table;
    const num_tables = uefi.system_table.number_of_table_entries;
    for (config_tables[0..num_tables]) |table| {
        if (
            std.mem.eql(
                u8,
                std.mem.asBytes(&table.vendor_guid),
                std.mem.asBytes(
                    &uefi
                        .tables
                        .ConfigurationTable
                        .acpi_20_table_guid,
                ),
            )
        ) {
            rsdp_addr = @intFromPtr(table.vendor_table);
            break;
        }
    }

    // --- open \init from the EFI System Partition ---
    const fs = boot_services.locateProtocol(
        uefi.protocol.SimpleFileSystem,
        null,
    )
        catch return .device_error;
    var root = fs.?.openVolume() catch return .device_error;
    var init_file = root.open(
        &[_:0]u16{ 'i', 'n', 'i', 't' },
        .read,
        .{},
    ) catch {
        root.close() catch {};
        return .not_found;
    };

    // --- read the whole payload into a scratch pool buffer ---
    const staging = boot_services.allocatePool(
        .loader_data,
        STAGING_SIZE,
    ) catch {
        init_file.close() catch {};
        root.close() catch {};
        return .aborted;
    };

    var total: usize = 0;
    while (total < STAGING_SIZE) {
        const n = init_file.read(staging[total..]) catch {
            init_file.close() catch {};
            root.close() catch {};
            return .device_error;
        };
        if (n == 0) break;
        total += n;
        if (total >= STAGING_SIZE) {
            init_file.close() catch {};
            root.close() catch {};
            return .load_error; // payload does not fit into the staging buffer
        }
    }

    init_file.close() catch {};
    root.close() catch {};

    const image = staging[0..total];

    // --- validate the ELF header and load every PT_LOAD segment ---
    const hdr = elf.parseHeader(image) orelse return .load_error;
    for (0..hdr.phnum) |i| {
        const seg = elf.segmentAt(image, &hdr, @as(usize, i))
            orelse continue;
        if (seg.ptype != elf.program_load) continue;
        const status = loadSegment(boot_services, image, seg);
        if (status != .success) return status;
    }

    // --- collect the physical memory map for the kernel ---
    var map_buf_ptr = boot_services.allocatePool(
        .boot_services_data,
        0x4000,
    )
        catch return .aborted;
    const map_buf = map_buf_ptr[0..0x4000];
    const memory_map = boot_services.getMemoryMap(map_buf)
        catch return .aborted;

    // --- hand hardware control over to the freshly loaded image ---
    _ = boot_services.exitBootServices(
        uefi.handle,
        memory_map.info.key,
    )
        catch return .aborted;

    var boot_info = FirmwareInterface{
        .map = @ptrCast(memory_map.ptr),
        .map_size = memory_map.info.len
            * memory_map.info.descriptor_size,
        .desc_size = memory_map.info.descriptor_size,
        .rsdp_addr = @intCast(rsdp_addr),
    };

    // --- transfer control to the image entry point (never returns) ---
    const KernelEntryFn = *const fn (
        info: *FirmwareInterface,
    ) callconv(.{ .x86_64_sysv = .{} }) noreturn;
    const entry: KernelEntryFn = @ptrFromInt(hdr.entry);

    entry(&boot_info);

    return .success; // unreachable
}
