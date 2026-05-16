# Metis Agent Team Series 22：Phase 0-9 执行记录与 Phase 8 平台边界确认

日期：2026-05-16

执行 worker：AgentTeam series21 并行实现 worker E

工作区：`/Users/l3gi0n/work/workspace_cangjie/Metis/.worktrees/agentteam-s21-docs-gate-20260516`

分支：`work/agentteam-s21-docs-gate-20260516`

## 1. 本文范围

本文承接 `develop_steps/metis-agent-team-series-21-post-phase20-source-backed-gap-quantification-manual-acceptance-2026-05-16.md`，只记录本轮 phase0-9 的并行执行边界、预期验证命令、外部资源缺口，以及 Phase 8 “自动创建 Feishu app/bot”平台能力边界。

本文不修改 Cangjie runtime、Control UI、Telegram、Feishu channel、manual gate 脚本。其他 worker 对 Feishu native commands、Control UI、manual gate、CardKit/rich events 的实际完成状态，以各自 worktree 的 diff、commit、验证输出为准。

本文使用的证据范围：

- series21 主基线文档：`develop_steps/metis-agent-team-series-21-post-phase20-source-backed-gap-quantification-manual-acceptance-2026-05-16.md`。
- series20 已验收记录：`develop_steps/metis-agent-team-series-20-phase0-9-implementation-and-verification-2026-05-16.md`。
- Metis 用户文档和 UI 边界：`docs/user/agent-team.md`、`ui/src/ui/views/agents-panel-teams.ts`。
- manual acceptance gate：`scripts/agentteam-manual-acceptance-gate.sh`。
- openclaw-lark 源码事实：`src/core/app-scope-checker.ts`、`src/core/auth-errors.ts`、`src/core/tool-scopes.ts`、`src/channel/onboarding.ts`。
- 飞书官方公开文章：`https://www.feishu.cn/content/article/7613711414611463386`。
- 飞书开放平台公开入口和自建应用流程页面：`https://open.feishu.cn/app`、`https://open.feishu.cn/document/uQjL04CN/ukzM04SOzQjL5MDN`、`https://open.feishu.cn/document/best-practices/intro-to-custom-app-review`。

## 2. 本轮 worker 边界

| Worker | 本轮范围 | 写入边界 | 本文记录的验证入口 |
| --- | --- | --- | --- |
| Worker A | Feishu native commands：`/feishu start`、`/feishu doctor`、`/feishu auth` 的输出、诊断、脱敏和 OpenClaw 体验对齐 | Feishu channel/native command 相关源码和测试 | Feishu channel 单测、Gateway native auth 单测、缺凭据/缺 scope/脱敏场景 |
| Worker B | Control UI：Agent Teams 页面、Feishu setup/repair wizard、状态看板、浏览器运行时验收 | `ui/`、`assets/control-ui/`、Gateway Control UI 静态服务相关文件 | `npm --prefix ui run build`、UI 单测、真实浏览器 smoke |
| Worker C | manual gate：phase0-9 证据包、external-resource-required 分类、operator record 入口 | `scripts/agentteam-manual-acceptance-gate.sh` 和对应测试 | `bash -n`、脚本测试、`node --test`、临时 `METIS_HOME` gate |
| Worker D | CardKit/rich events：Feishu card create/patch/final/fallback、media/resource/reaction/quote/merged-forward 事件路径 | Feishu channel/CardKit/resource 相关源码和测试 | Feishu adapter/CardKit 单测、no-network 默认路径、live opt-in gate |
| Worker E | Phase 8 平台边界确认文档、phase0-9 执行记录文档、外部资源准备清单 | `develop_steps/` 新增 series22 文档 | 文档自检、禁用词扫描、git diff、git commit |

协作边界：

- Worker E 不读取真实 Feishu 控制台，不使用真实 token/cookie，不把外部 live 缺口写成代码缺口。
- Worker E 不改其他 worker 写入范围。
- Worker E 不声称其他 worker 的代码变更已完成；本文只定义本轮并行工作如何验收和交接。

## 3. Phase 0-9 执行记录

| Phase | 本轮目标 | 主要负责 | 本地可验证项 | 外部资源缺口 |
| --- | --- | --- | --- | --- |
| Phase 0 | 冻结 source-backed GAP 主矩阵，并让 manual gate 映射 G01-G25 | Worker C、Worker E | `scripts/agentteam-manual-acceptance-gate.sh` 能生成 phase/gap/checklist/evidence 分类；文档能指出基线来源 | 无真实外部资源要求 |
| Phase 1 | Feishu native command 输出对齐 | Worker A | 未配置、已配置、缺 scope、OAuth pending/authorized/revoked、脱敏输出的单测 | 真实飞书会话里发送 `/feishu start`、`/feishu doctor`、`/feishu auth` 的截图或脱敏日志 |
| Phase 2 | Control UI Agent Teams 产品化和 Feishu setup/repair 可见化 | Worker B | UI build、controller/view/browser smoke 单测；构建产物无原始 TypeScript decorator | 真正打开 Gateway Control UI 后确认页面可见、`metis-app` 已注册、无 JS error/asset 404 |
| Phase 3 | Telegram route/broadcast live 验收入口 | Worker C 记录 gate，live operator 执行 | fake inbound、route resolver、broadcast aggregate 的本地测试 | 测试 Telegram bot、私聊、群、topic、脱敏日志 |
| Phase 4 | Feishu 多账号/accountId/group/thread route live 验收入口 | Worker A、Worker C 记录 gate，live operator 执行 | accountId merge、route resolver、requireMention/groupPolicy/threadSession 相关 fake 测试 | 两个测试 Feishu app/bot/accountId、测试群、话题群、测试用户 |
| Phase 5 | Feishu OAuth/UAT/TAT/OAPI live 验收入口 | Worker A、Worker C 记录 gate，live operator 执行 | device flow、token store、scope diagnostic、OAPI token mode 单测 | 测试 appId/appSecret、`offline_access`、低风险 OAPI scopes、测试用户授权 |
| Phase 6 | Feishu CardKit streaming live 闭环入口 | Worker D | card JSON、fallback 分类、no-network checklist、脱敏测试 | CardKit 权限、测试群、真实 create/patch/final/abort 操作记录 |
| Phase 7 | Feishu rich events/resource live 闭环入口 | Worker D | image/file/audio/video/reaction/quote/merged-forward fixture 和 resource context 测试 | 真实图片、文件、音频、视频、reaction、引用、合并转发事件 |
| Phase 8 | 自动创建 Feishu app/bot 平台能力确认 | Worker E | 本文给出平台边界、证据、禁止承诺项、资源清单 | 飞书开放平台 API、租户开发者权限、管理员授权、审核流程的真实验证记录 |
| Phase 9 | 发布前完整回归和证据包 | 所有 worker，Worker C 汇总 gate | Cangjie build/test、UI build/browser smoke、manual gate evidence pack | Telegram/Feishu live evidence pack 和 operator record |

## 4. Phase 8 平台边界结论

当前 Metis 能力边界：

- 支持 guided setup。
- 支持关联已有 Feishu app/bot。
- 支持读取 Gateway status、OAuth 状态、OAPI 诊断、CardKit readiness、redacted repair steps。
- 支持通过 CLI/UI/Gateway RPC 创建和绑定 Agent Team。
- 不承诺自动创建 Feishu 开放平台 app。
- 不承诺自动启用 Feishu bot 能力。
- 不承诺自动配置事件订阅、回调、长连接、权限导入、版本发布、审核通过。

平台边界结论：

在没有取得飞书开放平台公开 API、租户开发者权限、管理员授权、审核流程的真实验证记录前，Metis 对用户展示的产品文案只能写为“关联已有机器人”和“配置向导”。任何“自动创建 Feishu app/bot”的承诺都需要先完成平台验证，再进入实现。

## 5. Phase 8 证据和解释

### 5.1 飞书官方 OpenClaw 安装体验

飞书官方文章说明 OpenClaw 飞书官方插件安装时提供“新建机器人”或“关联已有机器人”；选择新建时，通过飞书客户端扫码并选择“一键创建飞书机器人”；创建后在飞书对话中发送消息开始对话，并通过 `/feishu auth` 完成授权、通过 `/feishu start` 验证安装。

这个证据说明飞书官方 OpenClaw 插件提供官方安装器体验，但它不等同于 Metis 本地代码已具备公开 API 级的 app/bot 创建能力。该体验的可复用边界取决于飞书开放平台是否向 Metis 可用租户开放等价 API、扫码授权流程、安装器能力、应用创建权限、发布审核能力。

### 5.2 飞书开放平台自建应用流程

飞书开放平台公开入口是 `https://open.feishu.cn/app`。自建应用创建文档和发布审核文档分别位于：

- `https://open.feishu.cn/document/uQjL04CN/ukzM04SOzQjL5MDN`
- `https://open.feishu.cn/document/best-practices/intro-to-custom-app-review`

这些页面属于开发者后台和发布审核流程证据。对 Metis 而言，用户或管理员需要在飞书开放平台完成应用创建、机器人能力、事件订阅、权限开通、版本发布和审核。Metis 可提供步骤、检测、回填和诊断；没有 live 验证记录时，Metis 不把这些后台动作写成本地自动化能力。

### 5.3 openclaw-lark 源码事实

`openclaw-lark/src/core/app-scope-checker.ts` 使用 `GET /open-apis/application/v6/applications/:app_id` 查询应用信息和 scopes，并注明该查询需要 `application:application:self_manage` 权限。

`openclaw-lark/src/core/auth-errors.ts` 把缺少 `application:application:self_manage` 的场景描述为“无法查询应用权限配置”，需要管理员在开放平台开通该权限。

`openclaw-lark/src/core/tool-scopes.ts` 把 `application:application:self_manage` 描述为“查询应用自身权限状态（诊断基础）”。

以上源码能证明该权限支撑应用自身权限查询和诊断，不能证明该权限足以创建另一个飞书应用、创建机器人、配置事件订阅、导入权限、发布版本或通过审核。

`openclaw-lark/src/channel/onboarding.ts` 的安装/配置流程会获取 appId/appSecret、测试连接、选择 Feishu/Lark domain、设置 groupPolicy 和 sender allowlist。该流程说明 openclaw-lark 运行态依赖已取得的应用凭据和租户配置。

### 5.4 Metis 当前边界证据

`docs/user/agent-team.md` 明确写明：Metis 不自动创建 Feishu app 或 bot；operator 需要先在飞书开发者后台创建或选择 app、启用 bot 和事件订阅、把应用凭据配置到 Gateway-backed Metis config，再由 Metis 提供 setup guidance、status checks、OAuth helpers、route binding 和 redacted diagnostics。

`ui/src/ui/views/agents-panel-teams.ts` 明确展示：Control UI 不能自动创建 Feishu app 或 bot；只支持 guided setup 和 linking an existing bot；Control UI 不存储 app secrets 或 token files。

`scripts/agentteam-manual-acceptance-gate.sh` 把 G21 “automatic Feishu bot/app creation platform boundary” 标为 `external-resource-required`，并在 live Feishu gate 中要求 operator 记录 app/account/tenant/scopes、pass/fail 和 log redaction 结果。

## 6. 不由本地代码证明的能力

| 能力 | 本地代码能证明的内容 | 本地代码不能证明的内容 | 需要的验收证据 |
| --- | --- | --- | --- |
| 创建 Feishu app | Metis 可保存和诊断已有 appId/appSecret | 飞书租户允许 Metis 通过 API 创建新 app | 飞书开放平台 API 文档、租户授权记录、一次测试租户 live 创建记录 |
| 创建或启用 Feishu bot | Metis 可关联已有 bot 并检查 channel/account 状态 | bot 能力由 Metis 自动启用并安装到租户 | 开发者后台变更记录、bot 可见性和测试消息记录 |
| 配置事件订阅和回调 | Metis 可提示事件和回调缺口 | Metis 自动写入飞书后台事件订阅、长连接、回调 URL | 飞书后台配置前后记录、事件投递到 Gateway 的脱敏日志 |
| 开通 scopes | Metis 可检查缺失 scope 并输出 repair hint | Metis 自动让租户管理员批准所有 scopes | 权限审批记录、缺 scope 到已授权的前后诊断 |
| 发布和审核应用版本 | Metis 可提示需要发布版本 | Metis 自动发布并通过飞书审核 | 版本发布记录、审核通过记录、测试租户安装记录 |
| OAuth 用户授权 | Metis 可启动 device flow、poll、status、revoke | 用户已完成授权且授权 scopes 覆盖所有 OAPI | 测试用户授权完成记录、token 输出脱敏检查 |
| Feishu OAPI read/write | Metis 可在 fake/no-network 测试中验证请求构造和诊断 | 真实 doc/wiki/calendar/task/bitable/sheet/im 操作成功 | 每个 tool family 的测试资源、低风险 read/write 记录 |
| CardKit streaming | Metis 可构造 card/fallback/checklist | 真实 card create、stream patch、final update、abort 成功 | CardKit 测试群记录、cardId、patch/final 脱敏日志 |
| Rich events/resource | Metis 可解析 fixture 和构造 resource context | 真实图片、文件、音频、视频、reaction、引用、合并转发事件完整投递 | 真实事件 payload 的脱敏记录、resource fetch 结果 |
| Telegram delivery | Metis 可验证 route/broadcast/fake inbound | Telegram 真实私聊、群、topic 收发成功 | 测试 bot、chat/topic id、脱敏 Gateway inbound/outbound 日志 |
| Control UI runtime | build 和单测可检查静态产物 | 用户浏览器真实打开 Gateway 页面并完成操作 | 浏览器 smoke：无 blank、无 JS error、无 asset 404、`metis-app` 注册 |

## 7. Feishu live 验收资源准备清单

### 7.1 租户和账号

- 使用测试租户或经过授权的低风险租户。
- 准备一个具备开发者后台权限的操作账号。
- 准备一个具备应用发布和权限审批权限的管理员账号。
- 准备两个普通测试用户，用于验证 allowlist、OAuth 用户授权、群内权限隔离。
- 不使用生产业务群、生产文档、生产日历、生产多维表格。

### 7.2 应用和机器人

- 准备两个测试 Feishu app/bot，用于 accountId 和 multi-bot route 验收。
- 每个 app/bot 记录脱敏标识：`accountId`、bot 名称、测试租户名称、是否启用 bot 能力。
- appId/appSecret 只写入临时 Metis 配置或安全凭据存储，不写入 `develop_steps`、截图、日志、PR 描述。
- 在开发者后台启用机器人能力。
- 配置事件订阅或长连接，让 Gateway 能收到测试消息事件。
- 配置卡片回传交互，用于 CardKit 和按钮事件验收。
- 发布测试版本，并记录发布和审核状态。

### 7.3 权限和 scopes

应用身份基础 scopes：

- `contact:contact.base:readonly`
- `docx:document:readonly`
- `im:chat:read`
- `im:chat:update`
- `im:message.group_at_msg:readonly`
- `im:message.p2p_msg:readonly`
- `im:message.pins:read`
- `im:message.pins:write_only`
- `im:message.reactions:read`
- `im:message.reactions:write_only`
- `im:message:readonly`
- `im:message:recall`
- `im:message:send_as_bot`
- `im:message:send_multi_users`
- `im:message:send_sys_msg`
- `im:message:update`
- `im:resource`
- `application:application:self_manage`
- `cardkit:card:write`
- `cardkit:card:read`

用户授权和 OAPI smoke scopes：

- `offline_access`
- doc/docx 只读和测试写入权限
- wiki 只读和测试写入权限
- calendar 只读和测试写入权限
- task 只读和测试写入权限
- bitable/base 只读和测试写入权限
- sheet 只读和测试写入权限
- search/message 只读权限

验收原则：

- 先授权最低可用 scopes。
- 写操作只对测试资源执行。
- 缺 scope 场景需要保留一次脱敏诊断，证明 repair hint 指向正确权限。
- 日志检查不能出现 appSecret、accessToken、refreshToken、Authorization、bot token。

### 7.4 测试资源

- 测试单聊：bot 与测试用户私聊。
- 测试普通群：验证 `requireMention=true`、非 @ 不触发、@ 触发。
- 测试话题群：验证 `threadSession=true` 时不同话题上下文隔离。
- 测试 allowlist：授权用户触发，非授权用户被拒绝。
- 测试文档：只读文档和可写文档各一份。
- 测试 wiki：只读节点和可写节点各一份。
- 测试日历：测试日历和测试日程。
- 测试任务：测试任务清单和任务。
- 测试多维表格：测试 base、table、view、record。
- 测试表格：测试 spreadsheet、sheet、单元格范围。
- 测试消息资源：图片、文件、音频、视频。
- 测试互动事件：reaction、引用消息、合并转发、卡片按钮。
- CardKit 测试群：支持 create、stream patch、final update、abort/fallback 的低风险群。

### 7.5 运行隔离

live 验收使用临时目录：

```bash
export METIS_HOME=/tmp/metis-agentteam-s22-live-home
export METIS_AGENTTEAM_REPORT_DIR=/tmp/metis-agentteam-s22-live-report
```

live Feishu gate 只通过 operator opt-in 启用：

```bash
export METIS_AGENTTEAM_LIVE_FEISHU=1
```

运行记录中只保留脱敏状态：

- `provided-redacted`
- `missing`
- `manual-opt-in-record-required`
- `external-resource-required`

## 8. Telegram live 验收资源准备清单

### 8.1 账号和聊天资源

- 准备一个只用于测试的 Telegram bot token。
- 准备一个测试私聊用户。
- 准备一个测试群。
- 准备一个启用 topic 的测试群或 forum topic。
- 记录 `accountId`、测试 chat id、topic/thread id 的脱敏标识。
- 需要代理时，使用测试代理配置；代理密码不进入日志和文档。

### 8.2 验收场景

- 私聊发送普通消息，确认命中指定 agent。
- 群内 @ bot，确认命中 group route。
- topic 内发送消息，确认 sessionKey 包含 topic 维度且不串上下文。
- 配置 team broadcast selected members，确认每个 member agent 都有 fan-out 记录。
- 检查 Gateway 日志存在 `Gateway.inbound: channel=telegram`。
- 检查 outbound reply 成功或失败原因。
- 检查日志不包含 bot token、Authorization、proxy credential。

### 8.3 opt-in 环境变量

```bash
export METIS_AGENTTEAM_LIVE_TELEGRAM=1
export METIS_AGENTTEAM_TELEGRAM_ACCOUNT_ID=<redacted-test-account-id>
export METIS_AGENTTEAM_TELEGRAM_TEST_CHAT_ID=<redacted-test-chat-or-topic-id>
```

Telegram 代理验收走 Metis 原生 transport。Telegram HTTPS 目标经 HTTP proxy 时，保留 HTTP CONNECT 连接器路径，不使用 `curl --config` 代替 native transport。

## 9. 预期验证命令

### 9.1 文档和 gate 预检

```bash
bash -n scripts/agentteam-manual-acceptance-gate.sh scripts/agentteam-manual-acceptance-gate-test.sh
bash scripts/agentteam-manual-acceptance-gate-test.sh
node --test scripts/agentteam-manual-acceptance-gate.test.mjs
METIS_AGENTTEAM_SKIP_ENVSETUP=1 METIS_HOME=/tmp/metis-agentteam-s22-gate-home METIS_AGENTTEAM_REPORT_DIR=/tmp/metis-agentteam-s22-gate-report scripts/agentteam-manual-acceptance-gate.sh
```

### 9.2 Cangjie 回归

```bash
cjpm clean && cjpm build -i && cjpm test
```

针对 worker 改动的局部命令：

```bash
cjpm test src/gateway/channels/feishu --no-color --show-all-output --parallel 1
cjpm test src/gateway/channels/telegram --no-color --show-all-output --parallel 1
cjpm test src/gateway/tools --no-color --show-all-output --parallel 1
cjpm test src/gateway/runtime --no-color --show-all-output --parallel 1
cjpm test src/program --no-color --show-all-output --parallel 1
```

### 9.3 Control UI 验证

Control UI 相关改动需要同时通过 build、单测、真实浏览器 smoke：

```bash
npm --prefix ui run build
npm --prefix ui test -- src/ui/controllers/agent-teams.metis.test.ts src/ui/views/agents-panel-teams.metis.test.ts src/ui/views/agents.metis.test.ts src/ui/navigation.test.ts src/ui/navigation.browser.test.ts src/ui/metis-control-ui-contract.metis.test.ts src/ui/metis-control-ui-browser-smoke.metis.test.ts --reporter verbose
```

真实浏览器 smoke 检查项：

- 构建后的 JavaScript 不含浏览器会拒绝的原始 TypeScript decorator。
- `customElements.get("metis-app")` 已注册。
- 页面渲染可见 Metis UI 内容。
- 无 page error。
- 无 JavaScript/CSS asset 404。
- control token bootstrap 写入 runtime 读取的同一 storage backend。
- favicon 和 touch-icon 不含 OpenClaw 品牌图形标记。

### 9.4 live 证据包

live gate 使用 operator opt-in：

```bash
METIS_AGENTTEAM_LIVE_TELEGRAM=1 \
METIS_AGENTTEAM_TELEGRAM_ACCOUNT_ID=<redacted-test-account-id> \
METIS_AGENTTEAM_TELEGRAM_TEST_CHAT_ID=<redacted-test-chat-or-topic-id> \
METIS_AGENTTEAM_SKIP_ENVSETUP=1 \
METIS_HOME=/tmp/metis-agentteam-s22-live-home \
METIS_AGENTTEAM_REPORT_DIR=/tmp/metis-agentteam-s22-live-report \
scripts/agentteam-manual-acceptance-gate.sh
```

```bash
METIS_AGENTTEAM_LIVE_FEISHU=1 \
METIS_AGENTTEAM_SKIP_ENVSETUP=1 \
METIS_HOME=/tmp/metis-agentteam-s22-live-home \
METIS_AGENTTEAM_REPORT_DIR=/tmp/metis-agentteam-s22-live-report \
scripts/agentteam-manual-acceptance-gate.sh
```

## 10. 后续 live 验收交付物

Telegram 交付物：

- 测试 bot/accountId 的脱敏说明。
- 私聊、群、topic 三类 inbound/outbound 脱敏日志。
- route result 或 sessionKey 证据。
- broadcast aggregate 证据。
- 日志脱敏检查结果。

Feishu 交付物：

- 测试租户和两个测试 app/bot 的脱敏说明。
- app/bot 创建或关联路径记录。
- 事件订阅、回调或长连接配置记录。
- scope 开通记录和缺 scope 诊断记录。
- OAuth start/status/poll/revoke 脱敏记录。
- 每个 OAPI family 的 read smoke 记录。
- 写操作只影响测试资源的记录。
- CardKit create/patch/final/abort 记录。
- rich event/resource 记录。
- `/feishu start`、`/feishu doctor`、`/feishu auth` 真实会话记录。
- 日志脱敏检查结果。

Phase 8 平台确认交付物：

- 飞书开放平台可调用 API 清单，逐项列出 endpoint、所需 token、所需 scope、租户角色、审核要求。
- 自动创建 app 的测试租户执行记录，或飞书平台不开放该能力的官方说明。
- 自动创建 bot 能力、事件订阅、scope 导入、版本发布、审核的每一步 pass/fail 记录。
- Metis 产品文案更新记录：未完成平台验证前，只展示“关联已有机器人”和“配置向导”。

## 11. 当前可执行决策

1. 本轮继续保留 Metis 的当前产品边界：guided setup + 关联已有 Feishu app/bot。
2. Phase 8 不进入自动创建实现，直到飞书开放平台 API、租户权限、审核流程完成 live 验证。
3. 后续代码实现不能把 `application:application:self_manage` 解释成自动创建 app/bot 的授权依据；该权限在现有证据中只支撑应用自身权限查询和诊断。
4. 外部 live 缺口写入 gate 和 evidence pack，不写成本地代码失败。
5. 任何真实 token、cookie、appSecret、Authorization header、bot token 均不进入文档、截图、commit message、PR 描述。
6. `develop_steps/` 被 gitignore；合入主工作区时需要对本文档执行强制添加。
