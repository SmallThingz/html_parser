#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX_DIR="$ROOT_DIR/bench/fixtures"
mkdir -p "$FIX_DIR"
FORCE_REFRESH="${FORCE_REFRESH:-${FORCE:-0}}"

if [[ "${1:-}" == "--refresh" ]]; then
  FORCE_REFRESH=1
fi

download() {
  local url="$1"
  local out="$2"
  local target="$FIX_DIR/$out"

  if [[ "$FORCE_REFRESH" != "1" && -s "$target" ]]; then
    echo "cached: $out"
    return
  fi

  echo "downloading: $out"
  curl -L --fail --retry 2 --retry-delay 1 \
    -A "htmlparser-bench/1.0 (+https://example.invalid)" \
    "$url" -o "$target"
}

download "https://www.rust-lang.org/" "rust-lang.html"
download "https://en.wikipedia.org/wiki/HTML" "wiki-html.html"
download "https://developer.mozilla.org/en-US/docs/Web/HTML" "mdn-html.html"
download "https://www.w3.org/TR/html52/" "w3-html52.html"
download "https://news.ycombinator.com/" "hn.html"

echo "fixtures ready in $FIX_DIR"
