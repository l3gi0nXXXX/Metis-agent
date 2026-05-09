# Metis OpenRouter ASR Request Format Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在保留现有 OpenAI-compatible ASR 行为的前提下，新增 OpenRouter ASR `input_audio` base64 JSON 请求格式适配，使 Telegram voice/audio 可以通过 `https://openrouter.ai/api/v1/audio/transcriptions` 正常转写。

**Architecture:** Metis 继续保持 Gateway shared speech config + channel override 的架构边界，不把 OpenRouter 特例写入 Telegram adapter 或 session runner。请求格式选择放在 `src/core/gateway_speech_asr_runtime.cj` 的 ASR provider runtime 内，通过 provider 配置显式选择或按 `baseUrl` 安全推断。测试全部使用 runner override，不访问真实 OpenRouter、真实 Telegram、真实用户文件或真实 API key。

**Tech Stack:** Cangjie, `stdx.encoding.json`, `stdx.encoding.base64.toBase64String`, `stdx.net.http`, `cjpm test`, Metis Gateway speech config/runtime。

---

## 现场问题记录

用户修改 provider 级 `insecureSkipTlsVerify=true` 后，TLS 错误已消失，最新日志变为 OpenRouter 400：

```text
OpenAI-compatible ASR API error (400): {"success":false,"error":{"name":"ZodError","message":"... \"path\": [\"input_audio\"] ... \"Invalid input: expected object, received undefined\" ..."}}
```

这说明当前问题不是 ASR 未配置，也不是 Telegram 入站失败，而是 Metis OpenAI-compatible ASR 请求体与 OpenRouter ASR 接口不兼容。

## 源码依据

### Hermes

1. `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:5-18`
   - Hermes 明确把 voice transcription 作为跨 Telegram、Discord、WhatsApp、Slack、Signal 的 shared STT 能力。
   - 支持输入格式包含 `ogg`，与 Telegram voice 的 `audio/ogg` 匹配。

2. `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:448-471`
   - Groq STT 使用 OpenAI SDK，调用 `client.audio.transcriptions.create(model, file, response_format="text")`。
   - 这是 Whisper-compatible 文件上传形态，不是把本地 `filePath` 发给远端。

3. `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:500-528`
   - OpenAI STT 同样打开本地音频文件，把文件对象作为 `file` 传入 `audio.transcriptions.create`。
   - `response_format` 根据模型选择 `text` 或 `json`。

4. `/Users/l3gi0n/work/workspace_cangjie/hermes-agent/tools/transcription_tools.py:596-625`
   - xAI STT 注释明确使用 REST endpoint + `multipart/form-data`。
   - 说明 Hermes 对不同 STT provider 接口形态分别适配，不把所有 provider 都强行归一为一个 JSON 形态。

### OpenClaw-China

1. `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/packages/shared/src/asr/tencent-flash.ts:16-23`
   - Tencent Flash ASR 配置独立建模，字段为 `appId`、`secretId`、`secretKey`、`engineType`、`voiceFormat`、`timeoutMs`。

2. `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/packages/shared/src/asr/tencent-flash.ts:40-50`
   - Tencent Flash query 按 provider 规则排序和编码。

3. `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/packages/shared/src/asr/tencent-flash.ts:73-104`
   - Tencent Flash 使用原始音频 bytes 作为 `application/octet-stream` body，并按腾讯规则签名。
   - 这证明 provider runtime 应按 provider 协议生成请求体，而不是由 IM adapter 处理。

4. `/Users/l3gi0n/work/workspace_cangjie/openclaw-china/packages/shared/src/asr/tencent-flash.ts:106-130`
   - 响应先解析 JSON，再映射 HTTP/auth/provider 错误。
   - Metis 当前 Tencent Flash helper 已复用这个方向，应让 OpenRouter ASR 也保持同等错误映射。

### OpenClaw

1. `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/media/input-files.fetch-guard.test.ts:145-158`
   - OpenClaw 对 base64 media source 有明确测试，验证转换后的 base64 数据和 MIME。

2. `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/media/input-files.fetch-guard.test.ts:274-318`
   - OpenClaw 对 base64 输入有 size guard，并验证超限时不会执行 `Buffer.from(..., "base64")` 解码。
   - Metis OpenRouter ASR 适配必须保持先检查原始音频 `maxBytes`，再 base64 编码，避免扩容后才拒绝。

### Metis 当前实现

1. `src/core/gateway_speech_asr_runtime.cj:180-198`
   - 当前 OpenAI-compatible ASR request object 包含 `url`、`authorization`、`filePath`、`fileBytes`、`mime`、`fields`。

2. `src/core/gateway_speech_asr_runtime.cj:213-249`
   - 当前 native post 发送 JSON body：`model`、`language`、`filePath`、`fileBytes`、`mime`。
   - 远端无法读取 Metis 本机路径，因此该形态只适合 mock/占位，不适合 OpenRouter。

3. `src/core/gateway_speech_asr_runtime.cj:255-312`
   - 当前错误映射已覆盖 401/403、408、provider_error、empty_result；OpenRouter 适配应复用这套状态，不增加用户可见的新错误码。

4. `src/core/gateway_speech_asr_runtime_test.cj:149-179`
   - 现有测试固定断言 `filePath` 和 `mime` 出现在 runner request。
   - 新适配必须新增 OpenRouter 测试，同时不能破坏现有 OpenAI-compatible 测试。

5. `src/gateway/tools/gateway_telegram_media_toolset.cj:580-600`
   - Metis 已有读取本地 media bytes、检查大小、base64 编码为 data URL 的成熟模式。
   - OpenRouter ASR 可复用 `stdx.encoding.base64.toBase64String` 的思路，但不得把完整 base64 写进日志或用户可见错误。

### OpenRouter 接口依据

OpenRouter 文档 `Create transcription`：`POST /api/v1/audio/transcriptions`，请求体需要：

```json
{
  "model": "openai/whisper-large-v3",
  "input_audio": {
    "data": "<base64 audio>",
    "format": "wav"
  },
  "language": "en"
}
```

当前线上错误 `input_audio expected object, received undefined` 与该文档一致。文档地址：

```text
https://openrouter.ai/docs/api/api-reference/transcriptions/create-audio-transcriptions
```

## 最终目标形态

1. `kind="openai-compatible"` 保留现有默认行为，继续支持后续补 multipart 的 Whisper-compatible provider。
2. 新增 provider 请求格式字段，推荐：

```json
{
  "kind": "openai-compatible",
  "baseUrl": "https://openrouter.ai/api/v1",
  "apiKey": "${OPENROUTER_API_KEY}",
  "model": "openai/whisper-large-v3-turbo",
  "requestFormat": "openrouter-input-audio-json",
  "timeoutMs": 60000,
  "maxBytes": 26214400,
  "insecureSkipTlsVerify": true
}
```

3. 为降低用户配置成本，当 `baseUrl` host 是 `openrouter.ai` 且未显式配置 `requestFormat` 时，Metis 可以推断为 `openrouter-input-audio-json`；如果显式配置了其他 `requestFormat`，以用户配置为准。
4. OpenRouter 请求体只包含远端可消费的数据：`model`、可选 `language`、`input_audio.data`、`input_audio.format`。
5. `input_audio.format` 从 provider 配置 `audioFormat` 优先读取；未配置时根据 MIME/文件后缀推断：`audio/ogg` 或 `.oga/.ogg/.opus` -> `ogg`，`audio/wav` 或 `.wav` -> `wav`，`audio/mpeg` 或 `.mp3` -> `mp3`，`audio/mp4/.m4a` -> `mp4`，兜底 `ogg`。
6. maxBytes 检查必须在 base64 编码前完成，继续沿用 shared ASR `maxBytes` 和 provider `maxBytes`。
7. 请求和错误日志不得包含 API key、Authorization、完整 base64 音频、真实 Telegram fileId。

## 分阶段落地计划

### Phase 1：OpenRouter 请求构造 TDD

**目标**：只新增请求构造能力和测试，不发真实网络请求。

**修改文件**

- `src/core/gateway_speech_asr_runtime.cj`
- `src/core/gateway_speech_asr_runtime_test.cj`
- `develop_steps/metis-speech-openrouter-asr-request-format-plan-2026-05-10.md`

**实施步骤**

- [ ] 在 `gateway_speech_asr_runtime_test.cj` 新增测试 `openRouterAsrProviderBuildsInputAudioJsonRequest`。
- [ ] 测试配置 provider：

```cangjie
provider.put("kind", JsonString("openai-compatible"))
provider.put("baseUrl", JsonString("https://openrouter.ai/api/v1"))
provider.put("apiKey", JsonString("test-openrouter-key"))
provider.put("model", JsonString("openai/whisper-large-v3-turbo"))
provider.put("requestFormat", JsonString("openrouter-input-audio-json"))
provider.put("language", JsonString("zh"))
provider.put("maxBytes", JsonInt(8192))
provider.put("insecureSkipTlsVerify", JsonBool(true))
```

- [ ] 测试写入本地临时音频 bytes：`File.writeTo(audio, "fake-openrouter-audio".toArray())`。
- [ ] runner 断言 request：
  - `url == "https://openrouter.ai/api/v1/audio/transcriptions"`
  - `authorization == "Bearer test-openrouter-key"`
  - `contentType == "application/json"`
  - `body.model == "openai/whisper-large-v3-turbo"`
  - `body.language == "zh"`
  - `body.input_audio.format == "ogg"`
  - `body.input_audio.data` 非空，且不等于本地 `filePath`
  - request JSON 不包含真实 `filePath`
- [ ] 先运行测试，预期失败，因为当前实现没有 `input_audio`。

**验收项**

| 验收项 | 验收命令 | 预期 |
| --- | --- | --- |
| OpenRouter request shape 测试先红后绿 | `source /Users/l3gi0n/cangjie100/envsetup.sh && cjpm test src/core --no-color --no-progress --show-all-output` | 新增测试最终通过 |
| 不破坏现有 OpenAI-compatible 测试 | 同上 | `openAICompatibleProviderPostsTranscriptionRequestAndParsesPlainText` 仍通过 |
| 不泄露路径和密钥 | 同上 | result/request 断言不包含 API key；OpenRouter body 不含 `filePath` |

### Phase 2：实现请求格式选择和 base64 body

**目标**：在 ASR runtime 内按 provider 配置生成 OpenRouter JSON body，并保留默认行为。

**修改文件**

- `src/core/gateway_speech_asr_runtime.cj`
- `src/core/gateway_speech_asr_runtime_test.cj`

**实施步骤**

- [ ] 在 `gateway_speech_asr_runtime.cj` 引入 `stdx.encoding.base64.toBase64String`。
- [ ] 新增私有函数 `speechAsrOpenAICompatibleRequestFormat(providerConfig: JsonObject, baseUrl: String): String`：
  - 先读 `requestFormat`
  - 兼容 `request_format`
  - 如果为空且 baseUrl host 包含 `openrouter.ai`，返回 `openrouter-input-audio-json`
  - 否则返回 `generic-json`
- [ ] 新增私有函数 `speechAsrOpenRouterAudioFormat(inputPath: String, mime: String, providerConfig: JsonObject): String`：
  - 优先读 `audioFormat`
  - 然后按 MIME/后缀推断
  - 兜底 `ogg`
- [ ] 修改 `speechAsrOpenAICompatibleRequest`，让 request 中包含：
  - `requestFormat`
  - `contentType`
  - `body`
- [ ] 当 requestFormat 是 `openrouter-input-audio-json` 时：
  - 使用已经读取的音频 bytes 或在构造前传入 bytes
  - `body.input_audio.data = toBase64String(inputBytes)`
  - `body.input_audio.format = inferredFormat`
  - `body.model = model`
  - 可选 `body.language = language`
- [ ] 当 requestFormat 是 `generic-json` 时，保留现有 `filePath/fileBytes/mime` body，避免破坏现有测试。
- [ ] 修改 `speechAsrOpenAICompatibleNativePost`，优先使用 request 内 `body` 和 `contentType`，不要重新硬编码 `filePath/fileBytes/mime`。
- [ ] runner override 仍接收 request object，方便测试所有请求体，不做真实网络。

**验收项**

| 验收项 | 验收命令 | 预期 |
| --- | --- | --- |
| OpenRouter 显式格式通过 | `cjpm test src/core --no-color --no-progress --show-all-output` | OpenRouter 测试通过 |
| OpenRouter host 自动推断通过 | 同上 | 新增 `openRouterAsrProviderInfersRequestFormatFromBaseUrl` 通过 |
| generic-json 向后兼容 | 同上 | 既有 OpenAI-compatible 测试通过 |
| maxBytes 在 base64 前生效 | 同上 | 新增测试确认超限时 runner 不被调用 |

### Phase 3：响应解析和错误诊断收敛

**目标**：OpenRouter 成功/错误响应能映射到 Metis 已有 ASR status，用户不再看到误导性的 TLS 或配置错误。

**修改文件**

- `src/core/gateway_speech_asr_runtime.cj`
- `src/core/gateway_speech_asr_runtime_test.cj`
- `src/gateway/tools/gateway_telegram_media_toolset_test.cj`（只在需要验证工具层输出时修改）

**实施步骤**

- [ ] 复用 `speechAsrOpenAICompatibleTextFromJson` 解析 OpenRouter 成功响应 `{ "text": "..." }`。
- [ ] 如果 OpenRouter 返回 400 且 body 包含 `input_audio`，仍映射 `provider_error`，message 保留前 300 字符并 redaction。
- [ ] 新增测试 `openRouterAsrMapsInputAudioValidationErrorToProviderError`：
  - runner 返回 400 + OpenRouter ZodError JSON
  - 断言 status=`provider_error`
  - 断言 message 包含 `input_audio`
  - 断言 message 不包含 API key 和 base64 data
- [ ] 新增测试 `openRouterAsrParsesJsonText`：
  - runner 返回 200 + `{ "text": "语音测试喽" }`
  - 断言 transcript 正确。

**验收项**

| 验收项 | 验收命令 | 预期 |
| --- | --- | --- |
| 成功响应解析 | `cjpm test src/core --no-color --no-progress --show-all-output` | transcript 为 OpenRouter JSON text |
| 400 诊断准确 | 同上 | status 为 `provider_error`，message 指向 `input_audio` |
| secret/base64 不泄露 | 同上 | result JSON 不包含 API key，不包含完整 base64 |

### Phase 4：文档、配置示例和 smoke 清单更新

**目标**：用户知道 OpenRouter ASR 必须使用 `requestFormat=openrouter-input-audio-json`，也知道 OpenAI/Groq/Mistral 类接口不是同一请求格式。

**修改文件**

- `docs/user/telegram.md`
- `develop_steps/metis-speech-shared-tts-asr-smoke-checklist-2026-05-09.md`
- `develop_steps/metis-speech-openrouter-asr-request-format-plan-2026-05-10.md`

**实施步骤**

- [ ] 在 `docs/user/telegram.md` 的 speech 配置示例中新增 OpenRouter ASR provider：

```json
"openrouter-whisper": {
  "kind": "openai-compatible",
  "baseUrl": "https://openrouter.ai/api/v1",
  "apiKey": "${OPENROUTER_API_KEY}",
  "model": "openai/whisper-large-v3-turbo",
  "requestFormat": "openrouter-input-audio-json",
  "timeoutMs": 60000,
  "maxBytes": 26214400
}
```

- [ ] 文档明确：
  - OpenRouter ASR 是 JSON base64 `input_audio` 形态。
  - OpenAI/Groq/Hermes 参考实现是文件上传/multipart 形态，本轮不把 multipart 伪装成 OpenRouter。
  - `insecureSkipTlsVerify` 是 provider 级调试开关，不是 Telegram network 开关。
- [ ] 在 smoke checklist 增加手动项：
  - 配置 OpenRouter ASR provider。
  - 发送 Telegram voice。
  - 预期 `understandingStatus=ok`，回复内容不再出现 `input_audio` 错误。
  - 再问“我刚才说了什么”，预期工具可读到 transcript。

**验收项**

| 验收项 | 验收命令 | 预期 |
| --- | --- | --- |
| 文档包含 OpenRouter ASR 配置 | `rg -n "openrouter-input-audio-json|OPENROUTER_API_KEY|input_audio" docs/user/telegram.md develop_steps` | 有命中 |
| 文档不包含真实 key | `rg -n "sk-[A-Za-z0-9]|OPENROUTER_API_KEY\\\":\\s*\\\"[^$]" docs/user/telegram.md develop_steps` | 无真实 key |
| smoke checklist 覆盖 Telegram voice | `rg -n "OpenRouter ASR|Telegram voice|understandingStatus=ok|input_audio" develop_steps/metis-speech-shared-tts-asr-smoke-checklist-2026-05-09.md` | 有命中 |

### Phase 5：统一验证

**目标**：本轮修改遵守项目要求，完成构建和测试。

**实施步骤**

- [ ] 执行 core 测试：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH"
cjpm test src/core --no-color --no-progress --show-all-output
```

- [ ] 执行 Telegram media/tooling 相关测试：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH"
cjpm test src/gateway/tools --no-color --no-progress --show-all-output
```

- [ ] 执行项目强制验证：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH"
cjpm clean && cjpm build -i && cjpm test
```

- [ ] 如果全量 `cjpm test` 仍出现包级 `exit code = 9` 聚合运行漂移，必须单跑失败包并记录结果，不得把聚合漂移误报为业务断言失败。

**验收项**

| 验收项 | 验收命令 | 预期 |
| --- | --- | --- |
| core ASR/TTS 测试通过 | `cjpm test src/core --no-color --no-progress --show-all-output` | 通过 |
| Telegram media/tooling 测试通过 | `cjpm test src/gateway/tools --no-color --no-progress --show-all-output` | 通过 |
| 全量 clean/build/test 已执行 | `cjpm clean && cjpm build -i && cjpm test` | clean/build 成功；test 结果记录到本文档 |
| 不访问真实外部服务 | 检查测试 runner override | 所有新增测试不使用真实 OpenRouter、Telegram 或真实 `~/.metis` |

## 风险和边界

1. 本计划不实现 OpenAI/Groq 真 multipart 上传；Hermes 证明这些 provider 使用文件上传形态，但当前用户故障是 OpenRouter `input_audio` JSON 缺失，应先修复 OpenRouter。
2. 本计划不把 OpenRouter 特例写入 Telegram adapter。Telegram 只负责下载 voice/audio 和投递回复，ASR 请求格式属于 core speech runtime。
3. 本计划不把 `gateway.telegram.network.insecureSkipTlsVerify` 传播给 ASR provider。provider TLS 行为必须显式配置，避免通道网络配置意外影响第三方 ASR 服务。
4. 本计划不在日志输出完整 base64 音频、Authorization、API key、Telegram fileId。
5. 手动 smoke 测试需要真实 OpenRouter key，但自动测试不得依赖真实 key。

## 本轮对话落盘记录

1. 用户反馈：加了 provider 级 `insecureSkipTlsVerify=true` 后，Telegram 语音结果仍与上次类似。
2. 排查结果：最新日志证实 TLS 问题已消失，OpenRouter 返回 400，原因是 `input_audio` 缺失。
3. 用户确认：同意新增 OpenRouter ASR 请求格式适配，并要求立即参考 OpenClaw、Hermes、OpenClaw-China 源码制定分阶段落地计划和验收项。
4. 本文档即为该确认后的落地计划，不包含代码改动。
