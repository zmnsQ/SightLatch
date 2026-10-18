#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-swiftc}"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 - "$BUILD/Diagnostics.swift" <<'PY'
from pathlib import Path
import sys
network=Path('ios/Shared/Network.swift').read_text()
vm=Path('ios/App/PilotViewModel.swift').read_text()
workspace=Path('ios/App/Workspace.swift').read_text()
status=network[network.index('struct DeviceStatus:'):network.index('enum DevicePairingCloseResult')]
accept=vm[vm.index('    private func acceptDeviceStatus('):vm.index('    func refreshDeviceStatus()')].replace('private func','func',1)
export=workspace[workspace.index('    func exportDiagnostics()'):workspace.rindex('\n}')]
Path(sys.argv[1]).write_text('import Foundation\n'+status+Path('tests/diagnostic_export_support.swift').read_text()+accept+export+'\n}\n'+Path('tests/diagnostic_export_main.swift').read_text())
PY
"$SWIFTC" -parse-as-library -module-cache-path "$BUILD/cache" "$BUILD/Diagnostics.swift" -o "$BUILD/diagnostic-tests"
"$BUILD/diagnostic-tests"
