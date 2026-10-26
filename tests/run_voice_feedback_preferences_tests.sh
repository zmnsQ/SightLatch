#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 - "$BUILD" <<'PY'
from pathlib import Path
import sys
source = Path('ios/App/VoiceTaskComposer.swift').read_text()
start = source.index('struct VoiceFeedbackVoiceOption:')
end = source.index('struct VoiceFeedbackSettingsView:', start)
Path(sys.argv[1], 'VoicePreferences.swift').write_text(
    'import Foundation\nimport AVFoundation\nimport Combine\n' + source[start:end])
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/VoicePreferences.swift" \
    ios/App/FishSpeechClient.swift tests/voice_feedback_preferences_test.swift -o "$BUILD/test"
"$BUILD/test"
