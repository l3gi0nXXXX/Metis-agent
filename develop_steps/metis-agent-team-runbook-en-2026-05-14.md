# Metis Agent Team Runbook

Date: 2026-05-14

## 1. Scope

This runbook covers Metis Agent Team startup, configuration, team creation, channel binding, Feishu OAuth, OAPI use, and common failure diagnosis. Browser UI actions must go through Gateway RPC. The browser must not write tokens, secrets, local config files, or authentication files under `~/.metis`.

## 2. Startup

1. Prepare the Cangjie environment:

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH"
```

2. Build Metis:

```bash
cjpm build -i
```

3. Start the Gateway using the local Gateway and Control UI configuration. After opening Control UI, verify visible Metis content and confirm that `customElements.get("metis-app")` is registered in the browser. Any change under `ui/` or `assets/control-ui/` also requires a Control UI build and browser smoke test.

## 3. Configuration Contract

Agent Team management stays behind Gateway RPC and Metis configuration management:

- Team definitions: `agents.teams.list/get/create/update/delete`.
- Member bindings: `agents.bind` and `agents.unbind`.
- Per-agent model files: `agents.models.get/set`.
- Profile files: `agents.files.list/get/set`; the UI allowlist is `SOUL.md`, `IDENTITY.md`, `USER.md`, and `TOOLS.md`.
- Feishu status and OAuth: `channels.status` and `channels.feishu.auth.start`.

Feishu app id, app secret, token store files, and model credentials must remain in Gateway-side config or auth storage. The UI may display only redacted summaries.

## 4. Default Collaboration Semantics And Entry Points

The current default product semantics are deterministic Gateway routing plus optional deterministic fan-out. A normal CLI, Telegram, or Feishu inbound request resolves to one agent and one agent-scoped session. Gateway fans the same turn out only when the team has `broadcast.enabled=true` and a non-empty `broadcast.members` list; each selected member keeps separate workspace, model, sessions, and per-agent delivery status.

Manager delegation can coexist with this model, but it is not a separate productized runtime yet. For manager-style behavior today, configure a manager as a normal member or `defaultAgentId`, put decomposition and handoff instructions in `AGENTS.md`, `SOUL.md`, or another allowed profile file, and bind CLI/IM routes to that manager. Execution still stays inside the existing Gateway route/session/session-runner boundary. Metis does not yet provide autonomous manager task decomposition, cross-agent handoff policy, or a separate manager-delegation engine.

Entry points:

- CLI: use `metis agents team create/list/get/update/delete` for the common team lifecycle; use `metis agents bind/unbind` for simple `channel[:account]` bindings; use `metis gateway call agents.teams.update ...` for structured peer/thread/team/role bindings or broadcast settings.
- Telegram: configure the built-in Telegram channel, then bind `telegram:<accountId>` or a structured group/topic route to a member agent. Native commands such as `/focus`, `/unfocus`, `/agents`, and `/subagents` still enter the unified Gateway route path.
- Feishu: configure Feishu account/app settings, then use `/feishu start`, `/feishu doctor`, `/feishu auth`, and `/feishu info --all` for conversation-side checks when available. Bind `feishu:<accountId>` or structured group/thread routes to member agents. OAuth/OAPI/card behavior must stay behind Gateway backend code or native commands, not browser-local files.
- Control UI: open Agents -> Teams to create teams, edit members and aliases, preview and apply bindings, edit allowed profile files, inspect model state, and review Feishu readiness/doctor guidance. The browser is only a Gateway RPC client.

## 5. Team Creation

1. Open Control UI -> Agents -> Teams.
2. Enter a Team key and Display name.
3. Use the PM/Writer/Reviewer template or add custom members.
4. Each member needs at least an `agentId`; `role` and `name` are optional display fields.
5. Choose the default member. If the selected default is not a valid member, the Gateway payload falls back to the first valid member.
6. Add aliases such as `@writer` or `/agent writer` to route text to a member.
7. Enable broadcast only for current team members.

Acceptance:

- Create, update, and delete use `agents.teams.*`.
- The UI does not edit local JSON files directly.
- Reloading the team shows the expected members, aliases, defaultAgentId, and broadcast state.

## 6. Channel Binding

The Binding Builder supports:

- Simple bindings, such as `feishu:tenant-a` or `telegram:bot-a`.
- Structured route bindings with channel, account, peer, thread, group, team, roles, and comment.

Recommended flow:

1. Select the team member.
2. Enter channel and accountId.
3. Use peer/group for chats, and thread for topic or threaded sessions.
4. Add team and roles if the route depends on those match fields.
5. Click Preview and inspect the apply payload.
6. Click Apply Binding or Remove Binding.

Acceptance:

- Preview is a read-only browser payload rendering.
- Apply/remove goes through Gateway RPC.
- No code path creates a separate AgentTeam runtime outside Gateway route/session handling.

## 7. Profile Files

Control UI can edit these workspace profile files:

- `SOUL.md`
- `IDENTITY.md`
- `USER.md`
- `TOOLS.md`

Flow:

1. Select a team member.
2. Click List Files.
3. Select a profile file and click Load.
4. Edit the content and click Save.

Safety boundary:

- The UI sends only the profile file name and content to `agents.files.*`.
- Gateway validates path boundaries.
- The UI does not accept arbitrary paths or read files outside the workspace.

## 8. Model Configuration

The Model Editor reads and writes each agent's `models.json` through `agents.models.get/set`.

Flow:

1. Select a team member.
2. Click Load Model.
3. Review provider chips, primary model ref, runtime primary model ref, and the redacted credential source.
4. Edit `models.json state` and click Save Model.

Notes:

- Do not paste API keys or Authorization headers into the UI.
- If a Gateway response accidentally includes a secret-bearing field, the UI redacts it before display.
- Credential material should stay in backend auth profiles or environment configuration.

## 9. Feishu OAuth and OAPI

The Feishu readiness panel should show:

- Accounts and default account.
- OAuth/auth status.
- Doctor status.
- OAPI capability.
- Missing setup steps.

OAuth flow:

1. Confirm the local Gateway config has Feishu app id and app secret.
2. In the Teams panel, click Start OAuth via Gateway.
3. The UI calls `channels.feishu.auth.start` and displays redacted verification URL, user code, expiration, and status fields.
4. Complete authorization in Feishu.
5. Refresh `channels.status` or run `/feishu auth` to check token status.

OAPI use:

- Agents should call Feishu OAPI through the Gateway Feishu OAPI toolset, not from the browser.
- Missing tokens return `auth_required`.
- Missing scopes return `scope_missing` or later app/user-scope diagnostics.
- Output and logs must not expose access tokens, refresh tokens, app secrets, or Authorization headers.

## 10. Common Failure Diagnosis

### Teams Panel Is Empty

- Refresh Agents -> Teams.
- Check whether `agents.teams.list` returns a response.
- If a scope error appears, check the operator permission used by the Control UI connection.

### Binding Does Not Route

- Inspect the Preview payload for the expected agentId, channel, accountId, peer/thread.
- After apply, check Gateway added/skipped/conflicts results.
- For Feishu groups, ensure accountId matches the source account.

### Feishu Receives No Reply

- First check logs for Feishu inbound events such as `Gateway.inbound: channel=feishu` or adapter inbound diagnostics.
- If there is no inbound event, prioritize account config, receive mode, app credentials, event subscriptions, and network/proxy checks.
- If inbound exists but no answer is sent, inspect route binding, session runner, model state, and outbound send path.

### OAuth Does Not Start

- `missing_app_credentials` means app id/app secret is absent or the wrong account was selected.
- `Auth status RPC missing` means the current Gateway status contract does not expose the auth object; use `/feishu auth` as a fallback diagnostic.
- Do not create token files from the browser. Use Gateway RPC or native `/feishu auth`.

### OAPI Reports Token or Scope Errors

- `auth_required`: complete OAuth first.
- `scope_missing`: add the required Feishu user scope and authorize again.
- App scope and user scope should be diagnosed separately as action-specific OAPI coverage expands.

### Control UI Is Blank or Buttons Do Not Respond

- Run `npm --prefix ui run build`.
- Confirm built JavaScript contains no raw TypeScript decorator syntax.
- In a browser, verify `customElements.get("metis-app")`, visible UI content, and no failed JS/CSS/static asset requests.

## 11. Verification

AgentTeam fake E2E/regression baseline:

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH"
cjpm test src/gateway/runtime --filter GatewayServerMethodsAgentsTest.agentTeamFakeImE2eCoversTelegramFeishuRoutesAndBroadcast
scripts/cli-agent-gateway-regression.sh
```

These commands use temporary `METIS_HOME` or fake route/broadcast payloads. They do not use real Telegram/Feishu network and do not read the real `~/.metis`.

For UI changes, run:

```bash
npm --prefix ui run test -- src/ui/controllers/agent-teams.metis.test.ts src/ui/views/agents-panel-teams.metis.test.ts
npm --prefix ui run build
```

For Cangjie Gateway RPC changes, run the targeted runtime test:

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH"
cjpm test src/gateway/runtime --filter GatewayServerMethodsChannelsTest
```

After the parent agent merges this branch into the main workspace, rerun full Cangjie verification and the Control UI browser smoke test there.
