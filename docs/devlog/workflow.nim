## devlog: 12 Nov 2026 A | A stage for a long port | How Pietro has been building projects with nimib and an AI agent, and how this repository was set up the same way: a devlog of explainers, a review mode, a look of its own, a roadmap and a coverage map.
## kind: tooling
import std/[strutils, strformat]
import nimib
import tabelline, tabelline/nimib
import ../blocks, ../site

nbInit
nb.usePost()

let dataDir = docsDir / "devlog" / "data" / "workflow"
let cov = loadCoverage()
let roadmap = loadRoadmap()

nbText: &"""
Pietro asked for the Gleam compiler to be ported to Nim, step by step, with an explainer at
every step. The reference is {cov.rustCode.thousands} lines of Rust, so this will take many
steps and many sessions, by several threads working at once, and Pietro will review most of it
from his phone. Before the first line of compiler, the port needs a place to happen. This post
is about that place: where its shape comes from, and what is in it.

## The findings, first

- Pietro already has a way of doing this. Over the last month he made five projects with an AI
  agent and [nimib](https://github.com/pietroppeter/nimib), and each took a few more parts
  than the one before. He sketched the whole as a list of parts to pick from, and called it
  **Operetta**.
- Its one-sentence idea: *the explainer is where the thinking happens; every other part keeps
  it true.*
- A port of a reference is the kind of project that picks every part. So this repository has
  them all from the first commit: working rules, a setup script, pages built by CI, a devlog,
  living documents (a roadmap, a coverage map), a look of its own, and the review mode.
- Nothing here is new. Almost every piece is tabelline's, made smaller. That is the point: the
  port should spend its imagination on the compiler.

## Where the shape comes from

Five repositories, read before writing anything:
"""

block:
  type Project = object
    project, what, took: string
    specs, posts: int
  var rows: seq[Project]
  for line in readFile(dataDir / "projects.tsv").strip.splitLines[1 .. ^1]:
    let f = line.split('\t')
    rows.add Project(project: &"[{f[0]}](https://github.com/pietroppeter/{f[0]})", what: f[1],
                     specs: parseInt(f[2]), posts: parseInt(f[3]), took: f[4])
  let t = tabella(rows, rownameCol = "project"):
    tabHeader "Five projects of the last month", "and what each one added to the way of working"
    colsLabel {"what": "", "specs": "specs", "posts": "posts", "took": "what it shows"}
    fmtMarkdown "project"
    colsWidth {"took": "45%"}
    tabSourceNote "Specs: the capabilities under openspec/specs. Posts: the notebooks of the devlog or blog. Counted on 12 November 2026."
    optCssTheme()
  nbTable t

nbText: """
The sketch of Operetta is the second part of
[A month of building with Claude](https://pietroppeter.github.io/claude-artifacts/a-month-with-claude/).
It sorts the parts in five groups with names from the theatre, and says when a project picks
each:

| Group | In plain words | Picked |
|---|---|---|
| Scena | the stage: what every repo needs (rules for agents, a setup script, pages) | always |
| Prove | rehearsals: places to think (an explainer, a devlog, living documents, a look) | from the first idea |
| Partitura | the score: what the code must do (specs, examples that run, a backlog) | when you start saying "it should" |
| Repertorio | the repertoire: growing toward a reference (a coverage map, threads, design posts) | when there is a reference to follow |
| Suggeritore | the prompter: skills, for other people's agents | when others use it |

Operetta also lists seven kinds of project and what each picks. *A port of a reference* (nanuq
after Polars, tabelline after gt) picks everything, because the coverage map and the threads
carry it. The Gleam compiler in Nim is that kind of project, with one difference that makes it
easier and one that makes it harder.
"""

nbNote """
**Easier:** the score is already written. nanuq and tabelline had to decide what their API
should be, in specs. Here the Rust compiler *is* the specification, with thousands of tests and
snapshots: when the Nim and the Rust disagree, the Nim is wrong. So this repository starts
without OpenSpec; the threads on planning and on development practices decide what takes its
place (decision records, differential tests).
""", nkGleam, "The reference is a program"

nbNote &"""
**Harder:** the size. tabelline is a few thousand lines; the reference here is
{cov.rustCode.thousands}, in {cov.stages.len} stages. No session will hold it in its head, so
the repository has to: what is done, what is next and why must be readable from the pages.
""", nkNim, "The port is long"

nbText: """
## What is in the repository

### Scena: the stage

- **`AGENTS.md`**, the working rules, short enough to be read at the start of every session.
  It is also a page of the site, [For coding agents](../../agents/), built from the same file,
  so Pietro reviews the rules the agents follow and not a copy of them.
- **`tools/setup.sh`**, one command that gets a fresh sandbox ready. Cloud sessions start from
  a clean clone every time, so this is run often. The dependencies of the pages are pinned by
  commit in a small file:
"""

nbCode:
  for line in readFile(repoDir / "deps.lock").splitLines:
    if line.len > 0 and not line.startsWith("#"):
      let f = line.splitWhitespace
      echo f[0].alignLeft(10), f[2][0 ..< 7], "  ", f[1]

nbText: """
tabelline manages its dependencies with atlas. Here a lock file and twenty lines of shell do
the same, because there is nothing to resolve: six repositories, six commits. The compiler
itself will need only Nim's standard library.

- **Pages built by CI.** No HTML is committed. Every push builds the tests and the pages; on
  `main` the pages go to GitHub Pages. One program builds the whole site (`docs/all.nim`
  imports every page), a trick from cicak that keeps CI at one compile.

### Prove: places to think

**The devlog** is where the explainers go. One step, one post, one notebook. A post says who it
is in its first two lines, and the index and the home page find it by reading them:

```nim
## devlog: 12 Nov 2026 A | A stage for a long port | How Pietro has been building...
## kind: tooling
```

So adding a post is adding a file. Six threads are writing posts at the same time today, and
the only line they share is one import each in `docs/all.nim`. Here is what the devlog holds as
this page is built:
"""

nbCode:
  for p in devlogPosts():
    echo p.date, " ", p.letter, "  ", p.kind.alignLeft(9), p.title

nbText: """
A post is dated and not rewritten. What has to stay true lives in **living documents**, pages
that read their data from a file and are changed by the pull request that changes the facts:

- the [roadmap](../../roadmap/): phases, steps, and where each step stands;
- the [coverage map](../../coverage/): the Rust compiler module by module.

### Repertorio: the coverage map

nanuq counted Polars' feature groups; tabelline counts gt's functions. A compiler has no list
of features to tick, but it has modules, and they have a size. `tools/coverage_seed.nim` walks
a checkout of the pinned Gleam and counts lines of Rust per module, code and tests apart. This
is the map on day one, computed as this page is built:
"""

nbCode:
  for s in cov.stages:
    echo s.name.alignLeft(20), align(s.rustCode.thousands, 8), "  ", "▇".repeat(max(1, s.rustCode div 2500))
  echo "total".alignLeft(20), align(cov.rustCode.thousands, 8)

nbText: """
Lines are a rough measure: a line of the type checker is not a line of the command line. But
it is honest about the proportions, it is cheap to keep, and it gives the home page its
pipeline. Each lamp is a stage; yellow when its port starts, pink when it is done:
"""

nbPipeline cov.pipeline

nbText: """
The stages and the assignment of modules to them are a first guess, made by name. The thread
that takes the compiler apart will correct them.

## A look of its own: Lucciola

Pietro's projects each have a look designed for them: tabelline has Munari and the quaderno,
cadero has a carpenter's drawing. This one is called **Lucciola**, firefly: a small gleam, in
Italian. Its rules:

- **Two colours with a meaning.** Pink is Gleam, yellow is Nim (the pink of gleam.run and the
  yellow of Nim's crown, deepened where they sit on paper). Wherever a page compares the
  original and the port, the colour says which is which.
- **Two modes**, *giorno* and *notte*. Fireflies come out at night, so notte is the one where
  the two colours are at their real values. The header switches; the first visit follows the
  system.
- **Six values per mode** (paper, ink, primary, secondary, warning, success), and every other
  colour mixed from them in the browser. The tokens have tabelline's names, so its tables and
  the review mode read them unchanged.
- **Three typefaces**, all served from the repository: Lexend for headings (the typeface of
  gleam.run, a nod), Atkinson Hyperlegible for text, JetBrains Mono for code.
- **Code first.** These pages will be full of code in four languages. Code is small (13px),
  scrolls sideways inside its own box, and is highlighted when the page is built, with no
  script and no CDN. nimib highlights Nim; a small highlighter in `docs/blocks.nim` does the
  others:
"""

nbText: """
```gleam
import gleam/io

pub type Lamp {
  Off
  Lit(colour: String)
}

pub fn main() {
  // a pipe, a constructor, a string
  Lit("pink") |> describe |> io.println
}
```

```rust
pub fn make_tokenizer(source: &str) -> impl Iterator<Item = LexResult> + '_ {
    let chars = source.char_indices().map(|(i, c)| (i as u32, c));
    let nlh = NewlineHandler::new(chars); // from compiler-core/src/parse/lexer.rs
    Lexer::new(nlh)
}
```

```erlang
-spec main() -> nil.
main() ->
    gleam@io:println(describe({lit, <<"pink"/utf8>>})). % what the Erlang backend writes
```
"""

nbText: """
Notes come in kinds, so a reader skimming a port step can find what they are after:
"""

nbNote "How the original does it: a quote of the Rust, a behaviour, a test.", nkGleam, "nkGleam"
nbNote "How the port does it, and why it differs where it does.", nkNim, "nkNim"
nbNote "What was verified, and against what.", nkDone, "nkDone"
nbNote "Something to watch out for.", nkWarning, "nkWarning"
nbNote "An open question, for Pietro or for a later step.", nkQuestion, "nkQuestion"

nbText: """
**Blocks, not HTML.** A page is Markdown, nimib's blocks, tabelline's tables and the dozen
blocks of `docs/blocks.nim`. No HTML, no CSS and no colours in a page: every rule is in
`docs/theme.nim`. An agent reaches for HTML because it knows HTML well, and a site drifts one
`div` at a time; tabelline learned this the slow way and wrote it down, so here it is the rule
from the start.

## Review mode

This is the part Pietro asked for by name. Under the lede of every page there is a line,
*Version N · updated D*, and a button, **✎ Review**. In review mode a reader selects text,
writes a comment on it, and at the end exports all the comments as one text: Markdown with a
small YAML block that names the page, its source file, the version read and the commit it was
built from. Pasted in a chat, that text is everything an agent needs to find each quote in the
notebook and change it; the skill `.claude/skills/nimib-review/` says how.

The version is the number of commits that changed the page's source, which is why CI checks
out the whole history. Comments are kept in the browser, per page and version.

The review mode lives in tabelline for now (`docs/review.nim` and `review.js`) and is meant to
move to nimib. It is copied here unchanged, with the commit it was copied from and a script to
copy it again, the way
[claude-artifacts](https://github.com/pietroppeter/claude-artifacts/tree/main/shared/review)
does it. If it needs to change, it changes in tabelline.

Try it on this page: the button is under the lede.

## What other threads do with this

Five other threads started at the same time as this one, each with a post to write. The
contract they were given, half an hour before this repository existed, was short:

1. A post is `docs/devlog/<slug>.nim`; its first two lines say what it is.
2. `nb.usePost()` after `nbInit`; then Markdown and blocks; no HTML, CSS or colours.
3. Code that can run, runs. Numbers come from code or a data file.
4. One branch and one pull request per step, code and post together; merge when CI is green.
5. The pull request updates the roadmap and the coverage map.

The roadmap as this page is built:
"""

nbCode:
  for phase in roadmap:
    echo "Phase ", phase.id, ": ", phase.title
    for s in phase.steps:
      echo "  ", ($s.status).alignLeft(8), s.kind.alignLeft(9), s.title

nbText: """
## What was checked, and what was not

- Every page builds from a clean clone with `sh tools/setup.sh` and `nim r docs/all.nim`.
- The pages were looked at 390px wide, in giorno and in notte.
- The line counts come from the pinned checkout and are recomputed by a tool; the assignment
  of modules to stages is a guess by name.
- The review mode was copied, not rewritten; its export was not yet exercised end to end in
  this repository. The first review Pietro sends will be the test.
- Not done yet, on purpose: a link checker and a drift counter (tabelline has both in CI).
  They are worth adding once there are enough pages to drift.

## What this changes for the port

- Every thread has one way to explain a step, and Pietro has one way to review it.
- The state of the port is in the repository: a session that starts cold reads `AGENTS.md`,
  the roadmap and the coverage map, and knows what is done and what is next.
- The plan thread owns `docs/data/roadmap.json` and the stages of `docs/data/coverage.json`;
  this post's guesses are theirs to replace.

## Sources

- [tabelline](https://github.com/pietroppeter/tabelline): `AGENTS.md`, `docs/blocks.nim`,
  `docs/theme.nim`, `docs/review.nim`, the workflow of `.github/workflows/pages.yml`, and its
  devlog, in particular [Three threads for every release](https://pietroppeter.github.io/tabelline/devlog/three-threads/)
  and the post on the review mode.
- [nanuq](https://github.com/pietroppeter/nanuq), [parloku](https://github.com/pietroppeter/parloku),
  [cicak](https://github.com/pietroppeter/cicak), [cadero](https://github.com/pietroppeter/cadero).
- [A month of building with Claude, as an operetta](https://pietroppeter.github.io/claude-artifacts/a-month-with-claude/),
  where Operetta is sketched.
- Pietro's [skills](https://github.com/pietroppeter/skills) for nimib: blocks, themes, and
  handing work back so it can be reviewed from a phone.
- [Gleam](https://github.com/gleam-lang/gleam) at the pinned tag, for the line counts.
"""

nbSave
