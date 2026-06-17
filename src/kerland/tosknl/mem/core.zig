//! Kernel embedded memory functions
//! Since zig 0.11 was released, we've lost the (un)comfortable C-like procedures
//! but in the osdev we extremely need it.
const std = @import("std");

/// Zig embedded @memset analog for unlimited slices 
pub fn set(comptime T: type, ptr: [*]T, len: usize, value: T) void {
    for (0..len) |i| {
        ptr[i] = value;
    }
}
/// Zig embedded @memcpy analog for unlimited slices
pub fn copy(comptime T: type, source: [*]T, dest: [*]T, size: usize) void {
    for (0..size) |i| {
        dest.*[i] = source[i];
    }
}