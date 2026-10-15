# ESP32-S3 本地 HTTP → BLE 键鼠原型

**2026-10-15增量：主机C++测试已覆盖原固件提取出的ASCII映射与计时回绕；没有编译完整ESP32固件。详见根目录 `CURRENT_VALIDATION_20261015.zh-CN.md`。**

**历史基线状态：只写了源码、对照官方头文件做人工自查。未安装依赖，未编译，未运行，未刷机，未配对，未做任何真机测试。不能承诺直接可用。**

## 安全边界先读

- 这个原型使用明文 HTTP + Bearer token。令牌、键入文本和动作在局域网可被窃听/修改；没有 TLS，也没有 HMAC 请求签名。仅在你控制的隔离受信 Wi-Fi 上实验，不要连接公共/共享不受信网络，不要做端口转发，不要暴露互联网，不要输入密码或其他敏感数据。
- BLE 使用 Secure Connections bonding + NoInputNoOutput（Just Works）。它不是 MITM-resistant 配对。物理配对窗口降低误配风险，但不提供强身份保证；附近攻击者仍可能抢先配对。第一次配对时核对手机正在连接正确板子。未经验证不要用于真实支付、发消息、删除等后果大的界面。
- 接受动作只说明加入固件单任务槽；HID 发送完成也不证明 iPhone 确实执行或点中了目标。上层必须读屏确认。
- 双按钮急停与状态机是软件设计，非安全认证。可拔掉板子电源作为独立硬停。系统崩溃/无线栈失效时，不能保证 release 报告送达。

## 目标与依赖（仅说明，未执行）

- ESP32-S3 开发板，有空闲 GPIO4、GPIO5；有 USB 数据线用于你自己刷写。
- Arduino-ESP32 **3.3.5**，ESP32S3 Dev Module，默认 **Bluedroid**。本源码使用该版本官方 `BLEDevice/BLEHIDDevice/BLESecurity/WebServer/WiFi` API；不支持把 NimBLE-Arduino 同时混进来。
- ArduinoJson **7.0.4**。未验证更高/更低版本。Arduino IDE 可从 Library Manager 指定版本安装。
- 入口草图 `IPhoneHIDBridge.ino` 为空容器，实际实现 `Bridge.cpp` 与之同目录，由 Arduino 同时编译；这样避免自动函数原型生成与自定义类型顺序冲突。
- 具体 flash/PSRAM/USB 设置以板卡型号为准；BLE 原型不需要 PSRAM。不提供臆测的通用烧录地址。
- 原型源码为本次新写；没有拷贝未明确授权的 Combo 库。Arduino-ESP32 的依赖/许可证以官方发行版为准；ArduinoJson 为 MIT，分发依赖时保留其 notices。标准 HID report map 根据键盘/相对鼠标格式写入。

官方 API 核查来源：
- [3.3.5 BLEHIDDevice.h](https://github.com/espressif/arduino-esp32/blob/3.3.5/libraries/BLE/src/BLEHIDDevice.h)
- [3.3.5 BLEServer.h](https://github.com/espressif/arduino-esp32/blob/3.3.5/libraries/BLE/src/BLEServer.h)
- [3.3.5 BLESecurity.h](https://github.com/espressif/arduino-esp32/blob/3.3.5/libraries/BLE/src/BLESecurity.h)

## 用户本地准备

1. 先检查板卡引脚图。把两个常开按钮分别接 `STOP_GPIO`、`ARM_GPIO` 与 GND，使用 INPUT_PULLUP。默认 GPIO4/5 只是配置起点；若板上占用、接外设或不可用，先改。不要冒用 flash/PSRAM/strapping/BOOT 管脚。
2. 把 `IPhoneHIDBridge/config.example.h` 复制为同目录 `config.h`。
3. 填 2.4GHz Wi-Fi SSID/password；设置你自己生成的至少32个不可预测ASCII字符 token，并在 iOS 配置同一个 token。不要把这些秘密发到聊天或提交到版本库。示例占位符会使固件停住而不启用 HID。
4. 在 Arduino IDE 打开 `IPhoneHIDBridge/IPhoneHIDBridge.ino`；由你安装上述官方依赖，选正确板卡/端口，先编译，再按开发板文档上传。我们未执行这些步骤。
5. 115200 串口只显示启动信息和 LAN IP，不输出 Wi-Fi 密码、token、键入内容。需要不占用用户手机的另一台开发设备用于初次刷写/读取 IP；运行期无需服务器/电脑，手机直接与板子通信。也可从你路由器的 DHCP 列表获取 IP。
6. 手机和板子加入同一个受信 LAN。iOS App 配置 `http://hidbridge.local` 或 `http://板子IP` 与 token。固件用 mDNS 公布 hidbridge.local；若路由器禁用组播或有多块同名板，改用实际私网IP。
7. 板子默认 DISARMED，默认不广播。长按 ARM **2秒** 打开 **30秒** BLE 接入窗口；在 iPhone 的设置→辅助功能→触控→辅助触控→设备→蓝牙设备中选择 LocalHID，并开启 AssistiveTouch。
8. 连接且加密成功后，短按 ARM（至少60ms）启用执行；每次启用创建新的 session_id，有效 **5分钟**。先在安全的空白测试页面/备忘录验证小移动、点击与英文字母。
9. 按 STOP 或 POST /v1/stop 急停后必须再次物理短按 ARM。短按 ARM 在已 armed 时也会解除。BLE断开后不自动广播、不自动恢复；长按重新开放连接。如果长按时仍连接，首次长按会先断开，需松开再长按开放窗口。

注意：初次绑定/加密流程、iOS 的 CCCD 订阅和重连均未真机验证；显示 hid_connected=true 只表示固件观察到成功加密连接，不表示 iOS 已正确订阅全部输入报告。更换 report map 后可能需要手机忘记设备并重配。

## v1 HTTP 合同

所有请求都需要 `Authorization: Bearer <CONTROL_TOKEN>`。不启用 CORS；这不是浏览器远程网页服务。HTTP响应 `Cache-Control: no-store`。

### GET /v1/status

返回：

```json
{"ok":true,"boot_id":"opaque-32hex","uptime_ms":12345,"armed":true,
 "hid_connected":true,"ble_connected":true,"session_id":"opaque-32hex",
 "next_sequence":1,"max_ttl_ms":5000,"busy":false,
 "last_action_id":"","last_action_state":"none","last_error":"",
 "pairing_open":false,"transport_security":"plaintext_http_trusted_lan_only"}
```

- boot_id 每次板子启动变；session_id 每次物理 ARM 变。客户端读取它们，不自己生成 session_id。
- uptime_ms 是板子 uint32 毫秒时钟。客户端在取得 status 时同时记自己的 monotonic clock；issued_at_ms 用该 uptime 加本地经过时间，按 uint32 处理。每次动作前刷新 status 是最简单实现。
- 时钟不依赖 NTP/互联网。最多允许250ms未来偏差；网络延迟导致宁可提前过期。不要把 Unix 时间戳放进 issued_at_ms。
- last_action_state：none / queued / running / completed / aborted。只有最后一项，单客户端串行使用，不支持多客户端同时竞争控制。

### POST /v1/action

```json
{"id":"client-generated-UUID","boot_id":"from-status","session_id":"from-status",
 "sequence":1,"issued_at_ms":12345,"ttl_ms":1500,"type":"move","dx":10,"dy":0}
```

- sequence 从 status.next_sequence 读，接受后加1；拒绝不消耗序号。id长度8..64；建议 UUID。仅一个进行中 job；busy返回409。
- ttl_ms 1..5000。接受时和执行每步都检查到期。长文本至少需要 `50*字节数+100ms` 剩余时间；建议客户端用 `max(1500,50*长度+500)`，最多5000。
- move：dx/dy 整数 -127..127，相对 counts，非截图像素。
- click：button=1左、2右、4中；按下40ms后自动释放。
- scroll：wheel -127..127；滚动方向/比例待真机标定。
- key：key 为 HID Keyboard usage 整数4..101；modifiers可选0..255；按下40ms后释放。不是字符Unicode。例 key=40 是 Enter。
- text：1..64 ASCII字符，仅 US 布局映射；仅支持可打印ASCII（32–126）；拒绝LF/TAB/CR及所有控制字符，避免文本隐式提交或跳焦点；不支持中文、emoji。逐字按下25ms/释放25ms；中文必须上层输入法候选选择，本固件不冒充已实现。
- drag：button=1/2/4，dx/dy -127..127，duration_ms 100..1000；分20ms步长相对移动并自动释放。不是绝对坐标滑动、多指或手势曲线。
- release_all：释放键盘和鼠标；同样遵守session/序号/单在途规则。取消进行中job要用 stop，而不是 release_all。

新接受返回 HTTP202：`{"ok":true,"id":"...","accepted":true,"duplicate":false,"state":"queued","next_sequence":2}`。

最近16项保留幂等记录。相同id、sequence和**原始JSON字节串**重发只返回已有状态，不执行第二次；同id但不同payload返回409。比缓存更老的包也因单调sequence被拒绝。协议虽防重复，客户端仍应不自动重试动作：若响应丢失，查status的id/状态，无法判定时人工处理或stop。

completed只表示发送工作已完成；上层仍要新的读屏帧确认效果。TTL到期可能已经执行前半段动作/文本，此时会release并返回aborted状态，不会自动补写或重放。

### POST /v1/stop

任意body（建议 `{}`），仍要求Bearer；不要求session/sequence，以便状态未知时急停。HTTP202 `{ok:true,stop_requested:true}`，安全任务稍后解除并释放；客户端轮询 status 确认 armed=false。只有物理ARM可恢复。

### 错误

400 invalid_json/invalid_action_or_non_ascii/invalid_envelope；401 unauthorized；408 expired_or_future/insufficient_ttl_for_action；409 session_mismatch/sequence_mismatch/id_payload_conflict/busy；413 body_size；423 not_armed；429 rate_limited；503 hid_or_wifi_unavailable。

最大动作请求正文1024字节，接受间隔至少50ms（20次/秒）；这是应用层上限。Arduino WebServer 会先读取请求再交给handler，因此它不是抗恶意HTTP大包/慢请求的加固服务器。

## 实现的失效策略与剩余风险

- 独立安全任务以10ms设计周期检查物理STOP、BLE状态、Wi-Fi状态、5分钟ARM租期，执行有界job；主HTTP handler不会长时间sleep等键。无线栈notify/锁等待仍可阻塞，因此不保证10ms急停或硬实时。
- 按住状态仅在40ms click/key或最多约1秒drag内存在；不开放任意key-down永久持有接口。text最多64字节有TTL。
- 断线清队列、撤销session、不重放。连接存在时发送零报告释放；已断线时无法保证设备收到释放，重新ARM先发送零报告。
- 无永久目标手机白名单；每次连接必须有物理窗口，可有其他附近主机抢先。不能宣传为只有某一iPhone可连接。只允许一个当前连接，其他连接会拒绝。
- 配对SC、报告CCCD、特定iOS键盘与鼠标组合兼容、并发回调和看门狗行为都仍待用户实际验证。
- 未实现USB HID、自定义GATT控制、Wi-Fi配置门户、OTA、TLS、HMAC、中文直输、绝对坐标、多指。研究报告里的候选不是此固件已经实现的功能。

## 用户验证顺序（未执行）

1. 仅编译，记录板子精确型号/core/library版本；失败时先保存完整错误，不盲目升级全部依赖。
2. 不ARM，确认未授权HTTP不能动作、默认无自动发键；测试物理STOP。
3. 配对，单次move/click/ASCII，人工看屏幕确认；再测drag和scroll。
4. 重复相同请求、旧sequence、旧session、旧boot、过期时间、超长text，确认不多执行。
5. 执行drag/text期间按STOP、拔Wi-Fi、关蓝牙，确认无持续卡键；重新连接/ARM不重放。
6. 最后才接入ReplayKit+AI，每次只准一小步；不要用真实支付或聊天发送作为初测。
