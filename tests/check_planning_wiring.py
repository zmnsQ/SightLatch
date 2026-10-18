from pathlib import Path
import unittest

class PlanningWiring(unittest.TestCase):
    def test_submit_has_no_hardware_or_prepare(self):
        s = Path('ios/App/PilotTaskPlanning.swift').read_text().split('func submitGoal()',1)[1].split('func allowPlannedTask',1)[0]
        for forbidden in ['HardwareClient', 'prepare()', 'startCommand', 'SessionCommand', 'jpeg:']:
            self.assertNotIn(forbidden, s)
        self.assertIn('planningTask = request', s)
        self.assertIn('request.cancel()', s)
        self.assertIn('!request.isCancelled', s)
    def test_only_goal_bound_permission_can_prepare(self):
        s = Path('ios/App/PilotViewModel.swift').read_text().split('func prepare()',1)[1].split('func stop()',1)[0]
        self.assertLess(s.index('taskFlow.consumePermission'), s.index('HardwareClient'))
        self.assertIn('SessionCommand(task: preparedGoal', s)
        self.assertIn('== preparedGoal', s)
        v = Path('ios/App/PilotTaskPlanning.swift').read_text()
        self.assertLess(v.index('taskFlow.authorize'), v.index('await prepare()'))
    def test_text_path_never_fakes_image(self):
        s = Path('ios/Shared/AIClient+Planning.swift').read_text().split('enum PlanningResponse',1)[0]
        for forbidden in ['jpeg:', 'image_url', 'input_image', 'inlineData', 'propose(']:
            self.assertNotIn(forbidden, s)
        self.assertIn('textPlanningConsent == true', s)
        s = Path('ios/Shared/ChatGPTPlanClient.swift').read_text()
        self.assertIn('jpeg: nil', s)
        self.assertIn('if let jpeg {', s)
        self.assertIn('defer { bytes.task.cancel() }', s)
    def test_shortcuts_do_not_start(self):
        s = Path('ios/App/PilotShortcutRouter.swift').read_text()
        for forbidden in ['prepare()', 'allowPlannedTask', 'submitGoal()', 'HardwareClient']:
            self.assertNotIn(forbidden, s)

if __name__ == '__main__': unittest.main(verbosity=2)
