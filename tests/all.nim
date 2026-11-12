## Runs every test: `nim r tests/all.nim`. A new test file adds its import here, one per line,
## sorted, so two branches adding tests rarely conflict.
{.warning[UnusedImport]: off.}
import test_graphemes
import test_pretty
