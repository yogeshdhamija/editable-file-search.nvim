#!/bin/sh
# Test suite for editable-file-search.nvim. Run it from anywhere:
#
#     test/run.sh
#
# Exits nonzero if any assertion failed. See driver.lua for how it works.

set -eu

EFS_ROOT=$(cd "$(dirname "$0")/.." && pwd)
export EFS_ROOT

command -v nvim >/dev/null || { echo "no nvim in PATH" >&2; exit 1; }
command -v rg >/dev/null || { echo "no rg in PATH" >&2; exit 1; }

# $NVIM is set when this runs inside a Neovim terminal; the nvim under test
# must not think it is nested in that one.
exec env -u NVIM timeout 120 nvim --clean -l "$EFS_ROOT/test/driver.lua"
