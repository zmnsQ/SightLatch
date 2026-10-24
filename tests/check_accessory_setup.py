#!/usr/bin/env python3
"""Static contracts and compiled mocked transport lifecycle; not Bluetooth tests."""
import os
import pathlib
import platform
import plistlib
import subprocess
import tempfile
root = pathlib.Path(__file__).resolve().parents[1]
s = (root / 'ios/App/SightLatchAccessorySetupAdapter.swift').read_text()
info = plistlib.loads((root / 'ios/App/Info.plist').read_bytes())
uuid = '7D9B1E20-4F6A-4C88-A3D2-6E5F0190B7C1'
assert uuid in s
assert info['NSAccessorySetupBluetoothServices'] == [uuid]
assert info['NSAccessorySetupBluetoothNames'] == ['SightLatch']
assert info['NSAccessorySetupKitSupports'] == ['Bluetooth']
# Discovery uses our service UUID and name, not manufacturer data. An empty
# company-identifier declaration makes ASAccessorySession.activate trap on iOS.
assert 'NSAccessorySetupBluetoothCompanyIdentifiers' not in info
assert 'descriptor.bluetoothCompanyIdentifier =' not in s
for key, value in info.items():
    if key.startswith('NSAccessorySetup'):
        assert isinstance(value, list) and value, f'{key} must not be empty'
        assert all(isinstance(item, str) and item.strip() for item in value), key
assert 'guard #available(iOS 18.4, *)' in s
assert 'compiler(>=6.1)' in s
assert 'guard serviceUUID?.uppercased() == Self.serviceUUID' in s
assert 'guard pairingWindowIsOpen, remainingSeconds > 0' in s
assert 'descriptor.supportedOptions = [.bluetoothHID, .bluetoothPairingLE]' in s
assert 'descriptor.bluetoothNameSubstring = "SightLatch"' in s
assert 'descriptor.bluetoothServiceUUID = CBUUID(string: Self.serviceUUID)' in s
assert 'generation == attempt' in s and 'previous?.invalidate()' in s
assert 'case .accessoryAdded:' in s and '.selectedAwaitingVerification' in s
assert 'case .pickerDidDismiss:' in s
assert 'App-Prefs:' not in s and 'prefs:' not in s
assert 'central.retrievePeripherals(withIdentifiers: [identifier])' in s
assert 'target.identifier == identifier' in s
assert 'known.count == 1' in s and 'known.count > 1' in s
assert 'accessory.state == .authorized' in s
assert 'accessory.descriptor.bluetoothServiceUUID == CBUUID(string: serviceUUID)' in s
assert 'accessory.descriptor.bluetoothNameSubstring == "SightLatch"' in s
for forbidden in ('scanForPeripherals(', 'discoverServices(', 'discoverCharacteristics(', 'writeValue(', 'setNotifyValue('):
    assert forbidden not in s
home = (root / 'ios/App/HomeView.swift').read_text()
assert 'else if phase == .connected { accessorySetup.completeVerification() }' in home
assert 'guard !usesSystemMouse else { return }' in home
assert 'guard !usesSystemMouse, !model.pairingUsesSystemMouse, supportsSystemPairing' in home
assert 'DevicePairingResultView(usesSystemMouse: true)' in home
assert 'model.checkSystemMousePairing()' in home
assert 'releaseConnectionsForSystemPairing()' in s
assert 'if let accessoryFailure {' in home
assert 'if waiting && accessoryFailure == nil {' in home
assert 'guard case .failed(let reason) = state else { return }' in home
assert 'if waiting { Task { await model.cancelPairing() } }' in home
assert 'removeAccessory(' not in s
assert 'com.apple.developer.accessory-setup-discovery-extension' not in (root / 'ios/App/App.entitlements').read_text()
print('PASS: AccessorySetupKit static capability, privacy, declaration and lifecycle contracts')
transport = s.split('// MARK: - Selected accessory transport', 1)[1].rsplit('#endif', 1)[0]
diagnostics = s.split('// MARK: - Pairing diagnostics', 1)[1].split('// MARK: - Pairing adapter', 1)[0]
with tempfile.TemporaryDirectory() as directory:
    directory = pathlib.Path(directory)
    source = directory / 'AccessoryConnection.swift'
    source.write_text((root / 'tests/accessory_connection_test_support.swift').read_text()
                      + diagnostics + transport + (root / 'tests/accessory_connection_test.swift').read_text())
    compiler = [os.environ.get('SWIFTC', 'swiftc')]
    sdk_options = []
    if platform.system() == 'Darwin':
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        sdk_options = ['-sdk', sdk]
    output = directory / 'accessory-connection-tests'
    subprocess.run(compiler + sdk_options + ['-swift-version', '6', '-parse-as-library', str(source), '-o', str(output)], check=True)
    subprocess.run([str(output)], check=True)
