# Package

version       = "0.0.1"
author        = "Pietro Peterlongo"
description   = "The Gleam compiler, ported to Nim one explained step at a time"
license       = "Apache-2.0"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.0"
requires "https://github.com/nim-lang/bigints#64288c8ff9d91523e6ac9746900efb12ca87f6f7"
# The compiler needs the standard library and bigints. The pages (docs/) use nimib and tabelline,
# pinned by commit in deps.lock and cloned by `sh tools/setup.sh`.
