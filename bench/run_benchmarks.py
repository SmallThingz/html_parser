#!/usr/bin/env python3
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
BENCH_DIR = REPO_ROOT / "bench"
BUILD_DIR = BENCH_DIR / "build"
BIN_DIR = BUILD_DIR / "bin"
RESULTS_DIR = BENCH_DIR / "results"
FIXTURES_DIR = BENCH_DIR / "fixtures"

FIXTURES = [
    ("rust-lang.html", 300),
    ("wiki-html.html", 40),
    ("mdn-html.html", 60),
    ("w3-html52.html", 12),
    ("hn.html", 120),
]

PARSERS = [
    "ours",
    "strlen",
    "lexbor",
    "gumbo-modern",
    "html5ever",
]

QUERY_PARSE_CASES = [
    ("simple", "li.x", 1_000_000),
    ("complex", "ul > li.item[data-prefix^=pre]:not(.skip) span.name", 400_000),
    ("grouped", "li#li1, li#li2, li:nth-child(2n+1)", 400_000),
]

QUERY_MATCH_CASES = [
    ("attr-heavy-button", "rust-lang.html", "a[href^=https][class*=button]:not(.missing)", 300_000),
    ("attr-heavy-nav", "rust-lang.html", "a[href^=https][class*=nav]:not(.missing)", 300_000),
]

QUERY_COMPILED_CASES = [
    ("attr-heavy-button", "rust-lang.html", "a[href^=https][class*=button]:not(.missing)", 300_000),
    ("attr-heavy-nav", "rust-lang.html", "a[href^=https][class*=nav]:not(.missing)", 300_000),
]

REPEATS = 5


def run(cmd, cwd=REPO_ROOT):
    print("+", " ".join(cmd))
    subprocess.run(cmd, cwd=cwd, check=True)


def output(cmd, cwd=REPO_ROOT):
    raw = subprocess.check_output(cmd, cwd=cwd, text=True, stderr=subprocess.STDOUT)
    return raw.strip()


def ensure_dirs():
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)


def ensure_external_parsers_built():
    if not (BUILD_DIR / "lexbor" / "liblexbor_static.a").exists():
        run([
            "cmake",
            "-S",
            str(BENCH_DIR / "parsers" / "lexbor"),
            "-B",
            str(BUILD_DIR / "lexbor"),
            "-DCMAKE_BUILD_TYPE=Release",
            "-DLEXBOR_BUILD_TESTS=OFF",
            "-DLEXBOR_BUILD_EXAMPLES=OFF",
        ])
        run(["cmake", "--build", str(BUILD_DIR / "lexbor"), "-j"])

    if not (BUILD_DIR / "gumbo-modern" / "libgumbo.a").exists():
        run([
            "meson",
            "setup",
            str(BUILD_DIR / "gumbo-modern"),
            str(BENCH_DIR / "parsers" / "gumbo-modern"),
            "--buildtype",
            "release",
        ])
        run(["ninja", "-C", str(BUILD_DIR / "gumbo-modern")])


def build_runners():
    run(["zig", "build", "-Doptimize=ReleaseFast"])

    run([
        "cc",
        "-O3",
        "-fno-builtin",
        str(BENCH_DIR / "runners" / "strlen_runner.c"),
        "-o",
        str(BIN_DIR / "strlen_runner"),
    ])

    run([
        "cc",
        "-O3",
        str(BENCH_DIR / "runners" / "lexbor_runner.c"),
        str(BUILD_DIR / "lexbor" / "liblexbor_static.a"),
        "-I" + str(BENCH_DIR / "parsers" / "lexbor" / "source"),
        "-lm",
        "-o",
        str(BIN_DIR / "lexbor_runner"),
    ])

    run([
        "cc",
        "-O3",
        str(BENCH_DIR / "runners" / "gumbo_runner.c"),
        str(BUILD_DIR / "gumbo-modern" / "libgumbo.a"),
        "-I" + str(BENCH_DIR / "parsers" / "gumbo-modern" / "src"),
        "-o",
        str(BIN_DIR / "gumbo_runner"),
    ])

    run([
        "cargo",
        "build",
        "--release",
        "--manifest-path",
        str(BENCH_DIR / "runners" / "html5ever_runner" / "Cargo.toml"),
    ])


def runner_cmd(parser_name: str, fixture: Path, iterations: int):
    if parser_name == "ours":
        return [str(REPO_ROOT / "zig-out" / "bin" / "htmlparser-bench"), str(fixture), str(iterations)]
    if parser_name == "strlen":
        return [str(BIN_DIR / "strlen_runner"), str(fixture), str(iterations)]
    if parser_name == "lexbor":
        return [str(BIN_DIR / "lexbor_runner"), str(fixture), str(iterations)]
    if parser_name == "gumbo-modern":
        return [str(BIN_DIR / "gumbo_runner"), str(fixture), str(iterations)]
    if parser_name == "html5ever":
        return [
            str(BENCH_DIR / "runners" / "html5ever_runner" / "target" / "release" / "html5ever_runner"),
            str(fixture),
            str(iterations),
        ]
    raise ValueError(parser_name)


def bench_parse_one(parser_name: str, fixture_name: str, iterations: int):
    fixture = FIXTURES_DIR / fixture_name
    if not fixture.exists():
        raise FileNotFoundError(f"fixture missing: {fixture}")

    size_bytes = fixture.stat().st_size
    ns_samples = []

    _ = output(runner_cmd(parser_name, fixture, 1))
    for _ in range(REPEATS):
        ns_samples.append(int(output(runner_cmd(parser_name, fixture, iterations))))

    median_ns = int(statistics.median(ns_samples))
    total_bytes = size_bytes * iterations
    seconds = median_ns / 1_000_000_000.0
    mbps = (total_bytes / 1_000_000.0) / seconds if seconds > 0 else 0.0

    return {
        "parser": parser_name,
        "fixture": fixture_name,
        "iterations": iterations,
        "samples_ns": ns_samples,
        "median_ns": median_ns,
        "throughput_mb_s": mbps,
    }


def bench_query_parse_one(case_name: str, selector: str, iterations: int):
    cmd = [str(REPO_ROOT / "zig-out" / "bin" / "htmlparser-bench"), "query-parse", selector, str(iterations)]
    ns_samples = []

    _ = output([cmd[0], "query-parse", selector, "1"])
    for _ in range(REPEATS):
        ns_samples.append(int(output(cmd)))

    median_ns = int(statistics.median(ns_samples))
    seconds = median_ns / 1_000_000_000.0
    ops_s = iterations / seconds if seconds > 0 else 0.0
    ns_per_op = median_ns / iterations if iterations > 0 else 0.0

    return {
        "parser": "ours",
        "case": case_name,
        "selector": selector,
        "iterations": iterations,
        "samples_ns": ns_samples,
        "median_ns": median_ns,
        "ops_s": ops_s,
        "ns_per_op": ns_per_op,
    }


def bench_query_exec_one(case_name: str, fixture_name: str, selector: str, iterations: int, compiled: bool):
    fixture = FIXTURES_DIR / fixture_name
    if not fixture.exists():
        raise FileNotFoundError(f"fixture missing: {fixture}")

    sub = "query-compiled" if compiled else "query-match"
    cmd = [str(REPO_ROOT / "zig-out" / "bin" / "htmlparser-bench"), sub, str(fixture), selector, str(iterations)]
    ns_samples = []

    _ = output([cmd[0], sub, str(fixture), selector, "1"])
    for _ in range(REPEATS):
        ns_samples.append(int(output(cmd)))

    median_ns = int(statistics.median(ns_samples))
    seconds = median_ns / 1_000_000_000.0
    ops_s = iterations / seconds if seconds > 0 else 0.0
    ns_per_op = median_ns / iterations if iterations > 0 else 0.0

    return {
        "parser": "ours",
        "case": case_name,
        "fixture": fixture_name,
        "selector": selector,
        "iterations": iterations,
        "samples_ns": ns_samples,
        "median_ns": median_ns,
        "ops_s": ops_s,
        "ns_per_op": ns_per_op,
    }


def render_markdown(parse_results, query_parse_results, query_match_results, query_compiled_results):
    lines = []
    lines.append("# HTML Parser Benchmark Results")
    lines.append("")
    lines.append(f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    lines.append("")
    lines.append("## Parse Throughput")
    lines.append("")

    grouped = {}
    for row in parse_results:
        grouped.setdefault(row["fixture"], []).append(row)

    for fixture, rows in grouped.items():
        rows = sorted(rows, key=lambda r: r["throughput_mb_s"], reverse=True)
        lines.append(f"## Fixture: `{fixture}`")
        lines.append("")
        lines.append("| Parser | Throughput (MB/s) | Median Time (ms) | Iterations |")
        lines.append("|---|---:|---:|---:|")
        for r in rows:
            lines.append(f"| {r['parser']} | {r['throughput_mb_s']:.2f} | {r['median_ns'] / 1_000_000:.3f} | {r['iterations']} |")
        lines.append("")

    def render_query_section(title, rows):
        lines.append(title)
        lines.append("")
        grouped_cases = {}
        for row in rows:
            grouped_cases.setdefault(row["case"], []).append(row)
        for case_name, case_rows in grouped_cases.items():
            case_rows = sorted(case_rows, key=lambda r: r["ops_s"], reverse=True)
            lines.append(f"### Case: `{case_name}`")
            lines.append("")
            lines.append("| Parser | Ops/s | ns/op | Median Time (ms) | Iterations | Selector |")
            lines.append("|---|---:|---:|---:|---:|---|")
            for r in case_rows:
                lines.append(
                    f"| {r['parser']} | {r['ops_s']:.2f} | {r['ns_per_op']:.2f} | {r['median_ns'] / 1_000_000:.3f} | {r['iterations']} | `{r['selector']}` |"
                )
            if "fixture" in case_rows[0]:
                lines.append("")
                lines.append(f"Fixture: `{case_rows[0]['fixture']}`")
            lines.append("")

    render_query_section("## Query Parse Throughput", query_parse_results)
    render_query_section("## Query Match Throughput", query_match_results)
    render_query_section("## Query Compiled Throughput", query_compiled_results)

    return "\n".join(lines)


def render_console(parse_results, query_parse_results, query_match_results, query_compiled_results):
    lines = []
    lines.append("HTML Parser Benchmark Results")
    lines.append(f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    lines.append("")

    grouped = {}
    for row in parse_results:
        grouped.setdefault(row["fixture"], []).append(row)

    lines.append("Parse Throughput")
    lines.append("")
    for fixture, rows in grouped.items():
        rows = sorted(rows, key=lambda r: r["throughput_mb_s"], reverse=True)
        lines.append(f"Fixture: {fixture}")
        headers = ("Parser", "Throughput (MB/s)", "Median Time (ms)", "Iterations")
        table_rows = [(r["parser"], f"{r['throughput_mb_s']:.2f}", f"{r['median_ns'] / 1_000_000:.3f}", str(r["iterations"])) for r in rows]
        widths = [max(len(headers[i]), *(len(row[i]) for row in table_rows)) for i in range(4)]
        sep = "+-" + "-+-".join("-" * w for w in widths) + "-+"
        lines.append(sep)
        lines.append("| " + headers[0].ljust(widths[0]) + " | " + headers[1].rjust(widths[1]) + " | " + headers[2].rjust(widths[2]) + " | " + headers[3].rjust(widths[3]) + " |")
        lines.append(sep)
        for row in table_rows:
            lines.append("| " + row[0].ljust(widths[0]) + " | " + row[1].rjust(widths[1]) + " | " + row[2].rjust(widths[2]) + " | " + row[3].rjust(widths[3]) + " |")
        lines.append(sep)
        lines.append("")

    def render_query_console(title, rows):
        lines.append(title)
        lines.append("")
        grouped_cases = {}
        for row in rows:
            grouped_cases.setdefault(row["case"], []).append(row)
        for case_name, case_rows in grouped_cases.items():
            case_rows = sorted(case_rows, key=lambda r: r["ops_s"], reverse=True)
            lines.append(f"Case: {case_name}")
            headers = ("Parser", "Ops/s", "ns/op", "Median Time (ms)", "Iterations")
            table_rows = [
                (r["parser"], f"{r['ops_s']:.2f}", f"{r['ns_per_op']:.2f}", f"{r['median_ns'] / 1_000_000:.3f}", str(r["iterations"]))
                for r in case_rows
            ]
            widths = [max(len(headers[i]), *(len(row[i]) for row in table_rows)) for i in range(5)]
            sep = "+-" + "-+-".join("-" * w for w in widths) + "-+"
            lines.append(sep)
            lines.append("| " + headers[0].ljust(widths[0]) + " | " + headers[1].rjust(widths[1]) + " | " + headers[2].rjust(widths[2]) + " | " + headers[3].rjust(widths[3]) + " | " + headers[4].rjust(widths[4]) + " |")
            lines.append(sep)
            for row in table_rows:
                lines.append("| " + row[0].ljust(widths[0]) + " | " + row[1].rjust(widths[1]) + " | " + row[2].rjust(widths[2]) + " | " + row[3].rjust(widths[3]) + " | " + row[4].rjust(widths[4]) + " |")
            lines.append(sep)
            lines.append("Selector:")
            lines.append(f"  {case_rows[0]['selector']}")
            if "fixture" in case_rows[0]:
                lines.append("Fixture:")
                lines.append(f"  {case_rows[0]['fixture']}")
            lines.append("")

    render_query_console("Query Parse Throughput", query_parse_results)
    render_query_console("Query Match Throughput", query_match_results)
    render_query_console("Query Compiled Throughput", query_compiled_results)
    return "\n".join(lines)


def main():
    ensure_dirs()
    ensure_external_parsers_built()
    build_runners()

    parse_results = []
    for fixture_name, iterations in FIXTURES:
        for parser_name in PARSERS:
            print(f"benchmarking {parser_name} on {fixture_name} ({iterations} iters)")
            parse_results.append(bench_parse_one(parser_name, fixture_name, iterations))

    query_parse_results = []
    for case_name, selector, iterations in QUERY_PARSE_CASES:
        print(f"benchmarking query-parse ours on {case_name} ({iterations} iters)")
        query_parse_results.append(bench_query_parse_one(case_name, selector, iterations))

    query_match_results = []
    for case_name, fixture_name, selector, iterations in QUERY_MATCH_CASES:
        print(f"benchmarking query-match ours on {case_name} ({iterations} iters)")
        query_match_results.append(bench_query_exec_one(case_name, fixture_name, selector, iterations, compiled=False))

    query_compiled_results = []
    for case_name, fixture_name, selector, iterations in QUERY_COMPILED_CASES:
        print(f"benchmarking query-compiled ours on {case_name} ({iterations} iters)")
        query_compiled_results.append(bench_query_exec_one(case_name, fixture_name, selector, iterations, compiled=True))

    results_json = {
        "generated_unix": int(time.time()),
        "repeats": REPEATS,
        "parse_results": parse_results,
        "query_parse_results": query_parse_results,
        "query_match_results": query_match_results,
        "query_compiled_results": query_compiled_results,
    }

    json_path = RESULTS_DIR / "latest.json"
    md_path = RESULTS_DIR / "latest.md"

    json_path.write_text(json.dumps(results_json, indent=2), encoding="utf-8")
    md_path.write_text(render_markdown(parse_results, query_parse_results, query_match_results, query_compiled_results) + "\n", encoding="utf-8")

    print(f"wrote {json_path}")
    print(f"wrote {md_path}")
    print("")
    print(render_console(parse_results, query_parse_results, query_match_results, query_compiled_results))


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        print(f"command failed with exit code {e.returncode}: {e.cmd}", file=sys.stderr)
        raise
