//!
//! Minimal 8250/16550-compatible UART driver for the first legacy COM port
//! (0x3F8). This is the kernel's main debugging sink.
//!
const cpu = @import("cpu.zig");

const COM1: u16 = 0x3F8;

/// Sends a single byte, waiting for the output buffer to drain first.
pub fn putChar(c: u8) void {
    while ((cpu.inb(COM1 + 5) & 0x20) == 0) {}
    cpu.outb(COM1, c);
}

/// Emits a whole string. `\n` is expanded to CRLF because a bare line feed
/// does not move the caret on a real terminal / serial monitor.
pub fn print(str: []const u8) void {
    for (str) |c| {
        if (c == '\n') putChar('\r');
        putChar(c);
    }
}
