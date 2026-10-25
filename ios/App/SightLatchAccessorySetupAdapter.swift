import Foundation
import Combine
import UIKit
#if canImport(AccessorySetupKit) && compiler(>=6.1)
import AccessorySetupKit
import CoreBluetooth
#endif

// MARK: - Pairing diagnostics
// Debug builds emit only fixed labels, counts and enum/error codes. Never log
// identifiers, names, URLs, descriptions, userInfo, credentials or payloads.
private func pairingDebug(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[SightLatch pairing] \(message())")
    #endif
}

private func pairingErrorSummary(_ error: Error?) -> String {
    guard let error else { return "none" }
    let nsError = error as NSError
    let safeDomains = ["ASErrorDomain", "CBErrorDomain", "CBATTErrorDomain", "NSCocoaErrorDomain",
                       "NSOSStatusErrorDomain", "NSPOSIXErrorDomain", "NSURLErrorDomain"]
    let domain = safeDomains.contains(nsError.domain) ? nsError.domain : "other"
    return "\(domain):\(nsError.code)"
}

// MARK: - Pairing adapter
/// Experimental until validated with a signed iPhone build and the matching firmware.
/// Accessory authorization is NOT evidence that the board's BLE link is encrypted.
@MainActor
final class SightLatchAccessorySetupAdapter: ObservableObject {
    static let serviceUUID = "7D9B1E20-4F6A-4C88-A3D2-6E5F0190B7C1"
    static let manualInstructions = "打开 iPhone 的设置 → 蓝牙，选择 SightLatch 并确认配对，然后返回这里验证连接。窗口过期后请重新开始。"

    enum State: Equatable {
        case idle, activating, presenting, choosingAuthorizedAccessory, selectedAwaitingVerification, cancelled
        case unavailable(String)
        case failed(String)
        var diagnosticName: String {
            switch self {
            case .idle: "idle"
            case .activating: "activating"
            case .presenting: "presenting"
            case .choosingAuthorizedAccessory: "choosingAuthorizedAccessory"
            case .selectedAwaitingVerification: "selectedAwaitingVerification"
            case .cancelled: "cancelled"
            case .unavailable: "unavailable"
            case .failed: "failed"
            }
        }
    }
    @Published private(set) var state: State = .idle {
        didSet { pairingDebug("adapter state=\(state.diagnosticName)") }
    }
    struct AuthorizedAccessoryChoice: Identifiable {
        let id: UUID
        let name: String
    }
    @Published private(set) var authorizedChoices: [AuthorizedAccessoryChoice] = []
    private var generation = UUID()
    private var timeout: Task<Void, Never>?
    #if canImport(AccessorySetupKit) && compiler(>=6.1)
    private var session: ASAccessorySession?
    private var selectedIdentifier: UUID?
    private var connection: SightLatchSelectedAccessoryConnection?
    private var connectionDeadline: Date?
    #endif

    /// Call only after /v1/pair succeeds and the board reports a live pairing window.
    /// Pass the latest /v1/status capability and the actual remaining window, not a new 30s.
    /// An absolute deadline prevents rounded seconds or session activation from extending it.
    func present(serviceUUID: String?, pairingWindowIsOpen: Bool, remainingSeconds: Int = 30, deadline: Date? = nil) {
        pairingDebug("present window_open=\(pairingWindowIsOpen) remaining_s=\(remainingSeconds)")
        switch state {
        case .activating, .presenting, .choosingAuthorizedAccessory, .selectedAwaitingVerification: return
        default: break
        }
        stopSession()
        guard pairingWindowIsOpen, remainingSeconds > 0 else {
            state = .unavailable("配对窗口尚未打开或已过期，请重新开始配对。")
            return
        }
        let expiresAt = min(deadline ?? .distantFuture,
                            Date().addingTimeInterval(TimeInterval(min(remainingSeconds, 30))))
        guard Date() < expiresAt else {
            state = .unavailable("配对窗口尚未打开或已过期，请重新开始配对。")
            return
        }
        guard serviceUUID?.uppercased() == Self.serviceUUID else {
            state = .unavailable("当前固件不支持 App 内系统配对，请使用系统蓝牙设置。")
            return
        }
        #if canImport(AccessorySetupKit) && compiler(>=6.1)
        guard #available(iOS 18.4, *) else {
            state = .unavailable("App 内 HID 配对需要 iOS 18.4 或更新版本，请使用系统蓝牙设置。")
            return
        }
        #if targetEnvironment(simulator)
        state = .unavailable("系统蓝牙配对需要真实 iPhone，模拟器不支持。")
        return
        #else
        guard Self.hasDiscoveryDeclarations else {
            state = .unavailable("此 App 构建缺少配件发现配置，请使用系统蓝牙设置。")
            return
        }
        let attempt = generation
        let session = ASAccessorySession()
        self.session = session
        selectedIdentifier = nil
        connectionDeadline = expiresAt
        state = .activating
        timeout = Task { [weak self] in
            let remaining = max(0, expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == attempt else { return }
            self.expireSession(attempt: attempt)
        }
        session.activate(on: .main) { [weak self, weak session] event in
            Task { @MainActor [weak self] in
                guard let self, let session, self.generation == attempt, self.session === session else { return }
                pairingDebug("ASK event=\(event.eventType.rawValue) error=\(pairingErrorSummary(event.error))")
                if event.error != nil {
                    self.stopSession()
                    self.state = .failed("系统配对未完成。可重试或使用系统蓝牙设置。")
                    return
                }
                switch event.eventType {
                case .activated:
                    let known = session.accessories.filter(Self.matchesSightLatch)
                    pairingDebug("ASK authorized_total=\(session.accessories.count) matching=\(known.count)")
                    if known.count == 1, let identifier = known[0].bluetoothIdentifier {
                        self.connectSelectedAccessory(identifier: identifier, attempt: attempt, deadline: expiresAt)
                    } else if known.count > 1 {
                        self.authorizedChoices = known.compactMap { accessory in
                            accessory.bluetoothIdentifier.map { AuthorizedAccessoryChoice(id: $0, name: accessory.displayName) }
                        }
                        self.state = .choosingAuthorizedAccessory
                    } else {
                        self.showPicker(session: session, attempt: attempt, deadline: expiresAt)
                    }
                case .pickerDidPresent:
                    self.state = .presenting
                case .accessoryAdded:
                    pairingDebug("ASK accessory_added matching=\(event.accessory.map(Self.matchesSightLatch) ?? false)")
                    if let accessory = event.accessory, Self.matchesSightLatch(accessory) {
                        self.selectedIdentifier = accessory.bluetoothIdentifier
                    }
                case .pickerDidDismiss:
                    if let identifier = self.selectedIdentifier {
                        self.connectSelectedAccessory(identifier: identifier, attempt: attempt, deadline: expiresAt)
                    } else {
                        self.stopSession()
                        self.state = .cancelled
                    }
                case .invalidated:
                    self.stopSession()
                    self.state = .failed("系统配对会话已结束。可重试或使用系统蓝牙设置。")
                default: break
                }
            }
        }
        #endif
        #else
        state = .unavailable("此 App 构建未启用系统 HID 配对，请使用系统蓝牙设置。")
        #endif
    }

    /// Cancels discovery and an unverified connection, without removing any bond.
    /// The owner must also cancel its /v1/pair flow and status polling as appropriate.
    func cancel() {
        stopSession()
        state = .cancelled
    }

    /// Explicit system-mouse recovery releases only transports owned by this app.
    /// It does not remove a bond, scan, connect, or change system Bluetooth settings.
    static func releaseConnectionsForSystemPairing() {
        #if canImport(AccessorySetupKit) && compiler(>=6.1)
        SightLatchSelectedAccessoryConnection.releaseRetainedConnections()
        #endif
    }

    /// Called only after the matching firmware status confirms an encrypted link.
    /// Keep our transport owner alive after the sheet closes; no assumed OS handoff.
    func completeVerification() {
        pairingDebug("firmware verification received")
        #if canImport(AccessorySetupKit) && compiler(>=6.1)
        if connection?.retainAfterVerification() == true { connection = nil }
        #endif
        stopSession()
    }

    func selectAuthorizedAccessory(id: UUID) {
        #if canImport(AccessorySetupKit) && compiler(>=6.1)
        guard state == .choosingAuthorizedAccessory,
              authorizedChoices.contains(where: { $0.id == id }),
              let deadline = connectionDeadline else { return }
        connectSelectedAccessory(identifier: id, attempt: generation, deadline: deadline)
        #endif
    }

    private func expireSession(attempt: UUID) {
        guard generation == attempt else { return }
        pairingDebug("adapter deadline expired")
        stopSession()
        state = .failed("配对窗口已结束。请重新开始，或使用系统蓝牙设置。")
    }

    private func stopSession() {
        pairingDebug("adapter stop_session")
        generation = UUID() // Fence delayed callbacks from cancellation/retry/timeout.
        timeout?.cancel()
        timeout = nil
        #if canImport(AccessorySetupKit) && compiler(>=6.1)
        let previous = session
        session = nil
        previous?.invalidate()
        connection?.cancel()
        connection = nil
        connectionDeadline = nil
        selectedIdentifier = nil
        authorizedChoices = []
        #endif
    }

    #if canImport(AccessorySetupKit) && compiler(>=6.1)
    @available(iOS 18.0, *)
    private static func matchesSightLatch(_ accessory: ASAccessory) -> Bool {
        accessory.state == .authorized && accessory.bluetoothIdentifier != nil
            && accessory.descriptor.bluetoothServiceUUID == CBUUID(string: serviceUUID)
            && accessory.descriptor.bluetoothNameSubstring == "SightLatch"
    }

    private func connectSelectedAccessory(identifier: UUID, attempt: UUID, deadline: Date) {
        guard generation == attempt else { return }
        guard Date() < deadline else { expireSession(attempt: attempt); return }
        guard connection == nil else { return }
        pairingDebug("selected transport begin remaining_ms=\(max(0, Int(deadline.timeIntervalSinceNow * 1000)))")
        authorizedChoices = []
        state = .selectedAwaitingVerification
        connection = SightLatchSelectedAccessoryConnection(identifier: identifier, deadline: deadline) { [weak self] event in
            guard let self, self.generation == attempt else { return }
            switch event {
            case .connected:
                // CoreBluetooth transport alone is not proof of encryption or HID readiness.
                self.state = .selectedAwaitingVerification
            case .failed(let message):
                self.stopSession()
                self.state = .failed(message)
            }
        }
    }

    private static var hasDiscoveryDeclarations: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        // Optional discovery keys must be omitted when unused. AccessorySetupKit
        // traps during activation if a declared company-identifier array is empty.
        if let value = info["NSAccessorySetupBluetoothCompanyIdentifiers"] {
            guard let identifiers = value as? [String], !identifiers.isEmpty,
                  identifiers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                return false
            }
        }
        let technologies = info["NSAccessorySetupKitSupports"] as? [String] ?? []
        let services = info["NSAccessorySetupBluetoothServices"] as? [String] ?? []
        let names = info["NSAccessorySetupBluetoothNames"] as? [String] ?? []
        return technologies.contains("Bluetooth")
            && services.contains(where: { $0.uppercased() == serviceUUID })
            && names.contains("SightLatch")
    }

    @available(iOS 18.4, *)
    private func showPicker(session: ASAccessorySession, attempt: UUID, deadline: Date) {
        guard generation == attempt else { return }
        guard Date() < deadline else { expireSession(attempt: attempt); return }
        let descriptor = ASDiscoveryDescriptor()
        // Apple explicitly requires a custom discovery service for HID, not 1812.
        descriptor.bluetoothServiceUUID = CBUUID(string: Self.serviceUUID)
        descriptor.bluetoothNameSubstring = "SightLatch"
        descriptor.supportedOptions = [.bluetoothHID, .bluetoothPairingLE]
        // A locally rendered product image avoids a missing asset / force unwrap.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { _ in
            UIImage(systemName: "computermouse.fill")?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 32, y: 16, width: 64, height: 96))
        }
        let item = ASPickerDisplayItem(name: "SightLatch", productImage: image, descriptor: descriptor)
        guard Date() < deadline else { expireSession(attempt: attempt); return }
        session.showPicker(for: [item]) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt, error != nil else { return }
                pairingDebug("ASK picker completion error=\(pairingErrorSummary(error))")
                self.stopSession()
                self.state = .failed("系统未能完成配对。请确认蓝牙已打开并重试，或使用系统蓝牙设置。")
            }
        }
    }
    #endif
}

#if canImport(AccessorySetupKit) && compiler(>=6.1)
// MARK: - Selected accessory transport
/// One connection attempt to one ASK-authorized identifier. Never scans, accesses
/// GATT characteristics, sends HID reports, or retries after a disconnection.
@MainActor
private final class SightLatchSelectedAccessoryConnection: NSObject, @preconcurrency CBCentralManagerDelegate {
    enum Event { case connected, failed(String) }
    private static var retained: [UUID: SightLatchSelectedAccessoryConnection] = [:]
    static func releaseRetainedConnections() {
        // cancel() removes itself from retained; iterate a snapshot.
        for connection in Array(retained.values) { connection.cancel() }
    }
    private let identifier: UUID
    private let deadline: Date
    private let now: () -> Date
    private var onEvent: ((Event) -> Void)?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var active = true
    private var requestedConnection = false
    private var verified = false
    private var powerStateGrace: Task<Void, Never>?

    init(identifier: UUID, deadline: Date, now: @escaping () -> Date = Date.init,
         onEvent: @escaping (Event) -> Void) {
        self.identifier = identifier
        self.deadline = deadline
        self.now = now
        self.onEvent = onEvent
        super.init()
        pairingDebug("CB central created authorization=\(CBCentralManager.authorization.rawValue)")
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func cancel() {
        pairingDebug("CB cancel active=\(active) verified=\(verified) peripheral_state=\(peripheral?.state.rawValue ?? -1)")
        active = false
        powerStateGrace?.cancel()
        powerStateGrace = nil
        onEvent = nil
        if let peripheral, peripheral.state == .connecting || peripheral.state == .connected {
            central.cancelPeripheralConnection(peripheral)
        }
        if Self.retained[identifier] === self { Self.retained[identifier] = nil }
        central.delegate = nil
        peripheral = nil
    }

    func retainAfterVerification() -> Bool {
        guard active, peripheral?.state == .connected else { return false }
        pairingDebug("CB transport retained after firmware verification")
        verified = true
        onEvent = nil
        if let previous = Self.retained[identifier], previous !== self { previous.cancel() }
        Self.retained[identifier] = self
        return true
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard active, central === self.central else { return }
        pairingDebug("CB state=\(central.state.rawValue) authorization=\(CBCentralManager.authorization.rawValue) requested=\(requestedConnection)")
        if central.state != .poweredOff {
            powerStateGrace?.cancel()
            powerStateGrace = nil
        }
        switch central.state {
        case .poweredOn:
            guard !requestedConnection else { return }
            guard now() < deadline else { fail("配对窗口已结束，请重新开始。"); return }
            let matches = central.retrievePeripherals(withIdentifiers: [identifier])
            pairingDebug("CB retrieve count=\(matches.count)")
            guard matches.count == 1, let target = matches.first, target.identifier == identifier else {
                fail("系统尚未提供所选设备的连接信息，请重新开始配对。")
                return
            }
            requestedConnection = true
            peripheral = target
            pairingDebug("CB connect requested peripheral_state=\(target.state.rawValue)")
            central.connect(target, options: nil)
        case .unknown, .resetting:
            break // The outer attempt keeps the original deadline while Bluetooth starts.
        case .poweredOff:
            // ASK authorization and Bluetooth availability arrive asynchronously.
            // Observe a brief startup transition without extending the pairing deadline.
            guard !requestedConnection, !verified else {
                fail("当前 App 无法使用蓝牙。请检查系统蓝牙与此配件的 App 授权后重试。")
                return
            }
            guard powerStateGrace == nil else { return }
            let remaining = max(0, min(2, deadline.timeIntervalSince(now())))
            pairingDebug("CB powered_off startup_grace_ms=\(Int(remaining * 1000))")
            powerStateGrace = Task { [weak self, weak central] in
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled, let self, let central,
                      self.active, self.central === central, central.state == .poweredOff else { return }
                self.powerStateGrace = nil
                pairingDebug("CB powered_off grace_ended authorization=\(CBCentralManager.authorization.rawValue)")
                self.fail("当前 App 无法使用蓝牙。请检查系统蓝牙与此配件的 App 授权后重试。")
            }
        case .unauthorized, .unsupported:
            fail("系统尚未授权连接此配件，请重新进行系统配对。")
        @unknown default:
            fail("蓝牙状态不可用，请重新开始配对。")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard active, central === self.central, peripheral === self.peripheral else { return }
        pairingDebug("CB did_connect peripheral_state=\(peripheral.state.rawValue)")
        guard verified || now() < deadline else { fail("配对窗口已结束，请重新开始。"); return }
        onEvent?(.connected)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard active, central === self.central, peripheral === self.peripheral else { return }
        pairingDebug("CB did_fail_to_connect error=\(pairingErrorSummary(error))")
        fail(connectionFailureMessage(error, fallback: "所选设备未能建立蓝牙连接，请重新开启配对窗口。"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard active, central === self.central, peripheral === self.peripheral else { return }
        pairingDebug("CB did_disconnect error=\(pairingErrorSummary(error))")
        fail(connectionFailureMessage(error, fallback: "设备蓝牙连接已断开，请重新开启配对窗口。"))
    }

    private func connectionFailureMessage(_ error: Error?, fallback: String) -> String {
        guard let error else { return fallback }
        let nsError = error as NSError
        if nsError.domain == CBErrorDomain,
           nsError.code == CBError.peerRemovedPairingInformation.rawValue {
            return "系统报告配对信息已失效。请在系统配件或蓝牙设置中移除 SightLatch 的旧记录，再回到 App 重新配对。"
        }
        return fallback
    }

    private func fail(_ message: String) {
        let callback = onEvent
        cancel()
        callback?(.failed(message))
    }
}
#endif
