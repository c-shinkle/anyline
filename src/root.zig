export fn readline(prompt: [*c]const u8) [*c]u8 {
    const prompt_slice = std.mem.span(prompt);
    const line_slice = zig.readline(std.heap.raw_c_allocator, prompt_slice) catch {
        return null;
    };
    return @ptrCast(@alignCast(line_slice.ptr));
}

export fn add_history(line: [*c]const u8) void {
    const line_slice = if (line) |l| std.mem.span(l) else "";
    zig.add_history(std.heap.raw_c_allocator, line_slice) catch {};
}

export fn read_history(filename: [*c]const u8) c_int {
    const maybe_absolute_path = if (filename) |f| std.mem.span(f) else null;
    zig.read_history(std.heap.raw_c_allocator, maybe_absolute_path) catch {
        return std.c._errno().*;
    };
    return 0;
}

export fn write_history(filename: [*c]const u8) c_int {
    const maybe_absolute_path = if (filename) |f| std.mem.span(f) else null;
    zig.write_history(std.heap.raw_c_allocator, maybe_absolute_path) catch {
        return std.c._errno().*;
    };
    return 0;
}

const std = @import("std");
const builtin = @import("builtin");
pub const zig = @import("readline.zig");
