# ESP32 驱动同一台 iPhone：HID 组件核查

核查日期：2026-10-14。仅云端读取官方文档、GitHub README 和源码；没有安装、编译、刷机、配对或真机测试。下面把源码事实、作者自述和待验证推断分开。

## 结论与推荐

可以把 ESP32 当成外接键鼠执行端，手机自己发送控制命令。首选验证顺序是：ESP32-S3 + 标准 BLE 鼠标/键盘 + 同局域网 WSS 控制；成功后再验证自定义 GATT 与系统 HID 共用同一个外设；USB HID 作为 S3 的备用路径。这里没有电脑充当运行期控制中枢。但固件开发/初次刷机仍然是独立准备工作。

HID 只解决执行出口，不保证 ReplayKit 扩展、AI 推理和控制连接能在其他 App 前台时持续运行。尤其不能把前台 App 已连接 CoreBluetooth 当成它退后台后仍能无限执行计算/网络循环的证明。

Apple 明确支持 iPhone 通过 AssistiveTouch 使用有线或蓝牙指针；这为鼠标路线提供官方依据，但不构成对任意 ESP32 描述符或 iOS 版本的认证。[Apple 指针设备说明](https://support.apple.com/en-us/111775)

## 真实项目与源码结果

### 1. Espressif 官方 esp-idf：长期底座，推荐

- 仓库：[espressif/esp-idf](https://github.com/espressif/esp-idf)。查询到最近提交 2026-10-12，`ab95e70748f2eddac6f87217b0cf62533684a6ba`。这是仓库活动时间，不是 HID 文件最近修改时间。
- [BLE HID 主程序](https://github.com/espressif/esp-idf/blob/master/examples/bluetooth/esp_hid_device/main/esp_hid_device_main.c)：读到 Bluedroid/NimBLE 分支、键盘/鼠标 report map、`esp_hidd_dev_input_set`、连接/断开/挂起处理。可复用报告发送、描述符和生命周期；不是完整 iPhone agent，也没有现成手机命令协议。
- [USB TinyUSB 示例](https://github.com/espressif/esp-idf/blob/master/examples/peripherals/usb/device/tusb_hid/main/tusb_hid_example_main.c)：同一 HID report descriptor 同时声明 keyboard/mouse。可复用 USB 枚举和报告发送。
- 仓库 [LICENSE](https://github.com/espressif/esp-idf/blob/master/LICENSE) 为 Apache-2.0；以上两个示例文件的 SPDX 是 `Unlicense OR CC0-1.0`。分发时仍要检查依赖、组件各自许可证。
- 不能直接把示例的 demo 自动发键/音量循环放入产品；需改成默认不执行、收到授权命令才发送。

### 2. asterics/esp32_mouse_keyboard：最有价值的 Apple 兼容参考

- [仓库/README](https://github.com/asterics/esp32_mouse_keyboard)；最近提交 [7c63616](https://github.com/asterics/esp32_mouse_keyboard/commit/7c63616b2da1c24ebe24509a44fcfa3aa4f575ed)，2026-09-08，提交说明为升级 IDF 6.1、缩短默认名称避免 iOS 长名称问题。README 仍写测试 IDF 5.0，说明文档与代码可能不同步，应锁定提交做验证。
- 作者报告 iPad Air 2 / iPad Pro / iPad 6 等 iOS 13.x 的 AssistiveTouch 鼠标与键盘测试；不能延伸为当前所有 iPhone 已验证。
- 已读 [main/ble_hidd_demo_main.c](https://github.com/asterics/esp32_mouse_keyboard/blob/master/main/ble_hidd_demo_main.c)。包含 UART 命令解析、配对控制、已配对设备和连接管理；源码特别指出 iPhone HID 加密时序及报告订阅时序；advertising appearance 用 mouse `0x03c2`，注释指出 generic 在部分 iOS 不工作。
- 可复用兼容经验与 HID/连接管理；它的入口是 UART，不是手机直连 GATT/WSS，所以仍需替换控制入口。
- 许可证存在粒度差异：仓库显示 [GPL-3.0 LICENSE](https://github.com/asterics/esp32_mouse_keyboard/blob/master/LICENSE)，主文件声明 GPL v2-or-later 并保留原始示例公共领域说明。不能简单标 MIT，也不应在未厘清许可时整包拷入闭源产品。
- 默认 bond + no-input/no-output，不等于具备 MITM 防护。

### 3. h2zero/NimBLE-Arduino：自定义 GATT + HID 的搭建材料

- [仓库](https://github.com/h2zero/NimBLE-Arduino)，Apache-2.0；最近查询提交 [c22a209](https://github.com/h2zero/NimBLE-Arduino/commit/c22a209335d0b701ec45e0e41d37c7922bab8130)，2026-09-13。
- 已读 [src/NimBLEHIDDevice.cpp](https://github.com/h2zero/NimBLE-Arduino/blob/master/src/NimBLEHIDDevice.cpp)：构造函数接收既有 `NimBLEServer*`，在其上创建 Device Information、HID `0x1812`、Battery 服务。这直接说明 HID 不必独占整个 server。
- 已读 [NimBLE_Server.ino](https://github.com/h2zero/NimBLE-Arduino/blob/master/examples/NimBLE_Server/NimBLE_Server.ino)：同一个 server 创建多个服务，支持 `onWrite`、`WRITE_ENC`、加密完成检查、配对回调。
- 因此固件可以在同一 server 再增加自定义 128-bit service：command write + result notify，统一队列驱动 HID。这是源码支持的组合推断，不是已找到的完整同机 iPhone 项目。
- 手机此时是 BLE central，ESP32 是 peripheral；手机的 App 写自定义 characteristic，手机系统接 HID 通知，数据双向不需要切换 GAP central/peripheral 角色。GATT client/server 与 GAP 角色也不应混为一谈。
- 同一 iPhone 的系统 HID 与 CoreBluetooth 是否稳定共用连接、发现与配对顺序、广播停止后的找回、App/ReplayKit 扩展生命周期，必须在目标 iOS/硬件实测。不要假设 App 能直接访问系统 HID 服务。[Apple CoreBluetooth central 官方流程](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/PerformingCommonCentralRoleTasks/PerformingCommonCentralRoleTasks.html)

### 4. tensimiku/esp32-wifi-websocket-bt-hid：已具备 Wi-Fi→BLE 桥接结构

- [仓库](https://github.com/tensimiku/esp32-wifi-websocket-bt-hid)，根许可证 MIT；主文件还保留 Espressif `Unlicense OR CC0-1.0` SPDX。最近提交 [1d4e265](https://github.com/tensimiku/esp32-wifi-websocket-bt-hid/commit/1d4e265a204a8abec13a9b7704196ae6cba41d22)，2026-07-21。
- 已读 [main/esp_hid_device_main.c](https://github.com/tensimiku/esp32-wifi-websocket-bt-hid/blob/main/main/esp_hid_device_main.c) 的 composite map、`wifi_init_sta`、`ws_handler`、`send_mouse`、`send_keyboard`、HTTPS server。
- 一张 report map：键盘 ID 1、鼠标 ID 2；WSS 文本命令解析后调用 `esp_hidd_dev_input_set`。C3 为作者指定目标，带 S3 配置文件。可以借鉴通信/命令分发，不是 iPhone 已验证成品。
- 具体审查发现：README 声称 sub-20ms，但前端 mouse/touchmove 有 100ms 节流，键盘发送还有 50ms delay；不能引用为端到端低延迟测量。
- `ws_handler` 用每帧密码比较；未见该处理器限定最大 frame 长度或命令序号/过期时间；鼠标输入直接强转 char，应在服务端检查范围。
- `/pair` POST handler 直接重新广告，未见此 handler 做密码验证，日志却写 payload verified。不能因为 README 写 secure 就当成安全成品。
- 自签证书浏览器警告的 README 做法不适合作为默认产品流程；应用应使用可验证/固定证书等设计，不能静默关闭证书验证。还需硬件配对按钮、速率限制、会话认证与失联释放。

### 5. blackketter / alexz006 ESP32-BLE-Combo：简单但老，许可需澄清

- [blackketter](https://github.com/blackketter/ESP32-BLE-Combo) 最近提交 2020-05-28；[alexz006 fork](https://github.com/alexz006/ESP32-BLE-Combo) 最近提交 2023-02-23。alexz006 README 自述 iPhone 13 Pro Max 测试成功，同时提示部分设备有问题。
- 已读 [BleComboKeyboard.cpp](https://github.com/blackketter/ESP32-BLE-Combo/blob/master/BleComboKeyboard.cpp) 与 [BleComboMouse.cpp](https://github.com/blackketter/ESP32-BLE-Combo/blob/master/BleComboMouse.cpp)：一个 server、三个 report ID（键盘/媒体/鼠标），鼠标 5 字节，X/Y/wheel 为相对 signed 8-bit，keyboard 使用 `_asciimap[128]`。
- alexz006 的 [BleCombo.cpp](https://github.com/alexz006/ESP32-BLE-Combo/blob/master/BleCombo.cpp) 可选 NimBLE，但不代表兼容当前 NimBLE 2.x/Arduino-ESP32 版本。
- 仓库页面未见独立许可证、`LICENSE` 查询 404，library.properties 不声明许可。仅作参考，不能把源码公开等同可无限制复用。

### 6. Mystfit/ESP32-BLE-CompositeHID：可组合，但不能当作 iPhone 已验证

- [仓库](https://github.com/Mystfit/ESP32-BLE-CompositeHID)，[MIT](https://github.com/Mystfit/ESP32-BLE-CompositeHID/blob/master/license.txt)，最近提交 2026-05-05。
- 已读 [BleCompositeHID.cpp](https://github.com/Mystfit/ESP32-BLE-CompositeHID/blob/master/BleCompositeHID.cpp)：动态拼接设备 report map，`onStarted(pServer)` 是加自定义服务的钩子；安全配置明确为 bonding=true、MITM=false、SC=false，需改。
- README 明确标 iOS 不兼容。其“不具 MFi”解释不能泛化成所有标准 BLE 鼠标都必须 MFi；Apple 官方本就允许辅助蓝牙鼠标。这里的决策只是：这个库不能按其 README 当成支持 iPhone 的现成底座。

### 7. 绝对坐标候选：shplishka/ESP32-BLE-Abs-Mouse-ios

- [仓库](https://github.com/shplishka/ESP32-BLE-Abs-Mouse-ios)，最近查询提交 2022-01-17；未确认明确许可证，根 `LICENSE` 返回 404。
- 已读 [BleAbsMouse.cpp](https://github.com/shplishka/ESP32-BLE-Abs-Mouse-ios/blob/master/BleAbsMouse.cpp)：实际是 Digitizer/Touch Screen/单 Stylus collection，Tip Switch + In Range + 16-bit X/Y 0..10000，并不是把普通鼠标报告改成像素坐标。
- README 自述兼容 iOS，但未给当前 iPhone/iOS 型号与成功矩阵；没有多 contact ID/独立多指轨迹。只能列实验候选，不能承诺通用绝对触摸注入，也不能据此保证免 AssistiveTouch。

## 型号选择：不要被板载 USB-C 误导

| 芯片 | BLE 键鼠 | 原生 USB HID device | 方案位置 |
|---|---|---|---|
| 经典 ESP32 | 可以，兼有 BR/EDR 与 BLE | 无 USB OTG | 已有硬件做 BLE 原型 |
| ESP32-C3 | 可以，BLE | 自带 USB 是固定 Serial/JTAG，不能改 HID | 成本敏感、只做 BLE |
| ESP32-S3 | 可以，BLE | 有 USB OTG，可 TinyUSB keyboard+mouse | 推荐，可比较 BLE/USB 两种输出 |

依据：[Espressif 芯片比较](https://docs.espressif.com/projects/esp-idf/en/v5.0/esp32s3/hw-reference/chip-series-comparison.html)、[USB 外设表](https://docs.espressif.com/projects/esp-iot-solution/en/latest/usb/usb_overview/usb_overview.html)、[C3 固定 USB 功能](https://docs.espressif.com/projects/esp-idf/en/v4.4.6/esp32c3/api-guides/usb-serial-jtag-console.html)。S3 板上必须接原生 USB 数据口，而不是 USB-UART 桥接口；iPhone 是 host，S3 是 HID device。

USB 模式仍可用 Wi-Fi 或 BLE GATT 接收手机命令，不能假设 iOS App 能把任意 USB CDC 串口当控制链路。Lightning/USB-C 转接、供电、线材、锁屏附件限制都要实测。

## 同机链路设计与限制

1. **优先最小验证：同一 LAN Wi-Fi→ESP32→BLE HID→同一 iPhone。** ESP32 运行 STA，手机原生客户端发 WSS。避免把一个前台网页当成跨 App 长驻 agent。官方 S3 共存表对 STA connected + BLE connected 标稳定支持，但单射频时分共享，仍有竞争；SoftAP connected + BLE 是性能不稳定类别，所以不要直接把 AP-only 当首选。[Espressif RF 共存](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-guides/coexist.html)
2. **纯 BLE 后续优化：自定义 GATT 与 HID 同 server。** 省局域网、无需 ESP32 扫描手机服务。iPhone app 管命令服务，系统管 HID。广播字段容量、服务 UUID 发现、系统配对后重新连接必须验证。无需两个独立 BLEDevice::init；把两个独立 keyboard/mouse 库分别 begin 通常不是可靠组合方式。
3. **USB 备用：Wi-Fi/GATT→S3→USB HID。** 用官方 TinyUSB 示例，可隔离 BLE HID 与控制服务共享的问题，但仍不是任意触摸接口。

### 动作模型应诚实表达

- 相对鼠标 `move(dx,dy)` 的单位是 HID counts，不能直接等同截图像素。iOS tracking speed/加速、边缘裁剪、旋转、分辨率都影响换算。应小步移动、读回画面确认；ReplayKit 是否捕获指针本身也须实测，否则需要额外定位方法。
- 单击、按住、释放、滚轮有明确 HID 表达。拖拽可用 button-down→连续 move→button-up，但系统长按阈值、应用交互、Drag Lock 会改变含义。滚轮不等于按给定曲线滑屏；滚动惯性需要闭环确认。
- Home/App Switcher/通知中心可通过 AssistiveTouch 菜单或用户映射的按钮动作探索，不能假设任意消费类 Home key 在 iOS 的行为相同。
- 多指不能由普通 mouse descriptor 直接表达。Apple AssistiveTouch 提供预设多指及用户录制手势，但这不是任意两根手指可独立控制的自动化 API。[Apple AssistiveTouch 手势说明](https://support.apple.com/en-us/111794)
- 标准 keyboard HID 发键位，不发 Unicode 字符串。中文需要匹配 iPhone 输入法、拼音/候选选择等闭环；ASCII `.print("中文")` 不可用。剪贴板跨 App 写入/粘贴是另一种机制，不能由 HID 单独完成。第一版限制英文数字并明确输入法状态。

## 安全与可靠性：建议的新增设计，非现有库保证

- 硬件物理 ARM/STOP；默认 disarmed；只有持有当前会话且设备仍 armed 才接受动作。急停清空队列并发送所有键/按钮释放，必要时断开 HID。单独板载按钮不依赖 iPhone 当前前台 App。
- 命令带 session ID、递增序号、短 TTL、最大持续时间；过期画面对应的动作拒绝执行。ACK 区分收到/执行/画面验证，HID notify 成功不代表点击目标已实现。
- 心跳超时/断网/蓝牙断开/广播结束立即清空状态；重新连接不重放旧动作。键盘修饰键、媒体键、鼠标各自都要发送零报告，不能只清内部变量。
- 配对只在物理按钮短窗口开放；绑定目标手机；控制 characteristic 需加密并做会话授权。Just Works bonding 不能宣传为抗 MITM；有合适显示/输入硬件时再考虑 passkey/numeric comparison。不要仅凭 MAC 名称或设备名称鉴权。
- 限制命令大小、频率、dx/dy/wheel、按住时长、队列长度；不执行网络传来的任意脚本。屏幕内容和键入内容不默认记录到串口日志。
- 高风险界面、支付、发送、删除等应由上层策略要求人确认；HID 层没有业务语义，无法天然阻止误点击。

## 实测验收清单

1. 目标 iPhone/iOS + S3：系统配对、AssistiveTouch、键盘与鼠标同时工作、重连/重启。
2. 手机给板发指令的同时，系统继续收板的 HID；前台换到其他 App，确认执行链仍活着。
3. GATT/HID 同连接版本和 Wi-Fi/BLE 版本分别测试；不要用其中一条成功推断另一条。
4. ReplayKit 画面包含/不包含指针、旋转、键盘出现、弹窗、受保护画面、帧滞后。
5. 点击 3×3 目标、长按、拖动、滚轮、快速/慢速滚动；量化成功率而不是只拍 demo。
6. 输入法英文/中文、软键盘显示、键盘组合键；USB 转接和供电单独矩阵。
7. 拔电/断链/应用退出/广播结束/超时后无卡键、无旧指令重放；物理急停可抢占。

总体判断：可复用材料充足，最稳的工程承诺是“有条件的外接键鼠闭环”，不是“已解决无越狱 iPhone 的任意触摸注入”。
