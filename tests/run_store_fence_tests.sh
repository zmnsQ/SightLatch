#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-swiftc}"
SOURCE_ROOT="${SOURCE_ROOT:-.}"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
mkdir "$BUILD/store"
python3 - "$SOURCE_ROOT/ios/Shared/SharedStore.swift" "$BUILD/SharedStore.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text().split('enum SecretStore', 1)[0]
source = source.replace('import Security\n', '').replace('import Darwin', 'import Glibc')
start = source.index('    private var directory: URL? {')
end = source.index('    var available:', start)
source = source[:start] + '    private var directory: URL? { URL(fileURLWithPath: ProcessInfo.processInfo.environment["SIGHTLATCH_TEST_STORE"]!) }\n' + source[end:]
source = source.replace('[.atomic, .completeFileProtection]', '[.atomic]').replace('[.atomic, .completeFileProtectionUntilFirstUserAuthentication]', '[.atomic]')
Path(sys.argv[2]).write_text(source)
PY
"$SWIFTC" -module-cache-path "$BUILD/cache" "$BUILD/SharedStore.swift" tests/shared_store_fence_test.swift -o "$BUILD/store-tests"
SIGHTLATCH_TEST_STORE="$BUILD/store" "$BUILD/store-tests"
