//! This is a main shared library which contains all metadata about project
//! Represents Operating system name, version structure and other details 
//! which will be used at the runtime. 
//! 
pub fn main() void {}
/// Uses everywhere when 
const NAME: []const u8 = "Toska";
const MAJOR_VERSION = 0;
const MINOR_VERSION = 1;
const REVISION = 16;

pub const Version = packed struct {
    major: u32,
    minor: u32,
    revision: u32,
};

pub export fn os_string() callconv(.c) *const []const u8 {
    return &NAME;
}

pub export fn os_version() callconv(.c) *const Version {
    return &.{
        .major = MAJOR_VERSION,
        .minor = MINOR_VERSION,
        .revision = REVISION
    };
}

pub export fn sdk_version() callconv(.c) *const Version {
    return &.{
        .major = 0,
        .minor = 16,
        .revision = 0
    };
}