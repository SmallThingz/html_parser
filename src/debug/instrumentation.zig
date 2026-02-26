const std = @import("std");
const ast = @import("../selector/ast.zig");
const ParseOptions = @import("../html/document.zig").ParseOptions;

pub const QueryInstrumentationKind = enum(u8) {
    one_runtime,
    one_compiled,
    all_runtime,
    all_compiled,
};

pub const ParseInstrumentationStats = struct {
    elapsed_ns: u64,
    input_len: usize,
    node_count: usize,
};

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

pub fn queryOneCompiledWithHooks(doc: anytype, sel: *const ast.Selector, hooks: anytype) @TypeOf(doc.queryOneCompiled(sel)) {
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryStart")) {
        hooks.onQueryStart(.one_compiled, sel.source.len);
    }

    const start = std.time.nanoTimestamp();
    const value = doc.queryOneCompiled(sel);
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
        hooks.onQueryEnd(QueryInstrumentationStats{
            .elapsed_ns = elapsedNs(start, std.time.nanoTimestamp()),
            .selector_len = sel.source.len,
            .kind = .one_compiled,
            .matched = matchedFromValue(value),
        });
    }
    return value;
}

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

pub fn queryAllCompiledWithHooks(doc: anytype, sel: *const ast.Selector, hooks: anytype) @TypeOf(doc.queryAllCompiled(sel)) {
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryStart")) {
        hooks.onQueryStart(.all_compiled, sel.source.len);
    }

    const start = std.time.nanoTimestamp();
    const iter = doc.queryAllCompiled(sel);
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
        hooks.onQueryEnd(QueryInstrumentationStats{
            .elapsed_ns = elapsedNs(start, std.time.nanoTimestamp()),
            .selector_len = sel.source.len,
            .kind = .all_compiled,
            .matched = null,
        });
    }
    return iter;
}
