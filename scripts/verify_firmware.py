from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[1]/'web-installer/public'
m=json.loads((root/'firmware/manifest.json').read_text())
assert m['version']=='0.2.0-c3'
repo=Path(__file__).resolve().parents[1]
for path,digest in {**m['source_sha256'],**m.get('extended_source_sha256',{})}.items():
    target=(repo/path).resolve();assert repo in target.parents
    assert hashlib.sha256(target.read_bytes()).hexdigest()==digest, f'firmware source changed; rebuild: {path}'
expected={('ESP32-C3','usb'),('ESP32-C3','uart'),('ESP32','uart'),('ESP32-S3','usb'),('ESP32-S3','uart')}
assert len(m['builds'])==len(expected) and {(b['chipFamily'],b['variant']) for b in m['builds']}==expected
for b in m['builds']:
    assert b['chipFamily'] in ('ESP32-C3','ESP32','ESP32-S3')
    assert b['flashSize']==4194304 and b['flashMode']=='dio'
    if b['chipFamily']!='ESP32-C3':
        assert set(b['compiled_source_sha256'])=={p.name for p in (repo/'firmware/IPhoneHIDBridge').glob('*') if p.is_file()}
        for name,digest in b['compiled_source_sha256'].items():
            data=(repo/'firmware/IPhoneHIDBridge'/name).read_bytes()
            if b['chipFamily']=='ESP32' and name=='Bridge.cpp':
                old=b'!defined(CONFIG_IDF_TARGET_ESP32S3) && !defined(CONFIG_IDF_TARGET_ESP32C3)'
                assert data.count(old)==1
                data=data.replace(old,b'!defined(CONFIG_IDF_TARGET_ESP32) && '+old)
            assert hashlib.sha256(data).hexdigest()==digest
    chip,boot,freq={'ESP32-C3':(5,0,0x20),'ESP32':(0,0x1000,0x20),'ESP32-S3':(9,0,0x2f)}[b['chipFamily']]
    assert b['variant'] in (('uart',) if chip==0 else ('usb','uart'))
    assert b['flashFrequency']==('80m' if chip==9 else '40m')
    assert len(b['parts'])==1
    p=b['parts'][0];assert p['offset']==0
    target=(root/p['path']).resolve();assert root.resolve() in target.parents
    data=target.read_bytes();assert len(data)==p['size']
    assert hashlib.sha256(data).hexdigest()==p['sha256']
    for offset in (boot,0x10000):
        assert data[offset]==0xe9 and int.from_bytes(data[offset+12:offset+14],'little')==chip
    assert data[boot+2:boot+4]==bytes([2,freq]),'unexpected per-family DIO / frequency / 4MB boot header'
    assert data[0x8000:0x8002]==b'\xaa\x50'
    print(b['chipFamily'],b['variant'],len(data),p['sha256'])
