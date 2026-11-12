#!/usr/bin/env bash
# Fetch the pinned Gleam compiler: its source (the spec we port from) and its
# release binary (the oracle we test against). Both land in reference/, which
# git ignores. Safe to run again: it only fetches what is missing.
#
#   reference/fetch.sh            source and binary
#   reference/fetch.sh source     only the source checkout
#   reference/fetch.sh binary     only the release binary
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source <(grep -E '^[A-Z]+=' "$here/PIN")
what="${1:-all}"

if [[ "$what" == all || "$what" == source ]]; then
  if [[ "$(git -C "$here/gleam" rev-parse HEAD 2>/dev/null || true)" != "$COMMIT" ]]; then
    rm -rf "$here/gleam"
    git clone --quiet --depth 1 --branch "$TAG" "$REPO" "$here/gleam"
    got="$(git -C "$here/gleam" rev-parse HEAD)"
    [[ "$got" == "$COMMIT" ]] || { echo "pin mismatch: $TAG is $got, expected $COMMIT" >&2; exit 1; }
  fi
  echo "source: $here/gleam at $TAG ($COMMIT)"
fi

if [[ "$what" == all || "$what" == binary ]]; then
  if [[ ! -x "$here/bin/gleam" ]]; then
    mkdir -p "$here/bin"
    curl -sSL "$BINARY" | tar xz -C "$here/bin"
  fi
  echo "binary: $here/bin/gleam ($("$here/bin/gleam" --version))"
fi
