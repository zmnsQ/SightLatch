import SwiftUI

struct ChatGPTSettingsSection: View {
    @ObservedObject var model: PilotViewModel
    @StateObject private var auth = ChatGPTSignInController()
    @State private var models: [ChatGPTModel] = []
    @State private var accounts: [ChatGPTAccountSummary] = []
    @State private var loadingModels = false
    @State private var modelError = ""
    var body: some View {
        Section("ChatGPT 套餐（实验性）") {
            Text("官方开源客户端登录；仍需真机验证系统浏览器与本地回调。API Key 方式保留，不会自动切换计费。")
                .font(.caption).foregroundStyle(.secondary)
            Text(auth.status).font(.caption)
            if !auth.accountLabel.isEmpty { Text(auth.accountLabel).font(.caption).textSelection(.enabled) }
            Button(auth.isSigningIn ? "正在登录…" : "Continue with ChatGPT") { auth.signIn() }
                .disabled(auth.isSigningIn || model.isSessionActive)
            if !accounts.isEmpty {
                Menu("选择保存的 ChatGPT 账户") {
                    ForEach(accounts) { account in
                        Button(account.email + " · " + String(account.id.suffix(6))) {
                            Task {
                                do { try await ChatGPTOAuth.shared.selectAccount(account.id); models = []; await auth.reload() }
                                catch { modelError = error.localizedDescription }
                            }
                        }
                    }
                    Button("添加另一个账户") { auth.signIn(newAccount: true) }
                }.disabled(auth.isSigningIn || model.isSessionActive)
            }
            if auth.isSigningIn { Button("取消登录", role: .cancel) { auth.cancel() } }
            if ChatGPTOAuth.hasStoredPlanCredentials() {
                Button("刷新可用模型") { Task { await loadModels() } }.disabled(loadingModels || model.isSessionActive)
                if !models.isEmpty {
                    Picker("ChatGPT 模型", selection: $model.configuration.model) {
                        if !models.contains(where: { $0.id == model.configuration.model }) {
                            Text("请选择模型").tag(model.configuration.model)
                        }
                        ForEach(models) { item in Text(item.displayName).tag(item.id) }
                    }.disabled(model.isSessionActive)
                }
                Toggle("允许本次启用后的屏幕任务在后台使用我的 ChatGPT 套餐", isOn: Binding(
                    get: { model.configuration.chatGPTPlanConsent == true },
                    set: { model.configuration.chatGPTPlanConsent = $0 })).disabled(model.isSessionActive)
                Button("使用 ChatGPT 套餐并保存") {
                    model.apiKey = "" // Clear only the editor; saved API Key credentials remain untouched.
                    model.configuration.provider = "chatgpt-plan"
                    model.configuration.endpoint = "https://api.openai.com/v1/responses"
                    _ = model.save()
                }.disabled(model.isSessionActive || model.configuration.chatGPTPlanConsent != true || !models.contains(where: { $0.id == model.configuration.model }))
            }
            if !auth.accountLabel.isEmpty {
                Button("退出 ChatGPT", role: .destructive) {
                    Task { await auth.signOut(); models = []; model.configuration.chatGPTPlanConsent = false; _ = model.save() }
                }.disabled(model.isSessionActive || auth.isSigningIn)
            }
            if loadingModels { ProgressView() }
            if !modelError.isEmpty { Text(modelError).font(.caption).foregroundStyle(.red) }
            Link("查看和管理 ChatGPT 用量", destination: URL(string: "https://chatgpt.com/settings/usage")!)
            Link("Sign in with ChatGPT 条款", destination: URL(string: "https://openai.com/policies/sign-in-with-chatgpt-terms/")!)
            Text("登录授权会分享基本账户信息。屏幕任务会向 OpenAI 发送任务与所选截图；截图上传仍需单独同意。额度以 ChatGPT 设置为准。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await auth.reload(); accounts = (try? await ChatGPTOAuth.shared.accounts()) ?? [] }
        .onChange(of: auth.isSigningIn) { _, active in
            if !active { Task { accounts = (try? await ChatGPTOAuth.shared.accounts()) ?? [] } }
        }
        .onDisappear { if auth.isSigningIn { auth.cancel() } }
    }
    @MainActor private func loadModels() async {
        loadingModels = true; modelError = ""; defer { loadingModels = false }
        do { models = try await ChatGPTPlanClient.shared.models() }
        catch { modelError = error.localizedDescription }
    }
}
