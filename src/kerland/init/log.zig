//!
//! Logger module. Implements message bus using COM1
//!
const serial = @import("serial.zig");
const bufPrint = @import("std").fmt.bufPrint;

const BUF_SIZE: usize = 512;

fn emit(
    comptime tag: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var buf: [BUF_SIZE]u8 = undefined;
    const msg = bufPrint(&buf, fmt, args) catch "print error";
    serial.print(tag);
    serial.print(msg);
    serial.print("\n");
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    emit("[ INFO ] ", fmt, args);
}

pub fn ok(comptime fmt: []const u8, args: anytype) void {
    emit("[  OK  ] ", fmt, args);
}

pub fn fail(comptime fmt: []const u8, args: anytype) void {
    emit("[ FAIL ] ", fmt, args);
}

pub fn trace(comptime fmt: []const u8, args: anytype) void {
    emit("[ TRCE ] ", fmt, args);
}

/// Bare println without a level tag.
pub fn println(comptime fmt: []const u8, args: anytype) void {
    var buf: [BUF_SIZE]u8 = undefined;
    const msg = bufPrint(&buf, fmt, args) catch "print error";
    serial.print(msg);
    serial.print("\n");
}
