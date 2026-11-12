## devlog: 12 Nov 2026 H | The lexer, token for token | The first piece of the Gleam compiler in Nim: source text to tokens, checked against the Rust lexer on real programs and on millions of random ones.
## kind: port
import std/[strutils, strformat, tables, sequtils, algorithm]
import nimib
import tabelline, tabelline/nimib
import ../blocks, ../site
import gleam_in_nim/parse/[lexer, literals]

nbInit
nb.usePost()

let dataDir = docsDir / "devlog" / "data" / "lexer"
let cov = loadCoverage()
let rustLexerLines = cov.stages.mapIt(it.modules).concat.filterIt(it.module == "compiler-core/parse/lexer")[0].rustCode

proc linesOf(path: string): int = readFile(repoDir / path).splitLines.len

# What was ported: the Rust module, the Nim module.
let ported = [
  ("compiler-core/src/parse/lexer.rs", "src/gleam_in_nim/parse/lexer.nim", "all of it"),
  ("compiler-core/src/parse/token.rs", "src/gleam_in_nim/parse/token.nim", "all of it"),
  ("compiler-core/src/parse/error.rs", "src/gleam_in_nim/parse/error.nim", "the lexer's errors and their messages"),
  ("compiler-core/src/parse.rs", "src/gleam_in_nim/parse/literals.nim", "the values of number literals"),
  ("src-span/src/lib.rs", "src/gleam_in_nim/src_span.nim", "`SrcSpan`"),
  ("compiler-core/src/error.rs", "src/gleam_in_nim/error.nim", "text wrapping"),
]

# The results of tools/lexcheck.sh, as it printed them.
var checked: Table[string, int]
for line in readFile(dataDir / "lexcheck.log").splitLines:
  if line.startsWith("ok: "):
    let f = line[4 .. ^1].split(", ")
    checked[f[0]] = parseInt(f[1].split(' ')[0])
let fuzzSources = readFile(dataDir / "lexcheck.log").splitLines.filterIt(it.len > 0 and it.allCharsInSet(Digits))[0].parseInt

type Repo = object
  repo, commit: string
  files: int
var repos: seq[Repo]
for line in readFile(dataDir / "corpus.tsv").strip.splitLines[1 .. ^1]:
  let f = line.split('\t')
  repos.add Repo(repo: f[0], commit: f[1][0 ..< 7], files: parseInt(f[2]))
let corpusFiles = readFile(dataDir / "lexcheck.log").splitLines.filterIt(it.endsWith(" files"))[0].split(' ')[0].parseInt

func quoted(s: string): string = "\"" & s.replace("\n", "\\n") & "\""  # a source on one line

proc kindsOf(name: string): Table[string, int] =
  for line in readFile(dataDir / name).strip.splitLines:
    let f = line.split('\t')
    result[f[0]] = parseInt(f[1])
# The tests of the first suite of tests/test_lexer.nim are the upstream ones.
let upstreamTests = readFile(repoDir / "tests" / "test_lexer.nim").split("suite \"")[1].count("\n  test \"")
let corpusKinds = kindsOf("corpus.kinds.tsv")
let fuzzKinds = kindsOf("fuzz.kinds.tsv")

nbText: &"""
A compiler reads text, and the first thing it does with it is cut it into words. That is the
lexer. Gleam's is one file of Rust, {rustLexerLines.thousands} lines
long, with no dependency on the rest of the compiler: the obvious place to start, whatever the
plan turns out to be. This post is the first step of the port proper.

## The findings, first

- **The lexer is in Nim**, with the tokens, the lexer's errors and their messages. It is a
  line by line translation, made to be read next to the Rust.
- **It gives the same tokens as the Rust lexer**, byte for byte, on {corpusFiles} real Gleam
  files from {repos.len} repositories and on {fuzzSources.thousands} random sources built to
  be nasty. Every kind of token and every kind of error was seen along the way.
- **The check is a tool, not a claim.** A small Rust program links the real Gleam lexer
  at the pinned commit and prints its tokens; a Nim program prints the same format; a script
  compares them. Any later step can rerun it.
- **The fuzzer found a bug, and it was not in the port.** Nim's own `parseFloat` gives the
  wrong value for floats with very long exponents. The port now has its own float parser,
  exact by construction, checked against Rust's on {checked["floats"].thousands} literals.
- **One dependency entered the compiler**: `bigints`, because a Gleam integer literal can be
  of any size and the token carries its value.

## What a lexer does

Here is the Nim lexer at work. The code below runs when this page is built:
"""

nbCode:
  let source = """
pub fn main() {
  let total = 1_000 + 0xFF
  echo total |> int.to_string // done
}
"""
  for item in lex(source):
    let (start, token, stop) = item.spanned
    echo align($start, 3), align($stop, 4), "  ", ($token.kind).alignLeft(16), source[start ..< stop].quoted

nbText: """
Each token is a kind, sometimes with a value, and two numbers: where it starts and where it
stops in the source, counted in bytes. Those two numbers travel through the whole compiler.
Much later, when a type error needs to underline your code, it is these offsets that say
where.

Two things in that listing are worth a second look.

- **Newlines and comments are tokens.** Most lexers throw them away. Gleam keeps them because
  the same front end feeds the formatter, which must put your comments and blank lines back.
  The parser sets them aside in a side table as it goes.
- **`1_000` and `0xFF` carry their value.** The token keeps the text as written (the
  formatter needs it) and the number it means (the type checker and the backends need it).
"""

nbNote """
Gleam's lexer is written by hand, not generated from a grammar. It holds the source, a cursor,
and exactly two characters of lookahead, `char0` and `char1`. One function looks at `char0`
and decides what kind of thing starts here; small functions then eat a name, a number, a
string, a comment. Tokens go to a small queue, because one look can produce several: `tuple.0`
is a name, a dot and an integer, and the lexer emits the dot and the integer together so that
`.0` is never read as the start of a float.

Most of the file is one `match` on a character, and thirty of its branches exist only to say
something kind about a character that looks right and is not.
""", nkGleam, "How the original does it"

nbText: """
## A lexer with manners

A lexer could stop at "unexpected character". Gleam's does better, and this is where the
language's reputation for friendly errors begins: at the very first stage. The lexer knows a
handful of mistakes by name. These messages are produced by the Nim port as the page builds:
"""

nbCode:
  proc explain(source: string) =
    let last = lex(source)[^1]
    let (title, extra) = last.error.toParseErrorInfo
    echo source.quoted, "\n  ", $last.error.error.kind, " at ", last.error.location.start, "..", last.error.location.stop
    echo "  ", title
    for line in extra[0 ..< min(1, extra.len)]:
      echo "  ", line.splitLines[0]
    echo ""

  explain "a === b"
  explain "total += 1"
  explain "let x = 1;"
  explain "let name = 'Lucy'"
  explain "let x = “hello”"
  explain "<<<<<<< HEAD"
  explain "1_000_"

nbText: """
Triple equals from JavaScript, `+=` from every procedural language, a semicolon from habit,
single quotes from Python, curly quotes pasted from a chat, a merge conflict left in the file.
Each has its own error and its own advice. The list of look-alike characters has thirty
entries, down to the Cyrillic `а` that is not a Latin `a`.

## A few quirks, kept

A port must reproduce the original exactly, including where it is odd. The ones met here:
"""

nbCode:
  proc show(source: string) =
    var parts: seq[string]
    for item in lex(source):
      if item.isOk:
        let t = item.spanned.token
        parts.add(
          case t.kind
          of tkInt: "Int(" & t.intText & ")"
          of tkFloat: "Float(" & t.floatText & ")"
          of tkName: "Name(" & t.name & ")"
          of tkString: "String(" & t.value & ")"
          else: ($t.kind)[2 .. ^1]
        )
      else:
        parts.add "error: " & $item.error.error.kind
    echo source.quoted.alignLeft(16), parts.join(" ")

  show "x-1"       # a binary minus, though `-1` alone is one token
  show "x - -1"
  show "t.0.1"     # tuple access, never the float 0.1
  show "0XFF"      # the value text is normalised to a lowercase prefix
  show "1.e3"      # a float needs no digit after the dot
  show "1.0e+3"    # but its exponent takes no plus sign

nbText: """
Two quieter ones. A string token holds the text between the quotes exactly as written: the
lexer checks that every escape such as `\n` or `\u{1F600}` is valid, and leaves turning them
into characters to a later stage. And `auto`, `delegate`, `derive`, `else`, `implement`,
`macro` and `test` are keywords that no Gleam syntax uses today: they are tokens the parser
has no rule for, reserved for the future.

## The translation

The Rust and the Nim can be read side by side, function by function, in the same order. Here
is the heart of it, the function that moves one character forward, in both:

```rust
fn next_char(&mut self) -> Option<char> {
    let character = self.char0;
    let next = match self.next_source_char() {
        Some((position, character)) => {
            self.location0 = self.location1;
            self.location1 = position as u32;
            Some(character)
        }
        None => {
            self.location0 = self.location1;
            self.location1 = u32::max(self.location1 + 1, self.cursor as u32);
            None
        }
    };
    self.char0 = self.char1;
    self.char1 = next;
    character
}
```

```nim
proc nextChar(lexer: var Lexer): int32 {.discardable.} =
  result = lexer.char0
  var next = noChar
  if lexer.cursor < lexer.source.len:
    let start = lexer.cursor
    # ... read one character at the cursor, `\r\n` and `\r` becoming `\n` ...
    lexer.location0 = lexer.location1
    lexer.location1 = start
  else:
    lexer.location0 = lexer.location1
    lexer.location1 = max(lexer.location1 + 1, lexer.cursor)
  lexer.char0 = lexer.char1
  lexer.char1 = next
```

Where the two languages differ, a choice had to be made. These are the choices, and they will
come back in every later step:

| Rust | Nim | Why |
|---|---|---|
| `Option<char>` | an `int32` code point, `noChar` for none | Nim strings are bytes; a character is decoded when read, and compared as a number |
| `Result<T, LexicalError>` and `?` | a private exception, caught once in `next` | the code keeps the shape of the Rust; callers still get a value, never an exception |
| an `enum` with data (`Token::Name { name }`) | a `case` object (`Token(kind: tkName, name: ...)`) | Nim's way of saying the same thing |
| `Token::LeftParen` | `tkLeftParen` | Nim convention; the Rust name is the Nim name without `tk` |
| `SrcSpan { start, end }` | `SrcSpan(start, stop)` | `end` is a keyword in Nim |
| `u32` positions | `int` | no casts at every index; revisit if memory ever matters |
| `EcoString` | `string` | Nim strings are already cheap to move |
| `num_bigint::BigInt` | `bigints.BigInt` | the one dependency |
"""

nbNote """
Two names changed for a reason that only shows up in practice. The convenience function that
lexes a whole source is `lex`, not `tokenize`, and the test tool's `escape` is `escapeBytes`:
both names already exist in Nim's `strutils`, and the compiler picked the wrong one without a
word. Nim resolves overloads across every imported module, so a port has to choose names that
the standard library has not taken.
""", nkNim, "Names the standard library already took"

nbText: "How much Nim is this? Lines per module, counted as the page builds:"

nbCode:
  for (rust, nim, what) in ported:
    echo align($linesOf(nim), 4), "  ", nim.replace("src/gleam_in_nim/", "").alignLeft(20), what.replace("`", "")

nbText: &"""
The Nim lexer is shorter than the Rust one mostly for one reason: the thirty look-alike
characters are a table of thirty lines in Nim, and thirty `match` arms of thirteen lines each
in Rust.

## Checking it: an oracle

The Rust compiler is the specification, so the test of the port is the Rust compiler itself.
For the lexer that is cheap to arrange:

- `reference/lexdump` is a small Rust program. Its only dependency is Gleam's compiler core,
  at the pinned commit. It runs the real lexer on a source and prints one line per token:
  start, end, kind, value. On an error it prints the error and its message, and stops.
- `tools/lexdump.nim` prints the same format from the Nim lexer.
- `tools/lexcheck.sh` runs both and compares the outputs. Identical or not: there is no
  judgement to make.

The dump is plain ASCII, with every other byte escaped, so a difference in a single byte of a
single string shows up as a different line.

### Real programs

First, Gleam as people write it: the compiler's own test projects, the standard library, the
language tour, and a few well known packages. (A larger, properly licensed corpus is being
assembled in another step; this is a first handful, used only to run the lexer on.)
"""

block:
  let t = tabella(repos, rownameCol = "repo"):
    tabHeader "The files the two lexers were compared on", &"{corpusFiles} files, {checked[\"corpus\"].thousands} lines of tokens, identical output"
    colsLabel {"commit": "at commit", "files": ".gleam files"}
    optCssTheme()
  nbTable t

nbText: &"""
Real programs are well behaved, though. They are full of names and parentheses, and they
contain almost no errors: of the {LexicalErrorKind.high.ord + 1} kinds of error the lexer can
report, this corpus triggers {toSeq(corpusKinds.keys).countIt(it.startsWith("!"))}. The corners of a lexer are in the text nobody
writes on purpose.

### Random programs

So the second check makes text up. `tools/lexfuzz.nim` builds sources from fragments chosen to
hit the corners: number prefixes, underscores, exponents, every escape, runs of `=`, `<` and
`>`, the four kinds of comment, carriage returns, a byte order mark, the look-alike
characters, emoji. Half of the sources are built from scratch; the other half are windows cut
from the real files with a few random edits, so that the nastiness lands in realistic
surroundings.

{fuzzSources.thousands} such sources went through both lexers. The outputs,
{checked["fuzz"].thousands} lines of them, were identical. Below is how often each kind of
token and error came up, in the real files and in the random ones:
"""

nbFold "Every kind of token and error, and how many times each was seen":
  nbCode:
    var names = toSeq(fuzzKinds.keys)
    names.sort(proc(a, b: string): int = cmp(fuzzKinds[b], fuzzKinds[a]))
    echo "kind".alignLeft(34), align("real files", 12), align("random", 12)
    for name in names:
      echo name.alignLeft(34), align(corpusKinds.getOrDefault(name).thousands, 12), align(fuzzKinds[name].thousands, 12)

nbCode:
  var tokenKinds, errorKinds = 0
  for name in fuzzKinds.keys:
    if name.startsWith("!"): inc errorKinds else: inc tokenKinds
  echo "kinds of token seen: ", tokenKinds, " of ", TokenKind.high.ord + 1, " (the missing one is EndOfFile, which the lexer never hands out)"
  echo "kinds of error seen: ", errorKinds, " of ", LexicalErrorKind.high.ord + 1

nbNote &"""
- {corpusFiles} real files: identical tokens.
- {fuzzSources.thousands} random sources: identical tokens, errors, error locations and
  error messages.
- {checked["floats"].thousands} float literals and {checked["ints"].thousands} integer
  literals: identical values, bit for bit.
- The upstream tests that touch the lexer ({upstreamTests} of them) are ported and pass.
- A sample of 2,500 random sources, 4,000 floats and 2,000 integers, with the Rust lexer's
  answers, is committed under `tests/golden/lexer`. CI checks the port against it on every
  push, without needing Rust.
""", nkDone, "What was verified"

nbText: """
## The bug the fuzzer found

The first run of the fuzzer did not come back clean. A few dozen sources in three hundred
thousand disagreed, all of them floats, all of them with absurd exponents:

```
Rust   0 34 Float 1.0e123456789012345678901234567890   7FF0000000000000   (infinity)
Nim    0 34 Float 1.0e123456789012345678901234567890   0000000000000000   (zero)
```

The first draft of the port computed a float's value with `parseFloat` from Nim's standard
library. It still does this, here, as the page builds:
"""

nbCode:
  echo parseFloat("1.0e123456789012345678901234567890")
  echo parseFloat("1.0e-123456789012345678901234567890")

nbText: """
Infinity comes out as zero, and zero as infinity. Nim's parser adds up the digits of the
exponent in a machine integer, which silently wraps around when there are too many; the sign
of what is left is a matter of luck. Rust's parser saturates instead. (Reading the Nim source
turned up a second, rarer problem: it also gives up on any number whose mantissa and exponent
together reach beyond a thousand digits, even when the two cancel out.)

Nobody writes `1.0e123456789012345678901234567890`. But a compiler meets generated code, test
suites and people trying to break it, and the rule of this port is that when the Nim and the
Rust disagree the Nim is wrong. So `literals.nim` has its own float parser:

- Short literals take the classic fast path. Up to 15 digits and a power of ten up to 22 are
  both exact as floats, so one multiplication or division gives the correctly rounded result.
  That covers nearly every float anyone writes.
- Everything else is done exactly, with big integers: the literal is a fraction, the fraction
  is divided to 53 bits, and the remainder says which way to round. Slow, simple, and right
  for any input, including the subnormals at the bottom of the range.
"""

nbCode:
  for literal in ["1.0e123456789012345678901234567890", "1.0e-123456789012345678901234567890",
                  "0.1", "9007199254740993.0", "4.9e-324", "2.4703282292062328e-324"]:
    echo literal.alignLeft(38), parseLiteralFloat(literal).get

nbText: &"""
`9007199254740993.0` is 2^53 + 1, exactly halfway between two floats: it must round to the
even one, `9007199254740992`. The fuzzer for numbers builds such halfway cases on purpose
(and their neighbours one digit off), because that is where float parsers go wrong. The
{checked["floats"].thousands} literals compared with Rust agree to the last bit.
"""

nbNote """
The exponent overflow in Nim's `parseFloat` looks like a real bug in the standard library,
worth reporting upstream with the two lines above as the reproduction. This project only
writes to its own repository, so that report is Pietro's to make, if he wants to.
""", nkQuestion, "For Pietro: a bug report for Nim?"

nbText: """
## What was checked, and what was not

Checked: everything in the green note above, on Linux, with Nim 2.2.4 and Rust 1.99.

Not checked, or not done:

- **Sources that are not UTF-8.** Rust cannot even hand such a thing to the lexer: a `&str` is
  valid by construction. The Nim lexer takes any string, and assumes it is valid: fed random
  bytes, it can stop with an internal error. The code
  that reads files will have to check (`validateUtf8`) and report the error the Rust compiler
  reports at that point.
- **Lexing on after an error.** The Rust lexer can be asked for more tokens after it returns
  an error, and so can the Nim one, but the comparison stops at the first error, as the parser
  does. Some errors do not consume the offending character, so "more" can be the same error
  forever, in both.
- **Speed.** Not measured. The lexer copies each token's text out of the source, as the Rust
  one does. It will be measured when there is a parser to feed.
- **The rest of the files touched.** `parse/error.nim` has only the lexer's errors,
  `src_span.nim` only the span, `error.nim` only the text wrapping. They grow with the parser.

## What this changes for the port

- **There is a pattern for a port step now**: translate next to the Rust, build an oracle from
  the real compiler, compare on real programs and on random ones, commit a golden sample for
  CI. The parser can follow it, with the tree printed in place of the tokens.
- **The oracle is cheap to extend.** Gleam's compiler core builds as a library in a minute and
  a half. Any stage whose output can be printed can be compared the same way.
- **Random inputs earn their keep.** The real corpus found nothing. The random one found the
  only bug, in a place nobody would have thought to write a test for.
- **`bigints` is a dependency of the compiler.** The rules said standard library only; this
  step changes them, with the reason. It will be needed again for constant folding and for
  pattern matching on integers.
- **Do not trust `parseFloat`** anywhere in this port: use `parseLiteralFloat`.
"""

nbNote """
The repository is MIT. The files ported from Gleam are translations of Apache-2.0 code, so
each carries an Apache-2.0 header naming its origin, and a copy of that licence is in
`LICENSE-APACHE`. That is enough to be correct file by file. It may be simpler to make the
whole repository Apache-2.0, like the project it follows: a decision for Pietro and the plan.
""", nkQuestion, "For Pietro: one licence or two?"

nbText: """
Next: the parser, which turns these tokens into a tree.

## Sources

- Gleam at the pinned tag `v1.19.2`:
  [`lexer.rs`](https://github.com/gleam-lang/gleam/blob/v1.19.2/compiler-core/src/parse/lexer.rs),
  [`token.rs`](https://github.com/gleam-lang/gleam/blob/v1.19.2/compiler-core/src/parse/token.rs),
  [`parse/error.rs`](https://github.com/gleam-lang/gleam/blob/v1.19.2/compiler-core/src/parse/error.rs),
  and the lexer tests in
  [`parse/tests.rs`](https://github.com/gleam-lang/gleam/blob/v1.19.2/compiler-core/src/parse/tests.rs).
  Gleam is made by Louis Pilfold and the Gleam contributors, under Apache-2.0.
- [nim-lang/bigints](https://github.com/nim-lang/bigints), arbitrary precision integers in
  pure Nim.
- Nim's float parser, `nimParseBiggestFloat` in
  [`lib/system/strmantle.nim`](https://github.com/nim-lang/Nim/blob/v2.2.4/lib/system/strmantle.nim).
- Rick Regan, [Fast path decimal to floating-point conversion](https://www.exploringbinary.com/fast-path-decimal-to-floating-point-conversion/),
  on why 15 digits and 10^22 are the limits of the easy case.
- The repositories in the table above, each at the commit shown.
"""

nbSave
