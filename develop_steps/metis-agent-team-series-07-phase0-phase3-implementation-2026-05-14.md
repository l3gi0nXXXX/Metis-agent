# Metis AgentTeam Series 07 Phase 0-3 Implementation Note

Date: 2026-05-14

Scope: isolated worktree `work/agentteam-s07-core-20260514`.

## Phase 0 Regression Baseline

- Fake-test rule is enforced by the added coverage: tests use temp `METIS_HOME`, fake Feishu clients, and local JSON payloads only.
- No real Feishu or Telegram network, tokens, credentials, or real `~/.metis` files are required.
- Source baseline remains the Series 07 source recheck plan in `develop_steps`; this note records the Phase 0-3 code landing evidence.

## Phase 1 Per-Agent Model/Auth Runtime

- Added regression coverage proving selected AgentTeam agents materialize runtime `models.json` under their own `agentDir`.
- The regression writes separate fake `auth-profiles.json` files for `writer` and `ops`, then verifies generated runtime state records the selected provider auth source without serializing fake secrets or another agent's source.

## Phase 2 Feishu Account/Group/Thread

- Feishu account override resolution now deep-merges supported nested `groups` objects so account-level group entries can override or extend top-level group settings without dropping inherited wildcard or per-group fields.
- Feishu thread capability checks are cached per account/chat and produce route diagnostics when `threadSession` is configured but the group is not thread-capable.

## Phase 3 Group Policy Enforcement

- Gateway route-level `systemPrompt` now contributes to the final AgentBridge system prompt from direct route context or nested `groupPolicy`/`policy`/`runtimePolicy`.
- Existing route-level tool allow/deny enforcement remains active; the new regression verifies a Feishu group can allow `feishu_fetch_doc` while excluding other Feishu OAPI tools in the final runtime inventory.

## Verification Targets

- `cjpm test --filter AgentBridgeRuntimeTest`
- `cjpm test --filter FeishuAdapterTest`
- `cjpm build -i`
