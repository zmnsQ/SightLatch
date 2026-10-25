# SightLatch iOS 源码原型

**状态：这是功能流程继续完善后的开发源码版本。iOS App仍未完成Apple SDK编译、签名安装或真机运行验证；Linux实际检查与xtool尝试请看根目录验证报告。不能把Linux工具能运行、源码解析或工程引用检查当作iOS构建成功。未使用用户电脑或手机。**

## 2026-10-15 增量

本轮修复持久化假成功、准备/停止/校准竞态、跨进程命令更新、配置白名单、广播终止撤销与STOP确认。损坏本地数据会阻止保存，可在工作区确认后先保留副本再重置；不删除Keychain。更改端点/协议必须重新同意上传。旧编译尝试仅为历史，本轮未编译Swift。完整变更及验收见 `../CURRENT_VALIDATION_20261015.zh-CN.md`。

首次安装直接打开工程，在三个 target 选择同一个 Development Team 即可开始构建；无需复制 `Local.example.xcconfig`。`Local.xcconfig` 仅用于可选高级覆盖或保留既有签名标识，仍被 Git 忽略。

## 既有功能

- 首启引导与共享存储、Keychain、模型、局域网、BLE、ARM、指针和上传许可检查；检查项明确区分本地配置与实际设备快照。
- 最多12个模型档案，端点绑定凭据；切换端点重新确认上传。独立自管兼容网关入口，仅配置不联网，不伪装订阅OAuth。
- 最多100条任务记录、保存/载入/人工完成/移回队列/删除。队列只排序，不自动开始下一任务或恢复旧动作。
- 错误恢复分类、JSON非秘密设置导入导出、脱敏诊断导出；没有自动把日志发到外部服务。
- 系统/浅色/深色主题、系统动态字体和按钮辅助功能标签。校准支持10/50/100相对单位与本地安全靶心计数。
- Live Activity公开AppIntent刷新与停止按钮；可选iOS26有界后台任务模式见下文。


## 工程与系统

打开 `SightLatch.xcodeproj`，选择共享 scheme `SightLatch`。包含：

- SightLatch：SwiftUI 主 App，任务主页、状态卡、iOS 26 原生 Liquid Glass 底栏、分层设置与人工校准面板。
- SightLatchBroadcast：ReplayKit Broadcast Upload Extension，`RPBroadcastSampleHandler` 处理视频帧，不处理音频。
- SightLatchWidget：WidgetKit Live Activity / Dynamic Island 展示。

使用 Xcode 26 或更新的兼容 Xcode / iOS SDK（源码调用 iOS 26 glassEffect，需要对应SDK才能编译）。部署下限18.0是为了可用性降级，不表示已验证18或26.5.2；代码不依赖任何iOS27功能。目标设备为iPhone。没有第三方Swift依赖、没有复制无许可证仓库源码。已包含原创 AppIcon 与深浅色品牌标记；尚未提供 App Store 上架素材。

### 首次签名：只选自己的 Team

1. 打开工程后，在 `SightLatch`、`SightLatchBroadcast`、`SightLatchWidget` 的 Signing & Capabilities 选择同一 Development Team，保持 Automatically manage signing 开启。
2. 公共配置会用 `com.sightlatch.team<所选TeamID>.HIDPilot` 派生主 App 与两个扩展的 Bundle ID、共同 App Group，以及主 App / Broadcast 的 Keychain group。Keychain 前缀仍用系统提供的 `$(AppIdentifierPrefix)`，不假定它等于 Team ID。Widget 不读取密钥。
3. 选择 iPhone 并运行 SightLatch；两个扩展随主 App 安装。账户必须支持所需能力并允许 Xcode 配置签名。免费 Personal Team 可能不满足 App Groups 等要求，以 Xcode 实际结果为准，不要删除共享权限绕过。
4. 安装后首次解锁设备才能读取共享凭据。Keychain 使用 `AfterFirstUnlockThisDeviceOnly`，不云同步；卸载 App 并不保证删除 Keychain 内容。

### 可选：保留既有标识 / 自定义签名

首次安装无需 `Config/Local.xcconfig`。若已有安装或注册标识，请保留现有本地文件；它会继续覆盖默认值，避免更换容器导致旧配置与凭据不可见。需要新建覆盖时才复制 `Local.example.xcconfig`，取消所需行的注释并填写。一般只需覆盖 `PILOT_BUNDLE_PREFIX`，两种共享组会跟随；历史安装使用其他组时再显式设置 `PILOT_APP_GROUP`、`PILOT_KEYCHAIN_GROUP`，后者保留 `$(AppIdentifierPrefix)`。

不要逐个 target 手改 Bundle Identifier：它们应共享同一前缀，扩展保留 `.Broadcast` / `.Widget` 后缀。更换 Team 或标识可能变成新的安装 / 数据容器，不提供自动迁移。默认标识若已被其他账户占用，也可在本地覆盖一个自己拥有的前缀。不要将个人配置、签名文件、API Key 或设备 token 提交到仓库。

**API与设备凭据只存Keychain**，按provider+完整endpoint、device URL分别绑定。更换端点时需重新填写密钥；这避免把旧/新凭据误发给不同端点。配置、任务、最多100条动作元数据/暂停原因存App Group；默认扩展直连模式不保存截图，只在内存中编码并发送；可选后台协调模式会短暂保存一份最新截图到受保护且排除备份的App Group文件（覆盖并在结束时删除），不是安全擦除保证。云端截图保留策略仍由供应商控制。日志可能包含用户任务推导的简短理由，不要填敏感任务。

## 聊天式首页

首页显示实际提交的任务、当前操作回复与可展开的执行过程；执行记录按会话区分，不显示内部思维链。底部输入区支持文本与用户主动语音听写，听写只填草稿，不自动开始。点“开始接管”才申请设备控制，ReplayKit 屏幕广播仍由系统要求你主动开启。

设备配对与手动授权收在设备设置，模型与凭据收在“更多 → 连接与模型”。iOS 26 使用原生 Liquid Glass 操作按钮；降低透明度时改用不透明背景 / 普通按钮，大字号时纵向排列操作。云端只通过 Swift 语法解析，未提供或声称已验证真机截图与视觉效果。

## ESP32-C3 软件控制模式

软件模式固件的 `/v1/status` 明确返回 `control_mode: "software"` 才显示 App 配对与授权按钮。旧固件没有此字段，或返回 `physical` 时仍走硬件 ARM / STOP，不尝试软件授权。

1. 网页 USB 串口完成设备网络 / token 配置后，在 App 填相同设备地址与 token，点“保存并检查局域网 / BLE”。
2. 在主页点设备状态，进入设备设置后点“开始蓝牙配对”，设备开放30秒窗口；到 iPhone 系统设置连接 SightLatch，必要时启用辅助触控。配对本身不授权控制。
3. 在设备设置打开“指针校准”，明确允许最长 60 秒的校准移动；iPhone 需按提示标记真实指针位置。正常任务在聊天中提交目标，审阅 AI 计划后再允许屏幕上传与设备控制，随后由你启动系统屏幕广播。
4. “停止控制”同时撤销本地会话并请求设备 STOP。若无法确认送达，立刻拔掉 USB 电源，并结束系统广播。App 不会在轮询、重连、恢复任务或上电时自动授权，不会为已有授权续期。

USB 用于烧录、首次配置与供电；运行时 **App → 设备是局域网 Wi-Fi HTTP，设备 → iPhone 是 BLE HID**。不能当成纯蓝牙方案。前台每约3秒读取已主动检查过的设备状态；10秒没有新快照会标为过期，网络失败显示未知。App 退后台不保证刷新，硬件授权最多5分钟与断连/重启撤销由设备独立执行。`hid_connected` 在软件固件中表示 BLE 加密认证已成功；App 不凭已配对记录推断当前连接。具体板型与固件构建见固件指南。

## 用户自己执行的首次验收步骤（本次未执行）

1. 按固件 README 为 ESP32-C3 安装对应固件，配置 Wi-Fi 和控制令牌；iPhone 与板卡接入同一局域网。
2. 在 App「设备设置」保存地址与令牌，检查局域网连接和 BLE 配对。首次本地网络权限需要在前台完成。
3. 在 AI 设置选择支持图片的服务并完成配置；API Key 与 ChatGPT 套餐登录是独立路径，见[登录说明](../docs/CHATGPT_PLAN_LOGIN.zh-CN.md)。
4. 保持辅助触控开启，在「指针校准」定位指针后开始自动测量。采用已验证的绝对 HID 映射时，不依赖录屏中的指针可见性。
5. 发送明确目标，按运行引导补齐缺少的连接、校准或上传设置，再在系统面板开始屏幕广播。收到首帧后才启动设备控制和执行计时。
6. 正常流程为观察 → 思考 → 执行 → 新画面验证。普通导航和本次明确授权的微信消息由模型逐步执行；发送结果需要从新画面核验。
7. 真正需要选择时，App、锁屏实时活动和展开灵动岛显示问题与选项。等待期间继续捕获画面、停止派发动作；回答后重新读屏，继续原任务，不重置已执行记录或运行时限。
8. 用户停止、系统停止广播、授权到期、硬件响应不明等仍会结束控制。先在受控测试页面验证停止入口，再使用真实任务。

## 闭环与安全约束

- 扩展直接完成帧缩放（最长1280px、JPEG 0.75）、至少2秒节流、单个AI请求和局域网HTTP。主App不需要在后台接收截图，也没有远程服务器转发硬件指令。
- 广播回调只接收视频；每300ms最多排一帧的32x32轻量指纹处理。AI请求时仍更新当前画面指纹；执行前要求近期新帧且粗缩略差异较小。这个检测可能漏掉小按钮/文字改变，**不是目标身份保证**。
- 默认截图有效15秒，上限20秒；AI慢于限制会暂停，不放宽后盲执行。HTTP响应流限制1MB，截图编码不超过600KB；真正ReplayKit内存上限与耗电仍需真机测量。后台协调模式每秒暂存一帧，需额外测量文件I/O与内存。
- AI返回严格单个JSON动作，无工具执行代码、无批量动作。相对move幅度±100，scroll±3；click仅左键；文本最多64个可打印US ASCII字节。中文直接 HID 输入、系统键盘切换和 AI 拖动未实现；明确的微信消息范围支持一次本地正文准备与固定粘贴，C3 实测绝对映射支持定位点击。
- 低风险模式可点击导航、输入明确搜索框ASCII、按Esc/方向键；仅微信范围内、已验证正文与隐藏软键盘条件下支持一次固定发送 Enter。default review模式暂停click/key/text，由用户手动完成。
- 模型问题 `ask_user` 是可恢复的等待状态，不触发硬件 STOP。选项只表达用户意图，不能重放旧动作或取消执行限制；回答后必须读取新帧。收件人纠正仅允许在粘贴/发送前，绑定本帧可见且无歧义的聊天；不自动裁剪名字或改写正文。
- 普通导航与已授权消息逐步执行；付款、密码、未授权发送等不会因为点击一个通用“继续”而获准。硬件结果不明、停止状态不明与会话过期不能靠回答恢复。
- 这些策略依赖不完美的模型判断与词匹配，可被误判或截图提示注入绕过。它们不构成安全保证。只用于你持续看管的无风险任务，不能无人值守控制真实账户。
- 运行中禁止修改配置/凭据；先停止会话。上传许可撤回通过停止生效；不要在尚未结束广播时切到敏感页面。
- 终止性停止/错误会取消当前Task并尽力POST `/v1/stop`。已经到达硬件的操作无法撤销；进程被系统强杀时软件stop不保证送达。固件物理急停、有限TTL、ARM期限是必要独立保护。
- 会话按所选时长执行，也可二次确认不限时；规划轮次最多50（默认20），失败不重试动作。没有后台音频hack、私有API、或永久保活承诺。

## HTTP与固件合同

以 `../firmware/README.md` 为准。主App和扩展共用 `HardwareClient`：

- GET `/v1/status`，Bearer token，读取 `boot_id, uptime_ms, session_id, next_sequence, armed, hid_connected, busy`。
- session_id由**每次物理ARM的固件**生成，App不自造硬件会话ID。每个动作重新GET状态，使用设备当前uptime作为issued_at_ms（没有精确RTT补偿，慢网会保守过期）。
- POST `/v1/action` 带单动作、id、session_id、sequence、boot_id、issued_at_ms、ttl_ms。移动/点击默认1500ms；文本为字符数×50+1000，限1500...5000ms。
- button=1，按键使用USB HID usage；无自动修饰键组合。
- 收到202只表示接收；最长6秒轮询对应last_action_id/state直到completed。界面是否成功还需下一截图判断。
- 不重试POST。出错/暂停/停止 POST `/v1/stop`，会disarm，需重新物理ARM。

仅允许HTTP私网IPv4或`.local`设备主机。Info.plist只开 `NSAllowsLocalNetworking`，**没有NSAllowsArbitraryLoads全局例外**；私网IP在不同系统SDK的ATS行为必须真机确认，必要时优先`.local`，不要直接改全局放行。没有证书固定或局域网TLS；Bearer、动作与ASCII文本是明文，mDNS也不验证身份。不能连接不可信LAN或暴露端口到公网。

云AI只允许HTTPS完整URL，无URL内用户密码/查询参数。网络客户端不跟随重定向，避免把凭据跨域带走。不支持用户自签名证书绕过。

## Live Activity与两种执行模式

### 默认：扩展直接闭环

ReplayKit扩展直接完成云AI和局域网指令。主App前台启动Activity，运行时每5秒更新，退后台挂起后不保证自动刷新。15秒后标为过期。

锁屏与展开灵动岛使用公开 `LiveActivityIntent` 提供“停止”和当前问题的真实选项。选项只携带会话/问题/答案 ID，宿主在文件锁内核对当前问题、授权与停止状态；锁屏回答要求系统认证。同一问题仅通知一次，新问题会提交 `alertConfiguration` 请求强调展示，是否展开及展示时机由 iOS 决定。状态图标、步数和文案只在实际更新时使用短动画，并适配 AOD 与减少动态效果。

### 可选：iOS26 BGContinuedProcessingTask有界会话

设置中明确启用后，用户前台点“准备会话”提交 `.fail` 策略的系统任务。只有handler实际启动并写出有效租约后，App才提示准备完成；系统拒绝或5秒未启动则取消，不静默排队执行。

此模式不是空轮询保活：主App后台任务真实执行云AI、单步安全核验、局域网硬件调度和下一帧验证；ReplayKit每秒覆盖一份最新帧到App Group供其读取。文件使用完整文件保护并排除备份，退出会话后删除。若系统同时异常杀死相关进程，文件可能暂时遗留；App下次启动会清理无有效租约的旧帧，准备新会话前也清理旧帧。这不是安全擦除或崩溃时即时删除保证。启用前需额外同意本地暂存截图。截图不在诊断或设置导出中。

任务更新系统进度、阶段标题，并在仍获准执行时更新自定义Activity。按所选时长、最多50轮规划运行；首帧后45秒未更新画面会停止。任务每秒续一份6秒执行租约；系统expiration立即撤销共享命令，网络Task取消，清帧并尽力停止硬件。主App被强退可能没有回调，扩展检测租约失效后停止采集/广播并清帧；已到达硬件的动作仍只能靠固件TTL与物理急停约束。

系统可能拒绝、终止或节流任务与Live Activity；具体在iOS26.5.2同机HID+ReplayKit组合中是否能工作仍未验证。没有GPU权限申请，没有后台音频，没有无限重提任务。后台模式的 AI 澄清与默认扩展模式相同：保留画面、短租约和进度，回答后重新读屏。终止性错误或系统撤销执行后，不能恢复旧动作。

官方依据：
- https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
- https://developer.apple.com/documentation/appintents/liveactivityintent
- https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados
- https://developer.apple.com/videos/play/wwdc2025/227/

## 你需自行验证且可能修改的地方

- 三target签名、AppGroup/Keychain共享、广播扩展装载与本地网络授权。
- SDK26 SwiftUI/ActivityKit/ReplayKit编译API，以及iOS26.5.2真机行为。
- 同一iPhone既运行广播又接收外部BLE鼠标/键盘时，指针是否被录入帧、焦点/键盘布局/滚动方向/方向旋转。
- 各供应商模型ID、视觉/JSON输出支持、错误返回、令牌预算、截图延迟和费用。兼容协议不保证所有服务可用。
- 极端取消竞态、AI请求超时、巨大/畸形响应、截图变化/提示注入、硬件ack失败；不要将源码检查等同测试通过。
- 无App Store审核/隐私清单合规评估、无生产级审计/访问控制，也没有交付已签名IPA。

## 实现参考（只参考官方接口，没有复制仓库实现）

- Apple ReplayKit：https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler
- Apple局域网隐私：https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- Apple ActivityKit：https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- OpenAI图像请求：https://developers.openai.com/api/docs/guides/images-vision
- Anthropic图像请求：https://platform.claude.com/docs/en/build-with-claude/vision
- Gemini图像请求：https://ai.google.dev/gemini-api/docs/generate-content/image-understanding

## 中文与系统输入法

HID键盘只发送US ASCII，不提供中文Unicode直输。用户可在安全搜索框里自行切到系统拼音输入法，用手动ASCII面板输入拼音，再观察并选择候选；候选出现、焦点、键盘布局与指针可见性必须真机验收。此版本不承诺自动拼音候选流程，不自动发送外部通讯。
