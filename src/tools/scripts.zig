const std = @import("std");
const common = @import("common.zig");

const REPO_ROOT = ".";
const BENCH_DIR = "bench";
const BUILD_DIR = "bench/build";
const BIN_DIR = "bench/build/bin";
const RESULTS_DIR = "bench/results";
const FIXTURES_DIR = "bench/fixtures";
const PARSERS_DIR = "bench/parsers";
const CONFORMANCE_CASES_DIR = "bench/conformance_cases";
const SUITES_DIR = "/tmp/htmlparser-suites";
const SUITE_RUNNER_BIN = "bench/build/bin/suite_runner";

const repeats: usize = 5;

const ParserCapability = struct {
    parser: []const u8,
    capability: []const u8,
};

const parser_capabilities = [_]ParserCapability{
    .{ .parser = "ours-strict", .capability = "dom" },
    .{ .parser = "ours-turbo", .capability = "dom" },
    .{ .parser = "strlen", .capability = "scan" },
    .{ .parser = "lexbor", .capability = "dom" },
    .{ .parser = "gumbo-modern", .capability = "dom" },
    .{ .parser = "html5ever", .capability = "dom" },
    .{ .parser = "lol-html", .capability = "streaming" },
};

const parse_parsers = [_][]const u8{
    "ours-strict",
    "ours-turbo",
    "strlen",
    "lexbor",
    "gumbo-modern",
    "html5ever",
    "lol-html",
};

const query_modes = [_]struct { parser: []const u8, mode: []const u8 }{
    .{ .parser = "ours-strict", .mode = "strict" },
    .{ .parser = "ours-turbo", .mode = "turbo" },
};

const FixtureCase = struct {
    name: []const u8,
    iterations: usize,
};

const QueryCase = struct {
    name: []const u8,
    selector: []const u8,
    iterations: usize,
};

const QueryExecCase = struct {
    name: []const u8,
    fixture: []const u8,
    selector: []const u8,
    iterations: usize,
};

const Profile = struct {
    name: []const u8,
    fixtures: []const FixtureCase,
    query_parse_cases: []const QueryCase,
    query_match_cases: []const QueryExecCase,
    query_compiled_cases: []const QueryExecCase,
};

const quick_fixtures = [_]FixtureCase{
    .{ .name = "rust-lang.html", .iterations = 30 },
    .{ .name = "wiki-html.html", .iterations = 30 },
    .{ .name = "mdn-html.html", .iterations = 30 },
    .{ .name = "w3-html52.html", .iterations = 30 },
    .{ .name = "hn.html", .iterations = 30 },
};

const stable_fixtures = [_]FixtureCase{
    .{ .name = "rust-lang.html", .iterations = 30 },
    .{ .name = "wiki-html.html", .iterations = 30 },
    .{ .name = "mdn-html.html", .iterations = 30 },
    .{ .name = "w3-html52.html", .iterations = 30 },
    .{ .name = "hn.html", .iterations = 30 },
};

const quick_query_parse = [_]QueryCase{
    .{ .name = "simple", .selector = "li.x", .iterations = 100_000 },
    .{ .name = "complex", .selector = "ul > li.item[data-prefix^=pre]:not(.skip) span.name", .iterations = 40_000 },
    .{ .name = "grouped", .selector = "li#li1, li#li2, li:nth-child(2n+1)", .iterations = 40_000 },
};

const stable_query_parse = [_]QueryCase{
    .{ .name = "simple", .selector = "li.x", .iterations = 1_000_000 },
    .{ .name = "complex", .selector = "ul > li.item[data-prefix^=pre]:not(.skip) span.name", .iterations = 400_000 },
    .{ .name = "grouped", .selector = "li#li1, li#li2, li:nth-child(2n+1)", .iterations = 400_000 },
};

const quick_query_exec = [_]QueryExecCase{
    .{ .name = "attr-heavy-button", .fixture = "rust-lang.html", .selector = "a[href^=https][class*=button]:not(.missing)", .iterations = 30_000 },
    .{ .name = "attr-heavy-nav", .fixture = "rust-lang.html", .selector = "a[href^=https][class*=nav]:not(.missing)", .iterations = 30_000 },
};

const stable_query_exec = [_]QueryExecCase{
    .{ .name = "attr-heavy-button", .fixture = "rust-lang.html", .selector = "a[href^=https][class*=button]:not(.missing)", .iterations = 1_000_000 },
    .{ .name = "attr-heavy-nav", .fixture = "rust-lang.html", .selector = "a[href^=https][class*=nav]:not(.missing)", .iterations = 1_000_000 },
};

fn getProfile(name: []const u8) !Profile {
    if (std.mem.eql(u8, name, "quick")) {
        return .{
            .name = "quick",
            .fixtures = &quick_fixtures,
            .query_parse_cases = &quick_query_parse,
            .query_match_cases = &quick_query_exec,
            .query_compiled_cases = &quick_query_exec,
        };
    }
    if (std.mem.eql(u8, name, "stable")) {
        return .{
            .name = "stable",
            .fixtures = &stable_fixtures,
            .query_parse_cases = &stable_query_parse,
            .query_match_cases = &stable_query_exec,
            .query_compiled_cases = &stable_query_exec,
        };
    }
    return error.InvalidProfile;
}

fn pathExists(path: []const u8) bool {
    return common.fileExists(path);
}

fn setupParsers(alloc: std.mem.Allocator) !void {
    try common.ensureDir(PARSERS_DIR);
    const repos = [_]struct { url: []const u8, dir: []const u8 }{
        .{ .url = "https://github.com/lexbor/lexbor.git", .dir = "lexbor" },
        .{ .url = "https://codeberg.org/gumbo-parser/gumbo-parser.git", .dir = "gumbo-modern" },
        .{ .url = "https://github.com/servo/html5ever.git", .dir = "html5ever" },
        .{ .url = "https://github.com/cloudflare/lol-html.git", .dir = "lol-html" },
    };
    for (repos) |repo| {
        const git_path = try std.fmt.allocPrint(alloc, "{s}/{s}/.git", .{ PARSERS_DIR, repo.dir });
        defer alloc.free(git_path);
        if (pathExists(git_path)) {
            std.debug.print("already present: {s}\n", .{repo.dir});
            continue;
        }
        std.debug.print("cloning: {s}\n", .{repo.dir});
        const dst = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ PARSERS_DIR, repo.dir });
        defer alloc.free(dst);
        const argv = [_][]const u8{ "git", "clone", "--depth", "1", repo.url, dst };
        try common.runInherit(alloc, &argv, REPO_ROOT);
    }
    std.debug.print("done\n", .{});
}

fn setupFixtures(alloc: std.mem.Allocator, refresh: bool) !void {
    try common.ensureDir(FIXTURES_DIR);
    const targets = [_]struct { url: []const u8, out: []const u8 }{
        .{ .url = "https://www.rust-lang.org/", .out = "rust-lang.html" },
        .{ .url = "https://en.wikipedia.org/wiki/HTML", .out = "wiki-html.html" },
        .{ .url = "https://developer.mozilla.org/en-US/docs/Web/HTML", .out = "mdn-html.html" },
        .{ .url = "https://www.w3.org/TR/html52/", .out = "w3-html52.html" },
        .{ .url = "https://news.ycombinator.com/", .out = "hn.html" },
    };
    for (targets) |item| {
        const target = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ FIXTURES_DIR, item.out });
        defer alloc.free(target);

        if (!refresh) {
            const stat = std.fs.cwd().statFile(target) catch null;
            if (stat != null and stat.?.size > 0) {
                std.debug.print("cached: {s}\n", .{item.out});
                continue;
            }
        }

        std.debug.print("downloading: {s}\n", .{item.out});
        const argv = [_][]const u8{
            "curl",
            "-L",
            "--fail",
            "--retry",
            "2",
            "--retry-delay",
            "1",
            "-A",
            "htmlparser-bench/1.0 (+https://example.invalid)",
            item.url,
            "-o",
            target,
        };
        try common.runInherit(alloc, &argv, REPO_ROOT);
    }
    std.debug.print("fixtures ready in {s}\n", .{FIXTURES_DIR});
}

fn ensureExternalParsersBuilt(alloc: std.mem.Allocator) !void {
    if (!pathExists("bench/parsers/lol-html/Cargo.toml")) {
        try setupParsers(alloc);
    }

    if (!pathExists("bench/build/lexbor/liblexbor_static.a")) {
        const cmake_cfg = [_][]const u8{
            "cmake",
            "-S",
            "bench/parsers/lexbor",
            "-B",
            "bench/build/lexbor",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DLEXBOR_BUILD_TESTS=OFF",
            "-DLEXBOR_BUILD_EXAMPLES=OFF",
        };
        try common.runInherit(alloc, &cmake_cfg, REPO_ROOT);
        const cmake_build = [_][]const u8{ "cmake", "--build", "bench/build/lexbor", "-j" };
        try common.runInherit(alloc, &cmake_build, REPO_ROOT);
    }

    if (!pathExists("bench/build/gumbo-modern/libgumbo.a")) {
        const meson_setup = [_][]const u8{
            "meson",
            "setup",
            "bench/build/gumbo-modern",
            "bench/parsers/gumbo-modern",
            "--buildtype",
            "release",
        };
        try common.runInherit(alloc, &meson_setup, REPO_ROOT);
        const ninja_build = [_][]const u8{ "ninja", "-C", "bench/build/gumbo-modern" };
        try common.runInherit(alloc, &ninja_build, REPO_ROOT);
    }
}

fn buildRunners(alloc: std.mem.Allocator) !void {
    try common.ensureDir(BIN_DIR);
    const zig_build = [_][]const u8{ "zig", "build", "-Doptimize=ReleaseFast" };
    try common.runInherit(alloc, &zig_build, REPO_ROOT);

    const strlen_cc = [_][]const u8{
        "cc",
        "-O3",
        "-fno-builtin",
        "bench/runners/strlen_runner.c",
        "-o",
        "bench/build/bin/strlen_runner",
    };
    try common.runInherit(alloc, &strlen_cc, REPO_ROOT);

    const lexbor_cc = [_][]const u8{
        "cc",
        "-O3",
        "bench/runners/lexbor_runner.c",
        "bench/build/lexbor/liblexbor_static.a",
        "-Ibench/parsers/lexbor/source",
        "-lm",
        "-o",
        "bench/build/bin/lexbor_runner",
    };
    try common.runInherit(alloc, &lexbor_cc, REPO_ROOT);

    const gumbo_cc = [_][]const u8{
        "cc",
        "-O3",
        "bench/runners/gumbo_runner.c",
        "bench/build/gumbo-modern/libgumbo.a",
        "-Ibench/parsers/gumbo-modern/src",
        "-o",
        "bench/build/bin/gumbo_runner",
    };
    try common.runInherit(alloc, &gumbo_cc, REPO_ROOT);

    const cargo_html5ever = [_][]const u8{
        "cargo",
        "build",
        "--release",
        "--manifest-path",
        "bench/runners/html5ever_runner/Cargo.toml",
    };
    try common.runInherit(alloc, &cargo_html5ever, REPO_ROOT);

    const cargo_lol = [_][]const u8{
        "cargo",
        "build",
        "--release",
        "--manifest-path",
        "bench/runners/lol_html_runner/Cargo.toml",
    };
    try common.runInherit(alloc, &cargo_lol, REPO_ROOT);
}

const ParseResult = struct {
    parser: []const u8,
    fixture: []const u8,
    iterations: usize,
    samples_ns: []u64,
    median_ns: u64,
    throughput_mb_s: f64,
};

const QueryResult = struct {
    parser: []const u8,
    mode: []const u8,
    case: []const u8,
    selector: []const u8,
    fixture: ?[]const u8 = null,
    iterations: usize,
    samples_ns: []u64,
    median_ns: u64,
    ops_s: f64,
    ns_per_op: f64,
};

const GateRow = struct {
    fixture: []const u8,
    ours_turbo_mb_s: f64,
    lol_html_mb_s: f64,
    pass: bool,
};

fn runnerCmdParse(alloc: std.mem.Allocator, parser_name: []const u8, fixture: []const u8, iterations: usize) ![]const []const u8 {
    const iter_s = try std.fmt.allocPrint(alloc, "{d}", .{iterations});
    if (std.mem.eql(u8, parser_name, "ours-strict")) {
        const argv = try alloc.alloc([]const u8, 5);
        argv[0] = "zig-out/bin/htmlparser-bench";
        argv[1] = "parse";
        argv[2] = "strict";
        argv[3] = fixture;
        argv[4] = iter_s;
        return argv;
    }
    if (std.mem.eql(u8, parser_name, "ours-turbo")) {
        const argv = try alloc.alloc([]const u8, 5);
        argv[0] = "zig-out/bin/htmlparser-bench";
        argv[1] = "parse";
        argv[2] = "turbo";
        argv[3] = fixture;
        argv[4] = iter_s;
        return argv;
    }
    if (std.mem.eql(u8, parser_name, "strlen")) {
        const argv = try alloc.alloc([]const u8, 3);
        argv[0] = "bench/build/bin/strlen_runner";
        argv[1] = fixture;
        argv[2] = iter_s;
        return argv;
    }
    if (std.mem.eql(u8, parser_name, "lexbor")) {
        const argv = try alloc.alloc([]const u8, 3);
        argv[0] = "bench/build/bin/lexbor_runner";
        argv[1] = fixture;
        argv[2] = iter_s;
        return argv;
    }
    if (std.mem.eql(u8, parser_name, "gumbo-modern")) {
        const argv = try alloc.alloc([]const u8, 3);
        argv[0] = "bench/build/bin/gumbo_runner";
        argv[1] = fixture;
        argv[2] = iter_s;
        return argv;
    }
    if (std.mem.eql(u8, parser_name, "html5ever")) {
        const argv = try alloc.alloc([]const u8, 3);
        argv[0] = "bench/runners/html5ever_runner/target/release/html5ever_runner";
        argv[1] = fixture;
        argv[2] = iter_s;
        return argv;
    }
    if (std.mem.eql(u8, parser_name, "lol-html")) {
        const argv = try alloc.alloc([]const u8, 3);
        argv[0] = "bench/runners/lol_html_runner/target/release/lol_html_runner";
        argv[1] = fixture;
        argv[2] = iter_s;
        return argv;
    }
    return error.InvalidParser;
}

fn freeArgv(alloc: std.mem.Allocator, argv: []const []const u8) void {
    if (argv.len == 0) return;
    // Last argument is always allocPrint'd iterations string.
    alloc.free(argv[argv.len - 1]);
    alloc.free(argv);
}

fn runIntCmd(alloc: std.mem.Allocator, argv: []const []const u8) !u64 {
    const out = try common.runCaptureCombined(alloc, argv, REPO_ROOT);
    defer alloc.free(out);
    return common.parseLastInt(out);
}

fn benchParseOne(alloc: std.mem.Allocator, parser_name: []const u8, fixture_name: []const u8, iterations: usize) !ParseResult {
    const fixture = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ FIXTURES_DIR, fixture_name });
    defer alloc.free(fixture);
    const stat = try std.fs.cwd().statFile(fixture);
    const size_bytes = stat.size;

    {
        const warm = try runnerCmdParse(alloc, parser_name, fixture, 1);
        defer freeArgv(alloc, warm);
        _ = try runIntCmd(alloc, warm);
    }

    const samples = try alloc.alloc(u64, repeats);
    for (samples) |*slot| {
        const argv = try runnerCmdParse(alloc, parser_name, fixture, iterations);
        defer freeArgv(alloc, argv);
        slot.* = try runIntCmd(alloc, argv);
    }

    const median_ns = try common.medianU64(alloc, samples);
    const total_bytes: f64 = @floatFromInt(size_bytes * iterations);
    const seconds = @as(f64, @floatFromInt(median_ns)) / 1_000_000_000.0;
    const mbps = if (seconds > 0.0) (total_bytes / 1_000_000.0) / seconds else 0.0;
    return .{
        .parser = parser_name,
        .fixture = fixture_name,
        .iterations = iterations,
        .samples_ns = samples,
        .median_ns = median_ns,
        .throughput_mb_s = mbps,
    };
}

fn benchQueryParseOne(alloc: std.mem.Allocator, parser_name: []const u8, mode: []const u8, case_name: []const u8, selector: []const u8, iterations: usize) !QueryResult {
    const iter_s = try std.fmt.allocPrint(alloc, "{d}", .{iterations});
    defer alloc.free(iter_s);

    {
        const warm = [_][]const u8{ "zig-out/bin/htmlparser-bench", "query-parse", mode, selector, "1" };
        _ = try runIntCmd(alloc, &warm);
    }

    const samples = try alloc.alloc(u64, repeats);
    for (samples) |*slot| {
        const argv = [_][]const u8{ "zig-out/bin/htmlparser-bench", "query-parse", mode, selector, iter_s };
        slot.* = try runIntCmd(alloc, &argv);
    }

    const median_ns = try common.medianU64(alloc, samples);
    const seconds = @as(f64, @floatFromInt(median_ns)) / 1_000_000_000.0;
    const ops_s = if (seconds > 0.0) @as(f64, @floatFromInt(iterations)) / seconds else 0.0;
    const ns_per_op = @as(f64, @floatFromInt(median_ns)) / @as(f64, @floatFromInt(iterations));
    return .{
        .parser = parser_name,
        .mode = mode,
        .case = case_name,
        .selector = selector,
        .iterations = iterations,
        .samples_ns = samples,
        .median_ns = median_ns,
        .ops_s = ops_s,
        .ns_per_op = ns_per_op,
    };
}

fn benchQueryExecOne(alloc: std.mem.Allocator, parser_name: []const u8, mode: []const u8, case_name: []const u8, fixture_name: []const u8, selector: []const u8, iterations: usize, compiled: bool) !QueryResult {
    const fixture = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ FIXTURES_DIR, fixture_name });
    defer alloc.free(fixture);
    const iter_s = try std.fmt.allocPrint(alloc, "{d}", .{iterations});
    defer alloc.free(iter_s);
    const sub = if (compiled) "query-compiled" else "query-match";

    {
        const warm = [_][]const u8{ "zig-out/bin/htmlparser-bench", sub, mode, fixture, selector, "1" };
        _ = try runIntCmd(alloc, &warm);
    }

    const samples = try alloc.alloc(u64, repeats);
    for (samples) |*slot| {
        const argv = [_][]const u8{ "zig-out/bin/htmlparser-bench", sub, mode, fixture, selector, iter_s };
        slot.* = try runIntCmd(alloc, &argv);
    }
    const median_ns = try common.medianU64(alloc, samples);
    const seconds = @as(f64, @floatFromInt(median_ns)) / 1_000_000_000.0;
    const ops_s = if (seconds > 0.0) @as(f64, @floatFromInt(iterations)) / seconds else 0.0;
    const ns_per_op = @as(f64, @floatFromInt(median_ns)) / @as(f64, @floatFromInt(iterations));
    return .{
        .parser = parser_name,
        .mode = mode,
        .case = case_name,
        .selector = selector,
        .fixture = fixture_name,
        .iterations = iterations,
        .samples_ns = samples,
        .median_ns = median_ns,
        .ops_s = ops_s,
        .ns_per_op = ns_per_op,
    };
}

fn capabilityOf(parser_name: []const u8) []const u8 {
    for (parser_capabilities) |cap| {
        if (std.mem.eql(u8, cap.parser, parser_name)) return cap.capability;
    }
    return "?";
}

fn findParseThroughput(rows: []const ParseResult, parser_name: []const u8, fixture_name: []const u8) ?f64 {
    for (rows) |row| {
        if (std.mem.eql(u8, row.parser, parser_name) and std.mem.eql(u8, row.fixture, fixture_name)) {
            return row.throughput_mb_s;
        }
    }
    return null;
}

fn writeMarkdown(
    alloc: std.mem.Allocator,
    profile_name: []const u8,
    parse_results: []const ParseResult,
    query_parse_results: []const QueryResult,
    query_match_results: []const QueryResult,
    query_compiled_results: []const QueryResult,
    gate_rows: []const GateRow,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const w = out.writer(alloc);

    try w.print("# HTML Parser Benchmark Results\n\nGenerated (unix): {d}\n\nProfile: `{s}`\n\n", .{ common.nowUnix(), profile_name });
    try w.writeAll("## Parse Throughput\n\n");

    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    for (parse_results) |row| {
        if (seen.contains(row.fixture)) continue;
        try seen.put(row.fixture, {});

        var fixture_rows = std.ArrayList(ParseResult).empty;
        defer fixture_rows.deinit(alloc);
        for (parse_results) |r| {
            if (std.mem.eql(u8, r.fixture, row.fixture)) try fixture_rows.append(alloc, r);
        }
        std.mem.sort(ParseResult, fixture_rows.items, {}, struct {
            fn lt(_: void, a: ParseResult, b: ParseResult) bool {
                return a.throughput_mb_s > b.throughput_mb_s;
            }
        }.lt);

        const strlen = findParseThroughput(parse_results, "strlen", row.fixture);
        try w.print("### Fixture: `{s}`\n\n", .{row.fixture});
        try w.writeAll("| Parser | Capability | Throughput (MB/s) | % of strlen | Median Time (ms) | Iterations |\n");
        try w.writeAll("|---|---|---:|---:|---:|---:|\n");
        for (fixture_rows.items) |r| {
            if (strlen) |s| {
                const pct = if (s > 0.0) (r.throughput_mb_s / s) * 100.0 else 0.0;
                try w.print("| {s} | {s} | {d:.2} | {d:.2}% | {d:.3} | {d} |\n", .{
                    r.parser,
                    capabilityOf(r.parser),
                    r.throughput_mb_s,
                    pct,
                    @as(f64, @floatFromInt(r.median_ns)) / 1_000_000.0,
                    r.iterations,
                });
            } else {
                try w.print("| {s} | {s} | {d:.2} | - | {d:.3} | {d} |\n", .{
                    r.parser,
                    capabilityOf(r.parser),
                    r.throughput_mb_s,
                    @as(f64, @floatFromInt(r.median_ns)) / 1_000_000.0,
                    r.iterations,
                });
            }
        }
        try w.writeAll("\n");
    }

    try writeQuerySection(alloc, &out, "## Query Parse Throughput", query_parse_results);
    try writeQuerySection(alloc, &out, "## Query Match Throughput", query_match_results);
    try writeQuerySection(alloc, &out, "## Query Compiled Throughput", query_compiled_results);

    if (gate_rows.len > 0) {
        try w.writeAll("## Turbo vs lol-html Gate\n\n");
        try w.writeAll("| Fixture | ours-turbo (MB/s) | lol-html (MB/s) | Result |\n");
        try w.writeAll("|---|---:|---:|---|\n");
        for (gate_rows) |g| {
            try w.print("| {s} | {d:.2} | {d:.2} | {s} |\n", .{
                g.fixture,
                g.ours_turbo_mb_s,
                g.lol_html_mb_s,
                if (g.pass) "PASS" else "FAIL",
            });
        }
        try w.writeAll("\n");
    }

    return out.toOwnedSlice(alloc);
}

fn writeQuerySection(alloc: std.mem.Allocator, out: *std.ArrayList(u8), title: []const u8, rows: []const QueryResult) !void {
    const w = out.writer(alloc);
    try w.print("{s}\n\n", .{title});
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    for (rows) |row| {
        if (seen.contains(row.case)) continue;
        try seen.put(row.case, {});

        var case_rows = std.ArrayList(QueryResult).empty;
        defer case_rows.deinit(alloc);
        for (rows) |r| if (std.mem.eql(u8, r.case, row.case)) try case_rows.append(alloc, r);
        std.mem.sort(QueryResult, case_rows.items, {}, struct {
            fn lt(_: void, a: QueryResult, b: QueryResult) bool {
                return a.ops_s > b.ops_s;
            }
        }.lt);

        try w.print("### Case: `{s}`\n\n", .{row.case});
        try w.writeAll("| Parser | Ops/s | ns/op | Median Time (ms) | Iterations | Selector |\n");
        try w.writeAll("|---|---:|---:|---:|---:|---|\n");
        for (case_rows.items) |r| {
            try w.print("| {s} | {d:.2} | {d:.2} | {d:.3} | {d} | `{s}` |\n", .{
                r.parser,
                r.ops_s,
                r.ns_per_op,
                @as(f64, @floatFromInt(r.median_ns)) / 1_000_000.0,
                r.iterations,
                r.selector,
            });
        }
        if (case_rows.items[0].fixture) |fx| {
            try w.print("\nFixture: `{s}`\n", .{fx});
        }
        try w.writeAll("\n");
    }
}

fn evaluateGateRows(alloc: std.mem.Allocator, profile: Profile, parse_results: []const ParseResult) ![]GateRow {
    var rows = std.ArrayList(GateRow).empty;
    errdefer rows.deinit(alloc);
    for (profile.fixtures) |fx| {
        const ours = findParseThroughput(parse_results, "ours-turbo", fx.name) orelse continue;
        const lol = findParseThroughput(parse_results, "lol-html", fx.name) orelse continue;
        try rows.append(alloc, .{
            .fixture = fx.name,
            .ours_turbo_mb_s = ours,
            .lol_html_mb_s = lol,
            .pass = ours > lol,
        });
    }
    return rows.toOwnedSlice(alloc);
}

fn parseBaselineOpsMap(
    alloc: std.mem.Allocator,
    value: std.json.Value,
    section_name: []const u8,
    parser_filter: []const u8,
) !std.StringHashMap(f64) {
    var out = std.StringHashMap(f64).init(alloc);
    errdefer out.deinit();
    const root_obj = value.object;
    const section = root_obj.get(section_name) orelse return out;
    if (section != .array) return out;
    for (section.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const parser = (obj.get("parser") orelse continue).string;
        if (!std.mem.eql(u8, parser, parser_filter)) continue;
        const case_name = (obj.get("case") orelse continue).string;
        const ops = switch (obj.get("ops_s") orelse continue) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => continue,
        };
        try out.put(case_name, ops);
    }
    return out;
}

fn parseBaselineParseMap(alloc: std.mem.Allocator, value: std.json.Value, parser_filter: []const u8) !std.StringHashMap(f64) {
    var out = std.StringHashMap(f64).init(alloc);
    errdefer out.deinit();
    const root_obj = value.object;
    const section = root_obj.get("parse_results") orelse return out;
    if (section != .array) return out;
    for (section.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const parser = (obj.get("parser") orelse continue).string;
        if (!std.mem.eql(u8, parser, parser_filter)) continue;
        const fixture = (obj.get("fixture") orelse continue).string;
        const mbps = switch (obj.get("throughput_mb_s") orelse continue) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => continue,
        };
        try out.put(fixture, mbps);
    }
    return out;
}

fn renderConsole(
    alloc: std.mem.Allocator,
    profile_name: []const u8,
    parse_results: []const ParseResult,
    query_parse_results: []const QueryResult,
    query_match_results: []const QueryResult,
    query_compiled_results: []const QueryResult,
    gate_rows: []const GateRow,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const w = out.writer(alloc);

    try w.writeAll("HTML Parser Benchmark Results\n");
    try w.print("Generated (unix): {d}\n", .{common.nowUnix()});
    try w.print("Profile: {s}\n\n", .{profile_name});

    try w.writeAll("Parse Throughput\n\n");

    var seen_fixtures = std.StringHashMap(void).init(alloc);
    defer seen_fixtures.deinit();
    for (parse_results) |row| {
        if (seen_fixtures.contains(row.fixture)) continue;
        try seen_fixtures.put(row.fixture, {});

        try w.print("Fixture: {s}\n", .{row.fixture});

        var fixture_rows = std.ArrayList(ParseResult).empty;
        defer fixture_rows.deinit(alloc);
        for (parse_results) |r| {
            if (std.mem.eql(u8, r.fixture, row.fixture)) try fixture_rows.append(alloc, r);
        }
        std.mem.sort(ParseResult, fixture_rows.items, {}, struct {
            fn lt(_: void, a: ParseResult, b: ParseResult) bool {
                return a.throughput_mb_s > b.throughput_mb_s;
            }
        }.lt);

        const headers = [_][]const u8{ "Parser", "Capability", "Throughput (MB/s)", "% of strlen", "Median Time (ms)", "Iterations" };
        const aligns = [_]bool{ false, false, true, true, true, true };
        var widths = [_]usize{
            headers[0].len,
            headers[1].len,
            headers[2].len,
            headers[3].len,
            headers[4].len,
            headers[5].len,
        };

        const strlen = findParseThroughput(parse_results, "strlen", row.fixture);
        var trows = std.ArrayList([6][]u8).empty;
        defer {
            for (trows.items) |cells| {
                for (cells) |c| alloc.free(c);
            }
            trows.deinit(alloc);
        }

        for (fixture_rows.items) |r| {
            var cells: [6][]u8 = undefined;
            cells[0] = try alloc.dupe(u8, r.parser);
            cells[1] = try alloc.dupe(u8, capabilityOf(r.parser));
            cells[2] = try std.fmt.allocPrint(alloc, "{d:.2}", .{r.throughput_mb_s});
            if (strlen) |s| {
                const pct = if (s > 0.0) (r.throughput_mb_s / s) * 100.0 else 0.0;
                cells[3] = try std.fmt.allocPrint(alloc, "{d:.2}%", .{pct});
            } else {
                cells[3] = try alloc.dupe(u8, "-");
            }
            cells[4] = try std.fmt.allocPrint(alloc, "{d:.3}", .{@as(f64, @floatFromInt(r.median_ns)) / 1_000_000.0});
            cells[5] = try std.fmt.allocPrint(alloc, "{d}", .{r.iterations});

            inline for (0..6) |i| widths[i] = @max(widths[i], cells[i].len);
            try trows.append(alloc, cells);
        }

        try appendAsciiSep(w, &widths);
        try appendAsciiRow(w, &widths, &headers, &aligns);
        try appendAsciiSep(w, &widths);
        for (trows.items) |cells| try appendAsciiRow(w, &widths, &cells, &aligns);
        try appendAsciiSep(w, &widths);
        try w.writeAll("\n");
    }

    try renderQueryConsoleSection(alloc, &out, "Query Parse Throughput", query_parse_results);
    try renderQueryConsoleSection(alloc, &out, "Query Match Throughput", query_match_results);
    try renderQueryConsoleSection(alloc, &out, "Query Compiled Throughput", query_compiled_results);

    if (gate_rows.len > 0) {
        try w.writeAll("Turbo vs lol-html Gate\n\n");
        const headers = [_][]const u8{ "Fixture", "ours-turbo (MB/s)", "lol-html (MB/s)", "Result" };
        const aligns = [_]bool{ false, true, true, false };
        var widths = [_]usize{ headers[0].len, headers[1].len, headers[2].len, headers[3].len };

        var rows = std.ArrayList([4][]u8).empty;
        defer {
            for (rows.items) |cells| for (cells) |c| alloc.free(c);
            rows.deinit(alloc);
        }
        for (gate_rows) |g| {
            var cells: [4][]u8 = undefined;
            cells[0] = try alloc.dupe(u8, g.fixture);
            cells[1] = try std.fmt.allocPrint(alloc, "{d:.2}", .{g.ours_turbo_mb_s});
            cells[2] = try std.fmt.allocPrint(alloc, "{d:.2}", .{g.lol_html_mb_s});
            cells[3] = try alloc.dupe(u8, if (g.pass) "PASS" else "FAIL");
            inline for (0..4) |i| widths[i] = @max(widths[i], cells[i].len);
            try rows.append(alloc, cells);
        }

        try appendAsciiSep(w, &widths);
        try appendAsciiRow(w, &widths, &headers, &aligns);
        try appendAsciiSep(w, &widths);
        for (rows.items) |cells| try appendAsciiRow(w, &widths, &cells, &aligns);
        try appendAsciiSep(w, &widths);
        try w.writeAll("\n");
    }

    return out.toOwnedSlice(alloc);
}

fn appendAsciiSep(writer: anytype, widths: []const usize) !void {
    try writer.writeAll("+-");
    for (widths, 0..) |w, i| {
        try writer.writeByteNTimes('-', w);
        if (i + 1 == widths.len) {
            try writer.writeAll("-+\n");
        } else {
            try writer.writeAll("-+-");
        }
    }
}

fn appendAsciiRow(writer: anytype, widths: []const usize, cells: []const []const u8, right_align: []const bool) !void {
    try writer.writeAll("| ");
    for (cells, 0..) |cell, i| {
        const width = widths[i];
        const pad = if (width > cell.len) width - cell.len else 0;
        if (right_align[i]) {
            try writer.writeByteNTimes(' ', pad);
            try writer.writeAll(cell);
        } else {
            try writer.writeAll(cell);
            try writer.writeByteNTimes(' ', pad);
        }
        if (i + 1 == cells.len) {
            try writer.writeAll(" |\n");
        } else {
            try writer.writeAll(" | ");
        }
    }
}

fn renderQueryConsoleSection(alloc: std.mem.Allocator, out: *std.ArrayList(u8), title: []const u8, rows: []const QueryResult) !void {
    const w = out.writer(alloc);
    try w.print("{s}\n\n", .{title});

    var seen_cases = std.StringHashMap(void).init(alloc);
    defer seen_cases.deinit();

    for (rows) |row| {
        if (seen_cases.contains(row.case)) continue;
        try seen_cases.put(row.case, {});

        var case_rows = std.ArrayList(QueryResult).empty;
        defer case_rows.deinit(alloc);
        for (rows) |r| if (std.mem.eql(u8, r.case, row.case)) try case_rows.append(alloc, r);
        std.mem.sort(QueryResult, case_rows.items, {}, struct {
            fn lt(_: void, a: QueryResult, b: QueryResult) bool {
                return a.ops_s > b.ops_s;
            }
        }.lt);

        try w.print("Case: {s}\n", .{row.case});
        const headers = [_][]const u8{ "Parser", "Ops/s", "ns/op", "Median Time (ms)", "Iterations" };
        const aligns = [_]bool{ false, true, true, true, true };
        var widths = [_]usize{ headers[0].len, headers[1].len, headers[2].len, headers[3].len, headers[4].len };

        var trows = std.ArrayList([5][]u8).empty;
        defer {
            for (trows.items) |cells| for (cells) |c| alloc.free(c);
            trows.deinit(alloc);
        }

        for (case_rows.items) |r| {
            var cells: [5][]u8 = undefined;
            cells[0] = try alloc.dupe(u8, r.parser);
            cells[1] = try std.fmt.allocPrint(alloc, "{d:.2}", .{r.ops_s});
            cells[2] = try std.fmt.allocPrint(alloc, "{d:.2}", .{r.ns_per_op});
            cells[3] = try std.fmt.allocPrint(alloc, "{d:.3}", .{@as(f64, @floatFromInt(r.median_ns)) / 1_000_000.0});
            cells[4] = try std.fmt.allocPrint(alloc, "{d}", .{r.iterations});
            inline for (0..5) |i| widths[i] = @max(widths[i], cells[i].len);
            try trows.append(alloc, cells);
        }

        try appendAsciiSep(w, &widths);
        try appendAsciiRow(w, &widths, &headers, &aligns);
        try appendAsciiSep(w, &widths);
        for (trows.items) |cells| try appendAsciiRow(w, &widths, &cells, &aligns);
        try appendAsciiSep(w, &widths);
        try w.writeAll("Selector:\n");
        try w.print("  {s}\n", .{case_rows.items[0].selector});
        if (case_rows.items[0].fixture) |fx| {
            try w.writeAll("Fixture:\n");
            try w.print("  {s}\n", .{fx});
        }
        try w.writeAll("\n");
    }
}

fn runBenchmarks(alloc: std.mem.Allocator, args: []const []const u8) !void {
    var profile_name: []const u8 = "quick";
    var baseline_path: ?[]const u8 = null;
    var write_baseline = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            profile_name = args[i];
        } else if (std.mem.eql(u8, arg, "--baseline")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            baseline_path = args[i];
        } else if (std.mem.eql(u8, arg, "--write-baseline")) {
            write_baseline = true;
        } else {
            return error.InvalidArgument;
        }
    }

    const profile = try getProfile(profile_name);

    try common.ensureDir(BIN_DIR);
    try common.ensureDir(RESULTS_DIR);
    try ensureExternalParsersBuilt(alloc);
    try buildRunners(alloc);

    var parse_results = std.ArrayList(ParseResult).empty;
    defer parse_results.deinit(alloc);

    for (profile.fixtures) |fixture| {
        for (parse_parsers) |parser_name| {
            std.debug.print("benchmarking {s} on {s} ({d} iters)\n", .{ parser_name, fixture.name, fixture.iterations });
            const row = try benchParseOne(alloc, parser_name, fixture.name, fixture.iterations);
            try parse_results.append(alloc, row);
        }
    }

    var query_parse_results = std.ArrayList(QueryResult).empty;
    defer query_parse_results.deinit(alloc);
    for (query_modes) |qm| {
        for (profile.query_parse_cases) |qc| {
            std.debug.print("benchmarking query-parse {s} on {s} ({d} iters)\n", .{ qm.parser, qc.name, qc.iterations });
            const row = try benchQueryParseOne(alloc, qm.parser, qm.mode, qc.name, qc.selector, qc.iterations);
            try query_parse_results.append(alloc, row);
        }
    }

    var query_match_results = std.ArrayList(QueryResult).empty;
    defer query_match_results.deinit(alloc);
    for (query_modes) |qm| {
        for (profile.query_match_cases) |qc| {
            std.debug.print("benchmarking query-match {s} on {s} ({d} iters)\n", .{ qm.parser, qc.name, qc.iterations });
            const row = try benchQueryExecOne(alloc, qm.parser, qm.mode, qc.name, qc.fixture, qc.selector, qc.iterations, false);
            try query_match_results.append(alloc, row);
        }
    }

    var query_compiled_results = std.ArrayList(QueryResult).empty;
    defer query_compiled_results.deinit(alloc);
    for (query_modes) |qm| {
        for (profile.query_compiled_cases) |qc| {
            std.debug.print("benchmarking query-compiled {s} on {s} ({d} iters)\n", .{ qm.parser, qc.name, qc.iterations });
            const row = try benchQueryExecOne(alloc, qm.parser, qm.mode, qc.name, qc.fixture, qc.selector, qc.iterations, true);
            try query_compiled_results.append(alloc, row);
        }
    }

    const gate_rows = try evaluateGateRows(alloc, profile, parse_results.items);
    defer alloc.free(gate_rows);

    const json_out = struct {
        generated_unix: i64,
        profile: []const u8,
        repeats: usize,
        bench_modes: struct { parse: []const []const u8, query: []const []const u8 },
        parser_capabilities: []const ParserCapability,
        parse_results: []const ParseResult,
        query_parse_results: []const QueryResult,
        query_match_results: []const QueryResult,
        query_compiled_results: []const QueryResult,
        gate_summary: []const GateRow,
    }{
        .generated_unix = common.nowUnix(),
        .profile = profile.name,
        .repeats = repeats,
        .bench_modes = .{ .parse = &[_][]const u8{ "strict", "turbo" }, .query = &[_][]const u8{ "strict", "turbo" } },
        .parser_capabilities = &parser_capabilities,
        .parse_results = parse_results.items,
        .query_parse_results = query_parse_results.items,
        .query_match_results = query_match_results.items,
        .query_compiled_results = query_compiled_results.items,
        .gate_summary = gate_rows,
    };

    var json_writer: std.io.Writer.Allocating = .init(alloc);
    defer json_writer.deinit();
    var json_stream: std.json.Stringify = .{
        .writer = &json_writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json_stream.write(json_out);
    try common.writeFile("bench/results/latest.json", json_writer.written());

    const md = try writeMarkdown(alloc, profile.name, parse_results.items, query_parse_results.items, query_match_results.items, query_compiled_results.items, gate_rows);
    defer alloc.free(md);
    try common.writeFile("bench/results/latest.md", md);

    // Optional baseline behavior.
    const baseline_default = try std.fmt.allocPrint(alloc, "bench/results/baseline_{s}.json", .{profile.name});
    defer alloc.free(baseline_default);
    const baseline = baseline_path orelse baseline_default;

    if (write_baseline) {
        try common.writeFile(baseline, json_writer.written());
        std.debug.print("wrote baseline {s}\n", .{baseline});
    }

    var warnings = std.ArrayList([]const u8).empty;
    defer warnings.deinit(alloc);
    var failures = std.ArrayList([]const u8).empty;
    defer failures.deinit(alloc);

    if (pathExists(baseline)) {
        const baseline_bytes = try common.readFileAlloc(alloc, baseline);
        defer alloc.free(baseline_bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, baseline_bytes, .{});
        defer parsed.deinit();

        var base_parse = try parseBaselineParseMap(alloc, parsed.value, "ours-strict");
        defer base_parse.deinit();
        var base_qp = try parseBaselineOpsMap(alloc, parsed.value, "query_parse_results", "ours-strict");
        defer base_qp.deinit();
        var base_qm = try parseBaselineOpsMap(alloc, parsed.value, "query_match_results", "ours-strict");
        defer base_qm.deinit();
        var base_qc = try parseBaselineOpsMap(alloc, parsed.value, "query_compiled_results", "ours-strict");
        defer base_qc.deinit();

        if (std.mem.eql(u8, profile.name, "stable")) {
            for (profile.fixtures) |fx| {
                const current = findParseThroughput(parse_results.items, "ours-strict", fx.name) orelse continue;
                if (base_parse.get(fx.name)) |base| {
                    if (current < base * 0.97) {
                        const msg = try std.fmt.allocPrint(alloc, "stable strict parse regression >3%: {s} {d:.2} < {d:.2}", .{ fx.name, current, base * 0.97 });
                        try failures.append(alloc, msg);
                    }
                }
            }
            try checkQuerySection(alloc, &failures, query_parse_results.items, "query-parse", base_qp, 0.98);
            try checkQuerySection(alloc, &failures, query_match_results.items, "query-match", base_qm, 0.98);
            try checkQuerySection(alloc, &failures, query_compiled_results.items, "query-compiled", base_qc, 0.98);
        } else {
            for (profile.fixtures) |fx| {
                const current = findParseThroughput(parse_results.items, "ours-strict", fx.name) orelse continue;
                if (base_parse.get(fx.name)) |base| {
                    if (current < base * 0.97) {
                        const msg = try std.fmt.allocPrint(alloc, "quick strict parse drift: {s} {d:.2} vs baseline {d:.2}", .{ fx.name, current, base });
                        try warnings.append(alloc, msg);
                    }
                }
            }
        }
    }

    for (gate_rows) |g| {
        if (std.mem.eql(u8, profile.name, "stable") and !g.pass) {
            const msg = try std.fmt.allocPrint(alloc, "stable turbo-vs-lol fail: {s} ours-turbo {d:.2} <= lol-html {d:.2}", .{ g.fixture, g.ours_turbo_mb_s, g.lol_html_mb_s });
            try failures.append(alloc, msg);
        }
    }

    std.debug.print("wrote bench/results/latest.json\n", .{});
    std.debug.print("wrote bench/results/latest.md\n\n", .{});
    const console = try renderConsole(alloc, profile.name, parse_results.items, query_parse_results.items, query_match_results.items, query_compiled_results.items, gate_rows);
    defer alloc.free(console);
    std.debug.print("{s}\n", .{console});

    if (warnings.items.len > 0) {
        std.debug.print("Gate warnings:\n", .{});
        for (warnings.items) |w| std.debug.print("- {s}\n", .{w});
    }
    if (failures.items.len > 0) {
        std.debug.print("Gate failures:\n", .{});
        for (failures.items) |f| std.debug.print("- {s}\n", .{f});
        return error.GateFailed;
    }
}

fn checkQuerySection(
    alloc: std.mem.Allocator,
    failures: *std.ArrayList([]const u8),
    rows: []const QueryResult,
    section_name: []const u8,
    baseline: std.StringHashMap(f64),
    min_ratio: f64,
) !void {
    var current = std.StringHashMap(f64).init(alloc);
    defer current.deinit();
    for (rows) |r| {
        if (!std.mem.eql(u8, r.parser, "ours-strict")) continue;
        try current.put(r.case, r.ops_s);
    }
    var it = baseline.iterator();
    while (it.next()) |entry| {
        if (current.get(entry.key_ptr.*)) |cur| {
            const min_expected = entry.value_ptr.* * min_ratio;
            if (cur < min_expected) {
                const msg = try std.fmt.allocPrint(alloc, "stable {s} regression >2%: {s} {d:.2} < {d:.2}", .{
                    section_name,
                    entry.key_ptr.*,
                    cur,
                    min_expected,
                });
                try failures.append(alloc, msg);
            }
        }
    }
}

// ---------------------------- External suites ----------------------------

const NwCase = struct {
    selector: []const u8,
    expected: usize,
};

const QwCase = struct {
    selector: []const u8,
    context: []const u8,
    expected: usize,
};

const SelectorSuiteSummary = struct {
    total: usize,
    passed: usize,
    failed: usize,
    examples: []const []const u8,
};

const ParserSuiteSummary = struct {
    total: usize,
    passed: usize,
    failed: usize,
    examples: []const []const u8,
};

fn ensureSuites(alloc: std.mem.Allocator) !void {
    try common.ensureDir(SUITES_DIR);
    const repos = [_]struct { name: []const u8, url: []const u8 }{
        .{ .name = "html5lib-tests", .url = "https://github.com/html5lib/html5lib-tests.git" },
        .{ .name = "css-select", .url = "https://github.com/fb55/css-select.git" },
    };
    for (repos) |repo| {
        const dst = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ SUITES_DIR, repo.name });
        defer alloc.free(dst);
        if (pathExists(dst)) continue;
        const argv = [_][]const u8{ "git", "clone", "--depth", "1", repo.url, dst };
        try common.runInherit(alloc, &argv, SUITES_DIR);
    }
}

fn buildSuiteRunner(alloc: std.mem.Allocator) !void {
    try common.ensureDir(BIN_DIR);
    const argv = [_][]const u8{
        "zig",
        "build-exe",
        "src/suite_runner.zig",
        "-O",
        "ReleaseFast",
        "-femit-bin=" ++ SUITE_RUNNER_BIN,
    };
    try common.runInherit(alloc, &argv, REPO_ROOT);
}

fn runSelectorCount(alloc: std.mem.Allocator, mode: []const u8, fixture: []const u8, selector: []const u8) !usize {
    const argv = [_][]const u8{ SUITE_RUNNER_BIN, "selector-count", mode, fixture, selector };
    const out = try common.runCaptureStdout(alloc, &argv, REPO_ROOT);
    defer alloc.free(out);
    return std.fmt.parseInt(usize, out, 10);
}

fn runSelectorCountScoped(alloc: std.mem.Allocator, mode: []const u8, fixture: []const u8, scope_tag: []const u8, selector: []const u8) !usize {
    const argv = [_][]const u8{ SUITE_RUNNER_BIN, "selector-count-scope-tag", mode, fixture, scope_tag, selector };
    const out = try common.runCaptureStdout(alloc, &argv, REPO_ROOT);
    defer alloc.free(out);
    return std.fmt.parseInt(usize, out, 10);
}

fn runParseTagsFile(alloc: std.mem.Allocator, mode: []const u8, fixture: []const u8) ![]const u8 {
    const argv = [_][]const u8{ SUITE_RUNNER_BIN, "parse-tags-file", mode, fixture };
    return common.runCaptureStdout(alloc, &argv, REPO_ROOT);
}

fn tempHtmlFile(alloc: std.mem.Allocator, html: []const u8) ![]u8 {
    const r = std.crypto.random.int(u64);
    const path = try std.fmt.allocPrint(alloc, "/tmp/htmlparser-suite-{x}.html", .{r});
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(html);
    return path;
}

fn loadNwCases(alloc: std.mem.Allocator) ![]NwCase {
    const bytes = try common.readFileAlloc(alloc, CONFORMANCE_CASES_DIR ++ "/nwmatcher_cases.json");
    defer alloc.free(bytes);
    const parsed = try std.json.parseFromSlice([]NwCase, alloc, bytes, .{});
    defer parsed.deinit();
    const out = try alloc.alloc(NwCase, parsed.value.len);
    for (parsed.value, 0..) |row, i| {
        out[i] = .{
            .selector = try alloc.dupe(u8, row.selector),
            .expected = row.expected,
        };
    }
    return out;
}

fn loadQwCases(alloc: std.mem.Allocator) ![]QwCase {
    const bytes = try common.readFileAlloc(alloc, CONFORMANCE_CASES_DIR ++ "/qwery_cases.json");
    defer alloc.free(bytes);
    const parsed = try std.json.parseFromSlice([]QwCase, alloc, bytes, .{});
    defer parsed.deinit();
    const out = try alloc.alloc(QwCase, parsed.value.len);
    for (parsed.value, 0..) |row, i| {
        out[i] = .{
            .selector = try alloc.dupe(u8, row.selector),
            .context = try alloc.dupe(u8, row.context),
            .expected = row.expected,
        };
    }
    return out;
}

fn runSelectorSuites(alloc: std.mem.Allocator, mode: []const u8) !struct { nw: SelectorSuiteSummary, qw: SelectorSuiteSummary } {
    const nw_cases = try loadNwCases(alloc);
    defer {
        for (nw_cases) |c| alloc.free(c.selector);
        alloc.free(nw_cases);
    }
    const qw_cases = try loadQwCases(alloc);
    defer {
        for (qw_cases) |c| {
            alloc.free(c.selector);
            alloc.free(c.context);
        }
        alloc.free(qw_cases);
    }

    const nw_fixture = SUITES_DIR ++ "/css-select/test/fixtures/nwmatcher.html";
    const qw_fixture = SUITES_DIR ++ "/css-select/test/fixtures/qwery.html";
    const qw_doc_html = try common.readFileAlloc(alloc, CONFORMANCE_CASES_DIR ++ "/qwery_doc.html");
    defer alloc.free(qw_doc_html);
    const qw_frag_html = try common.readFileAlloc(alloc, CONFORMANCE_CASES_DIR ++ "/qwery_frag.html");
    defer alloc.free(qw_frag_html);

    var nw_passed: usize = 0;
    var nw_examples = std.ArrayList([]const u8).empty;
    defer nw_examples.deinit(alloc);
    for (nw_cases, 0..) |c, idx| {
        if (idx >= 140) break;
        const got = runSelectorCount(alloc, mode, nw_fixture, c.selector) catch {
            const msg = try std.fmt.allocPrint(alloc, "{s} expected {d} got <parse-error>", .{ c.selector, c.expected });
            if (nw_examples.items.len < 8) try nw_examples.append(alloc, msg);
            continue;
        };
        if (got == c.expected) {
            nw_passed += 1;
        } else if (nw_examples.items.len < 8) {
            const msg = try std.fmt.allocPrint(alloc, "{s} expected {d} got {d}", .{ c.selector, c.expected, got });
            try nw_examples.append(alloc, msg);
        }
    }

    var qw_passed: usize = 0;
    var qw_examples = std.ArrayList([]const u8).empty;
    defer qw_examples.deinit(alloc);
    for (qw_cases) |c| {
        const got = blk: {
            if (std.mem.eql(u8, c.context, "document")) {
                break :blk runSelectorCount(alloc, mode, qw_fixture, c.selector) catch |err| return err;
            }
            const html = if (std.mem.eql(u8, c.context, "doc")) qw_doc_html else qw_frag_html;
            const tmp = try tempHtmlFile(alloc, html);
            defer {
                std.fs.deleteFileAbsolute(tmp) catch {};
                alloc.free(tmp);
            }
            break :blk runSelectorCountScoped(alloc, mode, tmp, "root", c.selector) catch |err| return err;
        };

        if (got == c.expected) {
            qw_passed += 1;
        } else if (qw_examples.items.len < 8) {
            const msg = try std.fmt.allocPrint(alloc, "{s} {s} expected {d} got {d}", .{ c.context, c.selector, c.expected, got });
            try qw_examples.append(alloc, msg);
        }
    }

    return .{
        .nw = .{
            .total = @min(nw_cases.len, 140),
            .passed = nw_passed,
            .failed = @min(nw_cases.len, 140) - nw_passed,
            .examples = try nw_examples.toOwnedSlice(alloc),
        },
        .qw = .{
            .total = qw_cases.len,
            .passed = qw_passed,
            .failed = qw_cases.len - qw_passed,
            .examples = try qw_examples.toOwnedSlice(alloc),
        },
    };
}

fn parseTreeTag(payload: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '!' or trimmed[0] == '?' or trimmed[0] == '/') return null;
    var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = parts.next() orelse return null;
    if ((std.mem.eql(u8, first, "svg") or std.mem.eql(u8, first, "math"))) {
        return parts.next() orelse first;
    }
    return first;
}

fn isWrapperTag(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "html") or
        std.mem.eql(u8, tag, "head") or
        std.mem.eql(u8, tag, "body") or
        std.mem.eql(u8, tag, "tbody") or
        std.mem.eql(u8, tag, "tr");
}

const ParserCase = struct {
    html: []const u8,
    expected: []const []const u8,
};

fn parseHtml5libDat(alloc: std.mem.Allocator, path: []const u8, out: *std.ArrayList(ParserCase)) !void {
    const text = try common.readFileAlloc(alloc, path);
    defer alloc.free(text);
    var blocks = std.mem.splitSequence(u8, text, "\n#data\n");
    while (blocks.next()) |raw_blk| {
        var blk = raw_blk;
        if (std.mem.startsWith(u8, blk, "#data\n")) blk = blk["#data\n".len..];
        if (std.mem.indexOf(u8, blk, "#document") == null) continue;
        const doc_idx = std.mem.indexOf(u8, blk, "\n#document\n") orelse continue;
        const data_part = blk[0..doc_idx];
        const rest = blk[doc_idx + "\n#document\n".len ..];
        if (std.mem.indexOf(u8, data_part, "\n#document-fragment\n") != null or std.mem.indexOf(u8, rest, "\n#document-fragment\n") != null) continue;

        var html_in = data_part;
        if (std.mem.indexOf(u8, html_in, "\n#errors\n")) |err_idx| {
            html_in = html_in[0..err_idx];
        }
        const html_copy = try alloc.dupe(u8, html_in);

        var expected = std.ArrayList([]const u8).empty;
        errdefer expected.deinit(alloc);
        var lines = std.mem.splitScalar(u8, rest, '\n');
        while (lines.next()) |line| {
            if (line.len < 3 or line[0] != '|') continue;
            var j: usize = 1;
            while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
            if (j >= line.len or line[j] != '<') continue;
            if (line[line.len - 1] != '>') continue;
            if (j + 1 > line.len - 1) continue;
            const payload = line[j + 1 .. line.len - 1];
            const maybe_tag = parseTreeTag(payload) orelse continue;
            const lower = try std.ascii.allocLowerString(alloc, maybe_tag);
            if (isWrapperTag(lower)) {
                alloc.free(lower);
                continue;
            }
            try expected.append(alloc, lower);
        }
        try out.append(alloc, .{
            .html = html_copy,
            .expected = try expected.toOwnedSlice(alloc),
        });
    }
}

fn parseTagJsonArray(alloc: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidJson;
    var tags = std.ArrayList([]const u8).empty;
    errdefer tags.deinit(alloc);
    for (parsed.value.array.items) |it| {
        if (it != .string) continue;
        const lower = try std.ascii.allocLowerString(alloc, it.string);
        if (isWrapperTag(lower)) {
            alloc.free(lower);
            continue;
        }
        try tags.append(alloc, lower);
    }
    return tags.toOwnedSlice(alloc);
}

fn eqlStringSlices(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn runParserSuite(alloc: std.mem.Allocator, mode: []const u8, max_cases: usize) !ParserSuiteSummary {
    const tc_dir = SUITES_DIR ++ "/html5lib-tests/tree-construction";
    var dir = try std.fs.cwd().openDir(tc_dir, .{ .iterate = true });
    defer dir.close();

    var dat_names = std.ArrayList([]const u8).empty;
    defer dat_names.deinit(alloc);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".dat")) continue;
        try dat_names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, dat_names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var cases = std.ArrayList(ParserCase).empty;
    defer {
        for (cases.items) |c| {
            alloc.free(c.html);
            for (c.expected) |tag| alloc.free(tag);
            alloc.free(c.expected);
        }
        cases.deinit(alloc);
    }
    for (dat_names.items) |name| {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ tc_dir, name });
        defer alloc.free(path);
        try parseHtml5libDat(alloc, path, &cases);
    }

    const limit = @min(max_cases, cases.items.len);
    var passed: usize = 0;
    var examples = std.ArrayList([]const u8).empty;
    defer examples.deinit(alloc);
    var idx: usize = 0;
    while (idx < limit) : (idx += 1) {
        const c = cases.items[idx];
        const tmp = try tempHtmlFile(alloc, c.html);
        defer {
            std.fs.deleteFileAbsolute(tmp) catch {};
            alloc.free(tmp);
        }
        const raw = runParseTagsFile(alloc, mode, tmp) catch {
            if (examples.items.len < 10) {
                const src = std.mem.replaceOwned(u8, alloc, c.html, "\n", "\\n") catch c.html;
                const msg = std.fmt.allocPrint(alloc, "{s} -> <parse-error>", .{src}) catch "parse-error";
                try examples.append(alloc, msg);
            }
            continue;
        };
        defer alloc.free(raw);
        const got = try parseTagJsonArray(alloc, raw);
        defer {
            for (got) |g| alloc.free(g);
            alloc.free(got);
        }
        if (eqlStringSlices(c.expected, got)) {
            passed += 1;
        } else if (examples.items.len < 10) {
            var src_short = c.html;
            if (src_short.len > 100) src_short = src_short[0..100];
            const src_escaped = try std.mem.replaceOwned(u8, alloc, src_short, "\n", "\\n");
            const msg = try std.fmt.allocPrint(alloc, "{s}", .{src_escaped});
            try examples.append(alloc, msg);
        }
    }

    return .{
        .total = limit,
        .passed = passed,
        .failed = limit - passed,
        .examples = try examples.toOwnedSlice(alloc),
    };
}

fn runExternalSuites(alloc: std.mem.Allocator, args: []const []const u8) !void {
    var mode_arg: []const u8 = "both";
    var max_cases: usize = 600;
    var json_out: []const u8 = "bench/results/external_suite_report.json";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            mode_arg = args[i];
        } else if (std.mem.eql(u8, arg, "--max-html5lib-cases")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            max_cases = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--json-out")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            json_out = args[i];
        } else return error.InvalidArgument;
    }

    try ensureSuites(alloc);
    try buildSuiteRunner(alloc);
    try common.ensureDir(RESULTS_DIR);

    const modes = if (std.mem.eql(u8, mode_arg, "both")) &[_][]const u8{ "strict", "turbo" } else &[_][]const u8{mode_arg};
    var mode_reports = std.ArrayList(struct {
        mode: []const u8,
        nw: SelectorSuiteSummary,
        qw: SelectorSuiteSummary,
        parser: ParserSuiteSummary,
    }).empty;
    defer mode_reports.deinit(alloc);

    for (modes) |mode| {
        const sel = try runSelectorSuites(alloc, mode);
        const parser = try runParserSuite(alloc, mode, max_cases);
        try mode_reports.append(alloc, .{
            .mode = mode,
            .nw = sel.nw,
            .qw = sel.qw,
            .parser = parser,
        });

        std.debug.print("Mode: {s}\n", .{mode});
        std.debug.print("  Selector suites:\n", .{});
        std.debug.print("    nwmatcher: {d}/{d} passed ({d} failed)\n", .{ sel.nw.passed, sel.nw.total, sel.nw.failed });
        std.debug.print("    qwery_contextual: {d}/{d} passed ({d} failed)\n", .{ sel.qw.passed, sel.qw.total, sel.qw.failed });
        std.debug.print("  Parser suite: html5lib tree-construction (compat subset): {d}/{d} passed ({d} failed)\n", .{
            parser.passed,
            parser.total,
            parser.failed,
        });
    }

    var json_buf = std.ArrayList(u8).empty;
    defer json_buf.deinit(alloc);
    const jw = json_buf.writer(alloc);
    try jw.writeAll("{\"modes\":{");
    for (mode_reports.items, 0..) |mr, idx_mode| {
        if (idx_mode != 0) try jw.writeAll(",");
        try jw.print("\"{s}\":{{", .{mr.mode});
        try jw.print("\"selector_suites\":{{\"nwmatcher\":{{\"total\":{d},\"passed\":{d},\"failed\":{d}}},\"qwery_contextual\":{{\"total\":{d},\"passed\":{d},\"failed\":{d}}}}},", .{
            mr.nw.total,
            mr.nw.passed,
            mr.nw.failed,
            mr.qw.total,
            mr.qw.passed,
            mr.qw.failed,
        });
        try jw.print("\"parser_suite\":{{\"total\":{d},\"passed\":{d},\"failed\":{d}}}", .{
            mr.parser.total,
            mr.parser.passed,
            mr.parser.failed,
        });
        try jw.writeAll("}");
    }
    try jw.writeAll("}}");
    try common.writeFile(json_out, json_buf.items);
    std.debug.print("Wrote report: {s}\n", .{json_out});
}

fn usage() void {
    std.debug.print(
        \\Usage:
        \\  htmlparser-tools setup-parsers
        \\  htmlparser-tools setup-fixtures [--refresh]
        \\  htmlparser-tools run-benchmarks [--profile quick|stable] [--baseline path] [--write-baseline]
        \\  htmlparser-tools run-external-suites [--mode strict|turbo|both] [--max-html5lib-cases N] [--json-out path]
        \\
    , .{});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 2) {
        usage();
        return;
    }
    const cmd = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, cmd, "setup-parsers")) {
        try setupParsers(alloc);
        return;
    }
    if (std.mem.eql(u8, cmd, "setup-fixtures")) {
        var refresh = false;
        if (rest.len > 0) {
            if (rest.len == 1 and std.mem.eql(u8, rest[0], "--refresh")) {
                refresh = true;
            } else return error.InvalidArgument;
        }
        try setupFixtures(alloc, refresh);
        return;
    }
    if (std.mem.eql(u8, cmd, "run-benchmarks")) {
        try runBenchmarks(alloc, rest);
        return;
    }
    if (std.mem.eql(u8, cmd, "run-external-suites")) {
        try runExternalSuites(alloc, rest);
        return;
    }

    usage();
    return error.InvalidCommand;
}
