old: termios.termios,

pub fn init() !Linux {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const stdin_handle = std.fs.File.stdin().handle;

    var old: termios.termios = undefined;
    if (termios.tcgetattr(stdin_handle, &old) < 0) {
        const errno_val = std.c._errno().*;
        const errno_string = string.strerror(errno_val);
        try stderr.print("{s}\n", .{errno_string});
        return error.TerminosFailure;
    }

    var new = old;
    const ICANON = @as(c_uint, termios.ICANON);
    const ECHO = @as(c_uint, termios.ECHO);
    new.c_lflag &= ~(ICANON | ECHO);
    if (termios.tcsetattr(stdin_handle, termios.TCSANOW, &new) < 0) {
        const errno_val = std.c._errno().*;
        const errno_string = string.strerror(errno_val);
        try stderr.print("{s}\n", .{errno_string});
        return error.TerminosFailure;
    }

    return Linux{
        .old = old,
    };
}

pub fn deinit(linux: Linux) void {
    const stdin_handle = std.fs.File.stdin().handle;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    if (termios.tcsetattr(stdin_handle, termios.TCSANOW, &linux.old) < 0) {
        const errno_val = std.c._errno().*;
        const errno_string = string.strerror(errno_val);
        stderr.print("{s}\n", .{errno_string}) catch {};
    }
}

const Linux = @This();
const std = @import("std");
const string = @cImport(@cInclude("string.h"));
const termios = @cImport(@cInclude("termios.h"));
