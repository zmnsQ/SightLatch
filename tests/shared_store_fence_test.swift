import Foundation
import Glibc

enum PilotError: LocalizedError { case message(String) }
struct PilotConfiguration: Codable {}
struct SessionCommand: Codable { var id: String; var running: Bool }
struct PilotStatus: Codable { static let idle = PilotStatus() }
struct LogEntry: Codable { var message: String; var sessionID: String? = nil }

@main struct SharedStoreFenceTests {
    static func main() throws {
        let store = SharedStore()
        if CommandLine.arguments.contains("stop-child") { try store.invalidatePendingStarts(); return }
        let initial = store.stopGeneration
        try store.startCommand(SessionCommand(id: "first", running: true), expectedStopGeneration: initial)
        try store.invalidatePendingStarts()
        try store.updateCommand(sessionID: "first") { $0.running = false }
        do {
            try store.startCommand(SessionCommand(id: "stale-prepare", running: true), expectedStopGeneration: initial)
            preconditionFailure("STOP was bypassed by pending prepare")
        } catch {}
        precondition(store.command?.id == "first" && store.command?.running == false)
        let next = store.stopGeneration
        try store.startCommand(SessionCommand(id: "second", running: true), expectedStopGeneration: next)
        let old = try store.updateCommand(sessionID: "first") { $0.running = false }
        precondition(!old && store.command?.id == "second" && store.command?.running == true)
        // Cross-process stop must invalidate a previously captured prepare token.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [CommandLine.arguments[0], "stop-child"]
        try process.run(); process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        do {
            try store.startCommand(SessionCommand(id: "late-parent", running: true), expectedStopGeneration: next)
            preconditionFailure("Cross-process STOP fence was ignored")
        } catch {}
        // A corrupt persisted fence cannot be treated as first-run nil.
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SIGHTLATCH_TEST_STORE"]!).appendingPathComponent("stop-generation.json")
        try Data("damaged".utf8).write(to: url)
        do {
            try store.startCommand(SessionCommand(id: "corrupt", running: true), expectedStopGeneration: nil)
            preconditionFailure("Corrupt fence must fail closed")
        } catch {}
        print("PASS: persisted STOP fence, stale prepare, old-session callback, cross-process fence, damaged-state fail closed")
    }
}
