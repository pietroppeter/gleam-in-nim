#!/usr/bin/env bash
# Differential test of the diagnostics: random errors and warnings, written by
# upstream's `Diagnostic::write` (compiler-core at the pin, over codespan-reporting
# and termcolor) and by the Nim port, with and without colours. The two outputs
# must be identical, byte for byte.
#
#   tests/differential/diagnostic/run.sh [SEED] [COUNT]     default: seed 1, 20000 diagnostics
#
# Needs cargo, and the pinned source (reference/fetch.sh source). The first build
# compiles upstream's compiler-core, which takes a few minutes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
seed="${1:-1}"
count="${2:-20000}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

[ -f Cargo.lock ] || cp ../../../reference/gleam/Cargo.lock Cargo.lock   # upstream's versions
cargo build --quiet --release
nim c --hints:off --verbosity:0 -d:release -o:"$work/driver" driver.nim
"$work/driver" generate "$seed" "$count" > "$work/diagnostics.txt"
./target/release/diagnostic-driver < "$work/diagnostics.txt" > "$work/rust.txt"
"$work/driver" print < "$work/diagnostics.txt" > "$work/nim.txt"

panics="$(grep -c PANIC "$work/rust.txt" || true)"
if cmp -s "$work/rust.txt" "$work/nim.txt"; then
  echo "diagnostics: $count diagnostics, identical (seed $seed; $panics where both refuse)"
else
  line="$(cmp "$work/rust.txt" "$work/nim.txt" | sed 's/.*line //')"
  echo "diagnostics: outputs differ at diagnostic $line (seed $seed)"
  echo "input: $(sed -n "${line}p" "$work/diagnostics.txt")"
  echo "--- rust"; sed -n "${line}p" "$work/rust.txt" | python3 -c "import sys; sys.stdout.buffer.write(bytes.fromhex(sys.stdin.read().strip()))"
  echo "--- nim";  sed -n "${line}p" "$work/nim.txt" | python3 -c "import sys; sys.stdout.buffer.write(bytes.fromhex(sys.stdin.read().strip()))"
  exit 1
fi
