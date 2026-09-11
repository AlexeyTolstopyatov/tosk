//!
//! Thin wrappers around a handful of x86-64 instructions and legacy PC I/O
//! that the kernel needs during bring-up (serial, PIT/PIC, interrupt gating).
//!

pub fn outb(port: u16, value: u8) void {
    asm volatile(
        "outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile(
        "inb %[port], %[ret]"
        : [ret] "={al}" (->u8),
        : [port] "{dx}" (port)
    );
}

/// Small port I/O pause so a slow legacy device can catch up.
pub fn waitIO() void {
    outb(0x80, 0);
}

pub fn sti() void {
    asm volatile("sti");
}

pub fn cli() void {
    asm volatile("cli");
}

pub fn hlt() void {
    asm volatile("hlt");
}
