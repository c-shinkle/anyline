pub fn readline(outlive_allocator: std.mem.Allocator, prompt: []const u8) ![]const u8 {
    var col_offset: usize = 0;
    var line_buffer = std.ArrayListUnmanaged(u8).empty;
    var edit_stack = std.ArrayListUnmanaged([]const u8).empty;

    var arena_allocator = std.heap.ArenaAllocator.init(outlive_allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    try history_entries.append(outlive_allocator, "");
    defer _ = history_entries.pop();
    var history_index: usize = history_entries.items.len - 1;

    const old = switch (builtin.os.tag) {
        .linux => try Linux.init(),
        .windows => try Windows.init(),
        else => return error.UnsupportedOS,
    };
    defer switch (builtin.os.tag) {
        .linux => old.deinit(),
        .windows => old.deinit(),
        else => unreachable,
    };

    const stdout_writer = std.io.getStdOut().writer();
    const stderr_writer = std.io.getStdErr().writer();
    const stdin_reader = std.io.getStdIn().reader();

    try stdout_writer.writeAll(prompt);
    if (builtin.os.tag == .windows) {
        const console_input = std.io.getStdIn().handle;
        if (0 == windows_c.FlushConsoleInputBuffer(console_input)) {
            return error.SetConsoleModeFailure;
        }
    }

    while (true) {
        const first_byte = try stdin_reader.readByte();
        switch (first_byte) {
            CTRL_B => {
                col_offset -|= 1;
                try setCursorColumn(stdout_writer, prompt.len + col_offset);
            },
            CTRL_D => {
                // try log(
                //     arena,
                //     "line_buffer.items.len == {d}",
                //     .{line_buffer.items.len},
                //     stdout_writer,
                //     prompt.len + col_offset,
                // );
                if (line_buffer.items.len == 0) {
                    try stdout_writer.writeByte('\n');
                    break;
                }
                if (line_buffer.items.len == col_offset) {
                    continue;
                }
                const edited_line = try arena.dupe(u8, line_buffer.items);
                try edit_stack.append(arena, edited_line);

                _ = line_buffer.orderedRemove(col_offset);

                try stdout_writer.writeAll(line_buffer.items[col_offset..]);
                try stdout_writer.writeByte(' ');
                try setCursorColumn(stdout_writer, prompt.len + col_offset);
            },
            CTRL_F => {
                col_offset = @min(col_offset + 1, line_buffer.items.len);
                try setCursorColumn(stdout_writer, prompt.len + col_offset);
            },
            control_code.lf, control_code.cr => { // ENTER
                try stdout_writer.writeByte('\n');
                break;
            },
            control_code.esc => {
                std.debug.assert('[' == try stdin_reader.readByte());
                const third_byte = try stdin_reader.readByte();
                switch (third_byte) {
                    UP_ARROW => {
                        if (!is_using_history or history_index == 0) {
                            continue;
                        }

                        if (history_index + 1 == history_entries.items.len) {
                            history_entries.items[history_index] =
                                try outlive_allocator.dupe(u8, line_buffer.items);
                        }
                        edit_stack.clearRetainingCapacity();

                        history_index -= 1;

                        line_buffer.clearRetainingCapacity();
                        try line_buffer.appendSlice(
                            arena,
                            history_entries.items[history_index],
                        );

                        try setCursorColumn(stdout_writer, prompt.len);
                        try clearFromCursorToLineEnd(stdout_writer);
                        try stdout_writer.writeAll(line_buffer.items);
                        col_offset = line_buffer.items.len;
                    },
                    DOWN_ARROW => {
                        if (!is_using_history or history_index + 1 >= history_entries.items.len) {
                            continue;
                        }

                        edit_stack.clearRetainingCapacity();
                        history_index += 1;

                        line_buffer.clearRetainingCapacity();
                        try line_buffer.appendSlice(
                            arena,
                            history_entries.items[history_index],
                        );

                        try setCursorColumn(stdout_writer, prompt.len);
                        try ansi_term.clear.clearFromCursorToLineEnd(stdout_writer);
                        try stdout_writer.writeAll(line_buffer.items);
                        col_offset = line_buffer.items.len;
                    },
                    RIGHT_ARROW => {
                        col_offset = @min(col_offset + 1, line_buffer.items.len);
                        try setCursorColumn(stdout_writer, prompt.len + col_offset);
                    },
                    LEFT_ARROW => {
                        col_offset -|= 1;
                        try setCursorColumn(stdout_writer, prompt.len + col_offset);
                    },
                    DEL => {
                        std.debug.assert('~' == try stdin_reader.readByte());

                        if (line_buffer.items.len == col_offset) {
                            continue;
                        }

                        const edited_line = try arena.dupe(u8, line_buffer.items);
                        try edit_stack.append(arena, edited_line);

                        _ = line_buffer.orderedRemove(col_offset);
                        try ansi_term.clear.clearFromCursorToLineEnd(stdout_writer);
                        try stdout_writer.writeAll(line_buffer.items[col_offset..]);
                        try setCursorColumn(stdout_writer, prompt.len + col_offset);
                    },
                    else => {
                        std.debug.print("Unhandled control byte: {d}\n", .{third_byte});
                    },
                }
            },
            UNDERSCORE => {
                if (edit_stack.items.len == 0) {
                    continue;
                }

                line_buffer.clearRetainingCapacity();
                try line_buffer.appendSlice(arena, edit_stack.pop().?);

                try setCursorColumn(stdout_writer, prompt.len);
                try ansi_term.clear.clearFromCursorToLineEnd(stdout_writer);
                try stdout_writer.writeAll(line_buffer.items);
                try setCursorColumn(stdout_writer, col_offset);
            },
            ' '...'~' => |print_byte| {
                // If you are editting a line that was populated from history,
                // then you need to include a backstop for undo's
                const is_last_entry = history_index + 1 == history_entries.items.len;
                if (!is_last_entry and edit_stack.items.len == 0) {
                    const duped_finished_line = try arena.dupe(u8, line_buffer.items);
                    try edit_stack.append(arena, duped_finished_line);
                }

                try line_buffer.insert(arena, col_offset, print_byte);
                try stdout_writer.writeAll(line_buffer.items[col_offset..]);

                col_offset += 1;
                try setCursorColumn(stdout_writer, prompt.len + col_offset);
            },
            BACK_SPACE => {
                if (col_offset == 0) {
                    continue;
                }
                const copied_line = try arena.dupe(u8, line_buffer.items);
                try edit_stack.append(arena, copied_line);

                col_offset -= 1;
                _ = line_buffer.orderedRemove(col_offset);

                try setCursorColumn(stdout_writer, prompt.len + col_offset);
                try stdout_writer.writeAll(line_buffer.items[col_offset..]);
                try stdout_writer.writeByte(' ');
                try setCursorColumn(stdout_writer, prompt.len + col_offset);
            },
            else => |unknown_byte| try stderr_writer.print("Unhandled character: {d}\n", .{
                unknown_byte,
            }),
        }
    }

    return try outlive_allocator.dupe(u8, line_buffer.items);
}

var is_using_history = false;
var history_entries = std.ArrayListUnmanaged([]const u8).empty;

pub fn using_history() void {
    is_using_history = true;
}

pub fn add_history(alloc: std.mem.Allocator, line: []const u8) !void {
    const duped_line = try alloc.dupe(u8, line);
    try history_entries.append(alloc, duped_line);
}

pub fn write_history(alloc: std.mem.Allocator, filename: []const u8) !void {
    var file = try std.fs.createFileAbsolute(filename, .{});
    defer file.close();

    const all_entries = try std.mem.join(alloc, "\n", history_entries.items);
    defer alloc.free(all_entries);
    try file.writeAll(all_entries);

    for (history_entries.items) |entry| {
        alloc.free(entry);
    }
    history_entries.deinit(alloc);
    history_entries = .empty;
}

pub fn read_history(alloc: std.mem.Allocator, filename: []const u8) !void {
    is_using_history = true;

    const file = try std.fs.openFileAbsolute(filename, .{});
    defer file.close();

    const data = try file.readToEndAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(data);

    var iterator = std.mem.tokenizeScalar(u8, data, '\n');
    while (iterator.next()) |line| {
        const duped_line = try alloc.dupe(u8, line);
        try history_entries.append(alloc, duped_line);
    }
}

fn log(
    arena: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
    stdout_writer: std.fs.File.Writer,
    col: usize,
) !void {
    const max_rows = 100;
    const msg = try std.fmt.allocPrint(arena, fmt, args);
    try setCursorColumn(stdout_writer, max_rows - msg.len);
    try stdout_writer.writeAll(msg);
    try setCursorColumn(stdout_writer, col);
}

const CTRL_B = 0x02;
const CTRL_D = 0x04;
const CTRL_F = 0x06;
const UP_ARROW = 'A';
const DOWN_ARROW = 'B';
const RIGHT_ARROW = 'C';
const LEFT_ARROW = 'D';
const DEL = '3';
const UNDERSCORE = 0x1F;
const BACK_SPACE = 0x7F;

const std = @import("std");
const builtin = @import("builtin");
const control_code = std.ascii.control_code;

const ansi_term = @import("ansi_term");
const setCursorColumn = ansi_term.cursor.setCursorColumn;
const clearFromCursorToLineEnd = ansi_term.clear.clearFromCursorToLineEnd;

const Linux = @import("Linux.zig");
const Windows = @import("Windows.zig");

const windows_c = @cImport(@cInclude("windows.h"));
