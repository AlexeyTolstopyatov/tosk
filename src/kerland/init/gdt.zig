//!
//! 64-bit GDT/TSS.
//!
//! UEFI configures "unique" global descriptor table for to init the following
//! boot/runtime services. The layout of UEFI isn't necessary, so against it
//! 64-bit operating systems can have GDT too to cover incompatibility problems of firmware.
//!
//! Starting from this the processes architecture will set.
//!
pub const Selector = struct {
    pub const KCODE: u16 = 0x08; // index 1
    pub const KDATA: u16 = 0x10; // index 2
    pub const UCODE: u16 = 0x18; // index 3
    pub const UDATA: u16 = 0x20; // index 4
    pub const TSS: u16 = 0x28; // index 5 (16-byte descriptor at slots 5..6)
};

/// code/data descriptor used for the flat supervisor/user segments.
const SegmentDescriptor = packed struct(u64) {
    lolimit: u16 = 0,
    lobase: u16 = 0,
    midbase: u8 = 0,
    access: u8 = 0,
    flags: u8 = 0, // G/D/B/L/AVL + limit_high
    hibase: u8 = 0,
};

///
/// 64-bit Task State Segment: IST1 is used by the #df handler
/// Layout follows Intel Vol.3A, section 8.7.
///
const Tss = packed struct {
    _res0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    _res1: u32 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    _res2: u64 = 0,
    _res3: u32 = 0,
    iomap_base: u16 = 0xFFFF, // "no I/O permission bitmap"
};

const Gdt = struct {
    descriptors: [5]u64 = [_]u64{0} ** 5,
    tss_desc: [2]u64 = [_]u64{0} ** 2,
};

const GdtRegister = packed struct { limit: u16, base: u64 };

// 16 KiB dedicated stack for the #df handler via ist1.
const double_fault_stack_size = 16384;
var double_fault_stack: [double_fault_stack_size]u8
    align(16) = undefined;

var gdt: Gdt align(16) = .{};
var task_state: Tss align(16) = .{};
var gdtr: GdtRegister = undefined;

fn getCodeDescriptor(access: u8) u64 {
    return @bitCast(
        SegmentDescriptor{
            .access = access,
            .flags = 0xAF, // G=1, L=1, AVL=0, limit_hi=0xF
        },
    );
}

fn getDataDescriptor(access: u8) u64 {
    return @bitCast(
        SegmentDescriptor{
            .access = access,
            .flags = 0xCF, // G=1, D=1, AVL=0, limit_hi=0xF
        },
    );
}

fn getTSSDescriptor(base: u64, size: usize) u128 {
    const limit = size - 1;
    return (@as(u128, limit & 0xFFFF))
        | (@as(u128, base & 0xFFFF) << 16)
        | (@as(u128, (base >> 16) & 0xFF) << 32)
        | (@as(u128, 0x89) << 40)
        | // expecting P=1, DPL=0, type=available 64-bit TSS
        (@as(u128, (limit >> 16) & 0x0F) << 48)
        | (@as(u128, (base >> 24) & 0xFF) << 56)
        | (@as(u128, (base >> 32) & 0xFFFFFFFF) << 64)
        | (@as(u128, 0) << 96);
}

fn loadGdtr() void {
    asm volatile(
        "lgdt (%[gdtr])"
        :
        : [gdtr] "r" (&gdtr),
        : .{ .memory = true }
    );
}

///
/// Point the data/stack segment registers at our flat kernel data selector.
///
fn reloadSegments() void {
    asm volatile(
        \\mov %[sel], %%ds
        \\mov %[sel], %%es
        \\mov %[sel], %%fs
        \\mov %[sel], %%gs
        \\mov %[sel], %%ss
        :
        : [sel] "r" (Selector.KDATA),
        : .{ .memory = true }
    );
}

///
/// Far-return onto init code selector (CS == Selector.KCODE)
///
fn reloadCs() void {
    asm volatile(
        \\pushq %[sel]
        \\lea 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        :
        : [sel] "r" (@as(u64, Selector.KCODE)),
        : .{ .rax = true, .memory = true }
    );
}

fn loadTss() void {
    asm volatile(
        "ltr %[sel]"
        :
        : [sel] "r" (Selector.TSS),
        : .{ .memory = true }
    );
}

///
/// Setup the global descriptor table and task segment
/// then switch the segment registers over.
///
pub fn init() void {
    const tss_base: u64 = @as(u64, @intFromPtr(&task_state));
    const tss_size = @sizeOf(Tss);

    gdt.descriptors[1] = getCodeDescriptor(0x9A);
    gdt.descriptors[2] = getDataDescriptor(0x92);
    gdt.descriptors[3] = getCodeDescriptor(0xFA);
    gdt.descriptors[4] = getDataDescriptor(0xF2);

    const raw_tss = getTSSDescriptor(tss_base, tss_size);
    gdt.tss_desc[0] = @truncate(raw_tss);
    gdt.tss_desc[1] = @intCast(raw_tss >> 64);

    task_state.ist1 = @as(
        u64,
        @intFromPtr(&double_fault_stack)
            + double_fault_stack_size,
    );

    gdtr = .{
        .limit = @sizeOf(Gdt) - 1,
        .base = @as(u64, @intFromPtr(&gdt)),
    };

    loadGdtr();
    reloadSegments();
    reloadCs();
    loadTss();
}
