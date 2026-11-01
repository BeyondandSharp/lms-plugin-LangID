//! `langid` — a tiny, offline language-identification CLI for the Lyrion
//! Music Server `LangID` plugin.
//!
//! The process reads UTF-8 text from standard input, normalises it, asks the
//! lingua-rs detector for confidence values and prints a single JSON object on
//! standard output:
//!
//! ```json
//! {
//!   "language": "Chinese",
//!   "iso": "zh",
//!   "confidence": 0.9992,
//!   "scores": [
//!     { "language": "Chinese", "confidence": 0.9992 },
//!     { "language": "Japanese", "confidence": 0.0004 }
//!   ]
//! }
//! ```
//!
//! Empty or blank input yields
//! `{"language":null,"confidence":0,"scores":[]}` and exit status 0.
//!
//! `--languages` prints the ISO 639-1 codes of all models compiled into this
//! binary as a JSON array, which lets the Perl wrapper report its capabilities
//! without hard-coding a language list.

use std::cmp::Ordering;
use std::env;
use std::io::{self, Read, Write};
use std::process::ExitCode;

use lingua::{Language, LanguageDetector, LanguageDetectorBuilder};

/// Maximum number of characters handed to the detector. lingua slows down on
/// very long input and the extra text does not improve accuracy, so the input
/// is truncated after normalisation.
pub const MAX_CHARS: usize = 16_000;

/// Default number of entries in the `scores` array.
pub const DEFAULT_TOP: usize = 5;

/// Exit status for invalid command-line arguments.
pub const EXIT_USAGE: u8 = 2;

/// Exit status for internal errors such as invalid UTF-8 on standard input.
pub const EXIT_INTERNAL: u8 = 3;

const USAGE: &str = "\
Usage: langid [OPTIONS] < TEXT

Reads UTF-8 text from standard input and prints language confidence values as
a single JSON object. The detector contains only the language models that were
compiled into the binary.

Options:
  --top N             number of scores to print (default: 5)
  --min-confidence F  ignore languages below confidence F (0.0 - 1.0, default: 0)
  --languages         print the compiled ISO 639-1 codes as a JSON array
  --version           print the version and exit
  -h, --help          show this help
";

/// Parsed command-line options.
#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    pub top: usize,
    pub min_confidence: f64,
    pub languages: bool,
    pub version: bool,
    pub help: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            top: DEFAULT_TOP,
            min_confidence: 0.0,
            languages: false,
            version: false,
            help: false,
        }
    }
}

/// Normalise detector input: strip control characters, collapse whitespace
/// runs into a single space, trim the result and cap it at [`MAX_CHARS`]
/// characters.
pub fn sanitize(input: &str) -> String {
    let mut output = String::with_capacity(input.len().min(MAX_CHARS * 4));
    let mut written = 0usize;
    let mut pending_space = false;
    let mut started = false;

    for ch in input.chars() {
        if written >= MAX_CHARS {
            break;
        }

        if ch == '\u{feff}' {
            // Byte order mark: not visible text, drop it.
            continue;
        }

        if ch.is_control() && !ch.is_whitespace() {
            // ASCII/Latin-1 control characters such as NUL, BEL or ESC.
            continue;
        }

        if ch.is_whitespace() {
            if started {
                pending_space = true;
            }
            continue;
        }

        if pending_space && written < MAX_CHARS {
            output.push(' ');
            written += 1;
            if written >= MAX_CHARS {
                break;
            }
        }
        pending_space = false;
        started = true;
        output.push(ch);
        written += 1;
    }

    output
}

/// ISO 639-1 code of a lingua language, lowercase (for example `zh`).
pub fn iso_code(language: Language) -> String {
    language.iso_code_639_1().to_string()
}

/// Escape a string for embedding in a JSON string literal. Language names and
/// ISO codes are ASCII, but keeping this strict makes the writer reusable.
fn json_escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            ch if (ch as u32) < 0x20 => {
                escaped.push_str(&format!("\\u{:04x}", ch as u32));
            }
            ch => escaped.push(ch),
        }
    }
    escaped
}

/// Render a JSON string literal (including the surrounding quotes).
fn json_string(value: &str) -> String {
    format!("\"{}\"", json_escape(value))
}

/// Render the detector result for `scores` (already filtered and truncated,
/// sorted by descending confidence).
pub fn output_json(scores: &[(Language, f64)]) -> String {
    match scores.first() {
        None => "{\"language\":null,\"confidence\":0,\"scores\":[]}".to_string(),
        Some((language, confidence)) => {
            let scores_json = scores
                .iter()
                .map(|(language, confidence)| {
                    format!(
                        "{{\"language\":{},\"confidence\":{}}}",
                        json_string(&language.to_string()),
                        confidence
                    )
                })
                .collect::<Vec<_>>()
                .join(",");

            format!(
                "{{\"language\":{},\"iso\":{},\"confidence\":{},\"scores\":[{}]}}",
                json_string(&language.to_string()),
                json_string(&iso_code(*language)),
                confidence,
                scores_json
            )
        }
    }
}

/// Render the ISO 639-1 codes of all compiled language models as a sorted JSON
/// array of strings.
pub fn languages_json() -> String {
    let mut codes: Vec<String> = Language::all().into_iter().map(iso_code).collect();
    codes.sort();
    codes.dedup();
    format!(
        "[{}]",
        codes
            .iter()
            .map(|code| json_string(code))
            .collect::<Vec<_>>()
            .join(",")
    )
}

fn parse_top(value: &str) -> Result<usize, String> {
    value
        .parse::<usize>()
        .map_err(|_| format!("invalid value for --top: {value}"))
}

fn parse_min_confidence(value: &str) -> Result<f64, String> {
    let parsed = value
        .parse::<f64>()
        .map_err(|_| format!("invalid value for --min-confidence: {value}"))?;
    if !parsed.is_finite() || !(0.0..=1.0).contains(&parsed) {
        return Err(format!(
            "invalid value for --min-confidence: {value} (expected 0.0 - 1.0)"
        ));
    }
    Ok(parsed)
}

/// Parse command-line arguments (without the program name).
pub fn parse_args<I, T>(args: I) -> Result<Config, String>
where
    I: IntoIterator<Item = T>,
    T: AsRef<str>,
{
    let mut config = Config::default();
    let mut args = args.into_iter();

    while let Some(arg) = args.next() {
        match arg.as_ref() {
            "--top" => {
                let value = args
                    .next()
                    .ok_or_else(|| "--top requires a value".to_string())?;
                config.top = parse_top(value.as_ref())?;
            }
            "--min-confidence" => {
                let value = args
                    .next()
                    .ok_or_else(|| "--min-confidence requires a value".to_string())?;
                config.min_confidence = parse_min_confidence(value.as_ref())?;
            }
            "--languages" => config.languages = true,
            "--version" | "-V" => config.version = true,
            "-h" | "--help" => config.help = true,
            other => {
                if let Some(value) = other.strip_prefix("--top=") {
                    config.top = parse_top(value)?;
                } else if let Some(value) = other.strip_prefix("--min-confidence=") {
                    config.min_confidence = parse_min_confidence(value)?;
                } else {
                    return Err(format!("unknown option or argument: {other}"));
                }
            }
        }
    }

    Ok(config)
}

/// Build the detector from all language models compiled into this binary.
fn build_detector() -> LanguageDetector {
    LanguageDetectorBuilder::from_all_languages().build()
}

/// Detect the language of `text` and return the (filtered, truncated) scores.
pub fn detect_scores(detector: &LanguageDetector, text: &str, config: &Config) -> Vec<(Language, f64)> {
    let mut scores = detector.compute_language_confidence_values(text);
    // lingua documents descending confidence order, but never rely on the
    // ordering contract of a dependency for output stability.
    scores.sort_by(|left, right| {
        right
            .1
            .partial_cmp(&left.1)
            .unwrap_or(Ordering::Equal)
    });
    scores.retain(|(_, confidence)| *confidence >= config.min_confidence);
    scores.truncate(config.top);
    scores
}

fn run() -> Result<(), u8> {
    let config = match parse_args(env::args().skip(1)) {
        Ok(config) => config,
        Err(message) => {
            eprintln!("langid: {message}");
            eprintln!("Try 'langid --help' for more information.");
            return Err(EXIT_USAGE);
        }
    };

    if config.help {
        print!("{USAGE}");
        let _ = io::stdout().flush();
        return Ok(());
    }

    if config.version {
        println!("langid {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }

    if config.languages {
        println!("{}", languages_json());
        return Ok(());
    }

    let mut input = String::new();
    if let Err(error) = io::stdin().read_to_string(&mut input) {
        eprintln!("langid: standard input is not valid UTF-8: {error}");
        return Err(EXIT_INTERNAL);
    }

    let text = sanitize(&input);

    // An empty text has no language and no scores. This mirrors the Perl
    // wrapper, which short-circuits empty strings, but the binary is correct
    // on its own as well.
    if text.is_empty() {
        println!("{}", output_json(&[]));
        return Ok(());
    }

    let detector = build_detector();
    let scores = detect_scores(&detector, &text, &config);
    println!("{}", output_json(&scores));

    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(code) => ExitCode::from(code),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_collapses_whitespace_runs() {
        assert_eq!(sanitize("  hello \n\t  world \r\n"), "hello world");
    }

    #[test]
    fn sanitize_trims_leading_and_trailing_whitespace() {
        assert_eq!(sanitize(" \t\n text \n\t "), "text");
    }

    #[test]
    fn sanitize_strips_control_characters() {
        assert_eq!(sanitize("a\u{0000}b\u{0007}c"), "abc");
        assert_eq!(sanitize("\u{001b}[31mred\u{001b}[0m"), "[31mred[0m");
    }

    #[test]
    fn sanitize_drops_byte_order_mark() {
        assert_eq!(sanitize("\u{feff}hello"), "hello");
    }

    #[test]
    fn sanitize_keeps_unicode_text() {
        assert_eq!(sanitize(" 这是  一个测试。 "), "这是 一个测试。");
    }

    #[test]
    fn sanitize_empty_and_whitespace_only_input() {
        assert_eq!(sanitize(""), "");
        assert_eq!(sanitize(" \n\t\r "), "");
    }

    #[test]
    fn sanitize_limits_input_to_max_characters() {
        let input = "a".repeat(MAX_CHARS * 2);
        assert_eq!(sanitize(&input).chars().count(), MAX_CHARS);

        let unicode = "中".repeat(MAX_CHARS * 2);
        assert_eq!(sanitize(&unicode).chars().count(), MAX_CHARS);
    }

    #[test]
    fn empty_result_renders_expected_json() {
        assert_eq!(
            output_json(&[]),
            "{\"language\":null,\"confidence\":0,\"scores\":[]}"
        );
    }

    #[test]
    fn result_renders_expected_json() {
        let scores = [(Language::English, 0.9876), (Language::Chinese, 0.0123)];
        assert_eq!(
            output_json(&scores),
            concat!(
                "{\"language\":\"English\",\"iso\":\"en\",\"confidence\":0.9876,",
                "\"scores\":[{\"language\":\"English\",\"confidence\":0.9876},",
                "{\"language\":\"Chinese\",\"confidence\":0.0123}]}"
            )
        );
    }

    #[test]
    fn json_escape_handles_special_characters() {
        assert_eq!(json_escape("a\"b\\c\nd"), "a\\\"b\\\\c\\nd");
        assert_eq!(json_escape("plain"), "plain");
    }

    #[test]
    fn iso_codes_are_lowercase() {
        #[cfg(feature = "lang-zh")]
        assert_eq!(iso_code(Language::Chinese), "zh");
        #[cfg(feature = "lang-en")]
        assert_eq!(iso_code(Language::English), "en");
        #[cfg(feature = "lang-ja")]
        assert_eq!(iso_code(Language::Japanese), "ja");
        #[cfg(feature = "lang-ko")]
        assert_eq!(iso_code(Language::Korean), "ko");
    }

    #[test]
    fn languages_json_lists_compiled_models() {
        let json = languages_json();
        assert!(json.starts_with('['), "unexpected JSON: {json}");
        assert!(json.ends_with(']'), "unexpected JSON: {json}");
        #[cfg(feature = "lang-zh")]
        assert!(json.contains("\"zh\""), "missing zh in {json}");
        #[cfg(feature = "lang-en")]
        assert!(json.contains("\"en\""), "missing en in {json}");
        #[cfg(feature = "lang-ja")]
        assert!(json.contains("\"ja\""), "missing ja in {json}");
        #[cfg(feature = "lang-ko")]
        assert!(json.contains("\"ko\""), "missing ko in {json}");
    }

    #[test]
    fn parse_args_defaults() {
        assert_eq!(parse_args(Vec::<String>::new()), Ok(Config::default()));
    }

    #[test]
    fn parse_args_reads_options() {
        let config = parse_args([
            "--top",
            "8",
            "--min-confidence=0.25",
            "--languages",
            "--version",
        ])
        .expect("valid arguments");
        assert_eq!(config.top, 8);
        assert_eq!(config.min_confidence, 0.25);
        assert!(config.languages);
        assert!(config.version);
    }

    #[test]
    fn parse_args_rejects_invalid_values() {
        assert!(parse_args(["--top", "many"]).is_err());
        assert!(parse_args(["--top"]).is_err());
        assert!(parse_args(["--min-confidence", "1.5"]).is_err());
        assert!(parse_args(["--min-confidence", "NaN"]).is_err());
        assert!(parse_args(["--bogus"]).is_err());
        assert!(parse_args(["stray"]).is_err());
    }

    #[test]
    fn detect_scores_applies_min_confidence_and_top() {
        let detector = build_detector();
        let config = Config {
            top: 2,
            min_confidence: 0.0,
            ..Config::default()
        };
        let scores = detect_scores(&detector, "This is an English sentence.", &config);
        assert!(!scores.is_empty());
        assert!(scores.len() <= 2);
        assert!(scores.windows(2).all(|pair| pair[0].1 >= pair[1].1));
    }

    #[cfg(feature = "lang-zh")]
    #[test]
    fn detector_identifies_chinese() {
        let detector = build_detector();
        let scores = detect_scores(
            &detector,
            "这是一个用来测试语言检测的句子。",
            &Config::default(),
        );
        assert_eq!(scores[0].0, Language::Chinese);
        assert_eq!(iso_code(scores[0].0), "zh");
    }

    #[cfg(feature = "lang-en")]
    #[test]
    fn detector_identifies_english() {
        let detector = build_detector();
        let scores = detect_scores(
            &detector,
            "This is a test sentence written in English.",
            &Config::default(),
        );
        assert_eq!(scores[0].0, Language::English);
        assert_eq!(iso_code(scores[0].0), "en");
    }
}
