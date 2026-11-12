# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2018 The codespan-reporting contributors
#
# Not a port of a Gleam file. Ported to Nim from the Rust crate
# codespan-reporting 0.13.1 (Brendan Zabarauskas and contributors, Apache-2.0),
# the version in the lock file of the reference compiler:
#   src/diagnostic.rs, src/files.rs, src/term/config.rs, src/term/renderer.rs,
#   src/term/views.rs, src/term/mod.rs
# https://github.com/brendanzab/codespan/tree/master/codespan-reporting
#
# What differs from the crate: one concrete writer (termcolor's Buffer, with
# the default styles, as the Gleam compiler uses it) where the crate has a
# `WriteStyle` trait; file ids are `int`; the crate's `Result<(), Error>`
# is an exception, `FilesError`.

## Diagnostic reporting for text based programming languages: a message, and
## the lines of source it is about, with carets under the spans.
import std/[algorithm, options, strutils, tables]
import std/unicode except repeat, strip, split, splitWhitespace, align, alignLeft, isUpper, isLower, toUpper, toLower, capitalize, title, swapCase, isAlpha, isSpace, translate
import termcolor, unicode_width

# ---------------------------------------------------------------- diagnostic

type
  Severity* {.pure.} = enum
    ## A severity level for diagnostic messages. These are ordered:
    ## `Bug > Error > Warning > Note > Help`.
    Help     ## A help message.
    Note     ## A note.
    Warning  ## A warning.
    Error    ## An error.
    Bug      ## An unexpected bug.

  LabelStyle* {.pure.} = enum
    Primary    ## Labels that describe the primary cause of a diagnostic.
    Secondary  ## Labels that provide additional context for a diagnostic.

  Range* = tuple[start, stop: int]
    ## A half open range of byte indexes (`Range<usize>`; `end` is `stop`).

  Label* = object
    ## A label describing an underlined region of code associated with a diagnostic.
    style*: LabelStyle
    fileId*: int
    range*: Range
    message*: string  ## An optional message to provide some additional information for the underlined code.

  Diagnostic* = object
    ## Represents a diagnostic message that can provide information like errors
    ## and warnings to the user.
    severity*: Severity
    code*: Option[string]
    message*: string
    labels*: seq[Label]
    notes*: seq[string]

func newLabel*(style: LabelStyle, fileId: int, range: Range): Label =
  Label(style: style, fileId: fileId, range: range, message: "")

func withMessage*(label: Label, message: string): Label =
  result = label
  result.message = message

func newDiagnostic*(severity: Severity): Diagnostic =
  Diagnostic(severity: severity)

func withMessage*(diagnostic: Diagnostic, message: string): Diagnostic =
  result = diagnostic
  result.message = message

func withLabels*(diagnostic: Diagnostic, labels: seq[Label]): Diagnostic =
  result = diagnostic
  result.labels.add labels

func withNotes*(diagnostic: Diagnostic, notes: seq[string]): Diagnostic =
  result = diagnostic
  result.notes.add notes

# --------------------------------------------------------------------- files

type
  FilesError* = object of CatchableError
    ## An error that happened while looking up a file or a piece of content in that file.

  Location* = object
    ## A user-facing location in a source file.
    lineNumber*: int    ## The user-facing line number.
    columnNumber*: int  ## The user-facing column number.

  SimpleFile* = object
    ## A file, with the byte index of the start of each of its lines.
    name: string
    source: string
    lineStarts: seq[int]

  SimpleFiles* = object
    ## A file database that can store multiple source files.
    files: seq[SimpleFile]

func isCharBoundary(source: string, index: int): bool =
  if index == 0 or index == source.len: true
  elif index > source.len: false
  else: (source[index].ord and 0xC0) != 0x80

func columnIndex*(source: string, lineRange: Range, byteIndex: int): int =
  ## The column index at the given byte index in the source file.
  ## This is the number of characters to the given byte index.
  let endIndex = min(byteIndex, min(lineRange.stop, source.len))
  for index in lineRange.start ..< endIndex:
    if source.isCharBoundary(index + 1): inc result

func lineStarts*(source: string): seq[int] =
  ## Return the starting byte index of each line in the source string.
  result.add 0
  for index, ch in source:
    if ch == '\n': result.add index + 1

func newSimpleFile*(name, source: string): SimpleFile =
  SimpleFile(name: name, source: source, lineStarts: lineStarts(source))

func lineStart(file: SimpleFile, lineIndex: int): int =
  ## Return the starting byte index of the line with the specified line index.
  if lineIndex < file.lineStarts.len: file.lineStarts[lineIndex]
  elif lineIndex == file.lineStarts.len: file.source.len
  else:
    raise newException(FilesError,
      "invalid line " & $lineIndex & ", maximum line is " & $(file.lineStarts.len - 1))

func lineIndex(file: SimpleFile, byteIndex: int): int =
  # binary_search, then `unwrap_or_else(|next_line| next_line - 1)`
  file.lineStarts.upperBound(byteIndex) - 1

func lineRange(file: SimpleFile, lineIndex: int): Range =
  (file.lineStart(lineIndex), file.lineStart(lineIndex + 1))

func add*(files: var SimpleFiles, name, source: string): int =
  ## Add a file to the database, returning the handle that can be used to
  ## refer to it again.
  result = files.files.len
  files.files.add newSimpleFile(name, source)

func get(files: SimpleFiles, fileId: int): lent SimpleFile =
  if fileId < 0 or fileId >= files.files.len: raise newException(FilesError, "file missing")
  files.files[fileId]

func name*(files: SimpleFiles, fileId: int): string = files.get(fileId).name
func source*(files: SimpleFiles, fileId: int): lent string = files.get(fileId).source
func lineIndex*(files: SimpleFiles, fileId, byteIndex: int): int = files.get(fileId).lineIndex(byteIndex)
func lineNumber*(files: SimpleFiles, fileId, lineIndex: int): int = lineIndex + 1
func lineRange*(files: SimpleFiles, fileId, lineIndex: int): Range = files.get(fileId).lineRange(lineIndex)

func columnNumber*(files: SimpleFiles, fileId, lineIndex, byteIndex: int): int =
  columnIndex(files.source(fileId), files.lineRange(fileId, lineIndex), byteIndex) + 1

func location*(files: SimpleFiles, fileId, byteIndex: int): Location =
  let lineIndex = files.lineIndex(fileId, byteIndex)
  Location(lineNumber: files.lineNumber(fileId, lineIndex),
           columnNumber: files.columnNumber(fileId, lineIndex, byteIndex))

# -------------------------------------------------------------------- config

type
  DisplayStyle* {.pure.} = enum
    ## The display style to use when rendering diagnostics.
    Rich    ## Output a richly formatted diagnostic, with source code previews.
    Medium  ## Output a condensed diagnostic, with a line number, severity, message and notes (if any).
    Short   ## Output a short diagnostic, with a line number, severity, and message.

  Chars* = object
    ## Characters to use when rendering the diagnostic.
    snippetStart*: string
    sourceBorderLeft*: string
    sourceBorderLeftBreak*: string
    noteBullet*: string
    singlePrimaryCaret*: string
    singleSecondaryCaret*: string
    multiPrimaryCaretStart*: string
    multiPrimaryCaretEnd*: string
    multiSecondaryCaretStart*: string
    multiSecondaryCaretEnd*: string
    multiTopLeft*: string
    multiTop*: string
    multiBottomLeft*: string
    multiBottom*: string
    multiLeft*: string
    pointerLeft*: string

  Config* = object
    ## Configures how a diagnostic is rendered.
    displayStyle*: DisplayStyle
    tabWidth*: int            ## Column width of tabs.
    chars*: Chars
    startContextLines*: int   ## The minimum number of lines to be shown after the line on which a multiline label begins.
    endContextLines*: int     ## The minimum number of lines to be shown before the line on which a multiline label ends.
    beforeLabelLines*: int    ## The minimum number of lines before a label that should be included for context.
    afterLabelLines*: int     ## The minimum number of lines after a label that should be included for context.

  Styles = object
    headerBug, headerError, headerWarning, headerNote, headerHelp, headerMessage: ColorSpec
    primaryLabelBug, primaryLabelError, primaryLabelWarning, primaryLabelNote, primaryLabelHelp: ColorSpec
    secondaryLabel, lineNumber, sourceBorder, noteBullet: ColorSpec

func boxDrawing*(_: typedesc[Chars]): Chars =
  ## A character set that uses Unicode box drawing characters.
  Chars(
    snippetStart: "┌─",
    sourceBorderLeft: "│",
    sourceBorderLeftBreak: "·",
    noteBullet: "=",
    singlePrimaryCaret: "^",
    singleSecondaryCaret: "-",
    multiPrimaryCaretStart: "^",
    multiPrimaryCaretEnd: "^",
    multiSecondaryCaretStart: "'",
    multiSecondaryCaretEnd: "'",
    multiTopLeft: "╭",
    multiTop: "─",
    multiBottomLeft: "╰",
    multiBottom: "─",
    multiLeft: "│",
    pointerLeft: "│",
  )

func defaultConfig*(): Config =
  Config(
    displayStyle: DisplayStyle.Rich,
    tabWidth: 4,
    chars: Chars.boxDrawing,
    startContextLines: 3,
    endContextLines: 1,
    beforeLabelLines: 0,
    afterLabelLines: 0,
  )

func defaultStyles(): Styles =
  let header = newColorSpec().setBold(true).setIntense(true)
  Styles(
    headerBug: header.setFg(some(Color.Red)),
    headerError: header.setFg(some(Color.Red)),
    headerWarning: header.setFg(some(Color.Yellow)),
    headerNote: header.setFg(some(Color.Green)),
    headerHelp: header.setFg(some(Color.Cyan)),
    headerMessage: header,
    primaryLabelBug: newColorSpec().setFg(some(Color.Red)),
    primaryLabelError: newColorSpec().setFg(some(Color.Red)),
    primaryLabelWarning: newColorSpec().setFg(some(Color.Yellow)),
    primaryLabelNote: newColorSpec().setFg(some(Color.Green)),
    primaryLabelHelp: newColorSpec().setFg(some(Color.Cyan)),
    secondaryLabel: newColorSpec().setFg(some(Color.Cyan)),
    lineNumber: newColorSpec().setFg(some(Color.Cyan)),
    sourceBorder: newColorSpec().setFg(some(Color.Cyan)),
    noteBullet: newColorSpec().setFg(some(Color.Cyan)),
  )

const styles = defaultStyles()

func header(styles: Styles, severity: Severity): ColorSpec =
  case severity
  of Severity.Bug: styles.headerBug
  of Severity.Error: styles.headerError
  of Severity.Warning: styles.headerWarning
  of Severity.Note: styles.headerNote
  of Severity.Help: styles.headerHelp

func label(styles: Styles, severity: Severity, labelStyle: LabelStyle): ColorSpec =
  case labelStyle
  of LabelStyle.Primary:
    case severity
    of Severity.Bug: styles.primaryLabelBug
    of Severity.Error: styles.primaryLabelError
    of Severity.Warning: styles.primaryLabelWarning
    of Severity.Note: styles.primaryLabelNote
    of Severity.Help: styles.primaryLabelHelp
  of LabelStyle.Secondary: styles.secondaryLabel

# ------------------------------------------------------------------ renderer

type
  Locus* = object
    ## The 'location focus' of a source code snippet.
    name*: string         ## The user-facing name of the file.
    location*: Location   ## The location.

  SingleLabel* = tuple[style: LabelStyle, range: Range, message: string]
    ## Single-line label, with an optional message.
    ##
    ## ```text
    ## ^^^^^^^^^ blah blah
    ## ```

  MultiLabelKind* = enum
    mlTop     ## Multi-line label top. `start` indicates where the label starts.
    mlLeft    ## Left vertical labels for multi-line labels.
    mlBottom  ## Multi-line label bottom, with an optional message. `start` indicates where the label ends.

  MultiLabel* = object
    ## A multi-line label to render.
    ##
    ## Locations are relative to the start of where the source code is rendered.
    kind*: MultiLabelKind
    start*: int
    message*: string

  IndexedMultiLabel* = tuple[index: int, style: LabelStyle, label: MultiLabel]

  VerticalBound = enum
    vbTop, vbBottom

  Underline = tuple[style: LabelStyle, bound: VerticalBound]

  Renderer* = object
    ## A renderer of display list entries.
    ##
    ## The following diagram gives an overview of each of the parts of the renderer's output:
    ##
    ## ```text
    ##                     ┌ outer gutter
    ##                     │ ┌ left border
    ##                     │ │ ┌ inner gutter
    ##                     │ │ │   ┌─────────────────────────── source ─────────────────────────────┐
    ##                     │ │ │   │                                                                │
    ##                  ┌────────────────────────────────────────────────────────────────────────────
    ##        header ── │ error[0001]: oh noes, a cupcake has occurred!
    ## snippet start ── │    ┌─ test:9:0
    ## snippet empty ── │    │
    ##  snippet line ── │  9 │   ╭ Cupcake ipsum dolor. Sit amet marshmallow topping cheesecake
    ##  snippet line ── │ 10 │   │ muffin. Halvah croissant candy canes bonbon candy. Apple pie jelly
    ##                  │    │ ╭─│─────────^
    ## snippet break ── │    · │ │
    ##  snippet line ── │ 33 │ │ │ Muffin danish chocolate soufflé pastry icing bonbon oat cake.
    ##  snippet line ── │ 34 │ │ │ Powder cake jujubes oat cake. Lemon drops tootsie roll marshmallow
    ##                  │    │ │ ╰─────────────────────────────^ blah blah
    ## snippet break ── │    · │
    ##  snippet line ── │ 38 │ │   Brownie lemon drops chocolate jelly-o candy canes. Danish marzipan
    ##  snippet line ── │ 39 │ │   jujubes soufflé carrot cake marshmallow tiramisu caramels candy canes.
    ##                  │    │ │           ^^^^^^^^^^^^^^^^^^^ -------------------- blah blah
    ##                  │    │ │           │
    ##                  │    │ │           blah blah
    ##                  │    │ │           note: this is a note
    ##  snippet line ── │ 40 │ │   Fruitcake jelly-o danish toffee. Tootsie roll pastry cheesecake
    ##  snippet line ── │ 41 │ │   soufflé marzipan. Chocolate bar oat cake jujubes lollipop pastry
    ##  snippet line ── │ 42 │ │   cupcake. Candy canes cupcake toffee gingerbread candy canes muffin
    ##                  │    │ │                                ^^^^^^^^^^^^^^^^^^ blah blah
    ##                  │    │ ╰──────────^ blah blah
    ## snippet break ── │    ·
    ##  snippet line ── │ 82 │     gingerbread toffee chupa chups chupa chups jelly-o cotton candy.
    ##                  │    │                 ^^^^^^                         ------- blah blah
    ## snippet empty ── │    │
    ##  snippet note ── │    = blah blah
    ##  snippet note ── │    = blah blah blah
    ##                  │      blah blah
    ##  snippet note ── │    = blah blah blah
    ##                  │      blah blah
    ##         empty ── │
    ## ```
    ##
    ## > Filler text from <http://www.cupcakeipsum.com>
    writer: Buffer
    config: Config

  Metrics = object
    byteIndex: int
    unicodeWidth: int

  CharIndex = tuple[byteIndex: int, ch: Rune]

func newRenderer*(writer: Buffer, config: Config): Renderer =
  ## Construct a renderer from the given writer and config.
  Renderer(writer: writer, config: config)

template chars(renderer: Renderer): Chars = renderer.config.chars

func write(renderer: Renderer, text: string) = renderer.writer.write(text)
func setHeader(renderer: Renderer, severity: Severity) = renderer.writer.setColor(styles.header(severity))
func setHeaderMessage(renderer: Renderer) = renderer.writer.setColor(styles.headerMessage)
func setLineNumber(renderer: Renderer) = renderer.writer.setColor(styles.lineNumber)
func setNoteBullet(renderer: Renderer) = renderer.writer.setColor(styles.noteBullet)
func setSourceBorder(renderer: Renderer) = renderer.writer.setColor(styles.sourceBorder)
func setLabel(renderer: Renderer, severity: Severity, labelStyle: LabelStyle) =
  renderer.writer.setColor(styles.label(severity, labelStyle))
func reset(renderer: Renderer) = renderer.writer.reset()

func isOverlapping(range0, range1: Range): bool =
  ## Check if two ranges overlap
  let start = max(range0.start, range1.start)
  let stop = min(range0.stop, range1.stop)
  start < stop

func labelPriorityKey(labelStyle: LabelStyle): int =
  ## For prioritizing primary labels over secondary labels when rendering carets.
  case labelStyle
  of LabelStyle.Secondary: 0
  of LabelStyle.Primary: 1

func maxByKey(found: Option[LabelStyle], labelStyle: LabelStyle): Option[LabelStyle] =
  ## One step of Rust's `max_by_key(label_priority_key)`.
  if found.isNone or labelPriorityKey(labelStyle) >= labelPriorityKey(found.get): some(labelStyle)
  else: found

func hangingLabels(singleLabels: openArray[SingleLabel], trailingLabel: Option[int]): seq[SingleLabel] =
  ## The labels that require hanging messages rendered underneath them.
  for index, label in singleLabels:
    if label.message.len > 0 and (trailingLabel.isNone or trailingLabel.get != index):
      result.add label

func charIndices(source: string): seq[CharIndex] =
  ## `str::char_indices`.
  var index = 0
  while index < source.len:
    let start = index
    var ch: Rune
    fastRuneAt(source, index, ch, true)
    result.add (start, ch)

func isRustWhitespace(ch: Rune): bool =
  ## `char::is_whitespace`: the code points with the property White_Space.
  case ch.int32
  of 0x09 .. 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000 .. 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
  else: false

func leadingWhitespace(source: string): int =
  ## `source.len() - source.trim_start().len()`.
  for (byteIndex, ch) in charIndices(source):
    if not isRustWhitespace(ch): return byteIndex
  source.len

func rustLines(text: string): seq[string] =
  ## `str::lines`: split at `\n`, drop one `\r` before it, no last empty line.
  var start = 0
  for index, ch in text:
    if ch == '\n':
      var stop = index
      if stop > start and text[stop - 1] == '\r': dec stop
      result.add text[start ..< stop]
      start = index + 1
  if start < text.len:
    # upstream strips only "\n" or "\r\n": a last line that ends in a lone `\r` keeps it
    result.add text[start .. ^1]

func padLeft(text: string, width: int): string =
  ## `{text: >width$}`, for text made of ASCII.
  if text.len >= width: text else: ' '.repeat(width - text.len) & text

func charMetrics(renderer: Renderer, charIndices: openArray[CharIndex]): seq[tuple[metrics: Metrics, ch: Rune]] =
  ## Adds tab-stop aware unicode-width computations to an iterator over
  ## character indices. Assumes that the character indices begin at the start
  ## of the line.
  let tabWidth = renderer.config.tabWidth
  var unicodeColumn = 0
  for (byteIndex, ch) in charIndices:
    let metrics = Metrics(
      byteIndex: byteIndex,
      unicodeWidth:
        if ch == Rune('\t'):
          if tabWidth == 0: 0  # Guard divide-by-zero
          else: tabWidth - (unicodeColumn mod tabWidth)
        else: ch.width,
    )
    unicodeColumn += metrics.unicodeWidth
    result.add (metrics, ch)

func snippetLocus(renderer: Renderer, locus: Locus) =
  ## Location focus.
  renderer.write locus.name & ":" & $locus.location.lineNumber & ":" & $locus.location.columnNumber

func outerGutter(renderer: Renderer, outerPadding: int) =
  ## The outer gutter of a source line.
  renderer.write ' '.repeat(outerPadding) & " "

func outerGutterNumber(renderer: Renderer, lineNumber, outerPadding: int) =
  ## The outer gutter of a source line, with line number.
  renderer.setLineNumber()
  renderer.write padLeft($lineNumber, outerPadding)
  renderer.reset()
  renderer.write " "

func borderLeft(renderer: Renderer) =
  ## The left-hand border of a source line.
  renderer.setSourceBorder()
  renderer.write renderer.chars.sourceBorderLeft
  renderer.reset()

func borderLeftBreak(renderer: Renderer) =
  ## The broken left-hand border of a source line.
  renderer.setSourceBorder()
  renderer.write renderer.chars.sourceBorderLeftBreak
  renderer.reset()

func caretPointers(renderer: Renderer, severity: Severity, maxLabelStart: int,
                   singleLabels: openArray[SingleLabel], trailingLabel: Option[int],
                   charIndices: openArray[CharIndex]) =
  ## Write vertical lines pointing to carets.
  for (metrics, ch) in renderer.charMetrics(charIndices):
    let columnRange: Range = (metrics.byteIndex, metrics.byteIndex + ch.size)
    var labelStyle = none(LabelStyle)
    for label in hangingLabels(singleLabels, trailingLabel):
      if columnRange.start <= label.range.start and label.range.start < columnRange.stop:
        labelStyle = maxByKey(labelStyle, label.style)

    var spaces = metrics.unicodeWidth
    if labelStyle.isSome:
      renderer.setLabel(severity, labelStyle.get)
      renderer.write renderer.chars.pointerLeft
      renderer.reset()
      spaces = metrics.unicodeWidth - 1
    # Only print padding if we are before the end of the last single line caret
    if metrics.byteIndex <= maxLabelStart:
      for _ in 0 ..< spaces: renderer.write " "

func labelMultiLeft(renderer: Renderer, severity: Severity, labelStyle: LabelStyle,
                    underline: Option[LabelStyle]) =
  ## The left of a multi-line label.
  ##
  ## ```text
  ##  │
  ## ```
  if underline.isNone:
    renderer.write " "
  else:
    # Continue an underline horizontally
    renderer.setLabel(severity, underline.get)
    renderer.write renderer.chars.multiTop
    renderer.reset()
  renderer.setLabel(severity, labelStyle)
  renderer.write renderer.chars.multiLeft
  renderer.reset()

func labelMultiTopLeft(renderer: Renderer, severity: Severity, labelStyle: LabelStyle) =
  ## The top-left of a multi-line label.
  ##
  ## ```text
  ##  ╭
  ## ```
  renderer.write " "
  renderer.setLabel(severity, labelStyle)
  renderer.write renderer.chars.multiTopLeft
  renderer.reset()

func labelMultiBottomLeft(renderer: Renderer, severity: Severity, labelStyle: LabelStyle) =
  ## The bottom left of a multi-line label.
  ##
  ## ```text
  ##  ╰
  ## ```
  renderer.write " "
  renderer.setLabel(severity, labelStyle)
  renderer.write renderer.chars.multiBottomLeft
  renderer.reset()

func labelMultiTopCaret(renderer: Renderer, severity: Severity, labelStyle: LabelStyle,
                        source: string, start: int) =
  ## Multi-line label top.
  ##
  ## ```text
  ## ─────────────^
  ## ```
  renderer.setLabel(severity, labelStyle)

  for (metrics, _) in renderer.charMetrics(charIndices(source)):
    if not (metrics.byteIndex < start + 1): break
    # FIXME: improve rendering of carets between character boundaries
    for _ in 0 ..< metrics.unicodeWidth: renderer.write renderer.chars.multiTop

  let caretStart = case labelStyle
    of LabelStyle.Primary: renderer.config.chars.multiPrimaryCaretStart
    of LabelStyle.Secondary: renderer.config.chars.multiSecondaryCaretStart
  renderer.write caretStart
  renderer.reset()
  renderer.write "\n"

func labelMultiBottomCaret(renderer: Renderer, severity: Severity, labelStyle: LabelStyle,
                           source: string, start: int, message: string) =
  ## Multi-line label bottom, with a message.
  ##
  ## ```text
  ## ─────────────^ expected `Int` but found `String`
  ## ```
  renderer.setLabel(severity, labelStyle)

  for (metrics, _) in renderer.charMetrics(charIndices(source)):
    if not (metrics.byteIndex < start): break
    # FIXME: improve rendering of carets between character boundaries
    for _ in 0 ..< metrics.unicodeWidth: renderer.write renderer.chars.multiBottom

  let caretEnd = case labelStyle
    of LabelStyle.Primary: renderer.config.chars.multiPrimaryCaretStart
    of LabelStyle.Secondary: renderer.config.chars.multiSecondaryCaretStart
  renderer.write caretEnd
  if message.len > 0:
    renderer.write " " & message
  renderer.reset()
  renderer.write "\n"

func innerGutterSpace(renderer: Renderer) =
  ## Writes an empty gutter space.
  renderer.write "  "

func innerGutterColumn(renderer: Renderer, severity: Severity, underline: Option[Underline]) =
  ## Writes an empty gutter space, or continues an underline horizontally.
  if underline.isNone:
    renderer.innerGutterSpace()
  else:
    let (labelStyle, verticalBound) = underline.get
    renderer.setLabel(severity, labelStyle)
    let ch = case verticalBound
      of vbTop: renderer.config.chars.multiTop
      of vbBottom: renderer.config.chars.multiBottom
    renderer.write ch & ch
    renderer.reset()

func innerGutter(renderer: Renderer, severity: Severity, numMultiLabels: int,
                 multiLabels: openArray[IndexedMultiLabel]) =
  ## Writes an inner gutter, with the left lines if necessary.
  var next = 0
  for labelColumn in 0 ..< numMultiLabels:
    if next < multiLabels.len and multiLabels[next].index == labelColumn:
      case multiLabels[next].label.kind
      of mlLeft, mlBottom:
        renderer.labelMultiLeft(severity, multiLabels[next].style, none(LabelStyle))
        inc next
      of mlTop:
        renderer.innerGutterSpace()
        inc next
    else:
      renderer.innerGutterSpace()

func renderHeader*(renderer: Renderer, locus: Option[Locus], severity: Severity,
                   code: Option[string], message: string) =
  ## Diagnostic header, with severity, code, and message.
  ##
  ## ```text
  ## error[E0001]: unexpected type in `+` application
  ## ```

  # Write locus
  #
  # ```text
  # test:2:9:
  # ```
  if locus.isSome:
    renderer.snippetLocus(locus.get)
    renderer.write ": "

  # Write severity name
  #
  # ```text
  # error
  # ```
  renderer.setHeader(severity)
  case severity
  of Severity.Bug: renderer.write "bug"
  of Severity.Error: renderer.write "error"
  of Severity.Warning: renderer.write "warning"
  of Severity.Help: renderer.write "help"
  of Severity.Note: renderer.write "note"

  # Write error code
  #
  # ```text
  # [E0001]
  # ```
  if code.isSome and code.get.len > 0:
    renderer.write "[" & code.get & "]"

  # Write diagnostic message
  #
  # ```text
  # : unexpected type in `+` application
  # ```
  renderer.setHeaderMessage()
  renderer.write ": " & message
  renderer.reset()

  renderer.write "\n"

func renderEmpty*(renderer: Renderer) =
  ## Empty line.
  renderer.write "\n"

func renderSnippetStart*(renderer: Renderer, outerPadding: int, locus: Locus) =
  ## Top left border and locus.
  ##
  ## ```text
  ## ┌─ test:2:9
  ## ```
  renderer.outerGutter(outerPadding)

  renderer.setSourceBorder()
  renderer.write renderer.chars.snippetStart
  renderer.reset()

  renderer.write " "
  renderer.snippetLocus(locus)

  renderer.write "\n"

func renderSnippetSource*(renderer: Renderer, outerPadding, lineNumber: int, source: string,
                          severity: Severity, singleLabels: openArray[SingleLabel],
                          numMultiLabels: int, multiLabels: openArray[IndexedMultiLabel]) =
  ## A line of source code.
  ##
  ## ```text
  ## 10 │   │ muffin. Halvah croissant candy canes bonbon candy. Apple pie jelly
  ##    │ ╭─│─────────^
  ## ```

  # Trim trailing newlines, linefeeds, and null chars from source, if they exist.
  # FIXME: Use the number of trimmed placeholders when rendering single line carets
  var source = source
  while source.len > 0 and source[^1] in {'\n', '\r', '\0'}: source.setLen(source.len - 1)
  let sourceChars = charIndices(source)

  # Write source line
  #
  # ```text
  # 10 │   │ muffin. Halvah croissant candy canes bonbon candy. Apple pie jelly
  # ```
  block:
    # Write outer gutter (with line number) and border
    renderer.outerGutterNumber(lineNumber, outerPadding)
    renderer.borderLeft()

    # Write inner gutter (with multi-line continuations on the left if necessary)
    var next = 0
    for labelColumn in 0 ..< numMultiLabels:
      if next < multiLabels.len and multiLabels[next].index == labelColumn:
        let (_, labelStyle, label) = multiLabels[next]
        case label.kind
        of mlTop:
          if label.start <= leadingWhitespace(source):
            renderer.labelMultiTopLeft(severity, labelStyle)
          else:
            renderer.innerGutterSpace()
        of mlLeft, mlBottom:
          renderer.labelMultiLeft(severity, labelStyle, none(LabelStyle))
        inc next
      else:
        renderer.innerGutterSpace()

    # Write source text
    renderer.write " "
    var inPrimary = false
    for (metrics, ch) in renderer.charMetrics(sourceChars):
      let columnRange: Range = (metrics.byteIndex, metrics.byteIndex + ch.size)

      # Check if we are overlapping a primary label
      var isPrimary = false
      for (labelStyle, range, _) in singleLabels:
        if labelStyle == LabelStyle.Primary and isOverlapping(range, columnRange):
          isPrimary = true
          break
      if not isPrimary:
        for (_, labelStyle, label) in multiLabels:
          if labelStyle == LabelStyle.Primary and (
            case label.kind
            of mlTop: columnRange.start >= label.start
            of mlLeft: true
            of mlBottom: columnRange.stop <= label.start
          ):
            isPrimary = true
            break

      # Set the source color if we are in a primary label
      if isPrimary and not inPrimary:
        renderer.setLabel(severity, LabelStyle.Primary)
        inPrimary = true
      elif not isPrimary and inPrimary:
        renderer.reset()
        inPrimary = false

      if ch == Rune('\t'):
        for _ in 0 ..< metrics.unicodeWidth: renderer.write " "
      else:
        renderer.write $ch
    if inPrimary:
      renderer.reset()
    renderer.write "\n"

  # Write single labels underneath source
  #
  # ```text
  #   │     - ---- ^^^ second mutable borrow occurs here
  #   │     │ │
  #   │     │ first mutable borrow occurs here
  #   │     first borrow later used by call
  #   │     help: some help here
  # ```
  if singleLabels.len > 0:
    # Our plan is as follows:
    #
    # 1. Do an initial scan to find:
    #    - The number of non-empty messages.
    #    - The right-most start and end positions of labels.
    #    - A candidate for a trailing label (where the label's message
    #      is printed to the left of the caret).
    # 2. Check if the trailing label candidate overlaps another label -
    #    if so we print it underneath the carets with the other labels.
    # 3. Print a line of carets, and (possibly) the trailing message
    #    to the left.
    # 4. Print vertical lines pointing to the carets, and the messages
    #    for those carets.
    #
    # We try our best avoid introducing new dynamic allocations,
    # instead preferring to iterate over the labels multiple times. It
    # is unclear what the performance tradeoffs are however, so further
    # investigation may be required.

    # The number of non-empty messages to print.
    var numMessages = 0
    # The right-most start position, eg:
    #
    # ```text
    # -^^^^---- ^^^^^^^
    #           │
    #           right-most start position
    # ```
    var maxLabelStart = 0
    # The right-most end position, eg:
    #
    # ```text
    # -^^^^---- ^^^^^^^
    #                 │
    #                 right-most end position
    # ```
    var maxLabelEnd = 0
    # A trailing message, eg:
    #
    # ```text
    # ^^^ second mutable borrow occurs here
    # ```
    var trailingLabel = none(int)

    for labelIndex, label in singleLabels:
      if label.message.len > 0:
        inc numMessages
      maxLabelStart = max(maxLabelStart, label.range.start)
      maxLabelEnd = max(maxLabelEnd, label.range.stop)
      # This is a candidate for the trailing label, so let's record it.
      if label.range.stop == maxLabelEnd:
        if label.message.len == 0:
          trailingLabel = none(int)
        else:
          trailingLabel = some(labelIndex)
    if trailingLabel.isSome:
      # Check to see if the trailing label candidate overlaps any of
      # the other labels on the current line.
      let trailingRange = singleLabels[trailingLabel.get].range
      for labelIndex, label in singleLabels:
        if labelIndex != trailingLabel.get and isOverlapping(trailingRange, label.range):
          # If it does, we'll instead want to render it below the
          # carets along with the other hanging labels.
          trailingLabel = none(int)
          break

    # Write a line of carets
    #
    # ```text
    #   │ ^^^^^^  -------^^^^^^^^^-------^^^^^----- ^^^^ trailing label message
    # ```
    renderer.outerGutter(outerPadding)
    renderer.borderLeft()
    renderer.innerGutter(severity, numMultiLabels, multiLabels)
    renderer.write " "

    var previousLabelStyle = none(LabelStyle)
    let placeholderMetrics = Metrics(byteIndex: source.len, unicodeWidth: 1)
    # Add a placeholder source column at the end to allow for
    # printing carets at the end of lines, eg:
    #
    # ```text
    # 1 │ Hello world!
    #   │             ^
    # ```
    for (metrics, ch) in renderer.charMetrics(sourceChars) & @[(placeholderMetrics, Rune(0))]:
      # Find the current label style at this column
      let columnRange: Range = (metrics.byteIndex, metrics.byteIndex + ch.size)
      var currentLabelStyle = none(LabelStyle)
      for (labelStyle, range, _) in singleLabels:
        if isOverlapping(range, columnRange):
          currentLabelStyle = maxByKey(currentLabelStyle, labelStyle)

      # Update writer style if necessary
      if previousLabelStyle != currentLabelStyle:
        if currentLabelStyle.isNone:
          renderer.reset()
        else:
          renderer.setLabel(severity, currentLabelStyle.get)

      let caretCh =
        if currentLabelStyle == some(LabelStyle.Primary): renderer.chars.singlePrimaryCaret
        elif currentLabelStyle == some(LabelStyle.Secondary): renderer.chars.singleSecondaryCaret
        # Only print padding if we are before the end of the last single line caret
        elif metrics.byteIndex < maxLabelEnd: " "
        else: ""
      if caretCh.len > 0:
        # FIXME: improve rendering of carets between character boundaries
        for _ in 0 ..< metrics.unicodeWidth: renderer.write caretCh

      previousLabelStyle = currentLabelStyle
    # Reset style if it was previously set
    if previousLabelStyle.isSome:
      renderer.reset()
    # Write first trailing label message
    if trailingLabel.isSome:
      let (labelStyle, _, message) = singleLabels[trailingLabel.get]
      renderer.write " "
      renderer.setLabel(severity, labelStyle)
      renderer.write message
      renderer.reset()
    renderer.write "\n"

    # Write hanging labels pointing to carets
    #
    # ```text
    #   │     │ │
    #   │     │ first mutable borrow occurs here
    #   │     first borrow later used by call
    #   │     help: some help here
    # ```
    if numMessages > (if trailingLabel.isSome: 1 else: 0):
      # Write first set of vertical lines before hanging labels
      #
      # ```text
      #   │     │ │
      # ```
      renderer.outerGutter(outerPadding)
      renderer.borderLeft()
      renderer.innerGutter(severity, numMultiLabels, multiLabels)
      renderer.write " "
      renderer.caretPointers(severity, maxLabelStart, singleLabels, trailingLabel, sourceChars)
      renderer.write "\n"

      # Write hanging labels pointing to carets
      #
      # ```text
      #   │     │ first mutable borrow occurs here
      #   │     first borrow later used by call
      #   │     help: some help here
      # ```
      let hanging = hangingLabels(singleLabels, trailingLabel)
      for index in countdown(hanging.high, 0):
        let (labelStyle, range, message) = hanging[index]
        renderer.outerGutter(outerPadding)
        renderer.borderLeft()
        renderer.innerGutter(severity, numMultiLabels, multiLabels)
        renderer.write " "
        var before: seq[CharIndex]
        for item in sourceChars:
          if not (item.byteIndex < range.start): break
          before.add item
        renderer.caretPointers(severity, maxLabelStart, singleLabels, trailingLabel, before)
        renderer.setLabel(severity, labelStyle)
        renderer.write message
        renderer.reset()
        renderer.write "\n"

  # Write top or bottom label carets underneath source
  #
  # ```text
  #     │ ╰───│──────────────────^ woops
  #     │   ╭─│─────────^
  # ```
  for multiLabelIndex, (_, labelStyle, label) in multiLabels:
    var bottomMessage = none(string)
    case label.kind
    of mlLeft: continue  # no label caret needed
    of mlTop:
      # no label caret needed if this can be started in front of the line
      if label.start <= leadingWhitespace(source): continue
    of mlBottom:
      bottomMessage = some(label.message)
    let range = label.start

    renderer.outerGutter(outerPadding)
    renderer.borderLeft()

    # Write inner gutter.
    #
    # ```text
    #  │ ╭─│───│
    # ```
    var underline = none(Underline)
    var next = 0
    for labelColumn in 0 ..< numMultiLabels:
      if next < multiLabels.len and multiLabels[next].index == labelColumn:
        let i = next
        let (_, ls, other) = multiLabels[next]
        let continued = if underline.isSome: some(underline.get.style) else: none(LabelStyle)
        if other.kind == mlLeft:
          renderer.labelMultiLeft(severity, ls, continued)
        elif other.kind == mlTop and multiLabelIndex > i:
          renderer.labelMultiLeft(severity, ls, continued)
        elif other.kind == mlBottom and multiLabelIndex < i:
          renderer.labelMultiLeft(severity, ls, continued)
        elif other.kind == mlTop and multiLabelIndex == i:
          underline = some((ls, vbTop))
          renderer.labelMultiTopLeft(severity, labelStyle)
        elif other.kind == mlBottom and multiLabelIndex == i:
          underline = some((ls, vbBottom))
          renderer.labelMultiBottomLeft(severity, labelStyle)
        else:
          renderer.innerGutterColumn(severity, underline)
        inc next
      else:
        renderer.innerGutterColumn(severity, underline)

    # Finish the top or bottom caret
    if bottomMessage.isNone:
      renderer.labelMultiTopCaret(severity, labelStyle, source, range)
    else:
      renderer.labelMultiBottomCaret(severity, labelStyle, source, range, bottomMessage.get)

func renderSnippetEmpty*(renderer: Renderer, outerPadding: int, severity: Severity,
                         numMultiLabels: int, multiLabels: openArray[IndexedMultiLabel]) =
  ## An empty source line, for providing additional whitespace to source snippets.
  ##
  ## ```text
  ## │ │ │
  ## ```
  renderer.outerGutter(outerPadding)
  renderer.borderLeft()
  renderer.innerGutter(severity, numMultiLabels, multiLabels)
  renderer.write "\n"

func renderSnippetBreak*(renderer: Renderer, outerPadding: int, severity: Severity,
                         numMultiLabels: int, multiLabels: openArray[IndexedMultiLabel]) =
  ## A broken source line, for labeling skipped sections of source.
  ##
  ## ```text
  ## · │ │
  ## ```
  renderer.outerGutter(outerPadding)
  renderer.borderLeftBreak()
  renderer.innerGutter(severity, numMultiLabels, multiLabels)
  renderer.write "\n"

func renderSnippetNote*(renderer: Renderer, outerPadding: int, message: string) =
  ## Additional notes.
  ##
  ## ```text
  ## = expected type `Int`
  ##      found type `String`
  ## ```
  for noteLineIndex, line in rustLines(message):
    renderer.outerGutter(outerPadding)
    if noteLineIndex == 0:
      renderer.setNoteBullet()
      renderer.write renderer.chars.noteBullet
      renderer.reset()
    else:
      renderer.write " "
    # Write line of message
    renderer.write " " & line & "\n"

# --------------------------------------------------------------------- views

type
  Line = ref object
    number: int
    range: Range
    singleLabels: seq[SingleLabel]
    multiLabels: seq[IndexedMultiLabel]
    mustRender: bool

  LabeledFile = ref object
    fileId: int
    start: int
    name: string
    location: Location
    numMultiLabels: int
    lines: Table[int, Line]   # upstream: a BTreeMap, read in the order of its keys
    maxLabelStyle: LabelStyle

func countDigits(n: int): int =
  ## Calculate the number of decimal digits in `n`.
  len($n)

func getOrInsertLine(file: LabeledFile, lineIndex: int, lineRange: Range, lineNumber: int): Line =
  if lineIndex notin file.lines:
    # `mustRender` has to be false by default so we know if it must be rendered by another condition already.
    file.lines[lineIndex] = Line(range: lineRange, number: lineNumber, mustRender: false)
  file.lines[lineIndex]

func binarySearchInsertion(labels: openArray[SingleLabel], start, stop: int): int =
  ## Where Rust's `binary_search_by` says a label with this range is or goes.
  ## With equal ranges it matters which of them is found, so this is the
  ## algorithm of the Rust standard library, step by step.
  var size = labels.len
  if size == 0: return 0
  var base = 0
  while size > 1:
    let half = size div 2
    let mid = base + half
    if cmp((labels[mid].range.start, labels[mid].range.stop), (start, stop)) <= 0: base = mid
    size -= half
  let order = cmp((labels[base].range.start, labels[base].range.stop), (start, stop))
  if order == 0: base
  elif order < 0: base + 1
  else: base

proc renderRich(diagnostic: Diagnostic, config: Config, files: SimpleFiles, renderer: Renderer) =
  ## Output a richly formatted diagnostic, with source code previews.
  var labeledFiles: seq[LabeledFile]
  # Keep track of the outer padding to use when rendering the
  # snippets of source code.
  var outerPadding = 0

  # Group labels by file
  for label in diagnostic.labels:
    let startLineIndex = files.lineIndex(label.fileId, label.range.start)
    let startLineNumber = files.lineNumber(label.fileId, startLineIndex)
    let startLineRange = files.lineRange(label.fileId, startLineIndex)
    let endLineIndex = files.lineIndex(label.fileId, label.range.stop)
    let endLineNumber = files.lineNumber(label.fileId, endLineIndex)
    let endLineRange = files.lineRange(label.fileId, endLineIndex)

    outerPadding = max(outerPadding, countDigits(startLineNumber))
    outerPadding = max(outerPadding, countDigits(endLineNumber))

    # NOTE: This could be made more efficient by using an associative
    # data structure like a hashmap or B-tree,  but we use a vector to
    # preserve the order that unique files appear in the list of labels.
    var labeledFile: LabeledFile = nil
    for candidate in labeledFiles:
      if label.fileId == candidate.fileId:
        labeledFile = candidate
        break
    if labeledFile != nil:
      # another diagnostic also referenced this file
      if labeledFile.maxLabelStyle > label.style or
          (labeledFile.maxLabelStyle == label.style and labeledFile.start > label.range.start):
        # this label has a higher style or has the same style but starts earlier
        labeledFile.start = label.range.start
        labeledFile.location = files.location(label.fileId, label.range.start)
        labeledFile.maxLabelStyle = label.style
    else:
      # no other diagnostic referenced this file yet
      labeledFile = LabeledFile(
        fileId: label.fileId,
        start: label.range.start,
        name: files.name(label.fileId),
        location: files.location(label.fileId, label.range.start),
        numMultiLabels: 0,
        maxLabelStyle: label.style,
      )
      labeledFiles.add labeledFile

    # insert context lines before label
    # start from 1 because 0 would be the start of the label itself
    for offset in 1 .. config.beforeLabelLines:
      # we are going from smallest to largest offset, so if
      # the offset can not be subtracted from the start we
      # reached the first line
      if startLineIndex - offset < 0: break
      let index = startLineIndex - offset
      try:
        let range = files.lineRange(label.fileId, index)
        let line = labeledFile.getOrInsertLine(index, range, startLineNumber - offset)
        line.mustRender = true
      except FilesError:
        break

    # insert context lines after label
    # start from 1 because 0 would be the end of the label itself
    for offset in 1 .. config.afterLabelLines:
      let index = endLineIndex + offset
      try:
        let range = files.lineRange(label.fileId, index)
        let line = labeledFile.getOrInsertLine(index, range, endLineNumber + offset)
        line.mustRender = true
      except FilesError:
        break

    if startLineIndex == endLineIndex:
      # Single line
      #
      # ```text
      # 2 │ (+ test "")
      #   │         ^^ expected `Int` but found `String`
      # ```
      let labelStart = label.range.start - startLineRange.start
      # Ensure that we print at least one caret, even when we
      # have a zero-length source range.
      let labelEnd = max(label.range.stop - startLineRange.start, labelStart + 1)

      let line = labeledFile.getOrInsertLine(startLineIndex, startLineRange, startLineNumber)

      # Ensure that the single line labels are lexicographically
      # sorted by the range of source code that they cover.
      # If the ranges are the same, order the labels in reverse
      # to how they were originally specified in the diagnostic.
      # This helps with printing in the renderer.
      let index = binarySearchInsertion(line.singleLabels, labelStart, labelEnd)

      line.singleLabels.insert((label.style, (labelStart, labelEnd), label.message), index)

      # If this line is not rendered, the SingleLabel is not visible.
      line.mustRender = true
    else:
      # Multiple lines
      #
      # ```text
      # 4 │   fizz₁ num = case (mod num 5) (mod num 3) of
      #   │ ╭─────────────^
      # 5 │ │     0 0 => "FizzBuzz"
      # 6 │ │     0 _ => "Fizz"
      # 7 │ │     _ 0 => "Buzz"
      # 8 │ │     _ _ => num
      #   │ ╰──────────────^ `case` clauses have incompatible types
      # ```

      let labelIndex = labeledFile.numMultiLabels
      labeledFile.numMultiLabels += 1

      # First labeled line
      let labelStart = label.range.start - startLineRange.start

      let startLine = labeledFile.getOrInsertLine(startLineIndex, startLineRange, startLineNumber)

      startLine.multiLabels.add (labelIndex, label.style, MultiLabel(kind: mlTop, start: labelStart))

      # The first line has to be rendered so the start of the label is visible.
      startLine.mustRender = true

      # Marked lines
      #
      # ```text
      # 5 │ │     0 0 => "FizzBuzz"
      # 6 │ │     0 _ => "Fizz"
      # 7 │ │     _ 0 => "Buzz"
      # ```
      for lineIndex in (startLineIndex + 1) ..< endLineIndex:
        let lineRange = files.lineRange(label.fileId, lineIndex)
        let lineNumber = files.lineNumber(label.fileId, lineIndex)

        outerPadding = max(outerPadding, countDigits(lineNumber))

        let line = labeledFile.getOrInsertLine(lineIndex, lineRange, lineNumber)

        line.multiLabels.add (labelIndex, label.style, MultiLabel(kind: mlLeft))

        # The line should be rendered to match the configuration of how much context to show.
        line.mustRender = line.mustRender or
          # Is this line part of the context after the start of the label?
          lineIndex - startLineIndex <= config.startContextLines or
          # Is this line part of the context before the end of the label?
          endLineIndex - lineIndex <= config.endContextLines

      # Last labeled line
      #
      # ```text
      # 8 │ │     _ _ => num
      #   │ ╰──────────────^ `case` clauses have incompatible types
      # ```
      let labelEnd = label.range.stop - endLineRange.start

      let endLine = labeledFile.getOrInsertLine(endLineIndex, endLineRange, endLineNumber)

      endLine.multiLabels.add (labelIndex, label.style,
                               MultiLabel(kind: mlBottom, start: labelEnd, message: label.message))

      # The last line has to be rendered so the end of the label is visible.
      endLine.mustRender = true

  # Header and message
  #
  # ```text
  # error[E0001]: unexpected type in `+` application
  # ```
  renderer.renderHeader(none(Locus), diagnostic.severity, diagnostic.code, diagnostic.message)

  # Source snippets
  #
  # ```text
  #   ┌─ test:2:9
  #   │
  # 2 │ (+ test "")
  #   │         ^^ expected `Int` but found `String`
  #   │
  # ```
  for fileIndex, labeledFile in labeledFiles:
    let source = files.source(labeledFile.fileId)

    # Top left border and locus.
    #
    # ```text
    # ┌─ test:2:9
    # ```
    if labeledFile.lines.len > 0:
      renderer.renderSnippetStart(outerPadding,
                                  Locus(name: labeledFile.name, location: labeledFile.location))
      renderer.renderSnippetEmpty(outerPadding, diagnostic.severity, labeledFile.numMultiLabels, [])

    var lineIndexes: seq[int]
    for lineIndex, line in labeledFile.lines:
      if line.mustRender: lineIndexes.add lineIndex
    lineIndexes.sort()

    for position, lineIndex in lineIndexes:
      let line = labeledFile.lines[lineIndex]
      renderer.renderSnippetSource(
        outerPadding,
        line.number,
        source[line.range.start ..< line.range.stop],
        diagnostic.severity,
        line.singleLabels,
        labeledFile.numMultiLabels,
        line.multiLabels,
      )

      # Check to see if we need to render any intermediate stuff
      # before rendering the next line.
      if position + 1 < lineIndexes.len:
        let nextLineIndex = lineIndexes[position + 1]
        let nextLine = labeledFile.lines[nextLineIndex]
        case nextLineIndex - lineIndex
        # Consecutive lines
        of 1: discard
        # One line between the current line and the next line
        of 2:
          # Write a source line
          let fileId = labeledFile.fileId

          # This line was not intended to be rendered initially.
          # To render the line right, we have to get back the original labels.
          let labels =
            if lineIndex + 1 in labeledFile.lines: labeledFile.lines[lineIndex + 1].multiLabels
            else: @[]

          let between = files.lineRange(fileId, lineIndex + 1)
          renderer.renderSnippetSource(
            outerPadding,
            files.lineNumber(fileId, lineIndex + 1),
            source[between.start ..< between.stop],
            diagnostic.severity,
            [],
            labeledFile.numMultiLabels,
            labels,
          )
        # More than one line between the current line and the next line.
        else:
          # Source break
          #
          # ```text
          # ·
          # ```
          renderer.renderSnippetBreak(outerPadding, diagnostic.severity,
                                      labeledFile.numMultiLabels, nextLine.multiLabels)

    # Check to see if we should render a trailing border after the
    # final line of the snippet.
    if fileIndex == labeledFiles.high and diagnostic.notes.len == 0:
      # We don't render a border if we are at the final newline
      # without trailing notes, because it would end up looking too
      # spaced-out in combination with the final new line.
      discard
    else:
      # Render the trailing snippet border.
      renderer.renderSnippetEmpty(outerPadding, diagnostic.severity, labeledFile.numMultiLabels, [])

  # Additional notes
  #
  # ```text
  # = expected type `Int`
  #      found type `String`
  # ```
  for note in diagnostic.notes:
    renderer.renderSnippetNote(outerPadding, note)
  renderer.renderEmpty()

proc renderShort(diagnostic: Diagnostic, showNotes: bool, files: SimpleFiles, renderer: Renderer) =
  ## Output a short diagnostic, with a line number, severity, and message.

  # Located headers
  #
  # ```text
  # test:2:9: error[E0001]: unexpected type in `+` application
  # ```
  var primaryLabelsEncountered = 0
  for label in diagnostic.labels:
    if label.style != LabelStyle.Primary: continue
    primaryLabelsEncountered += 1

    renderer.renderHeader(
      some(Locus(name: files.name(label.fileId), location: files.location(label.fileId, label.range.start))),
      diagnostic.severity, diagnostic.code, diagnostic.message)

  # Fallback to printing a non-located header if no primary labels were encountered
  #
  # ```text
  # error[E0002]: Bad config found
  # ```
  if primaryLabelsEncountered == 0:
    renderer.renderHeader(none(Locus), diagnostic.severity, diagnostic.code, diagnostic.message)

  if showNotes:
    # Additional notes
    #
    # ```text
    # = expected type `Int`
    #      found type `String`
    # ```
    for note in diagnostic.notes:
      renderer.renderSnippetNote(0, note)

# ---------------------------------------------------------------------- term

proc emitToWriteStyle*(writer: Buffer, config: Config, files: SimpleFiles, diagnostic: Diagnostic) =
  ## Emit a diagnostic using the given writer, context, config, and files.
  ## Raises `FilesError` where the crate returns an error.
  let renderer = newRenderer(writer, config)
  case config.displayStyle
  of DisplayStyle.Rich: renderRich(diagnostic, config, files, renderer)
  of DisplayStyle.Medium: renderShort(diagnostic, true, files, renderer)
  of DisplayStyle.Short: renderShort(diagnostic, false, files, renderer)
