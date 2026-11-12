## devlog: 12 Nov 2026 V | Checking a case | How a compiler knows that a case forgot something, and which clause can never run: patterns turned into a tree of questions. The algorithm Gleam follows, small enough to read, then Nim's simpler answer to a simpler question.
## kind: research
import std/[strformat, strutils]
import nimib
import ../blocks, ../site
import data/barlume/[series, parser, names, types, cases]

nbInit
nb.usePost()

const
  gleamAt = "https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/"

let
  shapes = readFile(docsDir / "devlog" / "data" / "barlume" / "shapes.gleam")
  casesLines = barlumeLines("cases.nim")

# The size of Gleam's exhaustiveness checker, from the coverage map.
var gleamLines = 0
for stage in loadCoverage().stages:
  for module in stage.modules:
    if module.module == "compiler-core/exhaustiveness": gleamLines = module.rustCode
doAssert gleamLines > 0

nbText: &"""
## The short version

- A `case` is a list of clauses, and a clause is a **pattern** and what to do when it fits.
  Two things can be wrong with the list as a whole: a value that **no clause** fits, and a
  clause that **no value** can ever reach because the ones above it take everything. The
  first is a crash waiting to happen. The second is dead code, and usually a thinking error.
- Checking that looks easy, tick off the constructors, until patterns **nest**. Then the
  number of combinations explodes, and the tick list does not work.
- The method that does work turns the question around. Do not compare patterns with each
  other. Build the **tree of questions** a running program would ask of a value: is it this
  constructor? then is its first field that one? Each clause ends up at the leaves where it
  wins.
- In that tree, a leaf with no clause is a missing pattern, and the path to it says which.
  A clause that is at no leaf is unreachable.
- The same tree is also the fastest way to *run* the `case`. Gleam builds it once and uses
  it twice: to check, and to generate JavaScript.
- Barlume's version is {casesLines} lines of Nim. Gleam's is {gleamLines.thousands} lines of
  Rust, most of them for kinds of pattern Barlume does not have.

This is part five of a series. Each part builds one stage of a compiler for Barlume, a toy
language that is a small piece of Gleam, and then looks at the real thing.
"""

nbText: seriesTable("checking-a-case")

nbText: """
## Where we left off

[The type checker](../what-a-type-checker-is/) gave every expression a type and let this
through:

```gleam
type T { A B }
fn f(t) { case t { A -> 1 } }
```

Every type fits. `t` is a `T`, the pattern `A` is a `T`, the clause gives an `Int`. And
`f(B)` has no answer.

## Why a language cares so much

In Gleam, `case` is the only way to look inside a value of a custom type. There is no
"is it a circle?" followed by "give me the radius and trust me". The radius only comes out
of a pattern that matched `Circle`. So every decision about data goes through a `case`, and
the compiler makes a promise about every one of them: **whatever the value is, some clause
will take it**. There is nothing like a null pointer error in Gleam, and this check is half
of the reason. The other half is the type checker.

The promise pays most on an ordinary day. Add a third shape to `Shape`, and the compiler
answers with the list of every `case` in the program that does not handle it yet. That list
is the to-do list of the change, complete, and it costs nothing.

## The easy version, and where it breaks

For the program above the check is simple. `T` has two constructors, `A` and `B`. Go through
the clauses, tick off the constructors you see. `B` has no tick: report it.

Now two types, one inside the other:

```gleam
type Light { On Off }
type Pair { Pair(Light, Light) }

fn f(p) {
  case p {
    Pair(On, On) -> 1
    Pair(Off, x) -> 2
  }
}
```

`Pair` has one constructor, and both clauses use it: ticked. But is every pair covered? You
have to think about what is *inside*. There are four pairs. The first clause takes one. The
second takes two, because `x` fits anything. One is left: `Pair(On, Off)`.

You found it by listing combinations. With three fields of three constructors each that is
twenty seven combinations, and a pattern can go as deep as the programmer likes. With a type
that contains itself, like a list, the combinations never end. Listing does not scale, and
ticking does not see inside. We need another idea.

## Turn the question around

Forget the checker for a moment and think about the *running* program. It holds a value and
must pick a clause. It cannot see the whole value at once. All it can do is ask one question
at a time: **which constructor made this?** Then, knowing that, the same question about one
of its fields.

Write down every question it could ask and every possible answer, and you get a tree. At
the top: which constructor is `p`? Under each answer: the next question, or, if no question
is left, the clause that wins. This is a **decision tree**.

Everything we want to know is in that tree:

- a leaf where **no clause is left** is a value nothing matches. The answers on the way down
  describe it.
- a clause that is **at no leaf** can never win. It is unreachable.

So the job is to build the tree. The checks are then two short walks.

## Clauses as rows of tests

The trick that makes the building easy is to stop treating a clause as one pattern, and
treat it as a list of small statements of the form "this variable has this shape":
"""

nbText: barlume("cases.nim", "rows")

nbText: """
At the start each clause has exactly one test: the thing examined against the clause's
whole pattern.

```
clause 1:  p is Pair(On, On)
clause 2:  p is Pair(Off, x)
```

When we learn that `p` was made by `Pair`, with fields we will call `$1` and `$2`, the test
on `p` can be replaced by tests on its fields:

```
clause 1:  $1 is On,  $2 is On
clause 2:  $1 is Off, $2 is x
```

One nested pattern has become several flat tests. Keep doing that and nesting disappears.
The tree we are building is made of three kinds of node:
"""

nbText: barlume("cases.nim", "decision")

nbText: """
## The algorithm, in four rules

Here is the whole compiler from rows to tree. It is one procedure that calls itself.
"""

nbText: barlume("cases.nim", "compile")

nbText: """
The four rules, in the order of the code:

**A name is not a test.** `$2 is x` is always true: `x` fits anything. So before anything
else, such tests are taken out of the rows and remembered as "in this clause, `x` means
`$2`". The same for `_`, without the remembering.

**No rows left: failure.** If we got here, some value did, and there is no clause for it.

**The first row has no tests left: it wins.** Everything it asked for has been confirmed
on the way down. Clauses are tried from the top, so the first row beats whatever is
below it. This is a leaf, and the clause is marked as reached.

**Otherwise, ask a question.** Take a variable that the first row still tests, and split
on its type. For each constructor of that type, make a branch, and decide which rows go
down into it:

- a row that **wants this constructor** goes down, and its test is replaced by tests on the
  fields, as in the example above;
- a row that **wants another constructor** is dropped: it cannot match here;
- a row that **does not test this variable** goes down unchanged, into every branch. It
  does not care.

Then the same procedure runs on the rows of each branch. Every step removes a test or
makes a pattern smaller, so it ends.
"""

nbFold "The helpers":
  nbText: barlume("cases.nim", "helpers")

nbText: """
## Watching it

The pair of lights, through all the stages so far, and the tree for its `case`:
"""

nbCode:
  proc showCases(source: string, tree = true) =
    let (module, nameErrors) = resolve(parse(source))
    let typed = check(module)
    doAssert nameErrors.len == 0 and typed.errors.len == 0
    for report in checkCases(module, typed):
      if tree: echo report.tree.render
      for pattern in report.missing:
        echo "missing: ", pattern
      for clause in report.unreachable:
        echo "clause ", clause + 1, " can never be reached"
      if report.missing.len + report.unreachable.len == 0:
        echo "every value has a clause, every clause has a value"

  showCases """
type Light { On Off }
type Pair { Pair(Light, Light) }
fn f(p) {
  case p {
    Pair(On, On) -> 1
    Pair(Off, x) -> 2
  }
}"""

nbText: """
Read it from the top. `p.0` is the parameter (the `.0` is from the name resolver). It can
only be a `Pair`, whose fields get the names `$1` and `$2`. Then the first field: if it is
`On`, the second field decides, and there, under `On` then `Off`, is the hole: no clause
matches. If the first field is `Off`, clause 2 wins without looking at the second field at
all, because that clause had a name there, and the tree remembers that `x` is `$2`.

The missing pattern was not searched for. It was *read off the path*: `p` is a `Pair`, `$1`
is `On`, `$2` is `Off`.
"""

nbText: barlume("cases.nim", "missing")

nbText: """
`missing` walks to every failure, keeping a table of what was decided on the way. `show`
turns that table back into a pattern, and a variable that no question was asked about
becomes `_`. That is why the next message is as short as it can be. A list of numbers, and a
function that forgets lists of exactly one element:
"""

nbCode:
  showCases """
type List { Empty Cons(Int, List) }
fn f(list) {
  case list {
    Empty -> 0
    Cons(first, Cons(second, rest)) -> first + second
  }
}""", tree = false

nbText: """
`Cons(_, Empty)`: a list with one element, whatever the element. `List` contains itself, so
there are infinitely many lists, and the tree is still small, because it only asks the
questions the clauses asked.

## Clauses that can never run

The other walk is not even a walk. While building the tree, every clause that becomes a leaf
is noted. Afterwards, a clause that was never noted is unreachable:
"""

nbCode:
  showCases """
type Light { On Off }
type Pair { Pair(Light, Light) }
fn f(p) {
  case p {
    Pair(On, _) -> 1
    Pair(_, On) -> 2
    Pair(On, Off) -> 3
    Pair(Off, Off) -> 4
  }
}"""

nbText: """
Clause 3 looks reasonable on its own. But a pair that starts with `On` never gets past
clause 1. In the tree, the branch for `On` is a leaf already, and clause 3 is at no leaf.

## Numbers and strings

A custom type has a known list of constructors. `Int` has no end. For those, the split
makes one branch for each number that appears in the clauses, and one more for "anything
else", which only the rows that did not ask can enter:
"""

nbCode:
  showCases """
fn name(n) {
  case n {
    0 -> "zero"
    1 -> "one"
  }
}"""

nbText: """
The missing pattern is `_`: you cannot list all the numbers, so a `case` on a number always
needs a clause that takes the rest.

And the program from the first post, which had it right all along:
"""

nbCode:
  showCases shapes

nbText: """
## One tree, two uses

Look at that last tree again, not as a proof but as a program. "Look at `shape`. Is it a
`Circle`? Then run clause 1 with `r` being its field." That is exactly what the compiled
code has to do when it runs. And it is good code: each part of the value is looked at once,
and no question is asked twice, however the clauses overlap.

That is why this stage has two names. People who care about errors call it **exhaustiveness
checking**. People who care about speed call it **compiling pattern matching**. It is the
same tree. The next post, on code generation, picks it up from here.

## The end of the errors

This is the last stage that can refuse a program. A Barlume program that got through the
lexer, the parser, the name resolver, the type checker and this check is a program whose
every name means something, whose every operation fits, and whose every `case` has an
answer. In compiler words, the **front end** and the **analysis** are done, and what is
left is the **back end**: turning a tree that is known to be right into something that
runs.

## Words you will meet

| Word | What it means |
|---|---|
| pattern | a shape with holes that a value either fits or does not |
| clause, branch, arm | one line of a `case`: a pattern and what to do |
| exhaustive | every possible value fits some clause |
| unreachable, redundant | a clause that no value can get to |
| wildcard, catch-all | a pattern that fits anything: `_` or a name |
| custom type, sum type, variant, tagged union | a type that is one of several constructors |
| decision tree | the questions to ask of a value, and where each answer leads |
| guard | an extra condition on a clause, as in `n if n > 0` (Barlume has none) |
| front end, back end | the stages that understand the program, and the ones that produce the result |

## The choices every language makes

| | Barlume | Gleam | Nim 2 |
|---|---|---|---|
| Patterns nest | yes | yes | no: a `case` compares with constant values |
| The check | a decision tree | a decision tree | a set of values, ticked off |
| It reports | the missing patterns | the missing patterns | the missing values |
| Not exhaustive is | an error | an error | an error |
| Unreachable is | reported | a warning | an error, for a value listed twice |
| Reading a field of the wrong variant | cannot be written | cannot be written | an error when it runs |
"""

nbNote &"""
Gleam's checker is [`exhaustiveness.rs`]({gleamAt}compiler-core/src/exhaustiveness.rs), and
its first lines say where it comes from: "How to compile pattern matching" by Jules Jacobs,
"Compiling Pattern Matching to good Decision Trees" by Luc Maranget, a paper by Per
Gustafsson and Konstantinos Sagonas on matching binary data, and Yorick Peterse's
implementation in Rust, with a thank you. Barlume follows the first of those, like Gleam.

- **Rows of tests.** The module comment explains the same change of view as this post: a
  branch "can each contain multiple pattern checks", written there as `a is Some, b is 1`,
  because that "makes it way easier to compile the pattern matching into a decision tree".
- **The same nodes, and one more.** Gleam's `Decision` is `Run`, `Switch`, `Fail` and
  `Guard`. `Fail` is documented as "a special node: it represents a missing pattern", and
  "the path leading to this node will describe what kind of pattern doesn't match". `Guard`
  is for clauses with an `if`.
- **Missing patterns** are collected by `exhaustiveness/missing_patterns.rs`, by walking to
  the `Fail` nodes, and become the error for a `case` that is not exhaustive. A `let` with a
  pattern is checked the same way, and has its own error.
- **Unreachable clauses** are a warning, not an error.
- **It picks its questions.** Barlume splits on the first test of the first row. Gleam
  chooses the variable to split on with a function, `find_pivot_check`, to keep trees small.
- **Why it is so long.** Lists, tuples, strings with a known prefix, and above all bit
  arrays, where a pattern like "eight bits, then that many bytes" needs reasoning about
  sizes and offsets. That is what the binary data paper is for.
- **One tree, two uses.** The tree is kept in the typed syntax tree. The JavaScript backend
  reads it and prints it as `if` and `else`
  ([`javascript/decision.rs`]({gleamAt}compiler-core/src/javascript/decision.rs)). The
  Erlang backend does not need it, because Erlang has `case` and patterns of its own.
""", nkGleam, "How Gleam does it"

nbText: &"""
## Aside: Nim and Nimony, a simpler answer to a simpler question

Nim's `case` does not take values apart. It compares a value with constants: enum values,
numbers, ranges, strings. So its exhaustiveness check is the easy version from the top of
this post, and it is done well. This program:

```nim
type Light = enum on, off

proc f(l: Light): int =
  case l
  of on: 1
```

is refused with "not all cases are covered; missing: {{off}}". The missing things are
printed as a set, because that is what they are: the compiler takes the set of all values
of the type and removes the ones the branches list. For types with too many values to
list, a `case` must end with `else`.

Types that are "one of several things" exist in Nim as **object variants**: an object with a
`kind` field and different fields for each kind. This is how the syntax tree of Barlume is
written, in the parser post. Nimony's manual shows them with an example that looks
familiar:

```nim
proc area(s: Shape): float =
  case s.kind
  of Circle:
    PI * s.radius * s.radius
  of Rectangle:
    s.width * s.height
```

Compare it with Barlume's `area`. The `case` is on `s.kind`, an enum, and that part is
checked: the manual says "the case section must be exhaustive - all possible values of the
discriminator must be handled or an `else` has to be used". But the fields are reached with
a dot, `s.radius`, not handed out by a pattern. Nothing in the `case` itself ties `radius`
to the branch for `Circle`. In Nim 2, reading `s.radius` from a rectangle compiles, and
fails when the program runs.

That is the trade. A pattern that both tests and takes apart is a bigger language feature
and needs the algorithm of this post. A `case` over constants needs a set. Nimony's manual
gives its side of it in one sentence: "because case statements are checked for
exhaustiveness during semantic analysis, the value in every `of` branch must be a constant
expression".
"""

nbNote """
The Nim program above was compiled with Nim 2.2.4 and the message is what it printed. So
were two more: a value listed twice in a `case` ("duplicate case label"), and a field read
from the wrong variant, which compiled and stopped with a `FieldDefect` when run. The
quotes about Nimony are from its language manual at the commit linked in the sources. How
Nimony treats a field of the wrong variant was not checked, and nothing of Nimony was built
or run.
""", nkDone, "What was checked"

nbText: """
## What this changes for the port

- **The tree is output, not only a check.** The JavaScript that Gleam generates for a
  `case` is printed from this tree. The port must match that JavaScript byte for byte, so
  it must build the same tree: the same questions in the same order. The function that
  picks which variable to split on has to be ported exactly, not merely well.
- **The order of missing patterns is output too.** The error lists them, and the port has
  to list them in the same order.
- **Most of the step is bit arrays.** The idea of this post is a small part of the file.
  When the step comes up in the roadmap, the paper on binary data is the thing to read
  first.
- **Barlume has five stages**: `cases.nim` joined the others in
  `docs/devlog/data/barlume/`.

Next, and last: code generation. The tree is right. Time to make it run.

## Sources

- Gleam at the pinned commit:
  [`exhaustiveness.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/exhaustiveness.rs)
  (the module comment, `Decision`, `find_pivot_check`),
  [`exhaustiveness/missing_patterns.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/exhaustiveness/missing_patterns.rs),
  [`javascript/decision.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/javascript/decision.rs).
- Jules Jacobs, [How to compile pattern matching](https://julesjacobs.com/notes/patternmatching/patternmatching.pdf).
  Luc Maranget, [Compiling Pattern Matching to good Decision Trees](https://www.cs.tufts.edu/~nr/cs257/archive/luc-maranget/jun08.pdf).
  Per Gustafsson and Konstantinos Sagonas,
  [Efficient manipulation of binary data using pattern matching](https://user.it.uu.se/~kostis/Papers/JFP_06.pdf).
  Yorick Peterse, [pattern-matching-in-rust](https://github.com/yorickpeterse/pattern-matching-in-rust).
  These are the references of Gleam's source. The three papers could not be opened from the
  sandbox this was written in: the algorithm here was written from the description in
  Gleam's module comment and from its code.
- Nimony's language manual at commit `4ba90a7`:
  [`doc/language.md`](https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/doc/language.md)
  (the sections "Case in object" and "Case statement").
- Earlier parts: [What a lexer is](../what-a-lexer-is/), [What a parser is](../what-a-parser-is/),
  [Names and scopes](../names-and-scopes/), [What a type checker is](../what-a-type-checker-is/).
"""

nbSave
