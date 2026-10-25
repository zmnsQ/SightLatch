#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 tests/calibration_test_support.py "$BUILD"
python3 - "$BUILD/Gate.swift" <<'PY'
from pathlib import Path
import sys
s = Path('ios/Shared/Network.swift').read_text()
a = s.index('enum MessageScopePolicy {')
b = s.index('// One validation path', a)
Path(sys.argv[1]).write_text('import Foundation\n' + s[a:b])
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Models.swift" "$BUILD/SharedStore.swift" "$BUILD/Gate.swift" tests/message_scope_test.swift -o "$BUILD/test"
SIGHTLATCH_TEST_STORE="$BUILD/store" "$BUILD/test"

python3 - "$BUILD/LaunchHost.swift" <<'PYHOST'
from pathlib import Path
import sys
s = Path('ios/App/PilotViewModel.swift').read_text()
a = s.index('    private func launchMessageAppIfNeeded()')
b = s.index('    @discardableResult\n    func save()', a)
methods = s[a:b].replace('    private func ', '    func ')
Path(sys.argv[1]).write_text('import Foundation\n@MainActor final class PilotViewModel {\nvar stopping = false\nvar captureObservation: CaptureObservation?\nvar taskFlow = TaskPlanningState()\nvar notice = ""\n' + methods + '}\n')
PYHOST
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Models.swift" "$BUILD/SharedStore.swift" ios/Shared/TaskPlanning.swift "$BUILD/LaunchHost.swift" tests/message_launch_host_test.swift -o "$BUILD/launch-test"
SIGHTLATCH_TEST_STORE="$BUILD/store" "$BUILD/launch-test"
