# SightLatch：第一次安装与使用

这份指南对应仓库现有代码和界面。先完成“手机安装 → 硬件配对 → 手动测试”，最后再启动 AI。源码尚未通过 Apple SDK 编译、签名安装或 ESP32 / iPhone 实机联调；遇到报错请保留具体错误，不要把下面的步骤当作已验证兼容承诺。

## 先准备这些

- 一台用于 Xcode 的 Mac，以及 Xcode 26 或更新的兼容版本。本项目已经包含 Xcode 工程，不需要额外项目生成器。
- 一部自己的 iPhone。工程部署下限是 iOS 18；完整液态玻璃界面需要 iOS 26。两个系统版本的真机效果都尚未验证。
- ESP32-S3 开发板、支持数据传输的 USB 线，以及两个常开按钮。先核实具体板子的 GPIO 引脚图。
- iPhone 与 ESP32 可互通的可信、最好隔离的局域网；板子需要 2.4 GHz Wi-Fi。
- 可用的 Apple 开发签名，以及支持图片输入的模型 API。ChatGPT 等聊天产品的订阅不是 API 额度。

整体路径：iPhone 的屏幕广播扩展取得图像 → 选定的 AI API 分析 → iPhone 通过局域网向 ESP32 发单步指令 → ESP32 通过蓝牙 HID 操作同一部 iPhone。没有要求 Mac 常驻转发；Mac 用于编译、安装和烧录。

## 1. 把 App 安装到 iPhone

1. 拉取仓库，在 `ios/Config/` 内复制 `Local.example.xcconfig` 为 `Local.xcconfig`。后者已被 Git 忽略，不要提交签名文件或个人配置。
2. 在这个本地文件填写自己的 `DEVELOPMENT_TEAM`，并设置你实际拥有的唯一 `PILOT_BUNDLE_PREFIX`、`PILOT_APP_GROUP` 和 `PILOT_KEYCHAIN_GROUP`。Keychain 值保留 `$(AppIdentifierPrefix)`，不要凭猜测替换成 Team ID。示例中的 `com.yourcompany` 必须换成自己的注册标识。
3. 用 Xcode 打开 `ios/HIDPilot.xcodeproj`，选择共享 scheme **HIDPilot**。内部工程名仍是 HIDPilot，安装后显示 **SightLatch**，无需因此重命名工程。
4. 在 `HIDPilot`、`HIDPilotBroadcast`、`HIDPilotWidget` 三个 target 的 Signing & Capabilities 中选择同一个 Team。三个 target 使用相同 App Group；主 App 与 Broadcast 使用相同 Keychain access group。确认这些能力已在开发者账户和签名 profile 中生效。免费个人签名是否支持所需能力，以 Xcode 的实际结果为准。
5. 选择连接的 iPhone，构建并运行主 App；它会嵌入两个扩展。如系统要求开发者模式、设备信任或签名信任，由你按系统提示完成。首次启动前先解锁手机。

如果编译失败，记录 Xcode 版本、首个完整错误和 target 名称。不要为了绕过错误删除 App Group / Keychain 权限，它们是扩展共享状态所必需的。

## 2. 烧录 ESP32-S3

1. 在 Arduino IDE 安装 **Espressif Arduino-ESP32 3.3.5** 和 **ArduinoJson 7.0.4**，选择 **ESP32S3 Dev Module**。本固件使用该核心的 Bluedroid BLE；不要混入 NimBLE 库。USB、Flash、PSRAM 选项按你的具体板卡配置。
2. 打开 `firmware/IPhoneHIDBridge/IPhoneHIDBridge.ino`，同目录的 `Bridge.cpp` 会参与构建。
3. 复制 `config.example.h` 为 `config.h`，仅在本地填写 Wi-Fi 名称、密码和至少 32 字符的随机 `CONTROL_TOKEN`。不要把密码或 token 发到聊天、提交到 GitHub。占位配置不会开放 HID 执行。
4. 断电后接两个常开按钮：默认 STOP 为 GPIO4 与 GND，ARM 为 GPIO5 与 GND，使用内部上拉。必须先对照开发板引脚定义；若这些引脚不适用，在本地配置里修改。
5. 编译、上传，打开 115200 波特率串口查看设备局域网 IP。也可从路由器的 DHCP 列表确认。详细接线、配置与协议见 [固件说明](../firmware/README.md)。

默认硬件处于 DISARMED，不能执行动作。设备控制使用局域网明文 HTTP；不要做公网端口映射，也不要在不可信公共 Wi-Fi 使用。

## 3. 让 iPhone 识别蓝牙鼠标

1. 长按物理 ARM 约 2 秒，打开约 30 秒的配对窗口。
2. iPhone 设置 → 辅助功能 → 触控 → 辅助触控，开启辅助触控，在“设备 / 蓝牙设备”中查找 **LocalHID** 并配对。具体菜单名称可能随 iOS 变化。
3. 确认连接及系统指针后，短按 ARM（至少约 60 ms）才允许执行，授权窗口最多 5 分钟。
4. 按 STOP 会停止并解除 ARM；恢复执行必须再次物理 ARM。断连不会自动重新广播。已连接时长按 ARM 会先断开，需要释放后再次长按来重新打开配对窗口。

本版本是 BLE 相对鼠标 / 键盘，不能当成任意绝对坐标触控注入，也没有多指手势。配对采用 Just Works，不提供强中间人防护。

## 4. 在 App 配好连接

打开右上角“设置”，进入“连接与安全”：

- 设备地址填写 `http://hidbridge.local`，或刚查到的私网 IPv4，例如 `http://192.168.1.50`。设备 Bearer Token 必须与固件的 `CONTROL_TOKEN` 相同。
- 点击“保存并检查局域网 / BLE”，在前台按系统提示允许局域网访问。看到检查失败时先排查网络、地址、token、蓝牙状态，不要直接开始 AI。
- “协议”选择实际使用的服务，填完整 HTTPS 请求 URL、支持视觉的模型 ID 和 API Key。密钥在 App 本地输入，保存在设备 Keychain。

常见请求 URL：

- OpenAI Responses：`https://api.openai.com/v1/responses`
- OpenAI 兼容：你获准使用的 HTTPS 地址，以 `/v1/chat/completions` 为例
- Anthropic Messages：`https://api.anthropic.com/v1/messages`
- Google Gemini：`https://generativelanguage.googleapis.com/v1beta/models/你的模型ID:generateContent`

Gemini 使用 URL 中的模型 ID；切换协议不会自动更改 URL。更换端点时重新输入对应密钥。兼容服务还需要确认它支持图片且你有权使用。

只有理解并同意后，才打开“同意将广播中的屏幕截图发给上述端点”。图像会发送给该模型服务，可能产生 API 费用，并受其数据保留政策影响；不是纯本地 AI 推理。项目目前没有 ChatGPT / Codex 或第三方订阅账户登录、额度转换功能。

第一次保持“允许低风险导航点击和搜索框 ASCII 输入”关闭，也保持可选“有界后台会话”关闭。

## 5. 先验证一小步，再开 AI

1. 保持自动会话停止，按物理 ARM。
2. 在主页点“指针校准”，进入“指针实验台”。先只测试一个方向的移动，确认系统指针确实移动。
3. 确认指针在本地安全靶心上，再试“左键点击”，检查计数。不要在消息发送、支付、删除或权限按钮上测试。
4. 验证物理 STOP 可以阻止后续动作，再重新 ARM。输入测试只支持最多 64 个可打印 US ASCII 字节，不支持直接输入中文 / emoji。

手动操作正常不等于 AI 能正常定位指针。ReplayKit 是否把系统指针录进画面需要真机验证；如果没有指针图像，当前自动控制路径可能无法使用。

## 6. 第一次 AI 会话

1. 打开不含私人资料的静态文章，准备一个很小的任务，例如“向下滚动一点，观察后停止”。不要从登录、购物或社交发布开始。
2. 回到 SightLatch 填写任务，首次可把最大步数调小。物理 ARM 后点击“准备会话”。
3. 点击中间的系统屏幕广播按钮，手动选择 **SightLatch Broadcast** 并开始广播，然后返回目标 App。
4. 持续观察手机和“动作记录”。默认谨慎模式仅自动相对移动 / 滚动；点击、键盘、输入需要人工处理。会话最多 5 分钟，默认 20 步、上限 50 步。
5. 完成后点 App 停止按钮，并结束系统屏幕广播；确认硬件解除 ARM 后再打开敏感页面。软件停止状态不确定时，使用物理 STOP 或直接断开 ESP32 电源。

灵动岛 / Live Activity 用于显示状态，不意味着主 App 永久保活。默认工作由广播扩展承担；系统仍可能暂停或终止。截图过期、网络异常、模型不确定或风险判断会暂停，不会自动重试旧动作。“我已手动处理，继续观察”表示重新观察，不会重放原先被拦截的动作。

## 遇到问题时

- **广播列表没有 SightLatch Broadcast**：检查主 App 是否成功安装、扩展是否嵌入、签名和 App Group 是否一致。
- **局域网检查失败**：确认同一可互通网络、App 的局域网授权、设备 IP 和 token；先不要排查模型。
- **BLE 已连但不能动**：检查物理 ARM、STOP 接线、授权是否过期；不要修改安全检查强行执行。
- **模型报错**：检查协议、完整 URL、视觉模型、该端点专用 key 和 API 余额；不要把 key 放进报错截图。
- **画面上传却没有动作**：检查是否能在广播画面中定位系统指针、是否谨慎模式暂停、是否截图过期。安全检查是必要条件，但不能保证模型永不误判。
- **需要反馈**：提供系统 / Xcode / 板卡版本、当前步骤、脱敏错误与动作日志。不要附 API Key、设备 token、Wi-Fi 密码或敏感屏幕内容。

相关资料：[iOS 详细说明](../ios/README.md) · [固件说明](../firmware/README.md) · [当前验证边界](../CURRENT_VALIDATION_20261015.zh-CN.md)
