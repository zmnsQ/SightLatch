# SightLatch iOS 源码原型

**状态：这是功能流程继续完善后的开发源码版本。iOS App仍未完成Apple SDK编译、签名安装或真机运行验证；Linux实际检查与xtool尝试请看根目录验证报告。不能把Linux工具能运行、源码解析或工程引用检查当作iOS构建成功。未使用用户电脑或手机。**

## 2026-10-15 增量

本轮修复持久化假成功、准备/停止/校准竞态、跨进程命令更新、配置白名单、广播终止撤销与STOP确认。损坏本地数据会阻止保存，可在工作区确认后先保留副本再重置；不删除Keychain。更改端点/协议必须重新同意上传。旧编译尝试仅为历史，本轮未编译Swift。完整变更及验收见 `../CURRENT_VALIDATION_20261015.zh-CN.md`。

签名建议复制 `Config/Local.example.xcconfig` 为Git忽略的 `Config/Local.xcconfig` 后填写，覆盖公共默认值，避免后续pull冲突。

## 既有功能

- 首启引导与共享存储、Keychain、模型、局域网、BLE、ARM、指针和上传许可检查；检查项明确区分本地配置与实际设备快照。
- 最多12个模型档案，端点绑定凭据；切换端点重新确认上传。独立自管兼容网关入口，仅配置不联网，不伪装订阅OAuth。
- 最多100条任务记录、保存/载入/人工完成/移回队列/删除。队列只排序，不自动开始下一任务或恢复旧动作。
- 错误恢复分类、JSON非秘密设置导入导出、脱敏诊断导出；没有自动把日志发到外部服务。
- 系统/浅色/深色主题、系统动态字体和按钮辅助功能标签。校准支持10/50/100相对单位与本地安全靶心计数。
- Live Activity公开AppIntent刷新与停止按钮；可选iOS26有界后台任务模式见下文。


## 工程与系统

打开 `HIDPilot.xcodeproj`，选择共享 scheme `HIDPilot`。包含：

- HIDPilot：SwiftUI 主 App，任务主页、状态卡、iOS 26 原生 Liquid Glass 底栏、分层设置与人工校准面板。
- HIDPilotBroadcast：ReplayKit Broadcast Upload Extension，`RPBroadcastSampleHandler` 处理视频帧，不处理音频。
- HIDPilotWidget：WidgetKit Live Activity / Dynamic Island 展示。

使用 Xcode 26 或更新的兼容 Xcode / iOS SDK（源码调用 iOS 26 glassEffect，需要对应SDK才能编译）。部署下限18.0是为了可用性降级，不表示已验证18或26.5.2；代码不依赖任何iOS27功能。目标设备为iPhone。没有第三方Swift依赖、没有复制无许可证仓库源码。已包含原创 AppIcon 与深浅色品牌标记；尚未提供 App Store 上架素材。

### 签名需要你修改

1. 在本地 `Config/Local.xcconfig` 把 `PILOT_BUNDLE_PREFIX` 改成你拥有的唯一前缀，比如 `com.yourcompany.HIDPilot`，并修改 `PILOT_APP_GROUP`。
2. 同步修改 `PILOT_KEYCHAIN_GROUP` 的后缀，保留 `$(AppIdentifierPrefix)`；前缀并不一定总等于Team ID，请以签名配置为准。
3. 在三个target选择同一开发者Team。App Group在开发者后台及三个target启用相同值。主App与Broadcast必须启用同一个Keychain access group；Widget不读取密钥。
4. 确认生成的 entitlements/provisioning profile 确实包含这些组。个人免费签名可能不满足这些能力；能否使用需以你的开发者账号和Xcode实际结果为准。
5. 安装主App时会嵌入两个扩展。设备首次解锁后才能读取共享凭据。Keychain使用 `AfterFirstUnlockThisDeviceOnly`，不云同步；卸载App并不保证删除Keychain内容。

**API与设备凭据只存Keychain**，按provider+完整endpoint、device URL分别绑定。更换端点时需重新填写密钥；这避免把旧/新凭据误发给不同端点。配置、任务、最多100条动作元数据/暂停原因存App Group；默认扩展直连模式不保存截图，只在内存中编码并发送；可选后台协调模式会短暂保存一份最新截图到受保护且排除备份的App Group文件（覆盖并在结束时删除），不是安全擦除保证。云端截图保留策略仍由供应商控制。日志可能包含用户任务推导的简短理由，不要填敏感任务。

## 用户自己执行的首次验收步骤（本次未执行）

1. 按固件README烧录ESP32-S3；在可信、最好隔离的Wi-Fi中配置唯一随机设备Token。打开iPhone设置配对ESP32的BLE HID设备，必要时开启辅助触控；确认有系统指针。
2. 在App“连接与安全”填写 `http://hidbridge.local` 或设备私网IPv4、对应Token。先在前台点击“保存并检查局域网 / BLE”，按系统提示允许局域网访问。后台扩展不能可靠触发首次授权。
3. 模型选择：OpenAI Responses、OpenAI-compatible Chat Completions、Anthropic Messages、Google Gemini generateContent。填写完整HTTPS URL、模型ID和你自己的API Key。必须使用支持图片的模型。
4. 示例端点：OpenAI `https://api.openai.com/v1/responses`；兼容 `https://你的域名/v1/chat/completions`；Anthropic `https://api.anthropic.com/v1/messages`；Gemini `https://generativelanguage.googleapis.com/v1beta/models/你的模型ID:generateContent`。Gemini实际模型以URL为准。切换协议不会自动改URL，请一并修改。Anthropic额外workspace header暂未支持。没有内置OAuth或订阅token转换；自管兼容网关可填HTTPS端点，但协议、视觉能力、授权范围和条款由你确认。
5. 阅读屏幕上传说明并明确同意。未配置/未同意不会运行AI；没有伪造“端侧大模型”。ChatGPT等产品订阅和API额度不能混为一谈。
6. 停止自动会话后，物理ARM，再打开“指针实验台”。先用上下左右100单位移动，观察方向/距离；可记录每100单位像素估计。点击、滚动、Esc、ASCII输入按钮会发真实HID操作，仅在安全页面试。AI不使用这组数字伪装精确绝对坐标。
7. 填一个无风险导航任务。初次建议保持谨慎模式：仅自动相对移动/滚动。需自动普通导航点击/搜索框ASCII输入时，另外明确启用“低风险导航”。
8. 物理ARM，点击“准备会话”，再点中间系统广播按钮，手动选SightLatch Broadcast并开始广播。返回目标App。扩展会延迟数秒等新帧。
9. 观察日志：观察→思考→执行→新帧观察；截图不可定位指针/模型不确定/画面变化/超时/错误都暂停。**系统指针是否出现在ReplayKit截图中没有保证，这可能让本版本无法自动移动或点击，需要你实际确认。**
10. 先验证物理急停；再验证App停止按钮、系统停止广播、网络中断、AI错误、锁屏/广播暂停、硬件重启/断连和最大步数。严禁用交易、外部通讯、密码或敏感表单作测试场景。

## 闭环与安全约束

- 扩展直接完成帧缩放（最长768px、JPEG 0.55）、至少2秒节流、单个AI请求和局域网HTTP。主App不需要在后台接收截图，也没有远程服务器转发硬件指令。
- 广播回调只接收视频；每300ms最多排一帧的32x32轻量指纹处理。AI请求时仍更新当前画面指纹；执行前要求近期新帧且粗缩略差异较小。这个检测可能漏掉小按钮/文字改变，**不是目标身份保证**。
- 默认截图有效15秒，上限20秒；AI慢于限制会暂停，不放宽后盲执行。HTTP响应流限制1MB，截图编码不超过600KB；真正ReplayKit内存上限与耗电仍需真机测量。后台协调模式每秒暂存一帧，需额外测量文件I/O与内存。
- AI返回严格单个JSON动作，无工具执行代码、无批量动作。相对move幅度±100，scroll±3；click仅左键；文本最多64个可打印US ASCII字节。中文HID直接输入、剪贴板注入、系统键盘切换、绝对tap、可靠归零home和AI拖动未实现。
- 低风险模式可点击导航、输入明确搜索框ASCII、按Esc/方向键；AI永不自动Enter。default review模式暂停click/key/text，由用户手动完成。
- purpose/risk/requiresConfirmation、置信度、指针可见性和本地关键词白名单共同限制动作。高风险、未知风险、发消息、发布、付款、购买、删除、权限、密码等暂停；用户回App确认的是“已手动处理，重新观察”，**不是批准重放旧动作**。物理重新ARM后才可继续。
- 这些策略依赖不完美的模型判断与词匹配，可被误判或截图提示注入绕过。它们不构成安全保证。只用于你持续看管的无风险任务，不能无人值守控制真实账户。
- 运行中禁止修改配置/凭据；先停止会话。上传许可撤回通过停止生效；不要在尚未结束广播时切到敏感页面。
- 停止/暂停会取消当前Task并尽力POST `/v1/stop`。已经到达硬件的操作无法撤销；进程被系统强杀时软件stop不保证送达。固件物理急停、有限TTL、ARM期限是必要独立保护。
- 每个会话最多5分钟、最多50步（默认20），失败不重试动作。没有后台音频hack、私有API、或永久保活承诺。

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

新增锁屏/展开灵动岛的“刷新”和“停止”按钮采用公开 `LiveActivityIntent`。用户点击时系统可在主App进程执行一次操作，不需要打开App界面；刷新只读取AppGroup最新快照，停止先撤销会话命令、再尽力请求硬件停止并检查ARM状态。停止请求不会直接藏掉Activity以冒充停止成功。锁屏交互可能需要系统验证解锁。

### 可选：iOS26 BGContinuedProcessingTask有界会话

设置中明确启用后，用户前台点“准备会话”提交 `.fail` 策略的系统任务。只有handler实际启动并写出有效租约后，App才提示准备完成；系统拒绝或5秒未启动则取消，不静默排队执行。

此模式不是空轮询保活：主App后台任务真实执行云AI、单步安全核验、局域网硬件调度和下一帧验证；ReplayKit每秒覆盖一份最新帧到App Group供其读取。文件使用完整文件保护并排除备份，退出会话后删除。若系统同时异常杀死相关进程，文件可能暂时遗留；App下次启动会清理无有效租约的旧帧，准备新会话前也清理旧帧。这不是安全擦除或崩溃时即时删除保证。启用前需额外同意本地暂存截图。截图不在诊断或设置导出中。

任务更新系统进度、阶段标题，并在仍获准执行时更新自定义Activity。最长5分钟/最多50步，等待广播45秒超时。任务每秒续一份6秒执行租约；系统expiration立即撤销共享命令，网络Task取消，清帧并尽力停止硬件。主App被强退可能没有回调，扩展检测租约失效后停止采集/广播并清帧；已到达硬件的动作仍只能靠固件TTL与物理急停约束。

系统可能拒绝、终止或节流任务与Live Activity；具体在iOS26.5.2同机HID+ReplayKit组合中是否能工作仍未验证。没有GPU权限申请，没有后台音频，没有无限重提任务。后台模式遇到暂停/风险会结束整个任务，人工处理后必须重新ARM并准备/开始广播，不恢复旧动作。

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
