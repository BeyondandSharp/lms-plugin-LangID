# fastText language-identification model (downloaded on demand)

The fastText model is **not shipped with LangID** and is **not embedded in the
helper binary**. It is downloaded on first use by the Perl wrapper
(`Plugins::LangID::API->detect_suite`) and cached for later calls. The CLI
accepts the model path with `--model <path>` (or `LANGID_MODEL_PATH`); without
a usable model the `suite` command returns the lingua result and
`"fastlang":null`.

## Model file

| Property | Value |
| --- | --- |
| File name | `lid.176.ftz` |
| Size | 938,013 bytes |
| SHA-256 | `8f3472cfe8738a7b6099e8e999c3cbfae0dcd15696aac7d7738a8039db603e83` |
| Format | fastText binary format version 12, product-quantized (`.ftz`) |
| Labels | 176 languages (`__label__<ISO 639-1>`) |
| Download URL | <https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.ftz> |

The Perl wrapper verifies the downloaded file against the size and SHA-256
above, sets mode `0644`, and atomically renames the temporary file into place.
The helper itself never performs network I/O: it only loads the file it is
given via `--model`.

## Cache location and environment overrides

| Variable | Meaning |
| --- | --- |
| `LANGID_MODEL_PATH` | exact model file to use (no cache logic) |
| `LANGID_MODEL_DIR` | cache directory; default is `<LMS prefs dir>/langid`, i.e. `lid.176.ftz` below it |
| `LANGID_MODEL_URL` | download URL (default: the official URL above) |

To pre-seed an offline installation, place a verified `lid.176.ftz` in the
cache directory or point `LANGID_MODEL_PATH` at it. If the download fails, the
plugin logs a warning and continues with lingua-only detection, so
translation detection keeps working.

## Source and attribution

The model is the official fastText language-identification model distributed
by Facebook (Meta) AI Research:

- Source URL:
  <https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.ftz>
- fastText project: <https://fasttext.cc/>
- fastText source code: <https://github.com/facebookresearch/fastText>
- Attribution: © Facebook, Inc. and the fastText contributors.

The model is not part of the Apache-2.0 licensed LangID source code and is not
redistributed by this repository. It is downloaded by the user's LMS at
runtime.

## License

The model is licensed under the **Creative Commons
Attribution-ShareAlike 3.0 Unported** license (CC BY-SA 3.0):

- License summary: <https://creativecommons.org/licenses/by-sa/3.0/>
- Full legal code: <https://creativecommons.org/licenses/by-sa/3.0/legalcode>
- Local copy of the full legal code: [`models/LICENSE`](LICENSE)

The downloaded model file remains under CC BY-SA 3.0. Keep the attribution
above (and this directory's README/LICENSE) when redistributing the model
file. Since the model is no longer vendored, the LangID source and helper
binary themselves do not contain CC BY-SA model data; see the "License and
attribution" section of the top-level [`README.md`](../README.md) and
[`NOTICE`](../NOTICE).
