const std = @import("std");
const html = @import("htmlparser");

fn run() !void {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    const input =
        "<div>" ++
        "<a id='a1' class='button nav' href='https://one'></a>" ++
        "<a id='a2' class='nav' href='https://two'></a>" ++
        "</div>";

    var buf = input.*;
    try doc.parse(&buf, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sel = try html.Selector.compileRuntime(arena.allocator(), "a[href^=https][class~=button]");
    const first = doc.queryOneCompiled(&sel) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a1", first.getAttributeValue("id").?);
}

test "compiled runtime selector reuse" {
    try run();
}
