// Oracle for the port of hexpm/src/version: reads cases on stdin, one per line, fields
// separated by tabs (kind, name, then the inputs in hex); prints one line per case.
//   V name <hex>            parse a version: its fields and its Display, or the error
//   R name <hex>            parse a range: the Display of the pubgrub range, or the error
//   C name <hex> <hex>      compare two versions: the Ordering, and whether they are ==
//   T name <hex> <hex>      does the range contain the version
use hexpm::version::{Identifier, Range, Version};
use std::io::BufRead;

fn unhex(s: &str) -> String {
    let bytes: Vec<u8> = (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap()).collect();
    String::from_utf8(bytes).unwrap()
}

fn main() {
    for line in std::io::stdin().lock().lines() {
        let line = line.unwrap();
        let f: Vec<&str> = line.split('\t').collect();
        match f[0] {
            "V" => match Version::parse(&unhex(f[2])) {
                Ok(v) => {
                    let pre: Vec<String> = v.pre.iter().map(|i| match i {
                        Identifier::Numeric(n) => format!("N:{n}"),
                        Identifier::AlphaNumeric(s) => format!("A:{s}"),
                    }).collect();
                    println!("ok\t{}\t{}\t{}\t{}\t{}\t{}", v.major, v.minor, v.patch, pre.join(","),
                        v.build.clone().map(|b| format!("+{b}")).unwrap_or("-".into()), v)
                }
                Err(e) => println!("err\t{e}"),
            },
            "R" => match Range::new(unhex(f[2])) {
                Ok(r) => println!("ok\t{}", r.to_pubgrub()),
                Err(e) => println!("err\t{e}"),
            },
            "C" => match (Version::parse(&unhex(f[2])), Version::parse(&unhex(f[3]))) {
                (Ok(a), Ok(b)) => println!("{:?}\t{}", a.cmp(&b), a == b),
                _ => println!("invalid"),
            },
            "T" => match (Range::new(unhex(f[2])), Version::parse(&unhex(f[3]))) {
                (Ok(r), Ok(v)) => println!("{}", r.to_pubgrub().contains(&v)),
                _ => println!("invalid"),
            },
            _ => panic!("unknown case"),
        }
    }
}
