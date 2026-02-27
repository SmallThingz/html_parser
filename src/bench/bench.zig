const std = @import("std");
const root = @import("htmlparser");
const default_options: root.ParseOptions = .{};
const Document = default_options.GetDocument();

const BenchMode = enum {
    strictest,
    fastest,
};

fn parseMode(arg: []const u8) !BenchMode {
    if (std.mem.eql(u8, arg, "strictest")) return .strictest;
    if (std.mem.eql(u8, arg, "fastest")) return .fastest;
    return error.InvalidBenchMode;
}

fn parseDocForBench(noalias doc: *Document, input: []u8, mode: BenchMode) !void {
    switch (mode) {
        .strictest => try doc.parse(input, .{
            .eager_child_views = true,
            .drop_whitespace_text_nodes = false,
        }),
        .fastest => try doc.parse(input, .{
            .eager_child_views = false,
            .drop_whitespace_text_nodes = true,
        }),
    }
}

pub fn runSynthetic() !void {
    const alloc = std.heap.page_allocator;

    var doc = Document.init(alloc);
    defer doc.deinit();

    var src = "<html><body><ul><li class='x'>1</li><li class='x'>2</li><li>3</li></ul></body></html>".*;

    const parse_start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        try doc.parse(&src, .{});
    }
    const parse_end = std.time.nanoTimestamp();

    const query_start = std.time.nanoTimestamp();
    i = 0;
    while (i < 100_000) : (i += 1) {
        _ = doc.queryOne("li.x");
    }
    const query_end = std.time.nanoTimestamp();

    std.debug.print("parse ns: {d}\n", .{parse_end - parse_start});
    std.debug.print("query ns: {d}\n", .{query_end - query_start});
}

pub fn runParseFile(path: []const u8, iterations: usize, mode: BenchMode) !u64 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const input = try std.fs.cwd().readFileAlloc(alloc, path, std.math.maxInt(usize));
    defer alloc.free(input);

    var working_opt: ?[]u8 = null;
    if (mode == .strictest) {
        working_opt = try alloc.alloc(u8, input.len);
    }
    defer if (working_opt) |working| alloc.free(working);

    var parse_arena = std.heap.ArenaAllocator.init(alloc);
    defer parse_arena.deinit();

    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const iter_alloc = parse_arena.allocator();
        {
            var doc = Document.init(iter_alloc);
            defer doc.deinit();
            if (working_opt) |working| {
                @memcpy(working, input);
                try parseDocForBench(&doc, working, mode);
            } else {
                try parseDocForBench(&doc, input, mode);
            }
        }
        _ = parse_arena.reset(.retain_capacity);
    }
    const end = std.time.nanoTimestamp();

    return @intCast(end - start);
}

pub fn runQueryParse(selector: []const u8, iterations: usize) !u64 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        _ = try root.Selector.compileRuntime(arena.allocator(), selector);
    }
    const end = std.time.nanoTimestamp();

    return @intCast(end - start);
}

pub fn runQueryMatch(path: []const u8, selector: []const u8, iterations: usize, mode: BenchMode) !u64 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const input = try std.fs.cwd().readFileAlloc(alloc, path, std.math.maxInt(usize));
    defer alloc.free(input);

    const working = try alloc.dupe(u8, input);
    defer alloc.free(working);

    var doc = Document.init(alloc);
    defer doc.deinit();
    try parseDocForBench(&doc, working, mode);

    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = doc.queryOneRuntime(selector) catch null;
    }
    const end = std.time.nanoTimestamp();

    return @intCast(end - start);
}

pub fn runQueryCached(path: []const u8, selector: []const u8, iterations: usize, mode: BenchMode) !u64 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const input = try std.fs.cwd().readFileAlloc(alloc, path, std.math.maxInt(usize));
    defer alloc.free(input);

    const working = try alloc.dupe(u8, input);
    defer alloc.free(working);

    var sel_arena = std.heap.ArenaAllocator.init(alloc);
    defer sel_arena.deinit();

    const sel = try root.Selector.compileRuntime(sel_arena.allocator(), selector);

    var doc = Document.init(alloc);
    defer doc.deinit();
    try parseDocForBench(&doc, working, mode);

    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = doc.queryOneCached(&sel);
    }
    const end = std.time.nanoTimestamp();

    return @intCast(end - start);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len == 1) {
        try runSynthetic();
        return;
    }

    if (args.len == 4 and std.mem.eql(u8, args[1], "query-parse")) {
        const iterations = try std.fmt.parseInt(usize, args[3], 10);
        const total_ns = try runQueryParse(args[2], iterations);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len == 5 and std.mem.eql(u8, args[1], "query-match")) {
        const iterations = try std.fmt.parseInt(usize, args[4], 10);
        const total_ns = try runQueryMatch(args[2], args[3], iterations, .fastest);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len == 6 and std.mem.eql(u8, args[1], "query-match")) {
        const mode = try parseMode(args[2]);
        const iterations = try std.fmt.parseInt(usize, args[5], 10);
        const total_ns = try runQueryMatch(args[3], args[4], iterations, mode);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len == 5 and std.mem.eql(u8, args[1], "query-cached")) {
        const iterations = try std.fmt.parseInt(usize, args[4], 10);
        const total_ns = try runQueryCached(args[2], args[3], iterations, .fastest);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len == 6 and std.mem.eql(u8, args[1], "query-cached")) {
        const mode = try parseMode(args[2]);
        const iterations = try std.fmt.parseInt(usize, args[5], 10);
        const total_ns = try runQueryCached(args[3], args[4], iterations, mode);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len == 5 and std.mem.eql(u8, args[1], "parse")) {
        const mode = try parseMode(args[2]);
        const iterations = try std.fmt.parseInt(usize, args[4], 10);
        const total_ns = try runParseFile(args[3], iterations, mode);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len != 3) {
        std.debug.print(
            "usage:\n  {s} <html-file> <iterations>\n  {s} parse <strictest|fastest> <html-file> <iterations>\n  {s} query-parse <selector> <iterations>\n  {s} query-match <html-file> <selector> <iterations>\n  {s} query-match <strictest|fastest> <html-file> <selector> <iterations>\n  {s} query-cached <html-file> <selector> <iterations>\n  {s} query-cached <strictest|fastest> <html-file> <selector> <iterations>\n",
            .{ args[0], args[0], args[0], args[0], args[0], args[0], args[0] },
        );
        std.process.exit(2);
    }

    const iterations = try std.fmt.parseInt(usize, args[2], 10);
    const total_ns = try runParseFile(args[1], iterations, .fastest);
    std.debug.print("{d}\n", .{total_ns});
}
