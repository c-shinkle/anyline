pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const outlive_allocator = gpa.allocator();

    anyline.zig.using_history();

    const filename = try findHistoryPath(outlive_allocator);
    defer outlive_allocator.free(filename);
    try anyline.zig.read_history(outlive_allocator, filename);

    while (true) {
        const line = try anyline.zig.readline(outlive_allocator, ">> ");
        defer outlive_allocator.free(line);

        if (std.mem.eql(u8, line, ".exit")) break;

        try anyline.zig.add_history(outlive_allocator, line);
    }

    try anyline.zig.write_history(outlive_allocator, filename);
}

fn findHistoryPath(alloc: std.mem.Allocator) ![:0]const u8 {
    const home_path = try std.process.getEnvVarOwned(alloc, switch (builtin.os.tag) {
        .linux, .macos => "HOME",
        .windows => "USERPROFILE",
        else => return error.UnsupportedOS,
    });
    defer alloc.free(home_path);

    var home_dir = try std.fs.openDirAbsolute(home_path, std.fs.Dir.OpenOptions{});
    defer home_dir.close();

    const file_name = ".demo_history";
    home_dir.access(file_name, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.print("history file is missing! Creating ~/{s} now...\n", .{file_name});
            const temp = try home_dir.createFile(file_name, .{});
            temp.close();
        },
        else => return e,
    };

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return alloc.dupeZ(u8, try home_dir.realpath(file_name, buf[0..]));
}

const std = @import("std");
const builtin = @import("builtin");
const anyline = @import("anyline");
