#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" \
    ios/App/FishSpeechClient.swift tests/fish_speech_test.swift -o "$BUILD/test"
"$BUILD/test"
