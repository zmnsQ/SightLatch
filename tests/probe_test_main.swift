@main struct ProbeTests {
    @MainActor static func main() async throws {
        let bare = try AddressPolicy.device(" 192.168.1.25 ").absoluteString
        precondition(bare == "http://192.168.1.25")
        let port = try AddressPolicy.device("10.0.0.2:8080").absoluteString
        precondition(port == "http://10.0.0.2:8080")
        for bad in ["8.8.8.8", "http://user:secret@192.168.1.2", "https://192.168.1.2", "192.168.1.2/path", "192.168.1.2?token=secret"] {
            do { _ = try AddressPolicy.device(bad); preconditionFailure("Unsafe address accepted") } catch {}
        }
        let model = ProbeHarness()
        model.configuration.deviceURL = "192.168.1.25"
        model.configuration.endpoint = "unfinished invalid AI endpoint"
        model.deviceToken = "mock-only-do-not-log"
        await model.probe()
        precondition(model.probeState.phase == .success && !model.probing)
        precondition(SecretStore.saves == ["device|http://192.168.1.25"])
        precondition(SharedStore.shared.configuration.endpoint == PilotConfiguration().endpoint)
        precondition(HardwareClient.calls == 1 && model.deviceToken.isEmpty)
        for failKeychain in [true, false] {
            model.deviceToken = "mock-only"
            SecretStore.fail = failKeychain; SharedStore.shared.failWrite = !failKeychain
            let before = HardwareClient.calls
            await model.probe()
            precondition(model.probeState.failure == .save && !model.probing && HardwareClient.calls == before)
            precondition(!model.deviceToken.isEmpty)
        }
        SecretStore.fail = false; SharedStore.shared.failWrite = false
        for error: Error in [HTTPStatusFailure(statusCode: 401), HTTPStatusFailure(statusCode: 403), URLError(.timedOut), URLError(.dataNotAllowed), URLError(.appTransportSecurityRequiresSecureConnection)] {
            HardwareClient.handler = { throw error }
            await model.probe()
            precondition(model.probeState.failure == DeviceProbeFailure.classify(error) && !model.probing)
            precondition(!model.deviceToken.isEmpty)
        }
        // The in-flight state is observable, and a second tap cannot send a second request.
        HardwareClient.handler = { try await Task.sleep(nanoseconds: 50_000_000); return DeviceStatus() }
        let before = HardwareClient.calls
        let pending = Task { await model.probe() }
        while model.probeState.phase != .checking { await Task.yield() }
        precondition(model.probing)
        await model.probe()
        await pending.value
        precondition(HardwareClient.calls == before + 1 && model.probeState.phase == .success)
        // An older background read cannot block the manual tap or overwrite its result.
        var requestIndex = 0
        HardwareClient.handler = {
            requestIndex += 1
            if requestIndex == 1 { try await Task.sleep(nanoseconds: 90_000_000); return DeviceStatus(hid_connected: false) }
            return DeviceStatus(hid_connected: true)
        }
        let olderPoll = Task { await model.refreshDeviceStatus() }
        while !model.refreshingDeviceStatus { await Task.yield() }
        await model.probe()
        precondition(model.probeState.phase == .success && model.lastDeviceStatus?.hid_connected == true)
        await olderPoll.value
        precondition(model.lastDeviceStatus?.hid_connected == true && requestIndex == 2)
        // A target edit during the request must not accept the previous target's response.
        HardwareClient.handler = { try await Task.sleep(nanoseconds: 50_000_000); return DeviceStatus() }
        let changing = Task { await model.probe() }
        while model.probeState.phase != .checking { await Task.yield() }
        model.configuration.deviceURL = "http://10.0.0.9"
        await changing.value
        precondition(model.probeState.failure == .cancelled && model.lastDeviceStatus == nil)
        // Closing the sheet cancels and permits immediate retry. Even an uncooperative old
        // request returning later must not clear the retry's spinner or overwrite its state.
        var closeIndex = 0
        HardwareClient.handler = {
            closeIndex += 1
            if closeIndex == 1 {
                try? await Task.sleep(nanoseconds: 80_000_000)
                return DeviceStatus(hid_connected: false)
            }
            try await Task.sleep(nanoseconds: 30_000_000)
            return DeviceStatus(hid_connected: true)
        }
        let closing = Task { await model.probe() }
        while closeIndex == 0 { await Task.yield() }
        model.cancelProbe()
        precondition(!model.probing && model.probeState.failure == .cancelled)
        await model.probe()
        await closing.value
        precondition(model.probeState.phase == .success && model.lastDeviceStatus?.hid_connected == true)
        HardwareClient.handler = { try await Task.sleep(nanoseconds: 50_000_000); return DeviceStatus() }
        // STOP invalidates a delayed completion; it cannot republish a successful device state.
        let stopTest = Task { await model.probe() }
        while !model.probing { await Task.yield() }
        while model.probeState.phase != .checking { await Task.yield() }
        SharedStore.shared.stopGeneration = "new-stop"
        await stopTest.value
        precondition(model.probeState.failure == .cancelled && !model.probing)
        await runPairingCases()
        print("PASS: production probe/save mock tests: bare IP, rejected hosts, independent AI settings, Keychain/App Group failures, 401/403, timeout, permission, ATS, repeated tap, STOP fence")
    }
}
