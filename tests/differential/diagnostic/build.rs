// Cuts `wrap` and its helpers out of upstream's compiler-core/src/error.rs, so that the driver
// runs upstream's own code without building the whole compiler.
use std::{env, fs, path::Path};

fn main() {
    let path = "../../../reference/gleam/compiler-core/src/error.rs";
    println!("cargo:rerun-if-changed={path}");
    let source = fs::read_to_string(path).expect("reference/gleam is missing: run reference/fetch.sh source");
    let start = source.find("pub fn wrap(text: &str)").expect("wrap not found");
    let last = start + source[start..].find("fn break_word(").expect("break_word not found");
    let end = last + source[last..].find("\n}\n").expect("end of break_word not found") + 3;
    let out = Path::new(&env::var("OUT_DIR").expect("OUT_DIR")).join("wrap.rs");
    fs::write(out, &source[start..end]).expect("write wrap.rs");
}
