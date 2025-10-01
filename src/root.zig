var is_using_history = false;
var history_entries = std.ArrayListUnmanaged([]const u8).empty;
var copy_stack = std.ArrayListUnmanaged([]const u8).empty;
// var previous_in_buffer: [8]u8 = undefined;
// var previous_len: usize = 0;

const CTRL_A = 0x01;
const CTRL_B = 0x02;
const CTRL_C = 0x03;
const CTRL_D = 0x04;
const CTRL_E = 0x05;
const CTRL_F = 0x06;
const CTRL_K = 0x0b;
const CTRL_L = 0x0c;
const CTRL_W = 0x17;
const CTRL_Y = 0x19;
const UP_ARROW = 'A';
const DOWN_ARROW = 'B';
const RIGHT_ARROW = 'C';
const LEFT_ARROW = 'D';
const DEL = '3';
const UNDERSCORE = 0x1F;
const BACKSPACE = 0x7F;

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
    std.fs.File.WriteError;

pub fn readline(outlive: Allocator, prompt: []const u8) ReadlineError![]u8 {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);

    const stdin_file = std.fs.File.stdin();

    return helper(outlive, prompt, &stdout_writer.interface, stdin_file);
}

fn helper(outlive: Allocator, prompt: []const u8, out: *std.Io.Writer, in: std.fs.File) ![]u8 {
    var col_offset: usize = 0;
    var line_buffer = std.ArrayListUnmanaged(u8).empty;
    var edit_stack = std.ArrayListUnmanaged([]const u8).empty;

    var arena_allocator = std.heap.ArenaAllocator.init(outlive);
    defer arena_allocator.deinit();
    const temp = arena_allocator.allocator();

    try history_entries.append(outlive, undefined);
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

    // Windows needs the following two lines to prevent garbage writes to the terminal
    try setCursorColumn(out, 0);
    try clearFromCursorToLineEnd(out);
    try out.writeAll(prompt);
    try out.flush();

    var in_buffer: [8]u8 = undefined;
    var bytes_read: usize = undefined;
    while (true) : ({
        try out.flush();
        // previous_in_buffer = in_buffer;
        // previous_len = bytes_read;
    }) {
        bytes_read = try in.read(&in_buffer);
        std.debug.assert(bytes_read > 0);

        const first_byte = in_buffer[0];
        switch (first_byte) {
            CTRL_A => {
                col_offset = 0;
                try setCursorColumn(out, prompt.len + col_offset);
            },
            CTRL_B => {
                col_offset -|= 1;
                try setCursorColumn(out, prompt.len + col_offset);
            },
            CTRL_C => {
                std.debug.assert(builtin.os.tag == .windows);
                std.process.exit(0);
            },
            CTRL_D => {
                if (line_buffer.items.len == 0) {
                    try out.writeByte('\n');
                    break;
                }
                if (line_buffer.items.len == col_offset) {
                    continue;
                }
                const edited_line = try temp.dupe(u8, line_buffer.items);
                try edit_stack.append(temp, edited_line);

                _ = line_buffer.orderedRemove(col_offset);

                try out.writeAll(line_buffer.items[col_offset..]);
                try out.writeByte(' ');
                try setCursorColumn(out, prompt.len + col_offset);
            },
            CTRL_E => {
                col_offset = line_buffer.items.len;
                try setCursorColumn(out, prompt.len + col_offset);
            },
            CTRL_F => {
                col_offset = @min(col_offset + 1, line_buffer.items.len);
                try setCursorColumn(out, prompt.len + col_offset);
            },
            CTRL_K => {
                const duped_buffer = try outlive.dupe(u8, line_buffer.items[col_offset..]);
                try copy_stack.append(outlive, duped_buffer);

                line_buffer.shrinkRetainingCapacity(col_offset);

                try clearFromCursorToLineEnd(out);
            },
            CTRL_L => {
                try clearEntireScreen(out);
                try setCursor(out, 0, 0);

                try out.writeAll(prompt);
                try out.writeAll(line_buffer.items);

                try setCursorColumn(out, prompt.len + col_offset);
            },
            CTRL_W => {
                const prev_col_offset = @min(col_offset + 1, line_buffer.items.len);
                if (col_offset == 0) continue;
                std.debug.assert(line_buffer.items.len > 0);

                if (std.ascii.isWhitespace(line_buffer.items[col_offset - 1])) {
                    while (col_offset > 0 and std.ascii.isWhitespace(line_buffer.items[col_offset - 1]))
                        col_offset -= 1;
                }
                while (col_offset > 0 and !std.ascii.isWhitespace(line_buffer.items[col_offset - 1])) {
                    col_offset -= 1;
                }

                const duped_buffer = try outlive.dupe(u8, line_buffer.items[col_offset..prev_col_offset]);
                try copy_stack.append(outlive, duped_buffer);

                try line_buffer.replaceRange(
                    temp,
                    col_offset,
                    line_buffer.items.len - prev_col_offset,
                    line_buffer.items[prev_col_offset..],
                );

                const new_len = line_buffer.items.len - (prev_col_offset - col_offset);
                line_buffer.shrinkRetainingCapacity(new_len);

                try setCursorColumn(out, prompt.len + col_offset);
                try clearFromCursorToLineEnd(out);
                try out.writeAll(line_buffer.items[col_offset..]);
                try setCursorColumn(out, prompt.len + col_offset);
            },
            CTRL_Y => {
                if (copy_stack.items.len == 0) continue;

                const copy = copy_stack.getLast();
                try line_buffer.insertSlice(temp, col_offset, copy);
                try out.writeAll(line_buffer.items[col_offset..]);
                col_offset += copy.len;
            },
            control_code.lf, control_code.cr => { // ENTER
                try out.writeByte('\n');
                try out.flush();
                break;
            },
            control_code.esc => {
                if (bytes_read == 1) continue;
                // if (bytes_read > 4) {
                //     const fmt = "Kitty protocol not supported: {s}";
                //     try log(outlive, fmt, .{in_buffer[2..8]}, prompt.len + col_offset);
                //     continue;
                // }

                const second_byte = in_buffer[1];
                if ('[' == second_byte) {
                    const third_byte = in_buffer[2];
                    switch (third_byte) {
                        UP_ARROW => {
                            if (!is_using_history or history_index == 0) {
                                continue;
                            }

                            if (history_index + 1 == history_entries.items.len) {
                                history_entries.items[history_index] =
                                    try temp.dupe(u8, line_buffer.items);
                            }
                            edit_stack.clearRetainingCapacity();

                            history_index -= 1;

                            line_buffer.clearRetainingCapacity();
                            try line_buffer.appendSlice(
                                temp,
                                history_entries.items[history_index],
                            );

                            try setCursorColumn(out, prompt.len);
                            try clearFromCursorToLineEnd(out);
                            try out.writeAll(line_buffer.items);
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
                                temp,
                                history_entries.items[history_index],
                            );

                            try setCursorColumn(out, prompt.len);
                            try clearFromCursorToLineEnd(out);
                            try out.writeAll(line_buffer.items);
                            col_offset = line_buffer.items.len;
                        },
                        RIGHT_ARROW => {
                            col_offset = @min(col_offset + 1, line_buffer.items.len);
                            try setCursorColumn(out, prompt.len + col_offset);
                        },
                        LEFT_ARROW => {
                            col_offset -|= 1;
                            try setCursorColumn(out, prompt.len + col_offset);
                        },
                        DEL => {
                            std.debug.assert('~' == in_buffer[3]);

                            if (line_buffer.items.len == col_offset) {
                                continue;
                            }

                            const edited_line = try temp.dupe(u8, line_buffer.items);
                            try edit_stack.append(temp, edited_line);

                            _ = line_buffer.orderedRemove(col_offset);
                            try clearFromCursorToLineEnd(out);
                            try out.writeAll(line_buffer.items[col_offset..]);
                            try setCursorColumn(out, prompt.len + col_offset);
                        },
                        else => {
                            const fmt = "Unhandled control byte: {d}";
                            try log(outlive, out, fmt, .{third_byte}, prompt.len + col_offset);
                        },
                    }
                } else {
                    // Meta
                    switch (second_byte) {
                        'f' => {
                            const len = line_buffer.items.len;
                            if (col_offset == len) continue;

                            const isAN = std.ascii.isAlphanumeric;
                            if (!isAN(line_buffer.items[col_offset])) {
                                while (col_offset < len and !isAN(line_buffer.items[col_offset])) {
                                    col_offset += 1;
                                }
                            }
                            while (col_offset < len and isAN(line_buffer.items[col_offset])) {
                                col_offset += 1;
                            }

                            try setCursorColumn(out, prompt.len + col_offset);
                        },
                        'b' => {
                            if (col_offset == 0) continue;
                            std.debug.assert(line_buffer.items.len > 0);

                            const isAN = std.ascii.isAlphabetic;
                            if (!isAN(line_buffer.items[col_offset - 1])) {
                                while (col_offset > 0 and
                                    !isAN(line_buffer.items[col_offset - 1]))
                                {
                                    col_offset -= 1;
                                }
                            }
                            while (col_offset > 0 and isAN(line_buffer.items[col_offset - 1])) {
                                col_offset -= 1;
                            }

                            try setCursorColumn(out, prompt.len + col_offset);
                        },
                        'd' => {
                            var word_offset = col_offset;
                            const len = line_buffer.items.len;
                            if (col_offset == len) continue;

                            const isAN = std.ascii.isAlphanumeric;
                            if (!isAN(line_buffer.items[word_offset])) {
                                while (word_offset < len and !isAN(line_buffer.items[word_offset])) {
                                    word_offset += 1;
                                }
                            }
                            while (word_offset < len and isAN(line_buffer.items[word_offset])) {
                                word_offset += 1;
                            }

                            const killed_text = try outlive.dupe(u8, line_buffer.items[col_offset..word_offset]);
                            try copy_stack.append(outlive, killed_text);

                            for (col_offset..word_offset) |i| {
                                line_buffer.items[i] = line_buffer.items[i + killed_text.len];
                            }

                            const new_len = line_buffer.items.len - (word_offset - col_offset);
                            line_buffer.shrinkRetainingCapacity(new_len);

                            try clearFromCursorToLineEnd(out);
                            try out.writeAll(line_buffer.items[col_offset..]);
                            try setCursorColumn(out, prompt.len + col_offset);
                        },
                        'y' => {
                            // TODO prevent if prior call is not ctrl y or meta y
                            const prev = copy_stack.pop().?;
                            try copy_stack.insert(outlive, 0, prev);

                            const next = copy_stack.getLast();

                            const prev_start_index = col_offset - prev.len;
                            for (0..prev.len) |_| {
                                _ = line_buffer.orderedRemove(prev_start_index);
                            }
                            try line_buffer.insertSlice(temp, prev_start_index, next);

                            col_offset = col_offset - prev.len + next.len;

                            try setCursorColumn(out, prompt.len);
                            try clearFromCursorToLineEnd(out);
                            try out.writeAll(line_buffer.items);
                            try setCursorColumn(out, prompt.len + col_offset);
                        },
                        control_code.del => {
                            const prev_col_offset = @min(col_offset + 1, line_buffer.items.len);
                            if (prev_col_offset == 0) continue;
                            std.debug.assert(line_buffer.items.len > 0);

                            const isAN = std.ascii.isAlphabetic;
                            if (!isAN(line_buffer.items[col_offset - 1])) {
                                while (col_offset > 0 and !isAN(line_buffer.items[col_offset - 1]))
                                    col_offset -= 1;
                            }
                            while (col_offset > 0 and isAN(line_buffer.items[col_offset - 1])) {
                                col_offset -= 1;
                            }

                            const copy = line_buffer.items[col_offset..prev_col_offset];
                            const duped_buffer = try outlive.dupe(u8, copy);
                            try copy_stack.append(outlive, duped_buffer);

                            try line_buffer.replaceRange(
                                outlive,
                                col_offset,
                                line_buffer.items.len - prev_col_offset,
                                line_buffer.items[prev_col_offset..],
                            );

                            const new_len = line_buffer.items.len - (prev_col_offset - col_offset);
                            line_buffer.shrinkRetainingCapacity(new_len);

                            try setCursorColumn(out, prompt.len + col_offset);
                            try clearFromCursorToLineEnd(out);
                            try out.writeAll(line_buffer.items[col_offset..]);
                            try setCursorColumn(out, prompt.len + col_offset);
                        },
                        else => {
                            const fmt = "Unhandled meta byte: {d}";
                            try log(outlive, out, fmt, .{second_byte}, prompt.len + col_offset);
                        },
                    }
                }
            },
            UNDERSCORE => {
                if (edit_stack.items.len == 0) {
                    continue;
                }

                line_buffer.clearRetainingCapacity();
                try line_buffer.appendSlice(temp, edit_stack.pop().?);

                col_offset = @min(col_offset, line_buffer.items.len);

                try setCursorColumn(out, prompt.len);
                try clearFromCursorToLineEnd(out);
                try out.writeAll(line_buffer.items);
                try setCursorColumn(out, prompt.len + col_offset);
            },
            ' '...'~' => |print_byte| {
                // If you are editting a line that was populated from history,
                // then you need to include a backstop for undo's
                const is_last_entry = history_index + 1 == history_entries.items.len;
                if (!is_last_entry and edit_stack.items.len == 0) {
                    const duped_finished_line = try temp.dupe(u8, line_buffer.items);
                    try edit_stack.append(temp, duped_finished_line);
                }

                try line_buffer.insert(temp, col_offset, print_byte);
                try out.writeAll(line_buffer.items[col_offset..]);

                col_offset += 1;
                try setCursorColumn(out, prompt.len + col_offset);
            },
            BACKSPACE => {
                if (col_offset == 0) {
                    continue;
                }
                const copied_line = try temp.dupe(u8, line_buffer.items);
                try edit_stack.append(temp, copied_line);

                col_offset -= 1;
                _ = line_buffer.orderedRemove(col_offset);

                try setCursorColumn(out, prompt.len + col_offset);
                try out.writeAll(line_buffer.items[col_offset..]);
                try out.writeByte(' ');
                try setCursorColumn(out, prompt.len + col_offset);
            },
            else => |unknown_byte| {
                const fmt = "Unhandled character: {d}";
                try log(outlive, out, fmt, .{unknown_byte}, prompt.len + col_offset);
            },
        }
    }

    return try outlive.dupe(u8, line_buffer.items);
}

pub fn free_copy(alloc: Allocator) void {
    for (copy_stack.items) |entry| {
        alloc.free(entry);
    }
    copy_stack.clearAndFree(alloc);
}

fn log(alloc: Allocator, out: *std.Io.Writer, comptime fmt: []const u8, args: anytype, prev_col: usize) !void {
    if (!(builtin.mode == .Debug)) return;

    const max_col = max_col: {
        try setCursorColumn(out, 999);
        try queryCursorPosition(out);
        try out.flush();

        var buffer: [32]u8 = undefined;
        var reader = std.fs.File.stdin().readerStreaming(&buffer);
        const input = try reader.interface.takeDelimiterExclusive('R');

        const semicolon_index = std.mem.indexOf(u8, input, ";").?;
        const position_slice = input[semicolon_index + 1 ..];
        break :max_col std.fmt.parseUnsigned(usize, position_slice, 10) catch unreachable;
    };

    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(msg);
    try setCursorColumn(out, max_col - msg.len);
    try out.writeAll(msg);
    try setCursorColumn(out, prev_col);
}

// History API

pub fn using_history() void {
    is_using_history = true;
}

pub fn add_history(alloc: Allocator, line: []const u8) AddHistoryError!void {
    const duped_line = try alloc.dupe(u8, line);
    try history_entries.append(alloc, duped_line);
}

pub fn write_history(alloc: Allocator, maybe_absolute_path: ?[]const u8) WriteHistoryError!void {
    defer {
        free_history(alloc);
        free_copy(alloc);
    }
    const file = if (maybe_absolute_path) |absolute_path|
        try std.fs.openFileAbsolute(absolute_path, std.fs.File.OpenFlags{ .mode = .write_only })
    else
        try openDefaultHistory(alloc);
    defer file.close();

    const all_entries = try std.mem.join(alloc, new_line, history_entries.items);
    defer alloc.free(all_entries);

    try file.writeAll(all_entries);
}

pub fn free_history(alloc: Allocator) void {
    for (history_entries.items) |entry| {
        alloc.free(entry);
    }
    history_entries.clearAndFree(alloc);
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

// Testing

test "Print characters" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");
    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
    }

    try std.testing.expectEqualStrings("asdf", line);
}

test "Move forward and backward" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");

    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});

    try inputStdin(fd, "d");
    try inputStdin(fd, "f");

    try inputStdin(fd, &.{CTRL_F});
    try inputStdin(fd, &.{CTRL_F});

    try inputStdin(fd, "g");
    try inputStdin(fd, "h");

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
    }

    try std.testing.expectEqualStrings("dfasgh", line);
}

test "Backspace" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");

    try inputStdin(fd, &.{BACKSPACE});
    try inputStdin(fd, &.{BACKSPACE});

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
    }

    try std.testing.expectEqualStrings("as", line);
}

test "Delete (key)" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");

    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});

    try inputStdin(fd, &.{ control_code.esc, '[', DEL, '~' });
    try inputStdin(fd, &.{ control_code.esc, '[', DEL, '~' });

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
    }

    try std.testing.expectEqualStrings("df", line);
}

test "Undo" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");

    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});

    try inputStdin(fd, &.{ control_code.esc, '[', DEL, '~' });

    try inputStdin(fd, &.{UNDERSCORE});

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
    }

    try std.testing.expectEqualStrings("asdf", line);
}

test "Move to start of line" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");

    try inputStdin(fd, &.{CTRL_A});

    try inputStdin(fd, "g");
    try inputStdin(fd, "h");
    try inputStdin(fd, "j");
    try inputStdin(fd, "k");

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
    }

    try std.testing.expectEqualStrings("ghjkasdf", line);
}

test "Move to end of line" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");

    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});

    try inputStdin(fd, &.{CTRL_E});

    try inputStdin(fd, "g");
    try inputStdin(fd, "h");
    try inputStdin(fd, "j");
    try inputStdin(fd, "k");

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
    }

    try std.testing.expectEqualStrings("asdfghjk", line);
}

test "Move forward a word" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");

    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});

    try inputStdin(fd, &.{ control_code.esc, 'f' });

    try inputStdin(fd, "g");
    try inputStdin(fd, "h");
    try inputStdin(fd, "j");
    try inputStdin(fd, "k");

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
    }

    try std.testing.expectEqualStrings("asdfghjk", line);
}

test "Move forward to non-alphanumeric" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");

    try inputStdin(fd, ";");
    try inputStdin(fd, "l");
    try inputStdin(fd, "k");
    try inputStdin(fd, "j");

    try inputStdin(fd, &.{CTRL_A});
    try inputStdin(fd, &.{ control_code.esc, 'f' });

    try inputStdin(fd, "q");
    try inputStdin(fd, "w");
    try inputStdin(fd, "e");
    try inputStdin(fd, "r");

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
    }

    try std.testing.expectEqualStrings("asdfqwer;lkj", line);
}

test "Move backward a word" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");

    try inputStdin(fd, &.{ control_code.esc, 'b' });

    try inputStdin(fd, "g");
    try inputStdin(fd, "h");
    try inputStdin(fd, "j");
    try inputStdin(fd, "k");

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
    }

    try std.testing.expectEqualStrings("ghjkasdf", line);
}

test "Move backward to non-alphanumeric" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");

    try inputStdin(fd, ";");
    try inputStdin(fd, "l");
    try inputStdin(fd, "k");
    try inputStdin(fd, "j");

    try inputStdin(fd, &.{ control_code.esc, 'b' });

    try inputStdin(fd, "q");
    try inputStdin(fd, "w");
    try inputStdin(fd, "e");
    try inputStdin(fd, "r");

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
    }

    try std.testing.expectEqualStrings("asdf;qwerlkj", line);
}

test "Clear line" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");

    try inputStdin(fd, &.{CTRL_L});

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
    }

    try std.testing.expectEqualStrings("asdf", line);
}

test "Kill text from cursor to end" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");
    try inputStdin(fd, ";");
    try inputStdin(fd, "l");
    try inputStdin(fd, "k");
    try inputStdin(fd, "j");

    try inputStdin(fd, &.{CTRL_A});

    try inputStdin(fd, &.{CTRL_K});

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
        free_copy(outlive);
    }

    try std.testing.expectEqualStrings("", line);
    try std.testing.expectEqualStrings(copy_stack.items[0], "asdf;lkj");
}

test "Kill text to end of word" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");
    try inputStdin(fd, ";");
    try inputStdin(fd, "l");
    try inputStdin(fd, "k");
    try inputStdin(fd, "j");

    try inputStdin(fd, &.{CTRL_A});

    try inputStdin(fd, &.{ control_code.esc, 'd' });

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
        free_copy(outlive);
    }

    try std.testing.expectEqualStrings(";lkj", line);
    try std.testing.expectEqualStrings(copy_stack.items[0], "asdf");
}

test "Kill text to end of word while surrounded" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, ".");
    try inputStdin(fd, ".");
    try inputStdin(fd, "1");
    try inputStdin(fd, ".");
    try inputStdin(fd, ".");

    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});

    try inputStdin(fd, &.{ control_code.esc, 'd' });

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
        free_copy(outlive);
    }

    try std.testing.expectEqualStrings("....", line);
    try std.testing.expectEqualStrings(copy_stack.items[0], "1");
}

test "Kill text to start of word" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");
    try inputStdin(fd, ";");
    try inputStdin(fd, "l");
    try inputStdin(fd, "k");
    try inputStdin(fd, "j");

    try inputStdin(fd, &.{ control_code.esc, control_code.del });

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
        free_copy(outlive);
    }

    try std.testing.expectEqualStrings("asdf;", line);
    try std.testing.expectEqualStrings(copy_stack.items[0], "lkj");
}

test "Kill text to previous whitespace" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");
    try inputStdin(fd, " ");
    try inputStdin(fd, "l");
    try inputStdin(fd, "k");
    try inputStdin(fd, "j");

    try inputStdin(fd, &.{CTRL_W});

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
        free_copy(outlive);
    }

    try std.testing.expectEqualStrings("asdf ", line);
    try std.testing.expectEqualStrings(copy_stack.items[0], "lkj");
}

test "Yank text" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "s");
    try inputStdin(fd, "d");
    try inputStdin(fd, "f");

    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});

    try inputStdin(fd, &.{CTRL_K});

    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_B});

    try inputStdin(fd, &.{CTRL_Y});

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
        free_copy(outlive);
    }

    try std.testing.expectEqualStrings("dfas", line);
    try std.testing.expectEqual(1, copy_stack.items.len);
}

test "Rotate kill-ring and yank text" {
    const outlive = std.testing.allocator;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    try inputStdin(fd, "a");
    try inputStdin(fd, "b");
    try inputStdin(fd, "c");

    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_K});

    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_K});

    try inputStdin(fd, &.{CTRL_B});
    try inputStdin(fd, &.{CTRL_K});

    try inputStdin(fd, &.{CTRL_Y});
    try inputStdin(fd, &.{ control_code.esc, 'y' });
    try inputStdin(fd, &.{CTRL_Y});

    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in);
    defer {
        outlive.free(line);
        free_history(outlive);
        free_copy(outlive);
    }

    try std.testing.expectEqualStrings("bb", line);
    try std.testing.expectEqual(3, copy_stack.items.len);
}

fn inputStdin(fd: c_int, input: []const u8) !void {
    var buffer: [8]u8 = undefined;
    std.mem.copyForwards(u8, &buffer, input);
    try std.testing.expect(-1 != unistd.write(fd, &buffer, 8));
}

// try log(allocator, out, "stdin: {d:0>3}, {d}, {d}, {d}, {d}, {d}, {d}, {d}", .{ stdin_buffer[0], stdin_buffer[1], stdin_buffer[2], stdin_buffer[3], stdin_buffer[4], stdin_buffer[5], stdin_buffer[6], stdin_buffer[7] }, prompt.len + col_offset);

const std = @import("std");
const control_code = std.ascii.control_code;
const Allocator = std.mem.Allocator;

const builtin = @import("builtin");

const Linux = @import("Linux.zig");
const MacOs = @import("MacOS.zig");
const Windows = @import("Windows.zig");
const FreeBSD = @import("FreeBSD.zig");

const unistd = @cImport(@cInclude("unistd.h"));
