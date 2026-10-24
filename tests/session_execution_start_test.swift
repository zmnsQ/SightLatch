import Foundation

/// Exercise the production file-locked CAS, not an already-active fixture or a
/// mock authorization implementation. Only the runner replaces platform storage.
@main
struct SessionExecutionStartTests {
    static let store = SharedStore()
    static let deviceA = "http://device-a.local"
    static let deviceB = "http://device-b.local"
    static let owner = "real-capture-owner"
    static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SIGHTLATCH_TEST_STORE"]!)
    }

    static func reset() throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: url)
        }
        try configure(deviceA)
    }

    static func configure(_ deviceURL: String, uploadConsent: Bool = true) throws {
        var configuration = PilotConfiguration()
        configuration.deviceURL = deviceURL
        configuration.uploadConsent = uploadConsent
        try store.write(configuration, to: "configuration.json")
    }

    static func prepared(id: String = UUID().uuidString, age: TimeInterval = 240,
                         deviceURL: String = deviceA, bootID: String = "boot-a",
                         software: Bool = true, physicalSession: String? = nil,
                         physicalEnd: Date? = nil) -> SessionCommand {
        SessionCommand(id: id, task: "查看当前页面", running: true,
            createdAt: Date().addingTimeInterval(-age),
            execution: SessionExecution(stopGeneration: store.stopGeneration,
                hardware: PreparedHardwareAuthorization(deviceURL: deviceURL, softwareControl: software,
                    bootID: bootID, controlEpoch: "epoch-a", hidGeneration: 7,
                    physicalSessionID: physicalSession, physicalExpiresAt: physicalEnd)))
    }

    static func start(_ command: SessionCommand) throws {
        try store.startCommand(command, expectedStopGeneration: command.execution?.stopGeneration ?? store.stopGeneration)
    }

    static func frame(_ command: SessionCommand, age: TimeInterval = 0) -> CaptureObservation {
        CaptureObservation(sessionID: command.id, state: "capturing",
            receivedAt: Date().addingTimeInterval(-age),
            receivedUptime: ProcessInfo.processInfo.systemUptime - age,
            sourceWidth: 1260, sourceHeight: 2736, exifOrientation: 1, generation: command.generation)
    }

    @discardableResult
    static func claim(_ command: SessionCommand, ownerID: String = owner,
                      firstFrame: CaptureObservation? = nil) throws -> SessionCommand {
        try store.claimCaptureExecution(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: command.execution?.stopGeneration, captureOwnerID: ownerID,
            firstFrame: firstFrame ?? frame(command))
    }

    @discardableResult
    static func activate(_ command: SessionCommand, ownerID: String = owner,
                         bootID: String? = nil, epoch: String = "epoch-a", hidGeneration: UInt32 = 7,
                         hardwareSession: String = "confirmed-arm-session", remainingMS: Int? = nil) throws -> SessionCommand {
        try store.activateCaptureExecution(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: command.execution?.stopGeneration, captureOwnerID: ownerID,
            hardwareBootID: bootID ?? command.execution!.hardware.bootID, controlEpoch: epoch,
            hidGeneration: hidGeneration, hardwareSessionID: hardwareSession,
            hardwareLeaseRemainingMS: remainingMS)
    }

    static func rejects<T>(_ reason: String, _ operation: () throws -> T) {
        do { _ = try operation(); preconditionFailure("Accepted forbidden transition: \(reason)") }
        catch {}
    }

    static func assertSameDates(_ lhs: SessionCommand, _ rhs: SessionCommand) {
        precondition(lhs.execution?.captureStartedAt == rhs.execution?.captureStartedAt)
        precondition(lhs.execution?.startupExpiresAt == rhs.execution?.startupExpiresAt)
        precondition(lhs.execution?.startedAt == rhs.execution?.startedAt)
        precondition(lhs.execution?.expiresAt == rhs.execution?.expiresAt)
    }

    static func delayedFirstFrameAndSingleActivation() throws {
        try reset()
        let command = prepared()
        try start(command)
        precondition(command.executionStartedAt == nil)
        precondition(command.authorizationExpiresAt == command.preparationExpiresAt)
        let first = frame(command)
        let claimed = try claim(command, firstFrame: first)
        precondition(claimed.execution?.phase == .startingHardware)
        precondition(claimed.execution?.captureOwnerID == owner)
        precondition(claimed.execution?.captureStartedAt == first.receivedAt)
        precondition(claimed.execution?.startupExpiresAt == first.receivedAt!.addingTimeInterval(10))
        precondition(claimed.executionStartedAt == nil && claimed.execution?.expiresAt == nil,
                     "A real frame starts only the bounded ARM startup, not execution time")
        rejects("same capture cannot claim twice") { try claim(command) }
        rejects("a second capture cannot steal first-frame ownership") { try claim(command, ownerID: "other-owner") }
        assertSameDates(claimed, store.command!)
        let beforeARMConfirmation = Date()
        let active = try activate(command)
        let afterARMConfirmation = Date()
        let execution = active.execution!
        precondition(execution.phase == .active && execution.hardwareSessionID == "confirmed-arm-session")
        precondition(execution.startedAt! >= beforeARMConfirmation && execution.startedAt! <= afterARMConfirmation)
        precondition(execution.expiresAt == execution.startedAt!.addingTimeInterval(300))
        precondition(active.authorizationExpiresAt == execution.expiresAt)
        precondition(execution.expiresAt!.timeIntervalSince(command.createdAt) >= 540,
                     "Four minutes preparing must not consume the five-minute actual execution budget")
        precondition(active.authorizationIsCurrent(requireActive: true))
        rejects("activation cannot renew the execution deadline") { try activate(command) }
        rejects("an active capture cannot be reclaimed") { try claim(command) }
        assertSameDates(active, store.command!)
    }

    static func rejectionBoundaries() throws {
        try reset()
        let stoppedBeforeCapture = prepared()
        try start(stoppedBeforeCapture)
        try store.invalidatePendingStarts()
        rejects("STOP before capture") { try claim(stoppedBeforeCapture) }
        precondition(store.command?.execution?.phase == .awaitingCapture)

        try reset()
        let stoppedBeforeARM = prepared()
        try start(stoppedBeforeARM)
        _ = try claim(stoppedBeforeARM)
        try store.invalidatePendingStarts()
        rejects("STOP before ARM activation") { try activate(stoppedBeforeARM) }
        precondition(store.command?.executionStartedAt == nil)

        try reset()
        let command = prepared()
        try start(command)
        var wrongFrame = frame(command); wrongFrame.sessionID = "old-session"
        rejects("old-session frame") { try claim(command, firstFrame: wrongFrame) }
        wrongFrame = frame(command); wrongFrame.generation = command.generation + 1
        rejects("old-generation frame") { try claim(command, firstFrame: wrongFrame) }
        rejects("stale actual frame") { try claim(command, firstFrame: frame(command, age: 6)) }
        rejects("empty capture owner") { try claim(command, ownerID: "") }
        _ = try claim(command)
        rejects("activation owner mismatch") { try activate(command, ownerID: "other-owner") }
        rejects("activation boot mismatch") { try activate(command, bootID: "boot-b") }
        rejects("activation control epoch mismatch") { try activate(command, epoch: "epoch-b") }
        rejects("activation BLE generation mismatch") { try activate(command, hidGeneration: 8) }
        try configure(deviceB)
        rejects("device URL changed while arming") { try activate(command) }
        try configure(deviceA, uploadConsent: false)
        rejects("upload consent revoked while arming") { try activate(command) }
        precondition(store.command?.executionStartedAt == nil)

        try reset()
        let expired = prepared(age: 301)
        try start(expired)
        rejects("preparation expired") { try claim(expired) }

        try reset()
        let oldJSONCommand = SessionCommand(id: "legacy-running", task: "查看当前页面", running: true)
        let oldJSON = try JSONEncoder().encode(oldJSONCommand)
        let object = try JSONSerialization.jsonObject(with: oldJSON) as! [String: Any]
        precondition(object["execution"] == nil)
        try start(oldJSONCommand)
        precondition(store.command?.running == true && store.command?.execution == nil)
        rejects("running old JSON without a prepared execution cannot claim capture") { try claim(oldJSONCommand) }
    }

    static func expiredStartup() throws {
        try reset()
        let command = prepared()
        try start(command)
        // An actual fresh frame near its allowed age gives a short, real startup
        // remainder. Wait for that deadline instead of forging an active state.
        let claimed = try claim(command, firstFrame: frame(command, age: 4))
        let startupEnd = claimed.execution!.startupExpiresAt!
        Thread.sleep(until: startupEnd.addingTimeInterval(0.05))
        rejects("expired fixed ARM startup cannot activate late") { try activate(command) }
        rejects("failed startup cannot claim a second capture window") { try claim(command) }
        precondition(store.command?.executionStartedAt == nil && store.command?.execution?.expiresAt == nil)
        precondition(store.command?.execution?.startupExpiresAt == startupEnd)
    }

    static func physicalLeaseCannotBeExtended() throws {
        try reset()
        let physicalEnd = Date().addingTimeInterval(40)
        let command = prepared(software: false, physicalSession: "physical-session", physicalEnd: physicalEnd)
        try start(command)
        _ = try claim(command)
        rejects("physical session mismatch") { try activate(command, hardwareSession: "different-session", remainingMS: 30_000) }
        rejects("physical remaining lease missing") { try activate(command, hardwareSession: "physical-session") }
        let beforeConfirmation = Date()
        let active = try activate(command, hardwareSession: "physical-session", remainingMS: 30_000)
        precondition(active.execution!.expiresAt! <= physicalEnd)
        precondition(active.execution!.expiresAt! >= beforeConfirmation.addingTimeInterval(30))
        precondition(active.execution!.expiresAt! == active.execution!.startedAt!.addingTimeInterval(30))
        rejects("physical lease cannot renew") { try activate(command, hardwareSession: "physical-session", remainingMS: 300_000) }
        assertSameDates(active, store.command!)
    }

    static func messageScopeSharesTheSingleExecutionClock() throws {
        try reset()
        var command = prepared()
        command.task = "打开微信给文件传输助手发送消息 校准测试正文"
        let intent = MessageIntent.parse(command.task)!
        command.messageScope = MessageScope(intent: intent, sessionID: command.id, generation: command.generation,
            expiresAt: command.preparationExpiresAt, stopGeneration: command.execution?.stopGeneration,
            clipboardPrepared: true)
        let originalScopeID = command.messageScope!.id
        try start(command)
        let claimed = try claim(command)
        precondition(claimed.execution?.messageScopeID == originalScopeID)
        precondition(claimed.messageScope?.expiresAt == command.preparationExpiresAt,
                     "Claiming the first frame must not extend message execution authority")
        let active = try activate(command)
        precondition(active.messageScope?.id == originalScopeID)
        precondition(active.messageScope?.expiresAt == active.execution?.expiresAt)
        precondition(active.messageScope!.expiresAt! > command.preparationExpiresAt)
        rejects("a message scope cannot extend a second time") { try activate(command) }
        precondition(store.command?.messageScope?.expiresAt == active.execution?.expiresAt)
        let instruction = SessionGoalInstruction(sessionID: active.id, generation: active.generation,
            expectedStopGeneration: command.execution?.stopGeneration, goal: "查看当前页面的返回入口")
        try store.enqueueGoalInstruction(instruction)
        assertSameDates(active, store.command!)
        let replaced = try store.applyPendingGoal(sessionID: active.id, expectedGeneration: active.generation)!
        precondition(replaced.generation == active.generation + 1)
        assertSameDates(active, replaced)
        precondition(replaced.authorizationExpiresAt == active.authorizationExpiresAt,
                     "A pending goal commit must retain the original execution deadline")

        try reset()
        var changedScope = prepared()
        changedScope.task = command.task
        changedScope.messageScope = MessageScope(intent: intent, sessionID: changedScope.id,
            generation: changedScope.generation, expiresAt: changedScope.preparationExpiresAt,
            stopGeneration: changedScope.execution?.stopGeneration, clipboardPrepared: true)
        try start(changedScope); _ = try claim(changedScope)
        try store.updateCommand(sessionID: changedScope.id) { stored in
            stored.messageScope = MessageScope(intent: intent, sessionID: stored.id, generation: stored.generation,
                expiresAt: stored.preparationExpiresAt, stopGeneration: stored.execution?.stopGeneration,
                clipboardPrepared: true)
        }
        precondition(store.command?.messageScope?.id != store.command?.execution?.messageScopeID)
        rejects("a replaced scope cannot consume an earlier capture claim") { try activate(changedScope) }
        precondition(store.command?.executionStartedAt == nil)
        precondition(store.command?.messageScope?.expiresAt == changedScope.preparationExpiresAt)
    }

    struct Record: Decodable {
        var ticket: String; var sessionID: String; var deviceURL: String; var bootID: String
    }

    static func leaveUnconfirmedOperation(bootID: String) throws {
        let command = prepared(bootID: "boot-a")
        try start(command)
        _ = try claim(command)
        var channel: HardwareChannelLease? = try store.acquireCaptureHardwareChannel(sessionID: command.id, captureOwnerID: owner)
        precondition(channel != nil)
        try store.identifyHardwareChannel(channel!, deviceURL: deviceA, bootID: bootID)
        rejects("an in-flight hardware request blocks a new prepare") { try start(prepared(bootID: "boot-next")) }
        try store.finishCaptureHardwareChannel(channel!, confirmed: false)
        channel = nil
        let records = store.read("hardware-stop-uncertain.json", as: [Record].self)!
        precondition(records.count == 1 && records[0].bootID == bootID && records[0].deviceURL == deviceA)
    }

    static func uncertainHardwareRecords() throws {
        try reset()
        try leaveUnconfirmedOperation(bootID: "unknown")
        rejects("unknown old hardware boot cannot be cleared by a new boot claim") { try start(prepared(bootID: "boot-new")) }
        rejects("unknown old hardware boot cannot be bypassed via another URL") {
            try start(prepared(deviceURL: deviceB, bootID: "boot-b"))
        }
        precondition(store.read("hardware-stop-uncertain.json", as: [Record].self)?.count == 1)

        try reset()
        try leaveUnconfirmedOperation(bootID: "boot-a")
        rejects("same device boot remains uncertain") { try start(prepared(bootID: "boot-a")) }
        rejects("same boot at another URL is not a reboot") { try start(prepared(deviceURL: deviceB, bootID: "boot-a")) }
        try configure(deviceB)
        try start(prepared(deviceURL: deviceB, bootID: "boot-b"))
        let retained = store.read("hardware-stop-uncertain.json", as: [Record].self)!
        precondition(retained.count == 1 && retained[0].deviceURL == deviceA && retained[0].bootID == "boot-a",
                     "Starting another target must not discard the first target's unknown cleanup")
        rejects("old target still blocked after using another device") { try start(prepared(bootID: "boot-a")) }
        try configure(deviceA)
        try start(prepared(bootID: "boot-a-rebooted"))
        precondition(store.read("hardware-stop-uncertain.json", as: [Record].self)?.isEmpty == true)

        try reset()
        let current = prepared()
        try start(current); _ = try claim(current)
        let wrongOwner = try store.acquireStopHardwareChannel(deviceURL: deviceA, expectedSessionID: current.id, captureOwnerID: "old-owner")
        precondition(wrongOwner == nil)
        let wrongSession = try store.acquireStopHardwareChannel(deviceURL: deviceA, expectedSessionID: "old-session", captureOwnerID: owner)
        precondition(wrongSession == nil)
        precondition(store.read("hardware-channel.json", as: Record.self) == nil,
                     "Rejected old cleanup must not reserve a hardware request")

        // A process dying before a STOP POST differs from an uncertain posted
        // operation. Exercise the persisted false marker through the real API.
        try reset() // No command: a pre-GET stop record initially has an unknown boot.
        var neverPosted: HardwareChannelLease? = try store.acquireStopHardwareChannel(deviceURL: deviceA,
            expectedSessionID: nil, captureOwnerID: nil)
        precondition(neverPosted != nil)
        neverPosted = nil // Simulate process release before any identified POST.
        try start(prepared(bootID: "boot-a"))
        precondition(store.read("hardware-stop-uncertain.json", as: [Record].self) == nil)

        try reset()
        let preparedBeforeNewUncertainty = prepared()
        try start(preparedBeforeNewUncertainty); _ = try claim(preparedBeforeNewUncertainty)
        try store.recordUnconfirmedHardwareStop(sessionID: "older-cleanup", deviceURL: deviceA, bootID: "boot-a")
        rejects("uncertainty appearing after prepare blocks the later ARM hardware channel") {
            try store.acquireCaptureHardwareChannel(sessionID: preparedBeforeNewUncertainty.id, captureOwnerID: owner)
        }
    }

    static func selectedDurationAndUnlimitedLease() throws {
        try reset()
        var bounded = prepared()
        bounded.execution!.durationSeconds = 120
        try start(bounded); _ = try claim(bounded)
        let active = try activate(bounded)
        precondition(active.execution!.expiresAt == active.execution!.startedAt!.addingTimeInterval(120))
        precondition(!active.authorizationIsCurrent(now: active.execution!.expiresAt!))
        var changedConfiguration = store.configuration; changedConfiguration.runDurationSeconds = 3600
        changedConfiguration.unlimitedRun = true; try store.write(changedConfiguration, to: "configuration.json")
        precondition(store.command?.execution?.durationSeconds == 120, "Settings cannot expand an existing run")
        try reset()
        var unlimited = prepared()
        unlimited.task = "打开微信，给测试发送消息：你好"
        unlimited.execution!.unlimitedConfirmed = true
        unlimited.execution!.renewableHardwareLease = true
        unlimited.messageScope = MessageScope(intent: MessageIntent.parse(unlimited.task)!, sessionID: unlimited.id,
            generation: unlimited.generation, expiresAt: unlimited.preparationExpiresAt, stopGeneration: store.stopGeneration)
        try start(unlimited); _ = try claim(unlimited)
        let infinite = try activate(unlimited, remainingMS: 30000)
        precondition(infinite.authorizationIsCurrent(requireActive: true) && infinite.authorizationExpiresAt == nil)
        precondition(infinite.messageScope!.expiresAt == nil && infinite.messageScope!.isUnlimited == true)
        precondition(infinite.messageScope!.matches(sessionID: infinite.id, generation: infinite.generation, task: infinite.task))
        try store.updateCommand(sessionID: infinite.id) { value in value.messageScope!.clipboardExpiresAt = Date().addingTimeInterval(-1) }
        let context = MessageDispatchContext(sessionID: infinite.id, generation: infinite.generation, frameID: "current-frame", scopeID: infinite.messageScope!.id)
        var expiredScope = store.command!.messageScope!
        precondition(!expiredScope.reserve(purpose: "message_paste", context: context, task: infinite.task))
        rejects("expired clipboard must not reserve a paste") { try store.reserveMessageAction(purpose: "message_paste", context: context) }
        precondition(store.command!.authorizationIsCurrent(requireActive: true), "Clipboard expiry is not a total runtime limit")
        try store.markMessageClipboardPrepared(context: context, expectedStopGeneration: store.stopGeneration, expiresAt: Date().addingTimeInterval(600))
        precondition(store.command!.messageScope!.clipboardIsReady)
        precondition(store.command!.messageScope!.clipboardExpiresAt != nil)
        precondition(!infinite.authorizationIsCurrent(now: Date().addingTimeInterval(31)), "No fresh renewal must expire locally")
        let reserved = try store.reserveHardwareRenewal(sessionID: infinite.id, captureOwnerID: owner, expectedStopGeneration: store.stopGeneration)
        precondition(reserved.execution!.nextRenewalSequence == 1 && store.command!.execution!.nextRenewalSequence == 2)
        let originalStart = infinite.execution!.startedAt
        try store.confirmHardwareRenewal(sessionID: infinite.id, captureOwnerID: owner, expectedStopGeneration: store.stopGeneration,
            sequence: 1, remainingMS: 29000, requestStartedAt: Date())
        precondition(store.command!.execution!.startedAt == originalStart && store.command!.execution!.expiresAt == nil)
        rejects("confirmation replay cannot extend lease") {
            try store.confirmHardwareRenewal(sessionID: infinite.id, captureOwnerID: owner, expectedStopGeneration: store.stopGeneration,
                sequence: 1, remainingMS: 30000, requestStartedAt: Date())
        }
        try store.invalidatePendingStarts()
        rejects("STOP fences renewal") { try store.reserveHardwareRenewal(sessionID: infinite.id, captureOwnerID: owner, expectedStopGeneration: nil) }
        var older = infinite
        older.createdAt = Date().addingTimeInterval(-1000)
        older.execution!.captureStartedAt = older.createdAt.addingTimeInterval(1)
        older.execution!.startupExpiresAt = older.createdAt.addingTimeInterval(11)
        older.execution!.startedAt = older.createdAt.addingTimeInterval(2)
        precondition(older.authorizationIsCurrent(requireActive: true), "Unlimited has no hidden 300-second total limit")
        older.execution!.unlimitedConfirmed = false
        precondition(!older.authorizationIsCurrent(requireActive: true), "nil expiry without explicit confirmation is invalid")
        older.execution!.unlimitedConfirmed = true; older.execution!.hardware.softwareControl = false
        precondition(!older.authorizationIsCurrent(requireActive: true), "Physical ARM is never unlimited")
        try reset(); var long = prepared(); long.execution!.durationSeconds = 3600; long.execution!.renewableHardwareLease = true
        try start(long); _ = try claim(long); let longActive = try activate(long, remainingMS: 30000)
        precondition(longActive.execution!.expiresAt == longActive.execution!.startedAt!.addingTimeInterval(3600))
        let roundTrip = try JSONDecoder().decode(SessionCommand.self, from: JSONEncoder().encode(longActive))
        precondition(roundTrip.execution!.durationSeconds == 3600)
    }

    static func main() throws {
        try selectedDurationAndUnlimitedLease()
        try delayedFirstFrameAndSingleActivation()
        try rejectionBoundaries()
        try physicalLeaseCannotBeExtended()
        try messageScopeSharesTheSingleExecutionClock()
        try uncertainHardwareRecords()
        try expiredStartup()
        print("PASS: production Store first-frame claim and ARM-confirmed five-minute execution, one-shot scope clock and pending goal bounds, STOP/owner/epoch/expiry/legacy rejection, physical leases, uncertain hardware/boot/URL and pre-POST cleanup; no active fixture")
    }
}
