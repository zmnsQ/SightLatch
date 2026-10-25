#!/usr/bin/env python3
"""Settings navigation and safety source contracts, not rendered UI or Xcode tests."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOME = (ROOT / 'ios/App/HomeView.swift').read_text()
WORKSPACE = (ROOT / 'ios/App/WorkspaceViews.swift').read_text()
AI = HOME.split('struct ConfigurationDetailView:', 1)[1].split('struct CalibrationView:', 1)[0]
AI_SETTINGS = AI.split('private var aiSettings:', 1)[1].split('private var apiSettings:', 1)[0]
PRIVACY = AI.split('private var privacySettings:', 1)[1].split('private func saveSettings()', 1)[0]


def view_source(source, name):
    body = source.split('struct ' + name + ':', 1)[1]
    return re.split(r'\n(?:private )?(?:struct|enum) ', body, maxsplit=1)[0]


class SettingsStructure(unittest.TestCase):
    def test_service_picker_precedes_conditional_account_content(self):
        self.assertLess(AI_SETTINGS.index('selection: $model.configuration.provider'),
                        AI_SETTINGS.index('if model.configuration.provider == "chatgpt-plan"'))
        self.assertRegex(AI_SETTINGS, r'if model.configuration.provider == "chatgpt-plan" \{\s+ChatGPTSettingsSection')
        self.assertRegex(AI_SETTINGS, r'\} else \{\s+apiSettings')
        self.assertIn('text: $model.apiKey', AI)
        self.assertIn('text: $model.configuration.endpoint', AI)

    def test_screenshot_permission_has_one_safety_home(self):
        binding = 'isOn: $model.configuration.uploadConsent'
        self.assertEqual(AI.count(binding), 1)
        self.assertEqual(PRIVACY.count(binding), 1)
        self.assertNotIn(binding, AI_SETTINGS)
        self.assertIn('LabeledContent("接收服务"', PRIVACY)
        self.assertIn('if !safety { aiSettings }', AI)
        self.assertIn('if safety { privacySettings }', AI)
        self.assertIn('model.stopAndRevokeConsent()', AI)
        self.assertIn('model.configuration.uploadConsent = false', AI)

    def test_advanced_options_stay_secondary_and_credential_deletion_is_confirmed(self):
        self.assertLess(PRIVACY.index('isOn: $model.configuration.uploadConsent'),
                        PRIVACY.index('isOn: $model.configuration.allowLowRiskNavigation'))
        advanced = PRIVACY.split('DisclosureGroup("高级后台选项")', 1)[1]
        self.assertIn('if #available(iOS 26.0, *)', advanced)
        self.assertIn('model.configuration.continuedProcessingEnabled = $0', advanced)
        self.assertIn('DisclosureGroup("凭据管理")', AI_SETTINGS)
        confirmation = AI.split('.confirmationDialog(', 1)[1]
        self.assertIn('role: .destructive', confirmation)
        self.assertIn('model.deleteSecrets()', confirmation)

    def test_secondary_destinations_share_the_existing_stack(self):
        profiles = view_source(WORKSPACE, 'ProfilesView')
        hub = view_source(WORKSPACE, 'WorkspaceHubView')
        self.assertNotIn('ConfigurationDetailView(', profiles)
        self.assertNotIn('ProfilesView(', hub)
        self.assertRegex(AI, r'\.navigationDestination\(isPresented: \$showProfiles\)\s*\{\s*ProfilesView\(embedded: true\)')
        self.assertIn('NavigationLink { TransferView(embedded: true) }', hub)
        self.assertIn('NavigationLink { GatewaySetupView(embedded: true) }', profiles)
        for page in (hub, profiles):
            self.assertNotIn('.sheet(', page)
        settings = view_source(WORKSPACE, 'SettingsView')
        self.assertIn('.navigationDestination(for: Destination.self)', settings)
        self.assertIn('case .workspace: WorkspaceHubView(embedded: true)', settings)
        self.assertIn('case .voice: VoiceFeedbackSettingsPage()', settings)

    def test_secondary_pages_keep_root_exit_and_visible_errors(self):
        for name in ('WorkspaceHubView', 'ProfilesView', 'TransferView', 'GatewaySetupView'):
            page = view_source(WORKSPACE, name)
            self.assertIn('var embedded = false', page, name)
            self.assertIn('PilotSettingsNavigation(embedded: embedded)', page, name)
            self.assertRegex(page, r'PilotSettingsPageStyle\(showsCloseButton: !embedded(?:,|\))', name)
        style = view_source(WORKSPACE, 'PilotSettingsPageStyle')
        self.assertIn('if showsCloseButton', style)
        self.assertIn('PilotCloseButton { dismiss() }', style)
        self.assertIn('PilotSettingsNotice(message: saveError, isError: true)', AI)
        self.assertIn('else { saveError = model.notice }', AI)
        transfer = view_source(WORKSPACE, 'TransferView')
        self.assertIn('if let exportError { PilotSettingsNotice(message: exportError, isError: true) }', transfer)
        self.assertIn('.fileExporter(', transfer)
        self.assertIn('.fileImporter(', transfer)
        self.assertIn('model.importSettings(url); feedback = model.notice', transfer)

    def test_device_toolbar_is_close_only(self):
        device = view_source(HOME, 'DeviceSettingsView')
        self.assertIn('PilotCloseButton', device)
        self.assertNotIn('ToolbarItem(placement: .cancellationAction)', device)
        self.assertNotIn('}.disabled(model.isSessionActive)', device)

    def test_absolute_calibration_stays_explicit_and_cancellable(self):
        calibration = view_source(HOME, 'CalibrationView')
        measurement = view_source(HOME, 'AbsoluteCalibrationMeasurementView')
        self.assertIn('{ showMeasurement = true }', calibration)
        self.assertIn('.fullScreenCover(isPresented: $showMeasurement', calibration)
        self.assertNotIn('startAutomaticCalibration()', calibration)
        self.assertRegex(measurement, r'\.task \{\s+await model.startAutomaticCalibration\(\)')
        self.assertIn('AbsoluteCalibrationCanvas(model: model).ignoresSafeArea()', measurement)
        self.assertIn('.interactiveDismissDisabled()', measurement)
        self.assertIn('model.calibrationFlow.stopConfirmed', measurement)
        self.assertIn('model.recordCalibrationCancellation(source: .measurementStopButton', measurement)
        self.assertIn('await model.endPointerCalibration()', measurement)
        self.assertIn('guard canLeave else { return }', measurement)
        self.assertIn('guard busy else { return }', measurement)
        self.assertIn('guard model.calibrationFlow.id == flowID', measurement)
        self.assertIn('cancelIfBusy(source: .sceneInactive', measurement)
        self.assertIn('cancelIfBusy(source: .sceneBackground', measurement)
        for obsolete in ('markObservedPointer', 'confirmPointerCalibration()', 'startCalibrationMeasurement()'):
            self.assertNotIn(obsolete, calibration + measurement)


if __name__ == '__main__':
    unittest.main(verbosity=2)
