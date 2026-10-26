#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 - "$BUILD" <<'PY'
from pathlib import Path
import sys
source = Path('ios/App/VoiceTaskComposer.swift').read_text()
start = source.index('struct VoiceFeedbackPlaybackGate {')
end = source.index('/// App-only output preferences.', start)
Path(sys.argv[1], 'PlaybackGate.swift').write_text('import Foundation\n' + source[start:end])
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/PlaybackGate.swift" \
    tests/voice_feedback_playback_test.swift -o "$BUILD/test"
"$BUILD/test"
