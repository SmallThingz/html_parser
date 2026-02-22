const std = @import("std");

pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn ensureDir(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

pub fn joinArgs(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "+ ");
    for (argv, 0..) |arg, i| {
        if (i != 0) try out.append(alloc, ' ');
        if (std.mem.indexOfScalar(u8, arg, ' ') != null) {
            try out.append(alloc, '"');
            try out.appendSlice(alloc, arg);
            try out.append(alloc, '"');
        } else {
            try out.appendSlice(alloc, arg);
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn runInherit(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !void {
    const pretty = try joinArgs(alloc, argv);
    defer alloc.free(pretty);
    std.debug.print("{s}\n", .{pretty});

    var child = std.process.Child.init(argv, alloc);
    child.cwd = cwd;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.ChildProcessFailed,
        else => return error.ChildProcessFailed,
    }
}

pub fn runCaptureCombined(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) ![]u8 {
    const res = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .cwd = cwd,
    });
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);

    switch (res.term) {
        .Exited => |code| if (code != 0) return error.ChildProcessFailed,
        else => return error.ChildProcessFailed,
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, res.stdout);
    if (res.stderr.len != 0) {
        if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
        try out.appendSlice(alloc, res.stderr);
    }
    return out.toOwnedSlice(alloc);
}

pub fn runCaptureStdout(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) ![]u8 {
    const res = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .cwd = cwd,
    });
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);

    switch (res.term) {
        .Exited => |code| if (code != 0) return error.ChildProcessFailed,
        else => return error.ChildProcessFailed,
    }
    return alloc.dupe(u8, std.mem.trim(u8, res.stdout, " \r\n\t"));
}

pub fn parseLastInt(text: []const u8) !u64 {
    var i: usize = text.len;
    while (i > 0) : (i -= 1) {
        const c = text[i - 1];
        if (c >= '0' and c <= '9') break;
    }
    if (i == 0) return error.NoIntegerFound;
    var start = i - 1;
    while (start > 0 and text[start - 1] >= '0' and text[start - 1] <= '9') : (start -= 1) {}
    return std.fmt.parseInt(u64, text[start..i], 10);
}

pub fn medianU64(alloc: std.mem.Allocator, vals: []const u64) !u64 {
    if (vals.len == 0) return error.EmptyInput;
    const copy = try alloc.dupe(u64, vals);
    defer alloc.free(copy);
    std.mem.sort(u64, copy, {}, std.sort.asc(u64));
    return copy[copy.len / 2];
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

pub fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(alloc, path, std.math.maxInt(usize));
}

pub fn nowUnix() i64 {
    return std.time.timestamp();
}
