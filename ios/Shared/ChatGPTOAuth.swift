import Foundation
import CryptoKit
import Security
import Darwin

// Public OSS client. No application secret, borrowed client ID, or browser cookies.
enum ChatGPTAuthError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class ChatGPTNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum ChatGPTHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 120
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config, delegate: ChatGPTNoRedirect(), delegateQueue: nil)
    }()
    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count < 1_000_000 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Never include token endpoint bodies or request URLs in logs/errors.
            throw ChatGPTAuthError.message("ChatGPT 请求失败（HTTP \(status)）。请检查连接或重新登录；不会改用 API Key。")
        }
        return data
    }
    static func form(_ url: String, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").data(using: .utf8)
        return request
    }
}

struct ChatGPTTokens: Codable, Sendable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let scope: String?
    let expires_in: Double
}
struct ChatGPTConnection: Codable, Sendable {
    var clientID: String
    var subject: String
    var email: String
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var scopes: String
    var expiresAt: Date
    var canUsePlan: Bool { scopes.split(separator: " ").contains("chatgpt.tokens.use.direct") }
}
struct ChatGPTAccountSummary: Identifiable, Sendable {
    let id: String
    let email: String
}
struct ChatGPTVault: Codable {
    var hostID = "urn:uuid:" + UUID().uuidString.lowercased()
    var pendingClientID: String?
    var activeClientID: String?
    var connections: [String: ChatGPTConnection] = [:]
}

// A lock shared by the app and extensions prevents rotating-refresh-token races.
// No tokens or identity are written to the App Group lock file.
actor ChatGPTOAuth {
    static let shared = ChatGPTOAuth()
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let keychainAccount = "chatgpt-plan|oauth-v1"
    private func lock() async throws -> Int32 {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PilotAppGroup") as? String,
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw ChatGPTAuthError.message("ChatGPT 登录需要有效的 App Group 签名配置。")
        }
        let fd = open(directory.appendingPathComponent("chatgpt-oauth.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ChatGPTAuthError.message("无法锁定 ChatGPT 会话。") }
        do {
            let deadline = Date().addingTimeInterval(60)
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                try Task.checkCancellation()
                guard Date() < deadline else { throw ChatGPTAuthError.message("另一进程正在更新登录，请稍后重试。") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            return fd
        } catch { close(fd); throw error }
    }
    private func unlock(_ fd: Int32) { flock(fd, LOCK_UN); close(fd) }
    private nonisolated static func readVault() throws -> ChatGPTVault {
        // Missing item is the only permissible empty-vault case. Corrupt/inaccessible credentials fail closed.
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PilotKeychainGroup") as? String, !group.contains("$(") else {
            throw ChatGPTAuthError.message("Keychain access group 配置无效。")
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "HIDPilot", kSecAttrAccount as String: Self.keychainAccount,
            kSecAttrAccessGroup as String: group, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return ChatGPTVault() }
        guard status == errSecSuccess, let data = item as? Data else { throw ChatGPTAuthError.message("无法读取 ChatGPT Keychain 会话。") }
        return try JSONDecoder().decode(ChatGPTVault.self, from: data)
    }
    private func save(_ vault: ChatGPTVault) throws {
        try SecretStore.save(String(decoding: JSONEncoder().encode(vault), as: UTF8.self), account: Self.keychainAccount)
    }
    func prepare() async throws -> (hostID: String, connection: ChatGPTConnection?, pendingClientID: String?) {
        let fd = try await lock(); defer { unlock(fd) }
        let vault = try Self.readVault(); try save(vault)
        return (vault.hostID, vault.activeClientID.flatMap { vault.connections[$0] }, vault.pendingClientID)
    }
    func current() async throws -> ChatGPTConnection? { let result = try await prepare(); return result.connection }
    nonisolated static func hasStoredPlanCredentials() -> Bool {
        guard let vault = try? readVault(), let id = vault.activeClientID, let connection = vault.connections[id] else { return false }
        return connection.canUsePlan && !connection.accessToken.isEmpty && (connection.expiresAt > Date() || !connection.refreshToken.isEmpty)
    }
    func accounts() async throws -> [ChatGPTAccountSummary] {
        let fd = try await lock(); defer { unlock(fd) }
        return try Self.readVault().connections.values.map { ChatGPTAccountSummary(id: $0.clientID, email: $0.email) }.sorted { $0.id < $1.id }
    }
    func selectAccount(_ clientID: String) async throws {
        let fd = try await lock(); defer { unlock(fd) }
        var vault = try Self.readVault()
        guard vault.connections[clientID] != nil else { throw ChatGPTAuthError.message("未找到保存的 ChatGPT 账户。") }
        vault.activeClientID = clientID; try save(vault)
    }
    func rememberRegistration(_ clientID: String) async throws {
        let fd = try await lock(); defer { unlock(fd) }
        var vault = try Self.readVault(); vault.pendingClientID = clientID; try save(vault)
    }
    func connect(code: String, clientID: String, verifier: String, redirect: String, nonce: String,
                 expectedSubject: String?) async throws {
        let data = try await ChatGPTHTTP.send(ChatGPTHTTP.form(Self.issuer + "/api/accounts/oauth/token", [
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect, "resource": Self.resource]))
        let tokens = try JSONDecoder().decode(ChatGPTTokens.self, from: data)
        guard let idToken = tokens.id_token, tokens.expires_in > 0, tokens.expires_in.isFinite else {
            throw ChatGPTAuthError.message("登录响应缺少有效身份或有效期。")
        }
        let identity = try await ChatGPTIdentity.verify(idToken, audience: clientID, nonce: nonce)
        guard expectedSubject == nil || expectedSubject == identity.subject else {
            throw ChatGPTAuthError.message("返回的账户与选择的账户不同；原会话未替换。")
        }
        try Task.checkCancellation()
        let fd = try await lock(); defer { unlock(fd) }
        try Task.checkCancellation()
        var vault = try Self.readVault()
        vault.connections[clientID] = ChatGPTConnection(clientID: clientID, subject: identity.subject,
            email: identity.email, accessToken: tokens.access_token, refreshToken: tokens.refresh_token ?? "",
            idToken: idToken, scopes: tokens.scope ?? "", expiresAt: Date().addingTimeInterval(tokens.expires_in))
        vault.activeClientID = clientID; vault.pendingClientID = nil; try save(vault)
    }
    func accessToken() async throws -> String {
        let fd = try await lock(); defer { unlock(fd) }
        var vault = try Self.readVault()
        guard let id = vault.activeClientID, var connection = vault.connections[id], connection.canUsePlan,
              !connection.accessToken.isEmpty else { throw ChatGPTAuthError.message("请先登录 ChatGPT 并授权使用套餐额度。") }
        if connection.expiresAt.timeIntervalSinceNow > 90 { return connection.accessToken }
        guard !connection.refreshToken.isEmpty else { throw ChatGPTAuthError.message("ChatGPT 会话已到期，请重新登录。") }
        let data = try await ChatGPTHTTP.send(ChatGPTHTTP.form(Self.issuer + "/api/accounts/oauth/token", [
            "grant_type": "refresh_token", "client_id": id, "refresh_token": connection.refreshToken, "resource": Self.resource]))
        let tokens = try JSONDecoder().decode(ChatGPTTokens.self, from: data)
        guard let replacement = tokens.refresh_token, !replacement.isEmpty, !tokens.access_token.isEmpty,
              tokens.expires_in.isFinite, tokens.expires_in > 0 else { throw ChatGPTAuthError.message("ChatGPT 刷新响应不完整，请重新登录。") }
        connection.accessToken = tokens.access_token; connection.refreshToken = replacement
        connection.expiresAt = Date().addingTimeInterval(tokens.expires_in)
        if let scopes = tokens.scope { connection.scopes = scopes }
        // Persist rotation even if the request was cancelled after the server rotated it.
        vault.connections[id] = connection; try save(vault)
        guard connection.canUsePlan else { throw ChatGPTAuthError.message("ChatGPT 套餐授权已关闭。") }
        return connection.accessToken
    }
    func signOut() async throws -> Bool {
        let fd = try await lock(); defer { unlock(fd) }
        var vault = try Self.readVault()
        guard let id = vault.activeClientID, var connection = vault.connections[id] else { return true }
        var revoked = connection.refreshToken.isEmpty
        if !connection.refreshToken.isEmpty {
            do {
                let discovery = try await ChatGPTHTTP.send(URLRequest(url: URL(string: Self.issuer + "/.well-known/openid-configuration")!))
                let object = try JSONSerialization.jsonObject(with: discovery) as? [String: Any]
                guard let endpoint = object?["revocation_endpoint"] as? String, let url = URL(string: endpoint),
                      url.scheme == "https", url.host == "auth.openai.com", url.user == nil, url.password == nil else {
                    throw ChatGPTAuthError.message("撤销端点无效。")
                }
                _ = try await ChatGPTHTTP.send(ChatGPTHTTP.form(endpoint, ["token": connection.refreshToken,
                    "token_type_hint": "refresh_token", "client_id": id]))
                revoked = true
            } catch { revoked = false }
        }
        connection.accessToken = ""; connection.refreshToken = ""; connection.idToken = ""; connection.scopes = ""
        vault.connections[id] = connection; try save(vault)
        return revoked
    }
}

// Strict RS256 verification; unsupported signing algorithms fail closed.
enum ChatGPTIdentity {
    static func decode(_ value: String) -> Data? {
        var base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        return Data(base64Encoded: base)
    }
    static func der(_ tag: UInt8, _ bytes: Data) -> Data {
        var length = bytes.count; var sizes = [UInt8]()
        repeat { sizes.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
        return Data([tag]) + (bytes.count < 128 ? Data([UInt8(bytes.count)]) : Data([0x80 | UInt8(sizes.count)]) + Data(sizes)) + bytes
    }
    static func integer(_ bytes: Data) -> Data {
        let normalized = Data(bytes.drop(while: { $0 == 0 }))
        return der(0x02, (normalized.first.map { $0 >= 128 } == true ? Data([0]) : Data()) + normalized)
    }
    static func verify(_ token: String, audience: String, nonce: String) async throws -> (subject: String, email: String) {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 3, let headerData = decode(pieces[0]), let payloadData = decode(pieces[1]), let signature = decode(pieces[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String else { throw ChatGPTAuthError.message("无效的身份令牌。") }
        let jwksData = try await ChatGPTHTTP.send(URLRequest(url: URL(string: ChatGPTOAuth.issuer + "/.well-known/jwks.json")!))
        let jwks = try JSONSerialization.jsonObject(with: jwksData) as? [String: Any]
        guard let keys = jwks?["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              let n = key["n"] as? String, let e = key["e"] as? String, let modulus = decode(n), let exponent = decode(e),
              let publicKey = SecKeyCreateWithData(der(0x30, integer(modulus) + integer(exponent)) as CFData,
                [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data((pieces[0] + "." + pieces[1]).utf8) as CFData, signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { throw ChatGPTAuthError.message("ChatGPT 身份签名验证失败。") }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        let now = Date().timeIntervalSince1970
        guard claims["iss"] as? String == ChatGPTOAuth.issuer, audiences.contains(audience),
              audiences.count <= 1 || claims["azp"] as? String == audience,
              let exp = claims["exp"] as? Double, exp > now - 5,
              let iat = claims["iat"] as? Double, iat <= now + 5,
              (claims["nbf"] as? Double ?? 0) <= now + 5,
              claims["nonce"] as? String == nonce, let subject = claims["sub"] as? String, !subject.isEmpty else {
            throw ChatGPTAuthError.message("ChatGPT 身份、有效期或登录随机数不匹配。")
        }
        return (subject, claims["email"] as? String ?? "ChatGPT 账户")
    }
}
