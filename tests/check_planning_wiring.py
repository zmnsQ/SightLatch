from pathlib import Path
import unittest

class PlanningWiring(unittest.TestCase):
    def test_send_prepares_without_remote_text_plan(self):
        s = Path('ios/App/PilotTaskPlanning.swift').read_text().split('func submitGoal(',1)[1].split('func allowPlannedTask',1)[0]
        for forbidden in ['HardwareClient', 'planGoal(', 'AIClient(', 'startCommand', 'SessionCommand', 'jpeg:']:
            self.assertNotIn(forbidden, s)
        self.assertIn('taskFlow.explicitGoalStart', s)
        self.assertIn('await prepareExplicitGoal(requestID: id, unlimitedConfirmed: unlimitedConfirmed)', s)
    def test_only_goal_bound_permission_can_prepare(self):
        s = Path('ios/App/PilotViewModel.swift').read_text().split('func prepare(',1)[1].split('func stop()',1)[0]
        self.assertLess(s.index('taskFlow.consumePermission'), s.index('HardwareClient'))
        self.assertIn('SessionCommand(task: preparedGoal', s)
        self.assertNotIn('.armSoftwareControl(', s)
        self.assertIn('device.preparedHardwareAuthorization(configuration: configuration)', s)
        self.assertIn('command.execution = SessionExecution(stopGeneration: expectedStopGeneration', s)
        self.assertIn('== preparedGoal', s)
        v = Path('ios/App/PilotTaskPlanning.swift').read_text()
        self.assertIn('taskFlow.explicitGoalStart', v)
        self.assertIn('taskFlow.continueExplicitGoalStart', v)
        self.assertIn('await prepare(unlimitedConfirmed: unlimitedConfirmed)', v)
    def test_text_path_never_fakes_image(self):
        s = Path('ios/Shared/AIClient+Planning.swift').read_text().split('enum PlanningResponse',1)[0]
        for forbidden in ['jpeg:', 'image_url', 'input_image', 'inlineData', 'propose(']:
            self.assertNotIn(forbidden, s)
        self.assertNotIn('textPlanningConsent == true', s)
        s = Path('ios/Shared/ChatGPTPlanClient.swift').read_text()
        self.assertIn('jpeg: nil', s)
        self.assertIn('if let jpeg {', s)
        self.assertIn('defer { bytes.task.cancel() }', s)
    def test_message_navigation_is_a_prerequisite_before_permission_and_hardware(self):
        s = Path('ios/App/PilotViewModel.swift').read_text().split('func prepare(',1)[1].split('func stop()',1)[0]
        gate = s.split('guard missing.isEmpty',1)[0]
        self.assertRegex(gate, r'if MessageIntent\.parse\([^\n]+\) != nil,\s+!configuration\.allowLowRiskNavigation')
        self.assertIn('TaskPrerequisite(kind: .settings', gate)
        self.assertIn('权限与安全', gate)
        self.assertIn('继续此任务', gate)
        self.assertIn('当前目标和已有校准会保留', gate)
        self.assertIn('missing.firstIndex(where: { $0.kind == .settings })', gate)
        self.assertLess(s.index('guard missing.isEmpty'), s.index('taskFlow.consumePermission'))
        self.assertLess(s.index('guard missing.isEmpty'), s.index('HardwareClient'))
        self.assertNotIn('configuration.allowLowRiskNavigation =', s)
    def test_shortcuts_do_not_start(self):
        s = Path('ios/App/PilotShortcutRouter.swift').read_text()
        self.assertNotRegex(s, r'\b(?:prepare|allowPlannedTask|submitGoal)\s*\(')
        self.assertNotIn('HardwareClient', s)

if __name__ == '__main__': unittest.main(verbosity=2)
