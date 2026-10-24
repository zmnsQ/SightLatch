import Foundation

enum AddressPolicy { static func device(_ value: String) throws -> URL { URL(string: value)! } }
struct DeviceProbeFailure: LocalizedError {
    var errorDescription: String? { "device unavailable" }
    static func classify(_ error: Error) -> Self { .init() }
}
extension PilotConfiguration { func validate() throws {} }

// The production entry coordinator is compiled unchanged. This stand-in owns only
// prepare's existing permit boundary; no AI, network, UIKit, voice or HID is invoked.
@MainActor final class PilotViewModel {
    var configuration = PilotConfiguration()
    var taskFlow = TaskPlanningState()
    var task = ""
    var probing = false
    var checkingTaskPrerequisites = false
    var prepared = false
    var storageWarning: String?
    var notice = ""
    var planningTask: Task<String, Error>?
    var captureObservation: CaptureObservation?
    var status = PilotStatus.idle
    var prepareCalls = 0
    var consumedPermits = 0
    var voiceRequests = 0
    var holdVoicePermission = false
    var cancelDuringPreparation = false
    var isSessionActive: Bool { prepared || SharedStore.shared.command?.running == true }
    func validateAutomaticCalibrationContext() throws {}
    func prepare() async {
        prepareCalls += 1
        let issues = taskPreparationIssues()
        guard issues.isEmpty else { taskFlow.require(issues); notice = issues[0].detail; return }
        guard taskFlow.consumePermission(goal: task, configurationID: planningConfigurationID()) else { return }
        consumedPermits += 1
        if cancelDuringPreparation { taskFlow.cancel(); return }
        let command = SessionCommand(task: taskFlow.goal, running: true)
        do { try SharedStore.shared.startCommand(command, expectedStopGeneration: SharedStore.shared.stopGeneration) }
        catch { taskFlow.fail(error.localizedDescription); return }
        prepared = true
    }
    func enableSessionVoice() async {
        voiceRequests += 1
        while holdVoicePermission { await Task.yield() }
    }
    func stop() async {
        taskFlow.cancel()
        if let command = SharedStore.shared.command {
            _ = try? SharedStore.shared.updateCommand(sessionID: command.id) { $0.running = false }
        }
        prepared = false
    }
}

@main struct DirectGoalStartTests {
    @MainActor static func main() async throws {
        let model = PilotViewModel()
        model.task = "打开微信给文件传输助手发送消息：你好"
        model.configuration.model = "mock"; model.configuration.relativeModeConfirmed = true
        model.holdVoicePermission = true
        let send = Task { await model.submitGoal() }
        let deadline = Date().addingTimeInterval(2)
        while model.voiceRequests == 0 && Date() < deadline { await Task.yield() }
        precondition(model.prepared && model.configuration.uploadConsent)
        precondition(model.taskFlow.plan == nil && model.taskFlow.sessionID == SharedStore.shared.command?.id)
        precondition(model.consumedPermits == 1 && model.voiceRequests == 1,
                     "Broadcast readiness must not wait for voice permission")
        await model.submitGoal()
        precondition(model.prepareCalls == 1, "Double Send must not renew or create another session")
        model.holdVoicePermission = false; await send.value
        await model.stop()

        let repaired = PilotViewModel()
        repaired.task = model.task; repaired.configuration.model = "mock"
        await repaired.submitGoal()
        let requestID = repaired.taskFlow.requestID!
        precondition(repaired.taskFlow.phase == .prerequisites && repaired.taskFlow.plan == nil)
        precondition(repaired.consumedPermits == 0 && repaired.voiceRequests == 0)
        repaired.configuration.relativeModeConfirmed = true
        repaired.configuration.model = "repaired model"
        precondition(repaired.taskFlow.phase == .prerequisites,
                     "Repair alone must not resume or grant execution")
        await repaired.resumePlannedTask(requestID: requestID)
        precondition(repaired.taskFlow.requestID == requestID && repaired.taskFlow.goal == model.task)
        precondition(repaired.prepared && repaired.consumedPermits == 1 && repaired.taskFlow.sessionID != nil)
        await repaired.stop()
        await repaired.resumePlannedTask(requestID: requestID)
        precondition(repaired.consumedPermits == 1, "Cancelled Continue cannot revive execution")

        let cancelled = PilotViewModel()
        cancelled.task = model.task; cancelled.configuration.model = "mock"
        cancelled.configuration.relativeModeConfirmed = true; cancelled.cancelDuringPreparation = true
        await cancelled.submitGoal()
        precondition(cancelled.taskFlow.phase == .cancelled && cancelled.taskFlow.sessionID == nil)
        precondition(cancelled.voiceRequests == 0)
        print("PASS: Send prepares without a remote plan, one permit/session, no duplicate start, explicit repaired-goal continuation, cancelled start cannot bind, broadcast ready before voice permission; no network/UI/HID")
    }
}
