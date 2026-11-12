#!/usr/bin/env bash
# Compare the Nim lexer with the reference Gleam lexer (reference/lexdump).
#
#   tools/lexcheck.sh corpus DIR...     every .gleam file under the DIRs
#   tools/lexcheck.sh fuzz COUNT SEED [DIR...]
#                                       random sources, half of them mutations
#                                       of the .gleam files under the DIRs
#   tools/lexcheck.sh numbers COUNT SEED   random float and int literals
#   tools/lexcheck.sh golden DIR...     regenerate tests/golden/lexer from the
#                                       reference (DIRs feed the mutations)
#
# Needs cargo (Rust 1.99 or later) and nim. Builds land in build/lexcheck.
set -euo pipefail
cd "$(dirname "$0")/.."
out=build/lexcheck
mkdir -p "$out"

(cd reference/lexdump && CARGO_TARGET_DIR="../../$out/cargo" cargo build --release --quiet)
ref="$out/cargo/release/lexdump"
nim c --hints:off --verbosity:0 -d:release -o:"$out/lexdump" tools/lexdump.nim
nim c --hints:off --verbosity:0 -d:release -o:"$out/lexfuzz" tools/lexfuzz.nim

files() { # the .gleam files under the given directories, one per line
  if [ "$#" -gt 0 ]; then find "$@" -name '*.gleam' -type f | LC_ALL=C sort; fi
}

compare() { # compare NAME: diff the two outputs and report
  if cmp -s "$out/$1.ref" "$out/$1.nim"; then
    echo "ok: $1, $(wc -l < "$out/$1.ref") lines identical"
    # how many times each kind of token and error was seen
    awk -F'\t' 'NF >= 3 && $1 ~ /^[0-9]+$/ { n[$3]++ } END { for (k in n) print k "\t" n[k] }' \
      "$out/$1.ref" | LC_ALL=C sort > "$out/$1.kinds"
  else
    echo "DIFFERENT: $1"
    diff "$out/$1.ref" "$out/$1.nim" | head -20
    exit 1
  fi
}

mode="${1:?usage: lexcheck.sh corpus|fuzz|numbers|golden ...}"
shift
case "$mode" in
  corpus)
    files "$@" > "$out/files.txt"
    echo "$(wc -l < "$out/files.txt") files"
    xargs -d '\n' "$ref" < "$out/files.txt" > "$out/corpus.ref"
    xargs -d '\n' "$out/lexdump" < "$out/files.txt" > "$out/corpus.nim"
    compare corpus
    ;;
  fuzz)
    count="$1"; seed="$2"; shift 2
    files "$@" | xargs -d '\n' "$out/lexfuzz" "$count" "$seed" > "$out/fuzz.txt"
    "$ref" --lines "$out/fuzz.txt" > "$out/fuzz.ref"
    "$out/lexdump" --lines "$out/fuzz.txt" > "$out/fuzz.nim"
    compare fuzz
    ;;
  numbers)
    for kind in floats ints; do
      "$out/lexfuzz" "--$kind" "$1" "$2" > "$out/$kind.txt"
      "$ref" "--$kind" "$out/$kind.txt" > "$out/$kind.ref"
      "$out/lexdump" "--$kind" "$out/$kind.txt" > "$out/$kind.nim"
      compare "$kind"
    done
    ;;
  golden)
    golden=tests/golden/lexer
    files "$@" | xargs -d '\n' "$out/lexfuzz" 2500 2026 > "$golden/sources.txt"
    "$ref" --lines "$golden/sources.txt" > "$golden/sources.expected"
    "$out/lexfuzz" --floats 4000 2026 > "$golden/floats.txt"
    "$ref" --floats "$golden/floats.txt" > "$golden/floats.expected"
    "$out/lexfuzz" --ints 2000 2026 > "$golden/ints.txt"
    "$ref" --ints "$golden/ints.txt" > "$golden/ints.expected"
    wc -l "$golden"/*
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac
