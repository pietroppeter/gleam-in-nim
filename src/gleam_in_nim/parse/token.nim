## port-of: compiler-core/src/parse/token.rs
## port-status: conformant
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/parse/token.rs.

## The tokens of Gleam.
##
## Naming: upstream `Token::LeftParen` is `tkLeftParen` here, and so on. The
## order of `TokenKind` is the order of the upstream enum.

import std/options
import pkg/bigints

export bigints

type
  TokenKind* = enum
    tkName
    tkUpName
    tkDiscardName
    tkInt
    tkFloat
    tkString
    tkCommentDoc
    # Groupings
    tkLeftParen ## (
    tkRightParen ## )
    tkLeftSquare ## [
    tkRightSquare ## ]
    tkLeftBrace ## {
    tkRightBrace ## }
    # Int Operators
    tkPlus
    tkMinus
    tkStar
    tkSlash
    tkLess
    tkGreater
    tkLessEqual
    tkGreaterEqual
    tkPercent
    # Float Operators
    tkPlusDot ## +.
    tkMinusDot ## -.
    tkStarDot ## *.
    tkSlashDot ## /.
    tkLessDot ## <.
    tkGreaterDot ## >.
    tkLessEqualDot ## <=.
    tkGreaterEqualDot ## >=.
    # String Operators
    tkConcatenate ## <>
    # Other Punctuation
    tkColon
    tkComma
    tkHash ## #
    tkBang ## !
    tkEqual
    tkEqualEqual ## ==
    tkNotEqual ## !=
    tkVbar ## |
    tkVbarVbar ## ||
    tkAmperAmper ## &&
    tkLtLt ## <<
    tkGtGt ## >>
    tkPipe ## |>
    tkDot ## .
    tkRArrow ## ->
    tkLArrow ## <-
    tkDotDot ## ..
    tkAt ## @
    tkEndOfFile
    # Extra
    tkCommentNormal
    tkCommentModule
    tkNewLine
    # Keywords (alphabetically):
    tkAs
    tkAssert
    tkAuto
    tkCase
    tkConst
    tkDelegate
    tkDerive
    tkEcho
    tkElse
    tkFn
    tkIf
    tkImplement
    tkImport
    tkLet
    tkMacro
    tkOpaque
    tkPanic
    tkPub
    tkTest
    tkTodo
    tkType
    tkUse

  Token* = object
    case kind*: TokenKind
    of tkName, tkUpName, tkDiscardName:
      name*: string
    of tkInt:
      intText*: string ## upstream `value`: the literal as written
      intValue*: BigInt
    of tkFloat:
      floatText*: string ## upstream `value`: the literal as written
      floatValue*: float ## never NaN (upstream `LiteralFloatValue`)
    of tkString:
      value*: string ## the raw contents: escapes are not interpreted here
    of tkCommentDoc:
      content*: string
    else:
      discard

const
  firstKeyword* = tkAs
  lastKeyword* = tkUse

func tok*(kind: TokenKind): Token =
  ## A token that carries no data.
  result = Token(kind: kind)

func `==`*(a, b: Token): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of tkName, tkUpName, tkDiscardName:
    a.name == b.name
  of tkInt:
    a.intText == b.intText and a.intValue == b.intValue
  of tkFloat:
    a.floatText == b.floatText and a.floatValue == b.floatValue
  of tkString:
    a.value == b.value
  of tkCommentDoc:
    a.content == b.content
  else:
    true

func guardPrecedence*(token: Token): Option[uint8] =
  case token.kind
  of tkVbarVbar:
    some(1'u8)
  of tkAmperAmper:
    some(2'u8)
  of tkEqualEqual, tkNotEqual:
    some(3'u8)
  of tkLess, tkLessEqual, tkLessDot, tkLessEqualDot, tkGreaterEqual, tkGreater,
      tkGreaterEqualDot, tkGreaterDot:
    some(4'u8)
  of tkConcatenate:
    some(5'u8)
  of tkPlus, tkPlusDot, tkMinus, tkMinusDot:
    some(6'u8)
  of tkStar, tkStarDot, tkSlash, tkSlashDot, tkPercent:
    some(7'u8)
  else:
    none(uint8)

func isReservedWord*(token: Token): bool =
  token.kind in firstKeyword .. lastKeyword

func text(token: Token): string =
  case token.kind
  of tkName, tkUpName, tkDiscardName: token.name
  of tkInt: token.intText
  of tkFloat: token.floatText
  of tkString: token.value
  of tkAmperAmper: "&&"
  of tkAs: "as"
  of tkAssert: "assert"
  of tkAt: "@"
  of tkAuto: "auto"
  of tkBang: "!"
  of tkCase: "case"
  of tkColon: ":"
  of tkComma: ","
  of tkCommentDoc: "///"
  of tkCommentModule: "////"
  of tkCommentNormal: "//"
  of tkConst: "const"
  of tkDelegate: "delegate"
  of tkDerive: "derive"
  of tkDot: "."
  of tkDotDot: ".."
  of tkEcho: "echo"
  of tkElse: "else"
  of tkNewLine: "NEWLINE"
  of tkEndOfFile: "EOF"
  of tkEqual: "="
  of tkEqualEqual: "=="
  of tkFn: "fn"
  of tkGreater: ">"
  of tkGreaterDot: ">."
  of tkGreaterEqual: ">="
  of tkGreaterEqualDot: ">=."
  of tkGtGt: ">>"
  of tkHash: "#"
  of tkIf: "if"
  of tkImplement: "implement"
  of tkImport: "import"
  of tkLArrow: "<-"
  of tkLeftBrace: "{"
  of tkLeftParen: "("
  of tkLeftSquare: "["
  of tkLess: "<"
  of tkLessDot: "<."
  of tkLessEqual: "<="
  of tkLessEqualDot: "<=."
  of tkLet: "let"
  of tkConcatenate: "<>"
  of tkLtLt: "<<"
  of tkMacro: "macro"
  of tkMinus: "-"
  of tkMinusDot: "-."
  of tkNotEqual: "!="
  of tkOpaque: "opaque"
  of tkPanic: "panic"
  of tkPercent: "%"
  of tkPipe: "|>"
  of tkPlus: "+"
  of tkPlusDot: "+."
  of tkPub: "pub"
  of tkRArrow: "->"
  of tkRightBrace: "}"
  of tkRightParen: ")"
  of tkRightSquare: "]"
  of tkSlash: "/"
  of tkSlashDot: "/."
  of tkStar: "*"
  of tkStarDot: "*."
  of tkTest: "test"
  of tkTodo: "todo"
  of tkType: "type"
  of tkUse: "use"
  of tkVbar: "|"
  of tkVbarVbar: "||"

func `$`*(token: Token): string =
  ## How the token is shown in error messages (upstream `Display`).
  "`" & token.text & "`"
