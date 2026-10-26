# Fish Audio 语音播报

在「设置 → 语音与播报」选择 Fish Audio，保存自己的 API Key，选择模型和音色后试听。密钥保存在本机 Keychain，不进入任务记录、配置导出或 Git。音色 ID 可从 Fish Audio 音色页面复制；留空使用平台默认声音。

「进度播报」控制会话中的自动语音。关闭时取消正在合成、排队和播放的声音，保留已经开启的语音指令监听。手动「试听」可在播报关闭时使用，不会打开播报开关或启动任务。

Fish Audio 只接收要朗读的短句，不接收屏幕截图、聊天历史或麦克风录音。选用云端音色后，合成需要网络和该平台的可用额度。请求失败时显示原因，任务可以继续，不会自动切回系统声音。系统音色仍可在同一设置页选择。

适配使用官方 `POST https://api.fish.audio/v1/tts`，Bearer 认证、`model` 请求头与 JSON 请求体，返回 MP3。音频只在内存中播放。停止、静音、换音色或会话失效会取消合成并丢弃迟到的音频。

开发验证使用模拟 HTTP 响应检查请求、错误、取消和音频边界，不使用真实密钥，也不代表已验证平台实际音质。真实试听需在 App 本地配置密钥。

官方参考（核对日期：2026-10-26）：

- [快速开始](https://docs.fish.audio/developer-guide/getting-started/quickstart)
- [Text to Speech API](https://docs.fish.audio/api-reference/endpoint/openapi-v1/text-to-speech)
- [模型说明](https://docs.fish.audio/developer-guide/models-pricing/models-overview)
