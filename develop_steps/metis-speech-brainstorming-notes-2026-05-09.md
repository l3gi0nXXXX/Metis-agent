# Metis TTS/ASR 需求发散讨论记录

## 背景

本记录用于同步保存 TTS/ASR 需求发散过程中的用户决策、设计取舍和已认可设计段。后续实现计划必须以本记录和 `develop_steps/metis-speech-shared-tts-asr-plan-2026-05-09.md` 为输入，不得只依赖聊天上下文。

## 已确认决策

| 序号 | 议题 | 用户选择 | 结论 |
|---:|---|---|---|
| 1 | 第一轮覆盖范围 | 2 | Telegram + Feishu + QQ 都纳入第一轮设计和验收。 |
| 2 | Feishu/QQ 验收深度 | 3 | Telegram 做真实闭环；Feishu/QQ 第一轮先做 fake adapter 验证 + 能力矩阵。 |
| 3 | Provider 支持范围 | 2 | 第一轮支持 command provider + OpenAI-compatible HTTP provider。 |
| 4 | 触发方式 | 3，并补充“用户显式要求语音回复时，回复语音” | 入站语音自动 ASR；出站支持自动/按需 TTS；用户明确要求语音回复时必须语音回复。 |
| 5 | 自动 TTS 策略 | 2+3 | voice/audio 输入默认可语音回复，同时由会话级开关控制；文本输入只有明确要求或会话开启 TTS 时才语音回复。 |
| 6 | 会话级开关边界 | 1 | 会话级只控制行为开关，不覆盖 provider/voice。provider 和 voice 由通道配置优先于共享配置解析。 |
| 7 | ASR 失败策略 | 1 | ASR 失败时保留媒体元数据和明确失败原因，不猜内容；纯语音无 transcript 时可回复诊断。 |
| 8 | 总体方案方向 | B | 建立 Speech Gateway 能力层：配置解析、provider registry、TTS/ASR runtime、会话语音开关、自动 ASR、自动/按需 TTS、通道能力矩阵。 |

## 已认可设计段

### 设计 1：配置模型

用户已认可。

核心优先级：

```text
会话行为开关 > 通道 speech 配置 > 共享 speech 配置
```

解释：

- 会话行为开关只控制是否语音回复、是否自动回复 voice 输入、是否本轮强制语音。
- 会话状态不覆盖 provider、voice、apiKey、baseUrl。
- provider 永远由通道配置优先于共享配置决定。

建议配置形态：

```json
{
  "gateway": {
    "speech": {
      "tts": {
        "enabled": true,
        "provider": "edge",
        "maxChars": 4000,
        "providers": {
          "edge": {
            "kind": "command",
            "command": ["edge-tts", "--text", "{text}", "--write-media", "{output}"],
            "outputExtension": "mp3",
            "timeoutMs": 10000
          },
          "openai": {
            "kind": "openai-compatible",
            "baseUrl": "https://api.openai.com/v1",
            "apiKeyEnv": "OPENAI_API_KEY",
            "model": "gpt-4o-mini-tts",
            "voice": "alloy",
            "format": "mp3",
            "timeoutMs": 30000
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
          },
          "openai": {
            "kind": "openai-compatible",
            "baseUrl": "https://api.openai.com/v1",
            "apiKeyEnv": "OPENAI_API_KEY",
            "model": "whisper-1",
            "timeoutMs": 60000
          }
        }
      }
    },
    "telegram": {
      "speech": {
        "tts": {
          "provider": "telegram-openai"
        },
        "asr": {
          "provider": "telegram-local"
        },
        "autoReplyToVoice": true,
        "audioAsVoice": true
      }
    }
  }
}
```

关键规则：

- `gateway.speech.*` 是所有 IM 的共享默认。
- `gateway.telegram.speech.*`、`gateway.feishu.speech.*`、`gateway.qq.speech.*` 是通道 override。
- 通道 override 可以只覆盖 `provider`。
- provider 具体配置可以从共享 `providers` 继承，也可以在通道下声明自己的 `providers`。
- legacy `gateway.channelsExtra.telegramTts` 只作为 fallback，优先级最低，并输出迁移诊断。

### 设计 2：Runtime 和数据流

用户已认可。

建议建立 core 级 `GatewaySpeechRuntime`，不让 Telegram/Feishu/QQ adapter 直接执行 provider。

核心组件：

- `GatewaySpeechConfigResolver`
  - 输入 `GatewayUserSettings + channel + session state`。
  - 输出最终 TTS/ASR 配置。
  - 负责通道 override、共享 fallback、legacy fallback、开关解析。
- `GatewaySpeechProviderRegistry`
  - 注册 provider 类型。
  - 第一轮内置 `command` 和 `openai-compatible`。
  - `command` 支持本地命令 TTS/ASR。
  - `openai-compatible` 支持 HTTP TTS/ASR，测试用 mock HTTP。
- `GatewayTtsRuntime`
  - 输入 text、channel、sessionKey、delivery prefs。
  - 成功输出音频临时文件路径、mime、可选 duration、provider、`asVoice` 建议。
  - 失败输出 `not_configured`、`disabled`、`too_large`、`provider_error`、`timeout`。
- `GatewayAsrRuntime`
  - 输入 media record、channel、localPath、mime。
  - 成功输出 transcript、provider、model、source。
  - 失败输出结构化 status 和 reason，写入 media understanding decision，不猜内容。

数据流：

1. 入站 voice/audio 到达某个 channel。
2. Channel adapter 只负责下载/记录媒体，生成 media record，带上 `channel`、`accountId`、`localPath`、`mimeType`。
3. Gateway media understanding 调用 `GatewayAsrRuntime`。
4. ASR 成功时 transcript 进入用户消息上下文。
5. ASR 失败时媒体元数据和失败原因进入上下文。
6. Agent 生成文字回复。
7. Gateway 判断是否需要 TTS：
   - 用户明确要求语音回复：本轮强制 TTS。
   - 当前会话 TTS 开启：执行 TTS。
   - voice/audio 输入且 `autoReplyToVoice=true`：执行 TTS。
   - 其他情况默认文字。
8. TTS 成功时，通过通道 delivery contract 投递 `[voice]` 或 `[audio]`。
9. TTS 失败时回退文字并附可读诊断。

关键边界：

- ASR provider 不进入 Telegram/Feishu/QQ adapter。
- TTS provider 不进入 Telegram/Feishu/QQ adapter。
- adapter 只处理平台协议、上传下载、动作权限和错误映射。
- 所有 provider 执行结果都必须可测试、可脱敏、可回放。

### 设计 3：Telegram/Feishu/QQ 通道接入与能力矩阵

用户已认可。

第一轮采用分层验收：

- Telegram：真实闭环。
- Feishu：fake adapter 验证 + 能力矩阵。
- QQ：fake adapter 验证 + 能力矩阵。

Telegram 第一轮真实闭环：

- 入站 voice/audio 下载到 Telegram media archive。
- media record 带 `channel=telegram`、`accountId`、`localPath`、`mimeType`。
- 自动 ASR 成功后 transcript 进入上下文。
- `/tts status` 展示最终解析结果：会话开关、通道 provider、共享 fallback、legacy fallback 状态。
- `/tts on/off` 只修改当前 Telegram session 的行为开关。
- `/tts audio <text>` 显式生成语音。
- 用户说“用语音回复”时，本轮强制 TTS。
- voice/audio 输入且会话 TTS 开启或 `autoReplyToVoice=true` 时，回复可转语音。
- TTS 输出通过现有 `[voice]` / `[audio]` payload 进入 Telegram adapter。

Feishu 第一轮不强行实现真实语音上传/下载，先要求：

- `gateway.feishu.speech.tts/asr` 可解析，且优先于 `gateway.speech`。
- fake Feishu inbound audio record 可调用 `GatewayAsrRuntime`。
- fake Feishu outbound TTS result 可生成通用 `[audio]` 或 channel-neutral media payload。
- 能力矩阵记录真实 Feishu 当前是否已有：
  - 入站音频下载能力
  - 出站音频发送能力
  - action permission
  - media archive
  - smoke 测试条件

QQ 第一轮同 Feishu：

- `gateway.qq.speech.tts/asr` 可解析，且优先于 `gateway.speech`。
- fake QQ inbound audio record 可调用 `GatewayAsrRuntime`。
- fake QQ outbound TTS result 可生成通用 `[audio]` 或 channel-neutral media payload。
- 能力矩阵记录真实 QQ 当前是否已有：
  - 入站音频下载能力
  - 出站音频发送能力
  - action permission
  - media archive
  - smoke 测试条件

能力矩阵建议落盘为：

```text
develop_steps/metis-speech-im-capability-matrix-2026-05-09.md
```

字段：

| channel | inbound audio download | outbound audio send | outbound voice send | channel speech override | ASR runtime test | TTS runtime test | real smoke | gap | acceptance |
|---|---|---|---|---|---|---|---|---|---|

状态只允许：

- `ready`
- `partial`
- `missing`
- `not-applicable`

### 设计 4：错误处理、安全与隐私边界

用户已认可。

TTS/ASR 会处理用户语音、可能调用外部服务、可能执行本地 command、可能产生日志，因此第一轮必须明确失败和安全策略。

错误处理：

ASR 失败状态：

- `not_configured`：没有可用 provider。
- `disabled`：共享或通道 ASR 被关闭。
- `too_large`：音频超过 `maxBytes`。
- `unsupported`：不是 audio/voice 或缺少 localPath。
- `provider_error`：provider 返回错误或非 0 exit。
- `timeout`：provider 超时。
- `auth_error`：OpenAI-compatible provider 缺少 API key 或返回 401/403。

进入上下文的内容：

- 成功：transcript + provider/model/source。
- 失败：media metadata + `ASRStatus` + reason。
- 不允许猜测音频内容。
- 纯语音消息 ASR 失败时，可给用户一条诊断，例如“语音已收到，但当前 ASR 未配置/失败”。

TTS 失败：

- 默认回退文字回复。
- 如果用户明确要求“只要语音”，也仍应给出失败诊断，而不是静默。
- 失败诊断不能暴露 token、Authorization header、完整 command env。

安全：

command provider：

- 必须是数组 argv。
- 禁止 shell string。
- 必须 `withWrap: false`。
- placeholder 只允许白名单：
  - TTS `{text}`、`{output}`、`{outputDir}`
  - ASR `{input}`、`{mime}`、`{output}`、`{outputDir}`
- 输出路径只能在临时目录、测试 fixture 目录或用户显式配置 allowlist 目录。
- 自动化测试只能使用临时 HOME/METIS_HOME。

OpenAI-compatible provider：

- API key 只能来自 `apiKeyEnv` 或安全配置字段。
- 日志和错误输出必须脱敏 Authorization、apiKey、token。
- 单元测试必须 mock HTTP，不允许真实网络。
- ASR 上传文件要遵守 `maxBytes`。
- TTS 输出必须写入受控临时文件。

隐私：

- 默认不把语音原始文件复制到 workspace。
- media archive 仍按 channel/account/session 隔离。
- transcript 可以进入会话上下文，因为这是 ASR 的目的；但原始音频路径不要暴露给模型，除非工具明确需要。
- 日志只记录 provider id、status、耗时、大小，不记录完整 transcript，最多记录短摘要或长度。
- 手动 smoke 可以用真实 Telegram，但自动测试不得用真实 Telegram/Feishu/QQ。

## 待继续讨论

### 设计 5：测试体系和验收设计

用户已认可。

第一轮测试覆盖四层：配置解析、provider runtime、通道集成、手动 smoke。

配置解析测试：

- `gateway.telegram.speech.tts` 优先于 `gateway.speech.tts`。
- `gateway.feishu.speech.asr` 优先于 `gateway.speech.asr`。
- `gateway.qq.speech.tts` 优先于 `gateway.speech.tts`。
- 通道只覆盖 provider 时，provider config 可从共享 `providers` 继承。
- legacy `gateway.channelsExtra.telegramTts` 只在新配置缺失时生效。
- 会话状态只影响 `ttsEnabled/autoReplyToVoice/forceVoiceReplyOnce`，不影响 provider。

Provider runtime 测试：

command TTS：

- argv 无 shell wrap。
- `{text}` / `{output}` 正确替换。
- 成功写出音频文件。
- 非 0 exit、timeout、无输出文件都返回结构化错误。
- 输出路径必须在受控目录。

command ASR：

- `{input}` / `{mime}` / `{output}` 正确替换。
- stdout transcript 和 output-file transcript 都可用。
- too large 在 provider 执行前拦截。
- 非音频输入返回 unsupported。

OpenAI-compatible TTS/ASR：

- 使用 mock HTTP。
- 校验 Authorization 脱敏。
- TTS 成功响应写入临时音频文件。
- ASR multipart 请求包含音频文件和 model。
- 401/403 转成 `auth_error`。
- 5xx 转成 `provider_error`。
- timeout 转成 `timeout`。

通道集成测试：

Telegram：

- fake update voice/audio -> media record -> ASR -> transcript 入上下文。
- `/tts status` 展示通道 provider、共享 fallback、会话开关。
- `/tts on/off` 只改 session state。
- “用语音回复”触发本轮 TTS。
- voice 输入 + autoReplyToVoice 或 session TTS on 触发 TTS。
- TTS result 走 `[voice]` / `[audio]`，adapter 仍只负责 `sendVoice` / `sendAudio`。

Feishu/QQ：

- fake inbound audio record 使用各自 channel override。
- fake outbound TTS 验证生成 channel-neutral media payload。
- 能力矩阵必须记录真实通道缺口，不允许声称真实闭环已完成。

手动 smoke：

Telegram 必测：

- `/tts status`
- `/tts on`
- 发送 voice note，确认自动 ASR
- voice note 后确认语音回复
- 文本消息“请用语音回复...”确认本轮 TTS
- `/tts off`
- ASR/TTS provider 关闭时确认诊断清晰

Feishu/QQ 第一轮：

- 不要求真实平台 smoke 通过。
- 只要求能力矩阵准确，并列出后续手动 smoke 条件。

统一验收命令：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
export DYLD_LIBRARY_PATH="/Users/l3gi0n/cangjie100/runtime/lib/darwin_aarch64_llvm:/Users/l3gi0n/cangjie100/tools/lib:/Users/l3gi0n/work/workspace_cangjie/CangjieMagic/libs/cangjie-stdx-mac-aarch64-1.0.0.1/darwin_aarch64_llvm/dynamic/stdx:/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH"
cjpm clean
cjpm build -i
cjpm test
```

## 待继续讨论

- 正式设计规格文档自检和用户审阅。
