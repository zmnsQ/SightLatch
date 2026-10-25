#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import subprocess,tempfile,shutil
out=Path(tempfile.mkdtemp(prefix='pilot-activity-publisher-'))
try:
    models=Path('ios/Shared/Models.swift').read_text()
    attributes='struct PilotActivityAttributes'+models.split('struct PilotActivityAttributes',1)[1].split('enum PilotError:',1)[0]
    attributes=attributes.replace(': ActivityAttributes','',1)
    attributes = models[models.index('struct PilotClarificationAction:'):models.index('/// Pure transition rules')] + attributes
    text=Path('ios/Shared/PilotActivityPresentation.swift').read_text()
    pure=text.split('#if os(iOS) && canImport(ActivityKit)',1)[0]
    publisher='struct PilotActivityDeliveryDiagnostic'+text.split('struct PilotActivityDeliveryDiagnostic',1)[1].rsplit('#endif',1)[0]
    (out/'ActualPresentation.swift').write_text(pure+attributes+publisher)
    subprocess.run(['swiftc','-module-cache-path',str(out/'cache'),str(out/'ActualPresentation.swift'),'tests/activity_publisher_test.swift','-o',str(out/'test')],check=True)
    subprocess.run([str(out/'test')],check=True)
finally: shutil.rmtree(out)
PY
