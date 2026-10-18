#!/usr/bin/env python3
"""Source contracts only; Apple SDK and physical device validation remain required."""
from pathlib import Path
import plistlib
import unittest
ROOT = Path(__file__).resolve().parents[1]
def read(path): return (ROOT / path).read_text()
class ShortcutsContracts(unittest.TestCase):
    def test_prepare_never_executes_or_broadcasts(self):
        code = read('ios/App/SightLatchShortcuts.swift')
        self.assertEqual(code.count('static var openAppWhenRun = true'), 2)
        self.assertEqual(code.count('.requiresAuthentication'), 2)
        for forbidden in ['.prepare()', 'RPSystemBroadcastPickerView', 'HardwareClient', 'command.json']:
            self.assertNotIn(forbidden, code)
        self.assertIn('StopPilotSessionIntent()', code)
        self.assertIn('@Parameter(title: "任务文本"', code)
    def test_permissions_and_deep_link(self):
        info = plistlib.loads((ROOT / 'ios/App/Info.plist').read_bytes())
        for key in ['NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription']:
            self.assertTrue(info[key])
        self.assertIn('sightlatch', info['CFBundleURLTypes'][0]['CFBundleURLSchemes'])
    def test_voice_lifetime_and_no_submit(self):
        code = read('ios/App/VoiceTaskComposer.swift')
        for required in ['requestAuthorization', 'requestRecordPermission', 'generation == token',
                         'phase == .background', '.onDisappear', '.seconds(55)', 'text = originalDraft',
                         'sampleRate > 0', 'channelCount > 0', 'interruptionNotification']:
            self.assertIn(required, code)
        self.assertNotIn('model.prepare', code)
        self.assertNotIn('model.send', code)
    def test_activity_privacy_and_coalescing(self):
        widget = read('ios/Widget/PilotWidget.swift')
        for unsafe in ['context.state.detail', 'command.task', 'status.detail']:
            self.assertNotIn(unsafe, widget)
        self.assertIn('sightlatch://chat', widget)
        self.assertIn('context.isStale', widget)
        manager = read('ios/App/PilotActivityManager.swift')
        for required in ['5 - Date()', 'latest[id]', 'stage.needsAttention', 'alerted[id', 'stage.isTerminal && !running']:
            self.assertIn(required, manager)
if __name__ == '__main__': unittest.main(verbosity=2)
