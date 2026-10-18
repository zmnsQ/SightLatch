import Foundation
import FoundationNetworking

// Production HardwareClient is compiled unchanged by run_agent_tests.sh. No real URLSession/HID.
enum PilotError: LocalizedError { case message(String) }
struct PilotConfiguration { let deviceURL = "http://test.local"; let deviceAccount = "test" }
enum SecretStore { static func load(_ key: String) throws -> String { "fake-test-token" } }
enum AddressPolicy { static func device(_ url: String) throws -> URL { URL(string: url)! } }
struct ActionProposal {
    enum Kind: String { case click, text }
    var type = Kind.click
    var dx: Int?; var dy: Int?; var wheel: Int?; var key: String?; var text: String?
}
final class Transport {
    static let shared = Transport()
    var calls: [String] = []
    var handler: ((URLRequest) async throws -> Data)!
    func send(_ request: URLRequest) async throws -> Data {
        calls.append(request.url!.path)
        return try await handler(request)
    }
}
@main struct HardwareCancellationTests {
    static let status = Data("""
    {"ok":true,"boot_id":"boot","uptime_ms":100,"armed":true,"hid_connected":true,"session_id":"session","next_sequence":1,"busy":false}
    """.utf8)
    static func main() async throws {
        let transport = Transport.shared
        let hardware = HardwareClient(configuration: PilotConfiguration())
        // STOP arrives during the awaited status result. A stale completion must never dispatch HID.
        var authorized = true
        transport.handler = { _ in await Task.yield(); authorized = false; return status }
        do {
            try await hardware.send(ActionProposal(), expectedSession: "session", stillAuthorized: { authorized })
            preconditionFailure("Revoked proposal dispatched")
        } catch is CancellationError {}
        precondition(transport.calls == ["/v1/status"])
        // Task cancellation while an uncooperative transport finishes also cannot dispatch.
        transport.calls = []
        let task = Task {
            try await hardware.send(ActionProposal(), expectedSession: "session")
        }
        task.cancel()
        do { try await task.value; preconditionFailure("Cancelled task dispatched") }
        catch is CancellationError {}
        precondition(!transport.calls.contains("/v1/action"))
        // Cancellation after accepted action must exit ACK polling, never retry the POST.
        transport.calls = []; authorized = true
        transport.handler = { request in
            if request.url!.path == "/v1/action" {
                let action = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                authorized = false
                return try JSONSerialization.data(withJSONObject: ["ok": true, "id": action["id"]!])
            }
            return status
        }
        do {
            try await hardware.send(ActionProposal(), expectedSession: "session", sessionAuthorized: { authorized })
            preconditionFailure("Polling ignored revoked session")
        } catch is CancellationError {}
        precondition(transport.calls.filter { $0 == "/v1/action" }.count == 1)
        // A completed ACK that arrives after STOP is not a successful tool result.
        transport.calls = []; authorized = true
        var acceptedID = ""
        transport.handler = { request in
            if request.url!.path == "/v1/action" {
                let action = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                acceptedID = action["id"] as! String
                return try JSONSerialization.data(withJSONObject: ["ok": true, "id": acceptedID])
            }
            if !acceptedID.isEmpty {
                authorized = false
                var completed = try JSONSerialization.jsonObject(with: status) as! [String: Any]
                completed["last_action_id"] = acceptedID; completed["last_action_state"] = "completed"
                return try JSONSerialization.data(withJSONObject: completed)
            }
            return status
        }
        do {
            try await hardware.send(ActionProposal(), expectedSession: "session", sessionAuthorized: { authorized })
            preconditionFailure("Late ACK revived stopped action")
        } catch is CancellationError {}
        precondition(transport.calls.filter { $0 == "/v1/action" }.count == 1)
        // Software control requires a fresh epoch; legacy physical status stays decodable.
        transport.calls = []
        let legacy = try JSONDecoder().decode(DeviceStatus.self, from: status)
        do { _ = try await hardware.armSoftwareControl(expected: legacy); preconditionFailure("Missing epoch permitted ARM") }
        catch is PilotError {}
        precondition(transport.calls.isEmpty)
        var softwareJSON = try JSONSerialization.jsonObject(with: status) as! [String: Any]
        let epoch = String(repeating: "a", count: 32)
        softwareJSON["control_mode"] = "software"; softwareJSON["control_epoch"] = epoch
        let softwareData = try JSONSerialization.data(withJSONObject: softwareJSON)
        let software = try JSONDecoder().decode(DeviceStatus.self, from: softwareData)
        transport.handler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            precondition(body == ["boot_id": "boot", "control_epoch": epoch])
            if request.url!.path == "/v1/pair" {
                return try JSONSerialization.data(withJSONObject: ["ok": true, "pairing_open": true, "boot_id": "boot", "control_epoch": String(repeating: "b", count: 32)])
            }
            return softwareData
        }
        try await hardware.beginPairing(expected: software)
        let armed = try await hardware.armSoftwareControl(expected: software)
        precondition(armed.armed && armed.control_epoch == epoch)
        precondition(transport.calls == ["/v1/pair", "/v1/arm"])
        // A STOP-rotated response cannot be accepted, and a server rejection is never retried.
        transport.calls = []
        softwareJSON["control_epoch"] = String(repeating: "c", count: 32)
        let staleReply = try JSONSerialization.data(withJSONObject: softwareJSON)
        transport.handler = { _ in staleReply }
        do { _ = try await hardware.armSoftwareControl(expected: software); preconditionFailure("Changed epoch accepted") }
        catch is PilotError {}
        precondition(transport.calls == ["/v1/arm"])
        transport.calls = []
        transport.handler = { _ in throw PilotError.message("HTTP 409 control_epoch_mismatch") }
        do { try await hardware.beginPairing(expected: software); preconditionFailure("Rejected epoch accepted") }
        catch is PilotError {}
        precondition(transport.calls == ["/v1/pair"])
        print("PASS: exact boot/epoch request bodies, rotated pair epoch, unchanged ARM epoch, missing/stale epoch rejection and no control retry")
        print("PASS: stop during async status, cancellation before dispatch, cancellation after ACK, late completion after STOP; no HID replay")
    }
}
