## devlog: 12 Nov 2026 V | Hex versions and requirements | The first piece of reading gleam.toml: what `~> 1.2 and < 1.5.0` means, ported with its own little lexer and parser, and checked against the Rust on 2.4 million random inputs.
## kind: port
import std/[json, options, os, sequtils, strutils, tables]
import nimib
import ../blocks, ../site
import ../../src/gleam_in_nim/hexpm/version

nbInit
nb.usePost()

let
  root = docsDir.parentDir
  cases = readFile(root / "tests" / "golden" / "hexpm_version" / "cases.txt").strip.splitLines
  expected = readFile(root / "tests" / "golden" / "hexpm_version" / "expected.txt").strip.splitLines
  fuzz = parseFile(docsDir / "devlog" / "data" / "hex_versions" / "fuzz.json")

nbText: """
## The short version

Every Gleam project has a `gleam.toml`, and most of its lines look like this:

```toml
[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
lustre = "~> 5.0"
```

Before the port can build a project it has to read those strings. This step ports the code
that does: about 1,100 lines of Rust in Gleam's `hexpm` crate, which understand the versions
and the version requirements of [Hex](https://hex.pm), the package manager Gleam shares with
Erlang and Elixir.

- **Ported:** the version type and its order, a small lexer, a small parser, in three files
  that follow the three Rust files. All three are *conformant*: upstream's tests pass.
- **Written here, not ported:** the sets of versions a requirement stands for. Upstream takes
  them from a library under a licence we cannot copy from. More on that below.
- **Checked from outside:** a Rust program linked to the real crate answers the same questions
  as the Nim, and the answers are compared. After one fix they are identical on
  """ & fuzz["cases"].getInt.thousands & """ random inputs.

If you have read [What a lexer is](../what-a-lexer-is/), this is the same idea at toy size: a
whole lexer and parser that fit on a phone screen or two.

## A version

Three numbers, then two optional tails: a *pre-release* after a hyphen, and *build metadata*
after a plus. This is the port, running while this page is built:
"""

nbCode:
  for text in ["1.2.3", "1.0.0-rc.1", "0.0.1+sha.0702245", "1.4.5-6-g3318bd5+ignore"]:
    let v = Version.parse(text).value
    echo text.alignLeft(24), " major ", v.major, ", minor ", v.minor, ", patch ", v.patch,
      ", pre ", v.pre.mapIt($it), ", build ", v.build.get("none")

nbText: """
And when it is not a version, the error says what is missing:
"""

nbCode:
  for text in ["2", "2.3", "02.3.0", "1.0.0 beta", "1.0.0-β"]:
    echo text.alignLeft(12), " ", Version.parse(text).error

nbText: """
## Which one is newer

Versions are ordered number by number. Two rules are less obvious, and both are in the code
as a few lines each:

- A pre-release comes **before** its release: `1.0.0-rc1` is older than `1.0.0`.
- Build metadata is **ignored** by the order, yet two versions that differ only there are not
  *equal*. Same place in the queue, different people.
"""

nbCode:
  proc v(text: string): Version = Version.parse(text).value
  echo "1.0.0-rc1 < 1.0.0        ", v"1.0.0-rc1" < v"1.0.0"
  echo "1.0.0-rc1 < 1.0.0-rc2    ", v"1.0.0-rc1" < v"1.0.0-rc2"
  echo "1.0.0-2   < 1.0.0-rc1    ", v"1.0.0-2" < v"1.0.0-rc1", "   (a number sorts before a word)"
  echo "cmp(1.0.0+a, 1.0.0+b)    ", cmp(v"1.0.0+a", v"1.0.0+b")
  echo "1.0.0+a == 1.0.0+b       ", v"1.0.0+a" == v"1.0.0+b"

nbText: """
That last pair looks like a curiosity. It is where the one bug of this step was hiding.

## A requirement

A requirement is a little language: comparisons joined by `and` and `or`, where `and` binds
tighter. `~>`, the *pessimistic* operator, means "this version or newer, but do not cross the
next big number". The parser turns each requirement into a set of versions, and a set is
printed as intervals:
"""

nbCode:
  for text in ["~> 5.0", "~> 5.0.2", ">= 0.44.0 and < 2.0.0", "!= 1.2.3", "<= 1.0.0",
               "> 1.0.0-rc1", "~> 1.0 or == 0.5.0", "< 1.0.0 and > 2.0.0", "< 1.0.0 or >= 1.0.0"]:
    echo text.alignLeft(24), " ", Range.new(text).value.toPubgrub

nbText: """
`∅` is the empty set (nothing can satisfy it) and `*` is everything. Reading the table:

- `~> 5.0` stops before `6.0.0`, and `~> 5.0.2` before `5.1.0`: the last number you write is
  the one allowed to grow.
- `<= 1.0.0` becomes `<1.0.1`, and `> 1.0.0-rc1` becomes `>=1.0.1`. Upstream never builds
  "greater than" or "up to and including": it bumps the patch number and uses "from" and
  "below". The second one skips `1.0.0` itself, which is surprising, and it is what Gleam
  does, so it is what the port does.
"""

nbNote """
The Rust compiler is the specification: when it does something odd, the port does the same odd
thing. Two more that the tests pinned down. Build metadata swallows the rest of the line, so
`1.0.0+a or 2.0.0` is an error. And a number too big for 32 bits is not an error at all: the
lexer quietly calls it a word.
""", nkGleam, "Odd, and kept"

nbText: """
## A lexer and a parser, small enough to see whole

The lexer walks the string with two characters of lookahead and gives out tokens: `>=`, `~>`,
`.`, `-`, `+`, `and`, `or`, a number, a word, whitespace. The parser reads the tokens with one
token of lookahead, and has one procedure per thing it can meet: `version`, `pre`, `range`, and
so on. Each calls the others, which is all "recursive descent" means.

One thing did not translate directly. In Rust the lexer and the parser are private submodules
of `version`, and they use each other's types in a circle, which Nim's imports do not allow.
So the two files are *included* in `version.nim`: three files as upstream has, one module
as Nim wants.
"""

nbNote """
Errors travel differently too. Rust returns them (`Result`, and `?` to pass one up). The port
raises a private exception inside the module and catches it at the door, so the outside sees a
value, `ParseResult`, like upstream's. Same rule as the lexer of Gleam itself, earlier in this
devlog.
""", nkNim, "In the port"

nbText: """
## The part that was not ported

The sets of versions (`>=1.0.0, <2.0.0 | >=7.0.1`) are not Gleam's code. They come from
[`version-ranges`](https://crates.io/crates/version-ranges), a crate of the
[PubGrub](https://github.com/pubgrub-rs/pubgrub) project, the dependency solver Gleam uses. Both
are under the Mozilla Public License 2.0. This repository is Apache-2.0, and a translation of
an MPL file stays under the MPL, so the rule here is not to translate it.

Instead `version_ranges.nim` was written from scratch: a sorted list of intervals, with union,
intersection, membership and printing. That is the kind of code that is easy to get almost
right, so it is not trusted on reading. It is trusted on this:
"""

nbCode:
  var kinds = initCountTable[string]()
  var sources = initCountTable[string]()
  for line in cases:
    let f = line.split('\t')
    kinds.inc({"V": "parse a version", "R": "parse a requirement", "C": "compare two versions",
               "T": "is this version in this requirement"}.toTable[f[0]])
    sources.inc f[1].split(':')[0]
  echo "cases kept in the repository: ", cases.len
  for kind, n in kinds: echo "  ", align($n, 5), "  ", kind
  echo "where they come from:"
  for source, n in sources: echo "  ", align($n, 5), "  ", source
  echo "requirements the Rust accepts: ", zip(cases, expected).countIt(it[0].startsWith("R") and it[1].startsWith("ok"))

nbText: """
Each case went through a forty line Rust program linked to the real `hexpm` crate, and its
answers are stored next to the cases. The Nim tests replay them on every run of CI, with no
Rust needed. `upstream` are the inputs of upstream's own tests, `corpus` every version and
requirement of our [corpus](../a-corpus-of-real-gleam/), `random` strings from a generator
with a fixed seed.

Then the same generator was run with other seeds, much longer, Nim against Rust:
"""

nbCode:
  echo "first run:  ", fuzz["first_run"]["cases"].getInt.thousands, " cases, ",
    fuzz["first_run"]["different"].getInt, " different"
  echo "  example:  ", fuzz["first_run"]["example"].getStr
  echo "  rust:     ", fuzz["first_run"]["rust"].getStr
  echo "  nim:      ", fuzz["first_run"]["nim"].getStr
  echo "after the fix: ", fuzz["cases"].getInt.thousands, " cases over ", fuzz["seeds"].len, " seeds, ",
    fuzz["different"].getInt, " different"

nbText: """
Eight in eight hundred thousand, and all eight the same story: two versions equal in order
and different in build metadata meet at the edge of an interval, and somebody has to choose
which one to keep. The crate keeps the second when it takes a maximum and the first when it
takes a minimum, because that is what Rust's `max` and `min` do with equal values. My first
version kept the first both times. It is a one character fix, and no amount of staring at
requirements people actually write would have found it: nobody writes build metadata in a
requirement. The rule is now a row in the [porting guide](../../porting/).
"""

nbNote """
What was verified: upstream's lexer tests and error tests pass; every input of upstream's
macro-made tests, the corpus, and the random cases get the answer the Rust crate gives; two
long random runs found no difference after the fix. What was not: the Rust half runs in the
sandbox, not in CI (CI replays the stored answers). `version_ranges.nim` is known to match
the crate only where the requirement parser can drive it. One error message differs on
purpose for unprintable characters, and is listed among the
[divergences](../../decisions/#divergences). Reading and writing versions inside TOML and
JSON comes with the files that need it.
""", nkDone, "Checked, and not"

nbNote """
Gleam resolves dependencies with the PubGrub solver, under the same MPL licence. When the port
gets there (the last phases of the roadmap), the choice is between writing a solver here from
the published algorithm, or deciding something else. Nothing is blocked today:
[decision 0011](../../decisions/#0011-version-ranges-are-written-here-not-ported-from-version-ranges)
records it.
""", nkQuestion, "For later: the solver"

nbText: """
## What this changes for the port

1. **The port can read a requirement**, the commonest value in `gleam.toml` and
   `manifest.toml`. Next is the TOML around it.
2. **A second way to be sure.** For code we may not read closely, or may not copy, a driver
   over the original plus a generator of inputs is a specification we can run. The pattern is
   in `tests/differential/hexpm_version/`.
3. **Licences are checked before reading**, crate by crate. It is now in the porting guide.
4. **`Ord` and `Eq` can disagree** in Rust, and code leans on it. A new trap in the guide.

## Sources

- [`hexpm/src/version.rs`](https://github.com/gleam-lang/gleam/blob/v1.19.2/hexpm/src/version.rs),
  [`version/lexer.rs`](https://github.com/gleam-lang/gleam/blob/v1.19.2/hexpm/src/version/lexer.rs),
  [`version/parser.rs`](https://github.com/gleam-lang/gleam/blob/v1.19.2/hexpm/src/version/parser.rs)
  and [`version/tests.rs`](https://github.com/gleam-lang/gleam/blob/v1.19.2/hexpm/src/version/tests.rs)
  in the Gleam repository, by the Gleam contributors. The lexer and parser say they are based
  on Steve Klabnik's [semver-parser](https://github.com/steveklabnik/semver-parser).
- [Elixir's `Version` module](https://hexdocs.pm/elixir/Version.html), which defines the syntax
  Hex uses and which upstream's tests are adapted from.
- [`version-ranges`](https://crates.io/crates/version-ranges) and
  [PubGrub](https://github.com/pubgrub-rs/pubgrub), for the licence and the documented
  behaviour of ranges; their source was not translated.
- In this repository: `src/gleam_in_nim/hexpm/version.nim` and `version/`,
  `src/gleam_in_nim/version_ranges.nim`, `tests/test_hexpm_version.nim`,
  `tests/differential/hexpm_version/`.
"""

nbSave
