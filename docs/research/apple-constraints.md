# iOS AI agent + ESP32：Apple 技术边界

研究日期：2026-10-14。目标现机：iOS 26.5.2。仅公开文档与源码只读研究；没有编译、安装、访问用户电脑或真机验证。下文把「官方已证实」「工程推论」「待测」分开。

## 结论

现机应以 ReplayKit Broadcast Upload Extension 为读屏入口。用户从系统界面主动启动一次屏幕广播，extension 在会话中取得像素、轻量预处理、请求 AI，再由手机向 ESP32 发命令，是值得做最小原型的路径。它不要求接入公开直播平台；但 Apple 没有对「跨 app AI 代理 + HID」这一组合给出通用审核许可或端到端可用性保证。优先验证 extension 内直接 Wi-Fi 控制，避免把主 app 常驻作为闭环前提。

重要版本分支：当前官方已有 iOS 27+ ScreenCaptureKit 全屏捕获示例，文档仍标 Beta。用户 26.5.2 不能照搬这条路线。网页里 ReplayKit 的新弃用标签不能解释成现机上 ReplayKit 已被删除。[官方 iOS 示例](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios)、[框架说明](https://developer.apple.com/documentation/screencapturekit)。

## 1. ReplayKit 与直接网络

**已证实：** RPBroadcastSampleHandler 接收 CMSampleBuffer；通过 processSampleBuffer、开始/暂停/恢复/结束回调处理广播。Apple 说明这些 handler 回调串行执行，前一个不返回不会调用后一个。[API 文档](https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler?changes=l_5)。

**已证实：** extension 可使用 URLSession 上传/下载；后台传输可在 extension 退出后由系统继续，但不是让自定义 AI 循环继续执行的机制。[Apple 扩展场景](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)。

**工程推论：** 广播 extension 存活期间可将精选帧通过 HTTPS 发给模型，接收结构化动作，并通过局域网发给 ESP32。没必要建立 YouTube/RTMP 直播；“Broadcast”是系统采集会话和扩展类型，不等于公开播放。直接模型请求、网络超时和跨 app 持续循环仍须真机验证。不要在串行回调里同步等模型：只保留最新帧，异步单请求，完成后再取新帧；广播结束必须取消请求并令硬件停机。

**资源边界：** Apple 明确 extension 内存限制比前台 app 低，会因资源压力被终止；没有在本次查到的正式文档中承诺统一 50 MB。网上以及 Apple 论坛用户帖子里的 50 MB 不能升级为 Apple 跨设备保证。OCR/图像压缩可实验，大型本地模型不能仅凭理论可加载便设计进 extension。[扩展性能限制](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)。

## 2. extension、主 app 与 App Groups

**已证实：** extension 是独立执行实体，包含它的主 app 不必运行；不能使用 UIApplication.shared 或标记 extension unavailable 的 API。App Groups 提供共享容器，不是共享进程或通用唤醒许可。[扩展模型](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)。

**建议：** 主 app 做首次权限、ESP32配置、任务确认与 Live Activity 启动；extension 做会话内采集/轻量控制。App Group 存少量配置、状态、序列号和停止标记，需同步读写。主 app 被挂起时，写文件、发进程通知或建立本地 socket 不应被当作可靠唤醒手段。若架构要求主 app 每步计算/转发，就必须额外证明其实际执行资格。

## 3. BLE：不能混淆三件事

1. **主 app 后台 BLE 已证实：** bluetooth-central 支持因特定蓝牙事件被唤醒、连接和读写；Apple 同时明确不是无限运行。系统可能减慢/合并扫描。[Core Bluetooth 后台说明](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)。
2. **iOS 26 Live Activity 例外已证实：** 主 app 已实例化 CBManager，且在进入后台前开启 Live Activity，可保留某些前台 BLE 权限，例如无指定 UUID 扫描及重复广播扫描。这不是任意网络推理、OCR或CPU循环永驻的文档保证。[Core Bluetooth 当前说明](https://developer.apple.com/documentation/CoreBluetooth?changes=_3)。Apple 工程师进一步说明：锁屏且屏幕熄灭后，Live Activity 不再充分处于使用中，扫描仍降级，不能绕过。[2026年2月官方工程师答复](https://developer.apple.com/forums/thread/815189)。
3. **广播 extension 内 BLE 尚未证实：** 本次没有找到 Apple 明确保证 RPBroadcastSampleHandler 内的 CBCentralManager 支持范围、权限呈现、后台恢复的文档。不能武断说 CoreBluetooth 一律禁止在所有扩展，也不能从主 app bluetooth-central 推导广播扩展同样有资格。老版扩展指南明确不允许把 UIBackgroundModes 放进 extension 的 plist 来取得普通 app 后台待遇。应以目标 SDK 的 application-extension-safe 编译检查及26.5.2真机测试为准。

因此最短闭环建议先用 extension → Wi-Fi → ESP32，BLE 控制作为独立实验；ESP32 → iOS 的 HID 链路与手机 app → ESP32 的控制通道也需分别验收。

## 4. 局域网权限与 Wi-Fi

**已证实：** extension 一般继承主 app 的 Local Network 授权状态；部分扩展被视为后台，权限未决定时会直接失败而不弹窗。NSLocalNetworkUsageDescription、使用 Bonjour 时的 NSBonjourServices 应放在主 app Info.plist。后台第一次连局域网不是可靠授权入口。[Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。

**建议：** 主 app 前台先完成局域网授权并实际连通 ESP32，再开广播。首版用同一局域网内的单播连接，减少发现和组播 entitlement 变量。若 ESP32 开无互联网热点，手机同时访问远程 AI 的路由是否正常要实测，不能默认蜂窝一定补上。对命令加配对认证、序列号、期限、确认和停止能力，防止局域网误控与旧动作重放。

## 5. Live Activity 真正能做什么

**已证实：** UI 在 widget extension 中，由 app 的 ActivityKit 更新，或通过 APNs 更新；Live Activity 自身不能访问网络。一般应在 app 前台启动；可由正在后台执行的 app 更新，不代表会因需要更新而任意唤醒。常规活动最多活跃8小时，结束后锁屏最多额外4小时；静态+动态数据合计4KB。[ActivityKit 指南](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities?changes=_6)。

**待测：** 广播 extension 是否能直接取得并更新该活动，不应在没有目标 SDK/真机证据时承诺；App Groups 写状态也不会自动更新 UI。可以先将 Live Activity 作为辅助状态显示，不让它成为安全停机唯一通道。进度需要标注最后更新时间，不能显示仍在运行却已无新帧的假状态。

## 6. 自用安装与 App Store

**已证实：** Xcode Personal Team 可在个人设备测试；Apple 当前说明 provisioning profile 7天到期，需重新构建安装，且有App/设备数量限制。[账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account)。付费开发签名也有有效期及 entitlement/provisioning 限制，不能把自用签名理解为解除沙盒、后台或隐私限制。

**审核风险与技术可行性分开：** 公开分发还涉及 API 预期用途（2.5.1）、后台用途（2.5.4）、屏幕记录的明确同意与可见指示（2.5.14），以及向第三方 AI 共享个人数据前明确披露和许可（5.1.2）。用户点系统“开始广播”不自动等于同意把画面发给任意 AI 服务。HID 自动行为、敏感界面和第三方服务规则也须解释，不能保证过审。[审核指南](https://developer.apple.com/app-store/review/guidelines/)。

## 7. 已读、可复用的公开源码

- **LiveKit Swift，Apache-2.0：** 已读 [LKSampleHandler.swift](https://github.com/livekit/client-sdk-swift/blob/main/Sources/LiveKit/Broadcast/LKSampleHandler.swift) 及[集成说明](https://github.com/livekit/client-sdk-swift/blob/main/Docs/ios-screen-sharing.md)。实际路径是 processSampleBuffer 调用 uploader；通过 BroadcastBundleInfo 的 socketPath 创建 BroadcastUploader，并使用 Darwin notification 协调开始/结束；连接关闭时结束广播。适合借鉴扩展生命周期、日志、停止清理及 App Group IPC。注意它把数据交给主 app 的设计不是“主 app 一定永驻”的证据，也不必为简单帧→AI路线带入完整视频 SDK。
- **Apple iOS ScreenCaptureKit 示例：** 已读[官方示例说明](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios)，包括系统 picker、SCStream 回调和 screen-capture 后台模式。是未来 iOS27+ 对照路线；当前网页标Beta，不适用于26.5.2。未下载编译示例，不能报告真机通过。
- **boboabw/phone-agent：** 同伴已读其 CaptureService.swift，依赖 iOS27 ScreenCaptureKit；它的构建/安装说明不等于跨 app闭环验收。不可作为26.5.2直接可运行替代品。

## 8. 最小闭环验证顺序

1. **采集门：** 26.5.2真机启动空的 Broadcast Upload Extension，切换两个普通 app，只记录帧计数、尺寸、旋转和停止回调。验收另一 app 在前台时仍有新帧，停止立即生效。不开AI/蓝牙。
2. **资源门：** 每次只保留最新帧，低频缩小压缩；测峰值内存、CPU、发热、横竖屏及长会话。不要按“50MB以下绝对安全”验收。
3. **控制门：** 前台预授权局域网，extension 向ESP32发送无副作用 ping/ack，再人工确认下发一个测试界面的HID动作。确认主app后台时通道仍通，且重复命令不重复执行。
4. **AI门：** 单帧→模型→单个有期限的结构化动作→新帧确认；每步验证session/frame/action序列号。先仅允许测试界面移动、点击，不碰支付、发送或账号安全操作。
5. **故障门：** 断网、模型超时、用户停止广播、extension退出、ESP32重连都不得继续旧动作；硬件无心跳自动释放所有按键并停止。
6. **辅助功能门：** 再测 Live Activity 更新和主app BLE方案；分开记录后台亮屏、锁屏亮屏、熄屏、用户强退等状态，禁止把一个状态的通过外推到所有状态。

通过标准是手机上形成“新帧→判断→手机直发硬件→HID改变画面→下一帧确认”的实测闭环，且停止/失败时安全收敛。仅编译成功、能显示Live Activity或录屏按钮出现均不算完成。
