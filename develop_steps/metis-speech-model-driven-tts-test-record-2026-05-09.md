# Metis Speech Model-Driven TTS Test Record

## 范围

本记录覆盖 2026-05-09 模型驱动 TTS 改造的自动测试与手动验收项。目标是让 Telegram 普通文本请求语音时由模型调用 `tts` 工具发送 voice/audio，而不是由 Gateway 硬编码自然语言关键词触发 TTS；同时保留 voice/audio 输入场景下的自动语音回复策略。

## 已完成自动测试

| 测试项 | 覆盖内容 | 结果 |
|---|---|---|
| `GatewayTtsToolset` fake/command provider 测试 | 使用临时 `METIS_HOME`，验证 Telegram 私有 TTS provider 优先于共享 provider，成功返回 `[voice]` payload 和 `audioPath` | 已通过 |
| `GatewayTtsToolset` 未配置 provider 测试 | 无 provider 时返回 `ok=false,status=not_configured,action=tts`，不误报成功 | 已通过 |
| `GatewayTtsToolset` `asVoice=false` 测试 | 验证工具可返回 `[audio]` payload | 已通过 |
| `GatewayTtsToolset` 当前 runtime context 投递测试 | fake `channels.send` runner 验证工具在 Telegram 当前会话中发送 payload，并标记 visible reply delivered | 已通过 |
| Telegram system prompt 测试 | 验证 prompt 要求模型显式调用 `tts` 工具、成功后 silent reply，并禁止 shell/host TTS 绕过 Gateway | 已通过 |
| Gateway session turn TTS 工具投递测试 | fake model 调用 `tts` 后返回 silent reply，验证不会追加第二条普通文本 | 已通过 |
| Gateway message tool 文本语音请求测试 | 普通文本“发一条语音信息给我...”不再被 `message` tool 关键字路径自动改写为 `[voice]` | 已通过 |
| Telegram native service 文本语音请求测试 | 普通文本语音请求不再由 Gateway service 关键字路径直接 TTS；应由模型工具路径处理 | 已通过 |

已执行聚焦验证：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
cjpm test
```

结果：`TOTAL: 1045 PASSED: 1045, SKIPPED: 0, ERROR: 0, FAILED: 0`。

## 全量验证

执行命令：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
cjpm clean && cjpm build -i && cjpm test
```

结果记录：

- `cjpm clean` 成功。
- `cjpm build -i` 成功。
- 首次 `cjpm test` 中 `metis.core.tools` 和 `metis.program` 被测试运行器报 `exit code = 9`，其余 1032 个测试通过；未出现断言失败。
- 隔离复现 `cjpm test src/core/tools --no-progress` 通过：`5 PASSED`。
- 隔离复现 `cjpm test src/program --no-progress` 通过：`8 PASSED`。
- 复跑全量 `cjpm test --no-progress` 通过：`TOTAL: 1045 PASSED: 1045, SKIPPED: 0, ERROR: 0, FAILED: 0`。

验收结论：

- 新增 TTS/ASR/Gateway 测试全部通过。
- 新增测试不读写真实 `~/.metis/metis.json`。
- 新增测试不调用真实 Telegram 网络。
- 日志不输出 bot token、proxy password、Authorization header。

## 手动 Telegram 验收

| 编号 | 操作 | 预期结果 | 当前状态 |
|---|---|---|---|
| TG-TTS-MANUAL-01 | 配置 TTS provider 后执行 `/tts audio 你好，这是 Metis 的语音回复测试` | Telegram 收到 voice/audio | 用户已测 OK |
| TG-TTS-MANUAL-02 | 配置 `audioAsVoice=true`、`autoReplyToVoice=true` 后发送 Telegram voice | ASR 成功后，本轮可见回复使用 voice/audio 投递 | 用户已测到语音回复，需在最新代码后复测 |
| TG-TTS-MANUAL-03 | 发送文本“发一条语音信息给我，随便说点什么。” | 模型调用 `tts` 工具，Telegram 收到且只收到一条 voice/audio；不应出现“无法直接发送语音”的拒绝文本 | 待手动复测 |
| TG-TTS-MANUAL-04 | 关闭或移除 TTS provider 后重复 TG-TTS-MANUAL-03 | 返回明确 TTS 未配置/不可用说明，不误报成功 | 待手动复测 |
| TG-TTS-MANUAL-05 | 发送 Telegram voice，诱导模型返回多段文字 | 在 `audioAsVoice=true`、`autoReplyToVoice=true` 下所有可见回复直接转成 voice/audio，不额外发普通文本 | 待手动复测 |

## 架构校验记录

- TTS provider 配置解析和合成仍在 `src/core/gateway_speech_runtime.cj`。
- 模型可调用能力新增在 `src/gateway/tools/gateway_tts_toolset.cj`。
- Telegram 发送仍复用 `[voice]` / `[audio]` payload 和现有 channel delivery，不在 agent core 中拼 Bot API。
- 普通文本请求语音不再依赖 `telegramTextExplicitlyRequestsVoiceReply` 类自然语言关键词判断。
- voice/audio 输入自动语音回复仍由 runtime context 的媒体类型和 Telegram speech 配置决定。
