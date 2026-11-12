## What the Nim parser makes of a source, in the format of the parser oracle
## (tests/differential/parse): the two outputs are compared byte for byte.
##
## Usage: parsedump MODE FILE
##
## MODE is `module`, `statements` or `const`. Each line of FILE is one source,
## escaped as in lexdump.nim. For each source it prints `== N`, then `ok` or
## `error`, then the tree or the error the way Rust's `{:#?}` prints them. For
## a module, the warnings of the parser follow, after a line `-- warnings`.

import std/[os, unicode]
import gleam_in_nim/[parse, rust_debug]
import ./lexdump

proc dumpResult[T](r: ParseResult[T]): string =
  if r.isOk:
    "ok\n" & debugRepr(r.value) & "\n"
  else:
    "error\n" & debugRepr(r.error) & "\n"

proc main() =
  let args = commandLineParams()
  if args.len != 2:
    quit "usage: parsedump module|statements|const FILE"
  var index = 0
  var output = ""
  for line in lines(args[1]):
    inc index
    output.add "== " & $index & "\n"
    let source = unescapeBytes(line)
    if validateUtf8(source) != -1:
      output.add "not utf8\n"
      continue
    case args[0]
    of "module":
      var warnings: ParserWarnings
      output.add dumpResult(parseModule(source, warnings))
      output.add "-- warnings\n"
      for warning in warnings.deprecatedSyntax:
        output.add debugRepr(warning) & "\n"
      for location in warnings.detachedDocComments:
        output.add "DetachedDocComment " & debugRepr(location) & "\n"
    of "statements":
      output.add dumpResult(parseStatementSequence(source))
    of "const":
      output.add dumpResult(parseConstValue(source))
    else:
      quit "unknown mode: " & args[0]
    if output.len > 1 shl 20:
      stdout.write output
      output.setLen 0
  stdout.write output

main()
