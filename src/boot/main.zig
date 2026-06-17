//! Toska bootloader will setup an address space, initializes a FS protocol
//! and tries to give a control to loaded kernel module in the .../kerland directory
//! 
//! Zig coding guidelines declare us the following:
//!   1) Types are written in PascalCase -> functions which return [type] -> PascalCase
//!   2) Functions which return a type instance are writen in camelCase
//!   3) Enum types are C-styled or snake_case
//!   4) Variables/Constants are C-styled or snake_case
//!   5) Global program constants are snake_case! 
const uefi = @import("std").os.uefi;
const std = @import("std");
const guid = @import("std").os.uefi.Guid;
const text = @import("text.zig");
const pe = @import("pe/pe_loader.zig");
/// BootInfo is an important data structure which will be used
/// after exiting EFI boot services. Kernel .EXE module will be use it 
/// to know where the physical devices ports are located in the memory.
const BootInfo = extern struct {
    memory_map: [*]u8,
    memory_map_size: usize,
    memory_map_desc_size: usize,
    framebuffer_base: *volatile anyopaque,
    framebuffer_width: u32,
    framebuffer_height: u32,
    rsdp: ?*anyopaque,
    module_start: usize,
    module_end: usize
    // anything here??
};
/// At the moment of the Zig 0.16:
/// 
/// Zig linker will select this entry and hides deep into the code.
/// Actually, if `std.Build` options are standing for EFI Application - 
/// Zig makes a EfiMain and call this `main` from there.
/// And knowing that well-known `EfiMain(HANDLE, *SystemTable) -> EFI_STATUS` function 
/// initializes the EFI boot services and EFI runtime services. 
/// Thats why I can operate the `SystemTable` from out-of-box.
pub fn main() void {
    // Get initialized EFI services for a first time.
    text.efiInitConsoleOutput();
    text.stdout.setAttribute(.{ .foreground = .white }) catch {};
    // Print a welcome "informative" message
    text.printfn("Running with the ring-0 privileges.", .{});
    text.printfn("The bootx64 is going to setup an address space", .{});
    text.printfn("load kernel module and give a control to the main procedure by pointer.", .{});
    
    const boot_services = uefi.system_table.boot_services.?;
    // Catch the graphics protocol
    var fb_base: *anyopaque = undefined;
    var fb_width: u32 = 0;
    var fb_height: u32 = 0;
    const gop_guid = uefi.protocol.GraphicsOutput.guid;
    var gop: *uefi.protocol.GraphicsOutput = undefined;
    
    if (boot_services._locateProtocol(&gop_guid, null, @ptrCast(&gop)) == .success) {
        const mode_info = gop.mode.info;
        fb_base = @ptrFromInt(gop.mode.frame_buffer_base);
        fb_width = mode_info.horizontal_resolution;
        fb_height = mode_info.vertical_resolution;
    }
    
    // RSDP
    var rsdp: ?*anyopaque = null;
    const acpi_guid = uefi.tables.ConfigurationTable.acpi_10_table_guid;

    const config_table = uefi.system_table.configuration_table;
    const tab_entries: usize = uefi.system_table.number_of_table_entries;

    for (config_table, 0..tab_entries) |entry, _| {
        // std.mem.eql(u8, &entry.vendor_guid, &acpi_guid)
        // transform GUID into bytes sequence and compare themsevles
        if (entry.vendor_guid.eql(acpi_guid)) {
            rsdp = entry.vendor_table;
            break;
        }
    }
    // Kernel module is going to be loaded
    const kfile_handle = pe.tryOpen("init.exe", boot_services) catch |err| {
        text.errorfn("Failed to open file: {}", .{err});
        while (true) {}
    };
    // Expected a valid Portable Executable (later will be my own relocatable OMF)
    // with the NATIVE subsystem and the Toska artifacts.
    const kdata: []align(8) u8 = pe.tryRead(kfile_handle, boot_services) catch |err| {
        text.errorfn("Failed to read: {}", .{err});
        return;
    };
    // As we've already got the file bytes, the best idea 
    // is and close file stream now. No `defer` call
    defer _ = kfile_handle.close() catch {};
    defer boot_services.freePool(kdata.ptr) catch {};
    // Then, Operating system is going to start now.
    // Image read already and must be loaded into the memory.
    // Given entry_point will be a raw image (exactly) offset in the map
    // And this address, instead of read "entry_point_rva" we must to catch
    // and call from the bootx64.efi.  
    const image = pe.tryLoad(kdata, uefi.handle, boot_services) catch |err| {
        text.errorfn("Failed to load: {}", .{err});
        while (true) {}
    };
    // If loading complete - get the control. efiUnsafeJump is breaking
    // down the stack after the memory map get. 
    // And exactly the truth type of it is "noreturn"!
    //
    // But if we really returned to this "main" - it is a catastrophic for us
    // because of loaded image is corrupted or loaded bad!. 
    tryJumpInit(boot_services, &image, fb_base, fb_width, fb_height, rsdp) catch {};

    text.errorfn("Catastrophic loader failure", .{});
    while(true) {}
}

fn tryJumpInit(
    boot: *uefi.tables.BootServices,
    image_data: *const pe.ImageData,
    fb: *anyopaque,
    fb_width: u32,
    fb_height: u32,
    rsdp: ?*anyopaque
) !void {
    // Try to know the minimum buffer size for memory map
    const map_info = try boot.getMemoryMapInfo();
    var map_size: usize = map_info.len * map_info.descriptor_size;
    
    map_size += 8 * map_info.descriptor_size;
    // Allocate buffer which will be used after exiting the boot services
    var map_buffer = try boot.allocatePool(.loader_data, map_size);
    errdefer boot.freePool(map_buffer.ptr) catch {};

    var memory_map_key: uefi.tables.MemoryMapKey = undefined;
    var final_map_slice: uefi.tables.MemoryMapSlice = undefined; // of [*]u8

    // Get memory map -> exit boot services
    while (true) {
        const result = boot.getMemoryMap(map_buffer);
        if (result) |slice| {
            final_map_slice = slice;
            memory_map_key = slice.info.key;
        } else |err| switch (err) {
            error.BufferTooSmall => {
                // Map is getting wide
                map_size = map_info.len * map_info.descriptor_size; // actual size
                map_size += 8 * map_info.descriptor_size;
                try boot.freePool(map_buffer.ptr);
                map_buffer = try boot.allocatePool(.loader_data, map_size);
                continue;
            },
            else => return err,
        }

        if (boot.exitBootServices(uefi.handle, memory_map_key)) {
            // Memory map caught successfully
            break;
        } else |err| {
            switch (err) {
                error.InvalidParameter => {
                    // Invalid key.
                    text.logfn("Getting memory map metadata again", .{}, @src());
                    continue;
                },
                error.Unexpected => {
                    text.errorfn("ExitBootServices fatal: {}", .{err});
                    return uefi.Error.LoadError;
                }
            }
        }
    }
    // Collect all data and send to the kernel module
    var boot_info = BootInfo {
        .memory_map = final_map_slice.ptr,
        .memory_map_size = final_map_slice.info.len,
        .memory_map_desc_size = map_info.descriptor_size,
        .framebuffer_base = @ptrCast(fb),
        .framebuffer_width = fb_width,
        .framebuffer_height = fb_height,
        .rsdp = rsdp,
        .module_start = image_data.start,
        .module_end = image_data.end
    };

    const kmain: *const fn (*BootInfo) callconv(.c) void = @ptrFromInt(image_data.*.entry_point);
    kmain(&boot_info);
}