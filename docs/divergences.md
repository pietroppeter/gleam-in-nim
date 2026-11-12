Every place where the Nim port knowingly behaves differently from Gleam at the pin, with the
reason ([decision 0003](#0003-the-pinned-compiler-and-its-tests-are-the-specification)). Anything not listed here must be identical.

- **An unprintable character in a version requirement.** When a requirement holds a character
  the version lexer does not know, the error shows it the way Rust's `{:?}` does. Rust escapes
  every character Unicode calls non-printable (`\u{200b}`); the port escapes only the control
  characters and prints the others as they are. Tables for the full rule are not worth their
  size for an error message about a character nobody types. (`hexpm/version/parser.nim`,
  `debugEscape`.)
