# Gipformer Captions

Vietnamese captions on Apple Silicon: a `captions.transcribe` provider (`bashcut.gipformer-captions`) that runs the
Gipformer 1.5 model (68M, G-Group AI Lab, MIT) through a statically linked sherpa-onnx (Apache-2.0). One arm64
binary, no Python. Installing downloads about 345 MB of model files (int8, 73 MB, and fp32, 270 MB) and the Silero voice detector, each checked
against a pinned SHA-256.

Options: `vocabulary` (names spelled as typed, uses beam search with hotwords), `maxCharacters`, and `voiceDetection`
(on skips silence and music; off cuts the audio into windows of about 20 s at quiet points, for audio with constant
background noise), and `precision` (`int8` by default; `fp32` is about a third slower and gets a few more words
right in songs and difficult recordings). The model outputs UPPERCASE text without punctuation, so captions are lowercased with a capital at
each caption start.

## Files

- `bin/provider`: the entrypoint, built by `build.sh` (not in git)
- `bin/setup`, `bin/check`: model install recipe and probe (keep their file tables identical)
- `build.sh`: downloads the pinned sherpa-onnx static libraries into `.native/` and builds `bin/provider`; not shipped
- `src/`: `Handlers.swift` (request), `Audio.swift`, `Segmenter.swift`, `Recognizer.swift`, `Captions.swift`,
  `main.swift` (protocol), and `c-api.h` + `SherpaOnnx.swift` vendored from sherpa-onnx v1.13.8
- `resources/bpe.vocab`: generated from the pinned model's `bpe.model` (command in `build.sh`), needed for hotwords
- `licenses/`: third-party notices
- `skills/`: the agent skill; `tests/test_provider.py`: tests in `GIPFORMER_FAKE=1` mode (no model); not shipped

## Test

```sh
cd plugins/gipformer-captions
./build.sh
python3 -m unittest discover -s tests -v
```

With the models installed (`bin/setup`), run the provider without `GIPFORMER_FAKE` for real transcription.

## Try it in BashCut

Link this folder into BashCut's plugin folder (the monorepo's `scripts/dev-link.sh` does this for plugins under
`plugins/`), open **Plugins** in BashCut, choose **Trust**, then install the dependency.

Packaging and registry publishing (`package.py`, `listing.json`) belong to the
[bashcut-plugins](https://github.com/dongnguyenvie/bashcut-plugins) monorepo; copy this folder to
`plugins/gipformer-captions` there to publish.
