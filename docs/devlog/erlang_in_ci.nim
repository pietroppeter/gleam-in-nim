## devlog: 12 Nov 2026 P | Erlang in CI | CI now has Erlang, Node and the reference compiler, and proves it by compiling a tiny Gleam program and running it three ways.
## kind: tooling
import std/[os, strutils]
import nimib
import ../blocks

nbInit
nb.usePost()

let
  root = docsDir.parentDir
  program = readFile(root / "tests" / "smoke" / "hello" / "src" / "hello.gleam").strip
  expected = readFile(root / "tests" / "smoke" / "hello" / "expected.txt").strip
  ci = readFile(docsDir / "devlog" / "data" / "erlang_in_ci" / "ci.txt").strip
  workflow = readFile(root / ".github" / "workflows" / "smoke.yml").strip
  script = readFile(root / "tools" / "smoke.sh").strip

nbText: """
## The short version

Until now nothing in this project could *run* compiled Gleam. The
[goldens](../what-the-reference-says/) were made without Erlang on purpose, and they say what
the compiler writes, not whether it works. A compiler is only right when its output runs, so
before the port has a back end, CI learns to execute code.

- CI installs **Erlang/OTP 28** and **Node 22**, and fetches the pinned reference `gleam`.
- A **smoke test**, `tools/smoke.sh`, compiles one small Gleam package and runs the result
  three ways: from Erlang source, from abstract forms, and as JavaScript. All three must print
  the same line.
- The compiler under test is a variable. Today it is the reference; the day the port can
  compile this package, the same script runs the port.

This is what the first run in CI printed:

```
""" & ci & """

```

## Three routes to a running program

Gleam can hand over its result in three shapes, and each has its own way to become something
that runs. If the BEAM, abstract forms or `erlc` are new to you, [The BEAM,
explained](../the-beam/) tells that story; here is only the plumbing.

| Route | What the compiler writes | What turns it into something that runs |
|---|---|---|
| `erlang-source` | `.erl` files, Erlang as text | `erlc`, Erlang's own compiler, then `erl` |
| `erlang-abstr` | `.abstr` files, Erlang abstract forms | an `escript` the Gleam compiler starts itself, then `erl` |
| `javascript` | `.mjs` modules and the prelude | `node` |

The second route is the one the real build tool uses since v1.19, and it is the route the
goldens had to fake with a stand-in `escript`. Here the real one answers.
"""

nbNote """
`erlc` compiles Erlang source to `.beam` files, the BEAM's bytecode. `erl` starts the virtual
machine. `escript` runs an Erlang program as a script: Gleam ships one that reads abstract
forms and writes `.beam` files, and talks to it over a pipe.
""", nkGleam, "The three Erlang tools"

nbText: """
## The program

It has no dependencies, not even the standard library, so the test needs no package manager
and no network beyond fetching the compiler. It cannot print for the same reason: printing
lives in the standard library. So `main` returns a value and the test prints it from outside,
in Erlang on one side and in JavaScript on the other.

```gleam
""" & program & """

```

Small as it is, it crosses a fair part of both back ends: a custom type with two variants,
labelled fields, pattern matching on records and on lists, a recursive function (a loop, on
the BEAM), string concatenation, a tuple and a bit array. The expected line is in
`tests/smoke/hello/expected.txt`:

```
""" & expected & """

```

The three circles and rectangles add up to 27, and `111,107,255` are the bytes of `"ok"`
followed by 255.

## The script and the workflow
"""

nbFold "tools/smoke.sh":
  nbText "```sh\n" & script & "\n```"

nbFold ".github/workflows/smoke.yml":
  nbText "```yaml\n" & workflow & "\n```"

nbText: """
The workflow is separate from the one that builds these pages, so a slow page build and a
broken back end show up as two different red crosses. Erlang comes from
[`erlef/setup-beam`](https://github.com/erlef/setup-beam), the action maintained by the Erlang
Ecosystem Foundation. The whole job took about twenty seconds.

On a machine without Erlang, `SMOKE_SKIP_MISSING=1 sh tools/smoke.sh` runs the routes it can
and says which it skipped. In CI nothing may be skipped: a missing tool is an error.
"""

nbNote """
What was verified: the workflow ran on the pull request of this step, on OTP 28 and Node 22,
and the three routes printed the expected line; the lines above are copied from that run's
log. In the sandbox where this was written only the JavaScript route could run, since there
is no recent Erlang there. What was not: nothing from the corpus is executed yet, and no test
suite of a real package is run. That needs dependencies written in Erlang to be compiled too,
which is the build tool's work and comes with it.
""", nkDone, "Checked, and not"

nbText: """
## What this changes for the port

1. **Output can be executed from now on.** A back end step can ask for more than "the same
   bytes as the reference": it can ask that the program runs and prints the same thing.
2. **One script, any compiler.** `GLEAM_BIN=path sh tools/smoke.sh` takes whatever speaks
   `compile-package`. It is the first end to end test waiting for the port.
3. **OTP 28 is the version of record** for running code here. Gleam 1.19 needs 27 or newer.
4. **Next for this thread:** reading `gleam.toml` and `manifest.toml`, the first part of the
   build tool.

## Sources

- `tools/smoke.sh`, `tests/smoke/hello/` and `.github/workflows/smoke.yml` in this repository.
- [`erlef/setup-beam`](https://github.com/erlef/setup-beam), for Erlang in GitHub Actions.
- [`compiler-cli/src/beam_compiler.rs`](https://github.com/gleam-lang/gleam/blob/v1.19.2/compiler-cli/src/beam_compiler.rs)
  in the Gleam repository, for how the compiler drives `escript`.
- [What the real compiler says](../what-the-reference-says/) and [The BEAM,
  explained](../the-beam/), earlier posts of this devlog.
"""

nbSave
