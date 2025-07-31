pub fn main() !void {
    const stdout_writer = std.io.getStdOut().writer();
    const stderr_writer = std.io.getStdErr().writer();
    const stdin_reader = std.io.getStdIn().reader();

    const old = switch (builtin.os.tag) {
        .linux => try Linux.init(),
        .windows => try Windows.init(),
        else => unreachable,
    };
    defer switch (builtin.os.tag) {
        .linux => old.deinit(),
        .windows => old.deinit(),
        else => unreachable,
    };

    var gpa = std.heap.DebugAllocator(.{}){};
    const child_allocator = gpa.allocator();
    var arena_allocator = std.heap.ArenaAllocator.init(child_allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var row = row: {
        try stdout_writer.print("\x1B[6n", .{});
        const buffer = try stdin_reader.readUntilDelimiterAlloc(arena, 'R', 1024);
        std.debug.assert(control_code.esc == buffer[0]);
        std.debug.assert('[' == buffer[1]);
        const row_end_index = std.mem.indexOf(u8, buffer, ";").?;
        break :row try std.fmt.parseInt(usize, buffer[2..row_end_index], 10) -| 1;
    };
    var history_index: usize = 0;
    const prompt = ">> ";
    const console_input = std.io.getStdIn().handle;
    var history_entries: std.ArrayListUnmanaged(HistoryEntry) = .empty;

    while (true) {
        try cursor.setCursorRow(stdout_writer, row);
        try cursor.setCursorColumn(stdout_writer, 0);
        try stdout_writer.writeAll(prompt);
        if (builtin.os.tag == .windows) {
            if (0 == windows_c.FlushConsoleInputBuffer(console_input)) {
                return error.SetConsoleModeFailure;
            }
        }

        var col_offset: usize = 0;
        var line_buffer: std.ArrayListUnmanaged(u8) = .empty;
        // This dummy value guarentees there will always be an element at 'history_index'
        try history_entries.append(arena, undefined);
        var edit_stack: std.ArrayListUnmanaged([]const u8) = .empty;

        while (true) {
            const first_byte = try stdin_reader.readByte();
            switch (first_byte) {
                control_code.stx => { // CTRL + B
                    col_offset -|= 1;
                    try cursor.setCursorColumn(stdout_writer, prompt.len + col_offset);
                },
                control_code.eot => { // CTRL + D
                    if (line_buffer.items.len == 0) {
                        return;
                    }
                    if (line_buffer.items.len == col_offset) {
                        continue;
                    }
                    const line_buffer_before_edit_command = try arena.dupe(u8, line_buffer.items);
                    try edit_stack.append(arena, line_buffer_before_edit_command);

                    _ = line_buffer.orderedRemove(col_offset);
                    try ansi_term.clear.clearFromCursorToLineEnd(stdout_writer);
                    try stdout_writer.writeAll(line_buffer.items[col_offset..]);
                    try cursor.setCursorColumn(stdout_writer, prompt.len + col_offset);
                },
                control_code.ack => { // CTRL + F
                    col_offset = @min(col_offset + 1, line_buffer.items.len);
                    try cursor.setCursorColumn(stdout_writer, prompt.len + col_offset);
                },
                control_code.lf, control_code.cr => { // ENTER
                    history_entries.items[history_index].edit_stack.clearRetainingCapacity();

                    const finished_line = try line_buffer.toOwnedSlice(arena);
                    history_entries.items[history_entries.items.len - 1].line = finished_line;

                    history_entries.items[history_entries.items.len - 1].edit_stack
                        .clearRetainingCapacity();
                    row += 1;
                    history_index = history_entries.items.len;
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

                            if (history_index + 1 == history_entries.items.len) {
                                const finished_line = try line_buffer.toOwnedSlice(arena);
                                history_entries.items[history_index].line = finished_line;
                            }
                            history_entries.items[history_index].edit_stack = edit_stack;

                            history_index -|= 1;

                            line_buffer.clearRetainingCapacity();
                            try line_buffer.appendSlice(
                                arena,
                                history_entries.items[history_index].line,
                            );
                            edit_stack = history_entries.items[history_index].edit_stack;

                            try cursor.setCursor(stdout_writer, prompt.len, row);
                            try ansi_term.clear.clearFromCursorToLineEnd(stdout_writer);
                            try stdout_writer.writeAll(line_buffer.items);
                            col_offset = line_buffer.items.len;
                        },
                        'B' => { //Down
                            if (history_index + 1 >= history_entries.items.len) {
                                continue;
                            }

                            history_entries.items[history_index].edit_stack = edit_stack;
                            history_index += 1;

                            line_buffer.clearRetainingCapacity();
                            try line_buffer.appendSlice(
                                arena,
                                history_entries.items[history_index].line,
                            );
                            edit_stack = history_entries.items[history_index].edit_stack;

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
                        else => {
                            std.debug.print("Unhandled control byte: {d}\n", .{third_byte});
                        },
                    }
                },
                control_code.us => { // Underscore
                    if (edit_stack.items.len == 0) {
                        continue;
                    }
                    line_buffer.clearRetainingCapacity();
                    try line_buffer.appendSlice(arena, edit_stack.pop().?);

                    try cursor.setCursor(stdout_writer, prompt.len, row);
                    try ansi_term.clear.clearFromCursorToLineEnd(stdout_writer);
                    try stdout_writer.writeAll(line_buffer.items);
                    col_offset = line_buffer.items.len;
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
                    const copied_line = try arena.dupe(u8, line_buffer.items);
                    try edit_stack.append(arena, copied_line);
                    _ = line_buffer.orderedRemove(col_offset);

                    try cursor.setCursorColumn(stdout_writer, prompt.len + col_offset);
                    try stdout_writer.writeAll(line_buffer.items[col_offset..]);
                    try stdout_writer.writeByte(' ');
                    try cursor.setCursorColumn(stdout_writer, prompt.len + col_offset);
                },
                else => |unknown_byte| try stderr_writer.print("Unhandled character: {d}\n", .{
                    unknown_byte,
                }),
            }
        }
    }
}

const HistoryEntry = struct {
    line: []const u8,
    edit_stack: std.ArrayListUnmanaged([]const u8),
};

const std = @import("std");
const builtin = @import("builtin");
const control_code = std.ascii.control_code;

const ansi_term = @import("ansi_term");
const cursor = ansi_term.cursor;

const Linux = @import("Linux.zig");
const Windows = @import("Windows.zig");

const windows_c = @cImport(@cInclude("windows.h"));
