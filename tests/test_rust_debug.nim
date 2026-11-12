## The Rust Debug printer, on a small tree shaped like the real one. The
## expected text is what the parser oracle printed for `let x = [1, ..y]`
## (cut down to the fields of this toy tree).

import std/[unittest, options]
import gleam_in_nim/[rust_debug, src_span]
import pkg/bigints

type
  ToyExprKind = enum
    teInt
    teVar
    teList
    teTodo

  ToyExprInt = object of StructVariant
    location: SrcSpan
    value: string
    intValue: BigInt

  ToyExprVar = object of StructVariant
    location: SrcSpan
    name: string

  ToyExprList = object of StructVariant
    location: SrcSpan
    elements: seq[ToyExpr]
    tail: Option[ref ToyExpr]

  ToyExpr = object
    case kind: ToyExprKind
    of teInt: vInt: ToyExprInt
    of teVar: vVar: ToyExprVar
    of teList: vList: ref ToyExprList
    of teTodo: discard

  ToyKind = enum
    tkLet
    tkAssert

  ToyAssignment = object
    location: SrcSpan
    value: ToyExpr
    typ: Unit
    kind: ToyKind
    annotation: Option[string]
    origin: (SrcSpan, string)

  ToyStatementKind = enum
    tsAssignment
    tsExpression

  ToyStatement = object
    case kind: ToyStatementKind
    of tsAssignment: vAssignment: ref ToyAssignment
    of tsExpression: vExpression: ToyExpr

func boxed[T](x: T): ref T =
  new result
  result[] = x

suite "rust_debug":
  test "a tree prints like Rust's {:#?}":
    let y = ToyExpr(kind: teVar, vVar: ToyExprVar(location: initSrcSpan(14, 15), name: "y"))
    let list = ToyExpr(
      kind: teList,
      vList: boxed ToyExprList(
        location: initSrcSpan(8, 16),
        elements: @[
          ToyExpr(
            kind: teInt,
            vInt: ToyExprInt(location: initSrcSpan(9, 10), value: "1", intValue: initBigInt(1)),
          )
        ],
        tail: some(boxed y),
      ),
    )
    let statements = @[
      ToyStatement(
        kind: tsAssignment,
        vAssignment: boxed ToyAssignment(
          location: initSrcSpan(0, 16),
          value: list,
          kind: tkLet,
          annotation: none(string),
          origin: (initSrcSpan(4, 5), "x"),
        ),
      ),
      ToyStatement(kind: tsExpression, vExpression: ToyExpr(kind: teTodo)),
    ]
    check debugRepr(statements) == """[
    Assignment(
        ToyAssignment {
            location: SrcSpan {
                start: 0,
                end: 16,
            },
            value: List {
                location: SrcSpan {
                    start: 8,
                    end: 16,
                },
                elements: [
                    Int {
                        location: SrcSpan {
                            start: 9,
                            end: 10,
                        },
                        value: "1",
                        int_value: 1,
                    },
                ],
                tail: Some(
                    Var {
                        location: SrcSpan {
                            start: 14,
                            end: 15,
                        },
                        name: "y",
                    },
                ),
            },
            type_: (),
            kind: Let,
            annotation: None,
            origin: (
                SrcSpan {
                    start: 4,
                    end: 5,
                },
                "x",
            ),
        },
    ),
    Expression(
        Todo,
    ),
]"""

  test "strings":
    check rustString("a\"b\\c\nd\te") == "\"a\\\"b\\\\c\\nd\\te\""
    check rustString("héllo 🦀") == "\"héllo 🦀\""
    check rustString("\x01\u{200B}") == "\"\\u{1}\\u{200b}\""

  test "floats":
    check rustFloat(1.0) == "1.0"
    check rustFloat(1.5) == "1.5"
    check rustFloat(-0.0) == "-0.0"
    check rustFloat(0.1) == "0.1"
    check rustFloat(1e15) == "1000000000000000.0"
    check rustFloat(1e16) == "1e16"
    check rustFloat(1.2345678901234568e17) == "1.2345678901234568e17"
    check rustFloat(0.0001) == "0.0001"
    check rustFloat(0.00001) == "1e-5"
    check rustFloat(1.5e-7) == "1.5e-7"
    check rustFloat(5e-324) == "5e-324"
    check rustFloat(123.456) == "123.456"
    check rustFloat(Inf) == "inf"
