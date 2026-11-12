## port-part-of: compiler-core/src/ast.rs
## (only a part of that file is ported so far: when the rest is, this becomes `port-of` with a `port-status`)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2018 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/ast.rs.

## The syntax tree of Gleam: modules, definitions, statements, patterns,
## constants, type annotations.
##
## The tree is generic, as upstream: `Pattern[T]`, `Statement[T, Expr]`,
## `Definition[T, Expr, PackageName]`. The parser builds it with `Unit` for
## the types (`UntypedPattern = Pattern[Unit]`), the type checker will rebuild
## it with real types (decision 0010).
##
## Ported: every type that the untyped tree is made of, and what upstream
## implements for all type parameters or for the untyped tree. Not ported yet:
## the `Typed*` aliases and their `impl` blocks, `find_node`, `TypedDefinitions`,
## `BoundVariable`, `PatternUnusedArguments`, `TypedPipelineAssignment`.
##
## How to read this file next to the Rust one:
##
## - Types come first, functions after, both in upstream order. Nim wants the
##   types that mention each other in one `type` section.
## - `ast/constant.nim` and `ast/untyped.nim` are included here, where the
##   types they need are known: upstream they are submodules that start with
##   `use super::*`, and `ast.rs` re-exports their types. Import `ast` and you
##   have all three.
## - An enum with data is written as `rust_enum.nim` says: `kind`, then one
##   `v<Variant>` field. The fields of a struct variant are in an object named
##   after the enum and the variant (`PatternList[T]` for `Pattern::List`).
## - Names changed because Nim cannot spell them, in `fieldRenames` below.
## - `u32` and `usize` are `int`, `Box<T>` is `ref T`, `Vec1<T>` is `seq[T]`,
##   `EcoString` is `string`, `()` is `Unit`.
## - `SpannedString` is upstream in `parse.rs`; it is here because the parser
##   imports this module, and Nim modules cannot import each other.
## - `InvalidExpression` is upstream in `ast/typed.rs`; it is here because
##   `Constant` needs it.
## - There is no `==` on the tree: compare two trees by their `debugRepr`.

import std/[options, sets, strutils]
import pkg/bigints
import ./[analyse, build, exhaustiveness, reference, rust_enum, src_span, typ]
import ./parse/literals
import ./typ/[error, expression, fields, printer]

export options, bigints
export analyse, build, exhaustiveness, reference, rust_enum, src_span, typ
export literals, error, expression, fields, printer

const
  PIPE_VARIABLE* = "_pipe"
  USE_ASSIGNMENT_VARIABLE* = "_use"
  RECORD_UPDATE_VARIABLE* = "_record"
  ASSERT_FAIL_VARIABLE* = "_assert_fail"
  ASSERT_SUBJECT_VARIABLE* = "_assert_subject"
  CAPTURE_VARIABLE* = "_capture"
  BLOCK_VARIABLE* = "_block"

  PIPE_PRECEDENCE*: uint8 = 6

  fieldRenames* = {"typ": "type_", "returns": "return_", "stop": "end", "tupl": "tuple"}
    ## The fields whose name is not the upstream one in camelCase: Nim name,
    ## Rust name. `type`, `return`, `end` and `tuple` are keywords, and a Nim
    ## identifier cannot end with an underscore.

type
  SpannedString* = (SrcSpan, string)

  # -- Function arguments ----------------------------------------------------

  ArgNamesKind* = enum
    agDiscard
    agLabelledDiscard
    agNamed
    agNamedLabelled

  ArgNamesDiscard* = object of StructVariant
    name*: string
    location*: SrcSpan

  ArgNamesLabelledDiscard* = object of StructVariant
    label*: string
    labelLocation*: SrcSpan
    name*: string
    nameLocation*: SrcSpan

  ArgNamesNamed* = object of StructVariant
    name*: string
    location*: SrcSpan

  ArgNamesNamedLabelled* = object of StructVariant
    label*: string
    labelLocation*: SrcSpan
    name*: string
    nameLocation*: SrcSpan

  ArgNames* = object
    case kind*: ArgNamesKind
    of agDiscard: vDiscard*: ArgNamesDiscard
    of agLabelledDiscard: vLabelledDiscard*: ArgNamesLabelledDiscard
    of agNamed: vNamed*: ArgNamesNamed
    of agNamedLabelled: vNamedLabelled*: ArgNamesNamedLabelled

  Arg*[T] = object
    names*: ArgNames
    location*: SrcSpan
    annotation*: Option[TypeAst]
    typ*: T

  # -- Custom types ----------------------------------------------------------

  RecordConstructor*[T] = object
    location*: SrcSpan
    nameLocation*: SrcSpan
    name*: string
    arguments*: seq[RecordConstructorArg[T]]
    documentation*: Option[(int, string)]
    deprecation*: Deprecation

  RecordConstructorArg*[T] = object
    label*: Option[SpannedString]
    ast*: TypeAst
    location*: SrcSpan
    typ*: T
    doc*: Option[(int, string)]

  # -- Type annotations ------------------------------------------------------

  TypeAstConstructor* = object
    location*: SrcSpan
    name*: TypeAstConstructorName
    arguments*: seq[TypeAst]
    startParentheses*: Option[int]

  TypeAstConstructorNameKind* = enum
    tnQualified
      ## ```gleam
      ## pub fn wibble() -> wibble.Wibble
      ## //                 ^^^^^^ module
      ## //                        ^^^^^^ name
      ## ```
    tnUnqualified
      ## ```gleam
      ## pub fn wibble() -> Wibble
      ## //                 ^^^^^^ name
      ## ```

  TypeAstConstructorNameQualified* = object of StructVariant
    module*: string
    moduleLocation*: SrcSpan
    dotLocation*: int
    name*: Option[(string, SrcSpan)]
      ## Notice how the name could be missing, this is an error! However, instead
      ## of treating it like a syntax error we allow parsing it and report it
      ## later. This way the language server can provide better help!

  TypeAstConstructorNameUnqualified* = object of StructVariant
    name*: string
    location*: SrcSpan

  TypeAstConstructorName* = object
    ## This represents a type constructor name, that can either be qualified, or
    ## unqualified.
    case kind*: TypeAstConstructorNameKind
    of tnQualified: vQualified*: TypeAstConstructorNameQualified
    of tnUnqualified: vUnqualified*: TypeAstConstructorNameUnqualified

  TypeAstFn* = object
    location*: SrcSpan
    arguments*: seq[TypeAst]
    returns*: ref TypeAst

  TypeAstVar* = object
    location*: SrcSpan
    name*: string

  TypeAstTuple* = object
    location*: SrcSpan
    elements*: seq[TypeAst]

  TypeAstHole* = object
    location*: SrcSpan
    name*: string

  TypeAstKind* = enum
    tyConstructor
    tyFn
    tyVar
    tyTuple
    tyHole

  TypeAst* = object
    case kind*: TypeAstKind
    of tyConstructor: vConstructor*: TypeAstConstructor
    of tyFn: vFn*: TypeAstFn
    of tyVar: vVar*: TypeAstVar
    of tyTuple: vTuple*: TypeAstTuple
    of tyHole: vHole*: TypeAstHole

  # -- Small enums -----------------------------------------------------------

  PublicityKind* = enum
    pbPublic
    pbPrivate
    pbInternal

  PublicityInternal* = object of StructVariant
    attributeLocation*: Option[SrcSpan]

  Publicity* = object
    case kind*: PublicityKind
    of pbPublic, pbPrivate: discard
    of pbInternal: vInternal*: PublicityInternal

  Layer* = enum
    laValue ## The default.
    laType

  BinOp* = enum
    # Boolean logic
    boAnd
    boOr
    # Equality
    boEq
    boNotEq
    # Order comparison
    boLtInt
    boLtEqInt
    boLtFloat
    boLtEqFloat
    boGtEqInt
    boGtInt
    boGtEqFloat
    boGtFloat
    # Maths
    boAddInt
    boAddFloat
    boSubInt
    boSubFloat
    boMultInt
    boMultFloat
    boDivInt
    boDivFloat
    boRemainderInt
    # Strings
    boConcatenate

  OperatorKind* = enum
    okBooleanLogic
    okEquality
    okIntComparison
    okFLoatComparison
    okIntMath
    okFloatMath
    okStringConcatenation

  ImplicitCallArgOrigin* = enum
    icUse
      ## The implicit callback argument passed as the last argument to the
      ## function on the right hand side of `use`.
    icPipe
      ## An argument added by the compiler when rewriting a pipe `left |> right`.
    icPatternFieldSpread
      ## An argument added by the compiler to fill in all the missing fields of a
      ## record that are being ignored with the `..` syntax.
    icIncorrectArityUse
      ## An argument used to fill in the missing args when a function on the
      ## right hand side of `use` is being called with the wrong arity.
    icRecordUpdate
      ## An argument added by the compiler to fill in the missing args when using
      ## the record update synax.

  IntOperator* = enum
    ioAdd
    ioSubtract
    ioMultiply
    ioDivide
    ioRemainder

  Endianness* = enum
    enBig
    enLittle

  AssignNameKind* = enum
    anVariable
    anDiscard

  AssignName* = object
    case kind*: AssignNameKind
    of anVariable: vVariable*: string
    of anDiscard: vDiscard*: string

  TodoKindKind* = enum
    tdKeyword
    tdEmptyFunction
    tdIncompleteUse
    tdEmptyBlock

  TodoKindEmptyFunction* = object of StructVariant
    functionLocation*: SrcSpan

  TodoKind* = object
    case kind*: TodoKindKind
    of tdKeyword, tdIncompleteUse, tdEmptyBlock: discard
    of tdEmptyFunction: vEmptyFunction*: TodoKindEmptyFunction

  InvalidExpressionKind* = enum
    ieModuleSelect
    ieUnknownVariable

  InvalidExpressionModuleSelect* = object of StructVariant
    moduleName*: string
    label*: string

  InvalidExpressionUnknownVariable* = object of StructVariant
    name*: string

  InvalidExpression* = object
    ## Upstream in `ast/typed.rs`.
    case kind*: InvalidExpressionKind
    of ieModuleSelect: vModuleSelect*: InvalidExpressionModuleSelect
    of ieUnknownVariable: vUnknownVariable*: InvalidExpressionUnknownVariable

  PipelineAssignmentKindKind* = enum
    pkFirstArgument ## In case `a |> b(c)` is desugared to `b(a, c)`.
    pkHole
      ## In case there's an explicit hole and `a |> b(_, c)` is desugared to
      ## `b(a, c)`.
    pkFunctionCall ## In case `a |> b(c)` is desugared to `b(c)(a)`
    pkEcho ## In case there's an echo in the middle of a pipeline `a |> echo`

  PipelineAssignmentKindFirstArgument* = object of StructVariant
    secondArgument*: Option[SrcSpan]
      ## The location of the second argument of the call, in case there's any:
      ## - `a |> b(c, d)`: here it's `Some` wrapping the location of `c`.
      ## - `a |> b()`: here it's `None`.

  PipelineAssignmentKindHole* = object of StructVariant
    hole*: SrcSpan

  PipelineAssignmentKind* = object
    ## The kind of desugaring that might take place when rewriting a pipeline to
    ## regular assignments.
    case kind*: PipelineAssignmentKindKind
    of pkFirstArgument: vFirstArgument*: PipelineAssignmentKindFirstArgument
    of pkHole: vHole*: PipelineAssignmentKindHole
    of pkFunctionCall, pkEcho: discard

  # -- Calls and records -----------------------------------------------------

  CallArg*[A] = object
    label*: Option[string]
    location*: SrcSpan
    value*: A
    implicit*: Option[ImplicitCallArgOrigin]

  RecordBeingUpdated*[A] = object
    base*: ref A
    location*: SrcSpan

  RecordUpdateArg*[A] = object
    label*: string
    location*: SrcSpan
    value*: A

  DefinitionLocation* = object
    module*: Option[string]
    span*: SrcSpan

  StringPrefixLeftSideAssignment* = object
    name*: string ## Name of the binding.
    nameStartPosition*: int
      ## Start position of the name:
      ##
      ## ```gleam
      ## "prefix" as alias <> suffix
      ## //          ^
      ## ```
    location*: SrcSpan
      ## Full location of the binding:
      ##
      ## ```gleam
      ## "prefix" as alias <> suffix
      ## //      ^^^^^^^^^
      ## ```

  # -- BitArrays -------------------------------------------------------------

  BitArraySegment*[Value, Type] = object
    location*: SrcSpan
    value*: ref Value
    options*: seq[BitArrayOption[Value]]
    typ*: Type

  BitArraySegmentTruncation* = object
    truncatedValue*: BigInt ## The value that would end up being truncated.
    truncatedInto*: BigInt ## What the value would be truncated into.
    valueLocation*: SrcSpan ## The span of the segment's value being truncated.
    segmentBits*: int64 ## The size of the segment.

  BitArrayOptionKind* = enum
    baBytes
    baInt
    baFloat
    baBits
    baUtf8
    baUtf16
    baUtf32
    baUtf8Codepoint
    baUtf16Codepoint
    baUtf32Codepoint
    baSigned
    baUnsigned
    baBig
    baLittle
    baNative
    baSize
    baUnit

  BitArrayOptionLocation* = object of StructVariant
    ## The fields of the fifteen options that are only a location
    ## (`Bytes { location }`, `Int { location }`, ...).
    location*: SrcSpan

  BitArrayOptionSize*[Value] = object of StructVariant
    location*: SrcSpan
    value*: ref Value
    shortForm*: bool

  BitArrayOptionUnit* = object of StructVariant
    location*: SrcSpan
    value*: uint8

  BitArrayOption*[Value] = object
    case kind*: BitArrayOptionKind
    of baBytes: vBytes*: BitArrayOptionLocation
    of baInt: vInt*: BitArrayOptionLocation
    of baFloat: vFloat*: BitArrayOptionLocation
    of baBits: vBits*: BitArrayOptionLocation
    of baUtf8: vUtf8*: BitArrayOptionLocation
    of baUtf16: vUtf16*: BitArrayOptionLocation
    of baUtf32: vUtf32*: BitArrayOptionLocation
    of baUtf8Codepoint: vUtf8Codepoint*: BitArrayOptionLocation
    of baUtf16Codepoint: vUtf16Codepoint*: BitArrayOptionLocation
    of baUtf32Codepoint: vUtf32Codepoint*: BitArrayOptionLocation
    of baSigned: vSigned*: BitArrayOptionLocation
    of baUnsigned: vUnsigned*: BitArrayOptionLocation
    of baBig: vBig*: BitArrayOptionLocation
    of baLittle: vLittle*: BitArrayOptionLocation
    of baNative: vNative*: BitArrayOptionLocation
    of baSize: vSize*: BitArrayOptionSize[Value]
    of baUnit: vUnit*: BitArrayOptionUnit

  # -- Imports, custom types, type aliases -----------------------------------

  Import*[PackageName] = object
    ## Import another Gleam module so the current module can use the types and
    ## values it defines.
    ##
    ## # Example(s)
    ##
    ## ```gleam
    ## import unix/cat
    ## // Import with alias
    ## import animal/cat as kitty
    ## ```
    documentation*: Option[string]
    location*: SrcSpan
    moduleLocation*: SrcSpan
    module*: string
    asName*: Option[(AssignName, SrcSpan)]
    unqualifiedValues*: seq[UnqualifiedImport]
    unqualifiedTypes*: seq[UnqualifiedImport]
    package*: PackageName

  UnqualifiedImport* = object
    location*: SrcSpan
    name*: string
    namePosition*: int
      ## The position of the original name. For example, in `type Wibble as
      ## Wobble`, it points to the start of `Wibble`.
    asName*: Option[string]

  CustomType*[T] = object
    ## A newly defined type with one or more constructors.
    ## Each variant of the custom type can contain different types, so the type is
    ## the product of the types contained by each variant.
    ##
    ## This might be called an algebraic data type (ADT) or tagged union in other
    ## languages and type systems.
    ##
    ##
    ## # Example(s)
    ##
    ## ```gleam
    ## pub type Cat {
    ##   Cat(name: String, cuteness: Int)
    ## }
    ## ```
    location*: SrcSpan
    endPosition*: int
    name*: string
    nameLocation*: SrcSpan
    publicity*: Publicity
    constructors*: seq[RecordConstructor[T]]
    documentation*: Option[(int, string)]
    deprecation*: Deprecation
    opaque*: bool
    parameters*: seq[SpannedString] ## The names of the type parameters.
    typedParameters*: seq[T]
      ## Once type checked this field will contain the type information for the
      ## type parameters.
    externalErlang*: Option[(string, string, SrcSpan)]
    externalJavascript*: Option[(string, string, SrcSpan)]

  TypeAlias*[T] = object
    ## A new name for an existing type
    ##
    ## # Example(s)
    ##
    ## ```gleam
    ## pub type Headers =
    ##   List(#(String, String))
    ## ```
    location*: SrcSpan
    alias*: string
    nameLocation*: SrcSpan
    parameters*: seq[SpannedString]
    typeAst*: TypeAst
    typ*: T
    publicity*: Publicity
    documentation*: Option[(int, string)]
    deprecation*: Deprecation

func precedence*(self: BinOp): uint8
  # Defined with the other functions, below; the two included files call it.

include ./ast/constant

type
  UntypedArg* = Arg[Unit]
  UntypedImport* = Import[Unit]
  UntypedCustomType* = CustomType[Unit]
  UntypedTypeAlias* = TypeAlias[Unit]

type
  # -- Clause guards ---------------------------------------------------------

  ClauseGuardKind* = enum
    cgBlock
    cgBinaryOperator
    cgNot
    cgVar
    cgTupleIndex
    cgFieldAccess
    cgModuleSelect
    cgConstant
    cgInvalid

  ClauseGuardBlock*[Type] = object of StructVariant
    location*: SrcSpan
    value*: ref ClauseGuard[Type]

  ClauseGuardBinaryOperator*[Type] = object of StructVariant
    location*: SrcSpan
    operator*: BinOp
    operatorStart*: int
      ## This is where the operator starts in the code. For example:
      ## ```gleam
      ## _ if 1.0 >=. 2.3 -> todo
      ## //       ^ Here!
      ## ```
    left*: ref ClauseGuard[Type]
    right*: ref ClauseGuard[Type]

  ClauseGuardNot*[Type] = object of StructVariant
    location*: SrcSpan
    expression*: ref ClauseGuard[Type]

  ClauseGuardVar*[Type] = object of StructVariant
    location*: SrcSpan
    typ*: Type
    name*: string
    definitionLocation*: SrcSpan
    origin*: VariableOrigin

  ClauseGuardTupleIndex*[Type] = object of StructVariant
    location*: SrcSpan
    index*: uint64
    typ*: Type
    tupl*: ref ClauseGuard[Type]

  ClauseGuardFieldAccess*[Type] = object of StructVariant
    labelLocation*: SrcSpan
    index*: Option[uint64]
    label*: string
    typ*: Type
    container*: ref ClauseGuard[Type]

  ClauseGuardModuleSelect*[Type] = object of StructVariant
    location*: SrcSpan
    fieldStart*: int
    definitionLocation*: SrcSpan
    typ*: Type
    label*: string
    moduleName*: string
    moduleAlias*: string
    literal*: Constant[Type]

  ClauseGuardInvalid*[Type] = object of StructVariant
    location*: SrcSpan
    typ*: Type

  ClauseGuard*[Type] = object
    case kind*: ClauseGuardKind
    of cgBlock: vBlock*: ClauseGuardBlock[Type]
    of cgBinaryOperator: vBinaryOperator*: ClauseGuardBinaryOperator[Type]
    of cgNot: vNot*: ClauseGuardNot[Type]
    of cgVar: vVar*: ClauseGuardVar[Type]
    of cgTupleIndex: vTupleIndex*: ClauseGuardTupleIndex[Type]
    of cgFieldAccess: vFieldAccess*: ClauseGuardFieldAccess[Type]
    of cgModuleSelect: vModuleSelect*: ClauseGuardModuleSelect[Type]
    of cgConstant: vConstant*: Constant[Type]
    of cgInvalid: vInvalid*: ClauseGuardInvalid[Type]

  # -- Patterns --------------------------------------------------------------

  PatternKind* = enum
    paInt
    paFloat
    paString
    paVariable
      ## The creation of a variable.
      ## e.g. `assert [this_is_a_var, .._] = x`
    paBitArraySize
      ## The specified size of a bit array. This can either be a literal integer,
      ## a reference to a variable, or a maths expression.
      ## e.g. `let assert <<y:size(somevar)>> = x`
    paAssign
      ## A name given to a sub-pattern using the `as` keyword.
      ## e.g. `assert #(1, [_, _] as the_list) = x`
    paDiscard
      ## A pattern that binds to any value but does not assign a variable.
      ## Always starts with an underscore.
    paList
    paConstructor
      ## The constructor for a custom type. Starts with an uppercase letter.
    paTuple
    paBitArray
    paStringPrefix # "prefix" <> variable
    paInvalid
      ## A placeholder pattern used to allow module analysis to continue
      ## even when there are type errors. Should never end up in generated code.

  PatternInt* = object of StructVariant
    location*: SrcSpan
    value*: string
    intValue*: BigInt

  PatternFloat* = object of StructVariant
    location*: SrcSpan
    value*: string
    floatValue*: LiteralFloatValue

  PatternString* = object of StructVariant
    location*: SrcSpan
    value*: string

  PatternVariable*[Type] = object of StructVariant
    location*: SrcSpan
    name*: string
    typ*: Type
    origin*: VariableOrigin

  PatternAssign*[Type] = object of StructVariant
    name*: string
    location*: SrcSpan
    pattern*: ref Pattern[Type]

  PatternDiscard*[Type] = object of StructVariant
    name*: string
    location*: SrcSpan
    typ*: Type

  PatternList*[Type] = object of StructVariant
    location*: SrcSpan
    elements*: seq[Pattern[Type]]
    tail*: Option[ref TailPattern[Type]]
    typ*: Type ## The type of the list, so this is going to be `List(something)`.

  PatternConstructorFields*[Type] = object of StructVariant
    ## The fields of `Pattern::Constructor`. Not `PatternConstructor`: that is
    ## the name of a type of `type_.rs`, the one of the `constructor` field.
    location*: SrcSpan
    nameLocation*: SrcSpan
    name*: string
    arguments*: seq[CallArg[Pattern[Type]]]
    module*: Option[(string, SrcSpan)]
    constructor*: Inferred[PatternConstructor]
    spread*: Option[SrcSpan]
    typ*: Type

  PatternTuple*[Type] = object of StructVariant
    location*: SrcSpan
    elements*: seq[Pattern[Type]]

  PatternBitArray*[Type] = object of StructVariant
    location*: SrcSpan
    segments*: seq[BitArraySegment[Pattern[Type], Type]]

  PatternStringPrefix* = object of StructVariant
    location*: SrcSpan
    leftLocation*: SrcSpan
    leftSideAssignment*: Option[StringPrefixLeftSideAssignment]
    rightLocation*: SrcSpan
    leftSideString*: string
    rightSideAssignment*: AssignName
      ## The variable on the right hand side of the `<>`.

  PatternInvalid*[Type] = object of StructVariant
    location*: SrcSpan
    typ*: Type

  Pattern*[Type] = object
    case kind*: PatternKind
    of paInt: vInt*: PatternInt
    of paFloat: vFloat*: PatternFloat
    of paString: vString*: PatternString
    of paVariable: vVariable*: PatternVariable[Type]
    of paBitArraySize: vBitArraySize*: BitArraySize[Type]
    of paAssign: vAssign*: PatternAssign[Type]
    of paDiscard: vDiscard*: PatternDiscard[Type]
    of paList: vList*: PatternList[Type]
    of paConstructor: vConstructor*: PatternConstructorFields[Type]
    of paTuple: vTuple*: PatternTuple[Type]
    of paBitArray: vBitArray*: PatternBitArray[Type]
    of paStringPrefix: vStringPrefix*: PatternStringPrefix
    of paInvalid: vInvalid*: PatternInvalid[Type]

  MultiPattern*[Type] = seq[Pattern[Type]]

  BitArraySizeKind* = enum
    bsInt
    bsVariable
    bsBinaryOperator
    bsBlock

  BitArraySizeInt* = object of StructVariant
    location*: SrcSpan
    value*: string
    intValue*: BigInt

  BitArraySizeVariable*[Type] = object of StructVariant
    location*: SrcSpan
    name*: string
    constructor*: Option[ref ValueConstructor]
    typ*: Type

  BitArraySizeBinaryOperator*[Type] = object of StructVariant
    location*: SrcSpan
    operator*: IntOperator
    left*: ref BitArraySize[Type]
    right*: ref BitArraySize[Type]

  BitArraySizeBlock*[Type] = object of StructVariant
    location*: SrcSpan
    inner*: ref BitArraySize[Type]

  BitArraySize*[Type] = object
    case kind*: BitArraySizeKind
    of bsInt: vInt*: BitArraySizeInt
    of bsVariable: vVariable*: BitArraySizeVariable[Type]
    of bsBinaryOperator: vBinaryOperator*: BitArraySizeBinaryOperator[Type]
    of bsBlock: vBlock*: BitArraySizeBlock[Type]

  TailPattern*[Type] = object
    ## The pattern one can use to match on the rest of a list:
    location*: SrcSpan
      ## The entire location of the pattern, covering the `..` as well.
    pattern*: Pattern[Type]
      ## The name assigned to the rest of the list being matched:
      ##
      ## ```gleam
      ## [wibble, ..]
      ## //       ^^ no name
      ##
      ## [wibble, ..rest]
      ## //       ^^^^^^ a variable name
      ##
      ## [wibble, .._rest]
      ## //       ^^^^^^^ a discarded name
      ## ```


  # -- Statements ------------------------------------------------------------

  AssignmentKindKind* = enum
    akLet ## let x = ...
    akGenerated
      ## This is a let assignment generated by the compiler for intermediate
      ## variables needed by record updates and `use`.
      ## Like a regular `Let` assignment this can never fail.
    akAssert ## let assert x = ...

  AssignmentKindAssert*[Expression] = object of StructVariant
    location*: SrcSpan
      ## The src byte span of the `let assert`
      ##
      ## ```gleam
      ## let assert Wibble = todo
      ## ^^^^^^^^^^
      ## ```
    assertKeywordStart*: int
      ## The byte index of the start of `assert`
      ##
      ## ```gleam
      ## let assert Wibble = todo
      ##     ^
      ## ```
    message*: Option[Expression]
      ## The message given to the assertion:
      ##
      ## ```gleam
      ## let asset Ok(a) = something() as "This will never fail"
      ##                                  ^^^^^^^^^^^^^^^^^^^^^^
      ## ```

  AssignmentKind*[Expression] = object
    case kind*: AssignmentKindKind
    of akLet, akGenerated: discard
    of akAssert: vAssert*: AssignmentKindAssert[Expression]

  StatementKind* = enum
    stExpression ## A bare expression that is not assigned to any variable.
    stAssignment ## Assigning an expression to variables using a pattern.
    stUse ## A `use` expression.
    stAssert ## A bool assertion.

  Statement*[TypeT, ExpressionT] = object
    ## A statement with in a function body.
    case kind*: StatementKind
    of stExpression: vExpression*: ExpressionT
    of stAssignment: vAssignment*: ref Assignment[TypeT, ExpressionT]
    of stUse: vUse*: Use[TypeT, ExpressionT]
    of stAssert: vAssert*: Assert[ExpressionT]

  Use*[TypeT, ExpressionT] = object
    call*: ref ExpressionT
      ## In an untyped use this is the expression with the untyped code of the
      ## callback function.
      ##
      ## In a typed use this is the typed function call the use expression
      ## desugars to.
    location*: SrcSpan
      ## This is the location of the whole use line, starting from the `use`
      ## keyword and ending with the function call on the right hand side of
      ## `<-`.
      ##
      ## ```gleam
      ## use a <- result.try(result)
      ## ^^^^^^^^^^^^^^^^^^^^^^^^^^^
      ## ```
    rightHandSideLocation*: SrcSpan
      ## This is the location of the expression on the right hand side of the use
      ## arrow.
      ##
      ## ```gleam
      ## use a <- result.try(result)
      ##          ^^^^^^^^^^^^^^^^^^
      ## ```
    assignmentsLocation*: SrcSpan
      ## This is the SrcSpan of the patterns you find on the left hand side of
      ## `<-` in a use expression.
      ##
      ## ```gleam
      ## use pattern1, pattern2 <- todo
      ##     ^^^^^^^^^^^^^^^^^^
      ## ```
      ##
      ## In case there's no patterns it will be corresponding to the SrcSpan of
      ## the `use` keyword itself.
    assignments*: seq[UseAssignment[TypeT]]
      ## The patterns on the left hand side of `<-` in a use expression.

  UseAssignment*[TypeT] = object
    location*: SrcSpan
    pattern*: Pattern[TypeT]
    annotation*: Option[TypeAst]

  Assignment*[TypeT, ExpressionT] = object
    location*: SrcSpan
    value*: ExpressionT
    pattern*: Pattern[TypeT]
    kind*: AssignmentKind[ExpressionT]
    compiledCase*: CompiledCase
    annotation*: Option[TypeAst]
      ## This will be true for assignments that are automatically generated by
      ## the compiler.

  Assert*[Expression] = object
    location*: SrcSpan
    value*: Expression
    message*: Option[Expression]

  Clause*[Expr, Type] = object
    location*: SrcSpan
    pattern*: MultiPattern[Type]
    alternativePatterns*: seq[MultiPattern[Type]]
    guard*: Option[ClauseGuard[Type]]
    then*: Expr

  # -- Definitions and modules -----------------------------------------------

  Function*[T, Expr] = object
    ## A function definition
    ##
    ## Note that an anonymous function will have `None` as the name field, while a
    ## named function will have `Some`.
    ##
    ## # Example(s)
    ##
    ## ```gleam
    ## // Public function
    ## pub fn wobble() -> String { ... }
    ## // Private function
    ## fn wibble(x: Int) -> Int { ... }
    ## // Anonymous function
    ## fn(x: Int) { ... }
    ## ```
    location*: SrcSpan
    bodyStart*: Option[int]
    endPosition*: int
    name*: Option[SpannedString]
    arguments*: seq[Arg[T]]
    body*: seq[Statement[T, Expr]]
    publicity*: Publicity
    deprecation*: Deprecation
    returnAnnotation*: Option[TypeAst]
    returnType*: T
    documentation*: Option[(int, string)]
    externalErlang*: Option[(string, string, SrcSpan)]
    externalJavascript*: Option[(string, string, SrcSpan)]
    implementations*: Implementations
    purity*: Purity

  ModuleConstant*[T] = object
    ## A certain fixed value that can be used in multiple places
    ##
    ## # Example(s)
    ##
    ## ```gleam
    ## pub const start_year = 2101
    ## pub const end_year = 2111
    ## ```
    documentation*: Option[(int, string)]
    location*: SrcSpan
      ## The location of the constant, starting at the "(pub) const" keywords and
      ## ending after the ": Type" annotation, or (without an annotation) after its name.
    publicity*: Publicity
    name*: string
    nameLocation*: SrcSpan
    annotation*: Option[TypeAst]
    value*: ref Constant[T]
    typ*: T
    deprecation*: Deprecation
    implementations*: Implementations

  DefinitionKind* = enum
    dfFunction
    dfTypeAlias
    dfCustomType
    dfImport
    dfModuleConstant

  Definition*[T, Expr, PackageName] = object
    case kind*: DefinitionKind
    of dfFunction: vFunction*: Function[T, Expr]
    of dfTypeAlias: vTypeAlias*: TypeAlias[T]
    of dfCustomType: vCustomType*: CustomType[T]
    of dfImport: vImport*: Import[PackageName]
    of dfModuleConstant: vModuleConstant*: ModuleConstant[T]

  Module*[Info, Definitions] = object
    name*: string
    documentation*: seq[string]
    typeInfo*: Info
    definitions*: Definitions
    names*: Names
    unusedDefinitionPositions*: HashSet[int]
      ## The source byte locations of definition that are unused.
      ## This is used in code generation to know when definitions can be safely omitted.

include ./ast/untyped

type
  UntypedClauseGuard* = ClauseGuard[Unit]
  UntypedPattern* = Pattern[Unit]
  UntypedMultiPattern* = MultiPattern[Unit]
  UntypedTailPattern* = TailPattern[Unit]
  UntypedPatternBitArraySegment* = BitArraySegment[UntypedPattern, Unit]
  UntypedUseAssignment* = UseAssignment[Unit]
  UntypedModuleConstant* = ModuleConstant[Unit]
  UntypedConstantBitArraySegment* = BitArraySegment[UntypedConstant, Unit]
  UntypedFunction* = Function[Unit, UntypedExpr]
  UntypedDefinition* = Definition[Unit, UntypedExpr, Unit]
  UntypedStatement* = Statement[Unit, UntypedExpr]
  UntypedUse* = Use[Unit, UntypedExpr]
  UntypedAssignment* = Assignment[Unit, UntypedExpr]
  UntypedAssert* = Assert[UntypedExpr]
  UntypedClause* = Clause[UntypedExpr, Unit]
  UntypedRecordUpdateArg* = RecordUpdateArg[UntypedExpr]
  UntypedExprBitArraySegment* = BitArraySegment[UntypedExpr, Unit]

  TargetedDefinition* = object
    ## The `@target(erlang)` and `@target(javascript)` attributes can be used to
    ## mark a definition as only being for a specific target.
    ##
    ## ```gleam
    ## const x: Int = 1
    ##
    ## @target(erlang)
    ## pub fn main(a) { ...}
    ## ```
    definition*: UntypedDefinition
    target*: Option[Target]

  UntypedModule* = Module[Unit, seq[TargetedDefinition]]

  GroupedDefinitions* = object
    functions*: seq[UntypedFunction]
    constants*: seq[UntypedModuleConstant]
    customTypes*: seq[UntypedCustomType]
    imports*: seq[UntypedImport]
    typeAliases*: seq[UntypedTypeAlias]

# ---------------------------------------------------------------------------
# Functions, in upstream order.
# ---------------------------------------------------------------------------

func erlangName*[Info, Definitions](self: Module[Info, Definitions]): string =
  moduleErlangName(self.name)

func isFor*(self: TargetedDefinition, target: Target): bool =
  self.target.isNone or self.target.get == target

iterator iterDefinitions*(self: UntypedModule, target: Target): UntypedDefinition =
  for definition in self.definitions:
    if definition.isFor(target):
      yield definition.definition

func dependencies*(self: UntypedModule, target: Target): seq[(string, SrcSpan)] =
  for definition in self.iterDefinitions(target):
    case definition.kind
    of dfImport:
      result.add (definition.vImport.module, definition.vImport.location)
    of dfFunction, dfTypeAlias, dfCustomType, dfModuleConstant:
      discard

func getLabel*(self: ArgNames): Option[(string, SrcSpan)] =
  case self.kind
  of agDiscard, agNamed:
    none((string, SrcSpan))
  of agLabelledDiscard:
    some((self.vLabelledDiscard.label, self.vLabelledDiscard.labelLocation))
  of agNamedLabelled:
    some((self.vNamedLabelled.label, self.vNamedLabelled.labelLocation))

func getVariableName*(self: ArgNames): Option[string] =
  case self.kind
  of agDiscard, agLabelledDiscard:
    none(string)
  of agNamedLabelled:
    some(self.vNamedLabelled.name)
  of agNamed:
    some(self.vNamed.name)

func setType*[A, B](self: Arg[A], t: B): Arg[B] =
  Arg[B](typ: t, names: self.names, location: self.location, annotation: self.annotation)

func getVariableName*[A](self: Arg[A]): Option[string] =
  self.names.getVariableName

func isCaptureHole*[A](self: Arg[A]): bool =
  case self.names.kind
  of agNamed:
    self.names.vNamed.name == CAPTURE_VARIABLE
  of agDiscard, agLabelledDiscard, agNamedLabelled:
    false

func putDoc*[A](self: var RecordConstructor[A], newDoc: (int, string)) =
  self.documentation = some(newDoc)

func putDoc*[T](self: var RecordConstructorArg[T], newDoc: (int, string)) =
  self.doc = some(newDoc)

func isQualified*(self: TypeAstConstructorName): bool =
  case self.kind
  of tnQualified: true
  of tnUnqualified: false

func moduleName*(self: TypeAstConstructorName): Option[string] =
  case self.kind
  of tnQualified:
    some(self.vQualified.module)
  of tnUnqualified:
    none(string)

func name*(self: TypeAstConstructorName): Option[string] =
  case self.kind
  of tnUnqualified:
    some(self.vUnqualified.name)
  of tnQualified:
    if self.vQualified.name.isSome:
      some(self.vQualified.name.get[0])
    else:
      none(string)

func nameLocation*(self: TypeAstConstructorName): Option[SrcSpan] =
  case self.kind
  of tnUnqualified:
    some(self.vUnqualified.location)
  of tnQualified:
    if self.vQualified.name.isSome:
      some(self.vQualified.name.get[1])
    else:
      none(SrcSpan)

func isLogicallyEqual(self, other: TypeAstConstructorName): bool =
  if self.kind == tnQualified and other.kind == tnQualified:
    let name = self.vQualified.name
    let otherName = other.vQualified.name
    self.vQualified.module == other.vQualified.module and (
      if name.isSome and otherName.isSome:
        name.get[0] == otherName.get[0]
      else:
        name.isNone and otherName.isNone
    )
  elif self.kind == tnUnqualified and other.kind == tnUnqualified:
    self.vUnqualified.name == other.vUnqualified.name
  else:
    false

func location*(self: TypeAst): SrcSpan =
  case self.kind
  of tyFn: self.vFn.location
  of tyVar: self.vVar.location
  of tyHole: self.vHole.location
  of tyTuple: self.vTuple.location
  of tyConstructor: self.vConstructor.location

func isLogicallyEqual*(self, other: TypeAst): bool =
  func allEqual(a, b: seq[TypeAst]): bool =
    if a.len != b.len:
      return false
    for i in 0 ..< a.len:
      if not a[i].isLogicallyEqual(b[i]):
        return false
    true

  case self.kind
  of tyConstructor:
    other.kind == tyConstructor and
      self.vConstructor.name.isLogicallyEqual(other.vConstructor.name) and
      allEqual(self.vConstructor.arguments, other.vConstructor.arguments)
  of tyFn:
    other.kind == tyFn and allEqual(self.vFn.arguments, other.vFn.arguments) and
      self.vFn.returns[].isLogicallyEqual(other.vFn.returns[])
  of tyVar:
    other.kind == tyVar and self.vVar.name == other.vVar.name
  of tyTuple:
    other.kind == tyTuple and allEqual(self.vTuple.elements, other.vTuple.elements)
  of tyHole:
    other.kind == tyHole and self.vHole.name == other.vHole.name

func print*(self: TypeAst, buffer: var string) =
  ## Generates an annotation corresponding to the type.
  case self.kind
  of tyVar:
    buffer.add self.vVar.name
  of tyHole:
    buffer.add self.vHole.name
  of tyTuple:
    buffer.add "#("
    for i, element in self.vTuple.elements:
      element.print(buffer)
      if i < self.vTuple.elements.len - 1:
        buffer.add ", "
    buffer.add ')'
  of tyFn:
    buffer.add "fn("
    for i, argument in self.vFn.arguments:
      argument.print(buffer)
      if i < self.vFn.arguments.len - 1:
        buffer.add ", "
    buffer.add ')'
    buffer.add " -> "
    self.vFn.returns[].print(buffer)
  of tyConstructor:
    let constructor = self.vConstructor
    case constructor.name.kind
    of tnUnqualified:
      buffer.add constructor.name.vUnqualified.name
    of tnQualified:
      buffer.add constructor.name.vQualified.module
      buffer.add '.'
      if constructor.name.vQualified.name.isSome:
        buffer.add constructor.name.vQualified.name.get[0]

    if constructor.arguments.len != 0:
      buffer.add '('
      for i, argument in constructor.arguments:
        argument.print(buffer)
        if i < constructor.arguments.len - 1:
          buffer.add ", "
      buffer.add ')'

func isPrivate*(self: Publicity): bool =
  self.kind == pbPrivate

func isInternal*(self: Publicity): bool =
  self.kind == pbInternal

func isPublic*(self: Publicity): bool =
  self.kind == pbPublic

func isImportable*(self: Publicity): bool =
  case self.kind
  of pbInternal, pbPublic: true
  of pbPrivate: false

func fullLocation*[T, E](self: Function[T, E]): SrcSpan =
  initSrcSpan(self.location.start, self.endPosition)

func usedName*[T](self: Import[T]): Option[string] =
  if self.asName.isSome:
    let name = self.asName.get[0]
    case name.kind
    of anVariable:
      some(name.vVariable)
    of anDiscard:
      none(string)
  else:
    # `"".split('/')` yields one empty string in Rust as in Nim.
    some(self.module.split('/')[^1])

func aliasLocation*[T](self: Import[T]): Option[SrcSpan] =
  if self.asName.isSome:
    some(self.asName.get[1])
  else:
    none(SrcSpan)

func fullLocation*[T](self: CustomType[T]): SrcSpan =
  ## The `location` field of a `CustomType` is only the location of `pub type
  ## TheName`. This method returns a `SrcSpan` that includes the entire type
  ## definition.
  initSrcSpan(self.location.start, self.endPosition)

func location*[A, B, C](self: Definition[A, B, C]): SrcSpan =
  case self.kind
  of dfFunction: self.vFunction.location
  of dfImport: self.vImport.location
  of dfTypeAlias: self.vTypeAlias.location
  of dfCustomType: self.vCustomType.location
  of dfModuleConstant: self.vModuleConstant.location

func isImport*[A, B, C](self: Definition[A, B, C]): bool =
  ## Returns `true` if the definition is `Import`.
  self.kind == dfImport

func isFunction*[A, B, C](self: Definition[A, B, C]): bool =
  ## Returns `true` if the module statement is `Function`.
  self.kind == dfFunction

func isCustomType*[A, B, C](self: Definition[A, B, C]): bool =
  ## Returns `true` if the module statement is `CustomType`.
  self.kind == dfCustomType

func getDoc*[A, B, C](self: Definition[A, B, C]): Option[string] =
  let doc =
    case self.kind
    of dfImport:
      return none(string)
    of dfFunction:
      self.vFunction.documentation
    of dfTypeAlias:
      self.vTypeAlias.documentation
    of dfCustomType:
      self.vCustomType.documentation
    of dfModuleConstant:
      self.vModuleConstant.documentation
  if doc.isSome:
    some(doc.get[1])
  else:
    none(string)

func isInternal*[A, B, C](self: Definition[A, B, C]): bool =
  case self.kind
  of dfFunction: self.vFunction.publicity.isInternal
  of dfCustomType: self.vCustomType.publicity.isInternal
  of dfModuleConstant: self.vModuleConstant.publicity.isInternal
  of dfTypeAlias: self.vTypeAlias.publicity.isInternal
  of dfImport: false

func usedName*(self: UnqualifiedImport): string =
  if self.asName.isSome: self.asName.get else: self.name

func nameLocation*(self: UnqualifiedImport): SrcSpan =
  ## The location of the original name, excluding the potential `as ...`
  ## clause or the `type` keyword. For example, in `type Wibble as Wobble`,
  ## it covers `Wibble`.
  initSrcSpan(self.namePosition, self.namePosition + self.name.len)

func isValue*(self: Layer): bool =
  ## Returns `true` if the layer is `Value`.
  self == laValue

func precedence*(self: BinOp): uint8 =
  # Ensure that this matches the other precedence function for guards
  case self
  of boOr: 1
  of boAnd: 2
  of boEq, boNotEq: 3
  of boLtInt, boLtEqInt, boLtFloat, boLtEqFloat, boGtEqInt, boGtInt, boGtEqFloat,
      boGtFloat: 4
  of boConcatenate: 5
  # Pipe is 6
  of boAddInt, boAddFloat, boSubInt, boSubFloat: 7
  of boMultInt, boMultFloat, boDivInt, boDivFloat, boRemainderInt: 8

func name*(self: BinOp): string =
  case self
  of boAnd: "&&"
  of boOr: "||"
  of boLtInt: "<"
  of boLtEqInt: "<="
  of boLtFloat: "<."
  of boLtEqFloat: "<=."
  of boEq: "=="
  of boNotEq: "!="
  of boGtEqInt: ">="
  of boGtInt: ">"
  of boGtEqFloat: ">=."
  of boGtFloat: ">."
  of boAddInt: "+"
  of boAddFloat: "+."
  of boSubInt: "-"
  of boSubFloat: "-."
  of boMultInt: "*"
  of boMultFloat: "*."
  of boDivInt: "/"
  of boDivFloat: "/."
  of boRemainderInt: "%"
  of boConcatenate: "<>"

func operatorKind*(self: BinOp): OperatorKind =
  case self
  of boConcatenate: okStringConcatenation
  of boEq, boNotEq: okEquality
  of boAnd, boOr: okBooleanLogic
  of boLtInt, boLtEqInt, boGtEqInt, boGtInt: okIntComparison
  of boLtFloat, boLtEqFloat, boGtEqFloat, boGtFloat: okFLoatComparison
  of boAddInt, boSubInt, boMultInt, boRemainderInt, boDivInt: okIntMath
  of boAddFloat, boSubFloat, boMultFloat, boDivFloat: okFloatMath

func canBeGroupedWith*(self, other: BinOp): bool =
  self.operatorKind == other.operatorKind

func isFloatOperator*(self: BinOp): bool =
  case self
  of boLtFloat, boLtEqFloat, boGtEqFloat, boGtFloat, boAddFloat, boSubFloat,
      boMultFloat, boDivFloat:
    true
  of boAnd, boOr, boEq, boNotEq, boLtInt, boLtEqInt, boGtEqInt, boGtInt, boAddInt,
      boSubInt, boMultInt, boDivInt, boRemainderInt, boConcatenate:
    false

func isBoolOperator*(self: BinOp): bool =
  case self
  of boAnd, boOr:
    true
  of boEq, boNotEq, boLtInt, boLtEqInt, boLtFloat, boLtEqFloat, boGtEqInt, boGtInt,
      boGtEqFloat, boGtFloat, boAddInt, boAddFloat, boSubInt, boSubFloat, boMultInt,
      boMultFloat, boDivInt, boDivFloat, boRemainderInt, boConcatenate:
    false

func isIntOperator*(self: BinOp): bool =
  case self
  of boLtInt, boLtEqInt, boGtEqInt, boGtInt, boAddInt, boSubInt, boMultInt, boDivInt,
      boRemainderInt:
    true
  of boAnd, boOr, boEq, boNotEq, boLtFloat, boLtEqFloat, boGtEqFloat, boGtFloat,
      boAddFloat, boSubFloat, boMultFloat, boDivFloat, boConcatenate:
    false

func floatEquivalent*(self: BinOp): Option[BinOp] =
  case self
  of boLtInt: some(boLtFloat)
  of boLtEqInt: some(boLtEqFloat)
  of boGtEqInt: some(boGtEqFloat)
  of boGtInt: some(boGtFloat)
  of boAddInt: some(boAddFloat)
  of boSubInt: some(boSubFloat)
  of boMultInt: some(boMultFloat)
  of boDivInt: some(boDivFloat)
  of boAnd, boOr, boEq, boNotEq, boLtFloat, boLtEqFloat, boGtEqFloat, boGtFloat,
      boAddFloat, boSubFloat, boMultFloat, boDivFloat, boRemainderInt, boConcatenate:
    none(BinOp)

func intEquivalent*(self: BinOp): Option[BinOp] =
  case self
  of boLtFloat: some(boLtInt)
  of boLtEqFloat: some(boLtEqInt)
  of boGtEqFloat: some(boGtEqInt)
  of boGtFloat: some(boGtInt)
  of boAddFloat: some(boAddInt)
  of boSubFloat: some(boSubInt)
  of boMultFloat: some(boMultInt)
  of boDivFloat: some(boDivInt)
  of boAnd, boOr, boEq, boNotEq, boLtInt, boLtEqInt, boGtEqInt, boGtInt, boAddInt,
      boSubInt, boMultInt, boDivInt, boRemainderInt, boConcatenate:
    none(BinOp)

func size*(self: BinOp): int =
  ## This returns how many characters this operator takes.
  case self
  of boLtInt, boGtInt, boRemainderInt, boMultInt, boAddInt, boSubInt, boDivInt:
    1
  of boAnd, boOr, boEq, boNotEq, boLtEqInt, boGtEqInt, boLtFloat, boGtFloat, boAddFloat,
      boSubFloat, boMultFloat, boDivFloat, boConcatenate:
    2
  of boLtEqFloat, boGtEqFloat:
    3

func isImplicit*[A](self: CallArg[A]): bool =
  self.implicit.isSome

func isUseImplicitCallback*[A](self: CallArg[A]): bool =
  self.implicit.isSome and self.implicit.get in {icUse, icIncorrectArityUse}

func isCaptureHole*(self: CallArg[UntypedExpr]): bool =
  case self.value.kind
  of ueVar:
    self.value.vVar.name == CAPTURE_VARIABLE
  of ueInt, ueFloat, ueString, ueBlock, ueFn, ueList, ueCall, ueBinOp, uePipeline,
      ueCase, ueFieldAccess, ueTuple, ueTupleIndex, ueTodo, uePanic, ueEcho, ueBitArray,
      ueRecordUpdate, ueNegateBool, ueNegateInt:
    false

func labelShorthandName*[T](self: CallArg[T]): Option[string] =
  ## If the call arg is defined using a label shorthand, this will return the
  ## label name.
  mixin location
  if not self.isImplicit and self.location == self.value.location:
    self.label
  else:
    none(string)

func usesLabelShorthand*[T](self: CallArg[T]): bool =
  self.labelShorthandName.isSome

func labelLocation*[T](self: CallArg[T]): Option[SrcSpan] =
  ## The location of this argument's label, if it has one. For the label
  ## shorthand syntax this spans the whole `label:`, otherwise it is just
  ## the label itself.
  if self.label.isNone:
    return none(SrcSpan)
  let label = self.label.get
  if self.usesLabelShorthand:
    some(self.location)
  else:
    some(initSrcSpan(self.location.start, self.location.start + label.len))

func labelSyntax*[T](self: CallArg[T]): LabelSyntax =
  if self.usesLabelShorthand: lsShorthand else: lsLonghand

func usesLabelShorthand*[A](self: RecordUpdateArg[A]): bool =
  mixin location
  self.value.location == self.location

func labelLocation*[A](self: RecordUpdateArg[A]): SrcSpan =
  ## The location of this argument's label. For the label shorthand syntax
  ## this spans the whole `label:`, otherwise it is just the label itself.
  if self.usesLabelShorthand:
    self.location
  else:
    initSrcSpan(self.location.start, self.location.start + self.label.len)

func labelSyntax*[A](self: RecordUpdateArg[A]): LabelSyntax =
  if self.usesLabelShorthand: lsShorthand else: lsLonghand

func patternCount*[A, B](self: Clause[A, B]): int =
  1 + self.alternativePatterns.len

func location*[A](self: ClauseGuard[A]): SrcSpan =
  case self.kind
  of cgConstant: self.vConstant.location
  of cgBinaryOperator: self.vBinaryOperator.location
  of cgNot: self.vNot.location
  of cgVar: self.vVar.location
  of cgTupleIndex: self.vTupleIndex.location
  of cgModuleSelect: self.vModuleSelect.location
  of cgInvalid: self.vInvalid.location
  of cgBlock: self.vBlock.location
  of cgFieldAccess:
    self.vFieldAccess.container[].location.merge(self.vFieldAccess.labelLocation)

func binOpName*[A](self: ClauseGuard[A]): Option[BinOp] =
  case self.kind
  of cgBinaryOperator:
    some(self.vBinaryOperator.operator)
  of cgConstant, cgInvalid, cgVar, cgNot, cgTupleIndex, cgFieldAccess, cgModuleSelect,
      cgBlock:
    none(BinOp)

func precedence*[A](self: ClauseGuard[A]): uint8 =
  # Ensure that this matches the other precedence function for guards
  let name = self.binOpName
  if name.isSome:
    name.get.precedence
  else:
    high(uint8)

func precedence*(self: IntOperator): uint8 =
  case self
  of ioAdd, ioSubtract: 7
  of ioMultiply, ioDivide, ioRemainder: 8

func toBinOp*(self: IntOperator): BinOp =
  case self
  of ioAdd: boAddInt
  of ioSubtract: boSubInt
  of ioMultiply: boMultInt
  of ioDivide: boDivInt
  of ioRemainder: boRemainderInt

func location*[T](self: BitArraySize[T]): SrcSpan =
  case self.kind
  of bsInt: self.vInt.location
  of bsVariable: self.vVariable.location
  of bsBinaryOperator: self.vBinaryOperator.location
  of bsBlock: self.vBlock.location

func compileTimeNumber*[T](self: BitArraySize[T]): Option[BigInt] =
  case self.kind
  of bsInt:
    some(self.vInt.intValue)
  of bsBlock:
    self.vBlock.inner[].compileTimeNumber
  of bsVariable, bsBinaryOperator:
    none(BigInt)

func nonZeroCompileTimeNumber*[T](self: BitArraySize[T]): bool =
  let number = self.compileTimeNumber
  number.isSome and number.get != initBigInt(0)

func syntacticallyEq*[T](self, other: BitArraySize[T]): bool =
  case self.kind
  of bsInt:
    other.kind == bsInt and self.vInt.intValue == other.vInt.intValue
  of bsVariable:
    other.kind == bsVariable and self.vVariable.name == other.vVariable.name
  of bsBinaryOperator:
    other.kind == bsBinaryOperator and
      self.vBinaryOperator.operator == other.vBinaryOperator.operator and
      self.vBinaryOperator.left[].syntacticallyEq(other.vBinaryOperator.left[]) and
      self.vBinaryOperator.right[].syntacticallyEq(other.vBinaryOperator.right[])
  of bsBlock:
    other.kind == bsBlock and self.vBlock.inner[].syntacticallyEq(other.vBlock.inner[])

func name*(self: AssignName): string =
  case self.kind
  of anVariable: self.vVariable
  of anDiscard: self.vDiscard

func toArgNames*(self: AssignName, location: SrcSpan): ArgNames =
  case self.kind
  of anVariable:
    ArgNames(kind: agNamed, vNamed: ArgNamesNamed(name: self.vVariable, location: location))
  of anDiscard:
    ArgNames(
      kind: agDiscard, vDiscard: ArgNamesDiscard(name: self.vDiscard, location: location)
    )

func assignedName*(self: AssignName): Option[string] =
  case self.kind
  of anVariable:
    some(self.vVariable)
  of anDiscard:
    none(string)

func location*[A](self: Pattern[A]): SrcSpan =
  case self.kind
  of paAssign:
    initSrcSpan(self.vAssign.pattern[].location.start, self.vAssign.location.stop)
  of paInt: self.vInt.location
  of paVariable: self.vVariable.location
  of paList: self.vList.location
  of paFloat: self.vFloat.location
  of paDiscard: self.vDiscard.location
  of paString: self.vString.location
  of paTuple: self.vTuple.location
  of paConstructor: self.vConstructor.location
  of paStringPrefix: self.vStringPrefix.location
  of paBitArray: self.vBitArray.location
  of paInvalid: self.vInvalid.location
  of paBitArraySize: self.vBitArraySize.location

func isDiscard*[A](self: Pattern[A]): bool =
  ## Returns `true` if the pattern is `Discard`.
  self.kind == paDiscard

func isVariable*[A](self: Pattern[A]): bool =
  self.kind == paVariable

func isString*[A](self: Pattern[A]): bool =
  self.kind == paString

func isAssert*[Expression](self: AssignmentKind[Expression]): bool =
  ## Returns `true` if the assignment kind is `Assert`.
  case self.kind
  of akAssert: true
  of akLet, akGenerated: false

func isBig*(self: Endianness): bool =
  self == enBig

func valueUnwrappingAssign*[Type](
    self: BitArraySegment[Pattern[Type], Type]
): Pattern[Type] =
  ## Returns the value of the pattern unwrapping any assign pattern.
  case self.value[].kind
  of paAssign:
    self.value[].vAssign.pattern[]
  of paInt, paFloat, paString, paVariable, paBitArraySize, paDiscard, paList,
      paConstructor, paTuple, paBitArray, paStringPrefix, paInvalid:
    self.value[]

func hasOption[Value, Type](
    self: BitArraySegment[Value, Type], kind: BitArrayOptionKind
): bool =
  for option in self.options:
    if option.kind == kind:
      return true
  false

func hasNativeOption*[Value, Type](self: BitArraySegment[Value, Type]): bool =
  self.hasOption(baNative)

func hasUtf16CodepointOption*[Value, Type](self: BitArraySegment[Value, Type]): bool =
  self.hasOption(baUtf16Codepoint)

func hasUtf32CodepointOption*[Value, Type](self: BitArraySegment[Value, Type]): bool =
  self.hasOption(baUtf32Codepoint)

func hasUtf16Option*[Value, Type](self: BitArraySegment[Value, Type]): bool =
  self.hasOption(baUtf16)

func hasUtf32Option*[Value, Type](self: BitArraySegment[Value, Type]): bool =
  self.hasOption(baUtf32)

func endianness*[Value, Type](self: BitArraySegment[Value, Type]): Endianness =
  if self.hasOption(baLittle): enLittle else: enBig

func signed*[Value, Type](self: BitArraySegment[Value, Type]): bool =
  self.hasOption(baSigned)

func size*[Value, Type](self: BitArraySegment[Value, Type]): Option[ref Value] =
  for option in self.options:
    if option.kind == baSize:
      return some(option.vSize.value)
  none(ref Value)

func unit*[Value, Type](self: BitArraySegment[Value, Type]): uint8 =
  ## Returns the unit of `size` in the bit array segment. The `unit` option
  ## overrides the `bytes` option, so if a segment has both, the unit is what
  ## is specified in `unit`, not 8.
  var hasBytesOption = false

  for option in self.options:
    case option.kind
    of baUnit:
      return option.vUnit.value
    of baBytes:
      hasBytesOption = true
    of baInt, baFloat, baBits, baUtf8, baUtf16, baUtf32, baUtf8Codepoint,
        baUtf16Codepoint, baUtf32Codepoint, baSigned, baUnsigned, baBig, baLittle,
        baNative, baSize:
      discard

  if hasBytesOption: 8 else: 1

func hasBitsOption*[Value, Type](self: BitArraySegment[Value, Type]): bool =
  self.hasOption(baBits)

func hasBytesOption*[Value, Type](self: BitArraySegment[Value, Type]): bool =
  self.hasOption(baBytes)

func truncate*(literalValue: BigInt, segmentBits: int64): BigInt =
  ## As Björn said, when a value is smaller than the segment's size it will be
  ## truncated, only taking the first `n` bits:
  ##
  ## > It will be silently truncated. In general, when storing value an integer
  ## > `I` into a segment of size `N`, the actual value stored will be
  ## > `I band ((1 bsl N) - 1)`.
  ##
  ## <https://erlangforums.com/t/what-happens-when-a-bit-array-segment-size-is-smaller-than-its-value/4650/2?u=giacomocavalieri>
  ##
  ## Thank you Björn!
  literalValue and ((initBigInt(1) shl int(segmentBits)) - initBigInt(1))

func value*[A](self: BitArrayOption[A]): Option[ref A] =
  case self.kind
  of baSize:
    some(self.vSize.value)
  of baBytes, baInt, baFloat, baBits, baUtf8, baUtf16, baUtf32, baUtf8Codepoint,
      baUtf16Codepoint, baUtf32Codepoint, baSigned, baUnsigned, baBig, baLittle,
      baNative, baUnit:
    none(ref A)

func location*[A](self: BitArrayOption[A]): SrcSpan =
  case self.kind
  of baBytes: self.vBytes.location
  of baInt: self.vInt.location
  of baFloat: self.vFloat.location
  of baBits: self.vBits.location
  of baUtf8: self.vUtf8.location
  of baUtf16: self.vUtf16.location
  of baUtf32: self.vUtf32.location
  of baUtf8Codepoint: self.vUtf8Codepoint.location
  of baUtf16Codepoint: self.vUtf16Codepoint.location
  of baUtf32Codepoint: self.vUtf32Codepoint.location
  of baSigned: self.vSigned.location
  of baUnsigned: self.vUnsigned.location
  of baBig: self.vBig.location
  of baLittle: self.vLittle.location
  of baNative: self.vNative.location
  of baSize: self.vSize.location
  of baUnit: self.vUnit.location

func label*[A](self: BitArrayOption[A]): string =
  case self.kind
  of baBytes: "bytes"
  of baInt: "int"
  of baFloat: "float"
  of baBits: "bits"
  of baUtf8: "utf8"
  of baUtf16: "utf16"
  of baUtf32: "utf32"
  of baUtf8Codepoint: "utf8_codepoint"
  of baUtf16Codepoint: "utf16_codepoint"
  of baUtf32Codepoint: "utf32_codepoint"
  of baSigned: "signed"
  of baUnsigned: "unsigned"
  of baBig: "big"
  of baLittle: "little"
  of baNative: "native"
  of baSize: "size"
  of baUnit: "unit"

func isTypeOption*[A](self: BitArrayOption[A]): bool =
  case self.kind
  of baBytes, baInt, baFloat, baBits, baUtf8, baUtf16, baUtf32, baUtf8Codepoint,
      baUtf16Codepoint, baUtf32Codepoint:
    true
  of baSigned, baUnsigned, baBig, baLittle, baNative, baSize, baUnit:
    false

func hasTypeOption*[Value, Type](self: BitArraySegment[Value, Type]): bool =
  for option in self.options:
    if option.isTypeOption:
      return true
  false

func syntacticallyEq*[A](
    self, other: BitArrayOption[A], compareSizes: proc(a, b: A): bool {.noSideEffect.}
): bool =
  if self.kind != other.kind:
    return false
  case self.kind
  of baBytes, baInt, baFloat, baBits, baUtf8, baUtf16, baUtf32, baUtf8Codepoint,
      baUtf16Codepoint, baUtf32Codepoint, baSigned, baUnsigned, baBig, baLittle, baNative:
    true
  of baUnit:
    self.vUnit.value == other.vUnit.value
  of baSize:
    self.vSize.shortForm == other.vSize.shortForm and
      compareSizes(self.vSize.value[], other.vSize.value[])

func len*(self: GroupedDefinitions): int =
  self.functions.len + self.constants.len + self.imports.len + self.customTypes.len +
    self.typeAliases.len

func add(self: var GroupedDefinitions, statement: UntypedDefinition) =
  case statement.kind
  of dfImport: self.imports.add statement.vImport
  of dfFunction: self.functions.add statement.vFunction
  of dfTypeAlias: self.typeAliases.add statement.vTypeAlias
  of dfCustomType: self.customTypes.add statement.vCustomType
  of dfModuleConstant: self.constants.add statement.vModuleConstant

func initGroupedDefinitions*(
    definitions: openArray[UntypedDefinition]
): GroupedDefinitions =
  ## Upstream `GroupedDefinitions::new`.
  for definition in definitions:
    result.add definition

func isExpression*[T, E](self: Statement[T, E]): bool =
  ## Returns `true` if the statement is `Expression`.
  self.kind == stExpression

func isUse*[T, E](self: Statement[T, E]): bool =
  self.kind == stUse

func location*(self: UntypedStatement): SrcSpan =
  case self.kind
  of stExpression:
    self.vExpression.location
  of stAssignment:
    self.vAssignment.location
  of stUse:
    self.vUse.location.merge(self.vUse.call[].location)
  of stAssert:
    self.vAssert.location

func startByteIndex*(self: UntypedStatement): int =
  case self.kind
  of stExpression:
    self.vExpression.startByteIndex
  of stAssignment:
    self.vAssignment.location.start
  of stUse:
    self.vUse.location.start
  of stAssert:
    self.vAssert.location.start
