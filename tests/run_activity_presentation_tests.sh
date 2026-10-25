#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 - "$BUILD" <<'PY'
from pathlib import Path
import sys
models = Path('ios/Shared/Models.swift').read_text()
attributes = 'struct PilotActivityAttributes' + models.split('struct PilotActivityAttributes', 1)[1].split('enum PilotError:', 1)[0]
attributes = attributes.replace(': ActivityAttributes', '', 1)
attributes = models[models.index('struct PilotClarificationAction:'):models.index('/// Pure transition rules')] + attributes
Path(sys.argv[1], 'Attributes.swift').write_text('import Foundation\n' + attributes)
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Attributes.swift" \
    ios/Shared/PilotActivityPresentation.swift tests/PilotActivityPresentationTests.swift -o "$BUILD/test"
"$BUILD/test"
