# Metis Speech Model-Driven TTS 落地方案

日期：2026-05-09

## 背景

本轮调查源于 Telegram 文本消息“发一条语音信息给我，随便说点什么。”未自然触发语音回复的问题。前一轮临时实现里存在中文/英文关键字判断，这能覆盖部分测试，但不应作为长期架构：它把“是否应发语音”的语义判断固化在 Gateway 代码中，无法覆盖模型自由表达、上下文指代、多语言变体和未来 IM 通道。

本方案只记录源码证据和分阶段落地方案；本轮不修改业务代码。

## 参考源码证据

### OpenClaw 主仓库

1. `openclaw/src/agents/openclaw-tools.ts:34` 引入 `createTtsTool`，`openclaw/src/agents/openclaw-tools.ts:219-238` 将 `createTtsTool` 放入 agent tools。这说明 TTS 是模型可调用工具，而不是仅靠命令或硬编码文本判断。
2. `openclaw/src/agents/tools/tts-tool.ts:17-26` 定义 agent tool `tts`，描述为“Convert text to speech”，并要求成功后回复 silent token 以避免重复消息。
3. `openclaw/src/agents/tools/tts-tool.ts:31-49` 调用 `textToSpeech`，成功后返回 `details.media.mediaUrl`，并在 voice-compatible 时返回 `audioAsVoice: true`。
4. `openclaw/src/agents/tools/tts-tool.test.ts:14-43` 验证 TTS tool 的指导文本包含 silent token，且音频交付信息写入 `details.media`，不是写入 `MEDIA:` 文本。
5. `openclaw/src/agents/pi-embedded-subscribe.tools.ts:220-277` 明确从 tool result 的 `details.media` 中提取 `mediaUrl/mediaUrls/audioAsVoice`，这是结构化媒体结果通道。
6. `openclaw/src/agents/system-prompt.ts:233-242` 只有存在 TTS hint 时才构建 `Voice (TTS)` 系统提示区；`openclaw/src/auto-reply/reply/commands-system-prompt.ts:120-138` 将 `buildTtsSystemPromptHint` 注入 agent system prompt。
7. `openclaw/src/auto-reply/reply/commands-tts.ts:126-164` `/tts audio <text>` 是命令式入口，成功后返回 `mediaUrl` 与 `audioAsVoice`。这与 agent tool 并存，不互相替代。
8. `openclaw/src/auto-reply/reply/dispatch-from-config.ts:563-599` final reply 会经过 `maybeApplyTtsToPayload` 再分发；`dispatch-from-config.ts:970-994` block streaming 完成后也可生成 TTS-only reply。
9. `openclaw/extensions/telegram/src/bot/delivery.replies.ts:342-446` Telegram delivery 根据 `reply.audioAsVoice` 决定 `sendVoice` 或 `sendAudio`，并处理 voice forbidden、caption too long 等 fallback。
10. `openclaw/extensions/telegram/src/send.ts:924-950` 发送层同样通过 `opts.asVoice` 和媒体类型选择 `sendVoice` 或 `sendAudio`。

结论：OpenClaw 的主路径是“模型可调用 TTS tool 生成结构化媒体结果 + 分发层按媒体 payload 发送”，不是在 Telegram Gateway 中硬编码自然语言意图。

### openclaw-china 仓库

当前工作区没有 `openclaw-chaine` 目录，实际存在 `/Users/l3gi0n/work/workspace_cangjie/openclaw-china`。本次按 `openclaw-china` 核对。

1. `openclaw-china/extensions/wecom-app/src/channel.ts:526-572` 根据 `mediaUrl/mimeType` 识别 voice，并走 `downloadAndSendVoice`，失败时 fallback 到文件。
2. `openclaw-china/extensions/feishu/src/bot.ts:361-447` delivery payload 支持 `{ text, mediaUrl, mediaUrls }`，先发送文本，再逐个发送媒体。
3. `openclaw-china/extensions/dingtalk/src/bot-handler.ts:1381-1459` delivery payload 同样支持 `{ text, mediaUrl, mediaUrls }`，并对媒体发送失败做文本 fallback。
4. `openclaw-china/extensions/qqbot/src/bot.ts:1428-1432` 有清理 `tts/audio_as_voice` directive 的逻辑；`extensions/qqbot/src/outbound.ts:523-550` 通过 `sendMedia` 发送媒体并在需要时追加文本 fallback。

结论：openclaw-china 更像是 IM 通道侧媒体 payload 发送抽象的证据；本次未找到与 OpenClaw 主仓库同等的通用 agent `tts` tool runtime。它支持“上游给媒体 payload，通道负责发送”，但不能证明应在 Metis 里继续硬编码语音意图。

## Metis 当前状态

1. `src/gateway/core/agent_bridge.cj:28-43` 的 Gateway agent tools 包含 `GatewayMessageToolset` 和 `GatewayTelegramMediaToolset`，但没有独立的模型可调用 `GatewayTtsToolset`。
2. `src/gateway/core/agent_bridge.cj:248-250` 当前 Telegram TTS hint 要求模型“写出最终文本，由 Gateway 合成语音”，而不是让模型调用 TTS tool。
3. `src/gateway/core/gateway_service.cj:260-303` 和 `src/gateway/tools/gateway_message_toolset.cj:129-164` 存在 `telegramTextExplicitlyRequestsVoiceReply` 关键字判断。
4. `src/gateway/tools/gateway_message_toolset.cj:166-213` 会在 voice input 或关键字命中时，把普通文本转成 `[voice]`/`[audio]` payload。
5. `src/gateway/tools/gateway_message_toolset.cj:246-356` 的 `message` tool 已支持 `audio` 和 `voice` action，但模型需要已有音频文件路径；它不负责 TTS 合成。
6. `src/gateway/channels/telegram/telegram_adapter.cj` 已有 `[voice]`/`[audio]` outbound payload 到 `sendVoice`/`sendAudio` 的发送能力，现阶段不需要改 Telegram transport 边界。

结论：Metis 已具备 TTS provider、Telegram voice/audio 发送和 message tool，但缺少“模型可调用 TTS 生成音频”的工具层。当前硬编码关键字判断应视为临时兼容路径，不应成为长期方案。

## 目标架构

长期目标是把 TTS 分为三条清晰路径：

1. 命令式 TTS：`/tts audio <text>` 继续作为 native command，适合用户直接测试 provider。
2. 自动 TTS：当入站是 voice/audio 且 `autoReplyToVoice=true`、`audioAsVoice=true` 时，最终回复直接转语音。这是确定性策略，不依赖模型判断。
3. 模型驱动 TTS：当用户显式或隐式要求语音回复时，由模型调用 `tts` 工具生成音频 payload，再通过既有 Gateway message/channel delivery 发送，模型最后 silent reply，避免重复文本。

这三条路径共享同一套 `gateway.speech.tts` / `gateway.<im>.speech.tts` 配置解析，且 IM 私有配置优先于共享配置。

## 分阶段落地方案

### Phase 1：补齐模型可调用 TTS 工具

任务：

- 新增 `GatewaySpeechToolset` 或 `GatewayTtsToolset`，注册模型可调用工具 `tts`。
- 工具参数至少包含 `text`、可选 `channel`、可选 `asVoice`。
- 工具调用 `gatewaySpeechResolveTtsConfig` 与 `gatewaySpeechTtsSynthesize`，输出结构化 JSON：`ok`、`status`、`audioPath`、`provider`、`payloadKind`、`payloadPreview`。
- 工具不直接读写真实用户配置；测试通过构造 `GatewayUserSettings` 或 test hook 使用临时目录。

验收项：

- 单测验证 `tts(text="你好", channel="telegram", asVoice=true)` 生成 `[voice]` payload。
- 单测验证未配置 provider 时返回结构化 `not_configured`，不调用 shell、不伪造成功。
- 单测验证 IM 私有 TTS 配置优先于共享 TTS 配置。
- `cjpm clean && cjpm build -i && cjpm test` 全部通过。

### Phase 2：让模型知道何时调用 TTS tool

任务：

- 调整 `buildGatewaySystemPrompt` 的 Telegram TTS hint：从“写最终文本，由 Gateway 硬转语音”改为“需要语音时调用 `tts` 工具，成功后使用 silent reply 避免重复文本”。
- 保留“不要使用 shellExecute、host TTS 命令或临时脚本生成语音”的约束。
- 工具描述必须说明成功后如何交付：优先返回可由 Gateway delivery 发送的 voice/audio payload。

验收项：

- 单测验证 Telegram system prompt 包含 `tts` tool 使用说明和 silent reply 约束。
- 单测验证非 Telegram 通道不注入 Telegram 专属 voice 发送描述；后续多 IM 可通过通道能力扩展。
- 单测验证 tool allowlist / tool catalog 中包含 `tts`。
- 全量构建与测试通过。

### Phase 3：把 TTS tool 结果接入可见回复交付

任务：

- 对齐 OpenClaw `details.media` 模式，在 Metis 中确定工具结果如何被 Gateway agent runner / message delivery 识别为已发送或待发送媒体。
- 推荐路径：`tts` 工具返回 `[voice]`/`[audio]` payload，并通过现有 `channels.send` 或当前会话 reply 目标发送；成功后调用 `gatewayMarkCurrentToolRuntimeVisibleReplyDelivered()`。
- 若选择两步模式，则模型先调用 `tts` 生成音频，再调用 `message action=voice/audio` 发送；必须在 prompt 和工具结果中清楚给出音频路径。

验收项：

- fake model/tool runner 测试：用户要求“发语音”时，模型调用 `tts`，最终只收到一条 voice/audio，不再收到“我无法发送语音”的文本。
- 测试覆盖工具成功后 `<silent_reply>`/`silent_reply` 不会触发第二条文本。
- 测试覆盖工具失败时返回清晰文字诊断，而不是 silent。
- 不真实连接 Telegram，不读取真实 `~/.metis/metis.json`。

### Phase 4：收敛或移除硬编码语音意图判断

任务：

- 将 `telegramTextExplicitlyRequestsVoiceReply` 从“判断文本是否要求语音”的主路径中移除，或只保留为短期兼容开关。
- 保留确定性 `autoReplyToVoice`：当入站是 voice/audio 且配置开启时，所有最终回复都直接转语音。这是用户已认可的策略，不属于自然语言意图硬编码。
- 删除“发/说/voice/audio”等关键字组合驱动的普通文本转语音逻辑。

验收项：

- 单测验证普通文本“发一条语音信息给我”不再被 Gateway 关键字函数直接改写；必须通过模型工具调用完成。
- 单测验证入站 voice/audio + `autoReplyToVoice=true` 仍自动语音回复。
- 单测验证入站 text + 未调用 TTS tool 时不会被偷偷转语音。
- 全量构建与测试通过。

### Phase 5：多 IM 扩展边界

任务：

- 复用共享 TTS config resolver，不把 Telegram 逻辑写入核心 TTS provider。
- 通道适配层只负责“voice/audio/media payload 如何发出去”，参考 openclaw-china 的 `mediaUrl/mediaUrls` delivery 方式。
- Telegram、Feishu、DingTalk、WeCom 等通道可逐步声明是否支持 voice/audio 原生发送；不支持时 fallback 到 audio file/document 或清晰诊断。

验收项：

- fake channel 测试覆盖支持 voice、仅支持 audio、仅支持 document 三类能力。
- Telegram 仍走 `[voice]`/`sendVoice`，不改 transport/proxy/session 边界。
- 文档说明共享配置与 IM 私有配置优先级。

## 当前建议

认可用户判断：不应该把“用户文字里是否想要语音”长期硬编码在 Gateway。应改为 OpenClaw 式模型可调用 `tts` 工具，让大模型在需要语音时调用工具；Gateway 只负责工具能力、配置解析、媒体 payload 和通道交付。

但 `autoReplyToVoice=true` 是另一类确定性产品策略，应保留：当用户用语音输入且配置要求语音回复时，Gateway 可以直接把最终回复转成语音，不需要模型再判断一次。

## 后续执行前置条件

1. 用户确认是否按 Phase 1 到 Phase 4 改造。
2. 如果 `openclaw-chaine` 不是 `openclaw-china`，需要提供准确目录后再补一次源码证据。
3. 进入代码实现前必须先写对应测试，且修改后统一执行：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
cjpm clean
cjpm build -i
cjpm test
```
