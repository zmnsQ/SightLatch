"""Source contracts, not a substitute for Apple SDK or physical-device UI tests."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class ChatRefinement(unittest.TestCase):
    def setUp(self):
        self.home = (ROOT/'ios/App/HomeView.swift').read_text()
        self.workspace = (ROOT/'ios/App/WorkspaceViews.swift').read_text()
        self.voice = (ROOT/'ios/App/VoiceTaskComposer.swift').read_text()
    def test_stop_replaces_send_and_covers_preparation(self):
        action = self.home.split('private var primaryAction:', 1)[1].split('private var currentSessionLogs:', 1)[0]
        self.assertIn('if model.isSessionActive', action)
        self.assertNotIn('await model.prepare()', action)
        self.assertIn('await model.submitGoal()', action)
        self.assertIn('confirmTextPlanning = true', action)
        self.assertEqual(action.count('await model.stop()'), 1)
        self.assertNotIn('disabled(model.isSessionActive)', action)
        vm=(ROOT/'ios/App/PilotViewModel.swift').read_text()
        self.assertIn('preparingRequestInFlight || preparing || stopping || sending || controllingDevice', vm)
    def test_clear_settings_and_single_device_editor(self):
        self.assertIn('Label("设置", systemImage: "gearshape")', self.home)
        self.assertNotIn('ellipsis.circle', self.home)
        self.assertEqual(self.home.count('text: $model.configuration.deviceURL'),1)
        for item in ['设备','AI 账户','权限与安全']:
            self.assertIn('settingsRow("'+item+'"', self.workspace)
    def test_onboarding_is_progressive_and_grants_no_consent(self):
        intro=self.workspace.split('struct OnboardingView:',1)[1].split('struct SettingsView:',1)[0]
        self.assertIn('step < 3',intro)
        self.assertIn('switch step',intro)
        self.assertNotIn('ForEach(model.readiness())', intro)
        for forbidden in ['uploadConsent = true', 'await model.prepare()', 'requestDeviceControl']:
            self.assertNotIn(forbidden,intro)
    def test_probe_feedback_is_local_and_stop_is_independent(self):
        panel=self.home.split('struct DeviceControlPanel:',1)[1].split('struct BroadcastPicker:',1)[0]
        self.assertIn('if model.probing { ProgressView() }',panel)
        self.assertIn('Text(model.probeState.message)',panel)
        self.assertIn('DeviceProbeResultView()', panel)
        self.assertIn('model.cancelProbe()', panel)
        self.assertIn('Button("紧急停止控制", role: .destructive)',panel)
        self.assertIn('.disabled(model.stopping)',panel)
    def test_control_requires_distinct_explicit_permission(self):
        self.assertIn('model.allowPlannedTask(requestID: requestID)', self.home)
        self.assertIn('基于目标，尚未观察屏幕', self.home)
        self.assertIn('允许屏幕上传与设备控制', self.home)
        self.assertNotIn('await model.prepare()', self.home)
    def test_keyboard_focus_is_local_and_does_not_intercept_controls(self):
        self.assertIn('@FocusState private var composerFocused', self.home)
        self.assertIn('@FocusState private var deviceField', self.home)
        self.assertIn('@FocusState private var aiField', self.home)
        self.assertGreaterEqual(self.home.count('.scrollDismissesKeyboard(.interactively)'), 3)
        self.assertNotIn('highPriorityGesture', self.home)
        self.assertNotIn('simultaneousGesture', self.home)
        self.assertNotIn('.onSubmit', self.home)
        self.assertIn('composerFocused = false\n                if model.configuration.textPlanningConsent', self.home)
    def test_pairing_sheet_and_calibration_are_explicit(self):
        self.assertIn('.sheet(item: $deviceSheet', self.home)
        self.assertIn('DevicePairingResultView()', self.home)
        self.assertIn('model.cancelPairing()', self.home)
        self.assertIn('model.pairingState.remainingSeconds', self.home)
        self.assertIn('accessorySetupServiceUUID?.uppercased() == SightLatchAccessorySetupAdapter.serviceUUID', self.home)
        self.assertNotIn('requestDeviceControl(pairing: false)', self.home)
        calibration = self.home.split('struct CalibrationView:', 1)[1].split('struct LogsView:', 1)[0]
        self.assertIn('model.startAutomaticCalibration()', calibration)
        self.assertIn('model.startAssistedCalibration()', calibration)
        self.assertIn('UIDevice.current.userInterfaceIdiom == .phone', calibration)
        self.assertIn('model.automaticCalibration.isAwaitingMarker', calibration)
        self.assertIn('PointerCalibrationCanvas(model: model)', calibration)
        self.assertNotIn('model.confirmPointerCalibration()', calibration)
        self.assertIn('model.cancelAutomaticCalibration()', calibration)
        self.assertIn('phase != .active', calibration)
        self.assertNotIn('model.manual(.click', calibration)
        self.assertNotIn('model.manual(.text', calibration)
    def test_refined_visual_surfaces_and_graphics(self):
        self.assertIn('enum PilotPalette', self.home)
        self.assertIn('PilotConnectionIllustration()', self.home)
        self.assertIn('DeviceConnectionIllustration', self.home)
        self.assertIn('.presentationCornerRadius(32)', self.home)
        self.assertIn('PilotCloseButton', self.home)
        self.assertIn('RoundedRectangle(cornerRadius: 28)', self.workspace)
        self.assertIn('settingsRow("设备", subtitle: "连接与配对"', self.workspace)
    def test_mic_is_icon_with_accessible_target(self):
        self.assertIn('.frame(width: 44, height: 44)', self.voice)
        self.assertIn('accessibilityIdentifier("chat.microphone")',self.voice)
        self.assertNotIn('    Label(recorder.isRecording',self.voice)
        self.assertNotIn('model.prepare()',self.voice)
if __name__=='__main__': unittest.main(verbosity=2)
