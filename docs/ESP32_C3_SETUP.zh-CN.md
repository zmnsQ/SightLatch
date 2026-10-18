# ESP32-C3：零外接引脚安装

只需开发板和 USB 数据线。USB 用于烧录/初次配置/供电，运行期手机通过受信 Wi-Fi 控制，板子通过 BLE HID 发送键鼠。无需 GPIO 按钮、显示屏或外部 HID 芯片。

## 支持边界

固定依赖 Arduino-ESP32 3.3.5、ArduinoJson 7.0.4。实际 C3 SDK 使用官方 NimBLE 后端（通过内置 BLE 包装层），并强制 Secure Connections only；没有混入外部 NimBLE-Arduino。S3 保留其 Bluedroid 回调分支。

本次优先 ESP32-C3，4MB Flash 布局、DIO、40MHz、无 PSRAM。网页拒绝非 C3 和无法识别/不足 4MB 的 Flash。板厂未知，不能保证所有 C3 的 Flash/USB 布线兼容；请查板厂信息。USB Serial/JTAG 与 USB-UART 各提供独立运行期串口镜像。ESP32-S2 没有 BLE，不支持此方案；其他带 BLE 的芯片尚未作为网页可用镜像发布。旧 S3 外接按钮配置可继续用 config.h 单独构建。

## 先打开安装页

目前仓库 GitHub Pages 尚未启用，没有已核验的线上入口。仓库拥有者先到 **Settings → Pages → Build and deployment → Source** 选择 **GitHub Actions**，再到 **Actions → Publish USB installer (manual) → Run workflow**。仅在部署成功后使用任务输出的真实 URL，不猜测地址。

也可直接在自己电脑本地启动，无需等部署。仓库已含预编译 C3 镜像；有 Node.js / npm 后，在仓库目录执行：

```sh
cd web-installer
npm ci
npm run dev
```

用电脑 Chrome / Edge 打开终端打印的 localhost 地址。不要用 `file://`；无需复制 `config.h`、安装 Arduino IDE 或重新编译镜像。更多细节见 [安装器说明](../web-installer/README.md)。

## 使用

1. 电脑 Chrome/Edge 打开构建后的静态安装页（HTTPS 或 localhost）。选择板子的 USB 类型，再选择串口识别。
2. 核对 ESP32-C3 和 Flash 容量，勾选清空确认，再点击安装并确认。全部 Flash 会被删除，包括旧程序和凭据。
3. 按板载 RESET 或重新插 USB。原生 USB 的端口可能重新枚举。填写 Wi-Fi 与随机控制令牌；保存同一令牌用于 App。网页经 USB 写入配置，等待板子确认；再读 IP。
4. 手机与板子连接同一个受信 2.4GHz LAN。App 填入 IP 与同一令牌，点击打开配对窗口，在 iPhone 辅助触控蓝牙设备中配对 SightLatch。
5. 从 App 明确允许接管。默认不自动允许；每次授权最长5分钟，停止、Wi-Fi/BLE断开或重启会撤销session，不能自动续租。App停止按钮发送认证 /v1/stop；独立硬停是拔掉USB电源。

首次配置失败不会启动 HID。串口仅显示状态/IP，不回显 Wi-Fi密码或令牌。NVS 未加密；拿到板子的人可能读取它们，物理USB也能重配。HTTP 是明文，仅用自己控制的隔离LAN；BLE Just Works 不防中间人，不能用于敏感操作。

## 新增兼容 API

所有请求仍须 `Authorization: Bearer <token>`，不启用 CORS。
- GET /v1/status 增加 control_mode（software / physical）、control_epoch 与 firmware_version，既有字段不变。hid_connected 代表已加密认证。
- POST /v1/pair `{boot_id,control_epoch}`：200 `{ok:true,pairing_open:true}`；窗口30秒；已连接409 already_connected；物理模式403 physical_control_required。
- POST /v1/arm `{boot_id,control_epoch}`：200完整status，创建5分钟session；已armed请求不续租；链路未准备好409 hid_or_wifi_unavailable；物理模式403 physical_control_required。
- POST /v1/stop：沿用202，安全任务解除；之后须App重新允许，绝不自动恢复。
- 配对/授权前先读取status，提交刚观察到的boot_id和control_epoch。STOP同步更换epoch，断线/租期失效也更换，迟到旧请求返回409 control_epoch_mismatch；不能自动重试，须用户重新明确允许。缺字段400 invalid_control_request。配对成功后刷新status再授权。
- action 协议、TTL、幂等、ASCII限制与原固件一致。

## 验证状态

软件构建和自动测试不能替代真机。本次不连接任何真实 USB、不开启手机配对、不执行 HID 动作。请先在空白备忘录测试，再验证 STOP、断线、不重放；勿以支付/真实消息作为首次测试。
