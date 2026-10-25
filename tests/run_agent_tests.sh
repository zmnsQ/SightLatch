#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-swiftc}"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
"$SWIFTC" -module-cache-path "$BUILD/cache" ios/Shared/AgentSession.swift tests/agent_session_test.swift -o "$BUILD/agent-tests"
"$BUILD/agent-tests"
python3 tests/calibration_test_support.py "$BUILD"
python3 - "$BUILD/HardwareClient.swift" <<'PY'
from pathlib import Path
import sys
source = Path('ios/Shared/Network.swift').read_text()
models = Path('ios/Shared/Models.swift').read_text().replace('import ActivityKit\n', '')
models = models[:models.index('struct PilotActivityAttributes:')] + models[models.index('enum PilotError:'):]
client = source.split('struct HardwareAction:', 1)[1].split('struct AIClient', 1)[0]
Path(sys.argv[1]).write_text('import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n' + source[source.index('struct HTTPStatusFailure:'):source.index('struct DeviceProbeState:')] + models + 'struct HardwareAction:' + client)
PY
"$SWIFTC" -module-cache-path "$BUILD/cache" "$BUILD/HardwareClient.swift" "$BUILD/SharedStore.swift" tests/hardware_cancellation_test.swift -o "$BUILD/hardware-tests"
SIGHTLATCH_TEST_STORE="$BUILD/store" "$BUILD/hardware-tests"
python3 - "$BUILD/AIClient.swift" <<'PY'
from pathlib import Path
import sys
network = Path('ios/Shared/Network.swift').read_text()
models = Path('ios/Shared/Models.swift').read_text()
models = models.replace('import ActivityKit\n', '')
models = models[:models.index('struct PilotActivityAttributes:')] + models[models.index('enum PilotError:'):]
client = 'struct AIClient' + network.split('struct AIClient', 1)[1]
Path(sys.argv[1]).write_text('import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n' + models + client)
PY
"$SWIFTC" -module-cache-path "$BUILD/cache" "$BUILD/AIClient.swift" tests/model_completion_test.swift -o "$BUILD/model-tests"
"$BUILD/model-tests"
