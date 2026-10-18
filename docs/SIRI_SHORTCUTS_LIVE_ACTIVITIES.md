# Siri、快捷指令、前台语音与实时活动

## 可用动作（源码实现，待 Xcode/真机验收）
- “准备 SightLatch 任务”：可接收快捷指令的文字或“听写文本”输出，打开聊天并填入草稿。
- “向 SightLatch 说任务”：解锁并打开 App 后开始一次前台听写，首次需系统麦克风与语音识别授权。最长 55 秒，可结束并保留文本，也可取消恢复原草稿。后台、视图退出、音频中断或会话启用会停止录音。Apple Speech 可能使用 Apple 服务器；App 不保存音频文件。
- “停止 SightLatch 会话”：复用已有停止 intent，先撤销本地命令再尝试硬件 STOP，并回报确认/未确认状态。软件停止不能替代物理急停，也不保证系统广播已经结束。

在“快捷指令”创建：“听写文本” → “准备 SightLatch 任务”，将听写结果传入“任务文本”，给快捷指令取一个容易说出的名字。长按侧边键唤起 Siri 后说这个名字。可直接使用自动发现的 App Shortcuts 短语。Siri 语言、名称识别和系统索引可能影响发现，需要真机检查。

任务文本只进入草稿，不发送、不准备硬件、不运行模型。用户确认聊天任务、连接/校准、屏幕上传同意、硬件 ARM，以及系统广播确认仍保留。已有会话进行中不会替换当前任务。短语可把进入聊天/听写压缩为一次调用，不能把跨 App 系统录屏授权压缩成静默自动启动。

## 系统边界
Apple 的 RPSystemBroadcastPickerView 由用户点击后显示系统广播选择器。实现没有遍历内部按钮、模拟点击或私有 API，不绕过系统广播确认。没有无限后台语音模式，也没有新增后台音频 entitlement。

iOS 18 基线使用 openAppWhenRun，意图只编入 App；停止/刷新 LiveActivityIntent 保留在 App 和 Widget。较新 SDK 将 openAppWhenRun 标为弃用，但仍保留兼容 API；发布前需要在所选 Xcode SDK 检查 App Intents 元数据提取。

## 实时活动与灵动岛
锁屏、compact、minimal、expanded 显示白名单状态、已执行步数、过期提示、回跳聊天及停止/刷新。任务原文、模型输出、URL、工具参数不会显示在锁屏；phase 也经白名单转换。深链 sightlatch://chat 仅导航，不携带或执行任务。

开始会话创建活动，观察/规划/执行更新合并到至多每 5 秒一次，保留最新快照；首次需处理/失败/完成转换可以使用 ActivityKit AlertConfiguration 请求系统突出显示。每类重要状态每会话最多提醒一次，普通每步不发提醒。最终停止/完成且命令已撤销后结束活动并保留系统默认结束摘要；未确认停止保留警示。暂停可回聊天处理，不冒充完成。

Apple 控制活动是否展示、横幅/灵动岛如何展开，以及系统资源/频率限制。AlertConfiguration 是重要更新的官方提醒机制，不是强制每步弹开的保证。活动本身不会保活 App；普通 ReplayKit 模式中主 App 被挂起后，进度可能过期。iOS 26 有界 continued-processing 运行期间可发布更新；后台任务到期/系统拒绝时不能保证持续刷新。

## 验证
Linux 可执行测试：tests/PilotActivityPresentationTests.swift 验证状态分类、隐私白名单、终态/提醒分类；tests/check_shortcuts.py 验证源码安全约束。swiftc -frontend -parse 可检查语法，但不等于 Apple SDK 类型检查、App Intents 元数据校验、签名或设备测试。

真机验收：
1. 安装后在 Shortcuts 找到三个动作；Siri 冷启动/热启动；锁屏需解锁；普通文字/空文字/听写文字输入。
2. 语音首次允许、拒绝、设置撤销、网络不可用、无音频输入、结束、取消、55 秒上限、切后台、电话中断；确认不自动发送。
3. 活动已存在时新草稿不覆盖；停止 intent 与下一会话不串线；校验物理停止失败警示。
4. 需手工点击系统广播确认；关闭系统录屏后会话正确撤销。
5. 真机有/无灵动岛、锁屏、compact/minimal/expanded、过期、停止失败、完成终态、点击返回聊天；活动关闭/权限关闭/系统预算限制时 App 正常工作。
6. iOS 18 普通广播与 iOS 26 continued-processing 两条路径，主 App 挂起、系统取消后状态可过期且不误报完成。

## Apple 官方参考
- https://developer.apple.com/documentation/replaykit/rpsystembroadcastpickerview
- https://developer.apple.com/documentation/appintents/appintent/openappwhenrun
- https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition
- https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)
- https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- https://developer.apple.com/documentation/activitykit/activity/update(_:alertconfiguration:)
- https://developer.apple.com/design/human-interface-guidelines/live-activities
