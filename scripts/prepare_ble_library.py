"""Copy pinned official BLE sources into the build tree and fix HID report registration."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / 'firmware/IPhoneHIDBridge/BLEService-3.3.5.patch'
UPSTREAM_SHA256 = '6c95afceec18f161575c4d682571d05bc03e5ca26976e066213e2234ae220124'
PATCHED_SHA256 = 'b6bcfda1225ffb7013fab519b456cf059221b6ace155a35f1b70144090f629d8'
DESTINATION = ROOT / 'firmware/build/ble-library/BLE'


def apply_fix(library):
    service = library / 'src/BLEService.cpp'
    if hashlib.sha256(service.read_bytes()).hexdigest() != UPSTREAM_SHA256:
        raise SystemExit('Refusing unknown BLEService.cpp; expected unmodified Arduino-ESP32 3.3.5')
    subprocess.run(['patch', '-p1', '-i', str(PATCH)], cwd=library, check=True, stdout=subprocess.PIPE)
    if hashlib.sha256(service.read_bytes()).hexdigest() != PATCHED_SHA256:
        raise SystemExit('BLE registration patch output did not match the reviewed source')


def data_directory(cli):
    # `config dump` omits defaults on a clean CLI installation. Ask the CLI for
    # its effective value so defaults, config files, and environment overrides
    # all follow the same resolution as the platform installer/compiler.
    value = json.loads(subprocess.check_output([cli, 'config', 'get', 'directories.data', '--json']))
    if not isinstance(value, str) or not value.strip():
        raise SystemExit('Arduino CLI did not return a valid directories.data path')
    return Path(value)


def prepare(cli):
    data = data_directory(cli)
    upstream = data / 'packages/esp32/hardware/esp32/3.3.5/libraries/BLE'
    if hashlib.sha256((upstream / 'src/BLEService.cpp').read_bytes()).hexdigest() != UPSTREAM_SHA256:
        raise SystemExit('Expected unmodified official Arduino-ESP32 3.3.5 BLE library')
    # Never edit the installed platform or other projects' dependencies.
    shutil.copytree(upstream, DESTINATION, dirs_exist_ok=True)
    apply_fix(DESTINATION)
    print(DESTINATION)


if __name__ == '__main__':
    prepare(sys.argv[1])
