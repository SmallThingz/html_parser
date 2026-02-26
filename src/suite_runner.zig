const std = @import("std");
const html = @import("root.zig");

const ParseMode = enum {
    strictest,
    fastest,
};

fn parseMode(s: []const u8) ?ParseMode {
    if (std.mem.eql(u8, s, "strictest") or std.mem.eql(u8, s, "strict")) return .strictest;
    if (std.mem.eql(u8, s, "fastest") or std.mem.eql(u8, s, "turbo")) return .fastest;
    return null;
}

fn parseDoc(noalias doc: *html.Document, input: []u8, mode: ParseMode) !void {
    switch (mode) {
        .strictest => try doc.parse(input, .{
            .store_parent_pointers = true,
            .normalize_input = true,
            .normalize_text_on_parse = true,
            .eager_child_views = true,
            .eager_attr_empty_rewrite = true,
            .defer_attribute_parsing = false,
        }),
        .fastest => try doc.parse(input, .{
            .store_parent_pointers = false,
            .normalize_input = false,
            .normalize_text_on_parse = false,
            .eager_child_views = false,
            .eager_attr_empty_rewrite = false,
            .defer_attribute_parsing = true,
        }),
    }
}

fn jsonEscape(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{X:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn printJsonStringArray(writer: anytype, items: []const []const u8) !void {
    try writer.writeByte('[');
    for (items, 0..) |it, i| {
        if (i != 0) try writer.writeByte(',');
        try jsonEscape(writer, it);
    }
    try writer.writeByte(']');
}

fn runSelectorIds(alloc: std.mem.Allocator, mode: ParseMode, fixture_path: []const u8, selector: []const u8) !void {
    const input = try std.fs.cwd().readFileAlloc(alloc, fixture_path, std.math.maxInt(usize));
    defer alloc.free(input);

    const working = try alloc.dupe(u8, input);
    defer alloc.free(working);

    var doc = html.Document.init(alloc);
    defer doc.deinit();
    try parseDoc(&doc, working, mode);

    var out_ids = std.ArrayList([]const u8).empty;
    defer out_ids.deinit(alloc);

    var it = try doc.queryAllRuntime(selector);
    while (it.next()) |node| {
        if (node.getAttributeValue("id")) |id| {
            try out_ids.append(alloc, id);
        }
    }

    var out_buf = std.ArrayList(u8).empty;
    defer out_buf.deinit(alloc);
    try printJsonStringArray(out_buf.writer(alloc), out_ids.items);
    try out_buf.append(alloc, '\n');
    try std.fs.File.stdout().writeAll(out_buf.items);
}

fn runSelectorCount(alloc: std.mem.Allocator, mode: ParseMode, fixture_path: []const u8, selector: []const u8) !void {
    const input = try std.fs.cwd().readFileAlloc(alloc, fixture_path, std.math.maxInt(usize));
    defer alloc.free(input);

    const working = try alloc.dupe(u8, input);
    defer alloc.free(working);

    var doc = html.Document.init(alloc);
    defer doc.deinit();
    try parseDoc(&doc, working, mode);

    var count: usize = 0;
    var it = try doc.queryAllRuntime(selector);
    while (it.next()) |_| {
        count += 1;
    }

    var out_buf = std.ArrayList(u8).empty;
    defer out_buf.deinit(alloc);
    try out_buf.writer(alloc).print("{d}\n", .{count});
    try std.fs.File.stdout().writeAll(out_buf.items);
}

fn runSelectorCountScopeTag(alloc: std.mem.Allocator, mode: ParseMode, fixture_path: []const u8, scope_tag: []const u8, selector: []const u8) !void {
    const input = try std.fs.cwd().readFileAlloc(alloc, fixture_path, std.math.maxInt(usize));
    defer alloc.free(input);

    const working = try alloc.dupe(u8, input);
    defer alloc.free(working);

    var doc = html.Document.init(alloc);
    defer doc.deinit();
    try parseDoc(&doc, working, mode);

    var count: usize = 0;
    if (doc.findFirstTag(scope_tag)) |scope| {
        var it = try scope.queryAllRuntime(selector);
        while (it.next()) |_| {
            count += 1;
        }
    }

    var out_buf = std.ArrayList(u8).empty;
    defer out_buf.deinit(alloc);
    try out_buf.writer(alloc).print("{d}\n", .{count});
    try std.fs.File.stdout().writeAll(out_buf.items);
}

fn runParseTagsFile(alloc: std.mem.Allocator, mode: ParseMode, fixture_path: []const u8) !void {
    const input = try std.fs.cwd().readFileAlloc(alloc, fixture_path, std.math.maxInt(usize));
    defer alloc.free(input);

    const working = try alloc.dupe(u8, input);
    defer alloc.free(working);

    var doc = html.Document.init(alloc);
    defer doc.deinit();
    try parseDoc(&doc, working, mode);

    var tags = std.ArrayList([]const u8).empty;
    defer tags.deinit(alloc);

    for (doc.nodes.items) |*n| {
        if (n.kind != .element) continue;
        try tags.append(alloc, n.name.slice(doc.source));
    }

    var out_buf = std.ArrayList(u8).empty;
    defer out_buf.deinit(alloc);
    try printJsonStringArray(out_buf.writer(alloc), tags.items);
    try out_buf.append(alloc, '\n');
    try std.fs.File.stdout().writeAll(out_buf.items);
}

fn usage() noreturn {
    std.debug.print(
        "usage:\n  suite_runner selector-ids <strictest|fastest> <fixture.html> <selector>\n  suite_runner selector-count <strictest|fastest> <fixture.html> <selector>\n  suite_runner selector-count-scope-tag <strictest|fastest> <fixture.html> <scope-tag> <selector>\n  suite_runner parse-tags-file <strictest|fastest> <fixture.html>\n",
        .{},
    );
    std.process.exit(2);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) usage();

    if (std.mem.eql(u8, args[1], "selector-ids")) {
        if (args.len != 5) usage();
        const mode = parseMode(args[2]) orelse usage();
        try runSelectorIds(alloc, mode, args[3], args[4]);
        return;
    }

    if (std.mem.eql(u8, args[1], "selector-count")) {
        if (args.len != 5) usage();
        const mode = parseMode(args[2]) orelse usage();
        try runSelectorCount(alloc, mode, args[3], args[4]);
        return;
    }

    if (std.mem.eql(u8, args[1], "selector-count-scope-tag")) {
        if (args.len != 6) usage();
        const mode = parseMode(args[2]) orelse usage();
        try runSelectorCountScopeTag(alloc, mode, args[3], args[4], args[5]);
        return;
    }

    if (std.mem.eql(u8, args[1], "parse-tags-file")) {
        if (args.len != 4) usage();
        const mode = parseMode(args[2]) orelse usage();
        try runParseTagsFile(alloc, mode, args[3]);
        return;
    }

    usage();
}
