## The look of the pages, in one place: fonts, colours, every CSS rule.
##
## The look is called **Lucciola** (firefly: a small gleam, in Italian). It has two modes:
## *giorno* (day, the default: a page without JavaScript is giorno) and *notte* (night), which
## the header switches and the browser remembers; the first visit follows the system.
##
## Six values per mode (paper, ink, primary, secondary, warning, success) and every other colour
## is mixed from them in the browser, as in tabelline's pages, so the tokens have the same names
## and tabelline's tables (`optCssTheme()`) and the review mode read them as they are:
##
## - primary is the pink of a gleam, for what is about Gleam and for links;
## - secondary is the yellow of Nim's crown, for what is about Nim and for marks;
## - warning (never text) and success say how a step went.
##
## Shape says the kind of thing: the sparkle ✦ is a place (the wordmark, a section), the square
## a sheet set apart (notes, cards: a straight top edge), the lamp a stage of the compiler
## (lit when ported). No other module writes CSS or names a colour: pages use `blocks.nim`.

import std/[os, strformat, strutils]
when defined(singleFile): import std/base64

const
  singleFile* = defined(singleFile)
    ## `-d:singleFile`: every page is one file, its style, fonts and scripts inlined
  assetsDir* = currentSourcePath().parentDir / "assets"
    ## `docs/assets/`: the files the pages share (deployed with them)
  fontDir = assetsDir / "fonts"

func face(family, file, weight, style: string): string =
  when singleFile:
    let src = "data:font/woff2;base64," & encode(staticRead(fontDir / file))
  else:
    discard fontDir   # the font file, beside site.css
    let src = "fonts/" & file
  &"@font-face{{font-family:'{family}';src:url({src}) format('woff2');" &
    &"font-weight:{weight};font-style:{style};font-display:swap}}\n"

const fonts =
  face("Lexend", "lexend-latin.woff2", "300 800", "normal") &                 # headings: the typeface of gleam.run
  face("Atkinson Hyperlegible", "atkinson-regular.woff2", "400", "normal") &  # text
  face("Atkinson Hyperlegible", "atkinson-bold.woff2", "700", "normal") &
  face("Atkinson Hyperlegible", "atkinson-italic.woff2", "400", "italic") &
  face("JetBrains Mono", "jetbrains-mono-latin-400-normal.woff2", "400", "normal") &  # code
  face("JetBrains Mono", "jetbrains-mono-latin-600-normal.woff2", "600", "normal")

# ------------------------------------------------------------------------------------ the palette

type Look* = object
  ## The six values a mode gives, and `lift`, what the paper is mixed with for a raised sheet.
  paper*, ink*, primary*, secondary*, warning*, success*, lift*: string

const
  giorno* = Look(paper: "#FFFBF4",      # warm paper
                 ink: "#2B2237",        # aubergine ink
                 primary: "#E65CC4",    # a gleam, deep enough for paper
                 secondary: "#F0B90B",  # the crown, deep enough for paper
                 warning: "#F2703D", success: "#2FA98A", lift: "#FFFFFF")
  notte* = Look(paper: "#1D1828",       # the night
                ink: "#F1EAF7",
                primary: "#FFAFF3",     # the pink of gleam.run
                secondary: "#FFE953",   # the yellow of nim-lang.org
                warning: "#FF8D5E", success: "#74DDB4", lift: "#4A3F63")

  neutralSteps* = [0, 4, 8, 14, 25, 40, 55, 65, 80, 100]  ## ink in paper, % per step `--neutral-0`..`--neutral-9`
  softShare* = 22   ## % of a colour in paper, for `--x-soft`
  textShare* = 50   ## % of a colour in ink, for `--x-text`

func tokensCss(): string =
  for i, s in neutralSteps:
    result.add &"--neutral-{i}: color-mix(in oklab, var(--ink) {s}%, var(--paper));\n"
  result.add "--shade: var(--neutral-1); --line: var(--neutral-3); --muted: var(--neutral-7);\n"
  result.add "--surface: color-mix(in oklab, var(--lift) 60%, var(--paper));\n"
  for role in ["primary", "secondary", "warning", "success"]:
    result.add &"--{role}-soft: color-mix(in oklab, var(--{role}) {softShare}%, var(--paper));\n"
    if role != "warning":
      result.add &"--{role}-text: color-mix(in oklab, var(--{role}) {textShare}%, var(--ink));\n"
  result.add "--font: 'Atkinson Hyperlegible', system-ui, sans-serif;\n"
  result.add "--display: 'Lexend', 'Atkinson Hyperlegible', system-ui, sans-serif;\n"
  result.add "--mono: 'JetBrains Mono', ui-monospace, 'SF Mono', Menlo, Consolas, monospace;\n"

func lookCss(l: Look): string =
  &"--paper: {l.paper}; --ink: {l.ink}; --primary: {l.primary}; --secondary: {l.secondary}; " &
    &"--warning: {l.warning}; --success: {l.success}; --lift: {l.lift};"

const tokens =
  "html {\n" & lookCss(giorno) & "\n" & tokensCss() & "--code-share: 55%; color-scheme: light; }\n" &
  "html[data-look=\"notte\"] {\n" & lookCss(notte) & "\n--code-share: 85%; color-scheme: dark; }\n"

# ------------------------------------------------------------------------------------- the rules

const rules = """
*, *::before, *::after { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; text-size-adjust: 100%; scroll-behavior: smooth; }
body { margin: 0 auto; max-width: 46rem; padding: 0 1.1rem 3rem; background: var(--paper); color: var(--ink);
  font: 400 17px/1.6 var(--font); overflow-wrap: break-word; }
[hidden] { display: none !important; }
a { color: var(--primary-text); text-decoration-thickness: 1px; text-underline-offset: 2px; }
a:hover { text-decoration-thickness: 2px; }
::selection { background: var(--secondary-soft); }
img, svg { max-width: 100%; height: auto; }
hr { border: 0; border-top: 1px solid var(--line); margin: 2rem 0; }

/* the header: a way back, the mode switch, the wordmark and where the page belongs */
body > header { padding: .8rem 0 0; }
.crumbs { display: flex; align-items: center; gap: .8rem; font: 400 .88rem var(--display); }
.crumbs a { color: var(--muted); text-decoration: none; min-height: 44px; display: inline-flex; align-items: center; }
.crumbs a:hover { color: var(--ink); }
.crumbs .grow { flex: 1; }
.look { font: inherit; color: var(--muted); background: transparent; border: 1px solid var(--line); border-radius: 999px;
  min-width: 44px; min-height: 32px; padding: 0 .7rem; cursor: pointer; }
.look:hover { color: var(--ink); border-color: var(--ink); }
.masthead { display: flex; flex-wrap: wrap; align-items: baseline; gap: .2rem .8rem; margin: .6rem 0 0;
  padding-bottom: .7rem; border-bottom: 3px solid var(--ink); font-family: var(--display); }
.wordmark { font-weight: 700; font-size: 1.15rem; letter-spacing: -.01em; color: var(--ink); text-decoration: none; }
.wordmark .spark { color: var(--primary); }
.wordmark .crown { color: var(--secondary-text); }
.masthead .section { color: var(--muted); font-size: .92rem; }
.masthead .cadence { color: var(--muted); font-size: .8rem; margin-left: auto; text-transform: uppercase; letter-spacing: .06em; }

/* the title of a page */
.kicker { margin: 2rem 0 .3rem; font: 500 .82rem var(--display); letter-spacing: .08em; text-transform: uppercase; color: var(--muted); }
.kicker .kind { color: var(--ink); background: var(--secondary-soft); padding: .1rem .5rem; }
.kicker .kind.port { background: var(--primary-soft); }
.kicker .kind.plan { background: var(--success-soft); }
.kicker .kind.tooling { background: var(--shade); }
h1 { font: 700 2.1rem/1.15 var(--display); letter-spacing: -.02em; margin: .2rem 0 .6rem; text-wrap: balance; }
.lede { font-size: 1.14rem; line-height: 1.5; color: var(--neutral-8); }
.lede p { margin: 0 0 .6rem; }

/* headings: the sparkle is a place */
h2 { font: 700 1.45rem/1.25 var(--display); letter-spacing: -.01em; margin: 2.6rem 0 .7rem; padding-top: .4rem; }
h2::before { content: "✦"; color: var(--primary); margin-right: .45rem; font-size: .8em; vertical-align: .08em; }
h3 { font: 600 1.12rem/1.3 var(--display); margin: 1.8rem 0 .5rem; }
h4 { font: 600 1rem/1.3 var(--display); margin: 1.4rem 0 .4rem; }
h2 a.up, h3 a.up { margin-left: .5rem; text-decoration: none; color: var(--line); font-weight: 400; }
h2 a.up::after, h3 a.up::after { content: "↑"; }
h2 a.up:hover, h3 a.up:hover { color: var(--ink); }
p { margin: 0 0 1rem; }
ul, ol { padding-left: 1.4rem; margin: 0 0 1rem; }
li { margin: .25rem 0; }
blockquote { margin: 1.2rem 0; padding: .1rem 1rem; border-left: 4px solid var(--primary); background: var(--primary-soft); }
blockquote p { margin: .6rem 0; }

/* code: small, in its own box, scrolling sideways inside it */
code, pre { font-variant-ligatures: none; }   /* `|>` and `->` as they are typed */
code { font-family: var(--mono); font-size: .86em; background: var(--shade); padding: .08em .3em; border-radius: 3px; }
pre { margin: 1rem 0; overflow-x: auto; max-width: 100%; background: var(--shade); border-left: 3px solid var(--line); }
pre > code { display: block; overflow-x: auto; padding: .7rem .8rem; background: transparent; border-radius: 0;
  font: 400 13px/1.5 var(--mono); white-space: pre; tab-size: 2; }
pre.nb-output { padding: .6rem .8rem; font: 400 12.5px/1.5 var(--mono); white-space: pre; background: var(--surface);
  border: 1px solid var(--line); border-left: 3px solid var(--secondary); margin-top: -.6rem; }
/* the colours of code: a role's colour, `--code-share` of it in the ink (more at night) */
.hljs-keyword, .hljs-meta { color: color-mix(in oklab, var(--primary) var(--code-share), var(--ink)); font-weight: 600; }
.hljs-string { color: color-mix(in oklab, var(--success) var(--code-share), var(--ink)); }
.hljs-comment { color: var(--muted); font-style: italic; }
.hljs-number, .hljs-literal { color: color-mix(in oklab, var(--secondary) var(--code-share), var(--ink)); }
.hljs-type, .hljs-title { color: color-mix(in oklab, var(--warning) var(--code-share), var(--ink)); }
.hljs-built_in { color: var(--neutral-8); font-weight: 600; }

/* tables written in Markdown (tabelline's bring their own rules and read the same tokens) */
.md-table { overflow-x: auto; margin: 1.2rem 0; }
.md-table table { border-collapse: collapse; width: 100%; font-size: .92rem; line-height: 1.4; }
.md-table th { text-align: left; font: 600 .82rem var(--display); letter-spacing: .03em; border-bottom: 2px solid var(--ink); padding: .4rem .6rem .4rem 0; vertical-align: bottom; }
.md-table td { border-bottom: 1px solid var(--line); padding: .45rem .6rem .45rem 0; vertical-align: top; }
.tabella { margin: 1.2rem 0 1.4rem; font-size: .9rem; line-height: 1.4; }
.tabella .tb_title { font-family: var(--display); font-weight: 600; }
.tabella td code { overflow-wrap: anywhere; }  /* long names in a cell wrap on a phone */

/* figures */
figure { margin: 1.4rem 0; }
figcaption { color: var(--muted); font-size: .88rem; margin-top: .4rem; }

/* the contents of a page */
.toc { margin: 1.6rem 0; padding: .8rem 1rem; background: var(--surface); border-top: 3px solid var(--ink); }
.toc-title { font: 600 .82rem var(--display); letter-spacing: .08em; text-transform: uppercase; color: var(--muted); margin: 0 0 .4rem; padding: 0; }
.toc-title::before { content: none; }
.toc ol { margin: 0; padding-left: 1.3rem; }
.toc ol ol { font-size: .92rem; }
.toc a { color: var(--ink); text-decoration: none; }
.toc a:hover { text-decoration: underline; }

/* notes and cards: a sheet set apart, with a straight top edge in the colour of its kind */
.note { margin: 1.2rem 0; padding: .7rem 1rem .1rem; background: var(--surface); border-top: 3px solid var(--line); }
.note .head { display: block; font: 600 .95rem var(--display); margin-bottom: .3rem; }
.note .num { display: block; font: 500 .74rem var(--display); letter-spacing: .08em; text-transform: uppercase; color: var(--muted); }
.note.info { border-top-color: var(--ink); }
.note.gleam { border-top-color: var(--primary); background: var(--primary-soft); }
.note.nim { border-top-color: var(--secondary); background: var(--secondary-soft); }
.note.done { border-top-color: var(--success); background: var(--success-soft); }
.note.warning { border-top-color: var(--warning); background: var(--warning-soft); }
.note.question { border-top-style: dashed; border-top-color: var(--ink); }
.cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(15rem, 1fr)); gap: .9rem; margin: 1.2rem 0; }
.cards .note { margin: 0; }
.cards .note .head a { color: var(--ink); }
.cards .note p { font-size: .94rem; line-height: 1.45; }

/* something folded away */
details.fold { margin: 1rem 0; border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); }
details.fold > summary { cursor: pointer; padding: .6rem 0; font: 500 .95rem var(--display); min-height: 44px; }
details.fold[open] > summary { border-bottom: 1px dashed var(--line); margin-bottom: .8rem; }

/* the pipeline: one lamp per stage of the compiler, lit when ported */
.pipeline { display: flex; flex-wrap: wrap; gap: .5rem .3rem; margin: 1.4rem 0; padding: 0; list-style: none; font: 500 .82rem var(--display); }
.pipeline li { display: flex; align-items: center; gap: .4rem; margin: 0; padding: .35rem .65rem; border: 1px solid var(--line); border-radius: 999px; color: var(--muted); }
.pipeline li::before { content: ""; width: .6rem; height: .6rem; border-radius: 50%; background: var(--neutral-2); }
.pipeline li.started { color: var(--ink); border-color: var(--secondary); }
.pipeline li.started::before { background: var(--secondary); }
.pipeline li.done { color: var(--ink); border-color: var(--primary); }
.pipeline li.done::before { background: var(--primary); box-shadow: 0 0 .5rem var(--primary); }
.pipeline li + li { position: relative; }
.pipeline-legend { color: var(--muted); font-size: .85rem; margin-top: -.8rem; }

/* a status, in words and a colour */
.status { font: 500 .78rem var(--display); letter-spacing: .03em; padding: .08rem .45rem; white-space: nowrap; background: var(--shade); }
.status.done { background: var(--success-soft); }
.status.started { background: var(--secondary-soft); }
.status.blocked { background: var(--warning-soft); }

/* the footer */
body > footer { margin-top: 3.5rem; padding-top: 1rem; border-top: 1px solid var(--line); color: var(--muted); font-size: .86rem; line-height: 1.5; }
body > footer p { margin: 0 0 .5rem; }
body > footer a { color: var(--muted); }
/* the notebook that made the page, folded at its foot */
body > footer details.source { margin-top: .8rem; color: var(--ink); }
body > footer details.source > summary { color: var(--muted); font-size: .86rem; }

@media (max-width: 480px) {
  body { font-size: 16.5px; padding: 0 .9rem 3rem; }
  h1 { font-size: 1.75rem; }
  h2 { font-size: 1.3rem; }
  .masthead .cadence { margin-left: 0; }
}
@media print {
  .crumbs, .rv-enter .rv-toggle { display: none; }
  body { max-width: none; }
}
"""

func scoped*(rules, scope: string): string =
  ## Puts `scope` before every selector of `rules`; `html` itself becomes `scope`. Rules inside
  ## `@media` are scoped too; comments are kept. (Used by the review mode, `review.nim`.)
  var i = 0
  while i < rules.len:
    if rules.continuesWith("/*", i):
      let e = rules.find("*/", i) + 2
      result.add rules[i ..< e]; i = e
    elif rules[i] in {'}', '\n', ' '}:
      result.add rules[i]; inc i
    elif rules.continuesWith("@media", i):
      let e = rules.find('{', i) + 1
      result.add rules[i ..< e]; i = e
    else:
      let e = rules.find('{', i)
      var sels: seq[string]
      for s in rules[i ..< e].split(','):
        let s = s.strip
        sels.add(if s == "html": scope else: scope & " " & s)
      let close = rules.find('}', e)
      result.add sels.join(", ") & " " & rules[e .. close]; i = close + 1

const css* = fonts & tokens & rules
  ## All the CSS of a page.

proc assetHref*(name, pageFile: string): string =
  ## The link from a page (its HTML file) to a file the pages share, `docs/assets/<name>`.
  relativePath(assetsDir / name, absolutePath(pageFile).parentDir).replace('\\', '/')

proc siteCss*(pageFile: string, extra = ""): string =
  ## What a page puts in its head for its style: a link to `docs/assets/site.css` (written when
  ## it changed), relative to the page; with `-d:singleFile`, the CSS itself. `extra` is CSS of
  ## other modules every page has (the review mode's).
  when singleFile:
    "<style>\n" & css & extra & "</style>"
  else:
    let file = assetsDir / "site.css"
    if not fileExists(file) or readFile(file) != css & extra: writeFile(file, css & extra)
    &"""<link rel="stylesheet" href="{assetHref("site.css", pageFile)}">"""

const tokenColours* = ["--paper", "--shade", "--line", "--muted", "--ink", "--surface",
  "--primary", "--primary-soft", "--primary-text", "--secondary", "--secondary-soft", "--secondary-text",
  "--warning", "--warning-soft", "--success", "--success-soft", "--success-text"]
  ## The tokens a page may name in a table colour, as `tint("--secondary")`.

func tint*(token: string): string =
  ## A token as a CSS colour, for tabelline's colour arguments: `style.fill(tint("--secondary-soft"))`.
  doAssert token in tokenColours, "not a token: " & token
  "var(" & token & ")"
