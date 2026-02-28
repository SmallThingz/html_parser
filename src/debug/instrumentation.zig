const std = @import("std");
const ast = @import("../selector/ast.zig");
const ParseOptions = @import("../html/document.zig").ParseOptions;

/// Query operation kind passed to instrumentation hooks.
pub const QueryInstrumentationKind = enum(u8) {
    one_runtime,
    one_cached,
    all_runtime,
    all_cached,
};

/// Timing/count payload emitted after `parseWithHooks`.
pub const ParseInstrumentationStats = struct {
    elapsed_ns: u64,
    input_len: usize,
    node_count: usize,
};

/// Timing payload emitted after query hook wrappers.
pub const QueryInstrumentationStats = struct {
    elapsed_ns: u64,
    selector_len: usize,
    kind: QueryInstrumentationKind,
    matched: ?bool = null,
};

fn elapsedNs(start: i128, finish: i128) u64 {
    if (finish <= start) return 0;
    return @intCast(finish - start);
}

fn HookDeclType(comptime H: type) type {
    return switch (@typeInfo(H)) {
        .pointer => |p| p.child,
        else => H,
    };
}

fn matchedFromValue(value: anytype) ?bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => value != null,
        else => true,
    };
}

/// Parses `input` and invokes optional parse hooks when provided.
pub fn parseWithHooks(doc: anytype, input: []u8, comptime opts: ParseOptions, hooks: anytype) !void {
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onParseStart")) {
        hooks.onParseStart(input.len);
    }

    const start = std.time.nanoTimestamp();
    try doc.parse(input, opts);
    const stats: ParseInstrumentationStats = .{
        .elapsed_ns = elapsedNs(start, std.time.nanoTimestamp()),
        .input_len = input.len,
        .node_count = doc.nodes.items.len,
    };

    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onParseEnd")) {
        hooks.onParseEnd(stats);
    }
}

/// Executes `queryOneRuntime` and emits query timing hooks.
pub fn queryOneRuntimeWithHooks(doc: anytype, selector: []const u8, hooks: anytype) @TypeOf(doc.queryOneRuntime(selector)) {
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryStart")) {
        hooks.onQueryStart(.one_runtime, selector.len);
    }

    const start = std.time.nanoTimestamp();
    const out = doc.queryOneRuntime(selector);
    if (out) |value| {
        if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
            hooks.onQueryEnd(QueryInstrumentationStats{
                .elapsed_ns = elapsedNs(start, std.time.nanoTimestamp()),
                .selector_len = selector.len,
                .kind = .one_runtime,
                .matched = matchedFromValue(value),
            });
        }
        return value;
    } else |err| {
        if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
            hooks.onQueryEnd(QueryInstrumentationStats{
                .elapsed_ns = elapsedNs(start, std.time.nanoTimestamp()),
                .selector_len = selector.len,
                .kind = .one_runtime,
                .matched = null,
            });
        }
        return err;
    }
}

/// Executes `queryOneCached` and emits query timing hooks.
pub fn queryOneCachedWithHooks(doc: anytype, sel: *const ast.Selector, hooks: anytype) @TypeOf(doc.queryOneCached(sel)) {
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryStart")) {
        hooks.onQueryStart(.one_cached, sel.source.len);
    }

    const start = std.time.nanoTimestamp();
    const value = doc.queryOneCached(sel);
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
        hooks.onQueryEnd(QueryInstrumentationStats{
            .elapsed_ns = elapsedNs(start, std.time.nanoTimestamp()),
            .selector_len = sel.source.len,
            .kind = .one_cached,
            .matched = matchedFromValue(value),
        });
    }
    return value;
}

/// Executes `queryAllRuntime` and emits query timing hooks.
pub fn queryAllRuntimeWithHooks(doc: anytype, selector: []const u8, hooks: anytype) @TypeOf(doc.queryAllRuntime(selector)) {
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryStart")) {
        hooks.onQueryStart(.all_runtime, selector.len);
    }

    const start = std.time.nanoTimestamp();
    const out = doc.queryAllRuntime(selector);
    if (out) |iter| {
        if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
            hooks.onQueryEnd(QueryInstrumentationStats{
                .elapsed_ns = elapsedNs(start, std.time.nanoTimestamp()),
                .selector_len = selector.len,
                .kind = .all_runtime,
                .matched = null,
            });
        }
        return iter;
    } else |err| {
        if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
            hooks.onQueryEnd(QueryInstrumentationStats{
                .elapsed_ns = elapsedNs(start, std.time.nanoTimestamp()),
                .selector_len = selector.len,
                .kind = .all_runtime,
                .matched = null,
            });
        }
        return err;
    }
}

/// Executes `queryAllCached` and emits query timing hooks.
pub fn queryAllCachedWithHooks(doc: anytype, sel: *const ast.Selector, hooks: anytype) @TypeOf(doc.queryAllCached(sel)) {
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryStart")) {
        hooks.onQueryStart(.all_cached, sel.source.len);
    }

    const start = std.time.nanoTimestamp();
    const iter = doc.queryAllCached(sel);
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
        hooks.onQueryEnd(QueryInstrumentationStats{
            .elapsed_ns = elapsedNs(start, std.time.nanoTimestamp()),
            .selector_len = sel.source.len,
            .kind = .all_cached,
            .matched = null,
        });
    }
    return iter;
}
