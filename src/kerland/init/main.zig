//!
//! Linked into a freestanding ELF64 x86-64 image by `linker.ld`. The bootloader
//! loads every `PT_LOAD` segment at its virtual address and jumps to
//! the init entry point, handing it a pointer to the boot info produced from UEFI.
//!
//! `init` boots sequentially: the physical memory allocator first, then (in the
//! upcoming steps) the IDT, PIC, PIT timer and the rest of the flat long-mode
//! environment. All progress is reported through the serial logger.
//!
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pit = @import("pit.zig");
const video = @import("video.zig").VideoLogger;
const std = @import("std");

const Video = @import("video.zig").Video;
const serial = @import("serial.zig").SerialLogger;
const interrupts = @import("interrupts.zig");
const kbd = @import("kbd.zig");

const FirmwareInterface = @import("fi.zig").FirmwareInterface;

pub export fn main(
    fi: *FirmwareInterface,
) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    video.init(fi);
    video.okf(
        "Monitor located (@0x{X})\n",
        .{@intFromPtr(fi.framebuffer_base)},
    );

    pmm.init(fi);
    testPMM();

    video.okf(
        "RAM status: {} MiB, ({} total pages, {} free pages)\n",
        .{
            pmm.getMemorySize() / 1024 / 1024,
            pmm.getPageCount(),
            pmm.getFreePagesCount(),
        },
    );
    gdt.init();
    video.okf("GDT rewritten\n", .{});

    const pml4 = vmm.init(
        pmm.getMemorySize(),
        @intFromPtr(fi.framebuffer_base),
        @as(usize, fi.framebuffer_width)
            * @as(usize, fi.framebuffer_height)
            * 4,
    ) catch {
        video.failf("VMM init failed\n", .{});
        cpu.cli();
        while (true) cpu.hlt();
    };
    video.tracef("PML4 @ 0x{X}\n", .{pml4});
    serial.println("paging enabled, PML4 @ 0x{X}", .{pml4});

    testVMM();

    // PIC remap + sti (must happen after IDT is in place)
    idt.init();
    interrupts.init();
    video.okf("Interrupts restored\n", .{});

    // PIT timer: fire IRQ0 at 100 Hz -> IDT vector 0x20
    video.tracef("Programming PIT at 100 Hz\n", .{});

    pit.init(100);
    testPIT();

    video.infof("keyboard ready. type 'help'.\n", .{});

    var line: [80]u8 = undefined;
    var nline: usize = 0;
    //var last_tick: u64 = 0;

    while (true) {
        // 10 ms poll window; ticks keep firing in the background at 100 Hz.
        pit.sleep(10);

        // Echo keyboard characters into the line buffer and run commands.
        while (kbd.poll()) |c| {
            switch (c) {
                0x08 => { // backspace: drop one char and redraw prompt + line
                    if (nline > 0) {
                        nline -= 1;
                        video.printf(
                            "\r{s} ",
                            .{line[0..nline]},
                        );
                    }
                },
                '\n' => {
                    video.printf("\n", .{});
                    runCommand(line[0..nline]);
                    nline = 0;
                    video.printf("> ", .{});
                },
                else => {
                    if (nline < line.len) {
                        line[nline] = c;
                        nline += 1;
                    }
                    video.printf(
                        "> {s}{c}",
                        .{ line[0..nline], c },
                    );
                },
            }
        }

        // spam of ticks.
        // const now = pit.getTicks();
        // if (now -% last_tick >= 10) {
        //     last_tick = now;
        //     video.printf("[tick {}]\n", .{now});
        // }
    }
}
///
/// Runtime test of the #PF trap path. Called by the interactive `pf` command:
/// it deliberately executes `int 14`, whose handler dumps the TrapFrame and
/// halts. QEMU's `info registers` output should agree with the printed frame.
///
inline fn testPFh() void {
    asm volatile(
        \\.intel_syntax noprefix
        \\ int 14
    );
}
///
/// Tiny interactive command dispatcher feeding off the keyboard line buffer.
///
fn runCommand(line: []const u8) void {
    if (std.mem.eql(u8, line, "help")) {
        video.infof("commands: help, ticks, clear, pf\n", .{});
    } else if (std.mem.eql(u8, line, "ticks")) {
        video.printf("ticks: {}\n", .{pit.getTicks()});
    } else if (std.mem.eql(u8, line, "clear")) {
        @import("video.zig").monitor.clear();
    } else if (std.mem.eql(u8, line, "pf")) {
        video.infof(
            "triggering #PF (int 14) trap-frame test\n",
            .{},
        );
        testPFh();
    } else if (line.len > 0) {
        video.printf("unknown command: '{s}'\n", .{line});
    }
}
///
/// Short test of physical memory allocator.
/// Test will be passed if memory size after memory pages releasing
/// is the same with the memory size before.
/// For else memory allocator works incorrect because of resources wasn't freed.
///
inline fn testPMM() void {
    // Quick alloc / free round-trip to prove the free list is sane.
    const a = pmm.alloc() orelse 0;
    const b2 = pmm.alloc() orelse 0;
    const c = pmm.alloc() orelse 0;
    pmm.free(b2);
    const d = pmm.alloc() orelse 0;
    video.printf("PMM allocates and releases pages now\n", .{});
    // alloc/free round-trip: d == b2 -> {}

    if (d == b2) {
        video.okf("PMM alloc/free round-trip (0x{X})\n", .{d});
    } else {
        video.failf(
            "Memory pages were lost (0x{X}/0x{X})\n",
            .{ d, b2 },
        );
        cpu.cli();

        while (true) {
            cpu.hlt();
        }
    }

    video.tracef("First/Last pages: {} / {}\n", .{ a, c });
    video.tracef(
        "Free pages now: {}\n",
        .{pmm.getFreePagesCount()},
    );
}
///
/// Short test of the virtual heap. Allocates two buffers that
/// live above 0xFFFF800000000000 and are backed by physical pages from `pmm`,
/// then round-trips a byte pattern through them.
///
inline fn testVMM() void {
    const a = vmm.alloc(512) orelse return;
    const b = vmm.alloc(16 * 4096) orelse return;

    a[0] = 0x11;
    b[16 * 4096 - 1] = 0x22;

    if (
        a[0] == 0x11
            and b[16 * 4096 - 1] == 0x22
            and @intFromPtr(a) >= 0xFFFF800000000000
    ) {
        video.okf(
            "VMM sucessfully allocated: a=0x{X} b=0x{X}\n",
            .{ @intFromPtr(a), @intFromPtr(b) },
        );
        serial.okf(
            "VMM::alloc=0x{X} b=0x{X}",
            .{ @intFromPtr(a), @intFromPtr(b) },
        );
    } else {
        video.failf("VMM alloc test failed\n", .{});
        serial.failf("VMM alloc test failed", .{});
        cpu.cli();
        while (true) cpu.hlt();
    }
}
/// Programmer interval timer test.
inline fn testPIT() void {
    const t0 = pit.getTicks();
    video.printf(
        "PIT test sleep 3 seconds via the timer\n",
        .{},
    );
    pit.sleep(3000);
    const t1 = pit.getTicks();
    video.okf("3s sleep: {} ticks elapsed\n", .{t1 -% t0});
}
