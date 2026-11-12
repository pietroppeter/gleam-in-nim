#!/usr/bin/env bash
# Compare the Nim parser with the reference Gleam parser (tests/differential/parse).
#
#   tools/parsecheck.sh harvest               the inputs of upstream's parser tests
#   tools/parsecheck.sh corpus DIR...         every .gleam file under the DIRs, as modules
#   tools/parsecheck.sh gen COUNT SEED        random sources from a grammar, for the
#                                             three entry points (module, statements, const)
#   tools/parsecheck.sh mutate COUNT SEED DIR...
#                                             pieces of the .gleam files under the DIRs
#                                             with a few tokens changed, three entry points
#
# Needs cargo (Rust 1.99 or later), nim, and the pinned source (bash reference/fetch.sh).
# Builds land in build/parsecheck.
set -euo pipefail
cd "$(dirname "$0")/.."
out=build/parsecheck
mkdir -p "$out"

tests/differential/parse/build.sh
ref=tests/differential/parse/target/release/parse-driver
nim c --hints:off --verbosity:0 -d:release -o:"$out/parsedump" tools/parsedump.nim
nim c --hints:off --verbosity:0 -d:release -o:"$out/parsefuzz" tools/parsefuzz.nim

files() { # the .gleam files under the given directories, one per line
  if [ "$#" -gt 0 ]; then find "$@" -name '*.gleam' -type f | LC_ALL=C sort; fi
}

compare() { # compare NAME MODE: run both parsers on $out/NAME.txt and report
  "$ref" "$2" "$out/$1.txt" > "$out/$1.ref"
  "$out/parsedump" "$2" "$out/$1.txt" > "$out/$1.nim"
  local sources oks
  sources="$(wc -l < "$out/$1.txt")"
  oks="$(grep -c '^ok$' "$out/$1.ref" || true)"
  if cmp -s "$out/$1.ref" "$out/$1.nim"; then
    echo "ok: $1, $sources sources ($oks parse, $((sources - oks)) are errors), $(wc -l < "$out/$1.ref") lines identical"
  else
    echo "ERROR $1: the outputs differ"
    local line number
    line="$(cmp "$out/$1.ref" "$out/$1.nim" | sed 's/.*line //' || true)"
    number="$(head -n "$line" "$out/$1.ref" | grep '^== ' | tail -1 | cut -c4- || true)"
    echo "first difference at line $line, source $number:"
    sed -n "${number}p" "$out/$1.txt" | cut -c1-600 || true
    diff "$out/$1.ref" "$out/$1.nim" | head -30 || true
    exit 1
  fi
}

mode="${1:?usage: parsecheck.sh harvest|corpus|gen|mutate ...}"
shift
case "$mode" in
  harvest)
    for entry in module statements; do
      "$out/parsefuzz" harvest "$entry" > "$out/harvest-$entry.txt"
      compare "harvest-$entry" "$entry"
    done
    ;;
  corpus)
    files "$@" | xargs -d '\n' "$out/parsefuzz" files > "$out/corpus.txt"
    compare corpus module
    ;;
  gen)
    for entry in module statements const; do
      "$out/parsefuzz" gen "$entry" "$1" "$2" > "$out/gen-$entry.txt"
      compare "gen-$entry" "$entry"
    done
    ;;
  mutate)
    count="$1"; seed="$2"; shift 2
    for entry in module statements const; do
      files "$@" | xargs -d '\n' "$out/parsefuzz" mutate "$entry" "$count" "$seed" > "$out/mutate-$entry.txt"
      compare "mutate-$entry" "$entry"
    done
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac
