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
@main struct SessionHardwareStartTests {
    static let epoch = String(repeating: "e", count: 32)
    static func data(armed: Bool = false, software: Bool = true, remaining: Int? = 300000,
                     boot: String = "boot", generation: Int = 1, renewable: Bool = false, renewalSequence: Int = 1) throws -> Data {
        var json: [String: Any] = ["ok": true, "boot_id": boot, "uptime_ms": 1, "armed": armed,
            "hid_connected": true, "busy": false, "session_id": armed ? "hardware-session" : "",
            "next_sequence": 1, "control_epoch": epoch, "hid_generation": generation,
            "control_lease_mode": "task", "control_mode": software ? "software" : "physical"]
        json["session_renewal_supported"] = renewable
        json["renewable_session"] = renewable && armed
        json["next_renewal_sequence"] = renewalSequence
        if let remaining { json["lease_remaining_ms"] = remaining }
        return try JSONSerialization.data(withJSONObject: json)
    }
    static func status(_ data: Data) throws -> DeviceStatus { try JSONDecoder().decode(DeviceStatus.self, from: data) }
    static func mustFail(_ operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("Unexpected authorization") } catch {}
    }
    static func main() async throws {
        var config = PilotConfiguration(); config.deviceURL = "http://10.0.0.2"; config.relativeModeConfirmed = true
        let hardware = HardwareClient(configuration: config), transport = Transport.shared
        let prepared = try status(data()).preparedHardwareAuthorization(configuration: config)
        precondition(transport.calls.isEmpty, "Preparing is read-only and does not ARM")
        transport.handler = { request in
            if request.url!.path == "/v1/arm" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                precondition(body == ["boot_id": "boot", "control_epoch": epoch])
                return try data(armed: true)
            }
            return try data()
        }
        _ = try await hardware.beginPreparedExecution(prepared, deadline: Date().addingTimeInterval(10), stillAuthorized: { true })
        precondition(transport.calls.map { $0.url!.path } == ["/v1/status", "/v1/arm"])
        // A lost ARM reply consumes this one attempt; never POST a second ARM.
        transport.calls = []
        transport.handler = { request in
            if request.url!.path == "/v1/arm" { throw URLError(.timedOut) }
            return try data()
        }
        await mustFail { _ = try await hardware.beginPreparedExecution(prepared, deadline: Date().addingTimeInterval(10), stillAuthorized: { true }) }
        precondition(transport.calls.filter { $0.url!.path == "/v1/arm" }.count == 1)
        // A fresh status may only preserve the original boot/epoch/generation and disarmed state.
        for reply in [try data(armed: true), try data(boot: "other"), try data(generation: 2)] {
            transport.calls = []; transport.handler = { _ in reply }
            await mustFail { _ = try await hardware.beginPreparedExecution(prepared, deadline: Date().addingTimeInterval(10), stillAuthorized: { true }) }
            precondition(!transport.calls.contains { $0.url!.path == "/v1/arm" })
        }
        transport.calls = []; transport.handler = { _ in try data() }
        await mustFail { _ = try await hardware.beginPreparedExecution(prepared, deadline: Date().addingTimeInterval(-1), stillAuthorized: { true }) }
        precondition(!transport.calls.contains { $0.url!.path == "/v1/arm" })
        var authorized = true; transport.calls = []
        transport.handler = { _ in authorized = false; return try data() }
        await mustFail { _ = try await hardware.beginPreparedExecution(prepared, deadline: Date().addingTimeInterval(10), stillAuthorized: { authorized }) }
        precondition(!transport.calls.contains { $0.url!.path == "/v1/arm" })
        // Physical mode cannot invent missing/invalid lease time or renew a valid one.
        for remaining in [nil, 0, -1, 300001] as [Int?] {
            do { _ = try status(data(armed: true, software: false, remaining: remaining)).preparedHardwareAuthorization(configuration: config); preconditionFailure("Guessed physical lease") } catch {}
        }
        let physical = try status(data(armed: true, software: false, remaining: 20000)).preparedHardwareAuthorization(configuration: config)
        transport.calls = []; transport.handler = { _ in try data(armed: true, software: false, remaining: 10000) }
        let physicalReply = try await hardware.beginPreparedExecution(physical, deadline: Date().addingTimeInterval(10), stillAuthorized: { true })
        precondition(physicalReply.lease_remaining_ms == 10000 && transport.calls.count == 1)
        // New mode uses a short lease and an explicit same-session sequence, never another ARM.
        transport.calls = []
        transport.handler = { request in
            if request.url!.path == "/v1/arm" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                precondition(body["mode"] == "renewable_task")
                return try data(armed: true, remaining: 30000, renewable: true)
            }
            return try data(renewable: true)
        }
        _ = try await hardware.beginPreparedExecution(prepared, deadline: Date().addingTimeInterval(10), renewable: true, stillAuthorized: { true })
        var execution = SessionExecution(hardware: prepared)
        execution.hardwareSessionID = "hardware-session"; execution.renewableHardwareLease = true
        transport.calls = []
        transport.handler = { request in
            if request.url!.path == "/v1/renew" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                precondition(body.count == 8 && body["renewal_sequence"] as? Int == 1 && body["lease_ms"] as? Int == 30000)
                precondition(body["session_id"] as? String == "hardware-session" && body["hid_generation"] as? Int == 1)
                return try data(armed: true, remaining: 29000, renewable: true, renewalSequence: 2)
            }
            return try data(armed: true, remaining: 14000, renewable: true)
        }
        _ = try await hardware.renewExecution(execution, sequence: 1, leaseMilliseconds: 30000, stillAuthorized: { true })
        precondition(transport.calls.map { $0.url!.path } == ["/v1/status", "/v1/renew"])
        transport.calls = []; transport.handler = { request in
            if request.url!.path == "/v1/renew" { throw URLError(.timedOut) }
            return try data(armed: true, remaining: 14000, renewable: true)
        }
        await mustFail { _ = try await hardware.renewExecution(execution, sequence: 1, leaseMilliseconds: 30000, stillAuthorized: { true }) }
        precondition(transport.calls.filter { $0.url!.path == "/v1/renew" }.count == 1)
        for reply in [try data(armed: false, renewable: true), try data(armed: true, boot: "changed", renewable: true),
                      try data(armed: true, generation: 2, renewable: true), try data(armed: true, renewable: true, renewalSequence: 2)] {
            transport.calls = []; transport.handler = { _ in reply }
            await mustFail { _ = try await hardware.renewExecution(execution, sequence: 1, leaseMilliseconds: 30000, stillAuthorized: { true }) }
            precondition(!transport.calls.contains { $0.url!.path == "/v1/renew" || $0.url!.path == "/v1/arm" })
        }
        // STOP failure persists uncertainty; a later successful STOP cannot prove the old POST was drained.
        let store = SharedStore.shared; config.uploadConsent = true; try store.write(config, to: "configuration.json")
        transport.calls = []; transport.handler = { request in
            if request.url!.path == "/v1/stop" { throw URLError(.timedOut) }
            return try data()
        }
        await mustFail { try await hardware.stopAndVerify() }
        transport.handler = { request in request.url!.path == "/v1/stop" ? Data("{\"ok\":true}".utf8) : try data() }
        try await hardware.stopAndVerify()
        var command = SessionCommand(task: "observe", running: true)
        command.execution = .init(stopGeneration: store.stopGeneration, hardware: prepared)
        do { try store.startCommand(command, expectedStopGeneration: store.stopGeneration); preconditionFailure("Unknown STOP cleared by refresh") } catch {}
        command.execution!.hardware.bootID = "rebooted"
        try store.startCommand(command, expectedStopGeneration: store.stopGeneration)
        let before = transport.calls.count
        do { try await hardware.stopAndVerify(expectedSessionID: "old-session", captureOwnerID: "old-owner"); preconditionFailure("Stale STOP reported verified") }
        catch HardwareClient.StopFailure.staleOwner {}
        precondition(transport.calls.count == before, "Late owner cleanup submitted STOP to the replacement")
        transport.handler = { request in
            if request.url!.path == "/v1/stop" { throw URLError(.timedOut) }
            return try data()
        }
        await hardware.stopRuntimeAndReport(sessionID: command.id, captureOwnerID: nil)
        precondition(store.status.phase == "请核实硬件停止" && store.command?.running == false)
        print("PASS: production renewable short lease/sequence/unknown no replay and STOP failure presentation; one-shot ARM, startup deadline/STOP/boot/generation, physical remaining TTL, durable unknown STOP and stale-owner suppression; no real network/HID")
    }
}
