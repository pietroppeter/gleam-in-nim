## devlog: 12 Nov 2026 F | What other rewrites teach us | Nine lessons from the Go compiler, TypeScript, Ladybird, Bun, fish, Roc and a C compiler built by agents, and what each one changes in how we port Gleam to Nim.
## kind: research
import std/[os, strutils, json]
import nimib
import ../blocks

nbInit
nb.usePost()

const here = currentSourcePath().parentDir
let portmap = parseFile(here / ".." / "data" / "portmap.json")
let snapshots = parseFile(here / ".." / "data" / "snapshots.json")
let harvest = parseFile(here / ".." / "data" / "harvest.json")

proc thousands(n: int): string = insertSep($n, ',')

let codeLines = portmap["code"].getInt
let testLines = portmap["tests"]["code"].getInt
let pin = portmap["pin"].getStr

nbText: """
## The short version

We are about to move """ & thousands(codeLines) & """ lines of Rust into Nim (Gleam """ & pin & """; tests, comments
and blank lines not counted),
mostly with coding agents. Other people have moved compilers and runtimes between languages, some
of them this year and with the same kind of agents. Before writing a line, we read how they did
it. Nine lessons came out, and each one became a rule or a tool of this project.

1. **Port, do not rewrite.** The fast, safe moves kept the program and changed the language.
2. **Choose by shape.** A port is easy when the new language can say what the old code says, the
   way it says it. Gleam's Rust happens to be shaped like Nim.
3. **An oracle beats a test you wrote.** The projects with no regressions compared the new output
   with the old, byte for byte.
4. **The old test suite is the treasure.** Nobody who succeeded wrote new tests first.
5. **Write the guide before the code.** One document that says how every idiom is translated,
   read by every session.
6. **One writes, another doubts.** Translation and verification are separate jobs, done with
   separate memories.
7. **Look-alikes bite.** The bugs that escape are where two languages write the same thing and
   mean different things.
8. **Half of the work comes after "it works".** The fish shell calls it the second 90%.
9. **Speed does not excuse review.** The fastest port of the year is also the most contested,
   and for that reason.

The rest of this post is the evidence, case by case, then what we do about it.
"""

nbNote("""
About the sources. Most blogs are outside what this sandbox can reach, so for each case we read
what lives on GitHub: the pull requests, the scripts and guides in the repositories, and the
sources of the posts where a project keeps its site in a repository. Those are marked *read*.
Numbers that we only saw quoted by others are marked *reported*. The list is at the end.
""", nkInfo, "How to read this")

nbText: """
## The cases at a glance

| Project | From, to | Size | Time | How it was checked |
| --- | --- | --- | --- | --- |
| Go compiler, 2015 | C to Go | the whole compiler and linker | one release cycle | same program, translated by a tool |
| fish shell, 2023 to 2024 | C++ to Rust | 57K lines became 75K | 14 months, then 11 more to a beta | end-to-end script tests, one component at a time |
| TypeScript, 2025 to 2026 | TypeScript to Go | the compiler and tools | about a year in public | the old test suite, same errors at the same places |
| Roc, 2025 to 2026 | Rust to Zig | 300K lines | 487 days (reported) | a rewrite, so new tests and fuzzing |
| A C compiler, Feb 2026 | nothing to Rust | 100K lines | two weeks, 16 agents | GCC as oracle, compiler test suites |
| Ladybird's LibJS, Feb 2026 | C++ to Rust | 25K lines | two weeks, one person and agents | identical AST and bytecode, 65,359 tests, zero regressions |
| Bun, May 2026 | Zig to Rust | about 535K lines (reported) | days to weeks (reported) | the existing test suite on every platform |

## Go, 2015: the same program in a different language

The Go compiler was written in C until Go 1.5. Its authors did not rewrite it. They wrote a tool
that translated their C into Go, and shipped the result. The release notes say it plainly: the
compiler "was actually moved by automatic translation of the C code into Go. It is in effect the
same program in a different language. It is not a new implementation of the compiler so we expect
the process will not have introduced new compiler bugs." They also say what it cost: the
translation "resulted in unidiomatic Go code that performs poorly compared to well-written Go",
to be cleaned up in the following releases.

**What we take.** The order of work: first the same program, then a good program. And the
argument for it, which is about bugs, not about speed: a translation can only have translation
bugs.

## TypeScript to Go, 2025 to 2026: structure is a feature

The TypeScript team moved their compiler from TypeScript to Go and called it a port from the
first day. Their FAQ gives the reason: "we need to keep the new codebase as compatible as
possible, both in terms of semantics and in terms of code structure", and "we're undertaking this
more as a port that maintains the existing behavior and critical optimizations". Go was chosen
for its shape: "Idiomatic Go strongly resembles the existing coding patterns of the TypeScript
codebase", a compiler that does "an unusually large amount of graph processing" over trees that
point both up and down, which wants a garbage collector.

Three details are worth copying.

- The Go repository held the TypeScript repository as a git submodule "pointing to the commit
  being ported", for tests and code generation. The pin was a file, not a memory.
- The status table in their README defines done as equality with the old compiler: parsing has
  the "exact same syntax errors", type checking the "same errors, locations, and messages".
- Differences made on purpose are listed in one file, `CHANGES.md`, such as positions counted in
  UTF-8 instead of UTF-16. Until version 7.0 shipped, only pull requests "addressing 6.0/7.0
  differences, or crashes" were accepted: a behaviour freeze.

The repository says the port "is now completed" and was archived on 1 September 2026. The
speed-up reported everywhere, around ten times, we did not read at the source.

**What we take.** A pin in the repository, a definition of done that is equality, one list of
divergences, and no new features until parity.

## Ladybird's LibJS, February 2026: identical or not done

Andreas Kling moved the front of Ladybird's JavaScript engine (lexer, parser, AST, bytecode
generator) from C++ to Rust with Claude Code and Codex, about 25,000 lines in about two weeks.
He is precise about who did what: "This was human-directed, not autonomous code generation. I
decided what to port, in what order, and what the Rust code should look like. It was hundreds of
small prompts". Then "multiple passes of adversarial review, asking different models to analyze
the code for mistakes and bad patterns".

The rule that made it safe: "The requirement from the start was byte-for-byte identical output
from both pipelines." Every AST and all bytecode equal to the C++ ones, 52,898 test262 tests and
12,461 regression tests with zero regressions, and then real browsing with both pipelines running
in lockstep. On style he is equally direct: the code "has a strong 'translated from C++' vibe.
That's because it is translated from C++", down to copying the register allocation so the
bytecode matches, and "that cleanup will come in time".

**What we take.** This is the closest case to ours, a compiler front end moved by one person and
agents, and we copy it whole: identical output as the requirement, non-idiomatic code accepted,
a second model asked to find faults.

## Bun, May 2026: the machinery of a large port

Bun moved from Zig to Rust in one pull request, "Rewrite Bun in Rust", opened on 8 May 2026 and
merged on the 14th, from a branch named `claude/phase-a-port` with 6,755 commits. When we cloned
Bun for this post it had 4,338 Rust files and no Zig file. Its author wrote that it "passes Bun's
pre-existing test suite on all platforms" and that "the codebase is otherwise largely the same.
The same architecture, the same data structures". The size (about 535,000 lines of Zig) and the
duration (eleven days in some accounts, four months end to end in others) we only have as
reported.

What we could read is better than a blog post: the scripts that ran the port are in the pull
request, forty of them, one per kind of job, in phases named A to H. They are the most concrete
description of an agent-driven port that exists.

- **A guide first.** Every agent starts with "Read the WHOLE file. Every rule is load-bearing":
  a porting guide with an idiom map (how each Zig construct is written in Rust), the crates to
  use and the ones that are forbidden.
- **Decide the hard question once, as data.** Before translating, a separate job classified
  every pointer field of every struct into one of eleven ownership classes and wrote the answer
  to a table. Translators were told to use that column "verbatim". Where Rust needs a decision
  that Zig never made, nobody decides it twice.
- **Nothing left to taste.** The path of each Rust file is computed from the Zig path ("do NOT
  let agents pick"). The instruction is "match structure, fn names, field order, control flow".
  Each file ends with a status trailer.
- **Three roles per file.** *Implement*, then *Verify* ("You are an adversarial verifier. Find
  every place the draft deviates"), then *Fix* ("surgical edits only. If an issue is wrong,
  skip it and note"). Later phases use two independent verifiers and a third to refute.
- **Phases by what can be checked.** A: draft every file, no build. B: make it compile, one
  crate tier at a time, stubbing what is not ready. C: link and fix panics. D to G: bring up the
  tests, from one file to the whole suite. H: remove duplication, tidy.

It is also the port people argue about. The pull request had almost exactly as many thumbs down
as up (1,804 and 1,773 when we read it). Zig's creator, Andrew Kelley, called the result
unreviewed in public, and later reports speak of semantic regressions where Zig and Rust look
alike and of a long tail of follow-up fixes. We could not read those at the source.
"""

nbNote("""
Bun belongs to Anthropic, which also makes the model that wrote most of this post. We tried to
report only what the repository shows, and to give the criticism its place.
""", nkPlain, "A disclosure")

nbText: """
**What we take.** The guide, the fixed paths, the status in each file and the three roles, all
scaled down to one compiler and one reviewer. And the warning: a port that nobody could review is
a port that half of its audience will not trust. Ours goes in small steps, each with a page that
explains it.

## A C compiler built by sixteen agents, February 2026

Not a port, but the nearest relative: Nicholas Carlini at Anthropic had sixteen parallel agents
write a C compiler in Rust, 100,000 lines in two weeks and about 2,000 sessions, good enough to
build Linux. His lessons are about the harness, not the model.

- "Write extremely high-quality tests": the verifier must be nearly perfect, "otherwise Claude
  will solve the wrong problem".
- Write the test output for the agent: a few lines, errors on one line with the word ERROR so
  that grep finds them, details in a file, statistics already computed.
- Agents cannot feel time. Give the test runner a `--fast` option that runs a random 1% or 10%,
  the same sample for one agent and different across agents.
- Keep READMEs and progress files current, because every session starts knowing nothing.
- When everyone was stuck on the same failure (the Linux kernel would not boot), the fix was an
  oracle: compile most files with GCC and a random few with the new compiler, and the failure
  became many small independent ones.

He is honest about the limits: the code is "nowhere near the quality of what an expert Rust
programmer might produce", new fixes often broke old features, and "it is easy to see tests pass
and assume the job is done".

**What we take.** Our tools follow his output rules to the letter, and the reference `gleam`
binary plays the part of GCC.

## fish, 2023 to 2024: the second 90%

The fish shell moved 57,000 lines of C++ to 75,000 lines of Rust, by hand, one component at a
time, with the two languages linked together so that fish worked at every commit. Their reason
for not disappearing into a rewrite: without a working program "we would not have been able to
use most of our test suite", which is end to end, and "had we chosen to disappear into a hole we
might not have finished at all".

The first estimate was "handwaving, half a year". The last C++ went away after about a year; the
first beta came eleven months after that. They name the gap: "The 'second 90%' - testing that
everything worked. We flushed out a lot of bugs in this time, and if we made a release at that
time it would have been a bad one."

**What we take.** Keep something that runs at every step, so the tests can run. And plan for the
second 90%: when every file is translated we are halfway.

## Roc, 2025 to 2026: when a rewrite is the right word

Roc is moving its compiler from Rust to Zig, 300,000 lines, and chose to rewrite. The reasons
are particular: their roadmap already rewrote almost every stage, Rust's compile times hurt, and
their compiler passes allocators around the way Zig likes. It reached feature parity after a
reported 487 days. It is the honest counterexample: a rewrite buys a better design and is paid
for in years.

**What we take.** We want the same compiler in another language, not a better compiler. So we
port.

## Small ports with a conformance suite

One more family, reported and not read at the source: Emil Stenström's JustHTML, an HTML5 parser
that passes the html5lib tests, was moved by agents to JavaScript, PHP, OCaml and Crystal in
hours or days each, with little intervention. The pattern is always the same: a language-independent
test suite, thousands of cases, and an agent looping until they pass.

**What we take.** Gleam does not have a language-independent suite. But its tests are almost
one: """ & thousands(snapshots["total"].getInt) & """ snapshot files, """ & thousands(snapshots["with_source"].getInt) & """ of which contain the Gleam source they
were made from, and """ & thousands(harvest["total"].getInt) & """ test macro calls, most with their inputs written as string literals. We built two
small tools that turn them into one (see [How this port is developed](../how-we-work/)).

## Is Nim the right shape?

Lesson 2 deserves a check on our own case. The TypeScript team could port line by line because Go
could express their code as it was. Ladybird first rejected Rust because their object model did
not fit it. So: can Nim say what Gleam's Rust says?

We counted the lines of `compiler-core` (tests left out) that use each Rust idiom.
"""

block:
  var table = "| Rust idiom | Lines | In Nim |\n| --- | ---: | --- |\n"
  for line in lines(here / "data" / "learning_from_rewrites" / "rust_idioms.tsv"):
    let cells = line.split('\t')
    table.add "| `" & cells[0] & "` | " & thousands(parseInt(cells[1])) & " | " & cells[2] & " |\n"
  nbText: table

nbText: """
This is Rust written the way one writes a compiler in a garbage-collected language. Values are
shared with `Arc` and copied with `.clone()` without ceremony; there is one `unsafe` in the whole
core and hardly any trait machinery. The lifetimes are many, but they only say "this lives as long
as the source", which a garbage collector says for free. Enums with data and `match` are
everywhere, and Nim has object variants and an exhaustive `case` for them.

Nim's memory management (reference counting with a cycle collector) gives every `Arc<T>` a
natural twin, a `ref object`. So the answer is yes, with three places to watch, which are the
first entries in the porting guide's list of traps.
"""

nbText: """
## Look-alikes between Rust and Nim

Lesson 7 says the escaped bugs hide where the languages look the same. These are ours. Each one
is a line of Nim that runs when this page is built.
"""

nbCode:
  # 1. Equality. Rust's derived == compares values, also behind an Arc.
  #    Nim compares refs by identity: two equal trees are "different".
  type Node = ref object
    name: string
  echo Node(name: "a") == Node(name: "a")

nbCode:
  # 2. A char is not a char. Rust's char is a Unicode scalar; Nim's is a byte.
  #    Byte offsets (what Gleam's spans use) agree; counting characters does not.
  import std/unicode
  echo "wibblé".len, " bytes, ", "wibblé".runeLen, " characters"

nbCode:
  # 3. Overflow. Rust wraps or panics depending on the build; Nim raises on signed
  #    integers and wraps on unsigned ones.
  var n = high(uint32)
  n += 1
  echo n

nbText: """
Two more that cannot be shown in three lines. A Rust `HashMap` iterates in a random order, so
upstream sorts wherever order reaches the output: we must sort in the same places and by the same
key, and never rely on the order of a Nim `Table`. And Nim identifiers cannot end with an
underscore, so the upstream module `type_` needs another name here.

## What this changes for the port

Every lesson is now something in the repository.

| Lesson | What exists |
| --- | --- |
| Port, do not rewrite | [Decision 0002](../../decisions/#0002-this-is-a-port-not-a-rewrite): mirror the Rust, file by file, idiomatic later |
| Choose by shape | The idiom table above, and the [porting guide](../../porting/) |
| An oracle beats a test | [Decision 0004](../../decisions/#0004-outputs-are-compared-byte-for-byte-with-the-reference) and `tools/difftest.nim`, byte for byte against `gleam` """ & pin & """ |
| The old tests are the treasure | [Decision 0003](../../decisions/#0003-the-pinned-compiler-and-its-tests-are-the-specification), `tools/snapshots.nim`, `tools/harvest.nim` |
| Guide before code | The [porting guide](../../porting/), read at the start of every port step |
| One writes, another doubts | [Decision 0005](../../decisions/#0005-every-file-goes-through-translate-verify-conform): draft, verified, conformant |
| Look-alikes bite | The traps section of the porting guide, fed by every verification |
| The second 90% | The port map shows translated, checked and proven as three different numbers |
| Speed does not excuse review | Small pull requests, one explainer per step, review mode on every page |

The next post, [How this port is developed](../how-we-work/), shows the tools and the working
loop.

## Sources

Read at the source:

- Go 1.5 release notes, [go.dev/doc/go1.5](https://go.dev/doc/go1.5) (from the `golang/website` repository).
- TypeScript: the FAQ [Why Go?](https://github.com/microsoft/typescript-go/discussions/411), and
  the README, `CHANGES.md` and `CONTRIBUTING.md` of [microsoft/typescript-go](https://github.com/microsoft/typescript-go).
- Ladybird: [Ladybird adopts Rust, with help from AI](https://ladybird.org/posts/adopting-rust/), Andreas Kling, 23 Feb 2026
  (from the `LadybirdBrowser/ladybird.org` repository), and the [pull request](https://github.com/LadybirdBrowser/ladybird/pull/8104).
- Bun: the pull request [Rewrite Bun in Rust](https://github.com/oven-sh/bun/pull/30412) and the
  workflow scripts under `.claude/workflows/` at its head commit. The porting guide itself was
  removed before the merge; we know it through the scripts that quote it.
- [Building a C compiler with a team of parallel Claudes](https://www.anthropic.com/engineering/building-c-compiler), Nicholas Carlini, 5 Feb 2026.
- fish: [Fish 4.0: The Fish Of Theseus](https://fishshell.com/blog/rustport/) (from the `fish-shell/fish-site` repository).
- Roc: Richard Feldman's note [on the rewrite](https://gist.github.com/rtfeldman/77fb430ee57b42f5f2ca973a3992532f).

Reported by others, not read at the source:

- Bun's size, duration, cost and the criticism: [InfoQ](https://www.infoq.com/news/2026/09/bun-AI-rewrite-zig-rust-4-months/),
  The Register ([the merge](https://www.theregister.com/devops/2026/05/14/anthropics-bun-rust-rewrite-merged-at-speed-of-ai/5240381),
  [the criticism](https://www.theregister.com/devops/2026/07/14/zig-creator-calls-buns-claude-rust-rewrite-unreviewed-slop/5270743)).
- TypeScript 7's release and speed: [InfoQ](https://infoq.com/news/2026/08/typescript-7-released/).
- Roc's 487 days: "How Our Rust-to-Zig Rewrite Is Going", seen through summaries.
- JustHTML and its ports: Simon Willison, [I ported JustHTML from Python to JavaScript](https://simonwillison.net/2025/Dec/15/porting-justhtml/).

The idiom counts come from `docs/devlog/data/learning_from_rewrites/count_idioms.sh`, run on
Gleam """ & pin & """.
"""

nbSave
