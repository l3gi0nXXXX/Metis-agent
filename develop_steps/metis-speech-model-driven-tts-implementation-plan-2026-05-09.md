# Metis Speech Model-Driven TTS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Metis 的“用户要求语音回复”从 Gateway 硬编码关键字判断，升级为 OpenClaw 式模型可调用 TTS 工具，同时保留 voice 输入自动语音回复策略。

**Architecture:** TTS 能力分为三层：共享 speech runtime 负责配置解析与合成；Gateway toolset 暴露模型可调用 `tts` 工具；IM channel adapter 只负责发送 `[voice]` / `[audio]` payload。Telegram 私有 speech 配置优先于共享配置，未来其他 IM 通道复用同一 speech runtime。

**Tech Stack:** Cangjie, magic.dsl toolset, Metis Gateway, Telegram adapter, cjpm test.

---

## 0. 参考证据

计划依据已落盘在：

- `develop_steps/metis-speech-model-driven-tts-plan-2026-05-09.md`

关键参考：

- OpenClaw `openclaw/src/agents/openclaw-tools.ts:219-238`：注册 `createTtsTool` 到 agent tools。
- OpenClaw `openclaw/src/agents/tools/tts-tool.ts:17-49`：`tts` tool 调用 `textToSpeech` 并返回 `details.media.mediaUrl/audioAsVoice`。
- OpenClaw `openclaw/src/agents/tools/tts-tool.test.ts:20-43`：测试结构化媒体输出。
- OpenClaw `openclaw/extensions/telegram/src/bot/delivery.replies.ts:342-446`：Telegram 按 `audioAsVoice` 选择 `sendVoice/sendAudio`。
- openclaw-china `extensions/feishu/src/bot.ts:361-447`、`extensions/dingtalk/src/bot-handler.ts:1381-1459`：IM 通道使用 `mediaUrl/mediaUrls` delivery 抽象发送媒体。

## 1. 当前 Metis 状态

已有能力：

- `src/core/gateway_speech_runtime.cj` 已提供 TTS/ASR 配置解析和 command/openai-compatible provider 调用能力。
- `src/gateway/core/gateway_telegram_native_tool_commands.cj` 已支持 `/tts audio <text>`。
- `src/gateway/channels/telegram/telegram_adapter.cj` 已支持 `[voice]` / `[audio]` payload 到 `sendVoice/sendAudio`。
- `src/gateway/tools/gateway_message_toolset.cj` 的 `message` tool 已支持 `action=voice` / `action=audio`。

当前问题：

- `src/gateway/core/gateway_service.cj` 和 `src/gateway/tools/gateway_message_toolset.cj` 中存在 `telegramTextExplicitlyRequestsVoiceReply` 类硬编码关键字判断。
- `buildGatewaySystemPrompt` 当前提示模型“写最终文本，由 Gateway 合成语音”，而不是提示模型调用 `tts` tool。
- 缺少模型可直接调用的 `GatewayTtsToolset`。

## 2. 分阶段计划

### Phase 1：新增模型可调用 TTS Toolset

目标：让模型可以显式调用 `tts` 工具，把文本转成受控音频 payload。

**Files:**

- Create: `src/gateway/tools/gateway_tts_toolset.cj`
- Modify: `src/gateway/core/agent_bridge.cj`
- Test: `src/gateway/tools/gateway_tts_toolset_test.cj`

**Implementation steps:**

- [x] Step 1: 新增失败测试：`GatewayTtsToolset.debugTtsForTest` 在 fake/command provider 配置下返回 `ok=true`、`payloadKind=voice`、`payloadPreview` 包含 `[voice]`。

验收项：

- 测试不读取真实 `~/.metis/metis.json`。
- 测试音频输出目录必须是临时目录。
- 测试能证明 Telegram 私有配置优先于共享配置。

- [x] Step 2: 新增 `GatewayTtsToolset`，暴露 `@tool public func tts(text, channel, asVoice)`。

验收项：

- 参数包含 `text: String`、`channel: Option<String>`、`asVoice: Option<Bool>`。
- 空文本返回结构化错误：`ok=false,status=error,error=tts requires text`。
- 未配置 provider 返回结构化错误：`ok=false,status=not_configured`。
- 成功结果包含：`ok`、`status`、`action=tts`、`channel`、`provider`、`audioPath`、`payloadKind`、`payload`、`payloadPreview`。

- [x] Step 3: 在 `GatewayP1ChatAgent` tools 中注册 `GatewayTtsToolset()`。

验收项：

- `MetisSystemPromptBuilder.collectToolNames(agent.toolManager.tools)` 能收集到 `tts`。
- 不影响现有 `message`、`telegram_media`、`subagents` 等工具。

- [x] Step 4: 运行聚焦测试。

命令：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
cjpm test -m metis.gateway.tools
```

验收项：

- 新增 `GatewayTtsToolset` 相关测试通过。
- 没有真实 Telegram 网络调用。

### Phase 2：调整模型提示，改为调用 TTS Tool

目标：让模型知道“要发语音时调用 `tts` tool”，而不是输出普通文本等待 Gateway 猜测。

**Files:**

- Modify: `src/gateway/core/agent_bridge.cj`
- Test: `src/gateway/core/gateway_session_turn_runner_test.cj` 或现有 system prompt 测试文件

**Implementation steps:**

- [x] Step 1: 写失败测试：Telegram system prompt 必须包含 `tts` tool guidance、silent reply 约束、禁止 shell/host TTS 命令。

验收项：

- prompt 包含“需要语音回复时调用 `tts` 工具”语义。
- prompt 包含“成功发送可见语音后回复 `<silent_reply>` 或 silent reply token”语义。
- prompt 不再表达“只要写最终文本，Gateway 会根据硬编码自然语言判断自动合成”。

- [x] Step 2: 修改 `buildGatewaySystemPrompt` 的 Telegram TTS hint。

验收项：

- Telegram 通道注入 TTS tool guidance。
- 非 Telegram 通道不注入 Telegram 专属 sendVoice 细节。
- 保留“不使用 shellExecute、curl、本机 TTS 脚本绕过 Gateway”的约束。

- [x] Step 3: 运行聚焦测试。

命令：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
cjpm test -m metis.gateway.core
```

验收项：

- system prompt 测试通过。
- 现有 Gateway session turn 测试通过。

### Phase 3：打通 TTS Tool 结果到 Telegram 可见发送

目标：模型调用 `tts` 后，用户实际收到 Telegram voice/audio；不会同时收到重复文本。

**Files:**

- Modify: `src/gateway/tools/gateway_tts_toolset.cj`
- Modify: `src/gateway/core/gateway_session_turn_runner.cj` 或当前 tool runtime visible reply 追踪位置
- Test: `src/gateway/core/gateway_session_turn_runner_test.cj`
- Test: `src/gateway/channels/telegram/telegram_adapter_test.cj`

**Implementation steps:**

- [x] Step 1: 写失败测试：fake model 调用 `tts` 成功后，Gateway 标记 visible reply 已发送。

验收项：

- 工具成功后调用 `gatewayMarkCurrentToolRuntimeVisibleReplyDelivered()` 或等价机制。
- 最终 `<silent_reply>` 不会产生第二条文本。

- [x] Step 2: 写失败测试：TTS tool 成功返回 `[voice]` payload，通过现有 `channels.send` / Telegram adapter 走 `sendVoice`。

验收项：

- Fake Telegram transport 看到 `/sendVoice` 调用。
- 如果 `asVoice=false` 或配置 `audioAsVoice=false`，走 `/sendAudio`。
- Payload 不暴露 provider token、Authorization header、proxy 密码。

- [x] Step 3: 实现 TTS tool 的发送模式。

验收项：

- 推荐默认模式：工具生成 payload 后发往当前 Gateway runtime context 的 channel/peer。
- 若缺少当前 channel/peer，工具只返回 payload，不尝试发送，并给出清晰 `delivery=skipped_missing_context`。
- 成功发送后结果中包含 `delivered=true`。

- [x] Step 4: 运行聚焦测试。

命令：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
cjpm test -m metis.gateway.core
cjpm test -m metis.gateway.channels.telegram
```

验收项：

- 模型工具调用路径、silent reply、Telegram sendVoice/sendAudio 均通过测试。
- 不进行真实 Telegram 网络调用。

### Phase 4：收敛硬编码文本意图判断

目标：移除“发/说/voice/audio”等关键字驱动的文本转语音主路径，只保留 voice 输入自动回复策略。

**Files:**

- Modify: `src/gateway/core/gateway_service.cj`
- Modify: `src/gateway/tools/gateway_message_toolset.cj`
- Test: `src/gateway/core/gateway_service_telegram_native_test.cj`
- Test: `src/gateway/tools/gateway_message_toolset_test.cj`

**Implementation steps:**

- [x] Step 1: 写失败测试：文本“发一条语音信息给我，随便说点什么。”不会被 Gateway 关键字函数自动改写成 `[voice]`。

验收项：

- 未调用 `tts` tool 时，普通 text payload 仍是 text。
- 不再依赖 `telegramTextExplicitlyRequestsVoiceReply`。

- [x] Step 2: 写失败测试：入站 `[voice]` / `[audio]` 且 `autoReplyToVoice=true`、`audioAsVoice=true` 时，最终回复仍自动转 `[voice]`。

验收项：

- voice 输入自动语音回复不受 Phase 4 删除影响。
- 模型误回 silent 时，按既定策略直接语音 fallback，不额外发文字。

- [x] Step 3: 删除或降级 `telegramTextExplicitlyRequestsVoiceReply` 主路径。

验收项：

- `gateway_service.cj` 不再用自然语言关键字决定普通文本是否要 TTS。
- `gateway_message_toolset.cj` 不再用自然语言关键字决定普通文本是否要 TTS。
- 只保留 media kind / runtime context 判断：voice/audio 输入、明确配置策略、模型 tool 调用。

- [x] Step 4: 运行聚焦测试。

命令：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
cjpm test -m metis.gateway.core
cjpm test -m metis.gateway.tools
```

验收项：

- 新旧 Telegram TTS 相关测试全部通过。
- 不出现重复文字 + 语音双回复。

### Phase 5：文档与手动测试清单更新

目标：让用户知道如何配置、如何触发、如何验证模型驱动 TTS。

**Files:**

- Modify: `docs/user/telegram.md`
- Modify: `develop_steps/metis-telegram-smoke-test-checklist-2026-05-08.md`
- Modify or Create: `develop_steps/metis-speech-model-driven-tts-test-record-2026-05-09.md`

**Implementation steps:**

- [x] Step 1: 更新 Telegram 用户文档。

验收项：

- 文档包含共享配置 `gateway.speech.tts`。
- 文档包含 Telegram 私有配置 `gateway.telegram.speech.tts`。
- 文档说明私有配置优先于共享配置。
- 文档说明 `/tts audio` 是测试命令，模型正常对话中应调用 `tts` 工具。

- [x] Step 2: 更新 smoke checklist。

验收项：

- 增加文本触发模型 TTS：发送“发一条语音信息给我，随便说点什么。”，期望收到一条 voice/audio。
- 增加 voice 输入自动语音回复：发送 Telegram voice，期望收到 voice/audio。
- 增加失败诊断：关闭 TTS provider，期望收到未配置说明，不误报成功。

- [x] Step 3: 新建测试记录文档。

验收项：

- 记录自动测试命令和结果。
- 记录需要用户手动验证的 Telegram bot 场景。
- 记录真实配置不应写入文档。

### Phase 6：全量验证

目标：确认修改完整、安全、没有破坏现有 Gateway 架构。

**Commands:**

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
cjpm clean
cjpm build -i
cjpm test
```

验收项：

- `cjpm clean` 成功。
- `cjpm build -i` 成功。
- `cjpm test` 全部通过。
- 所有新增测试不读写真实 `~/.metis/metis.json`。
- 所有新增测试不调用真实 Telegram 网络。
- 日志不输出 bot token、proxy password、Authorization header。

## 3. 手动验收项

需要用户在真实 Telegram bot 上验证：

1. `/tts audio 你好，这是 Metis 的语音回复测试`
   - 期望：收到一条 voice/audio。
2. 发送 Telegram 语音消息。
   - 配置 `audioAsVoice=true`、`autoReplyToVoice=true` 时，期望：收到一条 voice/audio。
3. 发送文本：`发一条语音信息给我，随便说点什么。`
   - 期望：模型调用 TTS 工具，Telegram 收到一条 voice/audio。
   - 不应收到“我无法发送语音”的拒绝文本。
   - 不应同时收到普通文本和 silent fallback 语音。
4. 关闭 TTS provider 后重复第 3 条。
   - 期望：收到清晰的 TTS 未配置/不可用说明。
   - 不应伪造语音发送成功。

## 4. 架构边界

- TTS provider 与配置解析归 `core/gateway_speech_runtime`。
- 模型工具归 `gateway/tools`。
- Telegram 发送归 `gateway/channels/telegram`。
- 不把 Telegram provider、proxy、Bot API 细节写入 agent core。
- 不用 `shellExecute`、`curl` 或临时脚本绕过 Gateway 发送语音。
- 不突破现有 Gateway channel/session/tool runtime 边界。

## 5. 执行顺序

推荐严格按 Phase 1 到 Phase 6 执行。每个 Phase 结束后先跑对应聚焦测试，再进入下一阶段。Phase 4 删除硬编码判断必须等 Phase 1 到 Phase 3 的模型工具路径通过后再做，否则会造成用户可见能力回退。

## 6. 执行记录

- Phase 1 到 Phase 5 已完成，详见 `develop_steps/metis-speech-model-driven-tts-test-record-2026-05-09.md`。
- `cjpm clean` 成功。
- `cjpm build -i` 成功。
- 首次 `cjpm test` 出现两个测试包运行器 `exit code = 9`，无断言失败；隔离运行 `src/core/tools` 和 `src/program` 均通过。
- 复跑全量 `cjpm test --no-progress` 通过：`TOTAL: 1045 PASSED: 1045, SKIPPED: 0, ERROR: 0, FAILED: 0`。
