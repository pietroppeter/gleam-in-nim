## devlog: 12 Nov 2026 M | What a lexer is | From a row of characters to a list of words: the first stage of a compiler, built from nothing in a page of Nim, then found again in Gleam, in Nim and in Nimony.
## kind: research
import std/[strformat, strutils]
import nimib
import ../blocks, ../site
import data/barlume/[series, lexer]

nbInit
nb.usePost()

const
  gleamAt = "https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/"
  nimAt = "https://github.com/nim-lang/Nim/blob/v2.2.4/"
  nimonyAt = "https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/"

let
  shapes = readFile(docsDir / "devlog" / "data" / "barlume" / "shapes.gleam")
  lexerLines = barlumeLines("lexer.nim")

# The size of Gleam's lexer, from the coverage map.
var gleamLexerLines = 0
for stage in loadCoverage().stages:
  for module in stage.modules:
    if module.module == "compiler-core/parse/lexer": gleamLexerLines = module.rustCode
doAssert gleamLexerLines > 0

nbText: &"""
## The short version

- A compiler never works on your program as you see it. It gets **one long row of characters**,
  and the first thing it does is cut that row into words. The words are called **tokens**, and
  the part that cuts is the **lexer** (also: scanner, tokenizer).
- A token is small: **what kind of word it is, and where it was** in the source. Everything
  after the lexer thinks in tokens and never looks at a character again.
- A lexer is the easy stage, and that is the point of having it. It needs five ideas: skip
  the blanks, one character can be a token, look one character ahead, keep going while it
  fits, and say where it went wrong. This post builds one from nothing in {lexerLines} lines
  of Nim, and it runs as the page is built.
- What a lexer **cannot** do tells you what the next stage is for: it has no idea whether your
  brackets match.
- Gleam's real lexer is the same five ideas plus a great deal of kindness: {gleamLexerLines.thousands}
  lines of Rust, already [ported to Nim](../lexer/). Nim's lexer adds one more idea, for
  indentation. Nimony's newest lexer is half generated from regular expressions, and is checked
  the way we check our port.

## A series, and a small language

This is the first post of a series that explains every stage of a compiler from the ground up,
for someone who has used compilers for years and never opened one. Each post takes one stage,
builds the smallest version of it that works, and then looks at how Gleam does it (that is what
we are porting) and how Nim or Nimony does it (that is where we live).
"""

nbText: seriesTable("what-a-lexer-is")

nbText: """
[How the Gleam compiler is made](../how-gleam-compiles/) is the map of the real thing, with
sizes. This series is the slow walk through the ideas behind that map.

The small version needs a small language. Meet **Barlume**, Italian for a glimmer: the smallest
piece of Gleam that still has every stage worth explaining. It has functions, `let`, whole
numbers, strings, a few operators, custom types and `case`. Here is all of it in one program:
"""

nbText: "```gleam\n" & shapes & "```"

nbNote """
Every Barlume program is a Gleam program. This one was given to the pinned `gleam format`,
which printed it back unchanged, so the real parser accepts it. That was checked by hand with
the reference binary, not when this page was built. What Barlume leaves out is most of Gleam:
floats, lists, tuples, modules and imports, labels, pipes, `use`, bit arrays, type annotations.
""", nkDone, "Checked against the real thing"

nbText: """
By the end of the series Barlume will have a compiler that fits in a few pages. It is a toy
with a job: to make each idea visible before we meet it at full size in Gleam.

## A program is flatter than it looks

When you look at the program above you see structure: a type with two cases, a function, a
block inside a block. None of that is in the file. The file is a row of characters, and the
line breaks you see are characters in the row like any other. This is the first line of the
`main` function's body, as the compiler receives it:
"""

nbCode:
  let line = "let total = area(Circle(2))"
  var row = ""
  for i, c in line:
    row.add &"{i}:{c}  "
  echo row

nbText: &"""
{line.len} characters, each with a position. To you, `total` is one thing. To a program that
has just opened the file, it is a `t` at 4, an `o` at 5, and so on, and nothing says they belong
together, or that `let` is special and `total` is not.

You read prose the same way without noticing: letters become words, then words become sentences.
Nobody parses a sentence letter by letter. Compilers split the work along the same line:

- the **lexer** knows spelling: which runs of characters are words, and of what kind;
- the **parser** (next post) knows grammar: which sequences of words are sentences.

They could be one program, and some compilers do it that way. Almost all split them, because
each half becomes simpler: the lexer never thinks about structure, and the parser never thinks
about spaces, comments or where a number ends.

## What a token is

A token is one word of the program, described by two things:

- its **kind**: a keyword `let`, a name, a number, an opening bracket, an arrow;
- its **place**: where it starts and where it stops in the row of characters.

Here are Barlume's tokens. This is the real source of the lexer we are about to read, shown
from its file:
"""

nbText: barlume("lexer.nim", "token")

nbText: """
A few things to notice, because every lexer makes these choices.

**Kinds are an enumeration**, and there is one per keyword and one per symbol, but only one for
all names and one for all numbers. The parser will ask "is this a `let`?" all the time and
"is this the name `total`?" never: for grammar, all names are alike.

**The token does not store its text.** It stores two positions, and the text is the slice of
the source between them. Those two numbers, usually called a **span**, are the most important
thing a lexer produces. Every later stage carries them along, and when a type error underlines
part of your code three stages later, it is drawing a span that was measured here.

**White space and comments are not tokens.** Barlume drops them. That is the usual choice, and
it is not Gleam's, as we will see.

## Building the lexer

The whole lexer is one loop over the row, with a cursor `i` that only moves forward. At each
turn it looks at the character under the cursor, decides what starts here, makes a token and
jumps over it. Here it is, complete. The numbered comments are the five ideas, explained below.
"""

nbText: barlume("lexer.nim", "lex")

nbText: """
**1. Skip the blanks.** A space, a tab or a line break makes no token: move on. This is where
the difference between `let x` and `letx` is decided, by the way. The space is thrown away, but
only after it has ended the word before it.

**2. One character can be a whole token.** `(` is always `tkLeftParen`. Nothing to decide.

**3. Look ahead.** `=` is a problem: it may be the whole token, or the first half of `==`.
The lexer cannot know by looking at the cursor alone, so it **peeks** at the next character
without moving. The same for `-` and `->`, and for `/`, which starts a comment when another
`/` follows. How many characters a lexer may peek at is called its **lookahead**. Barlume needs
one. The rule that `==` wins over two `=` has a name too: **maximal munch**, always take the
longest token that fits. It is why `letter` is one name and not the keyword `let` followed by
`ter`.

**4. Keep going while it fits.** A number has no fixed length: it lasts as long as there are
digits. So the lexer counts ahead until the character is not a digit, and the token is that
long. Names work the same way. Keywords are not handled here at all: the lexer reads a whole
name first, and only then looks it up in a small table.
"""

nbText: barlume("lexer.nim", "keywords")

nbText: """
That order matters. Reading the word first and asking afterwards is what makes `lettuce` a name.
Almost every lexer treats keywords this way: as names that happen to be reserved.

**5. Say where it went wrong.** Some rows of characters are not made of words. A string that
never closes, a character the language has no use for. The lexer is the first stage that can
refuse a program, and when it does it must say where: the error carries the position of the
cursor.

## Running it

Here is the lexer on the first lines of the program above:
"""

nbCode:
  proc show(source: string) =
    for token in lex(source):
      echo align($token.start, 3), align($token.stop, 4), "  ", alignLeft($token.kind, 14), source.text(token)

  show "type Shape {\n  Circle(Int)\n}"

nbText: """
Read the positions: `type` is characters 0 to 4, then the space at 4 is skipped and `Shape`
starts at 5. The line break and the two spaces before `Circle` left no trace except the jump
from 12 to 15. The last token is always `tkEndOfFile`: it saves the parser from asking "are
there tokens left?" before every step.

And the whole program:
"""

nbCode:
  let tokens = lex(shapes)
  var count: array[TokenKind, int]
  for token in tokens: inc count[token.kind]
  echo shapes.len, " characters, ", tokens.len, " tokens"
  for kind in TokenKind:
    if count[kind] > 0: echo align($count[kind], 4), "  ", kind

nbText: """
The comment in `main` is gone, and so is every blank. What is left is the list of words the
parser will read.

When a row of characters is not made of words, the lexer says so and says where:
"""

nbCode:
  proc tryLex(source: string) =
    try:
      echo source, "\n  fine: ", lex(source).len - 1, " tokens"
    except LexError as error:
      echo source, "\n", repeat(' ', error.at), "^ ", error.msg

  tryLex "let name = 'Lucy'"
  tryLex "let name = \"Lucy"
  tryLex "let price = 3 $"

nbText: """
Those messages are honest and not very helpful. Remember them when we get to Gleam.

## What a lexer cannot know

Now the most useful experiment of the post. Give the lexer nonsense that is made of real words:
"""

nbCode:
  tryLex ") ) ( let let = = fn"
  tryLex "fn area(shape {"

nbText: """
No complaint. Every word is spelled correctly, so the lexer is satisfied. It did not notice the
brackets that never open, the `let` with nothing to define, or the function whose `(` is never
closed. It **cannot** notice: to know that a bracket is not closed you must remember that one
was opened, and how many, and the loop above remembers nothing. It has a cursor and no memory.

That limit has a precise shape, and it is the one piece of theory worth knowing here. What a
machine with a fixed, finite memory can recognise is called a **regular language**: the things
you can describe with a regular expression. An integer is regular: a digit, then more digits.
A name is regular. "Brackets that match, nested as deep as you like" is not, because nesting
needs counting without a limit. So the line between lexer and parser is not a matter of taste.
The lexer takes the part of the language that needs no memory, and the parser takes the part
that needs a stack.

It is also why lexers are fast and simple, and why they can be **generated**: give a tool one
regular expression per kind of token and it builds the loop for you, as a table of states. That
is what `lex` and `flex` have done since the 1970s. Many compilers still write the loop by
hand, as we just did, because a hand-written lexer can give better errors and bend the rules
where a language needs it.

## Words you will meet

| Word | What it means |
|---|---|
| lexer, scanner, tokenizer | the same thing: characters in, tokens out |
| token | a word of the program: a kind and a place |
| lexeme | the text of a token, such as `total` |
| span | the place of a token: start and stop positions in the source |
| lookahead | how many characters the lexer may peek at before deciding |
| maximal munch | the rule "take the longest token that fits" |
| trivia | what the grammar does not care about: blanks and comments |
| regular language | what a regular expression can describe; what a lexer can recognise |
| finite automaton | a machine with a fixed set of states and no other memory; a lexer is one |

## The choices every lexer makes

The five ideas are the same everywhere. Real lexers differ in a handful of decisions, and here
are those decisions for the four lexers of this post.

| | Barlume | Gleam | Nim | Nimony (`nifler2`) |
|---|---|---|---|---|
| Written | by hand | by hand | by hand | half by hand, half generated |
| Lookahead | one character | two characters | a few, past a sentinel | the same, over a string |
| Blanks | dropped | line breaks are tokens | become a number on the next token | the same as Nim |
| Comments | dropped | tokens | tokens | tokens |
| Numbers | text only | text and value | value | text and value |
| Hands tokens over | all at once | one at a time | one at a time | one at a time |
| After an error | stops | the error is the next item | reports it | collects and goes on |

Each row is a small story. The next two sections tell them.
"""

nbNote &"""
Gleam's lexer is [`compiler-core/src/parse/lexer.rs`]({gleamAt}compiler-core/src/parse/lexer.rs),
written by hand. It is our loop with these differences:

- **Two characters of lookahead**, kept in two fields, `char0` and `char1`. One function looks
  at `char0` and decides what starts here; small functions then eat a name, a number, a
  string.
- **Line breaks and comments are tokens** (`NewLine`, `CommentNormal`, `CommentDoc`,
  `CommentModule`). The same lexer feeds the compiler and `gleam format`, and a formatter that
  lost your comments would be a short-lived formatter.
- **A number token carries its value** as well as its text. The formatter wants `1_000` as you
  wrote it, the type checker wants one thousand.
- **It is an iterator.** The parser asks for the next token when it wants one, and each item is
  either a token with its span or an error. One look can produce several tokens, so there is a
  small queue between the two.
- **It knows your mistakes by name.** Our lexer says "I do not know what to do with `'`".
  Gleam's knows that a single quote means you came from a language where strings look like
  that, and says so. Most of its length is this.

The port, and those error messages running in Nim, are in
[The lexer, token for token](../lexer/).
""", nkGleam, "How Gleam does it"

nbText: &"""
## Aside: Nim, and the lexer that reads indentation

Nim's lexer is [`compiler/lexer.nim`]({nimAt}compiler/lexer.nim), also written by hand, and it
has a problem that Gleam and Barlume do not: in Nim, **blanks mean something**. This is a block
because of how far the second line is from the margin:

```nim
if ready:
  launch()
```

A lexer that drops white space would destroy the program. There are two well known ways out.
Python's lexer invents tokens: when a line starts further right than the one before, it emits
an `INDENT` token, and a `DEDENT` when it comes back, so the parser sees something like the
curly brackets of other languages. Nim does something lighter. Every token has a field,
`indent`, described in the source as "the indentation; != -1 if the token has been preceded
with indentation". In other words: the first token of each line knows its column, and every
other token says -1. The lexer measures and the parser decides: Nim's parser keeps the
indentation of the block it is in (`currInd`) and compares each token's `indent` with it.

It is the same trick as the span, used for something else: a token is a kind and a place, and
"how far from the margin" is one more fact about the place. The next post will come back to
what the parser does with it.

Nim's token also has a field called `spacing`, which records whether there were blanks before
and after it. That is how Nim tells `a -b` (call `a` with minus `b`) from `a - b` (a
subtraction). So much for throwing blanks away.

## Aside: Nimony, and a lexer that is half generated

[Nimony](https://nim-lang.org/araq/nimony.html) is the new Nim compiler, in heavy development,
that is meant to become Nim 3. Its design is a chain of separate programs that hand each other
text files in one format, NIF, and the first program of the chain is the one that concerns us:
it reads Nim source and writes NIF. That is lexer and parser together, and nothing else.

There are two of them in the repository today, and the pair is a nice lesson.

[`nifler`]({nimonyAt}src/nifler) is the older one. It does not have a lexer of its own: it
links the lexer and the parser of the Nim 2 compiler and translates the tree they build. That
was the fastest way to get going, and it ties the new compiler to the sources of the old one.

[`nifler2`]({nimonyAt}src/nifler2) is the replacement, with the lexer in
[`nimlexer.nim`]({nimonyAt}src/nifler2/nimlexer.nim). Its header says how it was built, and it
is the "by hand or generated" question answered with "both":

- **generated**: keywords, names and every form of number. The file describes them as regular
  expressions inside a `lex` construct of Nimony's standard library, and the compiler turns
  them into a state machine. The comment gives the reason: numbers are "where a DFA earns its
  keep", because the hand-written version in Nim's lexer is "a hundred lines of hand-rolled
  state". (DFA is a deterministic finite automaton: the machine without memory from above.)
- **by hand**: the indentation bookkeeping, comments (Nim's can nest), string literals, and
  the punctuation whose meaning depends on the character after it.

That is the theory of the previous section showing up in practice. The regular part of the
language goes to a generator. The parts that need a little memory or a little judgement stay
in ordinary code.

Here is what the generated part looks like. It reads the suffix of a number, the `'i8` in
`100'i8`:

```nim
lex L.buf, pos:
of r"'? [iI] 8": kind = tkInt8Lit
of r"'? [iI] 16": kind = tkInt16Lit
of r"'? [uU]": kind = tkUIntLit
```

Each line is a regular expression and what to do when it is the longest match. Maximal munch is
built in.

Two more things in that header are worth a smile, given what we are doing here. The first: the
token kinds have the same names as in Nim's lexer on purpose, "because the two are meant to be
differentially tested against each other: same input, same token sequence, or a bug". That
sentence could be the motto of this port. The second: Nimony's keywords are case sensitive.
In Nim, `proc` and `pRoC` are the same keyword, because identifiers ignore case and
underscores after the first letter. `nifler2` says it "deliberately parts ways" there: `pRoC`
is a plain name.
"""

nbNote """
What was read for the two asides: the sources linked above, at the commits in the links
(Nim 2.2.4, and Nimony as it was on 12 November 2026). Nimony changes every day and `nifler2`
is new, so details may have moved by the time you read this. Nothing was built or run: these
are claims about what the code and its comments say.
""", nkWarning, "Read, not run"

nbText: """
## What this changes for the port

Nothing in the code: the lexer was the first stage ported, and it is checked against the Rust
token for token. What this post adds is around it.

- **A vocabulary.** Token, span, lookahead, trivia: the later posts and the port's own
  explainers use these words, and now they have one place where they are explained.
- **Barlume.** The toy lives in `docs/devlog/data/barlume/` and grows by one stage per post.
  It is ours and it is not part of the compiler: it is never compared with the reference,
  because it is not a port of anything.
- **A reason for a shape.** The ported lexer keeps line breaks and comments as tokens and
  carries both the text and the value of a number. That looked like detail. It is there
  because one front end serves the compiler and the formatter, and it is why the port plan
  can reach a working `format` command before it can type check anything.
- **Company.** Nimony checks its new lexer against the old one, input by input. We check ours
  against Gleam's the same way. It is good to see the method used by people who write
  compilers for a living.

Next: the parser, where the brackets finally have to match.

## Sources

- Gleam's lexer and tokens at the pinned commit:
  [`lexer.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/parse/lexer.rs),
  [`token.rs`](https://github.com/gleam-lang/gleam/blob/ed41eace2dd89054eb2d744c33925261d1eff32e/compiler-core/src/parse/token.rs).
- Nim 2.2.4: [`compiler/lexer.nim`](https://github.com/nim-lang/Nim/blob/v2.2.4/compiler/lexer.nim)
  (the `Token` object) and [`compiler/parser.nim`](https://github.com/nim-lang/Nim/blob/v2.2.4/compiler/parser.nim)
  (`currInd` and the templates that compare it with `tok.indent`).
- Nimony at commit `4ba90a7`:
  [`doc/design.md`](https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/doc/design.md),
  [`src/nifler2/nimlexer.nim`](https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/src/nifler2/nimlexer.nim),
  [`doc/internals/parser_generator.md`](https://github.com/nim-lang/nimony/blob/4ba90a781b0b22d0821efaa153c129c37cef6143/doc/internals/parser_generator.md).
  Andreas Rumpf, [Nimony: Design principles](https://nim-lang.org/araq/nimony.html), 2025.
- Robert Nystrom, *Crafting Interpreters*, the chapter
  [Scanning](https://craftinginterpreters.com/scanning.html). The book could not be opened from
  the sandbox this was written in; the chapter is named from memory as the best longer read
  on the subject, and nothing here is quoted from it.
- Python's `INDENT` and `DEDENT` tokens are described in the
  [lexical analysis](https://docs.python.org/3/reference/lexical_analysis.html#indentation)
  chapter of its reference, which also could not be opened from the sandbox.
- This series' map of the real compiler: [How the Gleam compiler is made](../how-gleam-compiles/).
  The port of the lexer: [The lexer, token for token](../lexer/).
"""

nbSave
