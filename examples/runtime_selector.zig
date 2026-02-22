const std = @import("std");
const html = @import("htmlparser");

fn run() !void {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div><a class='primary' href='/x'></a><a class='secondary' href='/y'></a></div>".*;
    try doc.parse(&input, .{});

    const one = try doc.queryOneRuntime("a.primary");
    try std.testing.expect(one != null);

    var it = try doc.queryAllRuntime("a[href]");
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() == null);
}

test "runtime selector APIs" {
    try run();
}
