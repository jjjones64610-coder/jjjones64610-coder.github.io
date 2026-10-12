#!/usr/bin/env bash
# Runs every offline check. Needs these tools on PATH (versions used to build
# this project in brackets):
#   rojo [7.4.4]  luau-lsp [1.70.0]  selene [0.27.1]  stylua [0.20.0]  lune [0.9.4]
# and Roblox type definitions for luau-lsp:
#   https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
# Set ROBLOX_DEFS to that file's path (default: ./globalTypes.d.luau).
set -euo pipefail
cd "$(dirname "$0")/.."

DEFS="${ROBLOX_DEFS:-./globalTypes.d.luau}"

echo "== format (stylua)"
stylua --check src tests

echo "== lint (selene)"
selene src

echo "== types (luau-lsp, strict, real Roblox API)"
rojo sourcemap default.project.json -o sourcemap.json
out=$(luau-lsp analyze --definitions="$DEFS" --sourcemap=sourcemap.json src 2>&1 | grep -v "INFO\|WARN" || true)
if [ -n "$out" ]; then
	echo "$out"
	exit 1
fi
echo "no type errors"

echo "== cross-module references"
python3 scripts/audit_refs.py

echo "== unit tests (lune)"
lune run tests/run.luau

echo "== build place"
rojo build default.project.json -o build/UltimateBreakpoint.rbxlx
lune run tests/place_check.luau > /dev/null && echo "place structure OK"
echo "all checks passed"
