#!/usr/bin/env python3
"""Pinned public C3 test build. No USB, provisioning, flashing or deployment."""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess
from c3_web_dependencies import LOCK,verify_library
ROOT=Path(__file__).resolve().parents[1]
VERSION='0.3.3-c3-web'
SOURCE=ROOT/'firmware/c3-web/IPhoneHIDBridge'
OUT=ROOT/'build/c3-web'
PUBLIC=ROOT/'web-installer/public'
WRAPS=['nvs_flash_erase','nvs_flash_erase_partition','esp_partition_erase_range','ble_gap_repeat_pairing_event','ble_gap_rx_conn_complete']
def sha(data):return hashlib.sha256(data).hexdigest()
def run(cmd,**kw):return subprocess.run(cmd,check=True,**kw)
def main():
 p=argparse.ArgumentParser();p.add_argument('--arduino-cli',default=os.getenv('ARDUINO_CLI','arduino-cli'));p.add_argument('--config-file');args=p.parse_args()
 cli=[args.arduino_cli]+(['--config-file',args.config_file] if args.config_file else [])
 assert '1.3.1' in subprocess.check_output(cli+['version'],text=True)
 config=json.loads(subprocess.check_output(cli+['config','dump','--format','json'],text=True))
 config=config.get('config',config)
 user=Path(config['directories']['user']);data=Path(config['directories']['data'])
 nimble=user/'libraries/NimBLE-Arduino';arduinojson=user/'libraries/ArduinoJson'
 assert 'version=2.5.1' in (nimble/'library.properties').read_text()
 assert 'version=7.0.4' in (arduinojson/'library.properties').read_text()
 assert (data/'packages/esp32/hardware/esp32/3.3.11').is_dir(),'Install esp32:esp32@3.3.11'
 for lib in LOCK['libraries']:verify_library(lib,user/'libraries'/lib['directory'],OUT/'dependency-archives')
 assert not (SOURCE/'config.h').exists(),'Public builds refuse private config.h'
 assert not (SOURCE/'LocalIdentity.h').exists(),'Public builds refuse a developer BLE identity'
 assert not (SOURCE/'build').exists(),'Generated artifacts must not enter source provenance'
 hashes={str(x.relative_to(SOURCE)):sha(x.read_bytes()) for x in sorted(SOURCE.rglob('*')) if x.is_file()}
 fingerprint=sha(json.dumps(hashes,sort_keys=True,separators=(',',':')).encode())
 sketch=OUT/'source/IPhoneHIDBridge';sketch.mkdir(parents=True,exist_ok=True)
 for f in sketch.rglob('*'):
  if f.is_file():f.unlink()
 shutil.copytree(SOURCE,sketch,dirs_exist_ok=True)
 (sketch/'BuildProvenance.h').write_text('#pragma once\n#define SIGHTLATCH_BUILD_SOURCE_SHA256 "'+fingerprint+'"\n')
 # Fix compile-time macros and normalize all diagnostic file paths.
 env=dict(os.environ,SOURCE_DATE_EPOCH='1792800000')
 mappings=[(str(ROOT),'/sightlatch'),(str(data),'/arduino/data'),(str(user),'/arduino/user'),('{runtime.platform.path}','/arduino/platform'),('{build.path}','/arduino/build')]
 flags=' '.join('"'+flag+'='+a+'='+b+'"' for a,b in mappings for flag in ['-ffile-prefix-map','-fmacro-prefix-map'])
 builds=[];PUB=PUBLIC/'firmware';PUB.mkdir(exist_ok=True)
 legacy=json.loads((PUB/'manifest-legacy-0.2.3.json').read_text())
 for mode in ['usb','uart']:
  fqbn='esp32:esp32:esp32c3:CDCOnBoot='+('cdc' if mode=='usb' else 'default')+',FlashMode=dio,FlashFreq=40,FlashSize=4M,PartitionScheme=huge_app'
  output=OUT/mode;output.mkdir(parents=True,exist_ok=True)
  cmd=cli+['compile','--fqbn',fqbn,'--jobs','2','--library',str(nimble),'--library',str(arduinojson),'--build-path',str(OUT/('compile-'+mode)),'--output-dir',str(output),'--build-property','compiler.c.extra_flags='+flags,'--build-property','compiler.cpp.extra_flags='+flags,'--build-property','compiler.c.elf.extra_flags='+' '.join('-Wl,--wrap='+x for x in WRAPS)+' -Wl,--cref','--verbose',str(sketch)]
  print('Compiling',VERSION,mode,'source',fingerprint,flush=True)
  with (output/'build.log').open('w') as log:run(cmd,env=env,stdout=log,stderr=subprocess.STDOUT)
  # Verify forced resource definitions reached the real NimBLE C/C++ host
  # and Arduino core, rather than merely the sketch translation unit.
  compiled=OUT/('compile-'+mode)
  for unit in ('NimBLEDevice.cpp.d','ble_gap.c.d','esp32-hal-misc.c.d'):
   dependencies=list(compiled.rglob(unit))
   assert len(dependencies)==1 and 'ResourceLimits.h' in dependencies[0].read_text(),unit
  linkmap=(compiled/'IPhoneHIDBridge.ino.map').read_text()
  callers={'ble_gap_repeat_pairing_event':'ble_sm.c.o','ble_gap_rx_conn_complete':'ble_hs_hci_evt.c.o','nvs_flash_erase':'NimBLEDevice.cpp.o','esp_partition_erase_range':'esp32-hal-misc.c.o'}
  for symbol,caller in callers.items():
   references=re.search('^__wrap_'+symbol+r'[^\n]*\n(?: {20,}[^\n]*\n)*',linkmap,re.M)
   assert references and caller in references.group(), 'Missing linked policy hook: '+symbol
  app=(output/'IPhoneHIDBridge.ino.bin').read_bytes()
  assert app[0]==0xe9 and int.from_bytes(app[12:14],'little')==5 and len(app)<=0x300000
  assert fingerprint.encode() in app and VERSION.encode() in app
  assert b'/Users/' not in app and str(ROOT).encode() not in app,'Workstation path leaked'
  previous=next(b for b in legacy['builds'] if b['chipFamily']=='ESP32-C3' and b['variant']==mode)
  oldpart=previous['parts'][0];old=(PUBLIC/oldpart['path']).read_bytes();assert sha(old)==oldpart['sha256']
  assert (output/'IPhoneHIDBridge.ino.partitions.bin').read_bytes()==old[0x8000:0x8c00]
  # Reviewed legacy IDF bootloader + fixed partitions keep application-only
  # upgrades compatible. The full installer explicitly erases the whole Flash.
  image=bytearray(b'\xff'*4194304);image[:0x10000]=old[:0x10000];image[0x10000:0x10000+len(app)]=app
  name='sightlatch-'+VERSION+'-'+mode
  (PUB/(name+'-app.bin')).write_bytes(app);(PUB/(name+'.bin')).write_bytes(image)
  application={'path':'firmware/'+name+'-app.bin','offset':0x10000,'size':len(app),'sha256':sha(app)}
  compat=dict(previous['update']['compatibility']);compat['fromVersion']='compatible-c3-layout'
  builds.append({'version':VERSION,'chipFamily':'ESP32-C3','variant':mode,'fqbn':fqbn,'source_id':fingerprint,'flashSize':4194304,'flashMode':'dio','flashFrequency':'40m','parts':[{'path':'firmware/'+name+'.bin','offset':0,'size':len(image),'sha256':sha(image)}],'update':{'application':application,'compatibility':compat}})
 manifest={'name':'SightLatch C3 public experimental build','version':VERSION,'channel':'experimental','hardwareValidated':False,'knownIssues':['Observed Wi-Fi/LAN disconnects remain unresolved. Public per-chip identity and UART variants await board/iPhone regression.'],'arduinoCli':'1.3.1','core':'3.3.11','nimble':'2.5.1','arduinoJson':'7.0.4','nimbleArchiveSHA256':'8fb09b1cde59f4ca5e6172d620c379968db959a883209289a9315b03eec27fe2','nimblePatches':[],'dependencyLockSHA256':sha((ROOT/'firmware/c3-web/dependencies.lock.json').read_bytes()),'sourceDateEpoch':int(env['SOURCE_DATE_EPOCH']),'sourceRoot':'firmware/c3-web/IPhoneHIDBridge','source_id':fingerprint,'source_sha256':hashes,'builds':builds,'bootloaderCore':'3.3.5 (reviewed compatibility prefix from public 0.2.3 images)','identity':'SHA-256 domain-separated factory identity; static-random per chip; existing bonds may need repair'}
 (PUB/'manifest-c3-web.json').write_text(json.dumps(manifest,indent=2)+'\n')
 (PUB/'C3_WEB_SHA256SUMS').write_text(''.join(b['parts'][0]['sha256']+'  '+Path(b['parts'][0]['path']).name+'\n'+b['update']['application']['sha256']+'  '+Path(b['update']['application']['path']).name+'\n' for b in builds))
 assert hashes=={str(x.relative_to(SOURCE)):sha(x.read_bytes()) for x in sorted(SOURCE.rglob('*')) if x.is_file()}
 print('Public C3 images packaged; no USB/flash/publish',flush=True)
if __name__=='__main__':main()
