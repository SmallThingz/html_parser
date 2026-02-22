#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import tempfile
from pathlib import Path

REPO = Path("/home/a/projects/zig/htmlparser")
SUITES = Path("/tmp/htmlparser-suites")
RUNNER = REPO / "bench" / "build" / "bin" / "suite_runner"

SUPPORTED_PSEUDOS = {
    ":first-child",
    ":last-child",
}


def shell_output(cmd):
    p = subprocess.run(cmd, capture_output=True, check=True)
    return p.stdout.decode("utf-8").strip()


def run(cmd, cwd=REPO):
    subprocess.run(cmd, cwd=cwd, check=True)


def ensure_suites():
    SUITES.mkdir(parents=True, exist_ok=True)
    repos = {
        "html5lib-tests": "https://github.com/html5lib/html5lib-tests.git",
        "css-select": "https://github.com/fb55/css-select.git",
    }
    for name, url in repos.items():
        dst = SUITES / name
        if dst.exists():
            continue
        run(["git", "clone", "--depth", "1", url, str(dst)], cwd=SUITES)


def build_runner():
    (REPO / "bench" / "build" / "bin").mkdir(parents=True, exist_ok=True)
    run(
        [
            "zig",
            "build-exe",
            str(REPO / "src" / "suite_runner.zig"),
            "-O",
            "ReleaseFast",
            "-femit-bin=" + str(RUNNER),
        ]
    )


def selector_supported(sel: str) -> bool:
    s = sel.strip()
    if not s:
        return False
    if any(ord(ch) > 127 for ch in s):
        return False

    if "\\:" in s or "|" in s and not re.search(r"\[[^\]]*\|=", s):
        return False

    pseudos = re.findall(r":([a-zA-Z-]+)", s)
    for p in pseudos:
        full = ":" + p
        if full in SUPPORTED_PSEUDOS:
            continue
        if p == "nth-child":
            continue
        if p == "not":
            continue
        return False

    unsupported_tokens = [
        ":contains",
        ":has(",
        ":checked",
        ":enabled",
        ":disabled",
        ":selected",
        ":input",
        ":button",
        ":header",
        ":parent",
        ":empty",
        ":only-child",
        ":nth-of-type",
        ":nth-last-child",
        ":nth-last-of-type",
        ":first-of-type",
        ":last-of-type",
        ":only-of-type",
        ":root",
        ":lang(",
        ":target",
    ]
    return not any(tok in s for tok in unsupported_tokens)


def extract_count_cases(ts_source: str):
    pat = re.compile(
        r"expect\(\s*select(?:All)?\(\s*\"((?:\\.|[^\"])*)\"(?:\s*,[^\)]*)?\)\s*\)\s*\.toHaveLength\(\s*(\d+)\s*\)",
        re.M,
    )
    out = []
    for m in pat.finditer(ts_source):
        sel = bytes(m.group(1), "utf-8").decode("unicode_escape")
        if not selector_supported(sel):
            continue
        out.append((sel, int(m.group(2))))
    return out


def extract_qwery_context_html(qwery_src: str, const_name: str) -> str:
    m = re.search(rf"const\s+{const_name}\s*=\s*parseDOM\((.*?)\);", qwery_src, re.S)
    if not m:
        raise RuntimeError(f"missing parseDOM const {const_name}")
    expr = m.group(1)
    parts = []
    for _, body in re.findall(r"(['\"])((?:\\.|(?!\1).)*)\1", expr, re.S):
        parts.append(bytes(body, "utf-8").decode("unicode_escape"))
    return "".join(parts)


def extract_qwery_context_cases(qwery_src: str):
    # direct context: selectAll("...", doc|frag)
    direct_pat = re.compile(
        r"expect\(\s*selectAll\(\s*\"((?:\\.|[^\"])*)\"\s*,\s*(doc|frag)\s*\)\s*\)\s*\.toHaveLength\(\s*(\d+)\s*\)",
        re.M,
    )
    # default context: selectAll("...")
    default_pat = re.compile(
        r"expect\(\s*selectAll\(\s*\"((?:\\.|[^\"])*)\"\s*\)\s*\)\s*\.toHaveLength\(\s*(\d+)\s*\)",
        re.M,
    )

    seen = set()
    out = []

    for m in direct_pat.finditer(qwery_src):
        sel = bytes(m.group(1), "utf-8").decode("unicode_escape")
        if not selector_supported(sel):
            continue
        ctx = m.group(2)
        expected = int(m.group(3))
        key = (sel, ctx, expected)
        if key in seen:
            continue
        seen.add(key)
        out.append((sel, ctx, expected))

    for m in default_pat.finditer(qwery_src):
        sel = bytes(m.group(1), "utf-8").decode("unicode_escape")
        if not selector_supported(sel):
            continue
        expected = int(m.group(2))
        key = (sel, "document", expected)
        if key in seen:
            continue
        seen.add(key)
        out.append((sel, "document", expected))

    return out


def run_selector_suite(mode: str):
    css_dir = SUITES / "css-select" / "test"

    nw_src = (css_dir / "nwmatcher.ts").read_text(encoding="utf-8")
    qw_src = (css_dir / "qwery.ts").read_text(encoding="utf-8")

    nw_cases = extract_count_cases(nw_src)[:140]
    qw_cases = extract_qwery_context_cases(qw_src)

    nw_fixture = str(css_dir / "fixtures" / "nwmatcher.html")
    qw_fixture = str(css_dir / "fixtures" / "qwery.html")
    qw_frag_html = extract_qwery_context_html(qw_src, "frag")
    qw_doc_html = extract_qwery_context_html(qw_src, "doc")

    nw_pass = 0
    nw_fail = []
    for sel, expected_count in nw_cases:
        try:
            got = int(shell_output([str(RUNNER), "selector-count", mode, nw_fixture, sel]))
            if got == expected_count:
                nw_pass += 1
            else:
                nw_fail.append((sel, expected_count, got))
        except subprocess.CalledProcessError:
            nw_fail.append((sel, expected_count, "<parse-error>"))

    qw_pass = 0
    qw_fail = []
    for sel, ctx, expected_count in qw_cases:
        try:
            if ctx == "document":
                got = int(shell_output([str(RUNNER), "selector-count", mode, qw_fixture, sel]))
            else:
                html_in = qw_doc_html if ctx == "doc" else qw_frag_html
                with tempfile.NamedTemporaryFile(mode="wb", suffix=".html") as tf:
                    tf.write(html_in.encode("utf-8", errors="replace"))
                    tf.flush()
                    got = int(shell_output([str(RUNNER), "selector-count-scope-tag", mode, tf.name, "root", sel]))
            if got == expected_count:
                qw_pass += 1
            else:
                qw_fail.append((ctx, sel, expected_count, got))
        except subprocess.CalledProcessError:
            qw_fail.append((ctx, sel, expected_count, "<parse-error>"))

    return {
        "nwmatcher": {
            "total": len(nw_cases),
            "passed": nw_pass,
            "failed": len(nw_fail),
            "examples": nw_fail[:8],
        },
        "qwery_contextual": {
            "total": len(qw_cases),
            "passed": qw_pass,
            "failed": len(qw_fail),
            "examples": qw_fail[:8],
        },
    }


def parse_html5lib_dat(path: Path):
    text = path.read_text(encoding="utf-8", errors="replace")
    blocks = text.split("\n#data\n")
    tests = []
    for blk in blocks:
        if blk.startswith("#data\n"):
            blk = blk[len("#data\n") :]
        if "#document" not in blk:
            continue
        try:
            data_part, rest = blk.split("\n#document\n", 1)
        except ValueError:
            continue

        html_in = data_part
        if "\n#errors\n" in html_in:
            html_in = html_in.split("\n#errors\n", 1)[0]
        if "\n#document-fragment\n" in html_in:
            continue

        expected_tags = []
        for ln in rest.splitlines():
            m = re.search(r"<([a-zA-Z0-9:-]+)>", ln)
            if not m:
                continue
            t = m.group(1).lower()
            if t in {"html", "head", "body", "tbody", "tr"}:
                continue
            expected_tags.append(t)

        tests.append((html_in, expected_tags))
    return tests


def run_parser_suite(mode: str, max_cases: int):
    tc_dir = SUITES / "html5lib-tests" / "tree-construction"
    dat_files = sorted(tc_dir.glob("*.dat"))

    all_tests = []
    for f in dat_files:
        all_tests.extend(parse_html5lib_dat(f))

    cases = all_tests[:max_cases]

    passed = 0
    failed = []

    for html_in, expected_tags in cases:
        with tempfile.NamedTemporaryFile(mode="wb", suffix=".html") as tf:
            tf.write(html_in.encode("utf-8", errors="replace"))
            tf.flush()
            out = shell_output([str(RUNNER), "parse-tags-file", mode, tf.name])
        got_tags = [t.lower() for t in json.loads(out)]
        if got_tags == expected_tags:
            passed += 1
        else:
            failed.append((html_in[:100].replace("\n", "\\n"), expected_tags[:12], got_tags[:12]))

    return {
        "total": len(cases),
        "passed": passed,
        "failed": len(failed),
        "examples": failed[:10],
    }


def run_mode(mode: str, max_cases: int):
    selector = run_selector_suite(mode)
    parser = run_parser_suite(mode, max_cases)
    return {
        "selector_suites": selector,
        "parser_suite": parser,
    }


def main():
    ap = argparse.ArgumentParser(description="Run external conformance suites against htmlparser")
    ap.add_argument("--mode", choices=["strict", "turbo", "both"], default="both")
    ap.add_argument("--max-html5lib-cases", type=int, default=600)
    ap.add_argument("--json-out", type=Path, default=REPO / "bench" / "results" / "external_suite_report.json")
    args = ap.parse_args()

    ensure_suites()
    build_runner()

    modes = ["strict", "turbo"] if args.mode == "both" else [args.mode]
    report = {"modes": {}}

    for mode in modes:
        data = run_mode(mode, args.max_html5lib_cases)
        report["modes"][mode] = data

        print(f"Mode: {mode}")
        print("  Selector suites:")
        for name, suite in data["selector_suites"].items():
            print(f"    {name}: {suite['passed']}/{suite['total']} passed ({suite['failed']} failed)")
        p = data["parser_suite"]
        print(f"  Parser suite: html5lib tree-construction (compat subset): {p['passed']}/{p['total']} passed ({p['failed']} failed)")

    args.json_out.parent.mkdir(parents=True, exist_ok=True)
    args.json_out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Wrote report: {args.json_out}")


if __name__ == "__main__":
    main()
