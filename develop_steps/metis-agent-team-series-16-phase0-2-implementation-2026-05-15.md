# Metis AgentTeam Series 16 Phase 0-2 Implementation

Date: 2026-05-15
Scope: Series 15 AgentTeam Phase 0 through Phase 2 worker handoff.
Worktree: `.worktrees/agentteam-s15-phase0-2-20260515`

## Summary

Phase 0 through Phase 2 were rechecked against the Series 15 plan and the current worktree. Core AgentTeam implementation and fake/RPC/CLI regression coverage already existed, so this worker did not duplicate production code. The only source-level gap found in this scope was the manual acceptance gate evidence output: the gate enforced isolated `METIS_HOME` and skipped live gates, but it did not persist a reusable redacted evidence pack template.

## Phase Status

| Phase | Status | Evidence |
| --- | --- | --- |
| Phase 0 evidence freeze and stale conclusion correction | done | Series 15 document marks OAPI G13 as aligned and the gate checks the Series 14 108-action parity baseline. |
| Phase 1 real resource and redacted evidence pack | done for offline gate; live resources still external | `scripts/agentteam-manual-acceptance-gate.sh` now writes `report.json` and `manual-acceptance-template.md` under an isolated report dir, records skipped live gates, and scans the pack for secret-like evidence. |
| Phase 2 core AgentTeam regression closure | done in fake/RPC/CLI tests | Existing tests cover CLI team RPC params, custom members, RPC create/list/get/update/delete, profile files, per-agent models/credential source redaction, binding conflict no-partial-write, fake Telegram/Feishu route, and broadcast aggregate rows. |

## Changed Artifacts

- `scripts/agentteam-manual-acceptance-gate.sh`
  - Adds redacted evidence pack generation.
  - Defaults the pack to `$METIS_HOME/agentteam-manual-acceptance-report`.
  - Supports `METIS_AGENTTEAM_REPORT_DIR` for another isolated output directory.
  - Records live Telegram/Feishu gates as `skipped` unless explicit opt-in variables are set.
  - Writes only redacted resource presence flags, not real account, tenant, chat, URL, token, app secret, provider key, or auth header values.
  - Fails if the generated evidence pack contains secret-like token/header patterns.

- `docs/user/agent-team.md`
  - Documents the evidence pack location, files, skipped live gate behavior, and redaction scan.

## Phase 2 Existing Coverage Rechecked

| Acceptance item | Current coverage |
| --- | --- |
| CLI template/custom team params | `src/program/cli_local_flows_agent_team_test.cj` |
| Team create/list/get/update/delete | `src/gateway/runtime/gateway_server_methods_agents_test.cj` |
| Template `pm-writer-reviewer` and custom members | `src/gateway/runtime/gateway_server_methods_agents_test.cj` |
| Profile files, 7 auto-created files, `BOOTSTRAP.md` set/get | `src/gateway/runtime/gateway_server_methods_agents_test.cj` |
| Per-agent models and credential source redaction | `src/gateway/runtime/gateway_server_methods_agents_test.cj` |
| Binding conflict without partial config writes | `src/gateway/runtime/gateway_server_methods_agents_test.cj` |
| Fake Telegram/Feishu route and session keys | `src/gateway/runtime/gateway_server_methods_agents_test.cj` |
| Broadcast selected member fanout and aggregate fields | `src/gateway/runtime/gateway_server_methods_agents_test.cj`, `src/gateway/core/gateway_agent_team_broadcast_test.cj` |

## Remaining External Items

These are not completed by code changes because they require user-provided external resources:

- Real Telegram test bot token, test chat/topic, and test user.
- Real Feishu test app, tenant, bot, event subscription, scopes, test chat/thread, and test user.
- Optional real provider credentials for per-agent model credential isolation.
- Real Control UI browser smoke URL when the Gateway or built static assets are running.

The offline gate must continue to report these live gates as skipped unless explicitly opted in, and tests must not read/write the real `~/.metis` or access real Telegram/Feishu networks by default.
