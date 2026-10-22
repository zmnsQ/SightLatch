"""Exercise the actual pinned upstream addCharacteristic body before/after our patch."""
from pathlib import Path
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ble_fix', ROOT / 'scripts/prepare_ble_library.py')
ble_fix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ble_fix)
FIXTURE = ROOT / 'tests/fixtures/arduino-esp32-3.3.5/BLEService.cpp'
package_spec = importlib.util.spec_from_file_location('app_updates', ROOT / 'scripts/package_application_updates.py')
app_updates = importlib.util.module_from_spec(package_spec)
package_spec.loader.exec_module(app_updates)

# Platform seams only: pointer-keyed characteristic map matches BLECharacteristicMap.cpp.
# The registration function under test is copied verbatim, never reimplemented here.
HARNESS = r'''
#include <cassert>
#include <map>
#define CONFIG_NIMBLE_ENABLED 1
#define log_v(...)
#define log_d(...)
#define log_w(...)
struct BLECharacteristic {
  int uuid = 0x2a4d;
  int m_removed = 0;
  int getUUID() { return uuid; }
};
struct BLECharacteristicMap {
  std::map<BLECharacteristic *, int> registered;
  BLECharacteristic *getByUUID(int uuid) {
    for (auto &entry : registered) if (entry.first->getUUID() == uuid) return entry.first;
    return nullptr;
  }
  void setByUUID(BLECharacteristic *characteristic, int uuid) { registered.emplace(characteristic, uuid); }
};
struct BLEServer { void serviceChanged() {} };
struct BLEService {
  BLECharacteristicMap m_characteristicMap;
  BLEServer server;
  BLEServer *getServer() { return &server; }
  void addCharacteristic(BLECharacteristic *);
};
FUNCTION_UNDER_TEST
int main() {
  BLEService hid;
  BLECharacteristic keyboard, mouse;
  hid.addCharacteristic(&keyboard);
  hid.addCharacteristic(&mouse);
  assert(hid.m_characteristicMap.registered.size() == EXPECTED_REPORTS);
  assert(hid.m_characteristicMap.registered.count(&keyboard) == 1);
  assert(hid.m_characteristicMap.registered.count(&mouse) == EXPECTED_REPORTS - 1);
  // Re-adding either identical object must not duplicate or replace report objects.
  hid.addCharacteristic(&keyboard);
  hid.addCharacteristic(&mouse);
  assert(hid.m_characteristicMap.registered.size() == EXPECTED_REPORTS);
}
'''


class HIDReportRegistration(unittest.TestCase):
    def test_app_update_packaging_on_clean_checkout_creates_evidence_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            public = root / 'public'
            (public / 'firmware').mkdir(parents=True)
            builds = []
            for family, mode, folder, chip, boot_offset in (
                ('ESP32-C3', 'usb', 'usb', 5, 0), ('ESP32-C3', 'uart', 'uart', 5, 0),
                ('ESP32', 'uart', 'esp32-uart', 0, 0x1000),
                ('ESP32-S3', 'usb', 's3-usb', 9, 0), ('ESP32-S3', 'uart', 's3-uart', 9, 0),
            ):
                source = root / 'firmware/build' / folder
                source.mkdir(parents=True)
                prefix = bytearray(b'\xff' * 0x10000)
                bootloader, partitions = b'bootloader', b'partitions'
                prefix[boot_offset:boot_offset + len(bootloader)] = bootloader
                prefix[0x8000:0x8000 + len(partitions)] = partitions
                app = bytearray(32)
                app[0], app[12] = 0xe9, chip
                for suffix, data in (('bootloader.bin', bootloader), ('partitions.bin', partitions), ('bin', app)):
                    (source / ('IPhoneHIDBridge.ino.' + suffix)).write_bytes(data)
                path = f'firmware/sightlatch-0.2.3-{family}-{mode}.bin'
                (public / path).write_bytes(prefix + app)
                (public / path.replace('0.2.3', '0.2.2')).write_bytes(prefix)
                builds.append({'chipFamily': family, 'variant': mode, 'parts': [{'path': path}]})
            (public / 'firmware/manifest.json').write_text(json.dumps({
                'version': '0.2.3', 'builds': builds, 'source_sha256': {}}))
            self.assertFalse((root / 'build').exists())
            with patch.object(app_updates, 'ROOT', root), patch.object(app_updates, 'PUBLIC', public), redirect_stdout(io.StringIO()):
                app_updates.package()
            evidence = json.loads((root / 'build/application-updates-0.2.3.json').read_text())
            self.assertEqual(len(evidence['builds']), 5)
            self.assertTrue(all(build['prefix_0_to_0x10000_identical'] for build in evidence['builds']))
            self.assertEqual(len(list((public / 'firmware').glob('*-app.bin'))), 5)

    def test_effective_cli_data_directory_for_defaults_and_explicit_configuration(self):
        # Observed Arduino CLI 1.3.1 responses: config dump has no directories
        # for defaults, while config get returns the effective data directory.
        for expected in ('/home/runner/.arduino15', '/build/custom Arduino data'):
            with self.subTest(path=expected), patch.object(
                ble_fix.subprocess, 'check_output', return_value=json.dumps(expected).encode()
            ) as query:
                self.assertEqual(ble_fix.data_directory('arduino-cli'), Path(expected))
                query.assert_called_once_with(['arduino-cli', 'config', 'get', 'directories.data', '--json'])

    def test_missing_or_invalid_effective_data_directory_is_rejected(self):
        for value in (None, '', ' ', {}, []):
            with self.subTest(value=value), patch.object(
                ble_fix.subprocess, 'check_output', return_value=json.dumps(value).encode()
            ):
                with self.assertRaisesRegex(SystemExit, 'directories.data'):
                    ble_fix.data_directory('arduino-cli')

    def test_original_drops_mouse_and_patched_registers_both_reports(self):
        self.assertEqual(hashlib.sha256(FIXTURE.read_bytes()).hexdigest(), ble_fix.UPSTREAM_SHA256)
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / 'src').mkdir()
            source = folder / 'src/BLEService.cpp'
            shutil.copyfile(FIXTURE, source)
            for expected in (1, 2):
                if expected == 2:
                    ble_fix.apply_fix(folder)
                text = source.read_text()
                start = text.index('void BLEService::addCharacteristic(')
                body = text[start:text.index('}  // addCharacteristic', start) + len('}  // addCharacteristic')]
                case = folder / 'test.cpp'
                case.write_text(HARNESS.replace('FUNCTION_UNDER_TEST', body).replace('EXPECTED_REPORTS', str(expected)))
                binary = folder / 'test'
                subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror', str(case), '-o', str(binary)], check=True)
                subprocess.run([str(binary)], check=True)

    def test_unknown_dependency_is_rejected_before_patch(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / 'src').mkdir()
            source = folder / 'src/BLEService.cpp'
            source.write_text('unexpected dependency')
            with self.assertRaises(SystemExit):
                ble_fix.apply_fix(folder)
            self.assertEqual(source.read_text(), 'unexpected dependency')

    def test_builds_select_patched_library_and_fingerprint_patch(self):
        for name in ('build_firmware.sh', 'build_extended_firmware.sh'):
            text = (ROOT / 'scripts' / name).read_text()
            self.assertIn('prepare_ble_library.py "$CLI"', text)
            self.assertIn('--library "$BLE_LIBRARY"', text)
        bridge = (ROOT / 'firmware/IPhoneHIDBridge/Bridge.cpp').read_text()
        self.assertIn('!defined(SIGHTLATCH_NIMBLE_REPORT_REGISTRATION_FIX)', bridge)
        self.assertIn('keyboardReport=hid->inputReport(1);mouseReport=hid->inputReport(2);', bridge)
        self.assertEqual(ble_fix.PATCH.parent, ROOT / 'firmware/IPhoneHIDBridge')


if __name__ == '__main__':
    unittest.main(verbosity=2)
