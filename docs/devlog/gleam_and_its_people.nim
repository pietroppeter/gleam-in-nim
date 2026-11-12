## devlog: 12 Nov 2026 B | Gleam, its people and its programs | Who makes Gleam, who uses it, and what a Nim port of its compiler is signing up for.
## kind: research
import std/[json, os, strformat, strutils, sequtils]
import nimib
import ../blocks

nbInit
nb.usePost()

const dataDir = currentSourcePath().parentDir / "data" / "gleam_and_its_people"
let facts = parseFile(dataDir / "facts.json")
let people = parseFile(dataDir / "people.json")

proc readTsv(name: string): seq[seq[string]] =
  ## Rows of a tab separated file, header dropped.
  for line in lines(dataDir / name):
    result.add line.split('\t')
  result.delete 0

let news = readTsv("news.tsv")          # date, slug, title, subtitle, author
let topRepos = readTsv("top_repos.tsv") # repo, stars, licence, pushed, archived, description

proc thousands(n: int): string = insertSep($n, ',')

let
  rust = facts["compiler_snapshot"]["rust_lines"]
  snaps = facts["compiler_snapshot"]["snapshot_files"]
  rustTotal = toSeq(rust.pairs).mapIt(it.val.getInt).foldl(a + b)
  snapTotal = toSeq(snaps.pairs).mapIt(it.val.getInt).foldl(a + b)
  survey = facts["survey_2024"]

nbText: &"""
## The short version

Before porting a compiler it helps to know whose house you are walking into. So this first
research post is not about lexers. It is about Gleam the language, the people who make it,
and the programs written in it, because those programs are what our compiler will have to
compile.

- **Gleam is small on purpose.** A statically typed functional language with one way to do
  most things, no macros, no type classes, no exceptions. That is very good news for a port.
- **It runs in two places.** On the BEAM (the Erlang virtual machine) and on JavaScript
  runtimes. Version 1.0 shipped on 4 March 2024. The snapshot we port is
  **{facts["gleam"]["latest_release"].getStr}**, from the v1.19 line released on 5 October 2026.
- **The compiler is written in Rust** and is bigger than the language looks: about
  **{thousands(rustTotal)} lines of Rust** across four crates, tests included, checked by
  **{thousands(snapTotal)} snapshot files**.
- **There is no written specification.** The language tour, the test suite and the changelog
  play that role.
- **A core team of four** leads the project, funded by sponsors rather than by a company.
- **The project does not accept AI generated contributions.** We respect that fully: this port
  lives in its own repository, reads upstream, and sends nothing back.
- **Real programs are easy to find.** GitHub counts {thousands(facts["ecosystem"]["github_repos_in_gleam"].getInt)}
  repositories in Gleam, from thirty line libraries to a JavaScript engine. The next posts turn
  them into a test corpus.
"""

nbText: """
## Gleam in five minutes

Here is a complete Gleam program. If you have written Elm, Rust or OCaml, most of it reads
itself.

```gleam
import gleam/int
import gleam/io
import gleam/list

pub type Shape {
  Circle(radius: Float)
  Rectangle(width: Float, height: Float)
}

pub fn area(shape: Shape) -> Float {
  case shape {
    Circle(radius:) -> 3.14 *. radius *. radius
    Rectangle(width:, height:) -> width *. height
  }
}

pub fn main() {
  [1, 2, 3]
  |> list.map(fn(x) { x * 2 })
  |> list.fold(0, int.add)
  |> int.to_string
  |> io.println
}
```

What the language has:

- Custom types (algebraic data types) and exhaustive pattern matching with `case`.
- Full type inference in the Hindley-Milner family, with generics. Annotations are optional
  and conventional on public functions.
- Immutable data everywhere. Lists, tuples, strings, bit arrays, and dictionaries from the
  standard library.
- The pipe operator `|>` and `use` expressions, which flatten callback style code.
- `Result` values for errors. No exceptions, no null.
- Separate operators for integers and floats (`+` and `+.`), so there is no overloading to
  resolve.
- Labelled arguments, opaque types, constants, and a module system with one module per file.
- `@external` functions, the door to Erlang and JavaScript code.
- A formatter, a language server, a build tool and a package manager in the same binary.

What it leaves out is just as much a part of the design. The official FAQ lists features that
are **not planned**: exception based error handling, function and operator overloading,
implicit arguments, Lisp style macros, mutation, object orientation, optional arguments, type
classes or traits, untagged unions, and a few more. Metaprogramming is the one door left ajar,
with a written process for anybody who wants to propose a design.

For a compiler writer every line of that list is a gift: no overload resolution, no trait
solver, no macro expander, no effect system. The hard parts that remain are type inference,
exhaustiveness checking, two code generators, and a very polished set of error messages.

### Three outputs, not two

The FAQ now describes three compile targets:

1. **Erlang abstract forms**, the syntax tree format the Erlang compiler uses internally. Since
   v1.19 this is what the build tool produces when you run Gleam on Erlang.
2. **Erlang source code**, kept for teaching, for testing the compiler, and for other build tools.
3. **JavaScript source code**, with optional TypeScript declarations.

The first one is a month old. Giacomo Cavalieri rewrote the Erlang code generator over two
releases, and the release post is titled, with some glee, *Gleam doesn't compile to Erlang
source anymore*. We are porting a snapshot taken right after that change, so the abstract
forms generator is part of our job.
"""

proc timeline(): string =
  ## The milestones are picked by hand; titles and dates come from news.tsv.
  const picks = ["hello-gleam", "v0.16-gleam-compiles-to-javascript",
    "v0.21-introducing-the-gleam-language-server", "v0.25-introducing-use-expressions",
    "v0.26-incremental-compilation-and-deno", "v0.33-exhaustive-gleam", "gleam-version-1",
    "fault-tolerant-gleam", "welcome-lambda", "hello-echo-hello-git",
    "gleam-javascript-gets-30-percent-faster", "javascript-source-maps",
    "gleam-doesnt-compile-to-erlang-source-anymore"]
  result = "| Date | Post | What it says |\n|---|---|---|\n"
  for row in news:
    if row[1] in picks:
      result.add &"| {row[0]} | [{row[2]}](https://gleam.run/news/{row[1]}/) | {row[3]} |\n"

proc postsPerYear(): string =
  var years: seq[string]
  for row in news:
    let y = row[0][0 .. 3]
    if y notin years: years.add y
  result = "| Year | Posts on gleam.run |\n|---|---|\n"
  for y in years:
    result.add &"| {y} | {news.countIt(it[0].startsWith(y))} |\n"

nbText: &"""
## A short history

Gleam began around 2016 as an experiment by Louis Pilfold. The prototype compilers were written
in Erlang. The FAQ explains why that did not last: without static types, refactoring the
compiler was slow and error prone, so it was rewritten in Rust. A language rewritten once
already, for the sake of its own maintainability, is a fitting subject for another rewrite.

The first public release, v0.1, is dated 15 April 2019. Since then the project has published
{news.len} posts on gleam.run, almost all of them release notes written by Louis. These are the
ones that mark a turn:

{timeline()}

The rhythm is steady: a release roughly every six weeks, each with a post that explains what
changed and why.

{postsPerYear()}
"""

nbText: &"""
## How Gleam is used

**Web backends.** The usual stack is `wisp` (web framework) on `mist` (HTTP server) on
`glisten` (TCP), with `pog` or `sqlight` for the database and `squirrel` to generate typed
query functions from SQL files. All of this runs on the BEAM and inherits its concurrency and
fault tolerance through `gleam_otp`.

**Web frontends.** `lustre` brings the Elm architecture to Gleam, compiles to JavaScript, and
can also render on the server. It is the most starred project written in Gleam.

**Tools and scripts.** Command line programs, static sites, code generators. Since v1.17 a
project can be exported as a single `escript` file.

**Itself.** gleam.run, the package index, the language tour and the developer survey are all
Gleam programs. That is handy for us: the project's own websites are real applications with
permissive licences.

How many people? The 2024 developer survey is the best public number. It had
**{survey["responses"].getInt} responses**; {survey["gleam_users"].getInt} said they use Gleam and
{survey["in_production"].getInt} said they run it in production, less than a year after 1.0.
In the 2025 Stack Overflow survey Gleam entered the list of most admired languages in second
place at {facts["stack_overflow_2025"]["admired_percent"].getInt}%, right behind Rust, and
Thoughtworks added it to its Technology Radar.

Two production stories are published as case studies on gleam.run. **Strand**, a London
marketing agency, runs its financial project management system in Gleam and chose it for
maintainability with a very small team. **Uncover**, in São Paulo, builds the query engine of
its marketing analytics platform in Gleam and reports that the only bugs they see are mistakes
in business logic.
"""

proc peopleTable(group: string, withRole: bool): string =
  result = if withRole: "| Who | Role | Known for |\n|---|---|---|\n"
           else: "| Who | Known for |\n|---|---|\n"
  for p in people[group]:
    let who = &"""[{p["name"].getStr}](https://github.com/{p["github"].getStr})"""
    if withRole: result.add &"""| {who} | {p["role"].getStr} | {p["known_for"].getStr} |""" & "\n"
    else: result.add &"""| {who} | {p["known_for"].getStr} |""" & "\n"

nbText: &"""
## The people

Gleam is not owned by a company or a university. It is funded by sponsorship, with
{facts["ecosystem"]["sponsors_listed"].getInt} sponsors listed on the website today and
{facts["ecosystem"]["featured_sponsors"].to(seq[string]).join(", ")} as featured ones. Lambda
Class became the primary sponsor in August 2024; before that Fly.io sponsored the project
through the long road to 1.0.

The sponsor page names four core team members:

{peopleTable("core_team", true)}

Around them is a community that calls itself *Gleamlins*. A few of the people whose code you
will meet again in our test corpus:

{peopleTable("community", false)}

This is a small sample and it leaves out many good people. The changelog credits every
contributor by name on every entry, which says something about how the project is run.

The community meets on Discord, on GitHub Discussions, at meetups, and since this year at its
own conference. **Gleam Gathering** was held in Bristol on 21 February 2026, the talks are on
YouTube, and the 2027 edition is announced for London.

### House rules we will follow

Gleam's contribution guide is explicit: the project does not accept contributions from AI
agents, and bug reports, pull request descriptions and comments must be written by a human.
gleam-in-nim is written with heavy use of AI, in the open, and says so. So the rule for this
project is simple. We read everything upstream publishes, we credit it, we keep licence
notices, and we do not open issues or pull requests there. If the port ever finds a real bug
in Gleam, a human reports it in their own words.
"""

proc reposTable(n: int): string =
  result = "| Project | Stars | What it is |\n|---|---|---|\n"
  for row in topRepos[0 ..< n]:
    result.add &"| [{row[0]}](https://github.com/{row[0]}) | {row[1]} | {row[5]} |\n"

nbText: &"""
## The programs

GitHub lists {thousands(facts["ecosystem"]["github_repos_in_gleam"].getInt)} repositories whose
main language is Gleam, and the compiler itself has
{thousands(facts["gleam"]["github_stars"].getInt)} stars. Here are the twenty most starred
Gleam projects on 12 November 2026:

{reposTable(20)}

Three groups are worth pointing at, because they matter for a compiler port.

**Big, healthy codebases.** `lustre`, `wisp`, `mist`, `squirrel` and the standard library are
maintained, tested, and use the whole language. If we compile them and their test suites pass,
we are doing well.

**Small ones.** `argv` is thirty lines. `envoy`, `snag`, `justin` and `filepath` are a few
hundred. The language tour is sixty three tiny programs, one per feature. These are the first
rungs of the ladder.

**Compilers in Gleam, and Gleam compilers elsewhere.** This is the surprising group:

- `glexer` is a Gleam lexer written in Gleam, and `glance` is a Gleam parser written in Gleam.
  Both are widely used, so they give us a second opinion on tokens and syntax trees.
- `glimpse` is a type checker for `glance` trees that follows the official one closely.
- `gig` is a Gleam compiler written in Gleam.
- `tree-sitter-gleam` is an independent grammar with its own parse tests.
- `glistix` is a fork of the official compiler that adds a third backend, for Nix.
- `eyg` is a whole language built in Gleam, and `arc` is a JavaScript engine for the BEAM
  written in Gleam, the largest Gleam codebase we found.

We are not the first to reimplement a part of Gleam. We may be the first to try all of it in
Nim.
"""

nbText: """
## What this changes for the port

1. **Scope.** The target is three outputs (Erlang abstract forms, Erlang source, JavaScript),
   plus the formatter, the build tool and, at the far end, the language server. The plan should
   say which of these count as "the compiler" for a first complete milestone.
2. **Abstract forms are in.** We pinned the snapshot after v1.19, so the new Erlang generator is
   the one to port. Erlang source output still exists and is the easier one to compare by eye.
3. **No spec means tests are the spec.** The snapshot files in the Rust repository are our
   oracle. The language tour is the reference for what users expect.
4. **Error messages are a feature.** Release posts spend as much time on diagnostics as on
   semantics. A port that only gets the happy path right is not a port of Gleam.
5. **Independent implementations exist.** `glexer`, `glance`, `glimpse` and `tree-sitter-gleam`
   let us cross-check each stage against something other than the code we are translating.
6. **Stay a good guest.** Read only upstream, credits everywhere, licence notices kept, no AI
   written text sent to the Gleam project.
7. **A corpus is ready to build.** The companion post *A corpus of real Gleam* pins the
   projects named here at exact commits with their licences.

## Sources

- [gleam.run](https://gleam.run), its [FAQ](https://gleam.run/frequently-asked-questions/),
  [news](https://gleam.run/news/), [case studies](https://gleam.run/case-studies/),
  [sponsor page](https://gleam.run/sponsor/) and [community page](https://gleam.run/community/),
  read from the source in [gleam-lang/website](https://github.com/gleam-lang/website).
- [gleam-lang/gleam](https://github.com/gleam-lang/gleam) at tag v1.19.2: `README.md`,
  `CONTRIBUTING.md`, `CHANGELOG.md`, `docs/`.
- [Gleam doesn't compile to Erlang source anymore](https://gleam.run/news/gleam-doesnt-compile-to-erlang-source-anymore/), the v1.19 release post.
- [Developer Survey 2024 results](https://gleam.run/news/developer-survey-2024-results/).
- [Stack Overflow Developer Survey 2025](https://survey.stackoverflow.co/2025/technology/).
- [Thoughtworks Technology Radar: Gleam](https://www.thoughtworks.com/radar/languages-and-frameworks/gleam).
- [awesome-gleam](https://github.com/gleam-lang/awesome-gleam) and the GitHub search API for
  the list of projects and star counts.
- [Gleam Gathering](https://gleamgathering.com/) and its [YouTube channel](https://www.youtube.com/@GleamGathering).
- The data behind every number on this page is in `docs/devlog/data/gleam_and_its_people/`.
"""

nbSave
