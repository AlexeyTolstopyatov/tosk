//! Simple Portable executable bootloader. 
//! 
//! Despite the fact that the choise of object module format
//! for this target - PE32+, EFI runtime and boot services works
//! correct with *.efi applications. 
//! It means that firstly the kernel module must be signed by Windows Certificate 2.0
//! (requirements of SecureBoot), secondary kernel can't escape a boots services 
//! (exacly it can, we but don't want it!) 
//! and loaded kernel will be work in the EFI environment by unknown address in the mem.
//! 
//! Expected alternative perspective for it. Custom COFF/PE loader loads 
//! files by fixed address (0x10000000) and once file what we want is a [TOSKNL.EXE].
//! TOSKNL.EXE has a NATIVE subsystem flag, not EFI_ROM or any EFI_flag. 
//! It means the complete independance of EFI boots services and EFI memory layout rules. 
//! 
//! After the exiting the boot services, 
//! our keyboard and other devices support will be broken. (left completely as a EFI as well).
//! 
const std = @import("std");
const text = @import("../text.zig");
const ImageDosHeader = @import("dos_header.zig").ImageDosHeader;
const ImageFileHeader = @import("file_header.zig").ImageFileHeader;
const ImageOptionalHeader64 = @import("optional_header.zig").ImageOptionalHeader64;
const ImageSectionHeader = @import("section_table.zig").ImageSectionHeader;
const ImageBaseRelocation = @import("base_relocation.zig").ImageBaseRelocation;
const RelocationType = @import("base_relocation.zig").RelocationType;

const uefi = std.os.uefi;
const Guid = uefi.Guid;
const Status = uefi.Status;
const Handle = uefi.Handle;
const BootServices = uefi.tables.BootServices;
const SystemTable = uefi.tables.SystemTable;
const SimpleFileSystem = @import("std").os.uefi.protocol.SimpleFileSystem;

pub const ImageData = packed struct {
    start: u64,
    end: u64,
    entry_point: u64,
};
/// 16-bit magic field which contains 2 ASCII codes
/// "MZ" which stands for Mark Zbikowski - the Microsoft Engineer
/// which designed the relocatable executables for MS-DOS (2.0+)
const IMAGE_DOS_SIGNATURE = 0x5A4D;
/// 16-bit magic field with ASCII codes of "PE" which are standing for
/// "Portable Executable" object module format. 
/// (became complete and safe analog of Linear Executables "LE")
/// 
/// Independent of CPU architecture, this magic field always will be 
/// "PE\0\0". Byte/Word ordering doesn't influence on it. 
const IMAGE_NT_SIGNATURE = 0x00004550; // "PE\0\0"
/// Fixed expecting architecture flag which we want to see.
/// "bootx64.efi" are assembled and linked 
/// for IA32e (Intel x86-64) CPU architecture
const IMAGE_FILE_MACHINE_AMD64 = 0x8664;
/// The architecture flag `machine: u16` was defined a specific
/// of a hardware. Optional image header contains the special magic field
/// which doesn't describe the hardware specific but declares new rules of 
/// next following structure fields
///  - 0x10B - PE32 IMAGE_OPTIONAL_HEADER (32-bit executable -> interpret fields like "long")
///  - 0x20B - PE32+ IMAGE_OPTIONAL_HEADER (64-bit executable -> interpret fields lile "long long")
///  - 0x107 - PEROM IMAGE_ROM_HEADER. EFI ROM image header (rarely uses but lives now). 
const IMAGE_NT_OPTIONAL_HDR64_MAGIC = 0x20B;
/// Virtual protection flag. 
/// Section `characteristics` bitmask might contain this flag
/// 
/// Section containment might be executed by loader
const IMAGE_SCN_MEM_EXECUTE = 0x20000000;
/// Virtual protection flag: 
/// Section `characteristics` bitmask might contain this flag
/// 
/// loader can read the section containment
const IMAGE_SCN_MEM_READ = 0x40000000;
/// Virtual protection flag: 
/// Section `characteristics` bitmask might contain this flag
/// 
/// loader can write information into section container
const IMAGE_SCN_MEM_WRITE = 0x80000000;
/// Number of "Base Relocations" directory which stores
/// all memory fixups which must be applied to all addresses/pointers 
/// in the executable/shared module
const IMAGE_DIRECTORY_ENTRY_BASERELOC = 5;

const ImageNtHeaders64 = extern struct {
    /// Must be `IMAGE_NT_SIGNATURE`
    Signature: u32,
    /// Fixed size. Size of `FILE_HEADER`. 
    /// Contains important details of each module
    FileHeader: ImageFileHeader,
    /// Has variant size (see `IMAGE_NT_OPTIONAL_HDR64_MAGIC` magic details)
    /// PE loader of Tosk having support only x64 PE with Native subsystem flag.
    OptionalHeader: ImageOptionalHeader64,
};

/// Open TOSKNL.exe from the same volume as the bootloader
pub fn tryOpen(comptime file_name: []const u8, boot: *BootServices) !*uefi.protocol.File {
    // Before catching file bytes -> follow filesystem protocol API step-by-step
    //  -> Define protocol
    //  -> Locate file
    //  -> Catch kernel file, remember *File descriptor
    // Then the efiCatchKernel job is done. The "TOSKNL.EXE" descriptor ready
    // If something happen -> efiMain will stop with an error {err}
    const file_system = blk: {
        const res = boot.locateProtocol(uefi.protocol.SimpleFileSystem, null) catch |err| {
            text.errorfn("Locating simple file system protocol failed", .{});
            return err;
        };
        if (res) |fs| {
            break :blk fs;
        } else {
            text.errorfn("Simple file system protocol not found", .{});
            return error.NotFound;
        }
    };
    text.logfn("Filesys protocol rev: {}", .{file_system.revision}, @src());
    
    const root = file_system.openVolume() catch |err| {
        text.errorfn("Opening root volume failed: {}", .{err});
        return err;
    };
    // Now the filesys protocol is ready. Next following jobs are
    // locate the tosknl.exe and return target descriptor (*File)
    // EFI operates with the UTF16LE strings -> transform name
    const utf16_name = std.unicode.utf8ToUtf16LeStringLiteral(file_name);
    const tosknl = root.open(
        utf16_name,
        .read,
        .{ 
            .read_only = true, 
        },
    ) catch |err| {
        text.errorfn("Opening {s} failed", .{file_name});
        return err;
    };
    text.logfn("File rev: {}", .{tosknl.revision}, @src());

    // Don't close the file stream, just because of next call.
    // (TODO: make defer call and return pointer to file bytes)
    //defer tosknl.close() catch {};
    
    return tosknl;
}
/// Read the file by given descriptor 
/// into a buffer allocated by BootServices
pub fn tryRead(file: *uefi.protocol.File, boot: *BootServices) ![]align(8) u8 {
    // buffer size
    defer file.close() catch {};
    var info_buf_size: usize = 0;
    const info_status = file._get_info(file, &uefi.protocol.File.Info.File.guid, &info_buf_size, null);
    if (info_status != .buffer_too_small and info_status != .success) {
        text.errorfn("Failed to get file metadata size: {}", .{info_status});
        return error.GetInfoFailed;
    }
    if (info_buf_size == 0) return error.InvalidFile;

    const info_buf = try boot.allocatePool(.loader_data, info_buf_size);
    defer _ = boot.freePool(info_buf.ptr) catch {};

    // request FileInfo
    var actual_size = info_buf_size;
    
    const get_status = file._get_info(file, &uefi.protocol.File.Info.File.guid, &actual_size, info_buf.ptr);
    if (get_status != .success) {
        text.errorfn("Failed to get FileInfo: {}", .{get_status});
        return error.GetInfoFailed;
    }

    const file_info = @as(*align(1) const uefi.protocol.File.Info.File, @ptrCast(info_buf.ptr));
    const file_size = file_info.size + file_info.physical_size;

    text.printfn("Module data: {}", .{file_info});

    // whole file buffer
    const buffer = try boot.allocatePool(.loader_data, file_size);

    try file.setPosition(0);
    _ = try file.read(buffer);

    return buffer;
}

/// Apply relocations (base relocations) to the loaded kernel
fn efiResolveFixups(
    image_base: u64,
    headers: *const align(1) ImageNtHeaders64,
    sections: []const align(1) ImageSectionHeader,
    raw_bytes: []const u8,
    _: *BootServices,
) !void {
    const aligned_nt = @as(*const ImageNtHeaders64, @alignCast(headers));
    const rlc_dir = aligned_nt.OptionalHeader.directories[IMAGE_DIRECTORY_ENTRY_BASERELOC];
    if (rlc_dir.size == 0) return;
    // find Base relocations section. (usually .reloc)
    const reloc_section = for (sections) |sec| {
        const start = sec.virtual_address;
        const end = start + if (sec.virtual_size != 0) sec.virtual_size else sec.sizeof_raw_data;
        if (rlc_dir.virtual_address >= start and rlc_dir.virtual_address < end) {
            break sec;
        }
    } else {
        text.errorfn("Relocation directory not found in any section", .{});
        return error.RelocSectionNotFound;
    };

    const reloc_base = reloc_section.pointer_raw_data + (rlc_dir.virtual_address - reloc_section.virtual_address);
    
    var offset: u32 = 0;
    while (offset < rlc_dir.size) {

        const block = @as(*align(1) const ImageBaseRelocation, @ptrCast(
            raw_bytes[reloc_base + offset ..][0..@sizeOf(ImageBaseRelocation)]
        ));
    
        const block_va = block.virtual_address;
        const block_size = block.sizeof_block;
        if (block_size == 0) break;

        const num_entries = (block_size - @sizeOf(ImageBaseRelocation)) / 2;
        // bio.efiLogfn("Found {} entries", .{num_entries}, @src());

        const entries = @as([*]align(1) const u16, @ptrCast(
            raw_bytes[reloc_base + offset + @sizeOf(ImageBaseRelocation) ..]
        ))[0..num_entries];

        
        var i: usize = 0;
        while (i < num_entries) : (i += 1) {
            const entry = entries[i];
            const reloc_type = @as(RelocationType, @enumFromInt(entry >> 12));
            const rva = block_va + (entry & 0xFFF);
            const patch_addr = image_base + rva;
            switch (reloc_type) {
                .IMAGE_REL_BASED_DIR64 => {
                    // Integer overflow??
                    const delta =  if (aligned_nt.OptionalHeader.image_base < image_base) 
                        image_base - aligned_nt.OptionalHeader.image_base
                        else aligned_nt.OptionalHeader.image_base - image_base;

                    const original = @as(*u64, @ptrFromInt(patch_addr));
                    original.* += delta;
                    
                },
                .IMAGE_REL_BASED_HIGHLOW => {
                    // Might be integer overflow too?
                    const big_delta =  if (aligned_nt.OptionalHeader.image_base < image_base) 
                        image_base - aligned_nt.OptionalHeader.image_base
                        else aligned_nt.OptionalHeader.image_base - image_base;

                    const delta = @as(u32, @intCast(big_delta));
                    const original = @as(*u32, @ptrFromInt(patch_addr));
                    original.* += delta;
                },
                .IMAGE_REL_BASED_ABSOLUTE => {},
                else => return error.UnsupportedRelocation,
            }
            //bio.efiLogfn("Resolved #{} ({})", .{i + 1, reloc_type}, @src());
        }
        offset += block_size;
    }
}
/// Parse PE, copy sections, apply relocs, jump
pub fn tryLoad(file_bytes: []u8, _: Handle, boot_services: *BootServices) !ImageData {
    text.printfn("** Loading image **", .{});

    text.logfn("Bytes of DOS header", .{}, @src());
    const dos = @as(*align(1) const ImageDosHeader, @ptrCast(file_bytes.ptr));
    if (dos.e_magic != IMAGE_DOS_SIGNATURE) 
        return error.InvalidDosHeader;

    const ntHeadersOffset = dos.e_lfanew;
    text.logfn("Image offset: 0x{X}", .{ntHeadersOffset}, @src());
    
    const nt_headers = @as(*const align(1) ImageNtHeaders64, @ptrCast(file_bytes[ntHeadersOffset..][0..@sizeOf(ImageNtHeaders64)]));
    
    if (nt_headers.Signature != IMAGE_NT_SIGNATURE) return error.InvalidPeSignature;
    text.logfn("Defined 0x{X} signature", .{nt_headers.Signature}, @src());

    if (nt_headers.FileHeader.machine != IMAGE_FILE_MACHINE_AMD64) return error.WrongMachine;
    text.logfn("Architecture: x86-64", .{}, @src());

    if (nt_headers.OptionalHeader.magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) return error.Not64Bit;

    const entry_rva = nt_headers.OptionalHeader.entry_point_rva;
    text.logfn("Entry point RVA: 0x{X}", .{entry_rva}, @src());

    // Allocate memory for the kernel at its preferred base or anywhere
    const image_base = nt_headers.OptionalHeader.image_base;
    const sizeof_image = nt_headers.OptionalHeader.size_of_image;
    
    const AllocateLocation = uefi.tables.AllocateLocation;
    const MemoryType = uefi.tables.MemoryType;

    const page_count: usize = (sizeof_image + 0xFFF) >> 12;
    text.logfn("Expected {} pages", .{page_count}, @src());
    const allocated_mem = blk: {
        if (image_base != 0) {
            text.logfn("Image base: 0x{X}", .{image_base}, @src());
            const desired = @as([*]align(4096) uefi.Page, @ptrFromInt(image_base));

            const result = boot_services.allocatePages(
                AllocateLocation{ .address = desired },
                MemoryType.loader_data,
                page_count,
            );
            if (result) |mem| {
                text.printfn("Required {} pages", .{mem.len});
                text.logfn("Allocated at 0x{X}", .{image_base}, @src());

                break :blk mem;
            } else |err| {
                text.errorfn("{}", .{err});
                text.logfn("Trying allocate anywhere", .{}, @src());
                // Allocate somewhere
                break :blk try boot_services.allocatePages(.any, MemoryType.loader_data, page_count);
            }
        } else {
            break :blk try boot_services.allocatePages(.any, MemoryType.loader_data, page_count);
        }
    };
    text.logfn("Allocated {} pages", .{allocated_mem.len}, @src());
    const ker_image_base = @intFromPtr(allocated_mem.ptr);
    text.logfn("Address: @0x{X}", .{ker_image_base}, @src());

    // fill zeros
    @memset(@as([*]u8, @ptrFromInt(ker_image_base))[0..sizeof_image], 0);
    
    text.logfn("Copying bytes", .{}, @src());
    // Copy header & sections 
    const headersSize = nt_headers.OptionalHeader.size_of_headers;
    @memcpy(@as([*]u8, @ptrFromInt(ker_image_base))[0..headersSize], file_bytes[0..headersSize]);
    
    
    const raw_ptr = file_bytes[ntHeadersOffset + @sizeOf(ImageNtHeaders64)..].ptr;
    const sections_ptr: [*]align(1) const ImageSectionHeader = @ptrCast(raw_ptr);
    const sections = sections_ptr[0..nt_headers.FileHeader.number_of_sections];

    text.printfn("Module sections#: {}", .{sections.len});

    for (sections) |sec| {
        if (sec.sizeof_raw_data == 0) 
            continue;
        
        const dest = ker_image_base + sec.virtual_address;
        const src = file_bytes[sec.pointer_raw_data .. sec.pointer_raw_data + sec.sizeof_raw_data];
        @memcpy(@as([*]u8, @ptrFromInt(dest))[0 .. sec.sizeof_raw_data], src);
        text.logfn("{s} -> {d}K done", .{sec.name, sec.sizeof_raw_data / 1024}, @src());
    }
    // If image base differs -> resolve relocations again

    if (ker_image_base != image_base) {
        try efiResolveFixups(ker_image_base, nt_headers, sections, file_bytes, boot_services);
    }

    // Flush cache (optional)
    //bootServices.flushInstructionCache(imageHandle, kernelImageBase, sizeOfImage);
    const entry_point = ker_image_base + entry_rva;
    
    text.printfn("Loaded: {d}K ({d} bytes)", .{nt_headers.OptionalHeader.size_of_image / 1024, nt_headers.OptionalHeader.size_of_image});
    
    return .{
        .entry_point = entry_point,
        .start =  ker_image_base,
        .end = ker_image_base + nt_headers.OptionalHeader.size_of_image
    };
}