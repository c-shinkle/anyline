pub fn main() !void {
    const stdout_writer = std.io.getStdOut().writer();
    const stdin_reader = std.io.getStdIn().reader();
    const stdin_handle = std.io.getStdIn().handle;

    var old: termios.termios = undefined;
    _ = termios.tcgetattr(stdin_handle, &old);
    defer _ = termios.tcsetattr(stdin_handle, termios.TCSANOW, &old);

    var new = old;
    const ICANON: c_uint = @as(c_uint, termios.ICANON);
    const ECHO: c_uint = @as(c_uint, termios.ECHO);
    new.c_lflag &= ~(ICANON | ECHO);
    _ = termios.tcsetattr(stdin_handle, termios.TCSANOW, &new);

    var col_offset: usize = 0;
    const prompt = ">> ";
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var history_buffer: std.ArrayListUnmanaged([]u8) = .empty;

    try ansi_term.clear.clearScreen(stdout_writer);
    try cursor.setCursorRow(stdout_writer, 0);
    try cursor.setCursorColumn(stdout_writer, 0);

    // line_loop:
    while (true) {
        // Start new line
        try stdout_writer.writeAll(prompt);
        var line_buffer: std.ArrayListUnmanaged(u8) = .empty;
        byte_loop: while (true) {
            const byte = try stdin_reader.readByte();
            switch (byte) {
                std.ascii.control_code.esc => {
                    const second_byte = try stdin_reader.readByte();
                    std.debug.assert(second_byte == '[');
                    const third_byte = try stdin_reader.readByte();
                    switch (third_byte) {
                        'D' => { //Left
                            col_offset -|= 1;
                            try cursor.setCursorColumn(stdout_writer, prompt.len + col_offset);
                        },
                        'C' => { //Right
                            col_offset = @min(col_offset + 1, line_buffer.items.len);
                            try cursor.setCursorColumn(stdout_writer, prompt.len + col_offset);
                        },
                        // 'A' => try stdout_writer.print("Up\n", .{}),
                        // 'B' => try stdout_writer.print("Down\n", .{}),
                        // TODO handle back space
                        else => @panic("unhandled control byte"),
                    }
                },
                '\n' => {
                    try stdout_writer.writeByte('\n');
                    try history_buffer.append(arena, try line_buffer.toOwnedSlice(arena));
                    col_offset = 0;
                    break :byte_loop;
                },
                std.ascii.control_code.del => { //Backspace
                    if (col_offset == 0) {
                        continue;
                    }

                    col_offset -= 1;
                    line_buffer.replaceRangeAssumeCapacity(col_offset, 1, &.{});

                    try cursor.setCursorColumn(stdout_writer, prompt.len + col_offset);
                    try stdout_writer.writeAll(line_buffer.items[col_offset..]);
                    try stdout_writer.writeByte(' ');
                    try cursor.setCursorColumn(stdout_writer, prompt.len + col_offset);
                },
                else => {
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
                },
            }
        }
    }
}

const std = @import("std");
const ansi_term = @import("ansi_term");
const cursor = ansi_term.cursor;
const termios = @cImport(@cInclude("termios.h"));
