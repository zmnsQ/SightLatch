#!/usr/bin/env python3
"""Lightweight regressions only; not an ESP-IDF or iOS compile/hardware test."""
import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("label", ROOT / "scripts/prepare_usb_pairing_label.py")
label = importlib.util.module_from_spec(spec)
spec.loader.exec_module(label)

class USBPrototypeTests(unittest.TestCase):
    def test_fixed_width_salt_and_verifier(self):
        salt = bytes(range(32))  # Deliberately leading zero; synthetic fixture.
        verifier = label.derive_verifier("synthetic-test-code-not-a-real-secret", salt)
        self.assertEqual(len(verifier), 384)
        self.assertEqual(hashlib.sha256(verifier).hexdigest(), "38e5e06ef93c3b86728cdc583962d01f17c7a99351fd474962a21fcef465d55a")
        self.assertNotEqual(verifier, label.derive_verifier("different-synthetic-test-code", salt))
        with self.assertRaises(ValueError): label.derive_verifier("test", salt[1:])

    def test_label_is_not_in_firmware_csv_or_stdout(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "dummy"
            output = io.StringIO()
            with patch.object(label.secrets, "token_hex", return_value="dummy-only-00000000000000000000000"), patch.object(label.secrets, "token_bytes", return_value=bytes(range(32))), contextlib.redirect_stdout(output):
                label.prepare(dest)
            self.assertNotIn("dummy-only", (dest / "factory.csv").read_text())
            self.assertNotIn("dummy-only", output.getvalue())
            self.assertEqual((dest / "label.txt").stat().st_mode & 0o777, 0o600)
            self.assertEqual(dest.stat().st_mode & 0o777, 0o700)
            with self.assertRaises(FileExistsError): label.prepare(dest)

    def test_fail_closed_source_contract(self):
        main = (ROOT / "firmware/SightLatchS3USB/main/main.c").read_text()
        config = (ROOT / "firmware/SightLatchS3USB/sdkconfig.defaults").read_text()
        self.assertIn('protocomm_set_security(pc,"prov-session",&protocomm_security2,&sec)', main)
        self.assertIn('(!handshake||pairing_open())', main)
        self.assertIn('!pairing_open()||provisioned_in_window', main)
        self.assertIn('(uint32_t)seq!=next_sequence', main)
        self.assertIn('!usb_link_ready()', main)
        self.assertIn('release_requested=true;', main)
        self.assertIn('req->content_len<(handshake?1:18)', main)
        self.assertIn('!valid_handshake(body,have)', main)
        self.assertIn('if(handshake)bootloader_random_enable();', main)
        self.assertIn('if(handshake)bootloader_random_disable();', main)
        self.assertIn('if(release_requested)release_requested=!usb_link_release();', main)
        self.assertIn('if(job.active&&!release_requested)', main)
        self.assertNotIn('nvs_flash_erase', main)
        self.assertNotIn('esp_wifi_start', main)  # Do not expose this listener on Wi-Fi.
        self.assertIn('CONFIG_ESP_PROTOCOMM_SUPPORT_SECURITY_VERSION_0 is not set', config)
        self.assertIn('CONFIG_ESP_PROTOCOMM_SUPPORT_SECURITY_VERSION_1 is not set', config)
        self.assertNotIn('esp_srp_gen_salt_verifier(', (ROOT / "firmware/SightLatchS3USB/main/pairing_verifier.c").read_text())
        usb = (ROOT / "firmware/SightLatchS3USB/main/usb_link.c").read_text()
        self.assertIn('TUD_CDC_NCM_DESCRIPTOR(0, 4, 5', usb)
        self.assertIn('TUD_HID_DESCRIPTOR(2, 6', usb)
        self.assertIn('ESP_NETIF_ROUTER_SOLICITATION_ADDRESS', usb)
        self.assertIn('ESP_NETIF_DOMAIN_NAME_SERVER', usb)

if __name__ == "__main__": unittest.main()
