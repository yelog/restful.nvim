#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shopt -s nullglob
tests=("$repo_root"/tests/*_spec.lua)
if ((${#tests[@]} == 0)); then
  printf '%s\n' "no test files found" >&2
  exit 1
fi
for test_file in "${tests[@]}"; do
  nvim --headless -u NONE "+luafile $test_file" "+qa!"
done
