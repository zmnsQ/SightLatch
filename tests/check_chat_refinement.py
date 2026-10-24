"""Source contracts, not a substitute for Apple SDK or physical-device UI tests."""
from pathlib import Path
import re
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
        self.assertNotIn('confirmTextPlanning', self.home)
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
    def test_probe_feedback_is_local_and_cancellation_is_available(self):
        panel=self.home.split('struct DeviceControlPanel:',1)[1].split('struct BroadcastPicker:',1)[0]
        self.assertIn('if model.probing { ProgressView() }',panel)
        self.assertIn('Text(model.probeState.message)',panel)
        self.assertIn('model.probeState.phase != .idle && model.probeState.phase != .success',panel)
        self.assertIn('DeviceProbeResultView()', panel)
        self.assertIn('model.cancelProbe()', panel)
        device = self.home.split("struct DeviceSettingsView:", 1)[1].split("struct DeviceControlPanel:", 1)[0]
        self.assertIn('PilotCloseButton', device)
        self.assertNotIn('stop.circle', device)
        self.assertNotIn('Button("紧急停止控制"', panel)
        self.assertIn('model.cancelPairing()', panel)
    def test_send_prepares_and_system_picker_remains_explicit(self):
        self.assertNotIn('model.allowPlannedTask(requestID: requestID)', self.home)
        self.assertNotIn('允许屏幕上传与设备控制', self.home)
        self.assertIn('BroadcastPicker()', self.home)
        self.assertIn('.disabled(!model.prepared || model.stopping)', self.home)
        self.assertIn('uiView.isUserInteractionEnabled = context.environment.isEnabled', self.home)
        self.assertNotIn('sendActions', self.home)
        self.assertNotIn('subviews', self.home)
        self.assertNotIn('await model.prepare()', self.home)
    def test_keyboard_focus_is_local_and_does_not_intercept_controls(self):
        self.assertIn('@FocusState private var composerFocused', self.home)
        self.assertIn('@FocusState private var deviceField', self.home)
        self.assertIn('@FocusState private var aiField', self.home)
        self.assertGreaterEqual(self.home.count('.scrollDismissesKeyboard(.interactively)'), 3)
        self.assertNotIn('highPriorityGesture', self.home)
        self.assertNotIn('simultaneousGesture', self.home)
        self.assertNotIn('.onSubmit', self.home)
        action = self.home.split('private var primaryAction:', 1)[1].split('private var currentSessionLogs:', 1)[0]
        self.assertLess(action.index('composerFocused = false'), action.index('confirmUnlimitedRun = true'))
        self.assertRegex(action, r'else\s*\{\s*Task\s*\{\s*await model.submitGoal\(\)\s*\}\s*\}')
    def test_unlimited_confirmation_cancel_does_not_start_or_resume(self):
        alert = self.home.split('isPresented: $confirmUnlimitedRun)', 1)[1].split('} message:', 1)[0]
        cancel = re.search(r'Button\("取消", role: \.cancel\) \{([^}]+)\}', alert)
        self.assertIsNotNone(cancel)
        self.assertIn('pendingUnlimitedRequestID = nil', cancel[1])
        for forbidden in ('submitGoal', 'resumePlannedTask', 'prepare('):
            self.assertNotIn(forbidden, cancel[1])
        confirmed = self.home.split('private func submitConfirmedUnlimitedRun()', 1)[1].split('private var resultPresentation:', 1)[0]
        self.assertIn('guard model.taskFlow.requestID == requestID', confirmed)
        self.assertIn('resumePlannedTask(requestID: requestID, unlimitedConfirmed: true)', confirmed)
        self.assertIn('submitGoal(unlimitedConfirmed: true)', confirmed)
    def test_pairing_sheet_and_calibration_are_explicit(self):
        self.assertIn('.sheet(item: $deviceSheet', self.home)
        self.assertIn('DevicePairingResultView()', self.home)
        self.assertIn('model.cancelPairing()', self.home)
        self.assertIn('model.pairingState.remainingSeconds', self.home)
        self.assertIn('accessorySetupServiceUUID?.uppercased() == SightLatchAccessorySetupAdapter.serviceUUID', self.home)
        self.assertIn('.onChange(of: model.pairingState.phase, initial: true)', self.home)
        self.assertIn('if phase == .waiting { presentSystemPairing() }', self.home)
        self.assertIn('if showsManualPairing {', self.home)
        self.assertNotIn('requestDeviceControl(pairing: false)', self.home)
        calibration = self.home.split('struct CalibrationView:', 1)[1].split('struct LogsView:', 1)[0]
        self.assertIn('model.startAutomaticCalibration()', calibration)
        self.assertNotIn('model.startAssistedCalibration()', calibration)
        self.assertIn('.fullScreenCover(isPresented: $showMeasurement', calibration)
        self.assertIn('AbsoluteCalibrationCanvas(model: model).ignoresSafeArea()', calibration)
        self.assertIn('.statusBarHidden(true)', calibration)
        self.assertIn('.interactiveDismissDisabled()', calibration)
        self.assertIn('model.calibrationFlow.stopConfirmed', calibration)
        self.assertNotIn('model.confirmPointerCalibration()', calibration)
        self.assertIn('model.recordCalibrationCancellation(source: .measurementStopButton', calibration)
        self.assertIn('cancelIfBusy(source: .viewDisappeared', calibration)
        self.assertIn('cancelIfBusy(source: .sceneInactive', calibration)
        self.assertIn('cancelIfBusy(source: .sceneBackground', calibration)
        self.assertIn('guard model.calibrationFlow.id == flowID', calibration)
        self.assertNotIn('指针已就位', calibration)
        self.assertNotIn('model.manual(.click', calibration)
        self.assertNotIn('model.manual(.text', calibration)
    def test_refined_visual_surfaces_and_graphics(self):
        self.assertIn('enum PilotPalette', self.home)
        self.assertIn('PilotConnectionIllustration()', self.home)
        self.assertIn('PilotLinkArtwork()', self.home)
        self.assertIn('PilotBridgeArtwork()', self.home)
        self.assertIn('.presentationCornerRadius(32)', self.home)
        self.assertIn('PilotCloseButton', self.home)
        self.assertIn('RoundedRectangle(cornerRadius: 24)', self.workspace)
        self.assertIn('settingsRow("设备", subtitle: "连接与配对"', self.workspace)
    def test_mic_is_icon_with_accessible_target(self):
        self.assertIn('.frame(width: 44, height: 44)', self.voice)
        self.assertIn('accessibilityIdentifier("chat.microphone")',self.voice)
        self.assertNotIn('    Label(recorder.isRecording',self.voice)
        self.assertNotIn('model.prepare()',self.voice)
if __name__=='__main__': unittest.main(verbosity=2)
