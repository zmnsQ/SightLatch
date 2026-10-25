import SwiftUI

struct ChatGPTSettingsSection: View {
    @ObservedObject var model: PilotViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var auth = ChatGPTSignInController()
    @State private var models: [ChatGPTModel] = []
    @State private var accounts: [ChatGPTAccountSummary] = []
    @State private var loadingModels = false
    @State private var modelError = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("ChatGPT 账户").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                PilotSettingsCard {
                    PilotSettingsRowLabel(title: auth.accountLabel.isEmpty ? "尚未连接账户" : auth.accountLabel,
                        symbol: auth.accountLabel.isEmpty ? "person.crop.circle" : "person.crop.circle.badge.checkmark")
                        .textSelection(.enabled)
                    Text(auth.status).font(.footnote).foregroundStyle(.secondary)
                        .contentTransition(reduceMotion ? .identity : .opacity)
                    if auth.accountLabel.isEmpty { signInButton }
                    if !auth.accountLabel.isEmpty || !accounts.isEmpty {
                        Divider()
                        accountMenu
                    }
                    if auth.isSigningIn {
                        Button("取消登录", role: .cancel) { auth.cancel() }.frame(minHeight: 44)
                    }
                }
            }
            if ChatGPTOAuth.hasStoredPlanCredentials() {
                VStack(alignment: .leading, spacing: 10) {
                    Text("模型与使用许可").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    PilotSettingsCard {
                        HStack(spacing: 12) {
                            PilotSettingsRowLabel(title: "当前模型", symbol: "cpu")
                            Spacer(minLength: 4)
                            Button { Task { await loadModels() } } label: {
                                if loadingModels { ProgressView().frame(width: 44, height: 44) }
                                else { Label("刷新", systemImage: "arrow.clockwise").font(.subheadline).frame(minHeight: 44).contentShape(Rectangle()) }
                            }
                            .buttonStyle(.plain).disabled(loadingModels || model.isSessionActive)
                            .accessibilityLabel("刷新可用模型")
                        }
                        if !models.isEmpty {
                            Picker("ChatGPT 模型", selection: $model.configuration.model) {
                                if !models.contains(where: { $0.id == model.configuration.model }) {
                                    Text("请选择模型").tag(model.configuration.model)
                                }
                                ForEach(models) { item in Text(item.displayName).tag(item.id) }
                            }.disabled(model.isSessionActive).frame(minHeight: 44)
                        } else {
                            Text(model.configuration.model.isEmpty ? "刷新后选择可用模型" : model.configuration.model)
                                .font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Divider()
                        Toggle("允许屏幕任务在后台使用套餐", isOn: Binding(
                            get: { model.configuration.chatGPTPlanConsent == true },
                            set: { model.configuration.chatGPTPlanConsent = $0 })).disabled(model.isSessionActive)
                    }
                    Text("任务与截图将发送至 OpenAI。截图上传需在“权限与安全”中单独开启。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("使用并保存") {
                    modelError = ""
                    model.apiKey = "" // Clear only the editor; saved API Key credentials remain untouched.
                    model.configuration.provider = "chatgpt-plan"
                    model.configuration.endpoint = "https://api.openai.com/v1/responses"
                    if !model.save() { modelError = model.notice }
                }
                .pilotAction(prominent: true, fullWidth: true)
                .disabled(model.isSessionActive || model.configuration.chatGPTPlanConsent != true || !models.contains(where: { $0.id == model.configuration.model }))
            }
            if !modelError.isEmpty { PilotSettingsNotice(message: modelError, isError: true) }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Text("实验性功能，ChatGPT 套餐与 API 分别计费。登录会分享基本账户信息；套餐额度以 ChatGPT 用量页为准。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !ChatGPTOAuth.hasStoredPlanCredentials() {
                        Text("任务与截图将发送至 OpenAI。截图上传仍需在“权限与安全”中单独开启。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Link("查看 ChatGPT 用量", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                    Link("登录服务条款", destination: URL(string: "https://openai.com/policies/sign-in-with-chatgpt-terms/")!)
                }.padding(.top, 8)
            } label: { Label("数据与用量", systemImage: "info.circle") }
                .font(.subheadline)
        }
        .task { await auth.reload(); accounts = (try? await ChatGPTOAuth.shared.accounts()) ?? [] }
        .onChange(of: auth.isSigningIn) { _, active in
            if !active { Task { accounts = (try? await ChatGPTOAuth.shared.accounts()) ?? [] } }
        }
        .onDisappear { if auth.isSigningIn { auth.cancel() } }
    }

    private var accountMenu: some View {
        Menu {
            ForEach(accounts) { account in
                Button(account.email) {
                    Task {
                        do {
                            try await ChatGPTOAuth.shared.selectAccount(account.id)
                            models = []
                            await auth.reload()
                            accounts = (try? await ChatGPTOAuth.shared.accounts()) ?? []
                        }
                        catch { modelError = error.localizedDescription }
                    }
                }
            }
            Button("添加另一个账户") { auth.signIn(newAccount: true) }
            if !auth.accountLabel.isEmpty {
                Button("重新授权当前账户") { auth.signIn() }
                Divider()
                Button("退出 ChatGPT", role: .destructive) {
                    Task { await auth.signOut(); models = []; model.configuration.chatGPTPlanConsent = false; _ = model.save() }
                }
            }
        } label: {
            HStack(spacing: 12) {
                PilotSettingsRowLabel(title: "管理账户", subtitle: "切换、添加或退出账户", symbol: "person.2")
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }
        .disabled(auth.isSigningIn || model.isSessionActive)
    }

    @ViewBuilder private var signInButton: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            loginAction.buttonStyle(.glassProminent).tint(PilotPalette.accent)
        } else {
            loginAction.buttonStyle(.borderedProminent).tint(PilotPalette.accent)
        }
    }
    private var loginAction: some View {
        Button(auth.isSigningIn ? "正在登录…" : "Continue with ChatGPT") { auth.signIn() }
            .controlSize(.large).frame(minHeight: 44)
            .disabled(auth.isSigningIn || model.isSessionActive)
    }
    @MainActor private func loadModels() async {
        loadingModels = true; modelError = ""; defer { loadingModels = false }
        do { models = try await ChatGPTPlanClient.shared.models() }
        catch { modelError = error.localizedDescription }
    }
}
