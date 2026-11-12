## Rust's pretty Debug format (`{:#?}`), for Nim values.
##
## This is not a port of a file: it stands in for `#[derive(Debug)]`. Upstream's
## parser tests are snapshots of the syntax tree printed with `{:#?}`, and the
## parser oracle (tests/differential/parse) prints the same, so the Nim tree
## must print byte for byte like the Rust one to be compared with either.
##
## `debugRepr(x)` works on any value built by the conventions of the porting
## guide, without code per type:
##
## - an `object` prints as a Rust struct, `Name { field: value, ... }`, with the
##   field names turned back to `snake_case` (and the few renamed ones, such as
##   `stop`, turned back to `end`);
## - an object with a `case kind` prints as a Rust enum: the variant is the
##   enum value without its lowercase prefix; its one field is the payload. A
##   payload whose type is named after the enum and the variant
##   (`UntypedExprInt`) is a struct variant, `Int { ... }`; any other payload is
##   a tuple variant, `Function(...)`;
## - a plain `enum` value prints without its lowercase prefix;
## - `seq` is `[...]`, `Option` is `Some(...)` or `None`, a tuple is `(...)`,
##   a `ref` prints as what it points to (a `Box`), `Unit` is `()`.

import std/[macros, options, sets, strutils, unicode, tables, typetraits]
import pkg/bigints
import ./[rust_debug_tables, rust_enum]
export rust_enum


const renamedFields* = {
  # Nim field name, Rust field name: the names that could not be kept.
  "stop": "end",
  "typ": "type_",
  "returns": "return_",
  "tupl": "tuple",
}.toTable

func snakeCase*(name: string): string =
  ## `bodyStart` to `body_start`.
  for c in name:
    if c in {'A' .. 'Z'}:
      result.add '_'
      result.add c.toLowerAscii
    else:
      result.add c

func rustFieldName*(name: string): string =
  renamedFields.getOrDefault(name, snakeCase(name))

func withoutPrefix*(name: string): string =
  ## `ueInt` to `Int`: an enum value without its lowercase prefix.
  var i = 0
  while i < name.len and name[i] in {'a' .. 'z'}:
    inc i
  if i < name.len: name[i .. ^1] else: name

func baseName(name: string): string =
  ## `Function[Unit, UntypedExpr]` to `Function`, `ref Foo` to `Foo`.
  result = name
  let bracket = result.find('[')
  if bracket >= 0:
    result = result[0 ..< bracket]
  if result.startsWith("ref "):
    result = result[4 .. ^1]
  let dot = result.rfind('.')
  if dot >= 0:
    result = result[dot + 1 .. ^1]

func isEscaped(c: int32): bool =
  ## Whether Rust's Debug writes this code point as `\u{..}`: it is not
  ## printable, or it extends the grapheme before it. The table is Rust's own
  ## answer for every code point (see rust_debug_tables.nim).
  var
    low = 0
    high = escapedRanges.len
  while low < high:
    let mid = (low + high) div 2
    if c < escapedRanges[mid].first: high = mid
    elif c > escapedRanges[mid].last: low = mid + 1
    else: return true
  false

func rustString*(s: string): string =
  ## A string as Rust's Debug prints it.
  result = "\""
  for rune in s.runes:
    let c = int32(rune)
    case c
    of ord('"'): result.add "\\\""
    of ord('\\'): result.add "\\\\"
    of ord('\n'): result.add "\\n"
    of ord('\r'): result.add "\\r"
    of ord('\t'): result.add "\\t"
    of 0: result.add "\\0"
    else:
      if not isEscaped(c):
        result.add $rune
      else:
        result.add "\\u{" & toHex(c).strip(leading = true, trailing = false, chars = {'0'}).toLowerAscii & "}"
  result.add '"'

func rustChar*(c: Rune): string =
  ## A character as Rust's Debug prints it.
  let code = int32(c)
  result = "'"
  case code
  of ord('\''): result.add "\\'"
  of ord('\\'): result.add "\\\\"
  of ord('\n'): result.add "\\n"
  of ord('\r'): result.add "\\r"
  of ord('\t'): result.add "\\t"
  of 0: result.add "\\0"
  else:
    if not isEscaped(code):
      result.add $c
    else:
      result.add "\\u{" & toHex(code).strip(leading = true, trailing = false, chars = {'0'}).toLowerAscii & "}"
  result.add '\''

func shortestDigits(x: float): tuple[digits: string, pointPosition: int] =
  ## The shortest decimal digits that read back as `x` (positive, finite), and
  ## where the decimal point goes: the value is `0.DIGITS * 10^pointPosition`.
  ##
  ## This follows Rust's `core::num::flt2dec::strategy::dragon::format_shortest`
  ## step by step, with big integers: Nim's `$` also gives shortest digits, but
  ## it breaks a tie between two candidates the other way (2^-25 is
  ## `2.9802322387695313e-8` for Rust and `...312e-8` for Nim).
  let bits = cast[uint64](x)
  let fraction = bits and ((1'u64 shl 52) - 1)
  let biased = int((bits shr 52) and 0x7FF)
  # x = mant * 2^exp, between (mant - minus) * 2^exp and (mant + plus) * 2^exp
  var mantissa: uint64
  var exp: int
  var plusValue = 1
  if biased == 0:
    # subnormal: Rust's `integer_decode` gives the fraction shifted by one
    mantissa = fraction shl 1
    exp = -1075
  elif fraction == 0:
    # the smallest mantissa of its exponent: the float below is closer
    mantissa = (1'u64 shl 52) shl 2
    exp = biased - 1075 - 2
    plusValue = 2
  else:
    mantissa = (fraction or (1'u64 shl 52)) shl 1
    exp = biased - 1075 - 1
  let inclusive = (fraction and 1) == 0

  let ten = initBigInt(10)
  var
    mant = initBigInt(mantissa)
    minus = initBigInt(1)
    plus = initBigInt(plusValue)
    scale = initBigInt(1)
  if exp < 0:
    scale = scale shl (-exp)
  else:
    mant = mant shl exp
    minus = minus shl exp
    plus = plus shl exp

  # k: the smallest power of ten above the upper bound (or on it, when the
  # bound is not part of the interval). Rust estimates it, then fixes it up.
  func outside(scale, high: BigInt, inclusive: bool): bool =
    if inclusive: scale <= high else: scale < high
  var k = 0
  let high = mant + plus
  # value = mant / scale; divide by 10^k: scale *= 10^k (k > 0) or mant *= 10^-k
  var scaled = scale
  while outside(scaled, high, inclusive):
    scaled = scaled * ten
    inc k
  if k == 0:
    # go down while one power of ten less is still above the bound
    var factor = ten
    while not outside(scale, high * factor, inclusive):
      factor = factor * ten
      dec k
    # the loop stops at the first power that is too small: `factor` is 10^(-k + 1)
    let shift = factor div ten
    mant = mant * shift
    minus = minus * shift
    plus = plus * shift
  else:
    scale = scaled
  # now 0.1 <= (mant + plus) / scale < 1 (roughly): produce the digits of mant / scale
  var digits = ""
  var down, up: bool
  while true:
    mant = mant * ten
    minus = minus * ten
    plus = plus * ten
    let digit = mant div scale
    mant = mant mod scale
    digits.add $digit
    down = if inclusive: mant <= minus else: mant < minus
    up = if inclusive: scale <= mant + plus else: scale < mant + plus
    if down or up:
      break
  # rounding up happens when only the rounding-up condition was triggered, or
  # both were and the tie breaking prefers rounding up.
  if up and (not down or mant * initBigInt(2) >= scale):
    var i = digits.high
    while i >= 0 and digits[i] == '9':
      digits[i] = '0'
      dec i
    if i >= 0:
      digits[i] = chr(ord(digits[i]) + 1)
    else:
      digits = "1" & digits[0 ..< digits.high]
      inc k
  (digits, k)

func rustFloat*(x: float): string =
  ## A float as Rust's Debug prints it: the shortest digits that round trip,
  ## always with a fraction, in exponent form below 1e-4 and from 1e16.
  if x != x:
    return "NaN"
  if x == Inf:
    return "inf"
  if x == -Inf:
    return "-inf"
  if x == 0.0:
    return (if 1.0 / x < 0: "-0.0" else: "0.0")
  # `digits` is d.ddd * 10^exponent
  let (digits, pointPosition) = shortestDigits(abs(x))
  let exponent = pointPosition - 1
  let magnitude = abs(x)
  var body: string
  if magnitude < 1e-4 or magnitude >= 1e16:
    body = digits[0 .. 0]
    if digits.len > 1:
      body.add "." & digits[1 .. ^1]
    body.add "e" & $exponent
  elif exponent < 0:
    body = "0." & repeat('0', -exponent - 1) & digits
  elif digits.len <= exponent + 1:
    body = digits & repeat('0', exponent + 1 - digits.len) & ".0"
  else:
    body = digits[0 .. exponent] & "." & digits[exponent + 1 .. ^1]
  (if x < 0: "-" else: "") & body

macro isVariantObject(T: typedesc): bool =
  ## Whether an object type has a `case` part.
  var impl = getTypeImpl(T)
  if impl.kind == nnkBracketExpr and impl.len == 2: # typedesc[T]
    impl = getTypeImpl(impl[1])
  while impl.kind == nnkRefTy:
    impl = getTypeImpl(impl[0])
  if impl.kind != nnkObjectTy:
    return newLit(false)
  for node in impl[2]:
    if node.kind == nnkRecCase:
      return newLit(true)
  newLit(false)

const step = "    "

proc debugFmt*[T](x: T, indent: string, into: var string)

proc fmtStruct[T](x: T, name: string, indent: string, into: var string) =
  ## `Name { field: value, ... }`, or `Name` when there are no fields.
  var any = false
  for fieldName, value in fieldPairs(x):
    if not any:
      into.add name & " {\n"
      any = true
    into.add indent & step & rustFieldName(fieldName) & ": "
    debugFmt(value, indent & step, into)
    into.add ",\n"
  if any:
    into.add indent & "}"
  else:
    into.add name

proc debugFmt*[T](x: T, indent: string, into: var string) =
  mixin rustDebugHook
  when compiles(rustDebugHook(x, indent, into)):
    # A type that does not follow the conventions prints itself: a module
    # defines `rustDebugHook(x: ItsType, indent: string, into: var string)`.
    rustDebugHook(x, indent, into)
  elif T is Unit:
    into.add "()"
  elif T is Table or T is HashSet:
    # Only the empty ones are needed so far: the parser leaves them empty.
    doAssert x.len == 0, "debugFmt: a map or set with items is not supported yet"
    into.add "{}"
  elif T is string:
    into.add rustString(x)
  elif T is bool:
    into.add (if x: "true" else: "false")
  elif T is BigInt:
    into.add $x
  elif T is SomeInteger:
    into.add $x
  elif T is SomeFloat:
    into.add rustFloat(x)
  elif T is distinct:
    # a tuple struct with one field: `LiteralFloatValue(1.0)`
    into.add baseName($T) & "(\n" & indent & step
    debugFmt(distinctBase(x), indent & step, into)
    into.add ",\n" & indent & ")"
  elif T is enum:
    into.add withoutPrefix($x)
  elif T is Option:
    if x.isSome:
      into.add "Some(\n" & indent & step
      debugFmt(x.get, indent & step, into)
      into.add ",\n" & indent & ")"
    else:
      into.add "None"
  elif T is seq or T is array:
    if x.len == 0:
      into.add "[]"
    else:
      into.add "[\n"
      for item in x:
        into.add indent & step
        debugFmt(item, indent & step, into)
        into.add ",\n"
      into.add indent & "]"
  elif T is ref:
    doAssert not x.isNil, "a nil ref in a tree: use Option for none"
    debugFmt(x[], indent, into)
  elif T is tuple:
    into.add "(\n"
    for value in fields(x):
      into.add indent & step
      debugFmt(value, indent & step, into)
      into.add ",\n"
    into.add indent & ")"
  elif T is object:
    const typeName = baseName($T)
    when isVariantObject(T):
      # A Rust enum: the first field is the kind, the next (if any) the payload.
      var variant = ""
      var hasPayload = false
      for fieldName, value in fieldPairs(x):
        when fieldName == "kind":
          variant = withoutPrefix($value)
        else:
          hasPayload = true
          when value is StructVariant:
            # struct variant: `Int { ... }`
            fmtStruct(value, variant, indent, into)
          elif value is ref StructVariant:
            fmtStruct(value[], variant, indent, into)
          else:
            # tuple variant: `Function(...)`
            into.add variant & "(\n" & indent & step
            debugFmt(value, indent & step, into)
            into.add ",\n" & indent & ")"
      if not hasPayload:
        into.add variant
    else:
      fmtStruct(x, typeName, indent, into)
  else:
    {.error: "debugFmt: unsupported type " & $T.}

proc debugRepr*[T](x: T): string =
  ## `x` as Rust's `{:#?}` would print the value it mirrors.
  debugFmt(x, "", result)
