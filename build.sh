#!/bin/sh
# Builds bin/provider (arm64 only: sherpa-onnx is linked statically, onnxruntime included) from src/*.swift.
# CI and scripts/package.py run it before the tests and before packaging; run it locally after changing src/.
#
# Pins: update the version, the archive hash and src/c-api.h + src/SherpaOnnx.swift together. resources/bpe.vocab comes
# from the pinned model's bpe.model:
#   uv run --with sentencepiece python scripts/export_bpe_vocab.py --bpe-model bpe.model   (sherpa-onnx, same tag)
set -eu
SHERPA_VERSION=1.13.8
SHERPA_SHA256=9091bf160dc7fdacedbc906b212badf53c2993f4e5277a0e03998e96c31d60da
here="$(cd "$(dirname "$0")" && pwd)"
native="$here/.native"
archive="sherpa-onnx-v$SHERPA_VERSION-osx-arm64-static-lib"
lib="$native/$archive/lib"
if [ ! -f "$lib/libsherpa-onnx-c-api.a" ]; then
    mkdir -p "$native"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl --fail --location --silent --show-error \
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$SHERPA_VERSION/$archive.tar.bz2" -o "$tmp/lib.tar.bz2"
    echo "$SHERPA_SHA256  $tmp/lib.tar.bz2" | shasum -a 256 -c - >/dev/null
    rm -rf "$native/$archive"
    tar -xjf "$tmp/lib.tar.bz2" -C "$native"
fi
mkdir -p "$here/bin"
swiftc -O -swift-version 5 -target arm64-apple-macos13 -import-objc-header "$here/src/bridging-header.h" -I "$here/src" \
    "$here"/src/*.swift -o "$here/bin/provider" -L "$lib" \
    -lsherpa-onnx-c-api -lsherpa-onnx-core -lkaldi-decoder-core -lsherpa-onnx-kaldifst-core -lsherpa-onnx-fstfar \
    -lsherpa-onnx-fst -lkaldi-native-fbank-core -lkissfft-float -lpiper_phonemize -lespeak-ng -lucd \
    -lssentencepiece_core -lonnxruntime -lc++ -framework Foundation -framework AVFoundation -Xlinker -dead_strip
strip -x "$here/bin/provider"
codesign --force --sign - "$here/bin/provider" 2>/dev/null || true
echo "Built $here/bin/provider ($(lipo -archs "$here/bin/provider"))"
