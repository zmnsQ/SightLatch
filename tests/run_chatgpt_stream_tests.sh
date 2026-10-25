#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 - "$BUILD/Stream.swift" <<'PY'
from pathlib import Path
import sys
s = Path('ios/Shared/ChatGPTPlanClient.swift').read_text()
Path(sys.argv[1]).write_text(s.split('actor ChatGPTPlanClient', 1)[0])
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Stream.swift" tests/chatgpt_stream_test.swift -o "$BUILD/stream-test"
"$BUILD/stream-test"
