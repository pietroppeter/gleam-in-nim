#!/bin/sh
# Rebuilds everything the post "The BEAM, explained" quotes.
# Needs: gleam 1.19.2, erl/erlc/escript (OTP 25 or newer), node, git.
# usage: sh docs/devlog/data/the_beam/regenerate.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
echo "working in $work"

# 1. Plain Erlang demos: compile, run, keep what they print.
mkdir -p "$work/demo"
erlc -o "$work/demo" "$here"/erlang/*.erl
for m in ping counter mailbox crash many sup_demo; do
  erl -noshell -pa "$work/demo" -eval "$m:main(), halt()." > "$here/erlang/$m.out.txt" 2>&1
done

# 2. Gleam projects. Dependencies are path dependencies on git clones (no Hex needed).
for r in stdlib erlang otp; do
  git clone -q --depth 1 "https://github.com/gleam-lang/$r" "$work/gl-$r"
done
cp -r "$here/gleam/roots" "$here/gleam/counter" "$work/"
mkdir -p "$work/text" "$work/forms"

# 2a. JavaScript: build, run, keep the generated modules.
(cd "$work/roots" && gleam run --target javascript 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g') \
  > "$here/generated/javascript/run.out.txt"
cp "$work"/roots/build/dev/javascript/roots/shapes.mjs \
   "$work"/roots/build/dev/javascript/roots/clock.mjs \
   "$work"/roots/build/dev/javascript/roots/roots.mjs "$here/generated/javascript/"

# 2b. Erlang, twice: as source (.erl, with --no-beam) and as abstract forms (.abstr).
#     The second run fails at its last step on an OTP older than 27 (Gleam's own
#     compile script needs 27), after writing the .abstr files, hence `|| true`.
for p in gl-stdlib:gleam_stdlib gl-erlang:gleam_erlang gl-otp:gleam_otp roots:roots counter:counter; do
  dir=${p%%:*}; name=${p##*:}
  gleam compile-package --target erlang --package "$work/$dir" \
    --out "$work/text/$name" --lib "$work/text" --no-beam --no-dev > /dev/null
  gleam compile-package --target erlang --package "$work/$dir" \
    --out "$work/forms/$name" --lib "$work/text" --no-dev > /dev/null 2>&1 || true
  escript "$here/abstr2beam.escript" "$work/ebin" \
    $(ls "$work/forms/$name"/_gleam_artefacts/*.abstr "$work/forms/$name"/_gleam_artefacts/*.erl 2>/dev/null)
done
for m in shapes clock roots; do cp "$work/text/roots/_gleam_artefacts/$m.erl" "$here/generated/erlang/"; done
for m in counter counter_demo; do cp "$work/text/counter/_gleam_artefacts/$m.erl" "$here/generated/erlang/"; done
cp "$work/text/roots/include/shapes_Rectangle.hrl" "$work"/text/counter/include/*.hrl "$here/generated/erlang/"
cp "$work/forms/roots/_gleam_artefacts/shapes.abstr" "$here/generated/erlang/"

# 2c. Run on the BEAM.
erl -noshell -pa "$work/ebin" -eval 'roots:main(), halt().' 2>&1 | sed 's/\x1b\[[0-9;]*m//g' \
  > "$here/generated/erlang/run.out.txt"
erl -noshell -pa "$work/ebin" -eval 'counter_demo:main(), halt().' \
  > "$here/generated/erlang/counter_run.out.txt" 2>&1

# 2d. The abstract forms of one function, printed.
erl -noshell -eval '{ok,B}=file:read_file("'"$here"'/generated/erlang/shapes.abstr"), Fs=binary_to_term(B), io:format("~p forms~n",[length(Fs)]), [io:format("~p~n",[F]) || F <- lists:sublist(Fs,5)], [io:format("~p~n",[F]) || {function,_,area,1,_}=F <- Fs], halt().' \
  > "$here/generated/erlang/shapes.abstr.txt"
echo done
