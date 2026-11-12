# gleam in nim ✦

The [Gleam](https://gleam.run) compiler, ported to [Nim](https://nim-lang.org) one explained
step at a time.

**Read it:** https://pietroppeter.github.io/gleam-in-nim/

Gleam is a friendly, statically typed language for the BEAM and for JavaScript, with a compiler
written in Rust. This repository ports a snapshot of that compiler (v1.19.2) to Nim. Every step
is a well defined task, checked against the original, and ships with an explainer: what was
found, what was done, what comes next.

It is a project made to learn: how a real compiler is made, and how far an AI model can carry a
long port when a person reviews every step. It is built in public by Pietro Peterlongo with
Claude. It is not a replacement for Gleam's compiler and it is not affiliated with the Gleam
project, which is made by Louis Pilfold and the Gleam contributors.

## The site

| Page | What it is |
|---|---|
| [Devlog](https://pietroppeter.github.io/gleam-in-nim/devlog/) | Every step, explained: research, plans and the port itself. Dated posts. |
| [Roadmap](https://pietroppeter.github.io/gleam-in-nim/roadmap/) | The phases and their steps, and where each stands. Kept up to date. |
| [Coverage map](https://pietroppeter.github.io/gleam-in-nim/coverage/) | The Rust compiler module by module, and how much of it is in Nim. Kept up to date. |
| [For coding agents](https://pietroppeter.github.io/gleam-in-nim/agents/) | The working rules of this repository ([AGENTS.md](AGENTS.md)). |

Every page is a [nimib](https://github.com/pietroppeter/nimib) notebook in `docs/`: the code
on a page ran when the page was built. Every page has a review mode (**✎ Review**): select
text, comment, export the comments for a coding agent.

## Working on it

```sh
sh tools/setup.sh        # Nim if missing, PCRE, the docs' dependencies (pinned in deps.lock)
nim r tests/all.nim      # the tests
nim r docs/all.nim       # every page, into docs/ (not committed: CI builds and deploys them)
```

The rules are in [AGENTS.md](AGENTS.md).

## Licence

MIT (see [LICENSE](LICENSE)). Files ported from the Gleam compiler, which is Apache-2.0, say so
in their header and keep its notice.
