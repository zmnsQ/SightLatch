# C3 构建验证 · 2026-10-18

已真实执行：
- Arduino CLI 1.3.1 + 官方 Arduino-ESP32 3.3.5 + ArduinoJson 7.0.4，C3 原生USB和UART0两个配置均完整编译成功。
- 原生USB应用 1,292,952 bytes / 3,145,728 bytes；静态RAM 47,940 / 327,680 bytes。
- UART0应用 1,276,722 bytes / 3,145,728 bytes；静态RAM 47,132 / 327,680 bytes。
- 两个合并镜像各4,194,304 bytes。打包/独立验证检查C3芯片ID（5）、boot 0x0、分区表0x8000、app 0x10000、DIO/40MHz/4MB头和SHA-256。
- STOP会同步旋转control_epoch，较早但延后到达的ARM/PAIR无法重新授权；重启/安全失效同样撤销旧epoch，App请求必须匹配刚读到的boot_id和control_epoch。
- 公共镜像不含Wi-Fi/token；构建拒绝本地config.h。manifest记录各源码文件SHA-256；CI重新编译，部署前验证源码与镜像hash。
- 9项JS单元/模拟DOM交互测试通过：取消串口、芯片错误、Flash不足/未知、无后台请求、擦除取消、令牌生成/显示、浏览器不支持以及损坏镜像header拒绝。
- 4项C3源码合同测试、原8项源码测试、C++协议256字节/ASCII/millis回绕测试通过。
- Vite 6.4.4生产打包通过，完整npm audit零已知漏洞（检查当时的registry结果）。

最终镜像SHA-256：
- USB：a45d880b3d23d43454e41df5cf63ad4d950289f0223333606e9411cd4ae2bf97
- UART：eb6b142449aa98b711c74e41d3a73cc87b06bfbfe51f1102360f11c72a5c260d

未执行/未证实：
- 不接触用户电脑或任何真实USB；没有烧录、擦除、手机配对或HID动作测试。
- 本环境Chromium启动被容器socket/沙箱挂载问题阻断，未完成真实浏览器视觉/真实Web Serial驱动验证；JS交互测试使用模拟串口，不能替代设备测试。
- GitHub Pages仓库设置当时尚未开启；已准备独立手动发布workflow，但代码推送不等于网页已经上线。
- 未证明全部C3板兼容。未知板厂需确认≥4MB Flash及USB类型，S2不支持BLE，其他芯片未提供网页镜像。

复现：`scripts/build_firmware.sh` → `python3 scripts/verify_firmware.py` → `cd web-installer && npm ci && npm test && npm run build`。固件构建产物、工具链许可和网页静态目录见相应README及CI artifact。
