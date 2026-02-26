const std = @import("std");
const hp = @import("src/root.zig");

fn runCombo(alloc: std.mem.Allocator, file: []const u8, iters: usize, comptime opts: hp.ParseOptions, copy_each_iter: bool) !u64 {
    const input = try std.fs.cwd().readFileAlloc(alloc, file, std.math.maxInt(usize));
    defer alloc.free(input);

    var working_opt: ?[]u8 = null;
    if (copy_each_iter) working_opt = try alloc.alloc(u8, input.len);
    defer if (working_opt) |w| alloc.free(w);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        var doc = hp.Document.init(arena.allocator());
        defer doc.deinit();
        if (working_opt) |w| {
            @memcpy(w, input);
            try doc.parse(w, opts);
        } else {
            try doc.parse(input, opts);
        }
        _ = arena.reset(.retain_capacity);
    }
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.next();
    const file = args.next() orelse return error.InvalidArgs;
    const iters = try std.fmt.parseInt(usize, args.next() orelse return error.InvalidArgs, 10);
    const combo = try std.fmt.parseInt(u32, args.next() orelse return error.InvalidArgs, 10);

    const ns = switch (combo) {
        0 => try runCombo(alloc, file, iters, .{ .store_parent_pointers = false, .normalize_input = false, .normalize_text_on_parse = false, .eager_child_views = false, .eager_attr_empty_rewrite = false, .defer_attribute_parsing = true, .drop_whitespace_text_nodes = true }, false),
        1 => try runCombo(alloc, file, iters, .{ .store_parent_pointers = false, .normalize_input = true, .normalize_text_on_parse = false, .eager_child_views = false, .eager_attr_empty_rewrite = false, .defer_attribute_parsing = true, .drop_whitespace_text_nodes = true }, false),
        2 => try runCombo(alloc, file, iters, .{ .store_parent_pointers = false, .normalize_input = false, .normalize_text_on_parse = false, .eager_child_views = false, .eager_attr_empty_rewrite = false, .defer_attribute_parsing = true, .drop_whitespace_text_nodes = false }, false),
        3 => try runCombo(alloc, file, iters, .{ .store_parent_pointers = false, .normalize_input = true, .normalize_text_on_parse = false, .eager_child_views = false, .eager_attr_empty_rewrite = false, .defer_attribute_parsing = true, .drop_whitespace_text_nodes = false }, false),
        4 => try runCombo(alloc, file, iters, .{ .store_parent_pointers = true, .normalize_input = false, .normalize_text_on_parse = false, .eager_child_views = false, .eager_attr_empty_rewrite = false, .defer_attribute_parsing = true, .drop_whitespace_text_nodes = true }, false),
        5 => try runCombo(alloc, file, iters, .{ .store_parent_pointers = true, .normalize_input = true, .normalize_text_on_parse = false, .eager_child_views = false, .eager_attr_empty_rewrite = false, .defer_attribute_parsing = true, .drop_whitespace_text_nodes = true }, false),
        6 => try runCombo(alloc, file, iters, .{ .store_parent_pointers = false, .normalize_input = false, .normalize_text_on_parse = false, .eager_child_views = false, .eager_attr_empty_rewrite = false, .defer_attribute_parsing = false, .drop_whitespace_text_nodes = true }, false),
        100 => try runCombo(alloc, file, iters, .{ .store_parent_pointers = true, .normalize_input = true, .normalize_text_on_parse = true, .eager_child_views = true, .eager_attr_empty_rewrite = true, .defer_attribute_parsing = false, .drop_whitespace_text_nodes = false }, true),
        else => return error.InvalidArgs,
    };

    std.debug.print("{d}\n", .{ns});
}
