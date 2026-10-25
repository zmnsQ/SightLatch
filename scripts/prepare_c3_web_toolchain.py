#!/usr/bin/env python3
"""Install the pinned public C3 toolchain into ignored build/, never global state."""
from pathlib import Path
import argparse,json,shutil,subprocess
from c3_web_dependencies import ROOT,LOCK,entries,verify_library

def main():
 p=argparse.ArgumentParser();p.add_argument('--arduino-cli',default='arduino-cli');args=p.parse_args()
 assert LOCK['arduinoCli'] in subprocess.check_output([args.arduino_cli,'version'],text=True)
 base=ROOT/'build/c3-web/toolchain';base.mkdir(parents=True,exist_ok=True)
 data=base/'data';user=base/'user';downloads=base/'downloads'
 config=base/'arduino-cli.yaml'
 config.write_text(json.dumps({'directories':{'data':str(data),'downloads':str(downloads),'user':str(user)},'board_manager':{'additional_urls':[LOCK['additionalURL']]}},indent=2)+'\n')
 cli=[args.arduino_cli,'--config-file',str(config)]
 subprocess.run(cli+['core','update-index'],check=True)
 index=json.loads((data/'package_esp32_index.json').read_text())
 core=next(p for pkg in index['packages'] if pkg['name']=='esp32' for p in pkg['platforms'] if p['version']==LOCK['core'])
 assert core['url']==LOCK['coreArchive']['url'] and core['checksum']=='SHA-256:'+LOCK['coreArchive']['sha256'],'Official core index changed'
 subprocess.run(cli+['core','install','esp32:esp32@'+LOCK['core']],check=True)
 for lib in LOCK['libraries']:
  destination=user/'libraries'/lib['directory']
  # This directory is owned by this script, and contains only pinned public dependencies.
  if destination.exists():shutil.rmtree(destination)
  for path,content in entries(lib,downloads).items():
   target=destination/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(content)
  verify_library(lib,destination,downloads)
 print('Ready. Build with:')
 print(args.arduino_cli+' is Arduino CLI '+LOCK['arduinoCli'])
 print('python3 scripts/build_c3_web.py --arduino-cli '+args.arduino_cli+' --config-file '+str(config.relative_to(ROOT)))
if __name__=='__main__':main()
