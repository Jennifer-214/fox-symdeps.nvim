#!/usr/bin/env bash
# Run the full fox-symdeps test suite headlessly.  Usage:  bash tests/run.sh   (or: make test)
#
# Each test is a standalone `nvim -l` script. Two things they need, both handled here:
#   - cwd = repo root       (the pure tests use  package.path = "./lua/?.lua")
#   - the cpp treesitter parser on runtimepath  (the treesitter tests parse C++; a bare
#     `nvim --clean` has no parser, so we add the site dir where nvim-treesitter installs it).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
site="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site"   # parser/cpp.so lives here
cd "$root" || exit 2

pass=0 fail=0 failed=""
for f in tests/test_*.lua; do
  if out="$(nvim --headless --clean -u NONE --cmd "set rtp+=$site" -l "$f" 2>&1)"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); failed="$failed ${f#tests/}"
    printf '\n── FAIL %s ─────────────────────────\n%s\n' "$f" "$(printf '%s' "$out" | tail -12)"
  fi
done

printf '\nfox-symdeps: %d passed, %d failed\n' "$pass" "$fail"
[ -n "$failed" ] && printf 'FAILED:%s\n' "$failed"
[ "$fail" -eq 0 ]
