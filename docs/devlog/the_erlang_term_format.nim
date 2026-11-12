## devlog: 12 Nov 2026 M | Speaking Erlang in bytes | The encoder under Gleam's binary Erlang output, ported and checked by Erlang itself. It found a number the reference compiler cannot write.
## kind: port
import std/[json, os, strformat, strutils, sequtils, options]
import nimib
import ../blocks
import pkg/bigints
import gleam_in_nim/erlang_term_format

nbInit
nb.usePost()

const here = currentSourcePath().parentDir
let results = parseJson(readFile(here / "data" / "the_erlang_term_format" / "roundtrip.json"))
let bigLiteral = readFile(here / "data" / "the_erlang_term_format" / "big_literal.out.txt").strip
let upstreamTests = results["upstream_tests"].getInt
let terms = results["terms"].getInt
let kilobytes = results["bytes"].getInt div 1000

nbText: fmt"""
## The short version

- Since version 1.19 `gleam build` hands Erlang a syntax tree as **bytes**, in Erlang's External
  Term Format ([The BEAM, explained](../the-beam/) has the story). The crate that writes those
  bytes, `erlang-term-format`, is 255 lines of Rust. It is now
  `src/gleam_in_nim/erlang_term_format.nim`.
- It needs big integers. They come from `bigints`, the one package the compiler may import
  (the lexer step chose it, [decision 0009](../../decisions/)). A first version of this step
  had a small module of its own; it is gone.
- Three checks, in growing order of trust: the {upstreamTests} upstream tests, replayed from the
  bytes written in the Rust file; the first form of a real `.abstr` file written by the
  reference compiler, reproduced byte for byte; and {terms} random terms ({kilobytes} kB of
  encodings) decoded by **real Erlang** to exactly the terms we meant.
- Reading the Rust a second time turned up something in Gleam itself: an integer literal longer
  than about 616 digits makes the reference compiler write a file that Erlang refuses to read.
  The port reproduces it, on purpose, and a test pins it.

## A format you can read with your fingers

The External Term Format is how Erlang turns any value into bytes, to send it to another
machine or to save it. Its design fits on a napkin: a version byte, `131`, then each value as a
**tag byte** that says what comes next, followed by the payload. Here is the atom `ok`, encoded
by the ported module as this page is built:
"""

nbCode:
  proc show(etf: TermBuilder): string = etf.intoVec.mapIt($it).join(" ")

  var ok = newTermBuilder()
  ok.atom("ok")
  echo show(ok)

nbText: """
`131` is the version, `119` is the tag for a short atom, `2` is its length, and `111 107` are the
letters `o` and `k`. A tuple is its tag, its size, and then its elements one after the other,
with no closing mark. So `{ok, 42}`:
"""

nbCode:
  var pair = newTermBuilder()
  pair.smallTuple(2)
  pair.atom("ok")
  pair.usize(42)
  echo show(pair)

nbText: """
These are all the tags the Gleam compiler ever writes:

| Tag | Name | Payload | Used for |
|---|---|---|---|
| 97 | SMALL_INTEGER_EXT | 1 byte | integers 0 to 255 |
| 98 | INTEGER_EXT | 4 bytes, big endian, signed | integers that fit 32 bits |
| 110 | SMALL_BIG_EXT | length (1 byte), sign, magnitude little endian | bigger integers |
| 111 | LARGE_BIG_EXT | length (4 bytes), sign, magnitude | integers past 255 bytes |
| 70 | NEW_FLOAT_EXT | 8 bytes, IEEE 754 | floats |
| 119 | SMALL_ATOM_UTF8_EXT | length (1 byte), UTF-8 | atoms up to 255 bytes |
| 118 | ATOM_UTF8_EXT | length (2 bytes), UTF-8 | longer atoms |
| 104 | SMALL_TUPLE_EXT | arity (1 byte), elements | tuples up to 255 |
| 105 | LARGE_TUPLE_EXT | arity (4 bytes), elements | bigger tuples |
| 108 | LIST_EXT | length (4 bytes), elements, tail | lists |
| 106 | NIL_EXT | nothing | the empty list, and the tail of a proper list |
| 109 | BINARY_EXT | length (4 bytes), bytes | binaries: Gleam strings |

Integers are where the care goes: the encoder picks the smallest form that fits.
"""

nbCode:
  for text in ["255", "256", "-1", "2147483648", "123123123123123123"]:
    var number = newTermBuilder()
    number.bigint(initBigInt(text))
    echo text.align(18), "  ", show(number)

nbText: """
### The one clever bit: lists of unknown length

A list starts with its length. But the code generator walks a function and emits its
statements as it goes: it does not know how many there will be until it is done. So `startList`
writes four zero bytes and remembers where, and `endList` goes back and fills them in.
"""

nbCode:
  var list = newTermBuilder()
  let ender = list.startList()
  echo "started: ", show(list)
  list.atom("a")
  list.atom("b")
  list.endList(ender, 2)
  echo "ended:   ", show(list)

nbNote("""
In Rust the value returned by `start_list` has a `Drop` implementation, compiled in debug
builds only, that panics if a list is started and never ended. Nim has destructors, but a
destructor must not raise, so that check is not ported. It changes no output, and the mistake
is loud anyway: the length stays zero and Erlang rejects the file.
""", nkNim, "One thing left out")

nbText: """
## Big integers: one package, one helper

A Gleam `Int` literal can have any number of digits, so upstream uses the crate `num-bigint`
everywhere an integer of the source is held. Nim's standard library has no such type. When
this step started I wrote a small module for it. Meanwhile the lexer step met the same need
and settled it with a decision record: the compiler imports
[nim-lang/bigints](https://github.com/nim-lang/bigints), and nothing else. Two modules for one
job is one too many, so mine was deleted and the encoder now uses the package.

The encoder asks three things of a big integer: does it fit a byte, does it fit 32 bits, and
what are the bytes of its magnitude. The package answers the first two (`toInt`). The third is
`to_bytes_le` in num-bigint and has no twin in `bigints`, so the ported module carries it as a
helper, with num-bigint's name and results:
"""

nbCode:
  let huge = initBigInt("1" & "0".repeat(30))
  let (sign, bytes) = huge.toBytesLe
  echo huge, ": ", sign, ", ", bytes.len, " bytes, least significant first"
  echo bytes.mapIt($it).join(" ")
  echo "fits 32 bits? ", toInt[int32](huge).isSome

nbText: fmt"""
## Checked by Erlang

The upstream tests have a charming method, described at their top: every expected array of
bytes was produced by Erlang's own `term_to_binary` and pasted into the Rust. So they are
already a comparison with the real thing, {upstreamTests} of them. The port does not retype
those arrays (two of them hold a number with 1,500 digits). A script extracted them into a
data file, each Nim test builds the same term as its Rust namesake, and when the reference
checkout is present the test also checks that the data file still matches the Rust.

Then two checks that upstream does not have.

**A real file.** The BEAM post kept `shapes.abstr`, written by the reference `gleam` for a
small module. It is a list of forms, and the first is `{{attribute, 0, module, shapes}}`. The
ported encoder, asked for the start of a list and that tuple, produces the same bytes the
file starts with.

**Erlang as the judge.** The test generates {terms} random terms (atoms with letters of one,
two and three bytes, integers from one digit to 700, floats, binaries, tuples up to 260 wide,
nested lists), encodes each with the ported module, and also writes each as Erlang source
text. A short escript gives Erlang both: it decodes our bytes with `binary_to_term`, parses the
source, and compares the two terms with `=:=`. Result on Erlang/OTP {results["otp"].getStr}:
**{results["mismatches"].getInt} mismatches in {terms} terms**. CI has no Erlang yet (it is a
step of the roadmap), so there this check is skipped and says so; the other two run everywhere.

## What the second reading found

The porting guide asks for a second pass over every ported file, reading the Nim against the
Rust. For 255 lines that takes minutes, and it found no difference between the two. It found
this instead, in both:

```rust
fn small_big(&mut self, number: BigInt) {{
    let (sign, bytes) = number.to_bytes_le();
    self.push(110);
    self.push(bytes.len() as u8);
```

`as u8` keeps the low byte of the length. A number with 291 bytes of magnitude gets the length
`35`. That is fine as long as callers send bigger numbers to `large_big`, and the function
`bigint`, "the most compact representation of the given big int", is the natural place to
choose. It does not: after trying one byte and 32 bits, everything else goes to `small_big`.
And `bigint` is what the binary code generator calls for every integer literal.

So I asked the reference compiler. A Gleam module with one function returning a literal of
`111…1`, compiled with Gleam 1.19.2 to abstract forms, then decoded with Erlang:
"""

nbText: "\n```text\n" & bigLiteral & "\n```\n"

nbText: """
255 bytes hold a little over 614 decimal digits. Below that, all is well. Above, `gleam build`
writes a file its own next step cannot load. Nobody writes 620 digit literals by hand, which is
surely why it went unnoticed, but generated code and cryptographic constants do get close.
"""

nbNote("""
The rule of this project is that the Rust is the specification, so the port keeps the
behaviour: `tests/test_erlang_term_format.nim` asserts that the length byte wraps, with a
comment saying that this is the test to change when upstream changes. It is not a divergence,
so it is not in the list of divergences.

Everything outside this repository is read only for the port, so nothing was reported
upstream. Pietro: this one looks worth a short issue to Gleam from a human. The script
`docs/devlog/data/the_erlang_term_format/big_literal.sh` reproduces it.
""", nkGleam, "Kept as it is, and a note for Pietro")

nbText: """
## What this changes for the port

1. **The binary Erlang backend has its floor.** `erlang-abstract-format`, the second builder of
   `erlang-generation`, writes through this module and nothing else.
2. **Erlang is an oracle for more than programs.** The escript pattern of this step (we write
   bytes and source, Erlang compares) works unchanged for whole `.abstr` files: decode ours,
   decode the reference's, compare terms, and on a difference print both as text.
3. **Big integers are `bigints` everywhere.** The `Int` token of the lexer and the encoder
   now share one type, so a literal travels from source to bytes without a conversion.
4. **For the porting guide:** a crate outside `compiler-core` becomes one module named after
   the crate; tests that call private functions import the module with `{.all.}`; expected
   data too long to retype is extracted to `tests/data/` and checked against the reference
   when it is there.
5. **A correction.** The two research posts of this thread said they read the compiler "at
   v1.19.2". The generated code and messages did come from the 1.19.2 binary, but the Rust
   source I read was the main branch of a month later. Checked now against the pinned
   commit: everything quoted holds except one line count in the Elm post (`type_/expression.rs`
   has 5,219 lines at the pin, not 5,385), fixed in this pull request. From here on this thread
   reads `reference/gleam` only.

## Sources

- [External Term Format](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html), Erlang documentation.
- `erlang-term-format/src/lib.rs` and `tests.rs`, and `erlang-generation/src/lib.rs` (the caller
  of `bigint`), in Gleam at the pin, v1.19.2.
- [num-bigint](https://docs.rs/num-bigint/), for `to_bytes_le`, and
  [nim-lang/bigints](https://github.com/nim-lang/bigints), the package used.
- In this repository: `src/gleam_in_nim/erlang_term_format.nim`,
  `tests/test_erlang_term_format.nim`, `tests/erlang_term_format_oracle.escript`.
"""

nbSave
