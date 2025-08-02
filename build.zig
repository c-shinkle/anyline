const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const anyline_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const is_x86_64_linux = target.result.cpu.arch == .x86_64 and target.result.os.tag == .linux;
    const anyline_lib = b.addLibrary(.{
        .name = "anyline",
        .root_module = anyline_mod,
        .use_llvm = !is_x86_64_linux,
    });

    const ansi_term_dep = b.dependency("ansi_term", .{
        .target = target,
        .optimize = optimize,
    });

    anyline_lib.root_module.addImport("ansi_term", ansi_term_dep.module("ansi_term"));
    b.installArtifact(anyline_lib);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "anyline-exe",
        .root_module = exe_mod,
        .use_llvm = !is_x86_64_linux,
    });

    exe.linkLibrary(anyline_lib);
    exe.root_module.addImport("anyline", anyline_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
