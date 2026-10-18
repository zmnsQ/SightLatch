import Foundation

/// Ephemeral, one-goal permission. Never persisted or restored as an execution grant.
struct TaskPlanningState {
    enum Phase: String { case idle, planning, awaitingPermission = "awaiting_permission", ready, running, completed, cancelled, error }
    private(set) var phase: Phase = .idle
    private(set) var goal = ""
    private(set) var plan: String?
    private(set) var requestID: UUID?
    private(set) var errorMessage: String?
    private(set) var expiresAt: Date?
    private(set) var sessionID: String?
    private var configurationID = Data()
    private var permissionConsumed = false
    var isBusy: Bool { [.planning, .awaitingPermission, .ready, .running].contains(phase) }

    @discardableResult
    mutating func begin(goal: String, configurationID: Data) -> UUID? {
        guard !isBusy else { return nil }
        self = TaskPlanningState()
        self.goal = goal; self.configurationID = configurationID
        let id = UUID(); requestID = id; phase = .planning
        return id
    }
    mutating func receive(_ text: String, requestID: UUID, now: Date = Date()) {
        guard self.requestID == requestID, phase == .planning else { return }
        plan = text; phase = .awaitingPermission; expiresAt = now.addingTimeInterval(120)
    }
    mutating func fail(_ message: String, requestID: UUID? = nil) {
        if let requestID, self.requestID != requestID { return }
        guard phase != .cancelled else { return }
        phase = .error; errorMessage = message; expiresAt = nil; permissionConsumed = true
    }
    mutating func authorize(requestID: UUID, goal: String, configurationID: Data, now: Date = Date()) -> Bool {
        guard self.requestID == requestID, phase == .awaitingPermission else { return false }
        guard self.goal == goal, self.configurationID == configurationID, let expiresAt, now < expiresAt else {
            fail("目标、设置已变化或计划已过期，请重新发送目标。"); return false
        }
        phase = .ready
        return true
    }
    mutating func consumePermission(goal: String, now: Date = Date()) -> Bool {
        guard phase == .ready, self.goal == goal, !permissionConsumed, let expiresAt, now < expiresAt else { return false }
        permissionConsumed = true
        return true
    }
    mutating func bindSession(_ id: String) { guard phase == .ready, permissionConsumed else { return }; sessionID = id }
    mutating func observe(sessionID: String, phase: String, running: Bool) {
        guard self.sessionID == sessionID, [.ready, .running].contains(self.phase) else { return }
        if phase == "完成" { self.phase = .completed }
        else if !running || phase == "停止" { self.phase = .cancelled }
        else if phase != "待广播" { self.phase = .running }
    }
    mutating func cancel() { phase = .cancelled; requestID = nil; expiresAt = nil; permissionConsumed = true }
}
