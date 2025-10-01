pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const outlive_allocator = gpa.allocator();

    anyline.using_history();

    const path = null;
    try anyline.read_history(outlive_allocator, path);

    while (true) {
        const line = try anyline.readline(outlive_allocator, ">> ");
        defer outlive_allocator.free(line);

        if (std.mem.eql(u8, line, ".exit")) {
            break;
        } else if (line.len > 0) {
            try anyline.add_history(outlive_allocator, line);
        }
    }

    try anyline.write_history(outlive_allocator, path);

    anyline.free_history(outlive_allocator);
    anyline.free_copy(outlive_allocator);
}

const std = @import("std");
const anyline = @import("anyline");
