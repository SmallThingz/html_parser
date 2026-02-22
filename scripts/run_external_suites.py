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

# We support :nth-child(...) and :not(simple)

def shell_output(cmd, input_bytes=None):
    p = subprocess.run(cmd, input=input_bytes, capture_output=True, check=True)
    return p.stdout.decode("utf-8").strip()


def build_runner():
    (REPO / "bench" / "build" / "bin").mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "zig",
            "build-exe",
            str(REPO / "src" / "suite_runner.zig"),
            "-O",
            "ReleaseFast",
            "-femit-bin=" + str(RUNNER),
        ],
        cwd=REPO,
        check=True,
    )


def selector_supported(sel: str) -> bool:
    s = sel.strip()
    if not s:
        return False
    if any(ord(ch) > 127 for ch in s):
        return False

    # Skip namespace/escape-heavy cases and custom pseudos.
    if "\\:" in s or "|" in s and not re.search(r"\[[^\]]*\|=", s):
        return False

    # Reject unsupported pseudos.
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
    # expect(select("..."))...toHaveLength(N)
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


def run_selector_suite():
    css_dir = SUITES / "css-select" / "test"

    nw_src = (css_dir / "nwmatcher.ts").read_text(encoding="utf-8")
    qw_src = (css_dir / "qwery.ts").read_text(encoding="utf-8")

    nw_cases = extract_count_cases(nw_src)
    qw_cases = extract_count_cases(qw_src)

    # Keep runtime reasonable.
    nw_cases = nw_cases[:140]
    qw_cases = qw_cases[:140]

    nw_fixture = str(css_dir / "fixtures" / "nwmatcher.html")
    qw_fixture = str(css_dir / "fixtures" / "qwery.html")

    nw_pass = 0
    nw_fail = []
    for sel, expected_count in nw_cases:
        try:
            got = int(shell_output([str(RUNNER), "selector-count", nw_fixture, sel]))
            if got == expected_count:
                nw_pass += 1
            else:
                nw_fail.append((sel, expected_count, got))
        except subprocess.CalledProcessError:
            nw_fail.append((sel, expected_count, "<parse-error>"))

    qw_pass = 0
    qw_fail = []
    for sel, expected_count in qw_cases:
        try:
            got = int(shell_output([str(RUNNER), "selector-count", qw_fixture, sel]))
            if got == expected_count:
                qw_pass += 1
            else:
                qw_fail.append((sel, expected_count, got))
        except subprocess.CalledProcessError:
            qw_fail.append((sel, expected_count, "<parse-error>"))

    return {
        "nwmatcher": {
            "total": len(nw_cases),
            "passed": nw_pass,
            "failed": len(nw_fail),
            "examples": nw_fail[:8],
        },
        "qwery": {
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
        # Drop optional leading sections like #errors.
        if "\n#errors\n" in html_in:
            html_in = html_in.split("\n#errors\n", 1)[0]
        if "\n#document-fragment\n" in html_in:
            # We don't support fragment-context parsing from this suite format yet.
            continue

        expected_lines = rest.splitlines()
        expected_tags = []
        for ln in expected_lines:
            m = re.search(r"<([a-zA-Z0-9:-]+)>", ln)
            if not m:
                continue
            t = m.group(1).lower()
            if t in {"html", "head", "body", "tbody", "tr"}:
                # Ignore auto-inserted wrappers for compatibility scoring.
                continue
            expected_tags.append(t)

        tests.append((html_in, expected_tags))
    return tests


def run_parser_suite(max_cases: int):
    tc_dir = SUITES / "html5lib-tests" / "tree-construction"
    dat_files = sorted(tc_dir.glob("*.dat"))

    all_tests = []
    for f in dat_files:
        all_tests.extend(parse_html5lib_dat(f))

    # Deterministic capped run.
    cases = all_tests[:max_cases]

    passed = 0
    failed = []

    for html_in, expected_tags in cases:
        with tempfile.NamedTemporaryFile(mode="wb", suffix=".html") as tf:
            tf.write(html_in.encode("utf-8", errors="replace"))
            tf.flush()
            out = shell_output([str(RUNNER), "parse-tags-file", tf.name])
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


def main():
    ap = argparse.ArgumentParser(description="Run external conformance suites against htmlparser")
    ap.add_argument("--max-html5lib-cases", type=int, default=600)
    ap.add_argument("--json-out", type=Path, default=REPO / "bench" / "results" / "external_suite_report.json")
    args = ap.parse_args()

    if not (SUITES / "html5lib-tests").exists() or not (SUITES / "css-select").exists():
        raise SystemExit("Missing external suites under /tmp/htmlparser-suites. Clone them first.")

    build_runner()

    selector = run_selector_suite()
    parser = run_parser_suite(args.max_html5lib_cases)

    report = {
        "selector_suites": selector,
        "parser_suite": parser,
    }

    args.json_out.parent.mkdir(parents=True, exist_ok=True)
    args.json_out.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("Selector suites:")
    for name, data in selector.items():
        print(f"  {name}: {data['passed']}/{data['total']} passed ({data['failed']} failed)")
    print("Parser suite:")
    print(f"  html5lib tree-construction (compat subset): {parser['passed']}/{parser['total']} passed ({parser['failed']} failed)")
    print(f"Wrote report: {args.json_out}")


if __name__ == "__main__":
    main()
