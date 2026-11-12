## Builds every page in one program: `nim r docs/all.nim`.
## A page is a nimib notebook in docs/ or docs/devlog/; each renders when its module is
## initialised, in import order. A new page or post adds its name here (posts: one per line,
## sorted, so two branches adding a post rarely conflict).
{.warning[UnusedImport]: off.}
import index, roadmap, coverage, agents, decisions, porting
import devlog/index as devlogIndex
import devlog/elm_roots
import devlog/the_beam
import devlog/the_erlang_term_format
import devlog/how_we_work
import devlog/learning_from_rewrites
import devlog/lexer
import devlog/workflow
import devlog/gleam_and_its_people
import devlog/where_gleam_decisions_live
import devlog/a_corpus_of_real_gleam
import devlog/how_gleam_compiles
import devlog/the_port_plan
import devlog/the_pretty_printer
import devlog/the_syntax_tree
import devlog/what_the_reference_says
import devlog/what_a_lexer_is
import devlog/what_a_parser_is
import devlog/erlang_in_ci
import devlog/names_and_scopes
import devlog/what_a_type_checker_is
