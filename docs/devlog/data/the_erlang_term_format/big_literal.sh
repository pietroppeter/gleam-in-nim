#!/bin/sh
# An integer literal too big for SMALL_BIG_EXT, compiled by the reference gleam (1.19.2) to
# Erlang abstract forms, then decoded by Erlang. Writes big_literal.out.txt next to this file.
# Needs: gleam 1.19.2, erl. usage: sh docs/devlog/data/the_erlang_term_format/big_literal.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
mkdir -p "$work/src" "$work/out" "$work/lib"
printf 'name = "bigcase"\nversion = "1.0.0"\n' > "$work/gleam.toml"
: > "$here/big_literal.out.txt"
for digits in 600 615 620 700; do
  ones=$(printf '%*s' "$digits" '' | tr ' ' '1')
  printf 'pub fn big() -> Int {\n  %s\n}\n' "$ones" > "$work/src/bigcase.gleam"
  # The command fails at its last step on an OTP older than 27, after writing the .abstr file.
  gleam compile-package --target erlang --package "$work" --out "$work/out" --lib "$work/lib" > /dev/null 2>&1 || true
  printf '%s digits: ' "$digits" >> "$here/big_literal.out.txt"
  erl -noshell -eval '{ok,B}=file:read_file("'"$work"'/out/_gleam_artefacts/bigcase.abstr"), case (catch binary_to_term(B)) of {'"'"'EXIT'"'"',{E,_}} -> io:format("binary_to_term fails with ~p~n",[E]); Fs -> io:format("decoded, ~p forms~n",[length(Fs)]) end, halt().' >> "$here/big_literal.out.txt"
done
cat "$here/big_literal.out.txt"
