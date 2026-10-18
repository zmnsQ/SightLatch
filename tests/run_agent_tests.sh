#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-swiftc}"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
"$SWIFTC" -module-cache-path "$BUILD/cache" ios/Shared/AgentSession.swift tests/agent_session_test.swift -o "$BUILD/agent-tests"
"$BUILD/agent-tests"
python3 - "$BUILD/HardwareClient.swift" <<'PY'
from pathlib import Path
import sys
source = Path('ios/Shared/Network.swift').read_text()
client = source.split('struct HardwareAction:', 1)[1].split('struct AIClient', 1)[0]
Path(sys.argv[1]).write_text('import Foundation\nimport FoundationNetworking\nstruct HardwareAction:' + client)
PY
"$SWIFTC" -module-cache-path "$BUILD/cache" "$BUILD/HardwareClient.swift" tests/hardware_cancellation_test.swift -o "$BUILD/hardware-tests"
"$BUILD/hardware-tests"
python3 - "$BUILD/AIClient.swift" <<'PY'
from pathlib import Path
import sys
network = Path('ios/Shared/Network.swift').read_text()
models = Path('ios/Shared/Models.swift').read_text()
config = 'struct PilotConfiguration:' + models.split('struct PilotConfiguration:', 1)[1].split('struct SessionCommand:', 1)[0]
action = 'struct ActionProposal:' + models.split('struct ActionProposal:', 1)[1].split('struct LogEntry:', 1)[0]
error = 'enum PilotError:' + models.split('enum PilotError:', 1)[1].split('struct SharedFrame:', 1)[0]
client = 'struct AIClient' + network.split('struct AIClient', 1)[1]
Path(sys.argv[1]).write_text('import Foundation\nimport FoundationNetworking\n' + config + action + error + client)
PY
"$SWIFTC" -module-cache-path "$BUILD/cache" "$BUILD/AIClient.swift" tests/model_completion_test.swift -o "$BUILD/model-tests"
"$BUILD/model-tests"
