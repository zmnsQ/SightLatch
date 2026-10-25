import Foundation

struct TaskPrerequisite: Identifiable, Equatable, LocalizedError {
    enum Kind: String { case model, aiConnection, calibration, deviceConnection, bluetoothPairing, deviceControl, settings, retry }
    var kind: Kind
    var title: String
    var detail: String
    var actionTitle: String
    var id: String { kind.rawValue }
    var errorDescription: String? { detail }
}

/// Calibration measures readiness; it does not change the text plan's goal or destination.
/// Execution-affecting settings remain part of the identity checked before authorization.
enum TaskPlanningConfiguration {
    static func identity(_ configuration: PilotConfiguration) -> Data {
        var value = configuration
        value.automaticCalibrationProfile = nil
        value.calibratedAt = nil
        value.relativeModeConfirmed = false
        value.calibrationX = 100; value.calibrationY = 100
        value.orientation = "portrait"
        value.uploadConsent = false // Set by the existing explicit execution button.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }
}

/// Ephemeral, one-goal permission. Never persisted or restored as an execution grant.
struct TaskPlanningState {
    enum Phase: String { case idle, planning, prerequisites, awaitingPermission = "awaiting_permission", ready, running, completed, cancelled, error }
    private(set) var phase: Phase = .idle
    private(set) var goal = ""
    private(set) var plan: String?
    private(set) var requestID: UUID?
    private(set) var errorMessage: String?
    private(set) var expiresAt: Date?
    private(set) var sessionID: String?
    private(set) var prerequisites: [TaskPrerequisite] = []
    private(set) var isExplicitGoalStart = false
    var messageIntent: MessageIntent? { MessageIntent.parse(goal) }
    private var configurationID = Data()
    private var permissionConsumed = false
    // Waiting for setup or permission does not reserve hardware or block independent calibration.
    var isBusy: Bool { [.planning, .ready, .running].contains(phase) }

    /// Send authorizes preparing this exact goal; screen capture still needs ReplayKit confirmation.
    @discardableResult
    mutating func explicitGoalStart(goal: String, configurationID: Data, now: Date = Date()) -> UUID? {
        guard !isBusy, !goal.isEmpty, goal.count <= 2000 else { return nil }
        self = TaskPlanningState()
        self.goal = goal
        let id = UUID(); requestID = id
        grantExplicitStart(configurationID: configurationID, now: now)
        return id
    }
    /// A visible Continue tap grants a new attempt with the repaired current configuration.
    /// No observation, calibration completion, foreground event or timer calls this method.
    mutating func continueExplicitGoalStart(requestID: UUID, goal: String, configurationID: Data, now: Date = Date()) -> Bool {
        guard self.requestID == requestID, phase == .prerequisites, self.goal == goal else { return false }
        grantExplicitStart(configurationID: configurationID, now: now)
        return true
    }
    private mutating func grantExplicitStart(configurationID: Data, now: Date) {
        self.configurationID = configurationID
        isExplicitGoalStart = true; plan = nil
        phase = .ready; prerequisites = []; errorMessage = nil; sessionID = nil
        expiresAt = now.addingTimeInterval(120); permissionConsumed = false
    }

    @discardableResult
    mutating func begin(goal: String, configurationID: Data) -> UUID? {
        guard !isBusy, phase != .awaitingPermission else { return nil }
        self = TaskPlanningState()
        self.goal = goal; self.configurationID = configurationID
        let id = UUID(); requestID = id; phase = .planning
        return id
    }
    mutating func receive(_ text: String, requestID: UUID, now: Date = Date()) {
        guard self.requestID == requestID, phase == .planning else { return }
        plan = text; phase = .awaitingPermission; expiresAt = nil
        prerequisites = []; errorMessage = nil
    }
    mutating func fail(_ message: String, requestID: UUID? = nil) {
        if let requestID, self.requestID != requestID { return }
        guard phase != .cancelled else { return }
        phase = .error; errorMessage = message; expiresAt = nil; permissionConsumed = true; prerequisites = []
    }
    mutating func require(_ issues: [TaskPrerequisite], requestID: UUID? = nil) {
        if let requestID, self.requestID != requestID { return }
        guard phase != .cancelled, phase != .running, !issues.isEmpty else { return }
        phase = .prerequisites; prerequisites = issues; errorMessage = nil
        expiresAt = nil; permissionConsumed = true; sessionID = nil
    }
    mutating func checkContext(goal: String, configurationID: Data) -> Bool {
        guard self.goal == goal, self.configurationID == configurationID else {
            fail("目标、AI 服务或执行设置已变化，请重新发送目标开始本次任务。"); return false
        }
        return true
    }
    mutating func preparationSatisfied(requestID: UUID, goal: String, configurationID: Data) -> Bool {
        guard self.requestID == requestID, [.awaitingPermission, .prerequisites].contains(phase), plan != nil else { return false }
        guard checkContext(goal: goal, configurationID: configurationID) else { return false }
        phase = .awaitingPermission; prerequisites = []; errorMessage = nil
        expiresAt = nil; permissionConsumed = false
        return true
    }
    mutating func authorize(requestID: UUID, goal: String, configurationID: Data, now: Date = Date()) -> Bool {
        guard self.requestID == requestID, phase == .awaitingPermission else { return false }
        guard checkContext(goal: goal, configurationID: configurationID) else { return false }
        phase = .ready; expiresAt = now.addingTimeInterval(120); permissionConsumed = false
        return true
    }
    mutating func consumePermission(goal: String, configurationID: Data? = nil, now: Date = Date()) -> Bool {
        // Context-free callers cannot consume an execution grant.
        guard phase == .ready, !permissionConsumed, let configurationID else { return false }
        guard checkContext(goal: goal, configurationID: configurationID) else { return false }
        guard let expiresAt, now < expiresAt else {
            require([TaskPrerequisite(kind: .retry, title: "执行授权已过期", detail: "当前目标仍保留；请点击继续此任务，重新准备本次会话。", actionTitle: "继续此任务")]); return false
        }
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
    mutating func recoverCaptureStartupFailure(sessionID: String, detail: String) {
        // observe() may already have seen running=false, but explicit cancel()
        // clears requestID and must never be revived by a late extension error.
        guard self.sessionID == sessionID, requestID != nil, (isExplicitGoalStart || plan != nil),
              [.ready, .running, .cancelled].contains(phase) else { return }
        phase = .ready
        require([.init(kind: .retry, title: "屏幕捕获尚未开始", detail: detail,
                       actionTitle: "继续此任务")])
    }
    mutating func recoverLaunchFailure(sessionID: String, detail: String) {
        guard self.sessionID == sessionID, [.ready, .running].contains(phase), messageIntent != nil else { return }
        phase = .ready // No HID has passed the launch barrier; preserve the plan without granting execution.
        require([.init(kind: .retry, title: "微信尚未打开", detail: detail, actionTitle: "继续此任务")])
    }
    mutating func cancel() { phase = .cancelled; requestID = nil; expiresAt = nil; permissionConsumed = true; prerequisites = [] }
}
