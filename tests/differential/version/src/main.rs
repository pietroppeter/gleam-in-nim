// Differential test driver: reads one case per line (strings in hex), asks
// upstream's hexpm crate and the pubgrub crate it uses, and prints what they
// say. The Nim port has the same driver (driver.nim); outputs must be identical.
//
//   V version                  parse a version
//   C version version          order and equality of two versions
//   R range                    parse a range
//   O range range version      the operations on two ranges
//   S range version...         simplify a range, given some versions
//   I range...                 one range from the segments of several
//   B n bound... n bound... version
//                              the operations on two ranges built from any
//                              segments: n pairs of bounds each, a bound being
//                              `u` (unbounded), `i` or `e` (included, excluded)
//                              followed by a version
use hexpm::version::{Identifier, LowestVersion, Range, Version};
use std::cmp::Ordering;
use std::io::{self, BufRead, Write};
use std::ops::Bound;

type Ranges = pubgrub::Range<Version>;

fn unhex(token: &str) -> String {
    if token == "-" {
        return String::new();
    }
    let bytes: Vec<u8> = (0..token.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&token[i..i + 2], 16).unwrap())
        .collect();
    String::from_utf8(bytes).unwrap()
}

fn hex(text: &str) -> String {
    text.bytes().map(|b| format!("{b:02x}")).collect()
}

fn fields(version: &Version) -> String {
    let pre: Vec<String> = version
        .pre
        .iter()
        .map(|identifier| match identifier {
            Identifier::Numeric(number) => format!("n{number}"),
            Identifier::AlphaNumeric(text) => format!("a{text}"),
        })
        .collect();
    format!(
        "{} {} {} [{}] {}",
        version.major,
        version.minor,
        version.patch,
        pre.join(","),
        match &version.build {
            Some(build) => format!("+{build}"),
            None => "-".to_string(),
        }
    )
}

fn ordering(ordering: Ordering) -> &'static str {
    match ordering {
        Ordering::Less => "less",
        Ordering::Equal => "equal",
        Ordering::Greater => "greater",
    }
}

fn version(token: &str) -> Version {
    Version::parse(&unhex(token)).unwrap()
}

fn range(token: &str) -> Ranges {
    Range::new(unhex(token)).unwrap().to_pubgrub().clone()
}

fn bound(token: &str) -> Bound<Version> {
    match &token[..1] {
        "u" => Bound::Unbounded,
        "i" => Bound::Included(version(&token[1..])),
        "e" => Bound::Excluded(version(&token[1..])),
        other => panic!("unknown bound {other}"),
    }
}

fn built(tokens: &[&str], position: &mut usize) -> Ranges {
    let count: usize = tokens[*position].parse().unwrap();
    *position += 1;
    let mut segments = vec![];
    for _ in 0..count {
        segments.push((bound(tokens[*position]), bound(tokens[*position + 1])));
        *position += 2;
    }
    segments.into_iter().collect()
}

fn operations(left: &Ranges, right: &Ranges, version: &Version) -> String {
    format!(
        "union:{} | intersection:{} | complement:{} | contains:{} | disjoint:{} | subset:{} | equal:{} | {} | singleton:{} | empty:{} | double:{}",
        left.union(right),
        left.intersection(right),
        left.complement(),
        left.contains(version),
        left.is_disjoint(right),
        left.subset_of(right),
        left == right,
        ordering(left.cmp(right)),
        match left.as_singleton() {
            Some(version) => version.to_string(),
            None => "none".to_string(),
        },
        left.intersection(&right.complement()).is_empty(),
        left.complement().complement() == *left,
    )
}

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    for line in stdin.lock().lines() {
        let line = line.unwrap();
        let tokens: Vec<&str> = line.split(' ').collect();
        let answer = match tokens[0] {
            "V" => match Version::parse(&unhex(tokens[1])) {
                Ok(version) => format!("ok {} | {} | pre:{}", hex(&version.to_string()), fields(&version), version.is_pre()),
                Err(error) => format!("error {}", hex(&error.to_string())),
            },
            "C" => {
                let (left, right) = (version(tokens[1]), version(tokens[2]));
                format!("{} {}", ordering(left.cmp(&right)), left == right)
            }
            "R" => match Range::new(unhex(tokens[1])) {
                Ok(range) => format!(
                    "ok {} | {} | {} | {:?} | lowest:{}",
                    hex(&range.to_pubgrub().to_string()),
                    hex(range.as_str()),
                    hex(&Range::from(range.to_pubgrub().clone()).to_string()),
                    range,
                    match range.to_pubgrub().lowest_version() {
                        Some(version) => version.to_string(),
                        None => "none".to_string(),
                    }
                ),
                Err(error) => format!("error {}", hex(&error.to_string())),
            },
            "O" => {
                let (left, right, version) = (range(tokens[1]), range(tokens[2]), version(tokens[3]));
                operations(&left, &right, &version)
            }
            "B" => {
                let mut position = 1;
                let left = built(&tokens, &mut position);
                let right = built(&tokens, &mut position);
                let version = version(tokens[position]);
                format!("{left} | {right} | {}", operations(&left, &right, &version))
            }
            "S" => {
                let range = range(tokens[1]);
                let mut versions: Vec<Version> = tokens[2..].iter().map(|token| version(token)).collect();
                versions.sort();
                let contained: Vec<String> = range.contains_many(versions.iter()).map(|b| b.to_string()).collect();
                format!("{} | {}", range.simplify(versions.iter()), contained.join(","))
            }
            "I" => {
                let mut segments = vec![];
                for token in &tokens[1..] {
                    for (start, end) in range(token).iter() {
                        segments.push((start.clone(), end.clone()));
                    }
                }
                let collected: Ranges = segments.into_iter().collect();
                format!("{collected}")
            }
            other => panic!("unknown case {other}"),
        };
        writeln!(out, "{answer}").unwrap();
    }
}
