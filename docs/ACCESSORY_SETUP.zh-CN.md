# App 内 HID 配对：实验性实现与验证边界

更新：2026-10-18。当前仅云端静态核验；没有 Apple SDK、签名构建、真实 iPhone、蓝牙抓包或真实硬件配对验证。不可宣称已实测可用。旧固件尚不支持本路径。

## 官方 API 与兼容范围

- AccessorySetupKit 和 ASAccessorySession 从 iOS 18.0 可用；HID 的 `ASAccessory.SupportOptions.bluetoothHID` 从 **iOS 18.4** 可用，iOS 26 继续使用相同公开 API。
- Apple 明确要求 HID 配件额外广播一个自定义服务，并使用该服务发现；不能仅用标准 HID `1812`。
- 因此保留 App 的 iOS 18.0 deployment target；运行时检查 18.4，旧系统走手动设置。编译分支以 `canImport(AccessorySetupKit) && compiler(>=6.1)` 保守限制到 Xcode 16.3 / Swift 6.1 或更新工具链。需使用带 iOS 18.4+ SDK 的 Xcode，编译器条件不是 SDK 存在性的正式证明。

官方依据：[ASAccessorySession](https://developer.apple.com/documentation/accessorysetupkit/asaccessorysession)、[bluetoothHID](https://developer.apple.com/documentation/accessorysetupkit/asaccessory/supportoptions/bluetoothhid)。核验了 Apple DocC JSON 元数据 introducedAt=18.4，不是根据名称推断最低版本。

## 固件与发现协议

- 项目专用服务 UUID：`7D9B1E20-4F6A-4C88-A3D2-6E5F0190B7C1`。
- `/v1/status` 可选字段 `accessory_setup_service_uuid` 必须精确匹配（忽略大小写）；旧固件缺失时自动降级。此字段仅为能力提示，不能证明设备身份或蓝牙连接成功。
- BLE 名称 `SightLatch`，主广告包含自定义服务、HID 1812 和 mouse appearance；名称放 scan response。固件工作分支负责实现和容量验证。
- 服务不增加控制端点或秘密特征；不虚构 Bluetooth SIG company ID。
- 同 UUID+名称的多台设备可能同时出现。用户需要选中自己的板子；最终以当前 Wi-Fi 目标板的加密 HID 状态验证，不能凭 picker 选择推断是同一块板。

## App 流程及权限

仅用户点击开始配对后，通过现有 Wi-Fi `/v1/pair` 开窗。确认 waiting 后，传真实剩余秒数给 adapter；激活 ASAccessorySession 后才显示系统 picker，要求用户确认。descriptor 使用 custom UUID + bluetoothNameSubstring，supportedOptions 为 bluetoothHID、bluetoothPairingLE。没有 CoreBluetooth 全局扫描，没有私有蓝牙设置 URL。

Info.plist 声明 `NSAccessorySetupKitSupports=[Bluetooth]`、专属 `NSAccessorySetupBluetoothServices`、`NSAccessorySetupBluetoothNames=[SightLatch]`。CompanyIdentifiers 使用空数组，不发明标识；实际硬件必须检验当前系统对此配置的兼容性。如果系统拒绝或无结果，降级而不是随意填写 company ID。ASK 本路径不初始化 CBCentralManager，也不新增全局蓝牙权限请求。原 Wi-Fi 本地网络权限仍保留。

官方发现文档允许 company identifier **或** service UUID 配合名称匹配。系统访问仅授予用户选中的配件；不能把授权事件当成可发送 HID 控制的许可。[Discovering and configuring accessories](https://developer.apple.com/documentation/accessorysetupkit/discovering-and-configuring-accessories)、[Info.plist supports](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaccessorysetupkitsupports)。

本 App 的直接 picker 不需要 Device Discovery Extension；不要向主 App 添加 `com.apple.developer.accessory-setup-discovery-extension`。该 entitlement 专属于发现扩展，Apple 明确不应添加到 App。[官方 entitlement 文档](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.accessory-setup-discovery-extension)。

## Adapter 生命周期与 UI 接口

`SightLatchAccessorySetupAdapter` 是 MainActor ObservableObject。调用：

```swift
adapter.present(serviceUUID: model.lastDeviceStatus?.accessorySetupServiceUUID,
                pairingWindowIsOpen: true,
                remainingSeconds: remainingWindowSeconds)
```

只在实际 waiting 状态调用。`state` 的 unavailable/failed 含可展示中文；manualInstructions 为系统设置步骤。`selectedAwaitingVerification` 仅表示收到 accessoryAdded 并已退出 picker，不表示加密成功。继续使用当前板端状态轮询；是否 ARM、授权 AI 控制由原安全流程决定。

关闭页面、超时、板端已确认连接时调用 `cancel()`，它只 invalidate 当前会话，不删除配对，不调用 /v1/pair，不更改 VM 状态。VM 自己负责窗口/轮询取消。generation 隔离旧回调，重复呈现被阻止，timeout 不会延长真实窗口。系统取消后可重试或按设置说明配对。

已通过系统设置配对的设备可能不被新 picker 发现：不擅自 removeAccessory、不虚构 CBPeripheral identifier 做迁移，不清除现有 bond；走已有连接验证或系统设置重新连接。若用户确实需忽略设备，必须由用户操作且解释影响。

## 项目注册（由整合者执行，避免并行冲突）

在 `ios/SightLatch.xcodeproj/project.pbxproj` 的 objects 加：

```text
AA2222222222222222221000 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "App/SightLatchAccessorySetupAdapter.swift"; sourceTree = "<group>"; };
AA2222222222222222221001 = { isa = PBXBuildFile; fileRef = AA2222222222222222221000; };
```

在主组 children 添加 `AA2222222222222222221000`；仅主 App 的 Sources phase `1C039998376449FF0E2EA2BB` 的 files 添加 `AA2222222222222222221001`。不加到 Widget/Broadcast。不需额外硬链接 framework；import 使用 SDK 自动链接。Info.plist 改动已在本分支，合并时保留其他并行修改。

## 必须补齐的验证

云端：`python3 tests/check_accessory_setup.py` 只做声明/隔离/能力 gate 静态契约检查，不是 Swift 编译、运行时状态机测试或系统配对证据。

真实 Xcode/iPhone：
1. 最新 SDK build + strict concurrency review；iOS 18.0–18.3 降级、18.4+ 与26原生picker。
2. 新/旧固件 gate；蓝牙关闭/拒绝、应用转后台、窗口期满、取消后重试、重复按钮、退出sheet；确保旧回调不改变新尝试。
3. 多设备选择错误、已配对、其他手机占用；发现失败仍保留清晰系统设置路径。
4. 每个板型实际抓包，核 custom service/name/HID/appearance 广告且限于窗口。验证系统确认后加密 HID 真连接、ARM 不掉线、取消不解除现有 bond。
5. 系统 picker 展示成功后仍不得跳过板端加密状态检查与 AI 控制授权。
