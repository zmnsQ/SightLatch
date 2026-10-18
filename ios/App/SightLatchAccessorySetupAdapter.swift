import Foundation
import Combine
import UIKit
#if canImport(AccessorySetupKit) && compiler(>=6.1)
import AccessorySetupKit
import CoreBluetooth
#endif

/// Experimental until validated with a signed iPhone build and the matching firmware.
/// Accessory authorization is NOT evidence that the board's BLE link is encrypted.
@MainActor
final class SightLatchAccessorySetupAdapter: ObservableObject {
    static let serviceUUID = "7D9B1E20-4F6A-4C88-A3D2-6E5F0190B7C1"
    static let manualInstructions = "打开 iPhone 的设置 → 蓝牙，选择 SightLatch 并确认配对，然后返回这里验证连接。窗口过期后请重新开始。"

    enum State: Equatable {
        case idle, activating, presenting, selectedAwaitingVerification, cancelled
        case unavailable(String)
        case failed(String)
    }
    @Published private(set) var state: State = .idle
    private var generation = UUID()
    private var timeout: Task<Void, Never>?
    #if canImport(AccessorySetupKit) && compiler(>=6.1)
    private var session: ASAccessorySession?
    private var selected = false
    #endif

    /// Call only after /v1/pair succeeds and the board reports a live pairing window.
    /// Pass the latest /v1/status capability and the actual remaining window, not a new 30s.
    func present(serviceUUID: String?, pairingWindowIsOpen: Bool, remainingSeconds: Int = 30) {
        switch state {
        case .activating, .presenting: return // No duplicate system sheets.
        default: break
        }
        stopSession()
        guard pairingWindowIsOpen, remainingSeconds > 0 else {
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
        selected = false
        state = .activating
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(remainingSeconds, 30)) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.generation == attempt else { return }
            self.stopSession()
            self.state = .failed("配对窗口已结束。请重新开始，或使用系统蓝牙设置。")
        }
        session.activate(on: .main) { [weak self, weak session] event in
            Task { @MainActor [weak self] in
                guard let self, let session, self.generation == attempt else { return }
                if event.error != nil {
                    self.stopSession()
                    self.state = .failed("系统配对未完成。可重试或使用系统蓝牙设置。")
                    return
                }
                switch event.eventType {
                case .activated:
                    self.showPicker(session: session, attempt: attempt)
                case .pickerDidPresent:
                    self.state = .presenting
                case .accessoryAdded:
                    self.selected = true
                case .pickerDidDismiss:
                    let didSelect = self.selected
                    self.stopSession()
                    self.state = didSelect ? .selectedAwaitingVerification : .cancelled
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

    /// Invalidates only discovery. Does not remove bonds or close the board's Wi-Fi window.
    /// The owner must also cancel its /v1/pair flow and status polling as appropriate.
    func cancel() {
        stopSession()
        state = .cancelled
    }

    private func stopSession() {
        generation = UUID() // Fence delayed callbacks from cancellation/retry/timeout.
        timeout?.cancel()
        timeout = nil
        #if canImport(AccessorySetupKit) && compiler(>=6.1)
        let previous = session
        session = nil
        previous?.invalidate()
        selected = false
        #endif
    }

    #if canImport(AccessorySetupKit) && compiler(>=6.1)
    private static var hasDiscoveryDeclarations: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let technologies = info["NSAccessorySetupKitSupports"] as? [String] ?? []
        let services = info["NSAccessorySetupBluetoothServices"] as? [String] ?? []
        let names = info["NSAccessorySetupBluetoothNames"] as? [String] ?? []
        return technologies.contains("Bluetooth")
            && services.contains(where: { $0.uppercased() == serviceUUID })
            && names.contains("SightLatch")
    }

    @available(iOS 18.4, *)
    private func showPicker(session: ASAccessorySession, attempt: UUID) {
        guard generation == attempt else { return }
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
        session.showPicker(for: [item]) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt, error != nil else { return }
                self.stopSession()
                self.state = .failed("系统未能完成配对。请确认蓝牙已打开并重试，或使用系统蓝牙设置。")
            }
        }
    }
    #endif
}
