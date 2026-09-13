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
const log = @import("log.zig");
const cpu = @import("cpu.zig");
const idt = @import("idt.zig");
const pit = @import("pit.zig");
const interrupts = @import("interrupts.zig");

const FirmwareInterface = @import("fi.zig").FirmwareInterface;

pub export fn main(
    bootinfo: *FirmwareInterface,
) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    log.info("main", .{});

    log.info("pmm::init", .{});
    pmm.init(bootinfo);
    log.ok(
        "Allocated: {} MiB, ({} total pages, {} free pages)",
        .{
            pmm.getMemorySize() / 1024 / 1024,
            pmm.getPageCount(),
            pmm.getFreePages(),
        },
    );

    // Quick alloc / free round-trip to prove the free list is sane.
    const a = pmm.alloc() orelse 0;
    const b2 = pmm.alloc() orelse 0;
    const c = pmm.alloc() orelse 0;
    pmm.free(b2);
    const d = pmm.alloc() orelse 0;

    log.ok("alloc/free round-trip: d == b2 -> {}", .{d == b2});
    log.trace("first/last pages: {} / {}", .{ a, c });
    log.trace("free pages now: {}", .{pmm.getFreePages()});
    // Do I really need to recreate IDT???
    log.info("idt::init", .{});
    idt.init();
    log.ok("IDT loaded", .{});

    // PIC remap + sti (must happen after IDT is in place)
    interrupts.init();
    log.ok("Interrupts enabled", .{});

    // PIT timer: fire IRQ0 at 100 Hz -> IDT vector 0x20
    log.info("Programming PIT at 100 Hz", .{});
    pit.init(100);

    const t0 = pit.getTicks();
    log.info("Sleeping 2 seconds via the timer", .{});
    pit.sleep(2000);
    const t1 = pit.getTicks();
    log.ok("2s sleep: {} ticks elapsed", .{t1 -% t0});

    log.info("printing ticks once a second", .{});
    while (true) {
        pit.sleep(100);
        log.println("tick => {}", .{pit.getTicks()});
    }
}
