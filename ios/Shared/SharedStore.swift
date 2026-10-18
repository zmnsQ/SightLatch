import Foundation
import Security
import Darwin

// App Group never contains API/device secrets. Optional continued mode temporarily stores the latest protected frame; default mode does not.
final class SharedStore {
    static let shared = SharedStore()
    private let queue = DispatchQueue(label: "HIDPilot.files")
    private var directory: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PilotAppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
    var available: Bool { directory != nil }
    func read<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        queue.sync {
            guard let url = directory?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
    }
    private func withFileLock<T>(_ operation: () throws -> T) throws -> T {
        guard let lockURL = directory?.appendingPathComponent("state.lock") else { throw PilotError.message("App Group 不可用，请检查三个 target 的签名配置。") }
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PilotError.message("无法打开共享状态锁") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw PilotError.message("无法锁定共享状态") }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
    private func writeUnlocked<T: Encodable>(_ value: T, to name: String) throws {
        guard let url = directory?.appendingPathComponent(name) else { throw PilotError.message("App Group 不可用，请检查三个 target 的签名配置。") }
        let data = try JSONEncoder().encode(value)
        if name == "frame.json" {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            var protectedURL = url
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protectedURL.setResourceValues(values)
        } else {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    func write<T: Encodable>(_ value: T, to name: String) throws {
        try queue.sync { try withFileLock { try writeUnlocked(value, to: name) } }
    }
    // Persisted cancellation fence shared by UI and Live Activity / shortcut STOP.
    var stopGeneration: String? { read("stop-generation.json", as: String.self) }
    func invalidatePendingStarts() throws {
        try write(UUID().uuidString, to: "stop-generation.json")
    }
    func startCommand(_ command: SessionCommand, expectedStopGeneration: String?) throws {
        try queue.sync {
            try withFileLock {
                guard let directory else { throw PilotError.message("App Group 不可用") }
                let fenceURL = directory.appendingPathComponent("stop-generation.json")
                let current: String?
                if FileManager.default.fileExists(atPath: fenceURL.path) {
                    current = try JSONDecoder().decode(String.self, from: Data(contentsOf: fenceURL))
                } else { current = nil }
                guard current == expectedStopGeneration else { throw PilotError.message("已收到停止请求，请重新主动开始。") }
                try writeUnlocked(command, to: "command.json")
            }
        }
    }
    // Serialize read-modify-write across App, ReplayKit and LiveActivityIntent processes.
    // Old-session callbacks cannot replace a newly prepared session or resurrect a stopped command.
    @discardableResult
    func updateCommand(sessionID: String, _ mutation: (inout SessionCommand) throws -> Void) throws -> Bool {
        try queue.sync {
            try withFileLock {
                guard let url = directory?.appendingPathComponent("command.json"),
                      let data = try? Data(contentsOf: url) else { return false }
                var current = try JSONDecoder().decode(SessionCommand.self, from: data)
                guard current.id == sessionID else { return false }
                try mutation(&current)
                try writeUnlocked(current, to: "command.json")
                return true
            }
        }
    }
    func readFailure<T: Decodable>(_ name: String, as type: T.Type) -> String? {
        queue.sync {
            guard let directory else { return "App Group 不可用，请检查签名配置" }
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do { _ = try JSONDecoder().decode(type, from: Data(contentsOf: url)); return nil }
            catch { return "\(name)无法读取或格式损坏；原文件未删除，请先备份应用数据再恢复设置。" }
        }
    }
    // Recovery never overwrites the only copy of a damaged file.
    func preserveSettingsForRecovery() throws {
        try queue.sync {
            try withFileLock {
                guard let directory else { throw PilotError.message("App Group 不可用") }
                let suffix = UUID().uuidString
                for name in ["configuration.json", "workspace.json"] {
                    let source = directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: source.path) {
                        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name + ".recovery-" + suffix))
                    }
                }
            }
        }
    }
    func remove(_ name: String) {
        queue.sync {
            guard let url = directory?.appendingPathComponent(name) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
    var configuration: PilotConfiguration { read("configuration.json", as: PilotConfiguration.self) ?? PilotConfiguration() }
    var command: SessionCommand? { read("command.json", as: SessionCommand.self) }
    var status: PilotStatus { read("status.json", as: PilotStatus.self) ?? .idle }
    var logs: [LogEntry] { read("logs.json", as: [LogEntry].self) ?? [] }
    // Extension is sole writer during broadcasting; the app only reads this file.
    func log(_ message: String, sessionID: String? = nil) {
        var entries = logs
        entries.append(LogEntry(message: message, sessionID: sessionID))
        try? write(Array(entries.suffix(100)), to: "logs.json")
    }
}

enum SecretStore {
    private static func query(_ account: String) throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PilotKeychainGroup") as? String, !group.contains("$(") else {
            throw PilotError.message("Keychain access group 未正确展开，请检查签名。")
        }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "HIDPilot", kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: group]
    }
    static func save(_ value: String, account: String) throws {
        let base = try query(account)
        if value.isEmpty {
            let result = SecItemDelete(base as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw PilotError.message("Keychain 删除失败：\(result)") }; return
        }
        let values: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(base as CFDictionary, values as CFDictionary)
        if update == errSecItemNotFound {
            let result = SecItemAdd(base.merging(values) { _, new in new } as CFDictionary, nil)
            guard result == errSecSuccess else { throw PilotError.message("Keychain 保存失败：\(result)") }; return
        }
        guard update == errSecSuccess else { throw PilotError.message("Keychain 更新失败：\(update)") }
    }
    static func load(_ account: String) throws -> String {
        var value = try query(account)
        value[kSecReturnData as String] = true
        value[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(value as CFDictionary, &item)
        guard result == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw PilotError.message("缺少共享凭据（\(account)），或设备尚未首次解锁。状态：\(result)")
        }
        return text
    }
}
