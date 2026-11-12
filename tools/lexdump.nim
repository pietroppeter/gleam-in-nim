## Dump the token stream of the Nim lexer, in the same format as the
## reference oracle (reference/lexdump, which links the real Gleam lexer).
##
## Usage:
##   lexdump FILE...          one dump per file, each preceded by `== FILE`
##   lexdump --lines FILE     treat each line of FILE as one escaped source
##                            and dump each preceded by `== LINENUMBER`
##   lexdump --floats FILE    each line is a float literal: print the bits of
##                            its value in hex, or `none`
##   lexdump --ints FILE      each line is an int literal: print its value in
##                            decimal, or `none`
##
## Output, one token per line: `START END KIND [PAYLOAD...]`, tab separated.
## Lexing stops at the first error, printed as `START END !KIND [PAYLOAD...]`
## and followed by its message: the title and each extra line as `| TEXT`.
## Payload bytes outside printable ASCII, and the backslash, are written as
## `\xHH`, so the dump is plain ASCII whatever the source contains.

import std/[strutils, unicode]
import gleam_in_nim/parse/lexer

func escapeBytes*(s: string): string =
  for c in s:
    if ord(c) >= 0x20 and ord(c) < 0x7f and c != '\\':
      result.add c
    else:
      result.add "\\x" & toHex(ord(c), 2)

func unescapeBytes*(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 3 < s.len and s[i + 1] == 'x':
      result.add char(parseHexInt(s[i + 2 .. i + 3]))
      i += 4
    else:
      result.add s[i]
      i += 1

func kindName(kind: TokenKind): string =
  ($kind)[2 .. ^1] # tkLeftParen -> LeftParen, the upstream name

proc dump*(source: string): string =
  ## The dump of one source.
  if validateUtf8(source) != -1:
    # The reference lexer takes a &str: sources that are not UTF-8 never reach it.
    return "!!NotUtf8\n"
  for item in lex(source):
    var fields: seq[string]
    if item.isOk:
      let (start, token, stop) = item.spanned
      fields = @[$start, $stop, kindName(token.kind)]
      case token.kind
      of tkName, tkUpName, tkDiscardName:
        fields.add escapeBytes(token.name)
      of tkInt:
        fields.add escapeBytes(token.intText)
        fields.add $token.intValue
      of tkFloat:
        fields.add escapeBytes(token.floatText)
        fields.add toHex(cast[uint64](token.floatValue), 16)
      of tkString:
        fields.add escapeBytes(token.value)
      of tkCommentDoc:
        fields.add escapeBytes(token.content)
      else:
        discard
    else:
      let error = item.error
      fields = @[$error.location.start, $error.location.stop, "!" & $error.error.kind]
      case error.error.kind
      of InvalidUnicodeEscape:
        fields.add $error.error.escape
      of UnrecognizedToken:
        fields.add escapeBytes($error.error.token)
      of VisuallySimilarInvalidCharacter:
        fields.add escapeBytes(error.error.name)
        fields.add escapeBytes(error.error.correct)
      else:
        discard
    result.add fields.join("\t")
    result.add '\n'
    if not item.isOk:
      let (title, extra) = item.error.toParseErrorInfo
      result.add "| " & escapeBytes(title) & "\n"
      for line in extra:
        result.add "| " & escapeBytes(line) & "\n"

when isMainModule:
  import std/os
  import gleam_in_nim/parse/literals

  let args = commandLineParams()
  var output = ""
  if args.len > 0 and args[0] == "--floats":
    for line in lines(args[1]):
      let value = parseLiteralFloat(line)
      output.add (if value.isSome: toHex(cast[uint64](value.get), 16) else: "none")
      output.add '\n'
  elif args.len > 0 and args[0] == "--ints":
    for line in lines(args[1]):
      let value = parseIntValue(line)
      output.add (if value.isSome: $value.get else: "none")
      output.add '\n'
  elif args.len > 0 and args[0] == "--lines":
    var number = 0
    for line in lines(args[1]):
      inc number
      output.add "== " & $number & "\n"
      output.add dump(unescapeBytes(line))
  else:
    for path in args:
      output.add "== " & path & "\n"
      output.add dump(readFile(path))
  stdout.write output
