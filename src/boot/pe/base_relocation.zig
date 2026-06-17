pub const ImageBaseRelocation = extern struct {
    virtual_address: u32,
    sizeof_block: u32,
};

pub const RelocationType = enum(u16) {
    IMAGE_REL_BASED_ABSOLUTE = 0,
    IMAGE_REL_BASED_HIGH = 1,
    IMAGE_REL_BASED_LOW = 2,
    IMAGE_REL_BASED_HIGHLOW = 3,
    IMAGE_REL_BASED_HIGHADJ = 4,
    IMAGE_REL_BASED_DIR64 = 10,
};
