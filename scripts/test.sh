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
	odin test tests/host -vet -strict-style -o:$opt -define:ODIN_TEST_FANCY=false
done
for pkg in abi host; do odin check $pkg -no-entry-point -vet -strict-style; done
echo "all tests passed"
