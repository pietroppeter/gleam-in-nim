## The porting guide, docs/porting/index.html: how Rust from the Gleam compiler is written in
## Nim here. Every port step reads it first and adds to it what it learned. Kept up to date.
import nimib
import blocks

nbInit
nb.doc.filename = docsDir / "porting" / "index.html"
nb.usePage(section = "Porting guide", cadence = "kept up to date", title = "Porting guide · gleam in nim",
           homeHref = "../", description = "How the Rust of the Gleam compiler is translated to Nim: ground rules, the idiom map, and the traps.")

nbTitle "Porting guide · kept up to date", "The porting guide", """
How a Rust file of the Gleam compiler becomes a Nim file here. Read it whole before porting
anything: the port is done by many sessions, and it only stays one program if they all translate
the same thing the same way. When a step finds a rule missing or wrong, it changes this page in
the same pull request.
"""

nbToc

nbText: """
## Ground rules

1. **Translate, do not improve.** Same types, same functions, same fields in the same order, same
   control flow, same order of side effects ([decision 0002](../decisions/#0002-this-is-a-port-not-a-rewrite)).
   If the Rust does something odd, the Nim does the same odd thing, with a comment if it helps.
2. **One Rust file, one Nim file.** `compiler-core/src/parse/lexer.rs` is
   `src/gleam_in_nim/parse/lexer.nim`. The tests of a file are ported with it, under `tests/`.
   A crate outside `compiler-core` is one module named after the crate
   (`erlang-term-format/src/lib.rs` is `src/gleam_in_nim/erlang_term_format.nim`). A test that
   calls functions upstream keeps private imports the module with `{.all.}`, so the module
   exports only what upstream makes `pub`. Expected data too long to retype (arrays of bytes)
   is extracted by a script into `tests/data/`, and the test compares it with the reference
   checkout when there is one.
3. **Say what you ported.** The file starts with its origin and its state. The port map and the
   licence notice both read these two lines:

   ```nim
   ## port-of: compiler-core/src/parse/lexer.rs
   ## port-status: draft
   ```

4. **Names.** Types keep their name. Functions, fields and variables go from `snake_case` to
   `camelCase`. Enum values get the short prefix Nim style asks for when they would clash. A name
   that is a Nim keyword, or that ends with an underscore (not allowed in Nim), takes the nearest
   plain word, listed in the table of names below so that everyone picks the same.
5. **Comments come along.** Doc comments (`///`) become `##`, ordinary ones stay where they were.
   They are part of the program we are porting.
6. **Only the standard library** in `src/`. A Rust crate is replaced by the standard library or
   by a small module of ours that is itself a port, never by a new dependency without a decision
   record.
7. **Three states.** `draft` when translated, `verified` when a second pass with fresh eyes has
   read it against the Rust, `conformant` when the upstream tests pass on it
   ([decision 0005](../decisions/#0005-every-file-goes-through-translate-verify-conform)).

## The idiom map

| Rust | Nim |
| --- | --- |
| `struct S { a: T }` | `type S = object` with `a: T`. *A value, copied on assignment, like a Rust struct that is `Clone`* |
| `Arc<T>`, `Rc<T>`, `Box<T>` | `ref`. *A type that upstream always holds behind a pointer is a `ref object`* |
| `enum E { A, B }` | `enum` |
| `enum E { A { x: T }, B(U) }` | object variant with a `kind`. *The kind enum is named `EKind`; tuple fields get the names upstream uses when it destructures them* |
| `match e { ... }` | `case e.kind`. *Never `else` on a kind: a new variant must fail to compile, as in Rust* |
| `match` with guards or nested patterns | `case`, then `if` inside the branch. *Keep the order of the arms* |
| `Option<T>` | `Option[T]` from `std/options`. *Also for refs: do not use `nil` for "none"* |
| `Result<T, E>` and `?` | see *Errors* below |
| `String`, `&str`, `EcoString` | `string`. *Both are UTF-8 bytes, so every offset agrees* |
| `char` | `Rune`. *A Nim `char` is a byte* |
| `Vec<T>`, `&[T]` | `seq[T]`, `openArray[T]` |
| `Vec1<T>` | `seq[T]`. *With a `doAssert` where upstream builds it* |
| `HashMap<K, V>`, `HashSet<K>` | `Table[K, V]`, `HashSet[K]`. *Never let their order reach the output: see the traps* |
| `im::HashMap` (persistent) | `Table`. *A Nim table is a value: assigning it copies, which gives the same meaning; speed comes later* |
| `u32`, `usize`, `i64` | `uint32`, `int`, `int64`. *Spans stay `uint32`* |
| `BigInt` | `BigInt` of `gleam_in_nim/bigint`, a small module of ours. *It has the `num-bigint` operations met so far, under the same names in camelCase; add the next one there, with tests, when a file needs it* |
| `x.clone()` | `x`. *For a ref, sharing is what `Arc::clone` did; for a value, Nim copies* |
| `&mut self` method | `proc p(self: var S)` or `proc p(self: S)` for a ref |
| `impl Trait for T` (one or two types) | plain procs with the same names |
| `trait` used as `dyn` or with many types | `method`, or an object of proc fields. *Decide per trait, write it in the table of names* |
| `'a` lifetimes | nothing |
| `#[derive(Debug, Clone, PartialEq, Eq, Hash)]` | nothing for values; `==` and `hash` by hand for refs. *See the traps* |
| `impl Display` | `proc `$`` |
| `panic!`, `unreachable!`, `.expect("...")` | `raiseAssert "..."`, `doAssert`. *Keep the message* |
| `tracing::...` | leave out |
| `#[test] fn name()` | `test "name":` in the test file of the module. *Same name, so a failure can be found upstream* |
| `insta::assert_snapshot!` | compare with the upstream `.snap` through `tools/snapshots.nim`. *Do not create new snapshot files* |
"""

nbNote("""
`Result<T, E>` and the `?` operator appear on 417 lines of the core. Two ways to write them in
Nim: exceptions (short, but they hide the early returns that the Rust shows) or a small `Result`
type with a `?` template (the Nim then reads like the Rust, line by line). This guide recommends
the second, because the port is verified by reading the two files side by side. The first port
step that meets `Result` settles it and replaces this note with the rule.
""", nkQuestion, "Errors: to be settled by the first step that needs it")

nbText: """
## Names that change

| Rust | Nim | Why |
| --- | --- | --- |
| `type_` (module and fields) | `typ` | Nim identifiers cannot end with an underscore |
| `break_` (pretty printer) | `breakDoc` | `break` is a keyword |
| `nil` (pretty printer) | `emptyDocument` | `nil` is a keyword |

Add a row when a name cannot be kept. Search this table before inventing one.

## Traps

Places where Rust and Nim look alike and behave differently. Each was either measured here or
found by a verification pass. The code runs when this page is built.
"""

nbCode:
  # Equality of refs is identity. Rust's derived == looks inside an Arc.
  type Node = ref object
    name: string
  proc same(a, b: Node): bool = a.name == b.name   # what the port must define as `==`
  let a = Node(name: "wibble")
  let b = Node(name: "wibble")
  echo a == b, " ", same(a, b)

nbText: """
So: every type that upstream derives `PartialEq` for, and that is a `ref` here, gets an `==`
written by hand that compares the fields (and a `hash` if upstream derives `Hash`). The same
goes for object variants, which Nim refuses to compare by default.
"""

nbCode:
  import std/unicode
  # .len() is bytes on both sides. .chars().count() is runeLen. A char is a Rune.
  let name = "wibblé"
  echo name.len, " ", name.runeLen
  for r in "é".runes: echo r.int32   # one scalar, not two bytes

nbCode:
  # Unsigned arithmetic wraps silently; signed raises. Rust panics in debug for both.
  var x = 0'u32
  x -= 1
  echo x

nbText: """
So: where upstream subtracts two `u32` (span arithmetic is the usual place), check which one is
bigger the way upstream's logic guarantees, and do not "fix" it by switching to `int`.

- **Order of a hash table.** Rust's `HashMap` iterates in a random order, so upstream already
  sorts, or uses an ordered map, wherever the order can be seen in an output. Port the sort with
  its exact key. Never iterate a `Table` or a `HashSet` on the way to an output without one.
- **Copies.** Assigning a Nim `object`, `seq`, `string` or `Table` copies it; assigning a `ref`
  shares it. Rust makes this visible (`clone()`, `&`, `&mut`), Nim does not. When upstream
  mutates through `&mut` something it got from a collection, take it with `addr` or `mitems`, or
  write it back: a silent copy is the commonest wrong translation.
- **Evaluation order of `?` in arguments.** `f(a()?, b()?)` returns early from `a` before calling
  `b`. Keep that order when unfolding it.
- **String formatting.** `format!("{:?}", s)` is Rust's debug form (quotes, escapes), not `$`.
  Where an output contains a debug form, port the escaping rules, do not approximate them.
- **Integer division and remainder** agree for positive numbers and both truncate toward zero
  (`div`, `mod`). Shifts on signed numbers do not: use the unsigned type upstream uses.

## A port step, from start to finish

1. `nim r tools/portmap.nim todo` and the [roadmap](../roadmap/) say what is next. Read the Rust
   file and its tests whole before writing.
2. Translate, following this page. Port the tests with it, replaying upstream cases with
   `tools/snapshots.nim` and `tools/harvest.nim` instead of retyping them. Status `draft`.
3. Verify: a second pass, without the memory of the first, reads the Nim against the Rust,
   function by function, and lists every difference in behaviour. Fix them. Add any new trap to
   this page. Status `verified`.
4. Conform: the upstream tests of the file pass, and `tools/difftest.nim` agrees where the stage
   can be reached from the command line. Status `conformant`.
5. Write the explainer, update the roadmap, run `nim r tools/portmap.nim`, open the pull request.

## The commands

```sh
sh tools/setup.sh                          # once per sandbox
nim r tools/portmap.nim                    # where the port stands, writes docs/data/portmap.json
nim r tools/portmap.nim todo               # what nobody ported yet, smallest first
nim r tools/snapcorpus.nim list compiler-core/src/parse   # upstream snapshots of a folder
nim r tools/harvest.nim cases format/src --macro:assert_format   # upstream test cases as JSON
nim r -d:release tools/difftest.nim format --candidate:PATH --fast:10   # compare with gleam
nim r tests/all.nim                        # our tests
```

The tools look for the Gleam checkout in `reference/gleam` or `$GLEAM_REF`, and for the
reference binary in `$GLEAM_BIN` or on the `PATH`.
"""

nbSave
