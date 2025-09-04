# Anyline
Anyline is a line processing library intended to be a drop-in replacement for GNU Readline. Anyline leverages Zig's cross compilation toolchain to bring the library to not only Linux and MacOS, but also Windows.

## Development Status
Anyline is a work in progress. More features and platforms will be added. Keep an eye on the releases for more details. 

# Installation

## Build from source
Firstly, you need to [install Zig 0.15.1](https://ziglang.org/download/). 
Then, `zig build install` will produce a static library at `zig-out/lib` and a header file at `zig-out/include`.

## Add as a Zig dependency

First, update your `build.zig.zon`:

```
zig fetch --save https://github.com/c-shinkle/anyline/archive/refs/tags/0.1.0.tar.gz
```

Next, add this snippet to your `build.zig` script:

```zig
const anyline_dep = b.dependency("anyline", .{
    .target = target,
    .optimize = optimize,
});
your_module.addImport("anyline", anyline_dep);
```

## Supported platforms

| Operating System | Architecture | Terminal Emulator  | Shell        |
| ---------------- | ------------ | -------------------| ------------ |
| Windows 11       | x86_64       | Microsoft Terminal | PowerShell 7 |
| Linux            | x86_64       | Ghostty, GNOME     | Fish, Bash   |
| MacOS            | aarch64      | Ghostty            | Fish         |
