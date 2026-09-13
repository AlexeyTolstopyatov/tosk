const std = @import("std");

/// Build bootx64.efi
fn buildBoot(b: *std.Build) void {
    const target = b.resolveTargetQuery(
        .{ .ofmt = .coff, .cpu_arch = .x86_64, .os_tag = .uefi },
    );

    const elf_mod = b.createModule(
        .{
            .root_source_file = b.path(
                "src/kerland/boot/elf.zig",
            ),
        },
    );

    const mod = b.addModule(
        "bootx64",
        .{
            .link_libc = false,
            .link_libcpp = false,
            .no_builtin = true,
            .single_threaded = true,
            .unwind_tables = .none,
            .root_source_file = b.path(
                "src/kerland/boot/main.zig",
            ),
            .target = target,
            .optimize = .ReleaseSmall,
            //.strip = true,
            //.code_model = .kernel
        },
    );
    mod.addImport("elf", elf_mod);

    const exec = b.addExecutable(
        .{
            .name = "bootx64",
            .root_module = mod,
            .linkage = .static,
        },
    );

    const boot_step = b.addInstallArtifact(
        exec,
        .{
            .dest_dir = .{
                .override = .{ .custom = "img/efi/boot" },
            },
        },
    );
    // Move bootx64 copy into
    b.getInstallStep().dependOn(&boot_step.step);
    b.installArtifact(exec);
}

fn buildInit(b: *std.Build) void {
    const target = b.resolveTargetQuery(
        .{ .cpu_arch = .x86_64, .os_tag = .freestanding },
    );

    const mod = b.addModule(
        "init",
        .{
            .link_libc = false,
            .link_libcpp = false,
            .no_builtin = true,
            .single_threaded = true,
            .unwind_tables = .none,
            .root_source_file = b.path(
                "src/kerland/init/main.zig",
            ),
            .target = target,
            .optimize = .ReleaseSmall,
        },
    );

    const exec = b.addExecutable(
        .{
            .name = "init",
            .root_module = mod,
            .linkage = .static,
        },
    );
    exec.setLinkerScript(b.path("src/kerland/init/init.ld"));
    exec.pie = false;

    const init_step = b.addInstallArtifact(
        exec,
        .{ .dest_dir = .{ .override = .{ .custom = "img" } } },
    );
    b.getInstallStep().dependOn(&init_step.step);
    b.installArtifact(exec);
}

pub fn build(b: *std.Build) void {
    buildBoot(b);
    buildInit(b);
}
