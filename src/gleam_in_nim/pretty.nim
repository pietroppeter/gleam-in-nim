## port-of: pretty-arena/src/lib.rs
## port-status: conformant
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Gleam contributors
#
# Ported to Nim from the Gleam compiler, v1.19.2:
#   pretty-arena/src/lib.rs
# https://github.com/gleam-lang/gleam/blob/v1.19.2/pretty-arena/src/lib.rs

## This module implements the functionality described in
## "Strictly Pretty" (2000) by Christian Lindig, with a few extensions.
##
## This module is heavily influenced by Elixir's Inspect.Algebra and
## JavaScript's Prettier.
##
## Extensions
## ----------
##
## - `ForcedBreak` from Elixir.
## - `FlexBreak` from Elixir.
##
## The way this module works is fairly simple conceptually, however the actual
## behaviour in practice can be hard to wrap one's head around.
##
## The basic premise is the `Document` type, which is a tree structure,
## containing some text as well as information on how it can be formatted.
## Once the document is constructed, it can be printed using the
## `toPrettyString` proc.
##
## It will then traverse the tree, and construct a string, attempting to wrap
## lines to that they do not exceed the line length limit specified. Where and
## when it wraps lines is determined by the structure of the `Document` itself.
##
## Differences from upstream
## -------------------------
##
## Upstream allocates documents in an arena and threads the arena through
## every call. Nim's memory management does that job, so there is no arena
## here: `document.group(arena)` is `document.group`. Upstream also has two
## variants for each kind of string (borrowed and owned); Nim has one string
## type, so there is one variant. The printing algorithm is the same, line
## for line.

import std/[strutils]
import graphemes

type
  CursorPositionObserver* = ref object of RootObj
    ## An object that observes the cursor position as a document is being
    ## formatted. This is useful for any operations that need to track the
    ## exact position a document is being written to in a buffer such as for
    ## source mapping.

  BreakKind* = enum
    ## The kind of line break a `Break` document is.
    Flex   ## A `flexBreak`.
    Strict ## A `breakDoc`.

  Mode* = enum
    Broken
      ## The mode used when a group doesn't fit on a single line: when
      ## `Broken` the `Break`s inside it will be rendered as newlines,
      ## splitting the group.
    Unbroken
      ## The default mode used when a group can fit on a single line: all its
      ## `Break`s will be rendered as their unbroken string and kept on a
      ## single line.
    ForcedBroken
      ## This mode is used by the `NextBreakFits` document to force a break
      ## to be considered as broken.
    ForcedUnbroken
      ## This mode is used to disable a `NextBreakFits` document.

  NextBreakFitsMode* = enum
    ## A flag that can be used to enable or disable a `NextBreakFits`
    ## document.
    Enabled
    Disabled

  NestCondition* = enum
    ## A flag that can be used to conditionally disable a `Nest` document.
    Always
      ## This always applies the nesting. This is a sensible default that
      ## will work for most of the cases.
    IfBroken
      ## Only applies the nesting if the wrapping `Group` couldn't fit on a
      ## single line and has been broken.

  NestMode* = enum
    ## Used to change the way nesting of documents work.
    Increase
      ## The current indentation will be increased by the specified value.
    Set
      ## The current indentation is going to be set to exactly the specified
      ## value.
      ##
      ## `doc.nest(2).setNesting(0)`
      ## "wibble
      ## wobble    <- no indentation is added!
      ## wubble"

  DocumentKind* = enum
    dkLine, dkForceBroken, dkNextBreakFits, dkBreak, dkJoin, dkJoin3, dkJoin4,
    dkNest, dkGroup, dkStr, dkZeroWidthStr, dkCursorPositionObserver, dkEmpty

  Document* = ref object
    ## A pretty printable document. A tree structure, made up of text and
    ## other elements which determine how it can be formatted.
    ##
    ## Documents are never changed once built, so they can be shared freely.
    ## Build them with the procs of this module, not field by field.
    case kind*: DocumentKind
    of dkLine:
      ## A mandatory linebreak. This is always printed as a string of
      ## newlines, equal in length to the number specified.
      count*: int
    of dkForceBroken:
      ## Forces the breaks of the wrapped document to be considered as not
      ## fitting on a single line. Used in combination with a `Group` it can
      ## be used to force its `Break`s to always break.
      forced*: Document
    of dkNextBreakFits:
      ## Ignore the next break, forcing it to render as unbroken.
      fitting*: Document
      fitsMode*: NextBreakFitsMode
    of dkBreak:
      ## A document after which the formatter can insert a newline. This
      ## determines where line breaks can occur, outside of hardcoded
      ## `Line`s. See `breakDoc` and `flexBreak` for usage.
      broken*, unbroken*: string
      breakKind*: BreakKind
    of dkJoin, dkJoin3, dkJoin4:
      ## Join multiple documents together. The documents are not separated
      ## in any way: the formatter will only print newlines if a `Break` or a
      ## `Line` is used.
      first*, second*, third*, fourth*: Document
    of dkNest:
      ## Nests the given document by the given indent, depending on the
      ## specified condition. See `nest`, `setNesting` and `nestIfBroken`.
      indent*: int
      nestMode*: NestMode
      condition*: NestCondition
      nested*: Document
    of dkGroup:
      ## Groups a document. When pretty printing a group, the formatter will
      ## first attempt to fit the entire group on one line. If it fails, all
      ## `breakDoc` documents in the group will render broken.
      ##
      ## Nested groups are handled separately to their parents, so if the
      ## outermost group is broken, any sub-groups might be rendered broken
      ## or unbroken, depending on whether they fit on a single line.
      grouped*: Document
    of dkStr:
      ## Renders a string. This will always render the string verbatim,
      ## without any line breaks or other modifications to it.
      string*: string
      ## The number of extended grapheme clusters in the string.
      ## This is what the pretty printer uses as the width of the string as
      ## it is closest to what a human would consider the "length" of a
      ## string. It is precomputed to avoid walking the string over and over
      ## again in the pretty printing algorithm.
      graphemes*: int
    of dkZeroWidthStr:
      ## A string that is not taken into account when determining line
      ## length. This is useful for additional formatting text which won't
      ## be rendered in the final output, such as ANSI codes or HTML
      ## elements.
      zeroWidth*: string
    of dkCursorPositionObserver:
      ## A node that gets notified of the cursor position as it is being
      ## formatted. This allows for processes outside of the final output to
      ## be notified of the cursor position and perform actions based on it,
      ## such as recording the span of the node in the generated source code
      ## for a source mapping.
      observer*: CursorPositionObserver
    of dkEmpty:
      discard

  Frame* = ref object
    ## One entry of the work list of the printer: a document together with
    ## the indentation and mode it has to be printed with, and the rest of
    ## the list.
    ##
    ## Upstream keeps the work list in a persistent vector that it only ever
    ## pushes to and pops from at the front, and that it clones when it needs
    ## to look ahead. An immutable linked list does the same with nothing to
    ## clone: looking ahead is walking the list without moving its owner.
    indent*: int
    mode*: Mode
    document*: Document
    next*: Frame

method observeCursorPosition*(observer: CursorPositionObserver, line, width: int) {.base.} =
  discard

# Constructors ---------------------------------------------------------------

let emptyDocument* = Document(kind: dkEmpty)
  ## The empty document that renders as nothing.

proc constStr*(string: string, graphemes: int): Document =
  ## A string document with a width given by hand. Only for the constants at
  ## the end of this module, which keep the widths upstream declares.
  Document(kind: dkStr, string: string, graphemes: graphemes)

proc graphemeWidth(string: string): int =
  ## The number of extended grapheme clusters in the string.
  for character in string:
    # A carriage return can join with a following line feed into one
    # grapheme, and bytes over 127 are parts of longer characters: both need
    # the real segmentation algorithm. Everything else is one byte, one
    # grapheme, which is by far the common case.
    if character >= '\x80' or character == '\r':
      return graphemesCount(string)
  string.len

proc toDoc*(document: Document): Document {.inline.} = document

proc toDoc*(string: string): Document =
  Document(kind: dkStr, string: string, graphemes: graphemeWidth(string))

proc toDoc*(character: char): Document = toDoc($character)

proc toDoc*(number: SomeInteger): Document = toDoc($number)

proc lines*(count: int): Document =
  ## Renders a string of newlines, equal in length to the number provided.
  Document(kind: dkLine, count: count)

proc line*(): Document =
  ## A document that is rendered as a single line break.
  lines(1)

proc positionObserver*(observer: CursorPositionObserver): Document =
  Document(kind: dkCursorPositionObserver, observer: observer)

proc breakDoc*(broken, unbroken: string): Document =
  ## A document after which the formatter can insert a newline. This
  ## determines where line breaks can occur, outside of hardcoded `Line`s.
  ##
  ## If the formatter determines that a group cannot fit on a single line,
  ## all breaks in the group will be rendered as broken. Otherwise, they will
  ## be rendered as unbroken.
  ##
  ## A broken `Break` renders the `broken` string, followed by a newline.
  ## An unbroken `Break` renders the `unbroken` string by itself.
  ##
  ## Upstream calls this `break_`; `break` is a keyword in Nim too.
  runnableExamples:
    let document = docvec("Hello", breakDoc("", ", "), "world!").group
    assert document.toPrettyString(20) == "Hello, world!"
    assert document.toPrettyString(10) == "Hello\nworld!"
  Document(kind: dkBreak, broken: broken, unbroken: unbroken, breakKind: Strict)

proc flexBreak*(broken, unbroken: string): Document =
  ## A document after which the formatter can insert a newline, similar to
  ## `breakDoc`. The difference is that when a group is rendered broken, all
  ## breaks are rendered broken. However, `flexBreak` decides whether to
  ## break or not for every individual `flexBreak`.
  runnableExamples:
    let withBreaks = docvec("Hello", breakDoc("", ", "), "pretty",
      breakDoc("", ", "), "printed!").group
    assert withBreaks.toPrettyString(20) == "Hello\npretty\nprinted!"
    let withFlexBreaks = docvec("Hello", flexBreak("", ", "), "pretty",
      flexBreak("", ", "), "printed!").group
    assert withFlexBreaks.toPrettyString(20) == "Hello, pretty\nprinted!"
  Document(kind: dkBreak, broken: broken, unbroken: unbroken, breakKind: Flex)

proc zeroWidthStr*(string: string): Document =
  ## A string that is not taken into account when determining line length.
  ## This is useful for additional formatting text which won't be rendered in
  ## the final output, such as ANSI codes or HTML elements.
  runnableExamples:
    let document = docvec("Hello", zeroWidthStr("This is a very long string"),
      breakDoc("", ""), "world")
    assert document.toPrettyString(20) == "HelloThis is a very long stringworld"
  Document(kind: dkZeroWidthStr, zeroWidth: string)

proc join3*(first, second, third: Document): Document =
  ## Joins exactly three documents into one.
  ## This is a little optimisation over joining three documents using
  ## `append`.
  Document(kind: dkJoin3, first: first, second: second, third: third)

proc join4*(first, second, third, fourth: Document): Document =
  ## Joins exactly four documents into one.
  Document(kind: dkJoin4, first: first, second: second, third: third, fourth: fourth)

# Operations on documents ----------------------------------------------------

proc group*(document: Document): Document =
  ## Groups a document. When pretty printing a group, the formatter will
  ## first attempt to fit the entire group on one line. If it fails, all
  ## `breakDoc` documents in the group will render broken.
  ##
  ## Nested groups are handled separately to their parents, so if the
  ## outermost group is broken, any sub-groups might be rendered broken or
  ## unbroken, depending on whether they fit on a single line.
  case document.kind
  # Grouping a group doesn't change how it will be formatted so we can avoid
  # wrapping it. Same for an empty document. Grouping a literal string will
  # never change how it's formatted either.
  of dkGroup, dkEmpty, dkStr, dkZeroWidthStr, dkCursorPositionObserver:
    document
  of dkLine, dkForceBroken, dkNextBreakFits, dkBreak, dkJoin, dkJoin3, dkJoin4, dkNest:
    Document(kind: dkGroup, grouped: document)

proc setNesting*(document: Document, indent: int): Document =
  ## Sets the indentation level of a document.
  Document(kind: dkNest, indent: indent, nestMode: Set, condition: Always, nested: document)

proc nest*(document: Document, indent: int): Document =
  ## Nests a document by a certain indentation. When rending linebreaks, the
  ## formatter will print a new line followed by the current indentation.
  Document(kind: dkNest, indent: indent, nestMode: Increase, condition: Always, nested: document)

proc nestIfBroken*(document: Document, indent: int): Document =
  ## Nests a document by a certain indentation, but only if the current group
  ## is broken.
  Document(kind: dkNest, indent: indent, nestMode: Increase, condition: IfBroken, nested: document)

proc forceBreak*(document: Document): Document =
  ## Forces all `breakDoc` and `flexBreak` documents in the current group to
  ## render broken.
  Document(kind: dkForceBroken, forced: document)

proc nextBreakFits*(document: Document, mode: NextBreakFitsMode): Document =
  ## Force the next `Break` to render unbroken, regardless of whether it fits
  ## on the line or not.
  Document(kind: dkNextBreakFits, fitting: document, fitsMode: mode)

proc append*(document, new: Document): Document =
  ## Appends one document to another. Equivalent to `docvec(document, new)`,
  ## except that if `document` is already a join of two or three documents it
  ## will grow that join instead of nesting it in a new one.
  ##
  ## Useful when chaining multiple documents together in a fashion where they
  ## cannot be put all into one `docvec`.
  if new.kind == dkEmpty:
    return document
  case document.kind
  of dkEmpty:
    new
  of dkJoin:
    Document(kind: dkJoin3, first: document.first, second: document.second, third: new)
  of dkJoin3:
    Document(kind: dkJoin4, first: document.first, second: document.second,
      third: document.third, fourth: new)
  of dkLine, dkJoin4, dkForceBroken, dkNextBreakFits, dkBreak, dkNest, dkGroup, dkStr,
      dkZeroWidthStr, dkCursorPositionObserver:
    Document(kind: dkJoin, first: document, second: new)

proc append*(document: Document, new: string | char | SomeInteger): Document =
  document.append(toDoc(new))

proc docvec*(documents: varargs[Document, toDoc]): Document =
  ## Join multiple documents together. Every argument is turned into a
  ## document with `toDoc`, so strings and numbers can be passed as they are.
  ##
  ## Note: the documents are not separated in any way: the formatter will
  ## never break a line unless a `Break` or a `Line` is used. Therefore,
  ## `docvec("a", "b", "c")` prints the same as `"abc".toDoc`.
  runnableExamples:
    assert docvec("Hello", line(), "world!").toPrettyString(80) == "Hello\nworld!"
  case documents.len
  of 0: emptyDocument
  # When we're joining exactly 3 or 4 documents we use the specialised
  # `join3` and `join4` to be a bit faster!
  of 3: join3(documents[0], documents[1], documents[2])
  of 4: join4(documents[0], documents[1], documents[2], documents[3])
  # Otherwise we just append all the documents together.
  else:
    var document = documents[0]
    for index in 1 ..< documents.len:
      document = document.append(documents[index])
    document

proc surround*(document: Document, open, closed: Document | string): Document =
  ## Surrounds a document in two delimiters. Equivalent to
  ## `docvec(open, document, closed)`.
  toDoc(open).append(document).append(toDoc(closed))

proc concat*(documents: openArray[Document]): Document =
  ## Joins together a sequence of documents into a single document.
  ## All the documents are gonna be rendered next to each other with no
  ## spaces in between.
  if documents.len == 0:
    return emptyDocument
  var
    previous = documents[0]
    index = 1
  while index < documents.len:
    let second = documents[index]
    inc index
    if index < documents.len:
      let third = documents[index]
      inc index
      if index < documents.len:
        let fourth = documents[index]
        inc index
        previous = docvec(previous, second, third, fourth)
      else:
        previous = docvec(previous, second, third)
    else:
      previous = previous.append(second)
  previous

proc join*(elements: openArray[Document], separator: Document): Document =
  ## Joins a sequence into a single document, interspersing each element with
  ## another document. This is useful for example in argument lists, where a
  ## list of arguments must all be separated with a comma.
  if elements.len == 0:
    return emptyDocument
  var previous = elements[0]
  for index in 1 ..< elements.len:
    previous = docvec(previous, separator, elements[index])
  previous

proc isEmpty*(document: Document): bool =
  ## Returns true when the document contains no printable characters
  ## (whitespace and newlines are considered printable characters).
  case document.kind
  of dkEmpty: true
  of dkLine: document.count == 0
  of dkStr: document.string.len == 0
  # assuming `broken` and `unbroken` are equivalent
  of dkBreak: document.broken.len == 0
  of dkForceBroken: document.forced.isEmpty
  of dkNest: document.nested.isEmpty
  of dkGroup: document.grouped.isEmpty
  of dkNextBreakFits: document.fitting.isEmpty
  of dkJoin: document.first.isEmpty and document.second.isEmpty
  of dkJoin3: document.first.isEmpty and document.second.isEmpty and document.third.isEmpty
  of dkJoin4:
    document.first.isEmpty and document.second.isEmpty and document.third.isEmpty and
      document.fourth.isEmpty
  # Zero-width strings don't count towards line length, but they are still
  # printed and so are not empty. (Unless their string contents is also
  # empty)
  of dkZeroWidthStr: document.zeroWidth.len == 0
  of dkCursorPositionObserver: true

# The printer ----------------------------------------------------------------

proc push(docs: var Frame, indent: int, mode: Mode, document: Document) {.inline.} =
  docs = Frame(indent: indent, mode: mode, document: document, next: docs)

proc fits*(limit: int, currentWidth: int, docs: Frame): bool =
  ## Can the documents of the work list `docs` be printed on what is left of
  ## the current line? Exported for the tests; not meant to be called from
  ## other modules.
  var
    currentWidth = currentWidth
    docs = docs
  # The `fits` proc is going to take each document from the `docs` list and
  # check if those can fit on a single line. In order to do so documents are
  # going to be pushed in front of this list and have to be accompanied by
  # additional information:
  # - the document indentation, that can be increased by the `Nest` block.
  # - the current mode; this is needed to know if a group is being broken or
  #   not and treat `Break`s differently as a consequence. You can see how
  #   the behaviour changes in [ref:break-fit].
  #
  # The loop might be broken earlier without checking all documents under one
  # of two conditions:
  # - the documents exceed the line `limit` and surely won't fit
  #   [ref:document-unfit].
  # - the documents are sure to fit the line - for example, if we meet a
  #   broken `Break` [ref:break-fit] or a newline [ref:newline-fit].
  while true:
    # [tag:document-unfit] If we've exceeded the maximum width allowed for a
    # line, it means that the document won't fit on a single line, we can
    # break the loop.
    if currentWidth > limit:
      return false

    # We start by checking the first document of the list. If there's no
    # documents then we can safely say that it fits (if reached this point it
    # means that the limit wasn't exceeded).
    if docs.isNil:
      return true
    let
      indent = docs.indent
      mode = docs.mode
      document = docs.document
    docs = docs.next

    case document.kind
    # If a document is marked as `ForceBroken` we can immediately say that it
    # doesn't fit, so that every break is going to be forcefully broken.
    of dkForceBroken:
      case mode
      # If the mode is `ForcedBroken` it means that we have to ignore this
      # break [ref:forced-broken], so we go check the inner document ignoring
      # the effects of this one.
      of ForcedBroken: docs.push(indent, mode, document.forced)
      of Broken, Unbroken, ForcedUnbroken: return false

    # [tag:newline-fit] When we run into a line we know that the document has
    # a bit that fits in the current line; if it didn't fit (that is, it
    # exceeded the maximum allowed width) the loop would have been broken by
    # one of the earlier checks.
    of dkLine:
      return true

    # If the nesting level is increased we go on checking the wrapped
    # document and increase its indentation level based on the nesting
    # condition.
    of dkNest:
      case document.condition
      of IfBroken: docs.push(indent, mode, document.nested)
      of Always:
        let newIndent =
          case document.nestMode
          of Increase: indent + document.indent
          of Set: document.indent
        docs.push(newIndent, mode, document.nested)

    # As a general rule, a group fits if it can stay on a single line without
    # its breaks being broken down.
    of dkGroup:
      case mode
      # If an outer group was broken, we still try to fit the inner group on
      # a single line, that's why for the inner document we change the mode
      # back to `Unbroken`.
      of Broken: docs.push(indent, Unbroken, document.grouped)
      # Any other mode is preserved as-is: if the mode is forced it has to be
      # left unchanged, and if the mode is already unbroken there's no need
      # to change it.
      of Unbroken, ForcedBroken, ForcedUnbroken: docs.push(indent, mode, document.grouped)

    # When we run into a string we increase the current width; looping back
    # we will check if we've exceeded the maximum allowed width.
    of dkStr:
      currentWidth += document.graphemes

    # Zero width strings do nothing: they do not contribute to line length
    of dkZeroWidthStr, dkCursorPositionObserver:
      discard

    # If we get to a break we need to first see if it has to be rendered as
    # its unbroken or broken string, depending on the mode.
    of dkBreak:
      case mode
      # [tag:break-fit] If the break has to be broken we're done!
      # We haven't exceeded the maximum length (otherwise the loop iteration
      # would have stopped with one of the earlier checks), and - since it
      # needs to be broken - we'll have to go on a new line anyway.
      # This means that the document inspected so far will fit on a single
      # line, thus we return true.
      of Broken, ForcedBroken: return true
      # If the break is not broken then it will be rendered inline as its
      # unbroken string, so we treat it exactly as if it were a normal
      # string.
      of Unbroken, ForcedUnbroken: currentWidth += document.unbroken.len

    # The `NextBreakFits` can alter the current mode to `ForcedBroken` or
    # `ForcedUnbroken` based on its enabled flag.
    of dkNextBreakFits:
      case document.fitsMode
      # [tag:disable-next-break] If it is disabled then we check the wrapped
      # document changing the mode to `ForcedUnbroken`.
      of Disabled: docs.push(indent, ForcedUnbroken, document.fitting)
      of Enabled:
        case mode
        # If we're in `ForcedUnbroken` mode it means that the check was
        # disabled by a document wrapping this one [ref:disable-next-break];
        # that's why we do nothing and check the wrapped document as if it
        # were a normal one.
        of ForcedUnbroken: docs.push(indent, mode, document.fitting)
        # [tag:forced-broken] Any other mode is turned into `ForcedBroken` so
        # that when we run into a break, the response to the question "Does
        # the document fit?" will be yes [ref:break-fit].
        # This is why this is called `NextBreakFit` I think.
        of Broken, Unbroken, ForcedBroken: docs.push(indent, ForcedBroken, document.fitting)

    # If there's a sequence of documents we will check each one, one after
    # the other to see if - as a whole - they can fit on a single line.
    of dkJoin:
      # The documents need to be pushed in reverse to preserve their order,
      # since each one is pushed _to the front_ of the list of documents to
      # check.
      docs.push(indent, mode, document.second)
      docs.push(indent, mode, document.first)
    of dkJoin3:
      docs.push(indent, mode, document.third)
      docs.push(indent, mode, document.second)
      docs.push(indent, mode, document.first)
    of dkJoin4:
      docs.push(indent, mode, document.fourth)
      docs.push(indent, mode, document.third)
      docs.push(indent, mode, document.second)
      docs.push(indent, mode, document.first)

    of dkEmpty:
      discard

proc format(writer: var string, limit: int, docs: Frame) =
  var
    docs = docs
    line = 0
    width = 0

  template newlineAndIndent(indent: int) =
    writer.add '\n'
    inc line
    writer.add spaces(max(indent, 0))
    width = indent

  # As long as there are documents to print we'll take each one by one and
  # output the corresponding string to the given writer.
  #
  # Each document in the `docs` list also has an accompanying indentation and
  # mode:
  # - the indentation is used to keep track of the current indentation, you
  #   might notice in [ref:format-nest] that it adds documents to the list
  #   increasing their current indentation.
  # - the mode is used to keep track of the state of the documents inside a
  #   group. For example, if a group doesn't fit on a single line its
  #   documents will be split into multiple lines and the mode set to
  #   `Broken` to keep track of this.
  while not docs.isNil:
    let
      indent = docs.indent
      mode = docs.mode
      document = docs.document
    docs = docs.next

    case document.kind
    # When we run into a line we print the given number of newlines and add
    # the indentation required by the given document.
    of dkLine:
      writer.add repeat('\n', document.count)
      line += document.count
      writer.add spaces(max(indent, 0))
      width = indent

    of dkBreak:
      case document.breakKind
      # Flex breaks are NOT conditional to the mode: if the mode is already
      # `Unbroken`, then the break is left unbroken (like strict breaks); any
      # other mode is ignored.
      # A flexible break will only be split if the following documents can't
      # fit on the same line; otherwise, it is just displayed as an unbroken
      # `Break`.
      of Flex:
        let unbrokenWidth = width + document.unbroken.len
        # Every time we need to check again if the remaining piece can fit.
        # If it does, the flexible break is not broken.
        if mode == Unbroken or fits(limit, unbrokenWidth, docs):
          writer.add document.unbroken
          width = unbrokenWidth
        else:
          writer.add document.broken
          newlineAndIndent(indent)

      # Strict breaks are conditional to the mode. They differ from flexible
      # break because, if a group gets split - that is the mode is `Broken`
      # or `ForcedBroken` - ALL of the breaks in that group will be split.
      # You can notice the difference with flexible breaks because here we
      # only check the mode and then take action; before we would try and see
      # if the remaining documents fit on a single line before deciding if
      # the (flexible) break can be split or not.
      of Strict:
        case mode
        # If the mode requires the break to be broken, then its broken string
        # is printed, then we start a newline and indent it according to the
        # current indentation level.
        of Broken, ForcedBroken:
          writer.add document.broken
          newlineAndIndent(indent)
        # If the mode doesn't require the break to be broken, then its
        # unbroken string is printed as if it were a normal string; also
        # updating the width of the current line.
        of Unbroken, ForcedUnbroken:
          writer.add document.unbroken
          width += document.unbroken.len

    # Strings are printed as they are and the current width is increased
    # accordingly.
    of dkStr:
      width += document.graphemes
      writer.add document.string

    of dkZeroWidthStr:
      # We write the string, but do not increment the length
      writer.add document.zeroWidth

    # If multiple documents need to be printed, then they are all pushed to
    # the front of the list and will be printed one by one.
    of dkJoin:
      # Just like `fits`, the elements will be pushed _on the front_ of the
      # list. In order to keep their original order they need to be pushed in
      # reverse order.
      docs.push(indent, mode, document.second)
      docs.push(indent, mode, document.first)
    of dkJoin3:
      docs.push(indent, mode, document.third)
      docs.push(indent, mode, document.second)
      docs.push(indent, mode, document.first)
    of dkJoin4:
      docs.push(indent, mode, document.fourth)
      docs.push(indent, mode, document.third)
      docs.push(indent, mode, document.second)
      docs.push(indent, mode, document.first)

    # A `Nest` document doesn't result in anything being printed, its only
    # effect is to increase the current nesting level for the wrapped
    # document [tag:format-nest].
    of dkNest:
      # The nesting is only applied under two conditions:
      # - either the nesting condition is `Always`.
      # - or the condition is `IfBroken` and the group was actually broken
      #   (that is, the current mode is `Broken`).
      if document.condition == Always or mode == Broken:
        let newIndent =
          case document.nestMode
          of Increase: indent + document.indent
          of Set: document.indent
        docs.push(newIndent, mode, document.nested)
      # If none of the above conditions is met, then the nesting is not
      # applied.
      else:
        docs.push(indent, mode, document.nested)

    of dkGroup:
      # When we see a group we first try and see if it can fit on a single
      # line without breaking any break; that is why we use the `Unbroken`
      # mode here: we want to try to fit everything on a single line.
      let groupDocs = Frame(indent: indent, mode: Unbroken, document: document.grouped)
      if fits(limit, width, groupDocs):
        # If everything can stay on a single line we print the wrapped
        # document with the `Unbroken` mode, leaving all the group's break as
        # unbroken.
        docs.push(indent, Unbroken, document.grouped)
      else:
        # Otherwise, we need to break the group. We print the wrapped
        # document changing its mode to `Broken` so that all its breaks will
        # be split on newlines.
        docs.push(indent, Broken, document.grouped)

    # `ForceBroken` and `NextBreakFits` only change the way the `fits` proc
    # works but do not actually change the formatting of a document by
    # themselves. That's why when we run into those we just go on printing
    # the wrapped document without altering the current mode.
    of dkForceBroken:
      docs.push(indent, mode, document.forced)
    of dkNextBreakFits:
      docs.push(indent, mode, document.fitting)

    of dkCursorPositionObserver:
      # Notify the observer of the current cursor position
      document.observer.observeCursorPosition(line, width)

    of dkEmpty:
      discard

proc prettyPrint*(document: Document, limit: int, writer: var string) =
  ## Prints a document into `writer`, attempting to limit lines to `limit`
  ## characters in length.
  format(writer, limit, Frame(indent: 0, mode: Unbroken, document: document))

proc toPrettyString*(document: Document, limit: int): string =
  ## Prints a document into a string, attempting to limit lines to `limit`
  ## characters in length.
  document.prettyPrint(limit, result)

# Constants ------------------------------------------------------------------
#
# Documents for the pieces of text the formatter and the code generators print
# again and again. They are generated from upstream's list, name for name
# (`SPACE_DOCUMENT` is `spaceDocument`), and number for number: a handful of
# upstream's widths are not the length of their string (`"const "` counts as
# 5, `"if "` as 2). The printer decides where to break lines from these
# widths, so to print what upstream prints we keep them as they are.

let
  lineDocument* = lines(1)
  twoLinesDocument* = lines(2)
  flexCommaDocument* = flexBreak(",", ", ")
  spaceDocument* = constStr(" ", 1)
  moduleCommentDocument* = constStr("////", 4)
  docCommentDocument* = constStr("///", 3)
  constSpaceDocument* = constStr("const ", 5)
  opaqueTypeSpaceDocument* = constStr("opaque type ", 12)
  typeSpaceDocument* = constStr("type ", 5)
  importSpaceDocument* = constStr("import ", 7)
  spaceAsSpaceDocument* = constStr(" as ", 4)
  spaceEqualSpaceDocument* = constStr(" = ", 3)
  todoDocument* = constStr("todo", 4)
  concatDocument* = constStr("<>", 2)
  dotDocument* = constStr(".", 1)
  dotDotDocument* = constStr("..", 2)
  colonSpaceDocument* = constStr(": ", 2)
  openCurlyDocument* = constStr("{", 1)
  closeCurlyDocument* = constStr("}", 1)
  openSquareDocument* = constStr("[", 1)
  closeSquareDocument* = constStr("]", 1)
  openCloseSquareDocument* = constStr("[]", 2)
  commentDocument* = constStr("//", 2)
  echoSpaceDocument* = constStr("echo ", 5)
  asDocument* = constStr("as", 2)
  spaceAsDocument* = constStr(" as", 2)
  openParenDocument* = constStr("(", 1)
  closeParenDocument* = constStr(")", 1)
  openCloseParenDocument* = constStr("()", 2)
  useDocument* = constStr("use", 3)
  useAndArrowDocument* = constStr("use <-", 6)
  leftArrowDocument* = constStr("<-", 2)
  minusSpaceDocument* = constStr("- ", 2)
  exclamationMarkDocument* = constStr("!", 1)
  assertSpaceDocument* = constStr("assert ", 7)
  pipeSpaceDocument* = constStr("|> ", 3)
  colonDocument* = constStr(":", 1)
  hashtagDocument* = constStr("#", 1)
  spaceOpenCurlyDocument* = constStr(" {", 2)
  emptyTupleDocument* = constStr("#()", 3)
  openTupleDocument* = constStr("#(", 2)
  fnDocument* = constStr("fn", 2)
  fnSpaceDocument* = constStr("fn ", 3)
  panicDocument* = constStr("panic", 5)
  ifSpaceDocument* = constStr("if ", 2)
  spaceRightArrowDocument* = constStr(" ->", 3)
  spaceRightArrowSpaceDocument* = constStr(" -> ", 4)
  letSpaceDocument* = constStr("let ", 4)
  letAssertSpaceDocument* = constStr("let assert ", 11)
  spaceEqualDocument* = constStr(" =", 2)
  underscoreDocument* = constStr("_", 1)
  doubleQuoteDocument* = constStr("\"", 1)
  openParenDotDotCloseParenDocument* = constStr("(..)", 4)
  verticalBarSpaceDocument* = constStr("| ", 2)
  spaceConcatSpaceDocument* = constStr(" <> ", 4)
  spacePlusSpaceDocument* = constStr(" + ", 3)
  spaceMinusSpaceDocument* = constStr(" - ", 3)
  spaceTimesSpaceDocument* = constStr(" * ", 3)
  spaceModuleSpaceDocument* = constStr(" % ", 3)
  spaceSlashSpaceDocument* = constStr(" / ", 3)
  spaceCloseCurlyDocument* = constStr(" }", 2)
  openCurlySpaceDocument* = constStr("{ ", 2)
  closeBitArrayDocument* = constStr(">>", 2)
  echoDocument* = constStr("echo", 4)
  emptyBitArrayDocument* = constStr("<<>>", 4)
  openBitArrayDocument* = constStr("<<", 2)
  rightArrowDocument* = constStr("->", 2)
  pubSpaceDocument* = constStr("pub ", 4)
  sizeDocument* = constStr("size", 4)
  bytesDocument* = constStr("bytes", 5)
  bitsDocument* = constStr("bits", 4)
  intDocument* = constStr("int", 3)
  floatDocument* = constStr("float", 5)
  utf8Document* = constStr("utf8", 4)
  utf16Document* = constStr("utf16", 5)
  utf32Document* = constStr("utf32", 5)
  utf8CodepointDocument* = constStr("utf8_codepoint", 14)
  utf16CodepointDocument* = constStr("utf16_codepoint", 15)
  utf32CodepointDocument* = constStr("utf32_codepoint", 15)
  signedDocument* = constStr("signed", 6)
  unsignedDocument* = constStr("unsigned", 8)
  bigDocument* = constStr("big", 3)
  littleDocument* = constStr("little", 6)
  nativeDocument* = constStr("native", 6)
  unitDocument* = constStr("unit", 4)
  andDocument* = constStr("&&", 2)
  orDocument* = constStr("||", 2)
  ltIntDocument* = constStr("<", 1)
  ltEqIntDocument* = constStr("<=", 2)
  ltFloatDocument* = constStr("<.", 2)
  ltEqFloatDocument* = constStr("<=.", 3)
  eqDocument* = constStr("==", 2)
  notEqDocument* = constStr("!=", 2)
  gtEqIntDocument* = constStr(">=", 2)
  gtIntDocument* = constStr(">", 1)
  gtEqFloatDocument* = constStr(">=.", 3)
  gtFloatDocument* = constStr(">.", 2)
  addIntDocument* = constStr("+", 1)
  addFloatDocument* = constStr("+.", 2)
  subIntDocument* = constStr("-", 1)
  subFloatDocument* = constStr("-.", 2)
  multIntDocument* = constStr("*", 1)
  multFloatDocument* = constStr("*.", 2)
  divIntDocument* = constStr("/", 1)
  divFloatDocument* = constStr("/.", 2)
  remainderIntDocument* = constStr("%", 1)
  deprecatedAttributeQuoteDocument* = constStr("@deprecated(\"", 13)
  quoteCloseParenDocument* = constStr("\")", 2)
  externalErlangQuoteDocument* = constStr("@external(erlang, \"", 19)
  externalJavascriptQuoteDocument* = constStr("@external(javascript, \"", 23)
  quoteCommaSpaceQuoteDocument* = constStr("\", \"", 4)
  internalAttributeDocument* = constStr("@internal", 9)
  internalAttributeSpaceDocument* = constStr("@internal ", 9)
  trueLowercaseDocument* = constStr("true", 4)
  falseLowercaseDocument* = constStr("false", 5)
  openCloseCurlyDocument* = constStr("{}", 2)
  spaceTimesAtIgnoreDocument* = constStr(" * @ignore", 10)
  slashTimesTimesDocument* = constStr("/**", 3)
  spaceTimesSlashDocument* = constStr(" */", 3)
  constFilepathEqualsDocument* = constStr("const FILEPATH = ", 17)
  semicolonDocument* = constStr(";", 1)
  functionSpaceDocument* = constStr("function ", 9)
  exportFunctionSpaceDocument* = constStr("export function ", 16)
  exportConstSpaceDocument* = constStr("export const ", 13)
  superCallSemicolonDocument* = constStr("super();", 8)
  constructorOpenParenDocument* = constStr("constructor(", 12)
  closeParenSpaceOpenCurlyDocument* = constStr(") {", 3)
  thisDotDocument* = constStr("this.", 5)
  thisOpenSquareDocument* = constStr("this[", 5)
  closeSquareSpaceEqualSpaceDocument* = constStr("] = ", 4)
  spaceExtendsCustomTypeOpenCurlyDocument* = constStr(" extends $CustomType {", 22)
  classSpaceDocument* = constStr("class ", 6)
  exportClassSpaceDocument* = constStr("export class ", 13)
  valueDotDocument* = constStr("value.", 6)
  spaceEqualSpaceValueSpaceArrow* = constStr(" = (value) =>", 13)
  spaceEqualOpenCloseParenSpaceArrowDocument* = constStr(" = () =>", 8)
  closeParenSemicolonDocument* = constStr(");", 2)
  newSpaceDocument* = constStr("new ", 4)
  valueOpenSquareDocument* = constStr("value[", 6)
  closeSquareSemicolonDocument* = constStr("];", 2)
  dollarIsDocument* = constStr("$is", 3)
  valueInstanceOfSpaceDocument* = constStr("value instanceof ", 17)
  dollarDocument* = constStr("$", 1)
  closeParenArrowDocument* = constStr(") =>", 4)
  closeParenSlimArrowDocument* = constStr(") ->", 4)
  spaceEqualSpaceOpenParenDocument* = constStr(" = (", 4)
  dollarConstSemicolonDocument* = constStr("$const;", 7)
  dollarConstDocument* = constStr("$const", 6)
  openCloseParenSemicolonDocument* = constStr("();", 3)
  exportSpaceOpenCloseCurlyDocument* = constStr("export {}", 9)
  exportSpaceOpenCurlyDocument* = constStr("export {", 8)
  exportTypeSpaceOpenCurlyDocument* = constStr("export type {", 13)
  dotMjsDotMapDocument* = constStr(".mjs.map", 8)
  dotDDotMtsCloseQuoteCloseTagDocument* = constStr(".d.mts\" />", 10)
  sourceMappingUrlEqualDocument* = constStr("//# sourceMappingURL=", 21)
  referenceTypesDocument* = constStr("/// <reference types=\"./", 24)
  closeCurlySemicolonDocument* = constStr("};", 2)
  timesSpaceAsSpaceDocument* = constStr("* as ", 5)
  spaceFromSpaceDoubleQuoteDocument* = constStr(" from \"", 7)
  doubleQuoteSemicolonDocument* = constStr("\";", 2)
  closeCurlySpaceFromSpaceDoubleQuoteDocument* = constStr("} from \"", 8)
  exportTypeSpaceDocument* = constStr("export type ", 12)
  xDocument* = constStr("x", 1)
  anyDocument* = constStr("any", 3)
  exportSpaceDocument* = constStr("export ", 7)
  declareSpaceDocument* = constStr("declare ", 8)
  spaceExtendsUnderscoreCustomTypeDocument* = constStr(" extends _.CustomType {", 23)
  constructorDocument* = constStr("constructor", 11)
  deprecatedMultilineCommentDocument* = constStr("/** @deprecated */", 18)
  closeParenColonSpaceDocument* = constStr("): ", 3)
  valueColonSpace* = constStr("value: ", 7)
  valueColonSpaceAnyDocument* = constStr("value: any", 10)
  closeParenColonSpaceValueIsSpaceDocument* = constStr("): value is ", 12)
  ltIntUnknownDocument* = constStr("<unknown", 8)
  commaSpaceUnknownDocument* = constStr(", unknown", 9)
  valueColonSpaceDocument* = constStr("value: ", 7)
  undefinedDocument* = constStr("undefined", 9)
  numberDocument* = constStr("number", 6)
  underscoreDotUtfCodepointDocument* = constStr("_.UtfCodepoint", 14)
  stringDocument* = constStr("string", 6)
  booleanDocument* = constStr("boolean", 7)
  underscoreDotBitArrayDocument* = constStr("_.BitArray", 10)
  underscoreDotListDocument* = constStr("_.List", 6)
  underscoreDotResultDocument* = constStr("_.Result", 8)
  spaceEqualRightArrowSpaceDocument* = constStr(" => ", 4)
  ifSpaceOpenParenDocument* = constStr("if (", 4)
  closeParenSpaceDocument* = constStr(") ", 2)
  doubleCloseParenSpaceDocument* = constStr(")) ", 3)
  ifSpaceOpenParenExclamationOpenParenDocument* = constStr("if (!(", 6)
  spaceElseSpaceDocument* = constStr(" else ", 6)
  dotCharCodeAtZeroDocument* = constStr(".charCodeAt(0)", 14)
  spaceTripleEqualSpaceDocument* = constStr(" === ", 5)
  tripleEqualDocument* = constStr("===", 3)
  dotStartsWithOpenParenDocument* = constStr(".startsWith(", 12)
  zeroDocument* = constStr("0", 1)
  dotBitSizeModulo8Document* = constStr(".bitSize % 8", 12)
  dotBitSizeMinusSpaceDocument* = constStr(".bitSize - ", 11)
  dotBitSizeDocument* = constStr(".bitSize", 8)
  closeParenModulo8Document* = constStr(") % 8", 5)
  spaceGtEqZeroDocument* = constStr(" >= 0", 5)
  spaceGtEqSpaceDocument* = constStr(" >= ", 4)
  globalThisDotNumberDotIsFiniteOpenParenDocument* = constStr("globalThis.Number.isFinite(", 27)
  spaceInstanceOfSpaceDocument* = constStr(" instanceof ", 12)
  spaceInstanceOfNonEmptyDocument* = constStr(" instanceof $NonEmpty", 21)
  spaceInstanceOfEmptyDocument* = constStr(" instanceof $Empty", 18)
  dotByteAtOpenParenDocument* = constStr(".byteAt(", 8)
  commaSpaceDocument* = constStr(", ", 2)
  bitArraySliceToIntOpenParenDocument* = constStr("bitArraySliceToInt(", 19)
  bitArraySliceToFloatOpenParenDocument* = constStr("bitArraySliceToFloat(", 21)
  bitArraySliceOpenParenDocument* = constStr("bitArraySlice(", 14)
  returnSpaceDocument* = constStr("return ", 7)
  spaceEqualLoopDollarDocument* = constStr(" = loop$", 8)
  whileTrueOpenParenDocument* = constStr("while (true) {", 14)
  dollarListDollarEmptyDollarConstDocument* = constStr("$List$Empty$const", 17)
  sizedIntOpenParenDocument* = constStr("sizedInt(", 9)
  sizedFloatOpenParenDocument* = constStr("sizedFloat(", 11)
  stringBitsOpenParenDocument* = constStr("stringBits(", 11)
  stringToUtf16OpenParenDocument* = constStr("stringToUtf16(", 14)
  stringToUtf32OpenParenDocument* = constStr("stringToUtf32(", 14)
  codepointToUtf16OpenParenDocument* = constStr("codepointToUtf16(", 17)
  codepointToUtf32OpenParenDocument* = constStr("codepointToUtf32(", 17)
  toBitArrayOpenParenDocument* = constStr("toBitArray(", 11)
  commaZeroCommaSpace* = constStr(", 0, ", 5)
  throwMakeErrorDocument* = constStr("throw makeError", 15)
  filepathUppercaseDocument* = constStr("FILEPATH", 8)
  spaceEqualArrowSpaceOpenCurlyDocument* = constStr(" => {", 5)
  infinityDocument* = constStr("Infinity", 8)
  minusInfinityDocument* = constStr("-Infinity", 9)
  nanDocument* = constStr("NaN", 3)
  toListOpenParenDocument* = constStr("toList(", 7)
  listPrependDocument* = constStr("listPrepend", 11)
  closeCurlyCloseParenOpenCloseParenDocument* = constStr("})()", 4)
  openParenOpenCloseParenEqualArrowOpenCurlyDocument* = constStr("(() => {", 8)
  codepointBitsOpenParenDocument* = constStr("codepointBits(", 14)
  closeCurlyElseOpenCurlyDocument* = constStr("} else {", 8)
  exclamationMarkOpenParenDocument* = constStr("!(", 2)
  spaceDoubleVerticalBarSpaceDocument* = constStr(" || ", 4)
  spaceDoubleAmpersandSpaceDocument* = constStr(" && ", 4)
  loopDollarDocument* = constStr("loop$", 5)
  divideIntDocument* = constStr("divideInt", 9)
  divideFloatDocument* = constStr("divideFloat", 9)
  globalThisDotMathDotTruncDocument* = constStr("globalThis.Math.trunc", 21)
  spaceModuloSpaceDocument* = constStr(" % ", 3)
  spaceExclamationMarkDoubleEqualSpaceDocument* = constStr(" !== ", 5)
  exclamationMarkDoubleEqualDocument* = constStr("!==", 3)
  isEqualDocument* = constStr("isEqual", 7)
  exclamationMarkIsEqualDocument* = constStr("!isEqual", 8)
  spaceLtIntSpaceDocument* = constStr(" < ", 3)
  spaceLtEqIntSpaceDocument* = constStr(" <= ", 4)
  spaceGtIntSpaceDocument* = constStr(" > ", 3)
  spaceGtEqIntSpaceDocument* = constStr(" >= ", 4)
  camelCaseRemainderIntDocument* = constStr("remainderInt", 12)
  pureJavascriptCommentDocument* = constStr("/* @__PURE__ */ ", 16)
  lowercaseArgDocument* = constStr("arg", 3)
  pubTypeSpaceDocument* = constStr("pub type ", 9)
  pubFnSpaceDocument* = constStr("pub fn ", 7)
  pubConstSpaceDocument* = constStr("pub const ", 10)
  pubOpaqueTypeSpaceDocument* = constStr("pub opaque type ", 16)
  fnOpenParenDocument* = constStr("fn(", 3)
  zeroWidthClosedSpanTagDocument* = zeroWidthStr("</span>")
  zeroWidthClosedATagDocument* = zeroWidthStr("</a>")
  zeroWidthOpenVariableColourSpan* = zeroWidthStr("<span class=\"hljs-variable\">")
  zeroWidthOpenTitleColourSpan* = zeroWidthStr("<span class=\"hljs-title\">")
  zeroWidthOpenKeywordColourSpan* = zeroWidthStr("<span class=\"hljs-keyword\">")
  zeroWidthOpenCommentColourSpan* = zeroWidthStr("<span class=\"hljs-comment\">")
  emptyBreakDocument* = breakDoc("", "")
  breakableSpaceDocument* = breakDoc("", " ")
  commaBreakDocument* = breakDoc(",", ", ")
  trailingCommaBreakDocument* = breakDoc(",", "")
  trailingCommaOrSpaceBreakDocument* = breakDoc(",", " ")
  openCurlyBreakDocument* = breakDoc("{", "{ ")
  openSquareBreakDocument* = breakDoc("[", "[")
  openParenBreakDocument* = breakDoc("(", "(")
  openTupleBreakDocument* = breakDoc("#(", "#(")
  openBitArrayBreakDocument* = breakDoc("<<", "<<")
  caseBreakDocument* = breakDoc("case", "case ")
  spaceDoubleAmpersandBreakDocument* = breakDoc(" &&", " && ")
