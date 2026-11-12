## port-part-of: compiler-core/src/ast.rs
## port-part-of-note: the three `type_ast_print_*` tests of that file
##
## The upstream tests of `TypeAst::print`, then tests of ours: a small untyped
## tree built by hand, to instantiate every generic type and call the
## functions of `ast.nim`, `ast/constant.nim` and `ast/untyped.nim`.
## `module_dependencies_test` needs the parser and comes with it.

import std/sets
import gleam_in_nim/ast

func span(start, stop: int): SrcSpan =
  initSrcSpan(start, stop)

func typeVar(name: string): TypeAst =
  TypeAst(kind: tyVar, vVar: TypeAstVar(location: span(1, 1), name: name))

func someType(): TypeAst =
  TypeAst(
    kind: tyConstructor,
    vConstructor: TypeAstConstructor(
      name: TypeAstConstructorName(
        kind: tnQualified,
        vQualified: TypeAstConstructorNameQualified(
          module: "some_module",
          dotLocation: 1,
          moduleLocation: span(1, 1),
          name: some(("SomeType", span(1, 1))),
        ),
      ),
      location: span(1, 1),
      arguments: @[typeVar("String"), typeVar("Bool")],
      startParentheses: some(1),
    ),
  )

func fnType(): TypeAst =
  TypeAst(
    kind: tyFn,
    vFn: TypeAstFn(
      location: span(1, 1),
      arguments: @[typeVar("String"), typeVar("Bool")],
      returns: box(typeVar("Int")),
    ),
  )

block typeAstPrintFn:
  var buffer = ""
  fnType().print(buffer)
  doAssert buffer == "fn(String, Bool) -> Int"

block typeAstPrintConstructor:
  var buffer = ""
  someType().print(buffer)
  doAssert buffer == "some_module.SomeType(String, Bool)"

block typeAstPrintTuple:
  var buffer = ""
  let ast = TypeAst(
    kind: tyTuple,
    vTuple: TypeAstTuple(location: span(1, 1), elements: @[someType(), fnType()]),
  )
  ast.print(buffer)
  doAssert buffer == "#(some_module.SomeType(String, Bool), fn(String, Bool) -> Int)"

# ---------------------------------------------------------------------------
# Not upstream.
# ---------------------------------------------------------------------------

func intExpr(value: int, start, stop: int): UntypedExpr =
  UntypedExpr(
    kind: ueInt,
    vInt: UntypedExprInt(location: span(start, stop), value: $value, intValue: initBigInt(value)),
  )

func varExpr(name: string, start, stop: int): UntypedExpr =
  UntypedExpr(kind: ueVar, vVar: UntypedExprVar(location: span(start, stop), name: name))

func varPattern(name: string, start, stop: int): UntypedPattern =
  UntypedPattern(
    kind: paVariable,
    vVariable: PatternVariable[Unit](
      location: span(start, stop),
      name: name,
      origin: VariableOrigin(
        syntax: VariableSyntax(kind: vsVariable, vVariable: name),
        declaration: VariableDeclaration(kind: vdLetPattern),
      ),
    ),
  )

block typeAst:
  doAssert someType().location == span(1, 1)
  doAssert someType().isLogicallyEqual(someType())
  doAssert not someType().isLogicallyEqual(fnType())
  doAssert fnType().isLogicallyEqual(fnType())
  doAssert not typeVar("a").isLogicallyEqual(typeVar("b"))
  let name = someType().vConstructor.name
  doAssert name.isQualified and name.moduleName == some("some_module")
  doAssert name.name == some("SomeType") and name.nameLocation == some(span(1, 1))

block operators:
  doAssert boOr.precedence < boAnd.precedence
  doAssert boAddInt.precedence == 7 and PIPE_PRECEDENCE == 6
  doAssert boLtEqFloat.name == "<=." and boLtEqFloat.size == 3
  doAssert boAddInt.floatEquivalent == some(boAddFloat)
  doAssert boAddFloat.intEquivalent == some(boAddInt)
  doAssert boRemainderInt.floatEquivalent.isNone
  doAssert boAddInt.canBeGroupedWith(boDivInt) and not boAddInt.canBeGroupedWith(boAddFloat)
  doAssert boAnd.isBoolOperator and boLtInt.isIntOperator and boGtFloat.isFloatOperator
  doAssert ioSubtract.toBinOp == boSubInt and ioMultiply.precedence == 8
  for op in BinOp:
    doAssert op.name.len == op.size

block expressions:
  # 1 + x |> f
  let sum = UntypedExpr(
    kind: ueBinOp,
    vBinOp: UntypedExprBinOp(
      location: span(0, 5),
      operator: boAddInt,
      operatorStart: 2,
      left: box(intExpr(1, 0, 1)),
      right: box(varExpr("x", 4, 5)),
    ),
  )
  let pipeline = UntypedExpr(
    kind: uePipeline, vPipeline: UntypedExprPipeline(expressions: @[sum, varExpr("f", 9, 10)])
  )
  doAssert pipeline.location == span(0, 10)
  doAssert pipeline.startByteIndex == 0
  doAssert pipeline.binOpPrecedence == 5 and sum.binOpPrecedence == 7
  doAssert sum.binOpName == some(boAddInt) and pipeline.binOpName.isNone
  doAssert sum.isBinop and pipeline.isPipeline and not sum.isCall
  doAssert intExpr(1, 0, 1).canHaveMultiplePerLine and not sum.canHaveMultiplePerLine
  let negated = UntypedExpr(
    kind: ueNegateInt,
    vNegateInt: UntypedExprNegateInt(location: span(0, 2), value: box(intExpr(1, 1, 2))),
  )
  doAssert negated.canHaveMultiplePerLine

  # f(_capture, label: x), with the shorthand `x:`
  let hole = CallArg[UntypedExpr](location: span(2, 3), value: varExpr(CAPTURE_VARIABLE, 2, 3))
  let longhand = CallArg[UntypedExpr](
    label: some("label"), location: span(5, 13), value: varExpr("x", 12, 13)
  )
  let shorthand =
    CallArg[UntypedExpr](label: some("x"), location: span(5, 7), value: varExpr("x", 5, 7))
  doAssert hole.isCaptureHole and not longhand.isCaptureHole
  doAssert not longhand.usesLabelShorthand and shorthand.usesLabelShorthand
  doAssert longhand.labelLocation == some(span(5, 10))
  doAssert shorthand.labelLocation == some(span(5, 7))
  doAssert hole.labelLocation.isNone
  doAssert longhand.labelSyntax == lsLonghand and shorthand.labelSyntax == lsShorthand
  doAssert not hole.isImplicit and not hole.isUseImplicitCallback
  let update = RecordUpdateArg[UntypedExpr](
    label: "name", location: span(0, 7), value: varExpr("n", 6, 7)
  )
  doAssert not update.usesLabelShorthand and update.labelLocation == span(0, 4)
  doAssert update.labelSyntax == lsLonghand

  let kind = FunctionLiteralKind(
    kind: flAnonymous, vAnonymous: FunctionLiteralKindAnonymous(head: span(0, 4))
  )
  doAssert kind.isAnonymous and not kind.isCapture

block patternsAndStatements:
  # let [a, ..rest] as all = x
  let list = UntypedPattern(
    kind: paList,
    vList: PatternList[Unit](
      location: span(4, 15),
      elements: @[varPattern("a", 5, 6)],
      tail: some(
        box(UntypedTailPattern(location: span(8, 14), pattern: varPattern("rest", 10, 14)))
      ),
    ),
  )
  let assign = UntypedPattern(
    kind: paAssign,
    vAssign: PatternAssign[Unit](name: "all", location: span(16, 22), pattern: box(list)),
  )
  doAssert list.location == span(4, 15)
  doAssert assign.location == span(4, 22)
  doAssert varPattern("a", 5, 6).isVariable and not list.isDiscard and not list.isString

  let assignment = UntypedStatement(
    kind: stAssignment,
    vAssignment: box(
      UntypedAssignment(
        location: span(0, 26),
        value: varExpr("x", 25, 26),
        pattern: assign,
        kind: AssignmentKind[UntypedExpr](kind: akLet),
        compiledCase: CompiledCase.failure,
      )
    ),
  )
  doAssert assignment.location == span(0, 26) and assignment.startByteIndex == 0
  doAssert not assignment.isExpression and not assignment.isUse
  doAssert not assignment.vAssignment.kind.isAssert

  let use = UntypedStatement(
    kind: stUse,
    vUse: UntypedUse(
      call: box(varExpr("f", 9, 10)),
      location: span(0, 8),
      rightHandSideLocation: span(9, 10),
      assignmentsLocation: span(4, 5),
      assignments: @[UntypedUseAssignment(location: span(4, 5), pattern: varPattern("a", 4, 5))],
    ),
  )
  doAssert use.isUse and use.location == span(0, 10)

  let statement = UntypedStatement(kind: stExpression, vExpression: intExpr(1, 3, 4))
  doAssert statement.isExpression and statement.location == span(3, 4)

  # a guard: `a.b > 1`
  let guard = UntypedClauseGuard(
    kind: cgBinaryOperator,
    vBinaryOperator: ClauseGuardBinaryOperator[Unit](
      location: span(0, 7),
      operator: boGtInt,
      operatorStart: 4,
      left: box(
        UntypedClauseGuard(
          kind: cgFieldAccess,
          vFieldAccess: ClauseGuardFieldAccess[Unit](
            labelLocation: span(2, 3),
            label: "b",
            container: box(
              UntypedClauseGuard(
                kind: cgVar,
                vVar: ClauseGuardVar[Unit](
                  location: span(0, 1), name: "a", origin: VariableOrigin.generated
                ),
              )
            ),
          ),
        )
      ),
      right: box(
        UntypedClauseGuard(
          kind: cgConstant,
          vConstant: UntypedConstant(
            kind: coInt,
            vInt: ConstantInt(location: span(6, 7), value: "1", intValue: initBigInt(1)),
          ),
        )
      ),
    ),
  )
  doAssert guard.location == span(0, 7) and guard.precedence == 4
  doAssert guard.vBinaryOperator.left[].location == span(0, 3)
  doAssert guard.vBinaryOperator.left[].precedence == high(uint8)
  doAssert guard.vBinaryOperator.right[].location == span(6, 7)

  let clause = UntypedClause(
    location: span(0, 20),
    pattern: @[list],
    alternativePatterns: @[@[assign]],
    guard: some(guard),
    then: intExpr(1, 19, 20),
  )
  doAssert clause.patternCount == 2

block bitArrays:
  # <<x:size(8)-little-unit(2)>>
  let size = UntypedPattern(
    kind: paBitArraySize,
    vBitArraySize: BitArraySize[Unit](
      kind: bsBlock,
      vBlock: BitArraySizeBlock[Unit](
        location: span(9, 10),
        inner: box(
          BitArraySize[Unit](
            kind: bsInt,
            vInt: BitArraySizeInt(location: span(9, 10), value: "8", intValue: initBigInt(8)),
          )
        ),
      ),
    ),
  )
  doAssert size.location == span(9, 10)
  doAssert size.vBitArraySize.compileTimeNumber == some(initBigInt(8))
  doAssert size.vBitArraySize.nonZeroCompileTimeNumber
  doAssert size.vBitArraySize.syntacticallyEq(size.vBitArraySize)
  let segment = UntypedPatternBitArraySegment(
    location: span(2, 26),
    value: box(varPattern("x", 2, 3)),
    options: @[
      BitArrayOption[UntypedPattern](
        kind: baSize,
        vSize: BitArrayOptionSize[UntypedPattern](location: span(4, 11), value: box(size)),
      ),
      BitArrayOption[UntypedPattern](
        kind: baLittle, vLittle: BitArrayOptionLocation(location: span(12, 18))
      ),
      BitArrayOption[UntypedPattern](
        kind: baUnit, vUnit: BitArrayOptionUnit(location: span(19, 26), value: 2)
      ),
    ],
  )
  doAssert segment.endianness == enLittle and not segment.endianness.isBig
  doAssert segment.unit == 2 and segment.size.isSome
  doAssert not segment.signed and not segment.hasTypeOption and not segment.hasNativeOption
  doAssert not segment.hasBytesOption and not segment.hasBitsOption
  doAssert not segment.hasUtf16Option and not segment.hasUtf32Option
  doAssert not segment.hasUtf16CodepointOption and not segment.hasUtf32CodepointOption
  doAssert segment.valueUnwrappingAssign.isVariable
  doAssert segment.options[0].label == "size" and segment.options[2].label == "unit"
  doAssert segment.options[1].location == span(12, 18)
  doAssert segment.options[0].value.isSome and segment.options[1].value.isNone
  doAssert not segment.options[1].isTypeOption
  let sameSize = proc(a, b: UntypedPattern): bool {.noSideEffect.} =
    a.kind == b.kind
  doAssert segment.options[0].syntacticallyEq(segment.options[0], sameSize)
  doAssert not segment.options[0].syntacticallyEq(segment.options[1], sameSize)
  doAssert truncate(initBigInt(258), 8) == initBigInt(2)

block constants:
  let one = UntypedConstant(
    kind: coInt, vInt: ConstantInt(location: span(0, 1), value: "1", intValue: initBigInt(1))
  )
  let sum = UntypedConstant(
    kind: coBinaryOperator,
    vBinaryOperator: ConstantBinaryOperator[Unit](
      location: span(0, 5), operatorStart: 2, operator: boAddInt, left: box(one), right: box(one)
    ),
  )
  let record = UntypedConstant(
    kind: coRecord,
    vRecord: ConstantRecord[Unit](
      location: span(0, 9),
      name: "Wibble",
      arguments: some(@[CallArg[UntypedConstant](location: span(7, 8), value: one)]),
      fieldMap: unknown[FieldMap](),
    ),
  )
  doAssert sum.location == span(0, 5) and sum.isBinop and not sum.isTuple
  doAssert sum.binOpPrecedence == 7 and one.binOpPrecedence == high(uint8)
  doAssert sum.binOpName == some(boAddInt) and one.binOpName.isNone
  doAssert one.canHaveMultiplePerLine and not record.canHaveMultiplePerLine
  doAssert record.vRecord.fieldMap.kind == inUnknown
  doAssert record.vRecord.recordConstructor.isNone

block modules:
  func importOf(module: string, start, stop: int, target = none(Target)): TargetedDefinition =
    TargetedDefinition(
      definition: UntypedDefinition(
        kind: dfImport,
        vImport: UntypedImport(location: span(start, stop), module: module),
      ),
      target: target,
    )

  let function = UntypedDefinition(
    kind: dfFunction,
    vFunction: UntypedFunction(
      location: span(130, 143),
      endPosition: 150,
      name: some((span(137, 141), "main")),
      arguments: @[
        UntypedArg(
          names: ArgNames(
            kind: agNamedLabelled,
            vNamedLabelled: ArgNamesNamedLabelled(
              label: "to", labelLocation: span(142, 144), name: "x", nameLocation: span(145, 146)
            ),
          ),
          location: span(142, 146),
        )
      ],
      body: @[UntypedStatement(kind: stExpression, vExpression: intExpr(1, 147, 148))],
      publicity: Publicity(kind: pbInternal, vInternal: PublicityInternal()),
      documentation: some((120, " The entry point")),
      implementations: Implementations.supportingAll,
      purity: puPure,
    ),
  )
  doAssert function.location == span(130, 143) and function.isFunction
  doAssert function.vFunction.fullLocation == span(130, 150)
  doAssert function.getDoc == some(" The entry point")
  doAssert function.isInternal and not function.isImport and not function.isCustomType
  let argument = function.vFunction.arguments[0]
  doAssert argument.getVariableName == some("x") and not argument.isCaptureHole
  doAssert argument.names.getLabel == some(("to", span(142, 144)))
  doAssert argument.setType(1).typ == 1
  doAssert function.vFunction.publicity.isImportable
  doAssert not function.vFunction.publicity.isPublic
  doAssert not function.vFunction.publicity.isPrivate

  # The module of upstream's `module_dependencies_test`, built by hand.
  let module = UntypedModule(
    name: "one/two",
    definitions: @[
      importOf("one", 0, 10),
      importOf("two", 45, 55, some(tgErlang)),
      importOf("three", 90, 102, some(tgJavaScript)),
      importOf("four", 118, 129),
      TargetedDefinition(definition: function),
    ],
    names: initNames(),
  )
  doAssert module.dependencies(tgErlang) ==
    @[("one", span(0, 10)), ("two", span(45, 55)), ("four", span(118, 129))]
  doAssert module.erlangName == "one@two"
  doAssert module.unusedDefinitionPositions.len == 0

  var all: seq[UntypedDefinition]
  for definition in module.iterDefinitions(tgJavaScript):
    all.add definition
  let grouped = initGroupedDefinitions(all)
  doAssert grouped.len == 4 and grouped.imports.len == 3 and grouped.functions.len == 1

  let aliased = UntypedImport(
    module: "animal/cat",
    asName: some((AssignName(kind: anVariable, vVariable: "kitty"), span(18, 26))),
  )
  doAssert aliased.usedName == some("kitty") and aliased.aliasLocation == some(span(18, 26))
  doAssert UntypedImport(module: "animal/cat").usedName == some("cat")
  let discarded = AssignName(kind: anDiscard, vDiscard: "_cat")
  doAssert discarded.name == "_cat" and discarded.assignedName.isNone
  doAssert discarded.toArgNames(span(0, 4)).kind == agDiscard
  let unqualified =
    UnqualifiedImport(location: span(0, 16), name: "Wibble", namePosition: 5, asName: some("W"))
  doAssert unqualified.usedName == "W" and unqualified.nameLocation == span(5, 11)

  var constructor = RecordConstructor[Unit](name: "Cat")
  constructor.putDoc((3, " A cat"))
  doAssert constructor.documentation == some((3, " A cat"))
  let customType = UntypedCustomType(location: span(0, 12), endPosition: 40)
  doAssert customType.fullLocation == span(0, 40)
  doAssert laValue.isValue and tgErlang.isErlang

echo "ok: ast"
