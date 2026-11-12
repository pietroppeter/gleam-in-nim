#!/usr/bin/env python3
"""Writes the cases of the differential test of Hex versions and ranges, on stdout.

One case per line, fields separated by tabs: kind, name, then the inputs in hex.
Three sources: the inputs of upstream's own tests (hexpm/src/version/tests.rs), every version
and requirement of the corpus (corpus/corpus.json), and random strings from a fixed seed.

    python3 cases.py REFERENCE_CHECKOUT CORPUS_JSON [SEED] [COUNT]
"""
import json, random, re, sys

ref, corpus = sys.argv[1], sys.argv[2]
seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
count = int(sys.argv[4]) if len(sys.argv) > 4 else 1500
out = []

def case(kind, name, *inputs):
    out.append("\t".join([kind, name] + [i.encode().hex() for i in inputs]))

def unescape(literal):
    return literal.encode().decode("unicode_escape")

# 1. upstream's tests: the macro calls of hexpm/src/version/tests.rs
tests = open(ref + "/hexpm/src/version/tests.rs").read()
for macro, kind in [("version_parse_test", "V"), ("version_parse_fail_test", "V"), ("version_parse_print", "V"),
                    ("parse_range_test", "R"), ("parse_range_fail_test", "R")]:
    for name, literal in re.findall(macro + r'!\(\s*(\w+),\s*"((?:[^"\\]|\\.)*)"', tests):
        case(kind, "upstream:" + name, unescape(literal))
for name, left, right in re.findall(r'assert_order!\(\s*(\w+),\s*"([^"]*)",\s*\w+,\s*"([^"]*)"', tests):
    case("C", "upstream:" + name, left, right)

# 2. the corpus: versions of packages, requirements of dependencies
versions, requirements = set(), set()
def walk(node):
    if isinstance(node, dict):
        if isinstance(node.get("version"), str): versions.add(node["version"])
        for key in ("dependencies", "dev_dependencies"):
            deps = node.get(key)
            if isinstance(deps, dict):
                requirements.update(v for v in deps.values() if isinstance(v, str))
        for value in node.values(): walk(value)
    elif isinstance(node, list):
        for value in node: walk(value)
walk(json.load(open(corpus)))
for i, version in enumerate(sorted(versions)): case("V", f"corpus:version{i}", version)
for i, requirement in enumerate(sorted(requirements)): case("R", f"corpus:requirement{i}", requirement)

# 3. random: expressions that are mostly valid, and token soup
rng = random.Random(seed)
numbers = ["0", "1", "2", "3", "10", "007", "4294967295", "4294967296"]
words = ["rc1", "alpha", "beta-2", "0a", "x", "pre", "and", "or", "andy", "orc"]
def version():
    text = ".".join(rng.choice(numbers[:5]) for _ in range(rng.choice([3] * 60 + [2, 4, 1])))
    if rng.random() < 0.3: text += "-" + ".".join(rng.choice(numbers[:4] + words[:3]) for _ in range(rng.randint(1, 3)))
    return text
def build():
    return "+" + ".".join(rng.choice(numbers + words) for _ in range(rng.randint(1, 2))) if rng.random() < 0.15 else ""
operators = ["==", "!=", ">", "<", ">=", "<=", "~>", ""]
def constraint():
    operator = rng.choice(operators)
    if operator == "~>" and rng.random() < 0.5:
        return "~> " + rng.choice(numbers[:5]) + "." + rng.choice(numbers[:5])
    return operator + rng.choice([" ", " ", " ", "", "  "]) + version()
def expression():
    parts = []
    for i in range(rng.randint(1, 5)):
        if i: parts.append(rng.choice([" and ", " or "] * 8 + [" and", "or ", "  or  "]))
        parts.append(constraint())
    # build metadata swallows the rest of the input, so it can only come last
    return "".join(parts) + build()
soup = operators[:-1] + numbers + words + [".", ".", "-", "+", " ", " ", "\t", "\n", "é", "$", "=", "~", "!", "A9"]
for i in range(count):
    case("R", f"random:expression{i}", expression())
for i in range(count // 3):
    case("V", f"random:version{i}", rng.choice(["", "", "", " "]) + version() + build() + rng.choice(["", "", "", "", " ", " x"]))
for i in range(count // 3):
    case("R", f"random:soup{i}", "".join(rng.choice(soup) for _ in range(rng.randint(0, 8))))
    case("V", f"random:vsoup{i}", "".join(rng.choice(soup) for _ in range(rng.randint(0, 6))))
for i in range(count // 3):
    left = version()
    case("C", f"random:order{i}", left + build(), (left if rng.random() < 0.2 else version()) + build())
    case("T", f"random:contains{i}", expression(), version())
print("\n".join(out))
