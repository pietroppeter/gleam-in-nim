## Runs every test: `nim r tests/all.nim`. A new test file adds its import here, one per line,
## sorted, so two branches adding tests rarely conflict.
{.warning[UnusedImport]: off.}
import test_ast
import test_diagnostic
import test_erlang_generation
import test_erlang_term_format
import test_graphemes
import test_lexer
import test_lexer_golden
import test_parse_extra
import test_pretty
import test_src_span
import test_tools
