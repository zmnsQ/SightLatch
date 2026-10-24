#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 - "$BUILD" <<'PY'
from pathlib import Path
import sys
source = Path('ios/App/VoiceTaskComposer.swift').read_text()
start = source.index('struct SessionVoiceDeadline {')
end = source.index('/// Explicit, bounded, on-device session listening.', start)
Path(sys.argv[1], 'VoiceDeadline.swift').write_text('import Foundation\n' + source[start:end])
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/VoiceDeadline.swift" \
    tests/voice_deadline_test.swift -o "$BUILD/test"
"$BUILD/test"
