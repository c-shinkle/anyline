pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const child_allocator = gpa.allocator();

    const line = try anyline.readline(child_allocator, ">> ");
    defer child_allocator.free(line);

    std.debug.print("\n{s}\n", .{line});
}

const std = @import("std");
const anyline = @import("anyline");
