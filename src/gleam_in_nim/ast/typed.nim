## port-part-of: compiler-core/src/ast/typed.rs
## (`find_node`, `find_statement` and `Located` wait for the language server: see below)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/ast/typed.rs.

## The typed expressions: what the type checker makes of the body of a
## function. Every expression knows its type.
##
## This file is included by `ast.nim` (it is not a module of its own), the way
## upstream's `typed.rs` starts with `use super::*`: import `ast` to use it.
## The types are here; the functions are in `ast/typed_functions.nim`, which
## `ast.nim` includes after the functions they call.
##
## - `ModuleValueConstructor` is upstream in `type_.rs`. It is here because it
##   holds a typed constant, and `TypedExpr` holds it (decision 0011).
## - `TypedPipelineAssignment` is upstream in `ast.rs`. It is here because it
##   and `TypedExpr` hold each other, and Nim wants such types in one `type`
##   section.
## - `InvalidExpression` is upstream in this file; it is in `ast.nim` because
##   `Constant` needs it.
## - Not ported: `find_node`, `find_statement`, `self_if_contains_location`
##   and `impl From<&TypedExpr> for Located`. They answer "what is under the
##   cursor" for the language server and return references into the tree;
##   they come with the roadmap step `lsp-engine`.

type
  ModuleValueConstructorKind* = enum
    mvRecord
    mvFn
    mvConstant

  ModuleValueConstructorRecord* = object of StructVariant
    name*: string
    variantIndex*: int
    arity*: int
    typ*: Type
    fieldMap*: Option[FieldMap]
    location*: SrcSpan
    documentation*: Option[string]

  ModuleValueConstructorFn* = object of StructVariant
    location*: SrcSpan
    module*: string
      ## The name of the module and the function
      ## This will be the module that this constructor belongs to
      ## and the name that was used for the function.
    name*: string
    externalErlang*: Option[(string, string)]
      ## If this is an `external` function, these will hold the name of the
      ## external module and function.
      ##
      ## This function has module "themodule" and name "wibble"
      ##     pub fn wibble() { Nil }
      ##
      ## This function has module "themodule" and name "wibble"
      ## and Erlang external "other" and "whoop".
      ##     @external(erlang, "other", "whoop")
      ##     pub fn wibble() -> Nil
    externalJavascript*: Option[(string, string)]
    fieldMap*: Option[FieldMap]
    documentation*: Option[string]
    purity*: Purity

  ModuleValueConstructorConstant* = object of StructVariant
    literal*: Constant[Type]
    location*: SrcSpan
    documentation*: Option[string]

  ModuleValueConstructor* = object
    case kind*: ModuleValueConstructorKind
    of mvRecord: vRecord*: ModuleValueConstructorRecord
    of mvFn: vFn*: ModuleValueConstructorFn
    of mvConstant: vConstant*: ModuleValueConstructorConstant

  TypedExprKind* = enum
    teInt
    teFloat
    teString
    teBlock
    tePipeline
      ## A chain of pipe expressions.
      ## By this point the type checker has expanded it into a series of
      ## assignments and function calls, but we still have a Pipeline AST node as
      ## even though it is identical to `Block` we want to use different
      ## locations when showing it in error messages, etc.
    teVar
    teFn
    teList
    teCall
    teBinOp
    teCase
    teRecordAccess
    tePositionalAccess
      ## Generated internally for accessing unlabelled fields of a custom type,
      ## such as for record updates.
    teModuleSelect
    teTuple
    teTupleIndex
    teTodo
    tePanic
    teEcho
    teBitArray
    teRecordUpdate
      ## A record update gets desugared to a block expression of the form
      ##
      ## {
      ##   let _record = record
      ##   Constructor(explicit_arg: explicit_value(), implicit_arg: _record.implicit_arg)
      ## }
      ##
      ## We still keep a separate `RecordUpdate` AST node for the same reasons as
      ## we do for pipelines.
    teNegateBool
    teNegateInt
    teInvalid
      ## A placeholder expression used to allow module analysis to continue
      ## even when there are type errors. Should never end up in generated code.

  TypedExprInt* = object of StructVariant
    location*: SrcSpan
    typ*: Type
    value*: string
    intValue*: BigInt

  TypedExprFloat* = object of StructVariant
    location*: SrcSpan
    typ*: Type
    value*: string
    floatValue*: LiteralFloatValue

  TypedExprString* = object of StructVariant
    location*: SrcSpan
    typ*: Type
    value*: string

  TypedExprBlock* = object of StructVariant
    location*: SrcSpan
    statements*: seq[Statement[Type, TypedExpr]] ## Upstream a `Vec1`: never empty.

  TypedExprPipeline* = object of StructVariant
    location*: SrcSpan
    firstValue*: TypedPipelineAssignment
    assignments*: seq[(TypedPipelineAssignment, PipelineAssignmentKind)]
    finally*: ref TypedExpr
    finallyKind*: PipelineAssignmentKind

  TypedExprVar* = object of StructVariant
    location*: SrcSpan
    constructor*: ValueConstructor
    name*: string

  TypedExprFn* = object of StructVariant
    location*: SrcSpan
    typ*: Type
    kind*: FunctionLiteralKind
    arguments*: seq[Arg[Type]]
    body*: seq[Statement[Type, TypedExpr]] ## Upstream a `Vec1`: never empty.
    returnAnnotation*: Option[TypeAst]
    purity*: Purity

  TypedExprList* = object of StructVariant
    location*: SrcSpan
    typ*: Type
    elements*: seq[TypedExpr]
    tail*: Option[ref TypedExpr]

  TypedExprCall* = object of StructVariant
    location*: SrcSpan
    typ*: Type
    fun*: ref TypedExpr
    arguments*: seq[CallArg[TypedExpr]]
    openParenthesis*: Option[int]
      ## Specifies the source position of the argument list, if present. Can
      ## be None in cases where the function call is part of a pipeline.

  TypedExprBinOp* = object of StructVariant
    location*: SrcSpan
    typ*: Type
    operator*: BinOp
    operatorStart*: int
    left*: ref TypedExpr
    right*: ref TypedExpr

  TypedExprCase* = object of StructVariant
    location*: SrcSpan
    typ*: Type
    subjects*: seq[TypedExpr]
    clauses*: seq[Clause[TypedExpr, Type]]
    compiledCase*: CompiledCase

  TypedExprRecordAccess* = object of StructVariant
    location*: SrcSpan
    fieldStart*: int
    typ*: Type
    label*: string
    index*: uint64
    record*: ref TypedExpr
    documentation*: Option[string]

  TypedExprPositionalAccess* = object of StructVariant
    location*: SrcSpan
    typ*: Type
    index*: uint64
    record*: ref TypedExpr

  TypedExprModuleSelect* = object of StructVariant
    location*: SrcSpan
    fieldStart*: int
    typ*: Type
    label*: string
    moduleName*: string
    moduleAlias*: string
    constructor*: ModuleValueConstructor

  TypedExprTuple* = object of StructVariant
    location*: SrcSpan
    typ*: Type
    elements*: seq[TypedExpr]

  TypedExprTupleIndex* = object of StructVariant
    location*: SrcSpan
    typ*: Type
    index*: uint64
    tupl*: ref TypedExpr

  TypedExprTodo* = object of StructVariant
    location*: SrcSpan
    message*: Option[ref TypedExpr]
    kind*: TodoKind
    typ*: Type

  TypedExprPanic* = object of StructVariant
    location*: SrcSpan
    message*: Option[ref TypedExpr]
    typ*: Type

  TypedExprEcho* = object of StructVariant
    location*: SrcSpan
    typ*: Type
    expression*: Option[ref TypedExpr]
    message*: Option[ref TypedExpr]

  TypedExprBitArray* = object of StructVariant
    location*: SrcSpan
    typ*: Type
    segments*: seq[BitArraySegment[TypedExpr, Type]]

  TypedExprRecordUpdate* = object of StructVariant
    location*: SrcSpan
    spreadStart*: int
      ## This is where the `..` starts:
      ## ```gleam
      ## Wibble(  ..wobble, a: 1)
      ## //       ^ Here!
      ## ```
    typ*: Type
    updatedRecord*: ref TypedExpr
      ## This is the record being updated as written in the code:
      ## ```gleam
      ## Wibble(..wibble, a: 1)
      ## //       ^^^^^^ This!
      ##
      ## Wibble(..fun(1), a: 1)
      ## //       ^^^^^ This!
      ## ```
    updatedRecordAssignedName*: Option[string]
      ## If the record is an expression that is not a variable we will need
      ## to assign to a variable so it can be referred to multiple times.
      ## If this is `Some` it will contain the name we've picked for the
      ## variable the record should be assigned to.
    constructor*: ref TypedExpr
      ## The constructor used to build a new record:
      ## ```gleam
      ##   Wibble(..wibble, a: 1)
      ## //^^^^^^ This!
      ## ```
    arguments*: seq[CallArg[TypedExpr]]

  TypedExprNegateBool* = object of StructVariant
    location*: SrcSpan
    value*: ref TypedExpr

  TypedExprNegateInt* = object of StructVariant
    location*: SrcSpan
    value*: ref TypedExpr

  TypedExprInvalid* = object of StructVariant
    location*: SrcSpan
    typ*: Type
    extraInformation*: Option[InvalidExpression]
      ## Extra information about the invalid expression, useful for providing
      ## addition help or information, such as code actions to fix invalid
      ## states.

  TypedExpr* = object
    case kind*: TypedExprKind
    of teInt: vInt*: TypedExprInt
    of teFloat: vFloat*: TypedExprFloat
    of teString: vString*: TypedExprString
    of teBlock: vBlock*: TypedExprBlock
    of tePipeline: vPipeline*: TypedExprPipeline
    of teVar: vVar*: TypedExprVar
    of teFn: vFn*: TypedExprFn
    of teList: vList*: TypedExprList
    of teCall: vCall*: TypedExprCall
    of teBinOp: vBinOp*: TypedExprBinOp
    of teCase: vCase*: TypedExprCase
    of teRecordAccess: vRecordAccess*: TypedExprRecordAccess
    of tePositionalAccess: vPositionalAccess*: TypedExprPositionalAccess
    of teModuleSelect: vModuleSelect*: TypedExprModuleSelect
    of teTuple: vTuple*: TypedExprTuple
    of teTupleIndex: vTupleIndex*: TypedExprTupleIndex
    of teTodo: vTodo*: TypedExprTodo
    of tePanic: vPanic*: TypedExprPanic
    of teEcho: vEcho*: TypedExprEcho
    of teBitArray: vBitArray*: TypedExprBitArray
    of teRecordUpdate: vRecordUpdate*: TypedExprRecordUpdate
    of teNegateBool: vNegateBool*: TypedExprNegateBool
    of teNegateInt: vNegateInt*: TypedExprNegateInt
    of teInvalid: vInvalid*: TypedExprInvalid

  TypedPipelineAssignment* = object
    ## A pipeline is desugared to a series of assignments:
    ##
    ## ```gleam
    ## wibble |> wobble |> woo
    ## ```
    ##
    ## Becomes:
    ##
    ## ```erl
    ## Pipe1 = wibble
    ## Pipe2 = wobble(Pipe1)
    ## woo(Pipe2)
    ## ```
    ##
    ## This represents one of such assignments once the pipeline has been desugared
    ## and each step has been typed.
    ##
    ## > We're not using a more general `TypedAssignment` node since that has much
    ## > more informations to carry around. This one is limited since we know it
    ## > will always be in the form `VarName = <Expr>`, with no patterns on the
    ## > left hand side of the assignment.
    ## > Being more constrained simplifies code generation for pipelines!
    location*: SrcSpan
      ## This is the location of the corresponding pipeline step.
      ##
      ## Take this pipeline:
      ##
      ## ```gleam
      ## wibble |> wobble |> woo
      ## ```
      ##
      ## It's made of two steps and a final expression:
      ##
      ## ```gleam
      ## let step_0 = wibble
      ## let step_1 = wobble(step_0)
      ## woo(step_1)
      ## ```
      ##
      ## The locations of each step would be the following:
      ##
      ## ```gleam
      ## wibble |> wobble |> woo
      ## ^^^^^^ location of first step
      ##           ^^^^^^ location of second step
      ## ```
    name*: string
    value*: ref TypedExpr
