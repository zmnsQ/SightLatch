# 手机读屏代理：模型供应商与订阅适配

核查日期：2026-10-14。只读官方公开文档及官方开源项目；没有登录、获取凭证、抓 cookies、发付费请求、运行或编译代码。先查看现有研究目录，未发现可回答供应商认证问题的本地实现，随后查官方网页。模型名称、额度和计划条款会变动，原型应允许用户填写准确模型 ID。

## 最短决策

- **可以实现：** OpenAI Responses、OpenAI-compatible Chat Completions、Anthropic Messages、Gemini generateContent 四种传输协议；选择支持图片的模型，用户自行填写有效API凭证。百炼视觉模型可走兼容协议。
- **不能承诺：** 一个通用“用ChatGPT账号登录即可使用订阅额度”的原生iOS模型接口。ChatGPT订阅和API分开计费，Codex客户端的订阅认证不是所有第三方应用都可使用的 OAuth 服务。
- **不应接入本用途：** 阿里 Coding Plan 官方限制其使用范围，禁止自动化脚本、自定义应用后端或非交互式批量调用。此手机跨app执行循环应选正常按量API；“兼容格式”不意味着允许借用编程套餐。
- **需用户确认名称：** “WorkBody”暂按WorkBuddy研究，“Tree”暂按TRAE研究；不是已确认同一产品。

## 1. 协议与图片格式

### OpenAI Responses

POST https://api.openai.com/v1/responses；Authorization: Bearer 用户APIKey；Content-Type: application/json。

请求骨架：model + input 数组，user 的 content 内放 `{ "type": "input_text", "text": "任务和输出要求" }` 与 `{ "type": "input_image", "image_url": "data:image/jpeg;base64,..." }`。

原始HTTP回复从 output 中 message 的 content 里取 output_text 类型的 text；不要依赖SDK提供的 response.output_text便利属性一定存在于原始JSON顶层。需处理拒绝、incomplete、错误和空内容，不解析到动作便不执行。[官方图片指南](https://developers.openai.com/api/docs/guides/images-vision)。

### OpenAI-compatible Chat Completions

POST 用户指定的base URL下 /chat/completions（是否包含 /v1 要规范化）；Bearer认证。请求 model + messages；user.content 使用 `{ "type": "text", "text": "任务" }`、`{ "type": "image_url", "image_url": { "url": "data:image/jpeg;base64,..." } }`。回复通常是 choices[].message.content。

这是协议模式，不是模型能力保证。部分网关不接图片、不支持某些结构化输出参数，或者仅实现文本。UI要明确标识“模型须支持图片”；不应把HTTP 200视作视觉任务完成。百炼官方确认 image_url.url支持公网URL和Base64 Data URL，但不同地域API key/base URL不同。[百炼兼容接口](https://help.aliyun.com/zh/model-studio/qwen-api-via-openai-chat-completions/)、[视觉指南](https://help.aliyun.com/zh/model-studio/vision/)。

### Anthropic Messages

POST https://api.anthropic.com/v1/messages。x-api-key 仍受支持；anthropic-version: 2023-06-01；Content-Type: application/json。当前文档也接受Bearer形式，且多workspace key可能额外要求anthropic-workspace-id，原型可注明仅支持标准单workspace API key。[官方API概览](https://platform.claude.com/docs/en/api/overview)。

请求 model、max_tokens、messages；图片 content block：`{ "type": "image", "source": { "type": "base64", "media_type": "image/jpeg", "data": "纯base64" } }`；文字 block：`{ "type": "text", "text": "任务" }`。这里data不加data URI前缀。回复content数组中筛选text block，并检查stop_reason；不把thinking或工具块当动作。[官方视觉说明](https://platform.claude.com/docs/en/build-with-claude/vision)。

### Gemini generateContent

POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent；x-goog-api-key；Content-Type: application/json。

contents[].parts 内放 `{ "inline_data": { "mime_type": "image/jpeg", "data": "纯base64" } }` 及 `{ "text": "任务" }`。从candidates[].content.parts[]筛选text；检查finishReason、安全阻止及空候选。

Google当前文档把generateContent归为Legacy，并提供Interactions迁移文档；“Legacy”不等于已经不能调用。首版用有明确公开图片示例的generateContent，并保留后续协议切换空间，不声称它是最新唯一推荐接口。[官方图片请求](https://ai.google.dev/gemini-api/docs/generate-content/image-understanding)、[迁移说明](https://ai.google.dev/gemini-api/docs/migrate-to-interactions)。

## 2. ChatGPT订阅、Codex认证、通用API是三个层次

OpenAI明确ChatGPT与API平台账单独立；订阅不自动给通用API支付。[官方计费说明](https://help.openai.com/en/articles/9039756-managing-billing-settings-on-chatgpt-web-and-platform)。

Codex官方认证文档列出ChatGPT登录获得订阅访问、API key获得按量访问；说明的客户端包括桌面app、Codex CLI及IDE扩展。当前文档还区分企业Codex access token与一般OpenAI API：一般API继续使用Platform API key。[官方认证文档](https://developers.openai.com/codex/auth)（当前重定向到learn.chatgpt.com/docs/auth）。

结论边界：不能从Codex开源源码含登录逻辑、存在token，推导“任意iOS应用获准复用该client ID/订阅端点”。也不能反向断言所有未来第三方集成永远被禁止。本次未查到供这个独立iOS读屏应用注册并使用的通用订阅OAuth授权方案，故原型仅做API key入口。若以后使用官方CLI/SDK桥接，应作为独立架构核实认证和用途，并承认它增加电脑或服务端依赖；不抓网页会话或复制缓存token。

## 3. WorkBuddy / CodeBuddy候选

官方确认WorkBuddy与CodeBuddy同账号积分共享。[个人订阅说明](https://www.codebuddy.cn/docs/workbuddy/Pricing)。但积分共享范围的描述不是第三方手机模型API授权。

存在两类真正公开的开发接口：
- WorkBuddy Managed Agents 企业API：托管Agent定义、版本、会话及运行资源，提供ADK/REST。[官方概览](https://cloud.tencent.com/document/api/1831/138581)。
- CodeBuddy Code HTTP API（Beta）：在运行CLI的机器上开启HTTP服务，公开REST及ACP接口。[官方HTTP说明](https://cloud.tencent.com/document/product/1831/137064)。

它们可以作为后续正式集成的研究候选，但不应偷换成“手机直接调用个人WorkBuddy会员的任意模型”。本次未验证其个人订阅范围、图像请求协议或本案手机自动操作用途许可。CLI桥还不满足当前不依赖电脑的目标。

另一个方向是WorkBuddy作为客户端接自定义API。官方支持填URL/key/model，并区分图片输入能力；这是API流入WorkBuddy，不是WorkBuddy向外输出其订阅额度。[模型配置](https://www.codebuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Model)。

## 4. TRAE候选

TRAE官方模型文档支持内置模型及自定义API；自定义模式可选OpenAI Chat Completions、Anthropic Messages并填服务商key。这里是用户自带API进入TRAE。[官方模型配置](https://docs.trae.cn/ide_models)。

ByteDance官方开源TRAE-agent也是多供应商客户端，README要求所选供应商的API key。不能以仓库名称或支持多模型推导它可以消费TRAE会员额度。[官方仓库README](https://github.com/bytedance/TRAE-agent/blob/main/README.md)。本次没有查到第三方iOS app直接消费TRAE个人会员额度的公开模型API，因此不做“TRAE订阅登录”入口。

## 5. 千问Coder / Coding Plan

需要区分Qwen Code这个开源工具、阿里Coding Plan订阅、百炼标准模型API以及具体模型。

阿里Coding Plan文档明确限制编程工具中的使用；禁止用于自动化脚本、自定义应用程序后端及非交互式批量调用，违规可能暂停订阅/封禁key。这个跨app手机自动代理不能因为有key就当普通推理API接入。[官方Coding Plan条款](https://help.aliyun.com/zh/model-studio/coding-plan)。

Qwen Code当前认证文档说明Qwen OAuth免费层已于2026-04-15结束；旧教程里浏览器登录领取免费额度不能作为当前方案。[当前认证文档](https://qwenlm.github.io/qwen-code-docs/en/users/configuration/auth/)。

可行替代：用户自己的百炼普通API，选择明确具备视觉输入能力的模型并按正确地域配置。不能从模型名字带Coder推导它会看图，也不要把纯OCR后的文字自动当成与原图等价。

## 6. 可复用公开适配项目与本原型选择

- [Vercel AI SDK](https://github.com/vercel/ai)：官方开源TypeScript多供应商抽象；适合作为协议/能力组织参考或将来有服务端时采用。不是Swift库，不应为ReplayKit小扩展引入Node运行时。本次读了项目主页，具体转换源文件抓取失败，因此不宣称完成源码级核验。
- [Qwen Code](https://github.com/QwenLM/qwen-code)：官方[供应商配置文档](https://qwenlm.github.io/qwen-code-docs/en/users/configuration/model-providers/)区分openai/anthropic/gemini及Chat Completions/Responses wireApi；可借鉴配置模型，但工具及其订阅认证不可混同通用API服务。
- [TRAE-agent](https://github.com/bytedance/TRAE-agent)：已读官方README的多供应商、API key与自定义URL配置；适合研究代理抽象，不是订阅转API工具。
- [OpenAI Codex](https://github.com/openai/codex)：官方CLI实现参考，可核对官方客户端认证；不是此iOS原型可直接嵌入的通用订阅OAuth组件。

本原型建议采用Swift URLSession + 4个小型协议适配器，以统一ImageRequest/ActionResponse模型隔离供应商差异。图片统一压缩JPEG，单请求、有限历史、限制大小；非2xx、解析失败、拒绝、无图能力、超时均禁止HID执行。base URL自定义前明确说明该服务会收到屏幕画面；更换供应商不能静默上传到新接收方。key不写源码、日志、AppGroup明文配置；由用户在其设备安全输入并保存在适当Keychain共享访问组中。

## 7. 明确未验证事项

没有测任何账号实际额度、网络可达性、模型ID、各服务图像质量或坐标能力；没有签署新的服务协议；没有编译/运行适配器。供应商对坐标输出和schema支持不同，实际手机闭环必须逐供应商验收。此报告提供工程与公开产品边界，不能替代供应商对具体订阅用途的确认。

## 8. 追加：第三方订阅接入的实际源码调查

用户要求进一步查看GitHub后，确认第三方订阅接入**确实有实际实现**。前文“没有查到供本iOS应用注册的官方通用订阅OAuth”不等于“技术上没有实现”。以下是源码证据，不是服务方对本用途的许可，也没有在本次运行验证。分支会变化；引用为2026-10-14所见main/dev，不冒充固定版本或完整安全审计。

### A. CLIProxyAPI：最适合复用为可选外部网关

- [项目](https://github.com/router-for-me/CLIProxyAPI)是Go代理服务，根目录标MIT；提供OpenAI/Responses、Claude、Gemini兼容入口，README声明支持图片。它不是iOS Swift SDK。
- 已读 [Codex OAuth源文件](https://github.com/router-for-me/CLIProxyAPI/blob/main/internal/auth/codex/openai_auth.go)：实现授权码+PKCE、刷新token；授权/交换地址在auth.openai.com；固定使用与Codex插件相同的client ID，回调为localhost:1455。是主动OAuth登录路径，不是必须抓ChatGPT网页cookie；这条路径不证明本应用拥有自己的client注册。
- 已读 [Chat Completions→Codex转换源码](https://raw.githubusercontent.com/router-for-me/CLIProxyAPI/main/internal/translator/codex/openai/chat-completions/codex_openai_request.go)：用户message中的image_url被映射为input_image；工具图片也有单独转换函数。由此可以确认代码层存在视觉数据通路，而不只是README声称。它还做schema/tool转换、store=false和参数裁剪，说明Codex后端不是换个Bearer就与普通API完全等价。
- 当前executor入口已重构为适配器，所读入口文件仅20行；不能仅凭它完成当前所有网络路径审计。本次未成功读到新client核心，因此CLIProxyAPI最终Codex请求端点的源码链尚未完全追到；同类OpenCode实现的端点已明确见下。
- **可借：** 图片/文本协议转换、SSE解析思路、配置/模型能力隔离、失败分类。最快产品集成是手机保留“自定义兼容API地址”，用户自行管理可信网关；不是我们部署、登录或导入凭证。
- **代价：** 需要另一台电脑或服务器持续运行；它可以仅代理AI，手机仍直接向ESP32发动作，但已不满足“只有手机、完全无网关”的部署目标。代理可以看到画面与模型凭证，应使用用户控制的实例、HTTPS和独立客户端认证，不能把第三方托管中转当等价安全方案。

### B. OpenCode：实际内置Codex订阅适配

已读搜索返回的 [packages/opencode/src/plugin/openai/codex.ts](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/plugin/openai/codex.ts) 源码内容：使用固定Codex client ID；PKCE/state；auth.openai.com授权与刷新；本地HTTP回调端口1455；目标是 `https://chatgpt.com/backend-api/codex/responses`。依赖Node http、os、timer及OpenCode插件/认证框架，无法原样贴进Swift扩展。[根LICENSE为MIT](https://github.com/anomalyco/opencode/blob/dev/LICENSE)。

图像证据边界：该认证文件主要重写认证/请求，不能单独证明所有模型和图片路径已正确。另读到[OpenCode的OpenAI请求转换文件](https://github.com/anomalyco/opencode/blob/dev/packages/console/app/src/routes/zen/util/provider/openai.ts)含input_image、image_url、base64 source转换；但它属于console/Zen路径，**不能将它直接当成Codex OAuth路径端到端成功证明**。若选OpenCode作为运行端，应另做新截图的实际识别测试。

**可借：** OAuth状态机、过期刷新、账户ID/请求适配的设计；它的存在证明第三方工具可实现订阅接入。**不可直接搬：** Node/Bun本地服务、文件认证存储、默认client ID/回调假设、整套桌面agent运行时。iOS移植须另处理系统浏览器会话、回调兼容、Keychain、扩展隔离与后台退出；不能仅加一个登录按钮便声称完成。

### C. numman-ali/opencode-openai-codex-auth：较小、便于研究的参考

已读 [lib/auth/auth.ts](https://github.com/numman-ali/opencode-openai-codex-auth/blob/main/lib/auth/auth.ts)：注释明确OAuth常量来自openai/codex；用PKCE及随机state，提供授权码换token；固定Codex client ID和localhost回调。已读[constants.ts](https://raw.githubusercontent.com/numman-ali/opencode-openai-codex-auth/main/lib/constants.ts)：backend-api基址、/codex/responses路径、chatgpt-account-id与originator头均显式定义，浏览器开启方式面向macOS/Windows/Linux。

因此它是一个可读的“OAuth+Codex后端适配”小样本，不要求窃取cookie，也不是厂商为本iOS App发放的通用授权。已检查的request-transformer文件未找到显式image分支；本次不把它列为独立确认的图片适配实现。可借鉴认证模块拆分和错误处理，不推荐为截图代理直接整体依赖。

特别注意[LICENSE](https://github.com/numman-ali/opencode-openai-codex-auth/blob/main/LICENSE)标题是“MIT License with Usage Disclaimer”，另有个人开发用途、第三方条款遵守及商业/生产API提示，复制时必须连同usage notice保留；不能只写“纯MIT、任意用途已获许可”。

### D. CLIProxyAPIPlus：名称可确认，但当前上游未完整取得

router-for-me/CLIProxyAPIPlus的仓库主页/README本次读取失败，其中raw README返回404；不能猜测删除、改名或仍维护。发现[公开fork vjeantet/cliproxyapiplus](https://github.com/vjeantet/cliproxyapiplus)的README写明Plus添加社区维护的第三方provider、MIT许可；它不能代替当前上游维护状态或具体provider源码审计。

因此本次不以“Plus一定支持某订阅/某图像格式”作为实现依据，也不推荐安装随机同名打包站。先选已读核心源码的CLIProxyAPI主线更可审计。若用户给出确切Plus仓库，应再核对固定commit、provider实现、许可证和凭证处理。

### E. 官方Codex源码对照

已读[官方login server.rs](https://raw.githubusercontent.com/openai/codex/main/codex-rs/login/src/server.rs)：确有本地回调、PKCE/state、授权码交换与凭证持久化。与第三方相似的认证代码能证明技术机制来源；不意味着其开源代码许可证自动授予模型服务使用权。服务授权、代码许可、原生iOS可运行性是三件独立的事。

### 当前应如何避免从零造轮子

1. 首版统一图像请求和动作协议，四种官方API格式用小型Swift适配器；配置里保留base URL，未来可对接用户已有兼容网关。
2. 订阅研究优先复用CLIProxyAPI做**外置网关候选**，而不是在iOS广播扩展内移植完整Go/Node代理。是否接受额外网关由用户决定。
3. 若坚持手机原生订阅OAuth，将其作为独立实验模块，参考OpenCode/小插件，但必须先验证认证回调和服务方用途边界，再处理扩展安全存储与刷新；此轮没有承诺它已经实现。
4. 不使用多账号轮换、额度绕过、客户端身份伪装或cookie抓取来保证可用；对于上游401/403/429、图片被拒或接口变化，清楚报错并停下，不能继续执行旧HID动作。
5. “不依赖API key”仍需保护OAuth refresh token；它不是无需凭证、无限额度或更低隐私风险。任何移植代码仍须保留相应许可证与声明。
