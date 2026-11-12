## Rust's `{:?}` for strings and characters. The expected texts were printed
## by Rust (rustc 1.97, Unicode 17); the table behind them is asked of Rust by
## tools/gen/rust_debug_tables.rs.
import std/[unittest, unicode]
import gleam_in_nim/rust_debug

suite "rust debug form":
  test "plain text is itself, in quotes":
    check debugStr("and") == "\"and\""
    check debugStr("") == "\"\""
    check debugChar(Rune('x')) == "'x'"
    check debugStr("é ∅ 😀") == "\"é ∅ 😀\""

  test "the named escapes":
    check debugStr("a\tb\r\n\0\\") == "\"a\\tb\\r\\n\\0\\\\\""
    check debugChar(Rune('\n')) == "'\\n'"

  test "a string escapes its quote, a char its own":
    check debugStr("\"'") == "\"\\\"'\""
    check debugChar(Rune('\'')) == "'\\''"
    check debugChar(Rune('"')) == "'\"'"

  test "what cannot be printed is written as a code point":
    check debugChar(Rune(0x1)) == "'\\u{1}'"
    check debugChar(Rune(0x7F)) == "'\\u{7f}'"
    check debugChar(Rune(0xAD)) == "'\\u{ad}'"       # soft hyphen
    check debugChar(Rune(0x301)) == "'\\u{301}'"     # combining acute accent: extends a grapheme
    check debugChar(Rune(0x200B)) == "'\\u{200b}'"   # zero width space
    check debugChar(Rune(0x378)) == "'\\u{378}'"     # not assigned
    check debugChar(Rune(0xE000)) == "'\\u{e000}'"   # private use
    check debugStr("é") == "\"e\\u{301}\""

  test "the table knows its Unicode version":
    check rustDebugUnicodeVersion == "17.0.0"
