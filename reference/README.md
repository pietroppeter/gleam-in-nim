# The reference

The Gleam compiler this repository ports, and tools that run it.

- `PIN`: the snapshot being ported (repository, tag, commit).
- `lexdump/`: a small Rust program that links Gleam's compiler core at the pinned commit and
  prints what its lexer makes of a source. `tools/lexcheck.sh` compares it with the Nim lexer;
  `tools/lexdump.nim` describes the output. Needs Rust 1.99 or later.
