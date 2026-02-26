const std = @import("std");
const html = @import("htmlparser");

fn run() !void {
    const fixture =
        "<html><body>" ++
        "<ul><li class='item'>A</li><li class='item'>B</li></ul>" ++
        "</body></html>";

    var strictest_doc = html.Document.init(std.testing.allocator);
    defer strictest_doc.deinit();
    var strictest_buf = fixture.*;
    try strictest_doc.parse(&strictest_buf, .{
        .store_parent_pointers = true,
        .normalize_input = true,
        .normalize_text_on_parse = true,
        .eager_child_views = true,
        .eager_attr_empty_rewrite = true,
        .defer_attribute_parsing = false,
    });

    var fastest_doc = html.Document.init(std.testing.allocator);
    defer fastest_doc.deinit();
    var fastest_buf = fixture.*;
    try fastest_doc.parse(&fastest_buf, .{
        .store_parent_pointers = false,
        .normalize_input = false,
        .normalize_text_on_parse = false,
        .eager_child_views = false,
        .eager_attr_empty_rewrite = false,
        .defer_attribute_parsing = true,
    });

    const strictest_count = blk: {
        var it = strictest_doc.queryAll("li.item");
        var n: usize = 0;
        while (it.next() != null) n += 1;
        break :blk n;
    };
    const fastest_count = blk: {
        var it = fastest_doc.queryAll("li.item");
        var n: usize = 0;
        while (it.next() != null) n += 1;
        break :blk n;
    };

    try std.testing.expectEqual(strictest_count, fastest_count);
    try std.testing.expectEqual(@as(usize, 2), strictest_count);
}

test "strictest and fastest parse option bundles return equivalent query results" {
    try run();
}
