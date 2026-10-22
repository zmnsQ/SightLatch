"""Package Arduino's merged C3 images; refuse incorrect chip headers/offsets."""
from pathlib import Path
import hashlib,json
from firmware_provenance import source_hashes, source_id
ROOT=Path(__file__).resolve().parents[1]
out=ROOT/'web-installer/public/firmware';out.mkdir(parents=True,exist_ok=True)
manifest={'name':'SightLatch ESP32-C3','version':'0.2.2','arduinoCli':'1.3.1','core':'3.3.5','arduinoJson':'7.0.4','builds':[]}
manifest['source_sha256']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted([*(ROOT/'firmware/IPhoneHIDBridge').glob('*'),ROOT/'scripts/build_firmware.sh',ROOT/'scripts/firmware_build_flags.sh',ROOT/'scripts/firmware_provenance.py',ROOT/'scripts/package_firmware.py']) if p.is_file()}
manifest['path_normalization']={'flags':['-ffile-prefix-map','-fmacro-prefix-map'],'checkout':'/sightlatch','arduinoData':'/arduino/data','arduinoUser':'/arduino/user','platform':'/arduino/platform','compileOutput':'/arduino/build'}
for mode in ('usb','uart'):
    folder=ROOT/'firmware/build'/mode
    # Arduino core 3.3.5 produces merged.bin from its own offset recipe.
    binary=(folder/'IPhoneHIDBridge.ino.merged.bin').read_bytes()
    assert 65560<len(binary)<=4*1024*1024
    for offset in (0,0x10000):
        assert binary[offset]==0xe9, f'missing ESP image at {offset:#x}'
        assert int.from_bytes(binary[offset+12:offset+14],'little')==5,'not ESP32-C3'
    assert binary[2:4]==bytes([2,0x20]),'expected DIO / 40MHz / 4MB boot header'
    assert binary[0x8000:0x8002]==b'\xaa\x50','partition table missing'
    name=f'sightlatch-0.2.2-c3-{mode}.bin';(out/name).write_bytes(binary)
    hashes=source_hashes(ROOT/'firmware/build/c3-source/IPhoneHIDBridge')
    fingerprint=source_id(hashes)
    assert fingerprint.encode() in binary, 'compiled image is missing its source fingerprint'
    assert str(ROOT).encode() not in binary and b'/Users/' not in binary, 'local build path leaked into image'
    target=f'esp32:esp32:esp32c3:CDCOnBoot={"cdc" if mode=="usb" else "default"},FlashMode=dio,FlashFreq=40,FlashSize=4M,PartitionScheme=huge_app'
    manifest['builds'].append({'fqbn':target,'source_id':fingerprint,'compiled_source_sha256':hashes,'chipFamily':'ESP32-C3','variant':mode,'flashSize':4194304,'flashMode':'dio','flashFrequency':'40m','parts':[{'path':'firmware/'+name,'offset':0,'size':len(binary),'sha256':hashlib.sha256(binary).hexdigest()}]})
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(out/'SHA256SUMS').write_text(''.join(f"{b['parts'][0]['sha256']}  {Path(b['parts'][0]['path']).name}\n" for b in manifest['builds']))
print((out/'SHA256SUMS').read_text())
