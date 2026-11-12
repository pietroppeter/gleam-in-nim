## The devlog's index, docs/devlog/index.html: every dated post, newest first, found by reading
## the first lines of each notebook in this folder (`blocks.devlogPosts`). A new post needs no
## entry here.
import std/[strformat]
import nimib
import ../blocks

let posts = devlogPosts()

nbInit
nb.doc.filename = docsDir / "devlog" / "index.html"
nb.usePage(section = "Devlog", cadence = "dated posts", title = "Devlog · gleam in nim", homeHref = "../",
           description = "Every step of porting the Gleam compiler to Nim, explained.")

nbTitle "Devlog", "Every step, explained", """
The Gleam compiler is being ported to Nim one well defined step at a time, and every step ships
with a post that says what was found and what was done. Some steps are research, some are
plans, some are code. A post is dated and not rewritten afterwards (a typo or a link gets
fixed); what must stay true lives in the [roadmap](../roadmap/) and the [coverage map](../coverage/).
"""

nbCards "the posts, newest first":
  for p in posts:
    nbCard(p.title, p.slug & "/", &"{p.date} · {p.kind}", (if p.kind == "port": nkGleam elif p.kind == "research": nkNim else: nkInfo)):
      nbText p.lede
nbSave
