#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-swiftc}"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 - "$BUILD/Probe.swift" <<'PY'
from pathlib import Path
import sys
network=Path('ios/Shared/Network.swift').read_text()
vm=Path('ios/App/PilotViewModel.swift').read_text()
models=Path('ios/Shared/Models.swift').read_text()
config='struct PointerCalibrationContext:'+models.split('struct PointerCalibrationContext:',1)[1].split('struct SessionCommand:',1)[0]
shared=network[network.index('struct HTTPStatusFailure:'):network.index('struct HardwareAction:')]
methods=vm[vm.index('    func refreshDeviceStatus()'):vm.index("    func requestDeviceControl(")]
Path(sys.argv[1]).write_text('import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n'+config+shared+Path('tests/probe_test_support.swift').read_text()+methods+'\n}\n'+Path('tests/pairing_test_cases.swift').read_text()+Path('tests/probe_test_main.swift').read_text())
PY
"$SWIFTC" -parse-as-library -module-cache-path "$BUILD/cache" "$BUILD/Probe.swift" -o "$BUILD/probe-tests"
"$BUILD/probe-tests"
