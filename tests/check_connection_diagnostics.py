"""Public diagnostic fields must observe, never weaken, connection admission."""
from pathlib import Path
import importlib.util
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'firmware/IPhoneHIDBridge/Bridge.cpp').read_text()
spec = importlib.util.spec_from_file_location('provenance', ROOT / 'scripts/firmware_provenance.py')
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)


class ConnectionDiagnostics(unittest.TestCase):
    def test_each_stack_records_rejections_before_disconnecting(self):
        callbacks = SOURCE.split('class ServerCallbacks final', 1)[1].split('class SecurityCallbacks final', 1)[0]
        for body in callbacks.split('  void onConnect(')[1:]:
            body = body.split('  void onDisconnect(', 1)[0]
            self.assertLess(body.index('connectionAttempts.fetch_add(1)'), body.index('if(!pairingOpen())'))
            self.assertLess(body.index('if(!pairingOpen())'), body.index('if(connected.exchange(true))'))
            self.assertEqual(body.count('connectionRejects.fetch_add(1)'), 2)
            self.assertEqual(body.count('server->disconnect('), 2)
            self.assertLess(body.index('ConnectionRejection::PairingWindowClosed'), body.index('server->disconnect('))
            self.assertLess(body.index('connectionAdmissions.fetch_add(1)'), body.index('connId.store('))
            self.assertIn('securityStartEvents.fetch_add(1)', body)
    def test_security_outcome_is_not_authentication(self):
        self.assertIn('BLESecurity::startSecurity(p->conn_handle,&securityResult)', SOURCE)
        self.assertIn('esp_ble_set_encryption(p->connect.remote_bda,ESP_BLE_SEC_ENCRYPT)', SOURCE)
        # Initiating security never sets encrypted=true; the authenticated callback remains authoritative.
        callbacks = SOURCE.split('class ServerCallbacks final', 1)[1].split('class SecurityCallbacks final', 1)[0]
        self.assertNotIn('encrypted.store(true)', callbacks)
        self.assertEqual(SOURCE.count('bool ok=hidpilot::acceptAuthentication('), 2)
        self.assertIn('p->sec_state.encrypted&&p->sec_state.key_size==16', SOURCE)
    def test_public_fields_are_observational_and_shared_by_uart_http(self):
        body = SOURCE.split('static void diagnosticFields(', 1)[1].split('static void statusHandler()', 1)[0]
        for field in ('connection_attempts', 'connection_admissions', 'connection_rejects', 'last_connection_rejection', 'ble_stack', 'firmware_source_sha256', 'security_start_events', 'last_security_start_code', 'last_security_start_accepted'):
            self.assertIn('"' + field + '"', body)
        for forbidden in ('controlToken', 'targetAddress', 'disconnect(', 'startSecurity(', '.store(', '.fetch_add('):
            self.assertNotIn(forbidden, body)
        self.assertIn('diagnosticFields(d)', SOURCE)
        self.assertIn('diagnosticFields(response)', SOURCE)
    def test_fingerprint_changes_for_content_or_file_name_but_not_order(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / 'first.h').write_text('public source')
            a = provenance.source_id(provenance.source_hashes(folder))
            (folder / provenance.PROVENANCE_HEADER).write_text('generated metadata')
            self.assertEqual(a, provenance.source_id(provenance.source_hashes(folder)))
            (folder / 'first.h').write_text('changed public source')
            self.assertNotEqual(a, provenance.source_id(provenance.source_hashes(folder)))
            (folder / 'first.h').write_text('public source')
            (folder / 'first.h').rename(folder / 'second.h')
            self.assertNotEqual(a, provenance.source_id(provenance.source_hashes(folder)))
        self.assertEqual(provenance.source_id({'a': '1', 'b': '2'}), provenance.source_id({'b': '2', 'a': '1'}))
    def test_public_preparation_refuses_private_configuration_and_escape(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'firmware/IPhoneHIDBridge'
            source.mkdir(parents=True)
            (source / 'Bridge.cpp').write_text(provenance.CLASSIC_GUARD)
            (source / 'config.h').write_text('private fixture, never publish')
            destination = root / 'firmware/build/test/IPhoneHIDBridge'
            with patch.object(provenance, 'ROOT', root), patch.object(provenance, 'SOURCE', source):
                with self.assertRaises(SystemExit):
                    provenance.prepare(destination)
                self.assertFalse(destination.exists())
                (source / 'config.h').unlink()
                with self.assertRaises(SystemExit):
                    provenance.prepare(root / 'outside')
                provenance.prepare(destination, classic=True)
                transformed = (destination / 'Bridge.cpp').read_text()
                self.assertIn('!defined(CONFIG_IDF_TARGET_ESP32) && ' + provenance.CLASSIC_GUARD, transformed)
                fingerprint = provenance.source_id(provenance.source_hashes(destination))
                self.assertIn(fingerprint, (destination / provenance.PROVENANCE_HEADER).read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
