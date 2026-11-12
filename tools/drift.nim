## drift: count what a nimib page writes as HTML or CSS instead of using blocks.
##
##   nim r drift.nim [--allow:FILE ...] [--fail] PATH ...
##
## PATH is a .nim file or a folder (searched recursively). For each file it counts calls of
## nbRawHtml, nbText blocks whose triple-quoted text holds an HTML tag, <style and <script,
## inline style=" and distinct #RRGGBB colours. Files given with --allow (the style module, the
## blocks module) are where CSS and HTML belong: they are listed but never counted as drift.
## With --fail it exits with 1 when any other file has drift. Code shown in prose is not drift:
## Markdown code (`spans` and fences) inside nbText and Nim comments are left out of the count.
import std/[os, strutils, sequtils, parseopt, strformat]

type Count = object
  raw, textHtml, style, script, inline, hex: int

const tags = ["<div", "<p ", "<p>", "<span", "<ul", "<ol", "<li", "<table", "<h1", "<h2", "<h3",
              "<small", "<details", "<button", "<br", "<a href", "<strong", "<em>", "<img"]

proc countOf(s, sub: string): int =
  var i = s.find(sub)
  while i >= 0:
    inc result
    i = s.find(sub, i + sub.len)

proc withoutCode(md: string): string =
  ## Markdown text without its code fences and `code spans`.
  var fence = false
  for line in md.splitLines:
    if line.strip.startsWith("```"):
      fence = not fence
      continue
    if fence: continue
    var inSpan = false
    for c in line:
      if c == '`': inSpan = not inSpan
      elif not inSpan: result.add c
    result.add '\n'

proc proseless(src: string): string =
  ## The source with Nim comments dropped and the code shown in nbText prose removed.
  for line in src.splitLines:
    if not line.strip.startsWith("#"): result.add line & "\n"
  var i = result.find("nbText:")
  while i >= 0:
    let a = result.find("\"\"\"", i)
    if a < 0: break
    let b = result.find("\"\"\"", a + 3)
    if b < 0: break
    let text = withoutCode(result[a + 3 ..< b])
    result = result[0 .. a + 2] & text & result[b .. ^1]
    i = result.find("nbText:", a + 3 + text.len + 3)

proc count(src: string): Count =
  let s = proseless(src)
  result.raw = s.countOf("nbRawHtml") - s.countOf("template nbRawHtml")
  var i = s.find("nbText:")
  while i >= 0:
    let a = s.find("\"\"\"", i)
    if a < 0: break
    let b = s.find("\"\"\"", a + 3)
    if b < 0: break
    if tags.anyIt(it in s[a + 3 ..< b]): inc result.textHtml
    i = s.find("nbText:", b)
  result.style = s.countOf("<style")
  result.script = s.countOf("<script")
  result.inline = s.countOf("style=\\\"") + s.countOf("style=\"")
  var found: seq[string]
  var k = 0
  while k < s.len - 6:
    if s[k] == '#' and allIt(s[k+1 .. k+6], it in HexDigits) and
       (k + 7 >= s.len or s[k+7] notin HexDigits + Letters):
      found.add s[k .. k+6].toUpperAscii
      k += 7
    else: inc k
  result.hex = found.deduplicate.len

proc total(c: Count): int = c.raw + c.textHtml + c.style + c.script + c.inline + c.hex

var paths, allowed: seq[string]
var fail = false
for kind, key, val in getopt():
  case kind
  of cmdArgument: paths.add key
  of cmdLongOption, cmdShortOption:
    case key
    of "allow": allowed.add val.absolutePath.normalizedPath
    of "fail": fail = true
    else: quit &"unknown option --{key}"
  of cmdEnd: discard
if paths.len == 0: quit "usage: nim r drift.nim [--allow:FILE ...] [--fail] PATH ..."

var files: seq[string]
for p in paths:
  if dirExists(p):
    for f in walkDirRec(p):
      if f.endsWith(".nim"): files.add f
  elif fileExists(p): files.add p
  else: quit &"not found: {p}"

echo "file\tnbRawHtml\tnbText html\t<style\t<script\tstyle=\thex colours\tallowed"
var drift = 0
for f in files:
  let c = count(readFile(f))
  let ok = f.absolutePath.normalizedPath in allowed
  if c.total > 0 or ok:
    echo &"{f}\t{c.raw}\t{c.textHtml}\t{c.style}\t{c.script}\t{c.inline}\t{c.hex}\t{ok}"
  if not ok: drift += c.total
echo &"\ndrift outside the allowed files: {drift}"
if fail and drift > 0: quit 1
