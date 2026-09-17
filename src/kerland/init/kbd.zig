//!
//! PS/2 keyboard driver (i8042 compatible) for scan-code set 1.
//!
//! Every key produces a scancode on I/O port 0x60, signalled by IRQ1 (remapped to IDT vector 0x21).
//! The IRQ handler drains the controller output buffer, translates make codes into
//! ASCII (<> Shift and Caps Lock) and pushes the bytes into a small ring
//! buffer.
//!
//! Extended (0xE0+) key sequences are scanned and ignored;
//! 
const cpu = @import("cpu.zig");
const pic = @import("pic.zig");

/// Status register
const SR = 0x64; // (bit 0 = output buffer full)
/// Data register
const DR = 0x60;

/// Capacity of the type-ahead ring buffer, in characters.
const BUFFER_SIZE = 256;

var buf: [BUFFER_SIZE]u8 = undefined;
var head: usize = 0; // next char to read
var tail: usize = 0; // next slot to fill

// Keyboard state.
var shift: bool = false; // Left/Right Shift currently held
var caps: bool = false;
var extended: bool = false; // saw the 0xE0 prefix, skip the next code

// mint fmt: off
/// Scan-code set 1 make codes -> ASCII (unshifted). 0 means "no character".
const normal: [128]u8 = blk: {
    @setEvalBranchQuota(2000);
    var t = [_]u8{0} ** 128;
    // Number row + symbols
    t[0x02] = '1'; t[0x03] = '2'; t[0x04] = '3'; t[0x05] = '4'; t[0x06] = '5';
    t[0x07] = '6'; t[0x08] = '7'; t[0x09] = '8'; t[0x0A] = '9'; t[0x0B] = '0';
    t[0x0C] = '-'; t[0x0D] = '='; t[0x1A] = '['; t[0x1B] = ']';
    t[0x27] = ';'; t[0x28] = '\''; t[0x2B] = '`'; t[0x29] = '\\';
    t[0x33] = ','; t[0x34] = '.'; t[0x35] = '/';
    // Top letter row
    t[0x10] = 'q'; t[0x11] = 'w'; t[0x12] = 'e'; t[0x13] = 'r'; t[0x14] = 't';
    t[0x15] = 'y'; t[0x16] = 'u'; t[0x17] = 'i'; t[0x18] = 'o'; t[0x19] = 'p';
    // Home row
    t[0x1E] = 'a'; t[0x1F] = 's'; t[0x20] = 'd'; t[0x21] = 'f'; t[0x22] = 'g';
    t[0x23] = 'h'; t[0x24] = 'j'; t[0x25] = 'k'; t[0x26] = 'l';
    // Bottom row
    t[0x2C] = 'z'; t[0x2D] = 'x'; t[0x2E] = 'c'; t[0x2F] = 'v'; t[0x30] = 'b';
    t[0x31] = 'n'; t[0x32] = 'm';
    // Space and control keys
    t[0x39] = ' ';
    t[0x1C] = '\n'; // Enter
    t[0x0E] = 0x08; // Backspace
    t[0x0F] = '\t'; // Tab
    break :blk t;
};

/// Scan-code set 1 make codes -> shifted ASCII.
const shifted: [128]u8 = blk: {
    @setEvalBranchQuota(2000);
    var t = [_]u8{0} ** 128;
    t[0x02] = '!'; t[0x03] = '@'; t[0x04] = '#'; t[0x05] = '$'; t[0x06] = '%';
    t[0x07] = '^'; t[0x08] = '&'; t[0x09] = '*'; t[0x0A] = '('; t[0x0B] = ')';
    t[0x0C] = '_'; t[0x0D] = '+'; t[0x1A] = '{'; t[0x1B] = '}';
    t[0x27] = ':'; t[0x28] = '"'; t[0x2B] = '~'; t[0x29] = '|';
    t[0x33] = '<'; t[0x34] = '>'; t[0x35] = '?';
    t[0x10] = 'Q'; t[0x11] = 'W'; t[0x12] = 'E'; t[0x13] = 'R'; t[0x14] = 'T';
    t[0x15] = 'Y'; t[0x16] = 'U'; t[0x17] = 'I'; t[0x18] = 'O'; t[0x19] = 'P';
    t[0x1E] = 'A'; t[0x1F] = 'S'; t[0x20] = 'D'; t[0x21] = 'F'; t[0x22] = 'G';
    t[0x23] = 'H'; t[0x24] = 'J'; t[0x25] = 'K'; t[0x26] = 'L';
    t[0x2C] = 'Z'; t[0x2D] = 'X'; t[0x2E] = 'C'; t[0x2F] = 'V'; t[0x30] = 'B';
    t[0x31] = 'N'; t[0x32] = 'M';
    break :blk t;
};
// mint fmt: on

/// Append a character to the ring buffer, dropping the oldest entry when full.
fn push(c: u8) void {
    buf[tail] = c;
    tail = (tail + 1) % BUFFER_SIZE;
    if (tail == head) {
        // Buffer overflow: oldest byte is overwritten.
        head = (head + 1) % BUFFER_SIZE;
    }
}

/// Translate one scancode into keyboard state or a buffered ASCII character.
fn translate(sc: u8) void {
    // ignore the byte following an 0xE0 extended-code prefix.
    if (extended) {
        extended = false;
        return;
    }
    if (sc == 0xE0) {
        extended = true;
        return;
    }

    // Modifier and lock keys.
    switch (sc) {
        0x2A, 0x36 => { // Left / Right Shift, make code
            shift = true;
            return;
        },
        0xAA, 0xB6 => { // shift, break code
            shift = false;
            return;
        },
        0x3A => { // Caps Lock (only on make code)
            caps = !caps;
            return;
        },
        else => {},
    }

    // Everything with bit 7 set is a break (release) code -> drop it.
    if ((sc & 0x80) != 0) return;

    var c = if (shift) shifted[sc] else normal[sc];
    if (c == 0) return;

    if (c >= 'a' and c <= 'z' and caps) c -= 'a' - 'A';
    if (c >= 'A' and c <= 'Z' and caps) c += 'a' - 'A';

    push(c);
}

/// Interrupts dispatcher from IDT vector 0x21 (remapped IRQ1).
/// Must stay short and non-blocking.
pub inline fn handleIrq() void {
    // Drain every pending scancode; the controller may have queued several.
    while ((cpu.inb(SR) & 0x01) != 0) {
        const sc = cpu.inb(DR);
        translate(sc);
    }
    pic.sendEoi(1);
}

/// Non-blocking: returns the next buffered character or `null` when empty.
pub fn poll() ?u8 {
    if (head == tail) return null;
    const c = buf[head];
    head = (head + 1) % BUFFER_SIZE;
    return c;
}
