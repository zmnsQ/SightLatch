# iPhone 本机编排 → ESP32 HID 自控制：GitHub 源码检索报告
检索日期：2026-10-14 UTC。范围：只读公开仓库、源代码和官方文档；未安装、编译、执行、烧录或操作任何手机。提交日期来自 GitHub commits API，不把 pushed_at 当最新源码提交日期。用户手机版本：iOS 26.5.2。

## 结论
本轮没有找到能够由源码与可复现实机证据共同确认的完整成品，严格满足：
用户主动 ReplayKit 广播 → 手机本地处理画面 → 手机与可选云端/端侧模型交互 → 手机自己决定并直接下发 ESP32 → HID 操作同一手机 → 新画面验证。

发现两个最值得研究的近似项目：
1. **boboabw/phone-agent**：手机本机 AI 编排与 BLE→ESP32→iPhone 闭环代码最接近，但画面是 **iOS 27 ScreenCaptureKit**，完全不是目标 ReplayKit 路线。不能在 iOS 26.5.2 原样用。
2. **nyc-design/ChromaCatch-Control**：真有 ReplayKit 扩展和手机→ESP32 Wi-Fi 指令代码；但屏幕传给 backend，App 接 backend 指令后转发，缺手机本地 AI 编排。它是模块参考，不是目标整套成品。

其余常被推荐的 esp32-iphone-agent / VersaiOS 都由电脑控制 ESP32，明确不满足要求。公开可读源码不等于已有开源复用授权；前三个非 MIT 候选的许可缺口需特别注意。

## 1. boboabw/phone-agent：最接近手机本机 Agent，系统版本不符
仓库：https://github.com/boboabw/phone-agent
最新默认分支提交：[a900450，2026-10-06 17:07:40Z](https://github.com/boboabw/phone-agent/commit/a90045074afcd4de69f885fba25b0b171d690f45)，主题为添加逐步 iPhone 演示 GIF 和全程视频。
许可：GitHub API license=null；递归文件树未找到 LICENSE/COPYING。**没有核实到明确的开源许可证**。
README 声明要求 iOS 27、Xcode 27、ESP32-S3、ESP-IDF 5.5.4、视觉模型 HTTPS endpoint、AssistiveTouch、配对及指针校准。板级配置 4 MB Flash、GPIO48 WS2812；USB 供电，运行输入通过 BLE。

### 源码直接证实
- [CaptureService.swift L6–7、L94–170](https://github.com/boboabw/phone-agent/blob/a90045074afcd4de69f885fba25b0b171d690f45/PhoneAgent/Services/CaptureService.swift#L94-L170)：import ScreenCaptureKit；SCContentSharingPicker 的 display 选择器建立 SCStream。仓库没有 ReplayKit Broadcast Upload Extension。
- [同文件 L195–285](https://github.com/boboabw/phone-agent/blob/a90045074afcd4de69f885fba25b0b171d690f45/PhoneAgent/Services/CaptureService.swift#L195-L285)：处理像素 buffer；在手机上限速约 4 FPS、最长边缩放、JPEG quality 0.72，保留捕获时间和确认时间。
- [AgentEngine.swift L202–240](https://github.com/boboabw/phone-agent/blob/a90045074afcd4de69f885fba25b0b171d690f45/PhoneAgent/Services/AgentEngine.swift#L202-L240)：要求新鲜整屏帧，最多等 6 秒；校验 captureID、尺寸及画面差异。
- [AgentEngine.swift L349–392](https://github.com/boboabw/phone-agent/blob/a90045074afcd4de69f885fba25b0b171d690f45/PhoneAgent/Services/AgentEngine.swift#L349-L392)：观察→模型下一动作→再次核对画面→MouseExecutor 执行→等待→再次观察。处理重复动作、用户确认/暂停和停止。
- [VisionClient.swift L122–137](https://github.com/boboabw/phone-agent/blob/a90045074afcd4de69f885fba25b0b171d690f45/PhoneAgent/Services/VisionClient.swift#L122-L137)：手机将 JPEG base64 和任务发送到配置模型 HTTP API；**这证明手机调用模型，不是模型服务器直接控制 ESP32**。当前实现是网络模型调用，不是已实现端侧视觉推理。
- [BLETransport.swift L146–183](https://github.com/boboabw/phone-agent/blob/a90045074afcd4de69f885fba25b0b171d690f45/PhoneAgent/Services/BLETransport.swift#L146-L183)：iPhone CoreBluetooth 将命令写入配件 GATT characteristic，包含序列号、错误检查和写超时。
- [firmware/main/main.c L73–79、L155–177](https://github.com/boboabw/phone-agent/blob/a90045074afcd4de69f885fba25b0b171d690f45/firmware/main/main.c#L73-L177)：控制连接和 HID 连接分开跟踪，BLE HID notification 发鼠标/键盘 report；代码显式考虑 iOS AssistiveTouch 与 App CoreBluetooth 两路连接。
- [main.c L432–469](https://github.com/boboabw/phone-agent/blob/a90045074afcd4de69f885fba25b0b171d690f45/firmware/main/main.c#L432-L469)：标准 HID service 0x1812 与自定义 control service 同时存在。

### 宣称、官方事实与待测
README 放有任务演示；[verification.md L27–69](https://github.com/boboabw/phone-agent/blob/a90045074afcd4de69f885fba25b0b171d690f45/docs/verification.md#L27-L69)自行报告离线测试、Xcode 27 编译及某次 iPhone 14 安装，但明确区分编译/安装与 BLE、跨 App、后台实机验收；画面有效期修复仍待真机验证。不能将这些记录升级为我们亲测或用户手机可运行。
Apple 官方[Capturing screen content on iOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios)当前资料说明 iOS 27+，审阅时页面标记 Beta；另一研究分支已核实。它不能满足 iOS 26.5.2。不能仅因仓库写了 Xcode27 或官方新文档存在，就推断已正式发布、用户能升级或所有设备后台稳定。
若坚持 ReplayKit，须重做采集进程、App/Extension 数据与执行归属，以及后台生命周期，而非替换一行 import。

## 2. nyc-design/ChromaCatch-Control：ReplayKit + 手机直连硬件模块齐，但决策在后端
仓库：https://github.com/nyc-design/ChromaCatch-Control
默认分支最新提交：[3299b15，2026-03-04 22:02:36Z](https://github.com/nyc-design/ChromaCatch-Control/commit/3299b1573007ea91100ea745be3b18b2b084926e)，仓库 pushed_at 为 2026-03-16，二者不同。
许可：API license=null，未核实到覆盖整仓库的开源授权。涉及内嵌 BLE 库还需独立核对第三方许可。
硬件：[platformio.ini](https://github.com/nyc-design/ChromaCatch-Control/blob/3299b1573007ea91100ea745be3b18b2b084926e/services/esp32/platformio.ini)选用 esp32-s3-devkitc-1、NimBLE，固件支持 BLE / USB HID 输出与 Wi-Fi HTTP/WS 输入。

### 源码直接证实
- [SampleHandler.swift L1–52](https://github.com/nyc-design/ChromaCatch-Control/blob/3299b1573007ea91100ea745be3b18b2b084926e/services/ios-app/ChromaCatchController/ChromaCatchBroadcast/SampleHandler.swift#L1-L52)：确为 RPBroadcastSampleHandler；App Group 读取 backend URL，创建 H264Encoder 与 BroadcastWSClient，将压缩帧发后端。
- [SampleHandler.swift L72–94](https://github.com/nyc-design/ChromaCatch-Control/blob/3299b1573007ea91100ea745be3b18b2b084926e/services/ios-app/ChromaCatchController/ChromaCatchBroadcast/SampleHandler.swift#L72-L94)：processSampleBuffer 对 .video 调 encoder.encode，非仅 README 宣称。
- [ESP32HTTPClient.swift L62–106](https://github.com/nyc-design/ChromaCatch-Control/blob/3299b1573007ea91100ea745be3b18b2b084926e/services/ios-app/ChromaCatchController/ChromaCatchController/Networking/ESP32HTTPClient.swift#L62-L106)：手机直连 ESP32，WebSocket 优先，HTTP POST /command 回退。
- [AppCoordinator.swift L579–611](https://github.com/nyc-design/ChromaCatch-Control/blob/3299b1573007ea91100ea745be3b18b2b084926e/services/ios-app/ChromaCatchController/ChromaCatchController/AppCoordinator.swift#L579-L611)：接 HIDCommandMessage 后调用 esp32Client.sendCommand，并向 wsManager 回 ACK。文件开头也说明 backend→wsManager→ESP32。
- [main.cpp L492–543](https://github.com/nyc-design/ChromaCatch-Control/blob/3299b1573007ea91100ea745be3b18b2b084926e/services/esp32/src/main.cpp#L492-L543)：设备将 move/click/drag 转成 BLE 鼠标操作。
- [main.cpp L1045–1112](https://github.com/nyc-design/ChromaCatch-Control/blob/3299b1573007ea91100ea745be3b18b2b084926e/services/esp32/src/main.cpp#L1045-L1112)：HTTP/WS 收命令并执行。

### 与目标的精确差距
“手机直接向 ESP32 发包”这一段成立，但 App 是后端命令的转发器，视频上后端；已阅执行路径没有手机本地观察/模型调用/决策/验收环。因此不满足“服务器只能是可选模型，不能控制硬件”的严格控制权约束。可参考采集与直连模块；需要新建手机端编排和资源/生命周期方案。未验证同机环路、多分钟后台、联网中断恢复，也未核查整个仓库其他功能安全性。

## 3. onehumanbeing/esp32-iphone-agent：完整桌面闭环，排除为目标成品
仓库：https://github.com/onehumanbeing/esp32-iphone-agent
提交：[1f6a51a，2026-10-13 16:19:49Z](https://github.com/onehumanbeing/esp32-iphone-agent/commit/1f6a51aa3d7bdb3f12024693a559cd5b5f2b9c28)。许可：[MIT](https://github.com/onehumanbeing/esp32-iphone-agent/blob/1f6a51aa3d7bdb3f12024693a559cd5b5f2b9c28/LICENSE)。
硬件 README 声明测试 Seeed XIAO ESP32-S3；USB 接 iPhone，Wi-Fi 连电脑；USB-C 手机直连，Lightning 要适配器；需 macOS/Linux 电脑。
- [screen.py L1–43](https://github.com/onehumanbeing/esp32-iphone-agent/blob/1f6a51aa3d7bdb3f12024693a559cd5b5f2b9c28/server/hidagent/screen.py#L1-L43)实际启动 UxPlay/GStreamer 接 AirPlay，不是 ReplayKit 手机本地帧。
- [device.py L27–70](https://github.com/onehumanbeing/esp32-iphone-agent/blob/1f6a51aa3d7bdb3f12024693a559cd5b5f2b9c28/server/hidagent/device.py#L27-L70)电脑 Python TCP server 直接写控制命令。
- [hid_bridge.ino L1–27、L132–152](https://github.com/onehumanbeing/esp32-iphone-agent/blob/1f6a51aa3d7bdb3f12024693a559cd5b5f2b9c28/hardware/hid_bridge/hid_bridge.ino#L132-L152)ESP32 连 SERVER_HOST，通过 USB mouse/keyboard 执行。
- [agent.py](https://github.com/onehumanbeing/esp32-iphone-agent/blob/1f6a51aa3d7bdb3f12024693a559cd5b5f2b9c28/server/hidagent/agent.py)在电脑实现 planner/actor、画面变化检查。
用途：可参考校准、动作后验证与错误恢复。不能把“手机浏览器能访问控制页”解释成“手机拥有闭环控制”。本研究未实测 README 视频或性能数字。

## 4. zhaodashuaibi/VersaiOS：桌面串口控制，排除
仓库：https://github.com/zhaodashuaibi/VersaiOS
提交：[5619a23，2026-08-10 09:54:06Z](https://github.com/zhaodashuaibi/VersaiOS/commit/5619a233a124df80b01477239d2bc60797c41998)。许可 API=null，未核实整仓授权。
硬件：README 宣称 ESP32-S3 BLE mouse，由电脑 USB serial 供指令，iPhone AssistiveTouch 接 BLE。
- [main_versaios.py L53–56](https://github.com/zhaodashuaibi/VersaiOS/blob/5619a233a124df80b01477239d2bc60797c41998/src/main_versaios.py#L53-L56)打开串口。
- [L86–121](https://github.com/zhaodashuaibi/VersaiOS/blob/5619a233a124df80b01477239d2bc60797c41998/src/main_versaios.py#L86-L121)抓桌面投屏窗口→模型计划→串口写 CLICK。此 CLI 是逐条指令/单次目标点流程，不能按名称自动称其完整自治多步闭环。
- [VersaiOS.ino L49–80](https://github.com/zhaodashuaibi/VersaiOS/blob/5619a233a124df80b01477239d2bc60797c41998/hardware/esp32_ble_mouse/VersaiOS.ino#L49-L80)Serial 读命令并 bleMouse.click。
缺 ReplayKit、手机本机编排、手机直发硬件。

## 5. KoStard/ESPRemoteControl：手机→ESP32→USB HID 部件参考
仓库：https://github.com/KoStard/ESPRemoteControl
提交：[4135f1b，2026-01-25 17:35:53Z](https://github.com/KoStard/ESPRemoteControl/commit/4135f1bcc524442f0938d443178c5e2e5d1e5950)。许可 API=null，未核实整仓授权。
硬件：ESP32-S3 native USB；原目标为电脑/电视，非已验证同一 iPhone。
- [BLEKeyboardBridge.swift L56–83](https://github.com/KoStard/ESPRemoteControl/blob/4135f1bcc524442f0938d443178c5e2e5d1e5950/ESPRemoteControl/BLEKeyboardBridge.swift#L56-L83)：iPhone TLV 命令经 CoreBluetooth writeValue 发送。
- [sketch L165–230](https://github.com/KoStard/ESPRemoteControl/blob/4135f1bcc524442f0938d443178c5e2e5d1e5950/sketch_uid_keyboard_ble/sketch_uid_keyboard_ble.ino#L165-L230)：BLE onWrite 解包；[L299–311](https://github.com/KoStard/ESPRemoteControl/blob/4135f1bcc524442f0938d443178c5e2e5d1e5950/sketch_uid_keyboard_ble/sketch_uid_keyboard_ble.ino#L299-L311)启动 USB HID。
没有画面、AI 或闭环；能参考双通路传输代码，不能据此断言回控同机/后台执行已支持。

## 6. ReplayKit 纯采集参考：twilio/video-quickstart-ios
仓库：https://github.com/twilio/video-quickstart-ios
最新默认分支提交：[92a766f，2026-07-21 08:32:48Z](https://github.com/twilio/video-quickstart-ios/commit/92a766f9bc4da3336a58923833b14ce78e974aab)；[MIT LICENSE](https://github.com/twilio/video-quickstart-ios/blob/92a766f9bc4da3336a58923833b14ce78e974aab/LICENSE)。
[ReplayKitExample/BroadcastExtension/SampleHandler.swift L10–17、L140–154](https://github.com/twilio/video-quickstart-ios/blob/92a766f9bc4da3336a58923833b14ce78e974aab/ReplayKitExample/BroadcastExtension/SampleHandler.swift#L140-L154)证实扩展收到 sampleBuffer 并交给视频源。原例连接 Twilio 房间，没有 ESP32 或 AI；可以参考正确的扩展结构，不能直接照搬发送外部视频的默认行为。仓库最新提交时间也不等于这个历史示例最近做了 iOS 26.5.2 验收。

## 其他已筛掉的线索
- ja1chen/actell：当前 README 明确 CoreDevice 调试协议和 VPN loopback/USB NCM，开发者模式、配对、DDI；保留的 ScreenCaptureKit/PA3 USB HID 是旧路线，并非当前默认。当前也要求 iOS27。没有找到符合本任务的 ReplayKit 成品，不能把 ESP32 NCM 网络桥称为 HID 控制。[当前仓库](https://github.com/ja1chen/actell)、[历史路线记录](https://github.com/ja1chen/actell/blob/e701786d1686823f9ab60524e689e387b7c3b904/archives/history/docs/usb-device/NO-PSK.md)
- handzlikchris/Glasscast：phone mode 已做 Android，iOS ReplayKit+ESP32 仅在架构文档列为可能路线并明确 not planned，没有实现。[文档](https://github.com/handzlikchris/Glasscast/blob/2563354ce91e4fd3ed620aef5397470ad42fc5fd/architecture/phone-mode.md)
- JiangNanGenius/floe-agent 有 RPBroadcastSampleHandler，但仓库 ESP32 搜索无命中，不能当作 HID 闭环。

## 搜索方法与边界
先用公开网页搜索 iPhone / ReplayKit / ESP32 / HID / agent 组合，再用 GitHub code search（例如 RPBroadcastSampleHandler ESP32、ReplayKit ESP32、RPBroadcastSampleHandler agent language:Swift）反查，并读候选完整树与关键路径。RPBroadcastSampleHandler ESP32 当时仅命中 ChromaCatch 两个说明文件，因此进一步追进实际源码。搜索会漏掉未索引、不同命名、私有仓库或新提交；“本轮未找到”不等于数学上不存在。
同一文件内多关键词搜索不是跨仓库能力证明；本报告每个正面结论均由具体实现链路支持。

## 建议选型
维持用户原始架构，不改成电脑/服务器控制硬件：
- iOS 26.5.2 先用 ReplayKit Broadcast Upload Extension 验证画面输入；
- 参考 Phone Agent 的手机端状态机、帧新鲜度与 BLE 双连接实现思想，但先处理许可证且不能直接依赖其 iOS27 采集；
- 如采用 Wi-Fi→ESP32、BLE HID→iPhone，可参考 ChromaCatch 的本地设备 API；移除后端命令控制，手机仅把截图按需发模型，自己验证返回并签发限次动作；
- 第一阶段应测同机链路、App 退后台后的真实执行、扩展内存/网络/蓝牙可用性与停止释放。未通过这些实测前，不把“组合部件齐全”承诺为完整可用产品。

