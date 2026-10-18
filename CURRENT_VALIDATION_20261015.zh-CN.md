# SightLatch 本轮增量与验收（2026-10-15）

## 范围与结论

保留既有三target原生工程和ESP32固件，完成源码可确认的流程断点修复。本轮未编译Swift、未做Xcode类型检查、未完整编译Arduino固件、未签名安装、未连硬件或调用模型。不能把结构检查及纯C++主机测试描述为App可运行、ReplayKit可见指针或生产就绪。旧LINUX_VALIDATION/STATIC_REVIEW文档属于上一轮历史。

## 修复与可观察结果

1. 工作区保存返回真实结果，写盘失败回滚到最后可读工作区；档案保存、导入、首次引导与准备时任务登记不再覆盖错误为“成功”。配置与工作区是两个文件，局部保存失败明确提示重试，不宣称跨文件事务。
2. 检测配置/工作区损坏并阻止默认值静默覆盖。工作区恢复按钮需要用户确认，先保留本机恢复副本再重置；凭据仍在Keychain，不写入JSON副本。副本不自动上传，也不承诺安全擦除。
3. 主App准备、手动校准、停止互斥。重复probe不创建多请求；准备等待中不能编辑任务/配置或发校准动作；新会话写入后若状态/任务登记失败会撤销会话。
4. 所有命令修改通过共享锁和session ID核对；只有创建新会话写完整命令。“继续观察”重新检查running/generation，停止不能被旧读改写复活。老会话的终态不能覆盖新会话状态。
5. 主AppSTOP与WidgetSTOP区分请求接受与已确认解除ARM/空闲。Widget即使本机命令写入失败也仍尝试网络STOP。默认广播结束直接撤销command，不再等主App前台轮询。
6. 上传许可在端点/协议修改时清除；设备地址修改使设备快照和校准确认失效；撤回上传先落盘再等待STOP网络结果。
7. 四种provider白名单、地址分段、数值finite与范围、方向、长度统一验证。AI请求与广播入口同样校验；未知provider不能落入兼容协议发送。动作完成回执额外核对boot ID。
8. ESP32文本入口只允许32–126可打印ASCII，拒绝LF/TAB/其他控制字符。键码映射和deadline函数抽成固件/主机测试共同使用的头文件，未另写测试专用替身。
9. 本地签名覆盖配置与固件秘密被.gitignore排除；源工程继续包含全部Swift编译引用。

## 本轮实际运行结果

在项目根目录执行：

```sh
python3 tests/check_source.py
c++ -std=c++17 -Wall -Wextra -Werror tests/protocol_primitives_test.cpp -o /tmp/hidpilot_protocol_test
/tmp/hidpilot_protocol_test
```

结果：8项Python源码/打包契约检查PASS；C++编译并运行PASS，覆盖256个输入字节的允许/拒绝、代表性US键码、deadline边界和millis回绕。

Python检查验证plists/entitlements可解析、三个target与Swift引用、命令更新调用点、验证门、STOP结果路径、持久化错误分支、广播终止撤销与secret忽略规则。它只检查源码契约，不执行Swift，不证明并发行为、SDK可用性或网络端到端正确。

## 用户本地编译

- 使用含iOS26 SDK的Xcode打开 `ios/SightLatch.xcodeproj`，选共享SightLatch scheme。
- 可先运行无签名编译：`xcodebuild -project ios/SightLatch.xcodeproj -scheme SightLatch -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`。
- 复制Local.example.xcconfig到Local.xcconfig，填写Team/唯一Bundle/App Group/共享Keychain配置，再签名装真机。
- 固件按firmware/README指定ESP32-S3/core/ArduinoJson版本编译；复制config.example.h到config.h，本地填秘密与实际GPIO，再刷机。
- 仓库保留手动触发的unsigned iOS工作流；本轮未触发，需你的Mac/CI实际运行后才有构建结论。

## 真机验收清单（全部未执行）

- [ ] 三target构建、扩展嵌入、App Group/Keychain访问、首次局域网授权；分别检查18降级和26功能（若你拥有对应设备）。
- [ ] 填配置→保存→重开一致；12档案上限、100任务上限、队列载入/确认完成/移回待办/删除；运行中不可改当前任务状态。
- [ ] 导入有效设置后不自动激活/授权；错误JSON、未知provider、超长文件、负校准值、不合法地址都明确失败；API密钥不出现在导出。
- [ ] 用开发副本损坏workspace/configuration：显示警告且不自动覆盖；确认恢复后旧文件副本保留，工作区归零且密钥未删除。模拟写盘失败，不能出现成功提示。
- [ ] 修改端点/协议清除同意；修改设备地址清除校准与设备快照；锁屏/设备未首次解锁时凭据或帧读取失败，不能假成功。
- [ ] ARM后校准方向、点击靶心、滚动、ASCII；LF/TAB、非ASCII文本被拒绝。对焦点和输入法结果逐一目视确认。
- [ ] 快速重复准备、准备中STOP、校准中STOP、probe中修改导航；没有双会话、旧准备完成提示或自动重放旧动作。
- [ ] 用户开始系统广播后，实际确认同机BLE HID与截图是否能共存、指针是否入帧；不可见时必须暂停。
- [ ] 模型响应错误、429、401、畸形JSON、超大响应、过期帧、画面变化、低置信度和敏感提案均暂停，不重试动作。
- [ ] 主AppSTOP、WidgetSTOP、系统结束广播、物理急停：查看真正ARM与busy状态；拔网络时明确未确认，禁止假报硬件停止。
- [ ] 默认广播停止且主App不在前台，command仍应被撤销；旧回调和Widget重复停止不应复活/替换新的command。
- [ ] iOS26可选后台模式被拒绝、5秒不启动、无画面45秒、6秒租约失效、系统取消、锁屏保护、5分钟/步数限制都安全结束；最新帧按设计清理。
- [ ] 单个模型请求费用/数据保留由你核对；测试只用无风险页面，不在真实支付、通讯、密码或医疗页面进行。

## 仍需理解的边界

没有ChatGPT订阅OAuth、中文Unicode直输、绝对触点、多指手势或永久后台执行。模型风险标签与关键词不是安全保证；粗指纹可能漏掉小范围目标变化。HTTP局域网明文与BLE Just Works不适合不可信网络；物理急停必要。任何已经抵达硬件的动作不能被软件撤销。各OS/SDK和固件API仍需你本地编译与真机验证后继续修正。
