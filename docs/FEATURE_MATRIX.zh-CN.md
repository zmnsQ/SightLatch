# HIDPilot 功能与验收矩阵（2026-10-15）

这是现有实现的核对表，不是“全部功能完成”的承诺。原生代码未在Apple SDK下编译或真机运行。源码契约检查只确认若干结构/保护分支存在；C++主机测试只运行实际固件共用的键码及计时函数。

| 用户流程 | 实际代码链路 | 本轮证据与待验收 | 缺失/限制 |
|---|---|---|---|
| 设置与模型配置 | App/HomeView.swift、WorkspaceViews.swift → PilotViewModel.save → Shared/SharedStore.swift / Keychain | provider及参数验证、写盘失败路径有源码检查；持久化/Keychain待真机 | 不自动提供API key或服务额度 |
| 系统跨应用屏幕广播 | 系统RPSystemBroadcastPickerView → Broadcast/SampleHandler.swift → 帧缩放/指纹/节流 | 三target及扩展结构检查；ReplayKit采集和指针入帧待真机 | 用户必须主动发起；无法保证受保护画面可采集 |
| 截图→AI单步决策 | SampleHandler → Shared/Network.swift AIClient.propose → ActionProposal → SafetyGate | 有实际HTTP请求和响应解析，不是假模型；未调用真实API | 依赖视觉模型能力；风险标注与关键词不是可靠安全边界 |
| 多API | Network.swift的responses、openai兼容chat、anthropic、gemini分支 | provider白名单源码检查；四家实际联网/限流/错误语义待用户API验证 | 完整endpoint由用户配置；兼容网关须显式确认视觉能力 |
| AI→局域网硬件 | HardwareClient.status/send → /v1/action →固件任务队列→回执轮询 | boot/session/sequence/期限及完成态真实代码；未端到端执行 | 不重试有副作用动作；只限受信LAN HTTP，非端到端加密 |
| BLE HID固件 | firmware/IPhoneHIDBridge/Bridge.cpp、ProtocolPrimitives.h | 共用键码/计时函数主机编译运行PASS；ESP32整包编译、BLE配对、同机操作待验 | ESP32-S3指定配置；相对键鼠，非绝对触控注入 |
| 配对与凭据 | 物理长按ARM开配对窗口；短按ARM会话；config.example.h；iOS共享Keychain | 未包含真实config.h；秘密忽略规则检查 | Wi-Fi/控制token由用户本地填；BLE Just Works非MITM防护；未提供App内写入Wi-Fi配置 |
| 手动校准 | WorkspaceViews/HomeView → PilotViewModel.manual → HardwareClient → BLE | 准备/校准/停止互斥源码检查；真实位移/点击/滚动待硬件验 | 依赖系统指针和输入焦点；不支持中文Unicode直输、多指手势 |
| 急停/取消 | 主App、LiveActivityIntent、广播结束 → session条件更新+STOP →轮询ARM/busy；固件物理STOP | STOP确认/未确认分支及命令修改检查；跨进程压力与硬件断网待验 | 已到硬件的动作无法撤销；网络STOP不能替代物理按钮 |
| 档案/历史/待办 | Workspace.swift保存档案、串行任务队列、历史同步；WorkspaceViews展示与操作 | 写入失败源码检查；完整UI状态恢复待真机 | 12档案/100历史有界；队列人工启动，不是无人值守批量执行 |
| 后台与实时活动 | 默认Broadcast扩展；可选App/ContinuedSession.swift；Shared/PilotIntents.swift；Widget/PilotWidget.swift | 完整实现有界后台任务与租约，不是占位保活；全部系统行为待真机 | 5分钟、6秒租约、45秒无帧等限制；不是永久后台；默认扩展无法保证Live Activity连续刷新 |
| 故障恢复与导入导出 | Workspace.swift、SharedStore恢复副本、PilotViewModel恢复动作 | 损坏存储保护/失败不假成功源码检查；真实磁盘失败待验 | 两文件保存不是跨文件事务；不保证安全擦除恢复副本 |
| ChatGPT等订阅登录/额度 | 未实现订阅OAuth或额度复用；设置只提供合法API/用户自管兼容端点 | 明确不可用 | 不抓Cookie、不逆向账号会话、不假装订阅登录已接通 |

本地编译、运行和逐项故障验收请依照根目录 CURRENT_VALIDATION_20261015.zh-CN.md。所有API、系统后台、BLE及真机完整闭环在本轮均未证实可运行。
