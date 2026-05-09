# Metis Speech ASR 配置排查记录 2026-05-09

## 背景

用户通过 Telegram bot 发送语音后，收到回复：当前未配置语音识别（ASR）功能。

用户说明 `~/.metis/metis.json` 中已经配置了 ASR 和 TTS，本次只排查原因，暂不改代码。

## 证据

### 运行日志

日志文件：

- `/Users/l3gi0n/.metis/logs/2026_05_09-16_29_53_059781000.log`

关键记录：

- 语音文件已下载并保存：
  - `localPath=/Users/l3gi0n/.metis/gateway-telegram/accounts/default/media/2026-05-09/545/file_9.oga`
  - `mimeType=audio/ogg`
  - `fileSize=6234`
- Telegram media context 标记：
  - `eligibleFor=transcription`
  - `modelHandling=asr-input-ready`
- `telegram_audio_transcribe` 工具返回：
  - `ASRStatus=not_configured`
  - `decision.outcome=not_configured`
  - `reason=native ASR runtime is not configured`
  - `error=native ASR runtime is not configured and no transcript companion file exists`

这说明 Telegram 语音下载和工具调用链路已走通，失败点不是 Telegram 文件保存，也不是模型没有调用工具，而是 ASR runtime 没有解析到可用 provider 配置。

### 当前配置形态

当前 `~/.metis/metis.json` 中 ASR/TTS 配置放在：

- `gateway.tts`
- `gateway.asr`

但已落地的 canonical 配置入口是：

- 共享默认：`gateway.speech.tts` / `gateway.speech.asr`
- Telegram 覆盖：`gateway.telegram.speech.tts` / `gateway.telegram.speech.asr`

Telegram 当前只配置了投递偏好：

- `gateway.telegram.actions.speech.audioAsVoice`
- `gateway.telegram.actions.speech.autoReplyToVoice`

该位置不是 provider 配置入口，也不会让 `telegram_audio_transcribe` 获得 ASR provider。

### 代码依据

- `src/core/config/gateway_user_settings.cj`
  - `GatewaySpeechUserSettings` 定义 `tts` / `asr`
  - `GatewayUserSettings` 持有 `speech: GatewaySpeechUserSettings`
  - `TelegramUserSettings` 持有 `speech: GatewayChannelSpeechUserSettings`
- `src/core/gateway_speech_config.cj`
  - `speechSharedConfig(..., "asr")` 读取 `user.speech.asr`
  - `speechChannelConfig(..., "telegram", "asr")` 读取 `user.telegram.speech.asr`
  - `gatewaySpeechResolveAsrConfig(user, channel: "telegram")` 不读取 `gateway.asr`
- `docs/user/telegram.md`
  - 明确记录 canonical 配置入口是 `gateway.speech.tts` / `gateway.speech.asr`
  - Telegram channel override 是 `gateway.telegram.speech.tts` / `gateway.telegram.speech.asr`

## 初步结论

这次 Telegram 语音返回“未配置 ASR”的主要原因是配置路径不匹配：

- 当前配置写在 `gateway.asr`
- 实现读取的是 `gateway.speech.asr` 或 `gateway.telegram.speech.asr`

因此 ASR runtime 看到的是空配置，并返回 `not_configured`。

另外，从文件时间看：

- 语音文件保存时间：2026-05-09 16:30:47
- `~/.metis/metis.json` 修改时间：2026-05-09 16:31:24

本次语音处理发生时，配置文件可能尚未保存为当前内容。即使迁移到正确路径，仍应重启 Gateway 或确认热加载已生效后再测试。

## 建议修复方向

不改代码的修复方式：

1. 将当前 `gateway.tts` 移到 `gateway.speech.tts`。
2. 将当前 `gateway.asr` 移到 `gateway.speech.asr`。
3. 保留 Telegram 投递偏好，但建议放到 `gateway.telegram.speech.audioAsVoice` / `gateway.telegram.speech.autoReplyToVoice`。
4. 重启 Gateway。
5. 用同一个语音或新语音复测，预期日志中 `ASRStatus` 从 `not_configured` 变为 `transcribed`，或变为 provider 运行错误；如果变为 provider 错误，再继续排查 ASR 脚本依赖。

## 验收项

| 编号 | 验收项 | 通过标准 |
| --- | --- | --- |
| ASR-DIAG-01 | 配置入口 | `metis.json` 中存在 `gateway.speech.asr.enabled=true` 和有效 provider。 |
| ASR-DIAG-02 | Telegram 覆盖优先级 | 若配置 `gateway.telegram.speech.asr`，Telegram 语音优先使用该 provider。 |
| ASR-DIAG-03 | Gateway 重载 | 重启 Gateway 后，日志不再出现 `native ASR runtime is not configured`。 |
| ASR-DIAG-04 | 语音转写 | Telegram 发送 voice 后，日志或工具结果出现 `ASRStatus=transcribed`。 |
| ASR-DIAG-05 | provider 故障隔离 | 若 ASR 脚本缺依赖或执行失败，状态应是 `provider_error` / `timeout` 等，而不是 `not_configured`。 |

## 二次排查：配置已迁移后仍返回 not_configured 和 too_large

用户按建议把 ASR/TTS 配置迁移到 `gateway.speech.*` 后，再次通过 Telegram bot 发送语音，收到回复：

- 当前未配置语音识别（ASR）功能
- 该语音文件大小超出了可处理的限制

本轮检查确认当前 `~/.metis/metis.json` 中 speech 配置入口已经正确：

- `gateway.speech.asr.provider=local-whisper`
- `gateway.speech.asr.providers.local-whisper.kind=command`
- `gateway.speech.asr.providers.local-whisper.command=python3 /Users/l3gi0n/.metis/scripts/asr_faster_whisper.py {input}`
- `gateway.speech.asr.maxBytes=26214400`
- `gateway.speech.tts.provider=edge`
- `gateway.telegram.speech.autoReplyToVoice=true`

未在文档中记录 token、密钥或完整真实配置内容。

### 二次证据

本次 Telegram 语音文件：

- `/Users/l3gi0n/.metis/gateway-telegram/accounts/default/media/2026-05-09/549/file_11.oga`
- 文件大小：9088 bytes

运行进程和配置时间：

- Gateway 进程启动时间早于本次配置保存时间，需要重启后才能确保新配置进入运行时。
- 但日志中的 `telegram_audio_transcribe` 失败还暴露了一个代码问题：工具结果包含 `media exceeds configured maxBytes`，而语音只有 9088 bytes，明显不应超过用户配置的 26214400 bytes。

日志关键现象：

- Telegram inbound 已到达 Gateway。
- 语音文件已下载。
- media context 已标记 `eligibleFor=transcription` 和 `modelHandling=asr-input-ready`。
- `telegram_audio_transcribe` 返回 `decision.outcome=rejected`、`reason=media exceeds configured maxBytes`。
- 同一返回里仍带 `ASRStatus=not_configured`，导致模型回复同时出现“未配置 ASR”和“文件过大”。

### 根因

代码路径 `telegram_audio_transcribe -> gatewayMediaUnderstandingForRecord(record, capability: "audio")` 使用了 media understanding 默认 `maxBytes=8192`。

因此 9088 bytes 的 Telegram voice 在进入 ASR provider 前，就被通用媒体预览大小限制拒绝。此处没有读取 `gateway.speech.asr.maxBytes=26214400`，所以用户配置虽然正确，但没有在这个 ASR 转写入口生效。

### 已落地修复

修复点：

- `src/core/gateway_media_understanding_runtime.cj`
  - 新增 `gatewayMediaUnderstandingForRecordWithSettings`，测试可注入隔离配置。
  - Telegram/audio 进入 ASR 时，先按通道读取 `gateway.telegram.speech.asr`，再 fallback 到共享 `gateway.speech.asr`。
  - audio capability 不再受通用 media preview 默认 8192 bytes 限制。
  - ASR provider 返回 `provider_error`、`timeout`、`too_large` 等状态时，透传为明确 `ASRStatus`，避免混成 `not_configured`。
- `src/gateway/tools/gateway_telegram_media_toolset_test.cj`
  - “未配置 ASR”测试改为使用测试专用 `METIS_HOME`，防止读取真实 `~/.metis/metis.json` 并启动本机 ASR 脚本。
- `src/core/gateway_media_understanding_runtime_test.cj`
  - 新增 `sharedAsrMaxBytesOverridesMediaDefaultLimit`，覆盖 9000 bytes 音频在共享 ASR `maxBytes=26214400` 下应正常转写。

### 当前环境依赖检查

- `faster_whisper`：本机 Python 可导入，ASR 脚本依赖基础可用。
- `edge-tts`：当前 PATH 中未找到 `edge-tts` 命令。若继续使用当前 TTS provider，需要安装或改成可执行的命令形式。

### 自动验证

| 编号 | 命令 | 结果 |
| --- | --- | --- |
| ASR-DIAG-06 | `cjpm test src/core --no-color --no-progress --show-all-output` | 2026-05-09 通过，100 passed、0 failed。 |
| ASR-DIAG-07 | `cjpm test src/gateway/tools --no-color --no-progress --show-all-output` | 2026-05-09 通过，75 passed、0 failed。 |
| ASR-DIAG-08 | `cjpm test src/gateway/core --no-color --no-progress --show-all-output` | 2026-05-09 通过，127 passed、0 failed。 |
| ASR-DIAG-09 | `cjpm clean && cjpm build -i && cjpm test --no-color --no-progress --show-all-output` | 2026-05-09 通过，1032 passed、0 failed、0 error。首次全量运行中 `metis.gateway.tools` 曾出现一次测试进程 error，单包重跑通过；随后按同一 clean/build/test 全量重跑通过。 |

### 用户下一步手动验收

1. 重新构建并重启 Gateway，必须让新二进制和新配置一起进入运行时。
2. 发送一条短 Telegram voice。
3. 检查日志中不应再出现 `media exceeds configured maxBytes`。
4. 若 ASR 成功，应出现 `ASRStatus=transcribed`。
5. 若 ASR 首次运行较慢，可能是 faster-whisper 加载或下载模型；如超时，增大 `gateway.speech.asr.providers.local-whisper.timeoutMs`。
6. 若要语音回复，当前已实现的确定链路是 Telegram `/tts audio <text>`；自动识别“请用语音回复”并把普通模型回复转成语音，仍属于后续 auto-TTS 阶段。

## 三次排查：Telegram 已回复 ASR timeout

用户再次发送 Telegram voice 后收到回复：

- 语音识别超时了，可能是 ASR 服务响应较慢或文件处理遇到了问题。
- 文件路径：`/Users/l3gi0n/.metis/gateway-telegram/accounts/default/media/2026-05-09/553/file_13.oga`

### 三次证据

运行进程：

- Gateway 当前进程为 2026-05-09 18:28:33 启动的新进程，配置文件同在 18:28 更新；本轮不是旧二进制或旧配置问题。

日志关键链路：

- `Gateway.inbound` 收到 Telegram `messageId=553`。
- 媒体文件已下载：`file_13.oga`，7654 bytes，`mediaKind=voice`，`mimeType=audio/ogg`。
- 模型调用了 `telegram_audio_transcribe`。
- 工具 observation 返回：
  - `ASRStatus=timeout`
  - `decision.outcome=timeout`
  - `reason=Configured ASR provider command timed out.`
- 因此用户收到的 timeout 回复来自真实 ASR 工具结果，不是模型猜测。

本机手动执行同一命令：

```text
python3 /Users/l3gi0n/.metis/scripts/asr_faster_whisper.py /Users/l3gi0n/.metis/gateway-telegram/accounts/default/media/2026-05-09/553/file_13.oga
```

观察：

- 手动执行 93 秒仍未完成，已手动停止，避免后台继续占资源。
- stdout 出现 Hugging Face 未认证下载提示，说明脚本正在尝试从 HF Hub 下载模型。
- `~/.cache/huggingface/hub/models--Systran--faster-whisper-small` 只有约 2.6MB，并存在 `.incomplete` 文件，说明 `faster-whisper-small` 模型未完整下载。
- 本机 PATH 中未找到 `ffmpeg`。
- 输入文件是 Ogg/Opus：`Ogg data, Opus audio, mono, 48000 Hz`，缺少 `ffmpeg` 会影响 Whisper/音频解码链路。

### 三次根因

当前 ASR 配置已经被 Gateway 读取并执行，失败点在 provider 命令运行环境：

1. `faster-whisper-small` 模型缓存未完整下载，ASR 脚本在初始化模型时等待下载，超过 provider `timeoutMs=120000` 后被 Metis 判为 timeout。
2. 本机缺少 `ffmpeg`，即使模型下载完成，处理 Telegram `.oga` / Opus 语音也可能继续失败。

### 建议修复步骤

1. 安装或确保 `ffmpeg` 在 Gateway 运行进程 PATH 中可见。
2. 预下载并预热 `faster-whisper-small` 模型，直到 Hugging Face 缓存中不再有 `.incomplete` 文件。
3. 在命令行单独执行 ASR 脚本确认能在 120 秒内输出文字。
4. 若首次模型加载仍慢，可临时把 `gateway.speech.asr.providers.local-whisper.timeoutMs` 调大到 300000。
5. 如需更快 smoke，可先把脚本模型从 `small` 改为 `tiny` 或 `base` 验证链路，再回到 `small`。

## 四次排查：ASR 成功但 Telegram voice 入站不自动语音回复

用户手动验证：

- Telegram 发送 `/tts audio 你好，这是 Metis 的语音回复测试` 后，已收到语音回复。
- Telegram 发送 voice 后，ASR 成功，收到文本回复：`语音识别成功！收到的内容是："语音测试喽"`。

### 四次证据

当前配置摘要：

- 共享 TTS 已启用，provider 为 `edge`。
- 共享 ASR 已启用，provider 为 `local-whisper`。
- Telegram speech 偏好中 `audioAsVoice=true`。
- Telegram speech 偏好中 `autoReplyToVoice=true`。
- Telegram 未配置独立 TTS/ASR provider，按设计 fallback 到共享 provider。

日志关键链路：

- `/tts audio ...` 命令路径已成功调用 TTS，并完成 Telegram 发送。
- Telegram voice 入站日志存在 `Gateway.inbound: channel=telegram`，说明不是 polling、proxy、pairing 或 Telegram 下载问题。
- voice 入站后的 media context 中已有 transcript，ASR 工作正常。
- 模型最终生成了文本答案。
- 发送阶段只出现 `Gateway.sendTextToPeer` / `Gateway.send`，没有 TTS 合成记录，也没有 `[voice]` / `[audio]` payload 投递记录。

### 四次根因

根因不是当前 TTS 配置，也不是 Telegram voice 投递能力；`/tts audio` 成功已经证明显式 TTS 命令链路可用。

实际问题是代码路径缺口：

- `autoReplyToVoice` 已被配置和解析，但普通 Telegram voice 入站后的模型回复仍直接走文本 `deliverHook`。
- `deliverHook` 没有在 `autoReplyToVoice=true` 且入站消息为 voice/audio 时，把最终模型文本交给 `gatewaySpeechTtsSynthesize`。
- Telegram 流式回复还会提前投递文本分片，因此自动语音回复场景需要在该 turn 临时关闭 Telegram streaming，避免先发文本再发语音。

### 已落地修复

修复点：

- `src/gateway/core/gateway_service.cj`
  - 新增 Telegram voice/audio 入站识别逻辑。
  - 当 `gateway.telegram.speech.autoReplyToVoice=true` 且消息为 voice/audio 时，对本轮 session 临时关闭 Telegram streaming。
  - 在最终回复 `deliverHook` 中调用共享的 `gatewaySpeechResolveTtsConfig`、`gatewaySpeechResolveDeliveryPrefs`、`gatewaySpeechTtsSynthesize`。
  - TTS 成功时把文本回复替换为 `[voice]` / `[audio]` payload；TTS 失败时保留原文本回复并记录 fallback 日志。
  - 自动 TTS 继续遵守 Telegram 通道覆盖优先于共享配置的规则。
- `src/gateway/core/gateway_service_telegram_native_test.cj`
  - 新增 `t53VoiceInboundAutoReplyUsesTtsPayloadWhenEnabled`，覆盖 voice 入站且 `autoReplyToVoice=true` 时发送语音 payload。
  - 新增 `t53VoiceInboundAutoReplyFallsBackToTextWhenDisabled`，覆盖 `autoReplyToVoice=false` 时保持文本回复。

### 自动验证

| 编号 | 命令 | 结果 |
| --- | --- | --- |
| ASR-DIAG-10 | `cjpm test src/gateway/core --no-color --no-progress --show-all-output` | 2026-05-09 通过，129 passed、0 failed。 |
| ASR-DIAG-11 | `cjpm clean && cjpm build -i && cjpm test --no-color --no-progress --show-all-output` | 2026-05-09 `clean` 和 `build -i` 通过。全量 test 期间曾出现包级 `exit code=9` 或既有 OpenClaw sidecar 单例测试偶发失败；相关包单独复核通过，最终完整 `cjpm test --no-color --no-progress --show-all-output` 通过，1034 passed、0 failed、0 error。 |

### 用户下一步手动验收

1. 重新构建并重启 Gateway，确保运行的是新二进制。
2. 保持 `gateway.telegram.speech.autoReplyToVoice=true`。
3. 保持 `gateway.telegram.speech.audioAsVoice=true`，或通过共享 delivery prefs 设置为 voice 投递。
4. Telegram 发送一条短 voice。
5. 预期：先看到正常 processing/typing 类状态，最终收到语音回复；日志中出现 `Telegram auto TTS reply synthesized`。
6. 若最终仍为文本，检查日志中的 `Telegram auto TTS reply fallback to text`，再按其中 `status` 继续排查 TTS provider。

## 五次排查：Telegram voice 第二次出现文字回复加 silent_reply 语音

用户手动验证：

- 第一次 Telegram voice 已能得到语音回复。
- 第二次 Telegram voice 收到两条回复：
  - 第一条是正常文字回复。
  - 第二条是 `silent_reply` 的语音。

### 五次证据

运行日志显示同一轮 Telegram voice 入站后出现两条不同发送路径：

1. 模型先调用 `message` 工具，向 Telegram 发送用户可见文字回复。
2. 随后模型最终答案返回 `<SILENT_REPLY>`，这是系统提示中约定的“可见回复已经由 message 工具发送，最终答案不要再发”的静默标记。
3. Telegram voice 入站的 `autoReplyToVoice` 路径在最终 `deliverHook` 中会把最终答案交给 TTS。
4. 旧逻辑只去掉 `[[reply_to_current]]` 这类 reply tag，没有识别 `<SILENT_REPLY>`；因此 `<SILENT_REPLY>` 被当成普通文本合成为语音，用户听到 `silent_reply`。

### 五次根因

根因不是 ASR，也不是 TTS provider；问题在 Telegram 自动语音回复的最终投递路径：

- `message` 工具已经完成真实文字回复。
- `<SILENT_REPLY>` 本应阻止重复回复。
- 自动 TTS 路径没有把 `<SILENT_REPLY>` 作为不可投递文本处理，导致重复语音回复。

后续用户明确调整验收规则：

- 当 Telegram 收到 voice/audio 入站时，如果 `audioAsVoice=true` 且 `autoReplyToVoice=true`，本轮所有用户可见回复都应尽量用语音发送。
- 即使模型最终误返回 `<SILENT_REPLY>`，也不能静默无回复；若本轮没有工具已交付的可见回复，应合成一条 voice fallback。
- 如果模型已经通过 `message` 工具交付了可见回复，则最终 `<SILENT_REPLY>` 只表示“不要重复回复”，不应再触发 fallback。

### 已落地修复

修复点：

- `src/gateway/core/gateway_service.cj`
  - 新增 `telegramIsSilentReplyText`，仅识别完整的 `<SILENT_REPLY>` / `silent_reply` 静默标记。
  - 在 Telegram voice 入站且 `autoReplyToVoice=true` 的 `deliverHook` 中，若最终文本为静默标记，不再发送字面量 `silent_reply`，而是按语音入口规则生成 `我已收到你的语音：...` fallback 并交给 TTS。
  - 保持普通文本自动 TTS、显式 `/tts audio`、非 Telegram 通道不受影响。
- `src/core/gateway_tool_runtime_context.cj`
  - 新增 `visibleReplyDelivered` 运行时标记，用于记录模型工具是否已经交付用户可见回复。
- `src/gateway/core/gateway_session_executor.cj`
  - 如果工具已交付可见回复，且最终答案是 `<SILENT_REPLY>`，执行器返回 `delivered-by-tool`，不再调用最终 `deliverHook`，避免重复回复。
- `src/gateway/tools/gateway_message_toolset.cj`
  - Telegram voice/audio 入站上下文中，若 `autoReplyToVoice=true` 且 `audioAsVoice=true`，`message` 工具的 `send/reply/thread` 文本会先经 TTS 转成 `[voice]` payload 再调用 `channels.send`。
  - `message` 工具成功交付 `send/reply/thread/poll/media` 等用户可见动作后，会标记本轮已交付。
- `src/gateway/core/gateway_service_telegram_native_test.cj`
  - 新增 `GatewayTelegramNativeSilentReplyFakeModel`，模拟模型最终返回 `<SILENT_REPLY>`。
  - 新增 `t53VoiceInboundAutoReplyFallsBackToVoiceWhenModelReturnsSilentReplyToken`，覆盖 voice 入站自动语音回复路径不会发送静默文本，且会合成 fallback voice。
- `src/gateway/core/gateway_session_turn_runner_test.cj`
  - 新增 `telegramSilentReplyAfterToolDeliveryDoesNotSendDuplicateFinalMessage`，覆盖工具已交付后最终 silent 不会重复发送。
- `src/gateway/tools/gateway_message_toolset_test.cj`
  - 新增 `telegramVoiceInputMessageToolSynthesizesTextReplyToVoiceAndMarksDelivered`，覆盖 `message` 工具文本回复自动转 voice，并标记已交付。

### 五次自动验收

| 编号 | 命令 | 结果 |
| --- | --- | --- |
| ASR-DIAG-12 | `cjpm test src/gateway/core --no-color --no-progress --show-all-output` | 2026-05-09 通过，130 passed、0 failed。 |
| ASR-DIAG-13 | `cjpm clean && cjpm build -i && cjpm test --no-color --no-progress --show-all-output` | 2026-05-09 `clean` 和 `build -i` 通过；首次全量 test 出现 `metis.io` / `metis.program` 包级 `exit code=9`，单独复跑这两个包通过，随后完整 `cjpm test --no-color --no-progress --show-all-output` 通过，1035 passed、0 failed、0 error。 |
| ASR-DIAG-14 | `cjpm test src/gateway/core --no-color --no-progress --show-all-output` | 2026-05-09 通过，131 passed、0 failed。 |
| ASR-DIAG-15 | `cjpm test src/gateway/tools --no-color --no-progress --show-all-output` | 2026-05-09 通过，76 passed、0 failed。 |
| ASR-DIAG-16 | `cjpm clean && cjpm build -i && cjpm test --no-color --no-progress --show-all-output` | 2026-05-09 通过；`clean` 通过，`build -i` 通过，最终全量 `cjpm test` 通过，1037 passed、0 failed、0 error。 |

### 五次手动验收

1. 重新构建并重启 Gateway，确保运行新二进制。
2. Telegram 连续发送两条 voice。
3. 若模型直接回答，预期每条 voice 最终只收到一条语音回复。
4. 若模型先用 `message` 工具发送回复，再返回 `<SILENT_REPLY>`，预期工具回复本身为 voice，且不会再收到第二条 fallback voice。
5. 若模型没有通过工具发送任何可见回复，但最终误返回 `<SILENT_REPLY>`，预期收到一条 fallback voice，内容类似 `我已收到你的语音：<transcript>`。
6. 全链路不应再出现字面量 `silent_reply` 的文字或语音。

## 六次排查：Telegram 文本显式要求语音但收到“无法发送语音”

用户手动验证：

- Telegram voice 入站已经能正常收到语音回复。
- 发送文本 `发一条语音信息给我，随便说点什么。` 时，收到文字回复称“目前无法直接发送语音消息”。

### 六次证据

日志 `/Users/l3gi0n/.metis/logs/2026_05_09-22_00_05_019443000.log` 显示：

1. `2026-05-09T22:03:39` 出现 `Gateway.inbound: channel=telegram`，说明消息已进入 Gateway。
2. 模型没有调用 Metis 的 `/tts` native command，也没有发送 `[voice]` / `[audio]` payload。
3. 模型连续调用 `shellExecute`，试图用 `say` 和 `ffmpeg` 在 `/tmp` 手工生成音频文件。
4. Telegram 通道中的 shell 工具需要交互式确认，IM 运行时无法读取确认输入，报错栈落在 `InputUtils.confirm` / `RawInputUtils.getRune`。
5. 模型随后根据 shell 失败自行输出“无法直接发送语音消息”。

### 六次根因

根因不是 TTS provider、Telegram voice 投递能力或配置失效；前面的 `/tts audio` 与 voice 入站自动 TTS 已证明这些链路可用。

真正问题有两层：

- 普通文本显式要求“语音回复”时，Gateway 没有把本轮交付意图识别为 TTS/voice。
- Telegram Gateway system prompt 没有明确告诉模型：不要用 `shellExecute` 或临时文件自造语音；只需要输出要朗读的文本，由 Gateway 负责 TTS 合成和 Telegram voice 投递。

### 六次已落地修复

修复点：

- `src/gateway/core/gateway_service.cj`
  - 新增 Telegram 文本显式语音请求识别逻辑，覆盖中文 `发/回复/说/读/讲 + 语音` 与英文 `send/reply/speak/say + voice/audio`。
  - 对 Telegram 文本显式语音请求，只要 `audioAsVoice=true`，最终可见回复会经现有 TTS runtime 合成为 `[voice]` payload。
  - 若模型最终误返回 `<SILENT_REPLY>` 且本轮没有工具可见回复，文本显式语音请求会合成通用 fallback voice：`你好，这是 Metis 的语音回复。`
- `src/gateway/core/agent_bridge.cj`
  - Telegram system prompt 新增 Voice/TTS 指引：用户要求语音/音频回复时，不要调用 `shellExecute`、host TTS 命令或临时文件；直接输出要朗读的最终文本，Gateway 会按配置合成并投递。
- `src/gateway/tools/gateway_message_toolset.cj`
  - `message` 工具在 Telegram 显式语音请求上下文中发送 `send/reply/thread` 文本时，也会经 TTS 转为 `[voice]` payload；voice 入站仍继续要求 `autoReplyToVoice=true`。
- `src/gateway/core/gateway_service_telegram_native_test.cj`
  - 新增 `t53TextExplicitVoiceRequestUsesTtsVoicePayloadWhenEnabled`，覆盖文本显式语音请求最终发 `[voice]`，不发纯文本答案。
- `src/gateway/core/gateway_session_turn_runner_test.cj`
  - 新增 `telegramSystemPromptTellsModelGatewayHandlesVoiceReplyTts`，覆盖 Telegram system prompt 明确禁止模型用 `shellExecute` 自造音频。
- `src/gateway/tools/gateway_message_toolset_test.cj`
  - 新增 `telegramExplicitVoiceRequestMessageToolSynthesizesTextReplyToVoice`，覆盖显式语音请求上下文中 `message` 工具文本回复自动转 voice。

### 六次自动验收

| 编号 | 命令 | 结果 |
| --- | --- | --- |
| ASR-DIAG-17 | `cjpm test src/gateway/core --no-color --no-progress --show-all-output` | 2026-05-09 通过，133 passed、0 failed。 |
| ASR-DIAG-18 | `cjpm test src/gateway/tools --no-color --no-progress --show-all-output` | 2026-05-09 通过，77 passed、0 failed。 |
| ASR-DIAG-19 | `cjpm clean && cjpm build -i && cjpm test --no-color --no-progress --show-all-output` | 2026-05-09 通过；`clean` 通过，`build -i` 通过。首次全量 test 出现 `metis.core.skills` / `metis.program` 包级 `exit code=9`，其中 `metis.core.skills` 单包复跑 37/37 通过，`metis.program` 用 `--parallel 1 -j 1` 复跑 8/8 通过；随后默认完整 `cjpm test --no-color --no-progress --show-all-output` 通过，1040 passed、0 failed、0 error。 |

### 六次手动验收

1. 重新构建并重启 Gateway，确保 Telegram bot 使用新二进制。
2. 发送文本 `发一条语音信息给我，随便说点什么。`
3. 预期最终收到 Telegram voice，不应再收到“无法直接发送语音消息”的文字答复。
4. 日志中不应再出现该轮模型调用 `shellExecute` 生成 `/tmp/metis_voice_test.*`。
5. 日志中应出现 `Telegram auto TTS reply synthesized: payloadKind=voice` 或 `channels.send` 的 `[voice]` payload。
