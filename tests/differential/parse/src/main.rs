//! The parser oracle: what the reference Gleam parser makes of a source.
//!
//! Usage: parse-driver MODE FILE
//!
//! MODE is `module`, `statements` or `const`: which entry point of the parser
//! to call (`parse_module`, `parse_statement_sequence`, `parse_const_value`).
//! Each line of FILE is one source, escaped as in tools/lexdump.nim (bytes
//! outside printable ASCII, and the backslash, as `\xHH`).
//!
//! For each source it prints `== N`, then `ok` or `error`, then the result in
//! Rust's pretty Debug format (`{:#?}`), which is also the format of upstream's
//! parser snapshots. For a module, the warnings the parser emits follow, after
//! a line `-- warnings`.

use camino::Utf8PathBuf;
use gleam_core::parse::{parse_const_value, parse_module, parse_statement_sequence};
use gleam_core::warning::{Warning, WarningEmitter};
use std::io::Write;

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

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mode = args[0].as_str();
    let text = std::fs::read_to_string(&args[1]).expect("read sources file");
    let stdout = std::io::stdout();
    let mut out = std::io::BufWriter::new(stdout.lock());
    for (index, line) in text.lines().enumerate() {
        writeln!(out, "== {}", index + 1).expect("write");
        let Ok(src) = String::from_utf8(unescape(line)) else {
            writeln!(out, "not utf8").expect("write");
            continue;
        };
        match mode {
            "module" => {
                let (warnings, emitted) = WarningEmitter::vector();
                match parse_module(Utf8PathBuf::from("test/path"), &src, &warnings) {
                    Ok(parsed) => writeln!(out, "ok\n{parsed:#?}"),
                    Err(error) => writeln!(out, "error\n{error:#?}"),
                }
                .expect("write");
                writeln!(out, "-- warnings").expect("write");
                for warning in emitted.take() {
                    // The path and the source are the same for every warning:
                    // print what the parser decided.
                    match warning {
                        Warning::DeprecatedSyntax { warning, .. } => {
                            writeln!(out, "{warning:#?}")
                        }
                        Warning::DetachedDocComment { location, .. } => {
                            writeln!(out, "DetachedDocComment {location:#?}")
                        }
                        other => writeln!(out, "{other:#?}"),
                    }
                    .expect("write");
                }
            }
            "statements" => match parse_statement_sequence(&src) {
                Ok(statements) => writeln!(out, "ok\n{statements:#?}"),
                Err(error) => writeln!(out, "error\n{error:#?}"),
            }
            .expect("write"),
            "const" => match parse_const_value(&src) {
                Ok(constant) => writeln!(out, "ok\n{constant:#?}"),
                Err(error) => writeln!(out, "error\n{error:#?}"),
            }
            .expect("write"),
            other => panic!("unknown mode {other}"),
        }
    }
}
