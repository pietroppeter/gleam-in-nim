## devlog: 12 Nov 2026 L | The pretty printer | The first ported file: a thousand lines of Nim that decide where every line of Gleam breaks, checked 450,000 times against the Rust.
## kind: port
import std/[json, os, strformat, strutils]
import nimib
import ../blocks
import gleam_in_nim/pretty

nbInit
nb.usePost()

const docsDir = currentSourcePath.parentDir.parentDir
let results = parseJson(readFile(docsDir / "devlog" / "data" / "the_pretty_printer" / "differential.json"))

proc thousands(n: int): string = insertSep($n, ',')

var documents = 0
for run in results["runs"]: documents += run["documents"].getInt
let
  widths = results["widths"].len
  printings = documents * widths
  nimLines = readFile(docsDir.parentDir / "src" / "gleam_in_nim" / "pretty.nim").countLines

nbText: fmt"""
## The short version

- **What**: `pretty-arena/src/lib.rs`, the pretty printer of the Gleam compiler, is now
  `src/gleam_in_nim/pretty.nim`. {thousands(results["rust_lines"].getInt)} lines of Rust,
  {thousands(nimLines)} lines of Nim. It is the first file of the port.
- **Who needs it**: the formatter (`gleam format`) and the JavaScript backend. Both build a
  *document* and ask the printer to lay it out in 80 columns.
- **Checked how**: upstream's own tests pass, and a differential test printed
  {thousands(documents)} random documents at {widths} widths with the Nim and with the Rust
  crate itself: **{thousands(printings)} printings, 0 differences**.
- **Surprises**: the pinned snapshot has no tests for this file (we found them in the history);
  some of upstream's constants declare the wrong width, and we keep them wrong; and counting
  "characters" needed a small Unicode module of our own.

## What a pretty printer does

A formatter does not decide line breaks one at a time. It describes the *shape* of the code, and
a small engine picks the breaks. The description is a document: text, places where a line *may*
break, groups that break all together or not at all, and nesting that says how far to indent
after a break. The idea comes from Philip Wadler's "A prettier printer", made strict (and
simpler) by Christian Lindig in "Strictly Pretty". Gleam's version follows Lindig, with
extensions it credits to Elixir's `Inspect.Algebra` and to Prettier.

Here is the port at work. The same document, printed in 80 columns and in 20:
"""

nbCode:
  let arguments = join(["one".toDoc, "two".toDoc, "[3, 4, 5]".toDoc], breakDoc(",", ", "))
  let call = docvec(
    "wibble(",
    docvec(breakDoc("", ""), arguments).nest(2),
    breakDoc(",", ""),
    ")",
  ).group
  echo call.toPrettyString(80)
  echo call.toPrettyString(20)

nbText: """
A break carries two strings: what to print if it breaks (before the new line) and what to print
if it does not. That is how the trailing comma appears only in the broken form. The group is the
unit of decision: if all of it fits in what is left of the line, none of its breaks is taken;
otherwise all of them are.

"All or nothing" is too rigid for some shapes, so upstream adds a few more words to the language:
"""

nbCode:
  let words = ["Hello", "pretty", "printed", "world", "of", "documents"]
  var strict, flex: seq[Document]
  for word in words:
    strict.add word.toDoc
    flex.add word.toDoc
  echo join(strict, breakDoc("", " ")).group.toPrettyString(24)
  echo "---"
  echo join(flex, flexBreak("", " ")).group.toPrettyString(24)

nbText: """
| Document | Meaning |
|---|---|
| `Str`, `ZeroWidthStr` | text; the second takes no room when fitting (used for what is not seen) |
| `Line` | a new line, always |
| `Break` strict | a new line if its group is broken |
| `Break` flex | decided one by one: break only when the next piece does not fit |
| `Group` | try everything on one line, else break |
| `Nest` | indent what follows a new line; can be conditional (`nest_if_broken`) or absolute (`set_nesting`) |
| `ForceBroken` | this group breaks, even if it would fit |
| `NextBreakFits` | lets the last argument of a call "hug" the parenthesis: `f(a, [` ... `])` |
| `CursorPositionObserver` | prints nothing, reports the line and column it ended up at |

The engine is two functions. `fits` asks "does the rest of this line fit in the room left?" and
`format` walks the document, calling `fits` each time it meets a group or a flex break. Both keep
a stack of what is left to print, each entry with its indentation and its mode (broken or not).
"""

nbNote("""
Upstream keeps every document in an *arena*: one big vector, and a document is an index into it.
That is a Rust answer to a Rust problem (ownership of a tree that is shared and never freed one
node at a time). Nim has a garbage collected `ref`, so a `Document` here is a `ref object` and
there is no arena to pass around: `"a".toDoc.append("b")`, not `"a".to_doc(arena).append(arena,
"b")`. The functions, their names and their order are upstream's.

The stack is the second difference. `fits` must look ahead without disturbing the stack of
`format`. Upstream uses a persistent vector (`imbl::Vector`), cheap to clone. The port uses an
immutable linked list of frames: "cloning" is copying one pointer.
""", nkNim, "No arena, and a linked list for the stack")

nbText: """
## The tests that were not there

Upstream moved the pretty printer to its own crate shortly before the pin, and its unit tests did
not move with it: at v1.19.2 the printer is tested only through the formatter and the JavaScript
backend, which we do not have yet. The tests exist in the history, though. The last commit that
has `compiler-core/src/pretty/tests.rs` is `bc1d344c3` (9 June 2026), and `tests/test_pretty.nim`
is a port of that file, with the examples from upstream's doc comments added.

That is a rule worth keeping for the rest of the port: **when the pin has no test for a file,
look in the history before writing one.**

## Wrong widths, kept wrong

To avoid measuring the same strings again and again, upstream declares some 270 constant
documents with their width written by hand. A few are off:
"""

nbCode:
  for (name, document) in {"const ": constSpaceDocument, "if ": ifSpaceDocument}:
    echo "\"", name, "\" has ", name.len, " characters and declares ", document.graphemes

nbText: """
A formatter that believes `"const "` is five columns wide will, once in a while, let a line run
to 81. That is a bug, and it is *the reference's* bug: our rule is to print what Gleam prints, so
the port keeps every declared width as it is. The constants were generated from the Rust by a
script, not typed, precisely so that no one would be tempted to fix them.
"""

nbNote("""
Not reported upstream: Gleam does not accept contributions written with AI, and this project
does not open issues or pull requests there. It is noted here for the day the pin moves.
""", nkInfo, "A note on etiquette")

nbText: fmt"""
## What is a character?

The printer measures text in *grapheme clusters*: what a person would call a character. An `é`
written as `e` plus a combining accent is two code points and one grapheme; a family emoji is
seven code points and one grapheme. Upstream gets this from the Rust crate `unicode-segmentation`.
Nim's standard library stops at code points, and `src/` may use only the standard library, so the
port has a small module of its own, `graphemes.nim`: the rules of Unicode Annex 29 in one pass,
with tables generated from version {results["unicode_segmentation"].getStr} of that same crate
(Unicode {results["unicode"].getStr}), the one in upstream's lock file. It passes the
{results["grapheme_cases"].getInt} cases of the Unicode test file.
"""

nbCode:
  import gleam_in_nim/graphemes
  for text in ["abc", "é", "👩‍👩‍👧‍👦", "🇮🇹🇮🇹"]:
    echo text, ": ", text.len, " bytes, ", graphemesCount(text), " graphemes"

nbText: """
One more oddity kept: the text of a *break* is measured in bytes, not graphemes. Upstream does
that, so a string and a break with the same accented text can fit differently. There is a test
for it.

## The differential test

Unit tests check the cases someone thought of. For a file this central we wanted more, and the
sandbox has `cargo`, so the oracle can be the Rust crate itself:

1. `tests/differential/pretty/driver.nim` generates random documents from a seed, in a tiny
   prefix language (one letter per constructor).
2. A small Rust program, built against `pretty-arena` at the pin, reads the same
   descriptions.
3. Both print every document at every width, with `is_empty` and the positions seen by the
   cursor observers. The two outputs must be the same file.
"""

block:
  var table = "| Seed | Documents | Widths | Printings | Differences |\n|---:|---:|---:|---:|---:|\n"
  for run in results["runs"]:
    let n = run["documents"].getInt
    table.add "| " & $run["seed"].getInt & " | " & thousands(n) & " | " & $widths & " | " &
      thousands(n * widths) & " | " & $run["differences"].getInt & " |\n"
  table.add "| **all** | **" & thousands(documents) & "** | | **" & thousands(printings) & "** | **0** |\n"
  nbText: table

nbNote(fmt"""
- Upstream's seven unit tests (from the history) and the examples of its doc comments pass.
- {thousands(printings)} printings are byte identical to the Rust crate at the pin.
- The grapheme counter passes the {results["grapheme_cases"].getInt} cases of Unicode's own test file.

Not checked: speed (no measurement yet), and `to_doc` for floats, which is not ported: it needs
Rust's shortest round trip float printing, and that comes with the first file that uses it.
The differential test needs `cargo` and the reference checkout, so it is run by hand
(`sh tests/differential/pretty/run.sh SEED COUNT`), not on every commit.
""", nkDone, "What was verified")

nbText: """
## What this changes for the port

- The first row of the [coverage map](../../coverage/) is done, and the port map counts its
  first conformant file.
- The formatter can start as soon as the syntax tree and the parser exist: it is the next step
  of this thread, and it leads to milestone M1 (format parity).
- Two habits for later steps: **look in the history for tests the pin dropped**, and **use the
  Rust crate as the oracle** when a component can be driven alone. The Erlang builder and the
  term format are candidates.
- The porting guide gains two names: `break_` is `breakDoc` and `nil` is `emptyDocument`.

## Sources

- `pretty-arena/src/lib.rs` in [gleam-lang/gleam v1.19.2](https://github.com/gleam-lang/gleam/blob/v1.19.2/pretty-arena/src/lib.rs).
- Christian Lindig, [Strictly Pretty](https://lindig.github.io/papers/strictly-pretty-2000.pdf) (2000).
  The paper was not read again for this step: the port follows the Rust, which cites it.
- Philip Wadler, [A prettier printer](https://homepages.inf.ed.ac.uk/wadler/papers/prettier/prettier.pdf) (1998).
- [Unicode Standard Annex 29](https://www.unicode.org/reports/tr29/), Unicode Text Segmentation, and the
  [unicode-segmentation](https://github.com/unicode-rs/unicode-segmentation) crate (MIT or Apache-2.0),
  whose tables ours are generated from.
- The [port plan](../the-port-plan/) and the [roadmap](../../roadmap/).
"""

nbSave
