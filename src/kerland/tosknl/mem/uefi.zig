pub const EfiAllocType = enum(u32) {
    /// Allocate any available range of pages that satisfies the request.
    alloc_any_pages,
    /// Allocate any available range of pages whose uppermost address is less than
    /// or equal to a specified maximum address.
    alloc_max_addresses,
    /// Allocate pages at a specified address.
    alloc_addresses,
    /// Maximum enumeration value that may be used for bounds checking.
    max_alloc
};
/// Enumeration of memory types introduced in UEFI.
/// ```text
/// 0..(EfiMaxMemoryType - 1)    - Normal memory type
/// EfiMaxMemoryType..0x6FFFFFFF - Invalid
/// 0x70000000..0x7FFFFFFF       - OEM reserved
/// 0x80000000..0xFFFFFFFF       - OS reserved
/// ```
pub const EfiMemoryType = enum(u32) {
    /// Not used.
    reserved,
    /// The code portions of a loaded application.
    /// (Note that UEFI OS loaders are UEFI applications.)
    loader_code,
    /// The data portions of a loaded application and the default data allocation
    /// type used by an application to allocate pool memory.
    loader_data,
    /// The code portions of a loaded Boot Services Driver.
    boot_code,
    /// The data portions of a loaded Boot Serves Driver, and the default data
    /// allocation type used by a Boot Services Driver to allocate pool memory.
    boot_data,
    /// The code portions of a loaded Runtime Services Driver.
    runtime_code,
    /// The data portions of a loaded Runtime Services Driver and the default
    /// data allocation type used by a Runtime Services Driver to allocate pool memory.
    runtime_data,
    /// Free (unallocated) memory.
    conventional,
    /// Memory in which errors have been detected.
    unusable,
    /// Memory that holds the ACPI tables.
    acpi_reclaim,
    /// Address space reserved for use by the firmware.
    acpi_nvs,
    /// Used by system firmware to request that a memory-mapped IO region
    /// be mapped by the OS to a virtual address so it can be accessed by EFI runtime services.
    mapped_io,
    /// System memory-mapped IO region that is used to translate memory
    /// cycles to IO cycles by the processor.
    mapped_io_port_space,
    /// Address space reserved by the firmware for code that is part of the processor.
    pal_code,
    /// A memory region that operates as EfiConventionalMemory,
    /// however it happens to also support byte-addressable non-volatility.
    persistent,
    /// A memory region that describes system memory that has not been accepted
    /// by a corresponding call to the underlying isolation architecture.
    unaccepted,
    max,
    
    /// Returns true if memory is in bounds of OEM reserved space
    pub fn isOem(v: u32) bool {
        return (v > 0x70000000 and v <= 0x7FFFFFFF);
    }
    /// Returns true if memory is in normal segment
    /// Is it normal or I miss something???
    pub fn isOk(v: u32) bool {
        return (v > 0 and v < EfiMemoryType.max);
    }
    /// Returns if addres in Operating System reserved memory
    pub fn isOS(v: u32) bool {
        return (v > 0x80000000 and v <= 0xFFFFFFFF);
    }
};
/// Definition of an EFI memory descriptor.
pub const EfiDescriptor = extern struct {
    /// Type of the memory region.
    /// Type EFI_MEMORY_TYPE is defined in the
    /// AllocatePages() function description.
    memory_type: EfiMemoryType,
    padding: u32 = 0,
    /// Physical address of the first byte in the memory region. PhysicalStart must be
    /// aligned on a `4K` boundary, and must not be above `0xfffffffffffff000`. Type
    /// EFI_PHYSICAL_ADDRESS is defined in the AllocatePages() function description
    physical_address: u64,
    /// Virtual address of the first byte in the memory region.
    /// VirtualStart must be aligned on a `4K` boundary,
    /// and must not be above `0xfffffffffffff000`.
    virtual_address: u64,
    /// NumberOfPagesNumber of `4K` pages in the memory region.
    /// NumberOfPages must not be 0, and must not be any value
    /// that would represent a memory page with a start address,
    /// either physical or virtual, above 0xfffffffffffff000.
    number_of_pages: u64,
    /// Attributes of the memory region that describe the bit mask of capabilities
    /// for that memory region, and not necessarily the current settings for that
    /// memory region.
    attribute: u64
};