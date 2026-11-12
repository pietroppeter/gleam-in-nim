## port-part-of: compiler-core/src/ast/constant.rs
## (only a part of that file is ported so far: when the rest is, this becomes `port-of` with a `port-status`)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/ast/constant.rs.

## Constants: the expressions that can stand on the right of `const`.
##
## This file is included by `ast.nim` (it is not a module of its own), the way
## upstream's `constant.rs` starts with `use super::*`: import `ast` to use it.
##
## Ported: the `Constant` type and what upstream implements for every
## `Constant<T>`. Not ported yet: `impl TypedConstant` (it needs the types of
## the type checker) and `bit_array::GetLiteralValue`.

type
  ConstantKind* = enum
    coInt
    coFloat
    coString
    coTuple
    coList
    coRecord
    coRecordUpdate
    coBitArray
    coVar
    coBinaryOperator
      ## A constant binary operation.
      ## Most binops are not supported in constants yet, however we parse them
      ## and produce an error during type analysis rather than during parsing so
      ## we can get better error messages and language server code actions.
    coInvalid
      ## A placeholder constant used to allow module analysis to continue
      ## even when there are type errors. Should never end up in generated code.
    coTodo

  ConstantInt* = object of StructVariant
    location*: SrcSpan
    value*: string
    intValue*: BigInt

  ConstantFloat* = object of StructVariant
    location*: SrcSpan
    value*: string
    floatValue*: LiteralFloatValue

  ConstantString* = object of StructVariant
    location*: SrcSpan
    value*: string

  ConstantTuple*[T] = object of StructVariant
    location*: SrcSpan
    elements*: seq[Constant[T]]
    typ*: T

  ConstantList*[T] = object of StructVariant
    location*: SrcSpan
    elements*: seq[Constant[T]]
    typ*: T
    tail*: Option[ref Constant[T]]

  ConstantRecord*[T] = object of StructVariant
    location*: SrcSpan
    argumentsStartPosition*: int
    module*: Option[(string, SrcSpan)]
    name*: string
    arguments*: Option[seq[CallArg[Constant[T]]]]
      ## These are the arguments used when calling the record.
      ## If the record is not being called to build a value, then this will
      ## be `None`. A couple of examples:
      ## ```gleam
      ## pub const a = Wibble
      ## // arguments: None
      ##
      ## pub const b = Wibble()
      ## // arguments: Some(vec![])
      ##
      ## pub const c = Wibble(1, 2)
      ## // arguments: Some(vec![1, 2])
      ## ```
    typ*: T
    fieldMap*: Inferred[FieldMap]
    recordConstructor*: Option[ref ValueConstructor]

  ConstantRecordUpdate*[T] = object of StructVariant
    location*: SrcSpan
    constructorLocation*: SrcSpan
    module*: Option[(string, SrcSpan)]
    name*: string
    record*: RecordBeingUpdated[Constant[T]]
    arguments*: seq[RecordUpdateArg[Constant[T]]]
    typ*: T
    fieldMap*: Inferred[FieldMap]

  ConstantBitArray*[T] = object of StructVariant
    location*: SrcSpan
    segments*: seq[BitArraySegment[Constant[T], T]]

  ConstantVar*[T] = object of StructVariant
    location*: SrcSpan
    module*: Option[(string, SrcSpan)]
    name*: string
    constructor*: Option[ref ValueConstructor]
    typ*: T

  ConstantBinaryOperator*[T] = object of StructVariant
    location*: SrcSpan
    operatorStart*: int
    operator*: BinOp
    left*: ref Constant[T]
    right*: ref Constant[T]
    typ*: T

  ConstantInvalid*[T] = object of StructVariant
    location*: SrcSpan
    typ*: T
    extraInformation*: Option[InvalidExpression]
      ## Extra information about the invalid expression, useful for providing
      ## addition help or information, such as code actions to fix invalid
      ## states.

  ConstantTodo*[T] = object of StructVariant
    location*: SrcSpan
    typ*: T
    message*: Option[ref Constant[T]]

  Constant*[T] = object
    case kind*: ConstantKind
    of coInt: vInt*: ConstantInt
    of coFloat: vFloat*: ConstantFloat
    of coString: vString*: ConstantString
    of coTuple: vTuple*: ConstantTuple[T]
    of coList: vList*: ConstantList[T]
    of coRecord: vRecord*: ConstantRecord[T]
    of coRecordUpdate: vRecordUpdate*: ConstantRecordUpdate[T]
    of coBitArray: vBitArray*: ConstantBitArray[T]
    of coVar: vVar*: ConstantVar[T]
    of coBinaryOperator: vBinaryOperator*: ConstantBinaryOperator[T]
    of coInvalid: vInvalid*: ConstantInvalid[T]
    of coTodo: vTodo*: ConstantTodo[T]

type UntypedConstant* = Constant[Unit]

func binOpPrecedence*[T](self: Constant[T]): uint8 =
  case self.kind
  of coBinaryOperator:
    self.vBinaryOperator.operator.precedence
  of coInt, coFloat, coString, coVar, coList, coTuple, coTodo, coBitArray, coInvalid,
      coRecord, coRecordUpdate:
    high(uint8)

func binOpName*[T](self: Constant[T]): Option[BinOp] =
  if self.kind == coBinaryOperator:
    some(self.vBinaryOperator.operator)
  else:
    none(BinOp)

func isTuple*[T](self: Constant[T]): bool =
  self.kind == coTuple

func isBinop*[T](self: Constant[T]): bool =
  self.kind == coBinaryOperator

func location*[T](self: Constant[T]): SrcSpan =
  case self.kind
  of coInt: self.vInt.location
  of coList: self.vList.location
  of coFloat: self.vFloat.location
  of coTuple: self.vTuple.location
  of coString: self.vString.location
  of coRecord: self.vRecord.location
  of coRecordUpdate: self.vRecordUpdate.location
  of coBitArray: self.vBitArray.location
  of coVar: self.vVar.location
  of coInvalid: self.vInvalid.location
  of coTodo: self.vTodo.location
  of coBinaryOperator: self.vBinaryOperator.location

func canHaveMultiplePerLine*[T](self: Constant[T]): bool =
  case self.kind
  of coInt, coFloat, coString, coVar:
    true
  of coTuple, coTodo, coList, coRecord, coRecordUpdate, coBitArray, coBinaryOperator,
      coInvalid:
    false
