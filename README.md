# LangID — offline language identification for Lyrion Music Server

`LangID` is a small, self-contained language detector for
[Lyrion Music Server](https://lyrion.org/) (LMS). It consists of two parts:

- a static Rust command-line helper, `langid`, built on
  [lingua-rs](https://github.com/pemistahl/lingua-rs) with only the selected
  language models compiled in; the optional fastText `lid.176.ftz` model is
  downloaded on demand for the second-opinion `suite` comparison;
- a minimal Perl wrapper that exposes both detectors to LMS and to other
  plugins.

Everything runs locally: no Python, no external services, no telemetry. The
only network operation is the one-time download of the fastText model when
`suite` is used for the first time; LMS caches it locally afterwards. Without
the model everything except the fastText half of the suite keeps working. The
helper is a static musl binary, so it also works on old glibc systems such as
the Debian 12 "bookworm" based LMS containers (glibc 2.36).

## Repository layout

```text
Cargo.toml / Cargo.lock     Rust crate `langid`
src/main.rs                 helper CLI (stdin -> JSON, suite mode)
models/README.md, LICENSE   fastText model URL, checksum and license
                            (the model itself is downloaded, not shipped)
scripts/build.sh            build the static binary into bin/<platform>/
scripts/smoke.sh            end-to-end checks for the compiled binary
API.pm                      Plugins::LangID::API - async wrapper for LMS
Plugin.pm                   Plugins::LangID::Plugin - LMS plugin entry point
install.xml                 LMS extension descriptor (PLUGIN_LANGID)
VERSION                     plugin version (single source of truth)
strings.txt                 plugin strings
t/api.t                     unit tests for the Perl wrapper
t/fixtures/fake-langid      stand-in binary used by the unit tests
t/fixtures/fake-langid-suite stand-in binary for the detect_suite() tests
t/lib/                      minimal AnyEvent shim for the unit tests
bin/linux-x86_64/langid     built helper binary (committed for releases)
.forgejo/                   Forgejo release workflow and packaging hooks
```

The plugin files live in the repository root, matching the usual LMS plugin
repository convention: the archive root is installed as `Plugins/LangID/`, so
`API.pm` becomes `Plugins/LangID/API.pm`.

## Requirements

- Rust/Cargo 1.85 or newer (tested with 1.99) to build the helper;
- `x86_64-unknown-linux-musl` target plus `musl-gcc` for the static build;
- Lyrion Music Server 8.0 or newer and Perl 5.10 or newer to run the plugin;
- the Perl wrapper uses only modules shipped with LMS or Perl core
  (`AnyEvent`, `IPC::Open3`, `JSON::PP`, `Encode`, `Digest::SHA`). The tests
  need no CPAN modules at all;
- network access (or a pre-seeded model via `LANGID_MODEL_PATH` /
  `LANGID_MODEL_DIR`) on the first `suite` use; nothing else downloads.

## Building the helper

```bash
# one-time, if the musl target is not installed yet
rustup target add x86_64-unknown-linux-musl

./scripts/build.sh
```

The script builds `--release --target x86_64-unknown-linux-musl` with LTO,
`codegen-units = 1` and `panic = "abort"` (configured in `Cargo.toml`), strips
the result and copies it to `bin/linux-x86_64/langid`.

Measured on the build host (Debian 13, Rust 1.99):

| Build | Options | Size |
| --- | --- | --- |
| default | `lang-zh`, `lang-en`, `lang-ja`, `lang-ko` | **6,891,776 bytes (6.57 MiB)** |
| extended | default + 12 more languages | 64,436,480 bytes (61.44 MiB) |

Both are `ELF 64-bit LSB pie executable, static-pie linked, stripped` with no
dynamic dependencies. The fastText model (938,013 bytes) is **not embedded**:
the helper accepts it with `--model`, and the Perl wrapper downloads it on
first use and caches it.

### Language feature selection

Each language is a Cargo feature. A feature forwards to the matching lingua-rs
model crate, so only the requested models end up in the binary.

| Feature | Language | ISO 639-1 | In `default` | In `extended` |
| --- | --- | --- | --- | --- |
| `lang-zh` | Chinese | `zh` | yes | yes |
| `lang-en` | English | `en` | yes | yes |
| `lang-ja` | Japanese | `ja` | yes | yes |
| `lang-ko` | Korean | `ko` | yes | yes |
| `lang-fr` | French | `fr` | – | yes |
| `lang-de` | German | `de` | – | yes |
| `lang-es` | Spanish | `es` | – | yes |
| `lang-it` | Italian | `it` | – | yes |
| `lang-pt` | Portuguese | `pt` | – | yes |
| `lang-nl` | Dutch | `nl` | – | yes |
| `lang-ru` | Russian | `ru` | – | yes |
| `lang-pl` | Polish | `pl` | – | yes |
| `lang-sv` | Swedish | `sv` | – | yes |
| `lang-tr` | Turkish | `tr` | – | yes |
| `lang-id` | Indonesian | `id` | – | yes |
| `lang-vi` | Vietnamese | `vi` | – | yes |

The default set is intentionally small. Every compiled model adds several
MiB to the binary (the extended build is about 62 MiB); pick the smallest set
that covers your library.

```bash
# the 16-language extended set
./scripts/build.sh --extended

# an explicit set (replaces the default set)
./scripts/build.sh --features "lang-zh lang-en lang-ja lang-ko lang-de"

# same through the environment
LANGID_FEATURES="lang-en lang-zh" ./scripts/build.sh
```

Other overrides: `LANGID_TARGET` (Rust triple), `LANGID_OUT_DIR` (destination
directory), `STRIP` (strip program). Run `./scripts/build.sh --help` for the
complete list.

Verify the result with:

```bash
./bin/linux-x86_64/langid --languages   # compiled ISO codes, e.g. ["en","ja","ko","zh"]
./bin/linux-x86_64/langid --version
./scripts/smoke.sh
```

## CLI protocol

The helper reads UTF-8 text from standard input, normalises it, detects the
language and writes exactly one JSON object to standard output.

Input normalisation (performed by both the binary and the Perl wrapper):

1. a leading UTF-8 BOM is dropped;
2. control characters are removed;
3. whitespace runs (spaces, tabs, newlines, Unicode spaces) collapse into a
   single space;
4. the text is trimmed;
5. the text is truncated to 16000 characters.

Options:

| Option | Meaning |
| --- | --- |
| `--top N` | number of `scores` entries to print (default: 5) |
| `--min-confidence F` | drop scores below confidence `F` (0.0 – 1.0, default: 0) |
| `--languages` | print the compiled ISO 639-1 codes as a JSON array and exit |
| `--version` | print `langid 0.1.0` and exit |
| `-h`, `--help` | usage text |

Output:

```json
{
  "language": "Chinese",
  "iso": "zh",
  "confidence": 1,
  "scores": [
    { "language": "Chinese", "confidence": 1 },
    { "language": "English", "confidence": 0 },
    { "language": "Japanese", "confidence": 0 },
    { "language": "Korean", "confidence": 0 }
  ]
}
```

- `language` is lingua's display name; `iso` is the lowercase ISO 639-1 code;
- `confidence` is the top score after `--min-confidence` filtering;
- `scores` is sorted by descending confidence and truncated to `--top`;
- empty or blank input produces
  `{"language":null,"confidence":0,"scores":[]}` and exit status 0.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | success |
| 2 | invalid command-line arguments |
| 3 | internal error (for example invalid UTF-8 on stdin) |

Example:

```console
$ printf '这是一个语言检测测试。' | ./bin/linux-x86_64/langid --top 2
{"language":"Chinese","iso":"zh","confidence":1,"scores":[{"language":"Chinese","confidence":1},{"language":"English","confidence":0}]}
```

### Suite command: lingua + fastText cross-check

The fastText model is not bundled with the binary. For CLI use download it
once (the LMS wrapper does this automatically) and pass it with `--model`:

```console
$ curl -fsSL -o /tmp/lid.176.ftz \
    https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.ftz
$ printf '这是一个语言检测测试。' | ./bin/linux-x86_64/langid suite --target zh-Hans --model /tmp/lid.176.ftz
{"target":"zh-Hans","lingua":{"confidence":1,"language":"zh","name":"Chinese"},"fastlang":{"confidence":1,"language":"zh","name":"Chinese"}}
```

Without a usable model the lingua part is still returned and fastlang is null:

```console
$ printf '这是一个语言检测测试。' | ./bin/linux-x86_64/langid suite --target zh-Hans
{"target":"zh-Hans","lingua":{"confidence":1,"language":"zh","name":"Chinese"},"fastlang":null}
```

`suite` reads and sanitises stdin exactly like the default mode and prints one
JSON object:

- `target` echoes the requested target;
- `lingua` is the compiled lingua-rs confidence for the target language;
- `fastlang` is computed from the model given via `--model` (or the
  `LANGID_MODEL_PATH` environment variable): `predict(text, k=8, 0.0)`, then
  the maximum probability among the labels of the target family. fastText
  probabilities are clamped to `0.0` – `1.0`;
- both blocks contain `confidence`, `language` (lowercase ISO 639-1) and
  `name` (display name). A missing, unreadable or invalid model only makes
  `fastlang` null; it never fails the lingua result or the exit code.

The download URL, expected size (938,013 bytes), SHA-256 and license are
documented in [`models/README.md`](models/README.md).

Target mapping:

| `--target` | lingua language | fastText label family |
| --- | --- | --- |
| `zh`, `zh-Hans`, `zh-Hant`, `cmn` | Chinese (`zh`) | `zh`, `zh-cn`, `zh-tw`, `zh-hans`, `zh-hant`, `cmn`, `yue`, `wuu` |
| `en` | English (`en`) | `en` |
| `ja` | Japanese (`ja`) | `ja` |
| `ko` | Korean (`ko`) | `ko` |

The lookup is case-insensitive. An unsupported target prints
`{"error":"unsupported target: ..."}`, a missing `--target` prints a JSON
error, and both exit with status 2. Empty input yields confidence 0 for both
detectors while still echoing the target. `--languages` is unaffected: it
lists the compiled lingua models, while the fastText model always knows 176
languages.

## Installing the LMS plugin

1. Build the helper for the LMS platform (`./scripts/build.sh` for Linux
   x86_64) and make sure `bin/<platform>/langid` is present.
2. Use the release archive (or render `install.xml` from `@VERSION@` when
   installing from a development checkout) and copy the plugin directory
   (containing `install.xml`, `Plugin.pm`, `API.pm`, `bin/`, `strings.txt` and
   `VERSION`) to the LMS plugins directory, for example `Plugins/LangID` below
   the LMS server root, or `Cache/InstalledPlugins/Plugins/LangID` for a
   managed installation.
3. Restart LMS and enable **LangID** under *Settings → Plugins*.
4. No settings page is provided; the plugin has no user-facing UI.

`install.xml` declares the extension name `PLUGIN_LANGID`, the module
`Plugins::LangID::Plugin`, minimum LMS version 8.0 and the version rendered
from the `VERSION` file (`@VERSION@`) by the release pipeline.

### Platform matrix

The wrapper maps the Perl platform (from `$^O` and `$Config{archname}`) to a
binary directory:

| Platform | Perl identifiers | Binary |
| --- | --- | --- |
| Linux x86_64 | `linux` + `x86_64` | `bin/linux-x86_64/langid` |
| Linux aarch64 | `linux` + `aarch64`/`arm64` | `bin/linux-aarch64/langid` |
| macOS | `darwin` | `bin/darwin-x86_64/langid` |
| Windows x86_64 | `MSWin32` | `bin/windows-x86_64/langid.exe` |
| anything else | – | `bin/langid` (fallback) |

Only `bin/linux-x86_64/langid` is built by default. `available()` returns
false when the mapped binary is missing or not executable. For tests or custom
installations the path can be overridden with the `LANGID_BIN` environment
variable.

## Perl API for other plugins

```perl
use Plugins::LangID::API;

if ( Plugins::LangID::API->available ) {
    Plugins::LangID::API->detect( $text, sub {
        my $result = shift;

        if ( $result->{error} ) {
            # helper missing, crashed, timed out or returned malformed JSON
            return;
        }

        my $iso        = $result->{language};   # e.g. "zh"
        my $name       = $result->{name};       # e.g. "Chinese"
        my $confidence = $result->{confidence}; # 0.0 - 1.0
        my $scores     = $result->{scores};     # [ { language, name, confidence }, ... ]
    } );
}

# Two-detector comparison, e.g. for the lyrics translation detector.
Plugins::LangID::API->detect_suite( $text, 'zh-Hans', sub {
    my $result = shift;

    if ( $result->{error} ) {
        return;   # missing helper, unsupported target, timeout, ...
    }

    my $target        = $result->{target};           # e.g. "zh-Hans"
    my $iso           = $result->{lingua}{language}; # e.g. "zh"
    my $lingua_conf   = $result->{lingua}{confidence};
    my $fastlang_conf = $result->{fastlang}{confidence};
} );
```

| Method | Description |
| --- | --- |
| `available()` | true when the helper binary exists and is executable |
| `detect($text, $callback)` | asynchronous detection; invokes `$callback` exactly once |
| `detect_suite($text, $target, $callback)` | asynchronous lingua + fastText comparison for `zh`/`en`/`ja`/`ko` targets |
| `languages()` | arrayref of ISO 639-1 codes compiled into the binary (cached) |
| `binary_path()` | absolute path of the helper, including the platform mapping |
| `version()` | plugin version from the `VERSION` file |

`detect()` executes the helper directly with `IPC::Open3` (no shell), writes
the normalised UTF-8 text to its stdin and closes it. Watchers are installed
with `AnyEvent->io` and `AnyEvent->timer`, so the call does not block the LMS
event loop. The timeout is 2 seconds; the helper then receives `SIGTERM` and,
after a 0.5 second grace period, `SIGKILL`. Stdout is parsed as JSON.

The wrapper normalises the helper's output for consumers:

- `language` is the **lowercase ISO 639-1 code** (`zh`, `ja`, `ko`, `en`, ...);
  if the helper omits `iso`, the lowercased display name is used;
- `name` keeps the display name (`Chinese`, `Japanese`, ...);
- `iso` mirrors `language` for convenience;
- every entry in `scores` is `{ language: <ISO code>, name: <display name>,
  confidence: <float> }`;
- for empty text the result is `{ language => undef, name => undef,
  iso => undef, confidence => 0, scores => [] }`.

`detect_suite($text, $target, $callback)` first ensures that the fastText
model exists, then runs the helper as
`langid suite --target $target --model $path` with the same asynchronous
process handling and timeout. Model handling:

- `LANGID_MODEL_PATH` (or `model_path_override()` in tests) selects an exact
  model file; it is used as-is;
- otherwise the model is cached at `<LMS prefs dir>/langid/lid.176.ftz`;
  `LANGID_MODEL_DIR` overrides the directory and `LANGID_MODEL_URL` the
  download URL;
- on first use the wrapper downloads asynchronously with
  `Slim::Networking::SimpleAsyncHTTP` (30 second timeout) into a temporary
  file, verifies size 938,013 and SHA-256
  `8f3472cf…603e83`, sets mode `0644` and atomically renames it into place;
  concurrent `detect_suite()` calls share a single download;
- if the model cannot be obtained, a warning is logged and the helper is
  called **without** `--model`: the callback still receives the lingua result
  with `fastlang => undef`, so translation detection keeps working.

The callback receives
`{ target, lingua => { confidence, language, name },
fastlang => { confidence, language, name } | undef }` or `{ error => ... }`.
The binary's JSON errors (for example an unsupported target) are surfaced as
the `error` value. `detect()` itself is unchanged.

On failure the callback receives `{ error => "<message>" }` instead. Calling
`detect()` on a missing binary returns such an error synchronously.

### CLI test command

For manual testing `Plugin.pm` registers the LMS CLI command:

```text
langid detect <text>
```

Spaces are CLI argument separators, so use a single token or the JSON-RPC
interface:

```bash
curl -s 'http://localhost:9000/jsonrpc.js' \
  -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request","params":["",["langid","detect","这是一个语言检测测试"]]}'
```

The result contains `language`, `name`, `iso`, `confidence` and a JSON-encoded
`scores` value; failures return an `error` result.

## Tests

```bash
# Rust: sanitisation, JSON rendering, ISO mapping, argument parsing and
# detector smoke tests for the compiled models
cargo test

# Perl: wrapper tests, using the AnyEvent shim and the fake helper binary
prove -l t            # or: perl t/api.t

# end-to-end: real binary against zh/ja/ko/en samples and the CLI contract
./scripts/smoke.sh
```

Current results:

- `cargo test`: 30 tests passed (sanitisation, JSON, ISO mapping, argument
  parsing, suite target mapping, `--model` parsing, fastText score extraction
  and clamping, fastlang-null rendering, missing model file, detector
  samples);
- `perl t/api.t`: 93 tests passed (normal, empty input, timeout, crash,
  malformed JSON, missing binary, `--languages`, `detect_suite()` with a
  present model -> `--model`, download-on-first-use with cache/mode/SHA
  checks, failed download -> lingua-only without `--model`, concurrent
  downloads coalesced, missing fastlang -> undef, binary errors and missing
  target, sanitisation, platform mapping);
- `scripts/smoke.sh`: 17 checks with a verified model (12 without), including:

  | Sample | Expected | Language | Confidence |
  | --- | --- | --- | --- |
  | Chinese | `zh` | Chinese | 1.00 |
  | Japanese | `ja` | Japanese | 1.00 |
  | Korean | `ko` | Korean | 1.00 |
  | English | `en` | English | 1.00 |

  plus suite checks (`zh-Hans`, `zh-Hant`, `en`, `ja`, `ko`, both detectors
  >= 0.5 when a verified model is available), a no-model fastlang=null check,
  an invalid `--model` check, `--languages`, `--version`, empty input and
  exit-code checks. The script downloads the model with `curl` into a temporary
  directory (or reuses `LANGID_MODEL_PATH`), verifies size and SHA-256, and
  skips the fastlang assertions cleanly when no model can be obtained.

## Releasing

The Forgejo release pipeline lives in `.forgejo/`:

- `.forgejo/workflows/release.yml` runs on tags matching `v1.2.3` / `1.2.3`
  and delegates to the shared `BeyondandSharp/action-template` workflow.
- `.forgejo/workflows/release-manual.yml` allows a manual dispatch (with an
  optional dry run) for an existing tag.
- `.forgejo/release/preflight.sh` checks that `VERSION`, `Cargo.toml`,
  `install.xml` (`@VERSION@` placeholder), the committed helper binary and
  `HEAD` all agree with the requested version.
- `.forgejo/release/prepare.sh` packages the tagged tree (via `git archive`)
  into `dist/LangID-<version>.zip` and `.tar.gz`, renders `install.xml` from
  `VERSION`, keeps `VERSION` for `API->version`, and leaves the helper binary
  executable inside the archive.

The version has a single source of truth: the `VERSION` file. Before tagging,
update `VERSION` and `Cargo.toml`, rebuild and commit
`bin/linux-x86_64/langid`, commit the release notes, then push a tag:

```sh
./scripts/build.sh
git add -A
git commit -m "release 0.2.0"
git tag v0.2.0
git push origin main --tags
```

Commit the `.forgejo/` files first; the workflows only run once they are in the
repository. The released archive is installed as `Plugins/LangID` in LMS.

## License and attribution

This project is licensed under the [Apache License, Version 2.0](LICENSE).
See [NOTICE](NOTICE) for the required attribution notices.

It embeds and links:

- [lingua-rs](https://github.com/pemistahl/lingua-rs) 1.8.0, Apache-2.0,
  Copyright © Peter M. Stahl;
- the lingua language model crates (Apache-2.0), which contain the trained
  model data compiled into the helper binary;
- the optional fastText language-identification model `lid.176.ftz`
  (938,013 bytes), Copyright © Facebook, Inc. and the fastText contributors,
  licensed under
  [Creative Commons Attribution-ShareAlike 3.0 Unported](models/LICENSE).
  The model is **not** shipped in this repository or embedded in the helper
  binary; it is downloaded by the LMS wrapper on first use. The downloaded
  model file remains under CC BY-SA 3.0: keep the attribution and comply with
  the ShareAlike terms if you redistribute that file; see
  [`models/README.md`](models/README.md);
- [fasttext-pure-rs](https://github.com/silvermine/fasttext-pure-rs) 0.1.0,
  MIT, Copyright © 2026 Jeremy Thomerson;
- the transitive Rust dependencies listed in `Cargo.lock` (MIT/Apache-2.0
  compatible licenses).

**Model-license caveat:** LangID source code and the compiled helper
(including release archives) are Apache-2.0 only — they contain no model data.
The fastText model is downloaded at run time and remains CC BY-SA 3.0. A
distribution that bundles the downloaded model file itself is a combined
distribution and must keep `NOTICE`, `models/LICENSE` and `models/README.md`
for the model. Keep those files with any redistribution of the model.
