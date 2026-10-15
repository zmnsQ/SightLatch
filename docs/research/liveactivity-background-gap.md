# Live Activity 后台状态缺口：补充结论（2026-10-14）

## 现在可做的选择

1. **必做：LiveActivityIntent 的“刷新 / 停止”交互。** Apple 明确由系统在主 App 进程执行，不必打开 App UI。可读取 App Group 原子快照，定位相同 sessionID 的活动并 await update。不是自动逐步刷新，但是真正公开支持的跨进程入口。
2. **最值得实验：iOS 26 BGContinuedProcessingTask。** 它允许前台由用户启动、具有明确完成目标的长任务继续在后台执行 CPU / 网络工作，并自带系统 Live Activity 进度与取消 UI。可以承载真实的有限 Agent 会话，不需要后台音频。不能把一个空循环伪装成工作来保活。
3. **不应作为保证：Broadcast Upload Extension 直接 Activity.activities.update。** 尚未找到 Apple 明确保证该扩展能枚举/更新所属主 App 活动的资料，也未取得 SDK 中确切 application-extension unavailable 声明。不要把“未证实可用”写成“已证实编译禁止”，也不要把能 import/编译写成可跨进程工作。
4. **条件路线：真实 BLE 配件状态通知唤醒主 App，然后更新相关活动。** 这适合真实 ESP32 ACK/连接状态，不能伪造广播包作为通用 CPU 保活。
5. **可选呈现服务：ActivityKit APNs。** 独立于主 App 持续运行更新展示；只发状态，不发硬件命令。用户自配开发者凭据与服务器，没有建立任何服务。推送不是逐帧或逐步时延保证。

## 证据和边界

### A. 后台 App 可以更新，但不等于扩展可以替它更新

Apple 的 [update(_:)](https://developer.apple.com/documentation/activitykit/activity/update(_:)) 明确支持主 App 前台或后台执行时更新；[activities](https://developer.apple.com/documentation/activitykit/activity/activities) 定义为当前 App 的活动数组。[reconnectNotPermitted](https://developer.apple.com/documentation/activitykit/activityauthorizationerror/reconnectnotpermitted) 明确描述重建活动的进程与原始进程不同。这是身份隔离的证据，但这个错误针对重建，不能独自推导所有扩展 update 都失败。

[Displaying live data](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) 给出的受支持结构是 App 调 ActivityKit、Widget 扩展负责展示，或 ActivityKit 推送更新。App Group 文件更新 / Darwin 通知不自动授予暂停主 App 执行时间。SwiftUI Widget 视图不是持续运行的读取器；文件变化本身也不会重绘 Live Activity。

本轮尝试读取公开 SDK 镜像的 ActivityKit.swiftinterface 未获得有效文件，故没有报告未经核实的编译器 availability 标记。仍需用户 Mac/Xcode 与 iPhone 实测进程身份/枚举结果；Linux 编译不了 Apple ActivityKit，也不能替代这一验收。

### B. 可以立即实现：用户点击的 LiveActivityIntent

[Apple 官方交互指南](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities) 明确：LiveActivityIntent 在 App 进程运行；把实现加入 App target；界面用 Button(intent:)。普通 AppIntent 默认在 Widget 扩展执行，不宜替代。锁定设备需认证解锁后才能执行按钮动作。

建议：
- RefreshStatusIntent(sessionID)：读取一次共享快照；过滤 Activity<AgentAttributes>.activities 中 attributes.sessionID 匹配者；await activity.update(ActivityContent(state: snapshotState, staleDate: ...))；不存在时返回可解释结果，不在后台盲目重建。
- StopAgentIntent(sessionID)：先原子写停止请求/吊销会话执行许可；有合法本地连接时发送安全停止。显示“正在停止”直到扩展或硬件 ACK，不能仅 end Activity 然后宣称硬件已停止。
- await 关键操作后返回，不能 fire-and-forget 后立刻结束 perform。
- shared command 与 status 分文件或明确单写者，包含 sessionID、commandID、revision、timestamp，避免旧会话覆盖新状态。
- staleDate 与 context.isStale 显示“状态可能过期”；系统计时文字只能表示时间经过，不能冒充新完成步骤。

[Apple DTS 2026-03 回答](https://developer.apple.com/forums/thread/818467) 进一步明确必须由用户经系统触发 LiveActivityIntent 才有相应权限；自己调用 perform() 不会制造这个系统授权。故扩展不能用这个方式自动唤醒主 App。

### C. 新发现：BGContinuedProcessingTask（iOS 26）

官方证据：
- [长任务实现指南](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)：前台用户动作提交，可继续后台 CPU 与网络；支持立即失败策略；报告真实进度；用户可取消。
- [任务类型](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)：iOS 26.0 起；系统用 Live Activity 显示进度；资源紧张可突然终止，少进度任务优先终止。
- [updateTitle(_:subtitle:)](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask/updatetitle(_:subtitle:))：更新系统进度 UI 的标题和副标题。
- [WWDC25 Session 227](https://developer.apple.com/videos/play/wwdc2025/227/)：有明确即时目标的用户工作，包括连接配件更新；不是后台守护进程。

**建议实现结构（推论，非此 App 已验证能力）：**
- 用户前台按“开始此次任务”，提交 BGContinuedProcessingTaskRequest；strategy = .fail，避免离开很久后突然开始操作硬件。
- 主 App 的 continued task 真正承担任务协调、阶段验收、停止决策，最好承担 AI 决策/网络处理；ReplayKit 扩展提供最新帧与采集状态。这样 continued task 有真实用户工作，不只是用于维持进程。
- 若保留“AI和硬件全部在扩展”的架构，只有读取状态/刷新 UI 的主 App任务是否足以构成官方所指关键长任务，没有明确保证，不能包装成已受支持方案。
- 注册 handler 后再 submit；成功获得 task 并启动会话后才展示后台执行已就绪。
- 设置 task.progress.totalUnitCount 为明确计划工作量；只在实际工作完成时增量。对于最大步数是预算而不是总工作量的 Agent，显示“已执行 N 步 / 上限 M”并准确描述，不声称 N/M 是目标完成概率，不伪造百分比。
- task.updateTitle 反映实际阶段；如另保留自定义 Activity，由主 App 在真实进展时 await 更新。系统可能同时显示系统任务活动与自定义活动，要评估重复 UI，系统活动已可提供基本进度。
- expirationHandler 取消协调工作、写停止指令、撤销执行租约；完成路径唯一调用 setTaskCompleted(success:)；不能后台重新提交以无限延长。
- 用户在 App Switcher 强退时，官方说明任务取消但不会给取消回调。因此扩展/硬件需短时执行租约、最大时限、幂等命令、心跳超时失效；不能只依靠 expirationHandler 保证停止。
- 不申请 GPU 能力，除非确实用 GPU 且设备 supportedResources 支持。仅 CPU / 网络任务不需要背景 GPU entitlement。

**验收**：前台启动→另一个 App→真实步骤推进并刷新→等待网络无进度→系统取消→强退→资源限制/低电量→重复提交失败。必须记录 handler 是否执行、进度时间戳、Activity 版本、扩展停止 ACK。不是只看计时器是否走动。

### D. BLE 是事件驱动，不是无限运行

[官方 BLE 后台指南](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html) 支持 bluetooth-central App 因真实连接/特征值通知被唤醒。执行应快速返回；文档给约 10 秒而非无限时间，且不应执行与唤醒原因无关的任务。

因此 ESP32 发送真实命令执行 ACK 的 characteristic notification，主 App 更新该执行状态的 Live Activity，是合理可测组合；屏幕理解/云端请求不能都挤入这段执行时间。需要 ESP32 自定义 GATT 服务，不只是系统 HID 配对。没有实际状态变化时不得造通知。

[iOS26 扫描例外官方工程师解释](https://developer.apple.com/forums/thread/815189)：Live Activity 可以让扫描在一定使用状态下保有前台待遇，但锁定且熄屏时扫描限制恢复，无受支持绕过方式。这里说的是扫描，不代表所有连接通知停止，也不是通用进程保活。

### E. APNs 只作为显示选项

[Apple ActivityKit push 指南](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications) 提供服务器更新路径。需要活动 token 管理/轮换、正确 push topic、时间戳、真实状态和结束事件。推送服务只接收最小状态，不应接收屏幕或控制硬件。必须明确其网络/推送调度限制；不将其标成严格实时。

## 实现优先级

P0：Refresh/Stop LiveActivityIntent、sessionID/版本过滤、stale UI、停止 ACK。
P1：可选 BGContinuedProcessingTask 有限会话模式；认真放入实际任务工作，而非空保活；主App更新系统进度与自定义活动。
P2：真实 BLE ACK 状态同步，只有确有 GATT 功能需求才扩展。
P3：用户自配 APNs 纯状态通知服务。

直接从 ReplayKit 扩展更新主 App Activity 仅作为隔离试验：记录 bundleID、PID、枚举结果、调用前后 Activity state，失败保留降级。不得把实验成功以外的场景承诺为普遍可用。

## 给实现作者的准确 API / 注册补充

官方已读签名：
```swift
func register(forTaskWithIdentifier identifier: String,
              using queue: DispatchQueue?,
              launchHandler: @escaping (BGTask) -> Void) -> Bool
BGContinuedProcessingTaskRequest(identifier: String, title: String, subtitle: String)
request.strategy = .fail
try BGTaskScheduler.shared.submit(request)
func updateTitle(_ title: String, subtitle: String) // 同步，非 throws
```

BGTaskSchedulerPermittedIdentifiers 包含 `<bundle>.agent.*`；register 与 submit 都使用展开后的 `<bundle>.agent.<UUID>`。不要重复注册同一标识。构造 request 成功不表示系统接受 submission。

[initializer 文档](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/init(identifier:title:subtitle:)) 给出 wildcard 约定。[通用 register 文档](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/register(fortaskwithidentifier:using:launchhandler:)) 仍写启动前注册，但 WWDC25 Session 227 **专门说明 continued tasks 可以用户表达任务意图时动态注册，不受此旧限制**，以专门说明为准。

本轮官方指南/WWDC 明确 permitted identifiers 和可选 GPU entitlement，但未找到明确声明 `UIBackgroundModes=processing` 对 continued task 必需的文字；社区示例普遍设置不等同官方必要条件。需 Xcode 能力配置/SDK和真机验证。不要宣称未知 entitlement 或伪造授权。

最小实质迁移选项：AI 仍在 ReplayKit 扩展产生方案；主 App continued task 读取带会话/序号的候选动作，独立校验允许动作与期限，实际发 LAN 指令、验 ACK，并更新进度。此时主 App 承担真实工作，优于纯状态轮询。必须保证每个动作只有一个执行方，模式切换时扩展不得同时发命令；重新启动不能重放已经 ACK 的动作。此组合仍需真机验证及正确的取消/过期处理。
