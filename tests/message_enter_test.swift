import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
enum SecretStore { static func load(_ account: String) throws -> String { "test-only" } }
final class Transport {
    static let shared = Transport()
    var calls: [URLRequest] = []
    var handler: ((URLRequest) async throws -> Data)!
    func send(_ request: URLRequest) async throws -> Data { calls.append(request); return try await handler(request) }
}
actor ChatGPTPlanClient {
    static let shared = ChatGPTPlanClient()
    func response(model: String, instructions: String, task: String, jpeg: Data) async throws -> String { throw CancellationError() }
}
@main struct MessageEnterTests {
    static let goal = "打开微信给文件传输助手发送消息：你好"
    static let epoch = String(repeating: "e", count: 32)
    static func command() -> SessionCommand {
        var value = SessionCommand(task: goal, running: true, createdAt: Date().addingTimeInterval(-5))
        value.messageScope = .init(intent: MessageIntent.parse(goal)!, sessionID: value.id,
            generation: value.generation, expiresAt: Date().addingTimeInterval(300), stopGeneration: SharedStore.shared.stopGeneration)
        value.messageScope!.pasteAttempted = true
        value.messageScope!.launch.phase = .opened
        value.messageScope!.launch.visuallyEstablishedAt = Date().addingTimeInterval(-2)
        value.messageScope!.launch.visuallyEstablishedUptime = ProcessInfo.processInfo.systemUptime - 2
        value.messageScope!.launch.visuallyEstablishedFrameID = "launch"
        return value
    }
    static func action() -> ActionProposal {
        .init(type: .key, key: "SEND_MESSAGE_ENTER", purpose: "message_send", risk: "authorized_message",
            requiresConfirmation: false, reason: "按本次准确范围发送一次", pointerVisible: false, highRisk: false, confidence: 0.99,
            messageEvidence: .init(frameID: "frame", app: "微信", recipient: "文件传输助手", recipientUnambiguous: true,
                composerFocused: true, composerText: "你好", sendButtonUnderPointer: false, outgoingText: "",
                newOutgoingMessage: false, deliveryState: "unknown", sendButtonVisible: false, softwareKeyboardVisible: false))
    }
    static func rejected(_ action: ActionProposal, _ command: SessionCommand?, config: PilotConfiguration,
                         capturedAt: Date = Date(), frame: String = "frame", absoluteContext: AbsolutePointerContext? = nil) -> Bool {
        SafetyGate.rejection(action, task: goal, config: config, command: command, frameID: frame,
            capturedAt: capturedAt, capturedUptime: ProcessInfo.processInfo.systemUptime, absoluteContext: absoluteContext) != nil
    }
    static func status(id: String? = nil, generation: Int = 7, absolute: Bool = false) throws -> Data {
        var json: [String: Any] = ["ok":true,"boot_id":"boot","uptime_ms":100,"armed":true,
            "hid_connected":true,"busy":false,"session_id":"hardware-session","next_sequence":1,
            "control_epoch":epoch,"hid_generation":generation,"absolute_pointer_supported":absolute]
        if let id { json["last_action_id"] = id; json["last_action_state"] = "completed" }
        return try JSONSerialization.data(withJSONObject: json)
    }
    static func mustFail(_ operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("Rejected action succeeded") } catch {}
    }
    static func main() async throws {
        let store = SharedStore.shared, transport = Transport.shared
        var config = PilotConfiguration(); config.deviceURL = "http://10.0.0.2"; config.allowLowRiskNavigation = true
        let hardware = HardwareClient(configuration: config)
        var value = command(); let enter = action()
        precondition(!rejected(enter, value, config: config), "Cursor-free focused scoped keyboard send must pass")
        precondition(rejected(enter, nil, config: config))
        for index in 0..<19 {
            var invalid = enter
            switch index {
            case 0: invalid.key = "ENTER"
            case 1: invalid.purpose = "navigation"; invalid.risk = "low"
            case 2: invalid.messageEvidence!.recipient = "别人"
            case 3: invalid.messageEvidence!.app = "其它App"
            case 4: invalid.messageEvidence!.composerText = "你好\n"
            case 5: invalid.messageEvidence!.composerFocused = false
            case 6: invalid.messageEvidence!.sendButtonVisible = true
            case 7: invalid.messageEvidence!.sendButtonVisible = nil
            case 8: invalid.messageEvidence!.softwareKeyboardVisible = true
            case 9: invalid.messageEvidence!.softwareKeyboardVisible = nil
            case 10: invalid.messageEvidence!.frameID = "old"
            case 11: invalid.messageEvidence!.recipientUnambiguous = false
            case 12: invalid.dx = 1
            case 13: invalid.dy = 1
            case 14: invalid.wheel = 1
            case 15: invalid.button = "left"
            case 16: invalid.text = "extra"
            case 17: invalid.confidence = 0.84
            default: invalid.requiresConfirmation = true
            }
            precondition(rejected(invalid, value, config: config), "Invalid Enter variant \(index)")
        }
        precondition(rejected(enter, value, config: config, capturedAt: Date().addingTimeInterval(-21)))
        var noPaste = value; noPaste.messageScope!.pasteAttempted = false
        precondition(rejected(enter, noPaste, config: config))
        var stopped = value; stopped.running = false; precondition(rejected(enter, stopped, config: config))
        var click = enter; click.type = .click; click.key = nil; click.button = "left"; click.pointerVisible = true
        click.messageEvidence!.sendButtonUnderPointer = true; click.messageEvidence!.sendButtonVisible = true
        precondition(!rejected(click, value, config: config), "Visible send button keeps the existing preferred click path")
        // Actual encoder + cross-process Store reservation: a lost reply consumes BOTH send methods.
        try store.startCommand(value, expectedStopGeneration: store.stopGeneration)
        var reservationCount = 0
        let reserve: () throws -> Void = {
            try store.reserveMessageAction(purpose: "message_send", context: .init(sessionID: value.id,
                generation: value.generation, frameID: "frame", scopeID: value.messageScope!.id))
            reservationCount += 1
        }
        transport.handler = { request in
            if request.url!.path == "/v1/action" {
                let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                precondition(reservationCount == 1 && store.command!.messageScope!.sendAttempted)
                precondition(payload["type"] as? String == "key" && payload["key"] as? Int == 40 && payload["modifiers"] as? Int == 0)
                precondition((payload["ttl_ms"] as! Int) >= 100 && (payload["ttl_ms"] as! Int) <= 1200)
                precondition(payload["text"] == nil && payload["button"] == nil && payload["dx"] == nil)
                throw URLError(.timedOut)
            }
            return try status()
        }
        await mustFail { try await hardware.send(enter, expectedSession: "hardware-session", frameDeadline: Date().addingTimeInterval(1.2), reserveMessageAction: reserve) }
        precondition(transport.calls.filter { $0.url!.path == "/v1/action" }.count == 1)
        for retry in [enter, click] {
            precondition(rejected(retry, store.command, config: config))
            await mustFail { try await hardware.send(retry, expectedSession: "hardware-session", frameDeadline: Date().addingTimeInterval(1), reserveMessageAction: reserve) }
        }
        precondition(reservationCount == 1 && transport.calls.filter { $0.url!.path == "/v1/action" }.count == 1)
        // No inferred success if Return inserted a newline rather than sending.
        var verify = enter; verify.type = .done; verify.key = nil; verify.purpose = "message_verify"
        verify.messageEvidence!.frameID = "new-frame"; verify.messageEvidence!.composerText = "你好\n"
        precondition(rejected(verify, store.command, config: config, frame: "new-frame"))
        precondition(store.command!.messageScope!.verified == false)
        // Expiry during the fresh device GET is typed pre-dispatch: no reservation or POST.
        transport.calls = []; transport.handler = { _ in try await Task.sleep(nanoseconds: 20_000_000); return try status() }
        var reserved = false
        do { try await hardware.send(enter, expectedSession: "hardware-session", frameDeadline: Date().addingTimeInterval(0.01), reserveMessageAction: { reserved = true }); preconditionFailure("Expired frame submitted") }
        catch HardwareClient.PreDispatchFailure.frameExpired {}
        precondition(!reserved && transport.calls.count == 1)
        // Fixed minimum TTL is checked before reservation, even with an otherwise fresh frame.
        transport.calls = []; transport.handler = { _ in try status() }
        do { try await hardware.send(enter, expectedSession: "hardware-session", frameDeadline: Date().addingTimeInterval(0.05), reserveMessageAction: { reserved = true }); preconditionFailure("Insufficient TTL submitted") }
        catch HardwareClient.PreDispatchFailure.frameExpired {}
        precondition(!reserved && transport.calls.count == 1)
        // A genuine completed hardware receipt still needs a later, separate UI verification.
        value = command(); try store.startCommand(value, expectedStopGeneration: store.stopGeneration)
        transport.calls = []; var completedID: String?
        transport.handler = { request in
            if request.url!.path == "/v1/action" {
                completedID = (try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])["id"] as? String
                return try JSONSerialization.data(withJSONObject: ["ok":true,"id":completedID!])
            }
            return try status(id: completedID)
        }
        try await hardware.send(enter, expectedSession: "hardware-session", frameDeadline: Date().addingTimeInterval(1), reserveMessageAction: reserve)
        precondition(store.command!.messageScope!.sendAttempted && !store.command!.messageScope!.verified)
        verify.messageEvidence!.composerText = ""; verify.messageEvidence!.outgoingText = "你好"
        verify.messageEvidence!.newOutgoingMessage = true; verify.messageEvidence!.deliveryState = "sent"
        precondition(!rejected(verify, store.command, config: config, frame: "new-frame"))
        try store.verifyMessage(context: .init(sessionID: value.id, generation: value.generation,
            frameID: "new-frame", scopeID: value.messageScope!.id), capturedAt: Date())
        precondition(store.command!.messageScope!.verified)
        // Measured absolute context's boot/generation must match the final fresh GET even for a keyboard action.
        var mappedConfig = config
        let calibration = PointerCalibrationContext(deviceURL: config.deviceURL, phoneModel: "fixture",
            orientation: "portrait", pixelWidth: 1000, pixelHeight: 2000, scale: 2)
        let mapping = AbsolutePointerMapping(hardwareBootID: "boot", hidGeneration: 7,
            screenFromHID: .init(a: 0.1, b: 0, c: 0, d: 0, e: 0.2, f: 0), maxResidualPixels: 1,
            verifiedAt: Date(), validationPointCount: 2, validatedHIDBounds: .init(minX: 500, maxX: 9500, minY: 500, maxY: 9500))
        mappedConfig.automaticCalibrationProfile = .init(context: calibration, pixelsPer100X: 400, pixelsPer100Y: 800,
            verifiedAt: Date(), hardwareBootID: "boot", absoluteMapping: mapping)
        let measured = try JSONDecoder().decode(DeviceStatus.self, from: status(absolute: true))
        let context = try measured.absolutePointerContext(configuration: mappedConfig,
            geometry: .init(sourceWidth: 1000, sourceHeight: 2000, orientedWidth: 1000, orientedHeight: 2000, jpegWidth: 500, jpegHeight: 1000), frameID: "frame")!
        precondition(!rejected(enter, command(), config: mappedConfig, absoluteContext: context), "Absolute mode keyboard send needs neither cursor nor a pointer target")
        transport.calls = []; transport.handler = { _ in try status(generation: 8, absolute: true) }
        await mustFail { try await HardwareClient(configuration: mappedConfig).send(enter, expectedSession: "hardware-session",
            frameDeadline: Date().addingTimeInterval(1), absoluteContext: context, reserveMessageAction: { reserved = true }) }
        precondition(!reserved && transport.calls.count == 1)
        // Hardware completion still cannot establish message delivery; connection changes reject its ACK.
        value = command(); try store.startCommand(value, expectedStopGeneration: store.stopGeneration)
        transport.calls = []; var acceptedID: String?
        transport.handler = { request in
            if request.url!.path == "/v1/action" {
                acceptedID = (try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])["id"] as? String
                return try JSONSerialization.data(withJSONObject: ["ok":true,"id":acceptedID!])
            }
            return try status(id: acceptedID, generation: acceptedID == nil ? 7 : 8)
        }
        await mustFail { try await hardware.send(enter, expectedSession: "hardware-session", frameDeadline: Date().addingTimeInterval(1), reserveMessageAction: reserve) }
        precondition(store.command!.messageScope!.sendAttempted && !store.command!.messageScope!.verified)
        precondition(transport.calls.filter { $0.url!.path == "/v1/action" }.count == 1)
        print("PASS: production scoped Enter gates/hidden-button evidence, fixed HID Return/no modifiers, shared click-or-key once-only reservation, timeout/no-repeat, newline-not-delivery, TTL/freshness and changed-generation ACK rejection; no real network/HID")
    }
}
