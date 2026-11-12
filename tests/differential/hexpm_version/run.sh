#!/usr/bin/env bash
# Differential test of Hex versions and ranges: the cases of cases.py, answered by upstream's
# Rust hexpm crate. The answers are the expected results of tests/test_hexpm_version.nim.
#
#   tests/differential/hexpm_version/run.sh              compare the committed goldens with upstream
#   tests/differential/hexpm_version/run.sh golden       regenerate tests/golden/hexpm_version
#   tests/differential/hexpm_version/run.sh fuzz SEED COUNT   new random cases, Nim against Rust
#
# Needs cargo, python3, nim and the pinned source (reference/fetch.sh source).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
root="../../.."
ref="${GLEAM_REF:-$root/reference/gleam}"
golden="$root/tests/golden/hexpm_version"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
CARGO_TARGET_DIR="$root/build/hexpm_version" cargo build --quiet --release
rust="$root/build/hexpm_version/release/hexpm-version-driver"

case "${1:-check}" in
  golden)
    python3 cases.py "$ref" "$root/corpus/corpus.json" > "$golden/cases.txt"
    "$rust" < "$golden/cases.txt" > "$golden/expected.txt"
    echo "hexpm version: wrote $(wc -l < "$golden/cases.txt") cases to $golden"
    ;;
  check)
    "$rust" < "$golden/cases.txt" > "$work/expected.txt"
    if cmp -s "$work/expected.txt" "$golden/expected.txt"; then
      echo "hexpm version: $(wc -l < "$golden/cases.txt") committed cases agree with upstream"
    else
      echo "ERROR hexpm version: the committed goldens differ from upstream at $(cmp "$work/expected.txt" "$golden/expected.txt")"
      exit 1
    fi
    ;;
  fuzz)
    python3 cases.py "$ref" "$root/corpus/corpus.json" "${2:-2}" "${3:-30000}" > "$work/cases.txt"
    "$rust" < "$work/cases.txt" > "$work/expected.txt"
    nim c --hints:off --verbosity:0 -d:release -o:"$work/driver" driver.nim
    "$work/driver" "$work/cases.txt" "$work/expected.txt"
    ;;
  *) echo "usage: run.sh [check | golden | fuzz SEED COUNT]"; exit 1 ;;
esac
