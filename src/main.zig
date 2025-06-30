pub fn main() !void {
    const stdout_writer = std.io.getStdOut().writer();
    var stdin_file = std.io.getStdIn();
    const stdin_reader = stdin_file.reader();

    var old: termios.termios = undefined;
    _ = termios.tcgetattr(stdin_file.handle, &old);
    defer _ = termios.tcsetattr(stdin_file.handle, termios.TCSANOW, &old);

    var new = old;
    const ICANON: c_uint = @as(c_uint, termios.ICANON);
    const ECHO: c_uint = @as(c_uint, termios.ECHO);
    new.c_lflag &= ~(ICANON | ECHO);
    _ = termios.tcsetattr(stdin_file.handle, termios.TCSANOW, &new);

    // var row: usize = 0;
    var col_offset: usize = 0;
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
        while (true) {
            const byte = try stdin_reader.readByte();
            if (byte == std.ascii.control_code.esc) {
                const second_byte = try stdin_reader.readByte();
                std.debug.assert(second_byte == '[');
                const third_byte = try stdin_reader.readByte();
                switch (third_byte) {
                    'D' => {
                        col_offset -|= 1;
                        try cursor.setCursorColumn(stdout_writer, prompt.len + col_offset);
                        continue;
                    },
                    // 'C' => try stdout_writer.print("Right\n", .{}),
                    // 'A' => try stdout_writer.print("Up\n", .{}),
                    // 'B' => try stdout_writer.print("Down\n", .{}),
                    else => @panic("unhandled control byte"),
                }
            } else if (byte == '\n') {
                try stdout_writer.writeByte('\n');
                try history_buffer.append(arena, try line_buffer.toOwnedSlice(arena));
                col_offset = 0;
                break;
            } else {
                try cursor.setCursorColumn(stdout_writer, prompt.len);
                try ansi_term.clear.clearFromCursorToLineEnd(stdout_writer);

                if (col_offset < line_buffer.items.len) {
                    line_buffer.items[col_offset] = byte;
                } else {
                    try line_buffer.append(arena, byte);
                }
                col_offset += 1;
                try stdout_writer.writeAll(line_buffer.items);
                try cursor.setCursorColumn(stdout_writer, prompt.len + col_offset);
            }
        }
        // Finish line
        // try stdout_writer.writeByte('\n');
        // row += 1;
    }
}

const std = @import("std");
const ansi_term = @import("ansi_term");
const cursor = ansi_term.cursor;
const termios = @cImport(@cInclude("termios.h"));
