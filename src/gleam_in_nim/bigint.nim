## Arbitrary precision integers: the part of Rust's `num-bigint` that the Gleam compiler uses.
##
## Upstream depends on the crate `num-bigint` for the integers of Gleam source (an `Int` literal
## can be of any size). The port uses only Nim's standard library, which has no such type, so this
## is a small module of ours (porting guide, ground rule 6). It is not a port of `num-bigint`:
## it has the same names and the same results for the operations listed here, and nothing else.
##
## What is here: making a `BigInt` from an `int64` or from text in a radix, the sign, the tests
## `isZero` and `isNegative`, negation, comparison, the conversions `toU8`, `toI32`, `toI64`,
## the bytes of the magnitude (`toBytesLe`, `toBytesBe`), `bits`, and `$` (decimal).
##
## What is not here yet: arithmetic between two big integers (add, subtract, multiply, divide).
## The step that first needs one adds it, with tests against Erlang or Rust.
import std/[options, strutils]

type
  Sign* = enum
    ## The order is num-bigint's: `Minus < NoSign < Plus`.
    Minus, NoSign, Plus
  BigInt* = object
    ## A sign and a magnitude. Zero is `NoSign` with no limbs.
    sign: Sign
    limbs: seq[uint32]  ## the magnitude in base 2^32, least significant first, no zero on top

func normalize(n: var BigInt) =
  while n.limbs.len > 0 and n.limbs[^1] == 0: n.limbs.setLen(n.limbs.len - 1)
  if n.limbs.len == 0: n.sign = NoSign

func mulAdd(limbs: var seq[uint32], factor, addend: uint32) =
  ## magnitude = magnitude * factor + addend
  var carry = uint64(addend)
  for limb in limbs.mitems:
    let x = uint64(limb) * uint64(factor) + carry
    limb = uint32(x and 0xFFFF_FFFF'u64)
    carry = x shr 32
  if carry > 0: limbs.add uint32(carry)

func divMod(limbs: var seq[uint32], divisor: uint32): uint32 =
  ## magnitude = magnitude div divisor; returns the remainder
  var rem = 0'u64
  for i in countdown(limbs.high, 0):
    let x = (rem shl 32) or uint64(limbs[i])
    limbs[i] = uint32(x div uint64(divisor))
    rem = x mod uint64(divisor)
  while limbs.len > 0 and limbs[^1] == 0: limbs.setLen(limbs.len - 1)
  uint32(rem)

func initBigInt*(value: int64): BigInt =
  ## `BigInt::from(value)`
  if value == 0: return BigInt(sign: NoSign)
  # the magnitude of low(int64) does not fit an int64: go through uint64
  let magnitude = if value < 0: (not cast[uint64](value)) + 1 else: uint64(value)
  result = BigInt(sign: if value < 0: Minus else: Plus,
                  limbs: @[uint32(magnitude and 0xFFFF_FFFF'u64), uint32(magnitude shr 32)])
  result.normalize

func zero*(_: typedesc[BigInt]): BigInt = BigInt(sign: NoSign)
func one*(_: typedesc[BigInt]): BigInt = initBigInt(1)

func parseBigInt*(text: string, radix = 10): Option[BigInt] =
  ## `BigInt::from_str_radix(text, radix)`, and `BigInt::from_str(text)` with the default radix:
  ## an optional `+` or `-`, then digits of the radix (2 to 36, letters in either case).
  ## As in num-bigint, underscores between digits are skipped, but the first character after the
  ## sign must be a digit. `none` when the text is not a number.
  doAssert radix in 2 .. 36
  var i = 0
  var sign = Plus
  if text.len > 0 and text[0] in {'+', '-'}:
    if text[0] == '-': sign = Minus
    i = 1
  if i >= text.len or text[i] == '_': return none(BigInt)
  var n = BigInt(sign: sign)
  while i < text.len:
    let c = text[i]
    inc i
    if c == '_': continue
    let digit = case c
      of '0' .. '9': ord(c) - ord('0')
      of 'a' .. 'z': ord(c) - ord('a') + 10
      of 'A' .. 'Z': ord(c) - ord('A') + 10
      else: return none(BigInt)
    if digit >= radix: return none(BigInt)
    n.limbs.mulAdd(uint32(radix), uint32(digit))
  n.normalize
  some(n)

func sign*(n: BigInt): Sign = n.sign
func isZero*(n: BigInt): bool = n.sign == NoSign
func isNegative*(n: BigInt): bool = n.sign == Minus
func isPositive*(n: BigInt): bool = n.sign == Plus

func `-`*(n: BigInt): BigInt =
  ## `n.neg()`
  result = n
  result.sign = case n.sign
    of Minus: Plus
    of NoSign: NoSign
    of Plus: Minus

func `==`*(a, b: BigInt): bool = a.sign == b.sign and a.limbs == b.limbs

func cmpMagnitude(a, b: BigInt): int =
  if a.limbs.len != b.limbs.len: return cmp(a.limbs.len, b.limbs.len)
  for i in countdown(a.limbs.high, 0):
    if a.limbs[i] != b.limbs[i]: return cmp(a.limbs[i], b.limbs[i])
  0

func cmp*(a, b: BigInt): int =
  if a.sign != b.sign: return cmp(ord(a.sign), ord(b.sign))
  case a.sign
  of NoSign: 0
  of Plus: cmpMagnitude(a, b)
  of Minus: cmpMagnitude(b, a)

func `<`*(a, b: BigInt): bool = cmp(a, b) < 0
func `<=`*(a, b: BigInt): bool = cmp(a, b) <= 0

func bits*(n: BigInt): uint64 =
  ## `n.bits()`: how many bits the magnitude needs. Zero needs none.
  if n.limbs.len == 0: return 0
  var top = n.limbs[^1]
  var topBits = 0'u64
  while top > 0:
    inc topBits
    top = top shr 1
  uint64(n.limbs.len - 1) * 32 + topBits

func toBytesLe*(n: BigInt): tuple[sign: Sign, bytes: seq[byte]] =
  ## `n.to_bytes_le()`: the sign, and the bytes of the magnitude, least significant first,
  ## with no zero byte on top. Zero is `(NoSign, [0])`, as in num-bigint.
  result.sign = n.sign
  for limb in n.limbs:
    for shift in [0, 8, 16, 24]: result.bytes.add byte((limb shr shift) and 0xFF)
  while result.bytes.len > 1 and result.bytes[^1] == 0: result.bytes.setLen(result.bytes.len - 1)
  if result.bytes.len == 0: result.bytes.add 0

func toBytesBe*(n: BigInt): tuple[sign: Sign, bytes: seq[byte]] =
  ## `n.to_bytes_be()`: as `toBytesLe`, most significant byte first.
  let le = n.toBytesLe
  result.sign = le.sign
  for i in countdown(le.bytes.high, 0): result.bytes.add le.bytes[i]

func toI64*(n: BigInt): Option[int64] =
  ## `n.to_i64()`: the value, when it fits.
  if n.limbs.len > 2: return none(int64)
  var magnitude = 0'u64
  for i in countdown(n.limbs.high, 0): magnitude = (magnitude shl 32) or uint64(n.limbs[i])
  if n.sign == Minus:
    if magnitude > uint64(high(int64)) + 1: none(int64)
    else: some(cast[int64]((not magnitude) + 1))
  elif magnitude > uint64(high(int64)): none(int64)
  else: some(int64(magnitude))

func toI32*(n: BigInt): Option[int32] =
  ## `n.to_i32()`
  let value = n.toI64
  if value.isSome and value.get >= int64(low(int32)) and value.get <= int64(high(int32)):
    some(int32(value.get))
  else: none(int32)

func toU8*(n: BigInt): Option[uint8] =
  ## `n.to_u8()`
  let value = n.toI64
  if value.isSome and value.get >= 0 and value.get <= 255: some(uint8(value.get))
  else: none(uint8)

func `$`*(n: BigInt): string =
  ## Decimal, with a `-` when negative: `n.to_string()`.
  if n.isZero: return "0"
  var limbs = n.limbs
  var chunks: seq[string]
  while limbs.len > 0:
    chunks.add $limbs.divMod(1_000_000_000)
  result = if n.sign == Minus: "-" else: ""
  result.add chunks[^1]
  for i in countdown(chunks.high - 1, 0): result.add align(chunks[i], 9, '0')
