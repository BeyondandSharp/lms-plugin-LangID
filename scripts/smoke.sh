#!/usr/bin/env bash
#
# Smoke test for the compiled langid binary.
#
# Runs the real binary against Chinese, Japanese, Korean and English samples,
# verifies the ISO 639-1 code and a minimum confidence, and checks the CLI
# contract (--languages, --version, empty input, invalid arguments).
#
# Usage:
#   scripts/smoke.sh
#   LANGID_BIN=/path/to/langid scripts/smoke.sh
#
# Exits 0 when every check passes.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

BIN=${LANGID_BIN:-}
if [ -z "$BIN" ]; then
	for candidate in \
		"$ROOT_DIR/bin/linux-x86_64/langid" \
		"$ROOT_DIR/bin/linux-aarch64/langid" \
		"$ROOT_DIR/bin/darwin-x86_64/langid" \
		"$ROOT_DIR/bin/windows-x86_64/langid.exe" \
		"$ROOT_DIR/bin/langid"
	do
		if [ -x "$candidate" ]; then
			BIN=$candidate
			break
		fi
	done
fi

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
	echo "error: langid binary not found; run scripts/build.sh first or set LANGID_BIN" >&2
	exit 1
fi

if ! command -v perl >/dev/null 2>&1; then
	echo "error: perl is required to parse the JSON output" >&2
	exit 1
fi

failures=0
checks=0

# json_field <output> <field> -> value of a top-level JSON field
json_field() {
	local output=$1 field=$2
	printf '%s' "$output" | perl -MJSON::PP -e '
		my $json = do { local $/; <STDIN> };
		my $data = eval { JSON::PP->new->decode($json) };
		if ( !$data ) { print ""; exit 0 }
		my $value = $data->{$ARGV[0]};
		print defined $value ? $value : "";
	' "$field"
}

check_case() {
	local name=$1 expected_iso=$2 expected_language=$3 text=$4
	local output status iso language confidence

	output=$(printf '%s' "$text" | "$BIN")
	status=$?

	checks=$((checks + 1))

	if [ "$status" -ne 0 ]; then
		echo "FAIL $name: exit status $status"
		failures=$((failures + 1))
		return
	fi

	iso=$(json_field "$output" iso)
	language=$(json_field "$output" language)
	confidence=$(json_field "$output" confidence)

	local verdict=PASS
	if [ "$iso" != "$expected_iso" ]; then
		verdict=FAIL
	fi
	if [ "$language" != "$expected_language" ]; then
		verdict=FAIL
	fi
	if ! perl -e 'exit( ( $ARGV[0] =~ /\A (?: \d+ (?: [.] \d* )? | [.] \d+ ) \z /xms && $ARGV[0] >= 0.5 ) ? 0 : 1 )' "$confidence"; then
		verdict=FAIL
	fi

	printf '%-6s expected=%-2s got=%-2s language=%-9s confidence=%-6s %s\n' \
		"$name" "$expected_iso" "$iso" "$language" "$confidence" "$verdict"

	if [ "$verdict" = FAIL ]; then
		echo "       raw output: $output"
		failures=$((failures + 1))
	fi
}

echo "==> binary: $BIN"
echo "==> size:   $(wc -c < "$BIN") bytes"
echo

check_case zh zh Chinese '这是一个用于测试语言识别的中文句子，包含足够多的文字来让检测器做出可靠判断。'
check_case ja ja Japanese 'これは言語識別をテストするための日本語の文章です。十分な長さがあります。'
check_case ko ko Korean '이것은 언어 식별을 테스트하기 위한 한국어 문장입니다. 충분히 깁니다.'
check_case en en English 'This is an English sentence used to test language identification.'

# ---------------------------------------------------------------------------
# CLI contract checks
# ---------------------------------------------------------------------------

check() {
	local description=$1
	shift
	checks=$((checks + 1))
	if "$@"; then
		echo "PASS   $description"
	else
		echo "FAIL   $description"
		failures=$((failures + 1))
	fi
}

languages_json=$("$BIN" --languages)
check '--languages returns a JSON array with zh/en/ja/ko' \
	perl -MJSON::PP -e '
		my $data = eval { JSON::PP->new->decode($ARGV[0]) };
		exit 1 unless ref $data eq "ARRAY";
		my %codes = map { $_ => 1 } @$data;
		exit( ( $codes{zh} && $codes{en} && $codes{ja} && $codes{ko} ) ? 0 : 1 );
	' "$languages_json"

version_output=$("$BIN" --version)
check '--version prints "langid 0.1.0"' \
	perl -e 'exit( $ARGV[0] =~ /\Alangid[ ]\d+[.]\d+[.]\d+\n?\z/xms ? 0 : 1 )' "$version_output"

empty_output=$(printf '' | "$BIN")
check 'empty input yields a null language and no scores' \
	perl -MJSON::PP -e '
		my $data = eval { JSON::PP->new->decode($ARGV[0]) };
		exit 1 unless ref $data eq "HASH";
		exit( ( !defined $data->{language} && ( $data->{confidence} // -1 ) == 0 && @{ $data->{scores} || [] } == 0 ) ? 0 : 1 );
	' "$empty_output"

bad_arg_status=0
"$BIN" --top not-a-number >/dev/null 2>&1 || bad_arg_status=$?
check 'invalid arguments exit with status 2' \
	perl -e 'exit( $ARGV[0] == 2 ? 0 : 1 )' "$bad_arg_status"

echo
if [ "$failures" -ne 0 ]; then
	echo "FAILED: $failures of $checks checks failed"
	exit 1
fi

echo "OK: $checks checks passed"
