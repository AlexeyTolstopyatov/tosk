const std = @import("std");

pub fn kprintbf(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    // Now, we call a function from the standard library. It writes the string
    // resulting from the format string and the arguments into the buffer, but
    // also returns a slice pointing to everything useful.
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "0";
    kbochs(msg);
}
pub inline fn kbochs(msg: []const u8) void {
    for (msg) |c| {
        asm volatile (
            "outb %al, $0xE9"
            :
            : [val] "{al}" (c)
        );
    }
}