## What the tools share: where the reference checkout is, and how they talk.
##
## The tools are written to be read by a coding agent with a small context window: a few lines
## on stdout, one line per problem starting with `ERROR` (so `grep ERROR` finds everything), the
## detail in a file under `build/`, and a last line that says what happened.
import std/[os, strutils]

const
  repoDir* = currentSourcePath().parentDir.parentDir   ## the root of gleam-in-nim
  defaultRef* = repoDir / "reference" / "gleam"        ## the pinned checkout of gleam-lang/gleam
  dataDir* = repoDir / "docs" / "data"

proc refDirFrom*(arg: string): string =
  ## The reference checkout: `--ref:PATH`, or $GLEAM_REF, or reference/gleam.
  result = if arg.len > 0: arg else: getEnv("GLEAM_REF", defaultRef)
  if not dirExists(result / "compiler-core"):
    quit "ERROR no reference checkout at " & result &
      " (pass --ref:PATH, set GLEAM_REF, or run the fetch script in reference/)", 2

proc pinOf*(refDir: string): string =
  ## The version of the reference checkout, read from compiler-core/Cargo.toml.
  for line in lines(refDir / "compiler-core" / "Cargo.toml"):
    if line.startsWith("version"):
      return line.split('"')[1]

proc unixPath*(path: string): string = path.replace('\\', '/')
