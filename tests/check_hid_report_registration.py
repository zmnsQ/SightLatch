"""Exercise the actual pinned upstream addCharacteristic body before/after our patch."""
from pathlib import Path
import hashlib
import importlib.util
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
    def test_effective_cli_data_directory_for_defaults_and_explicit_configuration(self):
        # Observed Arduino CLI 1.3.1 responses: config dump has no directories
        # for defaults, while config get returns the effective data directory.
        for expected in ('/home/runner/.arduino15', '/build/custom Arduino data'):
            with self.subTest(path=expected), patch.object(
                ble_fix.subprocess, 'check_output', return_value=ble_fix.json.dumps(expected).encode()
            ) as query:
                self.assertEqual(ble_fix.data_directory('arduino-cli'), Path(expected))
                query.assert_called_once_with(['arduino-cli', 'config', 'get', 'directories.data', '--json'])

    def test_missing_or_invalid_effective_data_directory_is_rejected(self):
        for value in (None, '', ' ', {}, []):
            with self.subTest(value=value), patch.object(
                ble_fix.subprocess, 'check_output', return_value=ble_fix.json.dumps(value).encode()
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
