#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 - "$BUILD/Error.swift" <<'PY'
from pathlib import Path
import sys
s=Path('ios/Shared/Models.swift').read_text()
Path(sys.argv[1]).write_text('import Foundation\nenum PilotError:'+s.split('enum PilotError:',1)[1].split('struct SharedFrame:',1)[0])
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Error.swift" ios/Shared/AutomaticCalibration.swift tests/automatic_calibration_fit_test.swift -o "$BUILD/test"
"$BUILD/test"
