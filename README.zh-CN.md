# HID Pilot iOS 与 ESP32 增强源码工程

原始交付日期 2026年10月14日。本轮已补齐模型档案、引导、任务历史、配置迁移、恢复、诊断、校准、Live Activity操作，以及可选iOS26有界后台AI/硬件调度。源码在助手云端编写；没有访问你的电脑或手机。

你随后授权Linux构建验证：官方xtool已实际运行，但缺Apple SDK且当前Xcode工程未迁移SwiftPM，未编译出iOS安装包；Arduino CLI实际运行，官方依赖索引下载遇环境网络阻塞，固件未编译。项目结构检查与独立源码复查已执行，详见 `LINUX_VALIDATION.zh-CN.md` 与 `STATIC_REVIEW.zh-CN.md`。这些检查不等于Swift类型检查、真机验收或生产就绪。
## 2026-10-15 本轮增量优先说明

本轮继续完善原生iOS App、ReplayKit、Widget与ESP32源码，没有换成网页原型。原生编译、签名安装、同机HID与ReplayKit真机验证由你完成；本轮没有安装Apple SDK、没有刷机或调用付费模型。旧 `LINUX_VALIDATION.zh-CN.md` / `STATIC_REVIEW.zh-CN.md` 是历史记录，不是本轮PASS。

新增修复：
- 准备、手动校准、停止互斥；准备失败撤销已创建会话，任务记录落盘失败不再冒充准备完成。
- 配置/档案/导入持久化错误会显示失败；损坏配置阻止静默覆盖，工作区提供用户确认后的“保留旧文件副本并重置”。
- 共享命令采用跨进程文件锁与按session ID更新，避免旧回调覆盖新会话；恢复只递增当前仍有效命令，不复活已停止命令。
- STOP收到202后继续验证硬件解除ARM且无在途动作，界面明确区分确认与未确认；Widget本地写盘失败也会尝试硬件STOP。
- 默认广播终止也直接撤销会话；旧会话不能覆盖新会话状态；端点/协议变化撤销上传同意，设备变化撤销校准快照。
- provider白名单与有限数值/范围验证、设备地址四段校验、硬件boot ID复核；固件文本拒绝LF/TAB等控制字符。

本轮可复现验证及真机清单：`CURRENT_VALIDATION_20261015.zh-CN.md`。已运行8项源码/结构检查和C++主机逻辑测试；这不是Swift类型检查或完整固件编译。

后续更新前，把签名配置放在不入库的 `ios/Config/Local.xcconfig`（复制同目录 `Local.example.xcconfig`），固件秘密放在 `firmware/IPhoneHIDBridge/config.h`。两个文件都被Git忽略，拉取源码不会覆盖它们。不要提交密钥、证书或真实配置。

## 从这里开始

1. 阅读 `ios/README.zh-CN.md`（如目录内名为README.md，以该文件为准），用Xcode打开 `ios/HIDPilot.xcodeproj`，按文档修改签名团队、bundle ID、App Group和Keychain共享组。主App、广播扩展、实时活动扩展需要一致的共享配置。
2. 阅读 `firmware/README.md`，确认你的开发板是文档指定的ESP32-S3，按板型检查引脚。配置模板中的Wi-Fi与设备控制令牌由你自己本地填；包内没有真实凭据。
3. 先完成你自己的编译与最小硬件测试，再配置模型、局域网权限、屏幕广播与相对指针校准。完整步骤见两端README。不要一开始就在支付、通讯录或真实业务应用里试。
4. 若遇错误，反馈首个完整编译错误、系统/SDK/板型版本及脱敏日志；不要发送API key、Wi-Fi密码、设备token、签名凭据或私人屏幕内容。

## 架构

用户主动开始ReplayKit屏幕广播 → 广播扩展取得跨应用帧并在手机上缩放/筛选 → 手机直接请求用户配置的多模态模型 → 手机校验单动作 → 手机通过本地Wi-Fi HTTP直接给ESP32-S3发命令 → ESP32以BLE HID键鼠操作同一iPhone → 下一帧重新观察。

没有远端服务器直接控制ESP32；没有直播平台推流。若你配置云端AI，精选截图、任务文字会发送到该模型服务，必须先明确同意，不能把“不公开直播”描述成“所有数据绝不出手机”。这一版未内置端侧视觉模型。

## 写入的功能

- iOS26基线原生SwiftUI、Liquid Glass主页与分层设置；三target工程及共享scheme。
- ReplayKit采集、单次模型请求、精选帧、图像变化粗检、步骤上限、停止/超时/过期暂停。
- OpenAI Responses、OpenAI兼容Chat Completions、Anthropic Messages、Gemini图片请求适配；模型与endpoint由你配置，API key保存共享Keychain。
- 默认谨慎模式与显式启用的低风险导航模式；未知风险、指针不可辨认、敏感意图等停止。模型风险分类和关键词过滤不是安全保证。
- 手动相对指针/按键校准面板、执行状态、日志。
- ESP32-S3键鼠固件、HTTP协议、物理ARM/STOP/配对窗口、会话/序号/期限检查、单任务与释放全部。
- Live Activity与Dynamic Island布局、用户点击刷新/停止的LiveActivityIntent。
- 首次使用检查、12个模型档案、100条任务历史、人工串行待办、配置JSON导入导出、脱敏诊断、分类恢复、主题与动态字体。
- 默认关闭的iOS26 BGContinuedProcessingTask：主App实际承担AI与LAN调度，ReplayKit只提供最新帧；包含6秒执行租约、五分钟会话上限、系统取消、过期动作拒绝与暂存帧清理。

## 重要限制

- 同一手机接收自己的BLE HID、ReplayKit能否捕获指针、目标系统后台循环与内存等均未实测。现机26.5.2不能照搬iOS27 ScreenCaptureKit例程。
- 本版是相对鼠标控制，不是绝对触点注入。没有中文HID直输、多指手势、任意应用100%自动操作。看不清指针就应停止，不能靠想象坐标乱点。
- 默认扩展模式仍不能保证Live Activity后台逐步更新；新增可选continued模式用真实有界后台工作更新活动。系统接纳、回收、强退与后台刷新仍待真机验证，不能保证永久运行。此模式临时将最新帧写入受文件保护的App Group，界面单独说明并征求同意；异常退出后的残留在下次启动/准备会话时清理，不声称即时安全擦除。
- 本地HTTP+Bearer为原型方便性选择，令牌与命令在LAN明文传输；仅限隔离受信网络，不可映射公网或用于不可信共享Wi-Fi。BLE Just Works不是MITM防护。
- API接口代码不等于任意模型都能可靠看图或遵循结构化动作。未调用付费模型。云端AI的费用和服务权限由你自行确认。
- 未实现原生ChatGPT订阅登录、WorkBuddy/TRAE/Coding Plan额度复用。报告列了实际第三方项目与边界；你自管兼容网关可配置为endpoint，但是否可用、允许用于此用途、是否支持图片须由相应服务实际条件确认。没有抓Cookie或借用凭据。
- 未部署服务器、未开放端口、未购买服务、未生成或获取你的凭据。

## 目录

- `ios/`：主App、ReplayKit扩展、实时活动扩展与Xcode工程。
- `firmware/`：ESP32-S3原创固件、配置模板、协议和烧录说明。
- `docs/调研与原型设计说明.docx`：第一阶段研究报告；其中旧实现状态以当前两端README和验证记录为准。
- `docs/research/`：详细公开证据、仓库固定提交与模型适配调查。
- `STATIC_REVIEW.zh-CN.md`：源码静态检查记录及残余风险。

项目暂名HID Pilot，可在你确定正式名字后修改。代码以本包原创实现为主，研究中未发现许可证的仓库只参考公开机制，没有复制其实现。系统SDK及框架、Arduino库等外部依赖沿用各自许可证，详见两端说明。

## 功能逐项核对

见 `docs/FEATURE_MATRIX.zh-CN.md`，列出每项源码入口、已验证范围、未实现能力与用户本机验收要求。
