## devlog: 12 Nov 2026 E | How the Gleam compiler is made | A tour of the 135,000 lines we are about to port: what each part does, how big it is, and how it got that way.
## kind: research
import std/[json, os, strformat, strutils]
import nimib
import ../blocks

nbInit
nb.usePost()

const dataDir = currentSourcePath.parentDir / "data" / "how_gleam_compiles"
let
  history = parseJson(readFile(dataDir / "history.json"))
  coverage = parseJson(readFile(currentSourcePath.parentDir.parentDir / "data" / "coverage.json"))

proc thousands(n: int): string = insertSep($n, ',')

proc total(field: string, areas: varargs[string]): int =
  ## Sum a numeric field of the coverage map, optionally for some areas only.
  for component in coverage["components"]:
    if areas.len == 0 or component["area"].getStr in areas:
      result += component[field].getInt

nbText: fmt"""
## The short version

- We port **Gleam v1.19.2** (commit `ed41eace`, 12 October 2026). That snapshot is
  {thousands(total("rust_loc"))} lines of Rust, plus {thousands(total("rust_test_loc"))} lines of
  tests and {thousands(total("snapshots"))} snapshot files. The tests are a gift: they are the
  specification we will be held to.
- The compiler is a classic pipeline with very few surprises: **lexer, parser, type checker, code
  generator, pretty printer**. No intermediate representation, no optimiser, no linker. It turns a
  typed syntax tree straight into Erlang or JavaScript *source code*.
- The compiler proper (front end, analysis and both backends, with their foundations) is about
  {thousands(total("rust_loc", "foundations", "frontend", "analysis", "backend"))} lines. The rest is
  a build tool, a package manager client and a language server.
- The hard parts are not where a compilers course says they are. Parsing is small. The weight is in
  **type inference with good error messages** and in **pattern matching**.
- It was not always like this: it started in Erlang in 2016, restarted in Rust in 2018, and has
  doubled in size since 1.0.

## Compilers, in one page

A compiler is a program that reads a program and writes a program. Almost all of them do it as a
relay race, where each runner hands a richer data structure to the next:

| Stage | Takes | Gives | Catches |
|---|---|---|---|
| Lexer | characters | tokens (`pub`, `fn`, a name, `(`...) | a stray `$`, an unterminated string |
| Parser | tokens | a syntax tree | a missing bracket |
| Analysis | syntax tree | the same tree with meaning: names resolved, types attached | `1 + "a"`, unknown variables |
| Lowering and optimisation | typed tree | one or more simpler intermediate representations | (makes it fast) |
| Code generation | the last representation | machine code, bytecode, or source in another language | |

The front (lexer, parser, analysis) is where a language's personality lives. The back is where the
engineering budget usually goes: rustc has several intermediate representations and hands the last
one to LLVM; Go builds an SSA form and emits machine code itself; Nim lowers to C and lets a C
compiler finish the job.

Gleam makes a different trade. It **skips the entire middle**, because its targets are not machines
but two mature virtual machines with their own compilers: the BEAM (through Erlang) and JavaScript
engines. Gleam's job ends at writing readable Erlang and readable JavaScript. This is the single
most important fact for our port: we never have to generate machine code, allocate registers or
write an optimiser. We have to produce *text*, and text is easy to compare.

## One function, all the way through

Here is a small module:
"""

nbText: "```gleam\n" & readFile(dataDir / "demo" / "shapes.gleam") & "```"

nbText: """
The **lexer** turns it into a few dozen tokens, each with a start and end offset. The **parser**
builds a module with two definitions: a custom type with two constructors, and a function whose
body is one `case` expression. At this point nothing knows that `radius` is a `Float`.

The **analyser** registers the type `Shape` and its constructors, then infers the function: `shape`
is a `Shape` because the annotation says so, each pattern is checked against `Shape`, `radius`
becomes a `Float`, `*.` wants two floats and gives one. It also compiles the `case` into a
*decision tree* to prove that no shape is forgotten. Remove the `Rectangle` clause and this is the
stage that tells you.

Then the two backends write it out. This is the real output of the pinned compiler. Erlang first:
"""

nbText: "```erlang\n" & readFile(dataDir / "demo" / "shapes.erl") & "```"

nbText: """
And JavaScript (the function only, the two classes for the constructors are left out):
"""

nbText: "```javascript\n" & readFile(dataDir / "demo" / "shapes.mjs").split("\n\n")[^1] & "```"

nbText: """
Look at the two `case` translations, because they show a real design decision. Erlang has pattern
matching, so the Erlang backend keeps the `case` as it is and lets the Erlang compiler optimise it.
JavaScript has none, so the JavaScript backend takes the decision tree that the analyser already
built for exhaustiveness checking and prints it as `if` and `else`. Same input, same analysis, two
very different amounts of work.

## The map

Upstream draws its own pipeline in `docs/compiler/README.md`; this is that picture with the module
names and sizes of the pin. Lines are Rust source without tests.
"""

proc componentTable(areas: varargs[string]): string =
  result = "| Component | Rust lines | Test lines | Snapshots | Notes |\n|---|---:|---:|---:|---|\n"
  for component in coverage["components"]:
    if component["area"].getStr in areas:
      result.add "| " & component["title"].getStr & " | " &
        thousands(component["rust_loc"].getInt) & " | " &
        thousands(component["rust_test_loc"].getInt) & " | " &
        thousands(component["snapshots"].getInt) & " | " &
        component["notes"].getStr & " |\n"

nbText: "### Front end: text to tree\n\n" & componentTable("frontend") & """

The lexer and the parser are both written by hand. The parser is recursive descent, with one
exception that its header comment explains well: binary operators use a small precedence stack
machine, the same one for expressions, clause guards, constants and bit array sizes. Comments are
not in the tree. The lexer collects them in a side table (`ModuleExtra`) and the formatter weaves
them back in by position. That side table is why `gleam format` can exist without a second parser.

The syntax tree is the largest thing in the front end, and it comes in two flavours that share one
set of generic definitions: `UntypedExpr` straight out of the parser, and `TypedExpr` after
analysis, where every node carries its type.
"""

nbText: "### Analysis: tree to typed tree\n\n" & componentTable("analysis") & """

This is the heart, and it is where most of our effort will go.

**Inference** is Hindley-Milner in the mutable style: a type is `Named`, `Fn`, `Tuple` or `Var`,
and a `Var` is a shared cell that is `Unbound`, a `Link` to another type, or `Generic`. Unifying
two types means walking both and turning unbound cells into links. There is no `let`
polymorphism: only top level functions and constants are generalised, after their whole group has
been inferred. That keeps the algorithm simple, and it is why the analyser needs a **call graph**:
it sorts functions into dependency order and infers mutually recursive ones together.

**Module analysis** goes in a fixed order that the port will follow line by line: imports, then
type names, then type aliases, then function signatures, and only then bodies. This is what lets
you use a type or a function before its definition.

**Exhaustiveness** is a decision tree compiler after Jules Jacobs and Luc Maranget (the source
credits both papers and Yorick Peterse's implementation). It is five thousand lines because of bit
arrays: matching `<<size:8, rest:bytes-size(size)>>` means reasoning about offsets and overlaps.

**Fault tolerance** runs through all of it. Since 2024 the analyser does not stop at the first
error: it records the problem, puts an `Invalid` node in the tree and continues. A module can come
out as `PartialFailure`: a usable typed tree *and* a list of errors. The language server lives on
this, and so do the snapshot tests, which often expect several errors from one input.
"""

nbText: "### Back end: typed tree to text\n\n" & componentTable("backend") & """

Two backends, two styles. The JavaScript backend builds a **document** (text plus places where a
line may break) and lets the pretty printer lay it out in 80 columns. It is the same pretty printer
the formatter uses, an implementation of Christian Lindig's *Strictly Pretty* with ideas from
Elixir and Prettier.

The Erlang backend used to work the same way. In mid 2026 it was rebuilt around a **builder
interface**: the generator says "start a function, start a case, here is a clause" and a builder
turns those calls into output. There are two builders. One writes Erlang source text. The other
writes **Erlang abstract format**, the binary form of Erlang's own syntax tree, which `gleam build`
now hands straight to the Erlang compiler without printing and reparsing text. For us this is good
news twice: the text builder needs no pretty printer, and the binary builder can wait.
"""

nbText: "### Around the compiler\n\n" & componentTable("foundations", "build", "tooling") & """

Three things here are worth knowing before we meet them.

The core is **pure**. `compiler-core` does no IO: it talks to traits like `FileSystemReader`, and
the tests run whole builds against an in-memory file system. We keep that design, it is what makes
the compiler testable (and runnable in a browser).

**Error messages are a component**, not an afterthought: over nine thousand lines, most of it
prose. Gleam's friendliness is written down in `error.rs`, one carefully worded paragraph at a
time, and 1,233 snapshots pin the exact wording.

The **language server** is the single biggest crate. It is not a separate analyser: it runs the
real compiler and walks the typed tree. That is why it comes last in our plan, and why the compiler
must stay fault tolerant.

## How it got here
"""

block:
  var timeline = "| When | What happened |\n|---|---|\n"
  for event in history["events"]:
    timeline.add "| " & event["date"].getStr & " | " & event["what"].getStr & " |\n"
  nbText: timeline

nbText: fmt"""
The dates come from the repository itself: {thousands(history["commits_at_pin"].getInt)} commits
by {history["contributors_at_pin"].getInt} authors. Louis Pilfold wrote almost half of them;
Giacomo Cavalieri and Surya Rose (GearsDatapacks) are the next two, and their names are on most of
the 2025 and 2026 restructuring.

And this is the growth, release by release:
"""

block:
  var sizes = "| Release | Date | Rust lines | of which tests | Snapshot files |\n|---|---|---:|---:|---:|\n"
  for size in history["sizes"]:
    sizes.add "| " & size["tag"].getStr & " | " & size["date"].getStr & " | " &
      thousands(size["rust_lines"].getInt) & " | " & thousands(size["test_lines"].getInt) & " | " &
      thousands(size["snapshots"].getInt) & " |\n"
  nbText: sizes

nbText: """
Three things in this history explain decisions we will meet in the code.

**The parser was generated, then rewritten by hand.** Early Gleam used LALRPOP, a parser generator.
It was replaced in December 2020 by the hand written parser we are porting. The usual reason
applies: a generated parser is quick to start with and poor at saying *what you probably meant*.
Many of Gleam's parse errors are hints for people arriving from other languages, and those need a
parser you can reach into.

**Tests moved from assertions to snapshots.** Between v0.16 and v0.20 the project adopted `insta`.
A snapshot test contains only an input; the output is recorded in a file and reviewed when it
changes. The count went from zero to more than four thousand, and the files contain both the input
and the expected output. We can read them without running any Rust.

**The compiler doubled after 1.0.** Not from new syntax (the language is deliberately small and
stable) but from tooling: the language server and its code actions, fault tolerance, better
errors, decision tree code generation. The lesson for a port: the language is the small part.

## Gleam next to other compilers

| | Written in | Parser | Types | Middle | Emits |
|---|---|---|---|---|---|
| **Gleam** | Rust | hand written | Hindley-Milner, no type classes | none | Erlang or JavaScript source |
| Elm | Haskell | hand written combinators | Hindley-Milner, a few built in constraints | optimisation on a small IR | JavaScript |
| Erlang (erlc) | Erlang | generated (yecc) | dynamic; Dialyzer is separate | Core Erlang, then several BEAM passes | BEAM bytecode |
| Elixir | Elixir and Erlang | generated (yecc) | gradual set theoretic types, arriving | macro expansion to Erlang abstract format | BEAM bytecode via erlc |
| TypeScript | TypeScript, now Go | hand written | structural, flow sensitive | none: types are erased | JavaScript |
| Go | Go | hand written | nominal and structural | SSA | machine code |
| Rust | Rust | hand written | traits, lifetimes | HIR, THIR, MIR, then LLVM | machine code |
| Nim | Nim | hand written | static, generics, macros | transformations on the AST | C, C++ or JavaScript source |

Gleam's nearest relatives are Elm (the type system and the care for error messages) and Elixir
(reaching the BEAM by producing Erlang's own syntax tree, which Gleam started doing this year).
Its nearest relative in *shape* is, pleasingly, Nim: a typed tree walked by backends that print
source code for another compiler to finish. We are porting a source-to-source compiler into a
language whose own compiler is one.

Like nearly every production compiler in the table, Gleam's parser is hand written. And like
TypeScript, it has a famous rewrite in its family tree: its own, from Erlang to Rust.

## What this changes for the port

- **Text out means text to compare.** Every stage has an oracle we can run without Erlang: the
  formatter for the parser, the package interface for the type checker, `.erl` and `.mjs` files for
  the backends. The plan is built around byte for byte comparison with the pinned binary.
- **Order follows the pipeline, with one detour.** The formatter comes right after the parser,
  because it is the best test a parser can have.
- **Erlang text first.** It is the default target, it needs neither the decision tree printer nor
  the pretty printer, and it is the smaller backend. JavaScript second, binary Erlang third.
- **Budget for the unglamorous parts.** Error messages, warnings and the build tool are about as
  much code as the parser and both backends together.
- **Keep the purity and the fault tolerance.** They look like extras; the tests and the language
  server depend on both.

The next post turns this into a plan.

## Sources

- The Gleam compiler at the pin: [gleam-lang/gleam v1.19.2](https://github.com/gleam-lang/gleam/tree/v1.19.2),
  in particular `docs/compiler/README.md`, `compiler-core/src/parse.rs`, `analyse.rs`,
  `exhaustiveness.rs`, `codegen.rs`, and the crates `pretty-arena` and `erlang-generation`.
- Jules Jacobs, [How to compile pattern matching](https://julesjacobs.com/notes/patternmatching/patternmatching.pdf).
- Luc Maranget, [Compiling pattern matching to good decision trees](https://www.cs.tufts.edu/~nr/cs257/archive/luc-maranget/jun08.pdf).
- Christian Lindig, *Strictly Pretty* (2000).
- [The Erlang abstract format](https://www.erlang.org/doc/apps/erts/absform.html).
- [insta](https://insta.rs), the snapshot testing tool upstream uses.
- Sizes and dates: measured with `git` and `tools/coverage_measure.nim`; the data is in
  `docs/data/coverage.json` and `docs/devlog/data/how_gleam_compiles/history.json`.
"""

nbSave
