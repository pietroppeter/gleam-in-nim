## The blocks of the pages and the page itself (`usePage`, `usePost`).
##
## A page is Markdown in `nbText`, nimib's blocks, tabelline's `nbTable`, and the blocks here:
##
## - `nbTitle kicker, title, lede`: the top of a page (a post gets it from `usePost`)
## - `nbToc`: the contents, from the `##` and `###` headings
## - `nbNote text, kind, title`: a sheet set apart (`nkPlain`, `nkInfo`, `nkGleam`, `nkNim`,
##   `nkDone`, `nkWarning`, `nkQuestion`)
## - `nbCards what: nbCard(title, href, small, kind): ...`: a grid of cards
## - `nbFold label: ...`: blocks folded away under a line to press
## - `nbPipeline stages`: the stages of the compiler as lamps, lit when ported
## - `status(s)`: a status as Markdown-safe text for a table cell
##
## No HTML in a page, no CSS, no colours: what is needed twice becomes a block here, and its CSS
## goes in `theme.nim`, from the tokens. Code fences in Markdown are highlighted at build time
## (Nim, Gleam, Rust, Erlang, Elixir, JavaScript, Python, shell, TOML, YAML, JSON).

import std/[json, os, strutils, strformat, times, algorithm]
import nimib
import theme, review
export theme, os   # os: every page builds paths with `/`

const
  repoUrl* = "https://github.com/pietroppeter/gleam-in-nim"
  siteUrl* = "https://pietroppeter.github.io/gleam-in-nim/"
  docsDir* = currentSourcePath().parentDir
  repoDir* = docsDir.parentDir

func esc*(s: string): string = s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))
func inline(md: string): string =
  ## Markdown for one line: the text without its paragraph.
  markdownToHtml(md).strip.replace("<p>", "").replace("</p>", "")

# ----------------------------------------------------------------------------- headings and TOC

func slugify*(s: string): string =
  ## The anchor of a heading: lowercase words joined by `-`.
  var last = '-'
  for c in s.toLowerAscii:
    if c in {'a'..'z', '0'..'9'}:
      result.add c
      last = c
    elif last != '-':
      result.add '-'
      last = '-'
  result = result.strip(chars = {'-'})

func stripInline(s: string): string =
  ## Heading text without Markdown marks or tags, for anchors and the contents.
  var inTag = false
  for c in s:
    if c == '<': inTag = true
    elif c == '>': inTag = false
    elif not inTag and c notin {'*', '`', '_'}: result.add c

func headingsOf*(markdownText: string): seq[(int, string)] =
  ## The `##` and `###` headings of a Markdown text, with their level (outside code fences).
  var fence = false
  for line in markdownText.splitLines:
    if line.strip.startsWith("```"): fence = not fence
    if fence: continue
    if line.startsWith("## "): result.add (2, line[3 .. ^1].strip.stripInline)
    elif line.startsWith("### "): result.add (3, line[4 .. ^1].strip.stripInline)

func unescapeHtml(s: string): string =
  s.multiReplace(("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&"))

func addHeadingIds(html: string, up = false): string =
  ## `<h2>Text</h2>` becomes `<h2 id="text">Text</h2>`; on a page with contents (`up`), also a
  ## way back to them, drawn by CSS so the heading's text stays the same for anchors and quotes.
  result = html
  for tag in ["h2", "h3"]:
    var res = ""
    var i = 0
    let open = "<" & tag & ">"
    let close = "</" & tag & ">"
    while true:
      let a = result.find(open, i)
      if a < 0: break
      let b = result.find(close, a)
      if b < 0: break
      let inner = result[a + open.len ..< b]
      res.add result[i ..< a] & "<" & tag & " id=\"" & slugify(unescapeHtml(stripInline(inner))) & "\">" & inner &
        (if up: "<a class=\"up\" href=\"#contents\" aria-label=\"Back to the contents\"></a>" else: "") & close
      i = b + close.len
    res.add result[i .. ^1]
    result = res

# --------------------------------------------------------------------------------- highlighting


type Lang = object
  names: seq[string]       ## the tags of a fence
  keywords, literals: seq[string]
  comments: seq[string]    ## what starts a comment that runs to the end of the line
  types: bool              ## Capitalised words are types (or constructors)
  atSign: bool             ## @words are meta (attributes, decorators, module attributes)

const langs = [
  Lang(names: @["gleam"], comments: @["//"], types: true, atSign: true,
       keywords: @["as", "assert", "auto", "case", "const", "delegate", "derive", "echo", "else", "fn", "if",
                   "implement", "import", "let", "macro", "opaque", "panic", "pub", "test", "todo", "type", "use"],
       literals: @["True", "False", "Nil"]),
  Lang(names: @["rust", "rs"], comments: @["//"], types: true,
       keywords: @["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
                   "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
                   "return", "self", "Self", "static", "struct", "super", "trait", "type", "unsafe", "use",
                   "where", "while"],
       literals: @["true", "false", "None", "Some", "Ok", "Err"]),
  Lang(names: @["erlang", "erl"], comments: @["%"],
       keywords: @["after", "and", "andalso", "band", "begin", "bnot", "bor", "bsl", "bsr", "bxor", "case",
                   "catch", "cond", "div", "end", "fun", "if", "let", "maybe", "not", "of", "or", "orelse",
                   "receive", "rem", "try", "when", "xor"],
       literals: @["true", "false", "ok", "error", "undefined", "nil"]),
  Lang(names: @["elixir", "ex"], comments: @["#"], types: true, atSign: true,
       keywords: @["after", "and", "case", "catch", "cond", "def", "defp", "defmodule", "defstruct", "defmacro",
                   "defprotocol", "defimpl", "do", "else", "end", "fn", "for", "if", "import", "in", "not", "or",
                   "quote", "raise", "receive", "require", "rescue", "try", "unless", "unquote", "use", "when", "with"],
       literals: @["true", "false", "nil"]),
  Lang(names: @["js", "javascript", "ts", "typescript", "mjs"], comments: @["//"],
       keywords: @["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "else",
                   "export", "extends", "for", "from", "function", "if", "import", "in", "instanceof", "let",
                   "new", "of", "return", "static", "switch", "this", "throw", "try", "typeof", "var", "while", "yield"],
       literals: @["true", "false", "null", "undefined", "Infinity", "NaN"]),
  Lang(names: @["python", "py"], comments: @["#"], atSign: true,
       keywords: @["and", "as", "assert", "break", "class", "continue", "def", "del", "elif", "else", "except",
                   "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "not", "or", "pass",
                   "raise", "return", "try", "while", "with", "yield"],
       literals: @["True", "False", "None"]),
  Lang(names: @["sh", "bash", "shell", "console"], comments: @["#"],
       keywords: @["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac",
                   "function", "export", "set", "cd"]),
  Lang(names: @["toml", "yaml", "yml"], comments: @["#"], literals: @["true", "false", "null"]),
  Lang(names: @["json"], literals: @["true", "false", "null"]),
  Lang(names: @["c", "h"], comments: @["//"],
       keywords: @["break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "goto",
                   "if", "return", "sizeof", "static", "struct", "switch", "typedef", "union", "while",
                   "int", "char", "void", "long", "short", "unsigned", "float", "double"],
       literals: @["NULL", "true", "false"]),
]

func langOf(name: string): int =
  for i, l in langs:
    if name in l.names: return i
  -1

func highlightOther*(code, lang: string): string =
  ## A small highlighter for the code that pages show but do not run: keywords, literals,
  ## strings, numbers, comments, types and function calls, with the classes of the Nim code.
  ## An unknown language is shown plain.
  let li = langOf(lang)
  if li < 0: return esc(code)
  let l = langs[li]
  func span(cls, s: string): string = "<span class=\"hljs-" & cls & "\">" & esc(s) & "</span>"
  const wordStart = {'a'..'z', 'A'..'Z', '_'}
  const wordChars = wordStart + {'0'..'9'}
  var i = 0
  while i < code.len:
    let c = code[i]
    var isComment = false
    for m in l.comments:
      # a shell `#` is a comment only at the start of a word: `$#` and `a#b` are not
      if code.continuesWith(m, i) and (m != "#" or i == 0 or code[i - 1] in {' ', '\t', '\n'}): isComment = true
    if isComment:
      var j = i
      while j < code.len and code[j] != '\n': inc j
      result.add span("comment", code[i ..< j]); i = j
    elif c == '"' or (c == '\'' and l.names[0] in ["js", "python", "sh", "toml"]):
      var j = i + 1
      while j < code.len and code[j] != c and (code[j] != '\n' or c == '"' and l.names[0] in ["gleam", "rust", "erlang", "elixir"]):
        if code[j] == '\\': inc j
        inc j
      j = min(j + 1, code.len)
      result.add span("string", code[i ..< j]); i = j
    elif c in {'0'..'9'} and (i == 0 or code[i - 1] notin wordChars):
      var j = i
      while j < code.len and (code[j] in {'0'..'9', '_', 'x', 'o', 'b', 'e', 'a'..'f', 'A'..'F'} or
          (code[j] == '.' and j + 1 < code.len and code[j + 1] in {'0'..'9'})): inc j
      result.add span("number", code[i ..< j]); i = j
    elif c == '@' and l.atSign and i + 1 < code.len and code[i + 1] in wordStart:
      var j = i + 1
      while j < code.len and code[j] in wordChars: inc j
      result.add span("meta", code[i ..< j]); i = j
    elif c in wordStart:
      var j = i
      while j < code.len and code[j] in wordChars: inc j
      let w = code[i ..< j]
      if w in l.keywords: result.add span("keyword", w)
      elif w in l.literals: result.add span("literal", w)
      elif l.names[0] in ["toml"] and (code.continuesWith(":", j) or code.continuesWith(" =", j) or code.continuesWith("=", j)):
        result.add span("keyword", w)
      elif l.types and w[0] in {'A'..'Z'}: result.add span("type", w)
      elif j < code.len and code[j] == '(': result.add span("built_in", w)
      else: result.add esc(w)
      i = j
    elif (c == '|' and code.continuesWith("|>", i)) or (c == '-' and code.continuesWith("->", i)) or
         (c == '<' and code.continuesWith("<-", i)):
      result.add span("meta", code[i .. i + 1]); i += 2
    else:
      result.add esc($c); inc i

func highlightFences(html: string): string =
  ## Code fences in Markdown, highlighted like the code that ran: Nim with nimib's highlighter,
  ## the others with `highlightOther`.
  result = html
  const openStart = "<pre><code class=\"language-"
  const close = "</code></pre>"
  var res = ""
  var i = 0
  while true:
    let a = result.find(openStart, i)
    if a < 0: break
    let q = result.find("\">", a + openStart.len)
    let b = result.find(close, a)
    if q < 0 or b < 0: break
    let lang = result[a + openStart.len ..< q]
    let code = unescapeHtml(result[q + 2 ..< b]).strip(leading = false, chars = {'\n'})
    res.add result[i ..< a]
    res.add "<pre><code class=\"nohighlight " & esc(lang) & " hljs\">" &
      (if lang == "nim": highlightNim(code) else: highlightOther(code, lang)) & close
    i = b + close.len
  res.add result[i .. ^1]
  result = res

func wrapTables(html: string): string =
  ## A Markdown table in a box of its own, so a wide one scrolls sideways inside it.
  html.replace("<table>", "<div class=\"md-table\"><table>").replace("</table>", "</table></div>")

# ------------------------------------------------------------------------------------- the title

newNbBlock(NbTitle):
  kicker: string
  title: string
  lede: string
  toHtml:
    (if blk.kicker.len > 0: &"""<p class="kicker">{blk.kicker}</p>""" & "\n" else: "") &
      &"<h1>{inline(blk.title)}</h1>\n" &
      (if blk.lede.len > 0: &"""<div class="lede">{markdownToHtml(blk.lede)}</div>""" else: "")

proc addTitle*(nb: var Nb, kicker, title: string, lede = "") =
  nb.add newNbTitle(kicker = esc(kicker), title = title, lede = lede)

template nbTitle*(tkicker, ttitle: string, tlede = "") =
  ## The top of a page: a small line above (the kicker: what kind of page, a date), the title,
  ## and the lede, a paragraph that says what the page is for. Title and lede in Markdown.
  nb.addTitle(tkicker, ttitle, tlede)

# ---------------------------------------------------------------------------------- the contents

newNbBlock(NbToc):
  title: string
  toHtml:
    var items = ""
    var openSub = false
    for b in nb.doc.blocksFlattened:
      if not (b of NbText): continue
      for (level, text) in headingsOf(b.NbText.text):
        let link = &"""<a href="#{slugify(text)}">{esc(text)}</a>"""
        if level == 2:
          if openSub: (items.add "</ol>"; openSub = false)
          if items.len > 0: items.add "</li>"
          items.add "<li>" & link
        else:
          if not openSub: (items.add "<ol>"; openSub = true)
          items.add "<li>" & link & "</li>"
    if openSub: items.add "</ol>"
    if items.len > 0: items.add "</li>"
    &"""<nav class="toc" id="contents" aria-label="{blk.title}"><p class="toc-title">{blk.title}</p><ol>{items}</ol></nav>"""

proc addToc*(nb: var Nb, title = "Contents") =
  nb.doc.context["toc"] = %true   # the headings get their arrow back to it (`addHeadingIds`)
  nb.add newNbToc(title = title)

template nbToc*(ttitle = "Contents") =
  ## The contents of the page: its `##` and `###` headings, found when the page is saved.
  nb.addToc(ttitle)

# ----------------------------------------------------------------------------------------- notes

type NoteKind* = enum
  ## What a note is about; its colour follows (`theme.nim`).
  nkPlain = "plain"        ## an aside
  nkInfo = "info"          ## information, a page to go to
  nkGleam = "gleam"        ## about Gleam or its compiler: how the original does it
  nkNim = "nim"            ## about Nim: how the port does it, and why it differs
  nkDone = "done"          ## what is done, what works, what was verified
  nkWarning = "warning"    ## something to watch out for
  nkQuestion = "question"  ## an open question, for Pietro or for a later step

newNbBlock(NbNote):
  text: string
  level: NoteKind
  title: string
  toHtml:
    &"""<div class="note {blk.level}">""" &
      (if blk.title.len > 0: &"""<span class="head">{inline(blk.title)}</span>""" else: "") &
      wrapTables(highlightFences(markdownToHtml(blk.text))) & "</div>"

proc addNote*(nb: var Nb, text: string, kind = nkPlain, title = "") =
  nb.add newNbNote(text = text, level = kind, title = title)

template nbNote*(ttext: string, tkind = nkPlain, ttitle = "") =
  ## A note beside the text, in Markdown, of a kind: `nbNote "Still to decide.", nkQuestion`.
  nb.addNote(ttext, tkind, ttitle)

# ----------------------------------------------------------------------------------------- cards

newNbBlock(NbCards of NbContainer):
  label: string
  toHtml:
    &"""<div class="cards" role="list" aria-label="{esc(blk.label)}">""" & nbContainerToHtml(blk, nb) & "</div>"

newNbBlock(NbCard of NbContainer):
  title: string
  href: string
  small: string
  level: NoteKind
  toHtml:
    let title = if blk.href.len > 0: &"""<a href="{blk.href}">{inline(blk.title)}</a>""" else: inline(blk.title)
    &"""<div class="note {blk.level}" role="listitem">""" &
      (if blk.small.len > 0: &"""<span class="num">{esc(blk.small)}</span>""" else: "") &
      &"""<span class="head">{title}</span>""" & nbContainerToHtml(blk, nb) & "</div>"

template nbCards*(what: string, body: untyped) =
  ## A grid of cards (`nbCard`), such as the pages on the home page. `what` names it for a
  ## screen reader.
  let cards = newNbCards(label = what)
  nb.withContainer(cards):
    body
  nb.add cards

template nbCard*(heading, link, tsmall: string, tkind: NoteKind, body: untyped) =
  ## A card: a title (a link when `link` is not empty), a small line above it (or ""), a kind
  ## and blocks inside.
  let card = newNbCard(title = heading, href = link, small = tsmall, level = tkind)
  nb.withContainer(card):
    body
  nb.add card

template nbCard*(heading, link: string, body: untyped) =
  ## A card of kind `nkInfo` with a link.
  nbCard(heading, link, "", nkInfo, body)

# ------------------------------------------------------------------------------------------ fold

newNbBlock(NbFold of NbContainer):
  label: string
  toHtml:
    &"""<details class="fold"><summary>{inline(blk.label)}</summary>""" & nbContainerToHtml(blk, nb) & "</details>"

template nbFold*(tlabel: string, body: untyped) =
  ## Blocks folded away under a line to press: long listings, raw data, the detail of a proof.
  let fold = newNbFold(label = tlabel)
  nb.withContainer(fold):
    body
  nb.add fold

# -------------------------------------------------------------------------------------- pipeline

type Status* = enum
  ## How far a step, a stage or a module is.
  stPlanned = "planned", stStarted = "started", stDone = "done", stBlocked = "blocked"

func toStatus*(s: string): Status =
  ## A status from its word; anything unknown is `planned`.
  for st in Status:
    if $st == s.strip.toLowerAscii: return st
  stPlanned

func status*(s: Status): string =
  ## A status as a table cell or a word in a sentence: `<span class="status done">done</span>`.
  &"""<span class="status {s}">{s}</span>"""

newNbBlock(NbPipeline):
  stages: seq[string]
  states: seq[string]
  toHtml:
    var items = ""
    for i, s in blk.stages:
      items.add &"""<li class="{blk.states[i]}" title="{blk.states[i]}">{esc(s)}</li>"""
    &"""<ol class="pipeline" aria-label="The stages of the compiler and how far each is ported">{items}</ol>"""

proc addPipeline*(nb: var Nb, stages: openArray[(string, Status)]) =
  var names, states: seq[string]
  for (name, st) in stages:
    names.add name
    states.add $st
  nb.add newNbPipeline(stages = names, states = states)

template nbPipeline*(tstages: openArray[(string, Status)]) =
  ## The stages of the compiler, in order, as lamps: off (planned), yellow (started), pink and
  ## glowing (done). `nbPipeline [("lexer", stStarted), ("parser", stPlanned)]`.
  nb.addPipeline(tstages)

# ---------------------------------------------------------------------------------- devlog posts

type Post* = object
  ## A devlog post, read from the first lines of its source:
  ## `## devlog: 12 Nov 2026 A | Title | Lede.` and `## kind: research`.
  slug*, date*, title*, lede*, kind*, letter*, file*: string
  day*: DateTime

const postKinds* = ["research", "plan", "port", "tooling"]

proc readPost*(path: string): Post =
  ## The post in a source file; `slug` is empty when the file is not a post.
  let lines = readFile(path).splitLines
  if lines.len == 0 or not lines[0].startsWith("## devlog:"): return
  let parts = lines[0]["## devlog:".len .. ^1].split('|')
  doAssert parts.len >= 3, path & ": the first line must be `## devlog: dd Mon yyyy X | title | lede`"
  let stamp = parts[0].strip.splitWhitespace
  doAssert stamp.len >= 3, path & ": no date in the first line"
  result = Post(slug: path.splitFile.name.replace('_', '-'), date: stamp[0 .. 2].join(" "),
                title: parts[1].strip, lede: parts[2 .. ^1].join("|").strip, file: path,
                day: parse(stamp[0 .. 2].join(" "), "d MMM yyyy"),
                letter: (if stamp.len > 3: stamp[3] else: ""), kind: "research")
  if lines.len > 1 and lines[1].startsWith("## kind:"):
    result.kind = lines[1]["## kind:".len .. ^1].strip
    doAssert result.kind in postKinds, path & ": kind must be one of " & postKinds.join(", ")

proc devlogPosts*(): seq[Post] =
  ## Every post of `docs/devlog/`, newest first (same day: by letter, latest first).
  for kind, path in walkDir(docsDir / "devlog"):
    if kind != pcFile or not path.endsWith(".nim") or path.splitFile.name == "index": continue
    let p = readPost(path)
    if p.slug.len > 0: result.add p
  result.sort(proc (a, b: Post): int = cmp((b.day.format("yyyyMMdd"), b.letter), (a.day.format("yyyyMMdd"), a.letter)))
  for i in 1 ..< result.len:
    doAssert result[i].letter.len > 0 and (result[i].date, result[i].letter) != (result[i - 1].date, result[i - 1].letter),
      result[i].file & " and " & result[i - 1].file & ": two posts of " & result[i].date & " with the letter " &
      result[i].letter & " (take the next free one)"

func stamp*(p: Post): string =
  ## `12 Nov 2026 A`: the date and the letter that orders the posts of a day, as the cards show it.
  p.date & (if p.letter.len > 0: " " & p.letter else: "")

# -------------------------------------------------------------------------------------- the page

const lookHeadScript = """<script>
(function () {
  var look = 'giorno';
  try {
    var q = new URLSearchParams(location.search).get('look');
    if (q === 'giorno' || q === 'notte') localStorage.setItem('gleam-in-nim-look', q);
    look = q || localStorage.getItem('gleam-in-nim-look') ||
      (window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches ? 'notte' : 'giorno');
  } catch (e) {}
  document.documentElement.dataset.look = (look === 'notte') ? 'notte' : 'giorno';
})();
</script>"""

const bodyScript = """<script>
(function () {
  var root = document.documentElement;
  var b = document.querySelector('button.look');
  if (!b) return;
  function show() {
    var night = root.dataset.look === 'notte';
    b.textContent = night ? '☀ giorno' : '☾ notte';
    b.setAttribute('aria-label', night ? 'Switch to the day look' : 'Switch to the night look');
  }
  b.hidden = false;
  b.addEventListener('click', function () {
    root.dataset.look = root.dataset.look === 'notte' ? 'giorno' : 'notte';
    try { localStorage.setItem('gleam-in-nim-look', root.dataset.look); } catch (e) {}
    show();
  });
  show();
})();
(function () {
  // a link to something inside a closed fold (nbFold) opens the fold, then goes there
  function reveal() {
    var id = decodeURIComponent(location.hash.slice(1));
    var el = id && document.getElementById(id);
    if (!el) return;
    var shut = false;
    for (var d = el.closest('details.fold'); d; d = d.parentElement && d.parentElement.closest('details.fold')) {
      if (!d.open) { d.open = true; shut = true; }
    }
    if (shut) el.scrollIntoView();
  }
  window.addEventListener('hashchange', reveal);
  reveal();
})();
</script>"""

func pageText(blk: JsonNode, nb: Nb): string =
  wrapTables(highlightFences(addHeadingIds(markdownToHtml(blk{"text"}.getStr), nb.doc.context{"toc"}.getBool)))

func pageHeader(blk: JsonNode, nb: Nb): string =
  let c = nb.doc.context
  let home = c{"home_href"}.getStr
  let backLabel = esc(c{"back_label"}.getStr)
  let back = if home.len > 0: &"""<a href="{home}">← {backLabel}</a>""" else: ""
  let wordmark = """<span class="spark">✦</span> gleam in nim"""
  let wordmarkHref = c{"wordmark_href"}.getStr
  let mark = if wordmarkHref.len > 0: &"""<a class="wordmark" href="{wordmarkHref}">{wordmark}</a>"""
             else: &"""<span class="wordmark">{wordmark}</span>"""
  let section = c{"section"}.getStr
  let cadence = c{"cadence"}.getStr
  &"""<header>
<nav class="crumbs">{back}<span class="grow"></span><button type="button" class="look" hidden>☾ notte</button><a href="{repoUrl}">GitHub ↗</a></nav>
<div class="masthead">{mark}""" &
    (if section.len > 0: &"""<span class="section">{esc(section)}</span>""" else: "") &
    (if cadence.len > 0: &"""<span class="cadence">{esc(cadence)}</span>""" else: "") & "</div>\n</header>"

func pageFooter(blk: JsonNode, nb: Nb): string =
  let source = nb.doc.context{"source_path"}.getStr
  let highlighted = nb.doc.context{"source_highlighted"}.getStr   # the notebook itself, set by nbInit
  "<footer><p>Written in Nim with <a href=\"https://github.com/pietroppeter/nimib\">nimib</a> 🐳, tables by " &
    "<a href=\"https://github.com/pietroppeter/tabelline\">tabelline</a>. The code on this page ran when it was built" &
    (if source.len > 0: &""" from <a href="{repoUrl}/blob/main/{source}">{source}</a>.""" else: ".") & "</p>" &
    "<p>gleam in nim is an independent project made to learn, by Pietro Peterlongo with Claude. " &
    "<a href=\"https://gleam.run\">Gleam</a> is made by Louis Pilfold and the Gleam contributors; " &
    "this project is not affiliated with it.</p>" &
    (if highlighted.len == 0: "" else:
      """<details class="fold source"><summary>Show the nimib source of this page</summary>""" &
      """<pre><code class="nohighlight nim hljs">""" & highlighted & "</code></pre></details>") &
    "</footer>" & bodyScript

func emptyPartial(blk: JsonNode, nb: Nb): string = ""

proc sharedReviewScript*(nb: Nb): string =
  ## The review mode's script: the shared copy, `docs/assets/review.js`, or "" (inlined) with
  ## `-d:singleFile`.
  when singleFile: "" else: assetHref("review.js", nb.doc.filename)

proc usePage*(nb: var Nb, section = "", cadence = "", title = "", description = "",
              homeHref = "", backLabel = "gleam in nim", wordmarkHref = "", review = true,
              reviewPage = "") =
  ## The page: the look (`theme.nim`), the header (a way back, the mode switch, the wordmark,
  ## then `section`, the part of the site the page belongs to, and `cadence`, how the page lives:
  ## kept up to date, or dated) and the footer. `homeHref` links back, with `backLabel` as its
  ## text; `wordmarkHref` makes the wordmark a link. Every page has the review mode
  ## (`review.nim`): its version line under the lede and **✎ Review**; `review = false` leaves
  ## it out, `reviewPage` keeps the key its comments are stored under when the file is renamed.
  ## Set `nb.doc.filename` before calling it.
  let desc = if description.len > 0: "<meta name=\"description\" content=\"" & esc(description) & "\">\n" else: ""
  nb.doc.context["title"] = %(if title.len > 0: title else: "gleam in nim")
  nb.doc.context["stylesheet"] = %(desc &
    """<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2280%22>✨</text></svg>">""" &
    "\n" & lookHeadScript & "\n" & siteCss(nb.doc.filename, extra = reviewCss))
  nb.doc.context["highlight"] = %""
  nb.doc.context["nb_style"] = %""
  nb.doc.context["disableHighlightJs"] = %true
  let file = nb.doc.thisFile.string
  if file.isRelativeTo(repoDir):
    nb.doc.context["source_path"] = %file.relativePath(repoDir).replace('\\', '/')
  for (key, value) in [("section", section), ("cadence", cadence), ("home_href", homeHref),
                       ("back_label", backLabel), ("wordmark_href", wordmarkHref)]:
    nb.doc.context[key] = %value
  nb.backend.partials["header"] = pageHeader
  nb.backend.partials["footer"] = pageFooter
  nb.backend.partials["nbText"] = pageText
  nb.backend.partials["left"] = emptyPartial
  nb.backend.partials["right"] = emptyPartial
  if review: nb.review(page = reviewPage, script = sharedReviewScript(nb), css = false)

func longDate*(p: Post): string =
  ## `12 November 2026`
  p.day.format("d MMMM yyyy")

proc usePost*(nb: var Nb, toc = true) =
  ## A devlog post: reads the first lines of the notebook (`## devlog: ...`, `## kind: ...`),
  ## writes the page to `docs/devlog/<slug>/index.html`, and adds the title (date and kind,
  ## title, lede) and, unless `toc = false`, the contents. Call it right after `nbInit`.
  let p = readPost(nb.doc.thisFile.string)
  doAssert p.slug.len > 0, nb.doc.thisFile.string & ": the first line must be `## devlog: dd Mon yyyy X | title | lede`"
  nb.doc.filename = docsDir / "devlog" / p.slug / "index.html"
  nb.usePage(section = "Devlog", cadence = "dated post", title = p.title & " · gleam in nim",
             description = p.lede, homeHref = "../", backLabel = "Devlog", wordmarkHref = "../../")
  nb.add newNbTitle(kicker = &"""{p.longDate} {p.letter} · <span class="kind {p.kind}">{p.kind}</span>""",
                    title = p.title, lede = p.lede)
  if toc: nb.addToc()
