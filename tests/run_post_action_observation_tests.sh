#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 - "$BUILD/Policy.swift" <<'PY'
from pathlib import Path
import sys
source = Path('ios/Broadcast/SampleHandler.swift').read_text()
start = source.index('struct PostActionObservationPolicy {')
end = source.index('// ReplayKit invokes', start)
Path(sys.argv[1]).write_text('import Foundation\n' + source[start:end])
assert source.count('self.postActionObservation.completed(at: completedAt)') == 1
success = source.split('let completedAt = Date()', 1)[1].split('} catch {', 1)[0]
assert 'self.postActionObservation.completed(at: completedAt)' in success
assert 'hardware_completed; UI effect must be verified' in success
assert 'lastCapture = Date()' in success and 'addingTimeInterval(-' not in success
capture = source.split('let interval = self.config.continuedProcessingEnabled', 1)[1].split('let jpeg: Data?', 1)[0]
assert 'busy: self.busy' in capture and 'capturedAt: sampledAt' in capture
assert capture.index('permitsCapture(') < capture.index('self.postActionObservation.beganEncoding()')
assert 'postActionObservation.reset()' in source.split('if command.generation != generation {', 1)[1].split('if !paused', 1)[0]
assert 'postActionObservation.reset()' in source.split('private func stopAndFinish(', 1)[1]
assert 'postActionObservation.reset()' in source.split('private func pause(', 1)[1].split('private func publish(', 1)[0]
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Policy.swift" tests/post_action_observation_test.swift -o "$BUILD/test"
"$BUILD/test"
