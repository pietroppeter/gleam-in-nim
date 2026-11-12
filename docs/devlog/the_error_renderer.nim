## devlog: 12 Nov 2026 O | The error renderer | The part of Gleam that draws the box around your mistake, ported with the Rust library under it, and checked on 80,000 random errors.
## kind: port
import std/[json, options, os, strformat, strutils]
import nimib
import ../blocks
import gleam_in_nim/[diagnostic, src_span, termcolor]

nbInit
nb.usePost()

const docsDir = currentSourcePath.parentDir.parentDir
let results = parseJson(readFile(docsDir / "devlog" / "data" / "the_error_renderer" / "differential.json"))

proc thousands(n: int): string = insertSep($n, ',')

var total = 0
for run in results["runs"]: total += run["diagnostics"].getInt
let crates = results["crates"]

nbText: fmt"""
## The short version

- **What**: `compiler-core/src/diagnostic.rs`, the small file through which every Gleam error
  and warning is printed, is now `src/gleam_in_nim/diagnostic.nim`.
- **The catch**: that file is 157 lines because the work is done by a Rust library,
  `codespan-reporting`. A port that must print the same bytes has to port the library too, and
  the two libraries under it. So this step is mostly that: about 3,000 lines of someone else's
  Rust, in three small Nim modules.
- **Checked how**: {thousands(total)} random diagnostics (spans over one line and many, several
  files, tabs, accents, emoji, with and without colours), written by upstream's own code and by
  the port: **0 differences**.
- **Why now**: {thousands(results["snapshots_with_diagnostics"].getInt)} of upstream's snapshots
  are errors and warnings. Every later step that can fail needs this to compare its messages.

## What a diagnostic is

For the compiler a diagnostic is five things: a title, a text, a level (error or warning),
perhaps a location, perhaps a hint. The location is a source file, a span of bytes in it with an
optional label, and any number of extra labels, which may point into other files.
"""

nbCode:
  let source = "pub fn main() {\n  let total = 1 + \"two\"\n  total\n}\n"
  let mismatch = Diagnostic(
    title: "Type mismatch",
    text: "The + operator expects arguments of this type:\n\n    Int\n\nBut this argument has this type:\n\n    String",
    level: Level.Error,
    location: some(Location(
      src: source,
      path: "src/app.gleam",
      label: Label(text: none(string), span: SrcSpan(start: 34, stop: 39)),
    )),
    hint: some("Strings are joined with the <> operator."),
  )
  let buffer = Buffer.noColor
  mismatch.write(buffer)
  echo buffer.asString

nbText: """
That is the port printing. The wording here is typed by hand for the example; the real messages
arrive with the steps that can raise them (parse errors with the parser, type errors with the
type checker).

Extra labels are where the drawing gets interesting. A label that spans several lines becomes a
line down the left margin, and several of them nest:
"""

nbCode:
  let nested = Diagnostic(
    title: "Two things at once",
    level: Level.Warning,
    location: some(Location(
      src: source,
      path: "src/app.gleam",
      label: Label(text: some("this expression"), span: SrcSpan(start: 30, stop: 39)),
      extraLabels: @[
        ExtraLabel(label: Label(text: some("in this function"), span: SrcSpan(start: 0, stop: 49))),
        ExtraLabel(label: Label(text: some("bound here"), span: SrcSpan(start: 22, stop: 27))),
      ],
    )),
  )
  let second = Buffer.noColor
  nested.write(second)
  echo second.asString

nbText: fmt"""
## Three libraries under 157 lines

| Rust crate | Version | What the compiler uses it for | In the port |
|---|---|---|---|
| `codespan-reporting` | {crates["codespan-reporting"].getStr} | lays out the header, the gutter, the carets and the labels | `codespan_reporting.nim` |
| `termcolor` | {crates["termcolor"].getStr} | a buffer that writes colours as ANSI codes, or drops them | `termcolor.nim` |
| `unicode-width` | {crates["unicode-width"].getStr} | how many columns a character takes in a terminal | `unicode_width.nim` and a generated table |

The versions are those of upstream's `Cargo.lock` at the pin. None of the three is a file of the
Gleam repository, so they do not count in the port map, and each Nim file says in its header
which crate it comes from and under which licence (all permissive: Apache-2.0, MIT or
Unlicense).
"""

nbNote("""
The porting guide says a Rust crate is replaced by the standard library or by a small module of
ours, never by a new dependency. Here "small" is stretched: the renderer is 1,222 lines of Rust.
It is ported whole, comments included, in upstream's order, because the only way to print the
same bytes in every corner (a caret under a tab, a label at the end of a line, two labels with
the same span) is to make the same decisions in the same order.

Three things are simpler than in the crate. It writes to one concrete buffer where the crate has
a trait with three implementations. Its file ids are plain integers. And where the crate returns
`Result`, the port raises an exception, since the compiler itself only ever calls `expect` on
that result.
""", nkNim, "A library, ported like a compiler file")

nbText: """
## What was subtle

**Tabs.** The renderer expands a tab to the next multiple of four columns, and the carets under
it are widened to match. A tab is the one character whose width depends on where it stands.

**Wide and invisible characters.** A caret line is drawn in terminal columns, not in characters:
a CJK character gets two carets, a combining accent none. The table says which is which.
"""

nbCode:
  import std/unicode
  import gleam_in_nim/unicode_width
  for text in ["a", "日", "́", "៘"]:
    echo text.runeAt(0).int32.toHex(4), " takes ", text.runeAt(0).width, " columns"

nbText: """
The last one is the single character that the crate says is three columns wide, a Khmer sign.
The table is not typed: a small Rust program in `tools/unicode_width_tables` asks the
crate for the width of every code point and writes the Nim file.

**A binary search with a tie.** When two labels cover exactly the same span, the renderer
decides their order with Rust's `binary_search_by`, and which of two equal elements a binary
search finds depends on how it is written. The port spells out the algorithm of the Rust
standard library instead of calling Nim's, and the differential test has labels with equal spans
to keep it honest.

**Colours.** The snapshots are written without colours, but the command line is not, and a
missing reset code is invisible until someone's terminal stays red. So half of the random
diagnostics are written to a buffer with colours, and the escape codes are compared too.

## The oracle would not build

The plan was the pretty printer's: a small Rust program that links upstream's code, fed the same
random inputs as the port. But `diagnostic.rs` lives in `compiler-core`, and `compiler-core` at
the pin needs a newer Rust than the sandbox has.
"""

nbNote("""
The driver does not link the crate. It compiles upstream's `diagnostic.rs` as a module of its
own, straight from the pinned checkout (`#[path = ".../compiler-core/src/diagnostic.rs"]`), and a
build script cuts the one function it needs from `error.rs` (`wrap`, for hints) out of the pinned
file. Nothing is copied into this repository, and what runs is upstream's code, over the three
crates at the versions of upstream's lock file.
""", nkInfo, "One file is enough")

block:
  var table = "| Seed | Diagnostics | Differences |\n|---:|---:|---:|\n"
  for run in results["runs"]:
    table.add "| " & $run["seed"].getInt & " | " & thousands(run["diagnostics"].getInt) & " | " &
      $run["differences"].getInt & " |\n"
  table.add "| **all** | **" & thousands(total) & "** | **0** |\n"
  nbText: table

nbNote(fmt"""
- {thousands(total)} random diagnostics print byte for byte like upstream, about half of them
  with colours. The outputs were identical on the first run, which is what a
  line by line port is for.
- {results["recorded_cases"].getInt} of those cases are recorded in `tests/data/diagnostics.txt`
  and replayed by `nim r tests/all.nim`, which needs no Rust.

Not checked: real compiler messages (there are none yet), spans that fall outside the source
(upstream panics, the port raises; the compiler never makes one), and the two display styles of
the library that Gleam does not use, which are ported but not tested.
""", nkDone, "What was verified")

nbText: """
## What this changes for the port

- The parser thread can print parse errors as soon as it has them, and compare them with the
  snapshots. The roadmap step *Diagnostics and parse errors* is split in two: the renderer (this
  step, done) and the parse error messages (with the parser).
- `Buffer`, `Diagnostic`, `Location` and `Label` are the types every later error goes through.
- A second component has now been verified against upstream's own Rust. When a crate does not
  build, compiling one file of it as a module is a way through.

## Sources

- `compiler-core/src/diagnostic.rs` in [gleam-lang/gleam v1.19.2](https://github.com/gleam-lang/gleam/blob/v1.19.2/compiler-core/src/diagnostic.rs).
- [codespan-reporting](https://github.com/brendanzab/codespan) by Brendan Zabarauskas and
  contributors (Apache-2.0), [termcolor](https://github.com/BurntSushi/termcolor) by Andrew
  Gallant (Unlicense or MIT), [unicode-width](https://github.com/unicode-rs/unicode-width)
  (MIT or Apache-2.0).
- The [port plan](../the-port-plan/), the [pretty printer](../the-pretty-printer/) step, whose
  method this one repeats, and the [roadmap](../../roadmap/).
"""

nbSave
