#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 - "$BUILD/SafetyGate.swift" <<'PY'
from pathlib import Path
import sys

models = Path('ios/Shared/Models.swift').read_text()
network = Path('ios/Shared/Network.swift').read_text()
models = models.replace('import ActivityKit\n', '')
models = models[:models.index('struct PilotActivityAttributes:')] + models[models.index('enum PilotError:'):]
start = network.index('enum MessageScopePolicy {')
gate = network[start:network.index('// One validation path', start)]
Path(sys.argv[1]).write_text(models + gate)
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/SafetyGate.swift" ios/Shared/AgentSession.swift tests/safety_gate_test.swift -o "$BUILD/test"
"$BUILD/test"
