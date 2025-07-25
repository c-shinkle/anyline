original_output_mode: windows_c.DWORD,
original_input_mode: windows_c.DWORD,

pub fn init() !WindowsState {
    const h_out = std.io.getStdOut().handle;
    const h_in = std.io.getStdIn().handle;

    var original_output_mode: windows_c.DWORD = 0;
    var original_input_mode: windows_c.DWORD = 0;
    if (0 == windows_c.GetConsoleMode(h_out, &original_output_mode)) {
        return error.InvalidHandle;
    }
    if (0 == windows_c.GetConsoleMode(h_in, &original_input_mode)) {
        return error.InvalidHandle;
    }

    const requested_out_mode =
        original_output_mode |
        windows_zig.ENABLE_VIRTUAL_TERMINAL_PROCESSING |
        windows_zig.DISABLE_NEWLINE_AUTO_RETURN;
    if (0 == windows_c.SetConsoleMode(h_out, requested_out_mode)) {
        return error.SetConsoleModeFailure;
    }

    const ConsoleInputMode = packed struct(windows_c.DWORD) {
        ENABLE_PROCESSED_INPUT: bool, // 0x0001
        ENABLE_LINE_INPUT: bool, // 0x0002
        ENABLE_ECHO_INPUT: bool, // 0x0004
        ENABLE_WINDOW_INPUT: bool, // 0x0008
        ENABLE_MOUSE_INPUT: bool, // 0x0010
        ENABLE_INSERT_MODE: bool, // 0x0020
        ENABLE_QUICK_EDIT_MODE: bool, // 0x0040
        ENABLE_EXTENDED_FLAGS: bool, // 0x0080
        ENABLE_AUTO_POSITION: bool, // 0x0100
        ENABLE_VIRTUAL_TERMINAL_INPUT: bool, // 0x0200
        padding_bits: u22 = undefined,
    };

    var requested_in_mode: ConsoleInputMode = @bitCast(original_input_mode);
    requested_in_mode.ENABLE_PROCESSED_INPUT = false;
    requested_in_mode.ENABLE_LINE_INPUT = false;
    requested_in_mode.ENABLE_ECHO_INPUT = false;
    requested_in_mode.ENABLE_MOUSE_INPUT = false;
    requested_in_mode.ENABLE_QUICK_EDIT_MODE = false;
    requested_in_mode.ENABLE_VIRTUAL_TERMINAL_INPUT = true;

    if (0 == windows_c.SetConsoleMode(h_in, @bitCast(requested_in_mode))) {
        return error.SetConsoleModeFailure;
    }

    return WindowsState{
        .original_output_mode = original_output_mode,
        .original_input_mode = original_input_mode,
    };
}

pub fn deinit(state: WindowsState) void {
    const h_out = std.io.getStdOut().handle;
    const h_in = std.io.getStdIn().handle;

    _ = windows_c.SetConsoleMode(h_out, state.original_output_mode);
    _ = windows_c.SetConsoleMode(h_in, state.original_input_mode);
}

const std = @import("std");
const print = std.debug.print;
const WindowsState = @This();

const windows_zig = std.os.windows;
const windows_c = @cImport(@cInclude("windows.h"));
const HANDLE = windows_zig.HANDLE;
