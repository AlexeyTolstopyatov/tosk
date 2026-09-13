//!
//! Legacy Programmable Interval Timer (8254 compatible). Runs at a fixed
//! frequency and produces IRQ0, which the PIC remap delivers as IDT vector 0x20.
//!
const std = @import("std");
const cpu = @import("cpu.zig");
const pic = @import("pic.zig");

const BASE_FREQUENCY = 1193180;
const COMMAND_PORT = 0x43;
const DATA_PORT_0 = 0x40;

var tick_count = std.atomic.Value(u64).init(0);
var freq: u32 = 0;

/// Reprograms the PIT to fire `freq` times per second.
pub fn init(f: u32) void {
    freq = f;
    const divisor = BASE_FREQUENCY / f;
    cpu.outb(COMMAND_PORT, 0x36);

    const l = @as(u8, @truncate(divisor));
    const h = @as(u8, @truncate(divisor >> 8));
    cpu.outb(DATA_PORT_0, l);
    cpu.outb(DATA_PORT_0, h);
}

/// Increments the software tick counter; called by the ISR and must be fast.
pub fn handleIrq() void {
    _ = tick_count.fetchAdd(1, .monotonic);
    pic.sendEoi(0);
}

/// Busy-waits for `ms` milliseconds based on the PIT tick counter.
pub fn sleep(ms: u64) void {
    const ticks = (ms * freq) / 1000;
    const start = tick_count.load(.monotonic);
    while (true) {
        const now = tick_count.load(.monotonic);
        if (now -% start >= ticks) {
            break;
        }
        asm volatile("hlt");
    }
}

pub fn getTicks() u64 {
    return tick_count.load(.monotonic);
}
