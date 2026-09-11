//!
//! x86-64 Interrupt Descriptor Table. 
//!
const log = @import("log.zig");
const cpu = @import("cpu.zig");

const isr_table = @import("isr_stub_table.zig");
const pit = @import("pit.zig");

const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,

    pub fn set(self: *IdtEntry, handler: anytype) void {
        const addr = @intFromPtr(handler);
        self.offset_low = @as(u16, @truncate(addr));
        self.selector = currentCS(); //0x08; General protection fault
        self.ist = 0;
        self.type_attr = 0x8e;
        self.offset_mid = @as(u16, @truncate(addr >> 16));
        self.offset_high = @as(u32, @truncate(addr >> 32));
        self.reserved = 0;
    }

    pub fn currentCS() u16 {
        // TODO: setup own GDT -> move init into 8 code segment
        return asm ("mov %%cs, %[ret]" : [ret] "=r" (-> u16));
    }
};

const IdtPtr = packed struct {
    limit: u16,
    base: u64,
};

var idt: [256]IdtEntry align(16) = undefined;

pub fn init() void {
    for (0..256) |i| {
        idt[i].set(isr_table.isr_stub_table[i]);
    }
    const idt_ptr = IdtPtr{
        .limit = @as(u16, @sizeOf(@TypeOf(idt)) - 1),
        .base = @intFromPtr(&idt),
    };

    asm volatile ("lidt (%[ptr])"
        :
        : [ptr] "r" (&idt_ptr),
    );
}

/// Dispatcher reached from every ISR stub. Routes to the relevant hardware
/// handler; anything unknown is fatal.
export fn isr_handler_zig(ctx: *isr_table.TrapFrame) callconv(.{ .x86_64_sysv = .{} }) u64 {
    const vector = @as(u8, @truncate(ctx.int_num));
    switch (vector) {
        14 => {
            pageFaultHandler(ctx);
        },
        32 => {
            pit.handleIrq();
        },
        else => {
            log.fail("Unhandled interrupt: {}", .{ctx.int_num});
            cpu.cli();
            while (true) cpu.hlt();
        },
    }
    return 0;
}

fn pageFaultHandler(ctx: *isr_table.TrapFrame) void {
    const cr2 = asm volatile ("mov %%cr2, %[ret]"
        : [ret] "=r" (-> u64),
    );
    _ = cr2;
    _ = ctx;
    @panic("PAGE FAULT");
    // log.fail("[PAGE FAULT] Failed to access memory at: 0x{x}\n", .{cr2});
    // log.fail("-> [RIP]: 0x{x}, [ERROR_CODE] {d}\n", .{ ctx.rip, ctx.error_code });
    
}
