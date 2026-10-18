# ChatGPT 套餐登录（实验性原生接入）

## 当前状态

这次提交实现官方 OSS OAuth 协议、本地 Keychain 会话、模型目录、Responses SSE 与设置界面。**未执行真实账户注册、登录或模型请求；未完成 Apple SDK 类型检查、iPhone 安装或 loopback 回调实机验证。** Linux Swift 语法解析与真实 Foundation SSE 单元测试不能替代这些验收。

原有 API Key 方式保留。ChatGPT 登录失败、额度不足或资格不符时停止，不会自动改走 API Key 付费。

## 接入条件与条款

SightLatch 以 MIT 许可发布。MIT 许可不代替 OpenAI 服务条款，也不会授予 OpenAI 服务使用资格。

使用此功能须遵守 [Sign in with ChatGPT 条款](https://openai.com/policies/sign-in-with-chatgpt-terms/)。条款约定集成或使用即接受；令牌只能持久保存在用户控制的本地环境；后台调用要明确同意；不能共用、转售套餐额度或通过账户轮换绕过限额；使用 SIWC 功能不得要求向本应用付费或升级。本应用不代替用户同意浏览器中的权限或条款。

[官方 OSS 路线](https://developers.openai.com/siwc/token-sharing-open-source)使用动态注册，不借用 Codex 或他人 client ID，也不要求用户提供密码、cookie 或复制 token。商业、收费或远程托管接入应按官方要求申请合作，不能用本地 OSS 实现绕过资格审核。实际套餐/工作区/地区资格以服务返回为准，不保证任何套餐必然成功。

## 用户操作

1. 在设置打开 ChatGPT 套餐区，点击 Continue with ChatGPT。
2. 系统认证窗口显示 OpenAI 登录及授权。用户本人选择账号、工作区并审阅授权。
3. 登录后刷新可用模型，选支持图片输入的模型。
4. 明确允许屏幕任务期间（包括后台）使用 ChatGPT 套餐，然后点“使用 ChatGPT 套餐并保存”。
5. 在原有截图选项中另行同意向 OpenAI 发送任务与选定截图。登录并不自动授权截图上传。
6. 用量与应用限额在 [ChatGPT 设置](https://chatgpt.com/settings/usage)查看。没有伪造的余额数字。

退出会尝试撤销 renewable session 并删除本地 token；若网络故障导致远端撤销无法确认，界面会提示到 ChatGPT 设置断开连接。账户/client 映射及 host ID 会保留，避免重新登录反复创建注册。保存账户的选择是人工操作，不因额度耗尽自动切换。

## 实现边界

- OAuth：Authorization Code + PKCE S256，随机 state/nonce；固定 auth.openai.com 端点；禁止 HTTP 重定向转发凭据；JWKS RS256 签名、issuer/audience/nonce/expiry 验证。未知算法失败关闭。
- 初次使用 dynamic_agent_client，回调返回 issued client ID。先记录未完成注册，再交换 code；成功验签后才替换活动账户。身份 scopes 不代表套餐权限，必须有 chatgpt.tokens.use.direct。
- 本地回调绑定 `127.0.0.1` 随机端口、固定 `/auth/callback`。同次请求与 token exchange URI 完全相同。没有使用 localhost、自定义 scheme 替代官方 redirect URI。
- iOS 使用 ASWebAuthenticationSession 展示系统认证界面，NWListener 收到 loopback 后结束认证界面。此组合是需要真机验收的原型，不宣称官方提供了原生 iOS SIWC SDK。五分钟超时、取消及离开设置会终止登录。
- App Group 只放协调锁，不放 token；token 在 ThisDeviceOnly Keychain，通过已配置共享 Keychain group 供本应用扩展使用。跨进程 flock 保护旋转 refresh token。
- 官方 `GET https://api.openai.com/v1/models` 加载账号模型；`POST https://api.openai.com/v1/responses` 使用 OAuth bearer、store:false、stream:true。未使用 backend-api、私有用量接口、API 余额猜测或其他人的凭据。
- 只有 response.completed 且 status=completed 才返回规划 JSON；失败、不完整、截断、只收到 delta 或缺少终态一律停止。最多 8KB 规划文本，不允许部分响应驱动硬件。
- 截图仍是图像输入，不使用此路线不支持的原生 computer-use 工具、音频/视频或转录 API。

## 验证

```sh
SWIFTC=/path/to/swiftc python3 tests/check_chatgpt_oauth.py
```

必须在签名后的 iPhone 上追加：

- 完成一次实际登录及一次小型文字/截图请求，核对 ChatGPT 应用用量。
- 登录超过一分钟、取消、离开页面、重复点击、错误 state、端口占用与 listener 启动失败。
- 系统认证界面期间应用生命周期；如 loopback 不可达，停止并报告，不能替换未注册回调或绕过系统认证。
- token 到期时 App/Broadcast 并发请求、刷新失败、用户退出后不再运行请求。
- 401/403/429/503、SSE 中途报错、断网、过长响应、后台停止与物理 STOP。
- API Key 老路径正常，OAuth 错误不会触发计费回退。

协议来源：[登录](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)、[账户与会话](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)、[模型调用](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)、[限制](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)。
