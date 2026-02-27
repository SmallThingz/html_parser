const std = @import("std");

pub const ParseOptions = @import("html/document.zig").ParseOptions;
pub const TextOptions = @import("html/document.zig").TextOptions;
pub const Selector = @import("selector/ast.zig").Selector;
pub const QueryDebugReport = @import("debug/selector_debug.zig").QueryDebugReport;
pub const DebugFailureKind = @import("debug/selector_debug.zig").DebugFailureKind;
pub const NearMiss = @import("debug/selector_debug.zig").NearMiss;
pub const ParseInstrumentationStats = @import("debug/instrumentation.zig").ParseInstrumentationStats;
pub const QueryInstrumentationStats = @import("debug/instrumentation.zig").QueryInstrumentationStats;
pub const QueryInstrumentationKind = @import("debug/instrumentation.zig").QueryInstrumentationKind;
pub const parseWithHooks = @import("debug/instrumentation.zig").parseWithHooks;
pub const queryOneRuntimeWithHooks = @import("debug/instrumentation.zig").queryOneRuntimeWithHooks;
pub const queryOneCachedWithHooks = @import("debug/instrumentation.zig").queryOneCachedWithHooks;
pub const queryAllRuntimeWithHooks = @import("debug/instrumentation.zig").queryAllRuntimeWithHooks;
pub const queryAllCachedWithHooks = @import("debug/instrumentation.zig").queryAllCachedWithHooks;

pub fn GetDocument(comptime options: ParseOptions) type {
    return options.GetDocument();
}

pub fn GetNode(comptime options: ParseOptions) type {
    return options.GetNode();
}

pub fn GetNodeRaw(comptime options: ParseOptions) type {
    return options.GetNodeRaw();
}

pub fn GetQueryIter(comptime options: ParseOptions) type {
    return options.QueryIter();
}

pub fn bufferedPrint() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("htmlparser: run `zig build test`\n", .{});
    try stdout.flush();
}

test "smoke parse/query" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    const Document = opts.GetDocument();

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

test {
    _ = @import("examples_tests.zig");
    _ = @import("behavioral_tests.zig");
}
