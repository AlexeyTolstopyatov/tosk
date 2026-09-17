//!
//! Thin wrappers around a handful of x86-64 instructions and legacy PC I/O
//! that the kernel needs during bring-up (serial, PIT/PIC, interrupt gating).
//!

/// Bit in RFLAGS that gates maskable interrupts (IF).
pub const INTERRUPT_FLAG: u64 = 1 << 9;

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

/// Reads the RFLAGS register (saved/restored via the stack). Used to remember
/// whether interrupts were enabled so a critical section can restore the
/// previous state instead of blindly enabling them.
pub fn flags() u64 {
    return asm volatile(
        "pushfq; pop %[f]"
        : [f] "=r" (->u64),
    );
}

/// Restores RFLAGS from a value previously returned by `flags()`.
pub fn restoreFlags(f: u64) void {
    asm volatile(
        "push %[f]; popfq"
        :
        : [f] "r" (f),
    );
}

pub fn hlt() void {
    asm volatile("hlt");
}
