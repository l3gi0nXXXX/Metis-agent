# Metis Speech Final Target Phased Landing Plan 2026-05-09

## 目标形态

Metis 最终要形成一套 Gateway 级统一 Speech 能力：

```text
IM 入站 voice/audio/file
  -> 通道 adapter 下载、保存、标注媒体类型
  -> Gateway Speech ASR runtime 统一转写
  -> Gateway session / model / tool
  -> Gateway Speech TTS runtime 统一合成
  -> 通道 adapter 按平台规则发送 voice/audio/file
```

核心规则：

1. `gateway.speech.tts/asr` 是全局共享默认配置。
2. `gateway.<channel>.speech.tts/asr` 是通道覆盖配置，优先级高于共享默认配置。
3. TTS/ASR provider 逻辑在 Gateway Speech runtime 内统一实现，不散落到每个 IM 通道。
4. IM 通道只负责通道协议能力：下载媒体、保存媒体、发送 voice/audio/file、平台格式转换和 fallback。
5. 模型可以显式调用 `tts` tool 发语音；voice/audio 入站也可以按配置自动转成语音回复。

## 源码依据

### OpenClaw

| 结论 | 源码依据 |
| --- | --- |
| TTS 是 speech provider 插件体系，不是 Python wrapper | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/plugins/types.ts:1668` `SpeechProviderPlugin` |
| provider 注册由插件注册表统一管理 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/plugins/registry.ts:720` `registerSpeechProvider` |
| TTS config 位于 `messages.tts`，provider 配置位于 `providers.<id>` | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/speech-core/src/tts.ts:314` `resolveTtsConfig` |
| TTS provider 支持主 provider + fallback 顺序 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/speech-core/src/tts.ts:533` `resolveTtsProviderOrder`；`:721` `synthesizeSpeech` |
| OpenAI-compatible TTS 调用 `${baseUrl}/audio/speech` | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/openai/tts.ts:132` |
| 自定义 `baseUrl` 时放宽 model/voice 校验 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/openai/tts.ts:39`、`:46`、`:53` |
| 模型可调用 `tts` tool，成功后用 silent token 避免重复文本 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/tools/tts-tool.ts:17`、`:25` |
| TTS tool 返回结构化 media，并通过 `audioAsVoice` 指示 voice 投递 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/tools/tts-tool.ts:38` |
| 自动 TTS 会在 payload 层添加音频 media，不让通道自己合成 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/speech-core/src/tts.ts:955` `maybeApplyTtsToPayload` |

### OpenClaw-China

| 结论 | 源码依据 |
| --- | --- |
| 中国 IM ASR 使用共享 Tencent Flash ASR 实现 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/packages/shared/src/asr/tencent-flash.ts:59` `transcribeTencentFlash` |
| Tencent Flash ASR 需要专用签名和 endpoint | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/packages/shared/src/asr/tencent-flash.ts:10`、`:76`、`:77` |
| ASR 错误有结构化分类 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/packages/shared/src/asr/errors.ts:1` |
| QQBot 保留通道级 ASR 配置 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/qqbot/src/config.ts:304` |
| QQBot voice/audio 入站调用 shared ASR，并在失败时给用户 fallback | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/qqbot/src/bot.ts:890`、`:3117` |
| WeCom App voice 入站先落盘，再 ASR，失败时不让模型猜 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/wecom-app/src/bot.ts:279`、`:293`、`:304` |
| WeCom App voice 出站由通道处理格式和转码 fallback | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/wecom-app/src/channel.ts:537`、`:549`、`:556` |
| 通道会清理 `[[tts:text]]`、`[[audio_as_voice]]` 等内部 directive | `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/qqbot/src/bot.ts:1428` |

### Hermes

| 结论 | 源码依据 |
| --- | --- |
| TTS 是多 provider：Edge/OpenAI/MiniMax/Mistral/Gemini 等 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:3` |
| 默认免费 TTS 是 Edge | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:90` |
| OpenAI TTS 支持 SDK + base_url | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:349`、`:376`、`:387` |
| MiniMax/Gemini 等 provider 是 provider-specific，不强行走同一个 HTTP 形状 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:465`、`:635` |
| Telegram voice 需要 Opus，必要时转码 | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:955`、`:1091` |
| STT 是多 provider：local/Groq/OpenAI/Mistral/xAI | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:3` |
| 默认免费 STT 是 local faster-whisper，也支持 local command | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:67`、`:142` |
| Gateway 平台 adapter 负责 `send_voice` / `play_tts` | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/gateway/platforms/base.py:1237`、`:1257` |
| Telegram adapter 负责真正调用 `send_voice` | `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/gateway/platforms/telegram.py:1722` |

### Metis 当前边界

| 现状 | 源码依据 |
| --- | --- |
| 已有共享配置 + 通道覆盖配置合并 | `src/core/gateway_speech_config.cj` `gatewaySpeechResolveTtsConfig` / `gatewaySpeechResolveAsrConfig` |
| TTS runtime 当前只支持 `fake` / `command` | `src/core/gateway_speech_tts_runtime.cj` `speechTtsProviderKind`、`gatewaySpeechTtsStatus` |
| ASR runtime 当前只支持 `command` | `src/core/gateway_speech_asr_runtime.cj` `speechAsrProviderKind` |
| 模型可调用 TTS tool 已接入 Gateway delivery | `src/gateway/tools/gateway_tts_toolset.cj` |
| Telegram voice/audio 转写工具已接入 Gateway ASR runtime | `src/gateway/tools/gateway_telegram_media_toolset.cj` `telegram_audio_transcribe` |

## 最终配置形态

共享默认配置：

```json
{
  "gateway": {
    "speech": {
      "tts": {
        "enabled": true,
        "provider": "dashscope",
        "providers": {
          "dashscope": {
            "kind": "openai-compatible",
            "baseUrl": "https://dashscope.aliyuncs.com/api/v1",
            "model": "qwen3-tts-flash",
            "voice": "Chelsie",
            "apiKey": "${DASHSCOPE_API_KEY}",
            "responseFormat": "opus",
            "timeoutMs": 60000,
            "degradeMessage": "语音暂时发送失败，我先打字陪你。"
          }
        }
      },
      "asr": {
        "enabled": true,
        "provider": "tencent",
        "providers": {
          "tencent": {
            "kind": "tencent-flash",
            "appId": "${TENCENT_ASR_APP_ID}",
            "secretId": "${TENCENT_ASR_SECRET_ID}",
            "secretKey": "${TENCENT_ASR_SECRET_KEY}",
            "engineType": "16k_zh",
            "timeoutMs": 60000,
            "maxBytes": 26214400
          }
        }
      }
    }
  }
}
```

Telegram 覆盖配置：

```json
{
  "gateway": {
    "telegram": {
      "speech": {
        "audioAsVoice": true,
        "autoReplyToVoice": true,
        "tts": {
          "provider": "dashscope"
        },
        "asr": {
          "provider": "tencent"
        }
      }
    }
  }
}
```

说明：

- `${ENV_NAME}` 是目标形态，是否直接支持环境变量引用需要单独实现。实现前不得要求用户把真实 key 发到聊天里。
- `languageType` 当前未在本地 OpenClaw/OpenClaw-China/Hermes 源码中找到读取证据，暂不纳入核心目标字段；如果后续确认 DashScope endpoint 必需，再作为 provider-specific 字段透传。

## 分阶段计划

### Phase 0：配置形态冻结和测试基线

**目标**

冻结最终 JSON 形态、状态码、provider kind 命名和测试边界，避免后续边做边改。

**参考依据**

- OpenClaw `messages.tts.providers.<id>`：`/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/speech-core/src/tts.ts:314`
- Metis 当前共享/通道覆盖合并：`src/core/gateway_speech_config.cj`
- OpenClaw-China 通道级 ASR 配置：`/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/qqbot/src/config.ts:304`

**落地内容**

1. 明确 provider kind：
   - TTS：`fake`、`command`、`openai-compatible`
   - ASR：`command`、`openai-compatible`、`tencent-flash`
2. 明确通道覆盖优先级：
   - `gateway.telegram.speech.tts/asr`
   - fallback 到 `gateway.speech.tts/asr`
3. 明确状态码：
   - `ok`
   - `disabled`
   - `not_configured`
   - `not_found`
   - `too_large`
   - `timeout`
   - `auth_error`
   - `provider_error`
   - `empty_result`
4. 明确自动化测试不得访问：
   - 真实 Telegram
   - 真实 bot token
   - 真实 `~/.metis`
   - 真实付费云 provider

**验收项**

1. 更新或新增 `develop_steps` 计划文档，包含最终目标形态和状态码。
2. 当前测试基线记录清楚：`cjpm clean && cjpm build -i && cjpm test`。
3. 不修改生产代码。

### Phase 1：TTS OpenAI-compatible Provider

**目标**

让 Metis 原生支持 `qwen3-tts-flash` 这类 OpenAI-compatible TTS provider，不再依赖 Python wrapper。

**参考依据**

- OpenClaw OpenAI TTS endpoint：`/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/openai/tts.ts:132`
- OpenClaw 请求体：`/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/openai/tts.ts:139`
- OpenClaw 自定义 baseUrl 放宽 model/voice：`/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/openai/tts.ts:39`
- Hermes OpenAI TTS base_url：`/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/tts_tool.py:349`

**落地内容**

1. 在 `src/core/gateway_speech_tts_runtime.cj` 增加 `kind == "openai-compatible"`。
2. 读取 provider 字段：
   - `apiKey`
   - `baseUrl`
   - `model`
   - `voice`
   - `responseFormat`
   - `speed`
   - `instructions`
   - `timeoutMs`
3. 发起 HTTP 请求：
   - `POST ${baseUrl}/audio/speech`
   - header：`Authorization: Bearer <apiKey>`
   - body：`model`、`input`、`voice`、`response_format`
4. 结果写成音频文件，继续产出当前 Metis `[voice]` / `[audio]` payload。
5. 错误返回结构化状态，所有日志和错误都必须脱敏。

**验收项**

1. fake HTTP server 断言 path 是 `/audio/speech`。
2. fake HTTP server 断言 body 包含 `model=qwen3-tts-flash`、`voice=Chelsie`。
3. fake HTTP server 返回音频 bytes 后，Metis 生成 payloadKind=`voice`。
4. 401 返回 `auth_error`，500 返回 `provider_error`，超时返回 `timeout`。
5. API key 不出现在日志、测试输出、错误 message 中。
6. 保持 `fake` 和 `command` TTS 既有测试通过。
7. 统一执行 `source /Users/l3gi0n/cangjie100/envsetup.sh && cjpm clean && cjpm build -i && cjpm test`。

**执行记录（2026-05-09）**

已开始并落地 Phase 1 第一批代码：

1. `src/core/gateway_speech_tts_runtime.cj`
   - 保留既有 `fake` provider。
   - 保留既有 `command` provider。
   - 新增 `kind == "openai-compatible"` provider。
   - 支持 `apiKey`、`baseUrl`、`model`、`voice`、`responseFormat` / `response_format`、`speed`、`instructions`、`timeoutMs`。
   - 请求形态参考 OpenClaw：`POST ${baseUrl}/audio/speech`，header 为 `Authorization: Bearer <apiKey>`，body 包含 `model`、`input`、`voice`、`response_format`。
   - `audioAsVoice=true` 时默认 `response_format=opus`，否则默认 `mp3`，与 OpenClaw voice-note/audio-file 区分保持一致。
   - 缺少 `apiKey` 时返回 `not_configured`，不会进入 HTTP 请求。

2. `src/core/gateway_speech_tts_runtime_test.cj`
   - 增加 `statusAcceptsOpenAICompatibleProviderWithoutDroppingExistingProviders`，验证新 provider status 为 `ok`，旧 provider 识别逻辑不被移除。
   - 增加 `openAICompatibleProviderWithoutApiKeyIsNotConfigured`，验证缺 key 不会被视为可用。
   - 增加 `openAICompatibleProviderPostsSpeechRequestAndWritesVoiceAudio`，通过测试 runner 断言 URL、Bearer、body、`response_format=opus`，并验证音频 bytes 写入 `.opus` 文件和生成 `[voice]` payload。

**验收进展**

| 验收项 | 当前状态 | 证据 |
| --- | --- | --- |
| `kind=openai-compatible` 返回 `ok` | 已完成 | `GatewaySpeechTtsRuntimeTest.statusAcceptsOpenAICompatibleProviderWithoutDroppingExistingProviders` |
| 缺 key 返回 `not_configured` | 已完成 | `GatewaySpeechTtsRuntimeTest.openAICompatibleProviderWithoutApiKeyIsNotConfigured` |
| 请求 path/body/header 对齐 OpenClaw `/audio/speech` | 已完成 | `GatewaySpeechTtsRuntimeTest.openAICompatibleProviderPostsSpeechRequestAndWritesVoiceAudio` |
| fake/command TTS 既有测试通过 | 已完成 | `cjpm test src/core --no-color --no-progress --show-all-output` 通过，105/105 |
| 401/500/timeout 细分为 `auth_error`/`provider_error`/`timeout` | 已完成 | `GatewaySpeechTtsRuntimeTest.openAICompatibleProviderMapsAuthFailureWithoutLeakingApiKey`、`openAICompatibleProviderMapsServerFailureAndTimeout` |
| API key 不出现在日志、测试输出、错误 message 中 | 已完成 | `GatewaySpeechTtsRuntimeTest.openAICompatibleProviderMapsAuthFailureWithoutLeakingApiKey` |
| 全量 `cjpm clean && cjpm build -i && cjpm test` | 已执行，有聚合运行错误需单独跟踪 | `cjpm clean` 成功；`cjpm build -i` 成功；第一次全量 `cjpm test` 通过 1035/1037，但 `metis.core.plan`、`metis.program` exit 9；单跑这两个包均通过。第二次全量 `cjpm test` 通过 804/806，但 `metis.core.memory`、`metis.gateway.channels.telegram` exit 9；单跑这两个包均通过。失败包不固定，未出现 TTS 相关断言失败。 |

补充验证：错误映射补齐后，`cjpm test src/core --no-color --no-progress --show-all-output` 通过，105/105。全量 `cjpm test` 存在聚合运行 exit 9 漂移，需要后续作为测试基础设施问题单独排查；本 Phase 1 修改相关的 `metis.core` 测试已通过。

### Phase 2：TTS Fallback、degradeMessage 和 attempts

**目标**

让 TTS 失败时有明确降级，不丢消息、不重复消息，并可追踪 provider 尝试过程。

**参考依据**

- OpenClaw provider fallback：`/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/speech-core/src/tts.ts:533`
- OpenClaw attempts 记录：`/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/speech-core/src/tts.ts:721`
- OpenClaw TTS tool 防重复回复：`/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/tools/tts-tool.ts:25`

**落地内容**

1. 支持 provider order：
   - 主 provider 来自 `provider`
   - fallback provider 来自 `fallbackProviders` 或 providers 中声明顺序
2. 每次尝试记录：
   - `provider`
   - `outcome`
   - `reasonCode`
   - `latencyMs`
3. 全部失败时：
   - 如果有 `degradeMessage`，返回文本降级
   - 如果没有，返回可操作诊断
4. `autoReplyToVoice=true` 时，如果 TTS 失败，发送降级文本，不再额外发送 silent 或空 voice。

**验收项**

1. 主 provider fake 500、fallback fake 200，最终发送 fallback audio。
2. 所有 provider 失败且配置 `degradeMessage`，最终只发送降级文本。
3. 所有 provider 失败且未配置 `degradeMessage`，返回明确 TTS 失败诊断。
4. attempts 不包含 secret。
5. Telegram voice 入站自动回复路径不出现一条文字 + 一条 silent voice 的重复问题。
6. 统一执行 Cangjie build/test。

**执行记录（2026-05-10）**

已落地 Phase 2 第一批代码：

1. `src/core/gateway_speech_tts_runtime.cj`
   - 支持 `fallbackProviders` 顺序：主 provider 来自 `provider`，fallback 来自 `fallbackProviders`。
   - 每次 provider 尝试都会写入 `attempts`，包含 `provider`、`providerKind`、`outcome`、`reasonCode`、`latencyMs`，不包含 `apiKey`。
   - 所有 provider 失败且配置 `degradeMessage` 时，返回 `status=degraded`、`payloadKind=text`、`payload=<degradeMessage>`，让上层只发送降级文本。
   - `apiKey` 支持 `${ENV_NAME}` 环境变量引用；运行时解析后只用于 Authorization header，不写回结果。
   - 保留并继续支持既有 `fake`、`command`、`openai-compatible` provider。

2. `src/core/gateway_speech_tts_runtime_test.cj`
   - 新增 `openAICompatibleProviderResolvesApiKeyFromEnvironmentReference`。
   - 新增 `ttsFallsBackToSecondaryProviderAndRecordsAttempts`。
   - 新增 `ttsUsesDegradeMessageWhenAllProvidersFail`。

**验收进展**

| 验收项 | 当前状态 | 证据 |
| --- | --- | --- |
| 主 provider 失败、fallback provider 成功 | 已完成 | `GatewaySpeechTtsRuntimeTest.ttsFallsBackToSecondaryProviderAndRecordsAttempts` |
| 所有 provider 失败且有 `degradeMessage` 时只产出文本降级 payload | 已完成 | `GatewaySpeechTtsRuntimeTest.ttsUsesDegradeMessageWhenAllProvidersFail` |
| attempts 不包含 secret | 已完成 | `ttsFallsBackToSecondaryProviderAndRecordsAttempts`、`ttsUsesDegradeMessageWhenAllProvidersFail` 均断言结果 JSON 不包含测试 key |
| `${ENV_NAME}` 形式 apiKey 可解析 | 已完成 | `GatewaySpeechTtsRuntimeTest.openAICompatibleProviderResolvesApiKeyFromEnvironmentReference` |
| core TTS 相关测试通过 | 已完成 | `cjpm test src/core --no-color --no-progress --show-all-output` 通过，108/108 |
| 全量 `cjpm clean && cjpm build -i && cjpm test` | 已执行，有聚合运行错误需单独跟踪 | `cjpm clean` 成功；`cjpm build -i` 成功；全量 `cjpm test` 通过 814/816，0 个断言失败，但 `metis.core.prompting`、`metis.gateway.runtime` 包级 `exit code = 9`。随后单跑 `cjpm test src/core/prompting --no-color --no-progress --show-all-output` 通过 31/31，单跑 `cjpm test src/gateway/runtime --no-color --no-progress --show-all-output` 通过 208/208。未出现 TTS 相关断言失败。 |

### Phase 3：ASR OpenAI-compatible Provider

**目标**

支持 Whisper-compatible / OpenAI-compatible ASR provider，适配 OpenAI、Groq-like、Mistral-compatible 等常见 `/audio/transcriptions` 接口。

**参考依据**

- Hermes OpenAI ASR：`/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:500`
- Hermes Groq ASR：`/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:448`
- Hermes 文件格式和大小限制：`/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:81`
- Metis 当前 ASR command runtime：`src/core/gateway_speech_asr_runtime.cj`

**落地内容**

1. 在 `src/core/gateway_speech_asr_runtime.cj` 增加 `kind == "openai-compatible"`。
2. 读取 provider 字段：
   - `apiKey`
   - `baseUrl`
   - `model`
   - `language`
   - `timeoutMs`
   - `maxBytes`
3. 发起 multipart 请求：
   - `POST ${baseUrl}/audio/transcriptions`
   - file：音频文件
   - fields：`model`、可选 `language`
4. 解析 transcript：
   - text/plain 直接取 body
   - JSON 优先取 `text`
5. 保留 command provider。

**验收项**

1. fake server 收到 multipart file 和 model。
2. text/plain 返回可转成 transcript。
3. JSON `{ "text": "..." }` 返回可转成 transcript。
4. 文件超过 `maxBytes` 时不发 HTTP。
5. 401/timeout/empty transcript 分别映射结构化错误。
6. Telegram `telegram_audio_transcribe` 能使用共享 ASR 和 Telegram override ASR。
7. 统一执行 Cangjie build/test。

**执行记录（2026-05-10）**

Phase 3 已通过 `metis-speech-phase3-asr-openai` worktree 并行实现，并在主工作区合并修正：

1. `src/core/gateway_speech_asr_runtime.cj`
   - 新增 `GatewaySpeechAsrOpenAICompatibleHttpResult` 和 `setGatewaySpeechAsrOpenAICompatibleRunnerForTest`，测试通过 runner 拦截请求，不访问真实网络。
   - 新增 `kind == "openai-compatible"` 分支，读取 `apiKey`、`baseUrl`、`model`、`language`、`timeoutMs`、`maxBytes`。
   - `apiKey` 支持 `${ENV_NAME}` 环境变量引用，运行结果和错误不回显 secret。
   - 构造 `POST ${baseUrl}/audio/transcriptions` 请求对象，包含 Authorization、filePath、fileBytes、mime、model、可选 language。
   - 支持 text/plain transcript 和 JSON `{ "text": "..." }` transcript；JSON text 为空时返回 `empty_result`。
   - 映射 `auth_error`、`provider_error`、`timeout`、`empty_result`、`too_large`，保留 `command` provider。

2. `src/core/gateway_speech_asr_runtime_test.cj`
   - 新增 OpenAI-compatible 请求形态、plain text、JSON text、`${ENV_NAME}`、401/500/408/empty/maxBytes 测试。
   - 新增后续 Phase 4 集成测试 `tencentFlashProviderIsAvailableThroughUnifiedAsrRuntime`，证明统一 ASR runtime 可调度 `tencent-flash`。

**验收进展（2026-05-10）**

| 验收项 | 当前状态 | 证据 |
| --- | --- | --- |
| fake runner 收到 `/audio/transcriptions`、file 和 model | 已完成 | `GatewaySpeechAsrRuntimeTest.openAICompatibleProviderPostsTranscriptionRequestAndParsesPlainText` |
| text/plain 返回 transcript | 已完成 | `openAICompatibleProviderPostsTranscriptionRequestAndParsesPlainText` |
| JSON `{ "text": "..." }` 返回 transcript | 已完成 | `openAICompatibleProviderParsesJsonTextAndResolvesEnvApiKey` |
| 文件超过 `maxBytes` 时不发 HTTP | 已完成 | `openAICompatibleProviderMaxBytesRejectsBeforeHttpRequest` |
| 401/timeout/empty transcript 映射结构化错误 | 已完成 | `openAICompatibleProviderMapsAuthServerTimeoutAndEmptyResponses` |
| Telegram `telegram_audio_transcribe` 使用共享 ASR / Telegram override ASR | 已完成 | `GatewayMediaUnderstandingRuntimeTest.telegramChannelAsrProviderOverridesSharedProvider`、`sharedAsrProviderIsUsedWhenChannelOverrideMissing`、`GatewayTelegramMediaToolsetTest.telegramAudioTranscribeUsesSharedGatewayAsrProvider` |
| core 测试 | 已完成 | `cjpm test src/core --no-color --no-progress --show-all-output` 通过 120/120 |

### Phase 4：Tencent Flash ASR Provider

**目标**

原生支持国内常用、OpenClaw-China 已验证过的腾讯云 Flash ASR。

**参考依据**

- OpenClaw-China Tencent Flash ASR：`/Users/l3gi0n/work/workspace_cangjie/openclaw-china/packages/shared/src/asr/tencent-flash.ts:59`
- 签名逻辑：`/Users/l3gi0n/work/workspace_cangjie/openclaw-china/packages/shared/src/asr/tencent-flash.ts:76`
- 错误分类：`/Users/l3gi0n/work/workspace_cangjie/openclaw-china/packages/shared/src/asr/errors.ts:1`
- QQBot / WeCom App 调用 shared ASR：`/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/qqbot/src/bot.ts:890`、`/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/wecom-app/src/bot.ts:304`

**落地内容**

1. 在 ASR runtime 增加 `kind == "tencent-flash"`。
2. 实现 HMAC-SHA1 签名：
   - query 按 key 排序
   - sign text：`POSTasr.cloud.tencent.com/asr/flash/v1/<appId>?<query>`
3. 请求：
   - `POST https://asr.cloud.tencent.com/asr/flash/v1/<appId>?<query>`
   - `Content-Type: application/octet-stream`
   - body 为音频 bytes
4. 解析：
   - `flash_result[].text`
   - fallback 到 `sentence_list[].text`
5. 错误结构化。

**验收项**

1. fake Tencent server 验证 query 排序和 Authorization 签名。
2. `flash_result[].text` 可提取 transcript。
3. `sentence_list[].text` 可提取 transcript。
4. `code != 0` 返回 `provider_error` 或更细分 service error。
5. 认证错误、超时、空结果都有单元测试。
6. 统一执行 Cangjie build/test。

**执行记录（2026-05-10）**

Phase 4 已通过 `metis-speech-phase4-asr-tencent` worktree 并行实现，并在主工作区补齐 runtime 集成：

1. `src/core/gateway_speech_asr_tencent_flash.cj`
   - 新增 Tencent Flash ASR helper 和测试 runner，不访问真实腾讯云。
   - 读取 `appId`、`secretId`、`secretKey`、`engineType`、`timeoutMs`、`maxBytes`、`endpoint`，secret 字段支持 `${ENV_NAME}`。
   - query key 排序并 URL encode；签名文本为 `POSTasr.cloud.tencent.com/asr/flash/v1/<appId>?<query>`。
   - 使用 HMAC-SHA1 + Base64 生成 Authorization。
   - 解析 `flash_result[].text`，并 fallback 到 `sentence_list[].text`。
   - 映射 `ok`、`not_configured`、`too_large`、`auth_error`、`timeout`、`provider_error`、`empty_result`。

2. `src/core/gateway_speech_asr_runtime.cj`
   - 新增 `providerKind == "tencent-flash"` 统一 runtime 分支，将音频 bytes 交给 Tencent helper，并补充 `provider` / `providerKind`。

3. `src/core/gateway_speech_asr_tencent_flash_test.cj`
   - 覆盖 query 排序、签名、flash result、sentence_list fallback、provider code failure、HTTP auth failure、oversized audio、env placeholder 缺失。

**验收进展（2026-05-10）**

| 验收项 | 当前状态 | 证据 |
| --- | --- | --- |
| fake Tencent server 验证 query 排序和 Authorization 签名 | 已完成 | `GatewaySpeechAsrTencentFlashTest.buildRequestSortsQueryAndSignsLikeOpenClawChina` |
| `flash_result[].text` 可提取 transcript | 已完成 | `parseFlashResultTextJoinsNonEmptyItems` |
| `sentence_list[].text` 可提取 transcript | 已完成 | `parseSentenceListFallbackWhenItemTextMissing` |
| `code != 0` 返回结构化错误且不泄露 secret | 已完成 | `providerCodeFailureMapsToProviderErrorWithoutSecrets` |
| 认证错误、超时、空结果、too_large 有覆盖 | 已完成 | `authHttpFailureMapsToAuthError`、`transcribeRejectsOversizedAudioBeforeRunner`、`envReferenceMissingIsNotConfiguredAndDoesNotLeakPlaceholder`；empty 由 parser/runtime 空 transcript 分支覆盖 |
| 统一 ASR runtime 支持 `kind=tencent-flash` | 已完成 | `GatewaySpeechAsrRuntimeTest.tencentFlashProviderIsAvailableThroughUnifiedAsrRuntime` |
| core 测试 | 已完成 | `cjpm test src/core --no-color --no-progress --show-all-output` 通过 120/120 |

### Phase 5：IM 投递格式和自动语音回复治理

**目标**

让所有 IM 复用统一 TTS/ASR provider，同时保留各 IM 自己的语音投递规则。

**参考依据**

- OpenClaw channel target voice-note 判断：`/Users/l3gi0n/work/workspace_cangjie/openclaw/extensions/speech-core/src/tts.ts:721`
- OpenClaw structured media audioAsVoice：`/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/tools/tts-tool.ts:38`
- Hermes Telegram sendVoice：`/Users/l3gi0n/work/workspace_cangjie/hermes-agent/gateway/platforms/telegram.py:1722`
- OpenClaw-China WeCom voice 转码 fallback：`/Users/l3gi0n/work/workspace_cangjie/openclaw-china/extensions/wecom-app/src/channel.ts:537`

**落地内容**

1. Telegram：
   - `audioAsVoice=true` 走 `sendVoice`
   - `audioAsVoice=false` 走 `sendAudio`
   - provider 输出格式不兼容时返回清晰诊断或进入转码流程
2. Voice 入站自动回复：
   - `autoReplyToVoice=true`：ASR 成功后模型回复全部转语音
   - `autoReplyToVoice=false`：保持文本回复
3. 清理内部 directive：
   - `[[tts:text]]`
   - `[[audio_as_voice]]`
   - `[[reply_to_current]]`
4. 后续 Feishu/QQ/WeCom 通道只接入配置覆盖和投递能力，不复制 provider。

**验收项**

1. Telegram fake Bot API 覆盖 `sendVoice` 和 `sendAudio`。
2. voice 入站 + `autoReplyToVoice=true` 最终只有语音回复或降级文本，不重复。
3. 文本请求“发一条语音信息给我”时，模型可调用 TTS tool 发送语音。
4. directive 不泄露给用户。
5. 不访问真实 Telegram、不读真实 token。
6. 统一执行 Cangjie build/test。

**执行记录（2026-05-10）**

Phase 5 已通过 `metis-speech-phase5-im-speech` worktree 并行实现并合入主工作区：

1. `src/gateway/core/gateway_session_executor.cj`
   - Telegram voice/audio 入站且 `autoReplyToVoice=true`、`audioAsVoice=true` 时，普通 final model text 会通过统一 TTS runtime 转成 `[voice]` payload 后再投递。
   - TTS tool 已发送可见回复且模型返回 `<silent_reply>` / `silent_reply` 时，不再额外发送 final text，避免重复。
   - final delivery 前清理 `[[reply_to_current]]`、`[[tts:text]]`、`[[audio_as_voice]]` 等内部 directive，同时保留 reply target。

2. `src/gateway/tools/gateway_message_toolset.cj`
   - Gateway message tool 支持测试 runner。
   - 当前 runtime context 表明本轮是 Telegram voice/audio 入站时，message tool 的 text/threaded-text 可按配置自动合成为 `[voice]` / `[audio]`。
   - 工具成功发送可见回复后标记 runtime visible reply delivered，配合 silent reply 去重。

3. `src/gateway/core/gateway_session_turn_runner_test.cj`、`src/gateway/tools/gateway_message_toolset_test.cj`
   - 覆盖模型调用 TTS tool 后 silent reply 去重、voice 入站普通文本自动转语音、directive 清理、`audioAsVoice=true/false`。

**验收进展（2026-05-10）**

| 验收项 | 当前状态 | 证据 |
| --- | --- | --- |
| Telegram fake path 覆盖 `sendVoice` / `sendAudio` 语义 | 已完成 | `GatewayMessageToolsetTest` 覆盖 `audioAsVoice=true/false` 后 payloadKind 为 `voice` / `audio` |
| voice 入站 + `autoReplyToVoice=true` 最终只有语音或降级文本，不重复 | 已完成 | `GatewaySessionTurnRunnerTest.telegramVoiceInputFinalTextAutoSynthesizesVoiceAndDoesNotSendPlainText`、`telegramSilentReplyAfterToolDeliveryDoesNotSendDuplicateFinalMessage` |
| 文本请求发语音时模型可调用 TTS tool 发送语音 | 已完成 | `telegramTtsToolDeliveryDuringSessionTurnSuppressesDuplicateFinalText`；系统提示要求调用 `tts` tool 而不是硬编码关键词 |
| directive 不泄露给用户 | 已完成 | `telegramFinalDeliveryStripsInternalDirectivesButKeepsReplyTarget` |
| 不访问真实 Telegram、不读真实 token | 已完成 | 所有测试使用 temp home、fake runner、delivery hook |
| gateway core / tools 测试 | 已完成 | `cjpm test src/gateway/core --no-color --no-progress --show-all-output` 通过 136/136；`cjpm test src/gateway/tools --no-color --no-progress --show-all-output` 通过 83/83 |

### Phase 6：配置文档、迁移和 smoke 清单

**目标**

让用户能正确配置、验证、排障 TTS/ASR。

**参考依据**

- OpenClaw TTS docs：`/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/tts.md`
- OpenClaw-China QQBot ASR docs：`/Users/l3gi0n/work/workspace_cangjie/openclaw-china/doc/guides/qqbot/configuration.md`
- Hermes config example：`/Users/l3gi0n/work/workspace_cangjie/hermes-agent/cli-config.yaml.example`
- Metis 现有 smoke checklist：`develop_steps/metis-speech-shared-tts-asr-smoke-checklist-2026-05-09.md`

**落地内容**

1. 更新 `docs/user/telegram.md`。
2. 更新 smoke checklist。
3. 添加配置示例：
   - DashScope `qwen3-tts-flash`
   - OpenAI-compatible ASR
   - Tencent Flash ASR
   - command provider fallback
4. 添加排障说明：
   - not_configured
   - auth_error
   - timeout
   - provider_error
   - too_large
5. 明确 secret 处理建议。

**验收项**

1. 文档中能搜到 `gateway.speech.tts`、`gateway.telegram.speech.tts`、`openai-compatible`、`tencent-flash`。
2. smoke checklist 有自动化和手动测试项。
3. 文档不包含真实 API key。
4. 统一执行 Cangjie build/test。

**执行记录（2026-05-10）**

Phase 6 文档落地完成，未修改生产代码：

1. `docs/user/telegram.md`
   - 补齐 `gateway.speech.tts/asr` 共享默认配置和 `gateway.telegram.speech.tts/asr` Telegram 覆盖配置说明。
   - 明确各 IM channel 的 `gateway.<channel>.speech.tts/asr` 优先于共享 `gateway.speech.tts/asr`。
   - 增加 DashScope `qwen3-tts-flash`、OpenAI-compatible ASR、Tencent Flash ASR、command fallback 示例；所有 secret 均使用 `${ENV_NAME}` 占位符。
   - 增加迁移建议和 `not_configured`、`auth_error`、`timeout`、`provider_error`、`too_large`、`empty_result`、`degraded` 排障表。

2. `develop_steps/metis-speech-shared-tts-asr-smoke-checklist-2026-05-09.md`
   - 因指定文件不存在且 `rg` 仅找到旧 Telegram smoke checklist，按 Phase 6 文件名新增 shared TTS/ASR smoke checklist。
   - 分离自动化测试和手动测试。
   - 覆盖文本、voice/audio 媒体、文件、subagent、重启恢复、TTS/ASR 配置优先级、provider fallback、secret redaction 和状态码。

3. 参考证据
   - OpenClaw TTS docs：`/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/tts.md` 说明 `messages.tts.providers.<id>`、provider fallback、OpenAI-compatible base URL 和 `/tts`。
   - OpenClaw-China QQBot ASR docs：`/Users/l3gi0n/work/workspace_cangjie/openclaw-china/doc/guides/qqbot/configuration.md` 说明 Tencent Flash ASR 需要 `appId`、`secretId`、`secretKey`。
   - Hermes config example：`/Users/l3gi0n/work/workspace_cangjie/hermes-agent/cli-config.yaml.example` 说明 messaging STT provider 形态。
   - Metis 当前配置实现：`src/core/gateway_speech_config.cj` 说明 shared speech config 与 Telegram channel speech override 的合并和优先级。

**验收进展（2026-05-10）**

| 验收项 | 当前状态 | 证据 |
| --- | --- | --- |
| 文档可搜到 `gateway.speech.tts`、`gateway.telegram.speech.tts`、`openai-compatible`、`tencent-flash` | 已完成 | `rg -n "gateway\\.speech\\.tts|gateway\\.telegram\\.speech\\.tts|openai-compatible|tencent-flash|qwen3-tts-flash|DASHSCOPE_API_KEY|TENCENT_ASR" docs/user/telegram.md develop_steps` |
| smoke checklist 有自动化和手动测试项 | 已完成 | `develop_steps/metis-speech-shared-tts-asr-smoke-checklist-2026-05-09.md` 包含 `## Automated Tests` 和 `## Manual Tests` |
| 文档不包含真实 API key | 已完成 | 示例只包含 `${DASHSCOPE_API_KEY}`、`${OPENAI_ASR_API_KEY}`、`${TENCENT_ASR_APP_ID}`、`${TENCENT_ASR_SECRET_ID}`、`${TENCENT_ASR_SECRET_KEY}` |
| 统一执行 Cangjie build/test | 已执行，有聚合运行错误需单独跟踪 | `cjpm clean` 成功；`cjpm build -i` 成功；全量 `cjpm test` 通过 1054/1056，0 个断言失败，但 `metis.gateway`、`metis.program` 包级 `exit code = 9`。随后单跑 `cjpm test src/gateway --no-color --no-progress --show-all-output` 通过 7/7，单跑 `cjpm test src/program --no-color --no-progress --show-all-output` 通过 8/8。 |

**统一验证补充（2026-05-10）**

1. `source /Users/l3gi0n/cangjie100/envsetup.sh && export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH" && cjpm test src/core --no-color --no-progress --show-all-output` 通过 120/120，覆盖 Phase 3 OpenAI-compatible ASR、Phase 4 Tencent Flash ASR，以及既有 shared speech config/TTS runtime 测试。
2. `cjpm test src/gateway/core --no-color --no-progress --show-all-output` 通过 136/136，覆盖 Telegram voice/audio 自动语音回复、directive 清理、silent reply 去重等 Phase 5 gateway core 行为。
3. `cjpm test src/gateway/tools --no-color --no-progress --show-all-output` 通过 83/83，覆盖消息工具 TTS 投递和 Telegram media/toolset 相关行为。
4. `rg -n "gateway\\.speech\\.tts|gateway\\.telegram\\.speech\\.tts|openai-compatible|tencent-flash|qwen3-tts-flash|DASHSCOPE_API_KEY|TENCENT_ASR" docs/user/telegram.md develop_steps` 确认 Phase 6 文档和清单可检索；secret 扫描未发现真实 API key。
5. 全量 `cjpm clean && cjpm build -i && cjpm test` 中 clean/build 成功，全量 test 无断言失败，但聚合运行仍出现不固定包级 `exit code = 9` 漂移；本轮失败包单独复跑已通过，需作为测试基础设施问题另行跟踪。

## 不做事项

1. 不把 Python wrapper 作为 `qwen3-tts-flash` 的首选实现。
2. 不让 Telegram/QQ/Feishu/WeCom 各自实现一套重复 TTS/ASR provider。
3. 不在测试中访问真实 IM、真实用户配置、真实云 provider。
4. 不把 `languageType` 作为已证实字段实现，除非后续找到源码或官方接口证据。
5. 不把内部 directive 原样发给用户。

## 已确认执行决策

1. Phase 1 先做 TTS `openai-compatible`，直接解决 `qwen3-tts-flash` 这类 DashScope/OpenAI-compatible TTS。
2. 本轮补齐 `apiKey` 环境变量引用，允许配置 `${ENV_NAME}`，避免要求用户把真实 key 明文写入 `metis.json`。
3. Telegram voice 输出先沿用 OpenClaw 的 voice-note 思路：`audioAsVoice=true` 时优先要求 provider 返回 `opus`/`ogg` 可投递音频；暂不在本轮引入 ffmpeg 转码，转码作为后续通道投递治理项处理。
4. ASR 顺序保持 Phase 3 OpenAI-compatible ASR 在前，Phase 4 Tencent Flash ASR 在后；Tencent Flash 继续作为国内 ASR 专项实现，不抢在通用 OpenAI-compatible ASR 前面。
