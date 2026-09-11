//!
//! Legacy 8259A Programmable Interrupt Controller remap. Moves the master/slave
//! IRQs off their 0x08/0x70 BIOS defaults up to 0x20/0x28 so they no longer
//! collide with CPU exceptions in the IDT.
//!
const cpu = @import("cpu.zig");

const PIC1_CMD = 0x20;
const PIC1_DATA = 0x21;
const PIC2_CMD = 0xA0;
const PIC2_DATA = 0xA1;

const ICW1_INIT = 0x10;
const ICW1_ICW4 = 0x01;
const ICW4_8086 = 0x01;

const PIC1_OFFSET = 0x20;
const PIC2_OFFSET = 0x28;

pub fn remap() void {
    cpu.outb(PIC1_CMD, ICW1_INIT | ICW1_ICW4);
    cpu.waitIO();
    cpu.outb(PIC2_CMD, ICW1_INIT | ICW1_ICW4);
    cpu.waitIO();

    cpu.outb(PIC1_DATA, PIC1_OFFSET);
    cpu.waitIO();
    cpu.outb(PIC2_DATA, PIC2_OFFSET);
    cpu.waitIO();

    cpu.outb(PIC1_DATA, 4);
    cpu.waitIO();
    cpu.outb(PIC2_DATA, 2);
    cpu.waitIO();

    cpu.outb(PIC1_DATA, ICW4_8086);
    cpu.waitIO();
    cpu.outb(PIC2_DATA, ICW4_8086);
    cpu.waitIO();

    cpu.outb(PIC1_DATA, 0xFF);  // mask all IRQs on master initially
    cpu.outb(PIC2_DATA, 0xFF);  // mask all IRQs on slave initially
}

pub fn disable() void {
    cpu.cli();
    cpu.outb(0x21, 0xFF);
    cpu.outb(0xA1, 0xFF);
    cpu.sti();
}

pub fn sendEoi(irq: u8) void {
    if (irq >= 8) {
        cpu.outb(PIC2_CMD, 0x20);
    }
    cpu.outb(PIC1_CMD, 0x20);
}

/// Unmask a specific IRQ line. Use after interrupts are enabled and
/// the corresponding handler is ready.
pub fn unmask(irq: u8) void {
    if (irq < 8) {
        const mask = cpu.inb(PIC1_DATA) & ~(@as(u8, 1) << @intCast(irq));
        cpu.outb(PIC1_DATA, mask);
    } else {
        const mask = cpu.inb(PIC2_DATA) & ~(@as(u8, 1) << @intCast(irq - 8));
        cpu.outb(PIC2_DATA, mask);
    }
}