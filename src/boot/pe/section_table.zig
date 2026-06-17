/// Record template for Section table. 
/// Section table embeds into Portable Executable file firstly
pub const ImageSectionHeader = extern struct {
    name: [8]u8,
    virtual_size: u32,
    virtual_address: u32,
    sizeof_raw_data: u32,
    pointer_raw_data: u32,
    pointer_relocations: u32,
    pointer_linenumbers: u32,
    number_of_relocations: u16,
    number_of_linenumbers: u16,
    characteristics: u32,
};
