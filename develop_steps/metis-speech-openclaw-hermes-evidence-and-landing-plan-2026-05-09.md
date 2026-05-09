# Metis Speech OpenClaw/Hermes Evidence And Landing Plan 2026-05-09

## 目标

在不修改 Metis 代码的前提下，先梳理 OpenClaw、OpenClaw-China、Hermes 中 TTS/ASR 的实际源码实现，再制定 Metis 后续落地方案，并等待确认后再进入实施。

## 调研边界

本轮只做源码取证和方案设计，不做代码改动。检索范围覆盖：

- `/Users/l3gi0n/work/workspace_cangjie/openclaw`
- `/Users/l3gi0n/work/workspace_cangjie/openclaw-china`
- `/Users/l3gi0n/work/workspace_cangjie/hermes-agent`
- Metis 当前 speech runtime/config 边界：`src/core/gateway_speech_config.cj`、`src/core/gateway_speech_tts_runtime.cj`、`src/core/gateway_speech_asr_runtime.cj`

## OpenClaw 源码证据

### TTS 总体架构

| 能力 | 源码证据 | 结论 |
| --- | --- | --- |
| Speech provider 插件接口 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/plugins/types.ts:1668` 定义 `SpeechProviderPlugin`，包含 `resolveConfig`、`isConfigured`、`synthesize`、`synthesizeTelephony`、`listVoices` | OpenClaw 的 TTS 是 provider 插件化，不是硬编码单一 provider。 |
| Provider 注册 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/plugins/registry.ts:720` 注册 speech provider；`:730` 注册 realtime transcription provider | speech / realtime transcription 都通过插件注册表接入。 |
| Provider 发现 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/tts/provider-registry.ts:52` `listSpeechProviders`；`:56` `getSpeechProvider` | TTS runtime 不直接依赖某个 provider 文件，而是按 provider id 查注册表。 |
| TTS config 解析 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/speech-core/src/tts.ts:314` `resolveTtsConfig` 读取 `messages.tts`、`provider`、`providers`、`timeoutMs`、`maxTextLength` | 共享 TTS 配置集中在 `messages.tts`，provider 配置放在 `messages.tts.providers.<id>`。 |
| Provider 自动选择和 fallback | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/speech-core/src/tts.ts:533` `resolveTtsProviderOrder`；`:721` `synthesizeSpeech` 遍历 providers 并记录 attempts | OpenClaw TTS 有主 provider + fallback provider 顺序。 |
| 输出目标区分 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/speech-core/src/tts.ts:721` `synthesizeSpeech` 内根据 channel 判断 `voice-note` 或 `audio-file` | Telegram/Feishu/WhatsApp/Matrix 这类通道优先 voice-note。 |
| 自动 TTS | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/speech-core/src/tts.ts:955` `maybeApplyTtsToPayload`；`:388` `buildTtsSystemPromptHint` | OpenClaw 同时支持模型显式 tool TTS 和 runtime 自动 TTS。 |

### OpenAI-compatible TTS

| 能力 | 源码证据 | 结论 |
| --- | --- | --- |
| OpenAI TTS endpoint | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/openai/tts.ts:132` 对 `${baseUrl}/audio/speech` 发 POST | OpenClaw 对 OpenAI-compatible TTS 的实际调用路径是 `baseUrl + /audio/speech`。 |
| 请求体 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/openai/tts.ts:139` JSON body 包含 `model`、`input`、`voice`、`response_format`、可选 `speed`、`instructions` | `qwen3-tts-flash` 如果走 OpenAI-compatible，Metis 应复用这类请求形态。 |
| 自定义 baseUrl 放宽校验 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/openai/tts.ts:39` `isCustomOpenAIEndpoint`；`:46` `isValidOpenAIModel`；`:53` `isValidOpenAIVoice` | 非默认 baseUrl 时，模型名和 voice 不限制在 OpenAI 官方列表，因此 `qwen3-tts-flash`、`Chelsie` 可以作为自定义 endpoint 配置。 |
| OpenAI provider config | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/openai/speech-provider.ts:18` 配置字段包含 `apiKey`、`baseUrl`、`model`、`voice`、`speed`、`instructions` | Metis 不应只支持 command provider，应增加原生 OpenAI-compatible provider。 |
| 配置读取路径 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/openai/speech-provider.ts:47` 从 `rawConfig.providers.openai` 或 legacy `rawConfig.openai` 读取 | 推荐 Metis 采用共享 `gateway.speech.tts.providers.<id>` + channel override，而不是把 provider 配置散落到各 IM 实现。 |
| voice-note 输出格式 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/openai/speech-provider.ts:174` `req.target === "voice-note" ? "opus" : "mp3"` | Telegram 场景应要求 provider 直接产出 opus，或 Metis 在必要时转码。 |

### 模型可调用 TTS Tool

| 能力 | 源码证据 | 结论 |
| --- | --- | --- |
| TTS tool 定义 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/tools/tts-tool.ts:17` `createTtsTool` | 模型可以显式调用 `tts` tool。 |
| 防重复回复 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/tools/tts-tool.ts:25` description 要求成功后回复 `SILENT_REPLY_TOKEN` | Tool 成功投递音频后，应避免再发一条同内容文本。 |
| 结构化媒体结果 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/tools/tts-tool.ts:38` 返回 `details.media.mediaUrl`，并按 `voiceCompatible` 设置 `audioAsVoice` | Metis 应继续保持 tool result 结构化媒体，而不是仅靠文本关键词。 |
| 系统提示 Voice section | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/system-prompt.ts:233` 构建 `## Voice (TTS)` section | 模型何时使用 TTS，需要通过系统提示明确能力和限制。 |

### OpenClaw ASR / STT

| 能力 | 源码证据 | 结论 |
| --- | --- | --- |
| 全局音频转写配置 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/config/schema.base.generated.ts:17191` `Audio Transcription`；`:17199` 描述 “Global audio ingestion settings” | OpenClaw 有全局 audio transcription 配置，主要用于语音/媒体进入更高层工具前的确定性转写。 |
| Legacy 转写迁移 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/config/legacy.shared.ts:57` `mapLegacyAudioTranscription` | OpenClaw 兼容旧音频转写配置。 |
| Realtime transcription provider | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/plugins/types.ts:1694` `RealtimeTranscriptionProviderPlugin` | OpenClaw 把实时语音转写和普通文件 ASR 分开。 |
| OpenAI realtime voice 内置 transcription | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/openai/realtime-voice-provider.ts:349` `input_audio_transcription.model = "whisper-1"`；`:405` 处理 `conversation.item.input_audio_transcription.completed` | 实时语音模式用 realtime provider，不等同于 IM voice 文件 ASR。 |

## OpenClaw-China 源码证据

### 共享腾讯云 Flash ASR

| 能力 | 源码证据 | 结论 |
| --- | --- | --- |
| Tencent Flash ASR provider | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/packages/shared/src/asr/tencent-flash.ts:1` 开始实现；`:59` `transcribeTencentFlash` | OpenClaw-China 的 ASR 是 Node 原生实现，不是 Python。 |
| 签名算法 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/packages/shared/src/asr/tencent-flash.ts:76` 构造 `POST asr.cloud.tencent.com/asr/flash/v1/<appId>?query` 签名文本；`:77` HMAC-SHA1 | 腾讯云 Flash ASR 需要 provider 专用签名，不适合用普通 OpenAI-compatible ASR 直接替代。 |
| 请求路径 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/packages/shared/src/asr/tencent-flash.ts:10` `https://asr.cloud.tencent.com/asr/flash/v1` | 若 Metis 支持 Tencent ASR，应实现专用 provider kind。 |
| 错误类型 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/packages/shared/src/asr/errors.ts:1` 定义 `timeout/auth/request/response_parse/service/empty_result` | Metis ASR 应返回结构化错误，区分认证、超时、空结果和服务错误。 |

### QQBot ASR / Voice 处理

| 能力 | 源码证据 | 结论 |
| --- | --- | --- |
| ASR 配置解析 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/qqbot/src/config.ts:304` `resolveQQBotASRCredentials` | OpenClaw-China 保留通道级 ASR 配置。 |
| 语音附件识别 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/qqbot/src/bot.ts:787` 判断 `voice` 或 `audio/*` | ASR 入口在通道媒体解析层。 |
| ASR 调用 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/qqbot/src/bot.ts:890` 调用 `transcribeTencentFlash` | QQBot 直接复用 shared ASR provider。 |
| ASR 失败回退 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/qqbot/src/bot.ts:816` 构建用户可见 fallback；`:3117` ASR 出错时发送 fallback 并终止后续 agent 分发 | 语音识别失败时不要让模型猜测音频内容。 |
| TTS-like 文本清理 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/qqbot/src/bot.ts:1428` 清理 `[[tts:text]]`、`[[audio_as_voice]]` 等 directive | 通道出站应清理控制标记，不能把内部 directive 原样发给用户。 |
| outbound voice 元数据 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/qqbot/src/outbound.ts:193` audio 识别为 voice；`:228` voice 时写入 transcriptSource `tts` | 发送语音时应保留 transcript/source 元数据，便于引用和追踪。 |

### WeChat MP / WeCom App ASR 与 Voice

| 能力 | 源码证据 | 结论 |
| --- | --- | --- |
| WeChat MP ASR 配置 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/wechat-mp/src/config.ts:227` `resolveWechatMpASRCredentials` | 通道配置可以继承/覆盖 ASR。 |
| WeChat MP ASR 调用 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/wechat-mp/src/dispatch.ts:5` 引入 `transcribeTencentFlash` | 多个中国 IM 共享同一个 ASR 实现。 |
| WeCom App ASR 配置 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/wecom-app/src/config.ts:352` `resolveWecomAppASRCredentials` | WeCom App 也保留通道自己的 ASR 配置。 |
| WeCom App voice 入站 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/wecom-app/src/bot.ts:279` 处理 `msgtype === "voice"`；`:293` 读取语音文件；`:304` 调用 `transcribeTencentFlash` | 入站语音先落盘再识别，失败时使用平台自带 Recognition 或文件路径回退。 |
| WeCom App voice 出站 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/wecom-app/src/channel.ts:537` voice 类型出站；`:549` `downloadAndSendVoice`；`:556` 转码失败后 fallback 到 file | IM 原生 voice 发送必须考虑格式要求和转码失败回退。 |
| WeCom App voice 上传/发送 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/wecom-app/src/api.ts:921` `uploadWecomVoice`；`:987` `msgtype: "voice"` | 语音发送是通道能力，不应塞进通用 TTS provider 内。 |

## Hermes 源码证据

### TTS

| 能力 | 源码证据 | 结论 |
| --- | --- | --- |
| Provider 列表 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:3` 文档列出 Edge、ElevenLabs、OpenAI、MiniMax、Mistral、Gemini、NeuTTS | Hermes 的 TTS 是多 provider，不只 OpenAI。 |
| 默认免费 provider | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:90` `DEFAULT_PROVIDER = "edge"` | 免费默认方案是 Edge TTS。 |
| OpenAI TTS | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:349` `_generate_openai_tts`；`:376` 创建 OpenAI client；`:387` `client.audio.speech.create` | Hermes OpenAI TTS 走 OpenAI SDK，支持 `base_url` 覆盖。 |
| MiniMax TTS | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:465` `_generate_minimax_tts`；`:525` POST `base_url` | Hermes 对不同 provider 采用 provider-specific 实现，不强行统一成一个 HTTP 形状。 |
| Gemini TTS | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:635` `_generate_gemini_tts`；`:681` `models/<model>:generateContent` | Gemini TTS 不是 OpenAI-compatible endpoint。 |
| Telegram voice 输出 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:955` Telegram 需要 Opus；`:1091` 必要时 ffmpeg 转 opus | IM voice 需要按平台格式处理。 |
| TTS tool 入口 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:917` `text_to_speech_tool` | Hermes 模型工具层也暴露 TTS。 |

### STT / ASR

| 能力 | 源码证据 | 结论 |
| --- | --- | --- |
| Provider 列表 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:3` 文档列出 local、groq、openai、mistral、xai | Hermes ASR 是多 provider。 |
| 默认免费 provider | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:67` `DEFAULT_PROVIDER = "local"`；`:59` 检测 `faster_whisper` | 默认免费方案是本地 faster-whisper。 |
| local command | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:142` 支持 `HERMES_LOCAL_STT_COMMAND` 或本地 whisper CLI | Metis 现有 command ASR 与 Hermes local command 思路一致。 |
| OpenAI/Groq/Mistral/xAI | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:448` Groq；`:500` OpenAI；`:557` Mistral；`:596` xAI | 不同 ASR provider 需要不同 endpoint 和 SDK/HTTP 实现。 |
| 文件限制 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:81` 支持格式；`:83` 25MB 上限 | Metis ASR 应保留 maxBytes/格式检查，避免把大文件直接发云端。 |
| 主入口 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:695` `transcribe_audio` | Gateway voice/audio 入站最终进入统一转写入口。 |

### Gateway voice 行为

| 能力 | 源码证据 | 结论 |
| --- | --- | --- |
| voice.tts RPC | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tui_gateway/server.py:3947` `@method("voice.tts")` 调用 `speak_text` | Hermes 有显式 TTS RPC。 |
| agent reply 自动 TTS | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tui_gateway/server.py:2199` voice-mode TTS 打开时朗读 agent final text | 用户进入 voice mode 后，文本回复可被自动转语音。 |
| Gateway media voice | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/gateway/platforms/base.py:1237` `send_voice`；`:1257` `play_tts` | 语音投递是平台 adapter 能力。 |
| MEDIA + audio_as_voice | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/gateway/platforms/base.py:1333` 提取 `MEDIA:` 和 `[[audio_as_voice]]` | 工具产出音频后通过通用 media 机制投递。 |
| Telegram sendVoice | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/gateway/platforms/telegram.py:1722` `send_voice`；`:1743` 调 Telegram `send_voice` | Telegram voice bubble 是 adapter 责任。 |

## Metis 当前状态

| 能力 | 源码证据 | 现状 |
| --- | --- | --- |
| 共享/通道配置合并 | `src/core/gateway_speech_config.cj` 中 `gatewaySpeechResolveTtsConfig` / `gatewaySpeechResolveAsrConfig`；通道配置覆盖共享配置 | 已具备“共享默认 + IM 通道覆盖”的基础。 |
| TTS runtime provider kind | `src/core/gateway_speech_tts_runtime.cj` 中 `speechTtsProviderKind` 只识别 `fake`、`command`，status 只有这两类为 `ok` | 缺少 OpenAI-compatible、Tencent/MiniMax/Gemini 等原生 provider。 |
| ASR runtime provider kind | `src/core/gateway_speech_asr_runtime.cj` 中 `speechAsrProviderKind` 只识别 `command` | 缺少 OpenAI-compatible、Tencent Flash、Groq/Mistral/xAI 等原生 ASR provider。 |
| TTS tool | `src/gateway/tools/gateway_tts_toolset.cj` 已把模型 TTS tool 接入 Gateway delivery | 已有 OpenClaw-style 模型可调用 TTS 的基础。 |
| Telegram ASR tool | `src/gateway/tools/gateway_telegram_media_toolset.cj` `telegram_audio_transcribe` 接入 `gatewaySpeechAsrTranscribeAudioPath` | 已有 IM 入站音频转写入口，但 provider 仍偏 command。 |

## 方案原则

1. 不引入 Python wrapper 作为首选实现。OpenClaw 和 OpenClaw-China 的证据都支持 Node/原生 provider 化；Metis 应在 Cangjie runtime 内实现 provider。
2. 保留 `gateway.speech.tts/asr` 共享配置，并保留各 IM 通道自己的 `gateway.<channel>.speech.tts/asr` 覆盖配置；通道覆盖优先级高于共享配置。
3. Provider 负责“生成/识别音频”；通道 adapter 负责“如何作为 voice/audio/file 发出去”。不要把 Telegram/WeCom 等平台投递规则塞进 provider。
4. TTS 和 ASR 都需要结构化状态：`ok`、`not_configured`、`disabled`、`not_found`、`timeout`、`provider_error`、`too_large`、`empty_result`、`auth_error`。
5. 所有自动化测试必须使用 fake server、临时 HOME/METIS_HOME、fake token、临时媒体目录，不能读写真实 `~/.metis` 和真实 IM。

## 分阶段落地方案

### Phase 1：OpenAI-compatible TTS 原生 provider

**范围**

- 在 Metis TTS runtime 增加 provider kind：`openai-compatible`。
- 支持配置字段：`apiKey`、`baseUrl`、`model`、`voice`、`responseFormat`、`speed`、`instructions`、`timeoutMs`、`degradeMessage`。
- 请求形态参考 OpenClaw：`POST ${baseUrl}/audio/speech`，body 包含 `model/input/voice/response_format`。
- 非默认 baseUrl 不限制 model/voice 值，允许 `qwen3-tts-flash`、`Chelsie`。

**验收项**

1. `gatewaySpeechTtsStatus` 对 `kind=openai-compatible` 返回 `ok`，缺 key 返回 `not_configured` 或 `auth_error`，未知 kind 仍返回 `not_found`。
2. 单元测试使用本地 fake HTTP server，断言请求 path 为 `/audio/speech`，header 带 Bearer，body 包含 `model/input/voice/response_format`。
3. fake server 返回二进制音频后，Metis 生成 `[voice]` 或 `[audio]` payload，并且不写真实 `~/.metis`。
4. fake server 返回 401/500/非 JSON/超时，返回结构化错误，日志和返回值不得泄露 API key。
5. 执行 `source /Users/l3gi0n/cangjie100/envsetup.sh && cjpm clean && cjpm build -i && cjpm test` 通过。

### Phase 2：OpenAI-compatible ASR 原生 provider

**范围**

- 在 Metis ASR runtime 增加 provider kind：`openai-compatible`。
- 支持配置字段：`apiKey`、`baseUrl`、`model`、`language`、`timeoutMs`、`maxBytes`。
- 默认请求形态参考 OpenAI Whisper-compatible：`POST ${baseUrl}/audio/transcriptions`，multipart 文件 + `model` + 可选 `language`。
- 保留 command provider 作为本地 ASR/Whisper/用户自定义 provider。

**验收项**

1. 对 voice/audio 文件，ASR fake server 能收到 multipart 请求并返回 transcript。
2. 文件不存在、非音频、超过 `maxBytes` 时直接本地失败，不发 HTTP。
3. `gateway.telegram.speech.asr` 覆盖 `gateway.speech.asr`，测试用两个 fake provider 返回不同 transcript 验证优先级。
4. 401/timeout/empty transcript 返回结构化错误，模型不能收到“猜测内容”。
5. 执行统一 Cangjie build/test 通过。

### Phase 3：Tencent Flash ASR 原生 provider

**范围**

- 参考 OpenClaw-China `transcribeTencentFlash`，在 Metis 增加 `kind=tencent-flash` ASR provider。
- 支持 `appId`、`secretId`、`secretKey`、`engineType`、`voiceFormat`、`timeoutMs`。
- HMAC-SHA1 签名、query 排序、`application/octet-stream` body 行为与 OpenClaw-China 对齐。

**验收项**

1. fake Tencent ASR server 验证签名输入、query 参数、body 原始音频 bytes。
2. 响应 `flash_result[].text` 和 `sentence_list[].text` 都能提取 transcript。
3. `code != 0`、401/403、非 JSON、空结果、超时都映射到结构化 ASR 错误。
4. QQ/WeCom/WeChat 未来接入时复用同一 provider，不复制签名逻辑。
5. 执行统一 Cangjie build/test 通过。

### Phase 4：TTS provider fallback 与 degradeMessage

**范围**

- 参考 OpenClaw provider order，实现主 provider + fallback provider 顺序。
- 支持 `degradeMessage`：TTS 失败但文本可达时，发送降级文本，不重复发送 silent 或空消息。
- 记录 attempts：provider、outcome、reasonCode、latencyMs。

**验收项**

1. 主 provider fake 500，fallback provider fake 200，最终发送 fallback 音频并记录 `fallbackFrom`。
2. 所有 provider 失败时返回 `degradeMessage` 文本；若未配置 degradeMessage，返回明确 TTS 失败诊断。
3. `autoReplyToVoice=true` 时，ASR 成功后的回复如果 TTS 失败，不丢消息，不发两条互相矛盾的回复。
4. attempts 中不包含 secret、Authorization header 或完整请求体。
5. 执行统一 Cangjie build/test 通过。

### Phase 5：IM voice/audio 投递格式治理

**范围**

- 参考 Hermes/OpenClaw-China，把 provider 输出和 IM 投递解耦。
- Telegram：优先 voice-note，支持 `audioAsVoice`；必要时明确要求 provider 输出 `opus/ogg/oga`，或引入受控 ffmpeg 转码。
- 后续 Feishu/QQ/WeCom：保留通道侧 voice/audio/file 发送策略，不让 TTS provider 直接知道平台 API。

**验收项**

1. Telegram fake Bot API 覆盖 `sendVoice`、`sendAudio`，断言 `audioAsVoice=true` 走 `sendVoice`。
2. provider 输出不兼容格式时，若转码不可用，返回清晰诊断或降级 file/audio，不静默失败。
3. 通道 directive 如 `[[audio_as_voice]]`、`[[tts:text]]` 不泄露到用户可见文本。
4. 不访问真实 Telegram，不使用真实 bot token。
5. 执行统一 Cangjie build/test 通过。

### Phase 6：文档、配置迁移和手动 smoke

**范围**

- 更新 `docs/user/telegram.md` 和 speech smoke checklist。
- 给出共享配置和 Telegram override 配置示例。
- 明确真实云 provider 的安全配置建议：不要把 key 发到聊天里；优先支持环境变量/secret 引用，如果 Metis 当前配置系统不支持，则先文档标红风险。

**验收项**

1. 文档包含 `gateway.speech.tts`、`gateway.telegram.speech.tts`、`gateway.speech.asr`、`gateway.telegram.speech.asr` 示例。
2. 文档明确 `qwen3-tts-flash` 走 OpenAI-compatible TTS provider，而不是 Python wrapper。
3. 手动 smoke 覆盖：`/tts status`、`/tts audio ...`、Telegram voice 入站 ASR、voice 入站自动语音回复、TTS 失败降级。
4. `develop_steps/metis-speech-shared-tts-asr-smoke-checklist-2026-05-09.md` 更新测试记录。
5. 执行统一 Cangjie build/test 通过。

## 待确认问题

1. `languageType`：当前本地 OpenClaw/OpenClaw-China/Hermes 源码未找到明确读取逻辑。是否作为 DashScope provider-specific pass-through 字段保留，需要进一步用 DashScope 官方接口或你手头 OpenClaw 私有分支确认。
2. `degradeMessage`：当前本地 OpenClaw OpenAI speech provider 未看到读取逻辑，但它符合 Metis 产品需求，可以在 Metis fallback 阶段实现。
3. API key 形态：是否要本轮顺带实现 env/secret 引用，例如 `{ "env": "DASHSCOPE_API_KEY" }`，避免在 `metis.json` 明文保存。
4. 转码策略：是否允许依赖本机 `ffmpeg`，还是 Phase 1 只要求 provider 输出 Telegram 可直接发送的格式。

## 建议实施顺序

推荐先确认并执行 Phase 1 + Phase 4 的最小闭环：OpenAI-compatible TTS 原生 provider + fallback/degradeMessage。这样可以直接解决 `qwen3-tts-flash` 作为 TTS 大模型的问题，同时不破坏当前 command/fake provider 和 Telegram 自动语音回复链路。

Phase 2/3 再处理 ASR provider 扩展：OpenAI-compatible ASR 适合 Whisper/Groq-like provider，Tencent Flash ASR 适合国内 IM 和免费额度场景。
