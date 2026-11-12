## port-of: format/src/lib.rs
## port-status: draft
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), format/src/lib.rs.

## The formatter: the syntax tree of a module, and what the lexer kept beside
## it (comments, empty lines, trailing commas), back to source text.
##
## How to read this file next to the Rust one:
##
## - Same functions, same order. Upstream's methods of `Formatter` are procs
##   whose first argument is `self`. There is no arena (see pretty.nim).
## - `Formatter` is a `ref object`: upstream passes `&mut self` into closures,
##   and a Nim closure cannot capture a `var` parameter.
## - Upstream's slices that are advanced as comments are consumed
##   (`self.comments = rest`) are a `seq` and the index where the rest begins.
## - Where upstream returns a lazy iterator of comments, the port returns a
##   `seq`: upstream computes what is popped eagerly too (`comments_before`).
## - `pretty`, the entry point that parses and then formats, waits for the
##   parser; `formatModule` is the part of it after parsing.

import std/[algorithm, options, strutils]
import ./[ast, pretty]
import ./parse/extra

const INDENT = 2

type
  Intermediate* = object
    comments: seq[Comment]
    docComments: seq[Comment]
    moduleComments: seq[Comment]
    emptyLines: seq[int]
    newLines: seq[int]
    trailingCommas: seq[int]

  FnCapturePosition = enum
    RightHandSideOfPipe
    EverywhereElse

  Formatter* = ref object
    ## Hayleigh's bane
    comments: seq[Comment]
    commentsStart: int
    docComments: seq[Comment]
    docCommentsStart: int
    moduleComments: seq[Comment]
    emptyLines: seq[int]
    emptyLinesStart: int
    newLines: seq[int]
    trailingCommas: seq[int]

  PoppedComment = tuple[position: int, content: Option[string]]

func fromExtra*(_: typedesc[Intermediate], extra: ModuleExtra, src: string): Intermediate =
  result.emptyLines = extra.emptyLines
  result.newLines = extra.newLines
  result.trailingCommas = extra.trailingCommas
  for span in extra.comments: result.comments.add initComment(span, src)
  for span in extra.docComments: result.docComments.add initComment(span, src)
  for span in extra.moduleComments: result.moduleComments.add initComment(span, src)

func withComments*(_: typedesc[Formatter], extra: Intermediate): Formatter =
  Formatter(
    comments: extra.comments,
    docComments: extra.docComments,
    moduleComments: extra.moduleComments,
    emptyLines: extra.emptyLines,
    newLines: extra.newLines,
    trailingCommas: extra.trailingCommas,
  )

type
  RecordUpdatePieceKind = enum
    rpRecord
    rpArgument

  RecordUpdatePiece[A] = object
    case kind: RecordUpdatePieceKind
    of rpRecord: record: RecordBeingUpdated[A]
    of rpArgument: argument: RecordUpdateArg[A]

  UntypedRecordUpdatePiece = RecordUpdatePiece[UntypedExpr]

  PrecedingAs {.pure.} = enum
    ## This is used to describe the kind of things that might preceding an `as`
    ## message that can be added to various places: `panic`, `echo`,
    ## `let assert`, `assert`, `todo`.
    ##
    ## It might be preceded by a keyword, like with `echo` and `panic`, or by
    ## an expression, like in `assert` or `let assert`.
    Expression
      ## An expression is preceding the `as` message:
      ## `echo 1 as "message"`, `assert 1 == 2 as "message"`,
      ## `let assert Ok(_) = result as "message"`
    Keyword
      ## A keyword is preceding the `as` message:
      ## `1 |> echo as "message"`, `panic as "message"`, `todo as "message"`

  ItemsPacking = enum
    ## This is used to determine how to fit the items of a list, or the
    ## segments of a bit array in a line.
    FitOnePerLine
      ## Try and fit everything on a single line; if the items don't fit,
      ## break the list putting each item into its own line.
    FitMultiplePerLine
      ## Try and fit everything on a single line; if the items don't fit,
      ## break the list putting as many items as possible in a single line.
    BreakOnePerLine
      ## Always break the list, putting each item into its own line.

  CallArgFormattingKind = enum
    cfShorthandLabelled
    cfUnlabelled
    cfLabelled

  CallArgFormatting[A] = object
    kind: CallArgFormattingKind
    label: string
    value: A

  AttributesPrinter = object
    externalErlang: Option[(string, string, SrcSpan)]
    externalJavascript: Option[(string, string, SrcSpan)]
    deprecation: Deprecation
    internal: bool

func location[A](self: RecordUpdatePiece[A]): SrcSpan =
  case self.kind
  of rpRecord: self.record.location
  of rpArgument: self.argument.location

func unbox[T](value: Option[ref T]): Option[T] =
  ## Upstream's `as_deref()`.
  if value.isSome: some(value.get[]) else: none(T)

proc binop(binop: BinOp): Document =
  case binop
  of boAnd: andDocument
  of boOr: orDocument
  of boLtInt: ltIntDocument
  of boLtEqInt: ltEqIntDocument
  of boLtFloat: ltFloatDocument
  of boLtEqFloat: ltEqFloatDocument
  of boEq: eqDocument
  of boNotEq: notEqDocument
  of boGtEqInt: gtEqIntDocument
  of boGtInt: gtIntDocument
  of boGtEqFloat: gtEqFloatDocument
  of boGtFloat: gtFloatDocument
  of boAddInt: addIntDocument
  of boAddFloat: addFloatDocument
  of boSubInt: subIntDocument
  of boSubFloat: subFloatDocument
  of boMultInt: multIntDocument
  of boMultFloat: multFloatDocument
  of boDivInt: divIntDocument
  of boDivFloat: divFloatDocument
  of boRemainderInt: remainderIntDocument
  of boConcatenate: concatDocument

func commentsBefore*(
    comments: seq[Comment], commentsStart: int, emptyLines: seq[int], emptyLinesStart: int,
    limit: int, retainEmptyLines: bool,
): tuple[popped: seq[PoppedComment], rest: int, emptyLines: int] =
  ## Upstream takes two slices and returns what is left of them; here the
  ## slices are a seq and the index where they begin, and what is returned is
  ## the index where the rest begins.
  var endComments = comments.len
  for i in commentsStart ..< comments.len:
    if comments[i].start > limit:
      endComments = i
      break
  var endEmptyLines = emptyLines.len
  for i in emptyLinesStart ..< emptyLines.len:
    if emptyLines[i] > limit:
      endEmptyLines = i
      break

  # compact consecutive empty lines into a single line
  var poppedEmptyLines: seq[int]
  if retainEmptyLines:
    var i = emptyLinesStart
    while i < endEmptyLines:
      poppedEmptyLines.add emptyLines[i]
      var last = emptyLines[i]
      inc i
      while i < endEmptyLines and last + 1 == emptyLines[i]:
        last = emptyLines[i]
        inc i

  # merge the two, a comment first when it starts before the empty line
  var popped: seq[PoppedComment]
  var c = commentsStart
  var e = 0
  while c < endComments or e < poppedEmptyLines.len:
    if c < endComments and (e >= poppedEmptyLines.len or comments[c].start < poppedEmptyLines[e]):
      popped.add (comments[c].start, some(comments[c].content))
      inc c
    else:
      popped.add (poppedEmptyLines[e], none(string))
      inc e

  # skip the empty lines that come before the first comment
  var first = 0
  while first < popped.len and popped[first].content.isNone: inc first
  (popped[first .. ^1], endComments, endEmptyLines)

func isBreakableArgument(expression: UntypedExpr, arity: int): bool =
  case expression.kind
  # A call is only breakable if it is the only argument
  of ueCall: arity == 1
  of ueFn, ueBlock, ueCase, ueList, ueTuple, ueBitArray: true
  of ueInt, ueFloat, ueString, ueVar, ueBinOp, uePipeline, ueFieldAccess, ueTupleIndex, ueTodo,
     uePanic, ueEcho, ueRecordUpdate, ueNegateBool, ueNegateInt: false

func isConstantBreakableArgument(expression: UntypedConstant): bool =
  case expression.kind
  of coTuple, coList, coBitArray: true
  of coInt, coFloat, coString, coRecord, coRecordUpdate, coVar, coBinaryOperator, coInvalid, coTodo:
    false

func callArgFormatting[A](argument: CallArg[A]): CallArgFormatting[A] =
  ## Upstream has three copies of this function, one per type of value:
  ## `expr_call_arg_formatting`, `pattern_call_arg_formatting`,
  ## `constant_call_arg_formatting`.
  if argument.usesLabelShorthand:
    # An argument supplied using label shorthand syntax.
    CallArgFormatting[A](kind: cfShorthandLabelled, label: argument.label.get)
  elif argument.label.isSome:
    # A labelled argument.
    CallArgFormatting[A](kind: cfLabelled, label: argument.label.get, value: argument.value)
  else:
    # An unlabelled argument.
    CallArgFormatting[A](kind: cfUnlabelled, value: argument.value)

func exprCallArgFormatting(argument: CallArg[UntypedExpr]): CallArgFormatting[UntypedExpr] =
  callArgFormatting(argument)

func patternCallArgFormatting(argument: CallArg[UntypedPattern]): CallArgFormatting[UntypedPattern] =
  callArgFormatting(argument)

func constantCallArgFormatting(argument: CallArg[UntypedConstant]): CallArgFormatting[UntypedConstant] =
  callArgFormatting(argument)

func new(_: typedesc[AttributesPrinter]): AttributesPrinter =
  AttributesPrinter()

func setExternalErlang(self: AttributesPrinter, external: Option[(string, string, SrcSpan)]): AttributesPrinter =
  result = self
  result.externalErlang = external

func setExternalJavascript(self: AttributesPrinter, external: Option[(string, string, SrcSpan)]): AttributesPrinter =
  result = self
  result.externalJavascript = external

func setInternal(self: AttributesPrinter, publicity: Publicity): AttributesPrinter =
  result = self
  result.internal = publicity.isInternal

func setDeprecation(self: AttributesPrinter, deprecation: Deprecation): AttributesPrinter =
  result = self
  result.deprecation = deprecation

proc toDoc(self: AttributesPrinter): Document =
  var attributes: seq[Document]

  # @deprecated attribute
  if self.deprecation.kind == dpDeprecated:
    attributes.add docvec(deprecatedAttributeQuoteDocument, self.deprecation.vDeprecated.message,
                          quoteCloseParenDocument)

  # @external attributes
  if self.externalErlang.isSome:
    let (module, function, _) = self.externalErlang.get
    attributes.add docvec(externalErlangQuoteDocument, module, quoteCommaSpaceQuoteDocument, function,
                          quoteCloseParenDocument)

  if self.externalJavascript.isSome:
    let (module, function, _) = self.externalJavascript.get
    attributes.add docvec(externalJavascriptQuoteDocument, module, quoteCommaSpaceQuoteDocument,
                          function, quoteCloseParenDocument)

  # @internal attribute
  if self.internal: attributes.add internalAttributeDocument

  if attributes.len == 0: emptyDocument
  else: join(attributes, line()).append(line())

proc breakBlock*(doc: Document): Document =
  openCurlyDocument
    .append(lineDocument.append(doc).nest(INDENT))
    .append(lineDocument)
    .append(closeCurlyDocument)
    .forceBreak

proc wrapBlock*(doc: Document): Document =
  openCurlyBreakDocument
    .append(doc)
    .nest(INDENT)
    .append(breakableSpaceDocument)
    .append(closeCurlyDocument)

proc printedComments(comments: seq[Option[string]], trailingNewline: bool): Option[Document] =
  if comments.len == 0: return none(Document)

  var doc: seq[Document]
  var i = 0
  while i < comments.len:
    let comment = comments[i]
    inc i
    if comment.isNone: continue

    # The comment is turned into a zero width string rather than a regular
    # string document: comment lines are never touched by the formatter and
    # we don't need to know how long each one is.
    # So we can do this to avoid counting the graphemes of each one, which
    # is a lot of wasted work.
    doc.add commentDocument.append(zeroWidthStr(comment.get))
    if i < comments.len:
      if comments[i].isSome:
        # Next line is a comment
        doc.add lineDocument
      else:
        # Next line is empty
        inc i
        if i < comments.len: doc.add twoLinesDocument
        elif trailingNewline: doc.add twoLinesDocument
    elif trailingNewline:
      # We've reached the end, there are no more lines
      doc.add lineDocument

  let all = concat(doc)
  if trailingNewline: some(all.forceBreak) else: some(all)

proc commented(doc: Document, comments: seq[Option[string]]): Document =
  let printed = printedComments(comments, true)
  if printed.isSome: printed.get.append(doc.group) else: doc

proc segmentOption[Value](option: BitArrayOption[Value], valueDoc: proc(value: Value): Document): Document =
  case option.kind
  of baBytes: bytesDocument
  of baBits: bitsDocument
  of baInt: intDocument
  of baFloat: floatDocument
  of baUtf8: utf8Document
  of baUtf16: utf16Document
  of baUtf32: utf32Document
  of baUtf8Codepoint: utf8CodepointDocument
  of baUtf16Codepoint: utf16CodepointDocument
  of baUtf32Codepoint: utf32CodepointDocument
  of baSigned: signedDocument
  of baUnsigned: unsignedDocument
  of baBig: bigDocument
  of baLittle: littleDocument
  of baNative: nativeDocument
  of baSize:
    if option.vSize.shortForm: valueDoc(option.vSize.value[])
    else:
      sizeDocument.append(openParenDocument).append(valueDoc(option.vSize.value[])).append(
        closeParenDocument
      )
  of baUnit:
    unitDocument.append(openParenDocument).append($option.vUnit.value).append(closeParenDocument)

proc bitArraySegment[Value, Type](
    segment: BitArraySegment[Value, Type], valueDoc: proc(value: Value): Document
): Document =
  if segment.options.len == 0: return valueDoc(segment.value[])

  let value = valueDoc(segment.value[])
  var options: seq[Document]
  for option in segment.options: options.add segmentOption(option, valueDoc)
  value.append(colonDocument).append(join(options, subIntDocument))

proc pubDoc(publicity: Publicity): Document =
  case publicity.kind
  of pbPublic, pbInternal: pubSpaceDocument
  of pbPrivate: emptyDocument

# Upstream's methods call each other in every direction: their signatures first.

proc anyComments(self: Formatter, limit: int): bool
proc anyCommentBetween(self: Formatter, start, stop: int): bool
proc anyEmptyLines(self: Formatter, limit: int): bool
proc popCommentsWithPosition(self: Formatter, limit: int): seq[PoppedComment]
proc popComments(self: Formatter, limit: int): seq[Option[string]]
proc popDocComments(self: Formatter, limit: int): seq[Option[string]]
proc popEmptyLines(self: Formatter, limit: int): bool
proc targetedDefinition(self: Formatter, definition: TargetedDefinition): Document
proc module*(self: Formatter, module: UntypedModule): Document
proc imports(self: Formatter, imports: seq[TargetedDefinition]): seq[Document]
proc sortedImportGroup(self: Formatter, imports: seq[TargetedDefinition]): Document
proc unqualifiedImport(self: Formatter, unqualifiedImport: UnqualifiedImport): Document
proc definition(self: Formatter, statement: UntypedDefinition): Document
proc constExpr(self: Formatter, value: UntypedConstant): Document
proc constList(self: Formatter, elements: seq[UntypedConstant], location: SrcSpan,
               tail: Option[ref UntypedConstant]): Document
proc constTuple*(self: Formatter, elements: seq[UntypedConstant], location: SrcSpan): Document
proc documentedDefinition(self: Formatter, definition: UntypedDefinition): Document
proc docCommentsDoc(self: Formatter, limit: int): Document
proc typeAstConstructor(self: Formatter, name: TypeAstConstructorName, arguments: seq[TypeAst],
                        location: SrcSpan): Document
proc typeAst(self: Formatter, typ: TypeAst): Document
proc typeArguments(self: Formatter, arguments: seq[TypeAst], location: SrcSpan): Document
proc typeAlias*[A](self: Formatter, alias: TypeAlias[A]): Document
proc argumentNames(self: Formatter, argumentNames: ArgNames): Document
proc fnArg[A](self: Formatter, argument: Arg[A]): Document
proc statementFn(self: Formatter, function: UntypedFunction): Document
proc exprFn(self: Formatter, arguments: seq[UntypedArg], returnAnnotation: Option[TypeAst],
            body: seq[UntypedStatement], location: SrcSpan, endOfHeadByteIndex: int): Document
proc statements(self: Formatter, statements: seq[UntypedStatement]): Document
proc assignment(self: Formatter, assignment: UntypedAssignment): Document
proc expr(self: Formatter, expression: UntypedExpr): Document
proc stringDoc(self: Formatter, string: string): Document
proc binOpString(self: Formatter, string: string): Document
proc floatDoc(self: Formatter, value: string): Document
proc intDoc(self: Formatter, value: string): Document
proc underscoreIntegerString(self: Formatter, value: string): Document
proc patternConstructor(self: Formatter, name: string, arguments: seq[CallArg[UntypedPattern]],
                        module: Option[(string, SrcSpan)], spread: Option[SrcSpan],
                        location: SrcSpan): Document
proc call(self: Formatter, function: UntypedExpr, arguments: seq[CallArg[UntypedExpr]],
          location: SrcSpan): Document
proc tupleDoc(self: Formatter, elements: seq[UntypedExpr], location: SrcSpan): Document
proc appendInlinableWrappedArguments[T](
    self: Formatter, doc: Document, values: seq[T], location: SrcSpan,
    isBreakableArgument: proc(value: T): bool,
    toDoc: proc(self: Formatter, value: T): Document): Document
proc caseDoc*(self: Formatter, subjects: seq[UntypedExpr], clauses: seq[UntypedClause],
              location: SrcSpan): Document
proc recordUpdate*(self: Formatter, constructor: UntypedExpr, record: RecordBeingUpdated[UntypedExpr],
                   arguments: seq[UntypedRecordUpdateArg], location: SrcSpan): Document
proc constRecordUpdate*(self: Formatter, module: Option[(string, SrcSpan)], name: string,
                        record: RecordBeingUpdated[UntypedConstant],
                        arguments: seq[RecordUpdateArg[UntypedConstant]], location: SrcSpan): Document
proc binOp*(self: Formatter, name: BinOp, left, right: UntypedExpr, nestSteps: bool): Document
proc constantBinaryOperator*(self: Formatter, name: BinOp, left, right: UntypedConstant,
                             nestSteps: bool): Document
proc constantBinaryOperatorSide(self: Formatter, operator: BinOp, side: UntypedConstant,
                                nestSteps: bool): Document
proc binOpSide(self: Formatter, operator: BinOp, side: UntypedExpr, nestSteps: bool): Document
proc operatorSide*(self: Formatter, doc: Document, op, side: uint8): Document
proc spansMultipleLines(self: Formatter, start, stop: int): bool
proc hasTrailingComma(self: Formatter, start, stop: int): bool
proc pipeline(self: Formatter, expressions: seq[UntypedExpr], nestPipe: bool): Document
proc expressionOnRightHandSideOfPipe(self: Formatter, nestPipe: bool, expression: UntypedExpr): Document
proc fnCapture(self: Formatter, call: seq[UntypedStatement], position: FnCapturePosition): Document
proc recordConstructor*[A](self: Formatter, constructor: RecordConstructor[A]): Document
proc customType*[A](self: Formatter, typ: CustomType[A]): Document
proc callArg(self: Formatter, argument: CallArg[UntypedExpr], arity: int): Document
proc formatCallArg[A](self: Formatter, argument: CallArg[A],
                      figureFormatting: proc(argument: CallArg[A]): CallArgFormatting[A],
                      formatValue: proc(self: Formatter, value: A): Document): Document
proc recordUpdateArg(self: Formatter, argument: UntypedRecordUpdateArg): Document
proc constantRecordUpdateArgument(self: Formatter, argument: RecordUpdateArg[UntypedConstant]): Document
proc tupleIndex(self: Formatter, tupl: UntypedExpr, index: uint64): Document
proc caseClauseValue(self: Formatter, expression: UntypedExpr): Document
proc assignedValue(self: Formatter, expression: UntypedExpr): Document
proc clause(self: Formatter, clause: UntypedClause, index: int): Document
proc alternativePatterns(self: Formatter, clause: UntypedClause): Document
proc list(self: Formatter, elements: seq[UntypedExpr], tail: Option[UntypedExpr],
          location: SrcSpan): Document
proc itemsSequencePacking[T](self: Formatter, items: seq[T], tail: Option[SrcSpan],
                             canHaveMultiplePerLine: proc(item: T): bool,
                             listLocation: SrcSpan): ItemsPacking
proc hasItemsOnTheSameLine(self: Formatter, items: seq[SrcSpan]): bool
proc commaSeparatedItem(self: Formatter, expression: UntypedExpr, siblings: int): Document
proc commaSeparatedConstantItem(self: Formatter, constant: UntypedConstant, siblings: int): Document
proc patternDoc(self: Formatter, pattern: UntypedPattern): Document
proc bitArraySize(self: Formatter, size: BitArraySize[Unit]): Document
proc listPattern(self: Formatter, elements: seq[UntypedPattern],
                 tail: Option[ref UntypedTailPattern]): Document
proc patternCallArg(self: Formatter, argument: CallArg[UntypedPattern]): Document
proc clauseGuardBinOp*(self: Formatter, name: BinOp, left, right: UntypedClauseGuard): Document
proc clauseGuardBinOpSide(self: Formatter, name: BinOp, side: UntypedClauseGuard,
                          sidePrecedence: uint8): Document
proc clauseGuard(self: Formatter, clauseGuard: UntypedClauseGuard): Document
proc constantCallArg(self: Formatter, argument: CallArg[UntypedConstant]): Document
proc negateBool(self: Formatter, expression: UntypedExpr): Document
proc negateInt(self: Formatter, expression: UntypedExpr): Document
proc useDoc(self: Formatter, use: UntypedUse): Document
proc assertDoc(self: Formatter, assert: UntypedAssert): Document
proc bitArray(self: Formatter, segments: seq[Document], packing: ItemsPacking,
              location: SrcSpan): Document
proc bitArraySegmentExpr(self: Formatter, expression: UntypedExpr): Document
proc statement(self: Formatter, statement: UntypedStatement): Document
proc blockDoc(self: Formatter, location: SrcSpan, statements: seq[UntypedStatement],
              forceBreaks: bool): Document
proc wrapFunctionCallArguments*(self: Formatter, arguments: seq[Document], location: SrcSpan): Document
proc wrapArguments*(self: Formatter, arguments: seq[Document], commentsLimit: int): Document
proc wrapArgumentsWithSpread*(self: Formatter, arguments: seq[Document], commentsLimit: int): Document
proc printedDocumentedComments(self: Formatter, comments: seq[PoppedComment]): Option[Document]
proc appendAsMessageExpression(self: Formatter, doc: Document, precedingAs: PrecedingAs,
                               message: Option[UntypedExpr]): Document
proc appendAsMessageConstant(self: Formatter, doc: Document, message: Option[UntypedConstant]): Document
proc echoDoc(self: Formatter, expression: Option[ref UntypedExpr],
             message: Option[ref UntypedExpr]): Document
proc formatModule*(module: UntypedModule, extra: ModuleExtra, src: string): string

proc anyComments(self: Formatter, limit: int): bool =
  ## Returns true if there's any comment that comes before the given
  ## position.
  self.commentsStart < self.comments.len and self.comments[self.commentsStart].start < limit

proc anyCommentBetween(self: Formatter, start, stop: int): bool =
  ## Returns true if there's any comment that appears inside the given span.
  # Upstream: a binary search that only asks whether there is one.
  var low = self.commentsStart
  var high = self.comments.high
  while low <= high:
    let mid = (low + high) div 2
    let comment = self.comments[mid]
    if comment.start < start: low = mid + 1
    elif comment.start > stop: high = mid - 1
    else: return true
  false

proc anyEmptyLines(self: Formatter, limit: int): bool =
  self.emptyLinesStart < self.emptyLines.len and self.emptyLines[self.emptyLinesStart] < limit

proc popCommentsWithPosition(self: Formatter, limit: int): seq[PoppedComment] =
  ## Pop comments that occur before a byte-index in the source, consuming
  ## and retaining any empty lines contained within.
  ## Returns the comments with their start position.
  let (popped, rest, emptyLines) =
    commentsBefore(self.comments, self.commentsStart, self.emptyLines, self.emptyLinesStart, limit, true)
  self.commentsStart = rest
  self.emptyLinesStart = emptyLines
  popped

proc popComments(self: Formatter, limit: int): seq[Option[string]] =
  ## Pop comments that occur before a byte-index in the source, consuming
  ## and retaining any empty lines contained within.
  for (_, comment) in self.popCommentsWithPosition(limit): result.add comment

proc popDocComments(self: Formatter, limit: int): seq[Option[string]] =
  ## Pop doc comments that occur before a byte-index in the source, consuming
  ## and dropping any empty lines contained within.
  let (popped, rest, emptyLines) =
    commentsBefore(self.docComments, self.docCommentsStart, self.emptyLines, self.emptyLinesStart, limit, false)
  self.docCommentsStart = rest
  self.emptyLinesStart = emptyLines
  for (_, comment) in popped: result.add comment

proc popEmptyLines(self: Formatter, limit: int): bool =
  ## Remove between 0 and `limit` empty lines following the current position,
  ## returning true if any empty lines were removed.
  var stop = 0
  for i in self.emptyLinesStart ..< self.emptyLines.len:
    if self.emptyLines[i] > limit: break
    stop = i - self.emptyLinesStart + 1

  self.emptyLinesStart += stop
  stop != 0

proc targetedDefinition(self: Formatter, definition: TargetedDefinition): Document =
  let target = definition.target
  let definition = definition.definition
  let start = definition.location.start

  let comments = self.popCommentsWithPosition(start)
  let comments2 = self.printedDocumentedComments(comments)
  var document = self.documentedDefinition(definition)
  if target.isSome:
    case target.get
    of tgErlang: document = docvec("@target(erlang)", lineDocument, document)
    of tgJavaScript: document = docvec("@target(javascript)", lineDocument, document)
  document = document.group
  if comments2.isSome: comments2.get.append(document)
  else: document

proc module*(self: Formatter, module: UntypedModule): Document =
  var documents: seq[Document]
  var previousWasADefinition = false

  # Here we take consecutive groups of imports so that they can be sorted
  # alphabetically.
  var index = 0
  while index < module.definitions.len:
    let isImportGroup = module.definitions[index].definition.isImport
    var definitions: seq[TargetedDefinition]
    while index < module.definitions.len and module.definitions[index].definition.isImport == isImportGroup:
      definitions.add module.definitions[index]
      inc index
    if isImportGroup:
      if previousWasADefinition:
        documents.add twoLinesDocument
      documents.add self.imports(definitions)
      previousWasADefinition = false
    else:
      for definition in definitions:
        if documents.len > 0:
          documents.add twoLinesDocument
        documents.add self.targetedDefinition(definition)
      previousWasADefinition = true

  let definitions = concat(documents)

  # Now that definitions has been collected, only freestanding comments (//)
  # and doc comments (///) remain. Freestanding comments aren't associated
  # with any statement, and are moved to the bottom of the module.
  var docCommentDocs: seq[Document]
  for i in self.docCommentsStart ..< self.docComments.len:
    docCommentDocs.add docCommentDocument.append(zeroWidthStr(self.docComments[i].content))
  let docComments = join(docCommentDocs, lineDocument)

  let poppedComments = self.popComments(high(int))
  let printed = printedComments(poppedComments, false)
  let comments = if printed.isSome: printed.get else: emptyDocument

  let moduleComments =
    if self.moduleComments.len > 0:
      var comments: seq[Document]
      for s in self.moduleComments:
        comments.add moduleCommentDocument.append(zeroWidthStr(s.content))
      join(comments, lineDocument).append(lineDocument)
    else:
      emptyDocument

  var nonEmpty: seq[Document]
  for doc in [moduleComments, definitions, docComments, comments]:
    if not doc.isEmpty: nonEmpty.add doc

  join(nonEmpty, lineDocument).append(lineDocument)

proc imports(self: Formatter, imports: seq[TargetedDefinition]): seq[Document] =
  ## Separates the imports in groups delimited by comments or empty lines and
  ## sorts each group alphabetically.
  ##
  ## The formatter needs to play nicely with import groups defined by the
  ## programmer. If one puts a comment before an import then that's a clue
  ## for the formatter that it has run into a gorup of related imports.
  ##
  ## So we can't just sort `imports` and format each one, we have to be a
  ## bit smarter and see if each import is preceded by a comment.
  ## Once we find a comment we know we're done with the current import
  ## group and a new one has started.
  ##
  ## ```gleam
  ## // This is an import group.
  ## import gleam/int
  ## import gleam/string
  ##
  ## // This marks the beginning of a new import group that can't
  ## // be mushed together with the previous one!
  ## import wibble
  ## import wobble
  ## ```
  var importGroupsDocs: seq[Document]
  var currentGroup: seq[TargetedDefinition]
  var currentGroupDelimiter = emptyDocument

  for imp in imports:
    let start = imp.definition.location.start

    # We need to start a new group if the `import` is preceded by one or
    # more empty lines or a `//` comment.
    let startNewGroup = self.anyComments(start) or self.anyEmptyLines(start)
    if startNewGroup:
      # First we print the previous group and clear it out to start a
      # new empty group containing the import we've just ran into.
      if currentGroup.len > 0:
        importGroupsDocs.add docvec(currentGroupDelimiter, self.sortedImportGroup(currentGroup))
        currentGroup.setLen 0

      # Now that we've taken care of the previous group we can start
      # the new one. We know it's preceded either by an empty line or
      # some comments se we have to be a bit more precise and save the
      # actual delimiter that we're going to put at the top of this
      # group.

      let comments = self.popComments(start)
      discard self.popEmptyLines(start)
      let printed = printedComments(comments, true)
      currentGroupDelimiter = if printed.isSome: printed.get else: emptyDocument
    # Lastly we add the import to the group.
    currentGroup.add imp

  # Let's not forget about the last import group!
  if currentGroup.len > 0:
    importGroupsDocs.add docvec(currentGroupDelimiter, self.sortedImportGroup(currentGroup))

  # We want all consecutive import groups to be separated by an empty line.
  # This should really be `.intersperse(LINE_DOCUMENT)` but I can't do that
  # because of https://github.com/rust-lang/rust/issues/48919.
  for i, doc in importGroupsDocs:
    if i > 0: result.add twoLinesDocument
    result.add doc

proc sortedImportGroup(self: Formatter, imports: seq[TargetedDefinition]): Document =
  ## Prints the imports as a single sorted group of import statements.
  let sortedImports = imports.sorted(proc(one, other: TargetedDefinition): int =
    if one.definition.kind == dfImport and other.definition.kind == dfImport:
      cmp(one.definition.vImport.module, other.definition.vImport.module)
    else:
      # It shouldn't really be possible for a non import to be here so
      # we just return a default value.
      0)
  var docs: seq[Document]
  for imp in sortedImports: docs.add self.targetedDefinition(imp)
  join(docs, lineDocument)

proc unqualifiedImport(self: Formatter, unqualifiedImport: UnqualifiedImport): Document =
  unqualifiedImport.name.toDoc.append(
    if unqualifiedImport.asName.isNone: emptyDocument
    elif unqualifiedImport.asName.get == unqualifiedImport.name: emptyDocument
    else: " as ".toDoc.append(unqualifiedImport.asName.get))

proc definition(self: Formatter, statement: UntypedDefinition): Document =
  case statement.kind
  of dfFunction: self.statementFn(statement.vFunction)

  of dfTypeAlias: self.typeAlias(statement.vTypeAlias)

  of dfCustomType: self.customType(statement.vCustomType)

  of dfImport:
    let module = statement.vImport.module
    let asName = statement.vImport.asName
    let unqualifiedValues = statement.vImport.unqualifiedValues
    let unqualifiedTypes = statement.vImport.unqualifiedTypes
    let second =
      if unqualifiedValues.len == 0 and unqualifiedTypes.len == 0:
        emptyDocument
      else:
        let byName = proc(a, b: UnqualifiedImport): int = cmp(a.name, b.name)
        var unqualifiedDocs: seq[Document]
        for imp in unqualifiedTypes.sorted(byName):
          unqualifiedDocs.add docvec(typeSpaceDocument, self.unqualifiedImport(imp))
        for imp in unqualifiedValues.sorted(byName):
          unqualifiedDocs.add self.unqualifiedImport(imp)
        var unqualified = join(unqualifiedDocs, flexCommaDocument)
        unqualified = emptyBreakDocument
          .append(unqualified)
          .nest(INDENT)
          .append(trailingCommaBreakDocument)
          .group
        ".{".toDoc.append(unqualified).append(closeCurlyDocument)

    let doc = docvec(importSpaceDocument, module, second)
    let defaultModuleAccessName = module.rsplit('/', maxsplit = 1)[^1]
    if asName.isNone:
      doc
    elif asName.get[0].kind == anVariable and defaultModuleAccessName == asName.get[0].vVariable:
      # If the `as name` is the same as the module name that would be
      # used anyways we won't render it. For example:
      # ```gleam
      # import gleam/int as int
      #                  ^^^^^^ this is redundant and removed
      # ```
      doc
    else:
      doc.append(spaceAsSpaceDocument).append(asName.get[0].name)

  of dfModuleConstant:
    let constant = statement.vModuleConstant
    let attributes = AttributesPrinter.new
      .setInternal(constant.publicity)
      .setDeprecation(constant.deprecation)
      .toDoc
    var head = attributes
      .append(pubDoc(constant.publicity))
      .append(constSpaceDocument)
      .append(constant.name)
    if constant.annotation.isSome:
      head = head.append(colonSpaceDocument).append(self.typeAst(constant.annotation.get))

    let value = constant.value[]
    var valueDoc: Document
    case value.kind
    of coList, coTuple, coBitArray:
      let expressionComments = self.popComments(value.location.start)
      let expressionDoc = self.constExpr(value)
      let printed = printedComments(expressionComments, true)
      valueDoc =
        if printed.isSome: lineDocument.append(printed.get).append(expressionDoc).nest(INDENT)
        else: spaceDocument.append(expressionDoc)

    of coInt, coFloat, coString, coRecord, coRecordUpdate, coVar, coBinaryOperator, coInvalid, coTodo:
      valueDoc = breakableSpaceDocument.append(self.constExpr(value).group).nest(INDENT)
    valueDoc = valueDoc.nextBreakFits(Disabled).group

    docvec(head, spaceEqualDocument, valueDoc)

proc constExpr(self: Formatter, value: UntypedConstant): Document =
  let comments = self.popComments(value.location.start)
  var document: Document
  case value.kind
  of coTodo:
    document = self.appendAsMessageConstant(todoDocument, unbox(value.vTodo.message))

  of coInt: document = self.intDoc(value.vInt.value)

  of coFloat: document = self.floatDoc(value.vFloat.value)

  of coString: document = self.stringDoc(value.vString.value)

  of coList:
    document = self.constList(value.vList.elements, value.vList.location, value.vList.tail)

  of coTuple:
    document = self.constTuple(value.vTuple.elements, value.vTuple.location)

  of coBitArray:
    let segments = value.vBitArray.segments
    let location = value.vBitArray.location
    var segmentDocs: seq[Document]
    for segment in segments:
      segmentDocs.add bitArraySegment(segment, proc(expression: UntypedConstant): Document =
        self.constExpr(expression))

    let packing = self.itemsSequencePacking(
      segments,
      none(SrcSpan),
      proc(segment: UntypedConstantBitArraySegment): bool = segment.value[].canHaveMultiplePerLine,
      location,
    )

    document = self.bitArray(segmentDocs, packing, location)

  of coRecord:
    let record = value.vRecord
    if record.arguments.isNone and record.module.isNone:
      document = record.name.toDoc
    elif record.arguments.isNone:
      document = record.module.get[0].toDoc.append(dotDocument).append(record.name)
    elif record.module.isNone:
      var arguments: seq[Document]
      for argument in record.arguments.get: arguments.add self.constantCallArg(argument)
      document = record.name.toDoc
        .append(self.wrapArguments(arguments, record.location.stop))
        .group
    else:
      var arguments: seq[Document]
      for argument in record.arguments.get: arguments.add self.constantCallArg(argument)
      document = record.module.get[0].toDoc
        .append(dotDocument)
        .append(record.name)
        .append(self.wrapArguments(arguments, record.location.stop))
        .group

  of coVar:
    if value.vVar.module.isNone: document = value.vVar.name.toDoc
    else: document = docvec(value.vVar.module.get[0], dotDocument, value.vVar.name)

  of coBinaryOperator:
    document = self.constantBinaryOperator(
      value.vBinaryOperator.operator, value.vBinaryOperator.left[], value.vBinaryOperator.right[], false)

  of coRecordUpdate:
    let update = value.vRecordUpdate
    document = self.constRecordUpdate(update.module, update.name, update.record, update.arguments,
                                      update.location)

  of coInvalid: raiseAssert "invalid constants can not be in an untyped ast"
  commented(document, comments)

proc constList(self: Formatter, elements: seq[UntypedConstant], location: SrcSpan,
               tail: Option[ref UntypedConstant]): Document =
  if elements.len == 0:
    # We take all comments that come _before_ the end of the list,
    # that is all comments that are inside "[" and "]", if there's
    # any comment we want to put it inside the empty list!
    let comments = self.popComments(location.stop)
    let printed = printedComments(comments, false)
    if printed.isNone: return openCloseSquareDocument
    return openSquareDocument
      .append(emptyBreakDocument.nest(INDENT))
      .append(printed.get)
      .append(emptyBreakDocument)
      .append(closeSquareDocument)
      # vvv We want to make sure the comments are on a separate
      #     line from the opening and closing brackets so we
      #     force the breaks to be split on newlines.
      .forceBreak

  let listPacking = self.itemsSequencePacking(
    elements,
    (if tail.isSome: some(tail.get[].location) else: none(SrcSpan)),
    proc(element: UntypedConstant): bool = element.canHaveMultiplePerLine,
    location,
  )
  let comma = case listPacking
    of FitMultiplePerLine: flexCommaDocument
    of FitOnePerLine, BreakOnePerLine: commaBreakDocument

  let listSize = elements.len + (if tail.isSome: 1 else: 0)
  var isEmpty = true
  var elementsDoc = emptyDocument
  for element in elements:
    let emptyLines = self.popEmptyLines(element.location.start)
    let elementDoc = self.commaSeparatedConstantItem(element, listSize)

    elementsDoc =
      if isEmpty:
        isEmpty = false
        elementDoc
      elif emptyLines:
        # If there's empty lines before the list item we want to add an
        # empty line here. Notice how we're making sure no nesting is
        # added after the comma, otherwise we would be adding needless
        # whitespace in the empty line!
        docvec(elementsDoc, comma.setNesting(0), lineDocument, elementDoc)
      else:
        docvec(elementsDoc, comma, elementDoc)
  elementsDoc = elementsDoc.nextBreakFits(Disabled)

  var doc = openSquareBreakDocument.append(elementsDoc)
  var finalBreak: Document
  if tail.isNone:
    doc = doc.nest(INDENT)
    finalBreak = trailingCommaBreakDocument
  else:
    let comments = self.popComments(tail.get[].location.start)

    let tailDoc = commented(docvec(dotDotDocument, self.constExpr(tail.get[])), comments)
    doc = doc.append(commaBreakDocument).append(tailDoc).nest(INDENT)
    finalBreak = emptyBreakDocument

  # We get all remaining comments that come before the list's closing
  # square bracket.
  # If there's any we add those before the closing square bracket instead
  # of moving those out of the list.
  # Otherwise those would be moved out of the list.
  let comments = self.popComments(location.stop)
  let printed = printedComments(comments, false)
  doc =
    if printed.isNone:
      doc.append(finalBreak).append(closeSquareDocument)
    else:
      doc
        .append(finalBreak.nest(INDENT))
        # ^ See how here we're adding the missing indentation to the
        #   final break so that the final comment is as indented as the
        #   list's items.
        .append(printed.get.nest(INDENT))
        .append(lineDocument)
        .append(closeSquareDocument)
        .forceBreak

  case listPacking
  of FitOnePerLine, FitMultiplePerLine: doc.group
  of BreakOnePerLine: doc.forceBreak

proc constTuple*(self: Formatter, elements: seq[UntypedConstant], location: SrcSpan): Document =
  if elements.len == 0:
    # We take all comments that come _before_ the end of the tuple,
    # that is all comments that are inside "#(" and ")", if there's
    # any comment we want to put it inside the empty list!
    let comments = self.popComments(location.stop)
    let printed = printedComments(comments, false)
    if printed.isNone: return emptyTupleDocument
    return openTupleDocument
      .append(emptyBreakDocument.nest(INDENT))
      .append(printed.get)
      .append(emptyBreakDocument)
      .append(closeParenDocument)
      # vvv We want to make sure the comments are on a separate
      #     line from the opening and closing parentheses so we
      #     force the breaks to be split on newlines.
      .forceBreak

  self.appendInlinableWrappedArguments(
    hashtagDocument,
    elements,
    location,
    proc(constant: UntypedConstant): bool = not constant.isTuple and isConstantBreakableArgument(constant),
    proc(self: Formatter, constant: UntypedConstant): Document =
      self.commaSeparatedConstantItem(constant, elements.len),
  )

proc documentedDefinition(self: Formatter, definition: UntypedDefinition): Document =
  let comments = self.docCommentsDoc(definition.location.start)
  comments.append(self.definition(definition).group).group

proc docCommentsDoc(self: Formatter, limit: int): Document =
  let comments = self.popDocComments(limit)
  if comments.len == 0: return emptyDocument
  var docs: seq[Document]
  for comment in comments:
    if comment.isSome: docs.add docCommentDocument.append(zeroWidthStr(comment.get))
    else: raiseAssert "empty lines dropped by pop_doc_comments"
  join(docs, lineDocument).append(lineDocument).forceBreak

proc typeAstConstructor(self: Formatter, name: TypeAstConstructorName, arguments: seq[TypeAst],
                        location: SrcSpan): Document =
  let head = case name.kind
    of tnUnqualified: name.vUnqualified.name.toDoc
    of tnQualified:
      name.vQualified.module.toDoc.append(dotDocument).append(
        if name.vQualified.name.isSome: name.vQualified.name.get[0].toDoc else: emptyDocument)

  if arguments.len == 0: head
  else: head.append(self.typeArguments(arguments, location))

proc typeAst(self: Formatter, typ: TypeAst): Document =
  let comments = self.popComments(typ.location.start)

  let doc = case typ.kind
    of tyHole: typ.vHole.name.toDoc

    of tyConstructor:
      self.typeAstConstructor(typ.vConstructor.name, typ.vConstructor.arguments, typ.vConstructor.location)

    of tyFn:
      fnDocument
        .append(self.typeArguments(typ.vFn.arguments, typ.vFn.location))
        .group
        .append(spaceRightArrowDocument)
        .append(breakableSpaceDocument.append(self.typeAst(typ.vFn.returns[])).group.nest(INDENT))

    of tyVar: typ.vVar.name.toDoc

    of tyTuple:
      hashtagDocument.append(self.typeArguments(typ.vTuple.elements, typ.vTuple.location))

  commented(doc.group, comments)

proc typeArguments(self: Formatter, arguments: seq[TypeAst], location: SrcSpan): Document =
  var docs: seq[Document]
  for typ in arguments: docs.add self.typeAst(typ)
  self.wrapArguments(docs, location.stop)

proc typeAlias*[A](self: Formatter, alias: TypeAlias[A]): Document =
  let attributes = AttributesPrinter.new
    .setDeprecation(alias.deprecation)
    .setInternal(alias.publicity)
    .toDoc

  var head = docvec(attributes, pubDoc(alias.publicity), typeSpaceDocument, alias.alias)
  if alias.parameters.len > 0:
    var arguments: seq[Document]
    for (_, e) in alias.parameters: arguments.add e.toDoc
    head = head.append(self.wrapArguments(arguments, alias.location.stop).group)

  head.append(spaceEqualDocument).append(
    lineDocument.append(self.typeAst(alias.typeAst)).group.nest(INDENT))

proc argumentNames(self: Formatter, argumentNames: ArgNames): Document =
  case argumentNames.kind
  of agNamed: argumentNames.vNamed.name.toDoc
  of agDiscard: argumentNames.vDiscard.name.toDoc
  of agLabelledDiscard:
    docvec(argumentNames.vLabelledDiscard.label, " ", argumentNames.vLabelledDiscard.name)
  of agNamedLabelled:
    docvec(argumentNames.vNamedLabelled.label, " ", argumentNames.vNamedLabelled.name)

proc fnArg[A](self: Formatter, argument: Arg[A]): Document =
  let comments = self.popComments(argument.location.start)
  let doc = (
    if argument.annotation.isNone: self.argumentNames(argument.names)
    else:
      self.argumentNames(argument.names)
        .append(colonSpaceDocument)
        .append(self.typeAst(argument.annotation.get))
  ).group
  commented(doc, comments)

proc statementFn(self: Formatter, function: UntypedFunction): Document =
  let attributes = AttributesPrinter.new
    .setDeprecation(function.deprecation)
    .setInternal(function.publicity)
    .setExternalErlang(function.externalErlang)
    .setExternalJavascript(function.externalJavascript)
    .toDoc

  # Fn name and args
  var arguments: seq[Document]
  for argument in function.arguments: arguments.add self.fnArg(argument)
  doAssert function.name.isSome, "Function in a statement must be named"
  var signature = pubDoc(function.publicity)
    .append(fnSpaceDocument)
    .append(function.name.get[1])
    .append(self.wrapArguments(
      arguments,
      # Calculate end location of arguments to not consume comments in
      # return annotation
      (if function.returnAnnotation.isSome: function.returnAnnotation.get.location.start
       else: function.location.stop),
    ))

  # Add return annotation
  if function.returnAnnotation.isSome:
    signature = signature
      .append(spaceRightArrowSpaceDocument)
      .append(self.typeAst(function.returnAnnotation.get))

  if function.body.len == 0:
    return docvec(attributes, signature.group)

  # Format body and add any trailing comments
  var body = self.statements(function.body)
  let comments = self.popComments(function.endPosition)
  let printed = printedComments(comments, false)
  if printed.isSome:
    body = body.append(lineDocument).append(printed.get)

  # Stick it all together
  let functionDoc = signature
    .append(spaceOpenCurlyDocument)
    .group
    .append(lineDocument.append(body).nest(INDENT).group)
    .append(lineDocument)
    .append(closeCurlyDocument)

  docvec(attributes, functionDoc)

proc exprFn(self: Formatter, arguments: seq[UntypedArg], returnAnnotation: Option[TypeAst],
            body: seq[UntypedStatement], location: SrcSpan, endOfHeadByteIndex: int): Document =
  var argumentsDocs: seq[Document]
  for argument in arguments: argumentsDocs.add self.fnArg(argument)
  let argumentsDoc = self
    .wrapArguments(argumentsDocs, endOfHeadByteIndex)
    .group
    .nextBreakFits(Disabled)
  #   ^^^ We add this so that when an expression function is passed as
  #       the last argument of a function and it goes over the line
  #       limit with just its arguments we don't get some strange
  #       splitting.
  #       See https://github.com/gleam-lang/gleam/issues/2571
  #
  # There's many ways we could be smarter than this. For example:
  #  - still split the arguments like it did in the example shown in the
  #    issue if the expr_fn has more than one argument
  #  - make sure that an anonymous function whose body is made up of a
  #    single expression doesn't get split (I think that could boil down
  #    to wrapping the body with a `next_break_fits(Disabled)`)
  #
  # These are some of the ways we could tweak the look of expression
  # functions in the future if people are not satisfied with it.

  var header = "fn".toDoc.append(argumentsDoc)

  if returnAnnotation.isSome:
    header = header
      .append(spaceRightArrowSpaceDocument)
      .append(self.typeAst(returnAnnotation.get))

  let statements = self.statements(body)
  let printed = printedComments(self.popComments(location.stop), false)
  let bodyDoc =
    if printed.isNone: statements
    else: statements.append(lineDocument).append(printed.get).forceBreak

  header.append(spaceDocument).append(wrapBlock(bodyDoc)).group

proc statements(self: Formatter, statements: seq[UntypedStatement]): Document =
  var previousPosition = 0
  let count = statements.len

  var documents = newSeqOfCap[Document](count * 2)
  for i, statement in statements:
    let precedingNewline = self.popEmptyLines(previousPosition + 1)
    if i != 0 and precedingNewline:
      documents.add twoLinesDocument
    elif i != 0:
      documents.add lineDocument
    previousPosition = statement.location.stop
    documents.add self.statement(statement).group

    # If the last statement is a use we make sure it's followed by a
    # todo to make it explicit it has an unimplemented callback.
    if statement.isUse and i == count - 1:
      documents.add lineDocument
      documents.add todoDocument

  if count == 1 and statements[0].isExpression:
    concat(documents)
  else:
    concat(documents).forceBreak

proc assignment(self: Formatter, assignment: UntypedAssignment): Document =
  let comments = self.popComments(assignment.location.start)

  discard self.popEmptyLines(assignment.pattern.location.stop)

  var keyword: Document
  var message = none(UntypedExpr)
  case assignment.kind.kind
  of akLet, akGenerated: keyword = letSpaceDocument
  of akAssert:
    keyword = letAssertSpaceDocument
    message = assignment.kind.vAssert.message

  let pattern = self.patternDoc(assignment.pattern)

  let annotation =
    if assignment.annotation.isSome: colonSpaceDocument.append(self.typeAst(assignment.annotation.get))
    else: emptyDocument

  let doc = keyword
    .append(pattern.append(annotation).group)
    .append(spaceEqualDocument)
    .append(self.assignedValue(assignment.value))

  commented(self.appendAsMessageExpression(doc, PrecedingAs.Expression, message), comments)

proc expr(self: Formatter, expression: UntypedExpr): Document =
  let comments = self.popComments(expression.startByteIndex)

  var document: Document
  case expression.kind
  of uePanic:
    document = self.appendAsMessageExpression(panicDocument, PrecedingAs.Keyword,
                                              unbox(expression.vPanic.message))

  of ueTodo:
    document = self.appendAsMessageExpression(todoDocument, PrecedingAs.Keyword,
                                              unbox(expression.vTodo.message))

  of ueEcho:
    document = self.echoDoc(expression.vEcho.expression, expression.vEcho.message)

  of uePipeline: document = self.pipeline(expression.vPipeline.expressions, false)

  of ueInt: document = self.intDoc(expression.vInt.value)

  of ueFloat: document = self.floatDoc(expression.vFloat.value)

  of ueString: document = self.stringDoc(expression.vString.value)

  of ueBlock:
    document = self.blockDoc(expression.vBlock.location, expression.vBlock.statements, false)

  of ueVar:
    if expression.vVar.name == CAPTURE_VARIABLE: document = underscoreDocument
    else: document = expression.vVar.name.toDoc

  of ueTupleIndex:
    document = self.tupleIndex(expression.vTupleIndex.tupl[], expression.vTupleIndex.index)

  of ueNegateInt: document = self.negateInt(expression.vNegateInt.value[])

  of ueNegateBool: document = self.negateBool(expression.vNegateBool.value[])

  of ueFn:
    if expression.vFn.kind.isCapture:
      document = self.fnCapture(expression.vFn.body, EverywhereElse)
    else:
      document = self.exprFn(
        expression.vFn.arguments,
        expression.vFn.returnAnnotation,
        expression.vFn.body,
        expression.vFn.location,
        expression.vFn.endOfHeadByteIndex,
      )

  of ueList:
    document = self.list(expression.vList.elements, unbox(expression.vList.tail), expression.vList.location)

  of ueCall:
    document = self.call(expression.vCall.fun[], expression.vCall.arguments, expression.vCall.location)

  of ueBinOp:
    document = self.binOp(expression.vBinOp.operator, expression.vBinOp.left[], expression.vBinOp.right[], false)

  of ueCase:
    document = self.caseDoc(
      expression.vCase.subjects,
      (if expression.vCase.clauses.isSome: expression.vCase.clauses.get else: @[]),
      expression.vCase.location,
    )

  of ueFieldAccess:
    document = self
      .expr(expression.vFieldAccess.container[])
      .append(dotDocument)
      .append(expression.vFieldAccess.label)

  of ueTuple: document = self.tupleDoc(expression.vTuple.elements, expression.vTuple.location)

  of ueBitArray:
    let segments = expression.vBitArray.segments
    let location = expression.vBitArray.location
    var segmentDocs: seq[Document]
    for segment in segments:
      segmentDocs.add bitArraySegment(segment, proc(segment: UntypedExpr): Document =
        self.bitArraySegmentExpr(segment))

    let packing = self.itemsSequencePacking(
      segments,
      none(SrcSpan),
      proc(segment: UntypedExprBitArraySegment): bool = segment.value[].canHaveMultiplePerLine,
      location,
    )

    document = self.bitArray(segmentDocs, packing, location)
  of ueRecordUpdate:
    document = self.recordUpdate(
      expression.vRecordUpdate.constructor[],
      expression.vRecordUpdate.record,
      expression.vRecordUpdate.arguments,
      expression.vRecordUpdate.location,
    )
  commented(document, comments)

proc stringDoc(self: Formatter, string: string): Document =
  let doc = string.toDoc.surround(doubleQuoteDocument, doubleQuoteDocument)
  if '\n' in string: doc.forceBreak
  else: doc

proc binOpString(self: Formatter, string: string): Document =
  let lines = string.split('\n')
  if lines.len <= 1:
    string.toDoc.surround(doubleQuoteDocument, doubleQuoteDocument)
  else:
    var doc = docvec(doubleQuoteDocument, lines[0])
    for i in 1 ..< lines.len:
      doc = doc.append(lineDocument.setNesting(0)).append(lines[i].toDoc)
    doc.append(doubleQuoteDocument).group

proc floatDoc(self: Formatter, value: string): Document =
  # Create parts
  let parts = value.split('.')
  let integerPart = parts[0]
  let floatingPart = if parts.len > 1: parts[1] else: ""
  let integerDoc = self.underscoreIntegerString(integerPart)
  # Split fp_part into a regular fractional and maybe a scientific part
  var splitAt = floatingPart.find('e')
  if splitAt < 0: splitAt = floatingPart.len
  var fractionalPart = floatingPart[0 ..< splitAt]
  let scientificPart = floatingPart[splitAt .. ^1]

  # Trim right any consequtive '0's
  fractionalPart = fractionalPart.strip(leading = false, trailing = true, chars = {'0'})
  # If there is no fractional part left, add a '0', thus that 1. becomes 1.0 etc.
  if fractionalPart.len == 0:
    fractionalPart.add '0'

  integerDoc.append(dotDocument).append(fractionalPart).append(scientificPart)

proc intDoc(self: Formatter, value: string): Document =
  let digits = value.strip(leading = true, trailing = false, chars = {'-'})
  if digits.startsWith("0x") or digits.startsWith("0b") or digits.startsWith("0o"):
    return value.toDoc

  self.underscoreIntegerString(value)

proc underscoreIntegerString(self: Formatter, value: string): Document =
  const underscore = '_'
  const minus = '-'

  let len = value.len
  let underscoreChCnt = value.count(underscore)
  let reformatWatershed = if value.startsWith(minus): 6 else: 5
  let insertUnderscores = (len - underscoreChCnt) >= reformatWatershed

  var newValue = ""
  var j = 0
  for i in 0 ..< len:
    let character = value[len - 1 - i]
    if character == underscore:
      continue

    if insertUnderscores and i != 0 and character != minus and i < len and j mod 3 == 0:
      newValue.add underscore
    newValue.add character

    j += 1

  newValue.reverse()
  newValue.toDoc

proc patternConstructor(self: Formatter, name: string, arguments: seq[CallArg[UntypedPattern]],
                        module: Option[(string, SrcSpan)], spread: Option[SrcSpan],
                        location: SrcSpan): Document =
  func isBreakable(expression: UntypedPattern): bool =
    case expression.kind
    of paTuple, paList, paBitArray: true
    of paConstructor: expression.vConstructor.arguments.len > 0
    of paInt, paFloat, paString, paVariable, paBitArraySize, paAssign, paDiscard, paStringPrefix,
        paInvalid: false

  let nameDoc =
    if module.isSome: module.get[0].toDoc.append(dotDocument).append(name)
    else: name.toDoc

  if arguments.len == 0 and spread.isSome:
    nameDoc.append(openParenDotDotCloseParenDocument)
  elif arguments.len == 0:
    nameDoc
  elif spread.isSome:
    var docs: seq[Document]
    for argument in arguments: docs.add self.patternCallArg(argument)
    nameDoc.append(self.wrapArgumentsWithSpread(docs, location.stop)).group
  else:
    if arguments.len == 1 and isBreakable(arguments[0].value):
      nameDoc
        .append(openParenDocument)
        .append(self.patternCallArg(arguments[0]))
        .append(closeParenDocument)
        .group
    else:
      var docs: seq[Document]
      for argument in arguments: docs.add self.patternCallArg(argument)
      nameDoc.append(self.wrapArguments(docs, location.stop)).group

proc call(self: Formatter, function: UntypedExpr, arguments: seq[CallArg[UntypedExpr]],
          location: SrcSpan): Document =
  let expression = case function.kind
    of uePipeline: breakBlock(self.expr(function))

    of ueBinOp, ueInt, ueFloat, ueString, ueBlock, ueVar, ueFn, ueList, ueCall, ueCase,
        ueFieldAccess, ueTuple, ueTupleIndex, ueTodo, ueEcho, uePanic, ueBitArray, ueRecordUpdate,
        ueNegateBool, ueNegateInt: self.expr(function)

  let arity = arguments.len
  self.appendInlinableWrappedArguments(
    expression,
    arguments,
    location,
    proc(argument: CallArg[UntypedExpr]): bool = isBreakableArgument(argument.value, arguments.len),
    proc(self: Formatter, argument: CallArg[UntypedExpr]): Document = self.callArg(argument, arity),
  )

proc tupleDoc(self: Formatter, elements: seq[UntypedExpr], location: SrcSpan): Document =
  if elements.len == 0:
    # We take all comments that come _before_ the end of the tuple,
    # that is all comments that are inside "#(" and ")", if there's
    # any comment we want to put it inside the empty tuple!
    let printed = printedComments(self.popComments(location.stop), false)
    if printed.isNone: return emptyTupleDocument
    return openTupleDocument
      .append(emptyBreakDocument.nest(INDENT))
      .append(printed.get)
      .append(emptyBreakDocument)
      .append(closeParenDocument)
      # vvv We want to make sure the comments are on a separate
      #     line from the opening and closing parentheses so we
      #     force the breaks to be split on newlines.
      .forceBreak

  self.appendInlinableWrappedArguments(
    hashtagDocument,
    elements,
    location,
    proc(expression: UntypedExpr): bool =
      not expression.isTuple and isBreakableArgument(expression, elements.len),
    proc(self: Formatter, expression: UntypedExpr): Document =
      self.commaSeparatedItem(expression, elements.len),
  )

# Appends to the given docs a comma-separated list of documents wrapped by
# parentheses. If the last item of the argument list is splittable the
# resulting document will try to first split that before splitting all the
# other arguments.
# This is used for function calls and tuples.
proc appendInlinableWrappedArguments[T](
    self: Formatter, doc: Document, values: seq[T], location: SrcSpan,
    isBreakableArgument: proc(value: T): bool,
    toDoc: proc(self: Formatter, value: T): Document): Document =
  if values.len > 0 and isBreakableArgument(values[^1]) and
      not self.anyComments(values[^1].location.start) and
      not self.anyCommentBetween(values[^1].location.stop, location.stop):
    var docs: seq[Document]
    for i in 0 ..< values.high: docs.add toDoc(self, values[i])

    let lastValueDoc = toDoc(self, values[^1]).group.nextBreakFits(Enabled)

    docs.add lastValueDoc

    doc.append(self.wrapFunctionCallArguments(docs, location))
      .nextBreakFits(Disabled)
      .group
  else:
    var docs: seq[Document]
    for value in values: docs.add toDoc(self, value)
    doc.append(self.wrapFunctionCallArguments(docs, location)).group

proc caseDoc*(self: Formatter, subjects: seq[UntypedExpr], clauses: seq[UntypedClause],
              location: SrcSpan): Document =
  var subjectDocs: seq[Document]
  for subject in subjects: subjectDocs.add self.expr(subject).group
  let subjectsDoc = caseBreakDocument
    .append(join(subjectDocs, commaBreakDocument))
    .nest(INDENT)
    .append(breakableSpaceDocument)
    .append(openCurlyDocument)
    .nextBreakFits(Disabled)
    .group

  var clauseDocs: seq[Document]
  for i, clause in clauses: clauseDocs.add self.clause(clause, i).group
  let clausesDoc = concat(clauseDocs)

  # We get all remaining comments that come before the case's closing
  # bracket. If there's any we add those before the closing bracket
  # instead of moving those out of the case expression.
  # Otherwise those would be moved out of the case expression.
  let comments = self.popComments(location.stop)
  let printed = printedComments(comments, false)
  let closingBracket =
    if printed.isNone: docvec(lineDocument, closeCurlyDocument)
    else:
      docvec(lineDocument, printed.get)
        .nest(INDENT)
        .append(lineDocument)
        .append(closeCurlyDocument)

  subjectsDoc
    .append(lineDocument.append(clausesDoc).nest(INDENT))
    .append(closingBracket)
    .forceBreak

proc recordUpdate*(self: Formatter, constructor: UntypedExpr, record: RecordBeingUpdated[UntypedExpr],
                   arguments: seq[UntypedRecordUpdateArg], location: SrcSpan): Document =
  let constructorDoc = self.expr(constructor)
  var pieces = @[UntypedRecordUpdatePiece(kind: rpRecord, record: record)]
  for argument in arguments: pieces.add UntypedRecordUpdatePiece(kind: rpArgument, argument: argument)

  self.appendInlinableWrappedArguments(
    constructorDoc,
    pieces,
    location,
    proc(argument: UntypedRecordUpdatePiece): bool =
      case argument.kind
      of rpArgument: isBreakableArgument(argument.argument.value, pieces.len)
      of rpRecord: isBreakableArgument(argument.record.base[], pieces.len),
    proc(this: Formatter, argument: UntypedRecordUpdatePiece): Document =
      case argument.kind
      of rpArgument: this.recordUpdateArg(argument.argument)
      of rpRecord:
        let comments = this.popComments(argument.record.location.start)
        commented(dotDotDocument.append(this.expr(argument.record.base[])), comments),
  )

proc constRecordUpdate*(self: Formatter, module: Option[(string, SrcSpan)], name: string,
                        record: RecordBeingUpdated[UntypedConstant],
                        arguments: seq[RecordUpdateArg[UntypedConstant]], location: SrcSpan): Document =
  let constructorDoc =
    if module.isSome: module.get[0].toDoc.append(dotDocument).append(name)
    else: name.toDoc

  var pieces = @[RecordUpdatePiece[UntypedConstant](kind: rpRecord, record: record)]
  for argument in arguments:
    pieces.add RecordUpdatePiece[UntypedConstant](kind: rpArgument, argument: argument)

  self.appendInlinableWrappedArguments(
    constructorDoc,
    pieces,
    location,
    proc(argument: RecordUpdatePiece[UntypedConstant]): bool =
      case argument.kind
      of rpArgument: isConstantBreakableArgument(argument.argument.value)
      of rpRecord: isConstantBreakableArgument(argument.record.base[]),
    proc(this: Formatter, argument: RecordUpdatePiece[UntypedConstant]): Document =
      case argument.kind
      of rpArgument: this.constantRecordUpdateArgument(argument.argument)
      of rpRecord:
        let comments = this.popComments(argument.record.location.start)
        commented(dotDotDocument.append(this.constExpr(argument.record.base[])), comments),
  )

proc binOp*(self: Formatter, name: BinOp, left, right: UntypedExpr, nestSteps: bool): Document =
  let leftSide = self.binOpSide(name, left, nestSteps)

  let comments = self.popComments(right.startByteIndex)
  let nameDoc = breakableSpaceDocument.append(commented(binop(name), comments))

  let rightSide = self.binOpSide(name, right, nestSteps)

  leftSide
    .append(if nestSteps: nameDoc.nest(INDENT) else: nameDoc)
    .append(spaceDocument)
    .append(rightSide)

proc constantBinaryOperator*(self: Formatter, name: BinOp, left, right: UntypedConstant,
                             nestSteps: bool): Document =
  let leftSide = self.constantBinaryOperatorSide(name, left, nestSteps)

  let comments = self.popComments(right.location.start)
  let nameDoc = breakableSpaceDocument.append(commented(binop(name), comments))

  let rightSide = self.constantBinaryOperatorSide(name, right, nestSteps)

  docvec(leftSide, (if nestSteps: nameDoc.nest(INDENT) else: nameDoc), spaceDocument, rightSide)

proc constantBinaryOperatorSide(self: Formatter, operator: BinOp, side: UntypedConstant,
                                nestSteps: bool): Document =
  let sideDoc = case side.kind
    of coString: self.binOpString(side.vString.value)
    of coBinaryOperator:
      self.constantBinaryOperator(side.vBinaryOperator.operator, side.vBinaryOperator.left[],
                                  side.vBinaryOperator.right[], nestSteps)
    of coInt, coFloat, coVar, coList, coTuple, coTodo, coBitArray, coInvalid, coRecord,
        coRecordUpdate: self.constExpr(side)
  let sideName = side.binOpName
  if sideName.isSome and sideName.get.canBeGroupedWith(operator):
    # In case the other side is a binary operation as well and it can
    # be grouped together with the current binary operation, the two
    # docs are simply concatenated, so that they will end up in the
    # same group and the formatter will try to keep those on a single
    # line.
    sideDoc
  else:
    # In case the binary operations cannot be grouped together the
    # other side is treated as a group on its own so that it can be
    # broken independently of other pieces of the binary operations
    # chain.
    self.operatorSide(sideDoc.group, operator.precedence, side.binOpPrecedence)

proc binOpSide(self: Formatter, operator: BinOp, side: UntypedExpr, nestSteps: bool): Document =
  let sideDoc = case side.kind
    of ueString: self.binOpString(side.vString.value)
    of ueBinOp:
      self.binOp(side.vBinOp.operator, side.vBinOp.left[], side.vBinOp.right[], nestSteps)
    of ueInt, ueFloat, ueBlock, ueVar, ueFn, ueList, ueCall, uePipeline, ueCase, ueFieldAccess,
        ueTuple, ueTupleIndex, ueTodo, uePanic, ueEcho, ueBitArray, ueRecordUpdate, ueNegateBool,
        ueNegateInt: self.expr(side)
  let sideName = side.binOpName
  if sideName.isSome and sideName.get.canBeGroupedWith(operator):
    # In case the other side is a binary operation as well and it can
    # be grouped together with the current binary operation, the two
    # docs are simply concatenated, so that they will end up in the
    # same group and the formatter will try to keep those on a single
    # line.
    sideDoc
  else:
    # In case the binary operations cannot be grouped together the
    # other side is treated as a group on its own so that it can be
    # broken independently of other pieces of the binary operations
    # chain.
    self.operatorSide(sideDoc.group, operator.precedence, side.binOpPrecedence)

proc operatorSide*(self: Formatter, doc: Document, op, side: uint8): Document =
  if op > side: wrapBlock(doc).group
  else: doc

proc spansMultipleLines(self: Formatter, start, stop: int): bool =
  # Upstream: a binary search that only asks whether there is one.
  var low = 0
  var high = self.newLines.high
  while low <= high:
    let mid = (low + high) div 2
    let newline = self.newLines[mid]
    if newline <= start: low = mid + 1
    elif newline >= stop: high = mid - 1
    else:
      # If the newline is in between the pipe start and end
      # then we've found it!
      return true
  # If we couldn't find any newline between the start and end of
  # the pipeline then we will try and keep it on a single line.
  false

proc hasTrailingComma(self: Formatter, start, stop: int): bool =
  ## Returns true if there's a trailing comma between `start` and `end`.
  var low = 0
  var high = self.trailingCommas.high
  while low <= high:
    let mid = (low + high) div 2
    let comma = self.trailingCommas[mid]
    if comma < start: low = mid + 1
    elif comma > stop: high = mid - 1
    else: return true
  false

proc pipeline(self: Formatter, expressions: seq[UntypedExpr], nestPipe: bool): Document =
  # We start by producing the document for the first step of the pipeline.
  let firstPrecedence = expressions[0].binOpPrecedence
  let first = self.expr(expressions[0]).group
  let firstStep = self.operatorSide(first, 5, firstPrecedence)

  # We then produce a doc for each item in the rest of the pipeline.
  let pipelineStart = expressions[0].location.start
  let pipelineEnd = expressions[^1].location.stop
  let tryToKeepOnOneLine = not self.spansMultipleLines(pipelineStart, pipelineEnd)
  let stepsSeparator = if tryToKeepOnOneLine: breakableSpaceDocument else: lineDocument

  var stops = @[firstStep]
  for i in 1 ..< expressions.len:
    let expression = expressions[i]
    # We start by producing the document for the pipe itself `|>`,
    # we also want to put comments before it!
    let comments = self.popComments(expression.location.start)
    let commentedPipe = commented(pipeSpaceDocument, comments)
    var pipe = docvec(stepsSeparator, commentedPipe)
    if nestPipe:
      pipe = pipe.nest(INDENT)

    # We then produce the document for the expression being piped into.
    var expressionDoc = self.expressionOnRightHandSideOfPipe(nestPipe, expression)
    expressionDoc = self.operatorSide(expressionDoc, 4, expression.binOpPrecedence)

    # And finally piece everything together.
    stops.add pipe.append(expressionDoc)

  if tryToKeepOnOneLine: concat(stops)
  else: concat(stops).forceBreak

proc expressionOnRightHandSideOfPipe(self: Formatter, nestPipe: bool, expression: UntypedExpr): Document =
  let doc =
    if expression.kind == ueFn and expression.vFn.kind.isCapture:
      self.fnCapture(expression.vFn.body, RightHandSideOfPipe)
    else:
      self.expr(expression)

  if nestPipe: doc.nest(INDENT)
  else: doc

proc fnCapture(self: Formatter, call: seq[UntypedStatement], position: FnCapturePosition): Document =
  # The body of a capture being multiple statements shouldn't be possible...
  if call.len != 1:
    raiseAssert "Function capture found not to have a single statement call"

  if not (call[0].kind == stExpression and call[0].vExpression.kind == ueCall):
    # The body of a capture being not a fn shouldn't be possible...
    raiseAssert "Function capture body found not to be a call in the formatter"
  let fun = call[0].vExpression.vCall.fun[]
  let arguments = call[0].vExpression.vCall.arguments
  let location = call[0].vExpression.vCall.location

  if arguments.len == 1 and arguments[0].isCaptureHole and arguments[0].label.isNone:
    # The capture has a single unlabelled hole:
    #
    #     wibble |> wobble(_)
    #     list.map([], wobble(_))
    #
    # We want these to become:
    #
    #     wibble |> wobble
    #     list.map([], wobble)
    #
    self.expr(fun)
  elif position == RightHandSideOfPipe and arguments.len >= 1 and arguments[0].isCaptureHole and
      arguments[0].label.isNone:
    # The capture is on the right hand side of a pipe and its first
    # argument it an unlabelled capture hole:
    #
    #     wibble |> wobble(_, woo)
    #
    # We want it to become:
    #
    #     wibble |> wobble(woo)
    #
    let expression = self.expr(fun)
    let rest = arguments[1 .. ^1]
    let arity = rest.len
    self.appendInlinableWrappedArguments(
      expression,
      rest,
      location,
      proc(argument: CallArg[UntypedExpr]): bool = isBreakableArgument(argument.value, rest.len),
      proc(self: Formatter, argument: CallArg[UntypedExpr]): Document = self.callArg(argument, arity),
    )
  else:
    # In all other cases we print it like a regular function call
    # without changing it.
    #
    let expression = self.expr(fun)
    let arity = arguments.len
    self.appendInlinableWrappedArguments(
      expression,
      arguments,
      location,
      proc(argument: CallArg[UntypedExpr]): bool = isBreakableArgument(argument.value, arguments.len),
      proc(self: Formatter, argument: CallArg[UntypedExpr]): Document = self.callArg(argument, arity),
    )

proc recordConstructor*[A](self: Formatter, constructor: RecordConstructor[A]): Document =
  let comments = self.popComments(constructor.location.start)
  let docComments = self.docCommentsDoc(constructor.location.start)
  let attributes = AttributesPrinter.new
    .setDeprecation(constructor.deprecation)
    .toDoc

  var doc: Document
  if constructor.arguments.len == 0:
    if self.anyComments(constructor.location.stop):
      doc = attributes
        .append(constructor.name.toDoc)
        .append(self.wrapArguments(@[], constructor.location.stop))
        .group
    else:
      doc = attributes.append(constructor.name.toDoc)
  else:
    var arguments: seq[Document]
    for arg in constructor.arguments:
      let argComments = self.popComments(arg.location.start)
      let argument =
        if arg.label.isSome:
          arg.label.get[1].toDoc.append(colonSpaceDocument).append(self.typeAst(arg.ast))
        else:
          self.typeAst(arg.ast)

      arguments.add commented(
        self.docCommentsDoc(arg.location.start).append(argument).group,
        argComments,
      )

    doc = attributes
      .append(constructor.name.toDoc)
      .append(self.wrapArguments(arguments, constructor.location.stop).group)

  commented(docComments.append(doc).group, comments)

proc customType*[A](self: Formatter, typ: CustomType[A]): Document =
  discard self.popEmptyLines(typ.location.stop)

  let attributes = AttributesPrinter.new
    .setDeprecation(typ.deprecation)
    .setInternal(typ.publicity)
    .setExternalErlang(typ.externalErlang)
    .setExternalJavascript(typ.externalJavascript)
    .toDoc

  var doc = attributes
    .append(pubDoc(typ.publicity))
    .append(if typ.opaque: opaqueTypeSpaceDocument else: typeSpaceDocument)
  if typ.parameters.len == 0:
    doc = doc.append(typ.name.toDoc)
  else:
    var arguments: seq[Document]
    for (_, e) in typ.parameters: arguments.add e.toDoc
    doc = doc.append(typ.name.toDoc.append(self.wrapArguments(arguments, typ.location.stop)).group)

  if typ.constructors.len == 0:
    return doc
  doc = doc.append(spaceOpenCurlyDocument)

  var constructorDocs: seq[Document]
  for c in typ.constructors:
    let separator = if self.popEmptyLines(c.location.start): twoLinesDocument else: lineDocument
    constructorDocs.add separator.append(self.recordConstructor(c))
  var inner = concat(constructorDocs)

  # Add any trailing comments
  let printed = printedComments(self.popComments(typ.endPosition), false)
  if printed.isSome:
    inner = inner.append(lineDocument).append(printed.get)
  inner = inner.nest(INDENT).group

  doc.append(inner).append(lineDocument).append(closeCurlyDocument)

proc callArg(self: Formatter, argument: CallArg[UntypedExpr], arity: int): Document =
  self.formatCallArg(argument, exprCallArgFormatting,
    proc(this: Formatter, value: UntypedExpr): Document = this.commaSeparatedItem(value, arity))

proc formatCallArg[A](self: Formatter, argument: CallArg[A],
                      figureFormatting: proc(argument: CallArg[A]): CallArgFormatting[A],
                      formatValue: proc(self: Formatter, value: A): Document): Document =
  let formatting = figureFormatting(argument)
  case formatting.kind
  of cfUnlabelled: formatValue(self, formatting.value)
  of cfShorthandLabelled:
    let comments = self.popComments(argument.location.start)
    let label = formatting.label.toDoc.append(colonDocument)
    commented(label, comments)
  of cfLabelled:
    let comments = self.popComments(argument.location.start)
    let label = formatting.label.toDoc.append(colonSpaceDocument)
    let value = formatValue(self, formatting.value)
    commented(label, comments).append(value)

proc recordUpdateArg(self: Formatter, argument: UntypedRecordUpdateArg): Document =
  let comments = self.popComments(argument.location.start)
  if argument.usesLabelShorthand:
    # Argument supplied with a label shorthand.
    commented(argument.label.toDoc.append(colonDocument), comments)
  else:
    # Labelled argument.
    let doc = argument.label.toDoc.append(colonSpaceDocument).append(self.expr(argument.value)).group

    if argument.value.isBinop or argument.value.isPipeline: commented(doc, comments).nest(INDENT)
    else: commented(doc, comments)

proc constantRecordUpdateArgument(self: Formatter, argument: RecordUpdateArg[UntypedConstant]): Document =
  let comments = self.popComments(argument.location.start)
  if argument.usesLabelShorthand:
    # Argument supplied with a label shorthand.
    commented(argument.label.toDoc.append(colonDocument), comments)
  else:
    # Labelled argument.
    let doc =
      argument.label.toDoc.append(colonSpaceDocument).append(self.constExpr(argument.value)).group

    if argument.value.isBinop: commented(doc, comments).nest(INDENT)
    else: commented(doc, comments)

proc tupleIndex(self: Formatter, tupl: UntypedExpr, index: uint64): Document =
  # In case we have a block with a single variable tuple access we
  # remove that redundant wrapper:
  #
  #     {tuple.1}.0 becomes
  #     tuple.1.0
  #
  var inner = tupl
  if tupl.kind == ueBlock:
    let statements = tupl.vBlock.statements
    # We can't apply this change if the inner thing is a
    # literal tuple because the compiler cannot currently parse
    # it:  `#(1, #(2, 3)).1.0` is a syntax error at the moment.
    if statements.len == 1 and statements[0].kind == stExpression and
        statements[0].vExpression.kind == ueTupleIndex and
        not statements[0].vExpression.vTupleIndex.tupl[].isTuple:
      inner = statements[0].vExpression
  self.expr(inner).append(dotDocument).append(index)

proc caseClauseValue(self: Formatter, expression: UntypedExpr): Document =
  var doc: Document
  case expression.kind
  of ueFn, ueList, ueTuple, ueBitArray:
    let expressionComments = self.popComments(expression.location.start)
    let expressionDoc = self.expr(expression)
    let printed = printedComments(expressionComments, true)
    if printed.isSome: doc = lineDocument.append(printed.get).append(expressionDoc).nest(INDENT)
    else: doc = spaceDocument.append(expressionDoc)

  of ueCase: doc = lineDocument.append(self.expr(expression)).nest(INDENT)

  of ueBlock:
    doc = spaceDocument.append(
      self.blockDoc(expression.vBlock.location, expression.vBlock.statements, true)
    )

  of ueInt, ueFloat, ueString, ueVar, ueCall, ueBinOp, uePipeline, ueFieldAccess, ueTupleIndex,
     ueTodo, uePanic, ueEcho, ueRecordUpdate, ueNegateBool, ueNegateInt:
    doc = breakableSpaceDocument.append(self.expr(expression).group).nest(INDENT)

  doc.nextBreakFits(Disabled).group

proc assignedValue(self: Formatter, expression: UntypedExpr): Document =
  case expression.kind
  of ueCase: spaceDocument.append(self.expr(expression)).group
  of ueInt, ueFloat, ueString, ueBlock, ueVar, ueFn, ueList, ueCall, ueBinOp, uePipeline,
     ueFieldAccess, ueTuple, ueTupleIndex, ueTodo, uePanic, ueEcho, ueBitArray, ueRecordUpdate,
     ueNegateBool, ueNegateInt:
    self.caseClauseValue(expression)

proc clause(self: Formatter, clause: UntypedClause, index: int): Document =
  let spaceBefore = self.popEmptyLines(clause.location.start)
  let comments = self.popComments(clause.location.start)

  var clauseDoc = self.alternativePatterns(clause)
  if clause.guard.isSome:
    clauseDoc = clauseDoc
      .append(breakableSpaceDocument.nest(INDENT))
      .append(ifSpaceDocument)
      .append(self.clauseGuard(clause.guard.get).group.nest(INDENT))

  # In case there's a guard or multiple subjects, if we decide to break
  # the patterns on multiple lines we also want the arrow to end up on
  # its own line to improve legibility.
  #
  # This looks like this:
  # ```gleam
  # case wibble, wobble {
  #   Wibble(_),  // pretend this goes over the line limit
  #     Wobble(_)
  #   -> todo
  #   // Notice how the arrow is broken on its own line, the same goes
  #   // for patterns with `if` guards.
  # }
  # ```

  let hasGuard = clause.guard.isSome
  let hasMultipleSubjects = clause.pattern.len > 1
  let arrowBreak = if hasGuard or hasMultipleSubjects: breakableSpaceDocument else: spaceDocument

  clauseDoc = docvec(clauseDoc, arrowBreak, rightArrowDocument).group
    .append(self.caseClauseValue(clause.then))
    .group

  let printed = printedComments(comments, false)
  if printed.isSome: clauseDoc = printed.get.append(lineDocument).append(clauseDoc)

  if index == 0: clauseDoc
  elif spaceBefore: twoLinesDocument.append(clauseDoc)
  else: lineDocument.append(clauseDoc)

proc alternativePatterns(self: Formatter, clause: UntypedClause): Document =
  let hasGuard = clause.guard.isSome
  let hasMultipleSubjects = clause.pattern.len > 1

  # In case there's an `if` guard but no multiple subjects we want to add
  # additional indentation before the vartical bar separating alternative
  # patterns `|`.
  # We're not adding the indentation if there's multiple subjects as that
  # would make things harder to read, aligning the vertical bar with the
  # different subjects:
  # ```
  # case wibble, wobble {
  #   Wibble,
  #     Wobble
  #     | Wibble, // <- we don't want this indentation!
  #     Wobble -> todo
  # }
  # ```
  let alternativesSeparator =
    if hasGuard and not hasMultipleSubjects:
      breakableSpaceDocument.nest(INDENT).append(verticalBarSpaceDocument)
    else:
      breakableSpaceDocument.append(verticalBarSpaceDocument)

  var alternativeDocs: seq[Document]
  for alternativeIndex, patterns in @[clause.pattern] & clause.alternativePatterns:
    # Here `patterns` is a single pattern that can be comprised of
    # multiple subjects.
    # ```gleam
    # case wibble, wobble {
    #   True, False
    # //^^^^^^^^^^^ This is a single pattern with multiple subjects
    #   | _, _ -> todo
    # }
    # ```
    let isFirstAlternative = alternativeIndex == 0
    var patternDocs: seq[Document]
    for patternIndex, pattern in patterns:
      # There's a small catch in turning each subject into a document.
      # Sadly we can't simply call `self.pattern` on each subject and
      # then nest each one in case it gets broken.
      # The first ever pattern that appears in a case clause (that is
      # the first subject of the first alternative) must not be nested
      # further; otherwise, when broken, it would have 2 extra spaces
      # of indentation: https://github.com/gleam-lang/gleam/issues/2940.
      let isFirstPattern = patternIndex == 0
      let isFirstPatternOfClause = isFirstPattern and isFirstAlternative
      let patternDoc = self.patternDoc(pattern)
      if isFirstPatternOfClause: patternDocs.add patternDoc
      else: patternDocs.add patternDoc.nest(INDENT)
    # We join all subjects with a breakable comma (that's also
    # going to be nested) and make the subjects into a group to
    # make sure the formatter tries to keep them on a single line.
    alternativeDocs.add join(patternDocs, commaBreakDocument.nest(INDENT)).group
  join(alternativeDocs, alternativesSeparator)

proc list(self: Formatter, elements: seq[UntypedExpr], tail: Option[UntypedExpr],
          location: SrcSpan): Document =
  if elements.len == 0:
    if tail.isSome: return self.expr(tail.get)
    # We take all comments that come _before_ the end of the list,
    # that is all comments that are inside "[" and "]", if there's
    # any comment we want to put it inside the empty list!
    let comments = self.popComments(location.stop)
    let printed = printedComments(comments, false)
    if printed.isNone: return openCloseSquareDocument
    return openSquareDocument
      .append(emptyBreakDocument.nest(INDENT))
      .append(printed.get)
      .append(emptyBreakDocument)
      .append(closeSquareDocument)
      # vvv We want to make sure the comments are on a separate
      #     line from the opening and closing brackets so we
      #     force the breaks to be split on newlines.
      .forceBreak

  let listPacking = self.itemsSequencePacking(
    elements,
    (if tail.isSome: some(tail.get.location) else: none(SrcSpan)),
    proc(element: UntypedExpr): bool = element.canHaveMultiplePerLine,
    location,
  )

  let comma = case listPacking
    of FitMultiplePerLine: flexCommaDocument
    of FitOnePerLine, BreakOnePerLine: commaBreakDocument

  let listSize = elements.len + (if tail.isSome: 1 else: 0)

  var isEmpty = true
  var elementsDoc = emptyDocument
  for element in elements:
    let emptyLines = self.popEmptyLines(element.location.start)
    let elementDoc = self.commaSeparatedItem(element, listSize)

    if isEmpty:
      isEmpty = false
      elementsDoc = elementDoc
    elif emptyLines:
      # If there's empty lines before the list item we want to add an
      # empty line here. Notice how we're making sure no nesting is
      # added after the comma, otherwise we would be adding needless
      # whitespace in the empty line!
      elementsDoc = docvec(elementsDoc, comma.setNesting(0), lineDocument, elementDoc)
    else:
      elementsDoc = docvec(elementsDoc, comma, elementDoc)
  elementsDoc = elementsDoc.nextBreakFits(Disabled)

  var doc = openSquareBreakDocument.append(elementsDoc)
  # We need to keep the last break aside and do not add it immediately
  # because in case there's a final comment before the closing square
  # bracket we want to add indentation (to just that break). Otherwise,
  # the final comment would be less indented than list's elements.
  var lastBreak: Document
  if tail.isNone:
    doc = doc.nest(INDENT)
    lastBreak = trailingCommaBreakDocument
  else:
    let comments = self.popComments(tail.get.location.start)
    let tailDoc = commented(docvec(dotDotDocument, self.expr(tail.get)), comments)
    doc = doc.append(commaBreakDocument).append(tailDoc).nest(INDENT)
    lastBreak = emptyBreakDocument

  # We get all remaining comments that come before the list's closing
  # square bracket.
  # If there's any we add those before the closing square bracket instead
  # of moving those out of the list.
  # Otherwise those would be moved out of the list.
  let comments = self.popComments(location.stop)
  let printed = printedComments(comments, false)
  if printed.isNone:
    doc = doc.append(lastBreak).append(closeSquareDocument)
  else:
    doc = doc
      .append(lastBreak.nest(INDENT))
      # ^ See how here we're adding the missing indentation to the
      #   final break so that the final comment is as indented as the
      #   list's items.
      .append(printed.get)
      .append(lineDocument)
      .append(closeSquareDocument)
      .forceBreak

  case listPacking
  of FitOnePerLine, FitMultiplePerLine: doc.group
  of BreakOnePerLine: doc.forceBreak

proc itemsSequencePacking[T](self: Formatter, items: seq[T], tail: Option[SrcSpan],
                             canHaveMultiplePerLine: proc(item: T): bool,
                             listLocation: SrcSpan): ItemsPacking =
  ## Upstream takes the tail itself; only its location is ever used.
  var locations: seq[SrcSpan]
  for item in items: locations.add item.location

  let lastElementEnd =
    if tail.isSome: some(tail.get.stop)
    elif locations.len > 0: some(locations[^1].stop)
    else: none(int)
  let endsWithTrailingComma =
    lastElementEnd.isSome and self.hasTrailingComma(lastElementEnd.get, listLocation.stop)

  let hasMultipleElementsPerLine =
    self.hasItemsOnTheSameLine(if tail.isSome: locations & @[tail.get] else: locations)

  var hasEmptyLinesBetweenElements = false
  if locations.len > 0 and self.emptyLinesStart < self.emptyLines.len:
    let emptyLine = self.emptyLines[self.emptyLinesStart]
    hasEmptyLinesBetweenElements = emptyLine >= locations[0].stop and emptyLine < locations[^1].start

  var allCanHaveMultiplePerLine = true
  for item in items:
    if not canHaveMultiplePerLine(item):
      allCanHaveMultiplePerLine = false
      break

  if hasEmptyLinesBetweenElements:
    # If there's any empty line between elements we want to force each
    # item onto its own line to preserve the empty lines that were
    # intentionally added.
    BreakOnePerLine
  elif not endsWithTrailingComma:
    # If the list doesn't end with a trailing comma we try and pack it in
    # a single line; if we can't we'll put one item per line, no matter
    # the content of the list.
    FitOnePerLine
  elif tail.isNone and allCanHaveMultiplePerLine and hasMultipleElementsPerLine and
      self.spansMultipleLines(listLocation.start, listLocation.stop):
    # If there's a trailing comma, we can have multiple items per line,
    # and there's already multiple items per line, we try and pack as
    # many items as possible on each line.
    #
    # Note how we only ever try and pack lists where all items are
    # unbreakable primitives. To pack a list we need to use put
    # `flex_break`s between each item.
    # If the items themselves had breaks we could end up in a situation
    # where an item gets broken making it span multiple lines and the
    # spaces are not, for example:
    #
    # ```gleam
    # [Constructor("wibble", "lorem ipsum dolor sit amet something something"), Other(1)]
    # ```
    #
    # If we used flex breaks here the list would be formatted as:
    #
    # ```gleam
    # [
    #   Constructor(
    #     "wibble",
    #     "lorem ipsum dolor sit amet something something",
    #   ), Other(1)
    # ]
    # ```
    #
    # The first item is broken, meaning that once we get to the flex
    # space separating it from the following one the formatter is not
    # going to break it since there's enough space in the current line!
    FitMultiplePerLine
  else:
    # If it ends with a trailing comma we will force the list on
    # multiple lines, with one item per line.
    BreakOnePerLine

proc hasItemsOnTheSameLine(self: Formatter, items: seq[SrcSpan]): bool =
  ## Upstream takes the items; only their locations are used.
  for i in 1 ..< items.len:
    # A list has multiple items on the same line if two consecutive
    # ones do not span multiple lines.
    if not self.spansMultipleLines(items[i - 1].stop, items[i].start): return true
  false

proc commaSeparatedItem(self: Formatter, expression: UntypedExpr, siblings: int): Document =
  ## Pretty prints an expression to be used in a comma separated list; for
  ## example as a list item, a tuple item or as an argument of a function call.
  # If there's more than one item in the comma separated list and there's a
  # pipeline or long binary chain, we want to indent those to make it
  # easier to tell where one item ends and the other starts.
  # Othewise we just print the expression as a normal expr.
  if expression.kind == ueBinOp and siblings > 1:
    let comments = self.popComments(expression.startByteIndex)
    let doc = self.binOp(expression.vBinOp.operator, expression.vBinOp.left[],
                         expression.vBinOp.right[], true).group
    commented(doc, comments)
  elif expression.kind == uePipeline and siblings > 1:
    let comments = self.popComments(expression.startByteIndex)
    let doc = self.pipeline(expression.vPipeline.expressions, true).group
    commented(doc, comments)
  else:
    self.expr(expression).group

proc commaSeparatedConstantItem(self: Formatter, constant: UntypedConstant, siblings: int): Document =
  ## Pretty prints an expression to be used in a comma separated list; for
  ## example as a list item, a tuple item or as an argument of a function call.
  # If there's more than one item in the comma separated list and there's a
  # pipeline or long binary chain, we want to indent those to make it
  # easier to tell where one item ends and the other starts.
  # Othewise we just print the expression as a normal expr.
  if constant.kind == coBinaryOperator and siblings > 1:
    let comments = self.popComments(constant.location.start)
    let doc = self.constantBinaryOperator(
      constant.vBinaryOperator.operator, constant.vBinaryOperator.left[],
      constant.vBinaryOperator.right[], true,
    ).group
    commented(doc, comments)
  else:
    self.constExpr(constant).group

proc patternDoc(self: Formatter, pattern: UntypedPattern): Document =
  let comments = self.popComments(pattern.location.start)
  var doc: Document
  case pattern.kind
  of paInt: doc = self.intDoc(pattern.vInt.value)

  of paFloat: doc = self.floatDoc(pattern.vFloat.value)

  of paString: doc = self.stringDoc(pattern.vString.value)

  of paVariable: doc = pattern.vVariable.name.toDoc

  of paBitArraySize: doc = self.bitArraySize(pattern.vBitArraySize)

  of paAssign:
    if pattern.vAssign.pattern[].isDiscard: doc = pattern.vAssign.name.toDoc
    else:
      doc = self.patternDoc(pattern.vAssign.pattern[])
        .append(spaceAsSpaceDocument)
        .append(pattern.vAssign.name)

  of paDiscard: doc = pattern.vDiscard.name.toDoc

  of paList: doc = self.listPattern(pattern.vList.elements, pattern.vList.tail)

  of paConstructor:
    doc = self.patternConstructor(
      pattern.vConstructor.name,
      pattern.vConstructor.arguments,
      pattern.vConstructor.module,
      pattern.vConstructor.spread,
      pattern.vConstructor.location,
    )

  of paTuple:
    var arguments: seq[Document]
    for element in pattern.vTuple.elements: arguments.add self.patternDoc(element)
    doc = "#".toDoc.append(self.wrapArguments(arguments, pattern.vTuple.location.stop)).group

  of paBitArray:
    var segmentDocs: seq[Document]
    for segment in pattern.vBitArray.segments:
      segmentDocs.add bitArraySegment(segment, proc(pattern: UntypedPattern): Document =
        self.patternDoc(pattern))

    doc = self.bitArray(segmentDocs, FitOnePerLine, pattern.vBitArray.location)

  of paStringPrefix:
    let left = self.stringDoc(pattern.vStringPrefix.leftSideString)
    let right = pattern.vStringPrefix.rightSideAssignment.name.toDoc
    let leftAssignment = pattern.vStringPrefix.leftSideAssignment
    if leftAssignment.isSome:
      doc = docvec(left, spaceAsSpaceDocument, leftAssignment.get.name, spaceConcatSpaceDocument, right)
    else:
      doc = docvec(left, spaceConcatSpaceDocument, right)

  of paInvalid: raiseAssert "invalid patterns can not be in an untyped ast"
  commented(doc, comments)

proc bitArraySize(self: Formatter, size: BitArraySize[Unit]): Document =
  case size.kind
  of bsInt: self.intDoc(size.vInt.value)
  of bsVariable: size.vVariable.name.toDoc
  of bsBinaryOperator:
    let operator = case size.vBinaryOperator.operator
      of ioAdd: spacePlusSpaceDocument
      of ioSubtract: spaceMinusSpaceDocument
      of ioMultiply: spaceTimesSpaceDocument
      of ioDivide: spaceSlashSpaceDocument
      of ioRemainder: spaceModuleSpaceDocument

    let left = self.bitArraySize(size.vBinaryOperator.left[])
    docvec(left, operator, self.bitArraySize(size.vBinaryOperator.right[]))
  of bsBlock:
    self.bitArraySize(size.vBlock.inner[]).surround(openCurlySpaceDocument, spaceCloseCurlyDocument)

proc listPattern(self: Formatter, elements: seq[UntypedPattern],
                 tail: Option[ref UntypedTailPattern]): Document =
  if elements.len == 0:
    if tail.isSome: return self.patternDoc(tail.get.pattern)
    return openCloseSquareDocument

  var elementDocs: seq[Document]
  for element in elements: elementDocs.add self.patternDoc(element)
  var doc = openSquareBreakDocument.append(join(elementDocs, commaBreakDocument))
  if tail.isNone:
    doc = doc.nest(INDENT).append(trailingCommaBreakDocument)
  else:
    let tailPattern = tail.get.pattern
    let comments = self.popComments(tailPattern.location.start)
    var tailDoc =
      if tailPattern.isDiscard: dotDotDocument
      else: docvec(dotDotDocument, self.patternDoc(tailPattern))
    tailDoc = commented(tailDoc, comments)
    doc = doc.append(commaBreakDocument).append(tailDoc).nest(INDENT).append(emptyBreakDocument)
  doc.append("]").group

proc patternCallArg(self: Formatter, argument: CallArg[UntypedPattern]): Document =
  self.formatCallArg(argument, patternCallArgFormatting,
    proc(this: Formatter, value: UntypedPattern): Document = this.patternDoc(value))

proc clauseGuardBinOp*(self: Formatter, name: BinOp, left, right: UntypedClauseGuard): Document =
  let leftComments = self.popComments(left.location.start)
  var leftDoc = self.clauseGuardBinOpSide(name, left, left.precedence)
  leftDoc = commented(leftDoc, leftComments)

  let rightComments = self.popComments(right.location.start)
  var rightDoc = self.clauseGuardBinOpSide(name, right, right.precedence - 1)
  rightDoc = docvec(binop(name), spaceDocument, rightDoc)
  rightDoc = commented(rightDoc, rightComments)

  leftDoc.append(breakableSpaceDocument).append(rightDoc)

proc clauseGuardBinOpSide(self: Formatter, name: BinOp, side: UntypedClauseGuard,
                          sidePrecedence: uint8): Document =
  # As opposed to `bin_op_side`, here we take the side precedence as an
  # argument instead of computing it ourselves. That's because
  # `clause_guard_bin_op` will reduce the precedence of any right side to
  # make sure the formatter doesn't remove any needed curly bracket.
  let sideDoc = self.clauseGuard(side)
  let sideName = side.binOpName
  if sideName.isSome and sideName.get.canBeGroupedWith(name):
    # In case the other side is a binary operation as well and it can
    # be grouped together with the current binary operation, the two
    # docs are simply concatenated, so that they will end up in the
    # same group and the formatter will try to keep those on a single
    # line.
    self.operatorSide(sideDoc, name.precedence, sidePrecedence)
  else:
    # In case the binary operations cannot be grouped together the
    # other side is treated as a group on its own so that it can be
    # broken independently of other pieces of the binary operations
    # chain.
    self.operatorSide(sideDoc.group, name.precedence, sidePrecedence)

proc clauseGuard(self: Formatter, clauseGuard: UntypedClauseGuard): Document =
  case clauseGuard.kind
  of cgInvalid: raiseAssert "invalid guard made it to formatting"

  of cgBinaryOperator:
    self.clauseGuardBinOp(
      clauseGuard.vBinaryOperator.operator,
      clauseGuard.vBinaryOperator.left[],
      clauseGuard.vBinaryOperator.right[],
    )

  of cgVar: clauseGuard.vVar.name.toDoc

  of cgTupleIndex:
    self.clauseGuard(clauseGuard.vTupleIndex.tupl[])
      .append(dotDocument)
      .append(clauseGuard.vTupleIndex.index)

  of cgFieldAccess:
    self.clauseGuard(clauseGuard.vFieldAccess.container[])
      .append(dotDocument)
      .append(clauseGuard.vFieldAccess.label)

  of cgModuleSelect:
    clauseGuard.vModuleSelect.moduleName.toDoc
      .append(dotDocument)
      .append(clauseGuard.vModuleSelect.label)

  of cgConstant: self.constExpr(clauseGuard.vConstant)

  of cgNot: docvec(exclamationMarkDocument, self.clauseGuard(clauseGuard.vNot.expression[]))

  of cgBlock: wrapBlock(self.clauseGuard(clauseGuard.vBlock.value[])).group

proc constantCallArg(self: Formatter, argument: CallArg[UntypedConstant]): Document =
  self.formatCallArg(argument, constantCallArgFormatting,
    proc(this: Formatter, value: UntypedConstant): Document = this.constExpr(value))

proc negateBool(self: Formatter, expression: UntypedExpr): Document =
  case expression.kind
  of ueNegateBool: self.expr(expression.vNegateBool.value[])
  of ueBinOp:
    let doc = self.expr(expression)

    exclamationMarkDocument.append(wrapBlock(doc))
  of ueInt, ueFloat, ueString, ueBlock, ueVar, ueFn, ueList, ueCall, uePipeline, ueCase,
     ueFieldAccess, ueTuple, ueTupleIndex, ueTodo, uePanic, ueEcho, ueBitArray, ueRecordUpdate,
     ueNegateInt:
    docvec(exclamationMarkDocument, self.expr(expression))

proc negateInt(self: Formatter, expression: UntypedExpr): Document =
  case expression.kind
  of ueNegateInt: self.expr(expression.vNegateInt.value[])
  of ueBinOp: minusSpaceDocument.append(self.expr(expression))
  of ueInt, ueFloat, ueString, ueBlock, ueVar, ueFn, ueList, ueCall, uePipeline, ueCase,
     ueFieldAccess, ueTuple, ueTupleIndex, ueTodo, uePanic, ueEcho, ueBitArray, ueRecordUpdate,
     ueNegateBool:
    if expression.kind == ueInt and expression.vInt.value.startsWith('-'):
      self.intDoc(expression.vInt.value[1 .. ^1])
    else:
      docvec(subIntDocument, self.expr(expression))

proc useDoc(self: Formatter, use: UntypedUse): Document =
  let comments = self.popComments(use.location.start)

  let call = (
    if use.call[].isCall: docvec(spaceDocument, self.expr(use.call[]))
    else: docvec(breakableSpaceDocument, self.expr(use.call[])).nest(INDENT)
  ).group

  var doc: Document
  if use.assignments.len == 0:
    doc = docvec(useAndArrowDocument, call)
  else:
    var left = @[useDocument, breakableSpaceDocument]
    for i, useAssignment in use.assignments:
      if i > 0: left.add commaBreakDocument
      let pattern = self.patternDoc(useAssignment.pattern)
      let annotation =
        if useAssignment.annotation.isSome:
          colonSpaceDocument.append(self.typeAst(useAssignment.annotation.get))
        else: emptyDocument

      left.add pattern.append(annotation).group
    let leftDoc = concat(left).nest(INDENT).append(breakableSpaceDocument).group
    doc = docvec(leftDoc, leftArrowDocument, call).group

  commented(doc, comments)

proc assertDoc(self: Formatter, assert: UntypedAssert): Document =
  let comments = self.popComments(assert.location.start)

  let expression =
    if assert.value.isBinop or assert.value.isPipeline: self.expr(assert.value).nest(INDENT)
    else: self.expr(assert.value)

  let doc = self.appendAsMessageExpression(expression, PrecedingAs.Expression, assert.message)
  commented(docvec(assertSpaceDocument, doc), comments)

proc bitArray(self: Formatter, segments: seq[Document], packing: ItemsPacking,
              location: SrcSpan): Document =
  let comments = self.popComments(location.stop)
  let commentsDoc = printedComments(comments, false)

  # Avoid adding illegal comma in empty bit array by explicitly handling it
  if segments.len == 0:
    # We take all comments that come _before_ the end of the bit array,
    # that is all comments that are inside "<<" and ">>", if there's
    # any comment we want to put it inside the empty bit array!
    # Refer to the `list` function for a similar procedure.
    if commentsDoc.isNone: return emptyBitArrayDocument
    return openBitArrayDocument
      .append(emptyBreakDocument.nest(INDENT))
      .append(commentsDoc.get)
      .append(emptyBreakDocument)
      .append(closeBitArrayDocument)
      # vvv We want to make sure the comments are on a separate
      #     line from the opening and closing angle brackets so
      #     we force the breaks to be split on newlines.
      .forceBreak

  let comma = case packing
    of FitMultiplePerLine: flexCommaDocument
    of FitOnePerLine, BreakOnePerLine: commaBreakDocument

  let lastBreak = trailingCommaBreakDocument
  var doc = openBitArrayBreakDocument.append(join(segments, comma)).nest(INDENT)

  if commentsDoc.isNone:
    doc = doc.append(lastBreak).append(closeBitArrayDocument)
  else:
    doc = doc
      .append(lastBreak.nest(INDENT))
      # ^ Notice how in this case we nest the final break before
      #   adding it: this way the comments are going to be as
      #   indented as the bit array items.
      .append(commentsDoc.get.nest(INDENT))
      .append(lineDocument)
      .append(closeBitArrayDocument)
      .forceBreak

  case packing
  of FitOnePerLine, FitMultiplePerLine: doc.group
  of BreakOnePerLine: doc.forceBreak

proc bitArraySegmentExpr(self: Formatter, expression: UntypedExpr): Document =
  case expression.kind
  of ueBinOp:
    emptyBreakDocument.append(self.expr(expression)).nestIfBroken(INDENT).append(emptyBreakDocument)

  of ueInt, ueFloat, ueString, ueVar, ueFn, ueList, ueCall, uePipeline, ueCase, ueFieldAccess,
     ueTuple, ueTupleIndex, ueTodo, uePanic, ueEcho, ueBitArray, ueRecordUpdate, ueNegateBool,
     ueNegateInt, ueBlock:
    self.expr(expression)

proc statement(self: Formatter, statement: UntypedStatement): Document =
  case statement.kind
  of stExpression: self.expr(statement.vExpression)
  of stAssignment: self.assignment(statement.vAssignment[])
  of stUse: self.useDoc(statement.vUse)
  of stAssert: self.assertDoc(statement.vAssert)

proc blockDoc(self: Formatter, location: SrcSpan, statements: seq[UntypedStatement],
              forceBreaks: bool): Document =
  let statementsDoc = docvec(breakableSpaceDocument, self.statements(statements)).nest(INDENT)
  let trailingComments = self.popComments(location.stop)
  let trailingCommentsDoc = printedComments(trailingComments, false)
  let blockDoc =
    if trailingCommentsDoc.isSome:
      docvec(
        openCurlyDocument,
        statementsDoc,
        lineDocument.nest(INDENT),
        trailingCommentsDoc.get.nest(INDENT),
        lineDocument,
        closeCurlyDocument,
      ).forceBreak
    else:
      docvec(openCurlyDocument, statementsDoc, breakableSpaceDocument, closeCurlyDocument)

  if forceBreaks: blockDoc.forceBreak.group
  else: blockDoc.group

proc wrapFunctionCallArguments*(self: Formatter, arguments: seq[Document], location: SrcSpan): Document =
  if arguments.len == 0: return openCloseParenDocument

  let argumentsDoc = emptyBreakDocument.append(join(arguments, commaBreakDocument)).nestIfBroken(INDENT)

  # We get all remaining comments that come before the call's closing
  # parenthesis.
  # If there's any we add those before the closing parenthesis instead
  # of moving those out of the call.
  # Otherwise those would be moved out of the call.
  let comments = self.popComments(location.stop)
  let printed = printedComments(comments, false)
  let closingParens =
    if printed.isNone: docvec(trailingCommaBreakDocument, closeParenDocument)
    else:
      docvec(
        trailingCommaBreakDocument.nest(INDENT),
        printed.get.nest(INDENT),
        lineDocument,
        closeParenDocument,
      ).forceBreak

  openParenDocument.append(argumentsDoc).append(closingParens).group

proc wrapArguments*(self: Formatter, arguments: seq[Document], commentsLimit: int): Document =
  if arguments.len == 0:
    let comments = self.popComments(commentsLimit)
    let printed = printedComments(comments, false)
    if printed.isNone: return openCloseParenDocument
    return openParenDocument
      .append(emptyBreakDocument)
      .append(printed.get)
      .nestIfBroken(INDENT)
      .forceBreak
      .append(emptyBreakDocument)
      .append(closeParenDocument)
  let doc = openParenBreakDocument.append(join(arguments, commaBreakDocument))

  # Include trailing comments if there are any
  let comments = self.popComments(commentsLimit)
  let printed = printedComments(comments, false)
  if printed.isSome:
    doc
      .append(trailingCommaBreakDocument)
      .append(printed.get)
      .nestIfBroken(INDENT)
      .forceBreak
      .append(emptyBreakDocument)
      .append(closeParenDocument)
  else:
    doc.nestIfBroken(INDENT).append(trailingCommaBreakDocument).append(closeParenDocument)

proc wrapArgumentsWithSpread*(self: Formatter, arguments: seq[Document], commentsLimit: int): Document =
  if arguments.len == 0: return self.wrapArguments(arguments, commentsLimit)
  let doc = openParenBreakDocument
    .append(join(arguments, commaBreakDocument))
    .append(commaBreakDocument)
    .append(dotDotDocument)

  # Include trailing comments if there are any
  let comments = self.popComments(commentsLimit)
  let printed = printedComments(comments, false)
  if printed.isSome:
    doc
      .append(trailingCommaBreakDocument)
      .append(printed.get)
      .nestIfBroken(INDENT)
      .forceBreak
      .append(emptyBreakDocument)
      .append(closeParenDocument)
  else:
    doc.nestIfBroken(INDENT).append(trailingCommaBreakDocument).append(closeParenDocument)

proc printedDocumentedComments(self: Formatter, comments: seq[PoppedComment]): Option[Document] =
  ## Given some regular comments it pretty prints those with any respective
  ## doc comment that might be preceding those.
  ## For example:
  ##
  ## ```gleam
  ## /// Doc
  ## // comment
  ##
  ## /// Doc
  ## pub fn wibble() {}
  ## ```
  ##
  ## We don't want the first doc comment to be merged together with
  ## `wibble`'s doc comment, so when we run into comments like `// comment`
  ## we need to first print all documentation comments that come before it.
  if comments.len == 0: return none(Document)

  var doc: seq[Document]
  var i = 0
  while i < comments.len:
    let (commentStart, content) = comments[i]
    inc i
    if content.isNone: continue
    let docComment = self.docCommentsDoc(commentStart)
    let isDocCommented = not docComment.isEmpty
    doc.add docComment
    doc.add commentDocument.append(zeroWidthStr(content.get))
    if i < comments.len:
      if comments[i].content.isSome:
        # Next line is a comment
        doc.add lineDocument
      else:
        # Next line is empty
        inc i
        doc.add twoLinesDocument
    else:
      # We've reached the end, there are no more lines
      if isDocCommented: doc.add twoLinesDocument
      else: doc.add lineDocument
  some(concat(doc).forceBreak)

proc appendAsMessageExpression(self: Formatter, doc: Document, precedingAs: PrecedingAs,
                               message: Option[UntypedExpr]): Document =
  if message.isNone: return doc
  let message = message.get

  let comments = self.popComments(message.location.start)
  let printed = printedComments(comments, false)

  let asDoc = case precedingAs
    of PrecedingAs.Keyword: spaceAsDocument
    of PrecedingAs.Expression: docvec(breakableSpaceDocument, asDocument).nest(INDENT)

  var all: Document
  if printed.isSome:
    # If there's comments between the document and the message we want
    # the `as` bit to be on the same line as the original document and
    # go on a new indented line with the message and comments:
    # ```gleam
    # todo as
    #   // comment!
    #   "wibble"
    # ```
    let grouped = doc.group
    all = docvec(
      grouped,
      asDoc,
      docvec(lineDocument, printed.get, lineDocument, self.expr(message).group).nest(INDENT),
    )
  else:
    # If we have `as` preceded by a keyword (like with `panic` and `todo`)
    # and the message is a block, we don't want to nest it any further. That is,
    # we want it to look like this:
    # ```gleam
    # panic as {
    #   wibble wobble
    # }
    # ```
    # instead of this:
    # ```gleam
    # panic as {
    #     wibble wobble
    #   }
    # ```
    let messageDoc =
      if precedingAs == PrecedingAs.Keyword and message.kind == ueBlock: self.expr(message).group
      else: self.expr(message).group.nest(INDENT)
    all = docvec(doc.group, asDoc, spaceDocument, messageDoc)

  all.group

proc appendAsMessageConstant(self: Formatter, doc: Document, message: Option[UntypedConstant]): Document =
  if message.isNone: return doc
  let message = message.get

  let comments = self.popComments(message.location.start)
  let printed = printedComments(comments, false)

  var all: Document
  if printed.isSome:
    # If there's comments between the document and the message we want
    # the `as` bit to be on the same line as the original document and
    # go on a new indented line with the message and comments:
    # ```gleam
    # todo as
    #   // comment!
    #   "wibble"
    # ```
    all = docvec(
      doc.group,
      spaceAsDocument,
      docvec(lineDocument, printed.get, lineDocument, self.constExpr(message).group).nest(INDENT),
    )
  else:
    let messageDoc = self.constExpr(message).group.nest(INDENT)
    all = docvec(doc.group, spaceAsSpaceDocument, messageDoc)

  all.group

proc echoDoc(self: Formatter, expression: Option[ref UntypedExpr],
             message: Option[ref UntypedExpr]): Document =
  if expression.isNone:
    return self.appendAsMessageExpression(echoDocument, PrecedingAs.Keyword, unbox(message))
  let expression = expression.get[]

  # When a binary expression gets broken on multiple lines we don't want
  # it to be on the same line as echo, or it would look confusing;
  # instead it's nested onto a new line:
  #
  # ```gleam
  # echo first
  #   |> wobble
  #   |> wibble
  # ```
  #
  # So it's easier to see echo is printing the whole thing. Otherwise,
  # it would look like echo is printing just the first item:
  #
  # ```gleam
  # echo first
  # |> wobble
  # |> wibble
  # ```
  #
  let doc = self.expr(expression)
  if expression.isBinop or expression.isPipeline:
    let withMessage =
      self.appendAsMessageExpression(doc.nest(INDENT), PrecedingAs.Expression, unbox(message))
    docvec(echoSpaceDocument, withMessage)
  else:
    docvec(echoSpaceDocument, self.appendAsMessageExpression(doc, PrecedingAs.Expression, unbox(message)))

proc formatModule*(module: UntypedModule, extra: ModuleExtra, src: string): string =
  ## What upstream's `pretty` does once the source is parsed: the syntax tree
  ## and what the lexer kept beside it, to formatted source.
  let intermediate = Intermediate.fromExtra(extra, src)
  Formatter.withComments(intermediate).module(module).toPrettyString(80)
