old_termios: termios.termios,

pub const Error = error{TerminosFailure} || std.Io.Writer.Error;

pub fn init() Error!MacOS {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stdin_handle = std.fs.File.stdin().handle;

    var old_termios: termios.termios = undefined;
    if (termios.tcgetattr(stdin_handle, &old_termios) < 0) {
        const errno_val = std.c._errno().*;
        const errno_string = string.strerror(errno_val);
        try stderr_writer.interface.print("{s}\n", .{errno_string});
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
        try stderr_writer.interface.print("{s}\n", .{errno_string});
        return error.TerminosFailure;
    }

    return MacOS{ .old_termios = old_termios };
}

pub fn deinit(macos: MacOS) void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stdin_handle = std.fs.File.stdin().handle;

    if (termios.tcsetattr(stdin_handle, termios.TCSANOW, &macos.old_termios) < 0) {
        const errno_val = std.c._errno().*;
        const errno_string = string.strerror(errno_val);
        stderr_writer.interface.print("{s}\n", .{errno_string}) catch {};
    }
}

const TermiosLocalMode = packed struct(termios.tcflag_t) {
    ECHOKE: bool, // 0x00000001
    ECHOE: bool, // 0x00000002
    ECHOK: bool, // 0x00000004
    ECHO: bool, // 0x00000008
    ECHONL: bool, // 0x00000010
    ECHOPRT: bool, // 0x00000020
    ECHOCTL: bool, // 0x00000040
    ISIG: bool, // 0x00000080
    ICANON: bool, // 0x00000100
    ALTWERASE: bool, // 0x00000200
    IEXTEN: bool, // 0x00000400
    EXTPROC: bool, // 0x00000800
    _12: u10,
    TOSTOP: bool, // 0x00400000
    FLUSHO: bool, // 0x00800000
    _24: u1,
    NOKERNINFO: bool, // 0x02000000
    _26: u3,
    PENDIN: bool, // 0x20000000
    _30: u1,
    NOFLSH: bool, // 0x80000000
    _: u32,
};

const MacOS = @This();
const std = @import("std");
const string = @cImport(@cInclude("string.h"));
const termios = @cImport(@cInclude("termios.h"));
