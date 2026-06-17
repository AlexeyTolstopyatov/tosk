const PhysicalAddress = @import("mem/pmm.zig").PhysicalAddress;
const std = @import("std");

const text = @import("text/debug.zig");
const console = &@import("text/console.zig").console;
pub const GlobalDescriptor = packed struct {
    limit_low: u16,
    base_low: u24,
    access: u8,
    limit_high: u4,
    flags: u4,
    base_high: u8,

    pub fn init(base: u64, limit: u20, access: u8, flags: u4) u64 {
        return (@as(u64, base & 0xFFFFFF) << 16) |
               (@as(u64, limit & 0xFFFF)) |
               (@as(u64, (limit >> 16) & 0xF) << 48) |
               (@as(u64, access) << 40) |
               (@as(u64, flags) << 52) |
               (@as(u64, (base >> 24) & 0xFF) << 56);
    }
};
const InterruptDescriptor = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u3,
    zero: u5,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,

    pub fn init(offset: u64, selector: u16, ist: u3, type_attr: u8) InterruptDescriptor {
        return .{
            .offset_low = @truncate(offset & 0xFFFF),
            .selector = selector,
            .ist = ist,
            .zero = 0,
            .type_attr = type_attr,
            .offset_mid = @truncate((offset >> 16) & 0xFFFF),
            .offset_high = @truncate((offset >> 32) & 0xFFFFFFFF),
            .reserved = 0,
        };
    }
};

const Descriptor = packed struct {
    limit: u16,
    base: u64,
};
/// Call from the "loader.asm" file. No Clobbers and Zig inline assembler.
/// File with given function changes registers state already and Zig can't restore
/// them at all.
/// 
/// Before linkage, file "loader.asm" will be rewritten into COFF object "loader.o"
/// and exactly "loader.o" will be linked with other TOSKNL objects. (see build::buildKer@120)
extern fn load_gdt(gdtr_ptr: *const Descriptor) void;
/// Same with the [load_gdt]:
/// It will be a call from the "loader.asm" file.
/// File with given function changes registers state already and Zig can't restore
/// them at all.
/// 
/// Before linkage, file "loader.asm" will be rewritten into COFF object "loader.o"
/// and exactly "loader.o" will be linked with other TOSKNL objects. (see build::buildKer@120)
extern fn load_idt(idtr_ptr: *const Descriptor) void;

var idt: [256]InterruptDescriptor align(16) = .{ InterruptDescriptor.init(0, 0, 0, 0) } ** 256;
var gdt: [8]GlobalDescriptor = .{ @as(GlobalDescriptor, @bitCast(@as(u64, 0))) } ** 8;

const Tss = extern struct {
    reserved1: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved2: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved3: u64 = 0,
    iomap_base: u16 = 0,

    pub fn init(tss_addr: u64, limit: u16) [2]u64 {
        const limit64 = @as(u64, limit);
        const low = (limit64 & 0xFFFF) |
                    ((tss_addr & 0xFFFFFF) << 16) |
                    (0x89 << 40) |
                    (((limit64 >> 16) & 0xF) << 48);
        const high = (tss_addr >> 32) & 0xFFFFFFFF;
        return [2]u64{ low, high };
    }
};
/// Initializes General Descriptor Table if procedure executes correct.
/// For else possible effect is a `#GP` and triple fault.
pub fn gdtInit(page: PhysicalAddress) void {
    gdt[0] = @bitCast(@as(u64, 0)); // NULL
    // kernel program text: base=0, limit=0, access=0x9A, flags=0xA
    gdt[1] = @bitCast(GlobalDescriptor.init(0, 0, 0x9A, 0xA));
    // kernel data: access=0x92, flags=0xC
    gdt[2] = @bitCast(GlobalDescriptor.init(0, 0, 0x92, 0xC));
    // userland:    access=0xFA, flags=0xA
    gdt[3] = @bitCast(GlobalDescriptor.init(0, 0, 0xFA, 0xA));
    // user data:   access=0xF2, flags=0xC
    gdt[4] = @bitCast(GlobalDescriptor.init(0, 0, 0xF2, 0xC));

    // TSS (long mode, access 0x89)
    const tss_addr = page + 0x200;
    const tss_limit = @sizeOf(Tss) - 1;
    
    const tss_low = GlobalDescriptor.init(tss_addr, tss_limit, 0x89, 0);
    const tss_high = (tss_addr >> 32) & 0xFFFFFFFF;
    gdt[5] = @bitCast(tss_low);
    gdt[6] = @bitCast(tss_high);
    const gdtr = Descriptor {
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base = @intFromPtr(&gdt[0]),
    };
    // Debug print all global desctiptors. We need to see how the init procedure
    // initializes them and will we caught the #GP or not?
    text.kprintbf("GDTR: limit={}, base=0x{x}\n", .{gdtr.limit, gdtr.base});
    // UNSAFETY: If something went wrong: function breaks down the stack
    // and kernel will be stopped. 
    // That's why the [lgdt] procedure drop execution with General Protection fault.
    // 
    // If gdt will be loaded successfully -> stack frame not breaks
    // and load_gdt returns correct into gdtInit (into Zig).
    load_gdt(&gdtr);
}
/// Compares vector# and returns official mnemonic ASCII string
inline fn idtMnemonic(gate: u64) []const u8 {
    return switch (gate) {
        0x00 => "#DE",
        0x01 => "#DB",
        0x02 => "NMI",
        0x03 => "#BP",
        0x04 => "#OF",
        0x05 => "#BR",
        0x06 => "#UD", 
        0x07 => "#NM",
        0x08 => "#DF",
        0x09 => "#MP",
        0x0A => "#TS",
        0x0B => "#NP",
        0x0C => "#SS",
        0x0D => "#GP",
        0x0E => "#PF",
        0x0F => "?",
        0x10 => "#MF",
        0x11 => "#AC",
        0x12 => "#MC",
        0x13 => "#XM",
        0x14 => "#VE",
        0x15 => "#CP",
        else => "?"
    };
}
// Exporting functions must be named snake_case or C-like.
/// Handles interrupt: stops kernel execution. Set system in halt state 
export fn kcheck(vector: u64) callconv(.c) noreturn {
    console.printf("\n** STOP **\n", .{});
    console.printf(
        \\This is a common interrupt handler message. 
        \\Something happened and system has been stopped. Not all interrupt requests are means system fault
        \\
        \\Coffeelake, make it smarter!
        \\
    , .{});
    console.printf("Code: 0x{X}", .{vector});
    
    if (vector < 0x20) {
        // It works but prints zeroes...
        console.printf("{s}\n", .{idtMnemonic(vector)});
    }
    
    console.printf("System halted\n", .{});
    while (true) {
        asm volatile ("hlt");
    }
}
extern const isr_stub_table: [256 * 16]u8;
/// Initializes an interrupt descriptor table by given physical address
/// If something went wrong - stack breaks and function has a [noreturn] type.
/// See `loader::load_idt` or `load_idt` in this module
pub fn idtInit() void {
    const kernel_cs = 0x08;
    const type_intgate = 0x8E; // Present, 64‑bit interrupt gate, DPL=0

    for (0..256) |i| {
        const stub_offset = i * 16; // each stub = 16 bytes
        const stub_addr = @intFromPtr(&isr_stub_table) + stub_offset;
        idt[i] = InterruptDescriptor.init(stub_addr, kernel_cs, 0, type_intgate);
    }

    const idtr = Descriptor{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };

    text.kprintbf("IDTR: limit={}, base=0x{x}\n", .{ idtr.limit, idtr.base });
    load_idt(&idtr);
}
