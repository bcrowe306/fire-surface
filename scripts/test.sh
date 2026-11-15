#!/usr/bin/env bash
# Builds the examples and runs the tests, at both optimization levels.
#
#   ./scripts/test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./scripts/build.sh
command -v python3 > /dev/null && python3 scripts/gen_layout.py
git diff --quiet -- tests/layout/layout.c 2>/dev/null || { echo "tests/layout/layout.c was out of date (regenerated): commit it" >&2; }
for opt in none speed; do
	for pkg in host kit; do
		odin test tests/$pkg -vet -strict-style -o:$opt -define:ODIN_TEST_FANCY=false
	done
done
for pkg in abi host surface testing; do odin check $pkg -no-entry-point -vet -strict-style; done
# The fsurf tool: a scripted run whose expectations hold.
EXE=""; case "$(uname -s)" in MINGW*|MSYS*) EXE=".exe" ;; esac
.build/fsurf$EXE run .build/grid_odin.fsurf --daw tests/tools/grid.txt > .build/tool.log || { cat .build/tool.log; echo "the fsurf tool's script failed" >&2; exit 1; }
echo "all tests passed"
