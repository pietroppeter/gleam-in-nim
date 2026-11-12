## devlog: 12 Nov 2026 X | Erlang, one call at a time | The builder that writes Gleam's Erlang is ported, and the real Rust one sat beside it for eight million calls. They disagreed once, on the last digit of a float.
## kind: port
import std/[json, options, os, strformat, strutils]
import nimib
import ../blocks
import pkg/bigints
import gleam_in_nim/src_span
import gleam_in_nim/erlang_generation {.all.}

nbInit
nb.usePost()

const here = currentSourcePath().parentDir
let sizes = parseJson(readFile(here / "data" / "the_erlang_builder" / "sizes.json"))
let erlcheck = readFile(here / "data" / "the_erlang_builder" / "erlcheck.out.txt").strip

proc thousands(n: int): string = insertSep($n, ',')

# The numbers of the text come from the two lines erlcheck printed:
# "ok: fuzz, N scripts, N calls, N lines of output identical, N of the scripts end in ..."
proc numbers(line: string): seq[int] =
  for word in line.replace(",", " ").splitWhitespace:
    if word.allCharsInSet(Digits): result.add parseInt(word)
let fuzz = numbers(erlcheck.splitLines[0])
let floats = numbers(erlcheck.splitLines[1])
let
  rustLines = sizes["rust_lines_ported"].getInt
  rustComments = sizes["rust_comment_lines_ported"].getInt
  functions = sizes["trait_functions"].getInt

nbText: fmt"""
## The short version

- The Gleam compiler does not print Erlang directly. Its code generator makes **calls** on a
  builder (start a function, start a tuple, an atom, an integer, end the tuple...) and the
  builder writes the text. That builder, the first {thousands(rustLines)} lines of
  `erlang-generation/src/lib.rs`, is now `src/gleam_in_nim/erlang_generation.nim`.
- It was checked against the real thing. A small Rust program links Gleam's own crate at the
  pinned commit and replays a script of calls; a Nim program replays the same script with the
  port. On **{thousands(fuzz[0])} random scripts, {thousands(fuzz[1])} calls**, the two wrote
  the same {thousands(fuzz[2])} lines, including the text of {thousands(fuzz[3])} internal
  errors.
- Before that result there was one difference, and it was not in the builder: Nim and Rust do
  not print every float alike. Two floats in forty thousand scripts differed in their last
  digit. The port now has its own float printer, checked on {thousands(floats[1] - 2)} floats.
- A real module, `shapes.erl` from [The BEAM, explained](../the-beam/), is rebuilt in a test
  with {functions} kinds of call and nothing else, byte for byte.
- Main moved while this was written: it now has a rule for how every Rust enum with data is
  written in Nim. The module was reshaped to it at the end, and the oracle said "identical"
  again in a minute. That is what an oracle is for.

## A builder, not a printer

Since 1.19 Gleam can write Erlang in two forms: text (`.erl`) and the binary abstract format
that `gleam build` hands to the Erlang compiler
([Speaking Erlang in bytes](../the-erlang-term-format/) ported the encoder under the second).
One code generator serves both. It never touches a string: it talks to an interface,
`ErlangBuilder`, that has {functions} functions and two implementations. This step ports the
one that writes text.

Here is the ported builder writing a function. The page runs this code as it is built.
"""

nbCode:
  let at = initSrcSpan(0, 0)   # where in the Gleam source: the text builder ignores it
  var b = default(ErlangSourceBuilder)

  b.moduleDeclaration(newErlangModuleName("my/app"))
  let function = b.startFunction(at, "main", 0, newSeq[(SrcSpan, string)]())
  let tup = b.startTuple(at)
  b.atomExpression(at, "ok")
  b.intExpression(at, initBigInt(42))
  b.endTuple(tup)
  b.endFunction(function)
  echo b.intoOutput()

nbText: """
Nobody wrote a comma, a brace, an indentation or the final full stop. The builder did, and to
do it it must know **where it is**. It keeps a stack of *positions*: "in the statements of a
function, none written yet", then on top "in a tuple, first item not written yet". Every call
looks at the top of the stack, writes what must come before (a comma, a newline and four
spaces), writes its own text, and updates the stack. `endTuple` pops and writes `}`.

Three places where that stack earns its keep:
"""

nbCode:
  proc demo(body: proc (b: var ErlangSourceBuilder)): string =
    var b = default(ErlangSourceBuilder)
    let function = b.startFunction(at, "f", 0, newSeq[(SrcSpan, string)]())
    body(b)
    b.endFunction(function)
    b.intoOutput().strip.splitLines[^1].strip

  # A list is cons cells, one inside the other, as Erlang's abstract format wants.
  echo demo(proc (b: var ErlangSourceBuilder) =
    b.consList(at); b.intExpression(at, initBigInt(1))
    b.consList(at); b.intExpression(at, initBigInt(2))
    b.consList(at); b.variable(at, "X")
    b.emptyList(at))

  # An operator inside an operator gets parentheses.
  echo demo(proc (b: var ErlangSourceBuilder) =
    b.binaryOperator(at, "*")
    b.binaryOperator(at, "+"); b.variable(at, "A"); b.variable(at, "B")
    b.variable(at, "C"))

  # Calling the result of a call needs parentheses (until OTP 29). A string is a binary.
  echo demo(proc (b: var ErlangSourceBuilder) =
    let outer = b.startCall(at)
    let inner = b.startCall(at)
    b.atomExpression(at, "make_greeter")
    b.endCall(b.endCalledExpression(inner))
    let call = b.endCalledExpression(outer)
    b.stringExpression(at, "caf\\u{e9}")
    b.endCall(call))

nbText: """
The list is the instructive one. The calls say `[1 | [2 | [X | []]]]`, and there is no
`endList`. The builder prints `[1, 2, X]` because when a cons cell arrives where the rest of a
list was expected, it writes a comma instead of opening a new list; and it only learns that a
list is over when the *next* thing arrives, so every call starts by closing what was left
open. The last line also shows a translation: Gleam's `\u{e9}` is Erlang's `\x{e9}`, and the
`~` makes the Erlang string a binary, which is what a Gleam `String` is.

And when the calls make no sense, the builder says where it was:
"""

nbCode:
  var wrong = default(ErlangSourceBuilder)
  discard wrong.startFunction(at, "f", 0, newSeq[(SrcSpan, string)]())
  discard wrong.startTuple(at)
  try:
    wrong.typeVariable("A")   # a type, inside a tuple of values
  except AssertionDefect as error:
    echo error.msg

nbNote("""
That message is the Rust one, character for character: `unreachable!` and the `{:?}` of the
position on top of the stack. It is a bug report for the compiler's authors, not something a
Gleam user should ever see, but "the Rust is the specification" has no exception for messages,
and a wrong call in *our* code generator will be much easier to find with it.
""", nkGleam, "The same words as upstream")

nbText: fmt"""
## How do you test a file that has no tests?

The crate `erlang-generation` has none. Upstream tests the builder through the snapshot tests
of the whole Erlang backend, which the port will only be able to run when it has a parser, a
type checker and a code generator. Waiting that long to learn that a comma is missing is a bad
plan.

So the Rust was made to testify. `reference/erldump` is a small Rust program: it depends on Gleam's crate at the pinned commit, reads a script with one call per
line, makes those calls on the real `ErlangSourceBuilder`, and prints what comes out, or the
panic message. `tools/erldump.nim` does the same with the port. A script looks like this:

```text
start_function	0:0	main	0
start_tuple	0:0
atom_expression	0:0	ok
int_expression	0:0	42
end_tuple
end_function
```

`tools/erlfuzz.nim` writes random scripts: modules with attributes, records, type specs and
functions, every one of the {functions} calls, nested at random, with the nasty values (atoms
that are reserved words or need quotes, strings full of backslashes, integers of sixty digits,
floats made of random bits). One script in four then has a line deleted, repeated or swapped
with its neighbour, to walk into the internal errors on purpose.
`tools/erlcheck.sh` builds both programs, runs them and compares. Its last run:
"""

nbText: "\n```text\n" & erlcheck & "\n```\n"

nbText: """
CI has no Rust toolchain, and should not need one. 400 of those scripts are kept in
`tests/golden/erlang_builder/` with the output of the reference, and the test replays them on
every push.

### The one difference

The first long run stopped here:

```text
< |             -1391943062256.1563 div 10,
> |             -1391943062256.1562 div 10,
```

`<` is Rust, `>` was Nim. Both decimals, read back, give the very same float: it has more
digits than a decimal of 17 can pin down, and those two are the two candidates. Rust prints
the one closer to the true value. Nim's `$` printed the other.
"""

nbCode:
  let x = -1391943062256.1563
  echo "Nim's $:         ", $x
  echo "the port prints: ", erlang_generation.formatFloat(x)
  echo "same float?      ", -1391943062256.1563 == -1391943062256.1562

nbText: fmt"""
The generated Erlang would have meant the same number. But the goal is the same *bytes* as the
reference compiler, so the port cannot borrow Nim's printer. `shortestDigits` in the module is
the classic algorithm for the job (Steele and White, in the form Burger and Dybvig gave it in
1996), on big integers: slow next to what Rust uses, but short and exact. Rust also never
writes an exponent, and prints a float without fractional part by its exact value:
"""

nbCode:
  for value in [1.5e-7, 1e21, 1e23, 0.1, -0.0]:
    echo ($value).alignLeft(8), " ", erlang_generation.formatFloat(value)

nbText: fmt"""
Then {thousands(floats[1] - 2)} floats of every size went through both sides (random bits,
powers of two and their neighbours, subnormals, short decimals): identical.

### A real module

Random scripts prove that the two builders agree. They do not prove that I understand how the
calls are meant to be used, and the next step (the code generator) depends on that. So the
test also rebuilds `shapes.erl`, a module the reference `gleam` 1.19.2 wrote for the BEAM
post: types, specs, docs, `case` with guards, bit arrays, a map, an anonymous function, a
pipeline. A few hundred calls typed by hand from reading the Erlang, and the output is the file,
byte for byte. It passed on the first run, which says more about the builder's design than
about my typing: there is very little a caller can get subtly wrong. Either the text is right
or the builder stops you.
"""

nbNote("""
- The random scripts are valid sequences of calls, not valid programs: Erlang was not asked to
  compile them. `shapes.erl` is the only output here that Erlang has compiled (in the BEAM
  post).
- A `case` with no clause at all: upstream subtracts from an indentation that was never added,
  which panics in a debug build and wraps around in a release build. No Gleam program produces
  one, the fuzzer does not generate one, and the port does not imitate either behaviour.
- Two `unit` specifiers on one bit array segment: upstream sorts with a comparison that is not
  an order in that case. A segment has one at most. The port puts units last, in order.
- One internal error, `escaping string`, cannot be reached through the public calls (an
  earlier check always fires first), so its message was compared by reading only.
""", nkWarning, "What was not checked")

nbText: fmt"""
## How the Rust became Nim

The file is unusual: of its {thousands(rustLines)} lines, {thousands(rustComments)} are
comments, most of them the documentation of the interface with a small Erlang example for
each call. They came along (rule 5 of the porting guide), copied by a script so that none was
retyped.
"""

nbNote("""
**No trait.** `ErlangBuilder` has two implementations. The porting guide says that a trait
with one or two implementations becomes plain procs with the same names, so there is no
interface type in the Nim: the binary builder will have procs with the same names, and the
code generator will be generic (`proc generate[B](builder: var B)`). The trait's
documentation lives on the procs of the text builder.

**Tokens.** `start_tuple` returns a value that `end_tuple` takes, so that the binary builder
can remember where the tuple began. For the text builder that value is `()`, here `Unit`. It
is kept, so the same calling code will compile for both builders.

**One shape for enums.** The positions are a Rust enum with 26 variants, some holding other
enums with data. My first version was one flat object with every field. While I worked, the
syntax tree step merged [decision 0010](../../decisions/): an enum with data is an object with
a `kind` and one field `vVariant` per variant. The module was rewritten to that shape, a
change to almost every line of its logic, and the 50,000 scripts were identical again on the
first run.

**One name changed.** The call for a string literal is `string` upstream. In Nim that is the
type, so it is `stringExpression`.
""", nkNim, "Four choices")

nbText: """
## What this changes for the port

1. **The Erlang code generator has something to write to.** Roadmap step `erlang-builder` is
   done; `erlang-expressions` can start as soon as there is a typed tree.
2. **The oracle is ready for the second builder.** `reference/erldump` is already generic over
   the builder: the next step, the binary one, adds a mode, and the same scripts then check it
   twice: against Rust byte for byte, and against the text builder by asking Erlang whether the
   two outputs are the same program.
3. **Floats: never `$`.** Anything the compiler prints from an `f64` goes through
   `formatFloat`. The JavaScript backend will need it too; the function moves to a module of
   its own when a second user appears. It is in the porting guide.
4. **A pattern for files without tests**: link the real crate, replay scripts, fuzz the
   scripts, keep some as golden files for CI. The lexer and the pretty printer did the same in
   their own way; this is the third time, so it is now simply how a leaf of the port is checked.
5. **Reshaping is cheap when an oracle watches.** Conventions will keep moving while several
   threads port in parallel. A module that can be compared with the reference in a minute can
   follow them without fear.

## Sources

- `erlang-generation/src/lib.rs` in Gleam at the pin, v1.19.2, written by the Gleam
  contributors: every comment in the ported module is theirs.
- [The Abstract Format](https://www.erlang.org/doc/apps/erts/absform.html), Erlang
  documentation: why the calls look the way they do (cons cells, clauses).
- Robert G. Burger and R. Kent Dybvig,
  [Printing Floating-Point Numbers Quickly and Accurately](https://doi.org/10.1145/231379.231397),
  PLDI 1996: the algorithm of `shortestDigits`. I wrote it from memory of the paper and
  checked it against Rust, not against the paper, which this sandbox could not fetch.
- In this repository: `src/gleam_in_nim/erlang_generation.nim`,
  `tests/test_erlang_generation.nim`, `reference/erldump/`, `tools/erldump.nim`,
  `tools/erlfuzz.nim`, `tools/erlcheck.sh`, and
  `docs/devlog/data/the_erlang_builder/regenerate.sh` for the numbers of this page.
"""

nbSave
