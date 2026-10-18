"""Source/build contract checks, not a substitute for hardware verification."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class C3Contracts(unittest.TestCase):
    def test_public_defaults_have_no_gpio_or_secrets(self):
        s=(ROOT/'firmware/IPhoneHIDBridge/config.default.h').read_text()
        self.assertIn('#define SIGHTLATCH_SOFTWARE_CONTROL 1',s)
        self.assertNotIn('STOP_GPIO',s);self.assertNotIn('ARM_GPIO',s)
        for key in ('WIFI_SSID','WIFI_PASSWORD','CONTROL_TOKEN'):
            self.assertIn(f'#define {key} ""',s)
    def test_software_control_remains_authenticated_and_fail_closed(self):
        s=(ROOT/'firmware/IPhoneHIDBridge/Bridge.cpp').read_text()
        for name in ('pairHandler','armHandler','stopHandler'):
            body=s.split('static void '+name+'() {',1)[1]
            self.assertIn('if(!authorized())',body[:80])
        self.assertIn('ble_hs_cfg.sm_sc_only=1',s)
        self.assertIn('p->sec_state.encrypted&&p->sec_state.key_size==16',s)
        self.assertIn('static bool armed = false',s)
        self.assertIn('tskNO_AFFINITY',s)
        self.assertIn('if(!armed) {',s)
        self.assertIn('pairUntil.store(0);bleServer->getAdvertising()->stop()',s)
    def test_stop_invalidates_late_control_requests(self):
        s=(ROOT/'firmware/IPhoneHIDBridge/Bridge.cpp').read_text()
        stop=s.split('static void stopHandler() {',1)[1].split('static bool parseControlRequest',1)[0]
        self.assertLess(stop.index('controlEpoch=randomId();emergency.store(true);'),stop.index('respond(202,d)'))
        for name in ('pairHandler','armHandler'):
            body=s.split('static void '+name+'() {',1)[1].split('\n}',1)[0]
            self.assertIn('if(!parseControlRequest(expectedBoot,expectedEpoch'+(',&requestedCalibration' if name=='armHandler' else '')+'))return;',body)
            self.assertIn('if(expectedBoot!=bootId||expectedEpoch!=controlEpoch)',body)
            self.assertIn('error(409,"control_epoch_mismatch");return;',body)
        self.assertIn('nextSequence=1;controlEpoch=randomId();',s)
        self.assertIn('bootId=randomId();controlEpoch=randomId();',s)
    def test_no_public_build_uses_private_config(self):
        s=(ROOT/'scripts/build_firmware.sh').read_text()
        self.assertIn('Refusing public build',s)
        self.assertIn('FlashMode=dio,FlashFreq=40,FlashSize=4M',s)
if __name__=='__main__':unittest.main(verbosity=2)
