var is_using_history = false;
var history_entries = std.ArrayListUnmanaged([]const u8).empty;
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

const esc = "\x1B";
const csi = esc ++ "[";

pub fn readline(outlive_allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    var col_offset: usize = 0;
    var line_buffer = std.ArrayListUnmanaged(u8).empty;
    var edit_stack = std.ArrayListUnmanaged([]const u8).empty;

    var arena_allocator = std.heap.ArenaAllocator.init(outlive_allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    try history_entries.append(outlive_allocator, undefined);
    defer _ = history_entries.pop();
    var history_index: usize = history_entries.items.len - 1;

    const old = switch (builtin.os.tag) {
        .linux, .macos => try Linux.init(),
        .windows => try Windows.init(),
        else => return error.UnsupportedOS,
    };
    defer switch (builtin.os.tag) {
        .linux, .macos => old.deinit(),
        .windows => old.deinit(),
        else => unreachable,
    };

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    var stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stdin = std.fs.File.stdin();

    var stderr_writer = std.fs.File.stderr().writerStreaming(&.{});
    var stderr = &stderr_writer.interface;

    // Windows needs the following two lines to prevent garbage writes to the terminal
    try setCursorColumn(stdout, 0);
    try clearFromCursorToLineEnd(stdout);
    try stdout.writeAll(prompt);
    try stdout.flush();

    while (true) : (try stdout.flush()) {
        var stdin_buffer: [4]u8 = undefined;
        std.debug.assert(try stdin.read(&stdin_buffer) > 0);
        const first_byte = stdin_buffer[0];
        switch (first_byte) {
            CTRL_B => {
                col_offset -|= 1;
                try setCursorColumn(stdout, prompt.len + col_offset);
            },
            CTRL_D => {
                if (line_buffer.items.len == 0) {
                    try stdout.writeByte('\n');
                    break;
                }
                if (line_buffer.items.len == col_offset) {
                    continue;
                }
                const edited_line = try arena.dupe(u8, line_buffer.items);
                try edit_stack.append(arena, edited_line);

                _ = line_buffer.orderedRemove(col_offset);

                try stdout.writeAll(line_buffer.items[col_offset..]);
                try stdout.writeByte(' ');
                try setCursorColumn(stdout, prompt.len + col_offset);
            },
            CTRL_F => {
                col_offset = @min(col_offset + 1, line_buffer.items.len);
                try setCursorColumn(stdout, prompt.len + col_offset);
            },
            std.ascii.control_code.lf, std.ascii.control_code.cr => { // ENTER
                try stdout.writeByte('\n');
                break;
            },
            std.ascii.control_code.esc => {
                std.debug.assert('[' == stdin_buffer[1]);
                const third_byte = stdin_buffer[2];
                switch (third_byte) {
                    UP_ARROW => {
                        if (!is_using_history or history_index == 0) {
                            continue;
                        }

                        if (history_index + 1 == history_entries.items.len) {
                            history_entries.items[history_index] =
                                try arena.dupe(u8, line_buffer.items);
                        }
                        edit_stack.clearRetainingCapacity();

                        history_index -= 1;

                        line_buffer.clearRetainingCapacity();
                        try line_buffer.appendSlice(
                            arena,
                            history_entries.items[history_index],
                        );

                        try setCursorColumn(stdout, prompt.len);
                        try clearFromCursorToLineEnd(stdout);
                        try stdout.writeAll(line_buffer.items);
                        col_offset = line_buffer.items.len;
                    },
                    DOWN_ARROW => {
                        const is_last_entry = history_index + 1 == history_entries.items.len;
                        if (!is_using_history or is_last_entry) {
                            continue;
                        }

                        edit_stack.clearRetainingCapacity();
                        history_index += 1;

                        line_buffer.clearRetainingCapacity();
                        try line_buffer.appendSlice(
                            arena,
                            history_entries.items[history_index],
                        );

                        try setCursorColumn(stdout, prompt.len);
                        try clearFromCursorToLineEnd(stdout);
                        try stdout.writeAll(line_buffer.items);
                        col_offset = line_buffer.items.len;
                    },
                    RIGHT_ARROW => {
                        col_offset = @min(col_offset + 1, line_buffer.items.len);
                        try setCursorColumn(stdout, prompt.len + col_offset);
                    },
                    LEFT_ARROW => {
                        col_offset -|= 1;
                        try setCursorColumn(stdout, prompt.len + col_offset);
                    },
                    DEL => {
                        std.debug.assert('~' == stdin_buffer[3]);

                        if (line_buffer.items.len == col_offset) {
                            continue;
                        }

                        const edited_line = try arena.dupe(u8, line_buffer.items);
                        try edit_stack.append(arena, edited_line);

                        _ = line_buffer.orderedRemove(col_offset);
                        try clearFromCursorToLineEnd(stdout);
                        try stdout.writeAll(line_buffer.items[col_offset..]);
                        try setCursorColumn(stdout, prompt.len + col_offset);
                    },
                    else => {
                        try stderr.print("Unhandled control byte: {d}\n", .{third_byte});
                    },
                }
            },
            UNDERSCORE => {
                if (edit_stack.items.len == 0) {
                    continue;
                }

                line_buffer.clearRetainingCapacity();
                try line_buffer.appendSlice(arena, edit_stack.pop().?);

                col_offset = @min(col_offset, line_buffer.items.len);

                try setCursorColumn(stdout, prompt.len);
                try clearFromCursorToLineEnd(stdout);
                try stdout.writeAll(line_buffer.items);
                try setCursorColumn(stdout, prompt.len + col_offset);
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
                try stdout.writeAll(line_buffer.items[col_offset..]);

                col_offset += 1;
                try setCursorColumn(stdout, prompt.len + col_offset);
            },
            BACK_SPACE => {
                if (col_offset == 0) {
                    continue;
                }
                const copied_line = try arena.dupe(u8, line_buffer.items);
                try edit_stack.append(arena, copied_line);

                col_offset -= 1;
                _ = line_buffer.orderedRemove(col_offset);

                try setCursorColumn(stdout, prompt.len + col_offset);
                try stdout.writeAll(line_buffer.items[col_offset..]);
                try stdout.writeByte(' ');
                try setCursorColumn(stdout, prompt.len + col_offset);
            },
            else => |unknown_byte| try stderr.print("Unhandled character: {d}\n", .{
                unknown_byte,
            }),
        }
    }

    return try outlive_allocator.dupe(u8, line_buffer.items);
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

pub fn using_history() void {
    is_using_history = true;
}

pub fn add_history(alloc: std.mem.Allocator, line: []const u8) !void {
    const duped_line = try alloc.dupe(u8, line);
    try history_entries.append(alloc, duped_line);
}

pub fn write_history(alloc: std.mem.Allocator, maybe_absolute_path: ?[]const u8) !void {
    defer {
        for (history_entries.items) |entry| {
            alloc.free(entry);
        }
        history_entries.clearAndFree(alloc);
    }
    const file = if (maybe_absolute_path) |absolute_path|
        try std.fs.openFileAbsolute(absolute_path, std.fs.File.OpenFlags{ .mode = .read_write })
    else
        try openDefaultHistory(alloc);
    defer file.close();

    const all_entries = try std.mem.join(alloc, "\n", history_entries.items);
    defer alloc.free(all_entries);

    var buffer: [1024]u8 = undefined;
    var writer = file.writerStreaming(&buffer);
    try writer.interface.writeAll(all_entries);
    try writer.interface.flush();
}

pub fn read_history(alloc: std.mem.Allocator, maybe_absolute_path: ?[]const u8) !void {
    is_using_history = true;

    var file = if (maybe_absolute_path) |absolute_path|
        try std.fs.createFileAbsolute(absolute_path, std.fs.File.CreateFlags{
            .read = true,
            .truncate = false,
        })
    else
        try openDefaultHistory(alloc);
    defer file.close();

    var buffer: [1024]u8 = undefined;
    var reader = file.readerStreaming(&buffer);
    const data = try reader.interface.allocRemaining(alloc, .unlimited);
    defer alloc.free(data);

    var iterator = std.mem.tokenizeScalar(u8, data, '\n');
    while (iterator.next()) |line| {
        const duped_line = try alloc.dupe(u8, line);
        try history_entries.append(alloc, duped_line);
    }
}

fn openDefaultHistory(alloc: std.mem.Allocator) !std.fs.File {
    const home_path = try std.process.getEnvVarOwned(alloc, switch (builtin.os.tag) {
        .linux, .macos => "HOME",
        .windows => "USERPROFILE",
        else => return error.UnsupportedOS,
    });
    defer alloc.free(home_path);

    var home_dir = try std.fs.openDirAbsolute(home_path, std.fs.Dir.OpenOptions{});
    defer home_dir.close();

    return try home_dir.createFile(".history", std.fs.File.CreateFlags{
        .read = true,
        .truncate = false,
    });
}

fn setCursorColumn(writer: *std.Io.Writer, column: usize) !void {
    try writer.print(csi ++ "{}G", .{column + 1});
}

pub fn clearFromCursorToLineEnd(writer: *std.Io.Writer) !void {
    try writer.writeAll(csi ++ "K");
}

const std = @import("std");
const builtin = @import("builtin");
const control_code = std.ascii.control_code;

const Linux = @import("Linux.zig");
const Windows = @import("Windows.zig");

const windows_c = @cImport(@cInclude("windows.h"));
