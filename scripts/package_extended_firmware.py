"""Append only real Arduino-built ESP32/S3 images; retain C3 bytes/provenance."""
from pathlib import Path
import hashlib,json
ROOT=Path(__file__).resolve().parents[1]
out=ROOT/'web-installer/public/firmware'
m=json.loads((out/'manifest.json').read_text())
m['builds']=[b for b in m['builds'] if b['chipFamily']=='ESP32-C3']
assert len(m['builds'])==2
m['name']='SightLatch ESP32 / C3 / S3'
for family,mode,folder,chip,boot,freq in [('ESP32','uart','esp32-uart',0,0x1000,'40m'),('ESP32-S3','usb','s3-usb',9,0,'80m'),('ESP32-S3','uart','s3-uart',9,0,'80m')]:
    binary=(ROOT/'firmware/build'/folder/'IPhoneHIDBridge.ino.merged.bin').read_bytes()
    assert 65560<len(binary)<=4194304
    for offset in (boot,0x10000):
        assert binary[offset]==0xe9 and int.from_bytes(binary[offset+12:offset+14],'little')==chip
    assert binary[boot+2:boot+4]==bytes([2,0x2f if freq=='80m' else 0x20])
    assert binary[0x8000:0x8002]==b'\xaa\x50'
    name=f'sightlatch-0.2.0-{folder}.bin';(out/name).write_bytes(binary)
    source=ROOT/'firmware/build/classic-source/IPhoneHIDBridge' if family=='ESP32' else ROOT/'firmware/IPhoneHIDBridge'
    target='esp32:esp32:esp32:FlashMode=dio,FlashFreq=40,FlashSize=4M,PartitionScheme=huge_app' if family=='ESP32' else f'esp32:esp32:esp32s3:USBMode=hwcdc,CDCOnBoot={"cdc" if mode=="usb" else "default"},FlashMode=dio,FlashSize=4M,PartitionScheme=huge_app,PSRAM=disabled'
    source_hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source.glob('*')) if p.is_file()}
    m['builds'].append({'fqbn':target,'compiled_source_sha256':source_hashes,'sourceTransform':'scripts/build_extended_firmware.sh' if family=='ESP32' else None,'chipFamily':family,'variant':mode,'flashSize':4194304,'flashMode':'dio','flashFrequency':freq,'parts':[{'path':'firmware/'+name,'offset':0,'size':len(binary),'sha256':hashlib.sha256(binary).hexdigest()}]})
m['extended_source_sha256']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [ROOT/'scripts/build_extended_firmware.sh',ROOT/'scripts/package_extended_firmware.py']}
(out/'manifest.json').write_text(json.dumps(m,indent=2)+'\n')
(out/'SHA256SUMS').write_text(''.join(f"{b['parts'][0]['sha256']}  {Path(b['parts'][0]['path']).name}\n" for b in m['builds']))
