#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
mkdir "$BUILD/store"
python3 - "$BUILD" <<'PY'
from pathlib import Path
import sys
build = Path(sys.argv[1])
models = Path('ios/Shared/Models.swift').read_text().replace('import ActivityKit\n', '')
a = models.index('struct PilotActivityAttributes:')
b = models.index('enum PilotError:', a)
build.joinpath('Models.swift').write_text(models[:a] + models[b:])
store = Path('ios/Shared/SharedStore.swift').read_text().split('enum SecretStore', 1)[0]
store = store.replace('import Security\n', '').replace('import Darwin',
    '#if canImport(Darwin)\nimport Darwin\n#elseif canImport(Glibc)\nimport Glibc\n#endif')
a = store.index('    private var directory: URL? {')
b = store.index('    var available:', a)
store = store[:a] + '    private var directory: URL? { URL(fileURLWithPath: ProcessInfo.processInfo.environment["SIGHTLATCH_TEST_STORE"]!) }\n' + store[b:]
store = store.replace('[.atomic, .completeFileProtection]', '[.atomic]').replace(
    '[.atomic, .completeFileProtectionUntilFirstUserAuthentication]', '[.atomic]')
build.joinpath('SharedStore.swift').write_text(store)
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Models.swift" "$BUILD/SharedStore.swift" \
    tests/session_execution_start_test.swift -o "$BUILD/test"
SIGHTLATCH_TEST_STORE="$BUILD/store" "$BUILD/test"
