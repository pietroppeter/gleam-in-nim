#!/usr/bin/env bash
# Builds the parser oracle: target/release/parse-driver.
#
# The driver needs two functions that upstream compiles only for its own
# tests (`parse_statement_sequence` and `parse_const_value` are `#[cfg(test)]`).
# So it is built against a copy of the pinned checkout, in build/parse-oracle,
# where those two attributes are removed. Nothing else is changed.
#
# Needs cargo (Rust 1.99 or later) and the pinned source (bash reference/fetch.sh).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
root="../../.."
copy="$root/build/parse-oracle/gleam"
if [ ! -d "$root/reference/gleam/compiler-core" ]; then
  echo "ERROR no pinned source: run bash reference/fetch.sh" >&2
  exit 1
fi
if [ ! -f "$copy/.patched" ]; then
  rm -rf "$copy"
  mkdir -p "$(dirname "$copy")"
  cp -r "$root/reference/gleam" "$copy"
  rm -rf "$copy/.git"
  # Remove `#[cfg(test)]` on the line before each of the two functions.
  python3 - "$copy/compiler-core/src/parse.rs" <<'PY'
import sys
path = sys.argv[1]
lines = open(path).read().split("\n")
wanted = ("pub fn parse_statement_sequence(", "pub fn parse_const_value(")
removed = 0
out = []
for i, line in enumerate(lines):
    nxt = lines[i + 1] if i + 1 < len(lines) else ""
    if line.strip() == "#[cfg(test)]" and nxt.startswith(wanted):
        removed += 1
        continue
    out.append(line)
assert removed == 2, f"expected to remove 2 attributes, removed {removed}"
open(path, "w").write("\n".join(out))
PY
  touch "$copy/.patched"
fi
cargo build --quiet --release
