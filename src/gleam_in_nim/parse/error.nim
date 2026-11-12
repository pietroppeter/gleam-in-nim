## port-part-of: compiler-core/src/parse/error.rs
## (only a part of that file is ported so far: when the rest is, this becomes `port-of` with a `port-status`)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/parse/error.rs.

## Errors of the lexer and of the parser. The types are ported, and the
## messages of the lexical errors. The messages of the parser's errors
## (`ParseErrorType::details`) are not ported yet.
##
## The lexer's types were ported before the rule for enums with data
## (decision 0010), and keep their own shape: `rustDebugHook` below prints
## them for the comparison with the reference parser.

import std/[options, strformat, unicode]
import ../[ast, rust_debug, src_span]
import ../error as core_error
import ./token

type
  InvalidUnicodeEscapeError* = enum
    MissingOpeningBrace ## Expected '{'
    ExpectedHexDigitOrCloseBrace ## Expected hex digit or '}'
    InvalidNumberOfHexDigits ## Expected between 1 and 6 hex digits
    InvalidCodepoint ## Invalid Unicode codepoint

  LexicalErrorKind* = enum
    ## Upstream `LexicalErrorType`.
    BadStringEscape ## String contains an unescaped slash
    InvalidUnicodeEscape ## \u{...} escape sequence is invalid
    DigitOutOfRadix ## 0x012 , 2 is out of radix
    NumTrailingUnderscore ## 1_000_ is not allowed
    RadixIntNoValue ## 0x, 0b, 0o without a value
    MissingExponent ## 1.0e, for example, where there is no exponent
    UnexpectedStringEnd ## Unterminated string literal
    UnrecognizedToken
    InvalidTripleEqual
    MergeConflictIndicator
    UnsupportedProceduralOperator
      ## Operators that commonly exist in procedural language, but do
      ## not exist in Gleam. e.g. `++`, `-=`, `/=`, `%=`, `+=`, `*=`
    VisuallySimilarInvalidCharacter
      ## A character was encountered that visually looks like a correct
      ## character, but in reality it's some other unicode characters.
      ## For example, a non-breaking-space instead of a regular space.

  LexicalErrorType* = object
    case kind*: LexicalErrorKind
    of InvalidUnicodeEscape:
      escape*: InvalidUnicodeEscapeError
    of UnrecognizedToken:
      token*: Rune
    of VisuallySimilarInvalidCharacter:
      name*: string
      correct*: string
    else:
      discard

  LexicalError* = object
    error*: LexicalErrorType
    location*: SrcSpan

type
  IncorrectNamePosition* = enum
    ## Where we found an incorrect name.
    inpAsPattern ## After `as`. For example: `as _wibble`.
    inpModule ## As a module in an import: `import _wibble`
    inpFunction ## As a function name: `fn _wibble()`
    inpAttribute ## As an attribute name: `@_wibble`
    inpConstant ## As a constant name: `const _wibble = ...`
    inpTarget ## As a target name: `@external(_wibble, ...)`
    inpVariable ## Used as a variable expression: `let a = _wibble`, `let a = _wibble(10)`

  ParseErrorTypeKind* = enum
    peExpectedEqual ## expect "="
    peExpectedExpr ## after "->" in a case clause
    peExpectedName ## any token used when a Name was expected
    peExpectedPattern ## after ':' where a pattern is expected
    peExpectedType ## after ':' or '->' where a type annotation is expected
    peExpectedUpName ## any token used when a UpName was expected
    peExpectedValue ## no value after "="
    peExpectedDefinition ## after attributes
    peExpectedDeprecationMessage ## after "deprecated"
    peExpectedExternalArguments ## after "@external"
    peExpectedFunctionDefinition ## after function-only attributes
    peExpectedTargetName ## after "@target("
    peExprLparStart ## it seems "(" was used to start an expression
    peExtraSeparator ## #(1,,) <- the 2nd comma is an extra separator
    peIncorrectName ## UpName or DiscardName used when Name was expected
    peIncorrectUpName ## Name or DiscardName used when UpName was expected
    peInvalidBitArraySegment ## <<7:hello>> `hello` is an invalid BitArray segment
    peInvalidBitArrayUnit ## in <<1:unit(x)>> x must be 1 <= x <= 256
    peInvalidTailPattern ## only name and _name are allowed after ".." in list pattern
    peInvalidTupleAccess ## only positive int literals for tuple access
    peLexError
    peNestedBitArrayPattern ## <<<<1>>, 2>>, <<1>> is not allowed in there
    peNoLetBinding ## Bindings and rebinds always require let and must always bind to a value.
    peNoValueAfterEqual ## = <something other than a value>
    peNotConstType ## :fn(), name, _  are not valid const types
    peOpNakedRight ## Operator with no value to the right
    peOpaqueTypeAlias ## Type aliases cannot be opaque
    peTooManyArgHoles ## a function call can have at most 1 arg hole
    peDuplicateAttribute ## an attribute was used more than once
    peUnknownAttribute ## an attribute was used that is not known
    peUnknownTarget ## an unknown target was used
    peListSpreadWithoutElements ## Pointless spread: `[..xs]`
    peListSpreadFollowedByElements ## trying to append something after the spread: `[..xs, x]`
    peListSpreadWithAnotherSpread ## trying to use multiple spreads: `[..xs, ..ys]`
    peUnexpectedLabel ## argument labels were provided, but are not supported in this context
    peUnexpectedEof
    peUnexpectedReservedWord ## reserved word used when a name was expected
    peUnexpectedToken
    peUnexpectedFunction ## a function was used called outside of another function
    peConcatPatternVariableLeftHandSide
      ## A variable was assigned or discarded on the left hand side of a <> pattern
    peConcatPatternVariableWithSuffix
      ## A variable was assigned as infix between prefix and suffix string
      ## patterns using <>
    peListSpreadWithoutTail ## let x = [1, ..]
    peExpectedFunctionBody ## let x = fn()
    peRedundantInternalAttribute ## for a private definition marked as internal
    peInvalidModuleTypePattern ## for patterns that have a dot like: `name.thing`
    peListPatternSpreadFollowedByElements
      ## When there is a pattern after a spread [..rest, pattern]
    peExpectedRecordConstructor
      ## This happens when someone forgets to write the type constructor around
      ## its fields in a custom type definition. For example:
      ##
      ## ```gleam
      ## pub type Wibble {
      ##   String,
      ##   field: Int,
      ##   field_2: a,
      ## }
      ## ```
    peCallInClauseGuard ## case x { _ if f() -> 1 }
    peIfExpression
    peTypeDefinitionNoArguments ## pub type Wibble() { ... }
    peUnknownAttributeRecordVariant
      ## an attribute was used that is not know for a custom type variant
    peIncorrectImportModuleSeparator
      ## a Python-like import was written, such as `import gleam.io`, instead of `import gleam/io`
    peEmptyGuardBlock
      ## This can happen when there's an empty block in a case clause guard.
      ## For example: `_ if a == {}`
    peConstantInsideFunction ## When the use tries to define a constant inside a function
    peFunctionDefinitionAngleGenerics ## fn something<T>() { ... }
    peTypeUsageAngleGenerics ## let a: List<String> = []
    peTypeDefinitionAngleGenerics ## type Something<T> {
    peMissingConstantAsMessage ## `const x = todo as` with no message after the `as`.
    peRecordUpdateAfterFields

  ParseErrorTypeIncorrectName* = object of StructVariant
    kind*: IncorrectNamePosition ## Where we found the incorrect name.

  ParseErrorTypeLexError* = object of StructVariant
    error*: LexicalError

  ParseErrorTypeListSpreadWithAnotherSpread* = object of StructVariant
    firstSpreadLocation*: SrcSpan

  ParseErrorTypeUnexpectedToken* = object of StructVariant
    token*: Token
    expected*: seq[string]
    hint*: Option[string]

  ParseErrorTypeConcatPatternVariableWithSuffix* = object of StructVariant
    name*: string

  ParseErrorTypeExpectedRecordConstructor* = object of StructVariant
    typeName*: string
    public*: bool
    opaque*: bool
    fields*: seq[RecordConstructorArg[Unit]] ## Those are the fields that have been written.

  ParseErrorTypeIncorrectImportModuleSeparator* = object of StructVariant
    module*: string
    item*: string

  ParseErrorTypeTypeUsageAngleGenerics* = object of StructVariant
    module*: Option[string]
    name*: string
    arguments*: seq[TypeAst]

  ParseErrorTypeTypeDefinitionAngleGenerics* = object of StructVariant
    name*: string
    arguments*: seq[string]

  ParseErrorType* = object
    case kind*: ParseErrorTypeKind
    of peIncorrectName: vIncorrectName*: ParseErrorTypeIncorrectName
    of peLexError: vLexError*: ParseErrorTypeLexError
    of peListSpreadWithAnotherSpread:
      vListSpreadWithAnotherSpread*: ParseErrorTypeListSpreadWithAnotherSpread
    of peUnexpectedToken: vUnexpectedToken*: ParseErrorTypeUnexpectedToken
    of peConcatPatternVariableWithSuffix:
      vConcatPatternVariableWithSuffix*: ParseErrorTypeConcatPatternVariableWithSuffix
    of peExpectedRecordConstructor:
      vExpectedRecordConstructor*: ParseErrorTypeExpectedRecordConstructor
    of peIncorrectImportModuleSeparator:
      vIncorrectImportModuleSeparator*: ParseErrorTypeIncorrectImportModuleSeparator
    of peTypeUsageAngleGenerics: vTypeUsageAngleGenerics*: ParseErrorTypeTypeUsageAngleGenerics
    of peTypeDefinitionAngleGenerics:
      vTypeDefinitionAngleGenerics*: ParseErrorTypeTypeDefinitionAngleGenerics
    else: discard

  ParseError* = object
    error*: ParseErrorType
    location*: SrcSpan

func rustDebugHook*(x: LexicalErrorType, indent: string, into: var string) =
  ## `LexicalErrorType` as Rust's `{:#?}` prints it.
  const step = "    "
  case x.kind
  of InvalidUnicodeEscape:
    into.add "InvalidUnicodeEscape(\n" & indent & step & $x.escape & ",\n" & indent & ")"
  of UnrecognizedToken:
    into.add "UnrecognizedToken {\n" & indent & step & "token: " & rustChar(x.token) & ",\n" &
      indent & "}"
  of VisuallySimilarInvalidCharacter:
    into.add "VisuallySimilarInvalidCharacter {\n" & indent & step & "name: " &
      rustString(x.name) & ",\n" & indent & step & "correct: " & rustString(x.correct) & ",\n" &
      indent & "}"
  else:
    into.add $x.kind

func rustDebugHook*(x: Token, indent: string, into: var string) =
  ## `Token` as Rust's `{:#?}` prints it.
  const step = "    "
  let name = ($x.kind)[2 .. ^1]
  template field(label, value: string) =
    into.add indent & step & label & ": " & value & ",\n"
  case x.kind
  of tkName, tkUpName, tkDiscardName:
    into.add name & " {\n"
    field("name", rustString(x.name))
    into.add indent & "}"
  of tkInt:
    into.add name & " {\n"
    field("value", rustString(x.intText))
    field("int_value", $x.intValue)
    into.add indent & "}"
  of tkFloat:
    into.add name & " {\n"
    field("value", rustString(x.floatText))
    field("float_value", "LiteralFloatValue(\n" & indent & step & step & rustFloat(x.floatValue) &
      ",\n" & indent & step & ")")
    into.add indent & "}"
  of tkString:
    into.add name & " {\n"
    field("value", rustString(x.value))
    into.add indent & "}"
  of tkCommentDoc:
    into.add name & " {\n"
    field("content", rustString(x.content))
    into.add indent & "}"
  else:
    into.add name

func `==`*(a, b: LexicalErrorType): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of InvalidUnicodeEscape:
    a.escape == b.escape
  of UnrecognizedToken:
    a.token == b.token
  of VisuallySimilarInvalidCharacter:
    a.name == b.name and a.correct == b.correct
  else:
    true

func `==`*(a, b: LexicalError): bool =
  a.error == b.error and a.location == b.location

func toParseErrorInfo*(error: LexicalError): tuple[title: string, extra: seq[string]] =
  ## The message shown for a lexical error, and its extra lines.
  let e = error.error
  case e.kind
  of BadStringEscape:
    ("I don't understand this escape code", @[
      "Hint: Add another backslash before it.",
      "See: https://tour.gleam.run/basics/strings",
    ])
  of DigitOutOfRadix:
    ("This digit is too big for the specified radix", @[])
  of NumTrailingUnderscore:
    ("Numbers cannot have a trailing underscore", @["Hint: remove it."])
  of RadixIntNoValue:
    ("This integer has no value", @[])
  of MissingExponent:
    ("This float is missing an exponent",
      @["Hint: Add an exponent or remove the trailing `e`"])
  of UnexpectedStringEnd:
    ("The string starting here was left open", @[])
  of UnrecognizedToken:
    if e.token == Rune(';'):
      ("Remove this semicolon", @[
        "Hint: Semicolons used to be whitespace and did nothing.",
        "You can safely remove them without your program changing.",
      ])
    elif e.token == Rune('\''):
      ("Unexpected single quote", @["Hint: Strings are written with double quotes."])
    else:
      ("I can't figure out what to do with this character", @["Hint: Is it a typo?"])
  of InvalidUnicodeEscape:
    case e.escape
    of MissingOpeningBrace:
      ("Expected '{' in Unicode escape sequence", @["Hint: Add it."])
    of ExpectedHexDigitOrCloseBrace:
      ("Expected hex digit or '}' in Unicode escape sequence", @[
        "Hint: Hex digits are digits from 0 to 9 and letters from a to f or A to F."
      ])
    of InvalidNumberOfHexDigits:
      ("Expected between 1 and 6 hex digits in Unicode escape sequence", @[])
    of InvalidCodepoint:
      ("Invalid Unicode codepoint", @[])
  of InvalidTripleEqual:
    ("Did you mean `==`?", @[
      "Gleam uses `==` to check for equality between two values.",
      "See: https://tour.gleam.run/basics/equality",
    ])
  of MergeConflictIndicator:
    ("Merge conflict marker found", @[
      """Your code appears to have a merge conflict. Resolve it by removing
the code you do not want to keep.

If you are in a merge, the top chunk is the checked-out code, and the
bottom chunk is the new code being merged.

If you are in a rebase, the top chunk is the code being rebased onto,
and the chunk section is the checked-out code which is being rebased.

More information can be found in the official git documentation:
https://git-scm.com/book/en/v2/Git-Tools-Advanced-Merging#_checking_out_conflicts"""
    ])
  of UnsupportedProceduralOperator:
    ("Unknown operator", @[
      """Gleam is an immutable language and does not have any operators that
change the value of an existing variable. You might want to create a
new variable with the same name as the previous one:

    let wibble = 10
    let blobby = wibble
    let wibble = wibble + 20
    assert wibble == 30
    assert blobby == 10
"""
    ])
  of VisuallySimilarInvalidCharacter:
    ("Unexpected character", @[
      wrap(&"This looks like ascii {e.correct}, but it is actually the unicode {e.name}.")
    ])
