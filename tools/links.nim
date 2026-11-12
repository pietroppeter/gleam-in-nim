## Links: every link of the built site leads somewhere.
##
##   nim r tools/links.nim               # links inside the site: files and #anchors
##   nim r tools/links.nim --external    # and links to other sites (needs the network)
##
## Run it after building the pages (`nim r docs/all.nim`): it reads every `.html` file under
## docs/. A link inside the site fails when its file is missing, or when its `#anchor` is no
## `id` of that page. A link to a file of this repository is checked in the checkout. A link to
## another site fails only when the site answers 404 or 410, so a page that moved or went away
## is caught; a timeout, a refusal or a 5xx is a warning, since it says nothing sure about the
## link. CI runs the first on every pull request and the second once a week.
## After tabelline's tools/links.nim.
import std/[os, osproc, strutils, sets, tables, uri, httpclient, asyncdispatch, algorithm, sequtils]

const
  root = currentSourcePath().parentDir.parentDir
  site = root / "docs"
  # the site's own address: a link to it is checked as a link inside the site
  ownBase = "https://pietroppeter.github.io/gleam-in-nim/"
  agent = "gleam-in-nim-links (+https://github.com/pietroppeter/gleam-in-nim)"
  parallel = 16
  skipped = ["github.com/pietroppeter/gleam-in-nim/edit/", "github.com/pietroppeter/gleam-in-nim/new/"]
  # a link to a file of this repository, on main or on the branch being built, is checked in the
  # checkout, without the network: a pull request that adds the file links it before
  # it is on main, and a link with no branch (blob//) or another branch is broken
  ownBlob = "https://github.com/pietroppeter/gleam-in-nim/blob/"

type Link = object
  page, href: string

proc attrValues(html, attr: string): seq[string] =
  ## The values of `attr="..."` (or '...') in the HTML, `href` or `id`.
  for q in ['"', '\'']:
    let key = " " & attr & "=" & q
    var i = html.find(key)
    while i >= 0:
      let start = i + key.len
      let stop = html.find(q, start)
      if stop < 0: break
      result.add html[start ..< stop]
      i = html.find(key, stop)

proc withoutCode(html: string): string =
  ## The HTML without `<pre>` and `<script>` blocks: a link written in code is text, not a link.
  result = html
  for (open, close) in [("<pre", "</pre>"), ("<script", "</script>")]:
    var i = result.find(open)
    while i >= 0:
      let stop = result.find(close, i)
      if stop < 0: break
      result.delete(i ..< stop + close.len)
      i = result.find(open, i)

proc htmlDecode(s: string): string =
  s.multiReplace(("&amp;", "&"), ("&#39;", "'"), ("&quot;", "\""))

proc check(url: string): Future[(int, string)] {.async.} =
  ## The status code of `url` (HEAD, then GET when HEAD is refused), or 0 and the error.
  for verb in [HttpHead, HttpGet]:
    let client = newAsyncHttpClient(userAgent = agent, maxRedirects = 10)
    try:
      let r = client.request(url, httpMethod = verb)
      if not await r.withTimeout(20_000):
        return (0, "timeout")
      let code = r.read.code.int
      if verb == HttpGet or code notin [403, 404, 405, 501]:
        return (code, "")
    except CatchableError as e:
      return (0, e.msg.splitLines[0])
    finally:
      client.close()

proc checkAll(urls: seq[string]): Future[seq[(int, string)]] {.async.} =
  ## `check` for every url, `parallel` at a time.
  result = newSeq[(int, string)](urls.len)
  var next = 0
  proc worker(res: ptr seq[(int, string)]) {.async.} =
    while next < urls.len:
      let i = next
      inc next
      res[][i] = await check(urls[i])
  var workers: seq[Future[void]]
  for _ in 1 .. parallel: workers.add worker(addr result)
  await all(workers)

proc main() =
  let external = "--external" in commandLineParams()
  # on a push GitHub sets GITHUB_HEAD_REF to "", so only a non-empty value names a branch
  let branches = if getEnv("GITHUB_HEAD_REF").len > 0: @["main", getEnv("GITHUB_HEAD_REF")] else: @["main"]
  var ids: Table[string, HashSet[string]]
  var links: seq[Link]
  for path in walkDirRec(site):
    if not path.endsWith(".html"): continue
    let rel = path.relativePath(site).replace('\\', '/')
    let html = readFile(path).withoutCode
    ids[rel] = toHashSet(html.attrValues("id") & html.attrValues("name"))
    for href in html.attrValues("href"):
      links.add Link(page: rel, href: href.htmlDecode)
  if ids.len == 0:
    quit "no pages under docs/: build them first (nim r docs/all.nim)"

  var broken, warnings: seq[string]
  var outside: Table[string, seq[string]]   # url -> pages that link it
  for l in links:
    var href = l.href.strip
    if href.len == 0 or href.startsWith("mailto:") or href.startsWith("javascript:") or
       href.startsWith("data:") or href.startsWith("tel:"): continue
    if href.startsWith(ownBase):
      href = relativePath(site / href[ownBase.len .. ^1], site / l.page.parentDir).replace('\\', '/')
    if href.startsWith(ownBlob):
      let rest = href[ownBlob.len .. ^1].split('#')[0].decodeUrl
      let branch = branches.filterIt(rest.startsWith(it & "/"))
      let sha = rest.split('/')[0]
      if branch.len == 0 and sha.len >= 7 and sha.allIt(it in HexDigits):
        # a link pinned to a commit: the file must be in that commit (the checkout has the history)
        let spec = sha & ":" & rest[sha.len + 1 .. ^1].strip(leading = false, chars = {'/'})
        if execCmdEx("git cat-file -e " & quoteShell(spec), workingDir = root).exitCode != 0:
          broken.add l.page & ": " & l.href & " (no " & spec & " in the history)"
        continue
      if branch.len == 0:
        broken.add l.page & ": " & l.href & " (not on " & branches.join(" or ") & ")"
        continue
      let path = rest[branch[0].len + 1 .. ^1]
      if not (fileExists(root / path) or dirExists(root / path)):
        broken.add l.page & ": " & l.href & " (no " & path & " in the repository)"
      continue
    if href.startsWith("http://") or href.startsWith("https://") or href.startsWith("//"):
      if not skipped.anyIt(it in href):
        outside.mgetOrPut(href.split('#')[0], @[]).add l.page
      continue
    let parts = href.split('#', 1)
    var target = parts[0].split('?')[0].decodeUrl
    let anchor = if parts.len > 1: parts[1].decodeUrl else: ""
    var file = if target.len == 0: l.page
               else: normalizedPath(l.page.parentDir / target).replace('\\', '/')
    if file.startsWith("../"):
      broken.add l.page & ": " & l.href & " (leaves the site)"
      continue
    if target.len > 0 and (dirExists(site / file) or target.endsWith("/")):
      file = file.strip(leading = false, chars = {'/'}) & "/index.html"
      if file == "/index.html": file = "index.html"
    if not fileExists(site / file):
      broken.add l.page & ": " & l.href & " (no " & file & ")"
    elif anchor.len > 0 and file.endsWith(".html") and file in ids and anchor notin ids[file]:
      broken.add l.page & ": " & l.href & " (no #" & anchor & " in " & file & ")"

  if external:
    var urls = toSeq(outside.keys)
    urls.sort
    let answers = waitFor checkAll(urls)
    for i, url in urls:
      let (code, err) = answers[i]
      let where = outside[url].deduplicate.join(", ")
      if code in [404, 410]:
        broken.add where & ": " & url & " (" & $code & ")"
      elif code == 0 or code >= 400:
        warnings.add where & ": " & url & " (" & (if code == 0: err else: $code) & ")"

  for w in warnings: echo "warning: ", w
  for b in broken: echo "broken: ", b
  echo ids.len, " pages, ", links.len, " links, ", outside.len, " to other sites",
       (if external: " (checked)" else: " (not checked: --external)"),
       ", ", broken.len, " broken, ", warnings.len, " warnings"
  if broken.len > 0: quit 1

main()
