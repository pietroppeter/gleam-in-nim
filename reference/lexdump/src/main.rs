//! Dump the token stream of the reference Gleam lexer.
//!
//! Usage:
//!   lexdump FILE...          one dump per file, each preceded by `== FILE`
//!   lexdump --lines FILE     treat each line of FILE as one escaped source
//!                            (same escaping as the output), dump each
//!                            preceded by `== LINENUMBER`
//!
//!   lexdump --floats FILE  each line is a float literal: print the bits of
//!                            its value in hex, or `none`
//!   lexdump --ints FILE    each line is an int literal: print its value in
//!                            decimal, or `none`
//!
//! Output, one token per line: `START END KIND [PAYLOAD...]`, tab separated.
//! Lexing stops at the first error, printed as `START END !KIND [PAYLOAD...]`
//! and followed by its message: the title and each extra line as `| TEXT`.
//! Payload bytes outside printable ASCII, and the backslash, are written as
//! `\xHH`, so the dump is plain ASCII whatever the source contains.

use gleam_core::parse::Token;
use gleam_core::parse::{LiteralFloatValue, parse_int_value};
use gleam_core::parse::error::{InvalidUnicodeEscapeError, LexicalErrorType};
use gleam_core::parse::lexer::make_tokenizer;
use std::io::Write;

fn escape(s: &str) -> String {
    let mut out = String::new();
    for &b in s.as_bytes() {
        if (0x20..0x7f).contains(&b) && b != b'\\' {
            out.push(b as char);
        } else {
            out.push_str(&format!("\\x{b:02X}"));
        }
    }
    out
}

fn unescape(s: &str) -> Vec<u8> {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\' && i + 3 < b.len() && b[i + 1] == b'x' {
            let hex = std::str::from_utf8(&b[i + 2..i + 4]).expect("hex");
            out.push(u8::from_str_radix(hex, 16).expect("hex digits"));
            i += 4;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    out
}

fn dump(out: &mut impl Write, src: &str) {
    for item in make_tokenizer(src) {
        match item {
            Ok((start, token, end)) => {
                let (kind, payload): (String, Vec<String>) = match &token {
                    Token::Name { name } => ("Name".into(), vec![escape(name)]),
                    Token::UpName { name } => ("UpName".into(), vec![escape(name)]),
                    Token::DiscardName { name } => ("DiscardName".into(), vec![escape(name)]),
                    Token::Int { value, int_value } => {
                        ("Int".into(), vec![escape(value), int_value.to_string()])
                    }
                    Token::Float { value, float_value } => (
                        "Float".into(),
                        vec![
                            escape(value),
                            format!("{:016X}", float_value.value().to_bits()),
                        ],
                    ),
                    Token::String { value } => ("String".into(), vec![escape(value)]),
                    Token::CommentDoc { content } => ("CommentDoc".into(), vec![escape(content)]),
                    other => (format!("{other:?}"), vec![]),
                };
                write!(out, "{start}\t{end}\t{kind}").expect("write");
                for p in payload {
                    write!(out, "\t{p}").expect("write");
                }
                writeln!(out).expect("write");
            }
            Err(error) => {
                let s = error.location.start;
                let e = error.location.end;
                let (kind, payload): (String, Vec<String>) = match error.error {
                    LexicalErrorType::InvalidUnicodeEscape(inner) => (
                        "InvalidUnicodeEscape".into(),
                        vec![
                            match inner {
                                InvalidUnicodeEscapeError::MissingOpeningBrace => {
                                    "MissingOpeningBrace"
                                }
                                InvalidUnicodeEscapeError::ExpectedHexDigitOrCloseBrace => {
                                    "ExpectedHexDigitOrCloseBrace"
                                }
                                InvalidUnicodeEscapeError::InvalidNumberOfHexDigits => {
                                    "InvalidNumberOfHexDigits"
                                }
                                InvalidUnicodeEscapeError::InvalidCodepoint => "InvalidCodepoint",
                            }
                            .into(),
                        ],
                    ),
                    LexicalErrorType::UnrecognizedToken { token } => (
                        "UnrecognizedToken".into(),
                        vec![escape(&token.to_string())],
                    ),
                    LexicalErrorType::VisuallySimilarInvalidCharacter { name, correct } => (
                        "VisuallySimilarInvalidCharacter".into(),
                        vec![escape(name), escape(correct)],
                    ),
                    other => (format!("{other:?}"), vec![]),
                };
                write!(out, "{s}\t{e}\t!{kind}").expect("write");
                for p in payload {
                    write!(out, "\t{p}").expect("write");
                }
                writeln!(out).expect("write");
                let (title, extra) = error.to_parse_error_info();
                writeln!(out, "| {}", escape(title)).expect("write");
                for line in extra {
                    writeln!(out, "| {}", escape(&line)).expect("write");
                }
                break;
            }
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let stdout = std::io::stdout();
    let mut out = std::io::BufWriter::new(stdout.lock());
    if args.first().map(String::as_str) == Some("--floats") {
        let text = std::fs::read_to_string(&args[1]).expect("read floats file");
        for line in text.lines() {
            match LiteralFloatValue::parse(line) {
                Some(float) => writeln!(out, "{:016X}", float.value().to_bits()),
                None => writeln!(out, "none"),
            }
            .expect("write");
        }
    } else if args.first().map(String::as_str) == Some("--ints") {
        let text = std::fs::read_to_string(&args[1]).expect("read ints file");
        for line in text.lines() {
            match parse_int_value(line) {
                Some(int) => writeln!(out, "{int}"),
                None => writeln!(out, "none"),
            }
            .expect("write");
        }
    } else if args.first().map(String::as_str) == Some("--lines") {
        let text = std::fs::read_to_string(&args[1]).expect("read lines file");
        for (index, line) in text.lines().enumerate() {
            writeln!(out, "== {}", index + 1).expect("write");
            let bytes = unescape(line);
            // The lexer takes a &str: sources that are not UTF-8 never reach it.
            match String::from_utf8(bytes) {
                Ok(src) => dump(&mut out, &src),
                Err(_) => writeln!(out, "!!NotUtf8").expect("write"),
            }
        }
    } else {
        for path in &args {
            writeln!(out, "== {path}").expect("write");
            match std::fs::read_to_string(path) {
                Ok(src) => dump(&mut out, &src),
                Err(_) => writeln!(out, "!!NotUtf8").expect("write"),
            }
        }
    }
}
