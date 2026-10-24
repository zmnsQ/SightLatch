#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 tests/calibration_test_support.py "$BUILD"
python3 - "$BUILD/Production.swift" <<'PY'
from pathlib import Path
import sys
models=Path('ios/Shared/Models.swift').read_text().replace('import ActivityKit\n','')
models=models[:models.index('struct PilotActivityAttributes:')]+models[models.index('enum PilotError:'):]
network=Path('ios/Shared/Network.swift').read_text()
network=network[network.index('struct HTTPStatusFailure:'):]
Path(sys.argv[1]).write_text('import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n'+models+network)
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Production.swift" "$BUILD/SharedStore.swift" tests/absolute_pointer_test.swift -o "$BUILD/test"
SIGHTLATCH_TEST_STORE="$BUILD/store" "$BUILD/test"
