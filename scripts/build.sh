#!/usr/bin/env bash
#
# Build the static `langid` helper binary and copy it to bin/<platform>/.
#
# Default build: the four default language models (zh, en, ja, ko) for
# x86_64-unknown-linux-musl, LTO + codegen-units=1 + panic=abort, stripped.
#
# Feature selection:
#   LANGID_FEATURES="lang-zh lang-en"          ./scripts/build.sh
#   ./scripts/build.sh --features "lang-en lang-de"
#   ./scripts/build.sh --extended             # default four + 12 more languages
#   ./scripts/build.sh --features ""          # no language models (not useful)
#
# Other overrides:
#   LANGID_TARGET    Rust target triple  (default x86_64-unknown-linux-musl)
#   LANGID_OUT_DIR   destination directory (default bin/<platform>)
#   STRIP            strip program       (default: strip)
#
# The binary is self-contained: consumers only need to copy the file.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

TARGET=${LANGID_TARGET:-x86_64-unknown-linux-musl}
FEATURES=${LANGID_FEATURES:-}
OUT_DIR=${LANGID_OUT_DIR:-}
STRIPPER=${STRIP:-strip}

usage() {
	cat <<'EOF'
Usage: scripts/build.sh [OPTIONS]

Options:
  --features "F ..."   Cargo features to build (replaces the default set).
                       Accepts space- or comma-separated feature names.
  --extended           shorthand for --features extended
  --target TRIPLE      Rust target triple (default: x86_64-unknown-linux-musl)
  --out-dir DIR        copy the binary here (default: bin/<platform>)
  -h, --help           show this help

Environment:
  LANGID_FEATURES, LANGID_TARGET, LANGID_OUT_DIR, STRIP
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--features)
			[ $# -ge 2 ] || { echo "error: --features requires a value" >&2; exit 2; }
			FEATURES=$2
			shift 2
			;;
		--features=*)
			FEATURES=${1#--features=}
			shift
			;;
		--extended)
			FEATURES=extended
			shift
			;;
		--target)
			[ $# -ge 2 ] || { echo "error: --target requires a value" >&2; exit 2; }
			TARGET=$2
			shift 2
			;;
		--target=*)
			TARGET=${1#--target=}
			shift
			;;
		--out-dir)
			[ $# -ge 2 ] || { echo "error: --out-dir requires a value" >&2; exit 2; }
			OUT_DIR=$2
			shift 2
			;;
		--out-dir=*)
			OUT_DIR=${1#--out-dir=}
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "error: unknown argument: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

# Normalise the feature list: commas and repeated spaces become single spaces.
FEATURES=$(printf '%s' "$FEATURES" | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')

case "$TARGET" in
	x86_64-unknown-linux-musl|x86_64-unknown-linux-gnu) PLATFORM=linux-x86_64 ;;
	aarch64-unknown-linux-musl|aarch64-unknown-linux-gnu) PLATFORM=linux-aarch64 ;;
	x86_64-apple-darwin|aarch64-apple-darwin) PLATFORM=darwin-x86_64 ;;
	x86_64-pc-windows-msvc|x86_64-pc-windows-gnu) PLATFORM=windows-x86_64 ;;
	*) PLATFORM="" ;;
esac

if [ -z "$OUT_DIR" ]; then
	if [ -n "$PLATFORM" ]; then
		OUT_DIR="$ROOT_DIR/bin/$PLATFORM"
	else
		OUT_DIR="$ROOT_DIR/bin/$TARGET"
	fi
fi

cd "$ROOT_DIR"

BUILD_ARGS=(build --release --target "$TARGET")

if [ -f "$ROOT_DIR/Cargo.lock" ]; then
	BUILD_ARGS+=(--locked)
fi

if [ -n "$FEATURES" ]; then
	BUILD_ARGS+=(--no-default-features --features "$FEATURES")
	echo "==> features: $FEATURES"
else
	echo "==> features: default (lang-zh lang-en lang-ja lang-ko)"
fi

echo "==> cargo ${BUILD_ARGS[*]}"
cargo "${BUILD_ARGS[@]}"

BINARY="$ROOT_DIR/target/$TARGET/release/langid"

if [ ! -f "$BINARY" ]; then
	echo "error: build output not found: $BINARY" >&2
	exit 1
fi

if command -v "$STRIPPER" >/dev/null 2>&1; then
	"$STRIPPER" --strip-all "$BINARY"
else
	echo "warning: $STRIPPER not found, binary stays unstripped" >&2
fi

mkdir -p "$OUT_DIR"
cp "$BINARY" "$OUT_DIR/langid"
chmod 0755 "$OUT_DIR/langid"

SIZE=$(wc -c < "$OUT_DIR/langid")

echo "==> built $OUT_DIR/langid ($SIZE bytes)"
if command -v file >/dev/null 2>&1; then
	file "$OUT_DIR/langid"
fi
if command -v ldd >/dev/null 2>&1; then
	# A static musl build must not depend on the host libc.
	if ldd "$OUT_DIR/langid" 2>&1 | grep -Eq 'not a dynamic executable|statically linked'; then
		echo "==> static: no dynamic dependencies"
	fi
fi
