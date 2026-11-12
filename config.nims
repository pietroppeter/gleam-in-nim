# The compiler in src/; the docs' dependencies are on the path from nim.cfg.
import std/os
switch("path", thisDir() / "src")
switch("hints", "off")
