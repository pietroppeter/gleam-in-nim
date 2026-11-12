## devlog: 12 Nov 2026 I | The port plan | Seven phases, seven milestones, one rule: print what the reference prints.
## kind: plan
import std/[json, os, strformat, strutils, tables]
import nimib
import ../blocks

nbInit
nb.usePost()

const docsDir = currentSourcePath.parentDir.parentDir
let
  roadmap = parseJson(readFile(docsDir / "data" / "roadmap.json"))
  coverage = parseJson(readFile(docsDir / "data" / "coverage.json"))

proc thousands(n: int): string = insertSep($n, ',')

var
  phaseLines, phaseTests, phaseSnapshots: CountTable[string]
  totalLines, totalSteps = 0
for component in coverage["components"]:
  let phase = component["phase"].getStr
  phaseLines.inc(phase, component["rust_loc"].getInt)
  phaseTests.inc(phase, component["rust_test_loc"].getInt)
  phaseSnapshots.inc(phase, component["snapshots"].getInt)
  totalLines += component["rust_loc"].getInt
for phase in roadmap["phases"]: totalSteps += phase["steps"].len

nbText: fmt"""
## The short version

- **What**: a port of Gleam v1.19.2 to Nim, the whole toolchain: compiler, formatter, build tool,
  package manager client, language server. {thousands(totalLines)} lines of Rust to read.
- **How**: file by file, faithful first and idiomatic later, in **{roadmap["phases"].len} phases
  and {totalSteps} steps**. Each step is one pull request with its explainer.
- **In what order**: along the pipeline. Front end, analysis, Erlang backend, JavaScript backend,
  the rest of the toolchain, the language server.
- **Erlang or JavaScript first?** Erlang, as text. Reasons below.
- **How we know it works**: the port is correct when it prints, byte for byte, what the pinned
  Gleam binary prints. Upstream's {thousands(phaseSnapshots.getOrDefault("P1") + phaseSnapshots.getOrDefault("P2") + phaseSnapshots.getOrDefault("P3") + phaseSnapshots.getOrDefault("P4") + phaseSnapshots.getOrDefault("P5") + phaseSnapshots.getOrDefault("P6"))}
  snapshot files are our conformance suite, and real Gleam packages are our field test.
- **Where the plan lives**: not in this post. This post is dated and will age. The living plan is
  the [roadmap](../../roadmap/) and the [coverage map](../../coverage/), two pages drawn from two
  JSON files that every pull request updates.

## Scope: what "the compiler" means

The repository called `gleam` is more than a compiler. The previous post measured it; here it is
again, grouped by the phase in which we will port it.
"""

block:
  var table = "| Phase | Goal | Steps | Rust lines | Test lines | Snapshots |\n|---|---|---:|---:|---:|---:|\n"
  for phase in roadmap["phases"]:
    let id = phase["id"].getStr
    table.add "| **" & id & " " & phase["title"].getStr & "** | " & phase["goal"].getStr & " | " &
      $phase["steps"].len & " | " & thousands(phaseLines.getOrDefault(id)) & " | " &
      thousands(phaseTests.getOrDefault(id)) & " | " & thousands(phaseSnapshots.getOrDefault(id)) & " |\n"
  nbText: table

nbText: """
(A component is counted in the phase where its port starts. Error messages, for example, start in
P2 but every phase adds the messages it can raise.)

Everything is in scope, in this order of importance: the language first, the tools second. If the
project had to stop early, it should stop at a milestone, with something that works: a formatter,
then a type checker, then a compiler.

One thing is out of scope by design: **changing Gleam**. No new syntax, no different error
wording, no "improvements". Where the port must differ from upstream (a cache file format, say) the
difference goes in a list of divergences, and the list should stay short.

## The seven milestones

A phase ends with a milestone, and a milestone is a claim that anyone can check by running a
command.
"""

block:
  var table = "| | Milestone | Proof |\n|---|---|---|\n"
  for milestone in roadmap["milestones"]:
    table.add "| **" & milestone["id"].getStr & "** | " & milestone["title"].getStr & " | " &
      milestone["proof"].getStr & " |\n"
  nbText: table

nbText: """
## Why this order

**Follow the data.** Each stage consumes what the previous one produces, so the pipeline order is
the only order in which every step can be tested on real input the day it is written.

**The formatter jumps the queue.** In upstream's history the formatter is tooling, and tooling
comes last. We do it right after the parser, for a selfish reason: a parser is hard to test,
because its output is a tree, and upstream tests its tree with Rust debug dumps that would be
tedious to imitate. The formatter turns the tree back into text. If our formatter prints exactly
what `gleam format` prints for every file of the standard library, our lexer, our parser and our
handling of comments are right, down to the last trailing comma. That is milestone M1, and it
needs no type checker.

**The type checker gets an oracle too.** `gleam export package-interface` writes the type of every
public function of a package as JSON. Comparing that JSON on real packages checks inference end to
end before a single line of backend exists. That is milestone M2.

**Diagnostics come with their component, not at the end.** A third of upstream's snapshots are
error and warning messages. We port the renderer early (step 1.6) and then each step ports the
messages it can raise.

## Erlang first

The question was asked explicitly, so here is the reasoning.

| | Erlang (text) | JavaScript |
|---|---|---|
| Role in Gleam | default target, where the ecosystem lives (OTP, most packages) | second target, added in 2021 |
| Backend size | 6,747 lines plus a 2,400 line text builder | 8,452 lines plus 1,314 for TypeScript |
| Needs the pretty printer | no | yes |
| Needs decision tree code generation | no, Erlang has `case` | yes, 2,558 lines |
| Runtime support code | none | `prelude.mjs`, 1,605 lines (copied, not ported) |
| Upstream snapshots | 483 | 843 |
| Can we run the output here | not yet: no Erlang in the sandbox, yes in CI | yes: Node and Bun are installed |

JavaScript wins exactly one row, the last, and that row matters less than it seems: our test is
*equality of output*, not behaviour. If the port writes the same `.erl` file as the reference, it
behaves the same, on any Erlang, without running it. Running the result on the BEAM is a second
opinion (milestone M4, in CI), not the main proof.

So: **Erlang text first** (phase P3), **JavaScript second** (P4), and the **binary Erlang abstract
format third** (step 5.3). That last one is a wrinkle of this particular snapshot: since mid 2026
`gleam build` writes abstract format (`.abstr`) and only `compile-package --no-beam` and the test
suite still use text. The generator is shared, only the builder at the end differs, so nothing is
lost by doing the readable one first.

## How we verify

Five layers, from cheap to thorough. A step is **ported** when the first two are green and
**verified** when the third is.

| Layer | What | Oracle | Runs |
|---|---|---|---|
| 1. Unit | tests ported with the code they test | upstream's own assertions | every commit |
| 2. Conformance | upstream's snapshot files and assertion macros, replayed against the port | the expected output recorded upstream | every commit |
| 3. Differential | real packages through both compilers, outputs diffed | the pinned `gleam` binary | every pull request, sampled; fully at milestones |
| 4. Execution | compiled output run on the BEAM and on Node: `test/language`, the standard library's own tests | the test suites themselves | CI, from M4 on |
| 5. Adversarial | a second reading of each ported file against its Rust original; mutated inputs to reach error paths, diagnostics diffed with the reference | the Rust source, the pinned binary | at each step, and at milestones |

Some details that make this work:

- **The reference needs nothing but itself.** `gleam compile-package --no-beam` compiles a package
  to Erlang text with no Erlang installed and no network. It compiles the whole standard library
  in a quarter of a second, so the oracle is never the bottleneck.
- **Snapshots are self describing, mostly.** Of the 2,749 compiler snapshots, 2,535 carry their own
  input under a `----- SOURCE CODE` header. The rest, and all 918 formatter tests and 374 inference
  tests, keep their inputs in Rust macros. Step 0.7 harvests those into data files.
- **The corpus grows in rings**: upstream's own test projects, then `gleam_stdlib`, then the core
  `gleam-lang` packages, then community packages. A package enters the corpus pinned to a commit.
- **Numbers, not adjectives.** Each row of the coverage map carries `tests_passing` and
  `tests_total`. "The parser works" is not a status; "264 of 264 snapshots, 0 differences on 40
  packages" is.

The verification plan is itself revised at every milestone: what did the oracle miss, which bug was
found late and which layer should have caught it. The answer goes into the roadmap as a step.

## How a step goes

1. **Pick**: the first `todo` step in the roadmap whose dependencies are ported. Mark it
   `in progress` in `docs/data/roadmap.json`.
2. **Read** the upstream files for that step, top to bottom, at the pin.
3. **Port** them into `src/gleam_in_nim/`, same module names, same function names, same order.
   Keep upstream's comments. Keep its licence header.
4. **Test**: layers 1 and 2 for the step; layer 3 if the step completes something a reference
   command can check.
5. **Explain**: a devlog post. What the component does, what was surprising, what the numbers are.
6. **Update** the coverage row and the roadmap step, in the same pull request.
7. **Merge** when CI is green, then go to 1.

The roadmap and the coverage map are data, so the plan can be changed by the same pull request that
discovers it was wrong. Steps will be split (the type checker steps almost certainly) and
reordered. What should not change without a decision record: the pin, the milestones, and the rule
that output is compared byte for byte.

## Rust to Nim: what will bite

The translation is mostly mechanical, enums with data become object variants, `match` becomes
`case`, traits become concepts or plain procs. These are the places where it is not.

| Rust | In Nim | Risk |
|---|---|---|
| `Arc<Type>` with `RefCell<TypeVar>` | `ref` objects, mutated in place | low: this is the natural Nim shape |
| Generic syntax tree, `Pattern<()>` and `Pattern<Arc<Type>>` | to decide in step 1.3: generics, or one tree with an optional type | medium: affects every later file |
| `Result` and `?` everywhere | exceptions for the parser, an `Outcome` object where upstream keeps partial results | low |
| `imbl` persistent maps for scopes | copy on scope entry at first, measure, optimise later | medium: speed only |
| `HashMap` iteration | upstream sorts wherever order reaches the output; we must sort in the same places | high: a classic source of one line diffs |
| `EcoString`, `&str` slices | `string` | low |
| `BigInt` literals | a big integer library or a small one of our own | low |
| Unicode grapheme widths in the pretty printer | a grapheme segmentation library | medium: affects line breaking |
| `f64` printed with `{:?}` | must reproduce Rust's shortest round trip formatting exactly | medium |
| `codespan-reporting` for diagnostics | a faithful port of the one renderer upstream uses | medium: 1,233 snapshots depend on it |
| `serde` and `bitcode` for cache files | our own format: a declared divergence | low |
| `pubgrub`, `toml`, `tar`, `flate2`, HTTP | Nim libraries where good ones exist, ports otherwise | decided in P3 and P5 |
| deep recursion guarded with `stacker` | watch stack depth in inference, raise the limit or iterate | low |

## What could go wrong

- **The long tail.** The first 90% of snapshots will fall quickly and the last few will each hide
  an ordering or formatting subtlety. Milestones are defined as zero differences on purpose, so
  the tail is paid for when it is cheap, not at the end.
- **The type checker is one big knot.** `expression.rs` alone is 5,219 lines. The roadmap cuts it
  into six steps along the test files upstream already has, but expect that cut to be redrawn.
- **Upstream moves.** Main is already 243 files ahead of the pin. We stay on v1.19.2 until M6 and
  then decide, with the upstream diff as a ready made to-do list.
- **Scale.** This is a large port for anyone. The mitigation is the same as for the tail: small
  steps, a living map, and milestones that are worth having on their own.

## What this changes for the port

Nothing: this *is* the port. The next steps are already moving: the lexer (step 1.2) is being
ported in parallel, and the first tooling steps are harvesting upstream's tests. After those:
spans, the syntax tree, the parser.

## Sources

- [The roadmap](../../roadmap/) and [the coverage map](../../coverage/), which supersede this post
  the moment they change.
- The previous post, [How the Gleam compiler is made](../how-gleam-compiles/).
- `reference/README.md` in the repository: how to ask the oracle.
- [gleam-lang/gleam v1.19.2](https://github.com/gleam-lang/gleam/tree/v1.19.2), the pin.
"""

nbSave
