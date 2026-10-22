from pathlib import Path
import hashlib,json
from firmware_provenance import source_id
from prepare_ble_library import UPSTREAM_SHA256, PATCHED_SHA256
root=Path(__file__).resolve().parents[1]/'web-installer/public'
m=json.loads((root/'firmware/manifest.json').read_text())
assert m['version']=='0.2.3'
assert m['ble_compatibility']['upstream_sha256']==UPSTREAM_SHA256
assert m['ble_compatibility']['patched_sha256']==PATCHED_SHA256
assert m['ble_compatibility']['patch'] in m['source_sha256']
assert m['path_normalization']['flags']==['-ffile-prefix-map','-fmacro-prefix-map']
repo=Path(__file__).resolve().parents[1]
for path,digest in {**m['source_sha256'],**m.get('extended_source_sha256',{})}.items():
    target=(repo/path).resolve();assert repo in target.parents
    assert hashlib.sha256(target.read_bytes()).hexdigest()==digest, f'firmware source changed; rebuild: {path}'
expected={('ESP32-C3','usb'),('ESP32-C3','uart'),('ESP32','uart'),('ESP32-S3','usb'),('ESP32-S3','uart')}
assert len(m['builds'])==len(expected) and {(b['chipFamily'],b['variant']) for b in m['builds']}==expected
for b in m['builds']:
    assert b['chipFamily'] in ('ESP32-C3','ESP32','ESP32-S3')
    assert b['flashSize']==4194304 and b['flashMode']=='dio'
    if 'compiled_source_sha256' in b:
        assert set(b['compiled_source_sha256'])=={p.name for p in (repo/'firmware/IPhoneHIDBridge').glob('*') if p.is_file()}
        for name,digest in b['compiled_source_sha256'].items():
            data=(repo/'firmware/IPhoneHIDBridge'/name).read_bytes()
            if b['chipFamily']=='ESP32' and name=='Bridge.cpp':
                old=b'!defined(CONFIG_IDF_TARGET_ESP32S3) && !defined(CONFIG_IDF_TARGET_ESP32C3)'
                assert data.count(old)==1
                data=data.replace(old,b'!defined(CONFIG_IDF_TARGET_ESP32) && '+old)
            assert hashlib.sha256(data).hexdigest()==digest
        assert b['source_id']==source_id(b['compiled_source_sha256'])
    else:
        raise AssertionError('Missing compiled source fingerprint')
    chip,boot,freq={'ESP32-C3':(5,0,0x20),'ESP32':(0,0x1000,0x20),'ESP32-S3':(9,0,0x2f)}[b['chipFamily']]
    assert b['variant'] in (('uart',) if chip==0 else ('usb','uart'))
    assert b['flashFrequency']==('80m' if chip==9 else '40m')
    assert len(b['parts'])==1
    p=b['parts'][0];assert p['offset']==0
    target=(root/p['path']).resolve();assert root.resolve() in target.parents
    data=target.read_bytes();assert len(data)==p['size']
    assert hashlib.sha256(data).hexdigest()==p['sha256']
    assert b['source_id'].encode() in data
    assert str(repo).encode() not in data and b'/Users/' not in data, 'local build path leaked into image'
    for offset in (boot,0x10000):
        assert data[offset]==0xe9 and int.from_bytes(data[offset+12:offset+14],'little')==chip
    assert data[boot+2:boot+4]==bytes([2,freq]),'unexpected per-family DIO / frequency / 4MB boot header'
    assert data[0x8000:0x8002]==b'\xaa\x50'
    update=b['update'];app=update['application'];compatibility=update['compatibility']
    assert compatibility['fromVersion']=='0.2.2'
    assert app['offset']==0x10000 and 0<app['size']<=0x300000
    app_path=(root/app['path']).resolve();assert root.resolve() in app_path.parents
    app_data=app_path.read_bytes()
    assert len(app_data)==app['size'] and hashlib.sha256(app_data).hexdigest()==app['sha256']
    assert app_data==data[0x10000:0x10000+app['size']]
    previous=(target.parent/target.name.replace(m['version'],compatibility['fromVersion'])).read_bytes()
    assert data[:0x10000]==previous[:0x10000]
    for name in ('bootloader','partitions'):
        region=compatibility[name];start=region['offset'];end=start+region['size']
        if name=='bootloader':assert start==boot and start<end<=0x8000
        else:assert start==0x8000 and start<end<=0x9000
        assert data[start:end]==previous[start:end]
        assert hashlib.sha256(data[start:end]).hexdigest()==region['sha256']
    print(b['chipFamily'],b['variant'],len(data),p['sha256'])
