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

use fasttext_pure_rs::{FastText, Prediction};
use lingua::{Language, LanguageDetector, LanguageDetectorBuilder};

/// Number of fastText predictions requested by the `suite` command.
pub const FASTLANG_TOP_K: usize = 8;

/// Official location of the fastText language-identification model. The model
/// is *not* embedded in the binary any more; the Perl wrapper downloads it on
/// demand and passes it with `--model`. This URL is only used for help text
/// and documentation.
pub const MODEL_URL: &str = "https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.ftz";

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
       langid suite --target <target> < TEXT

Reads UTF-8 text from standard input and prints language confidence values as
a single JSON object. The detector contains only the language models that were
compiled into the binary.

Options:
  --top N             number of scores to print (default: 5)
  --min-confidence F  ignore languages below confidence F (0.0 - 1.0, default: 0)
  --languages         print the compiled ISO 639-1 codes as a JSON array
  --version           print the version and exit
  -h, --help          show this help

Commands:
  suite --target LANG compare lingua-rs and the fastText model for LANG and
                      print one JSON object per line:
                      {\"target\":\"zh-Hans\",\"lingua\":{...},\"fastlang\":{...}}
                      Supported targets: zh, zh-Hans, zh-Hant, cmn, en, ja, ko
                      --model PATH  fastText lid.176.ftz model file. Without a
                                    usable model fastlang is null and only the
                                    lingua result is reported. The model is not
                                    embedded; LANGID_MODEL_PATH can provide a
                                    default path.
";

/// Parsed command-line options.
#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    pub top: usize,
    pub min_confidence: f64,
    pub languages: bool,
    pub version: bool,
    pub help: bool,
    pub suite: bool,
    pub target: Option<String>,
    pub model: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            top: DEFAULT_TOP,
            min_confidence: 0.0,
            languages: false,
            version: false,
            help: false,
            suite: false,
            target: None,
            model: None,
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

/// Target-language description for the `suite` command.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TargetSpec {
    /// Lowercase ISO 639-1 code reported for both detectors.
    pub iso: &'static str,
    /// lingua display name, also used for the fastText result.
    pub name: &'static str,
    /// lingua language that is scored against the input.
    pub language: Language,
    /// fastText label family: every label that counts as the target language.
    pub fastlang_labels: &'static [&'static str],
}

/// Map a `--target` value to the lingua language and fastText label family.
///
/// Only the languages handled by the music translation detector are
/// supported: Chinese (all script/variant spellings), English, Japanese and
/// Korean. The lookup is case-insensitive. `None` means the target is not
/// supported or its lingua model was not compiled into this binary.
pub fn target_spec(target: &str) -> Option<TargetSpec> {
    match target.trim().to_ascii_lowercase().as_str() {
        #[cfg(feature = "lang-zh")]
        "zh" | "zh-hans" | "zh-hant" | "cmn" => Some(TargetSpec {
            iso: "zh",
            name: "Chinese",
            language: Language::Chinese,
            fastlang_labels: &[
                "zh", "zh-cn", "zh-tw", "zh-hans", "zh-hant", "cmn", "yue", "wuu",
            ],
        }),
        #[cfg(feature = "lang-en")]
        "en" => Some(TargetSpec {
            iso: "en",
            name: "English",
            language: Language::English,
            fastlang_labels: &["en"],
        }),
        #[cfg(feature = "lang-ja")]
        "ja" => Some(TargetSpec {
            iso: "ja",
            name: "Japanese",
            language: Language::Japanese,
            fastlang_labels: &["ja"],
        }),
        #[cfg(feature = "lang-ko")]
        "ko" => Some(TargetSpec {
            iso: "ko",
            name: "Korean",
            language: Language::Korean,
            fastlang_labels: &["ko"],
        }),
        _ => None,
    }
}

/// Load a fastText model from disk. The model is downloaded on demand by the
/// caller (CLI: `--model` / `LANGID_MODEL_PATH`; Perl wrapper: automatic
/// verified download to a cache); the helper itself never opens a network
/// connection.
pub fn load_fasttext(path: &str) -> Result<FastText, String> {
    FastText::load(path)
        .map_err(|error| format!("failed to load the fastText model {path}: {error}"))
}

/// Strip the fastText label prefix and compare case-insensitively against the
/// target language family.
pub fn label_in_family(label: &str, family: &[&str]) -> bool {
    let code = label.strip_prefix("__label__").unwrap_or(label);
    family
        .iter()
        .any(|candidate| candidate.eq_ignore_ascii_case(code))
}

/// Maximum probability among the predictions whose label belongs to
/// `family`, or `0.0` when the family does not occur in the top-k list.
///
/// The probability is clamped to the documented `0.0..=1.0` range: the
/// pure-Rust fastText implementation computes `exp(log_probability)`, which
/// can come out a hair above 1.0 for quantized models such as `lid.176.ftz`.
pub fn best_family_confidence(predictions: &[Prediction], family: &[&str]) -> f64 {
    predictions
        .iter()
        .filter(|prediction| label_in_family(&prediction.label, family))
        .map(|prediction| (prediction.probability as f64).clamp(0.0, 1.0))
        .fold(0.0_f64, f64::max)
}

/// Render the `suite` result object:
/// `{"target":...,"lingua":{"confidence","language","name"},"fastlang":{...}}`.
///
/// `fastlang_confidence` is `None` when no usable fastText model is available;
/// the field is then rendered as `null` and the lingua result stays intact.
pub fn suite_json(
    target: &str,
    spec: &TargetSpec,
    lingua_confidence: f64,
    fastlang_confidence: Option<f64>,
) -> String {
    let lingua = format!(
        "{{\"confidence\":{},\"language\":{},\"name\":{}}}",
        lingua_confidence,
        json_string(spec.iso),
        json_string(spec.name),
    );

    let fastlang = match fastlang_confidence {
        Some(confidence) => format!(
            "{{\"confidence\":{},\"language\":{},\"name\":{}}}",
            confidence,
            json_string(spec.iso),
            json_string(spec.name),
        ),
        None => "null".to_string(),
    };

    format!(
        "{{\"target\":{},\"lingua\":{},\"fastlang\":{}}}",
        json_string(target),
        lingua,
        fastlang,
    )
}

/// Render an error object for the `suite` command.
pub fn error_json(message: &str) -> String {
    format!("{{\"error\":{}}}", json_string(message))
}

fn parse_top(value: &str) -> Result<usize, String> {    value
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
            "suite" => config.suite = true,
            "--target" => {
                let value = args
                    .next()
                    .ok_or_else(|| "--target requires a value".to_string())?;
                config.target = Some(value.as_ref().to_string());
            }
            "--model" => {
                let value = args
                    .next()
                    .ok_or_else(|| "--model requires a value".to_string())?;
                config.model = Some(value.as_ref().to_string());
            }
            other => {
                if let Some(value) = other.strip_prefix("--top=") {
                    config.top = parse_top(value)?;
                } else if let Some(value) = other.strip_prefix("--min-confidence=") {
                    config.min_confidence = parse_min_confidence(value)?;
                } else if let Some(value) = other.strip_prefix("--target=") {
                    config.target = Some(value.to_string());
                } else if let Some(value) = other.strip_prefix("--model=") {
                    config.model = Some(value.to_string());
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

    if config.suite {
        return run_suite(&config);
    }

    if config.target.is_some() {
        println!(
            "{}",
            error_json("--target is only valid with the 'suite' command")
        );
        return Err(EXIT_USAGE);
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

/// Run the `suite` command: score the stdin text with lingua-rs for the
/// requested target language and with the embedded fastText model, then print
/// one JSON object. Unsupported or missing targets produce a JSON error object
/// and exit status 2.
fn run_suite(config: &Config) -> Result<(), u8> {
    let target = match config.target.as_deref() {
        Some(target) if !target.trim().is_empty() => target.trim().to_string(),
        _ => {
            println!(
                "{}",
                error_json("the 'suite' command requires --target <target>")
            );
            return Err(EXIT_USAGE);
        }
    };

    let spec = match target_spec(&target) {
        Some(spec) => spec,
        None => {
            println!("{}", error_json(&format!("unsupported target: {target}")));
            return Err(EXIT_USAGE);
        }
    };

    let mut input = String::new();
    if let Err(error) = io::stdin().read_to_string(&mut input) {
        eprintln!("langid: standard input is not valid UTF-8: {error}");
        return Err(EXIT_INTERNAL);
    }

    let text = sanitize(&input);

    // `--model` wins; otherwise the documented environment fallback is used.
    // No model is not an error: the suite then reports `"fastlang":null`.
    let model_path = config
        .model
        .clone()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            env::var("LANGID_MODEL_PATH")
                .ok()
                .filter(|value| !value.trim().is_empty())
        });

    let lingua_confidence = if text.is_empty() {
        0.0
    } else {
        build_detector().compute_language_confidence(text.as_str(), spec.language)
    };

    // Load the fastText model once. A missing, unreadable or invalid model
    // only disables the fastlang part of the result; lingua always works.
    let fastlang_confidence = match model_path.as_deref() {
        None => {
            eprintln!(
                "langid: no fastText model supplied; use --model <path> or LANGID_MODEL_PATH (model: {MODEL_URL})"
            );
            None
        }
        Some(path) => match load_fasttext(path) {
            Err(message) => {
                eprintln!("langid: {message}; continuing without fastlang");
                None
            }
            Ok(_) if text.is_empty() => {
                // Model is usable, but there is nothing to score.
                Some(0.0_f64)
            }
            Ok(model) => match model.predict(text.as_str(), FASTLANG_TOP_K, 0.0) {
                Ok(predictions) => {
                    Some(best_family_confidence(&predictions, spec.fastlang_labels))
                }
                Err(_) => Some(0.0_f64),
            },
        },
    };

    println!(
        "{}",
        suite_json(&target, &spec, lingua_confidence, fastlang_confidence)
    );

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

    #[cfg(all(feature = "lang-en", feature = "lang-zh"))]
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

    // -----------------------------------------------------------------
    // suite command: target mapping, fastText extraction, JSON contract
    // -----------------------------------------------------------------

    #[cfg(feature = "lang-zh")]
    #[test]
    fn target_mapping_covers_chinese_variants() {
        for target in ["zh", "zh-Hans", "zh-Hant", "cmn", "ZH-hans", " zh "] {
            let spec = target_spec(target).unwrap_or_else(|| panic!("target {target}"));
            assert_eq!(spec.iso, "zh");
            assert_eq!(spec.name, "Chinese");
            assert_eq!(spec.language, Language::Chinese);
            for label in [
                "__label__zh",
                "__label__zh-cn",
                "__label__zh-tw",
                "__label__zh-hans",
                "__label__zh-hant",
                "__label__cmn",
                "__label__yue",
                "__label__wuu",
            ] {
                assert!(
                    label_in_family(label, spec.fastlang_labels),
                    "{label} should belong to the zh family"
                );
            }
            assert!(!label_in_family("__label__en", spec.fastlang_labels));
        }
    }

    #[cfg(feature = "lang-en")]
    #[test]
    fn target_mapping_covers_english() {
        let spec = target_spec("en").expect("en target");
        assert_eq!(spec.iso, "en");
        assert_eq!(spec.name, "English");
        assert_eq!(spec.language, Language::English);
        assert!(label_in_family("__label__en", spec.fastlang_labels));
        assert!(!label_in_family("__label__de", spec.fastlang_labels));
    }

    #[cfg(feature = "lang-ja")]
    #[test]
    fn target_mapping_covers_japanese() {
        let spec = target_spec("ja").expect("ja target");
        assert_eq!(spec.iso, "ja");
        assert_eq!(spec.name, "Japanese");
        assert_eq!(spec.language, Language::Japanese);
    }

    #[cfg(feature = "lang-ko")]
    #[test]
    fn target_mapping_covers_korean() {
        let spec = target_spec("ko").expect("ko target");
        assert_eq!(spec.iso, "ko");
        assert_eq!(spec.name, "Korean");
        assert_eq!(spec.language, Language::Korean);
    }

    #[test]
    fn target_mapping_rejects_unsupported_targets() {
        assert!(target_spec("fr").is_none());
        assert!(target_spec("de-DE").is_none());
        assert!(target_spec("").is_none());
        assert!(target_spec("  ").is_none());
    }

    #[test]
    fn fastlang_extraction_takes_max_probability_in_family() {
        let predictions = [
            Prediction {
                label: "__label__en".to_string(),
                probability: 0.90,
            },
            Prediction {
                label: "__label__zh".to_string(),
                probability: 0.05,
            },
            Prediction {
                label: "__label__zh-cn".to_string(),
                probability: 0.04,
            },
            Prediction {
                label: "__label__ja".to_string(),
                probability: 0.01,
            },
        ];
        let zh_family = [
            "zh", "zh-cn", "zh-tw", "zh-hans", "zh-hant", "cmn", "yue", "wuu",
        ];

        let confidence = best_family_confidence(&predictions, &zh_family);
        assert!((confidence - 0.05).abs() < 1e-6, "got {confidence}");
        assert_eq!(best_family_confidence(&predictions, &["ko"]), 0.0);
        assert!(label_in_family("__label__ZH-HANS", &zh_family));
        assert!(!label_in_family("__label__zhx", &zh_family));
    }

    #[test]
    fn fastlang_extraction_handles_empty_predictions() {
        assert_eq!(best_family_confidence(&[], &["en"]), 0.0);
    }

    #[test]
    fn fastlang_confidence_is_clamped_to_one() {
        let predictions = [
            Prediction {
                label: "__label__zh".to_string(),
                probability: 1.000_06,
            },
            Prediction {
                label: "__label__ja".to_string(),
                probability: -0.5,
            },
        ];
        let confidence = best_family_confidence(&predictions, &["zh"]);
        assert!((confidence - 1.0).abs() < 1e-12, "got {confidence}");
        assert_eq!(best_family_confidence(&predictions, &["ja"]), 0.0);
    }

    #[cfg(feature = "lang-zh")]
    #[test]
    fn suite_json_matches_contract() {
        let spec = target_spec("zh-Hans").expect("zh target");
        assert_eq!(
            suite_json("zh-Hans", &spec, 0.99, Some(0.97)),
            concat!(
                "{\"target\":\"zh-Hans\",",
                "\"lingua\":{\"confidence\":0.99,\"language\":\"zh\",\"name\":\"Chinese\"},",
                "\"fastlang\":{\"confidence\":0.97,\"language\":\"zh\",\"name\":\"Chinese\"}}"
            )
        );
    }

    #[cfg(feature = "lang-zh")]
    #[test]
    fn suite_json_without_model_renders_fastlang_null() {
        let spec = target_spec("zh").expect("zh target");
        assert_eq!(
            suite_json("zh", &spec, 1.0, None),
            concat!(
                "{\"target\":\"zh\",",
                "\"lingua\":{\"confidence\":1,\"language\":\"zh\",\"name\":\"Chinese\"},",
                "\"fastlang\":null}"
            )
        );
    }

    #[test]
    fn parse_args_reads_suite_command_and_target() {
        let config = parse_args(["suite", "--target", "zh-Hans"]).expect("valid suite args");
        assert!(config.suite);
        assert_eq!(config.target.as_deref(), Some("zh-Hans"));
        assert_eq!(config.model, None);

        let config = parse_args(["--target=ja", "suite"]).expect("valid suite args");
        assert!(config.suite);
        assert_eq!(config.target.as_deref(), Some("ja"));

        let config = parse_args(["suite", "--target", "en", "--model", "/tmp/lid.176.ftz"])
            .expect("valid suite args");
        assert_eq!(config.model.as_deref(), Some("/tmp/lid.176.ftz"));

        let config = parse_args(["suite", "--target=en", "--model=/tmp/m.ftz"])
            .expect("valid suite args");
        assert_eq!(config.target.as_deref(), Some("en"));
        assert_eq!(config.model.as_deref(), Some("/tmp/m.ftz"));

        assert!(parse_args(["--target"]).is_err());
        assert!(parse_args(["--model"]).is_err());
    }

    #[test]
    fn fasttext_model_loading_requires_an_existing_file() {
        let missing = "/nonexistent/lid.176.ftz";
        let error = load_fasttext(missing).expect_err("missing model must fail");
        assert!(error.contains(missing), "unexpected error: {error}");
    }

}
