export fn readline(prompt: [*c]const u8) [*c]u8 {
    const prompt_slice = std.mem.span(prompt);
    const line_slice = zig.readline(std.heap.raw_c_allocator, prompt_slice) catch
        return null;
    return @ptrCast(@alignCast(line_slice.ptr));
}

const std = @import("std");
pub const zig = @import("readline.zig");
