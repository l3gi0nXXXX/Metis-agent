# Metis Agent Team Series 07: Source Recheck, GAP, Quantification, and Landing Plan

Date: 2026-05-14

## 1. Scope and Evidence Rule

This document is a source-backed recheck of the AgentTeam requirement after the latest Metis implementation work.

Evidence inputs:

- Feishu public article: `https://www.feishu.cn/content/article/7613711414611463386`
- OpenClaw core source: `/Users/l3gi0n/work/workspace_cangjie/openclaw`
- OpenClaw Feishu/Lark plugin source: `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark`
- Metis current source: `/Users/l3gi0n/work/workspace_cangjie/Metis`

Rules:

- Every GAP below must have source evidence. A behavior that was not verified from source is not written as a conclusion.
- The plan keeps Metis changes inside existing architecture boundaries: Cangjie config/scope, Gateway route/session, ChannelAdapter, Gateway tools, Gateway RPC, Control UI, tests, and docs.
- This document does not change code or configuration.
- All future tests for these phases must use fake clients, injected runners, and temporary Metis homes. They must not use real Telegram/Feishu tokens, real Feishu network, or real files under `~/.metis`.

Important correction from `series-06`: that older document was accurate for the then-observed state, but current source has moved. Metis now has Feishu account override resolution, Feishu auth/device-flow skeleton, Feishu OAPI placeholder tools, interactive card send/patch skeleton, card action system events, and AgentTeam broadcast execution. The current GAP matrix below supersedes the stale rows in `series-06`.

## 2. Web Evidence: Feishu OpenClaw Agent Team Product

The Feishu article describes the official OpenClaw Feishu plugin as a Feishu workspace connector, not only as an IM text adapter.

Verified article-level facts:

- It introduces the official Feishu OpenClaw plugin and says it connects OpenClaw agents with Feishu workspace scenarios.
- It lists Feishu data/tool surfaces beyond chat: docs/wiki, bitable, calendar, tasks, and workplace messages.
- It shows multiple-bot/multiple-agent deployment examples where one deployment can host multiple isolated agents.
- It describes agent-specific files under agent directories, including examples such as `.openclaw/agents/<agent>/agent/AGENTS.md` and `.openclaw/agents/<agent>/workspace/AGENTS.md`.
- It shows Feishu-native commands such as `/feishu start`, `/feishu doctor`, `/feishu auth`, and `openclaw feishu info --all`.
- It mentions thread session behavior through `threadSession: true`.
- It shows group-level settings such as `requireMention`, `skills`, `systemPrompt`, and `tools`.
- It shows streaming/card-style replies and tool-use visibility as part of the Feishu experience.

Implication: Metis parity cannot be measured only by "one Gateway can route a Feishu message to an agent". Meaningful parity also includes per-account Feishu config, group policy, thread sessions, OAuth, OAPI tools, media/resource handling, cards/streaming, and a manageable AgentTeam UI.

## 3. OpenClaw / OpenClaw-Lark Architecture

### 3.1 OpenClaw Core AgentTeam Architecture

```text
Control UI / CLI / Channel Plugin
        |
        v
OpenClaw Gateway
        |
        v
Route Resolver
  input: channel, accountId, peer, parentPeer, guildId, teamId, roles
  output: agentId, accountId, sessionKey, mainSessionKey, matchedBy
        |
        v
Agent Scope
  agents.list[] / agents.defaults
  workspace / agentDir / sessions
  model / skills / tools / memorySearch / groupChat / subagents / sandbox
        |
        +-----------------------------+
        |                             |
        v                             v
Per-Agent Workspace             Per-Agent State
  AGENTS.md                       auth-profiles.json
  SOUL.md                         models.json
  TOOLS.md                        sessions/
  IDENTITY.md
  USER.md
  HEARTBEAT.md
  BOOTSTRAP.md
  MEMORY.md
```

Source facts:

| Area | Evidence | Meaning |
| --- | --- | --- |
| One agent boundary | `/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/concepts/multi-agent.md:10-18` | One agent has separate workspace, `agentDir`, and sessions. |
| Auth isolation | `/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/concepts/multi-agent.md:20-37` | Each agent reads its own `auth-profiles.json`; main credentials are not shared automatically. |
| Skill isolation | `/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/concepts/multi-agent.md:39-44` | Skills load from agent workspace plus shared roots, then are filtered by the effective agent allowlist. |
| Default paths | `/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/concepts/multi-agent.md:53-68` | Default workspace/state/session path conventions. |
| Binding priority | `/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/concepts/multi-agent.md:227-247` | Most-specific binding wins; omitted `accountId` means default account; `*` means channel-wide fallback; apply can upgrade a channel-only binding to account-scoped. |
| Account concept | `/Users/l3gi0n/work/workspace_cangjie/openclaw/docs/concepts/multi-agent.md:249-270` | `accountId` is a channel account instance; Feishu is listed as a multi-account-capable channel. |
| Scope schema | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/agent-scope.ts:35-53`, `:129-159` | Agent entries carry model, skills, memorySearch, heartbeat, identity, groupChat, subagents, sandbox, and tools. |
| Workspace file set | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/workspace.ts:24-33` | OpenClaw workspace bootstrap set includes AGENTS/SOUL/TOOLS/IDENTITY/USER/HEARTBEAT/BOOTSTRAP/MEMORY. |
| Boundary-safe workspace read | `/Users/l3gi0n/work/workspace_cangjie/openclaw/src/agents/workspace.ts:56-88` | Workspace file reads are guarded by workspace root and max bytes. |

### 3.2 OpenClaw-Lark Feishu Architecture

```text
Feishu / Lark Platform
  webhook / websocket / card.action.trigger / OAPI
        |
        v
openclaw-lark Channel Plugin
  channel: feishu
  capabilities: direct, group, media, reactions, threads, native commands, block streaming
        |
        +-----------------------------+
        |                             |
        v                             v
Account Config                  Inbound Pipeline
  channels.feishu                 accountScopedCfg
  channels.feishu.accounts        message parse/gate/media/quote
  per-account override merge      resolveAgentRoute(channel=feishu, accountId)
                                  threadSessionKey
        |
        +-----------------------------+
        |                             |
        v                             v
OAuth / Token / Scope            Feishu OAPI Tools
  device authorization              docs/wiki/drive/search
  UAT token store                   bitable/calendar/task/sheets
  app/user scope checks             chat/user/im/resource
        |
        v
Outbound Feishu UX
  static text/card
  streaming card
  tool-use display
  interactive card actions
```

Source facts:

| Area | Evidence | Meaning |
| --- | --- | --- |
| Plugin contract | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/openclaw.plugin.json:1-64` | Plugin id is `openclaw-lark`, channel is `feishu`, and the Feishu tool contract includes docs/wiki/drive/search/bitable/calendar/task/sheets/chat/user/im/OAuth/resource tools. |
| Config schema | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/core/config-schema.ts:141-151`, `:157-209` | Group config includes tools, skills, systemPrompt, allowFrom, allowBots; account config includes accounts, streaming, threadSession, footer, UAT, and OAPI flags. |
| Multi-account merge | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/core/accounts.ts:7-9`, `:45-69`, `:85-112`, `:121-183`, `:198-223` | Account overrides live under `channels.feishu.accounts`; downstream helpers can use account-scoped config. |
| Inbound route context | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/messaging/inbound/dispatch-context.ts:27-45`, `:102-135` | Dispatch context resolves Feishu route through core routing with channel `feishu` and account id. |
| Thread sessions | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/messaging/inbound/dispatch-context.ts:161-201` | `threadSession` requires group thread capability, checked through Feishu chat info cache. |
| OAuth device flow | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/core/device-flow.ts:95-163`, `:192-280` | Device auth requests `offline_access`, polls token endpoint, and handles pending/slow_down/denied/expired states. |
| Token store | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/core/token-store.ts:5-18`, `:87-180` | UAT is persisted through OS credential service on macOS or encrypted files on Linux/Windows. |
| Scope-aware tool client | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/core/tool-client.ts:139-250`, `:317-390` | OAPI invocation chooses tenant/user identity, checks app/user scopes, and returns structured auth/scope failures. |
| OAPI tool registration | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/tools/oapi/index.ts:46-95` | Registers Feishu common/chat/im/calendar/task/bitable/search/drive/wiki/sheets tools. |
| Reply dispatcher | `/Users/l3gi0n/work/workspace_cangjie/openclaw-lark/src/card/reply-dispatcher.ts:40-103`, `:194-246` | Per-account reply mode chooses static/streaming cards and routes tool payloads to streaming card controller. |

## 4. Metis Current Architecture

```text
Control UI / CLI / Telegram / Feishu
        |
        v
Metis Gateway
  Gateway RPC for CLI and Control UI
  ChannelManager / native ChannelAdapter for IM channels
        |
        v
Gateway Route Resolver
  channel, accountId, peer, parentPeer, guildId, teamId, roles
  binding apply/update/conflict checks
        |
        v
Gateway IM Route Session Context
  agentId
  workspaceDir
  agentDir
  modelsJsonPath
  authProfilesPath
  sessionsDir
  sessionKey / mainSessionKey
        |
        +-----------------------------+
        |                             |
        v                             v
Gateway Agent Bridge             AgentTeam Broadcast Planner
  tool inventory                  selected team-member fanout
  runtime tool policy             per-member isolated route/session/context
  workspace bootstrap prompt
  per-agent model/auth paths
        |
        +-----------------------------+
        |                             |
        v                             v
Native Telegram Adapter          Native Feishu Adapter
  mature IM route/media path       account resolver
                                  webhook/long-connect input
                                  group gate and policy context
                                  thread route context
                                  current-turn media
                                  native commands
                                  card send/patch skeleton
                                  OAPI placeholder tools
```

Metis source facts:

| Area | Evidence | Current meaning |
| --- | --- | --- |
| User-facing AgentTeam docs | `docs/user/agent-team.md:1-20`, `:41-60`, `:108-158`, `:162-187` | Metis documents multiple agents, separate workspace/agentDir/sessions/models/auth, and Telegram/Feishu binding. |
| Workspace file set | `src/core/prompting/metis_workspace_bootstrap.cj:8-20`, `:178-201`, `:203-232` | Metis supports AGENTS/SOUL/TOOLS/IDENTITY/USER/HEARTBEAT/BOOTSTRAP/MEMORY; BOOTSTRAP is supported but not auto-created. |
| Safe workspace IO | `src/core/prompting/metis_workspace_bootstrap.cj:135-164`, `:234-280` | Rejects absolute paths, `~`, URI schemes, traversal, symlink escape, and outside-root writes. |
| Agent add/update/files/models RPC | `src/gateway/runtime/gateway_server_methods_agents.cj:1226-1298`, `:1469-1582`, `:1678-1730` | Gateway can create agents, bootstrap workspace, list/get/set files, and get/set per-agent `models.json`. |
| Team CRUD | `src/gateway/runtime/gateway_server_methods_agents.cj:1814-1988`, `:1998-2079` | Supports built-in template, member bootstrap, aliases, bindings, conflict preflight, and broadcast field persistence. |
| Route session context | `src/gateway/core/gateway_im_route_session_context.cj:14-23`, `:43-108` | Route policy fields are merged into turn context; turn context carries agent workspace, agentDir, models/auth paths, session, and route. |
| Team broadcast runtime | `src/gateway/core/gateway_agent_team_broadcast.cj:8-45`, `:156-171`, `:258-307`, `:317-400`, `:403-501`; `src/gateway/core/gateway_service.cj:261-292` | Broadcast can fan out one inbound request to selected team member agents with isolated sessions and scopes. |
| Broadcast tests | `src/gateway/core/gateway_agent_team_broadcast_test.cj:189-262`; `src/gateway/core/gateway_service_feishu_native_test.cj:365-395` | Tests verify disabled fallback, selected-member fanout, isolated workspace/model/tool scopes, and Feishu service delivery of selected members. |
| Feishu account resolver | `src/gateway/channels/feishu/feishu_accounts.cj:9-20`, `:23-52`, `:52-107`, `:109-140` | Metis resolves default/explicit Feishu accounts, merges account overrides, and exposes redacted account descriptions. |
| Feishu adapter API | `src/gateway/channels/feishu/feishu_adapter.cj:32-38`, `:65-108`, `:110-223` | Feishu API client interface covers thread-capable check, resource fetch, text send, interactive card send, and card patch; fake/noop clients exist. |
| Feishu outbound text/card | `src/gateway/channels/feishu/feishu_adapter.cj:351-370`, `:389-435` | Normal Gateway outbound sends text; card send/patch has adapter hooks and text fallback. |
| Feishu event dispatch | `src/gateway/channels/feishu/feishu_adapter.cj:450-504`, `:506-590`, `:708-783` | Accepts URL verification, card actions as system events, and `im.message.receive_v1` text-bearing messages. Unsupported event types are ignored. |
| Feishu route/group/thread context | `src/gateway/channels/feishu/feishu_adapter.cj:785-843`, `:845-950` | Maps group/direct/thread route context and group policy fields including tools/skills/systemPrompt/runtimePolicy into media context. |
| Feishu native commands | `src/gateway/core/gateway_service.cj:468-614` | `/feishu start/doctor/auth/info/help` exist and are sent as text replies; `/feishu auth` can use injected auth runner and redacts secrets. |
| Feishu auth skeleton | `src/gateway/channels/feishu/feishu_auth.cj:8-65`, `:67-186`, `:188-283` | Device authorization result, token result, device flow client, token model, and file token store exist. |
| Feishu media tools | `src/gateway/tools/gateway_feishu_media_toolset.cj:33-47`, `:97-127`, `:129-166` | Current-turn media list/fetch tools exist and only read staged media context. |
| Feishu OAPI placeholder tools | `src/gateway/tools/gateway_feishu_oapi_toolset.cj:10-15`, `:25-78`, `:120-178`, `:184-240`; `src/gateway/tools/gateway_feishu_oapi_toolset_test.cj:7-84` | OpenClaw-compatible tool names/categories/scopes exist, but default runtime returns structured `auth_required`; fake runner tests exist. |
| Control UI team panel | `ui/src/ui/views/agents-panel-teams.ts:75-113`, `:116-220` | Control UI has teams list/editor, binding/profile/model/Feishu settings/doctor sections, but it is not yet a full Miaoda-style management workspace. |

## 5. Current GAP Matrix

Status values:

- `aligned`: Metis source matches the verified OpenClaw/OpenClaw-Lark behavior closely enough.
- `partial`: Metis has a source-backed subset or skeleton, but not full parity.
- `missing`: no verified Metis implementation exists for the user-visible capability.
- `not-applicable`: verified OpenClaw behavior is intentionally outside the Metis scope.

| ID | Capability | OpenClaw / OpenClaw-Lark evidence | Metis evidence | Status | Exact GAP | Implementation task | Acceptance items |
| --- | --- | --- | --- | --- | --- | --- | --- |
| AT-01 | One deployment hosts multiple isolated agents | `openclaw/docs/concepts/multi-agent.md:10-18`, `:53-68` | `docs/user/agent-team.md:1-20`; `src/gateway/runtime/gateway_server_methods_agents.cj:1226-1298` | aligned | No core isolation gap found. | Keep current Metis path model. | Existing temp-home tests continue proving separate workspace/agentDir/sessions. |
| AT-02 | Per-agent workspace bootstrap files | `openclaw/src/agents/workspace.ts:24-33` | `src/core/prompting/metis_workspace_bootstrap.cj:8-20`, `:178-201`, `:203-232` | aligned | Metis intentionally does not auto-create `BOOTSTRAP.md`, but supports it as an explicit file. This is documented and source-backed. | Keep no-auto-create rule unless product owner explicitly asks to change semantics. | `agents.files.list` includes BOOTSTRAP as supported/missing; `ensureMetisAgentWorkspace` does not create it. |
| AT-03 | Workspace boundary-safe file read/write | `openclaw/src/agents/workspace.ts:56-88` | `src/core/prompting/metis_workspace_bootstrap.cj:135-164`, `:234-280`; `gateway_server_methods_agents_test.cj:969-1037` | aligned | No safety gap found in current AgentTeam workspace file RPC. | Keep safety tests whenever profile files/UI are changed. | Traversal read/write fails; original agent workspace file remains unchanged. |
| AT-04 | Per-agent `models.json` and auth profile isolation | `openclaw/docs/concepts/multi-agent.md:20-37`; `openclaw/src/agents/agent-scope.ts:129-159` | `docs/user/agent-team.md:149-158`; `gateway_server_methods_agents_test.cj:1040-1178` | partial | Metis can manage per-agent `models.json` and reports credential source without implicit main-auth copy, but runtime/diagnostic coverage must continue proving no accidental fallback after recent model-runtime changes. | Add/keep regression tests where two agents have different `models.json` and auth profiles; Gateway request must use the selected agent's paths. | Fake provider observes the selected agent's model/auth path; another agent's credentials never appear in logs/result. |
| AT-05 | Binding route semantics and `accountId` semantics | `openclaw/docs/concepts/multi-agent.md:227-247`, `:249-270` | `src/gateway/core/gateway_agent_route_resolver.cj:341-559`, `:797-865`; `gateway_server_methods_agents_test.cj:687-769` | aligned | No source-backed routing priority gap found. | Preserve resolver tier order and binding apply semantics. | Tests cover omitted account, explicit default, wildcard, peer/thread/parent/account/channel priority, and conflicts. |
| AT-06 | Team CRUD and managed members | OpenClaw exposes core agent management; Feishu product adds team UX | `src/gateway/runtime/gateway_server_methods_agents.cj:1814-1988`, `:1998-2079`; `gateway_server_methods_agents_test.cj:1180-1405` | partial | Metis has CRUD and one template. It lacks a rich template library and Miaoda-like assisted team creation workflow. | Expand templates only through existing `agents.teams.*` RPC; keep member agents under normal agent scope. | UI/RPC can create custom teams with 1-N members, edit aliases/bindings/broadcast, and reject partial writes on conflict. |
| AT-07 | Broadcast team fanout | OpenClaw docs point shared groups to broadcast groups: `openclaw/docs/concepts/multi-agent.md:224-225` | `src/gateway/core/gateway_agent_team_broadcast.cj:8-501`; `src/gateway/core/gateway_service.cj:261-292`; broadcast tests listed above | partial | Metis now has selected-member fanout. Remaining parity risk is product semantics: UI guidance, diagnostics, failure aggregation, and explicit channel support matrix. | Harden broadcast as a first-class documented AgentTeam mode. | One inbound fake/Feishu message fans out to selected members; failed member turn is reported without corrupting other member sessions; disabled broadcast falls back to single-agent route. |
| AT-08 | Runtime schema breadth: memorySearch/subagents/sandbox/heartbeat/groupChat/tools | `openclaw/src/agents/agent-scope.ts:35-53`, `:129-159` | `src/core/config/metis_agent_scope.cj` policy parsing; `src/gateway/core/gateway_agent_team_doctor.cj` warnings | partial | Metis has several fields and diagnostics, but enforcement breadth is not equal to OpenClaw for memorySearch/subagents/sandbox/heartbeat. | Either implement enforcement or explicitly mark unsupported fields in doctor/UI/docs. | Doctor gives deterministic `ok/warning/error` rows; runtime tests prove each supported field is enforced. |
| FEI-01 | Feishu multi-account merged config | `openclaw-lark/src/core/accounts.ts:7-9`, `:45-69`, `:121-183`, `:198-223` | `src/gateway/channels/feishu/feishu_accounts.cj:23-140`; `feishu_adapter_test.cj:103-199` | partial | Metis resolves account overrides and redacts descriptions. Remaining gap: one-level deep merge parity is narrower than OpenClaw-Lark for nested fields such as footer/tools/heartbeat; Control UI account management is not complete. | Align merge semantics for all nested account fields Metis supports; expose account list/status in UI. | Tests cover default account, explicit account, disabled account, nested groups/media/policy override, and redacted account output. |
| FEI-02 | Feishu group policy, skills, tools, and system prompt | `openclaw-lark/src/core/config-schema.ts:141-151`; `dispatch-context.ts:102-135` | `feishu_adapter.cj:845-950`; `gateway_im_route_session_context.cj:14-23`, `:43-108`; `feishu_adapter_test.cj:550-574` | partial | Metis projects group policy fields into route context. Remaining risk: end-to-end prompt/skills/tool-policy behavior needs explicit route-to-agent-bridge regression tests per group. | Add full end-to-end tests from Feishu group payload to final tool inventory and prompt context. | Group A allows `feishu_fetch_doc` and injects systemPrompt; Group B denies it; both use the same account but produce different tool/prompt state. |
| FEI-03 | Feishu thread-capable group sessions | `openclaw-lark/src/messaging/inbound/dispatch-context.ts:161-201` | `feishu_adapter.cj:32-38`, `:785-843`; `feishu_adapter_test.cj:242-328` | partial | Metis has route context and injectable `isThreadCapableGroup`, but native real-client/cache/doctor behavior is not equivalent to OpenClaw-Lark's `im.chat.get` cache. | Add cached thread-capable lookup in native Feishu client and doctor output. | Fake client marks one group thread-capable and one normal; only thread-capable group writes `threadSessionKey`; diagnostics explain skipped cases. |
| FEI-04 | Feishu native commands | `openclaw-lark` native command paths and article commands | `src/gateway/core/gateway_service.cj:468-614`; `gateway_service_feishu_native_test.cj:237-361` | partial | Commands exist as text replies. OpenClaw-Lark uses richer card/onboarding UX and deeper auth/doctor integration. | Keep command handling in Gateway service, but route auth/start/doctor output through card-capable delivery when available. | `/feishu start/doctor/auth/info/help` work in direct and gated groups; secrets never appear; auth command can return device-flow pending state. |
| FEI-05 | OAuth/UAT device flow and token store | `openclaw-lark/src/core/device-flow.ts:95-280`; `token-store.ts:5-18`, `:87-180`; `tool-client.ts:139-250`, `:317-390` | `src/gateway/channels/feishu/feishu_auth.cj:8-283`; `gateway_service_feishu_native_test.cj:330-361` | partial | Metis has device-flow/token-store skeleton and injected auth runner tests, but OAPI runtime still does not consume persisted UAT or refresh tokens. | Wire auth subsystem into `/feishu auth`, tool invocation, refresh, status, and redacted diagnostics. | Fake HTTP verifies request/poll/pending/authorized/denied/expired; temp token store persists redacted status; OAPI tool can read a stored fake token path without leaking token. |
| FEI-06 | Feishu OAPI tool suite | `openclaw-lark/openclaw.plugin.json:14-55`; `tools/oapi/index.ts:46-95` | `src/gateway/tools/gateway_feishu_oapi_toolset.cj:25-78`, `:120-178`, `:184-240`; `gateway_feishu_oapi_toolset_test.cj:7-84` | partial | Metis has OpenClaw-compatible tool names/categories/scopes and fake-runner tests, but no real Feishu OAPI HTTP/SDK client behind them. | Replace placeholders with a Metis Feishu OAPI client that uses account/UAT/TAT/scope manager. Implement by tool domain. | For every listed tool, tests cover success, auth_required, scope_missing, invalid params, account id, and policy allow/deny. |
| FEI-07 | Feishu media/resource fetch | `openclaw-lark/openclaw.plugin.json:33-38`; resource/OAPI tool evidence | `feishu_adapter.cj:32-38`; `gateway_feishu_media_toolset.cj:33-166`; media tests | partial | Current-turn staged media works. Missing: user-OAuth-backed resource fetch for arbitrary messages returned by OAPI search/history. | Keep current-turn fetch; add historical/user-resource fetch using OAPI client and temp cache. | Current-turn tests remain; OAPI message resource fetch saves under temp Metis cache, enforces size/mime limits, and never touches user real files. |
| FEI-08 | Interactive cards, streaming card updates, tool-use display | `openclaw-lark/src/card/reply-dispatcher.ts:40-103`, `:194-246` | `feishu_adapter.cj:389-435`, `:506-590`; `feishu_adapter_test.cj:201-240` | partial | Metis can send/patch simple cards and map card actions to system events. Missing: full Gateway streaming card controller, footer tokens/cache/context/model, and tool-use display parity. | Add Feishu reply dispatcher layer that can choose text/static card/streaming card while preserving text fallback. | Fake Feishu client records create/patch sequence; streaming reply updates one card; tool payload appears only when tool-use display is enabled; text fallback works when card send fails. |
| FEI-09 | Feishu inbound event breadth | OpenClaw-Lark handles richer inbound pipeline and card actions; article mentions messages/resources/reactions | `feishu_adapter.cj:450-504`, `:506-590`, `:708-783` | partial | Metis handles URL verification, card actions, and text-bearing `im.message.receive_v1`. Other Feishu events and non-text message conversions are still limited. | Add event dispatcher table and targeted parsers for supported message/media/reaction/comment events. | Fake webhook tests cover accepted/ignored event types, malformed payloads, text/image/file/card action, and idempotent queue behavior. |
| UI-01 | Web management page for AgentTeam | Feishu product page demonstrates web-side team management; OpenClaw core exposes Gateway agent RPCs | `ui/src/ui/views/agents-panel-teams.ts:75-220` and related controller tests | partial | Metis has a functional panel foundation, but not a complete Miaoda-style AgentTeam management page for create/edit/profile/model/auth/binding/Feishu account workflows. | Build the management page over existing Gateway RPC and new status/auth RPCs. | Browser smoke verifies visible UI, registered `metis-app`, no JS errors, no failed static assets, and CRUD flows through fake Gateway RPC. |
| OPS-01 | Doctor/migration diagnostics | OpenClaw-Lark has `/feishu doctor` and CLI info; article lists doctor flows | `gateway_service.cj:539-579`; `gateway_agent_team_doctor.cj`; `docs/user/agent-team.md` | partial | Metis has doctor and migration dry-run, but it does not yet cover full Feishu OAPI/OAuth/thread/card/account health. | Expand doctor sections as each Feishu phase lands. | Doctor output reports account config, auth status, thread-capable status, OAPI status, card mode, route bindings, and AgentTeam findings with redaction. |

## 6. Quantified Current Completion

This is an engineering capability score, not a release-quality guarantee. It is weighted by user-visible requirements and source-backed implementation depth.

Current overall AgentTeam requirement completion: **about 76 / 100**.

Breakdown:

| Category | Weight | Current score | Reason |
| --- | ---: | ---: | --- |
| Core AgentTeam isolation/routing/binding/team/broadcast | 40 | 35 | Isolation, routing, bindings, CRUD, aliases, and broadcast fanout are source-backed and tested. Remaining work is mostly schema breadth and product hardening. |
| Per-agent workspace/model/auth lifecycle | 18 | 14 | Workspace/model/auth paths and RPCs exist. Need stronger runtime regression around selected-agent model/auth and explicit auth lifecycle. |
| Feishu channel routing/account/group/thread/native commands | 18 | 13 | Account resolver, group gate, thread route, native commands, card action system event, and tests exist. Need real thread-capable cache, richer event breadth, and deeper diagnostics. |
| Feishu OpenClaw-Lark deep parity: OAuth/OAPI/media/cards/streaming | 18 | 8 | Skeletons and placeholders exist, but real OAPI client, UAT refresh/scope manager, historical resource fetch, and streaming card controller remain. |
| Control UI, docs, and operational validation | 6 | 6 | Docs and UI foundations exist, but the target Miaoda-style management workflow and browser validation still need expansion in implementation phases. |

Interpretation:

- Metis AgentTeam core is roughly **85-90%** complete.
- Metis Feishu/OpenClaw-Lark feature parity is roughly **50-60%** complete.
- The main remaining work is no longer "create AgentTeam"; it is "finish Feishu/OpenClaw-Lark parity and management UX on top of the existing AgentTeam architecture."

## 7. Remaining Workload Estimate

Two scopes are useful:

1. **Usable Feishu AgentTeam closure**: account/group/thread routing, auth command, basic OAPI auth-required flow, current-turn media, simple cards, Control UI management. Estimated **12-16 engineer-days**.
2. **Near OpenClaw-Lark wide-tool parity**: real OAuth/UAT, real OAPI tools across docs/wiki/drive/search/bitable/calendar/task/sheets/chat/user/im, historical resource fetch, streaming cards, full diagnostics. Estimated **18-24 engineer-days**.

With two capable engineers working in isolated worktrees, the wide-tool parity scope is likely **8-12 calendar workdays** if reviews are disciplined and fake-test infrastructure is reused. With one engineer, it is more realistically **3-5 work weeks**, depending on how many Feishu OAPI domains are treated as release-blocking.

This estimate is below a 6-8 week project because Metis already has the AgentTeam core, Feishu account resolver, auth skeleton, OAPI placeholder surface, card skeleton, and broadcast runtime.

## 8. Phased补齐方案与验收项

### Phase 0: Evidence Baseline and Regression Guard

Goal: make this matrix actionable and prevent regressions while implementation continues.

Subphases:

- 0.1 Keep this `series-07` document as the current baseline. Future implementation phases must update it when source reality changes.
- 0.2 Add or update a small "AgentTeam current state" checklist in developer docs only if implementation starts.
- 0.3 Define the fake-test rule: no real Feishu network, no real Telegram token, no real `~/.metis`.

Acceptance:

- This document exists under `develop_steps`.
- Every `partial` row has an implementation task and acceptance items.
- No code/config is changed by this planning phase.

### Phase 1: Per-Agent Model/Auth Runtime Hardening

Source basis:

- OpenClaw auth isolation: `openclaw/docs/concepts/multi-agent.md:20-37`.
- Metis turn context paths: `gateway_im_route_session_context.cj:74-92`.
- Metis model/auth tests: `gateway_server_methods_agents_test.cj:1040-1178`.

Subphases:

- 1.1 Add fake runtime tests for two agents with different `models.json`, different `auth-profiles.json`, and the same channel peer.
- 1.2 Verify Gateway request execution always uses `GatewayTurnContext.modelsJsonPath` and `authProfilesPath` for the selected agent.
- 1.3 Tighten doctor output for "global/env fallback used" so fallback is explicit, visible, and never confused with per-agent auth.

Acceptance:

- Agent A and Agent B produce different model/auth source observations in fake runtime.
- Main/root auth is not read unless explicit fallback rules say so and doctor reports it.
- Secrets are redacted in CLI, Gateway RPC, logs, and Control UI.
- Full verification after code phase: `source /Users/l3gi0n/cangjie100/envsetup.sh && cjpm clean && cjpm build -i && cjpm test`.

### Phase 2: Feishu Account, Group, and Thread Completeness

Source basis:

- OpenClaw-Lark account merge: `openclaw-lark/src/core/accounts.ts:45-69`, `:121-183`.
- OpenClaw-Lark thread session: `dispatch-context.ts:161-201`.
- Metis account resolver/thread context: `feishu_accounts.cj:52-140`; `feishu_adapter.cj:785-950`.

Subphases:

- 2.1 Align nested account override merge for all Metis-supported nested objects.
- 2.2 Add native Feishu chat-info cache behind `isThreadCapableGroup`, with injectable fake client.
- 2.3 Add account/thread diagnostics to `/feishu doctor` and Gateway channel status.
- 2.4 Add tests for two Feishu accounts with the same chat id but different account-level group policies.

Acceptance:

- Account override precedence matches documented OpenClaw-Lark behavior for supported fields.
- A thread message in a thread-capable group gets thread session; the same payload in a normal group uses group session and reports why.
- Disabled account never starts transport and never routes inbound.
- Tests use fake clients and temp home only.

### Phase 3: Group Policy End-to-End Enforcement

Source basis:

- OpenClaw-Lark group schema: `config-schema.ts:141-151`.
- Metis route policy merge: `gateway_im_route_session_context.cj:14-23`.
- Metis Feishu group policy context: `feishu_adapter.cj:936-950`.

Subphases:

- 3.1 Add an end-to-end fake Feishu inbound test that carries group `systemPrompt`, `skills`, `tools`, and `runtimePolicy` into Gateway turn context.
- 3.2 Verify `agent_bridge` consumes route-level tool policy and skills in the final runtime inventory/prompt.
- 3.3 Add negative tests: denied tool is absent, disabled group does not trigger agent, requireMention works with and without mentions.

Acceptance:

- Group A and Group B on the same account produce different prompt/tool/skill state.
- Denied Feishu OAPI tool cannot be invoked even if globally registered.
- Gate diagnostics explain `group_disabled`, `sender_not_allowed`, `bot_sender_not_allowed`, and `group_mention_required`.

### Phase 4: Feishu OAuth/UAT Runtime Wiring

Source basis:

- OpenClaw-Lark device flow: `device-flow.ts:95-280`.
- OpenClaw-Lark token store: `token-store.ts:5-18`.
- OpenClaw-Lark tool client: `tool-client.ts:139-250`, `:317-390`.
- Metis auth skeleton: `feishu_auth.cj:8-283`.

Subphases:

- 4.1 Wire `/feishu auth` to the native device-flow client with app credentials from the resolved account.
- 4.2 Persist token state through the Metis token store abstraction, using temp path in tests.
- 4.3 Add token status and deletion RPCs if Control UI needs them.
- 4.4 Add structured auth/scope result types for OAPI tools.

Acceptance:

- Fake HTTP tests cover pending, authorized, slow_down, denied, expired, parse error, and network error.
- Token store tests prove persisted status can be loaded after manager restart in temp home.
- `/feishu auth` displays verification URL/user code when pending and never displays tokens or app secrets.

### Phase 5: Real Feishu OAPI Tool Client

Source basis:

- OpenClaw-Lark OAPI registry: `tools/oapi/index.ts:46-95`.
- OpenClaw-Lark plugin contract: `openclaw.plugin.json:14-55`.
- Metis OAPI placeholder: `gateway_feishu_oapi_toolset.cj:25-78`, `:120-178`, `:184-240`.

Subphases:

- 5.1 Create a Metis Feishu OAPI client boundary that accepts account id, token mode, path/action, params, and required scopes.
- 5.2 Implement common/user/chat/im first, because they support addressing and resource workflows.
- 5.3 Implement docs/wiki/drive/search.
- 5.4 Implement calendar/task/sheets/bitable.
- 5.5 Keep the current fake-runner test seam for unit tests and add fake HTTP fixtures per domain.

Acceptance:

- Tool names remain compatible with OpenClaw-Lark contract.
- Each tool returns structured JSON for success, invalid_request, auth_required, app_scope_missing, user_scope_missing, and Feishu API error.
- Account id is propagated into every request.
- Tool policy can allow/deny tools per agent and per Feishu group.

### Phase 6: Feishu Media and Historical Resource Fetch

Source basis:

- OpenClaw-Lark tool contract includes `feishu_im_user_fetch_resource`.
- Metis current-turn media tools: `gateway_feishu_media_toolset.cj:33-166`.

Subphases:

- 6.1 Keep current-turn staged fetch behavior unchanged.
- 6.2 Add OAPI-backed resource fetch for message ids returned by search/history tools.
- 6.3 Store fetched files under a configured Metis temp/cache root with size/mime limits.
- 6.4 Add cleanup/doctor diagnostics for cached resources.

Acceptance:

- Current-turn fetch still returns staged local path when available.
- Historical resource fetch uses fake OAPI and temp cache in tests.
- Oversized, unsupported mime, missing permission, and not found all return structured diagnostics.
- Tests never write into user downloads or real workspace unless temp workspace is supplied.

### Phase 7: Feishu Cards, Streaming, and Tool-Use Display

Source basis:

- OpenClaw-Lark reply dispatcher: `card/reply-dispatcher.ts:40-103`, `:194-246`.
- Metis card skeleton: `feishu_adapter.cj:389-435`, `:506-590`.

Subphases:

- 7.1 Add a Feishu reply dispatcher boundary in Metis Gateway that chooses text/static card/streaming card by config.
- 7.2 Add streaming card lifecycle: create card, patch card on chunks, finalize card, fallback to text.
- 7.3 Add tool-use display mode for tool payloads.
- 7.4 Add footer rendering for tokens/cache/context/model only when data exists in Metis turn metadata.

Acceptance:

- Fake Feishu API records card create and patch sequence.
- Text fallback is used when card send returns `not_configured` or unsupported error.
- Tool payloads appear in card only when configured.
- Card action callbacks become safe system events and do not execute arbitrary user-provided action names.

### Phase 8: Control UI AgentTeam Management Page

Source basis:

- Metis UI foundation: `ui/src/ui/views/agents-panel-teams.ts:75-220`.
- Metis Gateway RPCs: `agents.add`, `agents.files.*`, `agents.models.*`, `agents.teams.*`.

Subphases:

- 8.1 Keep all writes behind Gateway RPC; UI must not write local files directly.
- 8.2 Add a guided create/edit workflow: team identity, members, default agent, profile files, model state, auth status, bindings, Feishu account status.
- 8.3 Add broadcast editor with clear selected-member semantics and failure diagnostics.
- 8.4 Add Feishu account/auth/status panel when Phase 4/5 RPCs exist.
- 8.5 Add browser smoke validation for Control UI after any UI change.

Acceptance:

- `customElements.get("metis-app")` is registered in browser runtime.
- Page renders visible Metis UI content, no blank page, no page errors, no failed JS/CSS/static asset requests.
- Create/update/delete team, edit profile files, edit model JSON, preview/apply binding, and configure broadcast work against fake Gateway RPC.
- UI never exposes app secret, access token, refresh token, bot token, or auth headers.

### Phase 9: Documentation, Migration, and Full Verification

Source basis:

- Current user doc: `docs/user/agent-team.md`.
- Current doctor/migration: `gateway_agent_team_doctor.cj` and `agents.migration.dryRun`.

Subphases:

- 9.1 Update `docs/user/agent-team.md` with the final supported capability matrix.
- 9.2 Update `develop_steps` series document with closure evidence for every completed phase.
- 9.3 Expand migration dry-run/doctor output for Feishu account/auth/OAPI/card/thread states.
- 9.4 Run full Cangjie verification and UI browser smoke when UI changes land.

Acceptance:

- Docs show how users start Gateway, create/manage teams, bind Telegram/Feishu accounts, configure Feishu auth, and use OAPI tools.
- `agents.migration.dryRun` remains read-only and redacted.
- Verification command after implementation phases:

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
cjpm clean
cjpm build -i
cjpm test
```

- If UI changed, browser smoke also proves the page renders and has no runtime JavaScript errors.

## 9. Priority Recommendation

Recommended execution order:

1. Phase 1 and Phase 2 first, because they protect the core route/model/auth correctness and Feishu account/thread semantics.
2. Phase 4 before Phase 5, because real OAPI tools need OAuth/UAT and scope diagnostics.
3. Phase 5 in domain slices, not as one large change.
4. Phase 7 and Phase 8 can run in parallel after the RPC/tool/auth contracts are stable.

Do not add a separate "AgentTeam runtime" outside Gateway. OpenClaw and current Metis both center this feature around Gateway route/session context and per-agent scope. The safe path is to strengthen the existing Gateway/ChannelAdapter/RPC/UI boundaries rather than introducing another orchestration layer.
