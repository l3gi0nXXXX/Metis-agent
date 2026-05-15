# Metis AgentTeam 系列 17：Phase16 后源码复核、GAP 量化、补齐计划与手工验收

日期：2026-05-15
基线：当前 Metis `main` 工作区，已合入 Series 16 Phase 0-9 的 staged 改动。
范围：飞书公开网页、`openclaw` 多 Agent 核心源码、`openclaw-lark` 飞书插件源码、Metis 当前源码、Series 08-16 历史分析与补齐记录。

## 1. 复核结论

本轮只把能从网页或源码定位到的事实写入 GAP，不基于文件名、函数名或产品预期猜测。网页事实用于确认产品体验目标；架构、GAP、验收项必须以源码路径和行号为准。

| 维度 | Phase15 结论 | Phase16 后当前量化 | 说明 |
| --- | ---: | ---: | --- |
| OpenClaw 核心多 Agent 架构对齐 | 95/100 | 96/100 | workspace、`agentDir`、sessions、`models.json`、`auth-profiles.json`、profile 文件、route binding、team CRUD、broadcast 都已具备；剩余主要是更多真实验收证据和产品模板体验。 |
| Telegram/Feishu 优先 IM 落地 | 88/100 | 92/100 | Series 16 增加了 Telegram route/broadcast fake 验收、手工 gate evidence pack、Feishu OAPI repair、Card/rich event fake matrix。真实 Telegram/Feishu live evidence 仍未闭环。 |
| Feishu OpenClaw-Lark 插件能力对齐 | 84/100 | 89/100 | OAPI 108 action 已 aligned；user/TAT/bot/app token mode、repair action、CardKit observable state、rich events baseline 已补齐。真实 OAuth/UAT/TAT/app-scope、CardKit 和事件矩阵仍需测试租户证明。 |
| Miaoda-like AgentTeam 管理体验 | 约 75/100 | 84/100 | Control UI 已有 Agents -> Teams、模板、wizard、profile/model、Feishu setup/repair、cultivation/memory/doctor panel；仍缺模板市场、云端记忆、一键飞书 app/bot 关联、完整 live 操作证据。 |

综合工程完成度：约 90/100。
真实生产验收完成度：约 76/100。差异来自外部 live 资源未提供：测试 Telegram bot、飞书测试 app/bot、租户、群、线程、scopes、可用 provider 凭证。

剩余工作量按当前源码状态重新估算为 4-6 个有效人日，不包含等待飞书开放平台权限审核、租户授权审批或外部网络排障时间。

| 剩余方向 | 估算 | 是否需要用户补充 |
| --- | ---: | --- |
| 真实 Telegram route/topic/alias/broadcast 验收证据 | 0.5-1 人日 | 需要测试 bot、测试群、测试 topic、测试用户。 |
| 真实 Feishu OAuth/UAT/TAT/app-scope/OAPI 闭环 | 1-1.5 人日 | 需要测试 app/bot、appId/appSecret、测试租户、测试用户、授权 scopes。 |
| 真实 Feishu CardKit streaming、fallback、footer metrics 验收 | 0.75-1 人日 | 需要可发卡片的测试群、CardKit 权限、测试 thread。 |
| 真实 rich events、历史资源读取和 replay/live matrix | 0.75-1 人日 | 需要事件订阅、测试消息/文件/评论/反应/bitable/VC 事件。 |
| Control UI 手工验收和 Miaoda-like 使用体验微调 | 0.75-1 人日 | 需要用户确认模板和页面交互是否符合团队工作流。 |
| 文档、证据包、回归门禁固化 | 0.5 人日 | 需要用户确认哪些 live evidence 可落盘。 |

## 2. 网页事实

飞书官方 OpenClaw 插件文章说明：插件覆盖消息、文档、多维表格、日历、任务等飞书能力，支持流式生成、合并转发、表情等交互，并在安装流程中引导新建或关联机器人，飞书对话里提供 `/feishu auth`、`/feishu start` 等命令。来源：`https://www.feishu.cn/content/article/7613711414611463386`。

飞书智能体团队相关页面描述的目标体验是：同一个 IM/团队工作入口中创建多个专职 Agent，Agent 的角色、身份、知识/记忆、工作区相互独立；用户通过网页管理和 IM 对话触发团队协作。来源：`https://miaoda.feishu.cn/app/app_4k46fjhs6hx1h` 的本地保存页面和用户提供的飞书团队页面背景。

网页事实带来的设计约束：

| 约束 | Metis 当前解释 |
| --- | --- |
| 飞书 app/bot 可以在飞书侧创建或关联 | Metis 不能非交互式创建飞书开放平台 app/bot；Metis 只负责配置、检查、OAuth/OAPI/card/route 能力和 redacted 诊断。 |
| 一个部署可管理多个 Agent | Metis 通过 `agents.list`、`agentTeams.list`、workspace、`agentDir`、bindings 实现。 |
| Agent SOUL/AGENTS/IDENTITY/USER 等可编辑 | Metis 通过 `agents.files.*` 和 Control UI Teams profile panel 编辑支持的 profile 文件。 |
| skill/tool 公用但可按 agent 策略过滤 | Metis 已有 shared tools/skills policy，但 team 模板和 UI 仍需继续打磨。 |

## 3. OpenClaw / OpenClaw-Lark 源码事实

### 3.1 OpenClaw Core 多 Agent

| 事实 | 源码证据 |
| --- | --- |
| `agents.list` 不存在时 fallback 到 `main`；存在时去重后返回 agent ids。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/agent-scope.ts:57-80` |
| default agent 由 `default=true` 或第一项决定。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/agent-scope.ts:83-95` |
| agent entry 可配置 `workspace`、`agentDir`、`model`、`skills`、`memorySearch`、`heartbeat`、`identity`、`groupChat`、`subagents`、`sandbox`、`tools`。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/agent-scope.ts:129-159` |
| per-agent model 支持 primary 和 fallback override。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/agent-scope.ts:169-220` |
| 非 default agent 的 workspace 默认隔离到 default workspace 下的 `<agentId>` 或 state dir 的 `workspace-<agentId>`。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/agent-scope.ts:271-292` |
| `agentDir` 默认是 `<state>/agents/<agentId>/agent`。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/agent-scope.ts:350-362` |
| routing 匹配顺序是 peer、parent peer、peer wildcard、guild+roles、guild、team、account、channel，最后 default。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/routing/resolve-route.ts:743-830` |
| Gateway 按 channel plugin 的 `listAccountIds` 启动每个 account，`accountId` 是 channel account 维度，不是 agent id。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/gateway/server-channels.ts:258-374` |
| `models.json` 位于当前 agent dir，用于模型用量/成本索引。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/utils/usage-format.ts:121-150` |

### 3.2 OpenClaw-Lark 飞书插件

| 事实 | 源码证据 |
| --- | --- |
| Feishu channel plugin 支持 direct/group、media、reactions、threads、native commands、block streaming。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/channel/plugin.ts:78-126` |
| Feishu per-account config 包含 appId/appSecret、encryptKey、verificationToken、domain、connectionMode、groups、history、replyMode、streaming、blockStreaming、footer、dedup、threadSession、uat 等。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/core/config-schema.ts:157-201` |
| Feishu `startAccount` 从已有 account config 启动 monitor，不负责创建飞书开放平台 app。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/channel/plugin.ts:318-338` |
| thread session 只有在 `threadSession=true` 且群是 topic/thread capable 时才创建 thread-scoped session。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/messaging/inbound/dispatch-context.ts:161-201` |
| inbound gate 在 dispatch 前处理 group policy、sender allowlist、require mention、bot sender。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/messaging/inbound/gate.ts:124-220` |
| streaming reply 根据 account replyMode、footer config 创建 `StreamingCardController`，非 streaming 时走 typing/fallback guard。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/card/reply-dispatcher.ts:40-103` |
| StreamingCardController 明确管理 idle、creating、streaming、completed/aborted/terminated 生命周期。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/card/streaming-card-controller.ts:1-11` |
| StreamingCardController 内部保存 cardKit state、streaming text、reasoning、tool-use、flush、unavailable guard、image resolver、footer metrics。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/card/streaming-card-controller.ts:83-170` |
| footer 支持 status、elapsed、tokens、cache、context、model。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/card/builder.ts:215-270` |
| OAPI registry 注册 user/chat/IM/calendar/task/bitable/search/drive/wiki/sheets/bot IM。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/tools/oapi/index.ts:46-94` |
| auto-auth 在工具层处理 UserAuthRequired、UserScopeInsufficient、AppScopeMissing，并发起或更新授权卡片。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/tools/auto-auth.ts:5-30` |
| auto-auth 使用 debounce、scope merge、cooldown 避免并发工具重复发卡片。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/tools/auto-auth.ts:53-245` |
| OAuth 工具不会接受 `user_open_id` 参数，目标用户来自 LarkTicket，token 不暴露给 AI。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/tools/oauth.ts:5-17` |
| UAT client 从安全存储读取 token，自动 refresh，token 不暴露给 AI。 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/core/uat-client.ts:5-10` |

## 4. Metis 当前源码事实

### 4.1 Agent scope、team、route

| 事实 | 源码证据 |
| --- | --- |
| Metis agent scope 解析 `workspaceDir`、`agentDir`、`modelsJsonPath`、`authProfilesPath`、`sessionsDir`、model、skills、tools、identity、groupChat、subagents、memorySearch、sandbox。 | `src/core/config/metis_agent_scope.cj:979-1080` |
| per-agent auth diagnostics 明确不自动复制凭证，复制需要显式确认。 | `src/core/config/metis_agent_scope.cj:1083-1134` |
| route input 包含 channel、accountId、peer、parent peer、sender、guild、team、roles、dmScope、explicitAgentId。 | `src/gateway/core/gateway_agent_route_resolver.cj:7-63` |
| Metis route priority 覆盖 peer exact、parent、peer wildcard、guild+roles、guild、team、account、channel。 | `src/gateway/core/gateway_agent_route_resolver.cj:436-545` |
| AgentTeam broadcast 兼容 `agentTeams.list` 和 legacy `teams`。 | `src/gateway/core/gateway_agent_team_broadcast.cj:136-154` |
| broadcast 可用 bindings、broadcast match 或 team bindings 匹配。 | `src/gateway/core/gateway_agent_team_broadcast.cj:258-270` |
| broadcast 对 selected members 生成 isolated turns，并保留每个 agent 的 route/session context。 | `src/gateway/core/gateway_agent_team_broadcast.cj:451-501` |
| team product semantics 明确：single route 是 deterministic single agent，broadcast 是 explicit fan-out，manager 只是 member/default agent，不是 autonomous manager runtime。 | `src/gateway/runtime/gateway_server_methods_agents.cj:2080-2086` |
| team CRUD 和 binding apply 通过 Gateway RPC 实现，create/update 会预检成员、bindings 和 duplicate agentDir。 | `src/gateway/runtime/gateway_server_methods_agents.cj:2112-2177`、`src/gateway/runtime/gateway_server_methods_agents.cj:2179-2268` |
| Gateway RPC 暴露 `agents.files.*`、`agents.models.*`、`agents.teams.*`。 | `src/gateway/runtime/gateway_server_methods_agents.cj:3167-3246` |
| CLI 支持 `metis agents team create/list/get/update/delete`，也支持 bind/unbind。 | `src/program/cli_local_flows.cj:372-459`、`src/program/cli_local_flows.cj:1878-2049` |

### 4.2 Feishu、OAPI、Card、Control UI

| 事实 | 源码证据 |
| --- | --- |
| Feishu account resolver 支持 default account 和 `accounts` override，合并 app credentials、threadSession、groups、groupPolicy、requireMention、replyInThread、media。 | `src/gateway/channels/feishu/feishu_accounts.cj:32-107` |
| Feishu account status 是 redacted summary，不暴露 appSecret。 | `src/gateway/channels/feishu/feishu_accounts.cj:109-148` |
| Feishu adapter 保存 tenant token cache、thread capability cache、monitor process、accountId、chatQueue、apiClient、event dedup。 | `src/gateway/channels/feishu/feishu_adapter.cj:306-331` |
| card action 被映射成 safe system event inbound，包含 accountId、peerId、threadId、operatorId、messageId。 | `src/gateway/channels/feishu/feishu_adapter.cj:930-1015` |
| Feishu cards 支持 interactive card JSON、fallback decision、live smoke checklist、footer metrics。 | `src/gateway/channels/feishu/feishu_cards.cj:6-175`、`src/gateway/channels/feishu/feishu_cards.cj:177-258` |
| Feishu native auth 支持 start/status/poll/complete/revoke，并 redacted 输出。 | `src/gateway/core/gateway_feishu_native_auth.cj:68-121`、`src/gateway/core/gateway_feishu_native_auth.cj:161-204` |
| Gateway channels RPC 暴露 Feishu auth lifecycle 和 liveSmoke。 | `src/gateway/runtime/gateway_server_methods_channels.cj:2317-2363` |
| OAPI toolset 暴露 doc/wiki/drive/search/bitable/calendar/task/sheets 等工具，并返回结构化 repair action。 | `src/gateway/tools/gateway_feishu_oapi_toolset.cj:102-260` |
| OAPI client 支持 `missing_credential`、`auth_required`、`scope_missing`、`app_scope_missing`、`token_mode_unsupported` 等结构化结果。 | `src/gateway/tools/gateway_feishu_oapi_client.cj:110-214` |
| Series 14 OAPI parity 当前冻结为 108 aligned、0 partial、0 missing、0 not-applicable。 | `develop_steps/metis-agent-team-series-14-oapi-action-parity-report-2026-05-15.md:10-18` |
| Control UI Agents 页面已有 Teams tab。 | `ui/src/ui/views/agents.ts:393-420` |
| Teams panel 包含 workflow、Feishu setup/repair、team list/editor、binding、workspace profile、model、Feishu settings、Auth/Doctor、cultivation、doctor panel。 | `ui/src/ui/views/agents-panel-teams.ts:87-138` |
| Teams controller 定义 8 个 profile 文件和多类模板，包含 Feishu / Telegram 模板。 | `ui/src/ui/controllers/agent-teams.ts:157-216` |
| 手工验收 gate 会写 redacted evidence pack、拒绝真实 `~/.metis`、检查 OAPI parity、可选浏览器 smoke、可选 live Telegram/Feishu。 | `scripts/agentteam-manual-acceptance-gate.sh:34-184`、`scripts/agentteam-manual-acceptance-gate.sh:204-230` |

## 5. 当前 GAP 矩阵

状态只使用 `aligned`、`partial`、`missing`、`not-applicable`。

| 编号 | 能力 | OpenClaw / OpenClaw-Lark 事实 | Metis 当前事实 | 状态 | 当前 GAP | 补齐措施 |
| --- | --- | --- | --- | --- | --- | --- |
| G1 | 多 Agent scope 隔离 | OpenClaw agent scope 解析 workspace、agentDir、model、skills、tools 等。 | Metis scope 解析等价路径和策略。 | aligned | 无核心架构 GAP。 | 保持 `metis_agent_scope`、team CRUD、duplicate agentDir 测试。 |
| G2 | `agents/` 目录语义 | OpenClaw 默认 `<state>/agents/<agentId>/agent`。 | Metis 默认 `~/.metis/agents/<agentId>/agent`，sessions 独立。 | aligned | 无路径语义 GAP。 | 文档和 UI 继续明确 agentDir 不可共享。 |
| G3 | per-agent profile | OpenClaw 强调 per-agent prompt/identity files。 | Metis 支持 `AGENTS.md`、`SOUL.md`、`TOOLS.md`、`IDENTITY.md`、`USER.md`、`HEARTBEAT.md`、`BOOTSTRAP.md`、`MEMORY.md`。 | aligned | `BOOTSTRAP.md` 不自动创建是设计选择，不是 GAP。 | 手工验收中验证 `BOOTSTRAP.md` 可由 `agents.files.set` 创建。 |
| G4 | per-agent model | OpenClaw 支持 agent model primary/fallback。 | Metis 支持 agent entry model 和 per-agent `models.json`。 | aligned | 缺真实多模型运行证据。 | 用临时 `METIS_HOME` 和两套测试模型执行手工 smoke。 |
| G5 | per-agent auth | OpenClaw 不自动共享主 agent auth。 | Metis 显式禁止隐式复制，copy 需要 confirm/source。 | aligned | 缺真实 provider credential 隔离证据。 | 手工验证 agentA 有凭证、agentB 无凭证时状态 redacted 且不串用。 |
| G6 | route priority | OpenClaw route priority 明确。 | Metis route priority 等价。 | aligned | 缺真实 Telegram/Feishu route live evidence。 | 执行第 8 章 T04、T05、F03、F04。 |
| G7 | binding apply | OpenClaw 通过 bindings 决定 inbound route。 | Metis `agents.bind`、team create/update 可 apply bindings 并拒绝 conflict。 | aligned | 缺手工记录。 | 手工验证同一 route 绑定不同 agent 被拒绝且不写半成品。 |
| G8 | broadcast/fan-out | OpenClaw 支持 broadcast groups。 | Metis broadcast 对 selected members 生成 isolated turns 和 aggregate。 | aligned | 缺真实 IM fan-out UX 证据。 | Telegram/Feishu 各做一次 broadcast live smoke。 |
| G9 | CLI / Gateway RPC | OpenClaw 通过 CLI/RPC 管理 agent。 | Metis 有 `metis agents ...` 和 `agents.*` RPC。 | aligned | 无核心 GAP。 | 保持 CLI/RPC 手工验收。 |
| G10 | Control UI 管理页 | 飞书团队页强调网页管理 AgentTeam。 | Metis 有 Agents -> Teams 子页。 | partial | UI 已能管理，但不等同 Miaoda 模板市场/云端团队管理。 | 补模板导入导出、模板分组验收、用户确认交互细节。 |
| G11 | 飞书 app/bot 创建/关联 | 网页文章可引导新建或关联 bot；openclaw-lark 源码只从 config 启动 account。 | Metis 明确不能自动创建开放平台 app/bot。 | partial | 缺“一键创建/关联”体验；但自动创建不是当前架构内能力。 | 保留手工创建，增加 setup wizard 的 copyable steps 和 live checklist。 |
| G12 | Feishu OAuth/UAT | OpenClaw-Lark ToolClient/auto-auth 发卡片并处理 token。 | Metis 有 native auth lifecycle、redacted result、repair action 和 liveSmoke gate。 | partial | 缺真实租户 start/poll/complete/refresh/revoke 成功证据；auto-auth 仍偏 Gateway repair，不是完全 OpenClaw-Lark 卡片自动更新体验。 | 用测试租户执行 OAuth live pack；再决定是否补“工具触发自动授权卡片更新”。 |
| G13 | OAPI action parity | OpenClaw-Lark 注册 OAPI 分类。 | Metis Series 14 报告为 108 aligned。 | aligned | action-level 无当前 GAP。 | 每次新增 action 重新生成 parity report。 |
| G14 | token mode | OpenClaw-Lark 支持 UAT/TAT 等。 | Metis 支持 user/TAT/bot/app token mode 和 missing credential repair。 | aligned | 缺真实 token endpoint 成功证据。 | Feishu live OAPI smoke。 |
| G15 | CardKit streaming | OpenClaw-Lark 有真实 CardKit lifecycle 和 footer metrics。 | Metis 有 fake streaming controller、fallback、footer metrics、live checklist。 | partial | 缺真实 CardKit create/patch/finalize/abort/fallback 证据。 | 执行 Feishu card live matrix，落 redacted result。 |
| G16 | rich events / resources | OpenClaw-Lark 覆盖 reaction、card action、drive、membership、VC、bitable 等。 | Metis 有 rich event fake baseline 和 historical resource OAPI boundary。 | partial | 缺真实 event subscription 和历史资源读取证据。 | 执行 event replay/live matrix 和 safe temp cache 验收。 |
| G17 | threadSession | OpenClaw-Lark 只在 topic/thread capable 群启用 thread session。 | Metis 有 thread capability cache 和 fake coverage。 | partial | 缺真实 Feishu thread-capable 群证据。 | 在测试 topic/thread 群验证 sessionKey 和 route context。 |
| G18 | 手工验收证据包 | OpenClaw-Lark 是真实插件产品。 | Metis 有 `agentteam-manual-acceptance-gate.sh` redacted pack。 | partial | live evidence 仍未填充。 | 按第 8 章逐项执行并落盘。 |

## 6. 分阶段补齐方案

### Phase 0：证据冻结和工作区安全

| 子阶段 | 实施项 | 验收项 |
| --- | --- | --- |
| 0.1 | 以本文件、Series 15、Series 16 为当前差距基线。 | 文档中每个 GAP 都能追溯到源码路径或网页 URL。 |
| 0.2 | 使用 isolated `METIS_HOME`，禁止默认写真实 `~/.metis`。 | `scripts/agentteam-manual-acceptance-gate.sh` 在真实 home 下会失败。 |
| 0.3 | 生成 redacted evidence pack。 | report 中只出现 redacted id 和 pass/fail，不出现 token、secret、Authorization header。 |

### Phase 1：核心 AgentTeam CLI/RPC 验收

| 子阶段 | 实施项 | 验收项 |
| --- | --- | --- |
| 1.1 | CLI 创建/list/get/update/delete team。 | `metis agents team list --json` 能看到 team、members、aliases、semantics。 |
| 1.2 | Gateway RPC 直接调用 `agents.teams.*`。 | RPC 返回值与 CLI 一致，失败时不写半成品。 |
| 1.3 | binding apply conflict 验证。 | 同一 channel/account/peer 绑定到不同 agent 时返回 conflict，配置不被部分写入。 |

### Phase 2：Agent profile / model / auth 隔离验收

| 子阶段 | 实施项 | 验收项 |
| --- | --- | --- |
| 2.1 | `agents.files.list/get/set` 验证 8 个 supported profile。 | 7 个默认文件可见；`BOOTSTRAP.md` 初始可 missing，`set` 后可读取。 |
| 2.2 | `agents.models.get/set` 验证不同 agent 模型。 | agentA/agentB `models.json` 路径不同，modelRef 不串用。 |
| 2.3 | `auth-profiles.json` 隔离验证。 | 未显式复制时 agentB 不读取 agentA/main 凭证；状态 redacted。 |

### Phase 3：Telegram live route 验收

| 子阶段 | 实施项 | 验收项 |
| --- | --- | --- |
| 3.1 | 用测试 bot 配置 `telegram:<accountId>` route。 | Telegram 私聊/群消息进入 `Gateway.inbound: channel=telegram`，resolved agentId 符合绑定。 |
| 3.2 | 用测试 group/topic 验证 topic isolation。 | 不同 topic 生成不同 agent-scoped sessionKey。 |
| 3.3 | 验证 alias route。 | `@writer` 或 `/agent writer` 路由到 writer，普通消息按默认 route。 |
| 3.4 | 验证 broadcast aggregate。 | aggregate reply 记录每个 member 的 agentId、sessionKey、status、answer 或 error。 |

### Phase 4：Feishu account、group、thread route 验收

| 子阶段 | 实施项 | 验收项 |
| --- | --- | --- |
| 4.1 | 使用测试 Feishu app/bot 和 test account 启动 channel。 | `channels.status` 中 account configured/running，secret redacted。 |
| 4.2 | 验证 group route 和 requireMention。 | 群消息只有符合 group policy/mention 时进入 agent route。 |
| 4.3 | 验证 threadSession。 | topic/thread capable 群中 thread 消息生成 thread-scoped sessionKey；非 thread capable 群有 skipped diagnostic。 |

### Phase 5：Feishu OAuth/UAT/TAT/app-scope live 验收

| 子阶段 | 实施项 | 验收项 |
| --- | --- | --- |
| 5.1 | `/feishu start` 或 Control UI Auth start。 | 返回 device/auth 信息或配置缺口，结果 redacted。 |
| 5.2 | 完成 status/poll/complete/refresh/revoke。 | live smoke report 记录每步状态，不包含 accessToken/refreshToken/deviceCode。 |
| 5.3 | 缺 scope / 缺 app scope repair。 | 工具返回 `repair_action`，user auth 可指向 `channels.feishu.auth.start`，app scope 为 operator_required。 |
| 5.4 | TAT/bot/app token live smoke。 | 能按 token mode 选择 provider；缺凭证返回 `missing_credential` 而不是崩溃。 |

### Phase 6：Feishu OAPI 真实工具闭环

| 子阶段 | 实施项 | 验收项 |
| --- | --- | --- |
| 6.1 | 选 3-5 个低风险 OAPI case：search/doc/wiki/calendar/task/bitable 中的读接口。 | 成功 case 返回 `ok=true`；无权限 case 返回结构化 auth/scope diagnostic。 |
| 6.2 | 重新生成 OAPI parity report。 | 仍为 108 aligned、0 partial、0 missing，或新增 action 被明确标注和补测。 |
| 6.3 | 确认报告脱敏。 | report 不包含 appSecret、token、Authorization header、用户私有内容。 |

### Phase 7：Feishu CardKit live parity

| 子阶段 | 实施项 | 验收项 |
| --- | --- | --- |
| 7.1 | 真实群中验证 card create/patch/finalize。 | 同一 card 能持续更新并 final；footer metrics 包含 status/elapsed/model/token 可用字段。 |
| 7.2 | 验证 abort 和 unavailable fallback。 | 中断或消息不可用时有可读 fallback，不出现空回复。 |
| 7.3 | 验证 long text、markdown table、image key。 | 长文本/table 不破坏卡片；图片 key 能替换或降级。 |

### Phase 8：rich events 和资源读取

| 子阶段 | 实施项 | 验收项 |
| --- | --- | --- |
| 8.1 | replay redacted event fixtures。 | message/post/image/file/audio/video/card/reaction/drive/membership/VC/bitable 都有 pass/fail。 |
| 8.2 | live event subscription。 | 测试租户真实事件能映射到 safe system event 或 ignored diagnostic。 |
| 8.3 | historical resource read。 | 使用测试文件和临时 cache 目录，auth/scope/success 都有结构化结果。 |

### Phase 9：Control UI 和最终质量门禁

| 子阶段 | 实施项 | 验收项 |
| --- | --- | --- |
| 9.1 | 打开 Gateway Control UI，进入 Agents -> Teams。 | 页面可见 Teams tab，能创建/编辑/删除 team。 |
| 9.2 | UI profile/model/binding/Feishu wizard 全流程手工验收。 | 所有写入都走 Gateway RPC，浏览器不直接写 token/app secret/`~/.metis`。 |
| 9.3 | 执行统一质量门禁。 | `cjpm clean && cjpm build -i && cjpm test -j 1 --parallel 1`、UI test/build/browser smoke、manual gate 全部通过。 |

## 7. 用户交互方式

### 7.1 CLI

用户先启动 Gateway：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
metis gateway run
```

常用 CLI：

```bash
metis agents team create --team content --name "Content Team" --template pm-writer-reviewer
metis agents team list --json
metis agents team get --team content --json
metis agents team update --team content --name "Content Ops Team"
metis agents bind --agent content-writer --bind telegram:default
metis agents bind --agent feishu-manager --bind feishu:default
metis agents team delete --team content
```

CLI 是 team CRUD 的稳定入口。Telegram/Feishu IM 当前是 runtime route、alias、native command 入口，不是完整 team CRUD 管理入口。

### 7.2 Control UI

操作路径：

1. 打开 Gateway Control UI。
2. 左侧进入 `Agents`。
3. 在 Agents 页面顶部子 tab 点击 `Teams`。
4. 在 `Guided workflow` 查看当前步骤状态。
5. 在 `Team editor` 选择模板、编辑 team id、members、aliases、broadcast。
6. 在 `Binding` 区域 preview/apply Telegram 或 Feishu route。
7. 在 `Workspace profile` 区域选择 member，加载并保存 profile 文件。
8. 在 `Model` 区域加载并保存 per-agent `models.json`。
9. 在 `Feishu setup/repair wizard` 和 `Feishu Auth & Doctor` 中查看配置缺口和修复提示。
10. 在 `Cultivation` 区域查看 `MEMORY.md`、`HEARTBEAT.md`、当前文件预览和 doctor findings。

浏览器边界：Control UI 只作为 Gateway RPC client；不能直接写 token 文件、appSecret、provider key 或真实 `~/.metis`。

### 7.3 Telegram

操作路径：

1. 在 BotFather 创建或选择测试 bot。
2. 在 isolated `METIS_HOME` 中配置 Telegram channel/account。
3. 用 CLI 或 Control UI 绑定 `telegram:<accountId>` 或 structured group/topic route。
4. 在 Telegram 私聊、群、topic 中发送消息。
5. 用别名如 `@writer`、`/agent writer` 验证 alias route。
6. 开启 `broadcast.enabled` 后，在测试群触发 fan-out。

验收关注：Gateway 日志中应有 `Gateway.inbound: channel=telegram`，route 解析应包含 agentId/sessionKey，回复应到达测试 chat/topic。

### 7.4 Feishu

操作路径：

1. 在飞书开放平台创建或选择测试 app/bot。
2. 配置 appId/appSecret、verification token、encrypt key、domain、connection mode、event subscription。
3. 启动 Gateway 后，在飞书对话中运行 `/feishu start`、`/feishu doctor`、`/feishu auth`。
4. 用 CLI 或 Control UI 绑定 `feishu:<accountId>` 或 structured group/thread route。
5. 在测试群/thread 中发送消息，验证 route/session。
6. 触发 OAPI 工具、CardKit streaming、reaction、drive comment、card action 等测试事件。

限制：Metis 不能在创建 AgentTeam 时自动创建真实飞书 app/bot，也不能替用户授予飞书开放平台 scopes。Metis 能做的是配置入口、诊断、OAuth/OAPI/card/live smoke 和 redacted evidence。

## 8. 手工验收清单

| 编号 | 手工验收条目 | 验收操作方法 | 验收标准 |
| --- | --- | --- | --- |
| M01 | isolated home gate | `export METIS_HOME=/tmp/metis-agentteam-manual-acceptance && scripts/agentteam-manual-acceptance-gate.sh` | gate 通过，写出 report.json 和 template；不访问真实 `~/.metis`。 |
| M02 | redaction scan | 查看 evidence pack，运行 gate 内置 scan。 | 不含 bot token、appSecret、accessToken、refreshToken、Authorization header、provider key。 |
| M03 | CLI team create/list/get | 运行 `metis agents team create/list/get --json`。 | JSON 中有 team、members、aliases、semantics。 |
| M04 | CLI team update/delete | 更新 displayName/members/aliases 后删除测试 team。 | update 后 get 可见新值；delete 后 get 返回 not found。 |
| M05 | profile files | Control UI 或 RPC 读取 8 个 supported profile，写入 `BOOTSTRAP.md`。 | `BOOTSTRAP.md` 从 missing 变为 present；其他 profile 不被破坏。 |
| M06 | per-agent model | agentA/agentB 分别保存不同 `models.json`。 | 两个 agent 的 model state 路径和 modelRef 不同，互不覆盖。 |
| M07 | auth isolation | 只给 agentA 配置测试 auth，agentB 不配置。 | agentB 不读取 agentA/main auth；状态只显示 redacted diagnostic。 |
| M08 | binding conflict | 将同一 `telegram:default` 或 `feishu:default` route 绑定到不同 agent。 | 第二次 apply 返回 conflict；配置不被部分写入。 |
| M09 | Telegram direct route | 测试 bot 私聊发送消息。 | 日志显示 Telegram inbound，resolved agentId 符合 direct/account binding。 |
| M10 | Telegram group/topic | 在测试群和 topic 各发一条。 | group/topic sessionKey 不同，topic 不串上下文。 |
| M11 | Telegram alias | 发送 `@writer` 或 `/agent writer`。 | 路由到 writer agent；普通消息走默认 route。 |
| M12 | Telegram broadcast | 对 broadcast-enabled team 发消息。 | 聚合回复包含每个 selected member 的 agentId/status/sessionKey/answer 或 error。 |
| M13 | Feishu start/doctor | 飞书对话运行 `/feishu start`、`/feishu doctor`。 | 返回配置状态或缺口，secret redacted。 |
| M14 | Feishu OAuth | 运行 `/feishu auth` 或 Control UI Auth start，完成授权。 | start/status/poll/complete/refresh/revoke 有 redacted evidence，不落真实 token。 |
| M15 | Feishu route/thread | 测试群/thread 中发送消息。 | accountId、peerId、threadId、agentId、sessionKey 符合绑定；非 thread-capable 群有 skipped diagnostic。 |
| M16 | Feishu OAPI success | 用测试租户执行低风险 OAPI read case。 | 成功 case `ok=true`；无权限 case 返回 `auth_required`、`scope_missing` 或 `app_scope_missing`。 |
| M17 | Feishu OAPI repair | 故意缺 user scope/app scope/app credentials。 | repair_action 正确，user auth 指向 Gateway auth start，app/credential repair 为 operator_required。 |
| M18 | Feishu CardKit streaming | 触发一条较长回复。 | 同一 card create/patch/finalize；footer metrics 可见；无空回复。 |
| M19 | Feishu CardKit fallback | 模拟或触发 recoverable card error。 | 文本 fallback 可见，错误分类为 rate_limit/table_limit/message_unavailable 等。 |
| M20 | Feishu rich events | 触发 card action、reaction、drive comment、membership、VC、bitable 测试事件。 | 每类事件映射为 safe system event 或明确 ignored diagnostic。 |
| M21 | Historical resource | 用测试文件执行历史资源读取。 | 写入 isolated temp cache；权限不足时返回结构化 auth/scope diagnostic。 |
| M22 | Control UI Teams 页面 | 浏览器打开 Agents -> Teams，执行 create/edit/bind/profile/model/auth wizard。 | 页面无 JS 错误，`metis-app` 注册，操作都走 Gateway RPC。 |
| M23 | 最终 Cangjie 门禁 | `source /Users/l3gi0n/cangjie100/envsetup.sh && cjpm clean && cjpm build -i && cjpm test -j 1 --parallel 1`。 | 通过；若普通并行 `cjpm test` 随机 package exit 9，记录并用串行命令作为稳定 gate。 |
| M24 | 最终 UI 门禁 | `npm --prefix ui test && npm --prefix ui run build && npm --prefix ui test -- src/ui/metis-control-ui-browser-smoke.metis.test.ts --reporter verbose`。 | 全部通过；built JS 无 raw TS decorator；Metis branding 无 OpenClaw marker。 |

## 9. 当前需要用户补充的资源

| 资源 | 用途 | 最小要求 |
| --- | --- | --- |
| Telegram 测试 bot | Telegram direct/group/topic route live smoke | bot token 只配置在 isolated `METIS_HOME`，文档只记录 redacted account id。 |
| Telegram 测试群/topic | group/topic/broadcast live smoke | 测试群不要使用生产群。 |
| Feishu 测试 app/bot | Feishu channel/OAuth/OAPI/CardKit/event live smoke | appId/appSecret、verification token、encrypt key、测试 tenant 和测试群。 |
| Feishu scopes 列表 | 验证 auth/scope repair | 记录 granted/missing scope 名称，不记录 token。 |
| 测试 provider/model 凭证 | per-agent model/auth live smoke | 每个 agent 用独立或明确共享的 redacted credential source。 |
| 可落盘的验收证据策略 | 决定哪些 live evidence 可进入 `develop_steps` | 只允许 redacted id、状态、时间、scope 名称、pass/fail。 |

## 10. 后续执行顺序建议

推荐顺序：

1. 先执行 M01-M08，确认核心 AgentTeam 和隔离能力在本机闭环。
2. 再执行 M09-M12，把 Telegram 作为第一条完整 IM live route。
3. 接着执行 M13-M17，闭环 Feishu OAuth/OAPI/token/repair。
4. 再执行 M18-M21，闭环 Feishu CardKit、rich events、resource。
5. 最后执行 M22-M24，完成 Control UI 和全量质量门禁。

如果用户暂时不能提供飞书测试 app/tenant，则 Phase 5-8 的 live 项保持 `partial`，但 fake tests、manual gate 和 redacted evidence pack 仍可作为工程完成证据。
