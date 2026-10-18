# 公共零 GPIO 镜像兼容性

以下仅表示 Arduino-ESP32 3.3.5 / ArduinoJson 7.0.4 真实编译和镜像静态验证通过，**开发过程中未做开发板、USB、BLE 或 iPhone 真机测试**。不表示所有厂商板型可用。所有镜像使用至少 4MB Flash 的 4MB huge_app 布局，无 OTA，不依赖 PSRAM，不接外部 GPIO。

| 芯片 | 运行期串口 | Flash | 芯片 ID | 合并镜像内 bootloader | 状态 |
|---|---|---|---|---|---|
| ESP32-C3 | 原生 USB Serial/JTAG，或 USB 转 UART0 | DIO 40MHz / 4MB | 5 | 0x0000 | 两份已有构建，字节保持不变；有用户 C3 烧录成功反馈 |
| 经典 ESP32 | USB 转 UART0 | DIO 40MHz / 4MB | 0 | 0x1000 | 新增构建 |
| ESP32-S3 | 原生 USB Serial/JTAG，或 USB 转 UART0 | DIO 80MHz / 4MB | 9 | 0x0000 | 新增两份构建 |
| ESP32-S2 | 不支持 | 无 BLE | — | — | 拒绝 |
| C2 / C6 / H2 / 其他 | 本轮不支持 | — | — | — | 拒绝 |

S3 使用官方自带 DIO80 bootloader，不能用于要求 OPI Flash 的板型。PSRAM 禁用不是 OPI Flash 兼容方案。经典 ESP32 没有原生 USB。C3 原生 USB 为 GPIO18/19；S3 为 GPIO19/20。具体板子端口接线、驱动、Flash 类型和按钮以板厂资料为准。普通 ESP32/S3 BOOT 常用 GPIO0，C3 常用 GPIO9。安全启动或加密设备不支持。

安装器要求选择芯片系列并再次识别实体芯片。选择变更后断开并清空擦除同意；镜像的 bootloader 与应用芯片 ID 必须同时匹配目标，分区表、Flash 参数、SHA-256 均需通过才允许擦写。所有合并镜像从 0x0000 写入，应用在 0x10000，分区表在 0x8000；经典 ESP32 的前 0x1000 是官方合并填充区。

## 重建与溯源

运行 `scripts/build_firmware.sh` 构建 C3，然后运行 `scripts/build_extended_firmware.sh`，最后 `python3 scripts/verify_firmware.py`。后者可直接基于已提交的 C3 manifest 添加三份镜像，不重写 C3 文件。

扩展构建脚本只在独立临时构建副本中为经典 ESP32 增加编译目标白名单；原始 Bridge.cpp 不改动，任何运行期逻辑、认证、epoch、停止、取消、配对与会话代码都没有变换。脚本先拒绝私有 config.h，再复制公共源码并断言变换位置唯一。manifest 保留原始 source_sha256，另记录变换脚本哈希、每个新镜像的精确 FQBN、编译输入文件哈希和 Flash 参数。验证器可重放唯一目标白名单变换，并检查编译输入哈希。

本次静态测试不能证明 BLE 加密回调、iPhone 配对、USB重枚举、硬件停止和板上 NVS 操作实际可用。停止可直接断电；运行仅使用受信隔离 LAN。

协议/状态返回仍保留 `0.2.0-c3` 这个已有版本标识以保持现有控制端兼容；它不是芯片识别字段。安装器从 ROM 读取实际芯片，manifest 的 chipFamily 与二进制头共同确定目标，绝不凭版本字符串猜测芯片。

2026-10-18 用户反馈其 C3 已成功烧录；未提供精确板型/USB模式，不能推广为具体品牌或所有 C3 板型验证，更不代表 BLE 配对或同一 iPhone 闭环已通过。
