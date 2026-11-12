# Package

version       = "0.0.1"
author        = "Pietro Peterlongo"
description   = "The Gleam compiler, ported to Nim one explained step at a time"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.0"
# The compiler needs only the standard library. The pages (docs/) use nimib and tabelline,
# pinned by commit in deps.lock and cloned by `sh tools/setup.sh`.
