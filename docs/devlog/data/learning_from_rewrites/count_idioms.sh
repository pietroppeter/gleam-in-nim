#!/bin/sh
# Counts lines of compiler-core (tests left out) that use a Rust idiom, at the pinned Gleam.
#   sh count_idioms.sh /path/to/gleam > rust_idioms.tsv
# Columns: idiom, lines, what it becomes in Nim.
cd "$1/compiler-core/src" || exit 1
count() { grep -rE "$1" --include=*.rs . | grep -v '/tests' | wc -l | tr -d ' '; }
row() { printf '%s\t%s\t%s\n' "$1" "$(count "$2")" "$3"; }
row 'match'                'match '                         'case on the kind of an object variant'
row '.clone()'             '\.clone\(\)'                    'nothing for a ref, a plain copy for a value'
row 'SrcSpan'              'SrcSpan'                        'the same small object of two uint32'
row 'EcoString'            'EcoString'                      'string'
row "lifetimes (<'a)"      "<'a"                            'nothing: the garbage collector keeps things alive'
row 'if let, let else'     'if let |let .* else'            'if with isSome, or case'
row '? (early return)'     '\?;'                            'the error convention of the porting guide'
row '#[derive]'            '#\[derive'                      'mostly free in Nim; == and hash by hand for refs'
row 'Arc<T>'               'Arc<'                           'ref object'
row 'HashMap'              'HashMap'                        'Table'
row 'enum'                 '^\s*(pub )?enum '               'enum, or object variant when it carries data'
row 'struct'               '^\s*(pub )?struct '             'object'
row 'Box<T>'               'Box<'                           'ref object'
row 'RefCell'              'RefCell'                        'a ref with fields that change'
row 'trait'                '^\s*(pub )?trait '              'procs, or methods when there are several types'
row 'dyn'                  'dyn '                           'methods or a proc value'
row 'async, await'         'async |\.await'                 'plain calls (only the build tool is async)'
row 'unsafe'               'unsafe'                         'nothing'
