#!/bin/sh
# Gets a checkout ready to run the tests and build the pages. It works on a laptop, in CI and in a
# fresh coding-agent sandbox, and is safe to rerun: each step is skipped when already done.
#
#   sh tools/setup.sh
#
# 1. Nim: when `nim` is not on the PATH, the GitHub nightly $NIM_NIGHTLY (default
#    latest-version-2-2) goes into $NIM_HOME (default ~/.local/nim). GitHub, not nim-lang.org,
#    because sandboxes often block nim-lang.org.
# 2. PCRE, which nimib's markdown loads at run time (Debian/Ubuntu, with apt).
# 3. The docs' dependencies at the commits of deps.lock, into deps/ (not committed).
#
# The compiler needs only Nim; nimib, tabelline and their dependencies are for the pages.
set -eu

NIM_NIGHTLY="${NIM_NIGHTLY:-latest-version-2-2}"
NIM_HOME="${NIM_HOME:-$HOME/.local/nim}"
here=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$NIM_HOME/bin:$PATH"
log() { echo "[setup] $*"; }

# 1. Nim
if ! command -v nim >/dev/null 2>&1; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) nimArchive=linux_x64.tar.xz ;;
    Linux-aarch64) nimArchive=linux_arm64.tar.xz ;;
    Darwin-*) nimArchive=macosx_x64.tar.xz ;;
    *) log "no Nim nightly for $(uname -sm): install Nim 2.2 and rerun"; exit 1 ;;
  esac
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  log "nim not found: downloading the $NIM_NIGHTLY nightly into $NIM_HOME"
  curl -sSfL --retry 6 --retry-delay 15 --retry-all-errors -o "$tmp/nim.tar.xz" \
    "https://github.com/nim-lang/nightlies/releases/download/$NIM_NIGHTLY/$nimArchive"
  tar -xf "$tmp/nim.tar.xz" -C "$tmp"
  rm -rf "$NIM_HOME" && mkdir -p "$(dirname "$NIM_HOME")"
  mv "$tmp"/nim-*/ "$NIM_HOME"
  log "put it on the PATH of your shell: export PATH=\"$NIM_HOME/bin:\$PATH\""
fi
log "$(nim -v | head -1)"

# 2. PCRE (nim's std/re, used by nimib's markdown, loads libpcre.so.3 or libpcre.so.1)
if [ "$(uname -s)" = Linux ] && ! PATH="$PATH:/sbin:/usr/sbin" ldconfig -p 2>/dev/null | grep 'libpcre\.so\.[13]' >/dev/null; then
  log "libpcre not found: installing libpcre3"
  sudo=""; [ "$(id -u)" -ne 0 ] && sudo="sudo"
  if command -v apt-get >/dev/null 2>&1; then
    $sudo apt-get install -y -qq libpcre3 >/dev/null 2>&1 ||
      { $sudo apt-get update -qq && $sudo apt-get install -y -qq libpcre3 >/dev/null; } ||
      log "WARNING: could not install libpcre3; the pages need it"
  else
    log "WARNING: install PCRE (libpcre3 or pcre) with your package manager; the pages need it"
  fi
fi

# 3. dependencies
cd "$here"
mkdir -p deps
grep -v '^#' deps.lock | while read -r name url commit _; do
  [ -n "$name" ] || continue
  dir="deps/$name"
  if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" != "$commit" ]; then
    if [ ! -d "$dir/.git" ]; then
      rm -rf "$dir"; git init -q "$dir"; git -C "$dir" remote add origin "$url"
    fi
    git -C "$dir" fetch -q --depth 1 origin "$commit" ||
      { log "fetch of $name at $commit failed"; exit 1; }
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
  fi
  log "  $name $(echo "$commit" | cut -c1-7)"
done
log "ready: nim r tests/all.nim (tests), nim r docs/all.nim (pages)"
