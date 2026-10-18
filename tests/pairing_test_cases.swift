@MainActor func runPairingCases() async {
    let model = ProbeHarness()
    SharedStore.shared.stopGeneration = nil
    HardwareClient.handler = { DeviceStatus(hid_connected: false) }
    HardwareClient.pairCalls = 0
    await model.startPairing()
    precondition(model.pairingState.phase == .expired && !model.controllingDevice)
    precondition(HardwareClient.pairCalls == 1) // opening a window is not a connected result.

    var read = 0
    HardwareClient.handler = {
        read += 1
        return DeviceStatus(hid_connected: read >= 3)
    }
    await model.startPairing()
    precondition(model.pairingState.phase == .connected && model.lastDeviceStatus?.hid_connected == true)

    HardwareClient.handler = { DeviceStatus(hid_connected: false) }
    HardwareClient.closeCalls = 0
    let waiting = Task { await model.startPairing() }
    while model.pairingState.phase != .waiting { await Task.yield() }
    precondition(model.isSessionActive && model.pairingState.deadline != nil)
    let pairBefore = HardwareClient.pairCalls
    await model.startPairing() // duplicate cannot reopen a window.
    precondition(HardwareClient.pairCalls == pairBefore)
    await model.cancelPairing()
    await waiting.value
    precondition(model.pairingState.phase == .cancelled && HardwareClient.closeCalls == 1 && !model.controllingDevice)

    // Cancellation during the opening request waits for its receipt; no new local session
    // can start before the conditional cancellation has completed.
    HardwareClient.pairHandler = { try await Task.sleep(nanoseconds: 25_000_000); return DevicePairingReceipt() }
    let opening = Task { await model.startPairing() }
    while !model.controllingDevice { await Task.yield() }
    let cancelling = Task { await model.cancelPairing() }
    while !model.pairingCancelRequested { await Task.yield() }
    precondition(model.isSessionActive)
    await cancelling.value; await opening.value
    precondition(model.pairingState.phase == .cancelled && !model.controllingDevice)
    HardwareClient.pairHandler = { DevicePairingReceipt() }

    // A new external epoch / armed state is never followed by a cancellation STOP.
    HardwareClient.closeCalls = 0; read = 0
    HardwareClient.handler = {
        read += 1
        var value = DeviceStatus(hid_connected: false)
        if read > 1 { value.armed = true; value.control_epoch = "new-session" }
        return value
    }
    await model.startPairing()
    precondition(model.pairingState.phase == .error && HardwareClient.closeCalls == 0)

    // Lost LAN during polling is an explicit error and leaves firmware's own expiry intact.
    read = 0
    HardwareClient.handler = {
        read += 1
        if read > 1 { throw URLError(.notConnectedToInternet) }
        return DeviceStatus(hid_connected: false)
    }
    await model.startPairing()
    precondition(model.pairingState.phase == .error && !model.controllingDevice)

    // Old firmware is safe: report unsupported close instead of unconditional STOP.
    HardwareClient.handler = { DeviceStatus(hid_connected: false) }
    HardwareClient.closeHandler = { .unsupported }
    let oldFirmware = Task { await model.startPairing() }
    while model.pairingState.phase != .waiting { await Task.yield() }
    await model.cancelPairing(); await oldFirmware.value
    precondition(model.pairingState.phase == .cancelled && model.pairingState.message.contains("30秒"))
    HardwareClient.closeHandler = { .closed }
    print("PASS: production pairing lifecycle: waiting is not connected, encrypted status, expiry, duplicate tap, opening cancellation, local lock, new-session refusal, network loss, legacy safe expiry")
}
