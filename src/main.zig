pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const child_allocator = gpa.allocator();

    anyline.using_history();

    var i: u8 = 0;
    while (i < 5) : (i += 1) {
        const line = try anyline.readline(child_allocator, ">> ");
        defer child_allocator.free(line);
        try anyline.add_history(child_allocator, line);
    }

    std.debug.print("5 items added to history\n", .{});

    try anyline.write_history(child_allocator, "my_history_file");
}

const std = @import("std");
const anyline = @import("anyline");
