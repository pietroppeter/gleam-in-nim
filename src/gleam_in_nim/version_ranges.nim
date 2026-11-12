## Sets of versions as sorted lists of intervals: what upstream gets from the crate
## `version-ranges` under the name `pubgrub::Range`.
##
## This file is NOT a port. The crate is MPL-2.0, a licence this repository does not take code
## from (decision 0011), so the module was written from the crate's documented behaviour and
## is checked against it from outside: `tests/test_hexpm_version.nim` replays cases whose
## expected results were printed by the real crate.
##
## Only what the port needs so far is here. `V` needs `cmp` (the order) and `==` (which may be
## stricter than `cmp(a, b) == 0`: Hex versions that differ only in build metadata are equal
## in order and different in value, and the crate keeps the difference visible).
import std/[options, strutils]

type
  BoundKind* = enum
    bkUnbounded, bkIncluded, bkExcluded
  Bound*[V] = object
    case kind*: BoundKind
    of bkUnbounded: discard
    of bkIncluded, bkExcluded: value*: V
  Segment*[V] = tuple[lower, upper: Bound[V]]
  Ranges*[V] = object
    ## Sorted, non-overlapping, non-touching segments.
    segments*: seq[Segment[V]]

proc unbounded*[V](): Bound[V] = Bound[V](kind: bkUnbounded)
proc included*[V](v: V): Bound[V] = Bound[V](kind: bkIncluded, value: v)
proc excluded*[V](v: V): Bound[V] = Bound[V](kind: bkExcluded, value: v)

proc `==`*[V](a, b: Bound[V]): bool =
  a.kind == b.kind and (a.kind == bkUnbounded or a.value == b.value)

proc `==`*[V](a, b: Ranges[V]): bool = a.segments == b.segments

proc empty*[V](T: typedesc[Ranges[V]]): Ranges[V] = Ranges[V]()
  ## No version at all.

proc full*[V](T: typedesc[Ranges[V]]): Ranges[V] =
  ## Every version.
  Ranges[V](segments: @[(unbounded[V](), unbounded[V]())])

proc higherThan*[V](v: V): Ranges[V] =
  ## `v` and everything above it.
  Ranges[V](segments: @[(included(v), unbounded[V]())])

proc strictlyLowerThan*[V](v: V): Ranges[V] =
  ## Everything below `v`, without `v`.
  Ranges[V](segments: @[(unbounded[V](), excluded(v))])

proc singleton*[V](v: V): Ranges[V] =
  ## Exactly `v`.
  Ranges[V](segments: @[(included(v), included(v))])

proc isEmpty*[V](r: Ranges[V]): bool = r.segments.len == 0

# How two lower bounds, or two upper bounds, are ordered. Negative: `a` comes first.
proc cmpLower[V](a, b: Bound[V]): int =
  if a.kind == bkUnbounded: return (if b.kind == bkUnbounded: 0 else: -1)
  if b.kind == bkUnbounded: return 1
  result = cmp(a.value, b.value)
  if result == 0: result = ord(a.kind == bkExcluded) - ord(b.kind == bkExcluded)

proc cmpUpper[V](a, b: Bound[V]): int =
  if a.kind == bkUnbounded: return (if b.kind == bkUnbounded: 0 else: 1)
  if b.kind == bkUnbounded: return -1
  result = cmp(a.value, b.value)
  if result == 0: result = ord(b.kind == bkExcluded) - ord(a.kind == bkExcluded)

proc validSegment[V](lower, upper: Bound[V]): bool =
  ## Is there a version between the two bounds?
  if lower.kind == bkUnbounded or upper.kind == bkUnbounded: return true
  let c = cmp(lower.value, upper.value)
  c < 0 or (c == 0 and lower.kind == bkIncluded and upper.kind == bkIncluded)

proc touches[V](upper, lower: Bound[V]): bool =
  ## Does a segment ending at `upper` leave no gap before one starting at `lower`?
  if upper.kind == bkUnbounded or lower.kind == bkUnbounded: return true
  let c = cmp(upper.value, lower.value)
  c > 0 or (c == 0 and (upper.kind == bkIncluded or lower.kind == bkIncluded))

proc union*[V](a, b: Ranges[V]): Ranges[V] =
  ## The versions in `a`, in `b`, or in both.
  var i, j = 0
  while i < a.segments.len or j < b.segments.len:
    var next: Segment[V]
    if j >= b.segments.len or (i < a.segments.len and cmpLower(a.segments[i].lower, b.segments[j].lower) <= 0):
      next = a.segments[i]; inc i
    else:
      next = b.segments[j]; inc j
    if result.segments.len > 0 and touches(result.segments[^1].upper, next.lower):
      if cmpUpper(next.upper, result.segments[^1].upper) >= 0:
        result.segments[^1].upper = next.upper
    else:
      result.segments.add next

proc intersection*[V](a, b: Ranges[V]): Ranges[V] =
  ## The versions in both `a` and `b`.
  var i, j = 0
  while i < a.segments.len and j < b.segments.len:
    let (al, au) = a.segments[i]
    let (bl, bu) = b.segments[j]
    # On a tie in the order (two Hex versions that differ only in build metadata) the crate
    # keeps `b`'s lower bound and `a`'s upper bound. Found by fuzzing against it.
    let lower = if cmpLower(al, bl) > 0: al else: bl
    let upper = if cmpUpper(au, bu) <= 0: au else: bu
    if validSegment(lower, upper): result.segments.add (lower, upper)
    if cmpUpper(au, bu) <= 0: inc i else: inc j

proc contains*[V](r: Ranges[V], v: V): bool =
  ## Is `v` in the set? By order, so build metadata does not matter for Hex versions.
  for (lower, upper) in r.segments:
    let aboveLower = case lower.kind
      of bkUnbounded: true
      of bkIncluded: cmp(lower.value, v) <= 0
      of bkExcluded: cmp(lower.value, v) < 0
    let belowUpper = case upper.kind
      of bkUnbounded: true
      of bkIncluded: cmp(v, upper.value) <= 0
      of bkExcluded: cmp(v, upper.value) < 0
    if aboveLower and belowUpper: return true
  false

proc `$`*[V](r: Ranges[V]): string =
  ## The crate's `Display`: `∅`, `*`, `>=1.0.0, <2.0.0`, segments joined by ` | `.
  if r.segments.len == 0: return "∅"
  var parts: seq[string]
  for (lower, upper) in r.segments:
    parts.add(
      case lower.kind
      of bkUnbounded:
        case upper.kind
        of bkUnbounded: "*"
        of bkIncluded: "<=" & $upper.value
        of bkExcluded: "<" & $upper.value
      of bkIncluded:
        case upper.kind
        of bkUnbounded: ">=" & $lower.value
        of bkIncluded:
          if lower.value == upper.value: $lower.value
          else: ">=" & $lower.value & ", <=" & $upper.value
        of bkExcluded: ">=" & $lower.value & ", <" & $upper.value
      of bkExcluded:
        case upper.kind
        of bkUnbounded: ">" & $lower.value
        of bkIncluded: ">" & $lower.value & ", <=" & $upper.value
        of bkExcluded: ">" & $lower.value & ", <" & $upper.value)
  parts.join(" | ")
