## port-of: erlang-term-format/src/lib.rs
## port-status: conformant
##
## SPDX-License-Identifier: Apache-2.0
## SPDX-FileCopyrightText: 2026 The Gleam contributors
## Translated to Nim from Gleam v1.19.2 for the gleam-in-nim project.
import std/options
import bigint

type
  ListEnder* = object
    ## This is the index in the term builder buffer to where the number of
    ## elements in the list is written. When we start a list the number is
    ## zeroed as we may not know the number of elements yet, and it is
    ## written when finishing the list using this index.
    sizeIndex: int

    # Upstream has a second field, `used`, compiled only in debug builds: its `Drop`
    # implementation asserts that every list that was started was also ended. Nim has no
    # equivalent that may safely fail (a destructor must not raise), and the check changes no
    # output, so it is left out. Forgetting `endList` shows up at once anyway: the length of the
    # list stays zero and Erlang refuses the term.

proc newListEnder*(sizeIndex: int): ListEnder =
  ListEnder(sizeIndex: sizeIndex)

proc consume*(self: ListEnder) = discard

## The first byte of ETF data is this version number.
##
const erlangTermFormatVersionNumber: uint8 = 131

type
  TermBuilder* = object
    ## A data structure used to encode values into the Erlang Term Format:
    ## https://www.erlang.org/doc/apps/erts/erl_ext_dist.html.
    ##
    bytes: seq[uint8]

proc newTermBuilder*(): TermBuilder =
  TermBuilder(bytes: @[erlangTermFormatVersionNumber])

proc intoVec*(self: TermBuilder): seq[uint8] =
  ## Get the binary representation of the data structure built so far.
  self.bytes

proc push(self: var TermBuilder, byte: uint8) =
  self.bytes.add byte

proc extend(self: var TermBuilder, bytes: openArray[uint8]) =
  self.bytes.add bytes

proc toBeBytes(value: uint32): array[4, uint8] =
  [uint8(value shr 24), uint8((value shr 16) and 0xFF), uint8((value shr 8) and 0xFF), uint8(value and 0xFF)]

proc toBeBytes(value: int32): array[4, uint8] = toBeBytes(cast[uint32](value))

proc toBeBytes(value: uint16): array[2, uint8] =
  [uint8(value shr 8), uint8(value and 0xFF)]

proc toBeBytes(value: float64): array[8, uint8] =
  let bits = cast[uint64](value)
  for i in 0 .. 7: result[i] = uint8((bits shr (56 - 8 * i)) and 0xFF)

proc rawByte*(self: var TermBuilder, byte: uint8) =
  ## Pushes a single raw byte.
  ##
  self.push(byte)

# The procs upstream keeps private are declared first here, because Nim wants a proc declared
# before its use. They are the same procs, in upstream's order within each group.

proc smallInteger(self: var TermBuilder, value: uint8) =
  ## https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#small_integer_ext
  self.push(97)
  self.push(value)

proc integer(self: var TermBuilder, value: int32) =
  ## https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#integer_ext
  self.push(98)
  self.extend(value.toBeBytes)

proc smallBig(self: var TermBuilder, number: BigInt) =
  ## https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#small_big_ext
  let (sign, bytes) = number.toBytesLe
  self.push(110)
  # `bytes.len() as u8` upstream: the length is cut to its low byte, not checked.
  self.push(uint8(bytes.len and 0xFF))
  case sign
  of NoSign, Plus: self.push(0)
  of Minus: self.push(1)
  self.extend(bytes)

proc smallAtomUtf8(self: var TermBuilder, name: string) =
  ## https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#small_atom_utf8_ext
  self.push(119)
  self.push(uint8(name.len and 0xFF))
  self.extend(name.toOpenArrayByte(0, name.high))

proc atomUtf8(self: var TermBuilder, name: string) =
  ## https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#atom_utf8_ext
  self.push(118)
  self.extend(toBeBytes(uint16(name.len and 0xFFFF)))
  self.extend(name.toOpenArrayByte(0, name.high))

proc emptyList*(self: var TermBuilder) =
  ## https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#nil_ext
  self.push(106)

proc startList*(self: var TermBuilder): ListEnder =
  ## Start building a list with a number of item that is not known in
  ## advance.
  ##
  ## Once you've then pushed all the items, you _must_ complete the list by
  ## calling `end_list` with the number of items that were pushed.
  ##
  ## ```txt
  ## // [1, 2, 3]
  ## let list = etf.start_list()
  ## etf.small_integer(1);
  ## etf.small_integer(2);
  ## etf.small_integer(3);
  ## etf.end_list(list, 3)
  ## ```
  ##
  ## https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#list_ext
  self.push(108)
  let sizeIndex = self.bytes.len

  # These 4 bytes store the number of elements (not including the tail).
  # They are set to zero here, and the `end_list` function overwrites them
  # with the actual length, as that number may not be known in advance.
  self.push(0)
  self.push(0)
  self.push(0)
  self.push(0)

  newListEnder(sizeIndex)

proc endList*(self: var TermBuilder, list: ListEnder, numberOfElement: uint32) =
  self.emptyList()
  self.bytes[list.sizeIndex ..< list.sizeIndex + 4] = numberOfElement.toBeBytes
  list.consume()

proc atom*(self: var TermBuilder, atom: string) =
  ## Pushes the most compact representation of the given atom.
  # TODO: we could explore using ATOM_CACHE_REF in future.
  # Might be able to get slightly faster ETF parsing out of erlc if we
  # use it:
  # https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#atom_cache_ref
  if atom.len <= 255:
    self.smallAtomUtf8(atom)
  else:
    self.atomUtf8(atom)

proc bigint*(self: var TermBuilder, value: BigInt) =
  ## Pushes the most compact representation of the given big int.
  if (let v = value.toU8; v.isSome):
    self.smallInteger(v.get)
  elif (let v = value.toI32; v.isSome):
    self.integer(v.get)
  else:
    self.smallBig(value)

proc usize*(self: var TermBuilder, value: uint) =
  ## Pushes the most compact representation of the given usize int.
  ##
  if value <= 255:
    self.smallInteger(uint8(value))
  else:
    # `value as i32` upstream: the low 32 bits, reinterpreted.
    self.integer(cast[int32](uint32(value and 0xFFFF_FFFF'u)))

proc newFloat*(self: var TermBuilder, value: float64) =
  ## https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#new_float_ext
  self.push(70)
  self.extend(value.toBeBytes)

proc smallTuple*(self: var TermBuilder, arity: uint8) =
  ## https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#small_tuple_ext
  self.push(104)
  self.push(arity)

proc largeTuple*(self: var TermBuilder, arity: uint32) =
  ## https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#large_tuple_ext
  self.push(105)
  self.extend(arity.toBeBytes)

proc binary*(self: var TermBuilder, bytesCount: uint32, bytes: openArray[uint8]) =
  ## https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#binary_ext
  self.push(109)
  self.extend(bytesCount.toBeBytes)
  self.extend(bytes)

proc largeBig*(self: var TermBuilder, number: BigInt) =
  ## https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#large_big_ext
  let (sign, bytes) = number.toBytesLe
  self.push(111)
  self.extend(toBeBytes(uint32(bytes.len)))
  case sign
  of NoSign, Plus: self.push(0)
  of Minus: self.push(1)
  self.extend(bytes)
