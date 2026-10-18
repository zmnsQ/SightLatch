import Foundation
import AuthenticationServices
import Network
import CryptoKit
import Security
import UIKit
import Combine

// A system authentication sheet keeps the containing app alive while the loopback listener waits.
// This is an experimental native implementation: real-device browser/loopback behavior must be tested.
@MainActor
final class ChatGPTSignInController: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var isSigningIn = false
    @Published var status = "尚未登录 ChatGPT"
    @Published var accountLabel = ""
    private var webSession: ASWebAuthenticationSession?
    private var listener: NWListener?
    private var attempt: Task<Void, Never>?
    private var continuation: CheckedContinuation<URL, Error>?
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var attemptID: UUID?
    private var handlingCallback = false
    private var timer: Task<Void, Never>?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
    func reload() async {
        do {
            let connection = try await ChatGPTOAuth.shared.current()
            accountLabel = connection?.email ?? ""
            status = connection?.canUsePlan == true && connection?.accessToken.isEmpty == false ? "已启用 ChatGPT 套餐额度" : "尚未授权 ChatGPT 套餐额度"
        } catch { status = error.localizedDescription }
    }
    func signIn(newAccount: Bool = false) {
        guard !isSigningIn else { return }
        let id = UUID(); attemptID = id; isSigningIn = true; handlingCallback = false
        attempt = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await ChatGPTOAuth.shared.prepare()
                try Task.checkCancellation()
                let state = try Self.random(), nonce = try Self.random(), verifier = try Self.random()
                let port = try await startListener(id: id)
                try Task.checkCancellation()
                let redirect = "http://127.0.0.1:\(port)/auth/callback"
                let returning = newAccount ? nil : prepared.connection
                let clientID = returning?.clientID ?? prepared.pendingClientID ?? "dynamic_agent_client"
                var items = ["client_id": clientID, "ext_agent_host_id": prepared.hostID,
                    "response_type": "code", "redirect_uri": redirect, "scope": ChatGPTOAuth.scopes,
                    "resource": ChatGPTOAuth.resource, "state": state, "nonce": nonce,
                    "code_challenge_method": "S256", "code_challenge": Self.base64(Data(SHA256.hash(data: Data(verifier.utf8))))]
                if clientID == "dynamic_agent_client" { items["agent_name_hint"] = "SightLatch" }
                if let token = returning?.idToken, !token.isEmpty { items["id_token_hint"] = token }
                if returning?.canUsePlan == false { items["prompt"] = "consent" }
                var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
                components.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
                let callback = try await authorize(url: components.url!, id: id)
                try Task.checkCancellation()
                guard let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else { throw ChatGPTAuthError.message("登录回调无效。") }
                func single(_ name: String) -> String? { let matches = values.filter { $0.name == name }; return matches.count == 1 ? matches[0].value : nil }
                guard single("state") == state else { throw ChatGPTAuthError.message("登录校验失败，请重新开始。") }
                guard single("error") == nil else { throw ChatGPTAuthError.message("登录已取消或未授权套餐使用。") }
                guard let code = single("code"), !code.isEmpty else { throw ChatGPTAuthError.message("登录缺少授权码。") }
                let issued = single("client_id") ?? (clientID == "dynamic_agent_client" ? "" : clientID)
                guard !issued.isEmpty, issued != "dynamic_agent_client", issued.count < 512,
                      clientID == "dynamic_agent_client" || issued == clientID else { throw ChatGPTAuthError.message("登录注册标识不匹配。") }
                if returning == nil { try await ChatGPTOAuth.shared.rememberRegistration(issued) }
                try Task.checkCancellation()
                try await ChatGPTOAuth.shared.connect(code: code, clientID: issued, verifier: verifier,
                    redirect: redirect, nonce: nonce, expectedSubject: returning?.subject)
                await reload()
            } catch {
                if attemptID == id {
                    status = error is CancellationError ? "登录已取消" : ((error as? ChatGPTAuthError)?.localizedDescription ?? "ChatGPT 登录未完成，请重试。")
                }
            }
            if attemptID == id { finish() }
        }
    }
    func cancel() {
        attempt?.cancel(); resumeCallback(.failure(CancellationError()))
        readyContinuation?.resume(throwing: CancellationError()); readyContinuation = nil
        finish(); status = "登录已取消"
    }
    func signOut() async {
        cancel()
        do {
            let revoked = try await ChatGPTOAuth.shared.signOut()
            accountLabel = ""
            status = revoked ? "已退出 ChatGPT" : "已清除本地会话；远端撤销未确认，请在 ChatGPT 设置断开连接。"
        } catch { status = error.localizedDescription }
    }
    private func finish() {
        timer?.cancel(); timer = nil; listener?.cancel(); listener = nil
        webSession?.cancel(); webSession = nil; attemptID = nil; isSigningIn = false; attempt = nil
    }
    private func resumeCallback(_ result: Result<URL, Error>) {
        let current = continuation; continuation = nil
        current?.resume(with: result)
    }
    private func authorize(url: URL, id: UUID) async throws -> URL {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { callback in
            continuation = callback
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
                Task { @MainActor in
                    guard let self, self.attemptID == id, !self.handlingCallback else { return }
                    self.resumeCallback(.failure(error ?? CancellationError()))
                }
            }
            session.presentationContextProvider = self
            webSession = session
            guard session.start() else { resumeCallback(.failure(ChatGPTAuthError.message("无法启动系统登录窗口。"))); return }
            timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
                guard let self, self.attemptID == id else { return }
                self.resumeCallback(.failure(ChatGPTAuthError.message("登录超时，请重新开始。")))
            }
        }
    }
    private func startListener(id: UUID) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        return try await withCheckedThrowingContinuation { ready in
            readyContinuation = ready
            timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                guard let self, self.attemptID == id else { return }
                self.readyContinuation?.resume(throwing: ChatGPTAuthError.message("无法启动本地登录回调，请重试。"))
                self.readyContinuation = nil
            }
            server.stateUpdateHandler = { [weak self, weak server] state in
                Task { @MainActor in
                    guard let self, self.attemptID == id else { return }
                    switch state {
                    case .ready:
                        if let port = server?.port?.rawValue { self.timer?.cancel(); self.readyContinuation?.resume(returning: port); self.readyContinuation = nil }
                    case .failed(let error):
                        self.readyContinuation?.resume(throwing: error); self.readyContinuation = nil
                        self.resumeCallback(.failure(error))
                    default: break
                    }
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { connection.cancel() }
                Self.receive(connection, bytes: Data()) { url in
                    Task { @MainActor in
                        guard let self, self.attemptID == id, !self.handlingCallback, self.continuation != nil else { return }
                        self.handlingCallback = true
                        self.resumeCallback(.success(url)); self.webSession?.cancel()
                    }
                }
            }
            server.start(queue: .main)
        }
    }
    nonisolated private static func receive(_ connection: NWConnection, bytes: Data, callback: @escaping @Sendable (URL) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            let all = bytes + (data ?? Data())
            guard error == nil, all.count <= 16_384 else { connection.cancel(); return }
            guard let text = String(data: all, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { receive(connection, bytes: all, callback: callback) }; return
            }
            let first = text.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
            guard first.count == 3, first[0] == "GET", first[1].hasPrefix("/auth/callback?"),
                  let url = URL(string: "http://127.0.0.1" + first[1]) else { connection.cancel(); return }
            let body = "Login received. You can return to SightLatch."
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            callback(url)
        }
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatGPTAuthError.message("无法生成登录安全随机数。") }
        return base64(Data(bytes))
    }
    private static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
