//!
//! Minimal ELF-64 parser tailored to loading a freestanding x86-64 `init`
//! image. It only concerns itself with the file header and the `PT_LOAD`
//! program headers; everything else (`PT_NOTE`, section headers, symbol
//! tables, debug sections) is deliberately ignored.
//!
//! All multi-byte fields are decoded little-endian through explicit byte
//! offsets so the parser is immune to the alignment of the backing buffer
//! (e.g. an `align(8)` pool allocation).
//!
const std = @import("std");

/// ELF magic number: `0x7F 'E' 'L' 'F'`.
pub const magic = [_]u8{ 0x7F, 'E', 'L', 'F' };

/// `EI_CLASS` value for ELF64.
pub const class_64: u8 = 2;

/// `EI_DATA` value for little-endian data encoding.
pub const data_little_endian: u8 = 1;

/// `EI_CLASS` / `EI_DATA` offsets within `e_ident`.
const ident_class: usize = 4;
const ident_data: usize = 5;

/// `ET_EXEC` (position dependent) executable.
pub const type_exec: u16 = 2;

/// `EM_X86_64` machine type.
pub const machine_x86_64: u16 = 62;

/// `PT_LOAD` program header type.
pub const program_load: u32 = 1;

/// ELF64 file header (`Elf64_Ehdr`). `e_ident` is validated by `parseHeader`
/// and intentionally omitted from the struct.
pub const Header = extern struct {
    /// `e_type`
    ptype: u16,
    /// `e_machine`
    machine: u16,
    /// `e_version`
    version: u32,
    /// `e_entry` -- virtual address to transfer control to.
    entry: u64,
    /// `e_phoff` -- file offset of the program header table.
    phoff: u64,
    /// `e_shoff` -- file offset of the section header table.
    shoff: u64,
    /// `e_flags`
    flags: u32,
    /// `e_ehsize`
    ehsize: u16,
    /// `e_phentsize` -- size of a single program header entry.
    phentsize: u16,
    /// `e_phnum` -- number of program header entries.
    phnum: u16,
    /// `e_shentsize`
    shentsize: u16,
    /// `e_shnum`
    shnum: u16,
    /// `e_shstrndx`
    shstrndx: u16,
};

/// ELF64 program header (`Elf64_Phdr`).
pub const Segment = extern struct {
    /// `p_type`
    ptype: u32,
    /// `p_flags`
    pflags: u32,
    /// `p_offset` -- file offset of the segment payload.
    offset: u64,
    /// `p_vaddr` -- virtual address to load the segment at.
    virtual: u64,
    /// `p_paddr` -- physical address (usually ignored for images).
    paddr: u64,
    /// `p_filesz` -- size of the segment within the file.
    filesz: u64,
    /// `p_memsz` -- size the segment occupies in memory.
    mem_size: u64,
    /// `p_align`
    palign: u64,
};

fn u16le(bytes: []const u8, off: usize) u16 {
    return @as(u16, bytes[off])
        | (@as(u16, bytes[off + 1]) << 8);
}

fn u32le(bytes: []const u8, off: usize) u32 {
    return @as(u32, bytes[off])
        | (@as(u32, bytes[off + 1]) << 8)
        | (@as(u32, bytes[off + 2]) << 16)
        | (@as(u32, bytes[off + 3]) << 24);
}

fn u64le(bytes: []const u8, off: usize) u64 {
    return @as(u64, bytes[off])
        | (@as(u64, bytes[off + 1]) << 8)
        | (@as(u64, bytes[off + 2]) << 16)
        | (@as(u64, bytes[off + 3]) << 24)
        | (@as(u64, bytes[off + 4]) << 32)
        | (@as(u64, bytes[off + 5]) << 40)
        | (@as(u64, bytes[off + 6]) << 48)
        | (@as(u64, bytes[off + 7]) << 56);
}

/// Validates that `image` is a little-endian ELF64 x86-64 executable and
/// returns its header. Returns `null` on any mismatch.
pub fn parseHeader(image: []const u8) ?Header {
    if (image.len < @sizeOf(Header)) return null;
    if (!std.mem.eql(u8, image[0..4], &magic)) return null;
    if (image[ident_class] != class_64) return null;
    if (image[ident_data] != data_little_endian) return null;

    const hdr = Header{
        .ptype = u16le(image, 16),
        .machine = u16le(image, 18),
        .version = u32le(image, 20),
        .entry = u64le(image, 24),
        .phoff = u64le(image, 32),
        .shoff = u64le(image, 40),
        .flags = u32le(image, 48),
        .ehsize = u16le(image, 52),
        .phentsize = u16le(image, 54),
        .phnum = u16le(image, 56),
        .shentsize = u16le(image, 58),
        .shnum = u16le(image, 60),
        .shstrndx = u16le(image, 62),
    };

    if (hdr.ptype != type_exec) return null;
    if (hdr.machine != machine_x86_64) return null;
    return hdr;
}

/// Returns the `index`-th program header of the image, or `null` when the
/// table is malformed (too small entries or out-of-bounds offsets).
pub fn segmentAt(
    image: []const u8,
    hdr: *const Header,
    index: usize,
) ?Segment {
    if (hdr.phentsize < @sizeOf(Segment)) return null;
    const offset = hdr.phoff
        + @as(u64, @intCast(index * @as(usize, hdr.phentsize)));
    if (offset + @sizeOf(Segment) > image.len) return null;

    const off: usize = @intCast(offset);
    return Segment{
        .ptype = u32le(image, off),
        .pflags = u32le(image, off + 4),
        .offset = u64le(image, off + 8),
        .virtual = u64le(image, off + 16),
        .paddr = u64le(image, off + 24),
        .filesz = u64le(image, off + 32),
        .mem_size = u64le(image, off + 40),
        .palign = u64le(image, off + 48),
    };
}
