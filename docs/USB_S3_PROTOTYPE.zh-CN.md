# ESP32-S3 USB NCM + HID 实验目标

## 状态与不能承诺的部分

新增 `firmware/SightLatchS3USB`，不是替换现有 Arduino BLE 固件。
目标是 USB-C iPhone 经同一条 USB 数据线，使用 NCM 本地网络加密写入 Wi-Fi / 控制 Token，并发送 USB 键鼠报告。**组合枚举、iPhone DHCP、供电、AssistiveTouch 和实际输入效果均需要实机验证。源码/静态测试通过不等于真机可用。**

- ESP32-S3 的 USB OTG 口（GPIO19/20）才适用。板子上的 USB-UART 口不是同一个口。
- ESP32-C3 的 USB Serial/JTAG 不是通用 USB OTG；不能升级固件变成该 NCM+HID 设备。现有 C3、ESP32、S3 BLE 构建与网页镜像保持不变。
- 此版本是独立**有线实验模式**，不是一个镜像里自动切换 USB/BLE 的完整双模产品。原有 Wi-Fi→BLE 路径仍使用旧目标。
- 新目标把 Wi-Fi/Token 保存为兼容的 `sightlatch/config` NVS JSON，但不启动 Wi-Fi 或 BLE，不对 LAN 暴露控制服务器，也未验证 Wi-Fi 接入成功。不要将“写入成功”解释为“联网成功”。重新刷回旧目标并保留 NVS，才能由原固件使用该配置。
- App 新的 USB 设置页是独立实验入口；既有聊天/自动操作代理仍走旧 HardwareClient，尚未接入此有线协议。不伪称自动化任务已支持 USB。
- 没有刷机、发布 Release、部署网页安装器或更改用户设备。构建验证结果应以本分支后续的明确报告为准。

## 安全的手机直连首配

有设备标签的板子：

1. 设备准备者在可信离线环境为每块板生成不同的随机配对码，并把对应 SRP salt/verifier 写入独立 `sl_factory` 分区。配对码印在私密标签上交给设备持有者。此步骤是设备准备，不是 iPhone 运行时步骤。
2. iPhone 连接 S3 的原生 USB OTG 数据口。供电不足时需要合适的供电数据转接器；Lightning 不在当前验证范围。
3. 板子启动后长按实际配置的物理按钮 3 秒，打开 60 秒认证窗口。默认 GPIO0 对应部分开发板 BOOT，请先核板卡原理图；不要上电时按住进入下载模式。
4. 在 App USB 实验页输入标签配对码，发起 Security2 认证，再输入 Wi-Fi/Token 并保存。PoP 不通过 USB明文发送；SRP6a 完成双向证明，后续 JSON 经 AES-GCM 加密。
5. 配网成功立刻关闭配置窗口，同一已认证会话最多有效 5 分钟。ARM 租约只有 60 秒，不能自动续期。重新开始会话必须再次按物理按钮。

**无标签、无屏幕的普通开发板：默认拒绝配对，不会无认证降级。** 可显式启用 `CONFIG_SIGHTLATCH_ALLOW_UART_PAIRING`，在长按按钮后从另一台可信设备的 UART 终端获取一次性临时配对码。这个开发回退需要第二台设备，**不满足纯 iPhone 首配**。码只保留当前会话，禁止录制 UART 输出。未来屏幕/标签二维码扫描是硬件产品化工作，当前 App 支持手工输入标签码，不宣称已有扫码交付流程。

配对码不是控制 Token。不能把 Token、Wi-Fi 密码塞进 URL、USB 键盘输入或诊断日志。手机页不自动持久化这些字段，也不代替用户批准系统局域网权限。

## 固件构建（交给专用构建环境）

固定 ESP-IDF **5.5.2**、`espressif/esp_tinyusb` **2.4.0**。2.1.1 起包含 iOS NCM修复，2.4.0另修正NCM IAD设备类别。不要降回旧 CDC-ECM 例程。

```sh
cd firmware/SightLatchS3USB
idf.py set-target esp32s3
idf.py build
```

默认 4MB flash、自定义分区，不依赖 PSRAM。开发者应核实际 flash/板型。代码不会自动擦除出错 NVS。`sdkconfig.defaults` 仅对新构建目录生效；不要复用其他目标 sdkconfig。

没有增加自动 CI 构建或部署；本实验目标暂不加入旧网页安装器。编译后也不能把它当已验证可刷镜像。

## 设备标签准备（用户/设备准备者执行，不在助手任务中生成真实凭据）

```sh
umask 077
python3 scripts/prepare_usb_pairing_label.py /absolute/private/new-device-label
python3 "$IDF_PATH/components/nvs_flash/nvs_partition_generator/nvs_partition_gen.py" \
  generate /absolute/private/new-device-label/factory.csv \
  /absolute/private/new-device-label/factory.bin 0x10000
```

生成器不刷机，不联网，不把码打印到 stdout，拒绝在仓库内输出及覆盖旧目录。`label.txt` 含私密配对码，`factory.csv`/`.bin` 只含 salt/verifier；三者都应保护，禁止提交或上传。设备标签对应私有文件，不是仓库提供的通用默认码。测试使用固定假码。

`sl_factory` 是数据分区，固定当前分区表偏移 `0x2f0000`、大小 `0x10000`，与普通配置 NVS 分开。**仅由操作者核对实际构建分区表后按官方刷机流程写入，不自动刷机/擦除或代用户操作。** 重新生成标签将使旧码失效；不要覆盖保存配置的 NVS。默认固件不启用 Secure Boot / Flash Encryption / NVS Encryption，不抵御物理读闪存；生产安全设置须单独设计和批准，不能作为普通固件更新偷偷启用。

## USB 与协议

- Composite: interfaces 0/1 = NCM，interface 2 = HID。
- NCM notify EP0x81，数据 OUT0x02/IN0x82；HID IN0x83。
- HID report ID1 =键盘，ID2 =相对鼠标；没有绝对触控、多点或中文输入。
- 描述符 MAC string index5 与 `esp_tinyusb` 内部编号一致；主机NIC与设备IP栈使用不同MAC。
- IP `192.168.7.1/24`，DHCP不提供默认网关/DNS，不做互联网路由。仍须验证 iOS 是否保留可用的 Wi-Fi/蜂窝路由。
- HTTP只是承载加密二进制的本地 transport，不提供明文 Bearer HTTP端点，不开放 CORS，不接受凭据query。
- POST `/prov-session`：官方 protocomm Security2，固定 username `sightlatch`，sec_ver2/sec_patch_ver1。只在物理60秒窗口接受握手。
- POST `/usb-command`：Security2加解密后的JSON。单一逻辑session id1可跨TCP连接，但无跨设备、跨重新配对状态复用；TCP不是认证凭据。
- SDK依赖固定revision；握手直接 `initialiseSession`，不调用会加入Wi-Fi的 `connect()`。命令绕过SDK自动重试，用无重定向/缓存的独立URLSession传递官方securityLayer加密结果。
- 顺序 `sequence` 从1开始，正确序号的请求无论业务成功失败均消耗序号。不自动重试，网络/加密不确定则弃用会话并由用户物理重新配对。Security2 GCM counter负责密文重放保护，应用序号额外防重复副作用。

解密后请求示意（此处全为占位，不是真实凭据）：

```json
{"sequence":1,"op":"provision","ssid":"EXAMPLE","password":"EXAMPLE_ONLY","token":"EXAMPLE_TOKEN_NOT_A_REAL_SECRET_0000"}
```

`provision`：SSID 1..32字节；password为空（开放网络）或8..63可打印ASCII；token32..128可打印ASCII。仅物理窗口内成功一次，原子保存一个JSON记录，响应不回显任何秘密。密码不是64位十六进制PSK接口。

其它命令须带已配置token（同样在AES-GCM正文内）：

- `status`：查询已配置、ARM、USB报告的连接状态。
- `arm`：60秒租约，USB已连接才允许；不发送操作动作。
- `stop`：解除并清队列。
- `move`：dx/dy各-127..127。
- `click`：button只能1/2/4，40ms后释放。
- `key`：usage4..101、modifiers0..255，40ms后释放。

单在途动作，最迟1秒过期；USB断开/挂起、物理按键、租约/会话到期均撤销。release仅是尽力发送，线断开无法保证主机收到释放。发送报告不证明iPhone执行或点击正确，需要人工看屏幕。软件急停不是安全认证。

## 验证清单

已提供 `python3 tests/check_usb_prototype.py`：假码生成器权限/不泄露、固定长度前导零盐测试、源级安全回归。它不是编译、加密互通或USB测试。

构建环境继续：
1. IDF5.5.2完整编译，确认managed component2.4.0和tinyusb解析版本，记录依赖锁文件。
2. iOS Xcode26+ unsigned compile以及官方SDK/SwiftProtobuf依赖解析；没有macOS时明确未编译。
3. 运行Security2客户端/设备互通测试，错误PoP、旧GCM包/序号、过期窗口和凭据长度边界必须拒绝。
4. 真机先不ARM测NCM枚举/DHCP；验证旧标签、无标签默认拒绝、重新配对旧会话失效。
5. 空白测试页单次微移/点击/键，验证急停、拔线、挂起、租约和掉电；禁止拿支付、真实发消息或删除当测试。
6. 验证重启NVS读回和旧BLE镜像兼容。固件未连接Wi-Fi，不用保存成功替代此测试。

## 上游来源

- https://github.com/espressif/esp-usb/pull/410
- https://github.com/espressif/esp-idf/issues/18079
- https://components.espressif.com/components/espressif/esp_tinyusb/versions/2.4.0/changelog
- https://developer.apple.com/forums/thread/772812
- https://developer.apple.com/forums/thread/844110
- https://github.com/espressif/esp-idf/tree/v5.5.2/components/protocomm
- https://github.com/espressif/esp-idf-provisioning-ios/tree/78e58f010f8539f800bce063a26d3e4c4ac596b9

SRP verifier生成沿用官方Security2的RFC5054/SHA512参数，不是另建握手协议。固定32字节salt避免IDF5.5.2便捷生成API经MPI序列化裁去前导零但未返回实际长度的边界；无论salt首字节是否0都保留其完整长度。
