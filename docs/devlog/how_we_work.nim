## devlog: 12 Nov 2026 G | How this port is developed | No specification to write, eight decisions written down, four tools that turn the Gleam compiler's own tests into ours, and how Pietro can check the work in five minutes.
## kind: tooling
import std/[os, strutils, json, algorithm]
import nimib
import ../blocks

nbInit
nb.usePost()

const here = currentSourcePath().parentDir
let dataDir = here / ".." / "data"
let runs = here / "data" / "how_we_work"
let portmap = parseFile(dataDir / "portmap.json")
let snapshots = parseFile(dataDir / "snapshots.json")
let harvest = parseFile(dataDir / "harvest.json")
let selfRun = parseFile(runs / "reference_against_itself.json")

proc thousands(n: int): string = insertSep($n, ',')
proc run(name: string): string = "```text\n" & readFile(runs / name).strip & "\n```"

let pin = portmap["pin"].getStr
var difftestCases = 0
for mode in selfRun.keys: difftestCases += selfRun[mode]["cases"].getInt

nbText: """
## The short version

The [previous post](../learning-from-rewrites/) read how others moved a compiler from one language
to another. This one is what we do about it. Five answers, then the detail.

- **Do we write a specification first? No.** The specification exists: it is Gleam """ & pin & """, its
  tests and its binary. We write down only what it cannot tell us.
- **Do we keep decision records? Yes**, short ones. The first eight are written.
- **What is the working loop?** Translate a file, have a second pass doubt it, then make the
  upstream tests pass on it. Three states, visible on every file.
- **What tooling exists?** Four small Nim programs, working today: they read the upstream tests
  (""" & thousands(snapshots["total"].getInt) & """ snapshots, """ & thousands(harvest["total"].getInt) & """ test macro calls), compare any candidate with the reference
  compiler on """ & thousands(difftestCases) & """ inputs in seconds, and keep the map of what is ported.
- **How does Pietro review?** By looking at numbers a machine produced, at two files side by
  side, and at one page per step. A five-minute routine is at the end.

## A specification, or not

Pietro's recent projects are driven by a specification. In tabelline, every behaviour is first a
requirement with examples, in an OpenSpec folder; the code comes after, and a tool runs the
examples. It is the right tool there: tabelline decides what a table library for Nim should do,
and the decision has to live somewhere.

A port decides nothing about behaviour. What the lexer does with `1_000` is not ours to specify:
it is whatever the Rust lexer does. A second description of that, in English, would cost more
than the port and be wrong more often than the Rust. The TypeScript team reached the same
conclusion for their move to Go: their status table defines every stage by equality with the old
compiler.

So the rule is [decision 0003](../../decisions/#0003-the-pinned-compiler-and-its-tests-are-the-specification):
the pinned compiler, its tests and its binary are the specification. Specifications keep a place
for what upstream is silent about, and there we use the lightest form that works:
"""

nbText: """
| Question | Where the answer lives |
| --- | --- |
| What should the compiler do? | The Rust at the pin, its tests, the `gleam` binary |
| Where may we differ? | One list, `docs/divergences.md`, empty today |
| How do we translate Rust to Nim? | The [porting guide](../../porting/) |
| Why did we choose this? | A [decision record](../../decisions/) |
| What is next, what is done? | The [roadmap](../../roadmap/), the port map, the [coverage map](../../coverage/) |
| What happened in a step? | A devlog post, like this one |
| How do agents work here? | [For coding agents](../../agents/) |

## Decisions, written down

A decision record is a short dated note: the context, the decision, what follows. The form is
Michael Nygard's, from 2011, and it has not needed improving. We keep one when a later session
could reasonably choose otherwise, because that session will not remember this one.
"""

block:
  var list = "| | Decision | Status |\n| --- | --- | --- |\n"
  var files: seq[string]
  for path in walkFiles(here / ".." / "decisions" / "*.md"): files.add path
  files.sort
  for path in files:
    var title, status: string
    for line in lines(path):
      if line.startsWith("title: "): title = line[7 .. ^1]
      elif line.startsWith("status: "): status = line[8 .. ^1]
    list.add "| " & path.extractFilename[0 .. 3] & " | " & title & " | " & status & " |\n"
  nbText: list & "\nThey are on one page, [Decisions](../../decisions/), which finds the files by itself."

nbNote("""
Decision 0007 is *proposed*, not accepted, because it is Pietro's to make. Gleam is Apache-2.0,
and a translation of its code must keep that licence and say where it comes from. The repository
was created with an MIT licence. The proposal: make the whole repository Apache-2.0, like
upstream. Whatever the answer, every ported file already names the Rust file it comes from.
""", nkQuestion, "One for Pietro: the licence")

nbText: """
## The loop of a port step

Every Rust file goes through three states ([decision 0005](../../decisions/#0005-every-file-goes-through-translate-verify-conform)).
Bun's port did the same with three kinds of agents per file; Ladybird with one person and a
second model asked to find faults.

1. **Draft.** Translate the file following the porting guide: same names, same order, same
   control flow. Port its tests with it.
2. **Verified.** A second pass that does not remember the first reads the Nim against the Rust
   and looks only for differences in behaviour. It is asked to find problems, not to approve.
   What it finds is fixed, and any new trap goes into the porting guide.
3. **Conformant.** The upstream tests for that file pass on the Nim code, and the differential
   harness agrees with the reference wherever the stage can be reached from the command line.

The state is written in the file itself, in two lines that every ported file starts with:

```nim
## port-of: compiler-core/src/parse/lexer.rs
## port-status: draft
```

Those two lines are the whole bookkeeping. The port map is computed from them, so it cannot say
something the code does not.

## The tools

All four are in `tools/`, written in Nim with the standard library only, and they follow one
rule about their output ([decision 0006](../../decisions/#0006-tools-and-tests-are-written-for-a-reader-with-a-small-context)):
a few lines when all is well, one line starting with `ERROR` per problem, the detail in a file, a
summary last, and a `--fast` option for anything slow. The rule comes from the people who had
sixteen agents build a C compiler: write the harness for the reader that will actually read it.
It happens to suit a phone as well.

### snapshots and snapcorpus: upstream's expected outputs

Gleam's tests keep most of their expected results as snapshot files. `tools/snapshots.nim` reads
them (the front matter, then sections such as `SOURCE CODE`, `COMPILED ERLANG`, `ERROR`), and
`tools/snapcorpus.nim` indexes them all.

""" & run("snapcorpus_run.txt") & """

More than half embed the Gleam source they were made from. For those, a test of the port is three
lines: take the source, run our code, compare with the other section.

### harvest: the tests that are not snapshots

The formatter has no snapshot at all: its tests are calls like `assert_format!("...")` with the
Gleam source as a string in the Rust file. The type checker has `assert_infer!("[1, 2]",
"List(Int)")`. `tools/harvest.nim` reads Rust just well enough (strings, raw strings, escapes,
comments, nesting) to return every `assert_*!` call with its arguments decoded.

""" & run("harvest_run.txt") & """

The column on the right counts the calls whose arguments are only string literals: those can be
replayed as they are. The others pass Rust values, such as the expected tokens of the lexer, and
need a few lines of Nim each.

### difftest: the reference as an oracle

`tools/difftest.nim` runs the reference `gleam` and a candidate on the same inputs and compares
everything they produce: standard output, errors, exit code, every file written. Byte for byte
([decision 0004](../../decisions/#0004-outputs-are-compared-byte-for-byte-with-the-reference)).
It has three modes today, and none needs Erlang or the network: `format` pipes sources through
`gleam format --stdin`, `erlang` and `javascript` compile one-module packages with the low-level
`gleam compile-package`, which writes text.

The inputs are the sources embedded in the upstream snapshots, plus the formatter's test cases.
There is no Nim compiler to test yet, so the first candidate was the reference itself, which must
agree everywhere, and then a liar: a script that runs the reference and writes `pub  fn` with two
spaces. The harness has to pass the first and catch the second, and that is its self test.

""" & run("difftest_run.txt") & """

That is """ & thousands(difftestCases) & """ comparisons in well under a minute, which is what makes it usable inside a
working loop and not only at the end. The day the port has a `format --stdin`, this command says
how many of """ & thousands(selfRun["format"]["cases"].getInt) & """ sources it formats exactly like Gleam.

### portmap: where the port stands

`tools/portmap.nim` lists every Rust file of the reference with its size, its upstream tests, and
the Nim file that ports it, found by the `port-of` header.

""" & run("portmap_run.txt") & """

It also answers "what next?" (`portmap todo` lists unported files, smallest first) and it fails
when a Nim file claims to port a Rust file that does not exist. The [coverage map](../../coverage/)
shows the same data grouped by stage of the compiler.
"""

block:
  var table = "| Crate | Lines of code to port |\n| --- | ---: |\n"
  var rows: seq[(int, string)]
  for c in portmap["crates"]:
    var n = 0
    for key in ["todo", "draft", "verified", "conformant"]: n += c[key].getInt
    rows.add (n, c["crate"].getStr)
  rows.sort(Descending)
  for (n, name) in rows: table.add "| `" & name & "` | " & thousands(n) & " |\n"
  table.add "| **all** | **" & thousands(portmap["code"].getInt) & "** |\n"
  nbFold "The reference, crate by crate":
    nbText: table & "\nComments and blank lines are not counted, and neither are the " &
      thousands(portmap["tests"]["code"].getInt) & " lines of tests."

nbText: """
## What we chose not to build, for now

- **A Rust to Nim translator.** The Go team wrote one for C in 2014, and it was the right call
  then. Today the translator is the model, and what it needs is the guide, not a parser. If the
  first ports show the same mechanical mistakes again and again, a checker for those mistakes is
  the tool to write, not a transpiler.
- **A side-by-side page**, Rust on the left and Nim on the right, function by function, for
  review on a phone. Worth building as soon as there are a few ported files to show. It is the
  natural next tool of this thread.
- **Generated programs** (fuzzing both compilers with random Gleam). Powerful, and premature
  before the upstream cases pass.
- **Real projects as inputs.** Not ours to build: the [corpus of real Gleam](../a-corpus-of-real-gleam/)
  arrived the same day, and the harness takes it with `--corpus:.corpus-cache`. The 42 files of
  the standard library went through `format` and came out the same from both sides.

## For Pietro: checking a step in five minutes

1. Open the post of the step. It leads with what was found and done.
2. Look at the numbers the tools printed, which the post shows as they were printed: how many
   upstream cases pass, how many differ from the reference. A step that ports code and shows no
   such number is not finished.
3. Open the [coverage map](../../coverage/): did the right files move, and to which state? A file
   that is only `draft` has not been doubted by anyone yet.
4. Pick one function in the pull request and read it against the Rust. The port-of header says
   which file; names and order are the same, so this takes a minute, not an afternoon.
5. Comment with the review mode, on the page itself. The export goes back to the thread, which
   applies it.

What you should never have to do is trust a sentence like "the tests pass". The tests are
Gleam's, the judge is Gleam's binary, and both run in CI.

## What this changes for the port

- Every port step starts from the [porting guide](../../porting/) and ends by updating it.
- Every ported file starts with `port-of` and `port-status`.
- Tests replay upstream cases through `tools/snapshots.nim` and `tools/harvest.nim`; nobody
  retypes an expected output.
- "Done" for a stage means identical to the reference under `tools/difftest.nim`.
- A choice that could be made twice gets a decision record.

Still open: the licence (decision 0007, for Pietro), how `Result` and `?` are written in Nim (the
first port step that meets them decides, in the porting guide), and a place in CI for the
differential harness once the reference checkout is fetched there.

## Sources

- The cases and their sources are in [What other rewrites teach us](../learning-from-rewrites/).
- Michael Nygard, [Documenting Architecture Decisions](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions), 2011.
- [OpenSpec](https://github.com/Fission-AI/OpenSpec), the specification framework tabelline uses, and
  tabelline's own [working rules](https://github.com/pietroppeter/tabelline/blob/main/AGENTS.md).
- Nicholas Carlini, [Building a C compiler with a team of parallel Claudes](https://www.anthropic.com/engineering/building-c-compiler), for the rules about tool output.
- The tool runs shown here are in `docs/devlog/data/how_we_work/`, made with Gleam """ & pin & """ on 12 November 2026.
"""

nbSave
