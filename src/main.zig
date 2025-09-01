pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const outlive_allocator = gpa.allocator();

    anyline.zig.using_history();

    const path = "/home/theshinx317/Coding/Zig/anyline/.demo_history";
    // const path = null;
    try anyline.zig.read_history(outlive_allocator, path);

    while (true) {
        const line = try anyline.zig.readline(outlive_allocator, ">> ");
        defer outlive_allocator.free(line);

        if (std.mem.eql(u8, line, ".exit")) break;

        try anyline.zig.add_history(outlive_allocator, line);
    }

    try anyline.zig.write_history(outlive_allocator, path);
}

const std = @import("std");
const builtin = @import("builtin");
const anyline = @import("anyline");
