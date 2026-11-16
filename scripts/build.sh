#!/usr/bin/env bash
# Builds the examples (.build/hello_c.fsurf, hello_odin, grid_odin, keys_odin) and the
# header's layout printer (.build/layout), which tests/host needs.
#
#   ./scripts/build.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT=.build
mkdir -p "$OUT"

# cc SOURCE OUTPUT [shared] [DEFINE]
cc_build() {
	local SRC="$1" DST="$2" KIND="${3:-}" DEF="${4:-}"
	case "$(uname -s)" in
	Darwin) "${CC:-cc}" -O2 -Wall -Wextra -std=c11 -Iinclude -fvisibility=hidden ${KIND:+-dynamiclib} ${DEF:+-D$DEF} "$SRC" -o "$DST" ;;
	MINGW*|MSYS*)
		if command -v clang > /dev/null; then
			clang -O2 -Wall -Wextra -std=c11 -Iinclude ${KIND:+-shared} ${DEF:+-D$DEF} "$SRC" -o "$DST"
		else
			local VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
			local VS; VS="$("$VSWHERE" -latest -products '*' -property installationPath | tr -d '\r')"
			local BAT; BAT="$(mktemp -d)/build.bat"
			cat > "$BAT" <<BATCH
@call "$VS\\VC\\Auxiliary\\Build\\vcvars64.bat" > nul
cl /nologo /O2 /W3 /std:c11 /Iinclude ${KIND:+/LD} ${DEF:+/D$DEF} $(cygpath -w "$SRC") /Fe:$(cygpath -w "$DST") /Fo:$OUT\\
BATCH
			cmd //c "$(cygpath -w "$BAT")"
		fi
		;;
	*) "${CC:-cc}" -O2 -Wall -Wextra -std=c11 -Iinclude -fvisibility=hidden ${KIND:+-shared -fPIC} ${DEF:+-D$DEF} "$SRC" -o "$DST" ;;
	esac
}

EXE=""
case "$(uname -s)" in MINGW*|MSYS*) EXE=".exe" ;; esac
cc_build tests/layout/layout.c "$OUT/layout$EXE"
cc_build examples/hello_c/hello.c "$OUT/hello_c.fsurf" shared
cc_build examples/hello_c/hello.c "$OUT/hello_c_2.fsurf" shared HELLO_BYTE=2 # for the reload tests
odin build examples/hello_odin -build-mode:dll -vet -strict-style -out:"$OUT/hello_odin.fsurf"
odin build examples/grid_odin -build-mode:dll -vet -strict-style -out:"$OUT/grid_odin.fsurf"
odin build examples/keys_odin -build-mode:dll -vet -strict-style -out:"$OUT/keys_odin.fsurf"
odin build examples/screen_odin -build-mode:dll -vet -strict-style -out:"$OUT/screen_odin.fsurf"
odin build examples/push2_odin -build-mode:dll -vet -strict-style -out:"$OUT/push2_odin.fsurf"
odin build tools/fsurf -vet -strict-style -out:"$OUT/fsurf$EXE"
echo "built $OUT"
