import SwiftUI
import Foundation
import ESPProvision

// App target only. This experimental USB path is deliberately separate from BLE/AI control.
private final class USBNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct USBCommandReply: Decodable {
    let ok: Bool
    let error: String?
    let configured: Bool
    let armed: Bool
    let hid_connected: Bool
    let pairing_open: Bool
    let next_sequence: Int
    let transport: String
}

@MainActor
private final class USBProvisioningClient: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var authenticated = false
    @Published private(set) var lastReply: USBCommandReply?
    @Published private(set) var notice = "尚未认证。先在 S3 上长按按钮 3 秒，打开 60 秒准入窗口。"
    private var device: ESPDevice?
    private var session: URLSession?
    private let redirectDelegate = USBNoRedirectDelegate()
    private var generation = UUID()
    private var nextSequence = 1
    private static let commandURL = URL(string: "http://192.168.7.1/usb-command")!

    static func printableASCII(_ value: String, min: Int, max: Int) -> Bool {
        let bytes = Array(value.utf8)
        return (min...max).contains(bytes.count) && bytes.allSatisfy { (32...126).contains($0) }
    }

    func discard() {
        generation = UUID()
        session?.invalidateAndCancel()
        session = nil
        device = nil
        authenticated = false
        busy = false
        lastReply = nil
        nextSequence = 1
    }

    func authenticate(pop: String) {
        guard !busy else { return }
        guard !pop.isEmpty, pop.utf8.count <= 128 else {
            notice = "请输入已预置设备标签上的认证码。仅显式启用开发回退的固件可从 UART 获取临时代码。"
            return
        }
        discard()
        busy = true
        notice = "正在进行 Security 2 认证；不会切换 Wi-Fi。"
        let attempt = generation
        // Pinned SDK ESPLogging.isLogEnabled defaults to false. Never enable logs:
        // its initializer log would otherwise contain proofOfPossession.
        let candidate = ESPDevice(name: "SightLatch USB", security: .secure2,
                                  transport: .softap, proofOfPossession: pop,
                                  username: "sightlatch")
        candidate.espSoftApTransport = ESPSoftAPTransport(baseUrl: "192.168.7.1")
        // Verified SDK keys; patch 1 is mandatory for monotonically increasing GCM counters.
        candidate.versionInfo = ["prov": ["sec_ver": 2, "sec_patch_ver": 1]] as NSDictionary
        device = candidate
        // Direct session setup only: ESPDevice.connect would try to join a SoftAP.
        candidate.initialiseSession(sessionPath: "prov-session") { [weak self] status in
            Task { @MainActor in
                guard let self, self.generation == attempt else { return }
                self.busy = false
                guard case .connected = status, candidate.securityLayer != nil else {
                    self.discard()
                    self.notice = "认证未完成。检查线缆、局域网权限和认证码，重新长按板上按钮后再试。不会自动重试。"
                    return
                }
                let config = URLSessionConfiguration.ephemeral
                config.allowsCellularAccess = false
                config.waitsForConnectivity = false
                config.httpShouldSetCookies = false
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                config.urlCache = nil
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.httpMaximumConnectionsPerHost = 1
                config.timeoutIntervalForRequest = 3
                config.timeoutIntervalForResource = 3
                self.session = URLSession(configuration: config, delegate: self.redirectDelegate,
                                          delegateQueue: nil)
                self.authenticated = true
                self.notice = "Security 2 已认证。可显式写入配置或查询状态；不会自动 ARM 或移动。会话最多 5 分钟。"
            }
        }
    }

    func provision(ssid: String, password: String, token: String) async {
        guard (1...32).contains(ssid.utf8.count), !ssid.utf8.contains(0),
              password.isEmpty || Self.printableASCII(password, min: 8, max: 63),
              Self.printableASCII(token, min: 32, max: 128) else {
            notice = "SSID 必须为 1–32 个 UTF-8 字节；密码留空或为 8–63 个可打印 ASCII 字符；Token 为 32–128 个可打印 ASCII 字符。"
            return
        }
        await command(op: "provision", token: token, fields: ["ssid": ssid, "password": password])
    }

    func command(op: String, token: String, fields: [String: Any] = [:]) async {
        guard !busy, authenticated, let device, let security = device.securityLayer,
              let session else { return }
        guard Self.printableASCII(token, min: 32, max: 128) else {
            notice = "请输入 32–128 个可打印 ASCII 字符的设备 Token。"
            return
        }
        guard ["provision", "status", "arm", "stop", "move"].contains(op),
              (1..<Int(Int32.max)).contains(nextSequence) else {
            discard()
            notice = "会话状态无效，请重新打开物理窗口并认证。"
            return
        }
        busy = true
        let attempt = generation
        let sentSequence = nextSequence
        nextSequence += 1 // Consume before encryption/send. Never replay an uncertain request.
        var payload = fields
        payload["op"] = op
        payload["token"] = token
        payload["sequence"] = sentSequence
        do {
            let plain = try JSONSerialization.data(withJSONObject: payload)
            guard plain.count <= 1024, let encrypted = security.encrypt(data: plain) else {
                throw USBFailure.invalidResponse
            }
            var request = URLRequest(url: Self.commandURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 3)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = encrypted
            // Do not use ESPDevice.sendData: it may retry/reconnect and replay an action.
            let (data, response) = try await session.data(for: request)
            guard generation == attempt else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url == Self.commandURL, (16...4096).contains(data.count),
                  let decrypted = security.decrypt(data: data), decrypted.count <= 2048 else {
                throw USBFailure.invalidResponse
            }
            let reply = try JSONDecoder().decode(USBCommandReply.self, from: decrypted)
            guard reply.transport == "usb_ncm_hid_experimental",
                  reply.next_sequence == sentSequence + 1,
                  reply.next_sequence < Int(Int32.max) else { throw USBFailure.invalidResponse }
            nextSequence = reply.next_sequence
            lastReply = reply
            busy = false
            if reply.ok {
                switch op {
                case "provision": notice = "配置已写入板上 NVS，物理窗口已关闭；App 不保存这些凭据。Wi-Fi 配置仅保存，当前固件不启用 Wi-Fi。"
                case "arm": notice = "ARM 已确认，最长 60 秒。仅在安全测试页面手动测试。"
                case "stop": notice = "STOP 已确认；板端已撤销 ARM 并安排释放输入。实际 HID 接收仍需实机验证。"
                case "move": notice = "2 单位移动请求已接受，不代表 iPhone 已执行。"
                default: notice = "状态已更新（非持续监控）。"
                }
            } else {
                // Never render raw server errors, which are untrusted and might contain data.
                switch reply.error {
                case "physical_window_closed": notice = "配置窗口已关闭。重新长按板上按钮并认证。"
                case "unauthorized": notice = "Token 未被接受，请核对设备 Token。"
                case "not_armed": notice = "设备未 ARM 或租约已到期。"
                case "hid_unavailable": notice = "USB HID 尚未就绪，检查线缆和 iPhone 设置。"
                case "busy": notice = "板端上一操作尚未完成；未重试。"
                default: notice = "设备拒绝了请求；未重试。"
                }
            }
        } catch {
            guard generation == attempt else { return }
            discard()
            notice = "请求结果不确定或认证校验失败，会话已丢弃，不会重试。若可能仍在 ARM，请拔线停止，再重新打开物理窗口并认证。"
        }
    }

    private enum USBFailure: Error { case invalidResponse }
}

struct USBProvisioningView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var client = USBProvisioningClient()
    @State private var pop = ""
    @State private var ssid = ""
    @State private var password = ""
    @State private var token = ""
    @State private var confirmProvision = false
    @State private var confirmArm = false

    var body: some View {
        NavigationStack {
            Form {
                Section("实验性 USB NCM + HID") {
                    Text("仅适用于专用 ESP32-S3 USB 固件，不适用于 C3。使用 USB-C iPhone、支持数据的线缆与足够供电；指针可能需要开启辅助触控。枚举、供电和实际输入均待实机验证。")
                    Text("此面板不接入现有 BLE 自主代理，也不会启动 AI、录屏、自动配网或自动操作。")
                        .foregroundStyle(.secondary)
                }
                Section("1 · 物理准入与认证") {
                    Text("长按板上按钮 3 秒打开 60 秒窗口。使用已预置设备的标签认证码；默认固件在未预置标签凭据时保持关闭。只有显式启用 UART 开发回退的固件才显示临时代码，并需要第二台可信设备，不是纯 iPhone 首次安装。")
                    SecureField("设备认证码（PoP）", text: $pop)
                        .textContentType(.password)
                    Button("认证 Security 2") {
                        client.authenticate(pop: pop)
                        pop = ""
                    }.disabled(client.busy || pop.isEmpty)
                }
                Section("2 · 写入板端配置") {
                    SecureField("Wi-Fi SSID（1–32 UTF-8 字节）", text: $ssid)
                    SecureField("Wi-Fi 密码（可留空）", text: $password)
                    SecureField("设备 Token（32–128 ASCII 字符）", text: $token)
                    Text("这些字段仅保留在当前面板内存中。写入会将 SSID、密码和 Token 加密传给当前连接的 S3 并保存到其 NVS；会替换原配置并关闭准入窗口。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("写入配置…") { confirmProvision = true }
                        .disabled(!client.authenticated || client.busy)
                }
                Section("3 · 显式安全测试") {
                    Button("查询状态") { Task { await client.command(op: "status", token: token) } }
                    Button("ARM 60 秒…") { confirmArm = true }
                    Button("向右微移 2 单位") {
                        Task { await client.command(op: "move", token: token, fields: ["dx": 2, "dy": 0]) }
                    }.disabled(client.lastReply?.armed != true || client.lastReply?.hid_connected != true)
                    Button("STOP · 撤销 ARM", role: .destructive) {
                        Task { await client.command(op: "stop", token: token) }
                    }
                    Text("每次只发一个请求，不自动重试。关闭面板或进入后台会丢弃会话，但不等同于已发送 STOP；离开前先 STOP。无法确认停止时，拔线。板端 ARM 最长 60 秒后失效。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(!client.authenticated || client.busy)
                Section("最近状态") {
                    if client.busy { ProgressView("请求处理中") }
                    Text(client.notice)
                    if let reply = client.lastReply {
                        LabeledContent("已配置", value: reply.configured ? "是" : "否")
                        LabeledContent("ARM（上次查询）", value: reply.armed ? "是" : "否")
                        LabeledContent("HID（上次查询）", value: reply.hid_connected ? "就绪" : "未就绪")
                        LabeledContent("准入窗口", value: reply.pairing_open ? "打开" : "关闭")
                    }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("S3 USB 实验")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
            .confirmationDialog("将配置保存到连接的 S3？", isPresented: $confirmProvision, titleVisibility: .visible) {
                Button("加密发送并替换板端配置") {
                    Task {
                        await client.provision(ssid: ssid, password: password, token: token)
                        password = ""
                    }
                }
            } message: { Text("SSID、密码和 Token 将写入该板的 NVS。App 不保存副本，不启用 Wi-Fi。") }
            .confirmationDialog("允许手动 HID 测试 60 秒？", isPresented: $confirmArm, titleVisibility: .visible) {
                Button("ARM 60 秒") { Task { await client.command(op: "arm", token: token) } }
            } message: { Text("请先切到无敏感内容的测试页面。ARM 本身不移动指针，随后需手动点击微移。") }
            .onDisappear { clear() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { clear() } }
        }
    }

    private func clear() {
        client.discard()
        pop = ""; ssid = ""; password = ""; token = ""
    }
}
