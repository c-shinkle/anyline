const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const anyline_zig_mod = b.addModule("anyline", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const anyline_c_mod = b.createModule(.{
        .root_source_file = b.path("src/c_bindings.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const anyline_c_lib = b.addLibrary(.{
        .name = "anyline",
        .root_module = anyline_c_mod,
        .linkage = .static,
    });
    b.installArtifact(anyline_c_lib);

    // exe (for testing)

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "anyline", .module = anyline_zig_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "anyline-exe",
        .root_module = exe_mod,
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
