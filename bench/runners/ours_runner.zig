const std = @import("std");
const htmlparser = @import("htmlparser");
const default_options: htmlparser.ParseOptions = .{};
const Document = default_options.GetDocument();

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len != 3) {
        std.debug.print("usage: {s} <html-file> <iterations>\n", .{args[0]});
        std.process.exit(2);
    }

    const path = args[1];
    const iterations = try std.fmt.parseInt(usize, args[2], 10);

    const input = try std.fs.cwd().readFileAlloc(alloc, path, std.math.maxInt(usize));
    defer alloc.free(input);

    var working = try alloc.alloc(u8, input.len);
    defer alloc.free(working);

    var doc = Document.init(alloc);
    defer doc.deinit();

    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        @memcpy(working, input);
        try doc.parse(working, .{});
    }
    const end = std.time.nanoTimestamp();

    const total_ns: u64 = @intCast(end - start);
    std.debug.print("{d}\n", .{total_ns});
}
