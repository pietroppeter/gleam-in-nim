// Reads diagnostics, one per line, and prints each with upstream's `Diagnostic::write`,
// as hex, one line per diagnostic. The line format is in driver.nim.
#[path = "../../../../reference/gleam/compiler-core/src/diagnostic.rs"]
mod diagnostic;
mod error {
    use std::borrow::Cow;
    include!(concat!(env!("OUT_DIR"), "/wrap.rs"));
}

use diagnostic::{Diagnostic, ExtraLabel, Label, Level, Location};
use src_span::SrcSpan;
use std::io::{BufRead, Write};
use termcolor::Buffer;

fn unhex(text: &str) -> String {
    if text == "." {
        return String::new();
    }
    let bytes: Vec<u8> = (0..text.len() / 2)
        .map(|i| u8::from_str_radix(&text[i * 2..i * 2 + 2], 16).expect("hex"))
        .collect();
    String::from_utf8(bytes).expect("utf8")
}

fn optional(text: &str) -> Option<String> {
    if text == "-" { None } else { Some(unhex(text)) }
}

fn label<'a>(words: &mut impl Iterator<Item = &'a str>) -> Label {
    let text = optional(words.next().expect("label text"));
    let start: u32 = words.next().expect("start").parse().expect("start");
    let end: u32 = words.next().expect("end").parse().expect("end");
    Label { text, span: SrcSpan { start, end } }
}

fn main() {
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    std::panic::set_hook(Box::new(|_| {}));
    for line in stdin.lock().lines() {
        let line = line.expect("line");
        let mut words = line.split(' ');
        let colour = words.next().expect("colour") == "1";
        let level = if words.next().expect("level") == "E" { Level::Error } else { Level::Warning };
        let title = unhex(words.next().expect("title"));
        let text = unhex(words.next().expect("text"));
        let hint = optional(words.next().expect("hint"));
        let location = if words.next().expect("location") == "L" {
            let src = unhex(words.next().expect("src"));
            let path = unhex(words.next().expect("path"));
            let main = label(&mut words);
            let count: usize = words.next().expect("count").parse().expect("count");
            let mut extra_labels = vec![];
            for _ in 0..count {
                let src_info = if words.next().expect("kind") == "S" {
                    let src = unhex(words.next().expect("src"));
                    let path = unhex(words.next().expect("path"));
                    Some((src.into(), path.into()))
                } else {
                    None
                };
                extra_labels.push(ExtraLabel { src_info, label: label(&mut words) });
            }
            Some(Location { src: src.into(), path: path.into(), label: main, extra_labels })
        } else {
            None
        };
        let diagnostic = Diagnostic { title, text, level, location, hint };
        let result = std::panic::catch_unwind(|| {
            let mut buffer = if colour { Buffer::ansi() } else { Buffer::no_color() };
            diagnostic.write(&mut buffer);
            buffer.into_inner()
        });
        match result {
            Ok(bytes) => {
                let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
                writeln!(out, "{hex}").expect("write");
            }
            Err(_) => writeln!(out, "PANIC").expect("write"),
        }
    }
}
