const std = @import("std");
/// Major version of Toska project
pub const majorVersion = 0;
/// Minor version of Toska project
pub const minorVersion = 16;

const QEMU = "D:\\Program Files\\qemu\\qemu-system-x86_64.exe";
const NASM = "D:\\Program Files\\NASM\\nasm.exe";

fn runQemu(b: *std.Build) void {
    // I have no QEMU aliases in the environment. That's why I explicitly set path of target VM
    const qemu_x8664 = QEMU;
    const qemu_cmd = b.addSystemCommand(&.{qemu_x8664});
    // Root folder contains OVMF.fd diskette which provides UEFI for QEMU
    // Without it image can't run because the first course was use EFI services
    // in the OS dev.
    //      -drive if=pflash,format=raw,readonly=on,file=ovmf.fd
    qemu_cmd.addArg("-drive");
    qemu_cmd.addArg("if=pflash,format=raw,readonly=on,file=ovmf.fd");
    // Also, TOSKNL.EXE module uses Bochs debug port, that's why args of 
    // QEMU little extends.
    //      -debugcon stdio
    qemu_cmd.addArg("-s");
    qemu_cmd.addArg("-debugcon");
    qemu_cmd.addArg("stdio");
    // And finally connect the output Zig directory as FAT32 "ESP" volume
    // bootloader locates by /efi/boot/boot<arch>.efi path. It's requirement of UEFI standard
    //      -hda fat:rw:zig-out/image 
    qemu_cmd.addArg("-hda");
    qemu_cmd.addArg("fat:rw:zig-out/image");
    
    const qemu = b.step("run", "Connect EFI experience to QEMU and output directory as FAT32 volume");
    qemu.dependOn(&qemu_cmd.step);
}

fn buildBootx64(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .ofmt = .coff,
        .abi = .msvc
    });
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.
    const boot_module = b.createModule(.{
        .root_source_file = b.path("src/boot/main.zig"),
        .target = target,
        .code_model = .default,
        .optimize = optimize
    });
    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const bootx64 = b.addExecutable(.{
        .name = "bootx64",
        .root_module = boot_module,
        .use_llvm = true,
    });
    // Before making artifact: PE executables contains special
    // subsystem enum field. EFI shell operates PE executables
    // with the Efi... subsystem. For else the loaded image will be discarded.
    //bootx64.entry = .{ .symbol_name = "efi_main" };
    
    // Allow to see others entry point of TOSK bootloader
    bootx64.subsystem = .EfiApplication;
    bootx64.rdynamic = true;
    bootx64.pie = false;
    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    const install_artifact = b.addInstallArtifact(bootx64, .{
        .dest_dir = .{ 
            .override = .{ .custom = "image/efi/boot" }
        },
    });
    // Move bootx64 copy into 
    b.getInstallStep().dependOn(&install_artifact.step);
    b.installArtifact(bootx64);
}

fn buildKer(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .ofmt = .coff,
        .abi = .none,
    });
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    //const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .target = target,
        .code_model = .default,
        .root_source_file = b.path("src/kerland/tosknl/main.zig"),
    });
    // Installer of Netwide Assembler doesn't make aliases -> 
    // set explicit path to the nasm binary
    const nasm = NASM;

    const loader_src = "src/kerland/tosknl/protection.asm";

    _ = b.run(&[_][]const u8{
        nasm, "-f", "win64", "-o", "protection.o", loader_src, // elf64
    });
    module.addObjectFile(b.path("protection.o"));
    // Finally: TOSKNL.EXE
    // Requirements: PE32+ executable under the NATIVE subsystem
    // (subsystem is missing). 
    const tosknl = b.addExecutable(.{
        .name = "init",
        .use_llvm = true,
        .use_lld = true,
        .root_module = module,
    });
    tosknl.entry = .disabled;

    tosknl.entry = .{ .symbol_name = "kmain" };
    tosknl.subsystem = .Native;
    tosknl.rdynamic = true;
    tosknl.pie = false;

    // Produce toxic waste
    const artifact = b.addInstallArtifact(tosknl, .{ .dest_dir = .{ 
        .override = .{ .custom = "image" }
    }});
    b.getInstallStep().dependOn(&artifact.step);

    b.installArtifact(tosknl);
}
/// Version module (version.dll) is a special library which contains all 
/// metadata abot project.
/// Don't know where we're running? connect the versions.dll.
/// Don't know OS version? call versions.dll!version_os with "Microsoft x64" rules of course
fn buildVersion(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .ofmt = .coff,
        .os_tag = .windows,
    });
    const version_mod = b.createModule(.{
        .root_source_file = b.path("src/kerland/version/main.zig"),
        .target = target,
        .link_libc = false,
        .no_builtin = true,
    });

    const version = b.addLibrary(.{
        .root_module = version_mod,
        .linkage = .dynamic,
        .name = "version"
    });
    version.subsystem = .Native;
    // produce toxic waste
    const artifact = b.addInstallArtifact(version, .{ .dest_dir = .{ 
        .override = .{ .custom = "image" }
    }});

    b.getInstallStep().dependOn(&artifact.step);
    b.installArtifact(version);
}
// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Zero # procedure is a bootloader linking. 
    // Requirements pretty simple: IA32e (64-bit) UEFI Portable Executable module
    // name: bootx64.efi
    // location: zig-out/image/efi/boot
    buildBootx64(b);
    // Firstly -> link the kernland and the tosk kernel too
    // module name: tosknl.exe
    // location: /zig-out/image/init.exe
    // location: /zig-out/image/version.dll
    buildKer(b);
    buildVersion(b);
    // Prepare run step and finally run build results
    runQemu(b);
}
