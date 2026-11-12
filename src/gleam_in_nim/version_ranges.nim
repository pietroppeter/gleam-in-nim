# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: The pubgrub-rs contributors
#
# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at https://mozilla.org/MPL/2.0/.
#
# Not a port of a Gleam file. Ported to Nim from the Rust crate version-ranges
# 0.1.3 (src/lib.rs; the pubgrub-rs contributors, MPL-2.0), the version in the
# lock file of the reference compiler, which uses it through the pubgrub crate
# (`pubgrub::Range`).
# https://github.com/pubgrub-rs/pubgrub/tree/main/version-ranges
#
# This file is a translation of that file and keeps its licence, the MPL-2.0,
# unlike the rest of this repository, which is Apache-2.0 (decision 0011; the
# text of the licence is in LICENSES/MPL-2.0.txt).
#
# What differs from the crate: no serde and no proptest parts; `from_iter` is
# `fromIntervals`, `from_range_bounds` takes its two bounds, and `simplify` and
# `contains_many` take a sequence where the crate takes an iterator.

## This module contains a type for generic version ranges and operations on
## them.
##
## `Ranges` can represent version selectors such as `(>=1, <2) OR (==3) OR
## (>4)`. Internally, it is an ordered list of contiguous intervals (segments)
## with inclusive, exclusive or open-ended ends, similar to a
## `seq[(Bound[V], Bound[V])]`.
##
## You can construct a basic range from one of the following build blocks. All
## other ranges are concatenation, union, and complement of these basic ranges.
##  - `empty()`: No version
##  - `full()`: All versions
##  - `singleton(v)`: Only the version v exactly
##  - `higherThan(v)`: All versions `v <= versions`
##  - `strictlyHigherThan(v)`: All versions `v < versions`
##  - `lowerThan(v)`: All versions `versions <= v`
##  - `strictlyLowerThan(v)`: All versions `versions < v`
##  - `between(v1, v2)`: All versions `v1 <= versions < v2`
##
## `Ranges` is generic over any type that has `cmp`, `<`, `<=` and `==` and can
## represent all kinds of slices with ordered coordinates, not just version
## ranges.
##
## Note that there are limitations to the equality implementation: Given a
## `Ranges[uint32]`, the segments `(Unbounded, Included(42))` and
## `(Included(0), Included(42))` as well as `(Included(1), Included(5))` and
## `(Included(1), Included(3)) + (Included(4), Included(5))` are reported as
## unequal, even though the match the same versions: We can't tell that there
## isn't a version between `0` and `-inf` or `3` and `4` respectively.
##
## In the port: Rust tells two comparisons apart, `Ord` (`<`, `cmp`) and `Eq`
## (`==`), and so does this module, because Gleam's `Version` gives them
## different meanings (the order ignores the build metadata, the equality does
## not). Each `==` and each `<` below is the one upstream uses at that place.

import std/[options, hashes]

type
  BoundKind* = enum
    ## An endpoint of a range: Rust's `std::ops::Bound`.
    bkIncluded
    bkExcluded
    bkUnbounded

  Bound*[V] = object
    case kind*: BoundKind
    of bkIncluded:
      vIncluded*: V
    of bkExcluded:
      vExcluded*: V
    of bkUnbounded:
      discard

  Interval*[V] = tuple[start, stop: Bound[V]]

  Ranges*[V] = object
    ## Ranges represents multiple intervals of a continuous range of
    ## monotone increasing values.
    ##
    ## Internally, `Ranges` are an ordered list of segments, where segment is
    ## a bounds pair.
    ##
    ## Invariants:
    ## 1. The segments are sorted, from lowest to highest (through `cmp`).
    ## 2. Each segment contains at least one version (start < end).
    ## 3. There is at least one version between two segments.
    ##
    ## These ensure that equivalent instances have an identical
    ## representation, which is important for `==` and `hash`. Note that this
    ## representation cannot strictly guaranty equality of `Ranges` with
    ## equality of its representation without also knowing the nature of the
    ## underlying versions. In particular, if the version space is discrete,
    ## different representations, using different types of bounds
    ## (exclusive/inclusive), can be equal. Such problems must be taken care
    ## of externally through the method `contains`.
    segments: seq[Interval[V]]

func included*[V](value: V): Bound[V] = Bound[V](kind: bkIncluded, vIncluded: value)
func excluded*[V](value: V): Bound[V] = Bound[V](kind: bkExcluded, vExcluded: value)

func value*[V](bound: Bound[V]): V =
  ## The version of a bound that has one, whichever its kind.
  case bound.kind
  of bkIncluded: bound.vIncluded
  of bkExcluded: bound.vExcluded
  of bkUnbounded: raiseAssert "an unbounded bound has no value"
func unbounded*[V](): Bound[V] = Bound[V](kind: bkUnbounded)

func `==`*[V](left, right: Bound[V]): bool =
  if left.kind != right.kind:
    return false
  case left.kind
  of bkIncluded, bkExcluded: left.value == right.value
  of bkUnbounded: true

func hash*[V](bound: Bound[V]): Hash =
  case bound.kind
  of bkIncluded, bkExcluded: !$(hash(ord(bound.kind)) !& hash(bound.value))
  of bkUnbounded: !$hash(ord(bound.kind))

func `==`*[V](left, right: Ranges[V]): bool =
  left.segments == right.segments

func hash*[V](ranges: Ranges[V]): Hash =
  hash(ranges.segments)

func empty*[V](): Ranges[V] =
  ## Empty set of versions.
  Ranges[V](segments: @[])

func full*[V](): Ranges[V] =
  ## Set of all possible versions
  Ranges[V](segments: @[(unbounded[V](), unbounded[V]())])

func higherThan*[V](v: V): Ranges[V] =
  ## Set of all versions higher or equal to some version
  Ranges[V](segments: @[(included(v), unbounded[V]())])

func strictlyHigherThan*[V](v: V): Ranges[V] =
  ## Set of all versions higher to some version
  Ranges[V](segments: @[(excluded(v), unbounded[V]())])

func strictlyLowerThan*[V](v: V): Ranges[V] =
  ## Set of all versions lower to some version
  Ranges[V](segments: @[(unbounded[V](), excluded(v))])

func lowerThan*[V](v: V): Ranges[V] =
  ## Set of all versions lower or equal to some version
  Ranges[V](segments: @[(unbounded[V](), included(v))])

func between*[V](v1, v2: V): Ranges[V] =
  ## Set of versions greater or equal to `v1` but less than `v2`.
  Ranges[V](segments: @[(included(v1), excluded(v2))])

func isEmpty*[V](self: Ranges[V]): bool =
  ## Whether the set is empty, i.e. it has not ranges
  self.segments.len == 0

func singleton*[V](v: V): Ranges[V] =
  ## Set containing exactly one version
  Ranges[V](segments: @[(included(v), included(v))])

func negateSegments[V](start: Bound[V], segments: openArray[Interval[V]]): Ranges[V] =
  ## Helper function performing the negation of intervals in segments.
  var complementSegments: seq[Interval[V]] = @[]
  var start = start
  for (v1, v2) in segments.items:
    complementSegments.add (
      start,
      (case v1.kind
       of bkIncluded: excluded(v1.value)
       of bkExcluded: included(v1.value)
       of bkUnbounded: raiseAssert "unreachable")
    )
    start =
      case v2.kind
      of bkIncluded: excluded(v2.value)
      of bkExcluded: included(v2.value)
      of bkUnbounded: unbounded[V]()
  if start.kind != bkUnbounded:
    complementSegments.add (start, unbounded[V]())

  Ranges[V](segments: complementSegments)

func complement*[V](self: Ranges[V]): Ranges[V] =
  ## Returns the complement, which contains everything not included in `self`.
  if self.segments.len == 0:
    # Complement of ∅ is ∞
    return full[V]()
  let (start, stop) = self.segments[0]
  case start.kind
  of bkUnbounded:
    case stop.kind
    # Complement of ∞ is ∅
    of bkUnbounded: empty[V]()
    of bkIncluded: negateSegments(excluded(stop.value), self.segments.toOpenArray(1, self.segments.high))
    of bkExcluded: negateSegments(included(stop.value), self.segments.toOpenArray(1, self.segments.high))
  of bkIncluded:
    case stop.kind
    # First high bound is +∞
    of bkUnbounded: strictlyLowerThan(start.value)
    of bkIncluded, bkExcluded: negateSegments(unbounded[V](), self.segments)
  of bkExcluded:
    case stop.kind
    of bkUnbounded: lowerThan(start.value)
    of bkIncluded, bkExcluded: negateSegments(unbounded[V](), self.segments)

func asSingleton*[V](self: Ranges[V]): Option[V] =
  ## If the range includes a single version, return it.
  ## Otherwise, returns `none`.
  if self.segments.len == 1 and self.segments[0].start.kind == bkIncluded and
      self.segments[0].stop.kind == bkIncluded:
    if self.segments[0].start.value == self.segments[0].stop.value:
      return some(self.segments[0].start.value)
  none(V)

func boundingRange*[V](self: Ranges[V]): Option[Interval[V]] =
  ## Convert to something that can be used with a range query to do a
  ## coarse (but more efficient) search.
  ##
  ## Returns `none` for an empty range.
  if self.segments.len == 0:
    return none(Interval[V])
  some((self.segments[0].start, self.segments[^1].stop))

func withinBounds[V](version: V, segment: Interval[V]): int =
  ## The ordering of the version wrt to the interval.
  ## ```text
  ##      |-------|
  ##   ^      ^      ^
  ##   less   equal  greater
  ## ```
  let belowLowerBound =
    case segment.start.kind
    of bkExcluded: version <= segment.start.value
    of bkIncluded: version < segment.start.value
    of bkUnbounded: false
  if belowLowerBound:
    return -1
  let belowUpperBound =
    case segment.stop.kind
    of bkUnbounded: true
    of bkIncluded: version <= segment.stop.value
    of bkExcluded: version < segment.stop.value
  if belowUpperBound:
    return 0
  1

func contains*[V](self: Ranges[V], version: V): bool =
  ## Returns true if self contains the specified value.
  # A binary search for a segment that contains the version.
  var
    low = 0
    high = self.segments.len
  while low < high:
    let middle = low + (high - low) div 2
    let ordering = withinBounds(version, self.segments[middle])
    if ordering == 0:
      # An equal interval is one that contains the version
      return true
    elif ordering < 0:
      high = middle
    else:
      low = middle + 1
  false

func containsMany*[V](self: Ranges[V], versions: openArray[V]): seq[bool] =
  ## Returns true if self contains the specified values.
  ##
  ## The `versions` must be sorted.
  var i = 0
  for v in versions:
    var found = false
    while i < self.segments.len:
      let ordering = withinBounds(v, self.segments[i])
      if ordering < 0:
        break
      elif ordering == 0:
        found = true
        break
      else:
        inc i
    result.add found

func validSegment[V](start, stop: Bound[V]): bool =
  ## A valid segment is one where at least one version fits between start and
  ## end
  if start.kind == bkUnbounded or stop.kind == bkUnbounded:
    return true
  if start.kind == bkIncluded and stop.kind == bkIncluded:
    # Singleton interval are allowed
    start.value <= stop.value
  else:
    start.value < stop.value

func endBeforeStartWithGap[V](stop, start: Bound[V]): bool =
  ## The end of one interval is before the start of the next one, so they
  ## can't be concatenated into a single interval. The `stop` and `start` can
  ## be equal only if they are both exclusive.
  ##
  ## ```text
  ## left:   ...]
  ## right:        [...
  ## gap:       ^^^
  ## ```
  if start.kind == bkUnbounded or stop.kind == bkUnbounded:
    return false
  if stop.kind == bkExcluded and start.kind == bkExcluded:
    stop.value <= start.value
  else:
    stop.value < start.value

func checkInvariants[V](self: Ranges[V]): Ranges[V] =
  ## See `Ranges` for the invariants checked.
  when not defined(release):
    for i in 1 ..< self.segments.len:
      doAssert endBeforeStartWithGap(self.segments[i - 1].stop, self.segments[i].start)
    for (s, e) in self.segments.items:
      doAssert validSegment(s, e)
  self

func fromRangeBounds*[V](start, stop: Bound[V]): Ranges[V] =
  ## Construct a simple range from a pair of bounds.
  if validSegment(start, stop):
    Ranges[V](segments: @[(start, stop)])
  else:
    empty[V]()

func cmpBoundsStart[V](left, right: Bound[V]): int =
  ## Implementing `cmp` for start `Bound` of an interval.
  ##
  ## Legend: `∞` is unbounded, `[1,2]` is `>=1,<=2`, `]1,2[` is `>1,<2`.
  ##
  ## Examples:
  ## ```text
  ## left:   ∞-------]
  ## right:    [-----]
  ## left is smaller, since it starts earlier.
  ##
  ## left:   [-----]
  ## right:  ]-----]
  ## left is smaller, since it starts earlier.
  ## ```
  case left.kind
  of bkUnbounded:
    # left:   ∞-----
    # right:  ∞----- (equal), or [--- or ]--- (less)
    if right.kind == bkUnbounded: 0 else: -1
  of bkIncluded:
    case right.kind
    # left:     [---
    # right:  ∞-----
    of bkUnbounded: 1
    # left:   [----- OR [----- OR   [-----
    # right:    [--- OR [----- OR [---
    of bkIncluded: cmp(left.value, right.value)
    of bkExcluded:
      # left:   [-----
      # right:    ]---   less; with the same value, less: [ starts before ]
      if cmp(left.value, right.value) <= 0: -1 else: 1
  of bkExcluded:
    case right.kind
    # left:     ]---
    # right:  ∞-----
    of bkUnbounded: 1
    of bkIncluded:
      # left:   ]-----
      # right:    [---   less; with the same value, greater
      if cmp(left.value, right.value) < 0: -1 else: 1
    # left:   ]----- OR ]----- OR   ]---
    # right:    ]--- OR ]----- OR ]-----
    of bkExcluded: cmp(left.value, right.value)

func cmpBoundsEnd[V](left, right: Bound[V]): int =
  ## Implementing `cmp` for end `Bound` of an interval.
  ##
  ## We flip the unbounded ranges from `-∞` to `∞`, while `Included(n)` and
  ## `Excluded(n)` invert.
  ##
  ## Examples:
  ## ```text
  ## left:   [--------∞
  ## right:    [-----]
  ## left is greater, since it starts earlier.
  ##
  ## left:   [-----[
  ## right:  [-----]
  ## left is smaller, since it ends earlier.
  ## ```
  case left.kind
  of bkUnbounded:
    # left:   -----∞
    # right:  -----∞ (equal), or ---] or ---[ (greater)
    if right.kind == bkUnbounded: 0 else: 1
  of bkIncluded:
    case right.kind
    # left:   ---]
    # right:  -----∞
    of bkUnbounded: -1
    # left:   -----] OR -----] OR ---]
    # right:    ---] OR -----] OR -----]
    of bkIncluded: cmp(left.value, right.value)
    of bkExcluded:
      # left:   ---]
      # right:  -----[   less; with the same value, greater
      if cmp(left.value, right.value) < 0: -1 else: 1
  of bkExcluded:
    case right.kind
    # left:   ---[
    # right:  -----∞
    of bkUnbounded: -1
    of bkIncluded:
      # left:   ---[
      # right:  -----]   less; with the same value, less
      if cmp(left.value, right.value) <= 0: -1 else: 1
    # left:   -----[ OR -----[ OR ---[
    # right:  ---[   OR -----[ OR -----[
    of bkExcluded: cmp(left.value, right.value)

func cmp*[V](self, other: Ranges[V]): int =
  ## A simple ordering scheme where we zip the segments and compare all
  ## bounds in order. If all bounds are equal, the longer range is
  ## considered greater. (And if all zipped bounds are equal and we have
  ## the same number of segments, the ranges are equal).
  for i in 0 ..< min(self.segments.len, other.segments.len):
    let startCmp = cmpBoundsStart(self.segments[i].start, other.segments[i].start)
    if startCmp != 0:
      return startCmp
    let endCmp = cmpBoundsEnd(self.segments[i].stop, other.segments[i].stop)
    if endCmp != 0:
      return endCmp
  cmp(self.segments.len, other.segments.len)

func leftStartIsSmaller[V](left, right: Bound[V]): bool =
  if left.kind == bkUnbounded:
    return true
  if right.kind == bkUnbounded:
    return false
  if left.kind == bkExcluded and right.kind == bkIncluded:
    left.value < right.value
  else:
    left.value <= right.value

func leftEndIsSmaller[V](left, right: Bound[V]): bool =
  if right.kind == bkUnbounded:
    return true
  if left.kind == bkUnbounded:
    return false
  if left.kind == bkIncluded and right.kind == bkExcluded:
    left.value < right.value
  else:
    left.value <= right.value

func groupAdjacentLocations(locations: seq[Option[int]]): seq[(Option[int], Option[int])] =
  ## Group adjacent versions locations.
  ##
  ## ```text
  ## [None, 3, 6, 7, None] -> [(3, 7)]
  ## [3, 6, 7, None] -> [(None, 7)]
  ## [3, 6, 7] -> [(None, None)]
  ## [None, 1, 4, 7, None, None, None, 8, None, 9] -> [(1, 7), (8, 8), (9, None)]
  ## ```
  if locations.len == 0:
    return
  # If the first version matched, then the lower bound of that segment is not needed
  var seg: Option[(Option[int], Option[int])] =
    if locations[0].isSome: some((none(int), locations[0]))
    else: none((Option[int], Option[int]))
  for i in 1 ..< locations.len:
    let ver = locations[i]
    if ver.isSome:
      # As long as were still matching versions, we keep merging into the currently matching segment
      let first = if seg.isSome: seg.get[0] else: ver
      seg = some((first, ver))
    else:
      # If we have found a version that doesn't match, then right the merge segment and prepare for a new one.
      if seg.isSome:
        result.add seg.get
        seg = none((Option[int], Option[int]))
  # If the last version matched, then write out the merged segment but the upper bound is not needed.
  if seg.isSome:
    result.add (seg.get[0], none(int))

func union*[V](self, other: Ranges[V]): Ranges[V] =
  ## Computes the union of this `Ranges` and another.
  var output: seq[Interval[V]] = @[]
  var accumulator = none(Interval[V])
  var
    left = 0
    right = 0
  while true:
    var smallerInterval: Interval[V]
    if left < self.segments.len and right < other.segments.len:
      if leftStartIsSmaller(self.segments[left].start, other.segments[right].start):
        smallerInterval = self.segments[left]
        inc left
      else:
        smallerInterval = other.segments[right]
        inc right
    elif left < self.segments.len:
      smallerInterval = self.segments[left]
      inc left
    elif right < other.segments.len:
      smallerInterval = other.segments[right]
      inc right
    else:
      break

    if accumulator.isSome:
      let accumulatorValue = accumulator.get
      if endBeforeStartWithGap(accumulatorValue.stop, smallerInterval.start):
        output.add accumulatorValue
        accumulator = some(smallerInterval)
      else:
        let l = accumulatorValue.stop
        let r = smallerInterval.stop
        let accumulatorEnd =
          if l.kind == bkUnbounded or r.kind == bkUnbounded:
            unbounded[V]()
          elif l.kind == bkIncluded and l.value == r.value:
            l
          elif l.value > r.value:
            l
          else:
            r
        accumulator = some((accumulatorValue.start, accumulatorEnd))
    else:
      accumulator = some(smallerInterval)

  if accumulator.isSome:
    output.add accumulator.get

  Ranges[V](segments: output).checkInvariants()

func rustMax[V](l, r: V): V =
  ## Rust's `std::cmp::max`: the second one when the two compare equal.
  if r < l: l else: r

func intersection*[V](self, other: Ranges[V]): Ranges[V] =
  ## Computes the intersection of two sets of versions.
  var output: seq[Interval[V]] = @[]
  var
    left = 0
    right = 0
  # By the definition of intersection any point that is matched by the output
  # must have a segment in each of the inputs that it matches.
  # Therefore, every segment in the output must be the intersection of a segment from each of the inputs.
  # It would be correct to do the "O(n^2)" thing, by computing the intersection of every segment from one input
  # with every segment of the other input, and sorting the result.
  # We can avoid the sorting by generating our candidate segments with an increasing `end` value.
  while left < self.segments.len and right < other.segments.len:
    let (leftStart, leftEnd) = self.segments[left]
    let (rightStart, rightEnd) = other.segments[right]
    # The next smallest `end` value is going to come from one of the inputs.
    let leftEndIsSmaller = leftEndIsSmaller(leftEnd, rightEnd)
    # Now that we are processing `end` we will never have to process any segment smaller than that.
    # We can ensure that the input that `end` came from is larger than `end` by advancing it one step.
    # `end` is the smaller available input, so we know the other input is already larger than `end`.
    var otherStart, stop: Bound[V]
    if leftEndIsSmaller:
      inc left
      otherStart = rightStart
      stop = leftEnd
    else:
      inc right
      otherStart = leftStart
      stop = rightEnd
    # `start` will either come from the input `end` came from or the other input, whichever one is larger.
    # The intersection is invalid if `start` > `end`.
    # But, we already know that the segments in our input are valid.
    # So we do not need to check if the `start` from the input `end` came from is smaller than `end`.
    # If the `other_start` is larger than end, then the intersection will be invalid.
    if not validSegment(otherStart, stop):
      continue
    let start =
      if leftStart.kind == bkIncluded and rightStart.kind == bkIncluded:
        included(rustMax(leftStart.value, rightStart.value))
      elif leftStart.kind == bkExcluded and rightStart.kind == bkExcluded:
        excluded(rustMax(leftStart.value, rightStart.value))
      elif leftStart.kind == bkIncluded and rightStart.kind == bkExcluded:
        if leftStart.value <= rightStart.value: rightStart else: leftStart
      elif leftStart.kind == bkExcluded and rightStart.kind == bkIncluded:
        if rightStart.value <= leftStart.value: leftStart else: rightStart
      elif rightStart.kind == bkUnbounded:
        leftStart
      else:
        rightStart
    # Now we push a new segment.
    output.add (start, stop)

  Ranges[V](segments: output).checkInvariants()

func isDisjoint*[V](self, other: Ranges[V]): bool =
  ## Return true if there can be no `V` so that `V` is contained in both
  ## `self` and `other`.
  ##
  ## Note that we don't know that set of all existing `V`s here, so we only
  ## check if the segments are disjoint, not if no version is contained in
  ## both.
  # The operation is symmetric
  var
    left = 0
    right = 0
  while left < self.segments.len and right < other.segments.len:
    if not validSegment(other.segments[right].start, self.segments[left].stop):
      inc left
    elif not validSegment(self.segments[left].start, other.segments[right].stop):
      inc right
    else:
      return false

  # The remaining element(s) can't intersect anymore
  true

func subsetOf*[V](self, other: Ranges[V]): bool =
  ## Return true if any `V` that is contained in `self` is also contained in
  ## `other`.
  ##
  ## Note that we don't know that set of all existing `V`s here, so we only
  ## check if all segments `self` are contained in a segment of `other`.
  var containing = 0
  if other.segments.len == 0:
    # As long as we have subset elements, we need containing elements
    return self.segments.len == 0

  for subsetElem in self.segments:
    # Check if the current containing element ends before the subset element.
    # There needs to be another containing element for our subset element in this case.
    while not validSegment(subsetElem.start, other.segments[containing].stop):
      if containing + 1 < other.segments.len:
        inc containing
      else:
        return false

    let startContained = leftStartIsSmaller(other.segments[containing].start, subsetElem.start)

    if not startContained:
      # The start element is not contained
      return false

    let endContained = leftEndIsSmaller(subsetElem.stop, other.segments[containing].stop)

    if not endContained:
      # The end element is not contained
      return false

  true

func keepSegments[V](self: Ranges[V], keptSegments: seq[(Option[int], Option[int])]): Ranges[V] =
  ## Create a new `Ranges` given a list of segments that should be retained
  ## from the original `Ranges`: pairs of indexes, with `none` for an open
  ## end.
  var segments: seq[Interval[V]] = @[]
  for (s, e) in keptSegments.items:
    segments.add (
      (if s.isSome: self.segments[s.get].start else: unbounded[V]()),
      (if e.isSome: self.segments[e.get].stop else: unbounded[V]()),
    )
  Ranges[V](segments: segments).checkInvariants()

func simplify*[V](self: Ranges[V], versions: openArray[V]): Ranges[V] =
  ## Returns a simpler representation that contains the same versions.
  ##
  ## For every one of the `versions` provided, the existing range and the
  ## simplified range will agree on whether it is contained. The simplified
  ## version may include or exclude versions that are not in `versions` as
  ## the implementation wishes.
  ##
  ## If none of the versions are contained in the original than the range
  ## will be returned unmodified. If the range includes a single version, it
  ## will be returned unmodified. If all the versions are contained in the
  ## original than the range will be simplified to `full`.
  ##
  ## If the given versions are not sorted the correctness of this function is
  ## not guaranteed.
  # Do not simplify singletons
  if self.asSingleton().isSome:
    return self

  # Return the segment index in the range for each version in the range, none otherwise
  var versionLocations: seq[Option[int]] = @[]
  var i = 0
  for v in versions:
    var location = none(int)
    while i < self.segments.len:
      let ordering = withinBounds(v, self.segments[i])
      if ordering < 0:
        break
      elif ordering == 0:
        location = some(i)
        break
      else:
        inc i
    versionLocations.add location
  let keptSegments = groupAdjacentLocations(versionLocations)

  # Do not return null sets
  if keptSegments.len == 0:
    return self

  self.keepSegments(keptSegments)

iterator items*[V](self: Ranges[V]): Interval[V] =
  ## Iterate over the parts of the range.
  for segment in self.segments:
    yield segment

func fromIntervals*[V](intervals: openArray[Interval[V]]): Ranges[V] =
  ## Rust's `FromIterator`: a `Ranges` from any intervals, in any order.
  # We have three constraints we need to fulfil:
  # 1. The segments are sorted, from lowest to highest (through `cmp`): By sorting.
  # 2. Each segment contains at least one version (start < end): By skipping invalid
  #    segments.
  # 3. There is at least one version between two segments: By merging overlapping elements.
  #
  # Technically, the implementation has a O(n²) worst case complexity since we're inserting
  # and removing. This has two motivations: One is that we don't have any performance
  # critical usages of this method as of this writing, so we have no real world benchmark.
  # The other is that we get the elements from an iterator, so to avoid moving elements
  # around we would first need to build a different, sorted collection with extra
  # allocation(s), before we could build our real segments. --Konsti
  var segments: seq[Interval[V]] = @[]

  for segment in intervals:
    if not validSegment(segment.start, segment.stop):
      continue
    # Find where to insert the new segment
    var insertionPoint = 0
    block:
      # Rust's `partition_point`: a binary search for the first element that
      # does not start before the new segment.
      var
        low = 0
        high = segments.len
      while low < high:
        let middle = low + (high - low) div 2
        if cmpBoundsStart(segments[middle].start, segment.start) < 0:
          low = middle + 1
        else:
          high = middle
      insertionPoint = low
    # Is it overlapping with the previous segment?
    let previousOverlapping = insertionPoint > 0 and
      not endBeforeStartWithGap(segments[insertionPoint - 1].stop, segment.start)

    # Is it overlapping with the following segment? We'll check if there's more than one
    # overlap later.
    let nextOverlapping = insertionPoint < segments.len and
      not endBeforeStartWithGap(segment.stop, segments[insertionPoint].start)

    if previousOverlapping and nextOverlapping:
      # previous:  |------|
      # segment:       |------|
      # following:          |------|
      # final:     |---------------|
      #
      # OR
      #
      # previous:  |------|
      # segment:       |-----------|
      # following:          |----|
      # final:     |---------------|
      #
      # OR
      #
      # previous:  |------|
      # segment:       |----------------|
      # following:          |----|   |------|
      # final:     |------------------------|
      # We merge all three segments into one, which is effectively removing one of
      # two previously inserted and changing the bounds on the other.

      # Remove all elements covered by the final element
      var following = segments[insertionPoint]
      segments.delete(insertionPoint)
      while insertionPoint < segments.len and
          not endBeforeStartWithGap(segment.stop, segments[insertionPoint].start):
        following = segments[insertionPoint]
        segments.delete(insertionPoint)

      # Set end to max(segment.end, <last overlapping segment>.end)
      if cmpBoundsEnd(segment.stop, following.stop) < 0:
        segments[insertionPoint - 1].stop = following.stop
      else:
        segments[insertionPoint - 1].stop = segment.stop
    elif previousOverlapping:
      # previous:  |------|
      # segment:       |------|
      # following:                |------|
      #
      # OR
      #
      # previous:  |----------|
      # segment:       |---|
      # following:                |------|
      #
      # final:     |----------|   |------|
      # We can reuse the existing element by extending it.

      # Set end to max(segment.end, <previous>.end)
      if cmpBoundsEnd(segments[insertionPoint - 1].stop, segment.stop) < 0:
        segments[insertionPoint - 1].stop = segment.stop
    elif nextOverlapping:
      # previous:  |------|
      # segment:             |------|
      # following:               |------|
      # final:    |------|   |----------|
      #
      # OR
      #
      # previous:  |------|
      # segment:             |----------|
      # following:               |---|
      # final:    |------|   |----------|
      #
      # OR
      #
      # previous:  |------|
      # segment:             |------------|
      # following:               |---|  |------|
      #
      # final:    |------|   |-----------------|
      # We can reuse the existing element by extending it.

      # Remove all fully covered segments so the next element is the last one that
      # overlaps.
      while insertionPoint + 1 < segments.len and
          not endBeforeStartWithGap(segment.stop, segments[insertionPoint + 1].start):
        # We know that the one after also overlaps, so we can drop the current
        # following.
        segments.delete(insertionPoint)

      # Set end to max(segment.end, <last overlapping segment>.end)
      if cmpBoundsEnd(segments[insertionPoint].stop, segment.stop) < 0:
        segments[insertionPoint].stop = segment.stop
      segments[insertionPoint].start = segment.start
    else:
      # previous:  |------|
      # segment:             |------|
      # following:                      |------|
      #
      # final:    |------|   |------|   |------|

      # This line is O(n), which makes the algorithm O(n²), but it should be good
      # enough for now.
      segments.insert(segment, insertionPoint)

  Ranges[V](segments: segments).checkInvariants()

# REPORT ######################################################################

func `$`*[V](self: Ranges[V]): string =
  if self.segments.len == 0:
    result.add "∅"
  else:
    for idx, segment in self.segments:
      if idx > 0:
        result.add " | "
      let (start, stop) = segment
      case start.kind
      of bkUnbounded:
        case stop.kind
        of bkUnbounded: result.add "*"
        of bkIncluded: result.add "<=" & $stop.value
        of bkExcluded: result.add "<" & $stop.value
      of bkIncluded:
        case stop.kind
        of bkUnbounded: result.add ">=" & $start.value
        of bkIncluded:
          if start.value == stop.value:
            result.add $start.value
          else:
            result.add ">=" & $start.value & ", <=" & $stop.value
        of bkExcluded: result.add ">=" & $start.value & ", <" & $stop.value
      of bkExcluded:
        case stop.kind
        of bkUnbounded: result.add ">" & $start.value
        of bkIncluded: result.add ">" & $start.value & ", <=" & $stop.value
        of bkExcluded: result.add ">" & $start.value & ", <" & $stop.value
