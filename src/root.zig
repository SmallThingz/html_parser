const std = @import("std");

pub const Document = @import("html/document.zig").Document;
pub const Node = @import("html/document.zig").Node;
pub const ParseOptions = @import("html/document.zig").ParseOptions;
pub const TextOptions = @import("html/document.zig").TextOptions;
pub const Selector = @import("selector/ast.zig").Selector;

pub fn bufferedPrint() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("htmlparser: run `zig build test`\n", .{});
    try stdout.flush();
}

test "smoke parse/query" {
    const alloc = std.testing.allocator;

    var doc = Document.init(alloc);
    defer doc.deinit();

    var src = "<div id='a'><span class='k'>v</span></div>".*;
    try doc.parse(&src, .{});

    try std.testing.expect(doc.queryOne("div#a") != null);
    try std.testing.expect((try doc.queryOneRuntime("span")) != null);
    const span = (try doc.queryOneRuntime("span.k")) orelse return error.TestUnexpectedResult;
    const parent = span.parentNode() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div", parent.tagName());
    try std.testing.expect(doc.queryOne("div > span.k") != null);
}
