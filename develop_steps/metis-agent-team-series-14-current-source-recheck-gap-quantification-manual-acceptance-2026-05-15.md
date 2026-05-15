# Metis AgentTeam 系列 14：当前源码复核、GAP 量化、补齐计划与手工验收清单

日期：2026-05-15
Metis 基线提交：`5946fbd`
复核范围：飞书官方网页、OpenClaw 多 Agent 相关源码、OpenClaw-Lark 飞书插件源码、Metis 当前 `main` 源码、series 08 至 series 13 历史分析和补齐记录。
Phase 0/1/9 证据包：本文件固化源码复核和 GAP 量化；真实 Telegram/Feishu 手工验收结果记录在 `develop_steps/metis-agent-team-series-14-manual-acceptance-runbook-2026-05-15.md`；OAPI baseline 由 `develop_steps/metis-agent-team-series-14-oapi-action-parity-report-2026-05-15.md` 冻结为 108 action、108 aligned、0 partial、0 missing、0 not-applicable。

## 1. 本轮结论

本轮结论分三层。

第一层是 **Metis AgentTeam 核心架构**。Metis 当前已经对齐 OpenClaw 的核心多 Agent 隔离模型：每个 agent 有独立 workspace、`agentDir`、sessions、`models.json`、`auth-profiles.json`、profile 文件集合、路由绑定、`accountId`、session key、binding apply 语义、Gateway RPC 管理、Control UI Teams 页面，以及 deterministic fan-out。按源码事实和本地 fake-tested 能力量化，当前完成度为 **95/100**。

第二层是 **Telegram/Feishu 优先 IM 落地**。Telegram 已具备较完整的 ChannelAdapter 接入和 AgentTeam route baseline；Feishu 已具备事件入口、OAuth lifecycle、OAPI native client/toolset、TAT/app token provider、streaming card controller、Control UI Feishu setup/repair wizard、Auth & Doctor 面板、live smoke opt-in gate 和 OAPI parity report。真实飞书生产体验仍缺真实租户闭环、真实 scope/app-scope repair 验证、完整 CardKit 细节和 Miaoda-like 管理体验。按真实 Telegram + Feishu 优先级量化，当前整体完成度为 **88/100**。

第三层是 **飞书 Claw / OpenClaw-Lark 产品体验对齐**。飞书官方页面描述的目标是同一个飞书群内多个专职 Agent 分工协作，并通过模板、插件、云端记忆、国内模型和运维体验形成开箱即用团队。Metis 当前已经有基础团队管理和隔离架构，但还没有完全达到飞书 OpenClaw 的“从页面一键创建/培养 Agent 团队 + 飞书里自然调度 + 自动修复权限 + 真实 Card/OAPI 全闭环”的体验。按 OpenClaw-Lark + 飞书 OpenClaw 产品体验量化，当前完成度为 **84/100**。

后续工作量估算：

| 目标 | 估算 | 前提 |
| --- | --- | --- |
| 把源码/fake-tested 能力从 95 分推进到 97 分 | 已完成，后续维护约 0.5 人日/轮 | series14 OAPI parity report 已达到 108 aligned、0 partial、0 missing；后续需要在新增 action 时同步维护报告和测试 |
| 把真实 Telegram + Feishu 优先验收推进到 92 分 | 4-6 人日 | 需要测试 Telegram bot、测试飞书 app、测试租户、测试群、测试用户和可授权 scopes |
| 追平 OpenClaw-Lark 生产体验到 90 分以上 | 6-10 人日 | 包含真实 OAuth/UAT/TAT、scope repair、CardKit live、rich events live、Miaoda-like UI |
| 追平飞书 OpenClaw 页面展示的 AgentTeam 产品体验 | 8-12 人日 | 还需要模板市场、Agent 培养/记忆闭环、网页管理流和 IM 自然调度体验 |

## 2. 网页事实

飞书官方插件文章说明，OpenClaw 飞书官方插件面向消息、文档、多维表格、日历、任务等飞书能力，并支持消息流式生成、合并转发识别、表情等交互体验。该页面还说明安装时可选择新建机器人或关联已有机器人，飞书对话内可用 `/feishu auth` 和 `/feishu start` 做授权与验证。来源：`https://www.feishu.cn/content/article/7613711414611463386`。

飞书 OpenClaw AgentTeam 文章说明，Agent Team 是“同一个飞书群内创建多个专职 Agent，各有分工、协同工作、共同完成复杂任务”的产品形态，并以“运营主管、调研专员、写作专员、审核专员”的团队流程作为示例。该页面还强调模板、持续培养、应用开发插件、云端记忆和一站式模型接入。来源：`https://www.feishu.cn/content/article/7629286303804329160`。

网页事实只作为产品目标和验收交互参考；GAP 判断以源码证据为准。

## 3. 历史进展纳入与修正

纳入的历史文档：

| 文档 | 本轮使用方式 |
| --- | --- |
| `develop_steps/metis-agent-team-series-08-source-recheck-gap-quantification-and-landing-plan-2026-05-14.md` | 作为早期 OpenClaw/Metis 架构差距基线 |
| `develop_steps/metis-agent-team-series-09-prioritized-implementation-plan-2026-05-14.md` | 纳入 A/B/C 优先策略，尤其真实 OAuth/OAPI/UI 补齐方向 |
| `develop_steps/metis-agent-team-series-10-feishu-openclaw-source-recheck-gap-quantification-and-landing-plan-2026-05-14.md` | 作为 Feishu/OpenClaw-Lark 深度对比基线 |
| `develop_steps/metis-agent-team-series-11-post-phase0-9-source-recheck-gap-quantification-and-landing-plan-2026-05-14.md` | 纳入 phase 0-9 后的阶段性完成情况 |
| `develop_steps/metis-agent-team-series-12-current-source-recheck-gap-quantification-and-landing-plan-2026-05-14.md` | 纳入 series12 后的当前架构说明 |
| `develop_steps/metis-agent-team-series-13-source-recheck-gap-quantification-manual-acceptance-2026-05-15.md` | 作为上一轮复核和手工验收基线 |
| `develop_steps/metis-agent-team-series-13-oapi-action-parity-report-2026-05-15.md` | 作为上一轮 OAPI 108 action parity 历史报告 |
| `develop_steps/metis-agent-team-series-14-oapi-action-parity-report-2026-05-15.md` | 作为当前 OAPI 108 action parity 报告基线 |
| `develop_steps/metis-agent-team-series-13-*.md` 其他完成记录 | 纳入 live auth smoke、card/events、Control UI setup wizard、docs/runbook 进展 |

本轮修正一处过期结论：series13 源码复核文档中曾写到 Metis native token provider 对 `tenant_access_token` 返回 `token_mode_unsupported`。当前代码已经不是这个状态。`MetisFeishuOapiTokenProvider.tokenLookup` 已支持 `user_access_token`、`tenant_access_token`、`bot_access_token`、`app_access_token`，见 `src/gateway/tools/gateway_feishu_oapi_client.cj:619-630`；`appToken` 会通过 app credentials 获取并缓存 token，见 `src/gateway/tools/gateway_feishu_oapi_client.cj:633-677`；`FeishuNativeOapiAppTokenClient.fetch` 支持 tenant/bot/app token endpoint，见 `src/gateway/tools/gateway_feishu_oapi_client.cj:791-807`。

## 4. OpenClaw / OpenClaw-Lark 源码事实

### 4.1 OpenClaw 多 Agent 核心

| 事实 | 源码证据 |
| --- | --- |
| 一个 Agent 是独立 workspace、`agentDir`、sessions | `/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/concepts/multi-agent.md:10-18` |
| per-agent auth profiles 位于 `~/.openclaw/agents/<agentId>/agent/auth-profiles.json`，主 Agent 凭证不会自动共享 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/concepts/multi-agent.md:20-37` |
| skills 从 agent workspace 和共享 roots 读取，再按 allowlist 过滤 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/concepts/multi-agent.md:39-44` |
| 默认 agentId 为 `main`，session key 形如 `agent:main:main` | `/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/concepts/multi-agent.md:61-68` |
| wizard 创建 isolated agent 后通过 bindings 路由 inbound | `/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/concepts/multi-agent.md:72-84` |
| 每个 agent workspace 包含 `SOUL.md`、`AGENTS.md`、可选 `USER.md`，并有独立 `agentDir`/sessions | `/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/concepts/multi-agent.md:86-99` |
| channel/accountId/agentId/sessionKey 是路由核心术语 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/channels/channel-routing.md:14-23` |
| route 优先级为 peer、parent、guild+roles、guild、team、account、channel、default | `/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/channels/channel-routing.md:58-73` |
| broadcast groups 支持同一 peer 运行多个 agents | `/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/channels/channel-routing.md:75-91` |
| agent scope 解析 workspace、agentDir、model、skills、memory、heartbeat、identity、subagents、sandbox、tools | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/agent-scope.ts:129-159` |
| workspace fallback 和 agentDir fallback 逻辑 | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/agent-scope.ts:271-292`、`:350-362` |
| route resolver 归一化 channel/account/peer/team 并生成 sessionKey/mainSessionKey | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/routing/resolve-route.ts:631-708` |
| route tiers 逐级匹配 binding | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/routing/resolve-route.ts:743-830` |
| session key 支持 main、direct、group、thread | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/routing/session-key.ts:118-174`、`:234-253` |

OpenClaw 核心架构图：

```text
OpenClaw runtime
  |
  +-- Gateway / Control RPC
  |     |
  |     +-- agents.* / agents.files.* / tools.* / skills.*
  |
  +-- ChannelManager
  |     |
  |     +-- Telegram / Feishu plugin / Discord / Slack / WhatsApp / extension channels
  |           |
  |           +-- inbound event(channel, accountId, peer, thread, team, roles)
  |
  +-- Route resolver
  |     |
  |     +-- bindings -> agentId
  |     +-- priority: peer > parent > guild+roles > guild > team > account > channel > default
  |     +-- sessionKey: agent:<agentId>:...
  |
  +-- Agent scope
        |
        +-- workspace: ~/.openclaw/workspace or workspace-<agentId>
        +-- agentDir:  ~/.openclaw/agents/<agentId>/agent
        +-- sessions:  ~/.openclaw/agents/<agentId>/sessions
        +-- auth-profiles.json / model / skills / tools / identity / memory
```

### 4.2 OpenClaw-Lark 飞书插件

| 事实 | 源码证据 |
| --- | --- |
| 官方插件连接 OpenClaw Agent 到飞书 workspace，覆盖消息、文档、多维表格、日历、任务 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/README.md:9-28` |
| channel plugin 支持 direct/group、media、reactions、threads、native commands、block streaming | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/channel/plugin.ts:78-126` |
| account config 包含 appId/appSecret/domain/connectionMode/webhook/replyMode/streaming/dedup/threadSession/uat | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/core/config-schema.ts:157-201` |
| `startAccount` 使用已配置 account 启动 monitor，并不是运行时凭空创建飞书 app | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/channel/plugin.ts:318-338` |
| event handler 做 app_id 归属校验、自回声过滤、dedup、stale、abort fast-path、queue | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/channel/event-handlers.ts:49-167` |
| dispatch context 把 accountId、peer、thread 映射到 OpenClaw route/session | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/messaging/inbound/dispatch-context.ts:102-201` |
| tool client 统一处理 UAT/TAT、app scope、offline_access、owner fallback、invokeAsUser | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/core/tool-client.ts:139-250` |
| auto-auth 处理 UserAuthRequired、UserScopeInsufficient、AppScopeMissing，并合并 scope | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/tools/auto-auth.ts:1-245` |
| OAPI registry 覆盖 common、chat、IM、calendar、task、bitable、search、drive、wiki、sheets、bot IM | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/tools/oapi/index.ts:46-94` |
| tool-scopes 注释仍写 96 个动作，但当前源码枚举和自动报告按 108 action 计算 | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/core/tool-scopes.ts:57-167`，`develop_steps/metis-agent-team-series-14-oapi-action-parity-report-2026-05-15.md` |
| StreamingCardController 管理 idle、creating、streaming、completed、aborted、terminated | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/card/streaming-card-controller.ts:1-11` |
| StreamingCardController 包含 CardKit state、flush、guard、image resolver、reasoning、toolUse、footer metrics | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/card/streaming-card-controller.ts:83-185` |

OpenClaw-Lark 架构图：

```text
OpenClaw-Lark Feishu plugin
  |
  +-- Channel plugin: feishu/lark
  |     |
  |     +-- account config: appId/appSecret/domain/webhook/long_connect/groups/threadSession/uat
  |     +-- capabilities: direct/group/media/reactions/threads/nativeCommands/blockStreaming
  |
  +-- Event handlers
  |     |
  |     +-- app_id ownership / stale / dedup / self echo
  |     +-- message / reaction / card action / drive comment / membership / rich events
  |     +-- queue and abort fast-path
  |
  +-- Dispatch context
  |     |
  |     +-- accountId + peer + thread -> OpenClaw route/session
  |
  +-- Tool client + OAPI registry
  |     |
  |     +-- UAT/TAT decision
  |     +-- app scope / user scope / offline_access
  |     +-- auto-auth card and scope merge
  |
  +-- CardKit streaming reply
        |
        +-- create / patch / finalize / abort / fallback
        +-- reasoning / tool-use / footer metrics / image resolver / flush guard
```

## 5. Metis 当前源码事实

### 5.1 AgentTeam 核心

| 事实 | 源码证据 |
| --- | --- |
| AgentTeam 目标：一个 Gateway runtime 管理多个 named agents，隔离 workspace/model/session | `docs/user/agent-team.md:1-11` |
| 用户入口覆盖 CLI、Telegram、Feishu、Control UI | `docs/user/agent-team.md:48-57` |
| Control UI Teams 支持 team wizard、members、aliases、broadcast、bindings、profiles、model、Feishu readiness/doctor | `docs/user/agent-team.md:140-169` |
| 每个 managed agent 有独立 workspace、`agentDir`、sessions、`models.json`、`auth-profiles.json` 和 profile 文件 | `docs/user/agent-team.md:171-245` |
| Telegram/Feishu account binding 和 team aliases | `docs/user/agent-team.md:246-273` |
| Feishu app/bot 需要用户先在飞书开发者后台创建，Metis 提供配置、status、OAuth、diagnostics | `docs/user/agent-team.md:322-338` |
| agent scope 解析 workspaceDir、agentDir、modelsJsonPath、authProfilesPath、legacyAuthPath、sessionsDir、modelRef、skills/tools/identity/subagents/memory/sandbox | `src/core/config/metis_agent_scope.cj:952-1080` |
| auth profile diagnostics 要求显式复制凭证 | `src/core/config/metis_agent_scope.cj:1083-1134` |
| profile 文件和 `BOOTSTRAP.md` 不自动创建常量 | `src/core/prompting/metis_workspace_bootstrap.cj:8-20` |
| auto-created 文件为 7 个，supported profile 文件为 8 个，`BOOTSTRAP.md` 只支持不自动创建 | `src/core/prompting/metis_workspace_bootstrap.cj:178-200` |
| team template、member agent 创建、binding preflight、binding conflict、team create | `src/gateway/runtime/gateway_server_methods_agents.cj:1886-2177` |
| `agents.files.*`、`agents.models.*`、`agents.teams.*` RPC 注册 | `src/gateway/runtime/gateway_server_methods_agents.cj:3167-3246` |
| route binding 优先级和匹配语义 | `src/gateway/core/gateway_agent_route_resolver.cj:436-545` |
| session key、main session、lastRoute policy、main DM owner guard | `src/gateway/core/gateway_agent_route_resolver.cj:547-632` |
| binding apply 的 scope upgrade、冲突检测和更新 | `src/gateway/core/gateway_agent_route_resolver.cj:759-865` |
| broadcast 读取 `agentTeams.list` 和 legacy `teams` | `src/gateway/core/gateway_agent_team_broadcast.cj:136-171` |
| broadcast 生成多 agent turns 和 aggregate detail | `src/gateway/core/gateway_agent_team_broadcast.cj:451-501`、`:516-582` |

### 5.2 Feishu / OAPI / Card / UI

| 事实 | 源码证据 |
| --- | --- |
| Feishu adapter 处理 card action、reaction、drive comment、bot membership、VC、bitable、message | `src/gateway/channels/feishu/feishu_adapter.cj:619-725` |
| Feishu message type 支持 text/post/image/file/audio/video/media/interactive/merge_forward/sticker 等 | `src/gateway/channels/feishu/feishu_adapter.cj:742-785` |
| bot membership 映射为 system event | `src/gateway/channels/feishu/feishu_adapter.cj:1152-1175` |
| native auth runner 注册 start/status/poll/complete/revoke/revokeOptions | `src/gateway/channels/feishu/feishu_auth.cj:562-588` |
| OAuth start 使用 appId/appSecret/domain，返回 redacted pending/authorized/missing | `src/gateway/channels/feishu/feishu_auth.cj:590-655` |
| OAuth status/poll/complete/revoke 和 live smoke | `src/gateway/channels/feishu/feishu_auth.cj:657-768`、`:770-866`、`:868-910` |
| Gateway RPC 暴露 `channels.feishu.auth.start/status/poll/complete/revoke/liveSmoke` | `src/gateway/runtime/gateway_server_methods_channels.cj:2317-2371` |
| OAPI token provider 支持 user/TAT/bot/app token lookup | `src/gateway/tools/gateway_feishu_oapi_client.cj:619-630` |
| app token 获取、缓存和缺凭证诊断 | `src/gateway/tools/gateway_feishu_oapi_client.cj:633-677` |
| native app token client 支持 tenant/bot/app token endpoint | `src/gateway/tools/gateway_feishu_oapi_client.cj:791-807` |
| OAPI client 返回 auth_required、scope_missing、app_scope_missing、token_mode_unsupported、api_error 等结构化结果 | `src/gateway/tools/gateway_feishu_oapi_client.cj:984-1027` |
| OAPI action tokenMode/path/method 映射 | `src/gateway/tools/gateway_feishu_oapi_client.cj:1310-1395` |
| OAPI parity report 当前：108 action、108 aligned、0 partial、0 missing | `develop_steps/metis-agent-team-series-14-oapi-action-parity-report-2026-05-15.md` |
| streaming card observable state 和 image resolver baseline | `src/gateway/channels/feishu/feishu_cards.cj:464-470`、`:663-703` |
| live event/card/auth smoke 均为 opt-in，不默认访问真实网络 | `src/gateway/channels/feishu/feishu_auth.cj:524-559`、`src/gateway/channels/feishu/feishu_cards.cj:148-173`、`src/gateway/channels/feishu/feishu_adapter.cj:274` |
| Control UI 有 `agents` 主 tab 和 `Teams` 子 tab | `ui/src/ui/navigation.ts:4-24`、`:47-67`，`ui/src/ui/views/agents.ts:29`、`:393-420` |
| Teams 页面包含 workflow、wizard、Feishu setup/repair、list/editor、binding、profile、model、Feishu settings、capabilities、Auth & Doctor | `ui/src/ui/views/agents-panel-teams.ts:86-132` |
| UI profile 文件列表为 8 个 | `ui/src/ui/controllers/agent-teams.ts:123-132` |
| UI per-agent model editor 通过 Gateway 读写 `models.json` | `ui/src/ui/views/agents-panel-teams.ts:1205-1283` |
| UI model provider chips 和 credential source redaction | `ui/src/ui/views/agents-panel-teams.ts:1285-1325` |
| CLI 支持 `metis agents team list|get|create|update|delete` 参数解析 | `src/program/cli_local_flows.cj:372-459` |
| CLI help 展示 team、bind、migrate、add、set-identity 等用法 | `src/program/cli_local_flows.cj:1660-1674` |

Metis 当前架构图：

```text
Metis Gateway runtime
  |
  +-- Gateway RPC / CLI / Control UI
  |     |
  |     +-- agents.* / agents.files.* / agents.models.* / agents.teams.*
  |     +-- channels.feishu.auth.*
  |
  +-- Channel adapters
  |     |
  |     +-- Telegram adapter
  |     +-- Feishu adapter
  |           |
  |           +-- message / card action / reaction / drive comment / membership / VC / bitable
  |
  +-- Route resolver
  |     |
  |     +-- bindings: channel/account/peer/thread/team/roles -> agentId
  |     +-- sessionKey: agent:<agentId>:...
  |     +-- binding apply conflict/scope-upgrade
  |
  +-- Agent scope
  |     |
  |     +-- workspace: ~/.metis/workspaces/<agentId>
  |     +-- agentDir:  ~/.metis/agents/<agentId>/agent
  |     +-- sessions:  ~/.metis/agents/<agentId>/sessions
  |     +-- models.json / auth-profiles.json / AGENTS.md / SOUL.md / TOOLS.md / IDENTITY.md / USER.md / HEARTBEAT.md / MEMORY.md
  |
  +-- Team broadcast
        |
        +-- selected members -> isolated turns -> aggregate response
```

## 6. 当前 GAP 矩阵

| 编号 | 能力 | OpenClaw/OpenClaw-Lark 事实 | Metis 当前状态 | 状态 | GAP | 补齐任务 |
| --- | --- | --- | --- | --- | --- | --- |
| G1 | 多 Agent 隔离 | 独立 workspace/agentDir/sessions/auth profile | 已有同等隔离模型 | aligned | 无核心架构 GAP | 保持回归测试 |
| G2 | `agents/` 目录语义 | `~/.openclaw/agents/<agentId>/agent` 和 sessions | `~/.metis/agents/<agentId>/agent` 和 sessions | aligned | 无核心路径 GAP | 保持 docs/CLI/UI 一致 |
| G3 | profile 文件 | OpenClaw 文档强调 SOUL/AGENTS/USER | Metis 支持 8 个 profile，7 个自动创建，BOOTSTRAP 可手动创建 | aligned | OpenClaw-Lark 页面模板更多 | 增加模板库，不改变隔离语义 |
| G4 | per-agent model | OpenClaw agent entry 支持 model primary/fallbacks | Metis 支持 agent entry model 和 per-agent `models.json` | aligned | UI 仍偏基础 | 后续补模型模板和验证提示 |
| G5 | per-agent auth | OpenClaw 不自动共享主凭证 | Metis diagnostics 要求显式复制 | aligned | 无架构 GAP | 增加手工验收项 |
| G6 | route priority | peer > parent > guild+roles > guild > team > account > channel > default | Metis 实现等价优先级 | aligned | 需要更多 IM live 覆盖 | 加 live Telegram/Feishu route 验收 |
| G7 | binding apply | OpenClaw 用 binding 映射 channel/account/peer/team/roles | Metis 有 apply、scope upgrade、conflict 检查 | aligned | 无核心 GAP | 保持冲突无 partial write 测试 |
| G8 | broadcast/team fan-out | OpenClaw broadcast groups 多 agents | Metis deterministic fan-out + aggregate detail | aligned | Metis 不是 autonomously managed delegation | 明确产品语义，后续若需要做 manager runtime |
| G9 | 飞书 account config | OpenClaw-Lark account 包含 appId/appSecret/domain/connectionMode/webhook/threadSession/uat | Metis 有 Feishu config/status/OAuth/OAPI/doctor 但 UI 不创建开放平台 app | partial | Metis 不能像飞书页面那样“一键创建机器人” | 明确手工创建/关联 app 流程，或设计外部创建向导 |
| G10 | Feishu OAuth/UAT | OpenClaw-Lark tool client + auto-auth card | Metis 有 device flow lifecycle、status、liveSmoke gate | partial | 缺真实租户 UAT 成功/刷新/撤销证据和工具层自动修复闭环 | 做真实 UAT acceptance pack，补 tool-level repair |
| G11 | TAT/app token | OpenClaw-Lark 支持 UAT/TAT 决策 | Metis 当前已支持 user/TAT/bot/app token provider | partial | 需要真实 app token scope 检查和失败恢复记录 | 增加 live TAT/app token smoke 和 redacted report |
| G12 | OAPI action parity | OpenClaw-Lark 当前源码 108 action | Metis parity report：72 aligned、36 partial、0 missing | partial | 36 个 action scope matrix 与 OpenClaw 不一致 | 按 report 逐项修 scope，补 fake tests |
| G13 | auto-auth scope merge | OpenClaw-Lark `auto-auth.ts` 有 debounce、scope merge、AppScopeMissing 卡片 | Metis 有 structured auth/scope/app-scope diagnostics 和 merger tests，但没有完整卡片自动修复闭环 | partial | 用户触发工具时的自动授权/修复体验不如 OpenClaw-Lark | 实现工具层 repair action 和 UI/IM 引导 |
| G14 | rich events | OpenClaw-Lark message/reaction/card/drive/membership/event queue | Metis 覆盖 card/reaction/drive/membership/VC/bitable/message baseline | partial | 真实事件矩阵和历史资源 fetch 仍不足 | 建 live event replay matrix |
| G15 | streaming CardKit | OpenClaw-Lark 有完整 CardKit state/flush/guard/image/footer metrics | Metis 有 streaming controller、observable state、image resolver、live opt-in | partial | CardKit 2 组件、footer metrics、真实卡片更新矩阵不足 | 做 CardKit live smoke 和差异修补 |
| G16 | Miaoda-like 管理 UI | 飞书页面强调一键部署、模板、团队管理、持续培养 | Metis 有 Agents -> Teams 页面和 wizard | partial | 缺模板市场、培养/记忆可视化、权限修复闭环、一键创建/关联飞书 app 的完整体验 | 扩展 Control UI 管理流 |
| G17 | IM 内团队操作 | 飞书页面示例在群里 @运营主管 调度团队 | Metis Telegram/Feishu 主要通过 route/binding/alias/commands 进入 agent | partial | 自然语言创建/管理 team 和 manager dispatch 未产品化 | 增加安全的 IM command/natural-language team ops |
| G18 | 真实验收证据 | OpenClaw-Lark 面向真实飞书生产插件 | Metis 有 opt-in gate 和 fake tests | partial | 真实飞书租户、Telegram bot、Control UI 浏览器验收记录缺失 | 建手工验收包并记录结果 |

## 7. 用户如何启动和使用 AgentTeam

### 7.1 CLI

启动 Gateway：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH"
cjpm run --skip-build --name metis --run-args "gateway run"
```

创建单个 agent：

```bash
metis agents add --agent content-writer --name "Content Writer" --model openai:gpt-4o-mini
metis agents list --json
metis agents summary --json
```

创建团队：

```bash
metis agents team create --team content --name "Content Team" --template pm-writer-reviewer
metis agents team list --json
metis agents team get --team content --json
```

自定义成员、alias、binding：

```bash
metis agents team create \
  --team support \
  --name "Support Team" \
  --member support-triage:triage:"Support Triage" \
  --member support-reply:reply:"Support Reply" \
  --alias '@triage=support-triage' \
  --bind telegram:bot-a \
  --json
```

更复杂的 peer/thread/team/role binding 走 Gateway RPC：

```bash
metis gateway call agents.teams.update '{
  "id":"support",
  "bindings":[
    {
      "type":"route",
      "agentId":"support-triage",
      "match":{"channel":"feishu","accountId":"tenant-a","peer":{"kind":"group","id":"oc_xxx"}}
    }
  ]
}'
```

编辑 workspace profile：

```bash
metis gateway call agents.files.list '{"agentId":"support-triage"}'
metis gateway call agents.files.get '{"agentId":"support-triage","name":"SOUL.md"}'
metis gateway call agents.files.set '{"agentId":"support-triage","name":"SOUL.md","content":"# Soul\n\nHandle triage with concise questions.\n"}'
```

编辑 per-agent model：

```bash
metis gateway call agents.models.get '{"agentId":"support-triage"}'
metis gateway call agents.models.set '{
  "agentId":"support-triage",
  "state":{
    "primaryModelRef":"openai:gpt-4o-mini",
    "runtimePrimaryModelRef":"openai:gpt-4o-mini",
    "providers":[]
  }
}'
```

### 7.2 Control UI

用户操作路径：

1. 启动 Gateway。
2. 打开 Gateway Control UI。
3. 左侧主导航进入 `Agents`。
4. 在 `Agents` 页面顶部选择 `Teams` 子 tab。
5. 在 Team Wizard 中选择模板或自定义成员。
6. 输入 team id、display name、member agentId、role、name。
7. 配置 default member、aliases、broadcast members。
8. 在 Binding 区域输入 `telegram:bot-a`、`feishu:tenant-a` 或结构化 JSON binding。
9. 点击 create/update/save，对应请求通过 Gateway RPC 写入配置。
10. 在 Workspace Profile 区域选择 member 和 `SOUL.md`/`AGENTS.md`/`TOOLS.md` 等 profile 文件，点击 load/save。
11. 在 Model Editor 区域选择 member，加载并保存 per-agent `models.json`。
12. 在 Feishu Setup/Repair 和 Feishu Auth & Doctor 区域查看配置缺口、OAuth 状态、doctor/OAPI/card 诊断。

当前限制：Control UI 不会直接写 `~/.metis` token 文件，不会在浏览器本地保存 Feishu app secret，也不会自动创建飞书开放平台 app/bot。飞书 app/bot 仍需用户在飞书开发者后台创建或授权后，把 appId/appSecret/domain/event subscription 等配置交给 Gateway。

### 7.3 Telegram

用户操作路径：

1. 在 Telegram BotFather 创建或选择一个测试 bot。
2. 在 Metis 配置中启用 Telegram channel 和 account。
3. 用 `metis agents bind --agent <agentId> --bind telegram:<accountId>` 或 `agents.teams.*` structured binding 绑定到 agent/team member。
4. 在 Telegram 私聊、群、topic 中发送消息。
5. Gateway 根据 `channel=telegram`、`accountId`、peer/topic route 到指定 agent/session。
6. `/focus`、`/unfocus`、`/agents`、`/subagents` 等原有 Telegram native command 继续走同一 Gateway route/session。

当前限制：Telegram 内暂不作为完整 team CRUD 管理入口。也就是说，用户不应期待在 Telegram 里自然语言创建所有 team/members/models/profiles；当前更稳定的管理入口是 CLI 和 Control UI。

### 7.4 Feishu

用户操作路径：

1. 在飞书开发者后台创建或选择测试 app，启用 bot、事件订阅、所需 scopes。
2. 在 Metis 配置中启用 Feishu account，填入 appId/appSecret/domain/connectionMode/webhook 或长连接配置。
3. 启动 Gateway。
4. 在 Feishu 对话中使用 `/feishu start` 验证插件/通道状态。
5. 使用 `/feishu doctor` 查看本地配置、权限和事件订阅诊断。
6. 使用 `/feishu auth` 或 Control UI Feishu Auth 面板启动用户授权。
7. 用 `metis agents bind --agent <agentId> --bind feishu:<accountId>` 或 structured binding 绑定 Feishu group/thread 到 agent/team member。
8. 在飞书群内 @ 对应机器人或按 group policy 发送消息。
9. Gateway 根据 accountId、peer、thread route 到指定 agent/session；若 broadcast enabled，则 fan-out 到 selected members。

当前限制：Metis 不能在创建 AgentTeam 时自动创建真实飞书 bot/app 并完成飞书开放平台配置。可以做的是提供步骤、检测、状态、OAuth/OAPI/card/live smoke 和 redacted diagnostics。

## 8. 分阶段补齐方案

### Phase 0：证据冻结与回归门禁

目标：把当前源码事实、历史进展和过期结论修正固化，避免后续重复按旧 GAP 开发。

实施项：

- 固化 series14 文档。
- 更新手工验收模板引用到 series14。
- 将 OAPI parity report 纳入手工 gate。
- 对 `docs/user/agent-team.md` 中过期的 “TAT/app token parity remains gate” 说法做后续修正计划。

验收项：

- `develop_steps/metis-agent-team-series-14-current-source-recheck-gap-quantification-manual-acceptance-2026-05-15.md` 存在。
- 文档中明确当前 `tenant_access_token`、`bot_access_token`、`app_access_token` 已支持。
- `git diff --check` 通过。
- 不修改真实 `~/.metis`、Telegram token、Feishu token、app secret。

工作量：0.5 人日。

### Phase 1：真实测试环境准备和证据包

目标：把 fake-tested 和真实生产验收分开，建立可复现的 Telegram/Feishu 手工验收目录。

实施项：

- 新增或更新 redacted runbook，记录测试日期、Metis commit、Gateway 配置摘要、Telegram test bot、Feishu test app、test tenant、test user、test group、已开通 scopes。
- 本轮模板文件：`develop_steps/metis-agent-team-series-14-manual-acceptance-runbook-2026-05-15.md`。
- 所有 live test 默认 opt-in；未设置 opt-in 时必须生成 skipped report。
- 明确 `METIS_HOME=/tmp/...` 和 report dir，禁止写真实 home。

验收项：

- `scripts/agentteam-manual-acceptance-gate.sh` 在隔离 `METIS_HOME` 下通过。
- Feishu live auth smoke 未 opt-in 时返回 `skipped` 并写 redacted report。
- Telegram/Feishu live 项目没有真实 secret 出现在报告、日志、文档。

工作量：0.5-1 人日。需要用户提供测试 Telegram bot 和测试 Feishu app/tenant。

### Phase 2：OAPI 108 action scope-exact closure

目标：关闭 parity report 中原有 36 个 `partial` action。

实施项：

- 以 `develop_steps/metis-agent-team-series-13-oapi-action-parity-report-2026-05-15.md` 为历史输入，逐项核对 OpenClaw-Lark `src/core/tool-scopes.ts`。
- 更新 Metis `feishuOapiRequiredScopesForActionKey` 对应 scope。
- 补 fake tests：path、method、tokenMode、requiredScopes、structured auth/scope/app-scope diagnostics。
- 重新生成 `develop_steps/metis-agent-team-series-14-oapi-action-parity-report-2026-05-15.md`。

验收项：

- parity report 从 `72 aligned / 36 partial / 0 missing` 变为目标 `108 aligned / 0 partial / 0 missing`，或者每个非 aligned 行有明确 not-applicable 代码理由。当前 series14 报告已达到 `108 aligned / 0 partial / 0 missing`。
- `cjpm test src/gateway/tools --filter GatewayFeishuOapiToolsetTest --no-color` 通过。
- 结构化错误中不包含 access token、refresh token、Authorization header。

工作量：已完成；后续新增 action 时按报告和测试同步维护，预计 0.5 人日/轮。

### Phase 3：Feishu OAuth/UAT/TAT/app-scope 真实闭环

目标：让真实 Feishu user/app/tenant token 生命周期可验收。

实施项：

- 在测试租户中验证 user OAuth start/status/poll/complete/refresh/revoke。
- 验证 `tenant_access_token`、`bot_access_token`、`app_access_token` token lookup。
- 对 app-scope 缺失、user-scope 缺失、offline_access 缺失分别生成 redacted diagnostics。
- 补 UI/IM 的 repair 文案和 operator step。

验收项：

- `channels.feishu.auth.liveSmoke` 在 opt-in 下有完整 redacted report。
- 至少一条 UAT OAPI、一个 TAT action、一个 app token action 真实通过。
- app scope 缺失时返回 `app_scope_missing`，user scope 缺失时返回 `scope_missing`，未授权时返回 `auth_required`。
- 报告不保存 device code、appSecret、accessToken、refreshToken。

工作量：1.5-2 人日。需要用户提供测试 Feishu app credentials、test user、test tenant、可授权 scopes。

### Phase 4：工具层自动授权和 scope merge

目标：对齐 OpenClaw-Lark `auto-auth.ts` 的用户体验：工具触发权限缺口时，系统主动引导修复，而不是只把 JSON 返回给模型。

实施项：

- 为 Metis OAPI toolset 增加可注入的 auth repair runner。
- 当工具返回 `auth_required`、`scope_missing`、`app_scope_missing` 时生成统一 repair action。
- 同一 turn 内合并 scopes，避免重复发起多个授权卡片/提示。
- Control UI Feishu Auth & Doctor 显示最近 repair action 和 merged scopes。

验收项：

- fake test 覆盖同一 turn 多个 scope merge。
- Feishu/Control UI repair action 不暴露 token 和 secret。
- 未配置 ticket/chat 上下文时降级为 structured diagnostics。

工作量：1.5-2 人日。

### Phase 5：Feishu CardKit streaming parity

目标：把 Metis streaming card 从 baseline 提升到接近 OpenClaw-Lark CardKit 体验。

实施项：

- 建立 CardKit live smoke：create、stream patch、final update、abort、message unavailable、image resolver。
- 对 footer metrics 增加 input/output/cache/model/context 的可选显示。
- 对 long text、markdown table、image key replacement、rate limit fallback 建立 fixture。
- Control UI/doctor 展示 card readiness。

验收项：

- fake card tests 覆盖 create/stream/final/abort/fallback。
- live card test 在测试群里成功更新同一张卡片。
- 若 CardKit API 不可用，返回明确 fallback，不造成空回复。

工作量：1.5-2 人日。

### Phase 6：rich events 与历史资源

目标：补齐飞书事件类型和资源读取能力，使 AgentTeam route 能覆盖真实群聊/文档评论/资源消息。

实施项：

- 扩展 event replay fixtures：message、post、image、file、audio、video、interactive、reaction、drive comment、bot membership、VC、bitable。
- 对每类事件记录 accountId、peerId、threadId、systemEventKind、dedup key。
- 补历史消息/资源 fetch 的 auth-required、scope-missing、success fake cases。
- live replay 仍用 opt-in。

验收项：

- 每类 redacted fixture 有 fake replay test。
- 重复事件不会重复入队。
- threadSession 打开时，同一 group 下不同 thread 生成不同 session key。
- 未授权资源下载返回 `auth_required` 或 `scope_missing`，不报模糊错误。

工作量：1-1.5 人日。

### Phase 7：Miaoda-like Control UI 管理体验

目标：让普通用户可以通过网页完成大多数 AgentTeam 管理动作。

实施项：

- Teams 页面增加模板库分组：内容、研发、客服、数据、运营。
- 增加成员详情页：profile、model、bindings、auth、status、recent sessions。
- 增加 Feishu app setup checklist：开发者后台步骤、event URL、required scopes、test message。
- 增加“关联已有 Feishu app/bot”流程；不承诺自动创建 app。
- 增加 team health summary：routing conflicts、missing profiles、missing model、missing auth、Feishu readiness。

验收项：

- 浏览器 smoke 可进入 Agents -> Teams 并创建/编辑团队。
- 页面不保存 secret 到 localStorage/sessionStorage。
- 所有写操作走 Gateway RPC。
- UI 展示的 Feishu setup step 与 `/feishu doctor`/Gateway status 一致。

工作量：2-3 人日。

### Phase 8：IM 内团队调度体验

目标：在 Telegram/Feishu 内给用户可理解、可控的 team 使用方式。

实施项：

- 增加安全的 team command，例如 `/agents team`、`/agents switch <alias>`、`/agents status`。
- 支持 alias 触发：`@writer`、`/agent writer` route 到指定 member。
- 对 manager agent 给出明确语义：当前是普通 member/defaultAgent，不是 autonomous manager runtime。
- 后续若要自动 manager delegation，先补设计文档再实现。

验收项：

- Telegram 群/topic alias route 到正确 member/session。
- Feishu 群/thread alias route 到正确 member/session。
- 未命中 alias 时走 default member 或正常 default agent。
- 用户不会看到裸 session key 或内部 routing JSON。

工作量：1-1.5 人日。

### Phase 9：发布级验证和文档收口

目标：把代码、测试、浏览器、手工验收和文档统一到可提交状态。

实施项：

- 运行 `cjpm clean && cjpm build -i && cjpm test`。
- 运行 `npm --prefix ui test && npm --prefix ui run build`。
- 运行 `scripts/agentteam-manual-acceptance-gate.sh`。
- 有 Control UI 改动时跑真实浏览器 smoke。
- 更新 `docs/user/agent-team.md` 当前限制，删除过期 TAT/app-token 描述。
- 本 worker 不跑全量 `cjpm clean/build/test`，由主工作区统一执行；本 worker 只跑手工 gate 和 `git diff --check`。

验收项：

- Cangjie build/test 通过。
- UI test/build 通过。
- `git diff --check` 通过。
- 手工验收表有实际结果、日期、commit、操作者、跳过原因。
- 本地提交包含源码、测试、文档和生成资产。

工作量：0.5-1 人日。

## 9. 手工验收清单

所有手工验收必须使用隔离环境：

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH"
export METIS_HOME="/tmp/metis-agentteam-manual-acceptance"
```

| 编号 | 手工验收条目 | 操作方法 | 验收标准 |
| --- | --- | --- | --- |
| M1 | Gateway 启动 | `cjpm run --skip-build --name metis --run-args "gateway run"` | Gateway 进程启动，无 panic；`metis gateway health` 返回健康 |
| M2 | agent 创建 | `metis agents add --agent qa-writer --name "QA Writer" --model openai:gpt-4o-mini --json` | 输出包含 agentId、workspace、agentDir、sessions；目录在隔离 `METIS_HOME` 下 |
| M3 | profile 自动创建 | `metis gateway call agents.files.list '{"agentId":"qa-writer"}'` | `AGENTS.md`、`SOUL.md`、`TOOLS.md`、`IDENTITY.md`、`USER.md`、`HEARTBEAT.md`、`MEMORY.md` present；`BOOTSTRAP.md` supported but missing |
| M4 | profile 编辑 | 写入 `SOUL.md` 再读取 | 读取内容等于写入内容；不能越权写 `../`、绝对路径、`~` |
| M5 | per-agent model | `agents.models.get/set` 设置 `primaryModelRef` | 只写 selected agent 的 `models.json`；另一个 agent 不受影响 |
| M6 | team 创建 | `metis agents team create --team qa --template pm-writer-reviewer --json` | 创建 3 个 member agents；team list 可见；defaultAgentId 合法 |
| M7 | team update | 修改 displayName、aliases、broadcast members | `agents.teams.get` 返回更新后的 aliases/broadcast；重复 member 被过滤或拒绝 |
| M8 | binding conflict | 给两个 agent 绑定同一 `telegram:bot-a` | 第二次写入返回 conflict；配置不发生 partial write |
| M9 | route priority | 用 structured binding 配 peer/account/channel 三层 | exact peer 优先于 account/channel；sessionKey 中 agentId 正确 |
| M10 | broadcast aggregate | 开启 broadcast，选择两个 members，发送一次 fake request | aggregate 包含每个 member 的 status/detail/answer/deliveredCount；顺序稳定 |
| M11 | Control UI 入口 | 打开 Control UI，左侧点击 `Agents`，顶部点击 `Teams` | 页面显示 team wizard/list/editor/profile/model/Feishu panels；无 JS page error |
| M12 | Control UI 创建 team | 在 Teams 页面输入 team id、members、alias、binding，点击 create | Gateway config 更新；刷新页面后 team 仍存在 |
| M13 | Control UI profile 保存 | 在 Workspace Profile 选择 member 和 `SOUL.md`，保存 | 保存成功；文件在对应 member workspace；浏览器不直接写本地文件 |
| M14 | Control UI model 保存 | 在 Model Editor 设置 model ref，保存 | `agents.models.get` 返回新 model；credential source 被 redacted |
| M15 | Telegram route | 配置测试 bot 和 `telegram:<accountId>` binding，群/topic 发消息 | Gateway log 有 `channel=telegram` inbound；回复来自绑定 agent；sessionKey 对应 topic/group |
| M16 | Telegram alias | 在绑定群中发送 `@writer ...` 或 `/agent writer ...` | route 到 writer member；未命中 alias 时走 default member |
| M17 | Feishu app 配置 | 在飞书开发者后台创建测试 app/bot，配置 appId/appSecret/domain/event | `/feishu start` 或 Gateway status 显示 account configured；无 secret 明文日志 |
| M18 | Feishu OAuth 未配置 | 不配置 appSecret 调用 `channels.feishu.auth.start` | 返回 `missing_app_credentials`，redacted=true |
| M19 | Feishu OAuth live smoke skipped | 不设置 `METIS_FEISHU_LIVE_AUTH_SMOKE` 调用 liveSmoke | 返回 `skipped`；生成 redacted report；无网络调用 |
| M20 | Feishu OAuth live | 设置 `METIS_FEISHU_LIVE_AUTH_SMOKE=1` 和 test app | start/status/poll/complete/revoke 有 redacted fixtures；用户授权成功或失败原因明确 |
| M21 | Feishu OAPI UAT | 调用一个需要 user token 的 docs/search action | 已授权时 success；未授权时 `auth_required`；scope 不足时 `scope_missing` |
| M22 | Feishu OAPI TAT/app token | 调用一个 tenant/app token action | token lookup 不返回 `token_mode_unsupported`；缺凭证时 `missing_credential` |
| M23 | Feishu app scope 缺失 | 故意缺少一个 app scope 调用 OAPI | 返回 `app_scope_missing`，包含 missingScopes，不含 appSecret/token |
| M24 | Feishu rich event replay | 用 redacted fixtures replay message/reaction/card/drive/membership | 每类事件入队或 ignored reason 符合预期；重复事件 dedup |
| M25 | Feishu thread session | 在 topic/thread 群启用 threadSession 后发两条不同 thread 消息 | sessionKey 按 thread 隔离；不会串上下文 |
| M26 | Streaming card | 在测试飞书群启用 streaming/card opt-in | 创建/更新/完成同一张卡；不可用时有 fallback 文本 |
| M27 | Secret redaction | 检查日志、report、Control UI 状态 | 不出现 appSecret、accessToken、refreshToken、Authorization、Telegram bot token |
| M28 | 手工 gate | `METIS_HOME=/tmp/metis-agentteam-manual-acceptance scripts/agentteam-manual-acceptance-gate.sh` | gate 通过；若未设置 live opt-in，明确显示 skipped |
| M29 | 全量验证 | `cjpm clean && cjpm build -i && cjpm test` | Cangjie build/test 通过 |
| M30 | UI 验证 | `npm --prefix ui test && npm --prefix ui run build`，再浏览器 smoke | UI test/build 通过；`customElements.get("metis-app")` 注册；Agents -> Teams 可见 |

## 10. 需要用户补充的真实资源

为了完成 Phase 1、3、5、6、8 的真实验收，需要用户提供或准备以下测试资源：

| 资源 | 用途 | 要求 |
| --- | --- | --- |
| Telegram 测试 bot token | 验证 Telegram account route、group/topic、alias | 只能用测试 bot，不用生产 bot |
| Telegram 测试私聊/群/topic | 验证 direct/group/topic session | 允许记录 chat id/topic id，但不能记录 token |
| Feishu 测试 appId/appSecret | OAuth、OAPI、card/event live | 只能用测试 app；appSecret 不写入文档 |
| Feishu 测试租户 | 安装/授权 app | 不用生产租户，或明确接受风险 |
| Feishu 测试用户 open_id | UAT/OAuth | 用户可以完成 device flow 授权 |
| Feishu 测试群 chat_id/thread | group/thread route、card、rich events | 群内可以添加测试 bot |
| Feishu scopes 列表 | OAPI action validation | 至少覆盖消息、文档、搜索、日历/任务任选一类 |
| 模型 provider 测试 key | per-agent model 验收 | 放在测试环境或显式 agent auth profile，不写 profile markdown |

## 11. 风险和边界

- Metis 不应突破现有 Gateway/channel/session/agent-scope 架构边界。Telegram/Feishu 都应作为 ChannelAdapter 进入统一 route resolver。
- Control UI 是 Gateway RPC client，不能直接编辑本机 token 文件或 secret 文件。
- 自动创建真实飞书 app/bot 不是当前 Metis 能力。即使后续做，也必须通过飞书开放平台授权 API/用户确认，不能伪造“自动完成”。
- 当前 manager 语义是普通 member/defaultAgent + profile 指令，不是独立 autonomous manager runtime。
- OAPI action parity 当前是 action-level path/method/scope/tokenMode 对齐，不等于逐 action 参数 transformer 全量克隆。
- live smoke 必须 opt-in，报告必须 redacted，测试必须使用隔离 `METIS_HOME`。

## 12. 下一步建议

建议下一轮按优先级执行：

1. Phase 2：先把 OAPI 36 个 scope partial 行清零。这是最确定、最小外部依赖、收益最高的源码差距。
2. Phase 3：用测试飞书 app 做 OAuth/UAT/TAT/app token 真实闭环。这需要用户提供测试资源。
3. Phase 7：把 Control UI Teams 页面从“可用管理面板”推进到“Miaoda-like 管理入口”，但仍不承诺自动创建飞书 app。
4. Phase 5/6：补 CardKit/rich events live matrix，作为飞书生产体验验收门。
