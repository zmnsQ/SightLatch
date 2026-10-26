#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 tests/calibration_test_support.py "$BUILD"
python3 - "$BUILD" <<'PY'
from pathlib import Path
import sys
build = Path(sys.argv[1])
home = Path('ios/App/HomeView.swift').read_text()
state = 'enum HomeCaptureState:' + home.split('enum HomeCaptureState:', 1)[1].split('/// A local prompt,', 1)[0]
build.joinpath('HomeState.swift').write_text('import Foundation\n' + state)
manager = Path('ios/App/PilotActivityManager.swift').read_text()
method = '    static func presentationStatus(' + manager.split('    static func presentationStatus(', 1)[1].split('    private func isCurrent(', 1)[0]
build.joinpath('ActivityState.swift').write_text('import Foundation\nenum ActivityPresentationUnderTest {\n' + method + '}\n')
workspace = Path('ios/App/Workspace.swift').read_text()
recovery = 'struct RecoveryAdvice {' + workspace.split('struct RecoveryAdvice {', 1)[1].split('extension PilotViewModel', 1)[0]
build.joinpath('RecoveryAdvice.swift').write_text('import Foundation\n' + recovery)
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Models.swift" "$BUILD/HomeState.swift" "$BUILD/ActivityState.swift" "$BUILD/RecoveryAdvice.swift" \
    ios/Shared/PilotActivityPresentation.swift tests/home_session_state_test.swift -o "$BUILD/test"
"$BUILD/test"
