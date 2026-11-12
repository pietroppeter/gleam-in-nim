#!/usr/bin/env bash
# Regenerates the data of the post "Erlang, one call at a time":
#   erlcheck.out.txt   the Nim builder against the reference one (needs cargo)
#   sizes.json         how big the Rust and the Nim are
# Run from the root of the repository, after `bash reference/fetch.sh`.
set -euo pipefail
here=docs/devlog/data/the_erlang_builder
(tools/erlcheck.sh fuzz 50000 2026; tools/erlcheck.sh floats 1000000 2026) > "$here/erlcheck.out.txt"
python3 - "$here/sizes.json" <<'PY'
import json, sys
rust = open('reference/gleam/erlang-generation/src/lib.rs').read().split('\n')
part = rust[:3803]
trait_start = next(i for i, l in enumerate(rust) if l.startswith('pub trait ErlangBuilder'))
trait_end = next(i for i, l in enumerate(rust) if l.startswith('pub struct ErlangSourceBuilder'))
trait = rust[trait_start:trait_end]
nim = open('src/gleam_in_nim/erlang_generation.nim').read().split('\n')
def comments(lines, marks): return sum(1 for l in lines if l.strip().startswith(marks))
json.dump({
    "rust_lines_file": len(rust) - 1,
    "rust_lines_ported": len(part),
    "rust_comment_lines_ported": comments(part, ('//',)),
    "trait_functions": sum(1 for l in trait if l.strip().startswith('fn ')),
    "trait_associated_types": sum(1 for l in trait if l.strip().startswith('type ')),
    "position_kinds": 26,
    "nim_lines": len(nim),
    "nim_comment_lines": comments(nim, ('#',)),
}, open(sys.argv[1], 'w'), indent=2)
PY
cat "$here/sizes.json"
