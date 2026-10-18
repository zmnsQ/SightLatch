import AppIntents

/// Kept out of extensions: openAppWhenRun must run in the main application.
struct PrepareSightLatchTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "准备 SightLatch 任务"
    static var description = IntentDescription("将文字或快捷指令听写结果填入聊天草稿并打开 App。确认发送、硬件 ARM 和系统屏幕广播仍由你完成。")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "任务文本", default: "") var task: String
    static var parameterSummary: some ParameterSummary { Summary("在 SightLatch 准备 \(\.$task)") }
    @MainActor
    func perform() async throws -> some IntentResult {
        PilotShortcutRouter.shared.open(task: task)
        return .result()
    }
}

struct DictateSightLatchTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "向 SightLatch 说任务"
    static var description = IntentDescription("打开 App 后开始一次前台语音输入。首次使用需允许麦克风和语音识别；文字仅填入草稿，不会自动发送或录屏。")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @MainActor
    func perform() async throws -> some IntentResult {
        PilotShortcutRouter.shared.open(startVoice: true)
        return .result()
    }
}

struct SightLatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PrepareSightLatchTaskIntent(), phrases: ["用 \(.applicationName) 准备任务", "Prepare a task in \(.applicationName)"], shortTitle: "准备任务", systemImageName: "text.bubble")
        AppShortcut(intent: DictateSightLatchTaskIntent(), phrases: ["向 \(.applicationName) 说任务", "Dictate a task in \(.applicationName)"], shortTitle: "说出任务", systemImageName: "mic")
        AppShortcut(intent: StopPilotSessionIntent(), phrases: ["停止 \(.applicationName) 会话", "Stop \(.applicationName)"], shortTitle: "停止会话", systemImageName: "stop.circle")
    }
}
