## Barlume, a glimmer of Gleam: a language small enough to compile on one page, used by the
## devlog series on the stages of a compiler. Every Barlume program is a Gleam program.
## This file is its lexer: characters in, tokens out. It is ours, not a port: the real one is
## src/gleam_in_nim/parse/lexer.nim. The `#--- name` lines mark the parts the posts show.

#--- token
type
  TokenKind* = enum
    # these four carry a text
    tkInt, tkString, tkName, tkUpName,
    # keywords
    tkFn, tkLet, tkCase, tkType, tkPub,
    # punctuation
    tkLeftParen, tkRightParen,
    tkLeftBrace, tkRightBrace, tkComma,
    tkEqual, tkEqualEqual, tkArrow,
    tkPlus, tkMinus, tkStar, tkSlash,
    tkLess, tkGreater,
    tkEndOfFile

  Token* = object
    kind*: TokenKind
    # where it is: bytes start ..< stop
    start*, stop*: int

  LexError* = object of CatchableError
    at*: int  # where it went wrong
#--- end

func text*(source: string, token: Token): string =
  ## The characters a token was made of.
  source[token.start ..< token.stop]

#--- keywords
func keywordOrName(word: string): TokenKind =
  case word
  of "fn": tkFn
  of "let": tkLet
  of "case": tkCase
  of "type": tkType
  of "pub": tkPub
  else: tkName
#--- end

#--- lex
func lex*(source: string): seq[Token] =
  var tokens: seq[Token]
  # the cursor: the next character to read
  var i = 0

  # look without moving ('\0' past the end)
  func peek(ahead = 0): char =
    if i + ahead < source.len: source[i + ahead]
    else: '\0'

  # a token of `length` characters starts here
  proc add(kind: TokenKind, length: int) =
    tokens.add Token(kind: kind, start: i,
                     stop: i + length)
    i += length

  proc fail(message: string) =
    raise (ref LexError)(msg: message, at: i)

  while i < source.len:
    let c = peek()
    case c
    # 1. skip the blanks
    of ' ', '\t', '\n', '\r': inc i
    # 2. one character, one token
    of '(': add tkLeftParen, 1
    of ')': add tkRightParen, 1
    of '{': add tkLeftBrace, 1
    of '}': add tkRightBrace, 1
    of ',': add tkComma, 1
    of '+': add tkPlus, 1
    of '*': add tkStar, 1
    of '<': add tkLess, 1
    of '>': add tkGreater, 1
    # 3. one character or two: look ahead
    of '=':
      if peek(1) == '=': add tkEqualEqual, 2
      else: add tkEqual, 1
    of '-':
      if peek(1) == '>': add tkArrow, 2
      else: add tkMinus, 1
    of '/':
      if peek(1) == '/':
        # a comment: skip to the end of the line
        while i < source.len and peek() != '\n':
          inc i
      else: add tkSlash, 1
    # 4. keep going while it fits
    of '0'..'9':
      var n = 1
      while peek(n) in {'0'..'9', '_'}: inc n
      add tkInt, n
    of 'a'..'z', '_':
      var n = 1
      while peek(n) in {'a'..'z', '0'..'9', '_'}:
        inc n
      let word = source[i ..< i + n]
      add keywordOrName(word), n
    of 'A'..'Z':
      var n = 1
      while peek(n) in {'a'..'z', 'A'..'Z'}: inc n
      add tkUpName, n
    of '"':
      var n = 1
      while peek(n) != '"':
        # 5. say where it went wrong
        if peek(n) == '\0':
          fail "this string never ends"
        # \" does not close the string
        if peek(n) == '\\': inc n
        inc n
      add tkString, n + 1
    else:
      fail "I do not know what to do with " & c.repr
  # the last token is always the end of the file
  tokens.add Token(kind: tkEndOfFile, start: i, stop: i)
  tokens
#--- end
