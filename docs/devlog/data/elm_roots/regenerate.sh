#!/bin/sh
# Rebuilds the compiler messages quoted by the post "Elm, the other parent".
# Each cases/<name>.gleam is checked alone by gleam 1.19.2; what the compiler
# says is kept in cases/<name>.out.txt. Needs: gleam, git.
# usage: sh docs/devlog/data/elm_roots/regenerate.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
git clone -q --depth 1 https://github.com/gleam-lang/stdlib "$work/gl-stdlib"
mkdir -p "$work/errs/src"
printf 'name = "errs"\nversion = "1.0.0"\n\n[dependencies]\ngleam_stdlib = { path = "../gl-stdlib" }\n' > "$work/errs/gleam.toml"
for case in "$here"/cases/*.gleam; do
  name=$(basename "$case" .gleam)
  cp "$case" "$work/errs/src/errs.gleam"
  # The JavaScript target: checking for Erlang would compile the dependencies with OTP.
  (cd "$work/errs" && gleam check --target javascript 2>&1 || true) \
    | sed 's/\x1b\[[0-9;]*m//g' | sed "s#$work/errs/##" \
    | grep -v "Compiling\|Resolving\|Compiled\|Added\|Checked\|Checking\|Downloading" \
    > "$here/cases/$name.out.txt" || true  # grep finds nothing when the case compiles
done
echo done
