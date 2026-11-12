## devlog: 12 Nov 2026 I | Where Gleam's decisions live | Gleam has no specification and no RFC process, so here is a map of where to look when the code alone does not say why.
## kind: research
import std/[json, os, strformat, strutils, sequtils]
import nimib
import ../blocks

nbInit
nb.usePost()

const dataDir = currentSourcePath().parentDir / "data" / "where_gleam_decisions_live"
let sources = parseFile(dataDir / "sources.json")["sources"]

var changelog: seq[(string, int)] # version, number of entries
for line in lines(dataDir / "changelog_entries.tsv"):
  let cols = line.split('\t')
  if cols[0] != "version": changelog.add (cols[0], cols[1].parseInt)

let
  byReach = proc(r: string): int = sources.countIt(it["reach"].getStr == r)
  entriesTotal = changelog.mapIt(it[1]).foldl(a + b)
  entriesSinceV1 = changelog[1 .. ^1].mapIt(it[1]).foldl(a + b)

nbText: &"""
## The short version

Sooner or later a port hits a question the code does not answer. Why does `1 / 0` return `0`?
Is `a |> b(c)` allowed to mean `b(a)(c)`? Is this odd behaviour a bug to fix or a promise to
keep? For Rust you would look for an RFC, for Python a PEP. Gleam has neither, and no written
specification. Decisions are made by Louis Pilfold with the core team, in conversation, and
then written down in a handful of very regular places.

This post is the map of those places: {sources.len} of them, sorted by how useful they are for
a reimplementation.

- **{byReach("clone")} can be cloned**, pinned at a commit and searched offline. This is where
  almost every answer we need is.
- **{byReach("search")} can only be reached by web search**, which is fine for the rare deep dive.
- **{byReach("closed")} is closed to us**: the Discord server, where most informal discussion
  happens. We plan around that gap instead of pretending it is not there.

The most valuable single file is small and easy to miss: `docs/v2.md`, the list of things the
team considers mistakes but keeps for compatibility. A faithful port has to reproduce those
mistakes.
"""

proc sourcesTable(tier: int): string =
  result = "| Where | What you find there | Reach |\n|---|---|---|\n"
  for s in sources:
    if s["tier"].getInt == tier:
      result.add &"""| [{s["name"].getStr}]({s["url"].getStr}) | {s["what"].getStr} | {s["reach"].getStr} |""" & "\n"

nbText: &"""
## Tier 1: the record

These are part of the snapshot we port or sit right next to it. When they disagree with
anything else, they win.

{sourcesTable(1)}

Three notes on using them.

**The tests are the specification.** The compiler is tested mostly with snapshots: a piece of
Gleam goes in, and the generated Erlang, the generated JavaScript, or the full text of the
error message is stored in a file and reviewed by a human when it changes. Whatever is in a
snapshot is intended behaviour.

**The changelog is a decision log in disguise.** Each entry says what changed in a sentence or
two and credits the person who did it. Since v1.0 that is {entriesSinceV1} entries over
{changelog.len - 1} minor versions, and {entriesTotal} if you count everything back to the
first release.
"""

proc changelogTable(): string =
  result = "| Version | Changelog entries |\n|---|---|\n"
  for (v, n) in changelog: result.add &"| {v} | {n} |\n"

nbText: changelogTable()

nbText: """
**`docs/v2.md` tells us which quirks are load bearing.** Gleam promises not to break code
within v1, so when the team finds a design mistake it goes on this list, gets a warning, and
stays. At our snapshot the list has ten items. A few examples:

- `a |> b(c)` can mean `b(a, c)` or `b(a)(c)`, depending on the types. In v2 only the first
  will remain. In v1 the type checker has to try both.
- `[1, ..]` is accepted as a list value because of a parser bug that people may now depend on.
- `_ as a` is a legal pattern even though `a` alone says the same thing.
- A module can be imported twice under different aliases.
- A `case` guard can be written with `if` and no condition after it.
- `0.0 == -0.0` is `False` on Erlang and `True` on JavaScript.

Each of these is a test we would never think to write from the language tour, and each one
must behave exactly as upstream does, warning included.
"""

nbText: &"""
## Tier 2: positions and rationale

Stable statements of intent, and the discussions around individual changes.

{sourcesTable(2)}

The FAQ deserves a full read. It answers, in a paragraph each, questions that would otherwise
cost us an afternoon: why there are no type classes, why division by zero returns zero (Gleam
does not throw implicitly and the BEAM has no infinity, so zero is the only option left), how
message passing is typed (in libraries, not in the language, so the same language can run on
Erlang and JavaScript), and why the compiler will not be rewritten in Gleam.

The issue template asks people to open a GitHub Discussion before filing anything beyond a
trivial feature request. So Discussions is where proposals are argued, and the issue tracker
is where accepted work is tracked. Neither can be cloned with git, so we read them one
question at a time.

## Tier 3: voices

Context, motivation and taste. Rarely needed to settle a behaviour, often useful to
understand a direction.

{sourcesTable(3)}

Two of these are worth an evening for anyone following this project. *Gleam: Past, Present,
Future* is the best single account of how the language got to 1.0. The Software Unscripted
episode on Gleam's design and compiler is the closest thing to a guided tour of the code we
are porting, by the person who wrote most of it.
"""

nbText: """
## What we cannot read

The Gleam Discord is the heart of the community and the place where many decisions are first
talked through. It is open for anyone to join, but it is not indexed by search engines and has
no public archive, and an automated reader has no business there anyway. So:

- We treat anything that only exists on Discord as unknown, and say so when it matters.
- When a decision matters for the port and the record is silent, the fallback is behaviour:
  run the reference compiler and write down what it does.
- If a question truly needs a human answer, a human asks it. Gleam's contribution guide wants
  communication written by people, and that applies to questions as much as to patches.

## A recipe for "why does it do that?"

When the port meets a behaviour that looks odd, we go down this list and stop at the first
answer:

1. **Is there a snapshot test for it?** Search the `.snap` files of the pinned compiler for the
   construct or the message. If yes, it is intended.
2. **Is it in `docs/v2.md`?** Then it is a known quirk. Reproduce it, warning and all.
3. **What does the changelog say?** Search `CHANGELOG.md` and `changelog/` for the feature name.
   The entry gives the version and the author.
4. **What does the release post say?** Open the post for that version in the website
   repository. This is usually where the reason is.
5. **Still unclear?** Search issues and Discussions for the feature name, then the FAQ and the
   talks.
6. **Nothing?** Record it in the devlog as an open question, port the observed behaviour, and
   move on.

Steps 1 to 4 work offline on clones we already have.

## What this changes for the port

1. **Pin the website too.** The release posts are part of the record. The corpus manifest pins
   `gleam-lang/website` next to the compiler, so both can be searched at a known commit.
2. **Port the quirks on purpose.** The ten items of `docs/v2.md` go into the coverage map as
   their own rows, so that nobody "fixes" them by accident.
3. **Changelog entries are a feature checklist.** The entries since v1.0 can seed the feature
   coverage map: each one names a behaviour that some test should exercise.
4. **Decision records point upstream.** When we record a decision of our own that depends on
   an upstream choice, we link the tier 1 source and the commit, not a memory of a talk.
5. **Open questions are allowed.** With one closed source, some answers will stay unknown. The
   devlog says so plainly when that happens.

## Sources

- [gleam-lang/gleam](https://github.com/gleam-lang/gleam) at tag v1.19.2: `docs/`, `changelog/`,
  `CONTRIBUTING.md` and the issue templates.
- [gleam-lang/website](https://github.com/gleam-lang/website): news, FAQ, roadmap, community page.
- [How to add metaprogramming to Gleam](https://lpil.uk/blog/how-to-add-metaprogramming-to-gleam/), Louis Pilfold.
- [Gleam: Past, Present, Future!](https://archive.fosdem.org/2024/schedule/), FOSDEM 2024.
- [Gleam's Journey on the BEAM](https://www.youtube.com/watch?v=6I0IbJtUC3U), Code BEAM Europe 2024.
- [Core team panel](https://www.youtube.com/watch?v=LgfzH_WBlr4), Gleam Gathering 2026.
- [Gleam and the value of small](https://www.youtube.com/watch?v=E6_JqYMeNqs), Ubuntu Summit 26.04.
- [The Changelog 588: Run Gleam run](https://changelog.com/podcast/588).
- [Rustacean Station 40: Gleam with Louis Pilfold](https://rustacean-station.org/episode/040-louis-pilford/).
- [Interview with Louis Pilfold](https://serokell.io/blog/interview-with-louis-pilfold), Serokell.
- The list of sources and the changelog counts are in `docs/devlog/data/where_gleam_decisions_live/`.
"""

nbSave
