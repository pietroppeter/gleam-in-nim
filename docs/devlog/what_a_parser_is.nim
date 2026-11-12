## devlog: 12 Nov 2026 P | What a parser is | From a list of words to a tree: grammars, a procedure per rule, and two small stacks that know multiplication comes first. The second stage, built from nothing, then found in Gleam, Nim and Nimony.
## kind: research
import std/[strformat, strutils]
import nimib
import ../blocks, ../site
import data/barlume/[series, lexer, ast, parser]

nbInit
nb.usePost()

const
  gleamAt = "https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/"
  nimAt = "https://github.com/nim-lang/Nim/blob/v2.2.4/"
  nimonyAt = "https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/"

let
  shapes = readFile(docsDir / "devlog" / "data" / "barlume" / "shapes.gleam")
  parserLines = barlumeLines("parser.nim")

# The size of Gleam's parser, from the coverage map.
var gleamParserLines = 0
for stage in loadCoverage().stages:
  for module in stage.modules:
    if module.module == "compiler-core/parse": gleamParserLines = module.rustCode
doAssert gleamParserLines > 0

nbText: &"""
## The short version

- The lexer gave us a flat list of words. A program is not flat: a function contains a block,
  the block contains a `case`, the `case` contains expressions. The **parser** finds that
  nesting and builds it as a **tree**. Every later stage works on the tree.
- What can be inside what is written down as a **grammar**: a handful of rules, each saying
  what one thing is made of. Rules mention each other, and themselves. That is where nesting
  comes from.
- The most common way to write a parser by hand is **recursive descent**: one procedure per
  rule, and procedures call each other the way rules mention each other. If you can read the
  grammar, you can read the parser.
- The one part that does not fall out of the grammar is **operators**: `1 + 2 * 3` must become
  `1 + (2 * 3)`. Two small stacks solve it, and they are the same two stacks Gleam uses.
- Barlume's parser is {parserLines} lines of Nim and runs below. Gleam's is
  {gleamParserLines.thousands} lines of Rust in one file, written by hand in the same style.
  Nim's is written by hand too. Nimony's newest one is **generated** from a grammar, and
  what it writes out is not a tree in memory but text full of brackets.

This is part two of a series. Each part builds one stage of a compiler for Barlume, a toy
language that is a small piece of Gleam, and then looks at the real thing.
"""

nbText: seriesTable("what-a-parser-is")

nbText: """
## Where we left off

[The lexer](../what-a-lexer-is/) turned a row of characters into tokens: a kind and a place
each. It ended with an experiment: the lexer accepts `) ) ( let let = = fn` without a word,
because every token in it is well spelled. It cannot do better. It has a cursor and no memory,
and to match brackets you must remember the ones you opened.

So the parser has two jobs. **Refuse** the sequences of tokens that are not programs, and for
the ones that are, **say what their structure is**.

## Why a tree

Take the smallest interesting program:
"""

nbCode:
  echo parseExpression("1 + 2 * 3").sexp

nbText: """
That line is the output of the parser we are about to build, and it is a tree written on one
line. Read it like this: an opening bracket starts a node, the first word says what the node
is, and the rest are its children, which may be nodes themselves. So this is a `+` node with
two children: the number `1`, and a `*` node whose children are `2` and `3`.

The tree says something the tokens did not: the multiplication is *inside* the addition. To
compute the sum you must first have the product. There is no other information about order in
a program. "This happens before that" and "this belongs to that" are both written the same
way: by being deeper in the tree.

This is called a **syntax tree**. The full name is *abstract* syntax tree, AST, and abstract
means that it keeps what matters and drops the rest: there are no brackets, commas or `let`
keywords in it. They did their job, which was to tell the parser where things start and end.

The bracket notation has a name too, **S-expressions**, and it is as old as Lisp. Keep it in
mind: it comes back at the end of the post, in Nimony, as a file format.

## A grammar

How do we say which sequences of tokens are programs? With rules. Here is all of Barlume:

```
module      = definition*
definition  = "pub"? function | type
function    = "fn" Name "(" names? ")" block
type        = "type" UpName "{" constructor+ "}"
constructor = UpName ( "(" UpName ("," UpName)* ")" )?

block       = "{" statement+ "}"
statement   = "let" Name "=" expression
            | expression

expression  = unit (operator unit)*
unit        = Int | String | Name | UpName
            | block
            | case
            | unit "(" arguments? ")"
case        = "case" expression "{" clause+ "}"
clause      = pattern "->" expression
pattern     = Int | String | Name
            | UpName ( "(" pattern ("," pattern)* ")" )?
```

A rule has a name on the left and, on the right, what that thing is made of. Things in quotes
and capitalised words are tokens, straight from the lexer. Lower case words are other rules.
`?` means maybe, `*` means any number of times, `+` means at least once, `|` means or.

Read `block`: an opening brace, one or more statements, a closing brace. Read `statement`: a
`let`, or just an expression. Now follow the words: a `block` contains `statement`s, a
statement contains an `expression`, an expression contains `unit`s, and a `unit` can be a
`block`. **The rules go in a circle.** That circle is the nesting. A block inside a block
inside a `case` inside a block is those few rules, used again and again.

That is exactly what the lexer could not express. Its rules never mentioned themselves.

## One procedure per rule

Now the nice surprise: the grammar is almost the program. Take each rule and write a procedure
that reads tokens the way the rule says. Where the rule mentions another rule, call that
rule's procedure. This is **recursive descent**: *descent* because you start at `module` and
go down, *recursive* because the procedures call each other in the same circle as the rules.

First, the tools. The parser holds the tokens and a position, and has three small helpers:
"""

nbText: barlume("parser.nim", "parser")

nbText: """
`peek` looks at the next token without taking it. `advance` takes it. `expect` takes it only
if it is the right kind, and otherwise stops with an error that says what was expected, what
was found, and where. It is the lexer's cursor again, one level up: the lexer walked over
characters, the parser walks over tokens.

Now two rules and their procedures. Here are `statement` and `block` once more:

```
block       = "{" statement+ "}"
statement   = "let" Name "=" expression
            | expression
```
"""

nbText: barlume("parser.nim", "block")

nbText: """
Compare them line by line. `"{"` became `expect(tkLeftBrace)`. `statement+` became "parse one,
then keep parsing them until you see the closing brace". The `|` in `statement` became an
`if`: **peek at the next token and decide**. If it is `let`, this is the first alternative.
The whole method stands on that: at every fork, one token of lookahead is enough to know which
way to go. A grammar with that property has a name, LL(1), and most programming languages are
designed to be close to it, because it makes them easy to parse for programs and for people.

And here is the answer to the question from the lexer post, where the memory comes from.
When `parseBlock` calls `parseStatement`, which calls `parseExpr`, which meets a `{` and
calls `parseBlock` again, the first `parseBlock` is still there, waiting, and it remembers
that it owes a closing brace. The memory is the **call stack**. Each procedure that has
started and not finished is one thing still open.

## What the procedures build

Each procedure returns a piece of tree. These are the types for expressions:
"""

nbText: barlume("ast.nim", "expr")

nbText: """
An `Expr` is **one of several kinds**, and each kind has its own fields: a number has a
text, a binary operation has an operator and two sides, a call has what is called and its
arguments. The fields of a node are themselves `Expr`s: that is the tree. In Nim this is an
object variant, in Rust and in Gleam itself it would be an enum or a custom type. A compiler
is mostly a program that takes such a type apart with `case`, which is why languages with
custom types and `case` are pleasant to write compilers in.

Every node also keeps a span, `start` and `stop`: the positions the lexer measured, merged.
A node starts where its first token starts and stops where its last one stops.

## The hard part: operators

One rule in the grammar hides a problem:

```
expression  = unit (operator unit)*
```

It says an expression is units with operators between them, and that is all it says. For
`1 + 2 * 3` it gives a flat row: `1`, `+`, `2`, `*`, `3`. It does not say which operator gets
which numbers. We know the answer from school, multiplication first, and the name for that
knowledge is **precedence**: every operator has a number that says how tightly it holds what
is around it.
"""

nbText: barlume("parser.nim", "precedence")

nbText: """
There are many ways to turn those numbers into a tree. Barlume uses the one Gleam uses, with
two stacks: one for values that are waiting, one for operators that are waiting.
"""

nbText: barlume("parser.nim", "expr")

nbText: """
The rule is short. Read a value, push it. Read an operator, and before pushing it, look at
the operator on top of the stack: if that one **holds at least as tightly**, it goes first.
"Goes first" is `reduce`: take the top operator and the top two values, make a node out of
them, and push the node back as a value. At the end, reduce whatever is left.

It is easier to watch than to read. Here is the same loop on plain words, printing its two
stacks after every token:
"""

nbCode:
  func hold(operator: string): int =
    case operator
    of "==": 3
    of "+", "-": 7
    of "*", "/": 8
    else: 0

  proc watch(source: string) =
    var units, operators: seq[string]
    proc reduce() =
      let right = units.pop
      let left = units.pop
      units.add "(" & operators.pop & " " & left & " " & right & ")"
    proc show(read: string) =
      echo alignLeft(read, 4), alignLeft(units.join("  "), 24), operators.join(" ")
    for token in lex(source)[0 ..^ 2]:
      let word = source.text(token)
      if hold(word) == 0: units.add word
      else:
        while operators.len > 0 and hold(operators[^1]) >= hold(word): reduce()
        operators.add word
      show word
    while operators.len > 0: reduce()
    show "end"

  watch "1 + 2 * 3"

nbText: """
The first column is the token just read, then the waiting values, then the waiting operators.
When `*` arrives, `+` is on the stack and holds less tightly, so `+` keeps waiting and `*`
goes on top. At the end the stacks unwind from the top: `*` takes `2` and `3`, then `+` takes
`1` and the product.

Now the other order:
"""

nbCode:
  watch "1 * 2 + 3"

nbText: """
When `+` arrives, `*` is on the stack and holds more tightly, so it is reduced at once: `1`
and `2` are already a node before `3` is even read.

One more detail is hidden in "at least as tightly". With two operators of the same strength,
the one already waiting goes first, so `8 - 2 - 1` is `(8 - 2) - 1`, which is five, and not
`8 - (2 - 1)`, which is seven. This is **associativity**, and Barlume's operators, like
Gleam's, all associate to the left:
"""

nbCode:
  echo parseExpression("8 - 2 - 1").sexp
  echo parseExpression("1 + 2 * 3 == 3 * 2 + 1").sexp

nbText: """
## The whole program

The other procedures have nothing new in them. `parseUnit` peeks at one token to decide what
kind of value starts here, then checks whether a `(` follows, because anything followed by
brackets is a call. `parseCase`, `parsePattern`, `parseFunction` and `parseType` are their
rules, read aloud. They are folded here, and in the source of this page.
"""

nbFold "The rest of the parser: units, case, patterns, definitions":
  nbText: barlume("parser.nim", "unit")
  nbText: barlume("parser.nim", "case")
  nbText: barlume("parser.nim", "pattern")
  nbText: barlume("parser.nim", "definitions")
  nbText: barlume("ast.nim", "pattern")
  nbText: barlume("ast.nim", "module")

nbText: """
Here is the program from the first post again, and its tree:
"""

nbText: "```gleam\n" & shapes & "```"

nbCode:
  echo parse(shapes).sexp

nbText: """
Compare the two. Everything that was punctuation is gone, the comment is gone, and what is
left is who contains whom. `Circle(2)` is a call like any other: the parser does not know yet
that `Circle` builds a shape and `area` is a function. To the parser, both are names.

## Saying no

The parser is the second stage that can refuse a program, and the first that can refuse one
whose words are all fine. Here is the nonsense the lexer accepted:
"""

nbCode:
  proc tryParse(source: string) =
    try:
      discard parse(source)
      echo source, "\n  fine"
    except ParseError as error:
      echo source, "\n", repeat(' ', error.at), "^ ", error.msg

  tryParse ") ) ( let let = = fn"
  tryParse "fn area(shape {"
  tryParse "fn double(x) { x * }"
  tryParse "fn empty() { }"

nbText: """
Every message comes from the same place: a procedure that expected one kind of token and
peeked at another. That is another reason hand-written parsers are popular. The error
messages are right there in the code, at the exact point where the parser knows what it
was in the middle of.

Barlume's parser stops at the first error. That is the simple choice. A parser for an editor
wants to carry on, so that one missing bracket does not hide every other mistake in the file,
and doing that well is a craft of its own, called error recovery.

## What a parser cannot know

Same experiment as last time. Programs that are well formed and wrong:
"""

nbCode:
  tryParse "fn f() { total + 1 }"
  tryParse "fn f() { 1 + \"one\" }"
  tryParse "fn f(x) { x(x)(x) }"
  tryParse "type T { A B } fn f(t) { case t { A -> 1 } }"

nbText: """
All fine, says the parser, and from where it stands they are. Each is a correct sentence.
`total` was never defined, a number is added to a string, `x` is called with itself, and the
`case` forgets `B`. To notice any of that you have to know what the words *mean*: which
definition a name refers to, what type a value has, which constructors a type has. Grammar
does not reach that far. Those are the next three posts.

## Words you will meet

| Word | What it means |
|---|---|
| grammar | the rules that say which sequences of tokens are programs |
| rule, production | one line of a grammar: a name and what it is made of |
| terminal | a token; something the grammar does not take apart |
| non-terminal | the name of a rule |
| syntax tree, AST | the tree the parser builds: structure without punctuation |
| parse tree, CST | a tree that keeps everything, punctuation included; formatters like those |
| S-expression | a tree written with brackets: `(+ 1 (* 2 3))` |
| recursive descent | a parser with one procedure per rule |
| LL(1) | a grammar where one token of lookahead always tells which rule applies |
| precedence | how tightly an operator holds: `*` before `+` |
| associativity | which side goes first among equals: `8 - 2 - 1` |
| error recovery | carrying on after a syntax error to find the next ones |

## The choices every parser makes

| | Barlume | Gleam | Nim | Nimony (`nifler2`) |
|---|---|---|---|---|
| Written | by hand | by hand | by hand | generated from a grammar |
| Style | recursive descent | recursive descent | recursive descent | recursive descent |
| Operators | two stacks | two stacks | precedence climbing | precedence climbing, built in |
| The grammar is | in this post | in the code | in comments | the source of the parser |
| Blocks end with | `}` | `}` | indentation | indentation |
| It produces | a tree | a tree and a side table | a tree | text with brackets |
| After an error | stops | stops | reports it | stops |

Precedence climbing is the other popular way to do operators: the same numbers, with the
waiting done by the call stack instead of two explicit stacks.
"""

nbNote &"""
Gleam's parser is one file,
[`compiler-core/src/parse.rs`]({gleamAt}compiler-core/src/parse.rs), and it opens with a
comment that could have been the outline of this post.

- **It is recursive descent, by hand.** The comment defines its own words: an *expression
  unit* is "essentially a thing that goes between operators", and an *expression* is "one or
  more expression units separated by an operator". Barlume's `unit` is named after it.
- **Procedures are named for how they fail.** `parse_x` returns nothing if `x` is not there,
  `expect_x` makes it an error, `maybe_x` takes a token only if it is the right one. Our
  `peek`, `expect` and "peek then advance" are those three.
- **Operators use two stacks.** The comment names the algorithm, the simple precedence
  parser, and explains it: one stack "to hold expressions", one "to hold un-reduced
  operators". The same machine parses expressions, the guards of `case` clauses and
  constants. Barlume's precedence numbers are Gleam's.
- **Two tokens of lookahead**, `token0` and `token1`, like the lexer's two characters.
- **Comments go to a side table.** The lexer hands comments over as tokens. The parser puts
  their positions in a structure called `ModuleExtra` and keeps them out of the tree. The
  formatter gets both, and weaves the comments back in by position.
- **It returns one error.** A syntax error ends the parse. The stage that carries on after
  errors in Gleam is the type checker, not the parser.

The port of the parser is under way in another thread: see the [roadmap](../../roadmap/). The
tree it builds, the untyped AST, is a port step of its own, because the tree is the largest
thing in the front end.
""", nkGleam, "How Gleam does it"

nbText: &"""
## Aside: Nim, where the grammar lives in comments

Nim's parser, [`compiler/parser.nim`]({nimAt}compiler/parser.nim), is recursive descent
written by hand as well. Two things about it are worth knowing.

**The grammar is in the comments.** Above each procedure there are lines that start with
`#|` and hold the rule that the procedure implements:

```nim
#| module = complexOrSimpleStmt ^* (';' / IND{{=}})
```

A small program collects those lines into `doc/grammar.txt`, which is the grammar in Nim's
manual. It is the same idea as this post, one procedure per rule, with the rule written next
to it. The weak point is that nothing checks that a comment and its procedure agree.

**Blocks end by indentation.** Look at `IND{{=}}` in that rule: it means "a token at the same
indentation as the block". The lexer post showed that every Nim token carries an `indent`
field. Here is its other half: the parser keeps the indentation of the block it is in, in a
field called `currInd`, and a block is "statements, for as long as the next token's `indent`
equals `currInd`". A deeper token opens a new block, a shallower one ends this one. Barlume
asks "is the next token a `}}`?", Nim asks "is the next token further left?". Everything
else is the same.

## Aside: Nimony, a parser that is generated and writes brackets

The lexer post introduced Nimony's two front ends: `nifler`, which borrows the Nim 2 parser,
and [`nifler2`]({nimonyAt}src/nifler2), which replaces it. The design note for `nifler2`,
[`parser_generator.md`]({nimonyAt}doc/internals/parser_generator.md), lists what was wrong
with borrowing, and one item is the weak point we just met: "the grammar is not written down
anywhere that is checked".

So in `nifler2` the grammar is the program. The file
[`nimgrammar.nim`]({nimonyAt}src/nifler2/nimgrammar.nim) is a list of rules, each a name and
a string, and a compiler plugin turns them into a recursive descent parser at compile time.
This is from the small test grammar that sits beside it:

```nim
grammar:
  stmt "if[ 'if' expr({{-1}}) ':' body ]"
  stmt "while[ 'while' expr({{-1}}) ':' body ]"
  body "indented( stmt ^+ (';' | IND{{=}}) )"
  expr(limit: int) "binary(primary, getPrecedence, isRightAssoc, infix)"
```

You can read it now. `stmt` appears twice: repeating a name adds an alternative, the `|` of
our notation. Quoted words are tokens. `if[ ... ]` means "and wrap what you matched in a node
called `if`", so the grammar says what tree to build as well as what to accept. `binary(...)`
is operator precedence, built into the generator. And the generator checks that one token
of lookahead is always enough to choose between alternatives, the LL(1) property. Where it
is not, the grammar must declare how to decide, or it does not compile. The design note states the goal in one line: "keep every degree of freedom a
hand-written recursive-descent parser has, and pay for it by declaring each one."

The second idea is what the parser produces. Not a tree in memory: **text**. Nimony's stages
are separate programs that pass each other files in a format called
[NIF](https://github.com/nim-lang/nifspec/blob/master/doc/nif-spec.md), and NIF is
S-expressions. The specification's own example: the call `f(a, b, c)` "becomes
`(call f a b c)` in NIF". That is, give or take the details, what Barlume's tree printer
wrote a few sections ago.

Nimony goes one step further than printing. Its design document says "the typical compiler
pass works on streams of NIF tokens, no tree constructions are required". The later stages
never build the tree as linked objects. They read the bracketed text from left to right and
write new bracketed text. The tree is still there, in the brackets. A tree and a well
bracketed row of tokens are the same information, and a compiler can pick either.
"""

nbNote """
As in the first post: the Nim and Nimony sources were read at the commits in the links
(Nim 2.2.4, and Nimony on 12 November 2026), and nothing of Nimony was built or run. `nifler2`
is days old and moving.
""", nkWarning, "Read, not run"

nbText: """
## What this changes for the port

- **The parser port has a map.** Gleam's file is long, and its shape is the one in this post:
  helpers, one procedure per rule, a two-stack machine for operators. A reader who followed
  Barlume's parser can open the Rust, or the Nim port when it lands, and recognise each part.
- **Why the tree is a step of its own.** The parser is procedures, and the tree is the data
  they return. Every later stage is written against that data, so its types have to exist,
  and be right, before the parser or the type checker can be ported.
- **Why the port compares trees as text.** A tree printed with brackets is a string, and
  strings are easy to compare. The parser port is set up to check itself by printing its
  tree in the format the Rust compiler prints its own, and comparing the two. Nimony's NIF is that idea
  taken all the way.
- **Barlume now has two stages.** `ast.nim` and `parser.nim` joined `lexer.nim` in
  `docs/devlog/data/barlume/`. The next parts read the tree they produce.

Next: names. `total` was never defined, and the parser did not mind. Something has to.

## Sources

- Gleam's parser at the pinned commit:
  [`parse.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/parse.rs)
  (the header comment, the `Parser` struct, `parse_expression_inner`, `handle_operator`,
  `precedence`), and the precedence numbers in
  [`ast.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/ast.rs)
  (`BinOp::precedence`).
- The algorithm Gleam's comment names:
  [Simple precedence parser](https://en.wikipedia.org/wiki/Simple_precedence_parser) on
  Wikipedia. The page could not be opened from the sandbox this was written in; what is said
  here comes from Gleam's comment and code.
- Nim 2.2.4: [`compiler/parser.nim`](https://github.com/nim-lang/Nim/blob/v2.2.4/compiler/parser.nim)
  (the `#|` comments, `withInd`, `currInd`, `parseOperators`).
- Nimony at commit `4ba90a7`:
  [`doc/internals/parser_generator.md`](https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/doc/internals/parser_generator.md),
  [`src/nifler2/nimgrammar.nim`](https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/src/nifler2/nimgrammar.nim),
  [`src/nifler2/tests/mini.nim`](https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/src/nifler2/tests/mini.nim)
  (the small grammar quoted above),
  [`doc/design.md`](https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/doc/design.md).
- The [NIF specification](https://github.com/nim-lang/nifspec/blob/master/doc/nif-spec.md),
  read on 12 November 2026.
- Robert Nystrom, *Crafting Interpreters*, the chapters
  [Representing Code](https://craftinginterpreters.com/representing-code.html) and
  [Parsing Expressions](https://craftinginterpreters.com/parsing-expressions.html), named
  from memory as the best longer read; the site could not be opened from the sandbox.
- The first part of this series: [What a lexer is](../what-a-lexer-is/).
"""

nbSave
