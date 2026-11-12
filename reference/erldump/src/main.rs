//! Replay scripts of `ErlangBuilder` calls on the reference builders.
//!
//! Usage:
//!   erldump source FILE     replay with `ErlangSourceBuilder`
//!
//! A file holds scripts. A script starts with a line `== NAME` and has one
//! builder call per line: the name of the trait function, then its arguments,
//! tab separated. Bytes outside printable ASCII, and the backslash, are
//! written `\xHH`.
//!
//! - a location is `START:END`;
//! - a list (exports, argument names, type parameters, specifiers) is the rest
//!   of the line, pairs being two fields;
//! - a float is the 16 hex digits of its bits; an int is decimal;
//! - `doc_attribute` and `moduledoc_attribute` take `false`, or `string` and
//!   the content;
//! - the module of `function_reference` is `-` when there is none;
//! - a module name is a Gleam module name (`ErlangModuleName::new`).
//!
//! The `end_*` calls take no argument: the value their `start_*` returned is
//! kept on a stack, one stack per associated type of the trait.
//! `into_output` is called when the script ends.
//!
//! Output: `== NAME`, then each line of the output as `| LINE`, or
//! `! MESSAGE` when the builder panicked.

use ecow::EcoString;
use erlang_generation::{
    BitArraySegmentSpecifier, DocContent, ErlangBuilder, ErlangBuiltInType, ErlangModuleName,
    ErlangSourceBuilder,
};
use num_bigint::BigInt;
use src_span::SrcSpan;
use std::io::Write;
use std::str::FromStr;

fn unescape(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\' && i + 3 < b.len() && b[i + 1] == b'x' {
            out.push(u8::from_str_radix(&s[i + 2..i + 4], 16).expect("hex escape"));
            i += 4;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).expect("utf8 argument")
}

fn location(s: &str) -> SrcSpan {
    let (start, end) = s.split_once(':').expect("location");
    SrcSpan::new(start.parse().expect("start"), end.parse().expect("end"))
}

fn doc<'a>(fields: &'a [String]) -> DocContent<'a> {
    match fields[1].as_str() {
        "false" => DocContent::False,
        "string" => DocContent::String(&fields[2]),
        other => panic!("doc content {other}"),
    }
}

fn built_in(s: &str) -> ErlangBuiltInType {
    match s {
        "any" => ErlangBuiltInType::Any,
        "integer" => ErlangBuiltInType::Integer,
        "binary" => ErlangBuiltInType::Binary,
        "boolean" => ErlangBuiltInType::Boolean,
        "float" => ErlangBuiltInType::Float,
        "bitstring" => ErlangBuiltInType::Bitstring,
        "list" => ErlangBuiltInType::List,
        other => panic!("built in type {other}"),
    }
}

fn specifier(s: &str) -> BitArraySegmentSpecifier {
    match s {
        "utf8" => BitArraySegmentSpecifier::Utf8,
        "utf16" => BitArraySegmentSpecifier::Utf16,
        "utf32" => BitArraySegmentSpecifier::Utf32,
        "integer" => BitArraySegmentSpecifier::Integer,
        "float" => BitArraySegmentSpecifier::Float,
        "binary" => BitArraySegmentSpecifier::Binary,
        "bitstring" => BitArraySegmentSpecifier::Bitstring,
        "signed" => BitArraySegmentSpecifier::Signed,
        "unsigned" => BitArraySegmentSpecifier::Unsigned,
        "little" => BitArraySegmentSpecifier::Little,
        "big" => BitArraySegmentSpecifier::Big,
        "native" => BitArraySegmentSpecifier::Native,
        other => BitArraySegmentSpecifier::Unit(
            other.strip_prefix("unit:").expect("specifier").parse().expect("unit"),
        ),
    }
}

fn float(s: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(s, 16).expect("float bits"))
}

fn int(s: &str) -> BigInt {
    BigInt::from_str(s).expect("int")
}

fn pairs(fields: &[String]) -> Vec<(String, usize)> {
    fields.chunks(2).map(|c| (c[0].clone(), c[1].parse().expect("arity"))).collect()
}

fn arguments(fields: &[String]) -> Vec<(SrcSpan, String)> {
    fields.chunks(2).map(|c| (location(&c[0]), c[1].clone())).collect()
}

fn replay<Output, B: ErlangBuilder<Output>>(mut b: B, script: &[Vec<String>]) -> Output {
    let mut functions = Vec::new();
    let mut calls = Vec::new();
    let mut called_expressions = Vec::new();
    let mut cases = Vec::new();
    let mut case_subjects = Vec::new();
    let mut clause_patterns = Vec::new();
    let mut clause_guards = Vec::new();
    let mut guards = Vec::new();
    let mut clause_bodies = Vec::new();
    let mut tuples = Vec::new();
    let mut maps = Vec::new();
    let mut bit_arrays = Vec::new();
    let mut bit_array_patterns = Vec::new();
    let mut tuple_types = Vec::new();
    let mut tuple_patterns = Vec::new();
    let mut record_attributes = Vec::new();
    let mut function_types = Vec::new();
    let mut named_types = Vec::new();
    let mut remote_named_types = Vec::new();
    let mut union_types = Vec::new();
    let mut function_specs = Vec::new();
    let mut blocks = Vec::new();
    let mut function_type_arguments = Vec::new();
    let mut type_specs = Vec::new();

    for f in script {
        match f[0].as_str() {
            "module_declaration" => b.module_declaration(ErlangModuleName::new(&f[1])),
            "export_attribute" => b.export_attribute(pairs(&f[1..])),
            "export_type_attribute" => b.export_type_attribute(pairs(&f[1..])),
            "doc_attribute" => b.doc_attribute(doc(f)),
            "moduledoc_attribute" => b.moduledoc_attribute(doc(f)),
            "compile_attribute" => b.compile_attribute(f[1..].iter().map(|s| s.as_str())),
            "module_file_attribute" => b.module_file_attribute(&f[1]),
            "start_record_attribute" => record_attributes.push(b.start_record_attribute(&f[1])),
            "end_record_attribute" => b.end_record_attribute(record_attributes.pop().expect("stack")),
            "record_field" => b.record_field(),
            "start_function_spec" => {
                function_specs.push(b.start_function_spec(&f[1], f[2].parse().expect("arity")))
            }
            "end_function_spec" => b.end_function_spec(function_specs.pop().expect("stack")),
            "start_type_spec" => type_specs.push(b.start_type_spec(
                f[1] == "1",
                &f[2],
                f[3..].iter().map(|s| EcoString::from(s.as_str())),
            )),
            "end_type_spec" => b.end_type_spec(type_specs.pop().expect("stack")),
            "start_function_type" => function_type_arguments.push(b.start_function_type()),
            "end_function_type_arguments" => function_types
                .push(b.end_function_type_arguments(function_type_arguments.pop().expect("stack"))),
            "end_function_type" => b.end_function_type(function_types.pop().expect("stack")),
            "start_built_in_named_type" => {
                named_types.push(b.start_built_in_named_type(built_in(&f[1])))
            }
            "start_custom_named_type" => named_types.push(b.start_custom_named_type(&f[1])),
            "end_named_type" => b.end_named_type(named_types.pop().expect("stack")),
            "start_remote_named_type" => remote_named_types
                .push(b.start_remote_named_type(ErlangModuleName::new(&f[1]), &f[2])),
            "end_remote_named_type" => {
                b.end_remote_named_type(remote_named_types.pop().expect("stack"))
            }
            "start_tuple_type" => tuple_types.push(b.start_tuple_type()),
            "end_tuple_type" => b.end_tuple_type(tuple_types.pop().expect("stack")),
            "start_union_type" => union_types.push(b.start_union_type()),
            "end_union_type" => b.end_union_type(union_types.pop().expect("stack")),
            "type_variable" => b.type_variable(&f[1]),
            "literal_atom_type" => b.literal_atom_type(&f[1]),
            "start_function" => functions.push(b.start_function(
                location(&f[1]),
                &f[2],
                f[3].parse().expect("arity"),
                arguments(&f[4..]),
            )),
            "start_anonymous_function" => {
                functions.push(b.start_anonymous_function(location(&f[1]), arguments(&f[2..])))
            }
            "end_function" => b.end_function(functions.pop().expect("stack")),
            "start_block" => blocks.push(b.start_block(location(&f[1]))),
            "end_block" => b.end_block(blocks.pop().expect("stack")),
            "start_remote_call" => calls.push(b.start_remote_call(
                location(&f[1]),
                ErlangModuleName::new(&f[2]),
                &f[3],
            )),
            "start_call" => called_expressions.push(b.start_call(location(&f[1]))),
            "end_called_expression" => {
                calls.push(b.end_called_expression(called_expressions.pop().expect("stack")))
            }
            "end_call" => b.end_call(calls.pop().expect("stack")),
            "start_tuple" => tuples.push(b.start_tuple(location(&f[1]))),
            "end_tuple" => b.end_tuple(tuples.pop().expect("stack")),
            "start_map" => maps.push(b.start_map(location(&f[1]))),
            "end_map" => b.end_map(maps.pop().expect("stack")),
            "map_field" => b.map_field(location(&f[1])),
            "start_bit_array" => bit_arrays.push(b.start_bit_array(location(&f[1]))),
            "end_bit_array" => b.end_bit_array(bit_arrays.pop().expect("stack")),
            "bit_array_segment" => b.bit_array_segment(location(&f[1])),
            "bit_array_segment_default_size" => b.bit_array_segment_default_size(),
            "bit_array_segment_specifiers" => {
                b.bit_array_segment_specifiers(f[1..].iter().map(|s| specifier(s)))
            }
            "cons_list" => b.cons_list(location(&f[1])),
            "empty_list" => b.empty_list(location(&f[1])),
            "start_case" => case_subjects.push(b.start_case(location(&f[1]))),
            "end_case_subject" => {
                cases.push(b.end_case_subject(case_subjects.pop().expect("stack")))
            }
            "end_case" => b.end_case(cases.pop().expect("stack")),
            "start_case_clause" => clause_patterns.push(b.start_case_clause(location(&f[1]))),
            "end_clause_pattern" => {
                clause_guards.push(b.end_clause_pattern(clause_patterns.pop().expect("stack")))
            }
            "start_clause_guard" => guards.push(b.start_clause_guard()),
            "end_clause_guard" => b.end_clause_guard(guards.pop().expect("stack")),
            "end_clause_guards" => {
                clause_bodies.push(b.end_clause_guards(clause_guards.pop().expect("stack")))
            }
            "end_clause_body" => b.end_clause_body(clause_bodies.pop().expect("stack")),
            "variable" => b.variable(location(&f[1]), &f[2]),
            "unary_operator" => b.unary_operator(location(&f[1]), &f[2]),
            "binary_operator" => {
                b.binary_operator(location(&f[1]), Box::leak(f[2].clone().into_boxed_str()))
            }
            "function_reference" => b.function_reference(
                location(&f[1]),
                if f[2] == "-" { None } else { Some(ErlangModuleName::new(&f[2])) },
                &f[3],
                f[4].parse().expect("arity"),
            ),
            "match_operator" => b.match_operator(location(&f[1])),
            "match_pattern" => b.match_pattern(location(&f[1])),
            "variable_pattern" => b.variable_pattern(location(&f[1]), &f[2]),
            "discard_pattern" => b.discard_pattern(location(&f[1])),
            "int_pattern" => b.int_pattern(location(&f[1]), int(&f[2])),
            "float_pattern" => b.float_pattern(location(&f[1]), float(&f[2])),
            "string_pattern" => b.string_pattern(location(&f[1]), &f[2]),
            "atom_pattern" => b.atom_pattern(location(&f[1]), &f[2]),
            "start_tuple_pattern" => tuple_patterns.push(b.start_tuple_pattern(location(&f[1]))),
            "end_tuple_pattern" => b.end_tuple_pattern(tuple_patterns.pop().expect("stack")),
            "start_bit_array_pattern" => {
                bit_array_patterns.push(b.start_bit_array_pattern(location(&f[1])))
            }
            "end_bit_array_pattern" => {
                b.end_bit_array_pattern(bit_array_patterns.pop().expect("stack"))
            }
            "cons_list_pattern" => b.cons_list_pattern(location(&f[1])),
            "empty_list_pattern" => b.empty_list_pattern(location(&f[1])),
            "string" => b.string(location(&f[1]), &f[2]),
            "int_expression" => b.int_expression(location(&f[1]), int(&f[2])),
            "float_expression" => b.float_expression(location(&f[1]), float(&f[2])),
            "atom_expression" => b.atom_expression(location(&f[1]), &f[2]),
            other => panic!("unknown call {other}"),
        }
    }
    b.into_output()
}

fn message(payload: Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else {
        String::from("panic")
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 || args[1] != "source" {
        eprintln!("usage: erldump source FILE");
        std::process::exit(2);
    }
    let text = std::fs::read_to_string(&args[2]).expect("read");
    std::panic::set_hook(Box::new(|_| {}));
    let stdout = std::io::stdout();
    let mut out = std::io::BufWriter::new(stdout.lock());

    let mut name: Option<&str> = None;
    let mut script: Vec<Vec<String>> = Vec::new();
    let mut flush = |name: Option<&str>, script: &mut Vec<Vec<String>>| {
        let Some(name) = name else { return };
        writeln!(out, "== {name}").expect("write");
        let calls = std::mem::take(script);
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            replay(ErlangSourceBuilder::default(), &calls)
        }));
        match result {
            Ok(code) => {
                for line in code.split('\n') {
                    writeln!(out, "| {line}").expect("write");
                }
            }
            Err(payload) => {
                writeln!(out, "! {}", message(payload).replace('\n', "\\n")).expect("write")
            }
        }
    };
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("== ") {
            flush(name, &mut script);
            name = Some(rest);
        } else if !line.is_empty() {
            script.push(line.split('\t').map(unescape).collect());
        }
    }
    flush(name, &mut script);
}
