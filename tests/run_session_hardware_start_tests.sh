#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 tests/calibration_test_support.py "$BUILD"
python3 - "$BUILD/Network.swift" <<'PY'
from pathlib import Path
import sys
source = Path('ios/Shared/Network.swift').read_text()
Path(sys.argv[1]).write_text('import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n' + source[source.index('struct HTTPStatusFailure:'):])
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Models.swift" "$BUILD/SharedStore.swift" "$BUILD/Network.swift" tests/session_hardware_start_test.swift -o "$BUILD/test"
SIGHTLATCH_TEST_STORE="$BUILD/store" "$BUILD/test"
