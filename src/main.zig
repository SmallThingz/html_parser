const std = @import("std");
const htmlparser = @import("htmlparser");

pub fn main() !void {
    try htmlparser.bufferedPrint();

    var doc = htmlparser.Document.init(std.heap.page_allocator);
    defer doc.deinit();

    var src = "<html><body><h1 id='t'>Hi &amp; there</h1></body></html>".*;
    try doc.parse(&src, .{});

    if (doc.queryOne("h1#t")) |h1| {
        const txt = try h1.innerText(std.heap.page_allocator);
        std.debug.print("h1 text: {s}\n", .{txt});
    }
}
