//!
//! Brings the interrupt subsystem online: remaps the PIC so hardware IRQs land
//! on their remapped IDT vectors, then enables the CPU interrupt flag.
//!
const pic = @import("pic.zig");
const cpu = @import("cpu.zig");

pub fn init() void {
    pic.remap();
    cpu.sti();
    // Unmask IRQ0 (timer) and IRQ1 (keyboard) after interrupts are enabled.
    pic.unmask(0);
    pic.unmask(1);
}
