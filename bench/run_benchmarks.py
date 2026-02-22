#!/usr/bin/env python3
import json
import os
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
    {"name": "ours-inline", "base": "ours", "mode": "inline"},
    {"name": "ours-legacy", "base": "ours", "mode": "legacy"},
    {"name": "lexbor", "base": "lexbor", "mode": "-"},
    {"name": "gumbo-modern", "base": "gumbo-modern", "mode": "-"},
    {"name": "html5ever", "base": "html5ever", "mode": "-"},
]

QUERY_CASES = [
    ("simple", "li.x", 1_000_000),
    ("complex", "ul > li.item[data-prefix^=pre]:not(.skip) span.name", 400_000),
    ("grouped", "li#li1, li#li2, li:nth-child(2n+1)", 400_000),
]

QUERY_PARSERS = [
    {"name": "ours-inline", "base": "ours", "mode": "inline"},
    {"name": "ours-legacy", "base": "ours", "mode": "legacy"},
]

QUERY_MATCH_CASES = [
    ("attr-heavy", "rust-lang.html", "a[href^=https][class*=nav]:not(.missing)", 300_000),
]

QUERY_MATCH_PARSERS = [
    {"name": "ours-inline", "base": "ours", "mode": "inline"},
    {"name": "ours-legacy", "base": "ours", "mode": "legacy"},
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
    # Lexbor
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

    # Gumbo modern
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


def runner_cmd(parser_base: str, fixture: Path, iterations: int, mode: str):
    if parser_base == "ours":
        return [str(REPO_ROOT / "zig-out" / "bin" / "htmlparser-bench"), str(fixture), str(iterations), mode]
    if parser_base == "lexbor":
        return [str(BIN_DIR / "lexbor_runner"), str(fixture), str(iterations)]
    if parser_base == "gumbo-modern":
        return [str(BIN_DIR / "gumbo_runner"), str(fixture), str(iterations)]
    if parser_base == "html5ever":
        return [
            str(BENCH_DIR / "runners" / "html5ever_runner" / "target" / "release" / "html5ever_runner"),
            str(fixture),
            str(iterations),
        ]
    raise ValueError(parser_base)


def bench_one(parser: dict, fixture_name: str, iterations: int):
    fixture = FIXTURES_DIR / fixture_name
    if not fixture.exists():
        raise FileNotFoundError(f"fixture missing: {fixture}")

    size_bytes = fixture.stat().st_size
    ns_samples = []

    # warmup
    _ = output(runner_cmd(parser["base"], fixture, 1, parser["mode"]))

    for _ in range(REPEATS):
        ns = int(output(runner_cmd(parser["base"], fixture, iterations, parser["mode"])))
        ns_samples.append(ns)

    median_ns = int(statistics.median(ns_samples))
    total_bytes = size_bytes * iterations
    seconds = median_ns / 1_000_000_000.0
    mbps = (total_bytes / 1_000_000.0) / seconds if seconds > 0 else 0.0

    return {
        "parser": parser["name"],
        "mode": parser["mode"],
        "fixture": fixture_name,
        "iterations": iterations,
        "fixture_bytes": size_bytes,
        "samples_ns": ns_samples,
        "median_ns": median_ns,
        "throughput_mb_s": mbps,
    }


def render_markdown(parse_results, query_results, query_match_results):
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
        lines.append("| Parser | Mode | Throughput (MB/s) | Median Time (ms) | Iterations |")
        lines.append("|---|---|---:|---:|---:|")
        for r in rows:
            lines.append(
                f"| {r['parser']} | {r['mode']} | {r['throughput_mb_s']:.2f} | {r['median_ns'] / 1_000_000:.3f} | {r['iterations']} |"
            )
        lines.append("")

    lines.append("## Query Parse Throughput")
    lines.append("")

    query_grouped = {}
    for row in query_results:
        query_grouped.setdefault(row["case"], []).append(row)

    for case_name, rows in query_grouped.items():
        rows = sorted(rows, key=lambda r: r["ops_s"], reverse=True)
        lines.append(f"### Case: `{case_name}`")
        lines.append("")
        lines.append("| Parser | Mode | Ops/s | ns/op | Median Time (ms) | Iterations | Selector |")
        lines.append("|---|---|---:|---:|---:|---:|---|")
        for r in rows:
            lines.append(
                f"| {r['parser']} | {r['mode']} | {r['ops_s']:.2f} | {r['ns_per_op']:.2f} | {r['median_ns'] / 1_000_000:.3f} | {r['iterations']} | `{r['selector']}` |"
            )
        lines.append("")

    lines.append("## Query Match Throughput")
    lines.append("")

    query_match_grouped = {}
    for row in query_match_results:
        query_match_grouped.setdefault(row["case"], []).append(row)

    for case_name, rows in query_match_grouped.items():
        rows = sorted(rows, key=lambda r: r["ops_s"], reverse=True)
        lines.append(f"### Case: `{case_name}`")
        lines.append("")
        lines.append("| Parser | Mode | Ops/s | ns/op | Median Time (ms) | Iterations | Selector | Fixture |")
        lines.append("|---|---|---:|---:|---:|---:|---|---|")
        for r in rows:
            lines.append(
                f"| {r['parser']} | {r['mode']} | {r['ops_s']:.2f} | {r['ns_per_op']:.2f} | {r['median_ns'] / 1_000_000:.3f} | {r['iterations']} | `{r['selector']}` | `{r['fixture']}` |"
            )
        lines.append("")

    return "\n".join(lines)


def render_console(parse_results, query_results, query_match_results):
    lines = []
    lines.append("HTML Parser Benchmark Results")
    lines.append(f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    lines.append("")
    lines.append("Parse Throughput")
    lines.append("")

    grouped = {}
    for row in parse_results:
        grouped.setdefault(row["fixture"], []).append(row)

    for fixture, rows in grouped.items():
        rows = sorted(rows, key=lambda r: r["throughput_mb_s"], reverse=True)
        lines.append(f"Fixture: {fixture}")

        table_rows = []
        for r in rows:
            table_rows.append(
                (
                    r["parser"],
                    r["mode"],
                    f"{r['throughput_mb_s']:.2f}",
                    f"{r['median_ns'] / 1_000_000:.3f}",
                    str(r["iterations"]),
                )
            )

        headers = ("Parser", "Mode", "Throughput (MB/s)", "Median Time (ms)", "Iterations")
        widths = [
            max(len(headers[0]), *(len(row[0]) for row in table_rows)),
            max(len(headers[1]), *(len(row[1]) for row in table_rows)),
            max(len(headers[2]), *(len(row[2]) for row in table_rows)),
            max(len(headers[3]), *(len(row[3]) for row in table_rows)),
            max(len(headers[4]), *(len(row[4]) for row in table_rows)),
        ]

        sep = "+-" + "-+-".join("-" * w for w in widths) + "-+"
        lines.append(sep)
        lines.append(
            "| "
            + headers[0].ljust(widths[0])
            + " | "
            + headers[1].rjust(widths[1])
            + " | "
            + headers[2].rjust(widths[2])
            + " | "
            + headers[3].rjust(widths[3])
            + " | "
            + headers[4].rjust(widths[4])
            + " |"
        )
        lines.append(sep)
        for row in table_rows:
            lines.append(
                "| "
                + row[0].ljust(widths[0])
                + " | "
                + row[1].rjust(widths[1])
                + " | "
                + row[2].rjust(widths[2])
                + " | "
                + row[3].rjust(widths[3])
                + " | "
                + row[4].rjust(widths[4])
                + " |"
            )
        lines.append(sep)
        lines.append("")

    lines.append("Query Parse Throughput")
    lines.append("")

    query_grouped = {}
    for row in query_results:
        query_grouped.setdefault(row["case"], []).append(row)

    for case_name, rows in query_grouped.items():
        rows = sorted(rows, key=lambda r: r["ops_s"], reverse=True)
        lines.append(f"Case: {case_name}")

        table_rows = []
        for r in rows:
            table_rows.append(
                (
                    r["parser"],
                    r["mode"],
                    f"{r['ops_s']:.2f}",
                    f"{r['ns_per_op']:.2f}",
                    f"{r['median_ns'] / 1_000_000:.3f}",
                    str(r["iterations"]),
                )
            )

        headers = ("Parser", "Mode", "Ops/s", "ns/op", "Median Time (ms)", "Iterations")
        widths = [
            max(len(headers[0]), *(len(row[0]) for row in table_rows)),
            max(len(headers[1]), *(len(row[1]) for row in table_rows)),
            max(len(headers[2]), *(len(row[2]) for row in table_rows)),
            max(len(headers[3]), *(len(row[3]) for row in table_rows)),
            max(len(headers[4]), *(len(row[4]) for row in table_rows)),
            max(len(headers[5]), *(len(row[5]) for row in table_rows)),
        ]

        sep = "+-" + "-+-".join("-" * w for w in widths) + "-+"
        lines.append(sep)
        lines.append(
            "| "
            + headers[0].ljust(widths[0])
            + " | "
            + headers[1].rjust(widths[1])
            + " | "
            + headers[2].rjust(widths[2])
            + " | "
            + headers[3].rjust(widths[3])
            + " | "
            + headers[4].rjust(widths[4])
            + " | "
            + headers[5].rjust(widths[5])
            + " |"
        )
        lines.append(sep)
        for row in table_rows:
            lines.append(
                "| "
                + row[0].ljust(widths[0])
                + " | "
                + row[1].rjust(widths[1])
                + " | "
                + row[2].rjust(widths[2])
                + " | "
                + row[3].rjust(widths[3])
                + " | "
                + row[4].rjust(widths[4])
                + " | "
                + row[5].rjust(widths[5])
                + " |"
            )
        lines.append(sep)
        lines.append("Selector:")
        lines.append(f"  {rows[0]['selector']}")
        lines.append("")

    lines.append("Query Match Throughput")
    lines.append("")

    query_match_grouped = {}
    for row in query_match_results:
        query_match_grouped.setdefault(row["case"], []).append(row)

    for case_name, rows in query_match_grouped.items():
        rows = sorted(rows, key=lambda r: r["ops_s"], reverse=True)
        lines.append(f"Case: {case_name}")

        table_rows = []
        for r in rows:
            table_rows.append(
                (
                    r["parser"],
                    r["mode"],
                    f"{r['ops_s']:.2f}",
                    f"{r['ns_per_op']:.2f}",
                    f"{r['median_ns'] / 1_000_000:.3f}",
                    str(r["iterations"]),
                )
            )

        headers = ("Parser", "Mode", "Ops/s", "ns/op", "Median Time (ms)", "Iterations")
        widths = [
            max(len(headers[0]), *(len(row[0]) for row in table_rows)),
            max(len(headers[1]), *(len(row[1]) for row in table_rows)),
            max(len(headers[2]), *(len(row[2]) for row in table_rows)),
            max(len(headers[3]), *(len(row[3]) for row in table_rows)),
            max(len(headers[4]), *(len(row[4]) for row in table_rows)),
            max(len(headers[5]), *(len(row[5]) for row in table_rows)),
        ]

        sep = "+-" + "-+-".join("-" * w for w in widths) + "-+"
        lines.append(sep)
        lines.append(
            "| "
            + headers[0].ljust(widths[0])
            + " | "
            + headers[1].ljust(widths[1])
            + " | "
            + headers[2].rjust(widths[2])
            + " | "
            + headers[3].rjust(widths[3])
            + " | "
            + headers[4].rjust(widths[4])
            + " | "
            + headers[5].rjust(widths[5])
            + " |"
        )
        lines.append(sep)
        for row in table_rows:
            lines.append(
                "| "
                + row[0].ljust(widths[0])
                + " | "
                + row[1].ljust(widths[1])
                + " | "
                + row[2].rjust(widths[2])
                + " | "
                + row[3].rjust(widths[3])
                + " | "
                + row[4].rjust(widths[4])
                + " | "
                + row[5].rjust(widths[5])
                + " |"
            )
        lines.append(sep)
        lines.append("Selector:")
        lines.append(f"  {rows[0]['selector']}")
        lines.append("Fixture:")
        lines.append(f"  {rows[0]['fixture']}")
        lines.append("")

    return "\n".join(lines)


def query_parse_runner_cmd(parser: dict, selector: str, iterations: int):
    if parser["base"] == "ours":
        return [
            str(REPO_ROOT / "zig-out" / "bin" / "htmlparser-bench"),
            "query-parse",
            selector,
            str(iterations),
            parser["mode"],
        ]
    raise ValueError(parser["base"])


def bench_query_parse_one(parser: dict, case_name: str, selector: str, iterations: int):
    ns_samples = []

    _ = output(query_parse_runner_cmd(parser, selector, 1))

    for _ in range(REPEATS):
        ns = int(output(query_parse_runner_cmd(parser, selector, iterations)))
        ns_samples.append(ns)

    median_ns = int(statistics.median(ns_samples))
    seconds = median_ns / 1_000_000_000.0
    ops_s = iterations / seconds if seconds > 0 else 0.0
    ns_per_op = median_ns / iterations if iterations > 0 else 0.0

    return {
        "parser": parser["name"],
        "mode": parser["mode"],
        "case": case_name,
        "selector": selector,
        "iterations": iterations,
        "samples_ns": ns_samples,
        "median_ns": median_ns,
        "ops_s": ops_s,
        "ns_per_op": ns_per_op,
    }


def query_match_runner_cmd(parser: dict, fixture: Path, selector: str, iterations: int):
    if parser["base"] == "ours":
        return [
            str(REPO_ROOT / "zig-out" / "bin" / "htmlparser-bench"),
            "query-match",
            str(fixture),
            selector,
            str(iterations),
            parser["mode"],
        ]
    raise ValueError(parser["base"])


def bench_query_match_one(parser: dict, case_name: str, fixture_name: str, selector: str, iterations: int):
    fixture = FIXTURES_DIR / fixture_name
    if not fixture.exists():
        raise FileNotFoundError(f"fixture missing: {fixture}")

    ns_samples = []
    _ = output(query_match_runner_cmd(parser, fixture, selector, 1))

    for _ in range(REPEATS):
        ns = int(output(query_match_runner_cmd(parser, fixture, selector, iterations)))
        ns_samples.append(ns)

    median_ns = int(statistics.median(ns_samples))
    seconds = median_ns / 1_000_000_000.0
    ops_s = iterations / seconds if seconds > 0 else 0.0
    ns_per_op = median_ns / iterations if iterations > 0 else 0.0

    return {
        "parser": parser["name"],
        "mode": parser["mode"],
        "case": case_name,
        "fixture": fixture_name,
        "selector": selector,
        "iterations": iterations,
        "samples_ns": ns_samples,
        "median_ns": median_ns,
        "ops_s": ops_s,
        "ns_per_op": ns_per_op,
    }


def main():
    ensure_dirs()
    ensure_external_parsers_built()
    build_runners()

    parse_results = []
    for fixture_name, iterations in FIXTURES:
        for parser in PARSERS:
            print(f"benchmarking {parser['name']} on {fixture_name} ({iterations} iters)")
            row = bench_one(parser, fixture_name, iterations)
            parse_results.append(row)

    query_results = []
    for case_name, selector, iterations in QUERY_CASES:
        for parser in QUERY_PARSERS:
            print(f"benchmarking query-parse {parser['name']} on {case_name} ({iterations} iters)")
            row = bench_query_parse_one(parser, case_name, selector, iterations)
            query_results.append(row)

    query_match_results = []
    for case_name, fixture_name, selector, iterations in QUERY_MATCH_CASES:
        for parser in QUERY_MATCH_PARSERS:
            print(f"benchmarking query-match {parser['name']} on {case_name} ({iterations} iters)")
            row = bench_query_match_one(parser, case_name, fixture_name, selector, iterations)
            query_match_results.append(row)

    results_json = {
        "generated_unix": int(time.time()),
        "repeats": REPEATS,
        "results": parse_results,
        "parse_results": parse_results,
        "query_parse_results": query_results,
        "query_match_results": query_match_results,
    }

    json_path = RESULTS_DIR / "latest.json"
    md_path = RESULTS_DIR / "latest.md"

    json_path.write_text(json.dumps(results_json, indent=2), encoding="utf-8")
    md_path.write_text(render_markdown(parse_results, query_results, query_match_results) + "\n", encoding="utf-8")

    print(f"wrote {json_path}")
    print(f"wrote {md_path}")
    print("")
    print(render_console(parse_results, query_results, query_match_results))


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        print(f"command failed with exit code {e.returncode}: {e.cmd}", file=sys.stderr)
        raise
