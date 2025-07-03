pub fn main() !void {
    const stdout_writer = std.io.getStdOut().writer();
    const stderr_writer = std.io.getStdErr().writer();
    const stdin_reader = std.io.getStdIn().reader();
    const stdin_handle = std.io.getStdIn().handle;

    var old = old: {
        var temp: termios.termios = undefined;
        if (termios.tcgetattr(stdin_handle, &temp) < 0) {
            const errno_val = std.c._errno().*;
            const errno_string = string.strerror(errno_val);
            try stderr_writer.print("{s}\n", .{errno_string});
            return;
        }

        var new = temp;
        const ICANON = @as(c_uint, termios.ICANON);
        const ECHO = @as(c_uint, termios.ECHO);
        new.c_lflag &= ~(ICANON | ECHO);
        if (termios.tcsetattr(stdin_handle, termios.TCSANOW, &new) < 0) {
            const errno_val = std.c._errno().*;
            const errno_string = string.strerror(errno_val);
            try stderr_writer.print("{s}\n", .{errno_string});
            return;
        }
        break :old temp;
    };
    defer if (termios.tcsetattr(stdin_handle, termios.TCSANOW, &old) < 0) {
        const errno_val = std.c._errno().*;
        const errno_string = string.strerror(errno_val);
        stderr_writer.print("{s}\n", .{errno_string}) catch {};
    };

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

    while (true) {
        try cursor.setCursorRow(stdout_writer, row);
        try cursor.setCursorColumn(stdout_writer, col_offset);
        try stdout_writer.writeAll(prompt);

        var line_buffer: std.ArrayListUnmanaged(u8) = .empty;
        try history_buffer.append(arena, line_buffer.items);
        while (true) {
            switch (try stdin_reader.readByte()) {
                control_code.eot => return,
                control_code.lf => {
                    const finished_line = try line_buffer.toOwnedSlice(arena);
                    history_buffer.items[history_buffer.items.len - 1] = finished_line;
                    row += 1;
                    col_offset = 0;
                    history_index = history_buffer.items.len;
                    break;
                },
                control_code.esc => {
                    std.debug.assert('[' == try stdin_reader.readByte());
                    const third_byte = try stdin_reader.readByte();
                    switch (third_byte) {
                        'A' => { //Up
                            if (history_index == 0) {
                                continue;
                            }

                            if (history_index + 1 == history_buffer.items.len) {
                                history_buffer.items[history_index] = try line_buffer.toOwnedSlice(arena);
                            }
                            history_index -|= 1;
                            line_buffer.clearRetainingCapacity();
                            try line_buffer.appendSlice(arena, history_buffer.items[history_index]);

                            try cursor.setCursor(stdout_writer, prompt.len, row);
                            try ansi_term.clear.clearFromCursorToLineEnd(stdout_writer);
                            try stdout_writer.writeAll(line_buffer.items);
                            col_offset = line_buffer.items.len;
                        },
                        'B' => { //Down
                            if (history_index + 1 >= history_buffer.items.len) {
                                continue;
                            }

                            history_index += 1;
                            line_buffer.clearRetainingCapacity();
                            try line_buffer.appendSlice(arena, history_buffer.items[history_index]);

                            try cursor.setCursor(stdout_writer, prompt.len, row);
                            try ansi_term.clear.clearFromCursorToLineEnd(stdout_writer);
                            try stdout_writer.writeAll(line_buffer.items);
                            col_offset = line_buffer.items.len;
                        },
                        'C' => { //Right
                            col_offset = @min(col_offset + 1, line_buffer.items.len);
                            try cursor.setCursorColumn(stdout_writer, prompt.len + col_offset);
                        },
                        'D' => { //Left
                            col_offset -|= 1;
                            try cursor.setCursorColumn(stdout_writer, prompt.len + col_offset);
                        },
                        else => @panic("unhandled control byte"),
                    }
                },
                ' '...'~' => |print_byte| {
                    try line_buffer.insert(arena, col_offset, print_byte);
                    try stdout_writer.writeAll(line_buffer.items[col_offset..]);

                    col_offset += 1;
                    try cursor.setCursorColumn(stdout_writer, prompt.len + col_offset);
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
                else => |byte| try stderr_writer.print("Unhandled character: {c}\n", .{byte}),
            }
        }
    }
}

const std = @import("std");
const control_code = std.ascii.control_code;

const ansi_term = @import("ansi_term");
const cursor = ansi_term.cursor;

const string = @cImport(@cInclude("string.h"));
const termios = @cImport(@cInclude("termios.h"));
// const errno = @cImport(@cInclude("errno.h"));
