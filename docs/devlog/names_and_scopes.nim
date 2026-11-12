## devlog: 12 Nov 2026 R | Names and scopes | The parser built a tree full of names. This stage works out what each one refers to: scopes, shadowing, two passes over the top level, and why Gleam and Nimony do it in the middle of something else.
## kind: research
import std/[strformat, strutils]
import nimib
import ../blocks
import data/barlume/[series, ast, parser, names]

nbInit
nb.usePost()

const
  gleamAt = "https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/"
  nimAt = "https://github.com/nim-lang/Nim/blob/v2.2.4/"
  nimonyAt = "https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/"

let
  shapes = readFile(docsDir / "devlog" / "data" / "barlume" / "shapes.gleam")
  namesLines = barlumeLines("names.nim")

nbText: &"""
## The short version

- A program is full of names, and a name is a **reference**: `total` in one place points at
  the `let total` in another. The tree from the parser does not have those pointers. It has
  the same word written twice. This stage, **name resolution**, connects each use of a name
  to its definition, or reports that there is none.
- The rule that decides which definition a use sees is **scope**: the part of the program
  where a name is visible. Scopes nest like blocks do, and an inner name can hide an outer
  one. That is **shadowing**.
- The data structure is a chain of small tables, one per scope, each pointing at the one
  around it. To look a name up, start in the innermost and walk out.
- The top level needs **two passes**: first collect every function and type, then look inside
  them. That is all it takes to call a function that is defined further down the file.
- Barlume's resolver is {namesLines} lines of Nim. It gives every local variable a name of its
  own, `x.0`, `x.1`, so that after it no two different things are called the same.
- Gleam has no stage called name resolution. It does this work **inside the type checker**,
  and so do Nim and Nimony. The reason is worth understanding, and it is at the end.

This is part three of a series. Each part builds one stage of a compiler for Barlume, a toy
language that is a small piece of Gleam, and then looks at the real thing.
"""

nbText: seriesTable("names-and-scopes")

nbText: """
## Where we left off

[The parser](../what-a-parser-is/) turned tokens into a tree and refused whatever was not a
sentence. It ended by accepting four programs that are well formed and wrong. This was the
first:

```gleam
fn f() { total + 1 }
```

Nothing defines `total`. The parser cannot care: `total + 1` is a fine expression. From this
post on, the stages stop asking "is this written correctly?" and start asking "what does this
mean?". Compiler people call the first half *syntax* and the second *semantics*, and the
stages that deal with meaning are together called **semantic analysis**. Names come first,
because nothing else can be said about `total + 1` before knowing what `total` is.

## Definitions and uses

Every name in a program appears in one of two roles. Look at this function:

```gleam
fn area(shape) {
  case shape {
    Circle(r) -> 3 * r * r
    Rectangle(w, h) -> w * h
  }
}
```

**Definitions** bring a name into existence: `area` after `fn`, the parameter `shape`, and the
`r`, `w` and `h` inside the patterns. **Uses** refer to something that exists: `shape` after
`case`, `Circle` and `Rectangle` (defined elsewhere, in a `type`), and `r`, `w`, `h` on the
right of the arrows.

Which role a name plays is decided by where it stands, and the parser has already recorded
that: a name in a pattern is a `pkVar`, a name in an expression is an `ekVar`. So the job is
clear. Walk the tree. At each definition, write the name down. At each use, look it up.

The only real question is: look it up *where*?

## Scope

The same name can be defined many times in one program. Every function may have its own `x`.
So "the definition of `x`" means nothing without saying *from where you are asking*. The
answer is the scope of each definition: the region of the program in which it is visible.
Barlume's rules are Gleam's:

- a **parameter** is visible in the whole body of its function;
- a **`let`** is visible from the next statement to the end of its block;
- a **pattern variable** is visible in the body of its own `case` clause, after the arrow;
- a **function**, a **type** and its **constructors** are visible in the whole file.

All of these are regions of the source text. You can find the scope of a name by looking at
the program, without running it. That is called **lexical scope**, and nearly every language
you have used works this way.

Regions nest, because blocks nest. When the same name is defined in an outer and an inner
region, the inner one wins for as long as it lasts, and the outer one is untouched and comes
back afterwards. The inner name **shadows** the outer one.

## A chain of tables

To implement that, give each scope a small table from names to definitions, and a link to the
scope around it.
"""

nbText: barlume("names.nim", "scope")

nbText: """
`open` starts a new innermost scope and `close` drops it. `lookup` is the heart: try the
innermost table, then the one around it, and so on outwards. The first hit wins, and that
alone is shadowing: an inner definition is simply found first.

`declare` is where Barlume does something a little unusual, for the sake of showing its
work. Instead of storing "a definition", it invents a new name: the first `x` of a function
becomes `x.0`, the second `x.1`. That unique name is called a **symbol**. A name is what the
programmer wrote, and many things can share it. A symbol is one thing.

## Walking the tree

The resolver visits every node, and builds a new tree as it goes, the same shape as the old
one with symbols in place of names:
"""

nbText: barlume("names.nim", "expr")

nbText: """
Three of the branches are the whole idea.

**A variable** is a use: look it up, and put the symbol in the new tree.

**A block** opens a scope and closes it at the end. Inside, each statement is handled in a
careful order: first the value, then the name. That order is why this is legal, and means
what you expect:

```gleam
let x = x + 1
```

When the right side is resolved, the new `x` does not exist yet, so the `x` there is the old
one. Only afterwards does the new `x` enter the table and shadow it.

**A `case` clause** opens a scope too. The pattern goes first and declares its variables, the
body is resolved with them visible, and then the scope closes, so the next clause starts
clean. Patterns are in the fold below, along with the top level.

## Seeing it

Here is a function written to be confusing, and what the resolver makes of it. The printer
is the one from the parser post: a tree as nested brackets.
"""

nbCode:
  proc showResolved(source: string) =
    let (module, errors) = resolve(parse(source))
    echo module.sexp.strip
    for error in errors:
      echo "error at ", error.at, ": ", error.message

  showResolved """
fn confusing(x) {
  let x = x + 1
  let y = {
    let x = x * 2
    x
  }
  x + y
}"""

nbText: """
There are three different things called `x` in that function, and now they have three names.
The parameter is `x.0`. The first `let` defines `x.1` from `x.0`. Inside the inner block,
`x.2` is defined from `x.1`, and it is `x.2` that the block returns. And the last line adds
`x.1`, not `x.2`: the inner block has closed, its `x` is gone, and the one it was hiding is
back.

After this stage, a later stage never has to think about scope again. If two names are equal,
they are the same thing.

The program from the first posts, resolved:
"""

nbCode:
  showResolved shapes

nbText: """
`area`, `Circle` and `Rectangle` keep their names: there is one of each in the file, so the
name is already a symbol.

## The top level, twice

Look again at that program. `main` calls `area`, which is defined above it. Swap the two
functions and it still has to work. Gleam, like most modern languages, lets you put
definitions in any order.

A single walk from top to bottom cannot do that: it would reach the call before the
definition. The fix is as simple as it sounds. Go over the top level **twice**. The first
pass looks only at what is defined, functions, types and constructors, and writes all of
them in the outermost table. The second pass goes inside the functions, with everything
already in place.
"""

nbFold "The top level, and patterns":
  nbText: barlume("names.nim", "module")
  nbText: barlume("names.nim", "pattern")

nbCode:
  showResolved """
pub fn main() { double(21) }
fn double(n) { n + n }"""

nbText: """
The first pass is also where a second, separate table appears. `Int` and `Shape` are names
of **types**, and `Circle` is the name of a **value**, something you can call. They live in
different tables, called **namespaces**, because the program never confuses them: after a
`type`, or inside a constructor's brackets, only a type can stand. That is why Gleam lets a
type and its constructor share a name, as in `type Box { Box(Int) }`, and you see it all the
time in Gleam code.

## Saying no, and carrying on

The lexer and the parser stopped at the first problem. This stage does not have to. A wrong
name does not break the tree: the resolver notes the error, puts a placeholder in the new
tree, and keeps walking. So it can report every bad name in one go.
"""

nbCode:
  showResolved """
type Shape { Circle(Itn) }
fn area(shape) { shpae + 1 }
fn area(radius) { Crcle(radius) + r }"""

nbText: """
Every mistake in the file, in one run: a type that does not exist, a function defined
twice, and three names that refer to nothing. The placeholders are the names ending in `.?`.

The "did you mean" is cheap to do here, and only here: at the moment a lookup fails, the
resolver is holding the complete list of names that *would* have been right. It picks the
one that is the fewest edits away.
"""

nbText: barlume("names.nim", "unknown")

nbText: """
## What name resolution cannot know

The usual experiment. All names are fine in these:
"""

nbCode:
  showResolved "fn f() { 1 + \"one\" }"
  showResolved "fn f(x) { x(x) }"
  showResolved "fn g(a) { a } fn f() { g(1, 2, 3) }"

nbText: """
No errors. Every name refers to something. But a number is added to a string, `x` is called
with itself, and `g` gets three arguments for its one parameter. The resolver knows *which
thing* each name is and nothing about *what kind of thing* it is. Knowing that `g` is a
function of one argument, and that `1` is not something you can add to `"one"`, is knowing
their **types**. That is the next post, and the largest stage of the compiler.

## Words you will meet

| Word | What it means |
|---|---|
| semantic analysis | the stages that deal with what a program means: names, types, exhaustiveness |
| definition, declaration, binding | where a name comes into existence |
| use, reference | where a name refers to something that exists |
| scope | the region of the program where a definition is visible |
| lexical scope | scope decided by the text of the program, not by how it runs |
| shadowing | an inner definition hiding an outer one with the same name |
| environment, symbol table | the tables from names to what they refer to |
| symbol | a unique identity for one definition, whatever it is called |
| namespace | a separate table for a separate kind of name: types, values |
| forward reference | a use that comes before its definition in the file |

## The choices every language makes

| | Barlume | Gleam | Nim 2 | Nimony |
|---|---|---|---|---|
| A stage of its own | yes | no: in the type checker | no: in the semantic pass | no: in the semantic pass |
| Scopes are | a chain of tables | one table, copied and restored | a chain of tables | a chain of tables |
| Use before definition | yes | yes | no | yes |
| A `let` may shadow in its own block | yes | yes | no | not checked |
| One name, several functions | no | no | yes | yes |
| A resolved name is | a new name, `x.1` | a node that carries its definition | a pointer to a symbol | a new name, `x.1` |
"""

nbNote &"""
Gleam has no file called name resolution. The work is done by the type checker as it goes,
with a structure called `Environment`
([`type_/environment.rs`]({gleamAt}compiler-core/src/type_/environment.rs)).

- **One table, copied and restored.** The local names are in one map, `scope`. Entering a
  block (`open_new_scope`) keeps a copy of the map as it was, and leaving (`close_scope`)
  puts the copy back. That sounds expensive and is not: the map is an *immutable* one, built
  so that a copy shares almost everything with the original. It is the chain of tables seen
  from the other side: instead of adding a table and removing it, remember the old state and
  return to it.
- **Separate tables for separate things.** `module_values` for the functions and
  constructors of the module, `module_types` for its types, and more for imports. Those are
  the namespaces.
- **The top level in passes.** `infer_module` in
  [`analyse.rs`]({gleamAt}compiler-core/src/analyse.rs) registers imports first, then types,
  then type aliases, then the signature of every function, and only then goes into the
  bodies. Its comments give the reason in so many words: "so that anything imported can be
  referenced anywhere in the module".
- **Closing a scope finds unused variables.** Each scope keeps track of which of its names
  were used. When it closes, the ones never used become warnings. The scope is the natural
  place: that is the moment a name can no longer be used.
- **The error knows what you could have meant.** The unknown variable error carries the list
  of names that were in scope, and `did_you_mean` picks the closest. It carries one more
  thing: whether a name like `_total` exists, because writing `_total` and then using `total`
  is a mistake Gleam has seen before.
- **A resolved name is a richer node.** In the typed tree, a variable is not a name any
  more. It holds a `ValueConstructor`: what kind of thing it is, where it was defined, and
  its type.
""", nkGleam, "How Gleam does it"

nbText: &"""
## Why not a stage of its own?

Barlume resolves names first and will check types afterwards. Gleam does both in one walk.
For Gleam that is a convenience: the type checker has to visit every node and keep an
environment anyway, to know the type of each variable, so the environment might as well
answer both questions. One table from a name to "what it is and what type it has".

For Nim it is a necessity, and this is the reason worth understanding. Nim has
**overloading**: several procedures can share a name and differ in the types of their
parameters.

```nim
proc show(x: int) = echo "a number"
proc show(x: string) = echo "a text"
show("hello")
```

Which `show` does the last line refer to? You cannot tell from the name. You have to know
the type of the argument. So in a language with overloading, resolving names and checking
types cannot be two stages, one after the other. They need each other. Looking a name up
gives a *list* of candidates, and the types pick one.

## Aside: Nim, where order matters

Nim 2 reads a file once, from the top, and resolves names as it goes. So the two-pass trick
is missing, and a procedure must be known before it is used. When two procedures call each
other, one of them has to be announced first with a **forward declaration**: its signature
without its body. Everyone who writes Nim has met this.

Its scopes are the chain from this post: in the compiler's sources a scope is an object with
a table, `symbols`, and a link, `parent`
([`compiler/ast.nim`]({nimAt}compiler/ast.nim)). And unlike Gleam, Nim refuses a second
`let x` in the same block. Shadowing needs a new block.

## Aside: Nimony, where names become symbols in the text

The second goal on Nimony's list, in its
[design document]({nimonyAt}doc/design.md), is "no forward declarations for procs and types
required". It gets there the way this post did. Its semantic checker gives every top level
definition a phase, and the names of the phases tell the story: `SemcheckTopLevelSyms`, then
`SemcheckSignatures`, then `SemcheckBodies`
([`programs.nim`]({nimonyAt}src/nimony/programs.nim)). First the names, then what they look
like from outside, then their insides. Three passes where Barlume has two, because Nimony
has types to work out as well.

Its scope is our scope, almost field for field
([`symtabs.nim`]({nimonyAt}src/nimony/symtabs.nim)): a table called `tab`, a link called
`up`. One difference says a lot. The table maps a name to a *list* of symbols, and the
comment beside it reads "'seq' because of overloading".

The most interesting part is what comes out. Remember that Nimony's stages pass each other
NIF, text with brackets. NIF has two kinds of word for a name. Before the semantic checker a
name is an **identifier**, just what the programmer wrote. After it, a name is a **symbol**,
and the [NIF specification](https://github.com/nim-lang/nifspec/blob/master/doc/nif-spec.md)
defines the form: a local symbol is `<ident>.<disamb>`, such as `foo.0`, "where the `0`
implies it is the first symbol originally named `foo`". A global one adds the module: "the
2nd proc named `foo` in a Nim module `m` would typically become `foo.2.m`".

That is `x.0` and `x.1` from Barlume's output, which is where Barlume took the idea. And NIF
marks the two roles from the start of this post in the text itself: a definition is written
with a colon in front. The specification's example:

```
(imp (proc :write.1.sys . (pragmas varargs) (params (param f File)) .))
(call write.1.sys "Hello World!\0A")
```

`:write.1.sys` defines, `write.1.sys` uses. The payoff is stated in the same document: "a
tool can implement a feature like 'goto definition' in a language agnostic way". Once names
are resolved and written down like this, "where is this defined?" and "who uses this?" are
text searches.
"""

nbNote """
As before: the Nim and Nimony sources were read at the commits in the links (Nim 2.2.4, and
Nimony on 12 November 2026), and nothing of Nimony was built or run. What Nim 2 does with
forward declarations and with a second `let` in a block is said from experience with the
language, and was checked by compiling two small files with Nim 2.2.4.
""", nkWarning, "Read, not run"

nbText: """
## What this changes for the port

- **There is no name resolution step in the roadmap, and now we know why.** In Gleam it is
  part of the type checker. The port keeps that shape: the `Environment` arrives with the
  types, and the order of `infer_module` is ported line by line.
- **The immutable map matters.** Gleam's scopes rely on a map that is cheap to copy. Nim's
  standard library has no such map. The port has to choose: copy a normal table at every
  block, which is simple and may be slow, or build the chain of tables from this post, which
  is fast and no longer line by line. It is the kind of choice that gets a decision record,
  and it belongs to the step that ports the environment.
- **Errors that carry on start here.** This is the first stage that reports more than one
  problem. From here on the port has to reproduce not one error but the same list of errors,
  in the same order, as the reference.
- **Barlume has three stages**: `names.nim` joined the lexer and the parser in
  `docs/devlog/data/barlume/`.

Next: types. A number was added to a string and nobody noticed.

## Sources

- Gleam at the pinned commit:
  [`type_/environment.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/type_/environment.rs)
  (`Environment`, `open_new_scope`, `close_scope`),
  [`analyse.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/analyse.rs)
  (`infer_module`),
  [`type_/error.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/type_/error.rs)
  (`UnknownVariable`),
  [`error.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/error.rs)
  (`did_you_mean`),
  [`ast/typed.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/ast/typed.rs)
  (`TypedExpr::Var`).
- Nim 2.2.4: [`compiler/ast.nim`](https://github.com/nim-lang/Nim/blob/v2.2.4/compiler/ast.nim)
  (`TScope`).
- Nimony at commit `4ba90a7`:
  [`doc/design.md`](https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/doc/design.md),
  [`src/nimony/symtabs.nim`](https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/src/nimony/symtabs.nim),
  [`src/nimony/programs.nim`](https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/src/nimony/programs.nim)
  (`SemPhase`).
- The [NIF specification](https://github.com/nim-lang/nifspec/blob/master/doc/nif-spec.md),
  read on 12 November 2026: symbols, symbol definitions, and the example quoted.
- Robert Nystrom, *Crafting Interpreters*, the chapter
  [Resolving and Binding](https://craftinginterpreters.com/resolving-and-binding.html), named
  from memory as the best longer read; the site could not be opened from the sandbox.
- Earlier parts: [What a lexer is](../what-a-lexer-is/), [What a parser is](../what-a-parser-is/).
"""

nbSave
