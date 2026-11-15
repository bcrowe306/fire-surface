#!/usr/bin/env bash
# Builds the examples (.build/hello_c.fsurf, .build/hello_odin.fsurf) and the
# header's layout printer (.build/layout), which tests/host needs.
#
#   ./scripts/build.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT=.build
mkdir -p "$OUT"

# cc SOURCE OUTPUT [shared]
cc_build() {
	local SRC="$1" DST="$2" KIND="${3:-}"
	case "$(uname -s)" in
	Darwin) "${CC:-cc}" -O2 -Wall -Wextra -std=c11 -Iinclude -fvisibility=hidden ${KIND:+-dynamiclib} "$SRC" -o "$DST" ;;
	MINGW*|MSYS*)
		if command -v clang > /dev/null; then
			clang -O2 -Wall -Wextra -std=c11 -Iinclude ${KIND:+-shared} "$SRC" -o "$DST"
		else
			local VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
			local VS; VS="$("$VSWHERE" -latest -products '*' -property installationPath | tr -d '\r')"
			local BAT; BAT="$(mktemp -d)/build.bat"
			cat > "$BAT" <<BATCH
@call "$VS\\VC\\Auxiliary\\Build\\vcvars64.bat" > nul
cl /nologo /O2 /W3 /std:c11 /Iinclude ${KIND:+/LD} $(cygpath -w "$SRC") /Fe:$(cygpath -w "$DST") /Fo:$OUT\\
BATCH
			cmd //c "$(cygpath -w "$BAT")"
		fi
		;;
	*) "${CC:-cc}" -O2 -Wall -Wextra -std=c11 -Iinclude -fvisibility=hidden ${KIND:+-shared -fPIC} "$SRC" -o "$DST" ;;
	esac
}

EXE=""
case "$(uname -s)" in MINGW*|MSYS*) EXE=".exe" ;; esac
cc_build tests/layout/layout.c "$OUT/layout$EXE"
cc_build examples/hello_c/hello.c "$OUT/hello_c.fsurf" shared
odin build examples/hello_odin -build-mode:dll -vet -strict-style -out:"$OUT/hello_odin.fsurf"
echo "built $OUT"
