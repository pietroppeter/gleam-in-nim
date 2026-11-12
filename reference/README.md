# reference

The Gleam compiler we are porting, pinned.

- `PIN` records the release tag and commit. Everything in this repository (ported modules, tests,
  line counts, explainers) refers to this exact snapshot: Gleam **v1.19.2**.
- `fetch.sh` downloads the source into `reference/gleam/` and the official release binary into
  `reference/bin/gleam`. Neither is committed.

The source is the specification. The binary is the oracle: for any Gleam input, the port is right
when it prints what the binary prints. Three ways to ask the oracle, none of which needs Erlang or
a network connection:

```sh
# formatter (exercises the lexer and the parser)
reference/bin/gleam format --stdin < some.gleam

# Erlang, as text
reference/bin/gleam compile-package --target erlang --no-beam \
  --package path/to/package --out out --lib lib

# JavaScript
reference/bin/gleam compile-package --target javascript --javascript-prelude prelude.mjs \
  --package path/to/package --out out --lib lib
```

Gleam is Apache-2.0 licensed, copyright the Gleam contributors. Files ported from it keep a header
that says where they come from.
