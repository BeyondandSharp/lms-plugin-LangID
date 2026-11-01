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


# ---------------------------------------------------------------------------
# suite command: lingua + on-demand fastText model per target language
# ---------------------------------------------------------------------------

# The fastText model is no longer embedded. Download it to a temporary
# directory for the fastlang assertions when curl and network are available;
# otherwise only the lingua/no-model behaviour is checked.
MODEL_TEMP_DIR=""
MODEL_FILE=""

model_cleanup() {
	if [ -n "$MODEL_TEMP_DIR" ] && [ -d "$MODEL_TEMP_DIR" ]; then
		rm -rf "$MODEL_TEMP_DIR"
	fi
}
trap model_cleanup EXIT

MODEL_URL=${LANGID_MODEL_URL:-https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.ftz}
MODEL_SIZE=938013
MODEL_SHA256=8f3472cfe8738a7b6099e8e999c3cbfae0dcd15696aac7d7738a8039db603e83

if [ -n "${LANGID_MODEL_PATH:-}" ] && [ -f "$LANGID_MODEL_PATH" ]; then
	MODEL_FILE=$LANGID_MODEL_PATH
elif command -v curl >/dev/null 2>&1; then
	MODEL_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/langid-smoke.XXXXXX")
	echo "==> downloading fastText model for fastlang checks: $MODEL_TEMP_DIR"
	if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 180 \
		-o "$MODEL_TEMP_DIR/lid.176.ftz" "$MODEL_URL" 2>/dev/null
	then
		MODEL_FILE=$MODEL_TEMP_DIR/lid.176.ftz
	else
		echo "==> model download failed; skipping fastlang checks"
	fi
else
	echo "==> curl not available; skipping fastlang checks"
fi

if [ -n "$MODEL_FILE" ]; then
	MODEL_ACTUAL_SIZE=$(wc -c < "$MODEL_FILE")
	MODEL_ACTUAL_SHA=$(perl -MDigest::SHA -e 'print Digest::SHA->new(256)->addfile($ARGV[0])->hexdigest' "$MODEL_FILE" 2>/dev/null || true)

	if [ "$MODEL_ACTUAL_SIZE" -ne "$MODEL_SIZE" ] || [ "$MODEL_ACTUAL_SHA" != "$MODEL_SHA256" ]; then
		echo "==> model size/SHA-256 mismatch; skipping fastlang checks"
		MODEL_FILE=""
	else
		echo "==> using verified model: $MODEL_FILE ($MODEL_ACTUAL_SIZE bytes)"
	fi
fi

# suite result without a model: lingua must still work, fastlang must be null.
check_suite_without_model() {
	local target=$1 expected_iso=$2 text=$3
	local output status=0 parsed verdict=PASS

	# Ignore an inherited LANGID_MODEL_PATH: this check is about the no-model
	# fallback. Capture the status without tripping `set -e`.
	output=$(printf '%s' "$text" | env -u LANGID_MODEL_PATH "$BIN" suite --target "$target") || status=$?

	checks=$((checks + 1))

	if [ "$status" -ne 0 ]; then
		printf 'FAIL   suite %-7s exit status %s\n' "$target" "$status"
		failures=$((failures + 1))
		return
	fi

	parsed=$(printf '%s' "$output" | perl -MJSON::PP -e '
		my $json = do { local $/; <STDIN> };
		my $data = eval { JSON::PP->new->decode($json) };
		my ( $target, $expected ) = @ARGV;
		my $ok = $data
			&& ref $data->{lingua} eq "HASH"
			&& !defined $data->{fastlang}
			&& defined $data->{target}
			&& $data->{target} eq $target
			&& $data->{lingua}{language} eq $expected
			&& $data->{lingua}{confidence} >= 0.5;
		printf "lingua=%s/%s fastlang=%s",
			$data->{lingua}{language} // "?",
			$data->{lingua}{confidence} // "?",
			defined $data->{fastlang} ? "present" : "null";
		exit( $ok ? 0 : 1 );
	' "$target" "$expected_iso")

	if [ $? -ne 0 ]; then
		verdict=FAIL
	fi

	printf '%-6s %-7s %s %s\n' "suite" "$target" "$parsed $verdict"

	if [ "$verdict" = FAIL ]; then
		echo "       raw output: $output"
		failures=$((failures + 1))
	fi
}

# suite result with the downloaded model: both detectors must be >= 0.5.
check_suite_with_model() {
	local target=$1 expected_iso=$2 text=$3
	local output status=0 parsed verdict=PASS
	local -a arguments=(suite --target "$target" --model "$MODEL_FILE")

	output=$(printf '%s' "$text" | "$BIN" "${arguments[@]}") || status=$?

	checks=$((checks + 1))

	if [ "$status" -ne 0 ]; then
		printf 'FAIL   suite %-7s exit status %s\n' "$target" "$status"
		failures=$((failures + 1))
		return
	fi

	parsed=$(printf '%s' "$output" | perl -MJSON::PP -e '
		my $json = do { local $/; <STDIN> };
		my $data = eval { JSON::PP->new->decode($json) };
		my ( $target, $expected ) = @ARGV;
		my $ok = $data
			&& ref $data->{lingua} eq "HASH"
			&& ref $data->{fastlang} eq "HASH"
			&& defined $data->{target}
			&& $data->{target} eq $target
			&& $data->{lingua}{language} eq $expected
			&& $data->{fastlang}{language} eq $expected
			&& $data->{lingua}{confidence} >= 0.5
			&& $data->{fastlang}{confidence} >= 0.5;
		printf "lingua=%s/%s fastlang=%s/%s",
			$data->{lingua}{language} // "?",
			$data->{lingua}{confidence} // "?",
			$data->{fastlang}{language} // "?",
			$data->{fastlang}{confidence} // "?";
		exit( $ok ? 0 : 1 );
	' "$target" "$expected_iso")

	if [ $? -ne 0 ]; then
		verdict=FAIL
	fi

	printf '%-6s %-7s %s %s\n' "suite" "$target" "$parsed $verdict"

	if [ "$verdict" = FAIL ]; then
		echo "       raw output: $output"
		failures=$((failures + 1))
	fi
}

check_suite_without_model zh-Hans zh '这是一个用于测试语言识别套件的句子，包含足够多的中文文字来做出可靠判断。'

if [ -n "$MODEL_FILE" ]; then
	check_suite_with_model zh-Hans zh '这是一个用于测试语言识别套件的句子，包含足够多的中文文字来做出可靠判断。'
	check_suite_with_model zh-Hant zh '這是一個用於測試語言識別套件的句子，包含足夠多的中文文字。'
	check_suite_with_model en en 'This is an English sentence used to test the suite command.'
	check_suite_with_model ja ja 'これはスイートコマンドをテストするための日本語の文章です。十分な長さがあります。'
	check_suite_with_model ko ko '이것은 스위트 명령을 테스트하기 위한 한국어 문장입니다. 충분히 깁니다.'
else
	echo "SKIP   suite fastlang checks (no verified fastText model available)"
fi

# A missing/invalid model must not break the lingua result.
invalid_model_status=0
invalid_model_output=$(printf '这是一个中文句子。' | "$BIN" suite --target zh --model /nonexistent/lid.176.ftz 2>/dev/null) || invalid_model_status=$?
check 'suite with a missing --model keeps lingua and nulls fastlang' \
	perl -MJSON::PP -e '
		my ( $json, $status ) = @ARGV;
		my $data = eval { JSON::PP->new->decode($json) };
		exit( ( $status == 0 && $data && ref $data->{lingua} eq "HASH"
			&& !defined $data->{fastlang} && $data->{lingua}{language} eq "zh" ) ? 0 : 1 );
	' "$invalid_model_output" "$invalid_model_status"

unsupported_status=0
unsupported_output=$(printf 'text' | "$BIN" suite --target fr 2>&1) || unsupported_status=$?
check 'suite rejects an unsupported target with a JSON error and exit 2' \
	perl -MJSON::PP -e '
		my ( $json, $status ) = @ARGV;
		my $data = eval { JSON::PP->new->decode($json) };
		exit( ( $status == 2 && $data && defined $data->{error} && $data->{error} =~ /unsupported target/i ) ? 0 : 1 );
	' "$unsupported_output" "$unsupported_status"

missing_target_status=0
missing_target_output=$("$BIN" suite </dev/null 2>&1) || missing_target_status=$?
check 'suite without --target fails with a JSON error and exit 2' \
	perl -MJSON::PP -e '
		my ( $json, $status ) = @ARGV;
		my $data = eval { JSON::PP->new->decode($json) };
		exit( ( $status == 2 && $data && defined $data->{error} ) ? 0 : 1 );
	' "$missing_target_output" "$missing_target_status"

echo
echo
if [ "$failures" -ne 0 ]; then
	echo "FAILED: $failures of $checks checks failed"
	exit 1
fi

echo "OK: $checks checks passed"
