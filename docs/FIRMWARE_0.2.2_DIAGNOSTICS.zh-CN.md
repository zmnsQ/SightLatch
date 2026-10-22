# 0.2.2：连接入口诊断与构建核对

此版用于核对网页所刷固件与当前源码，并区分“手机没有连接”“连接被配对窗口拒绝”“安全协商已请求但尚未完成”。它没有放宽蓝牙配对或控制权限，也不宣称已经解决真实 iPhone 的 HID 配对问题。

HTTP 状态与 USB 串口状态共用以下只读字段，网页读取状态会显示它们：

| 字段 | 含义 |
| --- | --- |
| `ble_stack` | 实际编译的 `nimble` 或 `bluedroid` |
| `firmware_source_sha256` | 构建输入的公开源码指纹，与 manifest 中该目标的 `source_id` 对应 |
| `connection_attempts` | 进入固件连接回调的次数 |
| `connection_admissions` | 通过配对窗口与单连接检查的次数 |
| `connection_rejects` | 被上述检查拒绝的次数 |
| `last_connection_rejection` | `none`、`pairing_window_closed` 或 `existing_connection` |
| `security_start_events` | 已接纳连接发起安全协商的次数 |
| `last_security_start_code` | 对应 BLE 栈安全请求 API 最近的返回码 |
| `last_security_start_accepted` | BLE 栈是否接纳了最近的安全请求，**不代表已经配对或加密成功** |

`auth_events` 与 `hid_connected` 继续表达认证回调与可用加密连接。所有计数从本次启动开始；多个原子字段读取时可能跨越一个回调，不应把瞬间的计数差当成独立故障。拒绝原因保留最近一次拒绝，不会被后来的成功连接清空。没有安全请求时，`security_start_events` 为零，返回码与 accepted 的初始值不代表一次失败请求。

官方 Arduino-ESP32 3.3.5 的 NimBLE `startSecurity` 可能报告安全流程已经启动，此时 accepted 表示请求已接纳或正在处理中。它不证明已经发生新的加密协商。固件仍必须收到并验证认证回调，才会设置加密连接状态。

构建脚本在忽略的 `firmware/build/` 中复制无私有配置的源码，并生成 `BuildProvenance.h`。指纹覆盖文件名和每个公开源文件的 SHA-256；ESP32 classic 的目标守卫转换也计入其单独指纹。发布打包和验证都会检查指纹确实嵌入二进制。直接用 Arduino IDE 编译而未运行构建脚本时，指纹为 `unrecorded`。

公开构建使用 GCC 的 `-ffile-prefix-map` 与 `-fmacro-prefix-map`，把检出目录、Arduino 工具/库目录和编译输出目录映射为 `/sightlatch`、`/arduino/data`、`/arduino/user`、`/arduino/platform` 与 `/arduino/build`。这些选项保留断言和诊断中的源文件信息，只替换工作站绝对路径；没有删除诊断或剥离符号来隐藏路径。manifest 记录映射规则和构建脚本哈希，打包及发布验证拒绝包含本地检出路径或 macOS 用户目录的镜像。

保持不变的行为包括 30 秒配对窗口、Secure Connections 与 16 字节密钥检查、控制令牌、ARM 门禁、断链停止和不自动重新广播。首次安装和更新仍写完整 4 MiB 镜像，会清除 Wi-Fi、控制令牌和蓝牙绑定；刷写后需要重新配置。发布可刷写镜像不等于已经完成真机回归。

## 发布前本地核验（2026-10-22 UTC）

- Arduino CLI 1.3.1、Arduino-ESP32 3.3.5、ArduinoJson 7.0.4；下载的官方工具链包已核对 SHA-256。
- ESP32-C3 USB/UART、ESP32 UART、ESP32-S3 USB/UART 五种目标实际编译成功；每个完整镜像为 4 MiB。
- 源码指纹、芯片头、分区位置、Flash 参数、镜像大小及 SHA-256 验证通过；五个新镜像均未包含本地检出路径或 macOS 用户目录路径。
- C3、ARM 和连接诊断的 14 项 Python 契约测试、C++ 认证回归测试通过；网页安装器 18 项测试及 Vite 构建通过。生成的网页目录所含新镜像与 manifest 对应的已验证字节一致。
- 原有五个 0.2.1 下载镜像保持字节不变，供既有链接和版本比较使用；当前 manifest 仅选择 0.2.2。
- 本轮为本机构建与打包验证，没有刷写 0.2.2 或据此声明其已经完成真机 HID 回归。
