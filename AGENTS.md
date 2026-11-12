# Working on gleam in nim

Notes for coding agents (and people) changing this repository: a port of the Gleam compiler to
Nim, made one explained step at a time. This file holds the working rules. It is rendered on
the site as *For coding agents*, so a change here is reviewed like any page.

## The goal, and the reference

- Port a snapshot of the [Gleam compiler](https://github.com/gleam-lang/gleam) to Nim. The
  snapshot is pinned: tag `v1.19.2`, commit `ed41eace2dd89054eb2d744c33925261d1eff32e`
  (`docs/data/coverage.json` holds the pin the pages show; `reference/` holds how to fetch it).
- The Rust compiler is the specification. When the Nim and the Rust disagree, the Nim is wrong,
  unless a decision record says the difference is wanted.
- Gleam is Apache-2.0. A file ported from it starts with a header naming the Rust file it comes
  from and the pinned commit, and keeps the Apache-2.0 notice. Never copy from a source whose
  licence does not allow it.
- Everything outside this repository is read only: no issues, comments or pull requests on other
  projects, Gleam's included.

## Steps

- The work goes in steps. A step is a well defined task (research, a plan, a piece of the port,
  tooling), small enough to verify, and it ships with an explainer: a devlog post.
- One branch and one pull request per step, with the code and the post together. A thread may
  review and merge its own pull request when CI is green; rebase on `main` first. Tags and
  releases wait for Pietro.
- The pull request that starts, ships or replans a step updates `docs/data/roadmap.json`; the
  one that ports a module updates its row in `docs/data/coverage.json`. Both are living pages
  (Roadmap, Coverage map), so the site always says where the port stands.
- The work must survive a session reset. What a later session needs is in the repository (this
  file, the roadmap, the coverage map, the devlog, decision records), not in a chat.

## Porting

- Read the porting guide (`docs/porting.nim`, the page *Porting guide*) before porting a file,
  and the decision records (`docs/decisions/`, the page *Decisions*) before choosing anything a
  later session could choose differently. A new choice of that kind is a new record
  (`docs/decisions/NNNN-slug.md`: front matter with title, status, date; then Context, Decision,
  Consequences); a record is not rewritten, a new one supersedes it.
- A ported Nim file (in `src/` or `tests/`) starts with `## port-of: <path of the Rust file in
  the Gleam repository>` and `## port-status: draft` (then `verified`, then `conformant`).
  `nim r tools/portmap.nim` builds the port map from these headers (`docs/data/portmap.json`);
  run it in the pull request that ports or advances a file.
- Upstream tests are replayed, not retyped: `tools/snapshots.nim` reads the `.snap` files,
  `tools/harvest.nim` the `assert_*!` calls of the Rust tests. A stage is done when
  `tools/difftest.nim` finds its output identical to the reference `gleam`, byte for byte. A
  wanted difference is an entry in `docs/divergences.md`.
- The tools find the Gleam checkout in `reference/gleam` or `$GLEAM_REF`, and the reference
  binary in `$GLEAM_BIN` or on the `PATH`. They print a few lines, one `ERROR ...` line per
  problem, and a summary last; anything slow takes `--fast:N` (a sample of N percent).

## Setup

- In a fresh checkout or sandbox, run `sh tools/setup.sh` first. It installs what is missing
  (Nim from GitHub nightlies, PCRE) and clones the docs' dependencies at the commits of
  `deps.lock` into `deps/` (not committed); `nim.cfg` puts them on the path. Safe to rerun.
- `nim r tests/all.nim` runs the tests. `nim r docs/all.nim` builds every page (add
  `-d:release` when the pages run heavy code). The HTML is not committed: CI builds it and
  deploys `docs/` to GitHub Pages from `main`.
- The compiler (`src/`) needs only Nim's standard library. nimib and tabelline are for the pages.
- To change a dependency, change its commit in `deps.lock` (and `nim.cfg` for a new one), rerun
  the setup, build the pages.

## Layout

```
src/gleam_in_nim/      the compiler, module names after the Rust ones
tests/                 tests; tests/all.nim runs them all
reference/             the pin of the Gleam snapshot and how to fetch it
tools/                 setup.sh and the tools of the port
docs/                  the site: every page is a nimib notebook
  all.nim              builds every page in one program; a new page adds its import here
  theme.nim            the look: fonts, colours, every CSS rule
  blocks.nim           the blocks of the pages, and usePage / usePost
  site.nim             the data the living pages share
  review.nim           the review mode (tabelline's, copied unchanged), assets/review.js
  data/                roadmap.json, coverage.json and other data of the living pages
  decisions/NNNN-*.md  the decision records; decisions.nim is their page
  porting.nim          the porting guide: how Rust is written in Nim here
  devlog/<slug>.nim    a post; devlog/data/<slug>/ its data, images and reference code
```

## A devlog post

- One notebook, `docs/devlog/<slug>.nim` (snake_case; `the_beam.nim` is served at
  `devlog/the-beam/`), and one line for it in `docs/all.nim`.
- Its first line is `## devlog: 12 Nov 2026 A | Title | One-sentence lede.` The letter orders
  the posts of one day (A, B, C, in the order they were written): take the next free one. The
  devlog index and the home page find the post from this line.
- Its second line is `## kind: research` (or `plan`, `port`, `tooling`).
- After `nbInit`, call `nb.usePost()`: it sets the output file, the look, the title, the
  contents and the review mode. Then Markdown and blocks, then `nbSave`.

```nim
## devlog: 12 Nov 2026 C | The BEAM, explained | What the BEAM is and how Gleam lives on it.
## kind: research
import nimib
import ../blocks

nbInit
nb.usePost()

nbText: """
## First section
Markdown here.
"""

nbSave
```

- A post tells one step as it happened. It is dated and not rewritten afterwards; typos, links
  and small corrections are fine. What must stay true goes in a living page or in this file.
- Lead with the findings. Readable on a phone in ten to fifteen minutes; long listings and raw
  data go in `nbFold`. End with `## What this changes for the port` and `## Sources`.
- Nim code that can run, runs (`nbCode`), so the page proves itself. Numbers in the text come
  from code or a data file, not typed by hand. Code in other languages is a fence with its
  language (`gleam`, `rust`, `erlang`, `elixir`, `js`, `python`, `sh`, `toml`, `json`), highlighted
  at build time.
- Say what was checked and what was not. A claim about Gleam, the BEAM or a person links its
  source. If a source could not be read, say so.

## Pages

- **Blocks, not HTML.** A page is Markdown in `nbText`, nimib's blocks, tabelline's `nbTable`
  and the blocks of `docs/blocks.nim`: `nbTitle`, `nbToc`, `nbNote(text, kind, title)`,
  `nbCards`/`nbCard`, `nbFold`, `nbPipeline`, `status`. No HTML tags in `nbText`, no CSS and no
  colours in a page. What is needed a second time becomes a block in `docs/blocks.nim`, and its
  CSS goes in `docs/theme.nim`, from the tokens. `nbRawHtml` is a last resort, with a comment
  saying why.
- Notes have kinds: `nkGleam` for how the original does it (pink), `nkNim` for how the port
  does it and why it differs (yellow), `nkDone` for what was verified, `nkWarning`,
  `nkQuestion` for what is open (for Pietro or a later step), `nkInfo`, `nkPlain`.
- Tables: a Markdown table for a few rows of text; tabelline (`tabella(rows): ...` with
  `optCssTheme()`, then `nbTable t`) for data.
- The look is Lucciola (`docs/theme.nim`), in two modes, giorno and notte. Colours are tokens:
  six values per mode (paper, ink, primary, secondary, warning, success), the rest mixed from
  them. Pink (primary) is Gleam, yellow (secondary) is Nim. Check a new block in both modes and
  at 390px wide.
- No remote assets: fonts, scripts and styles are in `docs/assets/`. `-d:singleFile` inlines
  them, for a page that must work alone.
- A living page (home, roadmap, coverage map, this one) is kept up to date and reads its data
  from `docs/data/`. A new living page gets a card on the home page (`docs/index.nim`).
- Every link leads somewhere. Pages are served as `<name>/index.html`, so a post links the
  roadmap as `../../roadmap/` and another post as `../<slug>/`. After building the pages,
  `nim r tools/links.nim` checks every link inside the site (files and `#anchors`) and to files
  of this repository; `nim r -d:ssl tools/links.nim --external` asks other sites too (404 and
  410 fail). CI runs the first on every run and the second once a week.
- `nim r tools/drift.nim --fail --allow:docs/theme.nim --allow:docs/blocks.nim
  --allow:docs/review.nim docs/` (in CI) fails when a page holds HTML, a style, a script or a
  hex colour.

## Review mode

- Every page has it (`usePage`, `usePost`): *Version N · updated D* under the lede, and
  **✎ Review** beside it. The version is the number of commits that changed the page's source,
  so CI checks out the whole history.
- Pietro selects text, comments, and exports the comments as Markdown with a YAML block
  (`format: nimib-review/5`). When such an export is pasted in a chat, follow the skill
  `.claude/skills/nimib-review/`.
- `docs/review.nim` and `docs/assets/review.js` are tabelline's, copied unchanged
  (`docs/assets/REVIEW_VERSION` has the commit). Do not edit them here: change the review mode
  in tabelline, then `sh tools/sync_review.sh`.

## Tone and privacy

- This is built in public. Professional, playful, kind to every project and person named;
  credit sources and people for their work.
- The site says in its footer that the project is independent and not affiliated with Gleam.
  Do not use Gleam's logo or mascot.
- Nothing personal about Pietro goes in the repository or on the site, beyond his being the
  author and reviewer.

## Handing work to Pietro

- He reviews on his phone. A reply that delivers a page links it rendered (the GitHub Pages
  URL after merge; before, a published preview), and links the pull request.
- A visual change comes with a phone-width screenshot.
