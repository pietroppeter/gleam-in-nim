## devlog: 12 Nov 2026 D | Elm, the other parent | What Gleam took from Elm: a small language, inferred types and a compiler that talks like a person. And what it left behind.
## kind: research
import std/[os, strutils, sequtils, tables]
import nimib
import ../blocks

nbInit
nb.usePost()

# The Gleam programs and compiler messages quoted on this page are files next to it
# (docs/devlog/data/elm_roots/cases); `sh docs/devlog/data/elm_roots/regenerate.sh` rebuilds them.
const data = currentSourcePath().parentDir / "data" / "elm_roots" / "cases"

proc fence(lang, text: string): string =
  ## A Markdown fenced code block.
  "\n```" & lang & "\n" & text.strip(leading = false) & "\n```\n"

proc source(name: string): string {.compileTime.} =
  fence("gleam", staticRead(data / name & ".gleam"))

proc says(name: string): string {.compileTime.} =
  ## What Gleam 1.19.2 answered when asked to check the case.
  let output = staticRead(data / name & ".out.txt").strip
  fence("text", if output.len > 0: output else: "(no errors, no warnings)")

nbText: """
## The short version

- Gleam is often introduced as "an Elm for the BEAM". The [first post](../the-beam/) covered
  the BEAM half. This one covers the Elm half: where the feel of the language comes from.
- Elm's lasting gift to programming is an attitude: **the compiler is an assistant, not an
  adversary**. Its 2015 error messages changed what people expect from a compiler. Rust adopted
  the idea in 2016 and said so. Gleam's error rendering comes from the Rust side of that family.
- From Elm, Gleam took: full type inference with no annotations required, custom types and
  exhaustive pattern matching, no null, no exceptions as a way to handle errors, one official
  formatter, a small language that says no to features.
- Gleam left behind: currying, structural records, the last traces of type classes, and the
  closed door to the host platform. And it kept something Elm rejects: a program may crash, on
  purpose, because on the BEAM a crash is a tool.
- For the port, the type system is good news. It is Hindley-Milner at its plainest: four kinds of
  type, one `unify`, generalisation only at top level functions. A working sketch in Nim is on
  this page, and it runs.
- The bad news is that **the error messages are part of the specification**. The wording, the
  underlined span, the hint: the reference compiler tests all of it, and so must we.

## Elm in six dates

| Year | What happened |
|---|---|
| 2012 | Evan Czaplicki's thesis at Harvard: Elm, a language for web interfaces where the interface is a pure function of values that change over time |
| 2015 | *Compiler Errors for Humans* (0.15.1) and *Compilers as Assistants* (0.16): the error messages that made Elm famous |
| 2016 | *A Farewell to FRP* (0.17): the academic idea is dropped for something simpler, The Elm Architecture |
| 2018 | 0.19: smaller and faster output, and JavaScript interop restricted to "ports" for everyone outside the core team |
| 2019 | 0.19.1, then seven years without a release: the language stays as it is, stable and in use |
| 2026 | 0.19.2 in July and 0.19.3 in October: Elm is moving again, on a stated road to 1.0 |

Elm stayed small on purpose: several releases removed more than they added. That is unusual,
and it is the first thing Gleam inherited: the Gleam FAQ has a list of features that will never be added, and
it reads like Elm's.

## What Elm promises

Elm made a short list of promises and built the whole language to keep them:

- **No runtime exceptions in practice.** There is no `null`: a value that may be missing has
  type `Maybe`. There are no exceptions: a computation that may fail returns a `Result`. The
  compiler makes you handle both cases, every time.
- **Every `case` covers every case.** Add a variant to a type and the compiler lists every
  place that must now deal with it. Refactoring becomes following a list.
- **Types are inferred.** You may write annotations, and people do, as documentation. The
  compiler never needs them.
- **Versions mean something.** The package manager compares the types of two releases and
  enforces semantic versioning: an API change that breaks callers is a major version, or it is
  not published.
- **One architecture.** A program is a `Model`, a type of messages `Msg`, a function
  `update : Msg -> Model -> Model` and a `view`. Redux, in JavaScript, is this idea carried over.

Look at `update` again with the first post in mind. A state, a custom type of messages, a
function from one message and the old state to the new state. It is the counter actor: the
handler in Gleam was `fn handle(count: Int, message: Message)`. The Elm Architecture and an OTP
process are the same shape, found twice by people solving different problems. No wonder the two
traditions fit in one language. (Gleam's main web framework, Lustre, by Hayleigh Thompson, is
The Elm Architecture in Gleam, on the server as well as in the browser.)

## The compiler as an assistant

In June 2015 Evan Czaplicki wrote that most compiler error messages are bad, that this is a user
experience problem and not a law of nature, and that you can make "a shockingly huge difference
just by thinking about the user experience". The recipe, then and now:

1. **Show the code**, the exact lines, with the exact part underlined. Not a line number to go
   and find.
2. **Say what was expected and what was found**, as types set apart on their own lines.
3. **Speak like a person**, in full sentences, in the first person. "I cannot find...", "I am
   having trouble with...".
4. **Give a hint** when a common mistake is recognised, and suggest names when one looks like a
   typo.
5. **Never show more than helps.** No cascade of forty errors caused by the first one.

This is an Elm message from last month's release post, for modules that import each other:

```text
-- IMPORT CYCLE ----------------------------------------------------------------

Your module imports form a cycle:

    ┌─────┐
    │    User
    │     ↓
    │    Post
    │     ↓
    │    Blog
    └─────┘

Learn more about why this is disallowed and how to break cycles here:
https://elm-lang.org/0.19.3/import-cycles
```

The idea travelled fast. In August 2016 the Rust team announced a new error format in *Shape of
errors to come*, with the sentence: "Those of you familiar with the Elm style may recognize that
the updated `--explain` messages draw heavy inspiration from the Elm approach." Rust then made
the idea standard for a generation of languages: labelled spans drawn on the source, error
codes, suggestions the editor can apply.

Gleam sits downstream of both. Its 1.0 announcement names the type systems of "Elm, OCaml, and
Rust" and says the compiler "serves as a programming assistant". Its FAQ says the developer
tooling was "inspired in-part by Rust's". And in the source you can see the family tree: the
frames around the code are drawn by `codespan-reporting`, a Rust library in rustc's style, and
the function that proposes "did you mean" is a copy of rustc's edit distance, with a comment
saying so.

Here is the result. A program with one mistake:
""" & source"mismatch" & says"mismatch" & """

Code shown, span underlined, expected and found on their own lines. A typo:
""" & source"typo" & says"typo" & """

And one where the compiler knows what you probably meant:
""" & source"floatop" & says"floatop" & """

Two things to notice in that last one. The hint: Gleam has separate operators for floats, the
compiler knows people forget, and it tells them. And there are **two errors**: the compiler did
not stop at the first. Since version 1.2 (May 2024) Gleam's analysis is fault tolerant: when an
expression is wrong, it records the problem, assumes a plausible type, and carries on, so that
the language server still knows the types of everything else in a file you are half way through
editing. For us this is a design constraint from day one: the checker cannot be written as
"raise on the first error".

## Types: Hindley-Milner, the plain kind

Elm and Gleam infer types with the same idea, half a century old and named after Hindley and
Milner.
It fits on a page, so here it is, in Nim, modelled on the data types of the Gleam compiler
(`compiler-core/src/type_.rs`). This code runs when this page is built.

A type is a named type with arguments (`Int`, `List(Int)`), a function type, or a **type
variable**: a type we do not know yet. A variable is a mutable cell in one of three states,
and the names are Gleam's own: `Unbound` (unknown so far), `Link` (we found out, look over
there), `Generic` (it can be anything, for ever).
"""

nbCode:
  type
    VarState = enum Unbound, Link, Generic
    TypeKind = enum Named, Fn, Var
    Type = ref object
      case kind: TypeKind
      of Named:
        name: string
        args: seq[Type]
      of Fn:
        params: seq[Type]
        ret: Type
      of Var:
        state: VarState  # changes in place: this is how the checker learns
        id: int
        link: Type       # where a Link points
    TypeError = object of CatchableError

  var nextId = 0
  proc fresh(): Type =
    inc nextId
    Type(kind: Var, state: Unbound, id: nextId)
  proc named(name: string, args: varargs[Type]): Type =
    Type(kind: Named, name: name, args: @args)
  proc fn(params: openArray[Type], ret: Type): Type =
    Type(kind: Fn, params: @params, ret: ret)
  let Int = named"Int"
  let String = named"String"

  proc resolve(t: Type): Type =
    ## Follow the links to what a variable turned out to be.
    if t.kind == Var and t.state == Link: resolve(t.link) else: t

nbText: """
(The real compiler has a fourth kind, tuples, which behave like a named type. Printing types is
left out of the page: generic variables print as `a`, `b`, and unknown ones as `?1`, `?2`.)
"""

var letters: Table[int, char]
proc `$`(t: Type): string =
  let t = resolve(t)
  case t.kind
  of Named: t.name & (if t.args.len > 0: "(" & t.args.mapIt($it).join(", ") & ")" else: "")
  of Fn: "fn(" & t.params.mapIt($it).join(", ") & ") -> " & $t.ret
  of Var:
    if t.state == Generic: $letters.mgetOrPut(t.id, chr(ord('a') + letters.len))
    else: "?" & $t.id

nbText: """
The engine is **unification**: given two types that must be the same, make them the same, by
filling in variables, or fail. Every rule of the language reduces to calls of `unify`. "The
argument of `add_one` must be an `Int`" is `unify(Int, typeOfTheArgument)`.
"""

nbCode:
  proc occurs(v, t: Type): bool =
    ## Is the variable `v` inside the type `t`?
    let t = resolve(t)
    case t.kind
    of Var: t == v
    of Named: t.args.anyIt(occurs(v, it))
    of Fn: t.params.anyIt(occurs(v, it)) or occurs(v, t.ret)

  proc unify(expected, found: Type) =
    let (a, b) = (resolve(expected), resolve(found))
    if a == b: return
    if a.kind == Var and a.state == Unbound:
      if occurs(a, b): raise newException(TypeError, "Recursive type")
      a.state = Link  # now we know
      a.link = b
    elif b.kind == Var and b.state == Unbound:
      unify(b, a)
    elif a.kind == Named and b.kind == Named and a.name == b.name and a.args.len == b.args.len:
      for (x, y) in zip(a.args, b.args): unify(x, y)
    elif a.kind == Fn and b.kind == Fn and a.params.len == b.params.len:
      for (x, y) in zip(a.params, b.params): unify(x, y)
      unify(a.ret, b.ret)
    else:
      raise newException(TypeError, "Type mismatch. Expected type: " & $a & ". Found type: " & $b)

nbText: """
Watch it infer the type of `fn(x) { x + 1 }`. The parameter starts unknown. The body uses `+`,
which wants `Int`, and that one fact fills in the hole:
"""

nbCode:
  let x = fresh()
  let addOne = fn([x], Int)
  echo "before: ", addOne
  unify(Int, x)
  echo "after:  ", addOne

nbText: """
Nobody went back to update `addOne`. It held a reference to the cell, and the cell changed.
That is the entire mechanism, and Nim's `ref object` is a natural fit for it (the Rust original
needs `Arc<RefCell<...>>` to say the same thing).

### Generic functions

What about `fn(x) { x }`? After checking the body, `x` is still unbound: nothing forced it to
be anything. If we leave it like that, the first caller decides for everyone:
"""

nbCode:
  proc attempt(what: string, check: proc()) =
    try:
      check()
      echo what, ": ok"
    except TypeError as e:
      echo what, ": ", e.msg

  block:
    let x = fresh()
    let id = fn([x], x)
    attempt "id(1)", proc() = unify(id, fn([Int], fresh()))
    attempt "id(\"one\")", proc() = unify(id, fn([String], fresh()))

nbText: """
The fix is two small steps. **Generalise**: when a function is finished, whatever is still
unbound becomes `Generic`. **Instantiate**: every use of the function gets a copy of its type
with fresh variables in place of the generic ones.
"""

nbCode:
  proc generalise(t: Type) =
    let t = resolve(t)
    case t.kind
    of Var: (if t.state == Unbound: t.state = Generic)
    of Named: (for x in t.args: generalise(x))
    of Fn:
      for x in t.params: generalise(x)
      generalise(t.ret)

  proc instantiate(t: Type, copies: var Table[int, Type]): Type =
    let t = resolve(t)
    case t.kind
    of Var: (if t.state == Generic: copies.mgetOrPut(t.id, fresh()) else: t)
    of Named: named(t.name, t.args.mapIt(instantiate(it, copies)))
    of Fn: fn(t.params.mapIt(instantiate(it, copies)), instantiate(t.ret, copies))

  proc instantiate(t: Type): Type =
    var copies: Table[int, Type]
    instantiate(t, copies)

  block:
    let x = fresh()
    let id = fn([x], x)
    generalise(id)
    echo "id: ", id
    attempt "id(1)", proc() = unify(instantiate(id), fn([Int], fresh()))
    attempt "id(\"one\")", proc() = unify(instantiate(id), fn([String], fresh()))

nbText: """
Now the interesting part: **when** does Gleam generalise? Only at top level functions. The
sketch above predicts what the real compiler does. A top level `id` is generic:
""" & source"toplevelpoly" & says"toplevelpoly" & """

The same function bound with `let` is not generalised, so the first use fixes its type, exactly
like the first run of our sketch:
""" & source"letpoly" & says"letpoly" & """

Elm and OCaml do generalise `let`. Gleam does not, and its checker is simpler for it: there is
no need for the "levels" that track which variables may be generalised inside nested scopes.
What it needs instead is an order: the functions of a module are sorted by who calls whom
(`call_graph.rs`), mutually recursive ones are inferred together as a group, and each group is
generalised when it is done.

And `occurs`, the check that a variable is not inside the type it is being linked to? Without
it, unification would build an infinite type. With it:
"""

nbCode:
  block:
    let x = fresh()
    attempt "loop([x])", proc() = unify(x, named("List", x))

nbText: source"recursive" & says"recursive" & """

### Every case, checked

The second pillar is exhaustiveness: a `case` must cover every value of the type.
""" & source"exhaustive" & says"exhaustive" & """

Note that the message lists the missing patterns as Gleam code you could paste. Computing that
is its own algorithm, unrelated to inference: the patterns are compiled into a **decision tree**
(after Luc Maranget and Jules Jacobs, credited at the top of `exhaustiveness.rs`), and a path
that reaches no branch is a missing pattern. Gleam's checking became complete with this
algorithm in version 0.33, December 2023. The
same tree is then used by the code generators to emit efficient tests, so it is not optional
decoration: it is 4,450 lines in the middle of the pipeline.

## What Gleam kept and what it left

| | Elm | Gleam |
|---|---|---|
| Inference | complete, annotations optional | the same, without `let` generalisation |
| Custom types, exhaustive `case` | yes | yes |
| `null`, exceptions for errors | no: `Maybe`, `Result` | no: `Option`, `Result` |
| Type classes | none for users, but built-in `number`, `comparable`, `appendable` | none at all: `+` for `Int`, `+.` for `Float`, `<>` for `String` |
| Records | structural, extensible (`{ r \| name : String }`) | nominal: a record is a custom type with labelled fields |
| Functions | curried, one argument at a time | not curried; labelled arguments and `_` captures |
| Foreign code | ports only, by design | `@external`, anywhere, trusted |
| Crashing | a bug in Elm itself | `let assert`, `panic`, `todo`: allowed and explicit |
| Side effects | managed: commands and subscriptions | unmanaged, as in OCaml or Erlang |
| Syntax | ML family, whitespace | braces, familiar to C, Rust and JavaScript people |
| Formatter | `elm-format`, community, universal | `gleam format`, built in |
| Targets | JavaScript | Erlang and JavaScript |

Each row on the Gleam side is a simplification or a concession to the platform, and they explain
each other. Without type classes there can be no generic `+`, hence `+.`. Without type classes
and without row types, `unify` only ever compares names and arities, which is why the sketch
above is so short. The open door to Erlang and JavaScript is what makes a young language useful
on day one, at the price that an external's type is a promise the compiler cannot check.

The deepest difference is about failure. Elm's promise is that a program does not crash. Gleam's
is that it does not crash **by accident**: there are no hidden exceptions and no nulls, but
`let assert` says "if this is not so, this process should die", and a supervisor is there to
restart it. That is Elm's discipline with the BEAM's safety net: two ideas of reliability that
turn out to compose.

"""

nbNote """
**Checked on this page:** the Gleam programs and messages are files, produced by
`regenerate.sh` with Gleam 1.19.2; the Nim sketch runs when the page is built and its output is
what you read; the quotes of Elm, Rust and Gleam posts were read in the sources of their sites;
the claims about the compiler were read in its source at v1.19.2.

**Not checked:** no Elm compiler was run here, so the Elm column of the comparison table is
from the Elm guide and from memory. The sketch is a teaching model of `unify`, not a port: the
real one also carries error context, tuples, and the variants of custom types.
""", nkDone, "What was verified"

nbText: """
## What this changes for the port

1. **Messages are specification.** The reference compiler's tests are snapshots of full error
   text. We need a diagnostic renderer in Nim that matches `codespan-reporting` to the character
   (frames, line numbers, underlines, multi-line spans), the type printer that names variables
   `a`, `b`, and the edit distance for "did you mean". These are small, testable and early.
2. **Fault tolerance is architecture.** The checker returns a typed tree **and** a list of
   problems (`Problems` in `type_/error.rs` collects errors and warnings). A wrong expression
   becomes an "invalid" node with a fresh type variable. No exceptions for control flow.
3. **Inference ports naturally.** `Type` as a `ref object` with a mutable variable state, as in
   the sketch. Four kinds of type. No levels. Generalise per call graph group. The surrounding
   machinery is larger than the idea: `type_/expression.rs` alone is 5,385 lines, most of it
   error cases and their hints.
4. **Exhaustiveness is a component of its own,** shared by the checker (missing and unreachable
   patterns) and by the backends (decision trees). It deserves its own step and explainer.
5. **What we do not have to build:** type classes, higher kinded types, row polymorphism,
   `let` generalisation, effect tracking for users. The type system is deliberately small.
   Thank you, Elm.

## Sources

- Evan Czaplicki, [Compiler Errors for Humans](https://elm-lang.org/news/compiler-errors-for-humans) (2015),
  [Compilers as Assistants](https://elm-lang.org/news/compilers-as-assistants) (2015),
  [A Farewell to FRP](https://elm-lang.org/news/farewell-to-frp) (2016),
  [Faster Builds](https://elm-lang.org/news/faster-builds) and
  [Another step towards Elm v1](https://elm-lang.org/news/another-step-towards-elm-v1) (2026).
  Dates and quotes checked in the [site's source](https://github.com/elm/elm-lang.org).
- Sophia June Turner, [Shape of errors to come](https://blog.rust-lang.org/2016/08/10/Shape-of-errors-to-come/) (Rust blog, 2016).
- Gleam: [Gleam version 1](https://gleam.run/news/gleam-version-1/) (2024),
  [Fault tolerant Gleam](https://gleam.run/news/fault-tolerant-gleam/) (2024),
  [Exhaustive Gleam](https://gleam.run/news/v0.33-exhaustive-gleam/) (2023),
  the [FAQ](https://gleam.run/frequently-asked-questions/) and
  [Gleam for Elm users](https://gleam.run/cheatsheets/gleam-for-elm-users/).
- The Gleam compiler at v1.19.2: `compiler-core/src/type_.rs`, `type_/environment.rs` (`unify`),
  `type_/error.rs`, `error.rs` (`edit_distance`, `did_you_mean`), `exhaustiveness.rs`, `call_graph.rs`.
- Luc Maranget, [Compiling Pattern Matching to good Decision Trees](https://www.cs.tufts.edu/~nr/cs257/archive/luc-maranget/jun08.pdf) (2008);
  Jules Jacobs, [How to compile pattern matching](https://julesjacobs.com/notes/patternmatching/patternmatching.pdf).
- [Lustre](https://github.com/lustre-labs/lustre), The Elm Architecture in Gleam.
- The cases of this page: `docs/devlog/data/elm_roots/` in the repository.
"""

nbSave
