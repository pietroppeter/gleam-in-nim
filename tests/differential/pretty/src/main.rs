// Differential test driver: reads documents in a tiny prefix language, one per
// line, builds them with upstream's pretty-arena and prints them at several
// widths. The Nim port has the same driver; outputs must be identical.
use pretty_arena::*;
use std::cell::RefCell;
use std::io::{self, BufRead, Write};
use std::rc::Rc;

#[derive(Debug, Default)]
struct Recorder {
    seen: Vec<(isize, isize)>,
}
impl CursorPositionObserver for Recorder {
    fn observe_cursor_position(&mut self, line: isize, width: isize) {
        self.seen.push((line, width));
    }
}

fn unhex(token: &str) -> &'static str {
    if token == "-" {
        return "";
    }
    let bytes: Vec<u8> = (0..token.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&token[i..i + 2], 16).unwrap())
        .collect();
    Box::leak(String::from_utf8(bytes).unwrap().into_boxed_str())
}

fn hex(text: &str) -> String {
    text.bytes().map(|b| format!("{b:02x}")).collect()
}

fn build<'a>(
    tokens: &mut std::str::SplitWhitespace<'_>,
    arena: &'a DocumentArena<'static, 'a>,
    recorder: &Rc<RefCell<Recorder>>,
) -> Document<'static, 'a> {
    let number = |tokens: &mut std::str::SplitWhitespace<'_>| tokens.next().unwrap().parse::<isize>().unwrap();
    match tokens.next().unwrap() {
        "s" => unhex(tokens.next().unwrap()).to_doc(arena),
        "z" => arena.zero_width_str(unhex(tokens.next().unwrap())),
        "b" => {
            let broken = unhex(tokens.next().unwrap());
            arena.break_(broken, unhex(tokens.next().unwrap()))
        }
        "f" => {
            let broken = unhex(tokens.next().unwrap());
            arena.flex_break(broken, unhex(tokens.next().unwrap()))
        }
        "l" => arena.lines(number(tokens) as usize),
        "e" => EMPTY_DOCUMENT,
        "o" => arena.position_observer(recorder.clone()),
        "g" => build(tokens, arena, recorder).group(arena),
        "n" => {
            let indent = number(tokens);
            build(tokens, arena, recorder).nest(arena, indent)
        }
        "i" => {
            let indent = number(tokens);
            build(tokens, arena, recorder).nest_if_broken(arena, indent)
        }
        "t" => {
            let indent = number(tokens);
            build(tokens, arena, recorder).set_nesting(arena, indent)
        }
        "F" => build(tokens, arena, recorder).force_break(arena),
        "x" => build(tokens, arena, recorder).next_break_fits(arena, NextBreakFitsMode::Enabled),
        "y" => build(tokens, arena, recorder).next_break_fits(arena, NextBreakFitsMode::Disabled),
        "a" => {
            let first = build(tokens, arena, recorder);
            let second = build(tokens, arena, recorder);
            first.append(arena, second)
        }
        "c" => {
            let count = number(tokens);
            let documents: Vec<_> = (0..count).map(|_| build(tokens, arena, recorder)).collect();
            arena.concat(documents)
        }
        "j" => {
            let count = number(tokens);
            let separator = build(tokens, arena, recorder);
            let documents: Vec<_> = (0..count).map(|_| build(tokens, arena, recorder)).collect();
            arena.join(documents, separator)
        }
        other => panic!("unknown token {other}"),
    }
}

fn main() {
    let stdin = io::stdin();
    let mut out = io::BufWriter::new(io::stdout().lock());
    for line in stdin.lock().lines() {
        let line = line.unwrap();
        let widths: Vec<isize> = vec![0, 1, 2, 3, 5, 8, 13, 20, 40, 80];
        for width in widths {
            let arena = DocumentArena::new();
            let recorder = Rc::new(RefCell::new(Recorder::default()));
            let document = build(&mut line.split_whitespace(), &arena, &recorder);
            let empty = document.is_empty();
            let text = document.to_pretty_string(width);
            let seen: Vec<String> = recorder.borrow().seen.iter().map(|(l, w)| format!("{l}:{w}")).collect();
            writeln!(out, "{width} {empty} {} {}", hex(&text), seen.join(",")).unwrap();
        }
    }
}
