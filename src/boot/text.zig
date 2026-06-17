//! Bootloader I/O submodule
//! 

const uefi = @import("std").os.uefi;
const std = @import("std");

/// Bad idea. Use interfaces instead of global instance
pub var stdout: *uefi.protocol.SimpleTextOutput = undefined;

pub fn efiInitConsoleOutput () void {
    // Use an initialized console output stream by pointer
    stdout = uefi.system_table.con_out.?;
}

pub fn efiPrintn(msg: []const u8) void {
    efiPrint(msg);
    efiPrint("\r\n");
}
pub inline fn efiPrint(msg: []const u8) void {
    //iterate over the message we want to print out.
    for (msg) |c| {
        const c_ = [1:0]u16{c};
        _ = stdout.outputString(@as(*const [1:0]u16, &c_)) catch {};
    }
}
pub fn logfn(
    comptime fmt: []const u8, 
    args: anytype, 
    comptime src: std.builtin.SourceLocation,
    ) void {
    stdout.setAttribute(.{ .foreground = .darkgray }) catch unreachable;
    efiPrintf("{s}::{s}@{d} -> ", .{src.module, src.fn_name, src.line});
    // Write an error message with white. Arguments which got as a params
    // will be red highlighted
    printfn(fmt, args);
    stdout.setAttribute(.{ .foreground = .white }) catch unreachable;
}

pub fn errorfn(comptime fmt: []const u8, args: anytype) void {
    stdout.setAttribute(.{ .foreground = .lightred }) catch unreachable;
    efiPrint("Error\t");
    // Write an error message with white. Arguments which got as a params
    // will be red highlighted
    stdout.setAttribute(.{ .foreground = .white }) catch unreachable;
    printfn(fmt, args);
}

pub fn efiPrintf(comptime fmt: []const u8, args: anytype) void {
    // Because I don't want to allocate, I just have this buffer as a "limit".
    var buf: [1024]u8 = undefined;
    // Now, we call a function from the standard library. It writes the string
    // resulting from the format string and the arguments into the buffer, but
    // also returns a slice pointing to everything useful.
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    // And now, we just call our normal string output function.
    efiPrint(msg);
}
pub fn printfn(comptime fmt: []const u8, args: anytype) void {
    efiPrintf(fmt, args);
    efiPrint("\r\n");
}
