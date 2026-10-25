import Foundation

extension PilotViewModel {
    func planningConfigurationID() -> Data {
        var value = configuration
        value.deviceURL = (try? AddressPolicy.device(value.deviceURL).absoluteString) ?? value.deviceURL
        return TaskPlanningConfiguration.identity(value)
    }
    /// Sending the goal explicitly starts preparation; AI first runs on a real broadcast frame.
    func submitGoal(unlimitedConfirmed: Bool = false) async {
        guard !taskFlow.isBusy, !isSessionActive, !probing, !checkingTaskPrerequisites else { return }
        let goal = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, goal.count <= 2000 else { notice = "请填写1–2000字的目标。"; return }
        guard let id = taskFlow.explicitGoalStart(goal: goal, configurationID: planningConfigurationID()) else { return }
        await prepareExplicitGoal(requestID: id, unlimitedConfirmed: unlimitedConfirmed)
    }
    /// Compatibility for an already displayed legacy plan; this is still an explicit user action.
    func allowPlannedTask(requestID: UUID, unlimitedConfirmed: Bool = false) async {
        guard !isSessionActive, !probing, !checkingTaskPrerequisites,
              taskFlow.authorize(requestID: requestID, goal: task.trimmingCharacters(in: .whitespacesAndNewlines),
                                 configurationID: planningConfigurationID()) else { return }
        await prepareExplicitGoal(requestID: requestID, unlimitedConfirmed: unlimitedConfirmed)
    }
    /// A Continue button retries the same goal; fixing a setting never starts it automatically.
    func resumePlannedTask(requestID: UUID, unlimitedConfirmed: Bool = false) async {
        guard !isSessionActive, !probing, !checkingTaskPrerequisites,
              taskFlow.requestID == requestID, taskFlow.phase == .prerequisites else { return }
        let goal = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard goal == taskFlow.goal else { taskFlow.fail("目标已变化，请重新发送目标。"); return }
        guard taskFlow.continueExplicitGoalStart(requestID: requestID, goal: goal,
                                                configurationID: planningConfigurationID()) else { return }
        await prepareExplicitGoal(requestID: requestID, unlimitedConfirmed: unlimitedConfirmed)
    }
    private func prepareExplicitGoal(requestID: UUID, unlimitedConfirmed: Bool) async {
        checkingTaskPrerequisites = true
        defer { checkingTaskPrerequisites = false }
        configuration.uploadConsent = true
        notice = "正在准备本次会话；准备好后请点系统屏幕广播按钮。AI收到首帧后开始观察与执行。"
        // prepare owns consumePermission, persistence, STOP fences, hardware checks and ARM.
        await prepare(unlimitedConfirmed: unlimitedConfirmed)
        guard taskFlow.requestID == requestID, taskFlow.phase == .ready else { return }
        if let command = SharedStore.shared.command, command.running, command.task == taskFlow.goal {
            taskFlow.bindSession(command.id)
            // prepared is already published: ReplayKit never waits for voice permission.
            await enableSessionVoice()
        } else {
            taskFlow.require([.init(kind: .retry, title: "本次会话尚未准备好", detail: notice,
                                   actionTitle: "继续此任务")], requestID: requestID)
        }
    }
    func taskPreparationIssues(execution: Bool = true) -> [TaskPrerequisite] {
        var issues: [TaskPrerequisite] = []
        if let storageWarning {
            issues.append(.init(kind: .settings, title: "设置需要恢复", detail: storageWarning, actionTitle: "检查设置"))
        }
        if configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(kind: .model, title: "尚未选择视觉模型", detail: "在 AI 账户选择支持图片输入的模型，目标会保留。", actionTitle: "选择模型"))
        }
        do { try configuration.validate() }
        catch {
            if !issues.contains(where: { $0.kind == .settings }) {
                issues.append(.init(kind: .settings, title: "连接设置需要修正", detail: error.localizedDescription, actionTitle: "检查设置"))
            }
        }
        if configuration.provider == "chatgpt-plan", configuration.chatGPTPlanConsent != true {
            issues.append(.init(kind: .aiConnection, title: "ChatGPT 尚未准备好", detail: "连接 ChatGPT 并确认套餐使用授权后，继续当前目标。", actionTitle: "检查 AI 账户"))
        }
        guard execution else { return issues }
        var calibrationDetail = "先完成屏幕坐标校准；当前目标会保留。"
        do { try validateAutomaticCalibrationContext() }
        catch { calibrationDetail = error.localizedDescription }
        if !configuration.hasVerifiedPointerCalibration {
            issues.append(.init(kind: .calibration, title: "需要完成坐标校准", detail: calibrationDetail, actionTitle: "开始校准"))
        }
        if configuration.provider == "openai", configuration.gatewayVisionConfirmed != true {
            issues.append(.init(kind: .aiConnection, title: "需要确认图片输入能力", detail: "请在 AI 账户确认当前兼容端点和模型支持图片输入。", actionTitle: "检查 AI 账户"))
        }
        return issues
    }
    func devicePreparationIssue(_ error: Error) -> TaskPrerequisite {
        if let issue = error as? TaskPrerequisite { return issue }
        let failure = DeviceProbeFailure.classify(error)
        return .init(kind: .deviceConnection, title: "设备连接需要检查", detail: failure.localizedDescription, actionTitle: "检查设备")
    }
    func cancelPlannedTask() async {
        planningTask?.cancel(); planningTask = nil
        taskFlow.cancel()
        if isSessionActive { await stop() }
        else { notice = "已取消。旧计划和授权已失效；未开始控制。" }
    }
    func syncPlanningState() {
        if let capture = captureObservation, let failure = capture.startupFailureReason,
           let command = SharedStore.shared.command, !command.running,
           command.id == capture.sessionID, command.generation == capture.generation,
           capture.failureStopGeneration == SharedStore.shared.stopGeneration {
            taskFlow.recoverCaptureStartupFailure(sessionID: capture.sessionID, detail: failure)
        }
        taskFlow.observe(sessionID: status.sessionID, phase: status.phase,
                         running: SharedStore.shared.command?.running == true)
    }
}
