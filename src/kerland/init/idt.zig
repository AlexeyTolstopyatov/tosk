//!
//! x86-64 Interrupt Descriptor Table.
//!
const cpu = @import("cpu.zig");
const serial = @import("serial.zig").SerialLogger;
const video = @import("video.zig").VideoLogger;

const isrt = @import("isrt.zig");
const pit = @import("pit.zig");

const IdtEntry = packed struct {
    loffset: u16,
    selector: u16,
    ist: u8,
    @"type": u8,
    midoffset: u16,
    hioffset: u32,
    res: u32,

    pub fn set(self: *IdtEntry, handler: anytype) void {
        const addr = @intFromPtr(handler);
        self.loffset = @as(u16, @truncate(addr));
        self.selector = currentCS();
        self.ist = 0;
        self.@"type" = 0x8e;
        self.midoffset = @as(u16, @truncate(addr >> 16));
        self.hioffset = @as(u32, @truncate(addr >> 32));
        self.res = 0;
    }

    pub fn currentCS() u16 {
        return asm("mov %%cs, %[ret]" : [ret] "=r" (->u16));
    }
};

const IdtPtr = packed struct { limit: u16, base: u64 };

var idt: [256]IdtEntry align(16) = undefined;

pub fn init() void {
    for (0..256) |i| {
        idt[i].set(isrt.isr_stub_table[i]);
    }
    // Double fault (#8) runs on a dedicated stack via TSS.IST1.
    idt[8].ist = 1;
    const idt_ptr = IdtPtr{
        .limit = @as(u16, @sizeOf(@TypeOf(idt)) - 1),
        .base = @intFromPtr(&idt),
    };

    asm volatile(
        "lidt (%[ptr])"
        :
        : [ptr] "r" (&idt_ptr),
    );
}

///
/// Dispatcher reached from every ISR stub. Routes to the relevant hardware
/// handler; anything unknown is fatal.
///
export fn initCheckTrapContext(
    ctx: *isrt.TrapFrame,
) callconv(.{ .x86_64_sysv = .{} }) u64 {
    const vector = @as(u8, @truncate(ctx.int_num));
    switch (vector) {
        8 => {
            serial.println("#DF", .{});
            handleDoubleFault(ctx);
        },
        14 => {
            serial.println("#PF", .{});
            serial.println("truncated vec# {}", .{vector});

            handlePageFault(ctx);
        },
        32 => {
            pit.handleIrq();
        },
        else => {
            serial.failf(
                "Default callback for unknown context {}",
                .{vector},
            );
            cpu.cli();
            while (true) cpu.hlt();
        },
    }
    return 0;
}

fn handlePageFault(ctx: *isrt.TrapFrame) void {
    const cr2 = asm volatile(
        "mov %%cr2, %[ret]"
        : [ret] "=r" (->u64)
    );
    video.failf("Failed to access memory at: 0x{x}\n", .{cr2});
    ctx.print();

    cpu.cli();
    while (true) {
        cpu.hlt();
    }
}

fn handleDoubleFault(ctx: *isrt.TrapFrame) void {
    video.failf(
        "DOUBLE FAULT: cs=0x{X} rip=0x{X} err=0x{X}\n",
        .{ ctx.cs, ctx.rip, ctx.error_code },
    );
    serial.failf(
        "DOUBLE FAULT: cs=0x{X} rip=0x{X} err=0x{X}",
        .{ ctx.cs, ctx.rip, ctx.error_code },
    );
    video.tracef("{any}\n", .{ctx.*});

    cpu.cli();
    while (true) {
        cpu.hlt();
    }
}
