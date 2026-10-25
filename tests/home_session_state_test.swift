import Foundation

@main struct HomeSessionStateTests {
    static func main() {
        var command = SessionCommand(task: "观察安全页面", running: true)
        var status = PilotStatus(phase: "待广播", detail: "准备完成", steps: 0, sessionID: command.id)
        var frame = CaptureObservation(sessionID: command.id, state: "capturing", receivedAt: Date(),
            receivedUptime: ProcessInfo.processInfo.systemUptime, generation: command.generation)
        func state(_ observation: CaptureObservation?) -> HomeCaptureState {
            HomeCaptureState.resolve(preparing: false, prepared: true, command: command, status: status, observation: observation)
        }
        precondition(state(nil) == .ready)
        precondition(state(frame) == .capturing)
        command.pendingClarification = .init(question: "选择当前聊天吗？", options: [.init(title: "继续观察", reply: "重新查看")],
            createdAt: Date(), sessionID: command.id, generation: command.generation, frameID: "q-frame", scopeID: nil, stopGeneration: nil)
        status.phase = "等待用户"
        precondition(state(frame) == .awaitingAnswer, "A pending question retains capture without claiming the AI is executing")
        command.running = false
        precondition(state(frame) == .ended, "A stale question cannot advertise resumable control")
        command.running = true
        command.pendingClarification = nil
        status.phase = "暂停"
        precondition(state(frame) == .paused, "A fresh frame cannot hide the runtime pause")
        precondition(state(frame).detail == "查看原因后结束本轮任务。")
        status.phase = "观察"
        frame.state = "paused"
        precondition(state(frame) == .paused, "Capture pause must be visible before status polling catches up")
        frame.state = "waiting"
        precondition(state(frame) == .waiting)
        frame.state = "capturing"; frame.receivedUptime = ProcessInfo.processInfo.systemUptime - 6
        precondition(state(frame) == .interrupted)
        frame.receivedUptime = ProcessInfo.processInfo.systemUptime
        frame.generation = command.generation + 1
        precondition(HomeCaptureState.currentObservation(frame, command: command) == nil)
        precondition(state(frame) == .ready, "Another generation cannot claim to be receiving current frames")
        frame.generation = nil
        precondition(HomeCaptureState.currentObservation(frame, command: command) == nil)
        frame.generation = command.generation; frame.sessionID = "old-session"
        precondition(HomeCaptureState.currentObservation(frame, command: command) == nil)
        frame.sessionID = command.id
        command.running = false; status.phase = "暂停"
        precondition(state(frame) == .ended, "A revoked attempt is ended, not waiting to resume")
        let activity = ActivityPresentationUnderTest.presentationStatus(status, running: false)
        precondition(activity.phase == "暂停" && activity.steps == status.steps && activity.updatedAt == status.updatedAt)
        precondition(status.phase == "暂停" && activity.detail == status.detail, "Presentation must not overwrite the App's original cause")
        precondition(ActivityPresentationUnderTest.presentationStatus(status, running: true).phase == "暂停")
        status.phase = "完成"
        precondition(ActivityPresentationUnderTest.presentationStatus(status, running: false).phase == "完成")
        for warning in ["请核实硬件停止", "停止未确认，请急停", "硬件已停止，请结束广播", "设备停止失败"] {
            status.phase = warning
            precondition(ActivityPresentationUnderTest.presentationStatus(status, running: false).phase == warning,
                         "Revoked local command is not proof that a hardware warning was resolved")
        }
        for detail in ["模型把握不足（模型置信度82%，模型报告指针可见，执行门槛85%）：尚未确定下一步",
                       "模型置信度不足，指针已在按钮上", "规划期间画面变化或没有新帧，旧动作已丢弃", "截图已过期，当前提案未执行"] {
            let advice = RecoveryAdvice.classify(detail)
            precondition(!advice.steps.contains("校准"), "Confidence or frame freshness does not establish calibration failure")
            precondition(advice.steps.contains("结束本轮"))
        }
        precondition(RecoveryAdvice.classify("截图未能可靠定位系统指针").title == "尚未定位系统指针")
        precondition(RecoveryAdvice.classify("设备、方向或屏幕尺寸已变化，请重新自动校准。").title == "指针校准需要检查")
        precondition(RecoveryAdvice.classify("坐标映射未确认").title == "指针校准需要检查")
        precondition(!RecoveryAdvice.classify("指针可见，坐标映射已验证，需要检查其它结果").steps.contains("校准"))
        precondition(RecoveryAdvice.classify("HTTP 401").title == "凭据或权限不可用")

        var absoluteConfiguration = PilotConfiguration()
        let calibrationContext = PointerCalibrationContext(deviceURL: absoluteConfiguration.deviceURL, phoneModel: "test",
            orientation: "portrait", pixelWidth: 1260, pixelHeight: 2736, scale: 3)
        var profile = PointerCalibrationProfile(context: calibrationContext, pixelsPer100X: 504,
            pixelsPer100Y: 1094.4, verifiedAt: Date())
        profile.absoluteMapping = AbsolutePointerMapping(hardwareBootID: "measured-boot", hidGeneration: 7,
            screenFromHID: .init(a: 0.126, b: 0, c: 0, d: 0, e: 0.2736, f: 0),
            maxResidualPixels: 1, verifiedAt: Date(), validationPointCount: 4,
            validatedHIDBounds: .init(minX: 500, maxX: 9500, minY: 500, maxY: 9500))
        absoluteConfiguration.automaticCalibrationProfile = profile
        var absoluteCommand = SessionCommand(task: "观察安全页面", running: true,
            execution: SessionExecution(hardware: PreparedHardwareAuthorization(deviceURL: absoluteConfiguration.deviceURL,
                softwareControl: true, bootID: "measured-boot", controlEpoch: "measured-epoch", hidGeneration: 7)))
        let actualReason = "聊天历史疑似包含凭据，需要你先处理当前页面"
        let rawDetail = "AI 需要协助：\(actualReason)（置信度 98%，模型未定位指针）。"
        let absoluteStatus = PilotStatus(phase: "暂停", detail: rawDetail, steps: 1, sessionID: absoluteCommand.id)
        precondition(HomeStatusPresentation.usesVerifiedAbsoluteMapping(configuration: absoluteConfiguration,
            command: absoluteCommand, status: absoluteStatus))
        let shown = HomeStatusPresentation.detail(rawDetail, verifiedAbsoluteMode: true)
        precondition(shown.contains(actualReason) && shown.contains("置信度 98%"))
        precondition(shown.contains("已验证绝对坐标映射") && !shown.contains("模型未定位指针"))
        precondition(absoluteStatus.detail == rawDetail, "Presentation must not overwrite the stored first cause")
        let absoluteAdvice = RecoveryAdvice.classify(shown, verifiedAbsoluteMode: true)
        precondition(absoluteAdvice.title == "当前页面需要你处理", "Page content is not an API-credential failure")
        precondition(!absoluteAdvice.steps.contains("检查系统指针") && !absoluteAdvice.steps.contains("不能可靠自动点选"))
        // Both executors and their logs wrap the Gate reason before the App
        // reads it. Test these actual production forms, not just a naked Gate.
        for prefix in ["本轮未执行动作。", "暂停：本轮未执行动作。", "后台会话停止：本轮未执行动作。",
                       "本轮暂停原因：本轮未执行动作。"] {
            let wrapped = prefix + rawDetail
            let presented = HomeStatusPresentation.detail(wrapped, verifiedAbsoluteMode: true)
            precondition(presented == prefix + shown)
            precondition(presented.contains(actualReason) && presented.contains("置信度 98%"))
            precondition(!presented.contains("模型未定位指针"))
            precondition(RecoveryAdvice.classify(presented, verifiedAbsoluteMode: true).title == "当前页面需要你处理")
            precondition(HomeStatusPresentation.detail(wrapped, verifiedAbsoluteMode: false) == wrapped)
        }
        precondition(RecoveryAdvice.classify("截图未能可靠定位系统指针", verifiedAbsoluteMode: true).title == "当前目标需要检查")
        precondition(RecoveryAdvice.classify("目标超出实测绝对定位范围", verifiedAbsoluteMode: true).title == "目标坐标需要检查")
        precondition(HomeStatusPresentation.detail(rawDetail, verifiedAbsoluteMode: false) == rawDetail)
        let missingPointerReason = "AI 需要协助：模型未定位指针是原因原文，没有固定诊断后缀。"
        precondition(HomeStatusPresentation.detail(missingPointerReason, verifiedAbsoluteMode: true) == missingPointerReason,
                     "A true model reason must not be scrubbed as assessment metadata")
        let lowConfidence = "模型把握不足（置信度 82%，模型报告指针可见，执行门槛 85%）：当前目标不明确"
        let mappedConfidence = HomeStatusPresentation.detail(lowConfidence, verifiedAbsoluteMode: true)
        precondition(mappedConfidence.contains("置信度 82%") && mappedConfidence.contains("执行门槛 85%") && mappedConfidence.contains("当前目标不明确"))
        precondition(!mappedConfidence.contains("模型报告指针可见"))
        precondition(HomeStatusPresentation.detail("暂停：本轮未执行动作。" + lowConfidence, verifiedAbsoluteMode: true)
            == "暂停：本轮未执行动作。" + mappedConfidence)
        absoluteCommand.execution!.hardware.bootID = "different-boot"
        precondition(!HomeStatusPresentation.usesVerifiedAbsoluteMapping(configuration: absoluteConfiguration, command: absoluteCommand, status: absoluteStatus))
        absoluteCommand.execution!.hardware.bootID = "measured-boot"
        absoluteCommand.execution!.hardware.hidGeneration = 8
        precondition(!HomeStatusPresentation.usesVerifiedAbsoluteMapping(configuration: absoluteConfiguration, command: absoluteCommand, status: absoluteStatus))
        absoluteCommand.execution!.hardware.hidGeneration = 7
        absoluteCommand.execution!.hardware.deviceURL = "http://different-device.local"
        precondition(!HomeStatusPresentation.usesVerifiedAbsoluteMapping(configuration: absoluteConfiguration, command: absoluteCommand, status: absoluteStatus))
        absoluteCommand.execution!.hardware.deviceURL = absoluteConfiguration.deviceURL
        absoluteCommand.id = "old-session"
        precondition(!HomeStatusPresentation.usesVerifiedAbsoluteMapping(configuration: absoluteConfiguration, command: absoluteCommand, status: absoluteStatus))
        absoluteCommand.id = absoluteStatus.sessionID
        absoluteConfiguration.automaticCalibrationProfile?.absoluteMapping = nil
        precondition(!HomeStatusPresentation.usesVerifiedAbsoluteMapping(configuration: absoluteConfiguration, command: absoluteCommand, status: absoluteStatus),
                     "A legacy relative profile cannot claim absolute-mode presentation")

        command = SessionCommand(task: "打开微信，给测试收件人发送消息：测试文本", running: true)
        command.messageScope = MessageScope(intent: MessageIntent.parse(command.task)!, sessionID: command.id,
            generation: command.generation, expiresAt: Date().addingTimeInterval(60))
        command.messageScope!.launch.phase = .opening
        status = PilotStatus(phase: "观察", detail: "新画面", steps: 1, sessionID: command.id)
        let openingNotice = "正在打开微信；AI会读取画面并处理本次系统打开确认。"
        precondition(HomeNoticePresentation.visibleNotice(openingNotice, command: command, status: status) == openingNotice)
        status.phase = "暂停"
        precondition(HomeNoticePresentation.visibleNotice(openingNotice, command: command, status: status) == nil)
        status.phase = "观察"; command.messageScope!.launch.phase = .opened
        precondition(HomeNoticePresentation.visibleNotice(openingNotice, command: command, status: status) == openingNotice)
        command.messageScope!.launch.visuallyEstablishedAt = Date()
        command.messageScope!.launch.visuallyEstablishedUptime = ProcessInfo.processInfo.systemUptime
        command.messageScope!.launch.visuallyEstablishedFrameID = "visible-frame"
        precondition(HomeNoticePresentation.visibleNotice(openingNotice, command: command, status: status) == nil)
        command.running = false
        precondition(HomeNoticePresentation.visibleNotice(openingNotice, command: command, status: status) == nil)
        let stopWarning = "本地会话已停止，但未确认硬件停止送达。请按物理 STOP。"
        precondition(HomeNoticePresentation.visibleNotice(stopWarning, command: command, status: status) == stopWarning)
        print("PASS: capture generation/state, revoked Activity warnings, absolute-mode evidence and honest pause reasons, relative-mode help, current launch-only notice and preserved STOP warnings")
    }
}
