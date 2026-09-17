const video = @import("video.zig").VideoLogger;

pub const TrapFrame = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,

    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,

    // pushed by stubs
    int_num: u64,
    error_code: u64,

    // pushed by CPU
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
    // mint fmt: off
    pub fn print(ctx: *TrapFrame) void {
        video.tracef(
            \\rax {X:8}    r8  {X:8}    cs {X:4} rip {X:8}
            \\rbx {X:8}    r9  {X:8}    ss {X:4} rsp {X:8}
            \\rcx {X:8}    r10 {X:8}
            \\rdx {X:8}    r11 {X:8}    rflags {X:8}
            \\                r12 {X:8}    
            \\rsi {X:8}    r13 {X:8}
            \\rdi {X:8}    r14 {X:8}    vec#={}
            \\rbp {X:8}    r15 {X:8}    err#={}
            , .{
                ctx.rax, ctx.r8, ctx.cs, ctx.rip,
                ctx.rbx, ctx.r9, ctx.ss, ctx.rsp,
                ctx.rcx, ctx.r10,
                ctx.rdx, ctx.r11, ctx.rflags,
                ctx.r12,
                ctx.rsi, ctx.r13,
                ctx.rdi, ctx.r14, ctx.int_num,
                ctx.rbp, ctx.r15, ctx.error_code
            });
    }
    // mint fmt: on
};

comptime {
    asm(
        \\.intel_syntax noprefix
        \\.global initCatchTrapContext
        \\initCatchTrapContext:
        \\  push r15
        \\  push r14
        \\  push r13
        \\  push r12
        \\  push r11
        \\  push r10
        \\  push r9
        \\  push r8
        \\  push rbp
        \\  push rdi
        \\  push rsi
        \\  push rdx
        \\  push rcx
        \\  push rbx
        \\  push rax
        \\
        \\  cld
        \\  mov rdi, rsp
        \\  call initCheckTrapContext
        \\
        \\  pop rax
        \\  pop rbx
        \\  pop rcx
        \\  pop rdx
        \\  pop rsi
        \\  pop rdi
        \\  pop rbp
        \\  pop r8
        \\  pop r9
        \\  pop r10
        \\  pop r11
        \\  pop r12
        \\  pop r13
        \\  pop r14
        \\  pop r15
        \\
        \\  add rsp, 16
        \\  iretq
    );
}

fn hasErrorCode(i: u64) bool {
    return switch (i) {
        8, 10...14, 17, 21 => true,
        else => false,
    };
}

fn makeIsr(comptime i: u8) fn () callconv(.naked) void {
    return switch (i) {
        8, 10, 11, 12, 13, 14, 17, 21 => struct {
            fn handler() callconv(.naked) void {
                asm volatile(
                    \\ push 0
                    \\ push %[idx]
                    \\ jmp initCatchTrapContext
                    :
                    : [idx] "n" (i),
                );
            }
        }.handler,
        else => struct {
            fn handler() callconv(.naked) void {
                asm volatile(
                    \\ push 0
                    \\ push %[idx]
                    \\ jmp initCatchTrapContext
                    :
                    : [idx] "n" (i),
                );
            }
        }.handler,
    };
}

pub const isr_stub_table = blk: {
    var table: [
        256
    ]*const fn () callconv(.naked) void = undefined;
    for (0..256) |i| {
        table[i] = makeIsr(@intCast(i));
    }
    break :blk table;
};
