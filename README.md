# HIDPilot

原生 iOS App、ReplayKit 屏幕广播扩展、Live Activity Widget 与 ESP32-S3 BLE HID 固件的源码工程。用户主动广播屏幕后，由所选视觉 API 规划单步操作，手机校验后通过可信局域网控制 ESP32。

## 从这里开始

- [中文工程说明](README.zh-CN.md)：配置、目录、功能与边界
- [功能逐项核对](docs/FEATURE_MATRIX.zh-CN.md)：实际代码路径、已验证范围及未实现能力
- [本轮改动与用户验收清单](CURRENT_VALIDATION_20261015.zh-CN.md)
- [iOS 编译与签名](ios/README.md)
- [ESP32 固件配置与刷写](firmware/README.md)

本轮已在 Linux 运行源码契约检查和实际固件共用函数的 C++ 主机测试。没有编译或运行 Apple 原生代码、完整 ESP32 固件，没有完成 BLE、模型 API 和真机端到端验收。不是已签名安装包或生产成品。

API key、设备 token、Wi-Fi 密码及签名资料由你在本地配置，不应提交到仓库。不存在 ChatGPT 等订阅登录/额度复用功能；不支持中文 Unicode HID 直输或永久后台执行。

## 手动编译工作流

仓库的 Apple 编译 workflow 仅支持 workflow_dispatch，push 不会自动启动。你可自行在 Actions 页面触发；GitHub 托管 macOS runner 可能计入账户分钟配额或产生费用，请先核对账户计费。工作流只做无签名编译并保存编译日志，不安装 App、不部署、不申请或读取签名凭据。真机安装仍需你自己的 Xcode 签名配置。
