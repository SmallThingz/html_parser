const std = @import("std");

/// Relationship between a compound and the compound to its left.
pub const Combinator = enum(u8) {
    none,
    descendant,
    child,
    adjacent,
    sibling,
};

/// Attribute selector operator.
pub const AttrOp = enum(u8) {
    exists,
    eq,
    prefix,
    suffix,
    contains,
    includes,
    dash_match,
};

/// Source byte range pointing into selector text.
pub const Range = extern struct {
    start: u32 = 0,
    len: u32 = 0,

    /// Returns empty range.
    pub fn empty() @This() {
        return .{ .start = 0, .len = 0 };
    }

    /// Creates range from `start..end`.
    pub fn from(start: usize, end: usize) @This() {
        return .{
            .start = @intCast(start),
            .len = @intCast(end - start),
        };
    }

    /// Returns true when range has zero length.
    pub fn isEmpty(self: @This()) bool {
        return self.len == 0;
    }

    /// Returns the slice represented by this range.
    pub fn slice(self: @This(), source: []const u8) []const u8 {
        const s: usize = @intCast(self.start);
        const e: usize = s + @as(usize, @intCast(self.len));
        return source[s..e];
    }
};

/// One parsed attribute selector predicate.
pub const AttrSelector = extern struct {
    name: Range,
    name_hash: u32 = 0,
    op: AttrOp = .exists,
    value: Range = .{},
};

/// Parsed `An+B` expression for `:nth-child`.
pub const NthExpr = extern struct {
    // Matches values where index = a*n + b, n >= 0, index is 1-based.
    a: i32,
    b: i32,

    /// Evaluates this expression for a 1-based child index.
    pub fn matches(self: @This(), index_1based: usize) bool {
        const idx: i32 = @intCast(index_1based);
        if (self.a == 0) return idx == self.b;
        const diff = idx - self.b;
        if ((diff > 0 and self.a < 0) or (diff < 0 and self.a > 0)) return false;
        if (@rem(diff, self.a) != 0) return false;
        return @divTrunc(diff, self.a) >= 0;
    }
};

/// Supported pseudo classes.
pub const PseudoKind = enum(u8) {
    first_child,
    last_child,
    nth_child,
};

/// One parsed pseudo predicate.
pub const Pseudo = extern struct {
    kind: PseudoKind,
    nth: NthExpr = .{ .a = 0, .b = 1 },
};

/// Supported simple selectors inside `:not(...)`.
pub const NotKind = enum(u8) {
    tag,
    id,
    class,
    attr,
};

/// One parsed simple `:not(...)` predicate.
pub const NotSimple = extern struct {
    kind: NotKind,
    text: Range = .{},
    attr: AttrSelector = .{ .name = .{}, .op = .exists, .value = .{} },
};

/// One selector compound (tag/id/class/attr/pseudo/not + combinator).
pub const Compound = extern struct {
    combinator: Combinator = .none,

    has_tag: u8 = 0,
    tag: Range = .{},
    tag_hash: u64 = 0,

    has_id: u8 = 0,
    id: Range = .{},

    class_start: u32 = 0,
    class_len: u32 = 0,

    attr_start: u32 = 0,
    attr_len: u32 = 0,

    pseudo_start: u32 = 0,
    pseudo_len: u32 = 0,

    not_start: u32 = 0,
    not_len: u32 = 0,
};

/// One comma-separated selector group.
pub const Group = extern struct {
    compound_start: u32,
    compound_len: u32,
};

/// Compiled selector used by matcher/query APIs.
pub const Selector = struct {
    source: []const u8,
    requires_parent: bool = false,
    groups: []const Group,
    compounds: []const Compound,
    classes: []const Range,
    attrs: []const AttrSelector,
    pseudos: []const Pseudo,
    not_items: []const NotSimple,

    /// Compiles a selector at comptime with compile-time diagnostics.
    pub fn compile(comptime source: []const u8) @This() {
        return @import("compile_time.zig").compileImpl(source);
    }

    /// Compiles a selector at runtime.
    pub fn compileRuntime(allocator: std.mem.Allocator, source: []const u8) @import("runtime.zig").Error!@This() {
        return @import("runtime.zig").compileRuntimeImpl(allocator, source);
    }

    /// Releases memory owned by runtime-compiled selector.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.source));
        allocator.free(self.groups);
        allocator.free(self.compounds);
        allocator.free(self.classes);
        allocator.free(self.attrs);
        allocator.free(self.pseudos);
        allocator.free(self.not_items);
        self.* = undefined;
    }
};
