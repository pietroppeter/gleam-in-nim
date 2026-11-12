## port-of: compiler-core/src/ast/untyped.rs
## port-status: draft
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/ast/untyped.rs.

## The untyped expressions: what the parser makes of the body of a function.
##
## This file is included by `ast.nim` (it is not a module of its own), the way
## upstream's `untyped.rs` starts with `use super::*`: import `ast` to use it.

type
  FunctionLiteralKindKind* = enum
    flCapture
    flAnonymous
    flUse

  FunctionLiteralKindCapture* = object of StructVariant
    hole*: SrcSpan

  FunctionLiteralKindAnonymous* = object of StructVariant
    head*: SrcSpan

  FunctionLiteralKindUse* = object of StructVariant
    location*: SrcSpan

  FunctionLiteralKind* = object
    case kind*: FunctionLiteralKindKind
    of flCapture: vCapture*: FunctionLiteralKindCapture
    of flAnonymous: vAnonymous*: FunctionLiteralKindAnonymous
    of flUse: vUse*: FunctionLiteralKindUse

  UntypedExprKind* = enum
    ueInt
    ueFloat
    ueString
    ueBlock
    ueVar
    ueFn # TODO: create new variant for captures specifically
    ueList
    ueCall
    ueBinOp
    uePipeline
    ueCase
    ueFieldAccess
    ueTuple
    ueTupleIndex
    ueTodo
    uePanic
    ueEcho
    ueBitArray
    ueRecordUpdate
    ueNegateBool
    ueNegateInt

  UntypedExprInt* = object of StructVariant
    location*: SrcSpan
    value*: string
    intValue*: BigInt

  UntypedExprFloat* = object of StructVariant
    location*: SrcSpan
    value*: string
    floatValue*: LiteralFloatValue

  UntypedExprString* = object of StructVariant
    location*: SrcSpan
    value*: string

  UntypedExprBlock* = object of StructVariant
    location*: SrcSpan
    statements*: seq[Statement[Unit, UntypedExpr]] ## Upstream a `Vec1`: never empty.

  UntypedExprVar* = object of StructVariant
    location*: SrcSpan
    name*: string

  UntypedExprFn* = object of StructVariant
    location*: SrcSpan
      ## For anonymous functions, this is the location of the entire function including the end of the body.
      ## For named functions, this is the location of the function head.
    kind*: FunctionLiteralKind
    endOfHeadByteIndex*: int
      ## The byte location of the end of the function head before the opening bracket
    arguments*: seq[Arg[Unit]]
    body*: seq[Statement[Unit, UntypedExpr]] ## Upstream a `Vec1`: never empty.
    returnAnnotation*: Option[TypeAst]

  UntypedExprList* = object of StructVariant
    location*: SrcSpan
    elements*: seq[UntypedExpr]
    tail*: Option[ref UntypedExpr]

  UntypedExprCall* = object of StructVariant
    location*: SrcSpan
    fun*: ref UntypedExpr
    arguments*: seq[CallArg[UntypedExpr]]
    openParenthesis*: int

  UntypedExprBinOp* = object of StructVariant
    location*: SrcSpan
    operator*: BinOp
    operatorStart*: int
    left*: ref UntypedExpr
    right*: ref UntypedExpr

  UntypedExprPipeline* = object of StructVariant
    expressions*: seq[UntypedExpr] ## Upstream a `Vec1`: never empty.

  UntypedExprCase* = object of StructVariant
    location*: SrcSpan
    subjects*: seq[UntypedExpr]
    clauses*: Option[seq[Clause[UntypedExpr, Unit]]]
      # None if the case expression is missing a body.

  UntypedExprFieldAccess* = object of StructVariant
    location*: SrcSpan
      # This is the location of the whole record and field
      #   user.name
      #   ^^^^^^^^^
    labelLocation*: SrcSpan
      # This is the location of just the field access (ignoring the `.`)
      #   user.name
      #        ^^^^
    label*: string
    container*: ref UntypedExpr

  UntypedExprTuple* = object of StructVariant
    location*: SrcSpan
    elements*: seq[UntypedExpr]

  UntypedExprTupleIndex* = object of StructVariant
    location*: SrcSpan
    index*: uint64
    tupl*: ref UntypedExpr

  UntypedExprTodo* = object of StructVariant
    kind*: TodoKind
    location*: SrcSpan
    message*: Option[ref UntypedExpr]

  UntypedExprPanic* = object of StructVariant
    location*: SrcSpan
    message*: Option[ref UntypedExpr]

  UntypedExprEcho* = object of StructVariant
    location*: SrcSpan
    keywordEnd*: int
      ## This is the position where the echo keyword ends:
      ## ```gleam
      ## echo wibble
      ## // ^ ends here!
      ## ```
    expression*: Option[ref UntypedExpr]
    message*: Option[ref UntypedExpr]

  UntypedExprBitArray* = object of StructVariant
    location*: SrcSpan
    segments*: seq[BitArraySegment[UntypedExpr, Unit]]

  UntypedExprRecordUpdate* = object of StructVariant
    location*: SrcSpan
    spreadStart*: int
      ## This is where the `..` starts:
      ## ```gleam
      ## Wibble(  ..wobble, a: 1)
      ## //       ^ Here!
      ## ```
    constructor*: ref UntypedExpr
    record*: RecordBeingUpdated[UntypedExpr]
    arguments*: seq[RecordUpdateArg[UntypedExpr]]

  UntypedExprNegateBool* = object of StructVariant
    location*: SrcSpan
    value*: ref UntypedExpr

  UntypedExprNegateInt* = object of StructVariant
    location*: SrcSpan
    value*: ref UntypedExpr

  UntypedExpr* = object
    case kind*: UntypedExprKind
    of ueInt: vInt*: UntypedExprInt
    of ueFloat: vFloat*: UntypedExprFloat
    of ueString: vString*: UntypedExprString
    of ueBlock: vBlock*: UntypedExprBlock
    of ueVar: vVar*: UntypedExprVar
    of ueFn: vFn*: UntypedExprFn
    of ueList: vList*: UntypedExprList
    of ueCall: vCall*: UntypedExprCall
    of ueBinOp: vBinOp*: UntypedExprBinOp
    of uePipeline: vPipeline*: UntypedExprPipeline
    of ueCase: vCase*: UntypedExprCase
    of ueFieldAccess: vFieldAccess*: UntypedExprFieldAccess
    of ueTuple: vTuple*: UntypedExprTuple
    of ueTupleIndex: vTupleIndex*: UntypedExprTupleIndex
    of ueTodo: vTodo*: UntypedExprTodo
    of uePanic: vPanic*: UntypedExprPanic
    of ueEcho: vEcho*: UntypedExprEcho
    of ueBitArray: vBitArray*: UntypedExprBitArray
    of ueRecordUpdate: vRecordUpdate*: UntypedExprRecordUpdate
    of ueNegateBool: vNegateBool*: UntypedExprNegateBool
    of ueNegateInt: vNegateInt*: UntypedExprNegateInt

func location*(self: UntypedExpr): SrcSpan =
  case self.kind
  of uePipeline:
    let expressions = self.vPipeline.expressions
    expressions[0].location.merge(expressions[^1].location)
  of ueFn: self.vFn.location
  of ueVar: self.vVar.location
  of ueInt: self.vInt.location
  of ueTodo: self.vTodo.location
  of ueEcho: self.vEcho.location
  of ueCase: self.vCase.location
  of ueCall: self.vCall.location
  of ueList: self.vList.location
  of ueFloat: self.vFloat.location
  of ueBlock: self.vBlock.location
  of ueBinOp: self.vBinOp.location
  of ueTuple: self.vTuple.location
  of uePanic: self.vPanic.location
  of ueString: self.vString.location
  of ueBitArray: self.vBitArray.location
  of ueNegateInt: self.vNegateInt.location
  of ueNegateBool: self.vNegateBool.location
  of ueTupleIndex: self.vTupleIndex.location
  of ueFieldAccess: self.vFieldAccess.location
  of ueRecordUpdate: self.vRecordUpdate.location

func startByteIndex*(self: UntypedExpr): int =
  case self.kind
  of ueBlock:
    self.vBlock.location.start
  of uePipeline:
    self.vPipeline.expressions[0].startByteIndex
  of ueInt, ueFloat, ueString, ueVar, ueFn, ueList, ueCall, ueBinOp, ueCase,
      ueFieldAccess, ueTuple, ueTupleIndex, ueTodo, uePanic, ueEcho, ueBitArray,
      ueRecordUpdate, ueNegateBool, ueNegateInt:
    self.location.start

func binOpPrecedence*(self: UntypedExpr): uint8 =
  case self.kind
  of ueBinOp:
    self.vBinOp.operator.precedence
  of uePipeline:
    5
  of ueInt, ueFloat, ueString, ueBlock, ueVar, ueFn, ueList, ueCall, ueCase,
      ueFieldAccess, ueTuple, ueTupleIndex, ueTodo, uePanic, ueEcho, ueBitArray,
      ueRecordUpdate, ueNegateBool, ueNegateInt:
    high(uint8)

func binOpName*(self: UntypedExpr): Option[BinOp] =
  if self.kind == ueBinOp:
    some(self.vBinOp.operator)
  else:
    none(BinOp)

func canHaveMultiplePerLine*(self: UntypedExpr): bool =
  case self.kind
  of ueInt, ueFloat, ueString, ueVar:
    true
  of ueNegateBool:
    self.vNegateBool.value[].canHaveMultiplePerLine
  of ueNegateInt:
    self.vNegateInt.value[].canHaveMultiplePerLine
  of ueFieldAccess:
    self.vFieldAccess.container[].canHaveMultiplePerLine
  of ueBlock, ueFn, ueList, ueCall, ueBinOp, uePipeline, ueCase, ueTuple, ueTupleIndex,
      ueTodo, uePanic, ueEcho, ueBitArray, ueRecordUpdate:
    false

func isTuple*(self: UntypedExpr): bool =
  self.kind == ueTuple

func isCall*(self: UntypedExpr): bool =
  ## Returns `true` if the untyped expr is `Call`.
  self.kind == ueCall

func isBinop*(self: UntypedExpr): bool =
  self.kind == ueBinOp

func isPipeline*(self: UntypedExpr): bool =
  self.kind == uePipeline

func isTodo*(self: UntypedExpr): bool =
  self.kind == ueTodo

func isPanic*(self: UntypedExpr): bool =
  self.kind == uePanic

func isAnonymous*(self: FunctionLiteralKind): bool =
  case self.kind
  of flAnonymous: true
  of flCapture, flUse: false

func isCapture*(self: FunctionLiteralKind): bool =
  case self.kind
  of flCapture: true
  of flAnonymous, flUse: false
