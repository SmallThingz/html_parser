const std = @import("std");
const html = @import("htmlparser");

fn run() !void {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='x'> Hello\n  <span>world</span> &amp;\tteam </div>".*;
    try doc.parse(&input, .{});

    const node = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;

    var arena_normalized = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_normalized.deinit();
    const normalized = try node.innerText(arena_normalized.allocator());
    try std.testing.expectEqualStrings("Hello world & team", normalized);

    var arena_raw = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_raw.deinit();
    const raw = try node.innerTextWithOptions(arena_raw.allocator(), .{ .normalize_whitespace = false });
    try std.testing.expect(std.mem.indexOfScalar(u8, raw, '\n') != null);
}

test "innerText whitespace options" {
    try run();
}
