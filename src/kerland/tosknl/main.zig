//! Some important tips and notes are store here. The future CoffeeLake, don't forget them!!
//! And fix them immediately!! This is bad. But we're not looking for a simple solutions.
//! No ELF64 and SysV and unix-like stuff here as many people do. 
//!  
//! TOSKNL and other modules links into Portable Executable format at the moment of
//! release 0.16 (like zig :D). That's why I don't use System V ABI. Instead of it I use:
//!         Microsoft x64 ABI
//!
//! Kernel modules can't move correct, that's why .data and .rodata sections
//! will be corrupted or zeroed at the moment of 1st page allocation.
//! >> Go to the bootx64 module and set bounds of kernel image. (kernel entrypoint | size of image)
//! >> After this -> go here -> pmm.init(boot) must reserve selection of pages where tosknl is located
//! + pmm.lock(address, size); // must reserve segment by given address (and length)
//! + pmm.unlock(address, size); // must return free state of selection (unreserve?? idk inglish)  
const text = @import("text/debug.zig"); 
const pmm = @import("mem/pmm.zig");
const BootInfo = @import("boot/boot_info.zig").BootInfo;
const intel = @import("protection.zig");
const console = &@import("text/console.zig").console;
const Console = @import("text/console.zig").Console;
/// Zig linker must know that exists main.zig and main procedure inside
/// If I stay this entry point and set custom in the build.zig - 
/// resulting binary will have an entry point which refers to what we want.
/// Not to main(). Exactly to kmain();
pub fn main() void {}
/// Kernel Entry point which RVA will be set
pub export fn kmain(boot: *BootInfo) callconv(.c) void {
    // Send boot arguments to Physical memory allocator.
    // At the PML4 will be placed Global Descriptors slice and Interrupt Descriptor slice
    // It helps me in the future to STOP process execution if catastrophic failure occurs.
    pmm.init(boot);
    console.* = Console.init(boot) catch {
        kstop(&"VGA driver fault");
    };
    console.clear();
    console.printf("Now physical memory allocator and necessary protection will be set\n", .{});
    // Page Map (level 4) was allocated. It always prints "Page allocated 4096 bytes".
    const page_map4 = pmm.alloc() orelse kstop(&"GDT/TSS page allocation fault"); // panic immediate. no fucking memory
    intel.gdtInit(page_map4);
    // Interrupt Descriptor Table initialization
    // After this procedure I also seeing how my virtual machine crashes and resets
    // but I know this is bad. Does it mean that IDT doesn't work correct? or what?
    // If i send an unknown character to Console.putChar -> VM falls with no reason? 
    // (but I've expected #GP/#PF) 
    intel.idtInit();
    // Initialize console (VGA) minimal support (FS doesn't need. We're embed raster font in the data)
    console.printf("Finally minimal Toska payload is ready\n", .{});

    while (true) {
        asm volatile("hlt");
    }
}

pub export fn kstop(msg: *const []const u8) callconv(.c) noreturn {
    text.kbochs("STOP: ");
    text.kbochs(msg.*);
    text.kbochs("\n");

    while (true) {
        asm volatile("hlt");
    }
}