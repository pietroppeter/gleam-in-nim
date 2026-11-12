#!/usr/bin/env bash
# Compare the Nim Erlang builder with the reference one (reference/erldump,
# which links the real `erlang-generation` crate at the pinned commit).
#
#   tools/erlcheck.sh fuzz COUNT SEED   COUNT random scripts of builder calls
#   tools/erlcheck.sh floats COUNT SEED COUNT random floats, printed
#   tools/erlcheck.sh file FILE         the scripts of FILE
#   tools/erlcheck.sh golden            regenerate tests/golden/erlang_builder
#                                       from the reference
#
# Needs cargo and nim. Builds land in build/erlcheck. The formats are
# described in tools/erldump.nim.
set -euo pipefail
cd "$(dirname "$0")/.."
out=build/erlcheck
mkdir -p "$out"

(cd reference/erldump && CARGO_TARGET_DIR="../../$out/cargo" cargo build --release --quiet)
ref="$out/cargo/release/erldump"
nim c --hints:off --verbosity:0 -d:release -o:"$out/erldump" tools/erldump.nim
nim c --hints:off --verbosity:0 -d:release -o:"$out/erlfuzz" tools/erlfuzz.nim

compare() { # compare NAME FILE: replay FILE with both builders and report
  timeout 300 "$ref" source "$2" > "$out/$1.ref"
  "$out/erldump" source "$2" > "$out/$1.nim"
  if cmp -s "$out/$1.ref" "$out/$1.nim"; then
    echo "ok: $1, $(grep -c '^== ' "$2") scripts, $(grep -vc '^== ' "$2") calls," \
      "$(wc -l < "$out/$1.ref") lines of output identical," \
      "$(grep -c '^! ' "$out/$1.ref" || true) of the scripts end in an internal error"
  else
    echo "DIFFERENT: $1"
    diff "$out/$1.ref" "$out/$1.nim" | head -20
    exit 1
  fi
}

mode="${1:?usage: erlcheck.sh fuzz|floats|file|golden ...}"
shift
case "$mode" in
  fuzz)
    "$out/erlfuzz" "$1" "$2" > "$out/fuzz.txt"
    compare fuzz "$out/fuzz.txt"
    ;;
  floats)
    "$out/erlfuzz" --floats "$1" "$2" > "$out/floats.txt"
    compare floats "$out/floats.txt"
    ;;
  file)
    compare file "$1"
    ;;
  golden)
    golden=tests/golden/erlang_builder
    mkdir -p "$golden"
    "$out/erlfuzz" 400 2026 > "$golden/fuzz.txt"
    "$ref" source "$golden/fuzz.txt" > "$golden/fuzz.expected"
    wc -l "$golden"/*
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac
