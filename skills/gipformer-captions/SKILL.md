---
name: gipformer-captions
description: Transcribe Vietnamese speech into captions with the local Gipformer plugin, choose it over Whisper for Vietnamese or noisy audio, set its vocabulary and voice detection options, and check the result. Use when the user wants Vietnamese captions or subtitles, or when Vietnamese Whisper captions miss words. Triggers: "phụ đề tiếng Việt", "tạo sub", "nhận giọng nói", "gipformer", "âm thanh nhiều tạp âm", "Vietnamese captions", "subtitles".
---

# Gipformer captions

Gipformer Captions provides `captions.transcribe` for Vietnamese speech on this Mac (Gipformer 1.5, 68M, through
sherpa-onnx). Nothing leaves the Mac. The bc:captions-text skill covers caption style and placement; this one covers
getting the words right.

## Gipformer or Whisper

- Use Gipformer for Vietnamese speech, including phone or call-centre recordings and audio with background noise. It
  is small and fast, and needs Apple Silicon (Intel Macs are not supported).
- Use Whisper Captions (`bashcut.whisper-captions.local`) for any other language, or when the user wants punctuation:
  Gipformer's text has none, so captions are lowercase with a capital at the start of each caption.

## Before transcribing

1. Place the clips on the timeline first: captions follow the clips where the media is heard.
2. Put the names and terms of this video in the `vocabulary` option (project scope, comma separated, up to 500
   characters): `bashcut plugins option bashcut.gipformer-captions --option vocabulary --value "Buôn Đôn, Buôn Ma Thuột"`.
   They are spelled as typed. A vocabulary makes transcription slower (beam search).
3. `voiceDetection` (project scope, default on) skips silence and music. Turn it off when constant background noise
   makes captions miss speech:
   `bashcut plugins option bashcut.gipformer-captions --option voiceDetection --value false`. With it off, noise-only
   stretches are also decoded, so check for stray words.
4. `maxCharacters` (user scope, 16–84, default 42) splits long sentences; vertical video reads better around 32.

## Transcribe

1. `bashcut media list` to find the media that has the speech.
2. `bashcut captions generate --media <id> --provider bashcut.gipformer-captions.local` (add `--replace` to redo that
   media's captions, `--from`/`--to` in source seconds for one part, `--word-style highlight|karaoke|reveal` for words
   as they are spoken). It is a background job: poll `bashcut jobs status` until it finishes.

## Check

- Read the captions with `bashcut timeline get --format text` and look for misspelled names. Add them to
  `vocabulary` and run again with `--replace`, rather than fixing many captions by hand.
- If speech is missing, retry with `voiceDetection` off; if stray words appear in noise, turn it back on.
- Look at one frame with `bashcut ui frame <frame>` to confirm the captions fit the safe area.

## When it fails

- "Gipformer is not installed yet": Plugins shows "Install Dependencies…" for the model (about 75 MB). Only the user
  can approve that; tell them, and do not retry until they have.
- "Gipformer only transcribes Vietnamese": the language is another one; use Whisper Captions.
- "No speech found in this media": silent or music-only media; say so instead of retrying.
- "Cannot open media": the file's container is not readable by macOS (some MKV or WebM); convert it first.
