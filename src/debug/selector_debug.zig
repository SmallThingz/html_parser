const std = @import("std");

/// Sentinel for invalid node indexes in debug reports.
pub const InvalidIndex: u32 = std.math.maxInt(u32);
/// Sentinel for unset small integer fields in debug reports.
pub const InvalidSmall: u16 = std.math.maxInt(u16);
/// Maximum near-miss records captured per debug query run.
pub const MaxNearMisses: usize = 8;
/// Maximum selector groups tracked in debug counters.
pub const MaxSelectorGroups: usize = 8;

/// Classification of first-failure reason while matching a selector.
pub const DebugFailureKind = enum(u8) {
    none,
    parse,
    tag,
    id,
    class,
    attr,
    pseudo,
    not_simple,
    combinator,
    scope,
};

/// First failing predicate metadata for a candidate node.
pub const Failure = struct {
    kind: DebugFailureKind = .none,
    group_index: u16 = InvalidSmall,
    compound_index: u16 = InvalidSmall,
    predicate_index: u16 = InvalidSmall,

    /// Returns true when this failure slot is unset.
    pub fn isNone(self: @This()) bool {
        return self.kind == .none;
    }
};

/// Single non-matching node with its first failure reason.
pub const NearMiss = struct {
    node_index: u32 = InvalidIndex,
    reason: Failure = .{},
};

/// Fixed-capacity diagnostic report filled by debug query APIs.
pub const QueryDebugReport = struct {
    selector_source: []const u8 = "",
    scope_root: u32 = InvalidIndex,
    visited_elements: u32 = 0,
    matched_index: u32 = InvalidIndex,
    matched_group: u16 = InvalidSmall,
    runtime_parse_error: bool = false,

    group_count: u8 = 0,
    group_eval_counts: [MaxSelectorGroups]u32 = [_]u32{0} ** MaxSelectorGroups,
    group_match_counts: [MaxSelectorGroups]u32 = [_]u32{0} ** MaxSelectorGroups,

    near_miss_len: u8 = 0,
    near_misses: [MaxNearMisses]NearMiss = [_]NearMiss{.{}} ** MaxNearMisses,

    /// Resets report state before a debug query run.
    pub fn reset(self: *@This(), selector_source: []const u8, scope_root: u32, group_count: usize) void {
        self.* = .{
            .selector_source = selector_source,
            .scope_root = scope_root,
            .group_count = @intCast(@min(group_count, MaxSelectorGroups)),
        };
    }

    /// Marks runtime selector parse failure in this report.
    pub fn setRuntimeParseError(self: *@This()) void {
        self.runtime_parse_error = true;
    }

    /// Adds one near-miss entry if report capacity allows.
    pub fn pushNearMiss(self: *@This(), node_index: u32, reason: Failure) void {
        if (self.near_miss_len >= MaxNearMisses) return;
        const idx: usize = @intCast(self.near_miss_len);
        self.near_misses[idx] = .{
            .node_index = node_index,
            .reason = reason,
        };
        self.near_miss_len += 1;
    }
};
