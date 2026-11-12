## devlog: 12 Nov 2026 R | The syntax tree | The shape every later stage reads: Gleam's untyped tree in Nim, generic like the original, and one rule for writing its Rust enums.
## kind: port
import std/[json, os, strformat, strutils]
import nimib
import ../blocks
import gleam_in_nim/ast
import gleam_in_nim/parse/extra

nbInit
nb.usePost()

const docsDir = currentSourcePath.parentDir.parentDir
let portmap = parseJson(readFile(docsDir / "data" / "portmap.json"))

proc thousands(n: int): string = insertSep($n, ',')

proc rustLines(path: string): int =
  for file in portmap["files"]:
    if file["path"].getStr == path: return file["lines"].getInt
  doAssert false, path

proc nimLines(path: string): int =
  readFile(docsDir.parentDir / "src" / "gleam_in_nim" / path).countLines

func count(T: typedesc[enum]): int = ord(high(T)) + 1

let
  rustTree = rustLines("compiler-core/src/ast.rs") + rustLines("compiler-core/src/ast/untyped.rs") +
    rustLines("compiler-core/src/ast/constant.rs")
  nimTree = nimLines("ast.nim") + nimLines("ast/untyped.nim") + nimLines("ast/constant.nim")
  searchCases = readFile(docsDir.parentDir / "tests" / "data" / "parse_extra" / "binary_search.txt").strip.countLines

nbText: fmt"""
## The short version

- **What**: the data types of Gleam's syntax tree, as the parser builds it, are now in Nim:
  `ast.nim`, `ast/untyped.nim`, `ast/constant.nim`. Upstream's three files are
  {thousands(rustTree)} lines, ours {thousands(nimTree)}: the difference is the typed half,
  which waits for the type checker. With them come the rest of `src_span.nim` (line numbers)
  and `parse/extra.nim` (where the comments are).
- **How big is a tree**: {count(UntypedExprKind)} kinds of expression, {count(PatternKind)} of
  pattern, {count(ConstantKind)} of constant, {count(StatementKind)} of statement,
  {count(DefinitionKind)} of definition, {count(BinOp)} binary operators.
- **Two choices**, recorded as
  [decision 0010](../../decisions/#0010-the-syntax-tree-is-generic-like-upstream-s-and-every-enum-with-data-has-one-shape):
  the tree is generic, exactly like upstream's, and every Rust enum with data is written in
  Nim in one fixed shape.
- **Checked how**: upstream's tests for these files pass (there are few), a binary search was
  compared with Rust's on {thousands(searchCases)} random inputs, and tests of ours build a tree
  by hand and call every function. **Not checked yet**: that a real parser's output fits, byte
  for byte. That needs the parser, which is the next step, in another thread. The files are
  `draft`.
"""

nbText: """
## What a syntax tree is

The lexer turned text into words. The parser will turn words into a tree: a module holds
definitions, a function holds statements, a statement holds expressions, an expression holds
smaller expressions. This step is only the *shape* of that tree, the types, with no code that
builds one from text. Take this line:

```gleam
pub fn main() { 1 + x }
```

Upstream's parser makes of it, printed the way Rust prints a value (cut short here):

```rust
Function(
    Function {
        location: SrcSpan { start: 0, end: 13 },
        name: Some((SrcSpan { start: 7, end: 11 }, "main")),
        body: [
            Expression(
                BinOp {
                    location: SrcSpan { start: 16, end: 21 },
                    operator: AddInt,
                    left: Int { location: SrcSpan { start: 16, end: 17 }, value: "1", .. },
                    right: Var { location: SrcSpan { start: 20, end: 21 }, name: "x" },
                    ..
                },
            ),
        ],
        return_type: (),
        ..
    },
)
```

Every node knows where it came from: `location` is a pair of byte offsets into the source.
The formatter reads this tree to print the code again, the type checker reads it to give every
node a type, and the two backends read the typed result.
"""

nbNote("""
There is one tree in two states. `Function<T, Expr>`, `Pattern<Type>`, `Statement<TypeT,
ExpressionT>` are generic: the parser fills the type parameter with `()`, Rust's empty value
(that is the `return_type: ()` above), and the type checker builds the same shapes again with
real types. Only expressions are two separate enums, `UntypedExpr` and `TypedExpr`. So the
untyped tree already has the slots the type checker will fill, and they show in the 264
snapshots of upstream's parser tests.
""", nkGleam, "How the original does it")

nbText: """
## Generic, like the original

We kept that. A tree with optional types would have been shorter to write, but every later
file of the port (the formatter, the type checker, the backends) is read next to its Rust, and
there the types are `UntypedPattern` and `TypedPattern`. And the snapshots print `type_: ()`:
a tree of ours that had no such field could not be compared with them.
"""

nbCode:
  # The same generic type, in the state the parser builds: Unit is Rust's ().
  let discard1 = UntypedPattern(
    kind: paDiscard,
    vDiscard: PatternDiscard[Unit](name: "_", location: initSrcSpan(4, 5)),
  )
  echo discard1.vDiscard.typ is Unit, " ", discard1.location

nbText: """
## One shape for every enum

A Rust enum is a list of variants, and each variant can carry its own data. Almost every node
of the tree is one:

```rust
pub enum UntypedExpr {
    Int { location: SrcSpan, value: EcoString, int_value: BigInt },
    Var { location: SrcSpan, name: EcoString },
    List { location: SrcSpan, elements: Vec<Self>, tail: Option<Box<Self>> },
    // eighteen more
}
```

Nim's answer is an object with a `case`. But Nim does not allow the same field name in two
branches, and here every branch has a `location`, and `value` is a string in one variant and
an expression in another. Renaming fields one by one until nothing clashes would have worked,
and would have left some twenty enums each done a little differently. So there is one rule, for all
of them: the object has a `kind`, and one field per variant, named `v` and the variant. The
fields of the variant live in their own small object, in upstream's order, with upstream's
names.
"""

nbCode:
  let one = UntypedExpr(
    kind: ueInt,
    vInt: UntypedExprInt(location: initSrcSpan(16, 17), value: "1", intValue: initBigInt(1)),
  )
  let x = UntypedExpr(kind: ueVar, vVar: UntypedExprVar(location: initSrcSpan(20, 21), name: "x"))
  let sum = UntypedExpr(
    kind: ueBinOp,
    vBinOp: UntypedExprBinOp(
      location: initSrcSpan(16, 21), operator: boAddInt, operatorStart: 18,
      left: box(one), right: box(x),
    ),
  )

  # Reading it back is a `case`, the way Rust reads it with a `match`.
  func show(e: UntypedExpr): string =
    case e.kind
    of ueInt: e.vInt.value
    of ueVar: e.vVar.name
    of ueBinOp: "(" & show(e.vBinOp.left[]) & " " & e.vBinOp.operator.name & " " & show(e.vBinOp.right[]) & ")"
    else: "?"

  echo show(sum), " at ", sum.location, ", precedence ", sum.binOpPrecedence

nbNote("""
The price is one more step when reading a field: `e.vInt.value` where Rust destructures `Int {
value, .. }`. What it buys: no field was renamed to avoid a clash, the Nim can be checked
against the Rust field by field, and a single generic printer can write any tree the way Rust's
`{:#?}` does. The parser thread is writing that printer, and it is how the parser will be
checked against the reference. `Box<T>` is a `ref T` (`box(one)` above), the nodes themselves
are plain values. The four fields Nim cannot spell (`type_`, `return_`, `end`, `tuple`) are
`typ`, `returns`, `stop`, `tupl`, listed in one table in `ast.nim`.
""", nkNim, "How the port does it")

nbText: """
## Three files, one module

Upstream's `ast.rs` and its submodules use each other freely: `constant.rs` starts with `use
super::*`, and `ast.rs` hands its types back out. Nim modules cannot import each other in a
circle. So `ast.nim` *includes* `ast/constant.nim` and `ast/untyped.nim`, each at the point
where the types it needs exist. One file per upstream file, as the plan asks, and one `import
gleam_in_nim/ast` to get them all.

Two things the compiler taught us on the way. Types that mention each other must sit in one
`type` section, so in `ast.nim` the types come first and the functions after, each in upstream's
order. And an alias such as `UntypedPattern = Pattern[Unit]` written *inside* the section that
defines `Pattern` crashes Nim 2.2.4 (`internal error: no generic body`): the aliases moved to a
section of their own.

The tree also mentions types that belong to stages not ported yet: the target, deprecations,
the origin of a variable, and a few that only the type checker fills. Each got a small file at
its upstream path, marked as a part: real when small, an empty placeholder when the parser
never fills it.

## Lines and columns

`SrcSpan` came with the lexer. The rest of that upstream crate is `LineNumbers`: the table that
turns a byte offset into a line and a column for an error message, and into the UTF-16 column
that editors speak.
"""

nbCode:
  let source = "let a = \"क्षि\"\nlet b = 2\n"
  let lineNumbers = initLineNumbers(source)
  echo lineNumbers.lineStarts
  echo lineNumbers.lineAndUtf8ColumnNumber(source.find("b"))
  # After the Devanagari string: twelve bytes, four UTF-16 units.
  echo source.find("\"\n"), " ", lineNumbers.lineAndUtf16ColumnNumber(source.find("\"\n"))

nbText: """
## Where the comments are

A syntax tree has no comments in it. The parser sets them aside in `ModuleExtra`, with the
empty lines and the trailing commas, and the formatter puts them back by asking "is there a
comment between these two offsets?". That question is a binary search, and upstream's answer
depends on *which* matching comment Rust's `binary_search_by` happens to land on. So ours takes
the same steps, and a test replays a file of random cases produced by a small Rust program.
"""

nbCode:
  var moduleExtra = initModuleExtra()
  moduleExtra.comments = @[initSrcSpan(0, 10), initSrcSpan(20, 30), initSrcSpan(40, 50)]
  echo moduleExtra.firstCommentBetween(15, 45)
  echo moduleExtra.isWithinComment(35)

nbNote(fmt"""
- Upstream's tests for these files, all passing: the three `type_ast_print` tests of `ast.rs`,
  the three of `src-span`, the five of `parse/extra.rs`.
- Our binary search returns the index Rust's returns on {thousands(searchCases)} random lists
  of spans (`tests/data/parse_extra/`, made with rustc 1.97).
- `tests/test_ast.nim` builds expressions, patterns, guards, bit arrays, constants and a module
  by hand, which instantiates every generic type, and calls the functions on them.
- **Not verified**: `ast.rs` has a fourth test, `module_dependencies_test`, that needs the
  parser; ours builds its module by hand instead. No tree has been compared with the reference
  yet: that happens when the parser can produce one. Nobody has read the Nim against the Rust a
  second time, so the files are `draft`, not `verified`.
- Not ported on purpose: everything typed (`TypedExpr`, `find_node`, `visit.rs`), which is
  most of `ast.rs` by lines.
""", nkDone, "What was verified, and what was not")

nbText: """
## What this changes for the port

- The parser and the formatter have their types. Both threads were waiting on them and now
  build against the branch.
- The [porting guide](../../porting/) has the rule for enums, `Box`, `()` and `Vec1`, and its
  line on integers changed: byte offsets are `int`, not `uint32`.
- A problem is written down for the typed tree: upstream's `ast` and `type_` modules hold each
  other's types, and Nim will not import in a circle. The placeholders of this step mark the
  places.
- The diagnostics step was split while this one ran: the plan thread ported the renderer, and
  the parse error messages go with the parser.

## Sources

- `compiler-core/src/ast.rs`, `ast/untyped.rs`, `ast/constant.rs`, `parse/extra.rs` and
  `src-span/src/lib.rs` in
  [gleam-lang/gleam v1.19.2](https://github.com/gleam-lang/gleam/tree/v1.19.2/compiler-core/src).
- The snapshots of upstream's parser tests, in
  [compiler-core/src/parse/snapshots](https://github.com/gleam-lang/gleam/tree/v1.19.2/compiler-core/src/parse/snapshots).
- The [port plan](../the-port-plan/), the [lexer](../lexer/) that came before, and the
  [roadmap](../../roadmap/).
"""

nbSave
