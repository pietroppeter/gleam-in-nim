#!/usr/bin/env bash
# Is the differential test sharp? Plant one small bug at a time in the Nim port
# and check that run.sh notices. Every line of mutants.txt is a bug:
#
#   file<TAB>text to find<TAB>text to put in its place
#
#   tests/differential/version/mutants.sh [COUNT]     default: 100000 cases per mutant
#
# Prints one line per mutant and a summary; fails when a mutant survives.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
count="${1:-100000}"
src="../../../src/gleam_in_nim"
caught=0
survived=0
while IFS=$'\t' read -r file find replace; do
  [[ -z "$file" || "$file" == \#* ]] && continue
  cp "$src/$file" "$src/$file.orig"
  if ! python3 - "$src/$file" "$find" "$replace" <<'PY'
import sys
path = sys.argv[1]
find, replace = (t.replace("\\n", "\n") for t in sys.argv[2:4])
text = open(path).read()
if text.count(find) < 1:
    sys.exit(1)
open(path, "w").write(text.replace(find, replace, 1))
PY
  then
    echo "ERROR mutant not applicable: $file: $find"
    survived=$((survived + 1))
  elif ./run.sh 1 "$count" > /dev/null 2>&1; then
    echo "ERROR mutant survived: $file: $find -> $replace"
    survived=$((survived + 1))
  else
    caught=$((caught + 1))
  fi
  mv "$src/$file.orig" "$src/$file"
done < mutants.txt
echo "mutants: $caught caught, $survived survived"
[[ "$survived" == 0 ]]
