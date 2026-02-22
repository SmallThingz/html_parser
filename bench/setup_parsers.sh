#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSERS_DIR="$ROOT_DIR/bench/parsers"

mkdir -p "$PARSERS_DIR"

clone_if_missing() {
  local url="$1"
  local dir="$2"
  if [[ -d "$PARSERS_DIR/$dir/.git" ]]; then
    echo "already present: $dir"
    return
  fi
  echo "cloning: $dir"
  git clone --depth 1 "$url" "$PARSERS_DIR/$dir"
}

clone_if_missing "https://github.com/lexbor/lexbor.git" "lexbor"
clone_if_missing "https://codeberg.org/gumbo-parser/gumbo-parser.git" "gumbo-modern"
clone_if_missing "https://github.com/servo/html5ever.git" "html5ever"
clone_if_missing "https://github.com/cloudflare/lol-html.git" "lol-html"

echo "done"
