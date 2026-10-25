#!/usr/bin/env python3
"""Verify published C3 bytes against pure source, catalog and compatibility regions."""
from pathlib import Path
import hashlib,json,re
ROOT=Path(__file__).resolve().parents[1];PUBLIC=ROOT/'web-installer/public';FIRMWARE=PUBLIC/'firmware'
def sha(data):return hashlib.sha256(data).hexdigest()
def read(path):return json.loads((FIRMWARE/path).read_text())
m=read('manifest-c3-web.json');old=read('manifest-legacy-0.2.3.json');catalog=read('manifest.json')
assert m['version']=='0.3.3-c3-web' and m['channel']=='experimental' and m['hardwareValidated'] is False
assert m['knownIssues'] and 'unresolved' in ' '.join(m['knownIssues'])
source=ROOT/m['sourceRoot'];assert source==ROOT/'firmware/c3-web/IPhoneHIDBridge'
assert not any((source/name).exists() for name in ('config.h','LocalIdentity.h','BuildProvenance.h','build'))
hashes={str(p.relative_to(source)):sha(p.read_bytes()) for p in sorted(source.rglob('*')) if p.is_file()}
assert hashes==m['source_sha256'],'Source/manifest mismatch'
assert m['source_id']==sha(json.dumps(hashes,sort_keys=True,separators=(',',':')).encode())
assert all('/build/' not in name and not name.endswith(('.bin','.elf','.map')) for name in hashes)
lock=json.loads((ROOT/'firmware/c3-web/dependencies.lock.json').read_text())
assert (m['arduinoCli'],m['core'],m['nimble'],m['arduinoJson'])==('1.3.1','3.3.11','2.5.1','7.0.4')
assert m['dependencyLockSHA256']==sha((ROOT/'firmware/c3-web/dependencies.lock.json').read_bytes())
assert m['sourceDateEpoch']==lock['sourceDateEpoch']
assert lock['nimbleSourcePatches']==m['nimblePatches']==[]
assert m['nimbleArchiveSHA256']==lock['libraries'][0]['sha256']
identity=(source/'PublicIdentity.h').read_text()
assert 'esp_efuse_mac_get_default(chip)' in identity and 'mbedtls_sha256(seed' in identity
assert not any(text in identity for text in ('nvs_', 'printf', 'Serial', 'esp_efuse_write'))
assert 'setOwnAddr(address)' in identity and 'BLE_OWN_ADDR_RANDOM' in identity
assert {(b['chipFamily'],b['variant']) for b in m['builds']}=={('ESP32-C3','usb'),('ESP32-C3','uart')}
checksums=[]
for b in m['builds']:
 assert b['version']==m['version'] and b['source_id']==m['source_id']
 assert b['flashSize']==4194304 and b['flashMode']=='dio' and b['flashFrequency']=='40m'
 previous=next(x for x in old['builds'] if (x['chipFamily'],x['variant'])==(b['chipFamily'],b['variant']))
 old_data=(PUBLIC/previous['parts'][0]['path']).read_bytes()
 assert sha(old_data)==previous['parts'][0]['sha256']
 assert len(b['parts'])==1 and b['parts'][0]['offset']==0
 full_part=b['parts'][0];app_part=b['update']['application'];compat=b['update']['compatibility']
 full=(PUBLIC/full_part['path']).read_bytes();app=(PUBLIC/app_part['path']).read_bytes()
 for part,data in ((full_part,full),(app_part,app)):
  assert re.fullmatch(r'firmware/sightlatch-0\.3\.3-c3-web-(usb|uart)(-app)?\.bin',part['path'])
  assert len(data)==part['size'] and sha(data)==part['sha256']
  checksums.append(part['sha256']+'  '+Path(part['path']).name+'\n')
 assert len(full)==4194304 and 24<=len(app)<=0x300000 and app_part['offset']==0x10000
 assert full[:0x10000]==old_data[:0x10000] and full[0x10000:0x10000+len(app)]==app
 assert full[0x10000+len(app):]==b'\xff'*(len(full)-0x10000-len(app))
 assert app[0]==0xe9 and app[12:14]==bytes((5,0)) and full[2:4]==bytes((2,0x20))
 assert m['source_id'].encode() in app and m['version'].encode() in app
 assert b'/Users/' not in app and str(ROOT).encode() not in app
 assert compat['fromVersion']=='compatible-c3-layout'
 for name,offset,limit in (('bootloader',0,0x8000),('partitions',0x8000,0x9000)):
  region=compat[name];assert region==previous['update']['compatibility'][name]
  assert region['offset']==offset and offset+region['size']<=limit
  assert sha(full[offset:offset+region['size']])==region['sha256']
 print('PASS public C3',b['variant'],len(app),app_part['sha256'])
assert ''.join(checksums)==(FIRMWARE/'C3_WEB_SHA256SUMS').read_text()
expected=m['builds']+[dict(b,version='0.2.3') for b in old['builds'] if b['chipFamily']!='ESP32-C3']
assert catalog['builds']==expected and catalog['version']==m['version']
assert catalog['latestManifest']=='firmware/manifest-c3-web.json' and catalog['legacyManifest']=='firmware/manifest-legacy-0.2.3.json'
print('PASS source fingerprint, no private/generated inputs, inherited boot/partition ranges, experimental catalog and historical non-C3 versions')
