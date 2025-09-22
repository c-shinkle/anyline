var is_using_history = false;
var history_entries = std.ArrayListUnmanaged([]const u8).empty;
const CTRL_A = 0x01;
const CTRL_B = 0x02;
const CTRL_C = 0x03;
const CTRL_D = 0x04;
const CTRL_E = 0x05;
const CTRL_F = 0x06;
const CTRL_L = 0x0c;
const UP_ARROW = 'A';
const DOWN_ARROW = 'B';
const RIGHT_ARROW = 'C';
const LEFT_ARROW = 'D';
const DEL = '3';
const UNDERSCORE = 0x1F;
const BACK_SPACE = 0x7F;

const esc = "\x1B";
const csi = esc ++ "[";

const new_line = if (builtin.os.tag == .windows) "\r\n" else "\n";

pub const ReadlineError =
    Allocator.Error ||
    std.fs.File.ReadError ||
    std.Io.Reader.Error ||
    std.Io.Reader.DelimiterError ||
    std.fs.File.WriteError ||
    switch (builtin.os.tag) {
        .linux => Linux.Error,
        .macos => MacOs.Error,
        .windows => Windows.Error,
        .freebsd => FreeBSD.Error,
        else => @compileError(std.fmt.comptimePrint("{s} is not a supported OS!", .{
            name: for (@typeInfo(std.Target.Os.Tag).@"enum".fields) |field| {
                if (@intFromEnum(builtin.os.tag) == field.value) break :name field.name;
            },
        })),
    };

pub const AddHistoryError = Allocator.Error;

pub const WriteHistoryError =
    std.process.GetEnvVarOwnedError ||
    std.fs.File.OpenError ||
    std.Io.Writer.Error;

pub fn readline(allocator: Allocator, prompt: []const u8) ReadlineError![]u8 {
    var col_offset: usize = 0;
    var line_buffer = std.ArrayListUnmanaged(u8).empty;
    var edit_stack = std.ArrayListUnmanaged([]const u8).empty;

    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    try history_entries.append(allocator, undefined);
    defer _ = history_entries.pop();
    var history_index: usize = history_entries.items.len - 1;

    const old = switch (builtin.os.tag) {
        .linux => try Linux.init(),
        .macos => try MacOs.init(),
        .windows => try Windows.init(),
        .freebsd => try FreeBSD.init(),
        else => unreachable,
    };
    defer switch (builtin.os.tag) {
        .linux, .macos, .windows, .freebsd => old.deinit(),
        else => unreachable,
    };

    var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});

    var stdin_file = std.fs.File.stdin();

    // Windows needs the following two lines to prevent garbage writes to the terminal
    try setCursorColumn(&stdout_writer.interface, 0);
    try clearFromCursorToLineEnd(&stdout_writer.interface);
    try stdout_writer.interface.writeAll(prompt);
    try stdout_writer.interface.flush();

    while (true) : (try stdout_writer.interface.flush()) {
        var stdin_buffer: [8]u8 = undefined;
        const bytes_read = try stdin_file.read(&stdin_buffer);
        std.debug.assert(bytes_read > 0);

        const first_byte = stdin_buffer[0];
        switch (first_byte) {
            CTRL_A => {
                col_offset = 0;
                try setCursorColumn(&stdout_writer.interface, prompt.len + col_offset);
            },
            CTRL_B => {
                col_offset -|= 1;
                try setCursorColumn(&stdout_writer.interface, prompt.len + col_offset);
            },
            CTRL_C => {
                std.debug.assert(builtin.os.tag == .windows);
                std.process.exit(0);
            },
            CTRL_D => {
                if (line_buffer.items.len == 0) {
                    try stdout_writer.interface.writeByte('\n');
                    break;
                }
                if (line_buffer.items.len == col_offset) {
                    continue;
                }
                const edited_line = try arena.dupe(u8, line_buffer.items);
                try edit_stack.append(arena, edited_line);

                _ = line_buffer.orderedRemove(col_offset);

                try stdout_writer.interface.writeAll(line_buffer.items[col_offset..]);
                try stdout_writer.interface.writeByte(' ');
                try setCursorColumn(&stdout_writer.interface, prompt.len + col_offset);
            },
            CTRL_E => {
                col_offset = line_buffer.items.len;
                try setCursorColumn(&stdout_writer.interface, prompt.len + col_offset);
            },
            CTRL_F => {
                col_offset = @min(col_offset + 1, line_buffer.items.len);
                try setCursorColumn(&stdout_writer.interface, prompt.len + col_offset);
            },
            CTRL_L => {
                try clearEntireScreen(&stdout_writer.interface);
                try setCursor(&stdout_writer.interface, 0, 0);

                try stdout_writer.interface.writeAll(prompt);
                try stdout_writer.interface.writeAll(line_buffer.items);

                try setCursorColumn(&stdout_writer.interface, prompt.len + col_offset);
            },
            std.ascii.control_code.lf, std.ascii.control_code.cr => { // ENTER
                try stdout_writer.interface.writeByte('\n');
                break;
            },
            std.ascii.control_code.esc => {
                if (bytes_read == 1) continue;
                if (bytes_read > 4) {
                    const fmt = "Kitty protocol not supported: {s}";
                    try log(allocator, fmt, .{stdin_buffer[2..8]}, prompt.len + col_offset);
                    continue;
                }

                const second_byte = stdin_buffer[1];
                if ('[' == second_byte) {
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

                            try setCursorColumn(&stdout_writer.interface, prompt.len);
                            try clearFromCursorToLineEnd(&stdout_writer.interface);
                            try stdout_writer.interface.writeAll(line_buffer.items);
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

                            try setCursorColumn(&stdout_writer.interface, prompt.len);
                            try clearFromCursorToLineEnd(&stdout_writer.interface);
                            try stdout_writer.interface.writeAll(line_buffer.items);
                            col_offset = line_buffer.items.len;
                        },
                        RIGHT_ARROW => {
                            col_offset = @min(col_offset + 1, line_buffer.items.len);
                            try setCursorColumn(&stdout_writer.interface, prompt.len + col_offset);
                        },
                        LEFT_ARROW => {
                            col_offset -|= 1;
                            try setCursorColumn(&stdout_writer.interface, prompt.len + col_offset);
                        },
                        DEL => {
                            std.debug.assert('~' == stdin_buffer[3]);

                            if (line_buffer.items.len == col_offset) {
                                continue;
                            }

                            const edited_line = try arena.dupe(u8, line_buffer.items);
                            try edit_stack.append(arena, edited_line);

                            _ = line_buffer.orderedRemove(col_offset);
                            try clearFromCursorToLineEnd(&stdout_writer.interface);
                            try stdout_writer.interface.writeAll(line_buffer.items[col_offset..]);
                            try setCursorColumn(&stdout_writer.interface, prompt.len + col_offset);
                        },
                        else => {
                            const fmt = "Unhandled control byte: {d}";
                            try log(allocator, fmt, .{third_byte}, prompt.len + col_offset);
                        },
                    }
                } else {
                    switch (second_byte) {
                        'f' => {
                            if (col_offset == line_buffer.items.len) continue;

                            const isAN = std.ascii.isAlphanumeric;
                            const was_an = isAN(line_buffer.items[col_offset]);

                            var i = col_offset + 1;
                            const len = line_buffer.items.len;
                            if (was_an) {
                                while (i < len and isAN(line_buffer.items[i])) i += 1;
                            } else {
                                while (i < len and !isAN(line_buffer.items[i])) i += 1;
                            }
                            col_offset = i;
                            try setCursorColumn(&stdout_writer.interface, prompt.len + col_offset);
                        },
                        'b' => {
                            if (col_offset == 0) continue;

                            var i = @min(col_offset, line_buffer.items.len - 1);
                            const isAN = std.ascii.isAlphabetic;
                            const was_an = isAN(line_buffer.items[i]);

                            i -= 1;
                            if (was_an) {
                                while (i > 0 and isAN(line_buffer.items[i])) i -= 1;
                            } else {
                                while (i > 0 and !isAN(line_buffer.items[i])) i -= 1;
                            }
                            col_offset = i;
                            try setCursorColumn(&stdout_writer.interface, prompt.len + col_offset);
                        },
                        else => {
                            const fmt = "Unhandled meta byte: {d}";
                            try log(allocator, fmt, .{second_byte}, prompt.len + col_offset);
                        },
                    }
                }
            },
            UNDERSCORE => {
                if (edit_stack.items.len == 0) {
                    continue;
                }

                line_buffer.clearRetainingCapacity();
                try line_buffer.appendSlice(arena, edit_stack.pop().?);

                col_offset = @min(col_offset, line_buffer.items.len);

                try setCursorColumn(&stdout_writer.interface, prompt.len);
                try clearFromCursorToLineEnd(&stdout_writer.interface);
                try stdout_writer.interface.writeAll(line_buffer.items);
                try setCursorColumn(&stdout_writer.interface, prompt.len + col_offset);
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
                try stdout_writer.interface.writeAll(line_buffer.items[col_offset..]);

                col_offset += 1;
                try setCursorColumn(&stdout_writer.interface, prompt.len + col_offset);
            },
            BACK_SPACE => {
                if (col_offset == 0) {
                    continue;
                }
                const copied_line = try arena.dupe(u8, line_buffer.items);
                try edit_stack.append(arena, copied_line);

                col_offset -= 1;
                _ = line_buffer.orderedRemove(col_offset);

                try setCursorColumn(&stdout_writer.interface, prompt.len + col_offset);
                try stdout_writer.interface.writeAll(line_buffer.items[col_offset..]);
                try stdout_writer.interface.writeByte(' ');
                try setCursorColumn(&stdout_writer.interface, prompt.len + col_offset);
            },
            else => |unknown_byte| {
                const fmt = "Unhandled character: {d}";
                try log(allocator, fmt, .{unknown_byte}, prompt.len + col_offset);
            },
        }
    }

    return try allocator.dupe(u8, line_buffer.items);
}

fn log(alloc: Allocator, comptime fmt: []const u8, args: anytype, prev_col: usize) !void {
    if (!(builtin.mode == .Debug)) return;

    var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});

    const max_col = max_col: {
        try setCursorColumn(&stdout_writer.interface, 999);
        try queryCursorPosition(&stdout_writer.interface);
        try stdout_writer.interface.flush();

        var buffer: [32]u8 = undefined;
        var reader = std.fs.File.stdin().readerStreaming(&buffer);
        const input = try reader.interface.takeDelimiterExclusive('R');

        const semicolon_index = std.mem.indexOf(u8, input, ";").?;
        const position_slice = input[semicolon_index + 1 ..];
        break :max_col std.fmt.parseUnsigned(usize, position_slice, 10) catch unreachable;
    };

    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(msg);
    try setCursorColumn(&stdout_writer.interface, max_col - msg.len);
    try stdout_writer.interface.writeAll(msg);
    try setCursorColumn(&stdout_writer.interface, prev_col);
}

pub fn using_history() void {
    is_using_history = true;
}

pub fn add_history(alloc: Allocator, line: []const u8) AddHistoryError!void {
    const duped_line = try alloc.dupe(u8, line);
    try history_entries.append(alloc, duped_line);
}

pub fn write_history(alloc: Allocator, maybe_absolute_path: ?[]const u8) WriteHistoryError!void {
    defer {
        for (history_entries.items) |entry| {
            alloc.free(entry);
        }
        history_entries.clearAndFree(alloc);
    }
    const file = if (maybe_absolute_path) |absolute_path|
        try std.fs.openFileAbsolute(absolute_path, std.fs.File.OpenFlags{ .mode = .write_only })
    else
        try openDefaultHistory(alloc);
    defer file.close();

    const all_entries = try std.mem.join(alloc, new_line, history_entries.items);
    defer alloc.free(all_entries);

    var buffer: [1024]u8 = undefined;
    var writer = file.writerStreaming(&buffer);
    try writer.interface.writeAll(all_entries);
    try writer.interface.flush();
}

pub fn read_history(alloc: Allocator, maybe_absolute_path: ?[]const u8) !void {
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

    var iterator = std.mem.tokenizeSequence(u8, data, new_line);
    while (iterator.next()) |line| {
        const duped_line = try alloc.dupe(u8, line);
        try history_entries.append(alloc, duped_line);
    }
}

fn openDefaultHistory(alloc: Allocator) !std.fs.File {
    const home_path = try std.process.getEnvVarOwned(alloc, switch (builtin.os.tag) {
        .linux, .macos, .freebsd => "HOME",
        .windows => "USERPROFILE",
        else => unreachable,
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

fn setCursor(writer: *std.Io.Writer, x: usize, y: usize) !void {
    try writer.print(csi ++ "{};{}H", .{ y + 1, x + 1 });
}

fn clearFromCursorToLineEnd(writer: *std.Io.Writer) !void {
    try writer.writeAll(csi ++ "K");
}

fn clearEntireScreen(writer: *std.Io.Writer) !void {
    try writer.writeAll(csi ++ "2J");
}

fn queryCursorPosition(writer: *std.Io.Writer) !void {
    try writer.writeAll(csi ++ "6n");
}

// try log(allocator, "stdin: {d:0>3}, {d}, {d}, {d}, {d}, {d}, {d}, {d}", .{ stdin_buffer[0], stdin_buffer[1], stdin_buffer[2], stdin_buffer[3], stdin_buffer[4], stdin_buffer[5], stdin_buffer[6], stdin_buffer[7] }, prompt.len + col_offset);

const std = @import("std");
const control_code = std.ascii.control_code;
const Allocator = std.mem.Allocator;

const builtin = @import("builtin");

const Linux = @import("Linux.zig");
const MacOs = @import("MacOS.zig");
const Windows = @import("Windows.zig");
const FreeBSD = @import("FreeBSD.zig");
