old_termios: termios.termios,

pub const Error = error{TerminosFailure} || std.Io.Writer.Error;

pub fn init() Error!Linux {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const stdin_handle = std.fs.File.stdin().handle;

    var old_termios: termios.termios = undefined;
    if (termios.tcgetattr(stdin_handle, &old_termios) < 0) {
        const errno_val = std.c._errno().*;
        const errno_string = string.strerror(errno_val);
        try stderr.print("{s}\n", .{errno_string});
        return error.TerminosFailure;
    }

    var new_lflag: TermiosLocalMode = @bitCast(old_termios.c_lflag);
    new_lflag.ICANON = false;
    new_lflag.ECHO = false;

    var new_termios = old_termios;
    new_termios.c_lflag = @bitCast(new_lflag);

    if (termios.tcsetattr(stdin_handle, termios.TCSANOW, &new_termios) < 0) {
        const errno_val = std.c._errno().*;
        const errno_string = string.strerror(errno_val);
        try stderr.print("{s}\n", .{errno_string});
        return error.TerminosFailure;
    }

    return Linux{ .old_termios = old_termios };
}

pub fn deinit(linux: Linux) void {
    const stdin_handle = std.fs.File.stdin().handle;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    if (termios.tcsetattr(stdin_handle, termios.TCSANOW, &linux.old_termios) < 0) {
        const errno_val = std.c._errno().*;
        const errno_string = string.strerror(errno_val);
        stderr.print("{s}\n", .{errno_string}) catch {};
    }
}

const TermiosLocalMode = packed struct(termios.tcflag_t) {
    ISIG: bool, //0o000001
    ICANON: bool, //0o000002
    _2: u1,
    ECHO: bool, //0o000010
    ECHOE: bool, //0o000020
    ECHOK: bool, //0o000040
    ECHONL: bool, //0o000100
    NOFLSH: bool, //0o000200
    TOSTOP: bool, //0o000400
    _9_14: u6,
    IEXTEN: bool, //0o100000
    _16_31: u16,
};

const Linux = @This();
const std = @import("std");
const string = @cImport(@cInclude("string.h"));
const termios = @cImport(@cInclude("termios.h"));
