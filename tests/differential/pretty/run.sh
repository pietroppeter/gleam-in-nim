#!/usr/bin/env bash
# Differential test of the pretty printer: random documents, printed at ten
# widths by upstream's Rust pretty-arena and by the Nim port. The two outputs
# must be identical, byte for byte.
#
#   tests/differential/pretty/run.sh [SEED] [COUNT]     default: seed 1, 20000 documents
#
# Needs cargo, and the pinned source (reference/fetch.sh source).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
seed="${1:-1}"
count="${2:-20000}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cargo build --quiet --release
nim c --hints:off --verbosity:0 -d:release -o:"$work/driver" driver.nim
"$work/driver" generate "$seed" "$count" > "$work/documents.txt"
./target/release/pretty-driver < "$work/documents.txt" > "$work/rust.txt"
"$work/driver" print < "$work/documents.txt" > "$work/nim.txt"

printings="$(wc -l < "$work/rust.txt")"
if cmp -s "$work/rust.txt" "$work/nim.txt"; then
  echo "pretty printer: $count documents, $printings printings, identical (seed $seed)"
else
  line="$(cmp "$work/rust.txt" "$work/nim.txt" | sed 's/.*line //')"
  echo "pretty printer: outputs differ at printing $line (seed $seed)"
  echo "document: $(sed -n "$(( (line - 1) / 10 + 1 ))p" "$work/documents.txt")"
  echo "rust: $(sed -n "${line}p" "$work/rust.txt")"
  echo "nim:  $(sed -n "${line}p" "$work/nim.txt")"
  exit 1
fi
