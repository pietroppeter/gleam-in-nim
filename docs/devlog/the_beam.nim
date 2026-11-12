## devlog: 12 Nov 2026 C | The BEAM, explained | What Erlang's virtual machine is, how actors really work, and what the Gleam compiler hands to it.
## kind: research
import std/[os, strutils]
import nimib
import ../blocks

nbInit
nb.usePost()

# Everything quoted on this page is read from files next to it (docs/devlog/data/the_beam):
# the Gleam sources, what Gleam 1.19.2 generated from them, and what the programs printed.
# `sh docs/devlog/data/the_beam/regenerate.sh` rebuilds them.
const data = currentSourcePath().parentDir / "data" / "the_beam"

proc file(path: string): string {.compileTime.} =
  staticRead(data / path).strip(leading = false)

proc fence(lang, text: string): string =
  ## A Markdown fenced code block.
  "\n```" & lang & "\n" & text.strip(leading = false) & "\n```\n"

proc cut(text, first, stop: string): string =
  ## The part of `text` from the line that starts with `first` up to the line that starts with `stop`.
  var on = false
  for line in text.splitLines:
    if not on and line.startsWith(first): on = true
    elif on and stop.len > 0 and line.startsWith(stop): break
    if on: result.add line & "\n"
  doAssert result.len > 0, "nothing starts with: " & first

const
  shapesGleam = file"gleam/roots/src/shapes.gleam"
  shapesErl = file"generated/erlang/shapes.erl"
  shapesJs = file"generated/javascript/shapes.mjs"
  shapesAbstr = file"generated/erlang/shapes.abstr.txt"
  clockGleam = file"gleam/roots/src/clock.gleam"
  clockErl = file"generated/erlang/clock.erl"
  counterGleam = file"gleam/counter/src/counter.gleam"
  counterDemoErl = file"generated/erlang/counter_demo.erl"
  runErlang = file"generated/erlang/run.out.txt"
  runJs = file"generated/javascript/run.out.txt"

nbText: """
## The short version

- Erlang was built in the late 1980s at Ericsson to run telephone exchanges: thousands of things
  happening at once, on machines that must never stop, with software that will have bugs. The
  BEAM is the virtual machine that runs it.
- Its one big idea: a program is many tiny **processes** that share nothing and talk only by
  **sending messages**. A crash kills one process, not the program, and another process is told
  about it and decides what to do. That is the actor model, and it is simpler than its reputation.
- The BEAM does not know about types. It runs modules of functions over a small set of values:
  atoms, numbers, binaries, tuples, lists, maps, functions, process ids. A language "on the BEAM"
  is a compiler that turns its own ideas into those.
- Gleam turns a custom type into a tagged tuple, a `String` into a UTF-8 binary, a `case` into an
  Erlang `case`, a module `gleam/list` into the Erlang module `gleam@list`. Its types are checked
  and then erased: almost nothing of them survives in the output.
- Since version 1.19 (October 2026) the build tool no longer writes Erlang source. It writes
  **Erlang abstract forms**, the Erlang compiler's own syntax tree, in a binary format. The
  textual `.erl` output still exists, behind the same interface, and is what the compiler's tests
  compare against. Our port has two Erlang outputs to write, not one.
- Typed message passing is **not in the Gleam language**. It is a library, built from functions
  the compiler knows nothing special about. The port does not need to implement actors, only
  externals.

Every piece of code and output below is read from a file that sits next to this page: the Gleam
sources, what Gleam 1.19.2 generated from them, and what the programs printed when run.

## A telephone company's problem

In 1986 Joe Armstrong, at Ericsson's Computer Science Laboratory in Stockholm, was looking for a
better way to program telephone exchanges. An exchange handles a huge number of calls at once,
each call mostly waiting. It cannot be switched off to fix a bug or install a new version. And its
hardware fails, its software has errors, and neither is allowed to take the other calls down.

He started by adding concurrency to Prolog, and with Robert Virding and Mike Williams the
experiment became a language of its own.

| Year | What happened |
|---|---|
| 1986 | First experiments, as an interpreter written in Prolog |
| around 1990 | JAM, "Joe's Abstract Machine": the first real virtual machine |
| early 1990s | Bogumil Hausman writes a faster machine, the BEAM, which replaces JAM |
| 1996 | OTP, the libraries and design rules for building whole systems, is released |
| 1998 | The AXD301 switch ships with over a million lines of Erlang; Ericsson open sources Erlang |
| 2006 | The BEAM learns to use all the cores of a machine, with no change to programs |
| 2012 | Elixir, by José Valim, brings a new language and new people to the BEAM |
| 2019 | Gleam 0.1, by Louis Pilfold: static types on the BEAM |
| 2021 | The BEAM gets a JIT compiler (OTP 24) |
| 2024 | Gleam 1.0 |

The design that came out of the telephone problem turned out to fit the internet very well: chat
servers, message queues, databases, web servers. WhatsApp famously served hundreds of millions of
people with a few dozen engineers on it.

## The BEAM for a five year old

Imagine a town where everybody works alone at their own desk, and **nobody can ever touch anybody
else's desk**. If you want something from someone, you write a note and drop it in their letter
box. They read their notes one at a time, when they get to them. Maybe they write back.

Sometimes someone gets a note they cannot make sense of, panics, and faints. Nothing else in town
breaks, because nobody was leaning on their desk. Their manager gets an automatic note saying
"your worker fainted, here is why", and usually just puts a fresh worker at a clean desk.

That is all of it. The workers are processes, the letter boxes are mailboxes, the notes are
messages, the managers are supervisors, and the town is the BEAM, which makes sure everyone gets
a fair turn to work.

## Actors, properly

Now the same thing in running code. These are plain Erlang, run on the BEAM in this sandbox.

### A process is a function that is running

`spawn` starts a function as a new process and returns its address, a **pid**. `!` sends a
message to a pid. `receive` waits for a message and pattern matches on it.
""" & fence("erlang", file"erlang/ping.erl") & fence("text", file"erlang/ping.out.txt") & """

Sending never waits: the message is copied into the other mailbox and the sender moves on. If you
want an answer, you put your own pid in the message (`From`) and then wait for a reply yourself.
A "call" is just two sends and a wait.

### State is the argument of a loop

Nothing is mutable in Erlang, so where does an actor keep its state? In the argument of a
function that calls itself for ever. Each message produces the next state.
""" & fence("erlang", file"erlang/counter.erl") & fence("text", file"erlang/counter.out.txt") & """

This is the whole trick. The counter handles one message at a time, so there are no locks and no
data races: nobody else can see `Count`, they can only ask for it. The recursive call is the last
thing the function does, and the BEAM does not grow the stack for such calls, so the loop can run
for years.

### The mailbox is a queue you can search

`receive` does not simply take the oldest message. It takes the oldest message **that matches
one of its patterns** and leaves the rest where they are.
""" & fence("erlang", file"erlang/mailbox.erl") & fence("text", file"erlang/mailbox.out.txt") & """

This matters later: it is how Gleam gives messages a type.

### Processes are cheap

A BEAM process is not an operating system thread. It is a small piece of memory managed by the
virtual machine: its own stack, its own heap, its own garbage collector.
""" & fence("erlang", file"erlang/many.erl") & fence("text", file"erlang/many.out.txt") & """

So the unit of design is small. One process for each phone call, each connected user, each open
socket, each game, each job. A few schedulers (one per core) run them all, and they are
**preemptive**: every process gets a budget of work (function calls, roughly) and is paused when
it is spent, so one busy process cannot starve the others. Because heaps are private, collecting
the garbage of one process does not pause the rest.

### Failure is a message

A process that hits an error it has no code for simply dies. What makes this a design and not an
accident is that other processes can ask to be told.
""" & fence("erlang", file"erlang/crash.erl") & fence("text", file"erlang/crash.out.txt") & """

A **monitor** delivers a `'DOWN'` message. A **link** is stronger: linked processes die together,
unless one of them has asked to receive the exit as a message instead. From these two you build a
**supervisor**: a process whose only job is to start workers, watch them, and restart them when
they die. This is "let it crash": do not write code for errors you cannot handle here, let the
process die, and let a supervisor return the system to a state that is known to be good.

### OTP is these patterns, written once

Nobody writes those loops by hand. OTP ships them: `gen_server` is the counter loop with the
reply protocol, timeouts and debugging built in, and `supervisor` is the restarting manager.
Here a supervisor restarts a small server (`tally`, a `gen_server` that adds numbers) after we
send it something that is not a number.
"""

nbFold "The supervisor and the server, in Erlang":
  nbText: fence("erlang", file"erlang/sup_demo.erl") & fence("erlang", file"erlang/tally.erl")

nbText: fence("text", file"erlang/sup_demo.out.txt") & """

Same name, new process, clean state. The caller's mistake cost one worker its memory, nothing
else.

### What the model promises, and what it does not

- Messages between two given processes arrive in the order they were sent.
- A send does not fail and does not wait, even if the receiver is gone. If you need to know, you
  monitor and you use timeouts.
- Mailboxes have no size limit. A process that receives faster than it works will eat memory.
- Processes can be on different machines. A pid works the same across the network, which is why
  the "no shared memory" rule was there from the start.

## What the BEAM is to a compiler writer

Forget processes for a moment. For a compiler, the BEAM is a place where code lives in
**modules**, a module is a set of **functions** known by name and number of arguments
(`area/1`), and a function takes and returns **terms**:

| Term | Looks like | Notes |
|---|---|---|
| atom | `ok`, `circle` | a name that stands for itself |
| integer | `42` | as big as you like |
| float | `3.14` | 64 bits |
| binary | `<<"hello"/utf8>>` | bytes; a bit string when not a whole number of bytes |
| tuple | `{circle, 1.0}` | fixed size |
| list | `[1, 2, 3]` | linked |
| map | `#{name => 1}` | key and value |
| fun | `fun(X) -> X end` | a closure |
| pid, reference | `<0.79.0>` | a process address; a unique token |

There are no classes, no objects, no static types, no null. Everything is immutable. Pattern
matching, tail calls and bit-level binary matching are built into the machine, which is very
convenient for a functional language: Gleam's `case` has a direct target.

Erlang's own compiler goes through several stages, and a new language can join at any of them:

| Stage | What it is | Who enters here |
|---|---|---|
| Erlang source | text in `.erl` files | Gleam before 1.19 |
| Abstract forms | the syntax tree as Erlang terms | Elixir, Gleam from 1.19 |
| Core Erlang | a smaller functional language | LFE (Lisp Flavoured Erlang) |
| BEAM assembly, `.beam` | what the machine loads | Erlang's compiler does this for everyone |

Almost nobody writes `.beam` files directly: joining early means the Erlang compiler's checks and
optimisations are free.

## How Gleam lives on the BEAM

Here is a small Gleam module, written to touch as much of the code generator as it can.
""" & fence("gleam", cut(shapesGleam, "pub const pi", "pub fn describe")) & """
And this is what Gleam 1.19.2 generates for it as Erlang source:
""" & fence("erlang", cut(shapesErl, "-type shape", "-spec describe")) & """

A whole design is visible in those few lines:

| Gleam | Erlang | From the example |
|---|---|---|
| constructor with fields | tuple tagged with an atom in snake_case | `Circle(1.0)` is `{circle, 1.0}` |
| constructor without fields | the atom alone | `Dot` is `dot` |
| labels | gone, only the position is left | `radius:` is slot 2 |
| `True`, `False`, `Nil` | `true`, `false`, `nil` | |
| `Ok(x)`, `Error(e)` | `{ok, X}`, `{error, E}` | the shape all Erlang code uses |
| `String` | UTF-8 binary | `"circle"` |
| `List`, tuples | list, tuple | `#(a, b)` is `{A, B}` |
| module `gleam/list` | module `gleam@list` | |
| type annotations | `-spec` and `-type`, for Erlang's tools | never checked at run time |
| a public constant | inlined where it is used | `pi` became `3.14159` |

Types are erased, but representation is not arbitrary: `Result` compiling to `{ok, X}` and
`{error, E}` is what lets Gleam call Erlang libraries, and be called by Erlang and Elixir, with
no conversion at the border.

The rest of the module shows how the larger constructs are lowered.
""" & fence("gleam", cut(shapesGleam, "pub fn parse", "fn sum")) & fence("erlang", cut(shapesErl, "-spec parse", "-spec sum")) & """

- A **pipe** becomes a chain of assignments to variables named `_pipe`.
- **`use`** is only sugar: the rest of the block becomes an anonymous function passed as the last
  argument.
- Erlang variables can be assigned once, Gleam names can be reused, so the second `size` becomes
  `Size@1`. The code generator has to keep count.
- `int.parse` and `int.to_float` are not calls into Gleam's standard library any more: they were
  declared there as externals, so the compiler calls the Erlang functions directly
  (`gleam_stdlib:parse_int`, `erlang:float`).

Things that can fail at run time are spelled out as well.
""" & fence("gleam", cut(shapesGleam, "pub fn greeting", "pub fn make_adder") & cut(shapesGleam, "pub fn safe_divide", "pub fn header")) & fence("erlang", cut(shapesErl, "-spec greeting", "-spec make_adder") & cut(shapesErl, "-spec safe_divide", "-spec header")) & """

`let assert` is a `case` whose second branch raises an Erlang error carrying a map: the file, the
line, the offsets of the pattern in the source. Every one of those numbers has to come out of our
port exactly. And integer division checks for zero first, because in Gleam `7 / 0` is `0`, and an
exception is not an option.

### Externals: the door to the platform

Gleam has no built-in way to read the clock, print, or spawn a process. It has `@external`,
which says "this function is that Erlang function" (or that JavaScript one).
""" & fence("gleam", clockGleam) & fence("erlang", cut(clockErl, "-spec now", "")) & """

The whole standard library, and everything about processes, comes through this door. For the
compiler an external is cheap: check the declared type, trust it, emit a call.

### Since 1.19: abstract forms

All of the Erlang above came from `gleam compile-package --no-beam`. What `gleam build` writes
today is a file `shapes.abstr`: the same module as a tree of Erlang terms, serialized in Erlang's
External Term Format. This is `area` again, decoded and printed:
""" & fence("erlang", cut(shapesAbstr, "{function,", "")) & """

The numbers are **line numbers of the Gleam source**, which is the point: a crash on the BEAM now
points at the right line of the `.gleam` file. Louis Pilfold's release post names Giacomo
Cavalieri as the author of the rewrite and gives the reasons: faster builds, exact locations, and
never hearing the word "transpiler" again. In the compiler both outputs sit behind one interface
(`ErlangBuilder`, in the crate `erlang-generation`), with a source builder and a binary builder.

### The same module as JavaScript

Gleam has a second target, and the comparison shows what is language and what is platform.
""" & fence("javascript", cut(shapesJs, "export class Circle", "export class Rectangle") & "\n" & cut(shapesJs, "export function area", "export function describe") & "\n" & cut(shapesJs, "function sum", "export function total_area")) & """

A constructor is a class, `case` is a chain of `instanceof`, and since JavaScript has no tail
calls, the recursive `sum` is rewritten into a `while (true)` loop. On the BEAM none of that is
needed. The program prints almost the same thing on both, and the difference is instructive. On
the BEAM:
""" & fence("text", runErlang) & """
On Node.js:
""" & fence("text", runJs) & """

`echo` shows field labels on JavaScript, where they are properties of the object, and cannot on
Erlang, where a record is a tuple. And `4.0` prints as `4` where every number is a float. Our
tests will have to compare per target.

## Typed actors without touching the compiler

Erlang lets you send anything to anyone. How does a typed language live with that? Gleam's answer
is in a library, `gleam_erlang`. You do not send to a pid, you send to a **`Subject(message)`**:
a pid plus a unique tag, with the message type as a type parameter. `send` wraps your message as
`{Tag, Message}`, and `receive` uses the selective receive we saw above to take only messages
with that tag. The type parameter does the rest: the compiler will not let you send a `String`
to a `Subject(Int)`.

Here is the counter again, in Gleam, using the `actor` module of `gleam_otp`:
""" & fence("gleam", counterGleam) & """

Replying is typed too. `Get` carries a `Subject(Int)`: the caller makes a fresh subject, puts it
in the message, and waits on it. The client side compiles to this:
""" & fence("erlang", cut(counterDemoErl, "main() ->", "        _value@1")) & """

Compare it with the Erlang counter: `{increment, 2}` and `stop` are the very same messages we
wrote by hand. And it runs:
""" & fence("text", file"generated/erlang/counter_run.out.txt") & """

Gleam's actor is not a wrapper around `gen_server`. It is the same loop written again in Gleam,
speaking OTP's system messages, so it fits under Erlang supervisors and shows up in Erlang's
tools. On JavaScript none of this exists, and the compiler says so: a public function that needs
an Erlang-only external is rejected with *Unsupported target* when you build for JavaScript.

"""

nbNote """
**Checked on this page:** every listing and output is a file produced by `regenerate.sh` with
Gleam 1.19.2, Erlang/OTP 25 and Node.js 22, and the claims about the compiler were read in its
source at v1.19.2.

**Not checked:** the history. erlang.org could not be reached from the sandbox, so the dates of
the table come from Joe Armstrong's *A History of Erlang* as remembered, not re-read; treat the
"around" and "early" as honest.
""", nkDone, "What was verified"

nbNote """
`gleam build` and `gleam test` for the Erlang target need OTP 27 or newer, and the sandbox has
25. The detour through abstract forms is enough to run programs, not to run Gleam's own test
suites. A newer OTP in the environment's setup script would remove the detour.
""", nkQuestion, "Open: a newer OTP"

nbText: """
## What this changes for the port

1. **Two Erlang outputs.** Textual `.erl` first: it is readable, it is what the reference
   compiler's snapshot tests contain, and we can diff it. The binary abstract forms come second:
   a second implementation of the same builder interface plus an encoder for the External Term
   Format (small: 255 lines of Rust in `erlang-term-format`).
2. **The mapping tables above are a checklist** for the Erlang backend: tagged tuples, atoms for
   empty constructors, `@` in module names, `_pipe` variables, `Name@1` renaming, `-spec`
   generation, record `.hrl` files for Erlang callers, error maps with source offsets, guarded
   division, external calls made directly.
3. **No concurrency in the compiler.** Processes, subjects and actors are libraries on top of
   `@external`. What the compiler must get right is externals: per-target implementations,
   Gleam fallbacks, and tracking which functions exist on which target.
4. **Verification can run real programs.** The reference `gleam` binary runs in our sandbox and
   so does the BEAM. The sandbox has Erlang/OTP 25 and Gleam 1.19 expects 27 or newer, so
   `gleam build` does not work here as is; the abstract forms do compile, with the small
   script kept with this page (it drops the documentation attributes that OTP 25 refuses). So we
   can compare our output with the reference as text, and compare what both print when run.
5. **Outputs differ per target** even for the same program (`echo`, floats). Expected output is
   recorded per target.

## Sources

- Joe Armstrong, [A History of Erlang](https://dl.acm.org/doi/10.1145/1238844.1238850) (HOPL III, 2007),
  and his thesis [Making reliable distributed systems in the presence of software errors](https://erlang.org/download/armstrong_thesis_2003.pdf) (2003).
- [Erlang documentation](https://www.erlang.org/doc/): [processes](https://www.erlang.org/doc/system/ref_man_processes.html),
  [the abstract format](https://www.erlang.org/doc/apps/erts/absform.html),
  [the external term format](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html),
  [OTP design principles](https://www.erlang.org/doc/system/design_principles.html).
- Erik Stenman, [The BEAM Book](https://blog.stenmans.org/theBeamBook/).
- Louis Pilfold, [Gleam doesn't compile to Erlang source anymore](https://gleam.run/news/gleam-doesnt-compile-to-erlang-source-anymore/) (Gleam 1.19, October 2026),
  and the Gleam [FAQ](https://gleam.run/frequently-asked-questions/).
- [gleam_erlang](https://github.com/gleam-lang/erlang) and [gleam_otp](https://github.com/gleam-lang/otp), read at the source.
- The Gleam compiler at v1.19.2: `compiler-core/src/erlang.rs`, `compiler-core/src/codegen.rs`,
  `erlang-generation/`, `erlang-term-format/`.
- The examples of this page: `docs/devlog/data/the_beam/` in the repository.
"""

nbSave
