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

    // Capability changes from a valid poll must remain observable before HID connects.
    // Previously only the initial read was cached, so freshness expired during pairing.
    read = 0
    HardwareClient.handler = {
        read += 1
        var value = DeviceStatus(hid_connected: false)
        if read > 1 { value.accessorySetupServiceUUID = "7D9B1E20-4F6A-4C88-A3D2-6E5F0190B7C1" }
        return value
    }
    let refreshing = Task { await model.startPairing() }
    while read < 3 { await Task.yield() }
    precondition(model.lastDeviceStatus?.accessorySetupServiceUUID != nil)
    precondition(model.pairingState.phase == .waiting && model.lastDeviceStatus?.hid_connected == false)
    await model.cancelPairing(); await refreshing.value

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
    precondition(model.lastDeviceStatus?.control_epoch != "new-session")

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

    // Explicit system recovery releases app ownership before opening its own bounded
    // window. A delayed old link must not be mistaken for a new system connection.
    read = 0
    HardwareClient.handler = {
        read += 1
        return DeviceStatus(hid_connected: read == 1 || read >= 4)
    }
    let releaseBefore = SightLatchAccessorySetupAdapter.releaseCalls
    let systemPairsBefore = HardwareClient.pairCalls
    await model.startPairing(usingSystemMouse: true)
    precondition(model.pairingUsesSystemMouse && model.pairingState.phase == .connected)
    precondition(SightLatchAccessorySetupAdapter.releaseCalls == releaseBefore + 1)
    precondition(HardwareClient.pairCalls == systemPairsBefore + 1 && read >= 4)
    precondition(model.pairingState.message.contains("指针") && !model.pairingState.message.contains("鼠标已就绪"))

    // Returning from Settings is a status-only check, even after the window expired.
    model.pairingState = .init(phase: .expired, message: "expired")
    HardwareClient.handler = { DeviceStatus(hid_connected: true) }
    let returnsBefore = HardwareClient.pairCalls
    await model.checkSystemMousePairing()
    precondition(model.pairingState.phase == .connected && HardwareClient.pairCalls == returnsBefore)
    HardwareClient.handler = { DeviceStatus(hid_connected: false) }
    await model.checkSystemMousePairing()
    precondition(model.pairingState.phase == .expired && HardwareClient.pairCalls == returnsBefore)

    // Cancel during the asynchronous disconnect cannot open another pairing window.
    HardwareClient.handler = { DeviceStatus(hid_connected: true) }
    let releasing = Task { await model.startPairing(usingSystemMouse: true) }
    while !model.controllingDevice { await Task.yield() }
    await model.cancelPairing(); await releasing.value
    precondition(model.pairingState.phase == .cancelled && HardwareClient.pairCalls == returnsBefore)
    HardwareClient.handler = { DeviceStatus(hid_connected: false) }
    await model.startPairing()
    precondition(!model.pairingUsesSystemMouse)

    // A link still held by the OS after app release is not silently called a new
    // system pairing and never receives another window request.
    HardwareClient.handler = { DeviceStatus(hid_connected: true) }
    let stillHeldBefore = HardwareClient.pairCalls
    await model.startPairing(usingSystemMouse: true)
    precondition(model.pairingState.phase == .error && HardwareClient.pairCalls == stillHeldBefore)
    print("PASS: production pairing lifecycle: waiting is not connected, encrypted status, expiry, duplicate tap, opening cancellation, local lock, new-session refusal, network loss, legacy safe expiry")
    print("PASS: system mouse route releases app transport, waits for old disconnect, opens one window, and only reads status on return; cancel prevents reopening")
}
