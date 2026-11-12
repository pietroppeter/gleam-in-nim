#!/usr/bin/env bash
# Differential test of versions and ranges: random versions, requirements and
# operations on ranges, answered by upstream's Rust (the hexpm crate of the
# pinned checkout, and the pubgrub crate at the version of Gleam's Cargo.lock)
# and by the Nim port. The two outputs must be identical, byte for byte.
#
#   tests/differential/version/run.sh [SEED] [COUNT]     default: seed 1, 200000 cases
#
# Needs cargo, and the pinned source (reference/fetch.sh source).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
seed="${1:-1}"
count="${2:-200000}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The crates at the versions Gleam builds with: its lock file is the starting point.
[[ -f Cargo.lock ]] || cp ../../../reference/gleam/Cargo.lock Cargo.lock
cargo build --quiet --release
nim c --hints:off --verbosity:0 -d:release -o:"$work/driver" driver.nim
"$work/driver" generate "$seed" "$count" > "$work/cases.txt"
./target/release/version-driver < "$work/cases.txt" > "$work/rust.txt"
"$work/driver" answer < "$work/cases.txt" > "$work/nim.txt"

kinds="$(cut -c1 "$work/cases.txt" | sort | uniq -c | awk '{printf "%s%s %s", sep, $2, $1; sep=", "}')"
errors="$(grep -c '^error' "$work/rust.txt" || true)"
if cmp -s "$work/rust.txt" "$work/nim.txt"; then
  echo "versions: $count cases ($kinds; $errors rejected), identical (seed $seed)"
else
  line="$(cmp "$work/rust.txt" "$work/nim.txt" | sed 's/.*line //' || true)"
  echo "versions: outputs differ at case $line (seed $seed)"
  echo "case: $(sed -n "${line}p" "$work/cases.txt")"
  echo "rust: $(sed -n "${line}p" "$work/rust.txt")"
  echo "nim:  $(sed -n "${line}p" "$work/nim.txt")"
  exit 1
fi
