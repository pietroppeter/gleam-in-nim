## devlog: 12 Nov 2026 V | Versions, and the ranges between them | What `~> 1.2 and < 2.0.0` means to Gleam: the first piece of dependency resolution, ported with the set of ranges under it and checked five million times against the Rust.
## kind: port
import std/[json, os, strformat, strutils]
import nimib
import ../blocks
import gleam_in_nim/hexpm/version
import gleam_in_nim/hexpm/version/lexer
import gleam_in_nim/rust_debug

nbInit
nb.usePost()

const docsDir = currentSourcePath.parentDir.parentDir
let
  results = parseJson(readFile(docsDir / "devlog" / "data" / "versions_and_ranges" / "differential.json"))
  srcDir = docsDir.parentDir / "src" / "gleam_in_nim"

proc thousands(n: int): string = insertSep($n, ',')
proc linesOf(path: string): int = readFile(srcDir / path).countLines

var cases, rejected = 0
for run in results["runs"]:
  cases += run["cases"].getInt
  rejected += run["rejected"].getInt
let
  mutants = results["mutants"]["caught"].getInt + results["mutants"]["survived"].getInt
  caught = results["mutants"]["caught"].getInt
  hexLines = linesOf("hexpm/version.nim") + linesOf("hexpm/version/lexer.nim") + linesOf("hexpm/version/parser.nim")
  rangesLines = linesOf("version_ranges.nim")

nbText: fmt"""
## The short version

- **What**: the version module of Gleam's `hexpm` crate (versions, their order, and the little
  language of requirements such as `~> 1.2 and < 2.0.0`) is now `src/gleam_in_nim/hexpm/version.nim`
  and two files beside it, {thousands(hexLines)} lines of Nim. Under it sits a set of ranges that
  Gleam takes from a Rust library, `version-ranges`: also ported, {thousands(rangesLines)} lines.
- **Who needs it**: `gleam.toml` (every dependency has a requirement), `manifest.toml`, and the
  resolver that picks one version of every package. The resolver is the next step.
- **Checked how**: upstream's own tests pass, and a differential test asked the Rust and the Nim
  the same {thousands(cases)} random questions: **0 differences**. Then we planted {mutants} small
  bugs in the Nim, one at a time, to see if the test would notice: it caught {caught}.
- **Surprises**: two versions can be *not equal* and *neither smaller*; `<= 1.0.0` lets
  `1.0.1-rc1` in; the words `and` and `or` are recognised anywhere, even inside a name; and the
  library under the ranges has a different licence from Gleam's, which needed a decision.

## What a version is

Hex, the package manager that Erlang, Elixir and Gleam share, wants every version to be three
numbers, `MAJOR.MINOR.PATCH`. Two optional tails can follow: a *pre-release* after a hyphen
(`1.0.0-rc.1`) and *build metadata* after a plus (`1.0.0+20130417`). Upstream says its module is
"based off and compatible with the Elixir Version module".

A version is parsed into five fields. Here is the port doing it:
"""

nbCode:
  let parsed = parse("1.4.5-rc.2+linux").value
  echo parsed.major, " ", parsed.minor, " ", parsed.patch
  echo parsed.pre     # the pre-release, cut at the dots: a word and a number
  echo parsed.build
  echo parsed         # and printed back

nbText: """
The order is the interesting part. Numbers compare as numbers. A pre-release comes *before* the
release it prepares. Among pre-releases, a number is before a word, and words go letter by
letter. Build metadata is not looked at.
"""

nbCode:
  proc order(left, right: string): string =
    let ordering = cmp(parse(left).value, parse(right).value)
    left & (if ordering < 0: " < " elif ordering == 0: " = " else: " > ") & right
  echo order("1.10.0", "1.9.0")          # numbers, not text
  echo order("1.0.0-rc1", "1.0.0")       # a pre-release is before its release
  echo order("1.0.0-2", "1.0.0-rc1")     # a number is before a word
  echo order("1.0.0-rc10", "1.0.0-rc2")  # words go letter by letter: "rc1" < "rc2"
  echo order("1.0.0+linux", "1.0.0+mac") # the build is not looked at

nbNote("""
The last line hides a trap for a port. In Rust, upstream *derives* equality (`==` compares every
field, the build too) and *writes* the order by hand (the build is skipped). So `1.0.0+linux` and
`1.0.0+mac` are not equal, and neither is smaller. Nothing is wrong with that, but Rust keeps the
two comparisons apart and so must the Nim: the code of the ranges uses `==` in some places and
`<` in others, and swapping one for the other changes what is printed. The differential test
below was built to catch exactly this.
""", nkGleam, "Equal is not the same as not smaller, not greater")

nbCode:
  let (linux, mac) = (parse("1.0.0+linux").value, parse("1.0.0+mac").value)
  echo linux == mac, " ", linux < mac, " ", mac < linux

nbText: """
## A requirement is a set

`gleam.toml` does not name versions, it names *requirements*:

```toml
[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
lustre = "~> 5.0"
```

Upstream turns a requirement into a set of ranges at once, and forgets the operators. That is
the whole meaning of each operator: the set it becomes. The port prints the set the way the
Rust library does, and this is the text that ends up in `manifest.toml` and in the messages of
the resolver:
"""

nbCode:
  proc show(requirement: string) =
    let range = newRange(requirement)
    echo alignLeft(requirement, 26), (if range.isOk: $range.value.toPubgrub else: "error: " & $range.error)
  show "1.2.3"
  show "== 1.2.3"
  show ">= 1.2.3"
  show "> 1.2.3"
  show "< 1.2.3"
  show "<= 1.2.3"
  show "!= 1.2.3"
  show "~> 1.2"
  show "~> 1.2.3"
  show ">= 1.0.0 and < 2.0.0"
  show "~> 1.2 or ~> 3.0.0"
  show "< 1.0.0 and > 2.0.0"

nbText: """
Read the list slowly, it has three things worth knowing.

**There is no "greater than".** `> 1.2.3` becomes `>= 1.2.4`, and `<= 1.2.3` becomes `< 1.2.4`:
upstream adds one to the patch number and keeps only two kinds of edge. With three plain numbers
that is the same thing. With pre-releases it is not quite:
"""

nbCode:
  let atMost = newRange("<= 1.0.0").value.toPubgrub
  echo atMost, " contains 1.0.1-rc1: ", atMost.contains(parse("1.0.1-rc1").value)
  let differentFrom = newRange("!= 1.2.3").value.toPubgrub
  echo differentFrom, " contains 1.2.4-rc1: ", differentFrom.contains(parse("1.2.4-rc1").value)

nbText: """
A pre-release of the *next* patch is "at most 1.0.0", and a pre-release of 1.2.4 is not
"different from 1.2.3". Whether Elixir's module answers the same was not checked: the port
follows the Rust, and this is what the Rust says.

**`~>` is the one everybody uses**, and it has two forms. With two numbers, `~> 1.2` allows
anything from 1.2.0 up to the next major. With three, `~> 1.2.3` allows anything up to the next
minor. `gleam add` writes requirements of this kind.

**An impossible requirement is not an error.** `< 1.0.0 and > 2.0.0` is a perfectly good empty
set, printed `∅`. It is the resolver's job to complain, later, with the names of the packages
that asked for it.
"""

nbNote("""
The three numbers are `u32` upstream, and adding one to the largest wraps around to zero,
because the released compiler is built without overflow checks. So `~> 4294967295.2` is the
range from 4294967295.2.0 up to 0.0.0: empty. A Nim `uint32` wraps the same way, so the port
has this behaviour for free. Nobody will ever meet it. It is here because "identical" has to
include the corners, and the random test visits this one all the time.
""", nkNim, "The largest version number")

nbCode:
  show "~> 4294967295.2"
  show "> 1.0.4294967295"

nbText: """
## A lexer and a parser, in small

The text of a requirement goes through the same two stages as Gleam source, only tiny: a
*lexer* cuts it into tokens, a *parser* reads the tokens and builds the result. If those words
are new, the series has [What a lexer is](../what-a-lexer-is/) and
[What a parser is](../what-a-parser-is/); this pair is a good second example because it fits on
a page. Here are the tokens of a requirement:
"""

nbCode:
  proc tokens(input: string): string =
    var lexer = initLexer(input)
    while true:
      let token = lexer.next()
      if token.isNone: break
      result.add (if token.get.kind == vtWhitespace: "_" else: $token.get) & "  "
  echo tokens("~> 1.2 and < 2.0.0-rc1")

nbText: """
The lexer knows very little. It does not know what a version is: it sees numbers, words, dots,
hyphens and operators. It also has a habit that comes straight from being simple: it looks for
the two letters `or`, and for `an` followed by `d`, *before* it looks for a word. So:
"""

nbCode:
  echo tokens("1.0.0-order")
  for input in ["0.1.0-andpre", "1.0.0-order", "1.0.0-beta-1", "1.2", "1.2.3 and", "1.0.0-01", "1.0.0 🙂"]:
    let range = newRange(input)
    echo alignLeft(input, 14), (if range.isOk: "ok   " & $range.value.toPubgrub else: "no   " & $range.error)

nbText: """
A pre-release called `order` cannot be written, because it starts with `or`. Upstream knows:
its tests include `0.1.0-andpre` as a version that must fail. The port fails the same way, with
the same message, and the message is part of the contract: `gleam` prints it when a
`gleam.toml` has a requirement it cannot read.

Those messages contain a detail that cost a small module. `"and"` and `'🙂'` above are in
quotes because Rust printed them with `{:?}`, its *debug* form, which also escapes what cannot
be seen. To print the same bytes the port needs Rust's idea of which characters are printable,
and that is a table of Unicode. We did not copy it: a twenty line Rust program asks Rust about
every code point and writes the answer as a Nim file.
"""

nbCode:
  echo debugStr("a\tb"), " ", debugStr("é"), " ", debugStr("zero​width")
  echo "the table follows Unicode ", rustDebugUnicodeVersion

nbNote("""
Upstream's parser and its parent module use each other: the parser builds a `Version`, and
`Version::parse` runs the parser. Rust modules may form such a circle, Nim modules may not. So
`hexpm/version.nim` declares the types and then *includes* `hexpm/version/parser.nim`, which
stays a file of its own, with its own origin header, next to the Rust file it ports.

Where the Rust has `?` (return the error to my caller), the Nim raises an exception that never
leaves the module: `parse` and `newRange` catch it and return the error as a value, as the
Rust does. The lexer of Gleam source was ported the same way.
""", nkNim, "Two things Nim does differently")

nbText: """
## The set of ranges

The set itself is not Gleam's code. Gleam resolves dependencies with
[pubgrub](https://github.com/pubgrub-rs/pubgrub), a Rust implementation of the PubGrub
algorithm, and a requirement *is* a value of the type that library uses for sets of versions,
from its small companion crate `version-ranges`. To parse a requirement the way Gleam does, the
port needs that type. It is a sorted list of segments that never touch, and three operations do
all the work:
"""

nbCode:
  let
    one = newRange("~> 1.2").value.toPubgrub
    other = newRange(">= 1.5.0 or == 0.9.0").value.toPubgrub
  echo "one:          ", one
  echo "other:        ", other
  echo "both:         ", one.intersection(other)
  echo "either:       ", one.union(other)
  echo "not one:      ", one.complement()
  echo "one in other: ", one.subsetOf(other)

nbText: """
The resolver will live on these: "both" is how two packages that ask for the same dependency
are reconciled, "not" is how it remembers what has been ruled out, and an empty "both" is a
conflict.
"""

nbNote("""
Gleam is under the Apache-2.0 licence, and so is this repository. `version-ranges` and `pubgrub`
are under the Mozilla Public License 2.0, which works per file: a file translated from an MPL
file stays MPL, and may live inside a project under another licence. So
`src/gleam_in_nim/version_ranges.nim` says MPL-2.0 in its first lines, holds nothing but the
translation, and is listed in `NOTICE`; the licence text is in `LICENSES/`. The solver will
follow the same rule. This is [decision 0011](../../decisions/#0011-a-port-of-an-mpl-2-0-crate-keeps-the-mpl-2-0-file-by-file):
it is Pietro's to overturn, and cheap to undo, because these files are few and sit behind a
narrow interface.
""", nkQuestion, "One file with another licence")

nbText: fmt"""
## How it was checked

**Upstream's tests.** The version module has its tests in `hexpm/src/version/tests.rs` and at
the end of its lexer: 105 of them in Nim, same names, all passing. (One is left out: it tests
the TOML writer, which is not ported yet.)

**The Rust as the oracle.** `cargo` works in the sandbox, so the same trick as for the pretty
printer applies. A small Rust program links upstream's `hexpm` crate from the pinned checkout,
and `pubgrub` at the version of Gleam's lock file. It reads questions, one per line, and prints
answers. A Nim program with the same shape does the same with the port. The two outputs must
be the same file. The questions are random, from a generator with two moods: a wide one (big
numbers, odd characters, text damaged on purpose) and a narrow one, where every number is 0, 1
or 2, so that versions collide, edges touch and the same version turns up with two builds.
"""

block:
  let names = {"V": "parse a version", "C": "compare two versions", "R": "parse a requirement",
               "O": "operations on two requirements", "B": "operations on two sets built from any segments",
               "S": "simplify a set, given some versions", "I": "one set from the segments of several"}
  var table = "| Question | Cases |\n| --- | ---: |\n"
  for (letter, name) in names:
    var count = 0
    for run in results["runs"]: count += run["kinds"][letter].getInt
    table.add "| " & name & " | " & thousands(count) & " |\n"
  table.add "| **all** | **" & thousands(cases) & "** |\n"
  nbText: table

nbText: fmt"""
Of the versions and requirements, {thousands(rejected)} were rejected, by both sides, with the
same message.

**Is the test any good?** A test that passes proves little until it has been seen to fail. So
`mutants.sh` plants one small bug in the Nim ({mutants} of them: a `<` for a `<=`, a branch
removed, the build forgotten in an equality, a wrong escape) and runs the comparison again. A
bug that goes unnoticed is a hole in the generator. The first run had four holes: two were bugs
that change nothing (and were dropped from the list), two were real, and the generator learned
to produce the delete character and capital letters. It also found a bug in the test script we
had copied from the pretty printer's: when the outputs differed it stopped before saying where.
Both scripts are fixed.
"""

nbNote(fmt"""
- Upstream's 105 tests of the version module pass.
- {thousands(cases)} random cases print the same bytes as the Rust at the pin: versions, errors,
  requirements, and the operations on sets of ranges.
- {caught} of {mutants} planted bugs are caught.

Not checked: the `serde` parts (reading and writing versions in TOML and JSON), which are not
ported yet. The table of printable characters is that of the Rust toolchain in the sandbox
(Unicode {rustDebugUnicodeVersion}); the released `gleam` binary may have been built with
another Unicode version, which could only show for a character assigned between the two,
inside an error message. The differential test needs `cargo` and the reference checkout, so it
is run by hand (`tests/differential/version/run.sh SEED COUNT`), not on every commit.
""", nkDone, "What was verified")

nbText: """
## What this changes for the port

- The step `dependency-resolution` of the [roadmap](../../roadmap/) is now two: *Hex versions
  and requirements*, done here, and *Dependency resolution*, started: the requirement of
  `gleam.toml` (a Hex range, a path or a git repository), then the solver, then the manifest.
- `rust_debug.nim` is for everyone: any message that upstream formats with `{:?}` can use
  `debugStr` and `debugChar`.
- The [porting guide](../../porting/) gains five traps: modules that use each other, `==`
  against `<`, `max` of two equal things, overflow in release mode, and the debug form.
- A new habit worth keeping: **plant bugs to test the test**. It took ten minutes and found
  holes in a comparison that was already reporting zero differences.

## Sources

- `hexpm/src/version.rs`, `version/lexer.rs`, `version/parser.rs` and `version/tests.rs` in
  [gleam-lang/gleam v1.19.2](https://github.com/gleam-lang/gleam/tree/v1.19.2/hexpm/src). The
  lexer and the parser say they are based on Steve Klabnik's
  [semver-parser](https://github.com/steveklabnik/semver-parser).
- [version-ranges](https://github.com/pubgrub-rs/pubgrub/tree/main/version-ranges) 0.1.3, by the
  pubgrub-rs contributors (MPL-2.0), read from the crate as cargo downloads it.
- The [Mozilla Public License 2.0](https://www.mozilla.org/en-US/MPL/2.0/) and its
  [FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/). They were not reachable from the sandbox
  and were not read again for this step: what the note above says about the licence comes from
  the licence text shipped with the crate.
- Elixir's [Version](https://hexdocs.pm/elixir/Version.html) module, which upstream names as its
  model. Not read for this step.
- [The pretty printer](../the-pretty-printer/), where the Rust crate was first used as the oracle.
"""

nbSave
