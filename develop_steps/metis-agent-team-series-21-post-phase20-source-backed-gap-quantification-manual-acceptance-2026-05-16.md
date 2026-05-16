# Metis Agent Team Series 21: post-phase20 源码复核、GAP 量化、补齐方案和手工验收

日期：2026-05-16

## 1. 对当前问题的直接回应

这次复核不再把“本地代码缺口”和“外部飞书/Telegram 资源验收缺口”混在一起。前几轮看起来像每轮只补一小部分，核心原因是：你要求所有 GAP 必须有源码事实依据，不能凭感觉列清单；而 Agent Team 涉及 OpenClaw core、openclaw-lark、飞书官方安装器、Metis Gateway、IM channel、Control UI、真实飞书/Telegram 环境。上一轮 phase 0-9 已经把能本地补齐的大部分代码缺口集中合入，提交为 `2a0c305 Complete AgentTeam phase 0-9 gap closure`，series 20 记录完整验证 `cjpm clean && cjpm build -i && cjpm test` 通过，结果为 1423 passed。

本文件的目的不是再制造新的一轮小修小补，而是把当前状态一次性拆清楚：

- 已经本地闭合的差距。
- 代码已有实现，但必须接真实 Telegram/Feishu 资源才能验收的差距。
- 和 OpenClaw/飞书官方体验相比还存在的产品化差距。
- 受飞书开放平台权限、租户策略或人工审核约束，不能靠 Metis 本地代码直接完成的差距。

本次源码阅读边界是 Agent Team 相关调用链。对 OpenClaw 和 openclaw-lark 的证据使用具体文件和行号，不使用无源码依据的推断表述。对全仓无关文件不作为结论来源；结论只从 Agent Team、channel、gateway、workspace、OAuth/OAPI/CardKit、Control UI 相关源码和飞书官方网页产生。

## 2. 外部网页事实

来源：飞书官方文章《OpenClaw飞书官方插件上线｜一文讲清功能、安装更新教程与常见问题！》：`https://www.feishu.cn/content/article/7613711414611463386`。

网页证据：

- 安装命令是 `npx -y @larksuite/openclaw-lark install`，安装时可以选择“新建机器人”或“关联已有机器人”，新建机器人需要飞书客户端扫码并“一键创建飞书机器人”。证据：网页 lines 173-204。
- 用户授权通过飞书对话里的 `/feishu auth` 批量完成；安装验证通过 `/feishu start`。证据：网页 lines 202-208。
- 常见诊断命令包括 `/feishu start`、`/feishu doctor`、`/feishu auth`，也有 `npx @larksuite/openclaw-lark doctor --fix`、`info --all`。证据：网页 lines 443-500。
- 飞书官方插件强调工作数据风险、AI 幻觉和操作不可逆，建议先用个人账号测试，重要写操作要先预览再确认。证据：网页 lines 146-165。
- 权限导入覆盖消息、文档、日历、知识库、资源、reaction 等大量 scopes，且用户授权依赖 `offline_access`。证据：网页 lines 515 以后权限清单。

结论：OpenClaw 官方飞书插件不只是一个消息通道，它还包含安装器、机器人创建/关联、OAuth、doctor/fix、丰富 OAPI 工具、CardKit 和真实飞书权限闭环。Metis 不能把这些全部算作“只要本地代码存在就完成”，必须区分本地能力和真实平台验收。

## 3. OpenClaw 和 openclaw-lark 架构事实

### 3.1 OpenClaw core 的 Agent Team 基础设施

OpenClaw core 没有一个单独叫“team runtime”的孤立大模块。它通过下面几类结构组合出多个智能体：

- `openclaw/src/agents/agent-scope.ts:57-95`：从 `cfg.agents.list` 枚举 agent，空配置回退 `main`；`default=true` 或第一项作为 default agent。
- `openclaw/src/agents/agent-scope.ts:129-160`：单个 agent 的可解析配置包含 `workspace`、`agentDir`、`model`、`skills`、`memorySearch`、`heartbeat`、`identity`、`groupChat`、`subagents`、`sandbox`、`tools`。
- `openclaw/src/config/types.agents.ts:28-59`：binding match 支持 `channel`、`accountId`、`peer`、`guildId`、`teamId`、`roles`；binding 类型至少有 route/acp。
- `openclaw/src/config/types.agents.ts:61-105`：`AgentConfig` 明确支持 per-agent `workspace`、`agentDir`、`model`、`skills`、`params`、`tools`、`runtime`。
- `openclaw/src/agents/workspace.ts:24-33`：标准 profile 文件包括 `AGENTS.md`、`SOUL.md`、`TOOLS.md`、`IDENTITY.md`、`USER.md`、`HEARTBEAT.md`、`BOOTSTRAP.md`、`MEMORY.md`/`memory.md`。
- `openclaw/src/agents/workspace.ts:56-88` 和 `:168-179`：workspace 文件读取做边界保护，且有支持文件名集合。
- `openclaw/src/gateway/server-methods/agents.ts:526-540`、`:570-589`、`:723-767`、`:775-826`：Gateway 提供 agent list/create/update/remove/files list/get/set 这类管理 RPC。

OpenClaw core 的核心语义是：多 agent 不是复制多个进程，而是通过配置、workspace、agentDir、profile 文件、模型、binding、Gateway session key 和 channel plugin 组合起来。

### 3.2 openclaw-lark 的 Feishu/Lark 插件架构

openclaw-lark 是一个 channel plugin，不是 OpenClaw core 的一部分。它负责 Feishu/Lark 的账号、事件、消息、OAuth、OAPI、CardKit、doctor/install 等能力。

关键证据：

- `openclaw-lark/src/channel/plugin.ts:78-126`：插件声明 Feishu channel，能力包括 direct/group、media、reactions、threads、nativeCommands、blockStreaming。
- `openclaw-lark/src/channel/plugin.ts:167-220`：config adapter 提供 `listAccountIds`、`resolveAccount`、`defaultAccountId`、`setAccountEnabled`、`deleteAccount`、`describeAccount`。
- `openclaw-lark/src/core/accounts.ts:85-108`：从 `channels.feishu.accounts` 枚举 account，顶层 appId/appSecret 仍可作为 default account。
- `openclaw-lark/src/core/accounts.ts:121-183`：按 accountId 将顶层配置和账号覆盖配置合并。
- `openclaw-lark/src/core/accounts.ts:198-208`：创建 account-scoped config，让下游代码从 `cfg.channels.feishu` 读取合并后的当前 account 配置。
- `openclaw-lark/src/messaging/inbound/handler.ts:5-15`：入站消息是七阶段 pipeline：account resolution、parse、sender enrich、gate、prefetch、content resolution、dispatch。
- `openclaw-lark/src/messaging/inbound/handler.ts:70-87`：每条消息先解析 account，再构造 account-scoped config。
- `openclaw-lark/src/messaging/inbound/handler.ts:114-223`：做 policy gate、历史记录、sender command authorization、group config，然后 dispatch 到 agent。
- `openclaw-lark/src/tools/oauth.ts:5-17`：OAuth 工具不接收 `user_open_id` 参数，不把 token 返回给 AI。
- `openclaw-lark/src/core/tool-client.ts:139-250`：ToolClient 统一处理 UAT/TAT、应用 scope 预检、用户授权、fallback owner。
- `openclaw-lark/src/core/tool-client.ts:287-298`：`invokeByPath` 支持 SDK 未覆盖 API 的 raw HTTP path。
- `openclaw-lark/src/card/cardkit.ts:69-95`、`:108-130`、`:142-166`、`:185-245`、`:253-277`：CardKit create、stream patch、final update、send interactive card、streaming mode 都有真实 SDK 调用路径。
- `openclaw-lark/openclaw.plugin.json:14-55`：官方工具 contract 覆盖 bitable、calendar、chat、docs、drive、im、oauth、search、sheet、task、wiki、ask_user 等 40 个工具入口。

openclaw-lark 的关键设计是：IM 入口走 channel plugin，管理和配置走 OpenClaw Gateway/config；飞书账号通过 `accountId` 隔离；OAPI 用统一 ToolClient 保证 token、scope 和错误语义一致；CardKit 是独立真实 API 路径。

## 4. Metis 当前源码事实

### 4.1 Agent scope、workspace、profile、模型和凭据隔离

- `src/core/config/metis_agent_scope.cj:74-93`：读取 `agents`、`agents.defaults`、`agents.list`。
- `src/core/config/metis_agent_scope.cj:139-163`：枚举 agent entries 并去重，非法 id 产生 diagnostic。
- `src/core/config/metis_agent_scope.cj:189-223`：解析 default agent，没有配置时回退 `main`。
- `src/core/config/metis_agent_scope.cj:283-317`：workspace/agentDir path 做路径边界保护。
- `src/core/config/metis_agent_scope.cj:341-380`：从 agent workspace 的 `IDENTITY.md` 读取身份信息。
- `src/core/config/metis_agent_scope.cj:635-707`：解析 per-agent model primary/fallbacks。
- `src/core/config/metis_agent_scope.cj:865-923`：凭据来源优先级是 agent `auth-profiles.json`、agent `models.json`、global models、env。
- `src/core/prompting/metis_workspace_bootstrap.cj:8-20`：支持 OpenClaw 同类 profile 文件名，且明确 `BOOTSTRAP.md` 会读取但不自动创建。
- `src/core/prompting/metis_workspace_bootstrap.cj:178-201`：默认创建 `AGENTS.md`、`SOUL.md`、`TOOLS.md`、`IDENTITY.md`、`USER.md`、`HEARTBEAT.md`、`MEMORY.md`，supported profile 包含 `BOOTSTRAP.md`。
- `src/core/prompting/metis_workspace_bootstrap.cj:203-232`：为每个 workspace 创建默认 profile 文件。

结论：Metis 已支持每个 agent 独立 workspace、agentDir、sessionsDir、profile、model、auth source。`BOOTSTRAP.md` 不自动创建是明确产品取舍，但编辑/读取能力存在。

### 4.2 Gateway route、binding 和 team broadcast

- `src/gateway/core/gateway_agent_route_resolver.cj:7-63`：路由输入包含 channel、accountId、defaultAccountId、peer、parent peer、sender、guildId、teamId、roles、dmScope、explicitAgentId。
- `src/gateway/core/gateway_agent_route_resolver.cj:365-431`：解析 channel default account 和 binding 的 accountId pattern，支持 default 和 wildcard。
- `src/gateway/core/gateway_agent_route_resolver.cj:473-570`：binding 匹配优先级为 peer exact、parent、wildcard、guild+roles、guild、team、account、channel。
- `src/gateway/core/gateway_agent_route_resolver.cj:572-583`：根据 agent/channel/account/peer/dmScope 生成 session key。
- `src/gateway/core/gateway_agent_route_resolver.cj:586-650`：执行 route resolution，未知 agent 回退 default，并输出 diagnostics。
- `src/gateway/runtime/gateway_server_methods_agents.cj:1878-1887`：按 teamId 查找 team。
- `src/gateway/runtime/gateway_server_methods_agents.cj:1897-1905`：内置 `pm-writer-reviewer` team template。
- `src/gateway/runtime/gateway_server_methods_agents.cj:1907-1940`：确保 member agent 的 workspace、agentDir、sessionsDir、AGENT.md。
- `src/gateway/runtime/gateway_server_methods_agents.cj:1996-2008`：team members 自动创建或复用 member agents。
- `src/gateway/runtime/gateway_server_methods_agents.cj:2056-2070`：team binding apply 会校验 binding 解析和 member agent 是否属于 team。
- `src/gateway/runtime/gateway_server_methods_agents.cj:2081-2097`：产品语义明确：CRUD surface 是 `cli-ui-gateway-rpc`，IM surface 是 `runtime-route-alias-native-command`，delete preserves member agents/workspaces。
- `src/gateway/runtime/gateway_server_methods_agents.cj:2123-2188`：`agents.teams.create` 创建 team、members、aliases、bindings、broadcast，并写配置。
- `src/gateway/runtime/gateway_server_methods_agents.cj:2190-2279`：`agents.teams.update` 更新 members、aliases、bindings、broadcast。
- `src/gateway/runtime/gateway_server_methods_agents.cj:2281-2305`：`agents.teams.delete` 只删除 team 定义，不删除 member agents/workspaces。
- `src/gateway/core/gateway_agent_team_broadcast.cj:136-153`：从 `agentTeams.list` 和兼容 `teams` 中收集 team。
- `src/gateway/core/gateway_agent_team_broadcast.cj:215-270`：broadcast 可以用 team binding、broadcast binding 或 broadcast match 命中。
- `src/gateway/core/gateway_agent_team_broadcast.cj:329-371`：每个 fan-out turn 都重新解析 agent scope、workspace、agentDir、modelsJsonPath、authProfilesPath、sessionsDir。
- `src/gateway/core/gateway_agent_team_broadcast.cj:385-412`：fan-out request 保留 replyAccountId、thread、media context。
- `src/gateway/core/gateway_agent_team_broadcast.cj:463-495`：构建 selected members 的 fan-out turns。

结论：Metis 已经在 Gateway 边界内实现 team CRUD、binding apply、member agent 自动创建、明确 broadcast fan-out 语义。它不是 OpenClaw 的完全复制品，但核心边界和路由语义已经对齐。

### 4.3 CLI、Control UI 和用户操作面

- `src/program/cli_local_flows.cj:372-459`：`metis agents team list|get|create|update|delete` 映射到 `agents.teams.*` Gateway RPC。
- `src/program/cli_local_flows.cj:553-571`：help 文案明确 team CRUD 走 CLI/UI/Gateway RPC，Telegram/Feishu IM 只负责 runtime routes、aliases、native commands，不创建/更新/删除 team。
- `ui/src/ui/navigation.ts:4-10`：Control UI 顶部/侧边导航包含 agent 分组，tabs 包含 `agents` 和 `agentTeams`。
- `ui/src/ui/navigation.ts:48-50`：`agentTeams` 路径是 `/agent-teams`。
- `ui/src/ui/views/agents-panel-teams.ts:87-139`：Agent Team panel 渲染 summary、workflow、team wizard、Feishu setup/repair wizard、teams list、editor、binding、workspace profile、model、Feishu settings、doctor。
- `ui/src/ui/views/agents-panel-teams.ts:153-205`：summary 明确展示团队数量、成员、aliases、bindings、Telegram/Feishu readiness，并说明 Control UI 不能自动创建 Feishu app/bot，只能 guided setup 和关联已有 bot。
- `ui/src/ui/views/agents-panel-teams.ts:273-310`：Feishu setup/repair wizard 覆盖 app credentials、event subscription、scopes、routing、OAuth、OAPI、cards。
- `ui/src/ui/controllers/agent-teams.ts:157-166`：Control UI 支持 profile 文件集合：`AGENTS.md`、`SOUL.md`、`TOOLS.md`、`IDENTITY.md`、`USER.md`、`HEARTBEAT.md`、`BOOTSTRAP.md`、`MEMORY.md`。
- `ui/src/ui/controllers/agent-teams.ts:168-280`：Control UI 内置多个 Agent Team templates，包括 generic content、Feishu content handoff、engineering sprint、Telegram support triage、data insight。

结论：Metis 现在已经有 Agent Teams 入口和管理面，不再是“没有 UI”的状态。它仍不是飞书妙搭页面那种完整普通用户团队管理台，这是产品化差距，不是底层能力缺失。

### 4.4 Feishu 多账号、OAuth、OAPI、CardKit 和 rich event

- `src/gateway/channels/feishu/feishu_accounts.cj:43-61`：枚举 Feishu accountIds。
- `src/gateway/channels/feishu/feishu_accounts.cj:63-129`：按 accountId 合并 top-level 和 account override，字段包括 appId/appSecret、threadSession、groups、groupPolicy、requireMention、replyInThread、media。
- `src/gateway/channels/feishu/feishu_accounts.cj:131-176`：输出 account status，appId/appSecret 脱敏。
- `src/gateway/channels/feishu/feishu_auth.cj:191-256`：device flow start/poll/refresh 对应飞书 OIDC device_authorize/token。
- `src/gateway/channels/feishu/feishu_auth.cj:590-655`：native auth start 处理已授权、缺凭据、pending，并保存 pending session，输出脱敏。
- `src/gateway/channels/feishu/feishu_auth.cj:667-698`：native auth status 会读取 token store、pending session 和 refresh 状态。
- `src/gateway/channels/feishu/feishu_auth.cj:710-780`：native auth poll 完成后验证 scopes，保存 token，不输出 token。
- `src/gateway/core/gateway_feishu_native_auth.cj:68-120`：Gateway native auth runner 边界提供 start/status/poll/complete/revoke，默认未配置时返回结构化诊断。
- `src/gateway/core/gateway_feishu_native_auth.cj:161-203`：auth result 只透传允许字段并强制 redacted。
- `src/gateway/tools/gateway_feishu_oapi_client.cj:607-654`：支持 user_access_token、tenant_access_token、bot_access_token、app_access_token 的 token lookup。
- `src/gateway/tools/gateway_feishu_oapi_client.cj:656-700`：app token 缓存和 missing credential 诊断。
- `src/gateway/tools/gateway_feishu_oapi_client.cj:977-1050`：统一 OAPI invoke，处理 unsupported、app scope missing、token mode、missing credential、scope missing、expired、auth required、api error。
- `src/gateway/tools/gateway_feishu_oapi_client.cj:1066-1090`：message resource fetch 使用 user access token 并返回 auth/scope 诊断。
- `src/gateway/tools/gateway_feishu_oapi_toolset.cj:102-280`：Feishu OAPI toolset 覆盖 doc、wiki、drive、search、bitable、calendar、task、sheet、chat、user 等 OpenClaw 兼容工具入口。
- `src/gateway/channels/feishu/feishu_cards.cj:6-95`：构造 interactive card JSON 和 fallback text。
- `src/gateway/channels/feishu/feishu_cards.cj:112-146`：Card fallback 分类覆盖 rate limit、table/content too large、message unavailable、not configured。
- `src/gateway/channels/feishu/feishu_cards.cj:148-190`：CardKit live smoke checklist 标记需要真实外部资源，默认不走网络。
- `src/gateway/channels/feishu/feishu_adapter.cj:1714-1728`：按 Feishu group config 生成 policy context，包含 requireMention、allowBots、tools、skills、systemPrompt、runtimePolicy。
- `src/gateway/channels/feishu/feishu_adapter.cj:1779-1822`：从 mentions 中提取 alias candidates。
- `src/gateway/channels/feishu/feishu_adapter.cj:1824-1875`：为 image/file/media/audio/video 附件写入 media/resource context。

结论：Metis 已有 Feishu 多账号、OAuth、OAPI、诊断、脱敏、card fallback、resource context 的本地实现。和 openclaw-lark 的真实差距主要是 CardKit 真实 SDK/HTTP streaming path 的 live 闭环、rich events/resource 的真实 Feishu 事件覆盖，以及官方 `/feishu start/doctor/auth` 体验的一致性验证。

### 4.5 验收 gate 和历史补齐进展

- `develop_steps/metis-agent-team-series-20-phase0-9-implementation-and-verification-2026-05-16.md` 记录 phase 0-9 已完成，最终完整 Cangjie 验证为 1423 passed。
- `scripts/agentteam-manual-acceptance-gate.sh:47-216`：gate 把 G01-G25 分为 local-pass、external-resource-required、operator-record-required。
- `scripts/agentteam-manual-acceptance-gate.sh:220-260`：gate 会根据环境变量判断 Telegram/Feishu/Control UI 是否具备真实验收资源，默认不伪装 live pass。

结论：series 20 之后，本地能闭合的工作已经明显减少；剩余问题主要需要真实外部资源或产品化选择。

## 5. 当前 GAP 总矩阵

状态定义：

- `已本地闭合`：源码和本地测试已经覆盖，和 OpenClaw/openclaw-lark 目标语义一致。
- `代码已有，待 live 验收`：Metis 有实现和 fake/gate 测试，但必须接真实 Telegram/Feishu 资源验证。
- `局部产品差距`：底层能力有，但和飞书官方 OpenClaw/Miaoda 体验仍不完全一致。
- `平台边界待确认`：需要飞书开放平台权限、租户策略或人工审核确认，不能靠本地代码直接保证。

| ID | 能力 | OpenClaw/openclaw-lark 证据 | Metis 证据 | 当前状态 | 剩余补齐措施 |
| --- | --- | --- | --- | --- | --- |
| G01 | 多 agent 配置和 default agent | `agent-scope.ts:57-95` | `metis_agent_scope.cj:74-223` | 已本地闭合 | 保留回归测试和手工验收。 |
| G02 | 每个 agent 独立 workspace/agentDir/sessionsDir | `agent-scope.ts:129-160` | `gateway_server_methods_agents.cj:1907-1940` | 已本地闭合 | 手工验收跨 agent 文件隔离。 |
| G03 | profile files | `workspace.ts:24-33`、`:168-179` | `metis_workspace_bootstrap.cj:8-20`、`:178-201` | 已本地闭合 | `BOOTSTRAP.md` 不自动创建是设计取舍；UI 支持编辑。 |
| G04 | per-agent model | `types.agents.ts:61-99` | `metis_agent_scope.cj:635-707` | 已本地闭合 | 继续用 provider 参数测试守护 DeepSeek/max_tokens 类回归。 |
| G05 | per-agent auth/credential source | OpenClaw per-agent model/runtime | `metis_agent_scope.cj:865-923` | 已本地闭合 | 手工验收 agent A/B 不串 credentials。 |
| G06 | skill/tool 共享但可按 agent 过滤 | `types.agents.ts:76-99` | agent scope summary 和 Control UI tool policy | 已本地闭合 | Feishu group tool policy 需要 live 场景验收。 |
| G07 | binding match：channel/accountId/peer/guild/team/roles | `types.agents.ts:28-59` | `gateway_agent_route_resolver.cj:473-570` | 已本地闭合 | 手工验收 wildcard、accountId、teamId 冲突。 |
| G08 | CLI/UI/Gateway RPC 管理面，IM 只做 runtime route | OpenClaw Gateway methods + channel plugin 分层 | `cli_local_flows.cj:553-571`、`gateway_server_methods_agents.cj:2081-2097` | 已本地闭合 | 用户文档继续强调边界。 |
| G09 | team CRUD 和 member agent 自动创建 | OpenClaw `agents.list` + workspaces | `gateway_server_methods_agents.cj:2123-2305` | 已本地闭合 | 手工验收 delete 不删用户 workspace。 |
| G10 | team broadcast/fan-out | OpenClaw session/channel dispatch 模型 | `gateway_agent_team_broadcast.cj:463-514` | 已本地闭合 | 真实 IM delivery 需 live 验收。 |
| G11 | Telegram Agent Team route/broadcast | OpenClaw generic channel route | Metis Telegram adapter、route resolver、manual gate | 代码已有，待 live 验收 | 需要测试 bot、私聊、群、topic、broadcast 证据。 |
| G12 | Feishu 多账号 accountId route | `accounts.ts:85-208`、`plugin.ts:167-220` | `feishu_accounts.cj:43-176` | 代码已有，待 live 验收 | 需要两个真实测试 app/bot/accountId。 |
| G13 | Feishu groupPolicy/requireMention/threadSession | 网页 lines 394-441；`handler.ts:114-223` | `feishu_accounts.cj:81-110`、`feishu_adapter.cj:1714-1728` | 代码已有，待 live 验收 | 需要真实群、话题、@/非@、allowlist 验收。 |
| G14 | Feishu OAuth/UAT device flow | `oauth.ts:5-17`、`tool-client.ts:139-250` | `feishu_auth.cj:191-256`、`:590-780` | 代码已有，待 live 验收 | 需要测试 app、offline_access、测试用户授权。 |
| G15 | TAT/app/bot token modes | `tool-client.ts:199-250` | `gateway_feishu_oapi_client.cj:607-700` | 代码已有，待 live 验收 | 需要真实 appId/appSecret 和 token endpoint。 |
| G16 | Feishu OAPI tool matrix | `openclaw.plugin.json:14-55` | `gateway_feishu_oapi_toolset.cj:102-280` | 代码已有，待 live 验收 | 每个 tool family 需要低风险真实资源 smoke。 |
| G17 | scope diagnostic/repair hint | `tool-client.ts:202-227`、网页 lines 443-500 | `gateway_feishu_oapi_client.cj:977-1050` | 代码已有，待 live 验收 | 制造缺 app scope、缺 user scope 场景验证提示。 |
| G18 | CardKit streaming | `cardkit.ts:69-277` | `feishu_cards.cj:6-190` | 局部产品差距 + 待 live 验收 | Metis 有 card JSON/fallback/checklist，但还需要真实 CardKit create/patch/finalize/abort 路径闭环。 |
| G19 | rich events/resource read | `handler.ts:135-153`、media/reactions capabilities | `feishu_adapter.cj:1779-1875`、`gateway_feishu_oapi_client.cj:1066-1090` | 局部产品差距 + 待 live 验收 | 需要图片、文件、音频、视频、reaction、引用、合并转发真实事件。 |
| G20 | `/feishu start`、`/feishu doctor`、`/feishu auth` | 网页 lines 443-451；openclaw-lark commands | Metis native auth runner、Control UI wizard | 局部产品差距 | 需要对齐 IM native command 输出和 doctor/fix 体验。 |
| G21 | 自动创建飞书 app/bot | 网页 lines 183-204 | Control UI 明确只能 guided setup | 平台边界待确认 | 先确认飞书是否允许 self-management API 创建/配置 app/bot；不可行则保持“关联已有机器人”。 |
| G22 | 多机器人映射不同 agent/team | openclaw-lark accounts + binding accountId | `feishu_accounts.cj` + route resolver | 代码已有，待 live 验收 | 需要两个真实 bot 分别绑定不同 agent/team。 |
| G23 | Miaoda-like 管理 UI | 用户保存妙搭页面和飞书产品形态 | `agents-panel-teams.ts:87-310` | 局部产品差距 | 已有工程控制台；还需普通用户导向的模板、状态看板、导入导出、证据包入口。 |
| G24 | 手工验收和 evidence pack | OpenClaw doctor/info/fix | `agentteam-manual-acceptance-gate.sh:47-260` | 已本地闭合 | 需要接真实环境后补 live evidence pack。 |
| G25 | 安全和脱敏 | `oauth.ts:12-17` | `gateway_feishu_native_auth.cj:161-203`、`feishu_accounts.cj:131-176` | 已本地闭合 | 手工验收日志不含 token/secret/Authorization。 |

## 6. 当前完成度量化

### 6.1 分域评分

| 能力域 | 当前完成度 | 依据 |
| --- | ---: | --- |
| Agent core：agents.list/default/scope/workspace/agentDir | 96% | OpenClaw 同类结构已对齐，剩余为人工验收。 |
| profile files：AGENTS/SOUL/TOOLS/IDENTITY/USER/HEARTBEAT/BOOTSTRAP/MEMORY | 95% | 默认不创建 `BOOTSTRAP.md` 是明确取舍，编辑读取存在。 |
| per-agent model/auth/session | 94% | per-agent model、auth-profiles、models.json、session key 已闭合。 |
| binding/accountId/team route | 93% | route resolver 支持完整 match 维度，冲突和 fallback 有本地测试。 |
| team CRUD/broadcast | 92% | Gateway RPC、CLI、UI、fan-out plan 已实现；真实 delivery 待验收。 |
| CLI 管理面 | 90% | 命令存在且说明边界，仍可优化输出体验。 |
| Control UI 管理面 | 82% | Agent Teams 入口、panel、wizard 已有；离 Miaoda-like 普通用户体验还有差距。 |
| Telegram Agent Team live | 82% | 本地 route/broadcast/gate 已有；缺真实 bot/group/topic。 |
| Feishu account/routing/thread | 80% | 多账号、策略、thread context 已有；缺真实多账号和群话题验收。 |
| Feishu OAuth/UAT/TAT/app scope | 78% | device flow、token store、OAPI token mode 已有；缺真实 app/scope/live。 |
| Feishu OAPI parity | 80% | tool matrix 和 client 已有；缺真实低风险资源 smoke。 |
| Feishu CardKit/rich events | 70% | fallback/checklist/resource context 已有；真实 CardKit streaming 和 rich events 是主要剩余差距。 |
| 自动创建 Feishu app/bot | 20% | 当前只支持关联已有 app/bot 和 guided setup；平台能力待确认。 |

### 6.2 总分

当前综合完成度：**86/100**。

拆分口径：

- 本地代码能力完成度：**92/100**。
- 真实生产验收完成度：**74/100**。
- 与 OpenClaw/飞书官方/Miaoda 体验对齐度：**80/100**。

扣分主要来自真实 live 证据缺失、CardKit/rich events 真实链路、Miaoda-like 管理 UI 产品化、自动创建飞书 app/bot 的平台边界。

## 7. 剩余工作量估算

### 7.1 不依赖外部真实资源的工作

预计 **2-3 人日**：

- 补齐 `/feishu start`、`/feishu doctor`、`/feishu auth` 在 Metis native command 下的用户可见输出对齐。
- Control UI 从工程面板进一步产品化：模板库更清晰、状态看板、导入/导出、manual evidence pack 入口、错误修复路径。
- 把本文件的 GAP 矩阵和 manual gate 报告继续互链，避免文档和脚本漂移。
- 加强回归测试，保证新增测试只写临时目录，不触碰真实 `~/.metis`。

### 7.2 需要用户提供真实 Telegram/Feishu 测试资源的工作

预计 **3-5 人日**，前提是资源准备齐：

- Telegram：测试 bot、私聊、群、topic、broadcast、日志脱敏证据。
- Feishu：测试 app/bot、两个 accountId、测试租户、测试用户、测试群/话题。
- Feishu OAuth/OAPI：`offline_access`、必要 scopes、低风险 doc/wiki/calendar/task/bitable/sheet/im 测试资源。
- CardKit：CardKit 权限、测试群、create/patch/finalize/abort 测试。
- rich events/resource：图片、文件、音频、视频、引用、合并转发、reaction。

### 7.3 自动创建 Feishu app/bot

预计 **0.5-1 人日调研**，确认平台能力和权限边界。若飞书开放平台允许通过 API 创建/配置应用和机器人，再预计 **2-4 人日实现 guided create flow**。

如果平台不允许或需要人工审核，则 Metis 不能承诺“自动创建飞书 bot/app”。这时正确产品形态是 guided setup：用户在飞书开发者后台创建或授权，Metis 读取/保存 appId/appSecret、检查事件订阅、检查 scopes、执行 OAuth 和 OAPI doctor。

## 8. 分阶段补齐方案和验收项

### Phase 0：冻结当前 source-backed GAP 主矩阵

目标：以后不再重复“每轮重新发现一批旧差距”。

工作：

- 将本文件作为 series 20 之后的主 GAP 基线。
- 将 G01-G25 映射到 manual gate 的 local-pass、external-resource-required、operator-record-required。
- 新增任何实现项前，先把源码证据和验收项补进本文件或后续 series 文档。

验收项：

- `develop_steps` 中存在本文件。
- 每个 GAP 都有 OpenClaw/openclaw-lark/飞书网页和 Metis 证据。
- 没有无证据的缺口描述。

### Phase 1：Feishu native command 输出对齐

目标：让用户在 Feishu 中看到的 `/feishu start`、`/feishu doctor`、`/feishu auth` 和 OpenClaw 官方体验一致。

工作：

- 对照 `openclaw-lark/src/commands/*.ts` 和飞书网页 lines 443-500，梳理 start/doctor/auth 输出结构。
- 在 Metis native command 层统一输出：版本/运行状态、配置诊断、缺 scope、OAuth 状态、repair steps。
- 保证 IM native command 不做 Agent Team CRUD，只做 runtime route/native command。

验收项：

- `/feishu start` 返回 Metis/Feishu channel 状态和版本信息。
- `/feishu doctor` 能区分缺 appId/appSecret、缺 event subscription、缺 scopes、缺 OAuth、OAPI 不可用、CardKit 未验收。
- `/feishu auth` 只返回 verificationUri/userCode/status，不暴露 deviceCode/accessToken/refreshToken。
- 单测覆盖未配置、已配置、缺 scope、脱敏场景。

### Phase 2：Control UI 产品化补齐

目标：把现有 Agent Teams 工程控制台推进到用户能独立操作的管理台。

工作：

- 保留 `/agent-teams` 和 Agents 分组入口。
- 优化 team 创建向导：选择模板、编辑成员、默认 agent、aliases、binding、broadcast。
- 增加 Feishu/Telegram 连接状态看板和 evidence pack 入口。
- 增加 team import/export，便于备份和迁移。

验收项：

- 用户不记 CLI 命令也能创建、编辑、删除 team。
- 用户能为每个 agent 编辑 profile 文件和 model。
- 用户能设置 Telegram/Feishu binding，并看到 route preview。
- 浏览器烟测无 blank、JS error、asset 404，`customElements.get("metis-app")` 已注册。

### Phase 3：Telegram live 验收闭环

目标：把 G11 从“代码已有，待 live 验收”推进到“已生产验收”。

工作：

- 使用测试 Telegram bot、测试私聊、测试群、测试 topic。
- 配置 private/group/topic route binding。
- 配置 team broadcast selected members。
- 采集脱敏日志和 manual gate report。

验收项：

- 私聊命中指定 agent，sessionKey 正确。
- 群/topic 命中独立 session，topic 不串上下文。
- broadcast fan-out 到 selected members，聚合回复可读。
- 日志不出现 bot token、Authorization、proxy credential。

### Phase 4：Feishu 多账号和 route live 验收

目标：把 G12/G13/G22 从待 live 验收推进到已验收。

工作：

- 准备两个测试 Feishu app/bot/accountId。
- 分别绑定不同 agent/team。
- 测试 requireMention、groupPolicy、threadSession、allowlist。

验收项：

- bot A 和 bot B 命中不同 agent/team。
- `requireMention=true` 时非 @ 消息不触发，@ 消息触发。
- `threadSession=true` 时不同话题上下文隔离。
- 非 allowlist 用户无法触发敏感 command。
- account status 输出 appId/appSecret 脱敏。

### Phase 5：Feishu OAuth/UAT/TAT/OAPI live 验收

目标：把 G14/G15/G16/G17 的真实平台链路验收完整。

工作：

- 开通 `offline_access` 和低风险 OAPI scopes。
- 使用 `/feishu auth` 或 Gateway auth action 完成 device flow。
- 对 doc/wiki/calendar/task/bitable/sheet/im 各跑一个低风险 read action。
- 对测试资源跑限定 write action。

验收项：

- auth start/poll/status/revoke 都有结构化输出且脱敏。
- user_access_token、tenant_access_token、app_access_token/bot_access_token 路径按预期工作或返回准确诊断。
- 每个 tool family 至少一个 read action 成功。
- 写操作只影响测试资源。
- 缺 app scope 和缺 user scope 时 repair hint 指向正确 scope。

### Phase 6：Feishu CardKit streaming live 闭环

目标：缩小 Metis 和 openclaw-lark 在 CardKit 上的最大真实差距。

工作：

- 对照 `openclaw-lark/src/card/cardkit.ts:69-277`，确认 Metis 采用 SDK 还是 HTTP OAPI path 完成 create/stream patch/final update/settings。
- 用测试群发送 streaming card。
- 验证 fallback 分类和 message unavailable 行为。

验收项：

- card create 成功并得到 cardId。
- stream patch 按序更新。
- final update 正确关闭 streaming 状态。
- abort/fallback 可读，且不丢最终回复。
- CardKit 错误不会泄露 token/tenant 信息。

### Phase 7：Feishu rich events/resource live 闭环

目标：把 G19 从 fake/resource context 走到真实事件覆盖。

工作：

- 准备图片、文件、音频、视频、引用、合并转发、reaction 的测试消息。
- 验证 attachment context 和 historical resource fetch。
- 验证不支持事件能返回明确分类。

验收项：

- image/file/audio/video 的 resource context 包含 messageId、fileKey、resourceType、mime、size。
- resource fetch 成功或返回 auth_required/scope_missing/api_error 的准确诊断。
- reaction、引用、合并转发不破坏主消息 dispatch。
- 所有下载只写测试目录。

### Phase 8：自动创建 Feishu app/bot 平台能力确认

目标：不要在平台不支持的能力上做伪实现。

工作：

- 调研飞书开放平台是否允许由第三方应用/API 自动创建应用、机器人、事件订阅和权限导入。
- 若允许，制定 guided create flow。
- 若不允许，明确产品边界：只支持关联已有机器人和 guided setup。

验收项：

- 产出平台能力结论文档，列出 API、权限、审核和租户要求。
- Control UI 文案不暗示 Metis 能自动创建 bot，除非真实 API 已验证。
- 若进入实现，必须有 fake test、no-real-config test、手工 live gate。

### Phase 9：发布前完整回归和证据包

目标：保证一次性补齐后的质量，不靠口头完成。

工作：

- 运行 `cjpm clean && cjpm build -i && cjpm test`。
- Control UI 修改后运行 `npm --prefix ui run build` 和浏览器 smoke。
- 运行 `scripts/agentteam-manual-acceptance-gate.sh` 生成 evidence pack。
- 真实资源可用时，补 Telegram/Feishu live evidence pack。

验收项：

- Cangjie build/test 全通过。
- UI build 和 browser smoke 全通过。
- evidence pack 标明 pass/fail/skipped/external-resource-required。
- 报告中不出现 appSecret、accessToken、refreshToken、bot token、Authorization。

## 9. 用户交互和操作路径

### 9.1 CLI

启动 Gateway：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH"
metis gateway run
```

创建和管理 team：

```bash
metis agents team list --json
metis agents team create --team content --template pm-writer-reviewer --json
metis agents team get --team content --json
metis agents team update --team content --name "Content Team" --member content-writer:writer:Writer --alias @writer=content-writer --json
metis agents team delete --team content --json
```

CLI 的定位：

- CLI 是管理面，走 Gateway RPC。
- CLI 不是 IM channel。
- CLI 可以创建/更新/删除 team。
- Telegram/Feishu 不负责 team CRUD，只负责消息触发、route、alias、native command。

### 9.2 Control UI

当前可用路径：

1. 启动 Gateway。
2. 打开 Control UI。
3. 进入 agent 分组中的 `Agent Teams`，路径是 `/agent-teams`。
4. 在 Team Management 中选择模板或创建新 team。
5. 编辑 members、default agent、aliases、bindings、broadcast。
6. 选择成员 agent 后编辑 profile files 和 model。
7. 使用 Feishu setup/repair wizard 查看 app credentials、event subscription、scopes、OAuth、OAPI、Card 状态。

Control UI 的定位：

- Control UI 是管理面，走 Gateway RPC。
- Control UI 当前支持 guided setup 和关联已有 Feishu bot。
- Control UI 当前不自动创建 Feishu app/bot；如果后续飞书平台确认允许，才进入 Phase 8 实现。

### 9.3 Telegram

Telegram 的使用方式：

- 用户先在 CLI 或 Control UI 创建 team 和 binding。
- 私聊里直接发消息，命中绑定 agent 或 default agent。
- 群聊/topic 中 @ bot 或满足 group policy 后触发。
- 如果命中 team broadcast，则 Gateway fan-out 到 selected members 并聚合回复。

Telegram 不支持通过聊天命令创建/删除 team。这是 Metis 的架构边界，和 `cli_local_flows.cj:553-571` 一致。

### 9.4 Feishu

Feishu 的使用方式：

- 用户先在 CLI 或 Control UI 创建 team 和 binding。
- 在飞书中与 bot 对话或在群中 @ bot。
- `/feishu start` 用于连接/版本验证。
- `/feishu doctor` 用于配置、权限、事件订阅、OAPI、CardKit 诊断。
- `/feishu auth` 用于用户授权。
- 普通消息按 accountId、groupPolicy、requireMention、threadSession、binding 路由到 agent/team。
- OAPI 工具在授权和 scope 满足时读写测试资源。

Feishu 不负责 team CRUD；它是 IM runtime channel 和 native command channel。

## 10. 手工验收列表

| 编号 | 手工验收条目 | 验收操作方法 | 验收标准 |
| --- | --- | --- | --- |
| M01 | 临时环境安全 | 设置临时 `METIS_HOME` 和报告目录，运行 manual gate | 只写临时目录，不改真实 `~/.metis`；报告脱敏。 |
| M02 | 完整构建和单测 | `cjpm clean && cjpm build -i && cjpm test` | 全部通过，无 skipped/error/failed。 |
| M03 | CLI team create | `metis agents team create --team content --template pm-writer-reviewer --json` | 返回 ok；team 有 members/defaultAgentId/broadcast/semantics。 |
| M04 | CLI team list/get | `metis agents team list --json`、`metis agents team get --team content --json` | 能看到刚创建的 team、members、aliases、semantics。 |
| M05 | CLI team update | 更新 name/member/alias/binding | 配置持久化；binding apply 成功或返回明确 conflict。 |
| M06 | CLI team delete | `metis agents team delete --team content --json` | team 删除，member agents/workspaces 保留。 |
| M07 | member agent 自动创建 | 创建 team 后查看 agents list 或 config | member agents 存在，workspace/agentDir/sessionsDir 独立。 |
| M08 | profile file 隔离 | 给 writer 写 `SOUL.md`，给 reviewer 写不同 `SOUL.md` | 两者内容互不污染，UI/CLI 读取一致。 |
| M09 | model 隔离 | 给 writer/reviewer 配不同 model | 两个 agent 的 model status 不互相覆盖。 |
| M10 | auth profile 隔离 | 给 agent A/B 配不同测试 credential profile | agent A/B 不串用 token/auth profile。 |
| M11 | binding conflict | 给两个 agent 设置同一 channel/account/peer binding | 第二次 apply 返回 conflict，不写半成品配置。 |
| M12 | Telegram 私聊 route | 测试 bot 私聊发送消息 | 命中指定 agent，回复成功，sessionKey 正确。 |
| M13 | Telegram 群/topic route | 测试群和 topic 中 @ bot | group/topic 独立 session，日志脱敏。 |
| M14 | Telegram team broadcast | 触发绑定 team broadcast | selected members 均执行，聚合回复可读。 |
| M15 | Feishu account status | 配置两个测试 Feishu accounts | status 显示两个 account，appId/appSecret 脱敏。 |
| M16 | Feishu groupPolicy/requireMention | 群内分别发送 @ 和非 @ 消息 | 行为符合配置；非授权用户无法触发敏感 command。 |
| M17 | Feishu threadSession | 话题群不同话题发送消息 | 不同话题上下文隔离。 |
| M18 | Feishu OAuth start/status/poll | `/feishu auth` 或 Gateway auth action | 返回 verificationUri/userCode；完成后 authorized；token 不出现在输出。 |
| M19 | Feishu OAuth revoke | 执行 revoke action | token store 状态变为 revoked/missing；输出脱敏。 |
| M20 | Feishu OAPI read | 读取测试 doc/wiki/calendar/task/bitable/sheet/im | 每类至少一个 read action 成功，或返回准确 scope diagnostic。 |
| M21 | Feishu OAPI write | 只对测试资源创建/修改/删除 | 只影响测试资源；失败有 repair hint。 |
| M22 | Feishu CardKit streaming | 测试群发送 streaming card | create、stream patch、final update、settings/close 成功；失败 fallback 可读。 |
| M23 | Feishu resource read | 发送测试图片/文件/音频/视频 | resource context 完整；能下载或返回准确 auth/scope/api error。 |
| M24 | Feishu rich event | reaction、引用、合并转发、撤回/删除边界 | 能解析事件或给出明确不支持项，不影响主消息 dispatch。 |
| M25 | `/feishu start` | 在飞书对话中发送 `/feishu start` | 返回连接/版本/账号状态，不泄露 secret。 |
| M26 | `/feishu doctor` | 在飞书对话中发送 `/feishu doctor` | 返回配置、event、scope、OAuth、OAPI、CardKit 诊断和修复步骤。 |
| M27 | Control UI browser smoke | 打开 Control UI，进入 `/agent-teams` | 无 blank page、JS error、asset 404；`metis-app` 注册成功。 |
| M28 | Control UI team CRUD | UI 创建/编辑/删除 team | 操作成功，刷新后状态保留。 |
| M29 | Control UI profile/model/binding | UI 编辑 profile/model/binding | Gateway RPC 成功；错误提示可理解。 |
| M30 | Control UI Feishu wizard | 查看 Feishu setup/repair wizard | 能看到 app credentials、OAuth、OAPI、Card 状态和修复步骤。 |
| M31 | 日志脱敏 | 检查 Gateway/Channel/OAPI logs | 不出现 appSecret、accessToken、refreshToken、Authorization、bot token。 |
| M32 | evidence pack | 运行 manual acceptance gate 并收集报告 | 报告包含 pass/fail/skipped/external-resource-required，且脱敏。 |

## 11. 需要用户补充的真实资源

为了把剩余 `代码已有，待 live 验收` 转为 `已本地闭合 + 已生产验收`，需要用户提供或准备：

- Telegram：测试 bot token、测试私聊用户、测试群、测试 topic、可脱敏日志。
- Feishu：测试 app/bot、appId/appSecret、测试租户、测试用户、测试群、话题群。
- Feishu scopes：`offline_access`、消息读写、`im:resource`、CardKit、doc/wiki/calendar/task/bitable/sheet 等测试权限。
- Feishu 测试资源：测试文档、wiki、calendar、task、bitable、sheet、消息、图片、文件、音频、视频。
- 对“自动创建飞书 app/bot”的产品决策：是否接受“只能关联已有机器人”的边界；如果要继续自动创建，需要先确认飞书开放平台 API 和租户权限。

## 12. 后续执行原则

1. 后续 Agent Team 工作以本文件为主基线，不再从零开始重新发现旧 GAP。
2. 如果后续实现超出本文件，先补源码证据和验收项，再动代码。
3. 代码 fake test 通过不能等同于真实飞书/Telegram 生产通过。
4. 缺真实资源不能写成代码缺失；代码缺失也不能用“需要 live 验收”掩盖。
5. 所有外部 live 验收只使用测试资源，不修改真实生产数据。
6. 每轮代码修改仍执行 `cjpm clean && cjpm build -i && cjpm test`；Control UI 修改还必须执行 build 和浏览器 smoke。
