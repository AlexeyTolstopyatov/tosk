//!
//! Boot interface shared between the UEFI bootloader and the loaded `init`
//! image. The bootloader materialises one of these structs after it has torn
//! down the UEFI boot services and passes a pointer to it as the single
//! argument of the kernel entry point.
//!
const uefi = @import("std").os.uefi;

pub const BootInfo = struct {
    /// Physical memory map in the form of `UEFI` `MemoryDescriptor`s. The map
    /// is intentionally passed in its native UEFI encoding so that the kernel
    /// does not choke on firmware layouts it has never seen before.
    map: [*]uefi.tables.MemoryDescriptor,

    /// Total size, in bytes, of the memory map pointed to by `map`.
    map_size: usize,

    /// Size, in bytes, of a single `MemoryDescriptor` entry. Descriptors may
    /// be larger than the canonical `@sizeOf(MemoryDescriptor)` on newer
    /// firmware, hence the stride must be honoured by the kernel.
    desc_size: usize,

    /// Physical address of the ACPI 2.0 RSDP table, or `0` when absent.
    rsdp_addr: usize,
};
