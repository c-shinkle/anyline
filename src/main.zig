pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const child_allocator = gpa.allocator();

    anyline.using_history();
    const filename = try findHistoryPath(child_allocator);
    defer child_allocator.free(filename);
    try anyline.read_history(child_allocator, filename);

    var i: u8 = 0;
    while (i < 5) : (i += 1) {
        const line = try anyline.readline(child_allocator, ">> ");
        defer child_allocator.free(line);
        try anyline.add_history(child_allocator, line);
    }

    std.debug.print("5 items added to history\n", .{});

    try anyline.write_history(child_allocator, filename);
}

fn findHistoryPath(alloc: std.mem.Allocator) ![]const u8 {
    const home_path = switch (builtin.os.tag) {
        .linux => try std.process.getEnvVarOwned(alloc, "HOME"),
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
