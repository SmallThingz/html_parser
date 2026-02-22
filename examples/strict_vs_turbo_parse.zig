const std = @import("std");
const html = @import("htmlparser");

fn run() !void {
    const fixture =
        "<html><body>" ++
        "<ul><li class='item'>A</li><li class='item'>B</li></ul>" ++
        "</body></html>";

    var strict_doc = html.Document.init(std.testing.allocator);
    defer strict_doc.deinit();
    var strict_buf = fixture.*;
    try strict_doc.parse(&strict_buf, .{ .turbo_parse = false });

    var turbo_doc = html.Document.init(std.testing.allocator);
    defer turbo_doc.deinit();
    var turbo_buf = fixture.*;
    try turbo_doc.parse(&turbo_buf, .{ .turbo_parse = true, .eager_child_views = false, .eager_attr_empty_rewrite = false });

    const strict_count = blk: {
        var it = strict_doc.queryAll("li.item");
        var n: usize = 0;
        while (it.next() != null) n += 1;
        break :blk n;
    };
    const turbo_count = blk: {
        var it = turbo_doc.queryAll("li.item");
        var n: usize = 0;
        while (it.next() != null) n += 1;
        break :blk n;
    };

    try std.testing.expectEqual(strict_count, turbo_count);
    try std.testing.expectEqual(@as(usize, 2), strict_count);
}

test "strict and turbo modes return equivalent query results" {
    try run();
}
