# Anyline
Anyline is a line processing library intended to be a drop-in replacement for GNU Readline. Anyline leverages Zig's cross compilation toolchain to bring the library to not only Linux and MacOS, but also Windows.

# Installation

## Build from source
Firstly, you need to [install Zig](https://ziglang.org/download/). 
Then, `zig build install` will produce a static library at `zig-out/lib`.

# Add as dependency

First, update your `build.zig.zon`:

```
zig fetch --save https://github.com/c-shinkle/anyline.git
```

Next, add this snippet to your `build.zig` script:

```zig
const anyline_dep = b.dependency("anyline", .{
    .target = target,
    .optimize = optimize,
});
your_module.addImport("anyline", anyline_dep);
```

This will provide a editline as a static library to `your_compilation`.1
