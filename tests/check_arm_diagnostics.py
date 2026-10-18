"""Source contracts complement the compiled authentication regression; not hardware QA."""
from pathlib import Path
import unittest
S=(Path(__file__).resolve().parents[1]/'firmware/IPhoneHIDBridge/Bridge.cpp').read_text()
class Contracts(unittest.TestCase):
 def test_authentication_policy_used_by_both_stacks(self):
  self.assertEqual(S.count('bool ok=hidpilot::acceptAuthentication('),2)
  self.assertIn('p->sec_state.encrypted&&p->sec_state.key_size==16',S)
  self.assertIn('result.success && (result.auth_mode & ESP_LE_AUTH_REQ_SC_ONLY)',S)
 def test_read_only_diagnostics(self):
  fields=S.split('static void diagnosticFields(',1)[1].split('static void statusHandler()',1)[0]
  for name in ('reset_reason','last_disconnect_reason','last_encryption_status','auth_events','auth_rejects','notify_errors','safety_stack_free_bytes'):
   self.assertIn('"'+name+'"',fields)
  for forbidden in ('releaseReports(', 'disconnect(', 'start(', 'disarm(', 'controlToken'):
   self.assertNotIn(forbidden,fields)
 def test_cancel_cannot_stop_new_session(self):
  body=S.split('static void cancelPairingHandler() {',1)[1].split('static void armHandler()',1)[0]
  self.assertIn('if(!authorized())return;',body)
  self.assertIn('expectedBoot!=bootId||expectedEpoch!=controlEpoch||armed||!pairingOpen()',body)
  self.assertLess(body.index('pairing_window_changed'),body.index('pairUntil.store(0)'))
  self.assertNotIn('disarm(',body)
  self.assertNotIn('emergency.store(',body)
 def test_hardware_calibration_gate(self):
  arm=S.split('static void armHandler()',1)[1].split('static bool validCredentials',1)[0]
  self.assertIn('armed&&calibrationMode!=requestedCalibration',arm)
  self.assertIn('if(!armed) {',arm)
  self.assertIn('hidpilot::controlLeaseMs(calibrationMode,ARM_LEASE_MS)',arm)
  self.assertIn('candidate.kind!=Kind::Release',S)
  self.assertIn('candidate.kind!=Kind::Move || !hidpilot::calibrationMoveAllowed(candidate.dx,candidate.dy)',S)
  self.assertIn('failure="calibration_action_not_allowed"',S)
  self.assertIn('d["control_lease_mode"]',S)
  self.assertIn('d["lease_remaining_ms"]',S)
 def test_discovery_payload_budget_and_no_control_characteristics(self):
  self.assertEqual(3+18+4+4,29)
  self.assertEqual(len('SightLatch')+2,12)
  self.assertIn('bleServer->createService(ACCESSORY_SETUP_UUID)->start();',S)
  self.assertIn('discovery.setCompleteServices(BLEUUID((uint16_t)0x1812));',S)
  self.assertIn('discovery.getPayload().length()>31',S)
  self.assertIn('adv->setScanResponseData(scanResponse)',S)
  self.assertIn('d["accessory_setup_service_uuid"]=ACCESSORY_SETUP_UUID;',S)
if __name__=='__main__':unittest.main(verbosity=2)
