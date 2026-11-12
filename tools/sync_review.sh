#!/bin/sh
# Copies the review mode again from tabelline (docs/review.nim, docs/assets/review.js), where
# it lives until it moves to nimib. Do not edit the copies here: change it in tabelline.
#
#   sh tools/sync_review.sh            # tabelline's main
#   sh tools/sync_review.sh <commit>
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
ref="${1:-main}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q "$tmp"
git -C "$tmp" remote add origin https://github.com/pietroppeter/tabelline
git -C "$tmp" fetch -q --depth 1 origin "$ref"
git -C "$tmp" -c advice.detachedHead=false checkout -q FETCH_HEAD
cp "$tmp/docs/review.nim" "$here/docs/review.nim"
cp "$tmp/docs/assets/review.js" "$here/docs/assets/review.js"
git -C "$tmp" rev-parse HEAD > "$here/docs/assets/REVIEW_VERSION"
echo "review mode from tabelline $(cut -c1-7 "$here/docs/assets/REVIEW_VERSION"): rebuild the pages (nim r docs/all.nim)"
