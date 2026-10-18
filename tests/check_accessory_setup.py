#!/usr/bin/env python3
"""Static integration contracts only: NOT Apple SDK type checking or Bluetooth tests."""
import pathlib
import plistlib
root = pathlib.Path(__file__).resolve().parents[1]
s = (root / 'ios/App/SightLatchAccessorySetupAdapter.swift').read_text()
info = plistlib.loads((root / 'ios/App/Info.plist').read_bytes())
uuid = '7D9B1E20-4F6A-4C88-A3D2-6E5F0190B7C1'
assert uuid in s
assert info['NSAccessorySetupBluetoothServices'] == [uuid]
assert info['NSAccessorySetupBluetoothNames'] == ['SightLatch']
assert info['NSAccessorySetupKitSupports'] == ['Bluetooth']
assert info['NSAccessorySetupBluetoothCompanyIdentifiers'] == []
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
assert 'CBCentralManager(' not in s and 'scanForPeripherals' not in s
assert 'removeAccessory(' not in s
assert 'com.apple.developer.accessory-setup-discovery-extension' not in (root / 'ios/App/App.entitlements').read_text()
print('PASS: AccessorySetupKit static capability, privacy, declaration and lifecycle contracts')
