export fn readline(prompt: [*c]const u8) [*c]u8 {
    const prompt_slice = std.mem.span(prompt);
    const line_slice = lib.readline(std.heap.raw_c_allocator, prompt_slice) catch {
        return null;
    };
    var line_slice_z = std.heap.raw_c_allocator.realloc(line_slice, line_slice.len + 1) catch {
        return null;
    };
    line_slice_z[line_slice_z.len - 1] = 0;
    return @ptrCast(@alignCast(line_slice_z.ptr));
}

export fn add_history(line: [*c]const u8) void {
    const line_slice = if (line) |l| std.mem.span(l) else "";
    lib.add_history(std.heap.raw_c_allocator, line_slice) catch {};
}

export fn read_history(filename: [*c]const u8) c_int {
    const maybe_absolute_path = if (filename) |f| std.mem.span(f) else null;
    lib.read_history(std.heap.raw_c_allocator, maybe_absolute_path) catch {
        return std.c._errno().*;
    };
    return 0;
}

export fn write_history(filename: [*c]const u8) c_int {
    const maybe_absolute_path = if (filename) |f| std.mem.span(f) else null;
    lib.write_history(std.heap.raw_c_allocator, maybe_absolute_path) catch {
        return std.c._errno().*;
    };
    return 0;
}

export fn using_history() void {
    lib.using_history();
}

const std = @import("std");
const builtin = @import("builtin");
const lib = @import("root.zig");
