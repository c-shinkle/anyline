pub fn main() !void {
    const stdout_writer = std.io.getStdOut().writer();
    var stdin_reader = std.io.getStdIn().reader();
    // var row: usize = 0;
    var col: usize = 0;
    const prompt = ">> ";
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    // var line_buffer: std.ArrayListUnmanaged(u8) = .empty;
    var history_buffer: std.ArrayListUnmanaged([]u8) = .empty;

    try ansi_term.clear.clearScreen(stdout_writer);
    try cursor.setCursorRow(stdout_writer, 0);
    try cursor.setCursorColumn(stdout_writer, 0);

    while (true) {
        // Start new line
        try stdout_writer.writeAll(prompt);

        var line_buffer: std.ArrayListUnmanaged(u8) = .empty;
        byte_loop: while (true) {
            const byte = try stdin_reader.readByte();
            if (byte == std.ascii.control_code.esc) {
                const second_byte = try stdin_reader.readByte();
                std.debug.assert(second_byte == '[');
                const third_byte = try stdin_reader.readByte();
                switch (third_byte) {
                    'D' => {
                        col -|= 1;
                        try cursor.setCursorColumn(stdout_writer, col);
                        break :byte_loop;
                    },
                    // 'C' => try stdout_writer.print("Right\n", .{}),
                    // 'A' => try stdout_writer.print("Up\n", .{}),
                    // 'B' => try stdout_writer.print("Down\n", .{}),
                    else => @panic("unhandled control byte"),
                }
            } else if (byte == '\n') {
                break :byte_loop;
            } else {
                // try stdout_writer.writeAll("append\n");
                try line_buffer.append(arena, byte);
                col += 1;
            }
        }
        // Finish line
        try history_buffer.append(arena, try line_buffer.toOwnedSlice(arena));
        // try stdout_writer.writeByte('\n');
        // row += 1;
    }
}

const std = @import("std");
const ansi_term = @import("ansi_term");
const cursor = ansi_term.cursor;
