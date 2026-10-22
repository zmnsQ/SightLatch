"""Prepare app-only artifacts, but do not change the installer's erase/flash flow."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
PUBLIC = ROOT / 'web-installer/public'
VERSION = '0.2.3'
PREVIOUS_VERSION = '0.2.2'
sha256 = lambda data: hashlib.sha256(data).hexdigest()


def package():
    manifest = json.loads((PUBLIC / 'firmware/manifest.json').read_text())
    assert manifest['version'] == VERSION and len(manifest['builds']) == 5
    evidence = {'version': VERSION, 'previous_version': PREVIOUS_VERSION, 'builds': []}
    sums = []
    for build in manifest['builds']:
        family, mode = build['chipFamily'], build['variant']
        folder = mode if family == 'ESP32-C3' else 'esp32-uart' if family == 'ESP32' else 's3-' + mode
        source = ROOT / 'firmware/build' / folder
        merged_path = PUBLIC / build['parts'][0]['path']
        merged = merged_path.read_bytes()
        previous = (merged_path.parent / merged_path.name.replace(VERSION, PREVIOUS_VERSION)).read_bytes()
        assert merged[:0x10000] == previous[:0x10000], 'Bootloader/partition prefix changed; no app-only update'
        bootloader = (source / 'IPhoneHIDBridge.ino.bootloader.bin').read_bytes()
        partitions = (source / 'IPhoneHIDBridge.ino.partitions.bin').read_bytes()
        boot_offset = 0x1000 if family == 'ESP32' else 0
        # These are the only safe compatibility reads needed on a real device.
        # Do not read the whole prefix: its 0x9000..0xE000 NVS area contains credentials.
        assert boot_offset + len(bootloader) <= 0x8000
        assert 0x8000 + len(partitions) <= 0x9000
        assert bootloader == previous[boot_offset:boot_offset + len(bootloader)]
        assert partitions == previous[0x8000:0x8000 + len(partitions)]
        app = (source / 'IPhoneHIDBridge.ino.bin').read_bytes()
        assert 0 < len(app) <= 0x300000 and app[0] == 0xE9
        assert int.from_bytes(app[12:14], 'little') == {'ESP32-C3': 5, 'ESP32': 0, 'ESP32-S3': 9}[family]
        assert app == merged[0x10000:0x10000 + len(app)]
        app_path = merged_path.with_name(merged_path.stem + '-app.bin')
        app_path.write_bytes(app)
        part = {'path': str(app_path.relative_to(PUBLIC)), 'offset': 0x10000, 'size': len(app), 'sha256': sha256(app)}
        compatibility = {'fromVersion': PREVIOUS_VERSION,
            'bootloader': {'offset': boot_offset, 'size': len(bootloader), 'sha256': sha256(bootloader)},
            'partitions': {'offset': 0x8000, 'size': len(partitions), 'sha256': sha256(partitions)}}
        build['update'] = {'application': part, 'compatibility': compatibility}
        evidence['builds'].append({'chipFamily': family, 'variant': mode, 'application': part,
            'prefix_0_to_0x10000_identical': True, 'prefix_sha256': sha256(merged[:0x10000]),
            'bootloader': compatibility['bootloader'], 'partitions': compatibility['partitions']})
        sums.append(f'{part["sha256"]}  {app_path.name}\n')
    (PUBLIC / 'firmware/APPLICATION_SHA256SUMS').write_text(''.join(sums))
    manifest['source_sha256']['scripts/package_application_updates.py'] = sha256(Path(__file__).read_bytes())
    (PUBLIC / 'firmware/manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    # Keep the byte-for-byte comparison evidence locally as well.
    target = ROOT / 'build' / f'application-updates-{VERSION}.json'
    target.write_text(json.dumps(evidence, indent=2) + '\n')
    print(target)
    print(''.join(sums), end='')


if __name__ == '__main__':
    package()
