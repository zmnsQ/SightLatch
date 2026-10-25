#!/usr/bin/env python3
from pathlib import Path
import json
root=Path(__file__).resolve().parents[1]/'web-installer/public/firmware'
legacy=json.loads((root/'manifest-legacy-0.2.3.json').read_text())
latest=json.loads((root/'manifest-c3-web.json').read_text())
assert legacy['version']=='0.2.3' and latest['version']=='0.3.3-c3-web'
assert {(b['chipFamily'],b['variant']) for b in latest['builds']}=={('ESP32-C3','usb'),('ESP32-C3','uart')}
builds=latest['builds']+[dict(b,version=legacy['version']) for b in legacy['builds'] if b['chipFamily']!='ESP32-C3']
catalog={'name':'SightLatch — C3 experimental / ESP32 and S3 historical','version':latest['version'],'core':latest['core'],'channel':'experimental','legacyVersion':'0.2.3','builds':builds,'latestManifest':'firmware/manifest-c3-web.json','legacyManifest':'firmware/manifest-legacy-0.2.3.json'}
(root/'manifest.json').write_text(json.dumps(catalog,indent=2)+'\n')
