## port-part-of: erlang-generation/src/lib.rs
## (only a part of that file is ported so far: when the rest is, this becomes `port-of` with a `port-status`)
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Gleam contributors
#
# Ported to Nim from the Gleam compiler, v1.19.2
# (commit ed41eace2dd89054eb2d744c33925261d1eff32e):
#   erlang-generation/src/lib.rs
# https://github.com/gleam-lang/gleam/blob/v1.19.2/erlang-generation/src/lib.rs
#
# What is ported so far: the types shared by the two builders and
# `ErlangSourceBuilder`, the builder that writes Erlang source text (lines 1 to
# 3803 upstream). `ErlangBinaryBuilder`, the builder that writes the Erlang
# Abstract Format, is the next step and comes in this same module.
#
# How the trait is written here. Upstream `ErlangBuilder<Output>` is a trait
# with two implementations. Following the porting guide ("`impl Trait for T`
# (one or two types): plain procs with the same names") there is no trait in
# the Nim: each builder has procs with the names of the trait's functions, and
# code that must work with both is generic (`proc generate[B](builder: var B)`).
# The documentation of the trait's functions is on the procs of
# `ErlangSourceBuilder`, the first implementation.
#
# The associated types of the trait (`Function`, `Call`, `Tuple`...) are all
# `()` for the source builder. Here that is `Unit` (of `rust_enum`), so that a
# `start` proc returns a value and the matching `end` proc takes it, as
# upstream.
import std/[math, options, strutils]
import pkg/bigints
import rust_enum, src_span
export rust_enum.Unit

## Upstream, this is the documentation of the trait `ErlangBuilder<Output>`:
##
## A trait defining operations to describe the content of an Erlang module.
##
## This might look strange in places, for example why is there a `start_tuple`
## and `end_tuple` function, but lists are built using `cons_list` and not a
## `start_list` and `end_list` function?
##
## That's because this API has been made primarily to be able to generate
## the Erlang Abstract Format data structure. All the methods almost map 1:1
## to how Erlang constructs are represented in that format.
##
## You might want to keep a reference to it open as you go over this module,
## it's gonna be handy:
## https://www.erlang.org/doc/apps/erts/absform.html

proc invalidCodeForPosition(message: string) {.noreturn.} =
  ## This is to raise an `unreachable` pretty printed error when we try producing
  ## some piece of code that is not allowed in the current position.
  ##
  ## Upstream this is a macro around `unreachable!`; the message it is given
  ## comes from `errorWithPosition`.
  raiseAssert "internal error: entered unreachable code: " & message

type
  ErlangModuleName* = object
    ## This represent an Erlang module name.
    ## Gleam modules use `/` as a separator, but when turned into Erlang `@` is
    ## used as a separator instead.
    ##
    ## If we were to allow strings directly, a very common mistake to make would be
    ## to pass a Gleam module name to a function that's expecting an Erlang module
    ## name!
    ##
    ## With this those bugs cannot happen, and since this is a newtype wrapper its
    ## not adding any overhead over using plain strings.
    name: string

func newErlangModuleName*(gleamModuleName: string): ErlangModuleName =
  ## `ErlangModuleName::new`
  ErlangModuleName(name: gleamModuleName.replace("/", "@"))

func erlang*(_: typedesc[ErlangModuleName]): ErlangModuleName = ErlangModuleName(name: "erlang")
func binary*(_: typedesc[ErlangModuleName]): ErlangModuleName = ErlangModuleName(name: "binary")
func maps*(_: typedesc[ErlangModuleName]): ErlangModuleName = ErlangModuleName(name: "maps")
func io*(_: typedesc[ErlangModuleName]): ErlangModuleName = ErlangModuleName(name: "io")
func ioLib*(_: typedesc[ErlangModuleName]): ErlangModuleName = ErlangModuleName(name: "io_lib")
func lists*(_: typedesc[ErlangModuleName]): ErlangModuleName = ErlangModuleName(name: "lists")
func unicode*(_: typedesc[ErlangModuleName]): ErlangModuleName = ErlangModuleName(name: "unicode")

type
  ErlangBuiltInType* {.pure.} = enum
    Any, Integer, Binary, Boolean, Float, Bitstring, List

func asStr(self: ErlangBuiltInType): string =
  case self
  of ErlangBuiltInType.Any: "any"
  of ErlangBuiltInType.Integer: "integer"
  of ErlangBuiltInType.Binary: "binary"
  of ErlangBuiltInType.Boolean: "boolean"
  of ErlangBuiltInType.Float: "float"
  of ErlangBuiltInType.Bitstring: "bitstring"
  of ErlangBuiltInType.List: "list"

type
  BitArraySegmentSpecifierKind* = enum
    spUtf8, spUtf16, spUtf32, spInteger, spFloat, spBinary, spBitstring, spSigned, spUnsigned,
    spLittle, spBig, spNative, spUnit

  BitArraySegmentSpecifier* = object
    case kind*: BitArraySegmentSpecifierKind
    of spUnit: vUnit*: uint8
    of spUtf8, spUtf16, spUtf32, spInteger, spFloat, spBinary, spBitstring, spSigned,
       spUnsigned, spLittle, spBig, spNative: discard

  DocContentKind* = enum
    dcFalse, dcString

  DocContent* = object
    case kind*: DocContentKind
    of dcFalse: discard
    of dcString: vString*: string

func specifier*(kind: BitArraySegmentSpecifierKind): BitArraySegmentSpecifier =
  ## A specifier without data: `BitArraySegmentSpecifier::Utf8` and the like.
  doAssert kind != spUnit
  result = BitArraySegmentSpecifier(kind: spUtf8)
  {.cast(uncheckedAssign).}: result.kind = kind

func unitSpecifier*(unit: uint8): BitArraySegmentSpecifier =
  ## `BitArraySegmentSpecifier::Unit(unit)`
  BitArraySegmentSpecifier(kind: spUnit, vUnit: unit)

func docFalse*(): DocContent = DocContent(kind: dcFalse)
  ## `DocContent::False`
func docString*(content: string): DocContent = DocContent(kind: dcString, vString: content)
  ## `DocContent::String(content)`

# --- ErlangSourceBuilder ------------------------------------------------------------------------
#
# The enums with data below have the one shape of this port (decision 0010,
# `rust_enum.nim`): a `kind`, and one field `v<Variant>` per variant with data,
# holding an object with the variant's fields.

type
  ListKind {.pure.} = enum
    Pattern     ## We're generating a list pattern.
    Expression  ## We're generating a list expression.

  BitArrayKind {.pure.} = enum
    Pattern     ## We're generating a bit array pattern.
    Expression  ## We're generating a bit array expression.

  ExpectedMapFieldItem {.pure.} = enum
    ## A map field is made of two things: a key, and a value. It's not an item that
    ## is closed explicitly with a `end_map_field` function. It is implicitly over
    ## after two expressions are generated. So we need to keep track of what we're
    ## expecting to be generated next.
    Key, Value

  ExpectedRecordFieldItem {.pure.} = enum
    ## A record field is made of two things: a name, and a type. It's not an item
    ## that is closed explicitly with a `end_record_field` function.
    ## It is implicitly over after those two things are generated.
    ## So we need to keep track of which we're expecting to be generated next.
    Name, Type

  ExpectedCaseClauseItemKind = enum
    ccPattern, ccGuards, ccBody
  ExpectedCaseClauseItemGuards = object of StructVariant
    first: bool  ## This is true if no guard has been generated yet.
  ExpectedCaseClauseItemBody = object of StructVariant
    first: bool  ## This is true if no body statement has been generated yet.
  ExpectedCaseClauseItem = object
    ## Generating a case clause is done in three separate steps: first we generate
    ## a single pattern, then we have to generate the guards for the clause,
    ## finally we will be generating the statements making up the clause's body.
    case kind: ExpectedCaseClauseItemKind
    of ccPattern: discard
    of ccGuards: vGuards: ExpectedCaseClauseItemGuards
    of ccBody: vBody: ExpectedCaseClauseItemBody

  ExpectedCaseItemKind = enum
    ciSubject
      ## We're waiting for the expression to be matched on to be generated.
    ciBranches
      ## We've generated the expression to be matched on, and now are waiting for
      ## the case branches to be generated.
  ExpectedCaseItemBranches = object of StructVariant
    first: bool  ## This is `true` is no branch has been generated yet.
  ExpectedCaseItem = object
    ## Generating a case expression is done in two steps: first we generate the
    ## subject being matched on, then we generate the branches of the case
    ## expression.
    case kind: ExpectedCaseItemKind
    of ciSubject: discard
    of ciBranches: vBranches: ExpectedCaseItemBranches

  ExpectedBinaryOperatorSide {.pure.} = enum
    ## When generating a binary operator, that is made of three parts: the operator
    ## and the left and right hand sides.
    ## The way the Erlang Abstract Format works, we first generate the operator,
    ## and then the two sides.
    ## This is used to keep track which side we're expecting to see and properly
    ## pretty print the output.
    Left, Right, BinaryOperatorIsOver

  ExpectedBitArraySegmentItemKind = enum
    bsValue, bsSize, bsSpecifiers
  ExpectedBitArraySegmentItemValue = object of StructVariant
    kind: BitArrayKind
      ## This is telling us if the value of the segment has to be a pattern
      ## or an expression.
  ExpectedBitArraySegmentItem = object
    ## When generating a bit array segment we need to generate exactly three
    ## things: the value, the size, and the type specifiers.
    ## This keeps track of which one we're expecting to be generated next.
    case kind: ExpectedBitArraySegmentItemKind
    of bsValue: vValue: ExpectedBitArraySegmentItemValue
    of bsSize, bsSpecifiers: discard

  ExpectedCallItemKind = enum
    clFunctionToBeCalled
      ## We're waiting for the function to be called to be generated
    clArguments
      ## The function to be called was generated, now we're waiting for its
      ## arguments.
  ExpectedCallItemArguments = object of StructVariant
    first: bool
  ExpectedCallItem = object
    ## When generating a function call, that is made of two parts: the function to
    ## be called (that could be a simple literal atom, denoting a function from the
    ## current module, or any expression), and its arguments.
    case kind: ExpectedCallItemKind
    of clFunctionToBeCalled: discard
    of clArguments: vArguments: ExpectedCallItemArguments

  ExpectedFunctionTypeItemKind = enum
    ftArguments, ftReturnType
  ExpectedFunctionTypeItemArguments = object of StructVariant
    first: bool
  ExpectedFunctionTypeItem = object
    ## When generating a function type, that is made of two parts: the type
    ## arguments of the function, and the return type.
    case kind: ExpectedFunctionTypeItemKind
    of ftArguments: vArguments: ExpectedFunctionTypeItemArguments
    of ftReturnType: discard

  TypeSpecExpectedItem {.pure.} = enum
    ## Type specs don't have a "end_" function. They are implicitly over once a
    ## type is generated. This is used to keep track of what we're expecting to
    ## see.
    TypeDefinition, TypeSpecIsOver

  ExpectedMatchSide {.pure.} = enum
    ## A match operator is made of two sides: `X = 1`. A pattern and an expression.
    Pattern
      ## We're waiting for the pattern on the left hand side of an assignment to
      ## be generated.
    Expression
      ## We're waiting for the expression on the right hand side of an assignment
      ## to be generated.

  ExpectedMatchPatternSide {.pure.} = enum
    ## An as pattern is made of two sides: `[1, _ | _] = List`.
    ## A pattern and a variable pattern for the name.
    Left
      ## We're waiting for the pattern on the left hand side of the match pattern
      ## to be generated.
    Right
      ## We're waiting for the pattern on the right hand side of the match
      ## pattern to be generated.

  ExpectedListItem {.pure.} = enum
    ## Lists are built by cons cells, so when building a list we will do something
    ## like this: `[a | [b | []]]`.
    ## This is telling us if we're expecting the first item, the second list, or if
    ## the list is actually over.
    First, Rest, ListIsOver

  ErlangSourceBuilderPositionKind = enum
    posFunctionSpec
      ## We're generating a function spec like `-spec wibble(atom()) -> atom()`.
    posTypeSpec
      ## We're generating code for a type spec like
      ## `-type wibble() :: {ok, integer()}`.
    posFunctionType
      ## We're generating a function type, there's a couple of things that make
      ## it up that we will need to generate: its arguments and the return type.
      ## Which one we're expecting to see is described by the `expected` field.
    posNamedType
      ## We're generating a named type like `integer()`, or `list(atom())`.
    posUnionType
      ## We're generating a union type like `integer() | atom()`.
    posTupleType
      ## We're generating a tuple type like `{integer(), atom()}`.
    posFunctionStatement
      ## We're generating the statements of a function.
    posAnonymousFunctionStatement
      ## We're generating the statements of an anonymous function.
    posMatchOperator
      ## We're generating code for a match operator like `X = 1`.
      ## This is something that happens in multiple steps: first the pattern on
      ## the left hand side, second the expression on the right.
    posMatchPattern
      ## We're generating code for a match pattern like `[1, A | _] = List`.
      ## This is something that happens in multiple steps: first the pattern on
      ## the left hand side, second the pattern on the right hand side.
    posList
      ## We're generating a list.
    posUnaryOperator
      ## We're generating code for a unary operator. We're waiting for the
      ## expression to apply the operator to.
    posTuple
      ## We're generating a tuple.
    posTuplePattern
      ## We're generating a tuple pattern.
    posBitArray
      ## We're generating the segments of a bit array.
    posBitArraySegment
      ## We're generating code for a segment of a bit array, like `10:1/signed`.
    posBlock
      ## We're generating a `begin ... end` block.
    posFunctionCall
      ## We're generating code for a function call like `wibble(1, 2)`.
      ## This needs to happen in steps: first we generate the function being
      ## called (that could be any arbitrary expression after all), then we
      ## generate the arguments it's being called with.
    posBinaryOperator
      ## We're generating code for a binary operator like `1 + 3`.
    posCase
      ## We're generating code for a case expression.
    posCaseClause
      ## We're generating code for a case clause.
    posMap
      ## We're generating the key-value pairs of a map.
    posMapField
      ## We're generating a key-value pair inside a map.
    posRecordAttribute
      ## We're generating the fields of a record attribute.
    posRecordField
      ## We're generating the field of a record attribute. That needs to happen
      ## in two steps: first we generate the name, second we generate the type of
      ## the field.
    posClauseGuard
      ## We're generating a guard in a possible series of guards in a clause.

  ErlangSourceBuilderPositionTypeSpec = object of StructVariant
    expected: TypeSpecExpectedItem
  ErlangSourceBuilderPositionFunctionType = object of StructVariant
    expected: ExpectedFunctionTypeItem
    needsWrapping: bool
      ## If a function type doesn't appear at the top level as a spec
      ## annotation, then we must wrap it in a `fun(...)`. For example:
      ##
      ## ```erl
      ## % in a spec annotation it simply comes after the function name:
      ## -spec wibble () -> integer().
      ## wibble() -> 11.
      ##
      ## % but inside another type it has to be wrapped in `fun(...)`:
      ## -spec wobble () -> fun(() -> integer())
      ## wobble() -> fun wibble/0.
      ## ```
      ##
      ## This is `true` if the type has to be wrapped in `fun(...)`
  ErlangSourceBuilderPositionNamedType = object of StructVariant
    first: bool
      ## This is `true` is the first type argument of the named type has not
      ## been generated yet.
  ErlangSourceBuilderPositionUnionType = object of StructVariant
    first: bool
      ## This is `true` is the first alternative of the union type has not
      ## been generated yet.
  ErlangSourceBuilderPositionTupleType = object of StructVariant
    first: bool
      ## This is `true` is the first item of the tuple type has not been
      ## generated yet.
  ErlangSourceBuilderPositionFunctionStatement = object of StructVariant
    first: bool  ## This is `true` if the first statement has not been generated yet.
  ErlangSourceBuilderPositionAnonymousFunctionStatement = object of StructVariant
    first: bool  ## This is `true` if the first statement has not been generated yet.
  ErlangSourceBuilderPositionMatchOperator = object of StructVariant
    expected: ExpectedMatchSide  ## This keeps track of what we need to generate next.
  ErlangSourceBuilderPositionMatchPattern = object of StructVariant
    expected: ExpectedMatchPatternSide  ## This keeps track of what we need to generate next.
  ErlangSourceBuilderPositionList = object of StructVariant
    kind: ListKind
      ## This is telling us if we're generating a list expression, or a list
      ## pattern.
    expected: ExpectedListItem
      ## The list item we're expecting to see next.
  ErlangSourceBuilderPositionTuple = object of StructVariant
    first: bool  ## This is `true` is the first tuple item has not been generated yet.
  ErlangSourceBuilderPositionTuplePattern = object of StructVariant
    first: bool
      ## This is `true` if the first pattern of the tuple has not been
      ## generated ywt.
  ErlangSourceBuilderPositionBitArray = object of StructVariant
    kind: BitArrayKind
      ## Whether we're dealing with a bit array pattern, or a bit array
      ## expression.
    first: bool
      ## This is `true` if the first segment has not been generated yet.
  ErlangSourceBuilderPositionBitArraySegment = object of StructVariant
    expected: ExpectedBitArraySegmentItem
    segmentValueNeedsWrapping: bool
      ## This is `true` if the value of the bit array segment needs to be wrapped
      ## in parentheses. For example function calls need to be wrapped, or they
      ## would result in invalid Erlang being produced.
      ##
      ## ```erl
      ## <<x()/binary>>   % This is a syntax error!
      ## <<(x())/binary>> % This is fine.
      ## ```
    segmentSizeNeedsWrapping: bool
  ErlangSourceBuilderPositionBlock = object of StructVariant
    first: bool
      ## This is `true` is the first statement of the block has not been
      ## generated yet.
  ErlangSourceBuilderPositionFunctionCall = object of StructVariant
    expected: ExpectedCallItem
    calledItemNeedsWrapping: bool
      ## This is `true` if the thing that is being called needs to be wrapped
      ## in parentheses. This appears to be needed in just one case: if we
      ## are calling another function call expression. For example:
      ##
      ## ```erl
      ## wibble()()   % this is invalid Erlang
      ## (wibble())() % this is valid Erlang
      ## ```
      ##
      ## Actually this seems to be needed for OTP versions up to 28, in OTP
      ## 29 we can simply write `wibble()()`. However, since we have to
      ## support OTP 28 we will add the wrapping when needed.
  ErlangSourceBuilderPositionBinaryOperator = object of StructVariant
    expected: ExpectedBinaryOperatorSide
    needsWrapping: bool
      ## Wether this binary operation needs to be wrapped in parentheses or
      ## not.
    operator: string
  ErlangSourceBuilderPositionCase = object of StructVariant
    expected: ExpectedCaseItem
  ErlangSourceBuilderPositionCaseClause = object of StructVariant
    expected: ExpectedCaseClauseItem
  ErlangSourceBuilderPositionMap = object of StructVariant
    first: bool  ## This is `true` if no key-value pair has been generated yet.
  ErlangSourceBuilderPositionMapField = object of StructVariant
    expected: ExpectedMapFieldItem
  ErlangSourceBuilderPositionRecordAttribute = object of StructVariant
    first: bool  ## This is `true` if no field has been generated yet.
  ErlangSourceBuilderPositionRecordField = object of StructVariant
    expected: ExpectedRecordFieldItem

  ErlangSourceBuilderPosition = object
    ## This is used to keep track of the current position when generating pretty
    ## printed code from an `ErlangSourceBuilder`.
    case kind: ErlangSourceBuilderPositionKind
    of posFunctionSpec, posUnaryOperator, posClauseGuard: discard
    of posTypeSpec: vTypeSpec: ErlangSourceBuilderPositionTypeSpec
    of posFunctionType: vFunctionType: ErlangSourceBuilderPositionFunctionType
    of posNamedType: vNamedType: ErlangSourceBuilderPositionNamedType
    of posUnionType: vUnionType: ErlangSourceBuilderPositionUnionType
    of posTupleType: vTupleType: ErlangSourceBuilderPositionTupleType
    of posFunctionStatement: vFunctionStatement: ErlangSourceBuilderPositionFunctionStatement
    of posAnonymousFunctionStatement:
      vAnonymousFunctionStatement: ErlangSourceBuilderPositionAnonymousFunctionStatement
    of posMatchOperator: vMatchOperator: ErlangSourceBuilderPositionMatchOperator
    of posMatchPattern: vMatchPattern: ErlangSourceBuilderPositionMatchPattern
    of posList: vList: ErlangSourceBuilderPositionList
    of posTuple: vTuple: ErlangSourceBuilderPositionTuple
    of posTuplePattern: vTuplePattern: ErlangSourceBuilderPositionTuplePattern
    of posBitArray: vBitArray: ErlangSourceBuilderPositionBitArray
    of posBitArraySegment: vBitArraySegment: ErlangSourceBuilderPositionBitArraySegment
    of posBlock: vBlock: ErlangSourceBuilderPositionBlock
    of posFunctionCall: vFunctionCall: ErlangSourceBuilderPositionFunctionCall
    of posBinaryOperator: vBinaryOperator: ErlangSourceBuilderPositionBinaryOperator
    of posCase: vCase: ErlangSourceBuilderPositionCase
    of posCaseClause: vCaseClause: ErlangSourceBuilderPositionCaseClause
    of posMap: vMap: ErlangSourceBuilderPositionMap
    of posMapField: vMapField: ErlangSourceBuilderPositionMapField
    of posRecordAttribute: vRecordAttribute: ErlangSourceBuilderPositionRecordAttribute
    of posRecordField: vRecordField: ErlangSourceBuilderPositionRecordField

  ErlangSourceBuilder* = object
    code: string
    position: seq[ErlangSourceBuilderPosition]
      ## This keeps track of what we're generating
    indentation: int
      ## The current indentation to use when generating stuff like case
      ## expressions, block statements, etc.

# The positions are built in many places: one short constructor each, named
# after the variant, so that a call reads like the Rust literal
# (`ErlangSourceBuilderPosition::Tuple { first: true }` is `inTuple(first = true)`).
func inFunctionSpec(): ErlangSourceBuilderPosition = ErlangSourceBuilderPosition(kind: posFunctionSpec)
func inUnaryOperator(): ErlangSourceBuilderPosition = ErlangSourceBuilderPosition(kind: posUnaryOperator)
func inClauseGuard(): ErlangSourceBuilderPosition = ErlangSourceBuilderPosition(kind: posClauseGuard)

func expectArguments(first: bool): ExpectedFunctionTypeItem =
  ExpectedFunctionTypeItem(kind: ftArguments, vArguments: ExpectedFunctionTypeItemArguments(first: first))
func expectCallArguments(first: bool): ExpectedCallItem =
  ExpectedCallItem(kind: clArguments, vArguments: ExpectedCallItemArguments(first: first))
func expectBranches(first: bool): ExpectedCaseItem =
  ExpectedCaseItem(kind: ciBranches, vBranches: ExpectedCaseItemBranches(first: first))
func expectGuards(first: bool): ExpectedCaseClauseItem =
  ExpectedCaseClauseItem(kind: ccGuards, vGuards: ExpectedCaseClauseItemGuards(first: first))
func expectBody(first: bool): ExpectedCaseClauseItem =
  ExpectedCaseClauseItem(kind: ccBody, vBody: ExpectedCaseClauseItemBody(first: first))
func expectValue(kind: BitArrayKind): ExpectedBitArraySegmentItem =
  ExpectedBitArraySegmentItem(kind: bsValue, vValue: ExpectedBitArraySegmentItemValue(kind: kind))

func inTypeSpec(expected: TypeSpecExpectedItem): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posTypeSpec,
    vTypeSpec: ErlangSourceBuilderPositionTypeSpec(expected: expected))
func inFunctionType(expected: ExpectedFunctionTypeItem, needsWrapping: bool): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posFunctionType,
    vFunctionType: ErlangSourceBuilderPositionFunctionType(expected: expected, needsWrapping: needsWrapping))
func inNamedType(first: bool): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posNamedType,
    vNamedType: ErlangSourceBuilderPositionNamedType(first: first))
func inUnionType(first: bool): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posUnionType,
    vUnionType: ErlangSourceBuilderPositionUnionType(first: first))
func inTupleType(first: bool): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posTupleType,
    vTupleType: ErlangSourceBuilderPositionTupleType(first: first))
func inFunctionStatement(first: bool): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posFunctionStatement,
    vFunctionStatement: ErlangSourceBuilderPositionFunctionStatement(first: first))
func inAnonymousFunctionStatement(first: bool): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posAnonymousFunctionStatement,
    vAnonymousFunctionStatement: ErlangSourceBuilderPositionAnonymousFunctionStatement(first: first))
func inMatchOperator(expected: ExpectedMatchSide): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posMatchOperator,
    vMatchOperator: ErlangSourceBuilderPositionMatchOperator(expected: expected))
func inMatchPattern(expected: ExpectedMatchPatternSide): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posMatchPattern,
    vMatchPattern: ErlangSourceBuilderPositionMatchPattern(expected: expected))
func inList(kind: ListKind, expected: ExpectedListItem): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posList,
    vList: ErlangSourceBuilderPositionList(kind: kind, expected: expected))
func inTuple(first: bool): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posTuple, vTuple: ErlangSourceBuilderPositionTuple(first: first))
func inTuplePattern(first: bool): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posTuplePattern,
    vTuplePattern: ErlangSourceBuilderPositionTuplePattern(first: first))
func inBitArray(kind: BitArrayKind, first: bool): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posBitArray,
    vBitArray: ErlangSourceBuilderPositionBitArray(kind: kind, first: first))
func inBitArraySegment(expected: ExpectedBitArraySegmentItem, segmentValueNeedsWrapping,
                        segmentSizeNeedsWrapping: bool): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posBitArraySegment,
    vBitArraySegment: ErlangSourceBuilderPositionBitArraySegment(
      expected: expected, segmentValueNeedsWrapping: segmentValueNeedsWrapping,
      segmentSizeNeedsWrapping: segmentSizeNeedsWrapping))
func inBlock(first: bool): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posBlock, vBlock: ErlangSourceBuilderPositionBlock(first: first))
func inFunctionCall(expected: ExpectedCallItem, calledItemNeedsWrapping: bool): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posFunctionCall,
    vFunctionCall: ErlangSourceBuilderPositionFunctionCall(
      expected: expected, calledItemNeedsWrapping: calledItemNeedsWrapping))
func inBinaryOperator(expected: ExpectedBinaryOperatorSide, needsWrapping: bool,
                       operator: string): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posBinaryOperator,
    vBinaryOperator: ErlangSourceBuilderPositionBinaryOperator(
      expected: expected, needsWrapping: needsWrapping, operator: operator))
func inCase(expected: ExpectedCaseItem): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posCase, vCase: ErlangSourceBuilderPositionCase(expected: expected))
func inCaseClause(expected: ExpectedCaseClauseItem): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posCaseClause,
    vCaseClause: ErlangSourceBuilderPositionCaseClause(expected: expected))
func inMap(first: bool): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posMap, vMap: ErlangSourceBuilderPositionMap(first: first))
func inMapField(expected: ExpectedMapFieldItem): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posMapField,
    vMapField: ErlangSourceBuilderPositionMapField(expected: expected))
func inRecordAttribute(first: bool): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posRecordAttribute,
    vRecordAttribute: ErlangSourceBuilderPositionRecordAttribute(first: first))
func inRecordField(expected: ExpectedRecordFieldItem): ErlangSourceBuilderPosition =
  ErlangSourceBuilderPosition(kind: posRecordField,
    vRecordField: ErlangSourceBuilderPositionRecordField(expected: expected))

const INDENT = 4

func debug(position: ErlangSourceBuilderPosition): string =
  ## What `{:?}` prints for the position upstream (`#[derive(Debug)]`): it is
  ## part of the message of the internal errors.
  func b(value: bool): string = (if value: "true" else: "false")
  let p = position
  case p.kind
  of posFunctionSpec: "FunctionSpec"
  of posTypeSpec: "TypeSpec { expected: " & $p.vTypeSpec.expected & " }"
  of posFunctionType:
    "FunctionType { expected: " & (case p.vFunctionType.expected.kind
      of ftArguments: "Arguments { first: " & b(p.vFunctionType.expected.vArguments.first) & " }"
      of ftReturnType: "ReturnType") &
      ", needs_wrapping: " & b(p.vFunctionType.needsWrapping) & " }"
  of posNamedType: "NamedType { first: " & b(p.vNamedType.first) & " }"
  of posUnionType: "UnionType { first: " & b(p.vUnionType.first) & " }"
  of posTupleType: "TupleType { first: " & b(p.vTupleType.first) & " }"
  of posFunctionStatement: "FunctionStatement { first: " & b(p.vFunctionStatement.first) & " }"
  of posAnonymousFunctionStatement:
    "AnonymousFunctionStatement { first: " & b(p.vAnonymousFunctionStatement.first) & " }"
  of posMatchOperator: "MatchOperator { expected: " & $p.vMatchOperator.expected & " }"
  of posMatchPattern: "MatchPattern { expected: " & $p.vMatchPattern.expected & " }"
  of posList: "List { kind: " & $p.vList.kind & ", expected: " & $p.vList.expected & " }"
  of posUnaryOperator: "UnaryOperator"
  of posTuple: "Tuple { first: " & b(p.vTuple.first) & " }"
  of posTuplePattern: "TuplePattern { first: " & b(p.vTuplePattern.first) & " }"
  of posBitArray:
    "BitArray { kind: " & $p.vBitArray.kind & ", first: " & b(p.vBitArray.first) & " }"
  of posBitArraySegment:
    "BitArraySegment { expected: " & (case p.vBitArraySegment.expected.kind
      of bsValue: "Value { kind: " & $p.vBitArraySegment.expected.vValue.kind & " }"
      of bsSize: "Size"
      of bsSpecifiers: "Specifiers") &
      ", segment_value_needs_wrapping: " & b(p.vBitArraySegment.segmentValueNeedsWrapping) &
      ", segment_size_needs_wrapping: " & b(p.vBitArraySegment.segmentSizeNeedsWrapping) & " }"
  of posBlock: "Block { first: " & b(p.vBlock.first) & " }"
  of posFunctionCall:
    "FunctionCall { expected: " & (case p.vFunctionCall.expected.kind
      of clFunctionToBeCalled: "FunctionToBeCalled"
      of clArguments: "Arguments { first: " & b(p.vFunctionCall.expected.vArguments.first) & " }") &
      ", called_item_needs_wrapping: " & b(p.vFunctionCall.calledItemNeedsWrapping) & " }"
  of posBinaryOperator:
    "BinaryOperator { expected: " & $p.vBinaryOperator.expected & ", needs_wrapping: " &
      b(p.vBinaryOperator.needsWrapping) & ", operator: \"" & p.vBinaryOperator.operator & "\" }"
  of posCase:
    "Case { expected: " & (case p.vCase.expected.kind
      of ciSubject: "Subject"
      of ciBranches: "Branches { first: " & b(p.vCase.expected.vBranches.first) & " }") & " }"
  of posCaseClause:
    "CaseClause { expected: " & (case p.vCaseClause.expected.kind
      of ccPattern: "Pattern"
      of ccGuards: "Guards { first: " & b(p.vCaseClause.expected.vGuards.first) & " }"
      of ccBody: "Body { first: " & b(p.vCaseClause.expected.vBody.first) & " }") & " }"
  of posMap: "Map { first: " & b(p.vMap.first) & " }"
  of posMapField: "MapField { expected: " & $p.vMapField.expected & " }"
  of posRecordAttribute: "RecordAttribute { first: " & b(p.vRecordAttribute.first) & " }"
  of posRecordField: "RecordField { expected: " & $p.vRecordField.expected & " }"
  of posClauseGuard: "ClauseGuard"

func errorWithPosition(self: ErlangSourceBuilder, expected: string): string =
  ## This produces a pretty printed error message including the current
  ## position.
  ##
  ## Upstream takes the position as an argument, and every caller passes the
  ## last one: here it is read from the builder.
  let position =
    if self.position.len == 0: "None" else: "Some(" & debug(self.position[^1]) & ")"
  "tried " & expected & ", position: " & position

template invalid(self: ErlangSourceBuilder, expected: string) =
  ## `invalid_code_for_position!(self, expected)`
  invalidCodeForPosition(self.errorWithPosition(expected))

template top(self: ErlangSourceBuilder): untyped = self.position[^1]
  ## `self.position.last_mut()`, when there is one.

func isAt(self: ErlangSourceBuilder, kind: ErlangSourceBuilderPositionKind): bool =
  ## Whether the last position is of this kind.
  self.position.len > 0 and self.position[^1].kind == kind

# The helpers upstream declares after the trait implementation come first here,
# because Nim wants a proc declared before its use. They are in upstream's order.

func shortestDigits(number: float64): tuple[digits: string, pointAt: int] =
  ## The shortest decimal digits that read back as `number` (positive, finite,
  ## not zero), and where the decimal point goes: the value is
  ## `0.digits * 10^pointAt`. When several shortest decimals read back as
  ## `number`, the one closest to it.
  ##
  ## This is what Rust's `{}` prints for a float (`core::num::flt2dec`, the
  ## Grisu algorithm with Dragon as its fallback, which agree by contract).
  ## Nim's `$` is also a shortest round trip, but it does not always pick the
  ## closest of the candidates, so it cannot be used here. This is the
  ## free-format algorithm of Steele and White as told by Burger and Dybvig
  ## ("Printing Floating-Point Numbers Quickly and Accurately", 1996), with
  ## big integers: slower than Grisu, exact, and short.
  let bits = cast[uint64](number)
  let biased = int((bits shr 52) and 0x7FF)
  let fraction = bits and 0x000F_FFFF_FFFF_FFFF'u64
  # number = mantissa * 2^exponent
  let mantissa = if biased == 0: fraction else: fraction or 0x0010_0000_0000_0000'u64
  let exponent = if biased == 0: -1074 else: biased - 1075
  # A float is read back from any decimal closer to it than to its neighbours.
  # The lower neighbour is half as far when the mantissa is a power of two.
  let closerBelow = fraction == 0 and biased > 1
  # Ties round to the even mantissa, so the ends of the interval read back as
  # `number` only when its mantissa is even.
  let inclusive = (mantissa and 1) == 0
  let one = initBigInt(1)
  let ten = initBigInt(10)
  # number = r / s, and the interval is from (r - mMinus) / s to (r + mPlus) / s.
  var r, s, mPlus, mMinus: BigInt
  if exponent >= 0:
    if not closerBelow:
      r = initBigInt(mantissa) shl (exponent + 1)
      s = initBigInt(2)
      mPlus = one shl exponent
      mMinus = one shl exponent
    else:
      r = initBigInt(mantissa) shl (exponent + 2)
      s = initBigInt(4)
      mPlus = one shl (exponent + 1)
      mMinus = one shl exponent
  else:
    if not closerBelow:
      r = initBigInt(mantissa) shl 1
      s = one shl (1 - exponent)
      mPlus = one
      mMinus = one
    else:
      r = initBigInt(mantissa) shl 2
      s = one shl (2 - exponent)
      mPlus = initBigInt(2)
      mMinus = one
  # Scale so that the first digit generated is the first digit of the number.
  var k = 0
  while (if inclusive: r + mPlus >= s else: r + mPlus > s):
    s = s * ten
    inc k
  while (if inclusive: (r + mPlus) * ten < s else: (r + mPlus) * ten <= s):
    r = r * ten
    mPlus = mPlus * ten
    mMinus = mMinus * ten
    dec k
  var digits = ""
  while true:
    let (quotient, remainder) = divmod(r * ten, s)
    var digit = toInt[int](quotient).get
    r = remainder
    mPlus = mPlus * ten
    mMinus = mMinus * ten
    # Can we stop here, with this digit or with the next one up?
    let low = if inclusive: r <= mMinus else: r < mMinus
    let high = if inclusive: r + mPlus >= s else: r + mPlus > s
    if not low and not high:
      digits.add char(ord('0') + digit)
      continue
    if high and (not low or r * initBigInt(2) >= s):
      inc digit
    digits.add char(ord('0') + digit)
    break
  (digits, k)

func formatFloat(number: float64): string =
  ## Upstream prints with Rust's `{number:.1}` when the float has no fractional
  ## part and with `{number}` otherwise. Rust never uses an exponent: `{}` is
  ## the shortest decimal that reads back as the same float, written in full,
  ## and `{:.1}` of a float without fractional part is its exact value followed
  ## by `.0`.
  if number == 0:
    return if signbit(number): "-0.0" else: "+0.0"
  if number != number: return "NaN"
  if number == Inf: return "inf"
  if number == NegInf: return "-inf"
  result = if number < 0: "-" else: ""
  if number == trunc(number):
    # The exact integer: mantissa times a power of two.
    let bits = cast[uint64](number)
    let exponent = int((bits shr 52) and 0x7FF)
    let fraction = bits and 0x000F_FFFF_FFFF_FFFF'u64
    # A float without fractional part is never subnormal.
    let mantissa = initBigInt(fraction or 0x0010_0000_0000_0000'u64)
    let shift = exponent - 1075
    let value = if shift >= 0: mantissa shl shift else: mantissa shr (-shift)
    result.add $value & ".0"
    return
  let (digits, pointAt) = shortestDigits(abs(number))
  if pointAt <= 0:
    result.add "0." & "0".repeat(-pointAt) & digits
  elif pointAt >= digits.len:
    result.add digits & "0".repeat(pointAt - digits.len)
  else:
    result.add digits[0 ..< pointAt] & "." & digits[pointAt .. ^1]

func escapeLiteralStringContent(content: string): string =
  ## This takes the content of a literal string and escapes it to something
  ## suitable to be used in an Erlang literal string.
  # Upstream uses the regular expression `(\\+)(u)` and a replacement function.
  # `\\u`-s should not be affected, so that "\\u..." is not converted to
  # "\\x...": a `u` becomes an `x` only after an odd number of backslashes.
  var i = 0
  while i < content.len:
    if content[i] == '\\':
      var slashes = 0
      while i < content.len and content[i] == '\\':
        result.add '\\'
        inc slashes
        inc i
      if i < content.len and content[i] == 'u':
        result.add(if slashes mod 2 == 0: 'u' else: 'x')
        inc i
    else:
      result.add content[i]
      inc i

func isErlangReservedWord(name: string): bool =
  case name
  of "!", "receive", "bnot", "div", "rem", "band", "bor", "bxor", "bsl", "bsr", "not", "and",
     "or", "xor", "orelse", "andalso", "when", "end", "fun", "try", "catch", "after", "begin",
     "let", "query", "cond", "if", "of", "case", "maybe", "else": true
  else: false

func atomNameRegexIsMatch(name: string): bool =
  ## Upstream: the regular expression `^[a-z][a-z0-9_@]*$`.
  if name.len == 0 or name[0] notin {'a' .. 'z'}: return false
  for c in name:
    if c notin {'a' .. 'z', '0' .. '9', '_', '@'}: return false
  true

func quoteAtomName(name: string): string =
  ## This wraps an atom name in between single quotes if needed.
  if isErlangReservedWord(name):
    # Escape because of keyword collision
    "'" & name & "'"
  elif atomNameRegexIsMatch(name):
    name
  else:
    # Escape because of characters contained
    "'" & name & "'"

proc pushIndentation(self: var ErlangSourceBuilder) =
  for _ in 0 ..< self.indentation:
    self.code.add ' '

proc popLeftoverItems(self: var ErlangSourceBuilder) =
  ## This has to be called before any `new_x` function. This takes care of
  ## removing all leftover items that do not self close.
  ##
  ## That happens when there's some node that requires code to be pushed
  ## _after_ it is over and it is not closed manually with a `end_x`
  ## function.
  if self.position.len == 0:
    return

  case self.top.kind
  of posTypeSpec:
    case self.top.vTypeSpec.expected
    of TypeSpecExpectedItem.TypeSpecIsOver:
      self.code.add ".\n"
      discard self.position.pop()
      self.popLeftoverItems()
    of TypeSpecExpectedItem.TypeDefinition: discard

  # The expression we're generating is preceded by a list
  # that has been closed. Lists are a bit tricky because they
  # are built as a list of cons cells, so we can't really
  # tell when a list is over until we get to the next
  # expression.
  of posList:
    case self.top.vList.expected
    of ExpectedListItem.ListIsOver:
      self.code.add ']'
      # We remove this leftover list...
      discard self.position.pop()
      # ...and then we can keep going until there's no leftover
      # items left.
      self.popLeftoverItems()
    of ExpectedListItem.First, ExpectedListItem.Rest: discard

  # Like with lists, we don't really know when a binary operator is
  # over until we get to the following operation (or we try closing
  # the current item and notice there's a closed operator left).
  # Also, just like lists, we might still need to add some
  # parentheses _after_ the operator is over.
  of posBinaryOperator:
    case self.top.vBinaryOperator.expected
    of ExpectedBinaryOperatorSide.BinaryOperatorIsOver:
      # If needed add the closing parentheses...
      if self.top.vBinaryOperator.needsWrapping:
        self.code.add ')'
      # ...we remove this leftover binary operator...
      discard self.position.pop()
      # ...and then we can keep going until there's no leftover items
      # left.
      self.popLeftoverItems()
    of ExpectedBinaryOperatorSide.Left, ExpectedBinaryOperatorSide.Right: discard

  # All of these items are not leftovers. They are either still open,
  # require manual closing, or things that don't need closing at all!
  of posNamedType, posUnionType, posTupleType, posFunctionStatement,
     posAnonymousFunctionStatement, posFunctionSpec, posTuple, posTuplePattern, posBitArray,
     posMap, posBlock, posClauseGuard, posUnaryOperator, posFunctionType, posMapField,
     posBitArraySegment, posFunctionCall, posMatchPattern, posCase, posCaseClause,
     posRecordAttribute, posMatchOperator, posRecordField:
    discard

proc newTopLevelForm(self: var ErlangSourceBuilder) =
  ## This has to be called before generating any new top level form: those
  ## are specs like `-spec`, `-type`, `-opaque`, doc attributes like
  ## `-doc` and `-moduledoc`, and function definitions.
  ## This allows the code generator to:
  ## - check for inconsistencies and panic (for example if we're generating
  ##   a top level form not at the top level scope).
  ## - update the current context.
  ## - add all the code that needs to go before this expression we're about
  ##   to generate, based on the current context.
  self.popLeftoverItems()
  if self.position.len != 0:
    self.invalid("top level form")

proc newExpression(self: var ErlangSourceBuilder) =
  ## This has to be called before generating any expression!
  ## This allows the code generator to:
  ## - check for inconsistencies and panic (for example if we're generating
  ##   expressions in the wrong place).
  ## - update the current context.
  ## - add all the code that needs to go before this expression we're about
  ##   to generate, based on the current context.
  self.popLeftoverItems()
  if self.position.len == 0:
    self.invalid("expression")

  template statement(first: untyped) =
    if not first:
      self.code.add ','
    first = false
    self.code.add '\n'
    self.pushIndentation()

  case self.top.kind
  of posRecordField:
    case self.top.vRecordField.expected
    of ExpectedRecordFieldItem.Name:
      self.top.vRecordField.expected = ExpectedRecordFieldItem.Type
    of ExpectedRecordFieldItem.Type: self.invalid("expression")

  of posCase:
    case self.top.vCase.expected.kind
    of ciSubject: self.top.vCase.expected = expectBranches(first = true)
    of ciBranches: self.invalid("expression")

  of posFunctionCall:
    case self.top.vFunctionCall.expected.kind
    of clFunctionToBeCalled:
      if self.top.vFunctionCall.calledItemNeedsWrapping:
        self.code.add '('
      self.top.vFunctionCall.expected = expectCallArguments(first = true)
    of clArguments:
      if self.top.vFunctionCall.calledItemNeedsWrapping:
        self.top.vFunctionCall.calledItemNeedsWrapping = false
        self.code.add ')'
      if self.top.vFunctionCall.expected.vArguments.first:
        self.code.add '('
      else:
        self.code.add ", "
      self.top.vFunctionCall.expected.vArguments.first = false

  of posTuple:
    if not self.top.vTuple.first:
      self.code.add ", "
    self.top.vTuple.first = false

  of posList:
    case self.top.vList.kind
    of ListKind.Expression:
      case self.top.vList.expected
      # We're expecting the list's head. We don't have to add
      # anything!
      of ExpectedListItem.First: self.top.vList.expected = ExpectedListItem.Rest
      of ExpectedListItem.Rest:
        self.top.vList.expected = ExpectedListItem.ListIsOver
        self.code.add " | "
      of ExpectedListItem.ListIsOver: self.invalid("expression")
    of ListKind.Pattern: self.invalid("expression")

  of posBinaryOperator:
    case self.top.vBinaryOperator.expected
    of ExpectedBinaryOperatorSide.Left:
      self.top.vBinaryOperator.expected = ExpectedBinaryOperatorSide.Right
    of ExpectedBinaryOperatorSide.Right:
      self.top.vBinaryOperator.expected = ExpectedBinaryOperatorSide.BinaryOperatorIsOver
      self.code.add ' '
      self.code.add self.top.vBinaryOperator.operator
      self.code.add ' '
    of ExpectedBinaryOperatorSide.BinaryOperatorIsOver: self.invalid("expression")

  of posFunctionStatement: statement(self.top.vFunctionStatement.first)
  of posAnonymousFunctionStatement: statement(self.top.vAnonymousFunctionStatement.first)
  of posBlock: statement(self.top.vBlock.first)
  of posCaseClause:
    case self.top.vCaseClause.expected.kind
    of ccBody: statement(self.top.vCaseClause.expected.vBody.first)
    of ccPattern, ccGuards: self.invalid("expression")

  of posBitArraySegment:
    case self.top.vBitArraySegment.expected.kind
    of bsValue:
      case self.top.vBitArraySegment.expected.vValue.kind
      of BitArrayKind.Expression:
        if self.top.vBitArraySegment.segmentValueNeedsWrapping:
          self.code.add '('
        self.top.vBitArraySegment.expected = ExpectedBitArraySegmentItem(kind: bsSize)
      of BitArrayKind.Pattern: self.invalid("expression")
    of bsSize:
      if self.top.vBitArraySegment.segmentValueNeedsWrapping:
        self.code.add ')'
        # We've finished wrapping the value, we set this to
        # false so we don't add other parentheses when we get
        # to the specifiers list!
        self.top.vBitArraySegment.segmentValueNeedsWrapping = false
      self.top.vBitArraySegment.expected = ExpectedBitArraySegmentItem(kind: bsSpecifiers)
      self.code.add ':'
      if self.top.vBitArraySegment.segmentSizeNeedsWrapping:
        self.code.add '('
    of bsSpecifiers: self.invalid("expression")

  of posClauseGuard:
    self.code.add " when "

  of posMapField:
    case self.top.vMapField.expected
    of ExpectedMapFieldItem.Key: self.top.vMapField.expected = ExpectedMapFieldItem.Value
    # We've generated a key and now the value is being generated.
    # So we need to add the `=>` separating key and value and we
    # can pop this position that is now complete.
    of ExpectedMapFieldItem.Value:
      self.code.add " => "
      discard self.position.pop()

  of posMatchOperator:
    case self.top.vMatchOperator.expected
    # We were expecting an expression and someone is about to generate
    # it, we can pop this off the stack and need to add the ` = `
    # separating the previous pattern from this new expression.
    of ExpectedMatchSide.Expression:
      self.code.add " = "
      discard self.position.pop()
    of ExpectedMatchSide.Pattern: self.invalid("expression")

  # We were expecting an expression and someone generated it, we can
  # now pop this off the stack.
  of posUnaryOperator:
    discard self.position.pop()

  # Expressions are not allowed in any of these positions.
  of posBitArray, posTuplePattern, posMatchPattern, posFunctionSpec, posTypeSpec, posNamedType,
     posFunctionType, posUnionType, posTupleType, posMap, posRecordAttribute:
    self.invalid("expression")

proc newType(self: var ErlangSourceBuilder) =
  ## This has to be called before generating any type!
  ## This allows the code generator to:
  ## - check for inconsistencies and panic (for example if we're generating
  ##   types in the wrong place).
  ## - update the current context.
  ## - add all the code that needs to go before this type we're about
  ##   to generate, based on the current context.
  self.popLeftoverItems()
  if self.position.len == 0:
    self.invalid("type")

  template separated(first: untyped, separator: string) =
    if not first:
      self.code.add separator
    first = false

  case self.top.kind
  of posFunctionSpec: discard

  of posFunctionType:
    case self.top.vFunctionType.expected.kind
    of ftReturnType: discard
    of ftArguments: separated(self.top.vFunctionType.expected.vArguments.first, ", ")

  of posTypeSpec:
    case self.top.vTypeSpec.expected
    of TypeSpecExpectedItem.TypeDefinition:
      self.top.vTypeSpec.expected = TypeSpecExpectedItem.TypeSpecIsOver
    of TypeSpecExpectedItem.TypeSpecIsOver: self.invalid("type")

  of posTupleType: separated(self.top.vTupleType.first, ", ")
  of posNamedType: separated(self.top.vNamedType.first, ", ")

  of posUnionType: separated(self.top.vUnionType.first, " | ")

  of posRecordField:
    case self.top.vRecordField.expected
    of ExpectedRecordFieldItem.Type:
      self.code.add " :: "
      discard self.position.pop()
    of ExpectedRecordFieldItem.Name: self.invalid("type")

  of posFunctionCall, posBlock, posTuple, posBitArray, posBitArraySegment, posList,
     posFunctionStatement, posAnonymousFunctionStatement, posUnaryOperator, posCase,
     posClauseGuard, posBinaryOperator, posCaseClause, posMap, posMapField, posMatchOperator,
     posRecordAttribute, posMatchPattern, posTuplePattern:
    self.invalid("type")

proc newPattern(self: var ErlangSourceBuilder) =
  ## This has to be called before generating any pattern!
  ## This allows the code generator to:
  ## - check for inconsistencies and panic (for example if we're generating
  ##   patterns in the wrong place).
  ## - update the current context.
  ## - add all the code that needs to go before this type we're about
  ##   to generate, based on the current context.
  self.popLeftoverItems()
  if self.position.len == 0:
    self.invalid("pattern")

  case self.top.kind
  of posList:
    case self.top.vList.kind
    of ListKind.Pattern:
      case self.top.vList.expected
      # We're expecting the list's head. We don't have to add
      # anything!
      of ExpectedListItem.First: self.top.vList.expected = ExpectedListItem.Rest
      of ExpectedListItem.Rest:
        self.top.vList.expected = ExpectedListItem.ListIsOver
        self.code.add " | "
      of ExpectedListItem.ListIsOver: self.invalid("pattern")
    of ListKind.Expression: self.invalid("pattern")

  of posBitArraySegment:
    case self.top.vBitArraySegment.expected.kind
    of bsValue:
      case self.top.vBitArraySegment.expected.vValue.kind
      of BitArrayKind.Pattern:
        if self.top.vBitArraySegment.segmentValueNeedsWrapping:
          self.code.add '('
        self.top.vBitArraySegment.expected = ExpectedBitArraySegmentItem(kind: bsSize)
      of BitArrayKind.Expression: self.invalid("pattern")
    of bsSize, bsSpecifiers: self.invalid("pattern")

  of posMatchOperator:
    case self.top.vMatchOperator.expected
    # We were waiting for the pattern to be generated, now we're done
    # and can start generating an expression for the right-hand side.
    of ExpectedMatchSide.Pattern: self.top.vMatchOperator.expected = ExpectedMatchSide.Expression
    of ExpectedMatchSide.Expression: self.invalid("pattern")

  of posCaseClause:
    case self.top.vCaseClause.expected.kind
    # We were waiting for the pattern and a pattern has been generated.
    # We don't change this ourselves since the pattern has to be closed
    # explicitly calling `end_clause_pattern`.
    # We don't have to do anything here!
    of ccPattern: discard
    of ccGuards, ccBody: self.invalid("pattern")

  of posTuplePattern:
    if self.top.vTuplePattern.first:
      self.top.vTuplePattern.first = false
    else:
      self.code.add ", "

  of posMatchPattern:
    case self.top.vMatchPattern.expected
    of ExpectedMatchPatternSide.Left:
      self.top.vMatchPattern.expected = ExpectedMatchPatternSide.Right
    # The right hand side is about to be generated so we have to
    # push the ` = ` to separate it from the left hand side, and we
    # can remove this position since the match pattern has now been
    # completed.
    of ExpectedMatchPatternSide.Right:
      self.code.add " = "
      discard self.position.pop()

  of posFunctionCall, posBlock, posFunctionStatement, posAnonymousFunctionStatement,
     posBitArray, posUnaryOperator, posBinaryOperator, posCase, posClauseGuard, posMap,
     posMapField, posTuple, posFunctionType, posFunctionSpec, posTypeSpec, posNamedType,
     posUnionType, posTupleType, posRecordField, posRecordAttribute:
    self.invalid("pattern")

proc closeCurrentlyOpenItem(self: var ErlangSourceBuilder) =
  self.popLeftoverItems()
  if self.position.len == 0:
    return
  let position = self.position.pop()

  case position.kind
  # When we're done generating statements for a function we need to
  # add one final `.` to the last statement. Then we also want to
  # add an empty line to make our code breath a bit better.
  of posFunctionStatement:
    self.indentation -= INDENT
    self.code.add ".\n"
  # When we're done generating statements for an anonymous function
  # we need to add the closing `end` after the last statement on a
  # new line.
  of posAnonymousFunctionStatement:
    self.indentation -= INDENT
    self.code.add '\n'
    self.pushIndentation()
    self.code.add "end"
  # When we're done generating statements for a block we need to add
  # the closing `end`, and reduce the nesting level.
  of posBlock:
    self.indentation -= INDENT
    self.code.add '\n'
    self.pushIndentation()
    self.code.add "end"
  # When we're done generating code for a function spec we want to
  # add a `.` so we can start generating the function itself.
  # Notice one crucial detail: we don't add the newline here, because
  # that will be added by the function that is generated right after
  # this. We do it this way so that, even if we're generating
  # functions that have no annotation (like the echo functions
  # automatically added by the compiler), they will be spaced
  # correctly!
  of posFunctionSpec: self.code.add '.'
  of posFunctionCall:
    case position.vFunctionCall.expected.kind
    # When we're done generating the arguments of a function we need
    # to add the closed parentheses for the function call!
    of clArguments:
      if position.vFunctionCall.calledItemNeedsWrapping:
        self.code.add ')'

      # If the function is closed with no arguments being generated
      # then we will need to add both the open and closed
      # parentheses. That's because the open paren is added when the
      # first argument is generated.
      if position.vFunctionCall.expected.vArguments.first:
        self.code.add "()"
      else:
        self.code.add ')'
    # If we try and close a function for which no called item was
    # generated, then that's an error!
    of clFunctionToBeCalled: self.invalid("pop leftover item")

  # When we're done generating the items of a tuple we need
  # to add the closed curly brace to actually close the tuple.
  of posTupleType, posTuple, posTuplePattern: self.code.add '}'
  # When we're done generating a bit array we can add its closing
  # element.
  of posBitArray: self.code.add ">>"

  of posFunctionType:
    case position.vFunctionType.expected.kind
    # When the function type arguments are over we add what we need for
    # the return type.
    of ftArguments:
      # After popping the argument, we now need to wait for the
      # return type!
      self.position.add inFunctionType(
        expected = ExpectedFunctionTypeItem(kind: ftReturnType),
        needsWrapping = position.vFunctionType.needsWrapping)
      self.code.add ") -> "
    # If we close a function type we need to check what the current
    # state is. If we were generating this for a type spec we're done.
    # But if we were generating this as a type inside another we need to
    # add one further parentheses to close the `fun(...)` around the
    # function type.
    #
    # ```erl
    # % in a spec annotation it simply comes after the function name:
    # -spec wibble () -> integer().
    # wibble() -> 11.
    #
    # % but inside another type it has to be wrapped in `fun(...)`:
    # -spec wobble () -> fun(() -> integer())
    # %                                     ^ We're adding this bit here!
    # wobble() -> fun wibble/0.
    # ```
    of ftReturnType:
      if position.vFunctionType.needsWrapping:
        self.code.add ')'
  # When a named type is over we need to add the closing parentheses.
  of posNamedType: self.code.add ')'
  # There's nothing left to do when a union type ends.
  of posUnionType: discard
  of posCase:
    case position.vCase.expected.kind
    # When a case expression is over, we need to add the closing `end`.
    of ciBranches:
      self.indentation -= INDENT
      self.code.add '\n'
      self.pushIndentation()
      self.code.add "end"
    of ciSubject: self.invalid("pop leftover item")

  of posClauseGuard: discard
  of posCaseClause:
    case position.vCaseClause.expected.kind
    of ccPattern: discard
    # When the guards of a case clause are over we need to add the
    # arrow before the body is generated.
    of ccGuards: self.code.add " ->"
    of ccBody:
      self.indentation -= INDENT
  # We're done with a map, we can add the closed parentheses and
  # reduce nesting.
  of posMap:
    self.indentation -= INDENT
    self.code.add '\n'
    self.pushIndentation()
    self.code.add '}'
  of posRecordAttribute:
    self.indentation -= INDENT
    self.code.add '\n'
    self.pushIndentation()
    self.code.add "})."

  of posMapField, posRecordField, posMatchPattern, posUnaryOperator, posList,
     posBinaryOperator, posMatchOperator, posTypeSpec, posBitArraySegment:
    self.invalid("pop leftover item")

proc escapeStringContent(self: ErlangSourceBuilder, content: string): string =
  ## Given the content of something that has to end up inside an Erlang
  ## literal string `~"..."` this escapes its content based on
  ## position-specific rules: depending where we will be putting the string
  ## (and so depending where it comes from) it might need different things to
  ## be escaped!
  ##
  ## For example, if we're given the content of a literal Gleam string, we
  ## know that some charachters like double quotes are going to be escaped
  ## already:
  ##
  ## ```gleam
  ## let some_gleam_string = "wibble\"wobble"
  ## ```
  ##
  ## After all, if those weren't escaped our Gleam program would have a
  ## syntax error and not compile!
  ##
  ## However, there's other pieces of syntax that might be turned into
  ## literal Erlang strings: doc comments. In that case those can contain
  ## unescaped characters. For example:
  ##
  ## ```gleam
  ## /// This is a doc comment that has unescaped double quotes ""
  ## ```
  ##
  ## If we were to just take that comment's content and put it in an Erlang
  ## string with no escaping that would produce invalid code!
  if self.position.len == 0:
    raiseAssert "escaping string in the top level scope"

  case self.position[^1].kind
  of posFunctionSpec, posTypeSpec, posFunctionType, posNamedType, posUnionType,
     posRecordAttribute, posTupleType:
    self.invalid("escaping string")

  of posFunctionCall, posFunctionStatement, posAnonymousFunctionStatement, posList,
     posUnaryOperator, posTuple, posTuplePattern, posBitArray, posBitArraySegment, posBlock,
     posBinaryOperator, posCase, posCaseClause, posClauseGuard, posMap, posMapField,
     posMatchPattern, posRecordField, posMatchOperator:
    # When pretty printing we want the resulting code to be regular
    # executable Erlang code.
    # If we're tasked with escaping the content of a literal string
    # expression we need to turn Gleam's `\u` sequences into
    # Erlang's `\x`.
    escapeLiteralStringContent(content)

proc newBitArraySegment(self: var ErlangSourceBuilder): BitArrayKind =
  self.popLeftoverItems()
  if not self.isAt(posBitArray):
    self.invalid("bit array segment")

  if self.top.vBitArray.first:
    self.top.vBitArray.first = false
  else:
    self.code.add ", "

  self.top.vBitArray.kind

proc newCaseClause(self: var ErlangSourceBuilder) =
  self.popLeftoverItems()
  if not (self.isAt(posCase) and self.top.vCase.expected.kind == ciBranches):
    self.invalid("case clause")

  if self.top.vCase.expected.vBranches.first:
    self.top.vCase.expected.vBranches.first = false
    self.code.add " of\n"
    self.indentation += INDENT
  else:
    self.code.add ";\n\n"
  self.code.add " ".repeat(self.indentation)

proc newMapField(self: var ErlangSourceBuilder) =
  self.popLeftoverItems()
  if not self.isAt(posMap):
    self.invalid("map field")

  if self.top.vMap.first:
    self.top.vMap.first = false
    self.code.add '\n'
  else:
    self.code.add ",\n"
  self.code.add " ".repeat(self.indentation)

proc newClauseGuard(self: var ErlangSourceBuilder) =
  self.popLeftoverItems()
  if not (self.isAt(posCaseClause) and self.top.vCaseClause.expected.kind == ccGuards and
      self.top.vCaseClause.expected.vGuards.first):
    self.invalid("new clause guard")

  self.top.vCaseClause.expected.vGuards.first = false

proc doNotWrapIfSegmentValueOrSize(self: var ErlangSourceBuilder) =
  ## You can call this before generating any expression (before the
  ## `new_expression` call) if we can skip wrapping it in parentheses when it
  ## appears as a bitstring segment value.
  ## This is opt-out rather than opt-in: it's always safe to wrap everything,
  ## but it leads to slightly uglier code for some values like bare integers.
  ## For example:
  ##
  ## ```erl
  ## <<(1)/signed>>
  ## % ^ ^ Those are not needed at all!
  ## ```
  ##
  ## So for those values that you know are safe and would look better you can
  ## use this function.
  self.popLeftoverItems()
  # If we're about to generate a bit array segment value, or a size,
  # then we can skip the wrapping, otherwise this is not needed at all!
  if self.isAt(posBitArraySegment):
    case self.top.vBitArraySegment.expected.kind
    of bsValue: self.top.vBitArraySegment.segmentValueNeedsWrapping = false
    of bsSize: self.top.vBitArraySegment.segmentSizeNeedsWrapping = false
    of bsSpecifiers: discard

proc doPrintStringContent(self: var ErlangSourceBuilder, content: string) =
  ## This can be used to output the content of a string wether that is a
  ## pattern or an expression!
  let content = self.escapeStringContent(content)
  # If we're generating a string as a bit array segment value we want to
  # output slightly different code: rather than a bit array we want to
  # output a regular string with no modifiers which are going to be added
  # later as the segment is created
  #
  # the call to `new_expression` at the beginning is going to advance
  # the state to expect the `::Size`, that means the code we are
  # outputting now was expected to be the the `::Value` of the bit
  # array segment!
  # We can't move the `new_expression` call down, that _must_ be the
  # first thing we do, so we check to see if the size if the next
  # thing we're expecting to see.
  if self.isAt(posBitArraySegment) and self.top.vBitArraySegment.expected.kind == bsSize:
    self.code.add '"'
    self.code.add content
    self.code.add '"'
  else:
    self.code.add "~\""
    self.code.add content
    self.code.add '"'

proc consListOfKind(self: var ErlangSourceBuilder, listKind: ListKind) =
  self.popLeftoverItems()
  # If we were expecting the rest of a list and we generate a new
  # cons cell we can keep adding commas to separate items: we want
  # to show `[1, 2, 3]` rather than `[1 | [2 | [3 | []]]]`
  if self.isAt(posList) and self.top.vList.expected == ExpectedListItem.Rest and
      self.top.vList.kind == listKind:
    self.top.vList.expected = ExpectedListItem.First
    self.code.add ", "
  # Otherwise we have to properly start a new list: push the `[` and
  # wait for the first item to be generated.
  else:
    case listKind
    of ListKind.Pattern: self.newPattern()
    of ListKind.Expression: self.newExpression()
    self.code.add '['
    self.position.add inList(kind = listKind, expected = ExpectedListItem.First)

proc emptyListOfKind(self: var ErlangSourceBuilder, listKind: ListKind) =
  self.popLeftoverItems()
  # If we were building a cons list and were expecting the end of the
  # list then we have to special case this: we don't want to render
  # it as: `[1, 2 | []]`, but as `[1, 2]`.
  if self.isAt(posList) and self.top.vList.expected == ExpectedListItem.Rest and
      self.top.vList.kind == listKind:
    # Crucially we don't want to call `new_expression` here: we
    # don't want the default handling.
    self.code.add ']'
    # The list is over, so we pop it away.
    discard self.position.pop()
  else:
    case listKind
    of ListKind.Pattern: self.newPattern()
    of ListKind.Expression: self.newExpression()
    self.code.add "[]"

proc newRecordField(self: var ErlangSourceBuilder) =
  self.popLeftoverItems()
  if not self.isAt(posRecordAttribute):
    raiseAssert "tried generating record field outside of record attribute"

  if self.top.vRecordAttribute.first:
    self.top.vRecordAttribute.first = false
  else:
    self.code.add ','
  self.code.add '\n'
  self.pushIndentation()

proc docContent(self: var ErlangSourceBuilder, content: DocContent) =
  case content.kind
  of dcFalse: self.code.add "false"
  # Escaping strings generated inside doc attributes is a little
  # different: since their content doesn't come from a Gleam
  # literal string but freeform text, their content might contain
  # all sorts of unescaped characters.
  of dcString:
    self.code.add "~\""
    self.code.add content.vString.replace("\\", "\\\\").replace("\"", "\\\"")
    self.code.add '"'


## How does pretty printing work? Here's a high level overview of how it works:
##
## - When a new element is generated we call the `new_x` method.
##   If I'm generating an integer (or any expression) I call `new_expression`;
##   if I'm generating a pattern I call `new_pattern`.
## - The `new_x` functions make sure that we're allowed to generate that
##   element in the current context (for example if I'm generating a tuple type
##   I can't start generating expression)!
## - The `new_x` functions also make sure to add any code that is needed before
##   this new expression we're about to generate given the current context.
##   For example, say we're generating the items of a tuple, and we add another
##   one: first the call to `new_expression` is going to make sure to add
##   a comma to separate the previous item from the new one.
##
## - Then we can start pushing the code needed to generate whatever it is we
##   are generating. If it's something simple like an integer we can just push
##   its string representation.
## - There's also plenty of elements that are not "self-closing" and will be
##   generated in multiple steps (like function calls, tuples with multiple
##   items, binary operators, ...). In that case we can push a new `position`
##   to update the current context and keep track of what we're doing!
## - Whenever we reach a `end_x` function we can pop the position we pushed on
##   the stack. That's the moment we can add whatever is needed to "close" one
##   of those complex elements. For example if I'm done generating a function's
##   body I can add a full stop at the end of it; if I'm done generating a
##   tuple I can add the final `}` after all the elements, and so on...
##
## - There's one final tricky bit. Not all elements that are generated in
##   multiple steps have a `end_x` function (for example binary operators and
##   assignments). Those will end after a specific sequence of elements is
##   generated.
##   For example, if I call `self.match_operator` I know that it will be over
##   after the next pattern and expression are generated:
##
##   ```text
##   // X = 1
##   builder.match_operator()
##   builder.variable_pattern("X")
##   builder.int(1)
##   ```
##
##   Notice how here we don't have a `start_match_operator` and
##   `end_match_operator`. As you'll see in the implementation these will
##   require a bit of extra book-keeping in the `new_x` functions.

proc moduleDeclaration*(self: var ErlangSourceBuilder, moduleName: ErlangModuleName) =
  ## Adds to the module a `-module` attribute with the given name.
  self.newTopLevelForm()
  self.code.add "-module("
  self.code.add quoteAtomName(moduleName.name)
  self.code.add ").\n"

proc intoOutput*(self: var ErlangSourceBuilder): string =
  ## Consumes the given `ErlangBuilder` turning it into some other
  ## representation.
  ## For example that might be a binary representation, or a textual pretty
  ## printed one.
  ##
  ## Upstream this takes the builder by value: do not use it afterwards.
  self.closeCurrentlyOpenItem()
  self.code.add '\n'
  self.code

proc exportAttribute*(self: var ErlangSourceBuilder, exported: openArray[(string, int)]) =
  ## Adds to the module an export attribute for the given exported functions.
  ##
  ## For example:
  ##
  ## ```text
  ## builder.export_attribute(vec![("wibble", 1), ("wobble", 2)]);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## -export([wibble/1, wobble/2]).
  ## ```
  # If there's no item in the iterator we don't add the attribute at all.
  if exported.len == 0:
    return

  self.newTopLevelForm()

  self.code.add "-export(["
  var first = true
  for (name, arity) in exported.items:
    if first:
      first = false
    else:
      self.code.add ", "

    self.code.add quoteAtomName(name)
    self.code.add '/'
    self.code.add $arity
  self.code.add "]).\n"

proc exportTypeAttribute*(self: var ErlangSourceBuilder, exported: openArray[(string, int)]) =
  ## Adds to the module an export_type attribute for the given exported types.
  ##
  ## For example:
  ##
  ## ```text
  ## builder.export_attribute(vec![("wibble", 1), ("wobble", 2)]);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## -export_type([wibble/1, wobble/2]).
  ## ```
  # If there's no item in the iterator we don't add the attribute at all.
  if exported.len == 0:
    return

  self.newTopLevelForm()

  self.code.add "-export_type(["
  var first = true
  for (name, arity) in exported.items:
    if first:
      first = false
    else:
      self.code.add ", "

    self.code.add quoteAtomName(name)
    self.code.add '/'
    self.code.add $arity
  self.code.add "]).\n"

proc docAttribute*(self: var ErlangSourceBuilder, content: DocContent) =
  ## Creates a `-doc` attribute with the given content.
  ## For example:
  ##
  ## ```text
  ## todo!()
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## -doc(false).
  ## ```
  self.newTopLevelForm()
  self.code.add "\n-doc("
  self.docContent(content)
  self.code.add ")."

proc moduledocAttribute*(self: var ErlangSourceBuilder, content: DocContent) =
  ## Creates a `-moduledoc` attribute with the given content.
  ## For example:
  ##
  ## ```text
  ## todo!()
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## -moduledoc(false).
  ## ```
  self.newTopLevelForm()
  self.code.add "-moduledoc("
  self.docContent(content)
  self.code.add ").\n"

proc compileAttribute*(self: var ErlangSourceBuilder, arguments: openArray[string]) =
  ## This generates the code for a `-compile([]).` attribute where all the
  ## strings produces by the given iterator are going to be passed as atom
  ## literals.
  ##
  ## For example:
  ##
  ## ```text
  ## builder.compile_attribute(vec!["no_warn", "inline"]);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## -compile([no_warn, inline]).
  ## ```
  self.newTopLevelForm()

  self.code.add "-compile(["

  var first = true
  for argument in arguments:
    if first:
      first = false
    else:
      self.code.add ", "

    self.code.add argument
  self.code.add "]).\n"

proc moduleFileAttribute*(self: var ErlangSourceBuilder, file: string) =
  ## This generates a `-file` attribute, to be used at the start of a module
  ## to set the proper file for the entire module.
  ## For example:
  ##
  ## ```text
  ## builder.module_file_attribute("wibble.gleam");
  ## ```
  ##
  ## Correspods to:
  ##
  ## ```erl
  ## -file("wibble.gleam", 0).
  ## ```
  # This does nothing for the textual pretty printer.
  # All functions are gonna have their own annotation with a line number
  # too, so this would be redundant.
  #
  # It's actually something we only need in the binary format!
  discard

proc startRecordAttribute*(self: var ErlangSourceBuilder, recordName: string): Unit =
  ## Starts a `-record` attribute.
  ## After this you're supposed to generate a sequence of `record_field`, and
  ## once you're done you must end it with `end_record_attribute`.
  ##
  ## For example:
  ##
  ## ```text
  ## let record = builder.start_record_attribute("wobble");
  ## builder.record_field();
  ## builder.atom("wibble");
  ## builder.literal_atom_type("ok");
  ## builder.close_record_attribute(record);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## -record(wobble, { wibble :: ok }).
  ## ```
  self.newTopLevelForm()
  self.code.add "-record("
  self.code.add quoteAtomName(recordName)
  self.code.add ", {"
  self.indentation += INDENT
  self.position.add inRecordAttribute(first = true)

proc endRecordAttribute*(self: var ErlangSourceBuilder, record: Unit) =
  ## This closes the currently open record attribute.
  ## Code generated after this is not gonna be part of it.
  self.closeCurrentlyOpenItem()

proc recordField*(self: var ErlangSourceBuilder) =
  ## This creates a record field inside a record attribute.
  ## After this you're supposed to generate two things:
  ## - an atom representing the name of the field
  ## - a type representing the type of the field
  ##
  ## For an example on how to use this you can check the
  ## `start_record_attribute` docs.
  self.newRecordField()
  self.position.add inRecordField(expected = ExpectedRecordFieldItem.Name)

proc startFunctionSpec*(self: var ErlangSourceBuilder, name: string, arity: int): Unit =
  ## This starts a function type spec.
  ## Everything that is generated after this call is interpreted as the
  ## annotated type of the function. So this must be followed by a single
  ## function type.
  ##
  ## After that is complete, this has to be closed using `end_function_spec`.
  ##
  ## For example:
  ##
  ## ```text
  ## let spec = builder.start_function_spec("wibble", 1)
  ## let function_type = builder.start_function_type();
  ## builder.int_type();
  ## let function_type = builder.end_function_type_arguments(function_type);
  ## builder.variable_type("A");
  ## builder.end_function_type(function_type);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## -spec wibble(integer(), A) -> A.
  ## ```
  self.newTopLevelForm()
  self.code.add "\n-spec "
  self.code.add quoteAtomName(name)
  self.position.add inFunctionSpec()

proc endFunctionSpec*(self: var ErlangSourceBuilder, functionSpec: Unit) =
  ## This closes the currently open function spec.
  ## Code generated after this is not gonna be part of this function spec.
  self.closeCurrentlyOpenItem()

proc startTypeSpec*(self: var ErlangSourceBuilder, opaque: bool, name: string,
                    typeVariables: openArray[string]): Unit =
  ## This starts an Erlang type spec.
  ## After this call you're expected to generate a single type; that's going
  ## to be the definition of the type.
  ## After that is done you should call `end_type_spec`.
  ##
  ## For example:
  ##
  ## ```text
  ## let spec = builder.start_type_spec(false, "wibble", ["A"]);
  ##
  ## let union = builder.start_union_type();
  ## builder.literal_atom_type("nil");
  ##
  ## let list = builder.start_named_type("list");
  ## builder.type_variable("A")
  ## builder.close_named_type();
  ##
  ## builder.end_union_type(union);
  ## builder.end_type_spec(spec);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## -spec wibble(A) :: nil | list(A).
  ## ```
  self.newTopLevelForm()
  self.code.add '\n'
  self.code.add(if opaque: "-opaque " else: "-type ")
  self.code.add quoteAtomName(name)
  self.code.add '('

  var first = true
  for typeVariable in typeVariables:
    if first:
      first = false
    else:
      self.code.add ", "
    self.code.add typeVariable
  self.code.add ") :: "
  self.position.add inTypeSpec(expected = TypeSpecExpectedItem.TypeDefinition)

proc endTypeSpec*(self: var ErlangSourceBuilder, typeSpec: Unit) =
  # For the pretty printer type specs do not need any extra book keeping.
  # Ending one does nothing because the spec is already over and doesn't
  # change the builder's position.
  discard

proc startFunctionType*(self: var ErlangSourceBuilder): Unit =
  ## This starts a function type.
  ## Any code generated after this is gonna be an argument type of the open
  ## function type until `end_function_type_arguments` is called.
  ## After that you must generate a single type that's gonna be the return
  ## type, and then end the function.
  ##
  ## For example:
  ##
  ## ```text
  ## let function_type = builder.start_function_type();
  ## builder.int_type();
  ## builder.variable_type("A");
  ## let function_type builder.end_function_type_arguments(function_type);
  ## builder.variable_type("A");
  ## builder.end_function_type(function_type);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## (integer(), A) -> A.
  ## ```
  self.newType()

  let needsWrapping =
    if self.isAt(posFunctionSpec):
      self.code.add '('
      false
    else:
      self.code.add "fun(("
      true

  self.position.add inFunctionType(
    expected = expectArguments(first = true), needsWrapping = needsWrapping)

proc endFunctionTypeArguments*(self: var ErlangSourceBuilder, functionType: Unit): Unit =
  ## This closes the currently open function type arguments list.
  ## This means that the next type that is generated is going to be the
  ## return type of the open function type.
  ##
  ## After that you must call `end_function_type` to close the function
  ## type.
  self.closeCurrentlyOpenItem()

proc endFunctionType*(self: var ErlangSourceBuilder, functionType: Unit) =
  ## This closes the currently open function type arguments list.
  ## This means that the next type that is generated is going to be the
  ## return type of the open function type.
  ##
  ## After that you must call `end_function_type` to close the function
  ## type.
  self.closeCurrentlyOpenItem()

proc startBuiltInNamedType*(self: var ErlangSourceBuilder, typ: ErlangBuiltInType): Unit =
  ## This starts a built-in Erlang named type with the given name.
  ## Any code generated after this is gonna be an argument of the open
  ## named type type until `end_named_type` is called.
  ##
  ## For example:
  ##
  ## ```text
  ## let type_ = builder.start_named_type("any");
  ## builder.end_named_type(type_);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## any().
  ## ```
  self.newType()
  self.position.add inNamedType(first = true)
  self.code.add typ.asStr
  self.code.add '('

proc startCustomNamedType*(self: var ErlangSourceBuilder, name: string): Unit =
  ## This starts a user defined named type with the given name.
  ## Any code generated after this is gonna be an argument of the open
  ## named type type until `end_named_type` is called.
  ##
  ## For example:
  ##
  ## ```text
  ## let type_ = builder.start_named_type("wibble");
  ## builder.end_named_type(type_);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## wibble().
  ## ```
  self.newType()
  self.position.add inNamedType(first = true)
  self.code.add quoteAtomName(name)
  self.code.add '('

proc endNamedType*(self: var ErlangSourceBuilder, namedType: Unit) =
  ## This takes a named type and closes it.
  ## Code generated after this is not gonna be part of this named type.
  self.closeCurrentlyOpenItem()

proc startRemoteNamedType*(self: var ErlangSourceBuilder, module: ErlangModuleName,
                           name: string): Unit =
  ## This starts a remote named type with the given module and name.
  ## Any code generated after this is gonna be an argument of the open
  ## named type type until `end_named_type` is called.
  ##
  ## For example:
  ##
  ## ```text
  ## let type_ = builder.start_remote_named_type("wibble", "wobble");
  ## builder.end_named_type(type_);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## wibble:wobble().
  ## ```
  self.newType()
  self.position.add inNamedType(first = true)
  self.code.add quoteAtomName(module.name)
  self.code.add ':'
  self.code.add quoteAtomName(name)
  self.code.add '('

proc endRemoteNamedType*(self: var ErlangSourceBuilder, namedType: Unit) =
  ## This takes a remote named type and closes it.
  ## Code generated after this is not gonna be part of this named type.
  self.closeCurrentlyOpenItem()

proc startTupleType*(self: var ErlangSourceBuilder): Unit =
  ## This starts a tuple type.
  ## Any code generated after this is gonna be one of the tuple items.
  ##
  ## For example:
  ##
  ## ```text
  ## let tuple = builder.start_tuple_type();
  ## builder.literal_atom_type("nil");
  ## builder.literal_atom_type("ok");
  ## builder.end_tuple_type(tuple);
  ## ```
  ##
  ## Corresponds to the following Erlang type:
  ##
  ## ```erl
  ## {nil, ok}.
  ## ```
  self.newType()
  self.position.add inTupleType(first = true)
  self.code.add '{'

proc endTupleType*(self: var ErlangSourceBuilder, tupl: Unit) =
  ## This takes a tuple type and closes it.
  ## Code generated after this is not gonna be part of this tuple type.
  self.closeCurrentlyOpenItem()

proc startUnionType*(self: var ErlangSourceBuilder): Unit =
  ## This starts a union type.
  ## Any code generated after this is gonna be a possible alternative of this
  ## type.
  ##
  ## For example:
  ##
  ## ```text
  ## let ok_or_error = builder.start_union_type();
  ## builder.literal_atom_type("ok");
  ## builder.literal_atom_type("error");
  ## builder.end_union_type(ok_or_error);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## ok | error.
  ## ```
  self.newType()
  self.position.add inUnionType(first = true)

proc endUnionType*(self: var ErlangSourceBuilder, unionType: Unit) =
  ## This takes a union type and closes it.
  ## Code generated after this is not gonna be part of this union type.
  self.closeCurrentlyOpenItem()

proc typeVariable*(self: var ErlangSourceBuilder, name: string) =
  ## This generated the code for a type variable with the given name.
  ##
  ## For example, if we were to define the type of the identity function we
  ## could do it like this:
  ##
  ## ```text
  ## let function = builder.start_function_type();
  ## builder.type_variable("A");
  ## let function = builder.end_function_type_arguments();
  ## builder.type_variable("A");
  ## builder.end_function(function);
  ## ```
  ##
  ## And it corresponds to:
  ##
  ## ```erl
  ## (A) -> A.
  ## ```
  self.newType()
  self.code.add name

proc literalAtomType*(self: var ErlangSourceBuilder, name: string) =
  ## This generated the code for a literal atom type (as opposed to the
  ## type `atom()`).
  ##
  ## For example, the annotation of a function returning the atom `nil`
  ## is be defined like this:
  ##
  ## ```text
  ## let function = builder.start_function_type();
  ## let function = builder.end_function_type_arguments();
  ## builder.literal_atom_type("nil");
  ## builder.end_function(function);
  ## ```
  ##
  ## And it corresponds to:
  ##
  ## ```erl
  ## % type of a function returning nil!
  ## () -> nil.
  ## ```
  self.newType()
  self.code.add quoteAtomName(name)

proc startFunction*(self: var ErlangSourceBuilder, location: SrcSpan, name: string, arity: int,
                    argumentsNames: openArray[(SrcSpan, string)]): Unit =
  ## This starts a function type spec.
  ## Everything that is generated after this call is interpreted as the
  ## annotated type of the function. So this must be followed by a single
  ## function type.
  ##
  ## After that is complete, this has to be closed using `end_function_spec`.
  ##
  ## For example:
  ##
  ## ```text
  ## let spec = builder.start_function_spec("wibble", 1)
  ## let function_type = builder.start_function_type();
  ## builder.int_type();
  ## let function_type = builder.end_function_type_arguments(function_type);
  ## builder.variable_type("A");
  ## builder.end_function_type(function_type);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## -spec wibble(integer(), A) -> A.
  ## ```
  self.newTopLevelForm()
  self.code.add '\n'
  self.code.add quoteAtomName(name)
  self.code.add '('

  var first = true
  for (argumentLocation, argument) in argumentsNames.items:
    if not first:
      self.code.add ", "
    else:
      first = false
    self.code.add argument

  self.code.add ") ->"
  self.indentation += INDENT
  self.position.add inFunctionStatement(first = true)

proc startAnonymousFunction*(self: var ErlangSourceBuilder, location: SrcSpan,
                             argumentsNames: openArray[(SrcSpan, string)]): Unit =
  ## This starts an expression defining an anonymous function.
  ## Any code generated after this is gonna be a statement inside the
  ## anonymous function's body until `end_anonymous_function` is called.
  ##
  ## For example:
  ##
  ## ```text
  ## let function = builder.start_anonymous_function([]);
  ## builder.string("Erlang rocks");
  ## builder.end_anonymous_function(function);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## fun() -> ~"Erlang rocks" end.
  ## ```
  self.newExpression()
  self.code.add "fun("

  var first = true
  for (argumentLocation, argument) in argumentsNames.items:
    if not first:
      self.code.add ", "
    else:
      first = false
    self.code.add argument

  self.code.add ") ->"
  self.indentation += INDENT
  self.position.add inAnonymousFunctionStatement(first = true)

proc endFunction*(self: var ErlangSourceBuilder, function: Unit) =
  ## This closes the currently open function spec.
  ## Code generated after this is not gonna be part of this function spec.
  self.closeCurrentlyOpenItem()

proc startBlock*(self: var ErlangSourceBuilder, location: SrcSpan): Unit =
  ## This starts a block expression.
  ## Any code generated after this is gonna be a statement inside the open
  ## block.
  ##
  ## For example:
  ##
  ## ```text
  ## let block = builder.start_block();
  ## builder.string("Giacomo");
  ## builder.int(1);
  ## builder.end_block(block);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## begin
  ##   ~"Giacomo",
  ##   1
  ## end.
  ## ```
  self.newExpression()
  self.code.add "begin"
  self.indentation += INDENT
  self.position.add inBlock(first = true)

proc endBlock*(self: var ErlangSourceBuilder, blck: Unit) =
  ## This takes a block and closes it.
  ## Code generated after this is not gonna be part of this block.
  self.closeCurrentlyOpenItem()

proc wrapIfBeingCalled(self: var ErlangSourceBuilder) =
  ## Not a function upstream: these lines are written twice there, in
  ## `start_remote_call` and in `start_call`.
  ##
  # If this function call we're generating is itself being called then
  # it is going to need to be wrapped in parentheses to be valid in
  # OTP 28: it is not ok to write `wibble()()`, but we have to write
  # `(wibble())()`.
  if self.isAt(posFunctionCall) and self.top.vFunctionCall.expected.kind == clFunctionToBeCalled:
    self.top.vFunctionCall.calledItemNeedsWrapping = true

proc startRemoteCall*(self: var ErlangSourceBuilder, location: SrcSpan, module: ErlangModuleName,
                      function: string): Unit =
  ## This starts a remote call.
  ## Any code generated after this is gonna be an argument of the open
  ## function call `end_call` is called.
  ##
  ## For example:
  ##
  ## ```text
  ## let call = builder.start_remote_call("io", "format");
  ## builder.string("Giacomo");
  ## builder.end_call(call);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## io:format(~"Giacomo").
  ## ```
  self.popLeftoverItems()
  self.wrapIfBeingCalled()

  self.newExpression()
  self.code.add quoteAtomName(module.name)
  self.code.add ':'
  self.code.add quoteAtomName(function)
  self.position.add inFunctionCall(
    expected = expectCallArguments(first = true), calledItemNeedsWrapping = false)

proc startCall*(self: var ErlangSourceBuilder, location: SrcSpan): Unit =
  ## This starts a function call.
  ## The expression generated immediately after this is going to be the thing
  ## that is called, after generating it you must call the
  ## `end_called_expression` function and generate its arguments.
  ##
  ## For example:
  ##
  ## ```text
  ## let call = builder.start_call();
  ## builder.atom("wibble")
  ## let call = builder.end_called_expression(call);
  ## builder.string("Hello");
  ## builder.string("Giacomo");
  ## builder.end_call(call);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## wibble(~"Hello", ~"Giacomo").
  ## ```
  self.popLeftoverItems()
  self.wrapIfBeingCalled()

  self.newExpression()
  self.position.add inFunctionCall(
    expected = ExpectedCallItem(kind: clFunctionToBeCalled), calledItemNeedsWrapping = false)

proc endCalledExpression*(self: var ErlangSourceBuilder, called: Unit): Unit =
  ## This must be called after generating the expression that is called in a
  ## function call. After that you can generate the arguments of the function
  ## call.
  # We need to make sure that just a single expression was generated as
  # the called expression.
  # So we can assert that we're no longer expecting the called expression
  # but the arguments, and none has been generated yet.
  self.popLeftoverItems()
  if not (self.isAt(posFunctionCall) and self.top.vFunctionCall.expected.kind == clArguments and
      self.top.vFunctionCall.expected.vArguments.first):
    self.invalid("end called expression")

proc endCall*(self: var ErlangSourceBuilder, call: Unit) =
  ## This must be called after generating the expression that is called in a
  ## function call. After that you can generate the arguments of the function
  ## call.
  self.closeCurrentlyOpenItem()

proc startTuple*(self: var ErlangSourceBuilder, location: SrcSpan): Unit =
  ## This starts a tuple type.
  ## Any code generated after this is gonna be one of the tuple items.
  ##
  ## For example:
  ##
  ## ```text
  ## let tuple = builder.start_tuple_type();
  ## builder.literal_atom_type("nil");
  ## builder.literal_atom_type("ok");
  ## builder.end_tuple_type(tuple);
  ## ```
  ##
  ## Corresponds to the following Erlang type:
  ##
  ## ```erl
  ## {nil, ok}.
  ## ```
  self.newExpression()
  self.code.add '{'
  self.position.add inTuple(first = true)

proc endTuple*(self: var ErlangSourceBuilder, tupl: Unit) =
  ## This takes a tuple type and closes it.
  ## Code generated after this is not gonna be part of this tuple type.
  self.closeCurrentlyOpenItem()

proc startMap*(self: var ErlangSourceBuilder, location: SrcSpan): Unit =
  ## This starts an Erlang map.
  ## After this call you can add fields to the map using the `map_field`
  ## function.
  ##
  ## For example:
  ##
  ## ```text
  ## let map = builder.start_map();
  ##
  ## builder.map_field();
  ## builder.atom("gleam_error")
  ## builder.atom("todo");
  ##
  ## builder.map_field();
  ## builder.atom("line");
  ## builder.int(6.into());
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## #{
  ##   gleam_error => todo,
  ##   line => 6
  ## }.
  ## ```
  self.newExpression()
  self.code.add "#{"
  self.indentation += INDENT
  self.position.add inMap(first = true)

proc endMap*(self: var ErlangSourceBuilder, map: Unit) =
  ## This takes an open map and closes it.
  ## Code generated after this is not gonna be a map field.
  self.closeCurrentlyOpenItem()

proc mapField*(self: var ErlangSourceBuilder, location: SrcSpan) =
  ## This is used to add new fields to an open map.
  ## After calling this you must generate exactly two values: the first one
  ## is going to be the key, while the second one is going to be the
  ## associated value.
  self.newMapField()
  self.position.add inMapField(expected = ExpectedMapFieldItem.Key)

proc startBitArray*(self: var ErlangSourceBuilder, location: SrcSpan): Unit =
  ## This starts an Erlang bitstring (that's a Gleam's BitArray).
  ## Any code generated after this is gonna be a segment of the bitstring.
  ##
  ## For example:
  ##
  ## ```text
  ## let bit_array = builder.start_bit_array();
  ##
  ## builder.bit_array_segment();
  ## builder.int(1);
  ## builder.bit_array_segment_default_size();
  ## builder.bit_array_segment_specifiers([]);
  ##
  ## builder.bit_array_segment();
  ## builder.string("hello");
  ## builder.bit_array_segment_default_size();
  ## builder.bit_array_segment_specifiers([]);
  ##
  ## builder.end_bit_array(bit_array);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## <<1, ~"hello">>.
  ## ```
  self.doNotWrapIfSegmentValueOrSize()
  self.newExpression()
  self.code.add "<<"
  self.position.add inBitArray(kind = BitArrayKind.Expression, first = true)

proc endBitArray*(self: var ErlangSourceBuilder, bitArray: Unit) =
  ## This takes an open bit array and closes it.
  ## Code generated after this is not gonna be a segment of the bit array.
  self.closeCurrentlyOpenItem()

proc bitArraySegment*(self: var ErlangSourceBuilder, location: SrcSpan) =
  ## This starts a new bit array segment. Make sure to call it after
  ## `start_bit_array`!
  ## Bit array segments are a bit tricky, after calling this you're supposed
  ## to generate three distinct bits in the following order:
  ##
  ## 1. The expression representing the bit array segment
  ## 2. The expression representing the segment size (or call
  ##    `bit_array_default_segment_size` if you want to use the Erlang default)
  ## 3. A list of type specifiers (those are atoms like `utf8`, `binary`,
  ##    ...) or the atom `default` if you're ok with Erlang's default value,
  ##    those are generated using the `bit_array_segment_specifiers` function.
  ##
  ## After generating those three bits the segment is automatically over and
  ## you can go on to the next one!
  ##
  ## If this API seems a bit tricky and easy to get wrong, it is! But this is
  ## a low level API based on the shape of the Erlang Abstract Format itself,
  ## we don't make the rules.
  ##
  ## If you wanna check an example of how this is used you can have a read at
  ## the ones in `start_bit_array`.
  let kind = self.newBitArraySegment()
  self.position.add inBitArraySegment(
    expected = expectValue(kind),
    # We assume all values are going to have to be wrapped, better
    # be safe than sorry!
    # We will turn this off only for certain expressions we know
    # are safe to not wrap, like bare integers and strings.
    segmentValueNeedsWrapping = true,
    segmentSizeNeedsWrapping = true)

proc bitArraySegmentDefaultSize*(self: var ErlangSourceBuilder) =
  ## You can call this when a bit array segment has no explicit size, and the
  ## default Erlang behaviour is fine.
  self.popLeftoverItems()

  if self.isAt(posBitArraySegment) and self.top.vBitArraySegment.expected.kind == bsSize:
    # We are now expecting to see the specifiers list
    self.top.vBitArraySegment.expected = ExpectedBitArraySegmentItem(kind: bsSpecifiers)
    if self.top.vBitArraySegment.segmentValueNeedsWrapping:
      self.code.add ')'
      self.top.vBitArraySegment.segmentValueNeedsWrapping = false
    # We have the default atom as a size, that means we don't have to
    # print anything at all! The size doesn't need any wrapping because
    # there's no size at all.
    self.top.vBitArraySegment.segmentSizeNeedsWrapping = false
  else:
    self.invalid("segment default size")

proc bitArraySegmentSpecifiers*(self: var ErlangSourceBuilder,
                                specifiers: openArray[BitArraySegmentSpecifier]) =
  ## This generates a specifiers list for the currently open bit array
  ## segment.
  ## You always have to call this function, even if the segment has no
  ## specifiers; in that case you can pass this an empty list and the
  ## Erlang's default will be applied.
  self.popLeftoverItems()
  if not (self.isAt(posBitArraySegment) and
      self.top.vBitArraySegment.expected.kind == bsSpecifiers):
    self.invalid("bit array segment specifier")

  if self.top.vBitArraySegment.segmentValueNeedsWrapping:
    self.code.add ')'
    self.top.vBitArraySegment.segmentValueNeedsWrapping = false
  elif self.top.vBitArraySegment.segmentSizeNeedsWrapping:
    self.code.add ')'
    self.top.vBitArraySegment.segmentSizeNeedsWrapping = false

  var firstSpecifier = true
  # Upstream sorts the specifiers with a stable sort and a comparison that
  # only says "a unit is greater than anything": every `unit` goes last, the
  # others keep their order. (With two units that comparison is not an order,
  # and what the sort does then is not specified; a segment has one at most.)
  var sorted: seq[BitArraySegmentSpecifier]
  for specifier in specifiers:
    if specifier.kind != spUnit: sorted.add specifier
  for specifier in specifiers:
    if specifier.kind == spUnit: sorted.add specifier

  for specifier in sorted:
    let text = case specifier.kind
      of spUtf8: "utf8"
      of spUtf16: "utf16"
      of spUtf32: "utf32"
      of spInteger: "integer"
      of spFloat: "float"
      of spBinary: "binary"
      of spBitstring: "bitstring"
      of spSigned: "signed"
      of spUnsigned: "unsigned"
      of spLittle: "little"
      of spBig: "big"
      of spNative: "native"
      of spUnit: "unit:" & $specifier.vUnit
    if firstSpecifier:
      firstSpecifier = false
      self.code.add '/'
    else:
      self.code.add '-'
    self.code.add text

  discard self.position.pop()

proc consList*(self: var ErlangSourceBuilder, location: SrcSpan) =
  ## This creates a list.
  ## The next two generated values are going to be respectively the first
  ## item and the tail of the list.
  ##
  ## For example:
  ##
  ## ```text
  ## builder.cons_list();
  ## builder.variable("Hello");
  ## builder.cons_list();
  ## builder.string("Giacomo");
  ## builder.empty_list();
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## [Hello | [ ~"Giacomo" | []]].
  ## ```
  ##
  ## Which, with some syntax sugar, is how we represent a list with two
  ## elements:
  ##
  ## ```erl
  ## [Hello, ~"Giacomo"]
  ## ```
  self.consListOfKind(ListKind.Expression)

proc emptyList*(self: var ErlangSourceBuilder, location: SrcSpan) =
  ## This creates an empty list.
  self.emptyListOfKind(ListKind.Expression)

proc startCase*(self: var ErlangSourceBuilder, location: SrcSpan): Unit =
  ## This starts a new case expression.
  ## After this function is called you're supposed to first generate a single
  ## expression; that's going to be the case subject being matched on.
  ## After that you must call `end_case_subject`.
  ##
  ## After that you're supposed to generate the case branches using the
  ## `start_case_clause` function.
  ##
  ## For example:
  ##
  ## ```text
  ## let case = builder.start_case();
  ## builder.variable("wibble");
  ## let case = builder.end_case_subject();
  ##
  ## let clause = builder.start_case_clause();
  ## builder.discard_pattern();
  ## let clause = builder.end_clause_pattern();
  ## let clause = builder.end_clause_guards();
  ## builder.int(1.into());
  ## builder.end_clause_body();
  ##
  ## builder.end_case(case);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## case Wibble of
  ##   _ -> 1
  ## end.
  ## ```
  self.newExpression()
  self.code.add "case "
  self.position.add inCase(expected = ExpectedCaseItem(kind: ciSubject))

proc endCaseSubject*(self: var ErlangSourceBuilder, cas: Unit): Unit =
  ## This ends the open case subject, after this you can start generating the
  ## case clauses.
  # We need to make sure that just a single expression was generated as
  # the subject and then this function was called.
  # So we can assert that we're no longer expecting the subject but the
  # clauses and none has been generated yet.
  self.popLeftoverItems()
  if not (self.isAt(posCase) and self.top.vCase.expected.kind == ciBranches and
      self.top.vCase.expected.vBranches.first):
    self.invalid("end case subject")

proc endCase*(self: var ErlangSourceBuilder, cas: Unit) =
  ## This ends the open case subject, after this you can start generating the
  ## case clauses.
  self.closeCurrentlyOpenItem()

proc startCaseClause*(self: var ErlangSourceBuilder, location: SrcSpan): Unit =
  ## This starts a new case clause inside a case expression.
  ## After this is called you must generate a single pattern and then call
  ## `end_clause_pattern`.
  ##
  ## For an example on how to generate a full case clause check the
  ## `start_case` documentation.
  self.newCaseClause()
  self.position.add inCaseClause(expected = ExpectedCaseClauseItem(kind: ccPattern))

proc endClausePattern*(self: var ErlangSourceBuilder, clausePattern: Unit): Unit =
  ## This ends the case clause's pattern. After this you must generate the
  ## clause guards and then call `end_clause_guards`.
  ## If the clause you're generating has no guards you can immediately call
  ## that function without generating anything inbetween.
  self.closeCurrentlyOpenItem()
  self.position.add inCaseClause(expected = expectGuards(first = true))

proc startClauseGuard*(self: var ErlangSourceBuilder): Unit =
  ## You must call this before generating the guard of a case clause.
  ## For example:
  ##
  ## ```text
  ## let case = builder.start_case();
  ## builder.variable("wibble");
  ## let case = builder.end_case_subject();
  ##
  ## let clause = builder.start_case_clause();
  ## builder.discard_pattern();
  ## let clause = builder.end_clause_pattern();
  ## let guard = builder.start_clause_guard();
  ## builder.atom("true");
  ## builder.builder.end_clause_guard(guard);
  ## let clause = builder.end_clause_guards();
  ## builder.int(1.into());
  ## builder.end_clause_body();
  ##
  ## builder.end_case(case);
  ## ```
  ##
  ## A clause might have multiple guards but, the way Gleam is compiled, you
  ## should always call this function just once. A gleam guard is always
  ## compiled as a single Erlang guard with a single expression.
  self.newClauseGuard()
  self.position.add inClauseGuard()

proc endClauseGuard*(self: var ErlangSourceBuilder, clauseGuard: Unit) =
  ## This ends an open clause guards. Anything that is generated after
  ## this is going to be a new guard among the guards of a case's guards.
  self.closeCurrentlyOpenItem()

proc endClauseGuards*(self: var ErlangSourceBuilder, clauseGuards: Unit): Unit =
  ## This ends the case clause's guards. Anything that is generated after
  ## this is going to be a statement inside the current case clause until
  ## `end_clause_body` is called.
  self.closeCurrentlyOpenItem()
  self.indentation += INDENT
  self.position.add inCaseClause(expected = expectBody(first = true))

proc endClauseBody*(self: var ErlangSourceBuilder, clauseBody: Unit) =
  ## This takes an open clause body and ends it.
  ## After this you can start generating new case clauses, or end the
  ## currently open case expression if this was the last clause!
  self.closeCurrentlyOpenItem()

proc variable*(self: var ErlangSourceBuilder, location: SrcSpan, name: string) =
  ## This creates a variable expression with the given name.
  ## For example:
  ##
  ## ```erl
  ## wibble(X) -> X.
  ## %            ^ This here!
  ## ```
  self.doNotWrapIfSegmentValueOrSize()
  self.newExpression()
  self.code.add name

proc unaryOperator*(self: var ErlangSourceBuilder, location: SrcSpan, operator: string) =
  ## This generated the code that is going to apply the given unary operator
  ## to the expression that is going to be generated next.
  ## For example:
  ##
  ## ```text
  ## builder.unary_operator("-");
  ## builder.variable("X");
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## -X.
  ## ```
  self.newExpression()
  self.code.add operator
  self.code.add ' '
  self.position.add inUnaryOperator()

proc binaryOperator*(self: var ErlangSourceBuilder, location: SrcSpan, operator: string) =
  ## This generated the code that is going to apply the given binary operator
  ## to the two expressions generated after it.
  ## For example:
  ##
  ## ```text
  ## builder.binary_operator("+");
  ## builder.variable("X");
  ## builder.int(1);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## X + 1.
  ## ```
  self.popLeftoverItems()

  # If this new binary operator we're generating is part of a bigger
  # binary operator (it doesn't matter if on the left or right-hand
  # side), then we want to wrap it in parentheses to avoid precedence
  # confusion!
  let needsWrapping =
    self.isAt(posBinaryOperator) or self.isAt(posUnaryOperator)

  self.newExpression()
  if needsWrapping:
    self.code.add '('
  self.position.add inBinaryOperator(
    expected = ExpectedBinaryOperatorSide.Left, needsWrapping = needsWrapping, operator = operator)

proc functionReference*(self: var ErlangSourceBuilder, location: SrcSpan,
                        module: Option[ErlangModuleName], name: string, arity: int) =
  ## This generates the code for a function reference.
  ## For example:
  ##
  ## ```text
  ## builder.function_reference(None, "wibble", 1);
  ## builder.function_reference(Some("io"), "format", 2);
  ## ```
  ##
  ## Correspond to:
  ##
  ## ```erl
  ## fun wibble/1,
  ## fun io:format/2.
  ## ```
  self.newExpression()
  self.code.add "fun "
  if module.isSome:
    self.code.add quoteAtomName(module.get.name)
    self.code.add ':'
  self.code.add quoteAtomName(name)
  self.code.add '/'
  self.code.add $arity

proc matchOperator*(self: var ErlangSourceBuilder, location: SrcSpan) =
  ## This is used to create the code that corresponds to an assignment.
  ## A call to this function must always be followed by the generation of
  ## a pattern (the left-hand side of the assignment), and of an expression
  ## (the right-hand side of the assignment).
  ##
  ## For example:
  ##
  ## ```text
  ## builder.match_operator();
  ## builder.variable_pattern("X");
  ## builder.int(1);
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## X = 1.
  ## ```
  self.newExpression()
  self.position.add inMatchOperator(expected = ExpectedMatchSide.Pattern)

proc matchPattern*(self: var ErlangSourceBuilder, location: SrcSpan) =
  ## This is used to create the code that corresponds to a match pattern.
  ## A call to this function must always be followed by the generation of
  ## a pattern (the left-hand side of the assignment), and of another pattern
  ## (the right-hand side of the assignment).
  ##
  ## For example:
  ##
  ## ```text
  ## builder.match_pattern();
  ## builder.int_pattern(1);
  ## builder.variable_pattern("X");
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## 1 = X.
  ## ```
  ##
  ## You could use this to compare equality of arbitrary complex patterns:
  ## `{1, A, [_, _]} = {X, Y, [A | _]}` however you'll most likely ever need
  ## this only when generating code for Gleam's "as" patterns where the right
  ## hand side is just a variable pattern.
  self.newPattern()
  self.position.add inMatchPattern(expected = ExpectedMatchPatternSide.Left)

proc variablePattern*(self: var ErlangSourceBuilder, location: SrcSpan, name: string) =
  ## This creates a variable pattern with the given name.
  ## For example:
  ##
  ## ```erl
  ## wibble() ->
  ##   X = 1.
  ## % ^ This here!
  ## ```
  self.doNotWrapIfSegmentValueOrSize()
  self.newPattern()
  self.code.add name

proc discardPattern*(self: var ErlangSourceBuilder, location: SrcSpan) =
  ## This creates a discard pattern.
  ## For example:
  ##
  ## ```erl
  ## wibble() ->
  ##   _ = 1.
  ## % ^ This here!
  ## ```
  self.doNotWrapIfSegmentValueOrSize()
  self.newPattern()
  self.code.add '_'

proc intPattern*(self: var ErlangSourceBuilder, location: SrcSpan, number: BigInt) =
  ## This creates an integer pattern.
  ## For example:
  ##
  ## ```erl
  ## wibble() ->
  ##   1 = X.
  ## % ^ This here!
  ## ```
  self.doNotWrapIfSegmentValueOrSize()
  self.newPattern()
  self.code.add $number

proc floatPattern*(self: var ErlangSourceBuilder, location: SrcSpan, number: float64) =
  ## This creates an integer pattern.
  ## For example:
  ##
  ## ```erl
  ## wibble() ->
  ##   1 = X.
  ## % ^ This here!
  ## ```
  self.doNotWrapIfSegmentValueOrSize()
  self.newPattern()

  self.code.add formatFloat(number)

proc stringPattern*(self: var ErlangSourceBuilder, location: SrcSpan, content: string) =
  ## This creates a string pattern.
  ## For example:
  ##
  ## ```erl
  ## wibble() ->
  ##   <<"Hello"/utf8>> = X.
  ## % ^^^^^^^^^^^^^^^^ This here!
  ## ```
  self.doNotWrapIfSegmentValueOrSize()
  self.newPattern()
  self.doPrintStringContent(content)

proc atomPattern*(self: var ErlangSourceBuilder, location: SrcSpan, name: string) =
  ## This creates an atom pattern.
  ## For example:
  ##
  ## ```erl
  ## wibble() ->
  ##   ok = X.
  ## % ^^ This here!
  ## ```
  self.newPattern()
  self.code.add quoteAtomName(name)

proc startTuplePattern*(self: var ErlangSourceBuilder, location: SrcSpan): Unit =
  ## This starts a tuple pattern.
  ## Any code generated after this is gonna be an item of the tuple pattern.
  ##
  ## For example:
  ##
  ## ```text
  ## let tuple = builder.start_tuple_pattern();
  ## builder.int_pattern(1);
  ## builder.discard_pattern();
  ## builder.end_tuple(tuple);
  ## ```
  ##
  ## Corresponds to the following pattern:
  ##
  ## ```erl
  ## {~"Hello", _}.
  ## ```
  self.newPattern()
  self.code.add '{'
  self.position.add inTuplePattern(first = true)

proc endTuplePattern*(self: var ErlangSourceBuilder, tupl: Unit) =
  ## This takes an open tuple pattern and closes it.
  ## Any code generated after this is not gonna be part of that pattern.
  self.closeCurrentlyOpenItem()

proc startBitArrayPattern*(self: var ErlangSourceBuilder, location: SrcSpan): Unit =
  ## This starts an Erlang bitstring (that's a Gleam's BitArray) pattern.
  ## Any code generated after this is gonna be a segment of the pattern.
  ##
  ## For example:
  ##
  ## ```text
  ## let bit_array = builder.start_bit_array_pattern();
  ##
  ## builder.bit_array_pattern_segment();
  ## builder.int_pattern(1);
  ## builder.bit_array_segment_default_size();
  ## builder.bit_array_segment_specifiers([]);
  ##
  ## builder.bit_array_pattern_segment();
  ## builder.discard_pattern();
  ## builder.bit_array_segment_default_size();
  ## builder.bit_array_segment_specifiers([]);
  ##
  ## builder.end_bit_array_pattern(bit_array);
  ## ```
  ##
  ## Corresponds to the following pattern:
  ##
  ## ```erl
  ## <<1, _>>.
  ## ```
  self.newPattern()
  self.code.add "<<"
  self.position.add inBitArray(kind = BitArrayKind.Pattern, first = true)

proc endBitArrayPattern*(self: var ErlangSourceBuilder, bitArray: Unit) =
  ## This takes an open bit array pattern and closes it.
  ## Code generated after this is not gonna be a segment of the bit array.
  self.closeCurrentlyOpenItem()

proc consListPattern*(self: var ErlangSourceBuilder, location: SrcSpan) =
  ## This creates a list pattern.
  ## The next two generated values are going to be respectively the pattern
  ## for the first item and the pattern for the tail of the list.
  ##
  ## For example:
  ##
  ## ```text
  ## builder.cons_list_pattern();
  ## builder.discard_pattern();
  ## builder.cons_list_pattern();
  ## builder.string("Louis");
  ## builder.empty_list_pattern();
  ## ```
  ##
  ## Corresponds to the following pattern:
  ##
  ## ```erl
  ## [_ | [ ~"Louis" | []]].
  ## ```
  ##
  ## Which, with some syntax sugar, is how we represent a pattern matching
  ## on a list with two elements, where the second element is the string
  ## `~"Louis"`:
  ##
  ## ```erl
  ## [_, ~"Louis"]
  ## ```
  self.consListOfKind(ListKind.Pattern)

proc emptyListPattern*(self: var ErlangSourceBuilder, location: SrcSpan) =
  ## This creates a pattern matching on the empty list.
  self.emptyListOfKind(ListKind.Pattern)

proc stringExpression*(self: var ErlangSourceBuilder, location: SrcSpan, content: string) =
  ## This creates a string literal, where the string is represented as a
  ## bit array with the utf8 bytes making up the string.
  ## This is how Gleam string literals are represented in Erlang.
  ## This is expected to be passed a valid Gleam string!
  ##
  ## For example:
  ##
  ## ```text
  ## builder.string("ksiąskę");
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## ~"ksiąskę".
  ## ```
  ##
  ## Which is the same as `<<"ksiąskę"/utf8>>`
  ## Or the same as writing the bytes directly:
  ##
  ## ```erl
  ## <<107, 115, 105, 196, 133, 115, 107, 196, 153>>
  ## ```
  ##
  ## Upstream this is `string`, which in Nim is the name of the type.
  self.doNotWrapIfSegmentValueOrSize()
  self.newExpression()
  self.doPrintStringContent(content)

proc intExpression*(self: var ErlangSourceBuilder, location: SrcSpan, number: BigInt) =
  ## This creates an integer literal from the given value.
  ##
  ## For example:
  ##
  ## ```text
  ## builder.int(BigInt::from(2))
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## 2.
  ## ```
  self.doNotWrapIfSegmentValueOrSize()
  self.newExpression()
  self.code.add $number

proc floatExpression*(self: var ErlangSourceBuilder, location: SrcSpan, number: float64) =
  ## This creates a float literal from the given value.
  ##
  ## For example:
  ##
  ## ```text
  ## builder.float(1.2)
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## 1.2.
  ## ```
  self.doNotWrapIfSegmentValueOrSize()
  self.newExpression()
  self.code.add formatFloat(number)

proc atomExpression*(self: var ErlangSourceBuilder, location: SrcSpan, name: string) =
  ## This creates a literal atom with the given name.
  ##
  ## For example:
  ##
  ## ```text
  ## builder.atom("wibble")
  ## ```
  ##
  ## Corresponds to:
  ##
  ## ```erl
  ## wibble.
  ## ```
  self.newExpression()
  self.code.add quoteAtomName(name)
