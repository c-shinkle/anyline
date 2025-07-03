pub fn main() !void {
    const stdout_writer = std.io.getStdOut().writer();
    const stdin_reader = std.io.getStdIn().reader();
    const stdin_handle = std.io.getStdIn().handle;

    var old = old: {
        var temp: termios.termios = undefined;
        _ = termios.tcgetattr(stdin_handle, &temp);

        var new = temp;
        const ICANON = @as(c_uint, termios.ICANON);
        const ECHO = @as(c_uint, termios.ECHO);
        new.c_lflag &= ~(ICANON | ECHO);
        // TODO check c_int
        _ = termios.tcsetattr(stdin_handle, termios.TCSANOW, &new);
        break :old temp;
    };
    defer _ = termios.tcsetattr(stdin_handle, termios.TCSANOW, &old);

    var gpa = std.heap.DebugAllocator(.{}){};
    const child_allocator = gpa.allocator();
    var arena_allocator = std.heap.ArenaAllocator.init(child_allocator);
    defer arena_allocator.deinit();

    var row: usize = 0;
    var col_offset: usize = 0;
    var history_index: usize = 0;
    const prompt = ">> ";
    const arena = arena_allocator.allocator();
    var history_buffer: std.ArrayListUnmanaged([]const u8) = .empty;

    try ansi_term.clear.clearScreen(stdout_writer);
    try cursor.setCursorRow(stdout_writer, 0);
    try cursor.setCursorColumn(stdout_writer, 0);

    line_loop: while (true) {
        try stdout_writer.writeAll(prompt);
        var line_buffer: std.ArrayListUnmanaged(u8) = .empty;
        try history_buffer.append(arena, line_buffer.items);
        byte_loop: while (true) {
            const byte = try stdin_reader.readByte();
            switch (byte) {
                control_code.eot => break :line_loop,
                control_code.esc => {
                    std.debug.assert('[' == try stdin_reader.readByte());
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
                        'A' => { //Up
                            if (history_index == 0) {
                                continue;
                            }

                            std.debug.assert(history_buffer.items.len > 0);
                            if (history_index == history_buffer.items.len - 1) {
                                history_buffer.items[history_index] = try line_buffer.toOwnedSlice(arena);
                            }
                            history_index -|= 1;
                            line_buffer.clearRetainingCapacity();
                            try line_buffer.appendSlice(arena, history_buffer.items[history_index]);

                            try cursor.setCursor(stdout_writer, 0, row);
                            try ansi_term.clear.clearFromCursorToLineEnd(stdout_writer);
                            try stdout_writer.writeAll(prompt);
                            try stdout_writer.writeAll(line_buffer.items);
                            col_offset = line_buffer.items.len;
                        },
                        'B' => { //Down
                            if (history_index + 1 >= history_buffer.items.len) {
                                continue;
                            }

                            line_buffer.clearRetainingCapacity();
                            history_index += 1;
                            try line_buffer.appendSlice(arena, history_buffer.items[history_index]);

                            try cursor.setCursor(stdout_writer, 0, row);
                            try ansi_term.clear.clearFromCursorToLineEnd(stdout_writer);
                            try stdout_writer.writeAll(prompt);
                            try stdout_writer.writeAll(line_buffer.items);
                            col_offset = line_buffer.items.len;
                        },
                        else => @panic("unhandled control byte"),
                    }
                },
                control_code.lf => {
                    try stdout_writer.writeByte('\n');
                    std.debug.assert(history_buffer.items.len > 0);
                    history_buffer.items[history_buffer.items.len - 1] = try line_buffer.toOwnedSlice(arena);
                    row += 1;
                    col_offset = 0;
                    history_index = history_buffer.items.len;
                    break :byte_loop;
                },
                control_code.del => {
                    if (col_offset == 0) {
                        continue;
                    }

                    col_offset -= 1;
                    _ = line_buffer.orderedRemove(col_offset);

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
const control_code = std.ascii.control_code;
