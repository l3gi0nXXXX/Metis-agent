# Metis 共享与通道覆盖 TTS/ASR 配置落地方案

> **给后续执行 agent 的要求：** 实施本方案时必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans` 逐任务执行。任务使用复选框（`- [ ]`）跟踪状态。

**目标：** 将 Metis 的 TTS 与 ASR 从 Telegram 专属实现收敛为“Gateway 共享默认配置 + IM 通道覆盖配置”的语音能力。所有 IM 默认复用共享 provider，同时允许每个 IM 通道配置自己的 TTS/ASR，并且通道配置优先级高于共享配置。

**架构：** 参考 OpenClaw 的 `messages.tts.providers`、`tools.media.audio.models` 与 voice-call 深合并 override 设计，以及 Hermes 的全局 `tts:` / `stt:` 工具层和平台发送接口，Metis 应新增 Gateway 级 `speech` 默认配置、通道级 `speech` override 与共享 runtime。Telegram 继续只负责 `[voice]` / `[audio]` payload 投递，ASR 继续挂在 `gatewayMediaUnderstandingForRecord` 媒体理解边界内，不把 provider 执行逻辑塞进 IM adapter。

**技术栈：** Cangjie、`magic.jsonable`、`stdx.encoding.json`、Metis Gateway/channel/session 架构、Cangjie 单元测试、fake command provider、禁止真实 IM 网络调用。

---

## 1. 有代码证据的参考分析

本节只记录已按真实文件逐段读取的实现证据。后续实现不得绕开这些边界自创另一套逻辑。

### 1.1 OpenClaw TTS 证据

| 证据 | 文件/行号 | 已确认行为 | 对 Metis 的约束 |
|---|---:|---|---|
| TTS facade 从 speech-core 暴露 provider/runtime API，而不是放在 Telegram extension | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/tts/tts.ts:1-33`，`/Users/l3gi0n/work/workspace_cangjie/openclaw/src/plugin-sdk/tts-runtime.ts:1-81` | Core TTS API 通过 plugin-sdk facade 共享，包括 `maybeApplyTtsToPayload`、`synthesizeSpeech`、`textToSpeech`、provider setter/status API。 | Metis 应建立 core Gateway speech runtime，让 Telegram 调用它，而不是把 provider 解析继续留在 `gateway_telegram_native_tool_commands.cj`。 |
| TTS 配置使用 provider 集合形态 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/commands/doctor/shared/legacy-config-migrations.runtime.tts.ts:10-84` | 旧的 `messages.tts.openai/elevenlabs/microsoft/edge` 会迁移到 `messages.tts.providers.<provider>`。 | Metis 共享配置应使用 `gateway.speech.tts.providers.<provider>` 或同等结构，不能继续以 `gateway.channelsExtra.telegramTts` 作为长期配置入口。 |
| voice-call 插件会把自己的 TTS override 与 core TTS 配置深合并 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/voice-call/src/telephony-tts.ts:26-80`，`/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/voice-call/src/config.ts:358-359`，`:417-425`，`:484` | Telephony 有自己的 `tts` override；`applyTtsOverride` 会把 `coreConfig.messages.tts` 与插件 override 合并后再调用 runtime。 | Metis 的 IM 通道级配置应以更高优先级覆盖共享 speech 配置，同时未显式覆盖的 provider 字段应继承共享默认值。 |
| Telegram 发送音频只做投递层选择 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/telegram/src/send.ts:924-950`，`/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/telegram/src/voice.ts:1-35` | Telegram extension 只在调用方要求 voice 且音频兼容 Telegram voice 时使用 `sendVoice`，否则回退 `sendAudio`。 | Metis Telegram adapter 必须继续保持投递层职责。TTS runtime 返回音频路径和投递偏好，adapter 只映射到 `sendVoice` / `sendAudio`。 |

### 1.2 OpenClaw ASR / 媒体理解证据

| 证据 | 文件/行号 | 已确认行为 | 对 Metis 的约束 |
|---|---:|---|---|
| 旧 ASR 配置迁移到 media audio models | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/commands/doctor/shared/legacy-config-migrations.audio.ts:35-60` | `audio.transcription` 会迁移到 `tools.media.audio.models`，从而启用 media audio capability。 | Metis ASR 应建模为共享媒体/音频能力，而不是 Telegram 专属命令。 |
| Runtime 按 capability 分发 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/media-understanding/runtime.ts:45-93`，`:147-155` | `runMediaUnderstandingFile` 接收 `capability: "audio"`，归一化附件，运行 provider registry，返回 `audio.transcription`。 | Metis 应扩展现有 `gatewayMediaUnderstandingForRecord(record, capability: "audio")`，不要新增 channel-local ASR 入口。 |
| Provider registry 会合并插件 provider 和配置派生 provider | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/media-understanding/provider-registry.ts:34-89` | Media provider 来自 plugin capability providers 和模型配置，并按 normalized id 合并。 | Metis 第一阶段可以只支持 command provider，但配置形态要给后续 provider registry 留扩展空间。 |
| 自动音频 fallback 会先检查本地 CLI，再走 API provider | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/media-understanding/runner.ts:307-392`，`:566-598` | Audio auto mode 可选择 sherpa/whisper-cli/whisper 本地 CLI，然后才是 key-backed provider。 | Metis 应优先支持免费/本地 command ASR，因为用户明确倾向免费方案。 |
| CLI ASR runner 使用模板参数、临时输出目录、timeout、输出提取和清理 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/media-understanding/runner.entries.ts:639-719` | command 和 args 分离；placeholder 包含 media path/output dir/prompt/max chars；临时输出会删除。 | Metis command provider 必须使用数组 argv，不允许 shell string；必须使用临时输出和 timeout；测试不得写真实用户配置。 |
| Telegram 入站音频 preflight 调用共享 media-understanding runtime | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/telegram/src/bot-message-context.body.ts:175-214`，`:224-235` | Telegram 只用 `transcribeFirstAudio` 获取 mention/body 判断所需文本；转写本身不在 Telegram transport 内实现。 | Metis Telegram 应通过 media understanding 调用共享 ASR runtime；禁止把 ASR provider 逻辑加到 Telegram adapter。 |

### 1.3 Hermes TTS 证据

| 证据 | 文件/行号 | 已确认行为 | 对 Metis 的约束 |
|---|---:|---|---|
| TTS provider 配置是全局 `tts:` | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:18-24`，`:203-224` | TTS 配置从 `~/.hermes/config.yaml` 的 `tts` 读取，provider 默认 Edge。 | Metis 应提供 Gateway 全局 TTS 默认配置。 |
| 免费默认 provider 和 provider 限制集中定义 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:5-18`，`:91-160`，`:163-197` | Edge 是默认免费 provider；每个 provider 的 max text length 集中管理。 | Metis 应支持 provider 级 `maxChars`，并提供 Edge TTS 这类 command provider 示例。 |
| TTS 工具会按平台选择输出格式，但 provider 选择仍由用户配置驱动 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:917-960`，`:969-975`，`:1087-1112` | 同一套 TTS provider 配置被复用；Telegram 只影响 Opus/voice-compatible 输出和 `[[audio_as_voice]]`。 | Metis 应把共享 provider 默认放在 Gateway speech 配置，同时允许 channel override 选择不同 provider 或投递格式。 |
| Gateway base adapter 拥有 voice delivery 接口 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/gateway/platforms/base.py:1237-1269` | Base platform 有 `send_voice` 和 `play_tts`，子类覆盖具体投递方式。 | Metis `ChannelAdapter` 应继续作为投递抽象；speech runtime 不应知道 Telegram Bot API 细节。 |
| Gateway auto-TTS 调用共享 tool 后再调用 `play_tts` | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/gateway/platforms/base.py:2113-2148` | Auto-TTS 由 `tools.tts_tool` 生成，再通过 adapter `play_tts` 投递。 | Metis 后续 IM auto-TTS 应复用同一 speech runtime，再通过 channel payload/action 支持投递。 |
| Telegram adapter 只按文件扩展名映射到 sendVoice/sendAudio | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/gateway/platforms/telegram.py:1722-1768` | `.ogg/.opus` 走 `send_voice`，其他音频走 `send_audio`。 | Metis Telegram 应保留当前 `[voice]` / `[audio]` payload 解析，不把 provider 逻辑拉进 adapter。 |

### 1.4 Hermes ASR 证据

| 证据 | 文件/行号 | 已确认行为 | 对 Metis 的约束 |
|---|---:|---|---|
| STT provider 配置是全局 `stt:`，并被 messaging gateway 使用 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:1-27`，`:99-113` | `stt` 配置共享；注释明确说明用于 Telegram、Discord、WhatsApp、Slack、Signal。 | Metis ASR 应提供 Gateway 全局默认配置，并允许 IM 通道覆盖。 |
| Provider 选择尊重显式配置；未显式配置时优先自动探测免费/本地 provider | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:186-277` | 显式 provider 会被尊重，不静默回退到云 provider；未显式配置时顺序是 local faster-whisper/local command/Groq/OpenAI/Mistral/xAI。 | Metis 不得在用户显式配置本地/免费 ASR 时静默回退到付费云 ASR；auto 模式可以优先免费/本地 command。 |
| 音频文件校验集中处理 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:284-309` | provider 调用前检查文件存在、文件类型、扩展名和大小。 | Metis ASR runtime 应在 command 执行前校验 local path/downloaded/max bytes。 |
| `transcribe_audio` 是单一公开 STT 入口 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:695-775` | STT 返回 `{success, transcript, error, provider}`，不可用时提示免费本地安装方式。 | Metis 应提供共享 runtime 函数，返回结构化状态：`ok`、`not_configured`、`provider_error`、`timeout`、`too_large`。 |
| Platform base 缓存 voice 文件供 STT 读取 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/gateway/platforms/base.py:454-467` | voice messages 会下载到共享 audio cache，STT 从本地文件读取。 | Metis 应复用 Telegram media archive path 和未来 IM media archive 作为 ASR 输入根，不读任意真实用户文件。 |

### 1.5 Metis 当前状态证据

| 证据 | 文件/行号 | 当前行为 | 必须调整 |
|---|---:|---|---|
| Gateway 有强类型 channel 配置和通用 `channelsExtra` escape hatch | `/Users/l3gi0n/work/workspace_cangjie/Metis/src/core/config/gateway_user_settings.cj:501-559` | `GatewayUserSettings` 拥有 `telegram`、`feishu`、`qq`、tools/subagents/webchat 和 `channelsExtra`。 | 在 `GatewayUserSettings` 下增加一等公民共享 `speech`，并为 IM 通道增加 channel-level speech override 字段；`channelsExtra.telegramTts` 只作为兼容输入。 |
| Telegram action settings 已经拆分投递能力 | `/Users/l3gi0n/work/workspace_cangjie/Metis/src/core/config/gateway_user_settings.cj:257-277` | `actions.audio` 和 `actions.voice` 是 channel-specific send permissions。 | TTS provider 配置不应放在 actions 中；actions 只保留投递权限。 |
| 当前 TTS 是 Telegram 专属 | `/Users/l3gi0n/work/workspace_cangjie/Metis/src/gateway/core/gateway_telegram_native_tool_commands.cj:190-241`，`:264-283`，`:300-339`，`:341-411` | 状态写在 `gateway-telegram/tts`，配置读取 `channelsExtra.telegramTts`，状态文本写 “Telegram native TTS”。 | 将 provider 配置和 runner 抽到 core Gateway speech runtime；Telegram 命令只负责渲染状态并调用 runtime。 |
| 当前 TTS command 已使用安全数组执行 | `/Users/l3gi0n/work/workspace_cangjie/Metis/src/gateway/core/gateway_telegram_native_tool_commands.cj:243-250`，`:309-328` | command 是数组，支持 `{text}` 和 `{output}`，`withWrap: false`，有 timeout 和 output path 检查。 | 抽到共享 runtime 后必须保留这个安全属性。 |
| ASR runtime 已经共享，但目前只支持测试 override 和 companion file | `/Users/l3gi0n/work/workspace_cangjie/Metis/src/core/gateway_media_understanding_runtime.cj:8-38`，`:251-301` | `gatewayMediaTranscribeAudioPathForRuntime` 返回 test override 结果或空；audio fallback 读取 record transcript 或 companion file。 | 在这里或相邻 core speech runtime 中接入配置化 command ASR；保持 media-understanding 调用点不变。 |
| Telegram media toolset 已经调用共享 media understanding | `/Users/l3gi0n/work/workspace_cangjie/Metis/src/gateway/tools/gateway_telegram_media_toolset.cj:1049-1101`，`:1996-2008` | `telegram_audio_transcribe` 委托 `gatewayMediaUnderstandingForRecord(record, capability: "audio")`。 | 禁止把 ASR provider 逻辑加到 `gateway_telegram_media_toolset.cj`。 |
| Message payload 已区分 audio 与 voice | `/Users/l3gi0n/work/workspace_cangjie/Metis/src/core/gateway_message_payloads.cj:233-292` | `[audio]` 和 `[voice]` payload 可通用渲染/解析。 | 共享 TTS runtime 可以返回这两类 payload，无需 Telegram-specific provider 逻辑。 |
| Telegram adapter 按 payload kind 映射 Bot API 方法 | `/Users/l3gi0n/work/workspace_cangjie/Metis/src/gateway/channels/telegram/telegram_adapter.cj:6466-6537` | `voice` 映射到 `sendVoice`，`audio` 映射到 `sendAudio`。 | Adapter 继续保持 delivery-only 层。 |

## 2. 目标配置形态

新配置应以 `gateway.speech` 作为共享默认配置，并允许每个 IM 通道覆盖自己的 `tts` 和 `asr`。通道配置优先级高于共享配置；通道未声明的字段从共享配置继承。

```json
{
  "gateway": {
    "speech": {
      "tts": {
        "enabled": true,
        "provider": "edge",
        "maxChars": 4000,
        "outputDir": "",
        "providers": {
          "edge": {
            "kind": "command",
            "command": ["edge-tts", "--text", "{text}", "--write-media", "{output}"],
            "outputExtension": "mp3",
            "timeoutMs": 10000
          }
        }
      },
      "asr": {
        "enabled": true,
        "provider": "local",
        "maxBytes": 26214400,
        "providers": {
          "local": {
            "kind": "command",
            "command": ["python3", "/path/to/transcribe.py", "{input}"],
            "timeoutMs": 60000
          }
        }
      }
    },
    "telegram": {
      "speech": {
        "tts": {
          "provider": "telegram-edge",
          "providers": {
            "telegram-edge": {
              "kind": "command",
              "command": ["edge-tts", "--voice", "zh-CN-XiaoxiaoNeural", "--text", "{text}", "--write-media", "{output}"],
              "outputExtension": "ogg",
              "timeoutMs": 10000
            }
          }
        },
        "asr": {
          "provider": "telegram-local",
          "providers": {
            "telegram-local": {
              "kind": "command",
              "command": ["python3", "/path/to/telegram_transcribe.py", "{input}"],
              "timeoutMs": 60000
            }
          }
        },
        "audioAsVoice": true
      },
      "actions": {
        "audio": true,
        "voice": true
      }
    },
    "channelsExtra": {
      "telegram": {
        "speech": {
          "audioAsVoice": true
        }
      }
    }
  }
}
```

兼容规则：

- 共享默认路径：`gateway.speech.tts` 和 `gateway.speech.asr`。
- 通道覆盖路径：`gateway.<channel>.speech.tts` 和 `gateway.<channel>.speech.asr`。
- 解析优先级：通道覆盖 > 共享默认 > legacy 兼容。
- legacy 只读 fallback：`gateway.channelsExtra.telegramTts`。
- legacy fallback 绝对不能覆盖显式通道配置或共享 speech 配置。
- 诊断信息应提示用户从 `gateway.channelsExtra.telegramTts` 迁移到 `gateway.telegram.speech.tts` 或 `gateway.speech.tts`。

## 3. 分阶段实施方案

### 阶段 1：增加共享 Speech 配置模型和兼容解析器

**文件：**
- 修改：`src/core/config/gateway_user_settings.cj`
- 新增：`src/core/gateway_speech_config.cj`
- 测试：`src/core/gateway_speech_config_test.cj`
- 文档：`docs/user/telegram.md`

**实施内容：**

- 新增 `GatewaySpeechUserSettings`、`GatewaySpeechTtsUserSettings`、`GatewaySpeechAsrUserSettings`、`GatewaySpeechProviderUserSettings`。
- 在 `GatewayUserSettings` 下新增 `public var speech: GatewaySpeechUserSettings = GatewaySpeechUserSettings()`。
- 为内置 IM 配置增加通道级 speech override 字段：
  - `TelegramUserSettings.speech: GatewayChannelSpeechUserSettings`
  - 后续 `FeishuUserSettings.speech` 和 `QQUserSettings.speech` 在对应通道获得语音收发能力时使用同一形态。
- 实现解析函数：
  - `gatewaySpeechResolveTtsConfig(user: GatewayUserSettings, channel!: String = ""): JsonObject`
  - `gatewaySpeechResolveAsrConfig(user: GatewayUserSettings, channel!: String = ""): JsonObject`
  - `gatewaySpeechResolveDeliveryPrefs(user: GatewayUserSettings, channel!: String = ""): JsonObject`
- 解析器必须按以下顺序合并：
  1. 共享默认 `gateway.speech.tts` / `gateway.speech.asr`
  2. 通道覆盖 `gateway.<channel>.speech.tts` / `gateway.<channel>.speech.asr`，覆盖共享字段，并深合并 provider 对象
  3. 只有当共享和通道 TTS command/provider 都不存在时，才读取 legacy `gateway.channelsExtra.telegramTts`
  4. 投递偏好来自 `gateway.<channel>.speech` 和兼容路径 `gateway.channelsExtra.<channel>.speech`

**严格测试项：**

- [x] `gatewaySpeechResolveTtsConfig(user, channel: "telegram")` 在通道和共享 provider 都配置时返回 `gateway.telegram.speech.tts.provider`。
- [x] `gatewaySpeechResolveTtsConfig(user, channel: "telegram")` 在通道 override 只覆盖 provider 级 voice/output 字段时，继承共享 provider 的 command 字段。
- [x] `gatewaySpeechResolveAsrConfig(user, channel: "telegram")` 在通道和共享 ASR provider 都配置时返回 `gateway.telegram.speech.asr.provider`。
- [x] `gatewaySpeechResolveTtsConfig` 在通道 override 缺失时返回共享 `gateway.speech.tts.provider`。
- [x] `gatewaySpeechResolveTtsConfig` 只有在通道和共享 command/provider 都缺失时才返回 legacy `channelsExtra.telegramTts.command`。
- [x] `gatewaySpeechResolveDeliveryPrefs` 优先读取通道 speech config 的 `audioAsVoice`，其次读取 `channelsExtra.telegram.speech.audioAsVoice`。
- [x] provider 配置无效或缺失时返回空 provider，不抛异常。
- [x] 测试只使用内存中的 `GatewayUserSettings` 和 `JsonObject`，不得读写 `~/.metis`。

**验收项：**

- `cjpm test src/core --no-color --no-progress --show-all-output` 通过。2026-05-09 已验证：82 passed、0 failed。
- `cjpm clean && cjpm build -i && cjpm test` 已执行。2026-05-09 结果：`cjpm clean` 和 `cjpm build -i` 通过；全量 `cjpm test` 出现 `metis.gateway.core`、`metis.gateway.runtime` package launch exit code 9，但总计 685 passed、0 failed。随后单独重跑 `cjpm test src/gateway/core --no-color --no-progress --show-all-output` 通过 127 passed、0 failed；`cjpm test src/gateway/runtime --no-color --no-progress --show-all-output` 通过 208 passed、0 failed。

### 阶段 2：抽取共享 TTS Runtime

**文件：**
- 新增：`src/core/gateway_speech_tts_runtime.cj`
- 修改：`src/gateway/core/gateway_telegram_native_tool_commands.cj`
- 测试：`src/core/gateway_speech_tts_runtime_test.cj`
- 测试：`src/gateway/core/gateway_service_telegram_native_test.cj`

**实施内容：**

- 将 Telegram command 中的 TTS command 执行语义迁移到 core runtime：
  - command 必须是数组，禁止 shell string；
  - placeholder 支持 `{text}` 和 `{output}`；
  - provider status 包括 `ok`、`not_configured`、`not_found`、`disabled`、`too_large`、`provider_error`、`timeout`；
  - 输出文件只能位于临时目录、测试 fixture 目录或用户显式配置的 `outputDir`；
  - 默认输出扩展名必须在安全 allowlist 内：`mp3`、`wav`、`m4a`、`opus`、`oga`、`ogg`；
  - `fake` provider 仅作为测试兼容 provider 保留。
- `gatewayTelegramRenderTtsCommand` 调用共享 runtime，只负责将结果转换为 Telegram 命令的人类可读输出或 `[voice]` / `[audio]` payload。
- 状态文案从 “Telegram TTS” 改为 “Gateway TTS”，除非该行明确描述 Telegram 投递偏好。

**严格测试项：**

- [x] `fake` provider 在 `audioAsVoice=true` 时返回 `[voice]`。
- [x] `fake` provider 在 `audioAsVoice=false` 时返回 `[audio]`。
- [x] command provider 收到拆分后的 argv，并正确替换 `{text}` 与 `{output}`；不得 shell wrapping。
- [x] command provider timeout 返回结构化 `timeout`。
- [x] command provider 非 0 退出返回 `provider_error`，且不泄露 env secrets。
- [x] command provider 未写出音频文件时返回 `provider_error`。
- [x] Telegram native `/tts status` 在配置 `gateway.telegram.speech.tts` 时报告通道 provider。
- [x] Telegram native `/tts status` 在 Telegram override 缺失时 fallback 到共享 `gateway.speech.tts` provider。
- [x] legacy `channelsExtra.telegramTts` 仍可工作，并在 status 中包含迁移提示。
- [x] 测试使用临时 Metis home/output dir 和 fake command；不得调用真实 Edge/OpenAI/Telegram。

**验收项：**

- `cjpm test src/core --no-color --no-progress --show-all-output` 通过。2026-05-09 已验证：89 passed、0 failed。
- `cjpm test src/gateway/core --no-color --no-progress --show-all-output` 通过。2026-05-09 已验证：127 passed、0 failed。
- 执行完整 `cjpm clean && cjpm build -i && cjpm test`。2026-05-09 结果：clean/build 通过；全量 test 出现 `metis.gateway.core`、`metis.gateway.runtime` package launch exit code 9，但 685 passed、0 failed。随后单独重跑 `src/gateway/core` 通过 127 passed、0 failed；`src/gateway/runtime` 通过 208 passed、0 failed。

### 阶段 3：在媒体理解 Runtime 中实现共享 ASR Command Provider

**文件：**
- 新增或扩展：`src/core/gateway_speech_asr_runtime.cj`
- 修改：`src/core/gateway_media_understanding_runtime.cj`
- 测试：`src/core/gateway_media_understanding_runtime_test.cj`
- 测试：`src/gateway/tools/gateway_telegram_media_toolset_test.cj`

**实施内容：**

- 为 `gatewayMediaTranscribeAudioPathForRuntime` 增加配置化 ASR command provider 路径。
- 当 media record 含有 `channel` / `accountId` 元数据时，将 channel context 传入 ASR 解析，让 Telegram voice 优先使用 `gateway.telegram.speech.asr`，再使用共享 `gateway.speech.asr`。
- 保留测试 override 优先级：
  1. record transcript / `asrTranscript`
  2. 已安装的 test override
  3. 已配置的通道 ASR provider，例如 `gateway.telegram.speech.asr`
  4. 已配置的共享 ASR provider，即 `gateway.speech.asr`
  5. companion transcript file
  6. `not_configured`
- ASR command placeholder：
  - `{input}`：已下载本地媒体路径
  - `{mime}`：MIME type
  - `{output}`：临时 transcript 输出路径
  - `{outputDir}`：临时输出目录
- command 结果处理：
  - 如果 command 写出 `{output}`，读取该文件；
  - 否则使用 trimmed stdout；
  - 空输出根据 provider 是否实际运行区分 `not_configured` 或 `provider_error`；
  - timeout 和 exit code 必须进入结构化 decision attempts。

**严格测试项：**

- [x] 已有 record transcript 优先于配置化 ASR provider。
- [x] test override 优先于配置化 provider，并保持当前测试可用。
- [x] 配置化 command provider 从临时目录读取 fake audio 并返回 `ASRStatus=transcribed`。
- [x] media record channel 为 `telegram` 时，通道 ASR provider 优先于共享 ASR provider。
- [x] media record channel 无 override 时使用共享 ASR provider。
- [x] 配置化 command provider 可以通过 stdout 返回 transcript。
- [x] 配置化 command provider 可以通过 `{output}` 文件返回 transcript。
- [x] 非音频媒体返回 `unsupported`。
- [x] 超过 maxBytes 的媒体在 command 执行前返回 `too_large`。
- [x] 无 provider 且无 companion file 时返回 `ASRStatus=not_configured`。
- [x] Telegram `telegram_audio_transcribe` 原样接收共享 ASR 输出。
- [x] 测试不得触碰真实 Telegram 网络、真实 bot token、真实 `~/.metis` 或用户媒体归档。

**验收项：**

- `cjpm test src/core --no-color --no-progress --show-all-output` 通过。2026-05-09 使用包含项目 `ffi/` 的 `DYLD_LIBRARY_PATH` 验证：99 passed、0 failed。
- `cjpm test src/gateway/tools --no-color --no-progress --show-all-output` 通过。2026-05-09 使用包含项目 `ffi/` 的 `DYLD_LIBRARY_PATH` 验证：75 passed、0 failed。
- 执行完整 `cjpm clean && cjpm build -i && cjpm test`。2026-05-09 已执行，详见第 4 节最终验证记录。

### 阶段 4：接入通道投递偏好，但不重复 provider 执行逻辑

**文件：**
- 修改：`src/gateway/core/gateway_telegram_native_tool_commands.cj`
- 仅必要时修改：`src/core/gateway_message_payloads.cj`
- 仅必要时修改：`src/gateway/channels/telegram/telegram_adapter.cj`
- 测试：`src/core/gateway_message_payloads_test.cj`
- 测试：`src/gateway/channels/telegram/telegram_adapter_test.cj`

**实施内容：**

- 保持 `[voice]` / `[audio]` payload 作为 Gateway 投递契约。
- Telegram adapter 继续只做投递：
  - 不解析 TTS provider；
  - 不解析 ASR provider；
  - 只按 payload kind 和已有 action permission 选择 `sendVoice` / `sendAudio`。
- 后续 Feishu/QQ 增加 voice delivery 时，必须消费同一 speech runtime 输出，先解析自己的通道 override，再回退共享默认，并独立实现通道投递。

**严格测试项：**

- [x] `[voice]` payload 仍映射到 Telegram `sendVoice`。
- [x] `[audio]` payload 仍映射到 Telegram `sendAudio`。
- [x] 禁用 `telegram.actions.voice` 时，即使 TTS runtime 成功，也拒绝 voice delivery。
- [x] 禁用 `telegram.actions.audio` 时，即使 TTS runtime 成功，也拒绝 audio delivery。
- [x] Telegram adapter 测试中不读取 provider 配置。
- [x] Telegram command/core 测试验证通道 override 优先级；Telegram adapter 测试保持 delivery-only。

**验收项：**

- `cjpm test src/gateway/channels/telegram --no-color --no-progress --show-all-output` 通过。2026-05-09 使用包含项目 `ffi/` 的 `DYLD_LIBRARY_PATH` 验证：193 passed、0 failed。
- 执行完整 build/test 命令。2026-05-09 已执行，详见第 4 节最终验证记录。

### 阶段 5：文档、迁移诊断和 Smoke Checklist

**文件：**
- 修改：`docs/user/telegram.md`
- 新增或更新：`develop_steps/metis-speech-shared-tts-asr-smoke-checklist-2026-05-09.md`
- 必要时更新：`develop_steps/metis-telegram-smoke-test-checklist-2026-05-08.md`

**实施内容：**

- 更新 Telegram 文档：
  - `gateway.speech.tts` / `gateway.speech.asr` 是共享默认配置；
  - `gateway.telegram.speech.tts` / `gateway.telegram.speech.asr` 是 Telegram override，优先级更高；
  - `gateway.channelsExtra.telegramTts` 仅为 legacy 兼容；
  - Telegram-specific 设置包括投递偏好、action permissions 和可选 provider override。
- 增加 smoke checklist：
  - Telegram `/tts status`
  - Telegram `/tts audio <text>`
  - Telegram voice note 通过 `telegram_audio_transcribe` 走 ASR
  - 未来 IM 通道复用 TTS/ASR
  - 重启恢复

**严格测试项：**

- [x] `rg "gateway.channelsExtra.telegramTts" docs/user develop_steps` 只出现 legacy/migration 语义，不作为 canonical instruction。
- [x] `rg "gateway.speech.tts|gateway.speech.asr|gateway.telegram.speech.tts|gateway.telegram.speech.asr" docs/user/telegram.md develop_steps` 能看到共享默认和通道 override 示例。
- [x] Smoke checklist 同时包含手动测试和自动测试。
- [x] Smoke checklist 明确禁止自动化测试使用真实 token 和真实用户配置。

**验收项：**

- 文档内部一致。2026-05-09 已用 `rg` 检查 canonical/legacy 描述。
- 手动 checklist 中的命令可在 Telegram 中执行，且不强制依赖付费 provider。

## 4. 端到端验证要求

每个代码阶段都必须以以下命令收尾：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
export DYLD_LIBRARY_PATH="/Users/l3gi0n/cangjie100/runtime/lib/darwin_aarch64_llvm:/Users/l3gi0n/cangjie100/tools/lib:/Users/l3gi0n/work/workspace_cangjie/CangjieMagic/libs/cangjie-stdx-mac-aarch64-1.0.0.1/darwin_aarch64_llvm/dynamic/stdx:/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH"
cjpm clean
cjpm build -i
cjpm test
```

本轮实际验证发现 `src/core`、`src/gateway/core`、`src/gateway/runtime` 等测试包在本机还需要项目 `ffi/` 下的动态库，因此本机完整验证命令应使用：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
export DYLD_LIBRARY_PATH="/Users/l3gi0n/work/workspace_cangjie/Metis/ffi:/Users/l3gi0n/cangjie100/runtime/lib/darwin_aarch64_llvm:/Users/l3gi0n/cangjie100/tools/lib:/Users/l3gi0n/work/workspace_cangjie/CangjieMagic/libs/cangjie-stdx-mac-aarch64-1.0.0.1/darwin_aarch64_llvm/dynamic/stdx:/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH"
cjpm clean
cjpm build -i
cjpm test
```

如果聚合 `cjpm test` 报告 package launch error 且没有测试失败数，必须用 `--show-all-output` 单独重跑该 package，并把结果记录到对应 `develop_steps` 文件。

### 4.1 2026-05-09 最终验证记录

本轮最终验证使用本机必须的 `DYLD_LIBRARY_PATH`，包含项目 `ffi/`、Cangjie runtime/tools、stdx dynamic lib 与 Homebrew OpenSSL。

已执行完整命令：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
export DYLD_LIBRARY_PATH="/Users/l3gi0n/work/workspace_cangjie/Metis/ffi:/Users/l3gi0n/cangjie100/runtime/lib/darwin_aarch64_llvm:/Users/l3gi0n/cangjie100/tools/lib:/Users/l3gi0n/work/workspace_cangjie/CangjieMagic/libs/cangjie-stdx-mac-aarch64-1.0.0.1/darwin_aarch64_llvm/dynamic/stdx:/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH"
cjpm clean && cjpm build -i && cjpm test --parallel 1 --no-color --no-progress --no-capture-output --timeout-each=120s
```

结果：

- `cjpm clean`：通过。
- `cjpm build -i`：通过；仅有项目 `ffi/` 动态库 target minimum 版本 warning。
- 聚合 `cjpm test`：1018 passed、0 failed、2 package launch errors（`metis.core.tools`、`metis.program`，均为 exit code 9）。这两个 package 不属于本轮 speech 改动面。
- 按项目要求单独重跑聚合报错 package：
  - `cjpm test src/core/tools --no-color --no-progress --show-all-output`：5 passed、0 failed。
  - `cjpm test src/program --no-color --no-progress --show-all-output`：8 passed、0 failed。

本轮 speech 相关 package 均已明确通过：

- `src/core`：99 passed、0 failed。
- `src/gateway/core`：127 passed、0 failed。
- `src/gateway/tools`：75 passed、0 failed。
- `src/gateway/channels/telegram`：193 passed、0 failed。

额外说明：

- 直接运行聚合 `cjpm test --no-color --no-progress` 时曾出现 `metis.gateway.core`、`metis.mcp` package launch exit code 9；单独重跑分别通过 127 passed、0 failed 和 4 passed、0 failed。
- 聚合 runner 在本机存在 package launch 不稳定现象；所有相关 package 已按单包 `--show-all-output` 复核通过。

## 5. 不可突破的架构边界

- 不得把 TTS 或 ASR provider 执行逻辑加到 Telegram transport/adapter。
- 单元测试不得发起真实网络调用。
- 自动化测试不得使用真实 Telegram bot token、真实 proxy credential 或真实 `~/.metis` 文件。
- 用户显式配置本地/免费 ASR 时，不得静默回退到付费云 ASR。
- 不得执行 shell string；command provider 必须使用数组 argv 和 `withWrap: false`。
- 不得移除现有 Telegram `[voice]` / `[audio]` 投递行为。
- legacy `gateway.channelsExtra.telegramTts` 在迁移窗口前不得破坏。
- 共享 `gateway.speech` 不得覆盖显式 IM 通道 `gateway.<channel>.speech` 配置。

## 6. 自检结果

- 需求覆盖：OpenClaw TTS、OpenClaw ASR、Hermes TTS、Hermes ASR 和当前 Metis 架构都已绑定到上方文件/行号证据。
- 占位扫描：无 `TBD` / `TODO` 占位项。
- 边界检查：provider 选择和通道 override 解析位于 core Gateway speech/media runtime；channel adapter 保持 delivery-only。
- 测试覆盖：每个阶段都有明确自动化测试项，并要求完整 Cangjie 验证。
