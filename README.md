# LangID — offline language identification for Lyrion Music Server

`LangID` is a small, self-contained language detector for
[Lyrion Music Server](https://lyrion.org/) (LMS). It consists of two parts:

- a static Rust command-line helper, `langid`, built on
  [lingua-rs](https://github.com/pemistahl/lingua-rs) with only the selected
  language models compiled in;
- a minimal Perl wrapper that exposes the helper to LMS and to other plugins.

Everything runs locally: no network access, no Python, no external services.
The helper is a static musl binary, so it also works on old glibc systems such
as the Debian 12 "bookworm" based LMS containers (glibc 2.36).

## Repository layout

```text
Cargo.toml / Cargo.lock     Rust crate `langid`
src/main.rs                 helper CLI (stdin -> JSON)
scripts/build.sh            build the static binary into bin/<platform>/
scripts/smoke.sh            end-to-end checks for the compiled binary
API.pm                      Plugins::LangID::API - async wrapper for LMS
Plugin.pm                   Plugins::LangID::Plugin - LMS plugin entry point
install.xml                 LMS extension descriptor (PLUGIN_LANGID)
VERSION                     plugin version (0.1.0)
strings.txt                 plugin strings
t/api.t                     unit tests for the Perl wrapper
t/fixtures/fake-langid      stand-in binary used by the unit tests
t/lib/                      minimal AnyEvent shim for the unit tests
bin/linux-x86_64/langid     built helper binary (build artefact)
```

The plugin files live in the repository root, matching the usual LMS plugin
repository convention: the archive root is installed as `Plugins/LangID/`, so
`API.pm` becomes `Plugins/LangID/API.pm`.

## Requirements

- Rust/Cargo 1.85 or newer (tested with 1.99) to build the helper;
- `x86_64-unknown-linux-musl` target plus `musl-gcc` for the static build;
- Lyrion Music Server 8.0 or newer and Perl 5.10 or newer to run the plugin;
- the Perl wrapper uses only modules shipped with LMS or Perl core
  (`AnyEvent`, `IPC::Open3`, `JSON::PP`, `Encode`). The tests need no CPAN
  modules at all.

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
| default | `lang-zh`, `lang-en`, `lang-ja`, `lang-ko` | **6,834,432 bytes (6.52 MiB)** |
| extended | default + 12 more languages | 64,379,136 bytes (61.4 MiB) |

Both are `ELF 64-bit LSB pie executable, static-pie linked, stripped` with no
dynamic dependencies.

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
MiB to the binary (the extended build is about 61 MiB); pick the smallest set
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

## Installing the LMS plugin

1. Build the helper for the LMS platform (`./scripts/build.sh` for Linux
   x86_64) and make sure `bin/<platform>/langid` is present.
2. Copy the plugin directory (this repository, including `install.xml`,
   `Plugin.pm`, `API.pm`, `bin/`, `strings.txt` and `VERSION`) to the LMS
   plugins directory, for example `Plugins/LangID` below the LMS server root,
   or `Cache/InstalledPlugins/Plugins/LangID` for a managed installation.
3. Restart LMS and enable **LangID** under *Settings → Plugins*.
4. No settings page is provided; the plugin has no user-facing UI.

`install.xml` declares the extension name `PLUGIN_LANGID`, the module
`Plugins::LangID::Plugin`, minimum LMS version 8.0 and plugin version 0.1.0.

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
```

| Method | Description |
| --- | --- |
| `available()` | true when the helper binary exists and is executable |
| `detect($text, $callback)` | asynchronous detection; invokes `$callback` exactly once |
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

- `cargo test`: 18 tests passed;
- `perl t/api.t`: 40 tests passed (normal, empty input, timeout, crash,
  malformed JSON, missing binary, `--languages`, sanitisation, platform
  mapping);
- `scripts/smoke.sh`: 8 checks passed:

  | Sample | Expected | Language | Confidence |
  | --- | --- | --- | --- |
  | Chinese | `zh` | Chinese | 1.00 |
  | Japanese | `ja` | Japanese | 1.00 |
  | Korean | `ko` | Korean | 1.00 |
  | English | `en` | English | 1.00 |

  plus `--languages`, `--version`, empty input and exit-code checks.

## License and attribution

This project is licensed under the [Apache License, Version 2.0](LICENSE).
See [NOTICE](NOTICE) for the required attribution notices.

It embeds and links:

- [lingua-rs](https://github.com/pemistahl/lingua-rs) 1.8.0, Apache-2.0,
  Copyright © Peter M. Stahl;
- the lingua language model crates (Apache-2.0), which contain the trained
  model data compiled into the helper binary;
- the transitive Rust dependencies listed in `Cargo.lock` (MIT/Apache-2.0
  compatible licenses).
