#!/bin/sh
# Smoke test: compile a tiny Gleam package and run what comes out, on the BEAM and on Node.
#
#   sh tools/smoke.sh              with the reference compiler
#   GLEAM_BIN=path sh tools/smoke.sh   with another compiler that speaks `compile-package`
#
# Three routes, each must print the line in tests/smoke/hello/expected.txt:
#   erlang-source   Erlang source (--no-beam), compiled here with erlc, run with erl
#   erlang-abstr    abstract forms, compiled by the compiler's own escript step, run with erl
#   javascript      JavaScript modules, run with node
# Needs erl, erlc and escript (OTP 27 or newer for Gleam 1.19) and node on the PATH. A route
# whose runtime is missing is an ERROR, unless SMOKE_SKIP_MISSING=1 (for sandboxes without Erlang).
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
gleam="${GLEAM_BIN:-$root/reference/bin/gleam}"
[ -x "$gleam" ] || gleam="$(command -v gleam || true)"
ref="${GLEAM_REF:-$root/reference/gleam}"
pkg="$root/tests/smoke/hello"
expected="$(cat "$pkg/expected.txt")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/lib"
failed=0; ran=0

if [ -z "$gleam" ]; then echo "ERROR no gleam binary: run reference/fetch.sh binary, or set GLEAM_BIN"; exit 1; fi

check() { # name, output
  ran=$((ran + 1))
  if [ "$2" = "$expected" ]; then echo "ok $1: $2"; else echo "ERROR $1: got '$2', expected '$expected'"; failed=$((failed + 1)); fi
}
missing() { # name, tool
  if [ "${SMOKE_SKIP_MISSING:-0}" = 1 ]; then echo "skipped $1: no $2 on the PATH"
  else echo "ERROR $1: no $2 on the PATH"; failed=$((failed + 1)); fi
}
run_beam() { # folder of .beam files
  erl -noshell -pa "$1" -eval '
    {S, N, B} = hello:main(),
    Bytes = lists:join(",", [integer_to_list(X) || X <- binary_to_list(B)]),
    io:format("~s ~p ~s~n", [S, N, Bytes]), halt().' 2>&1
}

if command -v erlc > /dev/null && command -v erl > /dev/null; then
  "$gleam" compile-package --target erlang --no-beam --package "$pkg" --out "$tmp/erl" --lib "$tmp/lib" \
    && mkdir "$tmp/erl/ebin" && erlc -o "$tmp/erl/ebin" "$tmp"/erl/_gleam_artefacts/*.erl
  check erlang-source "$(run_beam "$tmp/erl/ebin")"
else missing erlang-source erlc; fi

if command -v escript > /dev/null && command -v erl > /dev/null; then
  "$gleam" compile-package --target erlang --package "$pkg" --out "$tmp/abstr" --lib "$tmp/lib"
  check erlang-abstr "$(run_beam "$tmp/abstr/ebin")"
else missing erlang-abstr escript; fi

if command -v node > /dev/null; then
  if [ -f "$ref/compiler-core/templates/prelude.mjs" ]; then
    cp "$ref/compiler-core/templates/prelude.mjs" "$tmp/prelude.mjs"
    "$gleam" compile-package --target javascript --javascript-prelude ../prelude.mjs --package "$pkg" \
      --out "$tmp/js" --lib "$tmp/lib"
    check javascript "$(cd "$tmp/js" && node --input-type=module -e '
      import { main } from "./hello.mjs";
      const [s, n, b] = main();
      console.log(s, n, Array.from(b.rawBuffer).join(","));' 2>&1)"
  else echo "ERROR javascript: no prelude.mjs in $ref: run reference/fetch.sh source, or set GLEAM_REF"; failed=$((failed + 1)); fi
else missing javascript node; fi

echo "smoke: $ran routes run, $failed errors ($("$gleam" --version))"
[ "$failed" = 0 ]
