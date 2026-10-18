@main struct DiagnosticTests {
    static func main() throws {
        var fixture: [String: Any] = ["ok": true, "boot_id": String(repeating: "a", count: 32),
            "uptime_ms": 1234, "armed": false, "hid_connected": true, "session_id": "SECRET_SESSION",
            "next_sequence": 1, "busy": false, "last_error": "STDERR_SECRET",
            "token": "TOKEN_NEVER_EXPORT", "ssid": "SSID_NEVER_EXPORT", "screenshot": "SCREEN_NEVER_EXPORT"]
        let legacy = try JSONDecoder().decode(DeviceStatus.self, from: JSONSerialization.data(withJSONObject: fixture))
        precondition(legacy.reset_reason == nil && legacy.notify_errors == nil && legacy.safety_stack_free_bytes == nil)
        let diagnostics: [String: Int] = ["reset_reason": 12, "auth_events": 5, "auth_rejects": 1,
            "disconnect_events": 3, "last_disconnect_reason": -1, "last_encryption_status": -1,
            "notify_events": 8, "notify_errors": 2, "last_notify_code": 14,
            "free_heap_bytes": 86000, "min_free_heap_bytes": 80000, "safety_stack_free_bytes": 4096]
        fixture.merge(diagnostics) { _, new in new }
        let current = try JSONDecoder().decode(DeviceStatus.self, from: JSONSerialization.data(withJSONObject: fixture))
        precondition(current.last_disconnect_reason == -1 && current.notify_errors == 2)
        let model = DiagnosticHarness()
        model.acceptDeviceStatus(current, from: model.configuration)
        var report = try JSONSerialization.jsonObject(with: model.exportDiagnostics()) as! [String: Any]
        precondition(report["device_snapshot_available"] as? Bool == true)
        precondition(report["device_snapshot_stale"] as? Bool == false)
        let fields = report["device_snapshot"] as! [String: Any]
        precondition(Set(fields.keys) == Set(diagnostics.keys).union(["boot_id", "uptime_ms", "hid_connected", "armed"]))
        for (key, value) in diagnostics { precondition((fields[key] as? NSNumber)?.intValue == value) }
        // Clearing current readiness after a disconnect retains only diagnostic evidence.
        model.lastDeviceStatus = nil; model.deviceStatusCheckedAt = nil
        model.diagnosticCapturedAt = Date().addingTimeInterval(-61)
        report = try JSONSerialization.jsonObject(with: model.exportDiagnostics()) as! [String: Any]
        precondition(report["device_snapshot_stale"] as? Bool == true)
        precondition((report["device_snapshot_age_seconds"] as? Int ?? 0) >= 61)
        let text = String(data: try model.exportDiagnostics(), encoding: .utf8)!
        for secret in ["TOKEN_NEVER_EXPORT", "SSID_NEVER_EXPORT", "SCREEN_NEVER_EXPORT", "STDERR_SECRET", "SECRET_SESSION", "192.168.1.2", "api-private-account", "device-private-account"] { precondition(!text.contains(secret)) }
        model.configuration.deviceURL = "http://192.168.1.3"
        report = try JSONSerialization.jsonObject(with: model.exportDiagnostics()) as! [String: Any]
        precondition(report["device_snapshot_available"] as? Bool == false && report["device_snapshot"] == nil)
        // An arbitrary string masquerading as boot_id is omitted, not exported as diagnostics.
        fixture["boot_id"] = "TOKEN_NEVER_EXPORT"
        let hostile = try JSONDecoder().decode(DeviceStatus.self, from: JSONSerialization.data(withJSONObject: fixture))
        precondition(hostile.redactedDiagnosticFields["boot_id"] == nil)
        print("PASS: production DeviceStatus legacy/new decoding and production redacted export: numeric allowlist, signed reasons, cached stale snapshot, target isolation, no secrets/logs/screens")
    }
}
