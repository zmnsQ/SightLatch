#!/usr/bin/env python3
"""Settings navigation and safety source contracts, not rendered UI or Xcode tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOME = (ROOT / 'ios/App/HomeView.swift').read_text()
WORKSPACE = (ROOT / 'ios/App/WorkspaceViews.swift').read_text()
AI = HOME.split('struct ConfigurationDetailView:', 1)[1].split('struct CalibrationView:', 1)[0]

class SettingsStructure(unittest.TestCase):
    def test_service_picker_precedes_conditional_account_content(self):
        self.assertLess(AI.index('Picker("协议"'), AI.index('ChatGPTSettingsSection(model: model)'))
        self.assertRegex(AI, r'if model.configuration.provider == "chatgpt-plan" \{\s+ChatGPTSettingsSection')
        self.assertIn('Section("API 连接")', AI)

    def test_screenshot_permission_has_one_safety_home(self):
        self.assertEqual(AI.count('isOn: $model.configuration.uploadConsent'), 1)
        safety = AI.split('if safety {', 1)[1]
        self.assertIn('Section("截图上传")', safety)
        self.assertIn('LabeledContent("接收服务"', safety)
        self.assertIn('model.stopAndRevokeConsent()', AI)
        self.assertIn('model.configuration.uploadConsent = false', AI)

    def test_advanced_options_follow_common_controls(self):
        self.assertLess(AI.index('Section("安全与节奏")'), AI.index('Section("高级后台选项")'))
        self.assertIn('DisclosureGroup("后台协调 · iOS 26")', AI)
        self.assertIn('DisclosureGroup("凭据管理")', AI)

    def test_profiles_do_not_loop_back_to_account_sheet(self):
        profiles = WORKSPACE.split('struct ProfilesView:', 1)[1].split('struct TaskLibraryView:', 1)[0]
        hub = WORKSPACE.split('struct WorkspaceHubView:', 1)[1].split('struct OnboardingView:', 1)[0]
        self.assertNotIn('ConfigurationDetailView(', profiles)
        self.assertNotIn('ProfilesView()', hub)
        self.assertEqual(AI.count('ProfilesView()'), 1)
        self.assertNotIn('没有假冒的ChatGPT/Codex OAuth入口', WORKSPACE)

    def test_secondary_pages_share_chrome_and_visible_errors(self):
        self.assertEqual(WORKSPACE.count('.modifier(PilotSettingsPageStyle())'), 4)
        self.assertIn('PilotCloseButton { dismiss() }', WORKSPACE)
        self.assertIn('Section("未能保存")', AI)
        self.assertIn('else { saveError = model.notice }', AI)
        self.assertIn('PilotSettingsNotice(message: exportError, isError: true)', WORKSPACE)

    def test_device_stop_remains_in_toolbar(self):
        device = HOME.split('struct DeviceSettingsView:', 1)[1].split('struct DeviceControlPanel:', 1)[0]
        self.assertIn('ToolbarItem(placement: .cancellationAction)', device)
        self.assertIn('await model.stop()', device)
        self.assertIn('.disabled(model.stopping)', device)
        self.assertNotIn('}.disabled(model.isSessionActive)', device)

    def test_calibration_stays_explicit_and_cancellable(self):
        calibration = HOME.split('struct CalibrationView:', 1)[1].split('struct LogsView:', 1)[0]
        self.assertIn('允许并开始辅助校准', calibration)
        self.assertIn('最长 60 秒', calibration)
        self.assertIn('model.cancelAutomaticCalibration()', calibration)
        self.assertIn('.frame(maxWidth: 540).frame(maxWidth: .infinity).background', calibration)

if __name__ == '__main__':
    unittest.main(verbosity=2)
