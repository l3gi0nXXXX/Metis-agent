# Metis Agent Team Series 19: Feishu/OpenClaw Source Recheck, GAP Quantification, and Manual Acceptance

日期：2026-05-16

## 1. 本轮结论

本轮重新核对了飞书官方网页、`openclaw`、`openclaw-lark`、Metis 当前源码，以及 series 18 的历史补齐和验证记录。结论如下：

1. Metis 的 Agent Team 核心架构已经不是“缺一个大模块”的状态。多 Agent、独立 workspace/agentDir、独立 profile files、独立模型配置、binding/accountId 路由、Telegram/Feishu 入口、Gateway RPC/Control UI/CLI 管理面、team broadcast、本地 fake/live-gate 测试都已经进入主线。
2. 当前真实差距主要集中在三类：
   - 真实外部资源验收：Feishu OAuth/UAT/TAT、OAPI、CardKit、rich events、Telegram live route/broadcast 需要真实测试 app、bot、租户、群、topic、测试资源 ID。
   - 产品化差距：Control UI 还不是飞书妙搭页面那种完整 Team Agent 管理台；现在有团队编辑、binding、profile、model、Feishu repair wizard，但仍偏工程控制台。
   - 平台自动化边界：Metis 当前不能自动创建飞书开放平台应用/机器人，只能基于已有 appId/appSecret/bot 配置接入和修复。
3. 按严格产品可用口径，当前 Agent Team 完成度约为 **84/100**；按本地代码能力口径约为 **90/100**；按真实飞书/Telegram 生产验收口径约为 **72/100**。
4. 剩余工作量不是 6-8 周。若只做现有架构下的针对性补齐和真实验收，预计 **5-8 人日**；若额外追求“自动创建飞书机器人/应用”的完整闭环，需先确认飞书开放平台是否允许并授权这类 self-management API，另需 **2-4 人日**，且可能存在平台权限不可自动化的边界。

关于“为什么之前每一轮只能补一小部分”：不是故意拖慢，而是因为我前几轮把每个已证实缺口作为单独 phase 补齐，且你要求所有 GAP 都必须基于源码事实，不能猜。OpenClaw core、openclaw-lark、飞书官方安装器、妙搭页面、Metis Cangjie 主体分散在不同来源，部分能力还必须真实外部资源才能确认。后续不应继续出现结构性漏项；如果再出现新增差距，应只来自真实 live 验收暴露的服务端行为、飞书权限策略变化，或 OpenClaw 上游新版本变化。

## 2. 证据范围

### 2.1 飞书官方网页事实

来源：飞书官方文章《OpenClaw飞书官方插件上线｜一文讲清功能、安装更新教程与常见问题！》。

网页明确说明：

- 官方插件能力包含消息读取、消息发送、消息回复、消息搜索、图片/文件下载、文档、维格表、日历、任务等飞书能力；也支持流式输出卡片、合并转发消息识别、表情等体验能力。网页证据：`https://www.feishu.cn/content/article/7613711414611463386` lines 104-139。
- 安装时可选择“新建机器人”或“关联已有机器人”；新建机器人需要飞书客户端扫码并选择一键创建。网页证据：同页 lines 173-204。
- `/feishu auth` 用于批量用户授权；`/feishu start` 用于验证安装；`/feishu doctor` 用于诊断。网页证据：同页 lines 204-208、443-451。
- Feishu streaming、threadSession、requireMention、groupPolicy、per-group requireMention 都是官方使用教程中的显式能力。网页证据：同页 lines 269-306、311-441。
- 权限导入包含 `offline_access`、`im:resource`、`cardkit:card:write/read`、消息、文档、日历等 scopes。网页证据：同页 lines 515-558 及后续权限清单。

### 2.2 OpenClaw core 源码事实

OpenClaw core 的 Agent Team 基础设施不是一个单独“team manager runtime”，而是由 `agents.list`、per-agent scope、workspace profile files、binding、Gateway session key 和 channel plugin 共同组成。

关键源码：

- `openclaw/src/agents/agent-scope.ts:57-95`：从 `cfg.agents.list` 枚举 agent，默认 fallback 为 `main`，`default=true` 或第一项作为 default agent。
- `openclaw/src/agents/agent-scope.ts:129-160`：per-agent 配置包括 `workspace`、`agentDir`、`model`、`skills`、`memorySearch`、`heartbeat`、`identity`、`groupChat`、`subagents`、`sandbox`、`tools`。
- `openclaw/src/config/types.agents.ts:28-59`：binding match 支持 `channel`、`accountId`、`peer`、`guildId`、`teamId`、`roles`，binding 类型包括 route/acp。
- `openclaw/src/config/types.agents.ts:61-105`：AgentConfig 支持 per-agent workspace、agentDir、model、skills、tools、runtime 等。
- `openclaw/src/agents/workspace.ts:24-33`：标准 profile 文件为 `AGENTS.md`、`SOUL.md`、`TOOLS.md`、`IDENTITY.md`、`USER.md`、`HEARTBEAT.md`、`BOOTSTRAP.md`、`MEMORY.md`/`memory.md`。
- `openclaw/src/agents/workspace.ts:56-88`、`:168-179`：workspace 文件读取有边界保护和受支持文件名集合。

### 2.3 openclaw-lark 源码事实

openclaw-lark 是 Feishu/Lark 插件实现，重点能力是 channel plugin、多账号、account-scoped config、event pipeline、OAuth/UAT/TAT、OAPI tool matrix、CardKit streaming。

关键源码：

- `openclaw-lark/src/channel/plugin.ts:78-126`：Feishu channel plugin 暴露 direct/group/media/reactions/threads/nativeCommands/blockStreaming。
- `openclaw-lark/src/channel/plugin.ts:167-220`：config adapter 提供 `listAccountIds`、`resolveAccount`、`defaultAccountId`、`setAccountEnabled`、`describeAccount`。
- `openclaw-lark/src/core/accounts.ts:85-112`：从 `channels.feishu.accounts` 枚举 account，并在 top-level appId/appSecret 存在时保留 default account。
- `openclaw-lark/src/core/accounts.ts:121-183`：按 account override 合并 appId/appSecret/domain 等配置。
- `openclaw-lark/src/core/accounts.ts:198-208`：构造 account-scoped config，让下游代码从 `cfg.channels.feishu` 读取当前 account 合并后的配置。
- `openclaw-lark/src/messaging/inbound/handler.ts:5-15`：入站消息七阶段 pipeline：account resolution、parse、sender enrich、gate、prefetch、content resolution、dispatch。
- `openclaw-lark/src/messaging/inbound/handler.ts:70-87`：每条消息先 resolve account，并构造 account-scoped config。
- `openclaw-lark/src/messaging/inbound/handler.ts:114-133`、`:155-223`：policy gate、group config、command authorization、dispatch 到 agent。
- `openclaw-lark/src/tools/oauth.ts:5-17`：OAuth 工具面向用户授权，不暴露 user_open_id，不返回 token。
- `openclaw-lark/src/core/tool-client.ts:5-28`、`:139-250`：ToolClient 统一封装 account 解析、SDK、TAT/UAT、scope 预检。
- `openclaw-lark/src/card/cardkit.ts:69-95`、`:108-130`、`:142-166`、`:185-245`、`:253-277`：CardKit create、stream patch、final update、send card、streaming mode。
- `openclaw-lark/openclaw.plugin.json:14-55`：官方插件 tool contract 覆盖 bitable、calendar、chat、docs、drive、im、oauth、search、sheet、task、wiki、ask_user 等。

### 2.4 Metis 当前源码事实

Metis 已经按自身 Gateway/session/channel 架构吸收了大部分 Agent Team 基础设施。

关键源码：

- `src/core/config/metis_agent_scope.cj:74-93`、`:139-163`、`:189-223`：解析 `agents.defaults`、`agents.list`、去重并解析 default agent。
- `src/core/config/metis_agent_scope.cj:283-317`：workspace/agentDir path boundary 保护。
- `src/core/config/metis_agent_scope.cj:341-467`：读取 `IDENTITY.md`，并校验头像路径。
- `src/core/config/metis_agent_scope.cj:635-707`：per-agent model primary/fallbacks。
- `src/core/config/metis_agent_scope.cj:865-923`：credential source 优先级：agent auth-profiles、agent models、global models、env。
- `src/core/prompting/metis_workspace_bootstrap.cj:8-20`、`:178-201`、`:203-230`：Metis profile 文件集合，`BOOTSTRAP.md` 支持读取但默认不自动创建。
- `src/gateway/core/gateway_agent_route_resolver.cj:7-105`、`:365-559`、`:561-633`：channel/accountId/peer/guild/team/roles/dmScope/explicitAgentId 路由和 session key。
- `src/gateway/runtime/gateway_server_methods_agents.cj:1878-2298`：team CRUD、member agent 自动创建、binding apply、alias、broadcast 配置、语义说明。
- `src/gateway/core/gateway_agent_team_broadcast.cj:136-502`：team broadcast plan、selected members、binding match、per-agent turn context、reply account/thread 保留。
- `src/program/cli_local_flows.cj:373-459`、`:553-571`：`metis agents team list|get|create|update|delete` 映射到 Gateway RPC，并明确 IM 只负责 runtime route/alias/native command，不做 team CRUD。
- `src/gateway/channels/feishu/feishu_accounts.cj:32-106`、`:109-147`：Feishu 多账号、defaultAccount、account override merge、threadSession、groupPolicy、requireMention、redacted account status。
- `src/gateway/channels/feishu/feishu_auth.cj:191-256`、`:590-760`：device flow start/poll/refresh/token store/status，token 状态输出脱敏。
- `src/gateway/tools/gateway_feishu_oapi_client.cj:257-323`、`:556-677`、`:939-1083`：UAT/TAT/app token、scope/missing credential/auth_required、OAPI invoke、resource fetch。
- `src/gateway/tools/gateway_feishu_oapi_toolset.cj:102-260` 及后续：Metis-native Feishu OAPI toolset，按 account_id/action/params_json 调用统一 OAPI client。
- `src/gateway/channels/feishu/feishu_cards.cj:6-95`、`:112-191`、`:193-280`：interactive card JSON、fallback 分类、live smoke checklist、footer metrics。
- `src/gateway/channels/feishu/feishu_adapter.cj:33-39`、`:66-109`、`:1714-1822`、`:1824-1870`：Feishu API client boundary、Noop/Fake client、group policy context、alias candidates、attachment/resource context。
- `ui/src/ui/views/agents-panel-teams.ts:87-138`、`:150-260`：Control UI team panel、workflow strip、Feishu setup/repair wizard。
- `ui/src/ui/controllers/agent-teams.ts:157-230`：profile file list 和 Agent Team templates。
- `develop_steps/metis-agent-team-series-18-phase0-9-integration-verification-2026-05-15.md:9-16`、`:20-32`、`:42-54`：上一轮已合入 phase 0-9，最终 `cjpm test` 通过 1412 tests，仍列出需要真实 Telegram/Feishu 资源的 live 验收项。

## 3. 当前 GAP 总矩阵

状态定义：

- `已对齐`：代码结构和本地测试已经覆盖，和 OpenClaw/openclaw-lark 的目标语义一致。
- `已实现，待 live 验收`：Metis 代码已有实现和 fake/gate 测试，但必须接真实外部资源验证。
- `局部差距`：核心能力有，但和 OpenClaw/飞书官方体验还有实现或覆盖差距。
- `产品化差距`：底层能力有，但用户操作体验还没达到妙搭页面级别。
- `外部依赖`：需要用户提供 app/bot/token/test resource，或依赖飞书平台权限。
- `设计取舍`：Metis 按自身架构有意不照搬 OpenClaw 某个产品语义。

| ID | 能力 | OpenClaw/openclaw-lark 证据 | Metis 证据 | 状态 | GAP/下一步 |
| --- | --- | --- | --- | --- | --- |
| G01 | 多 agent 配置、default agent | `agent-scope.ts:57-95` | `metis_agent_scope.cj:74-223` | 已对齐 | 无结构性 GAP。 |
| G02 | 每个 agent 独立 workspace/agentDir | `agent-scope.ts:129-160` | `metis_agent_scope.cj:283-317`; `gateway_server_methods_agents.cj:1907-1940` | 已对齐 | 手工验收要验证跨 agent 文件隔离。 |
| G03 | profile files：AGENTS/SOUL/TOOLS/IDENTITY/USER/HEARTBEAT/BOOTSTRAP/MEMORY | `workspace.ts:24-33`, `:168-179` | `metis_workspace_bootstrap.cj:8-20`, `:178-201` | 已对齐 | Metis 设计上不自动创建 `BOOTSTRAP.md`，但支持 profile editor 读取/写入；这是设计取舍，不是漏项。 |
| G04 | per-agent model | `types.agents.ts:61-99` | `metis_agent_scope.cj:635-707`; `gateway_server_methods_agents.cj` `agents.models.*` | 已对齐 | 继续用测试守护 DeepSeek/max_tokens 等 provider 参数回归。 |
| G05 | per-agent auth profile/credential source | OpenClaw per-agent model/runtime + plugin auth | `metis_agent_scope.cj:865-923`; `gateway_server_methods_agents.cj:883-952` | 已对齐 | 手工验收要确认 agent A/B 不串用 credentials。 |
| G06 | skill/tool 共享但可 per-agent 过滤 | `types.agents.ts:76-99`; `openclaw-lark/src/core/agent-config.ts` | `metis_agent_scope.cj` policy resolution; agent summary 输出 skills/tools | 已对齐 | 仍需 live 验收 Feishu group tool policy 是否符合期望。 |
| G07 | binding match：channel/accountId/peer/guild/team/roles | `types.agents.ts:28-59` | `gateway_agent_route_resolver.cj:7-105`, `:365-559` | 已对齐 | 手工验收要覆盖 accountId 冲突、wildcard、teamId。 |
| G08 | CLI/UI/Gateway RPC 管理面，不通过 IM 创建 team | OpenClaw Gateway methods + channel plugin 分层 | `cli_local_flows.cj:553-571`; `gateway_server_methods_agents.cj:2081-2089` | 已对齐 | 这是架构边界：CLI/Control UI/Gateway RPC 做 CRUD，Telegram/Feishu 做 runtime route。 |
| G09 | Team CRUD 自动创建 member agents | OpenClaw agents/list + workspaces | `gateway_server_methods_agents.cj:1897-2008`, `:2115-2179` | 已对齐 | 手工验收 create/update/delete 后确认 agents/list、workspace、AGENT.md。 |
| G10 | Team broadcast/fan-out | OpenClaw subagent/team runtime 可分派 | `gateway_agent_team_broadcast.cj:136-502` | 已对齐 | 需要 Telegram/Feishu live route 验证真实发送聚合。 |
| G11 | Telegram 优先支持 Agent Team route/broadcast | OpenClaw generic channel model | Metis Telegram adapter + series 18 phase3 | 已实现，待 live 验收 | 需要真实 bot/group/topic，不能用 fake test 替代。 |
| G12 | Feishu 多账号、accountId、account-scoped config | `accounts.ts:85-223`; `plugin.ts:167-220` | `feishu_accounts.cj:32-147`; `gateway_agent_route_resolver.cj` | 已实现，待 live 验收 | 需要真实多个 Feishu app/bot/accountId，验证 account override、status、runtime route。 |
| G13 | Feishu 入站 pipeline、groupPolicy、requireMention、threadSession | `handler.ts:5-15`, `:70-87`, `:114-223`; 网页 lines 288-441 | `feishu_accounts.cj:88-103`; `feishu_adapter.cj:1714-1822`; series 18 | 已实现，待 live 验收 | fake coverage 已有；需要真实群、话题、@、非@、allowlist 验收。 |
| G14 | Feishu OAuth device flow / UAT | `oauth.ts:5-17`; `tool-client.ts:139-250`; 网页 `/feishu auth` | `feishu_auth.cj:191-256`, `:590-760`; tests | 已实现，待 live 验收 | 需要测试 app 开通 offline_access 和用户授权。 |
| G15 | Feishu TAT/app token/bot token/OAPI token mode | `tool-client.ts:199-250` | `gateway_feishu_oapi_client.cj:619-677`, `:779-848` | 已实现，待 live 验收 | 需要真实 appId/appSecret，验证 tenant/app token 请求和缺权限诊断。 |
| G16 | Feishu OAPI 工具矩阵 | `openclaw.plugin.json:14-55`; 网页 lines 104-139 | `gateway_feishu_oapi_toolset.cj:102-260` 及后续；`gateway_feishu_oapi_client.cj:1085-1177` | 已实现，待 live 验收 | 本地矩阵和 fake tests 已覆盖；需要真实低风险读写资源验收。 |
| G17 | Feishu app/user scope diagnostic 和 repair action | `tool-client.ts:202-227`; 网页权限导入 lines 515-558 | `gateway_feishu_oapi_client.cj:954-1027`; `gateway_feishu_oapi_repair.cj` | 已实现，待 live 验收 | 需要真实缺 scope 场景确认提示准确。 |
| G18 | Feishu CardKit streaming card | `cardkit.ts:69-277`; 网页 streaming lines 261-286 | `feishu_cards.cj:6-191`; adapter card boundary | 局部差距 | Metis 有 interactive card/fallback/live-smoke checklist，但不像 openclaw-lark 直接完整封装 CardKit create/stream/update/settings 的真实 SDK 路径；需要真实 CardKit adapter 或 HTTP OAPI 路径验收。 |
| G19 | rich events/resource read：图片/文件/音视频/引用/合并转发/reaction | `handler.ts:135-153`; plugin capabilities media/reactions | `feishu_adapter.cj:1824-1870`; `MetisFeishuOapiResourceClient` | 局部差距 | fake resource context 有，真实资源下载、历史 resource fetch、reaction event 需要 live 验收和补齐失败分类。 |
| G20 | `/feishu start`、`/feishu doctor`、`/feishu auth` native commands | 网页 lines 443-451；openclaw-lark commands | Metis native auth runners and UI wizard | 局部差距 | Auth/status 有；需要确认 IM native commands 完整对齐 start/doctor/auth 输出和权限边界。 |
| G21 | 自动创建飞书机器人/应用 | 网页 lines 173-204 说明官方安装器支持扫码一键新建 | Metis 当前只支持已有 appId/appSecret/bot 配置 | 产品化差距/外部依赖 | 不能凭猜测实现。需确认飞书开放平台 self_manage/OAPI 是否允许自动创建应用/机器人；否则只能提供 guided setup。 |
| G22 | 多机器人映射不同 agent/team | openclaw-lark accounts + OpenClaw binding accountId | `feishu_accounts.cj`; route resolver accountId/teamId | 已实现，待 live 验收 | 需要真实两个 Feishu bots/accounts 分别绑定不同 agent/team。 |
| G23 | Miaoda-like Agent Team 管理 UI | 用户保存的妙搭页面 + 官方产品形态 | `agents-panel-teams.ts:87-260`; controller templates | 产品化差距 | 已有工程控制台，但不是“面向普通用户的完整妙搭式页面”。需要补信息架构、引导流、状态看板、批量导入、模板库、live 修复入口。 |
| G24 | 手工验收与证据包 | OpenClaw doctor/info/fix；网页 lines 443-500 | `agentteam-manual-acceptance-gate.sh`; series 18 verification | 局部差距 | gate 有，但需要一次真实环境的 evidence pack。 |
| G25 | 安全与脱敏 | openclaw-lark oauth 不暴露 token | `feishu_auth.cj`; `gateway_feishu_oapi_client.cj`; tests | 已对齐 | live 日志仍需验收无 appSecret/token/Authorization。 |

## 4. 量化完成度

### 4.1 按能力域量化

| 能力域 | 当前完成度 | 说明 |
| --- | ---: | --- |
| Agent core：agents.list/default/scope/workspace/agentDir | 95% | 与 OpenClaw core 基本对齐，剩余主要是人工验收和文档校准。 |
| Profile files：AGENTS/SOUL/TOOLS/IDENTITY/USER/HEARTBEAT/BOOTSTRAP/MEMORY | 95% | Metis 支持 profile editor；`BOOTSTRAP.md` 不自动创建是明确设计。 |
| per-agent model/auth/session | 92% | 本地实现和测试已覆盖；仍需 provider live 回归继续守护。 |
| binding/accountId/team route | 92% | 结构完整；真实多账号/多群需要 live 验证。 |
| CLI/Gateway RPC 管理面 | 90% | `metis agents team` 已存在；还可补更友好的命令输出和 error help。 |
| Control UI 管理面 | 78% | 有 AgentTeam panel/wizard，但离妙搭式“普通用户管理台”还有体验差距。 |
| Telegram Agent Team live | 82% | 本地 route/broadcast/gate 有；缺真实 bot/group/topic 验收。 |
| Feishu account/routing/group/thread | 78% | 多账号和策略已实现；缺真实飞书群/话题/live event 验收。 |
| Feishu OAuth/UAT/TAT/app scope | 76% | device flow、token store、token modes 已实现；缺真实 app/scopes/live 验收。 |
| Feishu OAPI parity | 78% | 工具矩阵和 OAPI client 有；缺真实低风险资源验收。 |
| Feishu CardKit/rich events | 68% | fake + fallback + checklist 有；真实 CardKit streaming 和 rich event 仍是主要差距。 |
| 自动创建飞书 bot/app | 20% | 当前不是 Metis 能力；需要平台权限确认。 |

### 4.2 总分

- 本地代码能力完成度：**90/100**。
- 真实生产验收完成度：**72/100**。
- 与飞书官方 OpenClaw/Miaoda 体验对齐度：**78/100**。
- 综合 Agent Team 需求完成度：**84/100**。

这个综合分不是简单平均，而是按用户可见价值加权：Agent core、routing、model/auth、CLI/UI 管理面权重较高；真实 Feishu/OAPI/CardKit 因依赖外部资源，按“已实现但未 live 证明”扣分；自动创建飞书机器人因平台边界不明单独扣分。

## 5. 后续补齐工作量

### 5.1 不需要外部资源即可完成

预计 **2-3 人日**：

- 补齐 Control UI 中更清晰的 Agent Team 主导航、状态摘要、空态、错误修复提示。
- 补齐 CLI 帮助文案、doctor 输出、manual gate 说明。
- 将本文件的 GAP 矩阵转换成可执行 checklist 或 gate report。
- 加强 no-real-config 测试，确保所有测试只写临时目录。

### 5.2 需要用户提供测试资源后完成

预计 **3-5 人日**：

- Telegram：真实 bot、测试群、topic、team route、broadcast 聚合验收。
- Feishu：真实测试 app/bot、测试租户、测试用户、测试群/话题、必要 scopes。
- OAPI：准备 doc/wiki/calendar/task/bitable/sheet/im 的低风险测试资源 ID。
- CardKit：测试群、CardKit 权限、可发送/patch/finalize/abort 的测试卡片。
- rich events：测试消息、文件、图片、音频、视频、reaction、引用、合并转发。

### 5.3 自动创建飞书 bot/app 的额外工作

预计 **2-4 人日**，但前提是飞书开放平台允许并授权：

- 调研 `application:application:self_manage` 是否足以创建/配置应用和机器人。
- 若可行，设计 Metis 的 guided create flow：创建 app、开启 bot、写入 appId/appSecret、配置事件订阅、权限导入、OAuth。
- 若不可行，则在 UI 中明确降级为“关联已有机器人/人工创建后接入”，不能伪装成自动创建。

## 6. 分阶段补齐方案和验收项

### Phase 0：冻结 source-backed GAP 主矩阵

工作：

- 将本文件作为当前唯一主 GAP 源。
- 对每个 GAP 标记 owner、状态、外部资源需求。
- 后续任何实现超出本文件时，必须先补文档再动代码。

验收：

- 文档存在于 `develop_steps/`。
- 每个 GAP 都有源码或网页证据。
- 不再用“感觉缺”“可能缺”描述任务。

### Phase 1：管理入口和用户操作路径补齐

工作：

- Control UI 中确认 Agents/Agent Teams 入口实际可见。
- CLI help 中明确 `metis agents team list|get|create|update|delete`。
- 补齐“IM 只触发 runtime，不做 CRUD”的用户说明。

验收：

- 用户能通过 CLI 创建、查看、更新、删除 team。
- 用户能在 Control UI 进入 team panel，看到 workflow strip、team editor、binding、profile、model、Feishu wizard。
- Telegram/Feishu 中不能误触发 team CRUD。

### Phase 2：Agent 隔离验收

工作：

- 验证每个 member agent 的 workspace/agentDir/sessionsDir 独立。
- 验证 profile files 只影响当前 agent。
- 验证 `models.json`、auth profile 不串用。

验收：

- agent A 写 `SOUL.md`，agent B 读取不到 A 的内容。
- agent A 配置模型，agent B 模型不变。
- 删除 team 不误删用户已有 workspace。

### Phase 3：binding/accountId/teamId 路由验收

工作：

- 覆盖 channel、accountId、peer、group、teamId、roles、wildcard。
- 验证 binding conflict 和 apply rollback。

验收：

- 同一个 Telegram/Feishu peer 能绑定到指定 agent/team。
- 不同 accountId 的 Feishu bot 路由到不同 agent。
- 冲突 binding 返回明确错误，不写入半成品配置。

### Phase 4：Telegram live 验收

工作：

- 使用测试 bot、测试私聊、测试群、测试 topic。
- 验证 route、alias、broadcast、reply delivery、session key。

验收：

- 私聊进入指定 agent。
- 群/topic 使用独立 session。
- broadcast 能 fan-out 到 selected members，并返回聚合结果。
- 日志不泄露 token。

### Phase 5：Feishu account/routing/threadSession live 验收

工作：

- 使用两个测试 Feishu accounts/bots。
- 验证 requireMention、groupPolicy、group overrides、threadSession。

验收：

- bot A 与 bot B 可绑定不同 agent/team。
- 非 @ 消息在 requireMention=true 时不触发。
- `threadSession=true` 时不同话题上下文隔离。
- allowlist 用户和非 allowlist 用户行为符合配置。

### Phase 6：Feishu OAuth/UAT/TAT live 验收

工作：

- 开通 offline_access 和至少一组 OAPI scopes。
- 通过 `/feishu auth` 或 Gateway auth action 完成 device flow。
- 验证 status、poll、refresh、revoke。

验收：

- auth start 返回 userCode/verificationUri，且不返回 deviceCode/token。
- poll 后 token store 显示 authorized，输出脱敏。
- 缺 appId/appSecret、缺 offline_access、缺 user scope 都有结构化错误。

### Phase 7：Feishu OAPI parity live 验收

工作：

- 从低风险读能力开始：doc/wiki/search/calendar/task/bitable/sheet/im。
- 再用测试资源验证写能力：创建测试文档、测试任务、测试维格表记录。

验收：

- 每个 tool family 至少一个 read action 成功。
- 每个写入 family 只写测试资源。
- app scope missing/user scope missing/api error 都能给出 repair hint。

### Phase 8：Feishu CardKit 和 rich events live 验收

工作：

- 验证 CardKit create、stream patch、final update、abort/fallback。
- 验证图片、文件、音频、视频、引用、合并转发、reaction/resource read。

验收：

- 流式卡片可以逐步更新，最终状态正确。
- CardKit 不可用时能 fallback 到文本/普通卡片。
- resource read 能读取测试文件，失败时返回可诊断原因。

### Phase 9：Control UI 妙搭式管理体验补齐

工作：

- 从“工程面板”升级为“用户可理解的团队管理台”。
- 增加模板库、创建向导、成员编辑、profile editor、model editor、binding wizard、Feishu/Telegram 连接状态。
- 增加导入/导出团队配置和 evidence pack。

验收：

- 用户无需记 CLI 命令即可创建 team。
- 用户能给每个 agent 编辑 profile/model/binding。
- 用户能看到 Feishu/Telegram 连接是否可用以及缺什么配置。
- Browser smoke test 通过，页面无 blank、JS error、asset 404。

## 7. 用户操作路径

### 7.1 CLI

典型流程：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH"

metis gateway run

metis agents team create --team content --template pm-writer-reviewer
metis agents team list --json
metis agents team get --team content --json
metis agents team update --team content --name "Content Team" --member content-writer:writer:Writer --alias @writer=content-writer
metis agents team delete --team content
```

说明：

- CLI 通过 Gateway RPC 管理 team 定义。
- CLI 不是 IM channel；它不承载 Telegram/Feishu 的消息入站。
- IM 中的 team route/broadcast 依赖 binding 和 runtime session。

### 7.2 Control UI

当前预期操作：

1. 启动 Gateway。
2. 打开 Control UI。
3. 进入 Agents/Agent Teams 管理面。
4. 创建或选择 team。
5. 编辑 members、aliases、bindings、broadcast。
6. 选择成员 agent 后编辑 profile files、model、Feishu auth/status。

当前差距：

- 如果左侧导航还没有显式 `Agents` tab，必须补入口可见性。
- 当前 UI 已有 `renderAgentTeamsPanel` 和 Feishu setup/repair wizard，但体验仍偏工程控制台。

### 7.3 Telegram

用户不通过 Telegram 创建 team。Telegram 的职责是触发已配置好的 runtime route：

- 私聊：发送自然语言消息，路由到绑定 agent 或 default agent。
- 群聊：@ bot 或满足 group policy 后触发。
- topic：应形成独立 session。
- team broadcast：当绑定命中 broadcast team 时 fan-out 到 selected members。

验收时需要测试 bot、测试群、topic、脱敏日志。

### 7.4 Feishu

用户不通过 Feishu 创建 team。Feishu 的职责是触发已配置好的 runtime route，并执行 native commands/OAPI：

- `/feishu start`：验证插件/连接状态。
- `/feishu doctor`：诊断配置、权限、事件订阅。
- `/feishu auth`：启动或引导用户授权。
- 普通消息：按 accountId、groupPolicy、requireMention、threadSession、binding 路由到 agent/team。
- OAPI 工具：在授权和 scopes 满足时执行文档、消息、日历、任务、维格表等操作。

## 8. 手工验收列表

| 编号 | 手工验收条目 | 验收操作方法 | 验收标准 |
| --- | --- | --- | --- |
| M01 | 临时环境安全 | 设置临时 `METIS_HOME`，不使用真实 `~/.metis`；运行 manual gate | 只写临时目录；报告脱敏；真实配置不变。 |
| M02 | 构建和单测 | `cjpm clean && cjpm build -i && cjpm test -j 1 --parallel 1` | 全部通过；无 OpenSSL/TLS 环境错误。 |
| M03 | CLI team create | `metis agents team create --team content --template pm-writer-reviewer --json` | 返回 ok；team 有 members/defaultAgentId/broadcast。 |
| M04 | CLI team list/get | `metis agents team list --json`、`get --team content --json` | 能看到刚创建的 team 和语义说明。 |
| M05 | CLI team update | 更新 name/member/alias/binding | 配置持久化；binding apply 成功或冲突错误明确。 |
| M06 | member agent 自动创建 | 创建 team 后查看 `metis agents list --json` | member agents 存在；workspace/agentDir/sessionsDir 独立。 |
| M07 | profile file 隔离 | 给 writer 写 `SOUL.md`，给 reviewer 写不同 `SOUL.md` | 两者内容互不污染。 |
| M08 | model 隔离 | 给 writer/reviewer 配不同 model | 两个 agent 的 model status 不互相覆盖。 |
| M09 | auth profile 隔离 | 使用测试 credential profile | agent A/B 不串用 token 或 auth profile。 |
| M10 | binding conflict | 给两个 agent 设置同一 channel/account/peer binding | 第二次 apply 返回 conflict；不写半成品。 |
| M11 | Telegram 私聊 route | 测试 bot 私聊发送消息 | 命中绑定 agent；回复成功；日志含 route/sessionKey。 |
| M12 | Telegram 群/topic route | 测试群和 topic 中 @ bot | group/topic 独立 session；不泄露 token。 |
| M13 | Telegram team broadcast | 群/私聊触发绑定 team broadcast | selected members 均执行；返回聚合结果。 |
| M14 | Feishu account status | 配置两个测试 Feishu accounts | channel status 显示两个 account，appId/appSecret 脱敏。 |
| M15 | Feishu groupPolicy/requireMention | 测试群中分别发送 @ 和非 @ 消息 | 行为符合配置；非授权用户不能触发。 |
| M16 | Feishu threadSession | 飞书话题群不同话题发送消息 | 不同话题上下文隔离。 |
| M17 | Feishu OAuth start/status/poll | `/feishu auth` 或 Gateway auth action | 返回 verificationUri/userCode；完成后 authorized；token 不出现在输出。 |
| M18 | Feishu OAPI read | 读取测试 doc/wiki/calendar/task/bitable | 至少每类一个 read action 成功或返回准确 scope diagnostic。 |
| M19 | Feishu OAPI write | 只对测试资源创建/修改/删除 | 操作只影响测试资源；失败有 repair hint。 |
| M20 | Feishu CardKit streaming | 在测试群发送流式卡片 | create/patch/final 成功；失败时 fallback 可读。 |
| M21 | Feishu resource read | 发送测试图片/文件/音频/视频 | resource context 完整；可下载或返回准确原因。 |
| M22 | Feishu rich event | reaction、引用、合并转发、撤回/删除边界 | 能解析事件或给出明确不支持项。 |
| M23 | Control UI browser smoke | 打开 Control UI，进入 Agent Team panel | 无 blank page、JS error、asset 404；custom element 注册成功。 |
| M24 | Control UI team CRUD | UI 创建/编辑/删除 team | 操作成功；刷新后状态保留。 |
| M25 | Control UI profile/model/binding | UI 编辑 profile/model/binding | Gateway RPC 成功；错误提示可理解。 |
| M26 | Control UI Feishu wizard | 查看 Feishu setup/repair wizard | 能看到 app credentials、OAuth、OAPI、Card 状态和修复步骤。 |
| M27 | 日志脱敏 | 检查 Gateway/Channel/OAPI logs | 不出现 appSecret、accessToken、refreshToken、Authorization、bot token。 |
| M28 | 证据包 | 运行 manual acceptance gate 并收集报告 | 报告包含 pass/fail/skipped/external-resource-required，且脱敏。 |

## 9. 需要用户补充的资源

为了把 `已实现，待 live 验收` 变成 `已对齐`，需要用户提供或准备：

1. Telegram：测试 bot token、测试私聊用户、测试群、测试 topic、可脱敏日志。
2. Feishu：测试 app/bot、appId/appSecret、测试租户、测试用户、测试群、话题群。
3. Feishu scopes：`offline_access`、消息读取/发送、`im:resource`、CardKit、doc/wiki/calendar/task/bitable/sheet 等测试权限。
4. Feishu 测试资源：测试文档、wiki、calendar、task、bitable、sheet、消息、图片/文件/音视频。
5. 是否要追求“自动创建飞书机器人/应用”：需要确认是否允许 Metis 通过飞书开放平台 API 创建/配置 app/bot。如果不能授权，则只能做 guided setup。

## 10. 后续执行原则

1. 后续所有 Agent Team 实现都以本文件的 GAP 矩阵为基线。
2. 遇到超出本文件的新实现点，先回查 OpenClaw/openclaw-lark/飞书网页或真实接口文档，再更新本文件或新 series 文档，然后动代码。
3. 不再把“缺真实资源验收”写成“代码缺失”；也不把“代码 fake test 通过”写成“生产已完成”。
4. 对真实外部系统的验收必须只使用测试资源，不修改真实环境配置和数据。
5. 每轮代码修改仍执行 `cjpm clean && cjpm build -i && cjpm test`；Control UI 修改还必须做 browser/runtime smoke。
