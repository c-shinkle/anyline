pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const outlive_allocator = gpa.allocator();

    anyline.using_history();

    const filename = try findHistoryPath(outlive_allocator);
    defer outlive_allocator.free(filename);
    try anyline.read_history(outlive_allocator, filename);

    while (true) {
        const line = try anyline.readline(outlive_allocator, ">> ");
        defer outlive_allocator.free(line);

        if (std.mem.eql(u8, line, ".exit")) break;

        try anyline.add_history(outlive_allocator, line);
    }

    try anyline.write_history(outlive_allocator, filename);
}

fn findHistoryPath(alloc: std.mem.Allocator) ![]const u8 {
    const home_path = switch (builtin.os.tag) {
        .linux, .macos => try std.process.getEnvVarOwned(alloc, "HOME"),
        .windows => @panic("unimplemented!"),
        else => return error.UnsupportedOS,
    };
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

    return try home_dir.realpathAlloc(alloc, file_name);
}

const std = @import("std");
const builtin = @import("builtin");
const anyline = @import("anyline");
