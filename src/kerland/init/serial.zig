//!
//! Minimal 8250/16550-compatible UART driver for the first legacy COM port
//! (0x3F8). This is the kernel's main debugging sink.
//!
const cpu = @import("cpu.zig");
const bufPrint = @import("std").fmt.bufPrint;
const COM1: u16 = 0x3F8;

/// Sends a single byte, waiting for the output buffer to drain first.
pub fn putChar(c: u8) void {
    while ((cpu.inb(COM1 + 5) & 0x20) == 0) {}
    cpu.outb(COM1, c);
}

/// Emits a whole string. `\n` is expanded to CRLF because a bare line feed
/// does not move the caret on a real terminal / serial monitor. Interrupts are
/// masked for the duration so an ISR cannot interleave its own bytes.
pub fn print(str: []const u8) void {
    const saved = cpu.flags();
    cpu.cli();
    defer if ((saved & cpu.INTERRUPT_FLAG) != 0) cpu.sti();
    for (str) |c| {
        if (c == '\n') putChar('\r');
        putChar(c);
    }
}

pub const SerialLogger = struct {
    fn emit(
        comptime tag: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        var buf: [0x400]u8 = undefined;
        const msg = bufPrint(&buf, fmt, args)
            catch |n| @errorName(n);
        print(tag);
        print(msg);
        print("\n");
    }
    pub fn infof(comptime fmt: []const u8, args: anytype) void {
        emit("[ INFO ] ", fmt, args);
    }

    pub fn okf(comptime fmt: []const u8, args: anytype) void {
        emit("[  OK  ] ", fmt, args);
    }

    pub fn failf(comptime fmt: []const u8, args: anytype) void {
        emit("[ FAIL ] ", fmt, args);
    }
    /// Bare println without a level tag.
    pub fn println(
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        var buf: [0x400]u8 = undefined;
        const msg = bufPrint(&buf, fmt, args)
            catch "print error";
        print(msg);
        print("\n");
    }
};
