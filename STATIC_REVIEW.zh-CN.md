# 静态源码审阅记录

日期：2026-10-14。范围：人工阅读源码、工程配置及协议；没有安装依赖、编译、运行、模拟器、单元测试、烧录或真机操作。因此以下不是构建通过或安全认证。

版本范围：这是首轮源码审阅记录。随后版本新增 Workspace、WorkspaceViews、PilotIntents、模型档案/历史/队列等功能，并修改Widget成员关系；下文首轮target成员清单不再代表最新版全部内容。后续Linux尝试与实际执行结果见LINUX_VALIDATION.zh-CN.md；新增功能未因此获得Swift编译或真机验收。

## 已核对的源码结构
- Xcode 工程存在 App、Broadcast Upload Extension、Live Activity Widget 三个 target；App 对两个扩展有 target dependency 与 PlugIns 嵌入阶段。
- App target 包含三个 App Swift 文件及 Models、SharedStore、Network；Broadcast 包含 SampleHandler 与同样三个共享文件；Widget 只包含 Widget 与 Models，未纳入网络/密钥读取代码。
- Broadcast 的 extension point、principal class 与 SampleHandler 名称对应，RPBroadcastProcessMode 为 SampleBuffer。
- 三 target 的 App Group 配置一致；只有 App 与 Broadcast 持有共享 Keychain entitlement。Info.plist 配置变量与 SharedStore 查询名对应。
- scheme 的 App target 标识与工程对应。部署下限为 iOS18，Liquid Glass 调用用 iOS26 availability 判断；仍需 Xcode26 SDK 才能解析该新API。
- 没有在工程发现编译/构建阶段自动执行外部脚本。未独立验证签名、注册标识或SDK编译可用性。

## 审阅后已在源码看到的修正
- 模型返回的移动量改用范围判断，避免 abs(Int.min) 的整数溢出。
- 网络响应改为 AsyncBytes 有界累积，避免先整包收完再检查大小；已加入 defer bytes.task.cancel() 显式取消底层请求。
- API与设备凭据的Keychain账户分别绑定供应商/endpoint和设备地址；修改配置或删除凭据前检查运行命令。
- 保存配置返回成功/失败，准备会话和探测在保存失败时停止。
- Keychain删除检查返回值。
- 文本动作TTL按ASCII字节数计算，覆盖固件每字符50ms预算；硬件完成轮询期限调至6秒。
- 动作发送前复核command ID/generation/running及上传同意；模型思考期间仍读取缩略图，发动作前做低分辨率差异判断。
- 固件增加hidbridge.local的mDNS；协议入口、身份字段、序列、TTL和完成状态与iOS代码对应。
- 固件主体移到Bridge.cpp，避免Arduino自动函数声明与自定义类型定义顺序的问题。

## 仍须明确的限制
1. 32×32缩略图差异只是保守启发式，不能证明目标控件身份，也不能阻止所有小范围弹窗/按钮变化。方向和尺寸转换、指针是否出现在ReplayKit画面、相对鼠标加速度仍需实测。
2. 风险字段依赖模型自报，关键词白名单不能构成强安全边界。默认关闭自动点击/输入；一旦开启，必须全程人工监督。不得宣称可以安全无人值守处理敏感页面。
3. BLE hid_connected当前表示连接且加密，不表示系统已订阅CCCD、接收HID report或界面动作成功。固件completed同样不是UI成功证明。
4. ReplayKit停止/进程被系统终止时，异步软件STOP不保证送达。依赖固件有界动作、ARM租期和物理急停；安全任务10ms是轮询目标而不是硬实时保证。
5. 长按ARM在已连接情况下先断开；需再次长按打开配对窗口。SC JustWorks/固定PIN确认行为与目标iOS版本兼容性未测。
6. Live Activity由主App更新；App退后台后状态可能过期，Widget已提示延迟，不能将其视为可靠实时停止控件。
7. HTTP局域网链路为明文，Bearer Token可被同网攻击者窃听。仅适合可信隔离测试网络；本次未改为TLS。
8. 多供应商请求已按OpenAI Responses、OpenAI兼容Chat Completions、Anthropic Messages和Gemini generateContent分别组织。未调用服务验证模型参数支持、额度、错误格式或真实图片能力。

## 最后一轮源码复核
- 运行期间 Settings 和 Calibration 编辑已禁用；Settings 工具栏保留独立的“停止并撤回上传”操作。
- 软件STOP已使用持久化设备配置，避免使用尚未保存的表单地址。
- AsyncBytes超限/HTTP错误退出会显式取消底层URLSessionTask。

结论：本轮指出的主要源码缺陷已修正或在上文如实列为限制，可以作为**未经编译与真机验证的研究源码**交付。没有据此宣称可编译、可安装、端到端可用或通过安全认证。构建、权限弹窗、同机HID、后台扩展、内存峰值和断线恢复都留给用户后续独立验收。

## 2026-10-14 增补：可选 iOS 26 Continued Processing 路线

此次仅源码回读与项目结构检查；没有 Swift 编译器或 Apple SDK，**没有执行 Swift 语法解析、类型检查、iOS 构建或运行**。

### 新路径与修复回归

- `App/ContinuedSession.swift` 使用 `BGContinuedProcessingTaskRequest`、`.fail`、实际 launch handler 启动工作、进度与 expiration handler。后台工作真实承担模型请求、安全核验及局域网单步调度；默认 ReplayKit 扩展模式保留。
- `Broadcast/SampleHandler.swift` 在可选模式只生成最新帧文件，依据同会话六秒租约决定是否继续采集；主进程模型调用和动作提交均核验会话、generation、授权、时效与粗图像指纹。
- 已回读确认：旧 expiration 取消工作前匹配 session ID 与 task identifier；拒绝重复 run；取消等待 lease 时统一清理自身会话；已取消工作通过独立 `Task.detached` 尽力发有界 STOP；上传前在 `await publish` 后重新核验授权；默认扩展也在 await status 后复核上传授权；广播不再覆盖同会话终止原因。
- `SharedStore.swift` 的 frame.json 用原子写入、Complete File Protection、排除备份；`Workspace.swift` 启动无有效 lease 时清理旧帧，准备新会话也清理。文档现明确截图会短暂落盘，异常杀进程可能留下文件。文件删除不等于安全擦除。
- 无新确定阻塞性源码错误；这不等于 API/actor 类型检查通过或可上架、可实机工作。

### 结构检查的实际范围

Python 成功解析六个 plist/entitlements、一个共享 scheme XML；检查 PBX 中19个带引号路径全部存在、75个对象定义 ID 无重复。此为定制结构检查，**不是完整 Xcode project parser**。当前12个 Swift 源文件；ContinuedSession 仅进入 App target，Broadcast/Widget 不误编入该主进程协调器。三个 target 的运行、共享 Keychain、LiveActivityIntent 主进程路由仍待 Xcode/实机。

### 官方 API 证据与限制

- [Apple BGContinuedProcessingTaskRequest 初始化](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/init(identifier:title:subtitle:))：官方 Markdown availability 为 iOS/iPadOS26.0；描述 wildcard 基础标识及每次提交具体标识。
- [Apple 长任务指南](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)：可由用户前台操作发起，后台可执行网络和 CPU 工作，示例使用 register、submit、fail；系统可取消/终止，必须报告进度。
- [Apple updateTitle](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask/updatetitle(_:subtitle:))：所用方法确实存在。
- [Apple 通用 register 文档](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/register(fortaskwithidentifier:using:launchhandler:)) 仍写 launch 前完成注册及相同 ID 不能注册两次。新长任务指南则演示注册/提交流程。当前实现使用动态唯一具体 ID + plist wildcard，避免重复 ID；动态注册和 wildcard 在目标26.5.2的实际系统行为仍须验证，不能以能写出代码代替测试。

### 残余风险

- 六秒 lease 是应用层授权，不是操作系统执行时间保证。系统可在 STOP 完成前终止进程；必须保留物理急停和固件有界动作。
- App Group 单文件原子替换避免半包读取，但没有跨进程事务/CAS；读-修改-写及检查后执行仍有竞态。当前 ID/代际/时效检查缩小风险，不能证明零竞态或已发请求可撤回。
- frame.json 仅保留最新一帧，但崩溃、锁屏保护状态、排除备份设置失败等需要设备验证。上传许可撤回不会追回服务端已收到的数据。
- 32×32 指纹是粗变化检测，不是控件身份校验；不能保证没有点错，不应用于无人确认的敏感操作。
- BG任务等待广播期间进度有限，系统可能视为停滞；45秒无新帧退出只是应用策略，不保证系统给足45秒。每次动态注册闭包生命周期与多会话长时资源占用也需验证。

### 编译验证路径

Linux官方 xtool已实际运行，但无Apple SDK且本项目是三target Xcode工程、缺Package.swift，不能直接 dev build。不能把 SwiftPM 普通构建等同 iOS 构建。提供的 `.github/workflows/macos-unsigned-build.yml` 仅源码：用户未来自行上传/触发后，在有Xcode26+ SDK的macOS云runner做三个target的 unsigned xcodebuild；此次没有上传或触发。
