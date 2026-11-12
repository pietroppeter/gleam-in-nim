## port-part-of: compiler-core/src/parse.rs
## (only a part of that file is ported so far: when the rest is, this becomes `port-of` with a `port-status`)
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2020 The Gleam contributors
# Ported to Nim from gleam-lang/gleam v1.19.2 (commit ed41eace), compiler-core/src/parse.rs.

## Values of number literals.
##
## Upstream these live in `parse.rs`, next to the parser. They are split out
## here because the lexer needs them and Nim modules cannot import each other
## in a cycle.

import std/[options, strutils]
import pkg/bigints

type LiteralFloatValue* = distinct float
  ## The value of a float literal: an `f64` that is never NaN, so it can be
  ## compared for equality. Upstream `LiteralFloatValue(f64)`.

func value*(self: LiteralFloatValue): float =
  float(self)

func `==`*(a, b: LiteralFloatValue): bool {.borrow.}

func parseIntValue*(value: string): Option[BigInt] =
  ## Parses an Int value to a bigint.
  var radix = 10
  var digits = value
  if value.startsWith("0x"):
    radix = 16
    digits = value[2 .. ^1]
  elif value.startsWith("0o"):
    radix = 8
    digits = value[2 .. ^1]
  elif value.startsWith("0b"):
    radix = 2
    digits = value[2 .. ^1]
  digits = digits.strip(leading = true, trailing = false, chars = {'_'})

  # What follows is what `BigInt::parse_bytes` of num-bigint accepts: an
  # optional sign, then digits that may be separated (not led) by underscores.
  var negative = false
  if digits.startsWith("-"):
    negative = true
    digits = digits[1 .. ^1]
  elif digits.startsWith("+"):
    digits = digits[1 .. ^1]
  if digits.len == 0 or digits[0] == '_':
    return none(BigInt)
  var clean = newStringOfCap(digits.len)
  for c in digits:
    if c == '_':
      continue
    let digit =
      case c
      of '0' .. '9': ord(c) - ord('0')
      of 'a' .. 'z': ord(c) - ord('a') + 10
      of 'A' .. 'Z': ord(c) - ord('A') + 10
      else: 99
    if digit >= radix:
      return none(BigInt)
    clean.add c
  var parsed = initBigInt(clean, radix)
  if negative:
    parsed = -parsed
  some(parsed)

const powersOfTen = [
  1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15,
  1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
]

func decimalToFloat(digits: string, exponent: int): float =
  ## The float nearest to `digits * 10^exponent`, ties to even, like Rust's
  ## `f64::from_str`. `digits` are decimal digits without leading zeros.
  ##
  ## Short literals take the classic fast path: a mantissa below 2^53 and a
  ## power of ten up to 10^22 are both exact floats, so one multiplication or
  ## division rounds once, correctly. Everything else is done exactly with
  ## big integers, which is slow and always right.
  if digits.len == 0:
    return 0.0
  if digits.len <= 15 and abs(exponent) <= 22:
    var mantissa = 0'u64
    for c in digits:
      mantissa = mantissa * 10 + uint64(ord(c) - ord('0'))
    return
      if exponent < 0:
        float(mantissa) / powersOfTen[-exponent]
      else:
        float(mantissa) * powersOfTen[exponent]
  # The value is in [10^(magnitude-1), 10^magnitude).
  let magnitude = digits.len + exponent
  if magnitude > 310:
    return Inf
  if magnitude < -325:
    return 0.0

  # value = numerator / denominator
  var numerator = initBigInt(digits)
  var denominator = initBigInt(1)
  if exponent >= 0:
    numerator = numerator * pow(initBigInt(10), exponent)
  else:
    denominator = pow(initBigInt(10), -exponent)

  # Find the binary exponent that leaves a 53 bit quotient, but not below
  # -1074, where subnormals live and the quotient simply has fewer bits.
  var binaryExponent = fastLog2(numerator) - fastLog2(denominator) - 52
  var quotient, remainder: BigInt
  while true:
    binaryExponent = max(binaryExponent, -1074)
    let scaledNumerator =
      if binaryExponent < 0: numerator shl -binaryExponent else: numerator
    let scaledDenominator =
      if binaryExponent > 0: denominator shl binaryExponent else: denominator
    (quotient, remainder) = divmod(scaledNumerator, scaledDenominator)
    let bits = if quotient == initBigInt(0): 0 else: fastLog2(quotient) + 1
    if bits > 53:
      binaryExponent += 1
    elif bits < 53 and binaryExponent > -1074:
      binaryExponent -= 1
    else:
      # Round half to even.
      let twice = remainder shl 1
      var mantissa = quotient.toInt[:uint64].get
      if twice > scaledDenominator or (twice == scaledDenominator and (mantissa and 1) == 1):
        mantissa += 1
      if mantissa == 1'u64 shl 53:
        mantissa = 1'u64 shl 52
        binaryExponent += 1
      if binaryExponent + 52 > 1023:
        return Inf
      if mantissa < 1'u64 shl 52:
        # Subnormal (or zero): the mantissa is the bit pattern.
        return cast[float](mantissa)
      let biased = uint64(binaryExponent + 52 + 1023)
      return cast[float]((biased shl 52) or (mantissa - (1'u64 shl 52)))

func parseLiteralFloat*(value: string): Option[float] =
  ## Upstream `LiteralFloatValue::parse`: the value of a float literal, or
  ## none if it is not a valid float or is NaN. Underscores are ignored.
  ##
  ## This accepts what Rust's `f64::from_str` accepts, and rounds the same
  ## way. It does not use Nim's `parseFloat`, which is wrong for very long
  ## exponents and mantissas.
  let text = value.replace("_", "")
  var i = 0
  var negative = false
  if i < text.len and text[i] in {'+', '-'}:
    negative = text[i] == '-'
    inc i
  let word = text[i .. ^1].toLowerAscii
  if word == "inf" or word == "infinity":
    return some(if negative: -Inf else: Inf)

  # Mantissa: digits, with at most one dot.
  var digits = ""
  var exponent = 0
  var sawDigit = false
  var sawDot = false
  while i < text.len:
    let c = text[i]
    if c in {'0' .. '9'}:
      sawDigit = true
      if sawDot:
        dec exponent
      if digits.len > 0 or c != '0':
        digits.add c
    elif c == '.' and not sawDot:
      sawDot = true
    else:
      break
    inc i
  if not sawDigit:
    return none(float)

  # Exponent, saturating: beyond a billion the result is zero or infinity
  # however long the mantissa is, because sources are far shorter than that.
  if i < text.len and text[i] in {'e', 'E'}:
    inc i
    var exponentNegative = false
    if i < text.len and text[i] in {'+', '-'}:
      exponentNegative = text[i] == '-'
      inc i
    if i >= text.len:
      return none(float)
    var written = 0
    while i < text.len and text[i] in {'0' .. '9'}:
      if written < 1_000_000_000:
        written = written * 10 + (ord(text[i]) - ord('0'))
      inc i
    exponent += (if exponentNegative: -written else: written)
  if i != text.len:
    return none(float)

  # Trailing zeros of the mantissa belong to the exponent.
  var trailing = 0
  while trailing < digits.len and digits[digits.high - trailing] == '0':
    inc trailing
  digits.setLen(digits.len - trailing)
  exponent += trailing

  let magnitude = decimalToFloat(digits, exponent)
  some(if negative: -magnitude else: magnitude)
