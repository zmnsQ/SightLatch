from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[1]/'web-installer/public'
m=json.loads((root/'firmware/manifest.json').read_text())
assert m['version']=='0.2.0-c3'
repo=Path(__file__).resolve().parents[1]
for path,digest in m['source_sha256'].items():
    target=(repo/path).resolve();assert repo in target.parents
    assert hashlib.sha256(target.read_bytes()).hexdigest()==digest, f'firmware source changed; rebuild: {path}'
assert {b['variant'] for b in m['builds']}=={'usb','uart'}
for b in m['builds']:
    assert b['chipFamily']=='ESP32-C3'
    assert len(b['parts'])==1
    p=b['parts'][0];assert p['offset']==0
    target=(root/p['path']).resolve();assert root.resolve() in target.parents
    data=target.read_bytes();assert len(data)==p['size']
    assert hashlib.sha256(data).hexdigest()==p['sha256']
    for offset in (0,0x10000):
        assert data[offset]==0xe9 and int.from_bytes(data[offset+12:offset+14],'little')==5
    assert data[2:4]==bytes([2,0x20]),'expected DIO / 40MHz / 4MB boot header'
    assert data[0x8000:0x8002]==b'\xaa\x50'
    print(b['variant'],len(data),p['sha256'])
