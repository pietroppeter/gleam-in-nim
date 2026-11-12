## The review mode of a page: open it with **✎ Review**, select text, comment on it, and export
## the comments for a coding agent. One module for now, with its blocks, its styles and its
## script (`assets/review.js`), so it can move to nimib as it is.
import std/[json, os, osproc, strutils, strformat, times, hashes]
import nimib
import theme

func esc(s: string): string = s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))
func inline(md: string): string = markdownToHtml(md).strip.replace("<p>", "").replace("</p>", "")

# ---------------------------------------------------------------------------------------- styles

const reviewRules = """
/* the colours and fonts the review mode uses, for a page that has none of its own (a plain nimib
   page): `:where` weighs nothing, so a page's own tokens (tabelline's, on :root) win */
:where(html) { --paper: #fffdf8; --ink: #1f1f1f; --surface: #f6f3ec; --line: #c9c4ba; --shade: #e7e2d8;
  --muted: #6b675f; --secondary: #6aa9d6; --secondary-soft: #d6e8f5; --primary-text: #8a3550;
  --neutral-1: #ece8df; --font: system-ui, sans-serif; --mono: ui-monospace, monospace; }
/* the review mode (review.nim, nbReview): a Review button, then marks on the text, a bar at
   the bottom, the comment's sheet at the top, export and history */
.rv-only { display: none; }
body.rv-on .rv-only { display: block; }
.rv-bar[hidden], .rv-panel[hidden] { display: none; }
.rv-enter { display: flex; flex-wrap: wrap; align-items: center; gap: .4rem .8rem; margin: .8rem 0 1.4rem; color: var(--muted); font-size: .92rem; }
.rv-enter .rv-version { font-weight: 700; color: var(--ink); }
.rv-toggle { font: inherit; color: var(--ink); background: transparent; border: 1px solid var(--line); border-radius: 0;
  min-height: 44px; padding: 0 .8rem; cursor: pointer; }
.rv-toggle[aria-pressed="true"] { border-color: var(--ink); box-shadow: inset 0 -3px 0 var(--secondary); }
body.rv-on { padding-bottom: calc(4.6rem + env(safe-area-inset-bottom, 0px)); }
mark.rv-mark { background: var(--secondary-soft); color: inherit; box-shadow: 0 2px 0 var(--secondary); cursor: pointer; }
mark.rv-mark.rv-current { background: var(--secondary); }
.rv-bar { position: fixed; left: 0; right: 0; bottom: 0; z-index: 50; display: flex; align-items: center; gap: .3rem;
  justify-content: center; padding: .45rem max(.5rem, env(safe-area-inset-right, 0px)) calc(.45rem + env(safe-area-inset-bottom, 0px)) max(.5rem, env(safe-area-inset-left, 0px));
  background: var(--surface); border-top: 3px solid var(--ink); font: 400 15px/1.2 var(--font); }
.rv-bar button, .rv-sheet button { font: inherit; color: var(--ink); background: var(--paper); border: 1px solid var(--line);
  border-radius: 0; min-height: 44px; min-width: 44px; padding: 0 .7rem; cursor: pointer; white-space: nowrap; }
.rv-bar button { padding: 0 .55rem; }
.rv-bar button[data-do="delete"] { color: var(--primary-text); }
.rv-bar button:disabled { color: var(--muted); border-color: var(--shade); cursor: default; }
.rv-bar button[data-do="prev"], .rv-bar button[data-do="next"] { font-size: 1.4rem; padding: 0; }
.rv-bar .rv-count { min-width: 3.2rem; text-align: center; color: var(--muted); font-size: .85rem; }
.rv-bar .rv-add, .rv-sheet .rv-save { background: var(--ink); color: var(--paper); border-color: var(--ink); font-weight: 700; }
.rv-bar .rv-add.rv-selected { background: var(--secondary); color: var(--ink); border-color: var(--ink); }
dialog.rv-sheet { width: 100%; max-width: 40rem; margin: 0 auto auto; padding: 1rem max(1rem, env(safe-area-inset-right, 0px)) 1rem max(1rem, env(safe-area-inset-left, 0px));
  border: 0; border-bottom: 3px solid var(--ink); background: var(--surface); color: var(--ink); font: 400 16px/1.45 var(--font);
  max-height: 90vh; overflow-y: auto; }
dialog.rv-sheet::backdrop { background: color-mix(in oklab, var(--ink) 30%, transparent); }
.rv-sheet .rv-where { margin: 0 0 .4rem; font-weight: 700; }
.rv-sheet textarea { display: block; width: 100%; margin-top: .2rem; font: 16px/1.4 var(--font); color: var(--ink);
  background: var(--paper); border: 1px solid var(--line); border-radius: 0; padding: .5rem; }
.rv-export textarea { font: 16px/1.45 var(--mono); white-space: pre-wrap; }   /* 16px: a phone zooms on smaller fields */
.rv-sheet .rv-actions { display: flex; flex-wrap: wrap; gap: .4rem; justify-content: flex-end; }
.rv-sheet .rv-left { margin-right: auto; }
.rv-sheet .rv-danger { color: var(--primary-text); }
/* the comment's sheet: at the top, small, not modal: the bar and the page stay in reach */
.rv-panel { position: fixed; top: 0; left: 0; right: 0; z-index: 60; max-width: 40rem; margin: 0 auto;
  padding: .5rem max(.6rem, env(safe-area-inset-right, 0px)) .6rem max(.6rem, env(safe-area-inset-left, 0px));
  background: var(--surface); border-bottom: 3px solid var(--ink); color: var(--ink); font: 400 16px/1.45 var(--font);
  animation: rv-down .2s ease-out; }
.rv-panel .rv-whole { margin: 0 0 .3rem; color: var(--muted); font-size: .85rem; }
.rv-panel .rv-note { margin: 0; }
.rv-panel .rv-thumbs { margin-top: .45rem; }
.rv-panel button { font: inherit; color: var(--ink); background: var(--paper); border: 1px solid var(--line); border-radius: 0; cursor: pointer; }
/* history: one line per version */
.rv-versions { list-style: none; margin: 0 0 .8rem; padding: 0; }
.rv-versions li { display: flex; flex-wrap: wrap; align-items: center; gap: .5rem; min-height: 48px; padding: .3rem 0; border-bottom: 1px solid var(--shade); }
.rv-versions .rv-old { display: flex; gap: .4rem; }
.rv-versions .rv-old[hidden] { display: none; }
.rv-versions a { color: var(--ink); }
.rv-versions .rv-date { flex: 1; color: var(--muted); font-size: .9rem; }
.rv-versions .rv-n { font-size: .85rem; }
/* a screenshot, as large as the screen allows */
dialog.rv-zoom { width: 100vw; height: 100vh; max-width: 100vw; max-height: 100vh; margin: 0; padding: 0; border: 0; background: transparent; }
dialog.rv-zoom[open] { display: flex; align-items: center; justify-content: center; }
dialog.rv-zoom::backdrop { background: color-mix(in oklab, var(--ink) 88%, transparent); }
dialog.rv-zoom img { max-width: 100%; max-height: 100%; object-fit: contain; }
dialog.rv-zoom button { position: fixed; top: max(.5rem, env(safe-area-inset-top, 0px)); right: .5rem; min-width: 44px; min-height: 44px;
  font-size: 1.5rem; color: var(--ink); background: var(--paper); border: 1px solid var(--line); border-radius: 0; }
.rv-thumb img, .rv-shot img { cursor: zoom-in; }
dialog.rv-sheet[open] { animation: rv-down .2s ease-out; }
@keyframes rv-down { from { transform: translateY(-100%); } }
/* the note: an editable box, so a phone offers to paste a screenshot in it */
.rv-note { min-height: 3.2rem; max-height: 9rem; overflow-y: auto; padding: .5rem; font: 16px/1.4 var(--font);
  background: var(--paper); border: 1px solid var(--line); white-space: pre-wrap; overflow-wrap: anywhere; }
.rv-note:empty::before { content: attr(data-placeholder); color: var(--muted); }
.rv-note:focus { outline: 2px solid var(--secondary); outline-offset: -1px; }
.rv-thumbs { display: flex; flex-wrap: wrap; gap: .5rem; }
.rv-thumb { position: relative; }
.rv-thumb img { display: block; height: 4.5rem; width: auto; border: 1px solid var(--line); }
.rv-thumb button { position: absolute; top: 0; right: 0; min-height: 32px; min-width: 32px; padding: 0; font-size: 1.1rem; }
/* the export: each screenshot with its own Copy */
.rv-shotlist { display: flex; flex-direction: column; gap: .35rem; margin: 0 0 .6rem; }
.rv-shot { display: flex; align-items: center; gap: .5rem; font-size: .85rem; color: var(--muted); }
.rv-shot img { height: 2.75rem; width: auto; border: 1px solid var(--line); }
.rv-shot span { flex: 1; overflow-wrap: anywhere; }
"""

const reviewQuaderno = """
mark.rv-mark { background: var(--highlight); box-shadow: 0 2px 0 var(--red-pen); }
mark.rv-mark.rv-current { background: var(--postit); box-shadow: 0 2px 0 var(--red-pen), 0 0 0 2px var(--red-pen); }
.rv-bar { font-family: var(--font); }
"""

const reviewCss* = reviewRules & scoped(reviewQuaderno, "html[data-tema=\"quaderno\"]")
  ## The styles of the review mode, added only to the pages that use it.

# ---------------------------------------------------------------------------------------- blocks

const reviewJs* = staticRead(currentSourcePath().parentDir / "assets" / "review.js")
  ## The script, kept as a file of its own (`assets/review.js`) so it can be read and shown.

type ReviewVersion* = object
  ## The version of a page: `number` (the commits that touched its source, `+` when the page was
  ## built from uncommitted changes; outside git, a hash of the source), the last `commit`'s short
  ## hash and its date, `updated` (both empty outside git).
  number*, commit*, updated*: string

proc reviewVersion*(commits: openArray[string], dirty = false, source = ""): ReviewVersion =
  ## The version from `git log --format=%h|%cs -- <source>`, newest first: one line per commit.
  ## No commits (outside git): the first 7 characters of a hash of the `source` text.
  if commits.len == 0:
    return ReviewVersion(number: toHex(hash(source)).toLowerAscii[^7 .. ^1])
  let last = commits[0].split('|')
  ReviewVersion(number: $commits.len & (if dirty: "+" else: ""), commit: last[0],
                updated: (if last.len > 1: parse(last[1], "yyyy-MM-dd", utc()).format("d MMM yyyy") else: ""))

proc repoRoot(file: string): string =
  var dir = file.parentDir
  while dir.len > 1 and not dirExists(dir / ".git") and not fileExists(dir / ".git"): dir = dir.parentDir
  if dirExists(dir / ".git") or fileExists(dir / ".git"): dir else: ""

proc gitVersion*(file: string): ReviewVersion =
  ## The version of `file` (a notebook) from git, at build time; see `reviewVersion`.
  let root = repoRoot(file)
  if root.len > 0:
    let rel = file.relativePath(root)
    let (log, code) = execCmdEx("git log --format=%h%x7C%cs -- " & quoteShell(rel), workingDir = root)
    if code == 0 and log.strip.len > 0:
      let (status, _) = execCmdEx("git status --porcelain -- " & quoteShell(rel), workingDir = root)
      return reviewVersion(log.strip.splitLines, dirty = status.strip.len > 0)
  reviewVersion([], source = (if fileExists(file): readFile(file) else: file))

func reviewTag*(page, title, source: string, v: ReviewVersion): string =
  ## The settings the script reads: an empty `<div id="review">` with them as data attributes.
  &"""<div id="review" hidden data-page="{esc(page)}" data-title="{esc(title)}" data-source="{esc(source)}" """ &
    &"""data-version="{esc(v.number)}" data-commit="{esc(v.commit)}" data-updated="{esc(v.updated)}"></div>"""

newNbBlock(NbReview):
  page: string
  title: string
  source: string
  number: string
  commit: string
  updated: string
  script: string     ## the script's address, or "" to inline it
  toHtml:
    reviewTag(blk.page, blk.title, blk.source, ReviewVersion(number: blk.number, commit: blk.commit, updated: blk.updated)) &
      (if blk.script.len > 0: &"""<script src="{esc(blk.script)}" defer></script>"""
       else: "<script>\ndocument.addEventListener('DOMContentLoaded', function () {\n" & reviewJs & "});\n</script>")

func `$`*(v: ReviewVersion): string =
  &"version: {v.number}, commit: {v.commit}, updated: {v.updated}"

type ReviewSettings* = object
  ## What the export names: `page` (the key the comments are kept under), `source` and `title`.
  page*, source*, title*: string

func `$`*(s: ReviewSettings): string =
  &"page: {s.page}\nsource: {s.source}\ntitle: {s.title}"

proc reviewSettings*(file, root: string, title: string, page = "", source = ""): ReviewSettings =
  ## The settings `nbReview` writes for the notebook `file` in the repository at `root` ("" outside
  ## git): the source is the file from the root, the page is the source; either can be given.
  let source = if source.len > 0: source
               elif root.len > 0: file.relativePath(root).replace('\\', '/')
               else: file.extractFilename
  ReviewSettings(page: (if page.len > 0: page else: source), source: source, title: title)

proc review*(nb: var Nb, page = "", title = "", source = "", script = "", css = true) =
  ## See `nbReview`. `css = false` leaves the styles out, for a site that puts `reviewCss` in
  ## its shared style sheet.
  let file = nb.doc.thisFile.string
  let s = reviewSettings(file, repoRoot(file), (if title.len > 0: title else: nb.doc.context{"title"}.getStr),
                         page, source)
  let v = gitVersion(file)
  if css:
    nb.doc.context["stylesheet"] = %(nb.doc.context["stylesheet"].getStr & "\n<style>\n" & reviewCss & "</style>")
  nb.add newNbReview(page = s.page, title = s.title, source = s.source,
                     number = v.number, commit = v.commit, updated = v.updated, script = script)

template nbReview*(tpage = "", ttitle = "", tsource = "", tscript = "") =
  ## The review mode on this page. Reading is the default: the page shows its version, from git
  ## (*Version 12 · updated 10 Nov 2026*), under its lede or title, and **✎ Review** beside it,
  ## which opens and closes the review mode. With no arguments, everything comes from the
  ## notebook: its source file (named in the export, and the key the comments are kept under in
  ## the browser), its title and its version. `tpage` keeps the key when the file is renamed;
  ## `tscript` is the address of a shared `review.js`: empty, the script is inlined and the page
  ## stays one file.
  nb.review(tpage, ttitle, tsource, tscript)

newNbBlock(NbVersion):
  toHtml:
    """<p class="rv-enter"></p>"""

template nbVersion*() =
  ## Where the version line and **✎ Review** go, when not under the lede or the title: the
  ## script writes them here.
  nb.add newNbVersion()

newNbBlock(NbInReview of NbContainer):
  toHtml:
    """<div class="rv-only">""" & nbContainerToHtml(blk, nb) & "</div>"

template nbInReview*(body: untyped) =
  ## Blocks shown only while the review mode is open, such as what is new in this version.
  let only = newNbInReview()
  nb.withContainer(only):
    body
  nb.add only
