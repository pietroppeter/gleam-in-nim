## Runs every test: `nim r tests/all.nim`. A new test file adds its import here, one per line,
## sorted.
{.warning[UnusedImport]: off.}
import test_lexer
import test_lexer_golden
import test_tools
