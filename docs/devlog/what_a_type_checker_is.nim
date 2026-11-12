## devlog: 12 Nov 2026 U | What a type checker is | How a compiler knows the type of everything without being told: unknowns, equations between them, and one small procedure called unify. The largest stage of Gleam, built small, then compared with Nim and Nimony.
## kind: research
import std/[strformat, strutils, tables]
import nimib
import ../blocks
import data/barlume/[series, ast, parser, names, types]

nbInit
nb.usePost()

const
  gleamAt = "https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/"
  nimonyAt = "https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/"

let
  shapes = readFile(docsDir / "devlog" / "data" / "barlume" / "shapes.gleam")
  typesLines = barlumeLines("types.nim")

nbText: &"""
## The short version

- A **type** is a promise about a value: this is a whole number, this is a function from a
  shape to a number. A **type checker** proves, without running the program, that every
  promise is kept: nothing is added to a string, no function gets the wrong arguments.
- Some languages make you write the types and then check them. Gleam asks for nothing and
  works them out. That is **type inference**, and it is less magic than it looks.
- The method: give every thing whose type is not known yet an **unknown**, a blank to fill
  in. Walk the tree. Every operation says something about its parts: `+` says both sides
  are `Int`. Each such statement is an equation, and one procedure, **unify**, solves them by
  filling in blanks.
- A blank that is still empty when a function is finished means "any type will do". That is
  how `fn identity(x) {{ x }}` works for numbers and strings alike: **generics**, for free.
- A type error is an equation with no solution: `Int = String`.
- Barlume's checker is {typesLines} lines of Nim and uses the same three kinds of type
  variable as Gleam: unbound, link and generic. Gleam's is the largest part of its compiler.
  Nim and Nimony make a different trade: you write more types, and get overloading.

This is part four of a series. Each part builds one stage of a compiler for Barlume, a toy
language that is a small piece of Gleam, and then looks at the real thing.
"""

nbText: seriesTable("what-a-type-checker-is")

nbText: """
## Where we left off

[Names and scopes](../names-and-scopes/) connected every name to its definition and gave each
local a symbol of its own, `x.0`, `x.1`. It ended with programs where every name is fine and
something else is wrong:

```gleam
fn f() { 1 + "one" }
fn g(a) { a }
fn h() { g(1, 2, 3) }
```

A number plus a string. Three arguments for a function of one. To see these, the compiler
has to know what *kind* of thing each expression is.

## What a type is

A type is what you can say about a value before the program runs. `Int`: a whole number.
`String`: a text. `Shape`: one of the shapes that a `type Shape` declared. `fn(Shape) -> Int`:
something you can call with a shape, and that gives back a whole number.

That is a small vocabulary and it catches a remarkable share of mistakes, because most
mistakes are of the form "I gave this thing to something that wanted another kind of thing".
A compiler that checks types before running is called **statically typed**. Gleam, Nim, Rust
and Elm are. Python, JavaScript and Erlang check while running, when the mistake actually
happens, which is later and in front of your users.

In Barlume, as in Gleam, a type is one of three things:
"""

nbText: barlume("types.nim", "type")

nbText: """
The first two are what you expect: a type with a name, and a function type, which is made of
other types, one per parameter and one for the result. So types are small trees, like
expressions are.

The third kind is the idea this whole post is about.

## Unknowns

Here is a function with no types written anywhere:

```gleam
fn double(n) { n + n }
```

You can tell its type at a glance: it takes an `Int` and gives an `Int`. How do you know?
Not from `n`. From `+`. In Gleam `+` adds whole numbers and nothing else, so `n` must be one,
and so is the sum.

A compiler reasons the same way, in three moves.

1. It does not know the type of `n`, so it gives it a blank: call it `?1`.
2. It reaches `n + n`. The rule for `+` is: both sides are `Int`, and so is the result. The
   left side is `n`, whose type is `?1`. So `?1 = Int`. The blank is filled in.
3. The body's type is `Int`, the parameter's type is `?1`, which is now `Int`. The function
   is `fn(Int) -> Int`.

That blank is a **type variable**: `tyVar` in the code above. It has a number to tell it
from other blanks, and a `link` that is empty at first and, once we find out, points at the
type it turned out to be. Making a new one is two lines:
"""

nbText: barlume("types.nim", "fresh")

nbText: """
Since a blank may point at another blank that points at a type, reading a type always starts
by following the links to the end. This helper is called at the top of everything else:
"""

nbText: barlume("types.nim", "prune")

nbText: """
## Unify

Step 2 above, "so `?1 = Int`", is the one operation of the whole stage. It takes two types
and makes them equal, by filling in whatever blanks it needs to. It is called
**unification**.
"""

nbText: barlume("types.nim", "unify")

nbText: """
Read `unify` from the top.

- If the two are already the same, there is nothing to do.
- If one of them is a blank, fill it in with the other. **This line is type inference.**
  Everything else is bookkeeping.
- If both are named types, they must have the same name. `Int` and `Int`, fine. `Int` and
  `String`: this is where a type error is born.
- If both are functions, they must take the same number of parameters, and then the
  parameters are unified one by one, and the results. The procedure calls itself, because
  types are trees.
- Anything else, a function against an `Int` for example, cannot be made equal.

The small check before filling in a blank, `occursIn`, refuses to make a blank equal to
something that contains that same blank. We will meet the program that needs it.

## Walking the tree

With unknowns and `unify`, the checker is a walk over the tree that the name resolver
produced. Each kind of expression has a rule: what its parts must be, and what it is.
"""

nbText: barlume("types.nim", "infer")

nbText: """
`expect` is `unify` plus an error message when it fails. The rules, in words:

- **A literal** has its type on its face.
- **A variable** has the type that was recorded for its symbol. This is where the previous
  stage pays off: the table goes from symbol to type, with no scopes, because every symbol
  is unique.
- **An operator** wants `Int` on both sides. `==` is different: it wants both sides to be
  the *same* type, whatever that is, so it unifies them with each other.
- **A block** has the type of its last statement, and each `let` records the type of its
  value for its name.
- **A `case`** gives the same type in every clause, and each pattern must fit the type of
  the thing examined.

**A call** is the one to read twice. The checker does not look up how many parameters the
function has. It builds the type the function *would need to have* for this call to make
sense, "a function from these arguments to something", with a fresh blank for the something,
and unifies that with the type of whatever is being called. If the callee is a known
function, that checks the arguments and fills in the result. If the callee is itself a
blank, that *tells us it is a function*. Same line of code, both directions.

## Running it

The program from the first post, through all four stages:
"""

nbCode:
  proc showTypes(source: string) =
    let (module, nameErrors) = resolve(parse(source))
    let typed = check(module)
    for name, typ in typed.functions:
      echo name, ": ", typ
    for error in nameErrors:
      echo "name error at ", error.at, ": ", error.message
    for error in typed.errors:
      echo "type error at ", error.at, ": ", error.message

  showTypes shapes

nbText: """
Nobody wrote `Shape` or `Int` next to `area`. The checker found `Shape` because the `case`
matches its parameter against `Circle(r)`, and `Circle` builds a `Shape`. It found `Int`
because the clauses multiply.

The checker knows more than the types of functions. It recorded a type for **every
expression** in the tree. Here they are for the body of `main`, smallest first:
"""

nbCode:
  let (resolved, _) = resolve(parse(shapes))
  let typed = check(resolved)

  proc walk(e: Expr) =
    case e.kind
    of ekBinary: (walk e.left; walk e.right)
    of ekCall:
      walk e.callee
      for arg in e.args: walk arg
    of ekBlock:
      for s in e.statements: walk s.value
    else: discard
    if e.kind != ekBlock:
      echo alignLeft(shapes[e.start ..< e.stop], 20), " ", typed.of_expr[e]

  walk resolved.functions[1].body

nbText: """
That table is the output of this stage: the **typed tree**. The same tree as before, where
every node now knows its type. The later stages need it. A code generator has to know
whether `Circle` is being called as a function or used as a value, and the next post has to
know that the thing in a `case` is a `Shape` to know which constructors to expect.

Now functions that take functions. No types written, all of them found:
"""

nbCode:
  showTypes """
fn apply(f, x) { f(x) }
fn twice(f, x) { f(f(x)) }
fn compose(f, g, x) { f(g(x)) }"""

nbText: """
Follow `apply` in your head. `f` gets `?1`, `x` gets `?2`. The call `f(x)` says: `?1` is a
function from `?2` to something new, `?3`. Nothing else is known. So `apply` takes a
function from `?2` to `?3`, and a `?2`, and gives a `?3`. The printer writes the blanks that
are left as `a`, `b`, `c`.

Look at `twice`: `f(f(x))` feeds the result of `f` back into `f`, so its result type and its
parameter type must be the same. The checker noticed: `fn(a) -> a`.

## Generics, for free

Those letters are not a failure to work something out. `apply` really does work for any `a`
and `b`. When a function is finished and some blanks are still empty, nothing in the function
cares what they are. So the checker marks them as **generic**: free to be something
different at every use.
"""

nbText: barlume("types.nim", "generalise")

nbText: """
`generalise` runs once, when a function is done. `instantiate` runs at every *use* of the
function, in the `ekVar` rule: it makes a copy of the type with new blanks in place of the
generic ones. So each call fills in its own copy, and one call's `Int` does not leak into
another call's `String`:
"""

nbCode:
  showTypes """
fn identity(x) { x }
fn main() {
  let n = identity(1)
  let s = identity("one")
  n + 1
}"""

nbText: """
Without the copy, the first call would fill the blank with `Int` for good, and the second
would be a type error.

There is an order problem hiding here, and it explains a piece of the real compiler. A
function can only be generalised when it is finished, and it should be finished before
anyone uses it. So functions are inferred **after the functions they call**, whatever order
they are written in. Barlume follows the calls. Gleam builds a graph of who calls whom and
sorts it.

## Type errors

A type error is `unify` saying no. Here are the programs from the top of the post:
"""

nbCode:
  showTypes "fn f() { 1 + \"one\" }"
  showTypes "fn g(a) { a }\nfn h() { g(1, 2, 3) }"

nbText: """
The second message shows the call rule at work: the call needed a function of three `Int`s,
and `g` is a function of one thing.

Like the name resolver, the checker carries on after an error. A failed `unify` is reported
and the walk continues, so one run reports everything:
"""

nbCode:
  showTypes """
type T { A(Int) B }
fn f(t) {
  case t {
    A(n, m) -> 0
    B -> "zero"
    3 -> 1
  }
}"""

nbText: """
And the program `occursIn` was written for. A function applied to itself:
"""

nbCode:
  showTypes "fn f(x) { x(x) }"

nbText: """
`x` has type `?1`. The call says `?1` is a function whose parameter is the type of `x`, which
is `?1`. So `?1 = fn(?1) -> ?2`: a type that contains itself, a function taking a function
taking a function, without end. `occursIn` sees the blank inside the type it is about to be
filled with and refuses. Without that check the checker would build a loop and run for ever
printing it.

## What a type checker cannot know

The last program of the parser post is still standing:
"""

nbCode:
  showTypes """
type T { A B }
fn f(t) { case t { A -> 1 } }"""

nbText: """
Well typed. `t` is a `T`, `A` is a `T`, every clause gives an `Int`. And the function has no
answer for `B`. The types of the patterns are right. What is wrong is that, taken together,
they do not cover the type. That is a question about *all* the clauses at once, and it has
its own stage: the next post.

Beyond that, there are things no type checker of this kind will tell you: that a number is
never zero before a division, that a loop ends. A type is a cheap promise. That is its
strength and its limit.

## Words you will meet

| Word | What it means |
|---|---|
| type | what can be said about a value before the program runs |
| static typing | checking types before running; dynamic typing checks while running |
| type annotation | a type written by the programmer, as in `n: Int` |
| type inference | working the types out instead of asking for them |
| type variable | a type not known yet; a blank |
| unification | making two types equal by filling in blanks |
| generic, polymorphic | working for any type: `fn(a) -> a` |
| generalise | declare the blanks left in a finished function generic |
| instantiate | copy a generic type with new blanks, for one use |
| occurs check | refusing a type that would contain itself |
| arity | how many parameters a function has |
| Hindley-Milner | the name of this method, after two of the people who found it |
| typed tree | the syntax tree where every node has its type |

## The choices every language makes

| | Barlume | Gleam | Nim 2 | Nimony |
|---|---|---|---|---|
| Types on parameters | cannot be written | optional | required | as Nim |
| Inference | whole functions | whole functions | from the right side of a `let` | as Nim |
| A generic function | found by the checker | found, or written with letters | written with `[T]` | written with `[T]` |
| Its body is checked | once, when defined | once, when defined | at every use | once, when defined |
| What a generic value can do | be passed around | be passed around | anything that compiles | what a concept declares |
| Overloading | no | no | yes | yes |
| After an error | carries on | carries on | reports it | carries on |
"""

nbNote &"""
This stage is the heart of the Gleam compiler and its largest part. The pieces have
the names of this post.

- **Three kinds of type, three kinds of variable.** In
  [`type_.rs`]({gleamAt}compiler-core/src/type_.rs) a `Type` is `Named`, `Fn`, `Var` or
  `Tuple`, and a `TypeVar` is `Unbound`, `Link` or `Generic`. The comments say what this
  post said: unbound "is one specific type but we don't know what yet", a link "was an
  unbound variable but we worked out that it is some other type and now we point to that
  one", and a generic "stands in for any possible type". Barlume folds the three into one
  object with a `link` and a `generic` flag.
- **`unify` is one function**, in
  [`type_/environment.rs`]({gleamAt}compiler-core/src/type_/environment.rs), with the same
  cases. `instantiate` is beside it, and `generalise` is in `type_.rs`.
  The occurs check is there too, and its error is called `RecursiveType`.
- **The walk is `type_/expression.rs`**, one of the longest files of the compiler: a rule per kind
  of expression, like `infer`, for a language with many more kinds. Patterns have their own
  file, `type_/pattern.rs`.
- **Only top level functions are generalised.** A `let` inside a function is not, which
  keeps the method simple. And functions are inferred in dependency order:
  [`call_graph.rs`]({gleamAt}compiler-core/src/call_graph.rs) builds the graph, and the
  comment where it is used says "definitions that do not depend on other definitions are
  inferred first, then ones that depend on those".
- **You may write types, and they are checked.** An annotation is one more equation: the
  annotated type is unified with the inferred one. Annotations are also how you make a
  function *less* general than it could be.
- **It carries on.** A failed expression becomes a node called `Invalid` in the typed tree,
  with a type, and the walk continues. That is how the language server can show every error
  in a file, and still know types around them.

[How the Gleam compiler is made](../how-gleam-compiles/) has the sizes and the history. The
port of this stage is the second phase of the [roadmap](../../roadmap/).
""", nkGleam, "How Gleam does it"

nbText: &"""
## Aside: Nim, where you write the types and get something back

Nim infers much less. Try `double` without a type:

```nim
proc double(n) = n + n
```

The compiler answers "parameter 'n' requires a type". In Nim inference is **local**: it goes
from the right of a `let` to its left, `let total = area(c)`, and no further. A procedure's
parameters are a contract that the programmer writes.

What Nim gets in exchange is **overloading**, the thing the previous post ended on. With
types written on every parameter, `show(x: int)` and `show(x: string)` can coexist, and `+`
can mean addition for integers, floats and anything you define it for. In Gleam `+` is for
`Int` and floats have their own `+.`. That is not a quirk. It is the price of the method:
"both sides of `+` are `Int`" is what let the checker work out `double` with nothing
written. If `+` could mean several things, the equation would have several solutions.

Generics show the other half of the trade. In Nim you write the type variable yourself:

```nim
proc add[T](a, b: T): T = a + b
```

and Nim 2 does not check the body of `add` when it reads it. It checks it at each use, with
the real type in place of `T`: `add(1, 2)` compiles, `add("a", "b")` is an error, reported
inside `add`. Until someone calls it, a generic procedure can contain almost anything.

## Aside: Nimony, where generics are checked once

"Type-checked generics" is the fourth goal on Nimony's list, and
[the article on its design](https://nim-lang.org/araq/nimony.html) says what it means:
"Nimony improves on Nim's generics by performing complete type checking on generic code, not
merely on generic instantiations". The body of a generic procedure is checked when it is
defined, as in Gleam.

But Nimony keeps overloading, so it cannot do what Gleam does and let a generic value be
only "passed around". If `fib[T]` uses `+` and `<=` on a `T`, the checker has to know that
`T` has them. The article's example declares it:

```nim
type
  Fibable = concept
    proc `<=`(a, b: Self): bool
    proc `+`(x, y: Self): Self
    proc `-`(x, y: Self): Self

proc fib[T: Fibable](a: T): T =
  if a <= 2:
    result = 1
  else:
    result = fib(a-1) + fib(a-2)
```

"Without declaring that T must be Fibable the compiler rejects proc fib." A **concept** is a
list of operations a type must have. It is the middle of the road between Gleam, where a
generic thing can do nothing, and Nim 2, where it can try anything.

The three languages are three answers to one question: how much should the programmer write
so that the checker can be sure? Gleam: nothing, and operators mean one thing. Nim 2: the
parameter types, and generics are checked late. Nimony: the parameter types and what
generics need, and everything is checked early.

The matching itself is in [`sigmatch.nim`]({nimonyAt}src/nimony/sigmatch.nim) in both
compilers: given a call and the candidates for its name, find the ones whose parameter
types fit the arguments, and pick the best. It is unification's practical cousin, with
conversions and rankings added.
"""

nbNote """
The three small Nim programs in the first aside were compiled with Nim 2.2.4, and the
messages quoted are what it printed. The Nimony part comes from the article and the sources
linked, at the commit in the links. Nothing of Nimony was built or run.
""", nkDone, "What was checked"

nbNote """
Rust needs some ceremony for a type variable that several types share and that can be
filled in later: a reference counted pointer to a cell that allows mutation. In Nim that is
a `ref object`, which is what Barlume's `Type` is. Two types that hold the same blank hold
the same reference, and filling it in through one is seen through the other. The port of
the types can be plainer than the original.
""", nkNim, "One thing that gets simpler in Nim"

nbText: """
## What this changes for the port

- **A map for the largest phase.** The analysis phase of the roadmap has steps called
  types, inference of the expression core, of patterns, module analysis. After this post
  each has a small counterpart to compare with: `Type` and `unify`, `infer`, `check` for
  patterns, the top of `check` for modules.
- **The order of blanks is part of the output.** When Gleam prints `fn(a) -> b` in an error
  message, the letters come from the order in which the variables are met. The port has to
  print the same letters, so it has to walk in the same order and make new variables at the
  same moments as the Rust. "Same result" is not enough for this stage. The route matters.
- **Errors come in lists, and nodes can be invalid.** The typed tree has a node for "this
  did not type check". Every later stage of the port has to accept it.
- **Barlume has four stages**: `types.nim` joined the others in
  `docs/devlog/data/barlume/`.

Next: the `case` that forgot `B`.

## Sources

- Gleam at the pinned commit:
  [`type_.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/type_.rs)
  (`Type`, `TypeVar`, `generalise`),
  [`type_/environment.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/type_/environment.rs)
  (`unify`, `instantiate`),
  [`type_/expression.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/type_/expression.rs),
  [`analyse.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/analyse.rs)
  and [`call_graph.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/call_graph.rs)
  (dependency order),
  [`ast/typed.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/ast/typed.rs)
  (`TypedExpr::Invalid`).
- Andreas Rumpf, [Nimony: Design principles](https://nim-lang.org/araq/nimony.html), 2025:
  the section on generics, quoted above.
- Nimony at commit `4ba90a7`:
  [`doc/design.md`](https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/doc/design.md),
  [`src/nimony/sigmatch.nim`](https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/src/nimony/sigmatch.nim).
- The method is the Hindley-Milner type system; its
  [Wikipedia page](https://en.wikipedia.org/wiki/Hindley%E2%80%93Milner_type_system) could
  not be opened from the sandbox this was written in. That Gleam generalises only top level
  functions is from [How the Gleam compiler is made](../how-gleam-compiles/).
- Earlier parts: [What a lexer is](../what-a-lexer-is/), [What a parser is](../what-a-parser-is/),
  [Names and scopes](../names-and-scopes/).
"""

nbSave
