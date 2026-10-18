#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 - "$BUILD/Models.swift" <<'PY'
from pathlib import Path
import sys
s=Path('ios/Shared/Models.swift').read_text()
a='struct PointerCalibrationContext:'+s.split('struct PointerCalibrationContext:',1)[1].split('struct SessionCommand:',1)[0]
b='enum PilotError:'+s.split('enum PilotError:',1)[1].split('struct SharedFrame:',1)[0]
c='struct ActionProposal:'+s.split('struct ActionProposal:',1)[1].split('struct LogEntry:',1)[0]
Path(sys.argv[1]).write_text('import Foundation\n'+a+b+c)
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Models.swift" ios/Shared/TaskPlanning.swift ios/Shared/PointerCalibration.swift ios/App/PilotPointerCalibration.swift tests/pointer_calibration_test.swift -o "$BUILD/test"
"$BUILD/test"
