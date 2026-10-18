# 0.2.1 断链诊断与配对发现改进

## 结论与边界

用户已报告真机配对后 ARM / 其他操作触发掉线。尚未取得该设备的重启原因、GAP 断链原因或日志；**不能宣布现场根因已确定或真机已修复**。本版没有真实 iPhone / ESP32 板测试。

代码中确定存在的缺陷：首次认证成功关闭 pairing 窗口后，同一已认证连接若再次收到成功的加密事件，旧回调因窗口关闭而主动断链。0.2.1 允许同连接的重复成功认证；连接回调仍清空 prior authentication，新连接必须在窗口内完成认证，失败加密依旧断链，SC-only / 16-byte key 不变。主机回归重现旧判定并覆盖新策略真值表。这是确证代码路径，不是此次现场已确认根因。

ARM 自身不调用断链或停止广告，只先发 keyboard/mouse release，再建立五分钟 session。action 的执行/完成、STOP/disarm 也涉及报告。status 读取不会发送报告。BLE callbacks 不获取 stateLock；HID release 保留原有安全锁与 STOP 语义，未凭猜测移出临界区。NimBLE notify 库内部订阅容器会由 BLE task 更新；并发、单核调度、堆/栈、Wi-Fi 共存仍需要诊断数据，不能仅凭“操作后掉线”断言看门狗或重启。

## 不擦配置的最小诊断

无需再次 ARM、动作测试、刷写、重新配对或向任何人提供 token。

1. 由现有 App 已保存的连接读取一次 /v1/status；对比此前已有的 boot_id / uptime_ms。boot_id 改变是重启证据；uptime 回退要排除约49.7天回绕。只有新的一次快照而无旧值，不能单凭它宣布重启。
2. 如果设备已连 USB 串口且能被动读取，115200 留存已有 ROM rst / panic / watchdog 信息。不要为采集主动复位；部分串口工具打开端口会切 DTR/RTS 并导致复位，应关闭自动复位，避免把采集造成的重启当成原故障。
3. 旧版串口 {"command":"status"} 只有版本/IP/配置标记，没有 reset reason；不要把旧版缺字段误认成零。
4. 0.2.1 的 HTTP status 和 USB status 都增加 reset_reason（ESP-IDF 枚举整数）、boot_id、uptime、auth_events/auth_rejects、disconnect_events、last_disconnect_reason、last_encryption_status、notify_events/notify_errors/last_notify_code、free/min heap 与 safety_stack_free_bytes。-1 表示未观察到/当前栈无该事件字段。NimBLE GAP reason 是 host 编码值，不能直接当裸 HCI byte；通知错误也可能是未订阅，不自动等于链路损坏。计数仅当前启动有效。

本工具链 reset_reason 常见值：1=上电、3=软件重启、4=异常/panic、5=中断看门狗、6=任务看门狗、7=其他看门狗、9=欠压、11=USB复位、12=JTAG复位（取自该版 ESP-IDF esp_system.h）。一次快照只能说明当前这次启动的来源，不能还原更早已丢失的启动历史。

**现有网页的完整 4MiB merged 镜像会覆盖 NVS，包括 Wi-Fi 配置与 BLE bonding；不选“全片擦除”也不等于保留 NVS。不要把重装网页流程说成无损诊断升级。** app-only 升级必须另行核对完全一致的分区表和正确地址，当前页面不提供该能力。

## 条件取消与原生发现

POST /v1/cancel_pairing 使用现有 Bearer 认证与 {boot_id,control_epoch}。仅同 boot/epoch、未 armed、仍开窗时生效；锁内关闭窗口并轮转 epoch，停止广告，未加密连接断开。状态已变返回409，不 disarm 新授权。旧固件404/405需等窗口自然过期，禁止 fallback 到无条件STOP。

发现服务 UUID：7D9B1E20-4F6A-4C88-A3D2-6E5F0190B7C1。没有特征、控制命令或秘密。保留1812 HID。主广告共29字节（flags3 + custom128 UUID18 + HID16 UUID4 + appearance4）；SightLatch名称仅在12字节scan response。只在显式配对窗口广播；status 的 accessory_setup_service_uuid 用于能力判断，不能证明手机已授权/已订阅。

## 硬件校准租约

/v1/arm 可传 mode:"calibration"，由固件固定限制最多60秒，且仅允许 dx/dy 各在[-10,10]内的move与release_all；键盘、点击、滚轮、拖动与大移动返回403。默认或mode:"task"仍为5分钟。重复ARM不会续期，已授权模式与请求模式不同返回409，不能把校准升级为任务。

status 返回 control_lease_mode（none/calibration/task）和 lease_remaining_ms。客户端需在ARM前确认字段存在，不得把忽略mode的旧固件当作60秒校准固件；成功后再次检查模式与实际剩余期限。App挂起或失联不影响固件自己的60秒到期检查，但这不是安全认证或硬件独立看门狗保证。

## 验证

- 主机 C++：旧认证路径复现、新策略16组合真值表、新连接失败关闭、原ASCII/时钟回绕。
- Python：认证与诊断字段契约、只读边界、条件取消、发现广告预算、原固件与全仓源码契约。
- 5种官方 Arduino-ESP32 3.3.5 镜像实际编译与芯片头/分区/源码SHA验证结果见 manifest 与构建输出。
- 网页测试与生产构建。
- 未进行真机BLE、App原生配对面板、iPhone控制或烧录；编译及主机测试不能替代这些。
