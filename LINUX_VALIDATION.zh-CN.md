# Linux 验证补充记录

2026-10-14。用户在初始只读交付后新增了云端 Linux 运行验证授权；本记录是后续验证，早先“未执行”记录属于当时状态。

## 实际执行
- 环境：x86_64 Linux。检查到 Node 24.19.0、npm 11.9.0；未找到 Swift、Docker、xtool 或 Apple iOS SDK/Xcode.xip。
- 从官方 xtool-org/xtool GitHub Release 下载 xtool 1.22.2 x86_64 AppImage；通过 --appimage-extract-and-run 成功执行 --help。
- 实际执行 xtool sdk status：输出 `Not installed`。
- 在本项目 ios/ 目录实际执行 xtool dev build：退出码1，错误 `Could not find Package.swift in this directory.`
- Python plistlib 成功解析6个plist/entitlements；XML解析scheme成功；工程引用的源码/配置路径均存在。新增Workspace/PilotIntents之后再次进行了同样检查。这只是结构检查，不是Swift编译或Xcode工程有效性证明。

## 结论
Linux上构建iOS并非绝对不可能，但**本次没有构建出该iOS App**。xtool成功运行不等于Swift/iOS SDK已配置。当前工程是App+ReplayKit+Widget三target的Xcode工程，不能直接交给xtool的SwiftPM构建入口。

官方源码确认，xtool支持扩展产品与Widget示例。因此不能说它完全不支持appex；需要先把该项目认真迁移为Package.swift+xtool.yml，并保留三个产品各自的Info.plist、扩展入口、共享源码、entitlements和嵌入关系。此迁移未实施、未冒充完成。

## 最小继续门槛
1. 合适的官方Linux Swift工具链（当前xtool文档要求Swift6.4）。
2. 用户合法取得并提供的匹配Xcode.xip/Apple SDK。官方指南要求Apple登录并接受下载许可；本次没有登录、接受新协议、寻找非官方SDK镜像或绕过许可。
3. 将三个target映射为SwiftPM产品与xtool扩展打包配置，随后执行真实arm64-apple-ios构建。无签名dev build本身可不登录；签名安装是后续单独步骤。
4. Linux不提供Apple iOS Simulator运行时。本次没有手机连接，也没有实机ReplayKit/HID运行验证。

## 无用户Mac的另一条路
包内 `.github/workflows/macos-unsigned-build.yml` 是手动触发的GitHub托管macOS编译流程源码：检查现有SDK≥26，然后执行xcodebuild CODE_SIGNING_ALLOWED=NO build，保留日志。不运行测试、不安装手机、不签名。

该workflow没有创建仓库、上传或触发，也没有产生CI费用。用户若日后自行上传并手动启动，需自行确认GitHub账户配额、费用、仓库可见性和源码上传范围；macos-latest的预装Xcode版本随平台变化，不足版本时流程明确失败。

## 官方依据
- https://github.com/xtool-org/xtool/blob/main/Documentation/xtool.docc/Installation-Linux.md
- https://github.com/xtool-org/xtool/blob/main/Sources/XToolSupport/DevCommand.swift
- https://github.com/xtool-org/xtool/blob/main/Sources/XToolSupport/SDKCommand.swift
- https://github.com/xtool-org/xtool/blob/main/Examples/DemoExtensions/Package.swift
- https://github.com/xtool-org/xtool/blob/main/Examples/DemoExtensions/xtool.yml

与此独立的macOS项目Node MCP gateway已经在Linux实际通过TypeScript编译及本地模拟smoke；该结果不能代替本iOS工程或macOS SwiftUI界面的编译运行。

## 可选后台路线增补与固件尝试

2026-10-14 新增ContinuedSession后，再次执行六个plist/entitlements与scheme XML解析、19个PBX文件路径存在性和75个对象ID唯一性检查，全部通过。12个Swift文件未做Swift parse或类型检查；环境仍无swift/Apple SDK。

云端从官方 `https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_Linux_64bit.tar.gz` 下载并实际运行Arduino CLI，latest当时返回 **1.5.2-rc.1**，仅记录工具实际版本，不推荐RC作为发布工具链。独立data/downloads/user位于云验证目录。`core update-index --additional-urls https://espressif.github.io/arduino-esp32/package_esp32_index.json` 实际exit1，CLI的Go网络栈报 DNS `network is unreachable`，官方索引无法取得，故没有安装ESP32依赖、没有执行固件编译。未绕过网络权限，也未取非官方预编译库。固件README仍锁定Arduino-ESP32稳定3.3.5与ArduinoJson7.0.4；未填入真实凭据、未刷写、未接触用户设备。
