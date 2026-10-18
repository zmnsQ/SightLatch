import Foundation

extension PilotViewModel {
    private func planningConfigurationID() -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(configuration)) ?? Data()
    }
    func submitGoal() async {
        guard !taskFlow.isBusy, !isSessionActive, !probing else { return }
        let goal = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, goal.count <= 2000 else { notice = "请填写1–2000字的目标。"; return }
        guard let id = taskFlow.begin(goal: goal, configurationID: planningConfigurationID()) else { return }
        let snapshot = configuration
        notice = "正在请模型基于目标规划，尚未读取屏幕。"
        let request = Task { try await AIClient(configuration: snapshot).planGoal(goal) }
        planningTask = request
        let deadline = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled { request.cancel() }
        }
        defer { deadline.cancel() }
        do {
            let plan = try await request.value
            guard !request.isCancelled else { throw CancellationError() }
            guard !Task.isCancelled, taskFlow.requestID == id else { return }
            taskFlow.receive(plan, requestID: id)
            notice = "计划已返回。请阅读后决定是否允许本次屏幕上传与控制。"
        } catch {
            guard taskFlow.requestID == id else { return }
            let message = error is CancellationError ? "规划已取消或超时；请重新发送目标。" : error.localizedDescription
            taskFlow.fail(message, requestID: id); notice = message
        }
        if taskFlow.requestID == id { planningTask = nil }
    }
    /// Only the explicit goal-bound permission button may call this method.
    func allowPlannedTask(requestID: UUID) async {
        guard !isSessionActive, !probing,
              taskFlow.authorize(requestID: requestID,
                  goal: task.trimmingCharacters(in: .whitespacesAndNewlines), configurationID: planningConfigurationID()) else {
            notice = taskFlow.errorMessage ?? "请先取得当前目标的新计划，再明确允许。"; return
        }
        configuration.uploadConsent = true
        await prepare()
        guard taskFlow.requestID == requestID, taskFlow.phase == .ready else { return }
        if let command = SharedStore.shared.command, command.running, command.task == taskFlow.goal {
            taskFlow.bindSession(command.id)
        } else { taskFlow.fail(notice, requestID: requestID) }
    }
    func cancelPlannedTask() async {
        planningTask?.cancel(); planningTask = nil
        taskFlow.cancel()
        if isSessionActive { await stop() }
        else { notice = "已取消。旧计划和授权已失效；未开始控制。" }
    }
    func syncPlanningState() {
        taskFlow.observe(sessionID: status.sessionID, phase: status.phase,
                         running: SharedStore.shared.command?.running == true)
    }
}
