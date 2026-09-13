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
const cpu = @import("cpu.zig");
const idt = @import("idt.zig");
const pit = @import("pit.zig");
const video = @import("video.zig").VideoLogger;

const Video = @import("video.zig").Video;
const serial = @import("serial.zig").SerialLogger;
const interrupts = @import("interrupts.zig");

const FirmwareInterface = @import("fi.zig").FirmwareInterface;

pub export fn main(
    bootinfo: *FirmwareInterface,
) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    video.init(bootinfo);
    video.okf("Monitor located (@0x{X})\n", .{@intFromPtr(bootinfo.framebuffer_base)});

    pmm.init(bootinfo);

    video.okf(
        "RAM status: {} MiB, ({} total pages, {} free pages)\n",
        .{
            pmm.getMemorySize() / 1024 / 1024,
            pmm.getPageCount(),
            pmm.getFreePages(),
        },
    );

    idt.init();

    // PIC remap + sti (must happen after IDT is in place)
    interrupts.init();
    video.okf("Interrupts restored\n", .{});

    // PIT timer: fire IRQ0 at 100 Hz -> IDT vector 0x20
    video.infof("Programming PIT at 100 Hz\n", .{});
    pit.init(100);

    const t0 = pit.getTicks();
    video.infof("PIT test sleep 2 seconds via the timer\n", .{});
    pit.sleep(2000);
    const t1 = pit.getTicks();
    video.okf("2s sleep: {} ticks elapsed\n", .{t1 -% t0});

    video.infof("printing ticks once a second.\n", .{});
    while (true) {
        pit.sleep(100);
        video.printf("{} ", .{pit.getTicks()});
    }
}
/// 
/// Short test of physical memory allocator.
/// Test will be passed if memory size after memory pages releasing
/// is the same with the memory size before.
/// For else memory allocator works incorrect because of resources wasn't freed. 
/// 
inline fn testMemory() void {
    // Quick alloc / free round-trip to prove the free list is sane.
    const a = pmm.alloc() orelse 0;
    const b2 = pmm.alloc() orelse 0;
    const c = pmm.alloc() orelse 0;
    pmm.free(b2);
    const d = pmm.alloc() orelse 0;

    video.okf("alloc/free round-trip: d == b2 -> {}\n", .{d == b2});
    video.tracef("first/last pages: {} / {}\n", .{ a, c });
    video.tracef("free pages now: {}\n", .{pmm.getFreePages()});
}