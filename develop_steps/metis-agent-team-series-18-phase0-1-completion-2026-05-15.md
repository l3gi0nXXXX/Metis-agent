# Metis AgentTeam Series18 Phase0-1 Completion

日期：2026-05-15
工作区：`.worktrees/agentteam-s17-phase0-1-20260515`
范围：Series17 Phase 0-1，证据冻结/工作区安全、核心 AgentTeam CLI/RPC 验收。

## Source Facts Frozen Before Implementation

| Fact | Source evidence | Acceptance impact |
| --- | --- | --- |
| Series17 Phase 0 requires isolated `METIS_HOME`; the manual gate should fail when pointed at the real `~/.metis`. | `develop_steps/metis-agent-team-series-17-post-phase16-source-recheck-gap-quantification-manual-acceptance-2026-05-15.md:151` | Gate tests must use a fake `HOME` and prove `METIS_HOME=$HOME/.metis` fails, without touching the operator's real home. |
| Current gate writes a redacted `report.json` and `manual-acceptance-template.md`, and records skipped live Telegram/Feishu gates by default. | `scripts/agentteam-manual-acceptance-gate.sh:59-91` | Gate test should assert the pack exists and contains Phase 0-1 acceptance sections, not secrets or raw live IDs. |
| Current gate has an implementation detail not stated in Series17: `METIS_AGENTTEAM_ALLOW_REAL_HOME=1` bypasses the real-home/report-dir rejection. | `scripts/agentteam-manual-acceptance-gate.sh:171-182` | Series18 tightens this for Phase 0 evidence safety: the gate must reject the real home even if the old override is set. Tests use a temporary `HOME` so no real `~/.metis` is written. |
| CLI parsing already accepts team `--binding-json`, `--binding`, and legacy `--bind`, storing them as `bindings`. | `src/program/cli_local_flows.cj:433-457` | A binding-only `metis agents team update` is a real Phase 1 update and should pass CLI validation before Gateway RPC. |
| Current CLI update validation only treats `displayName`, `members`, and `aliases` as mutation fields. | `src/program/cli_local_flows.cj:545-549` | Add a failing CLI test for binding-only update acceptance, then include `bindings` in the validation. |
| Gateway RPC already tests create/update binding conflict atomicity. | `src/gateway/runtime/gateway_server_methods_agents_test.cj:1658-1719` | Keep RPC architecture unchanged; focused validation should rerun the existing conflict tests after CLI/gate fixes. |

## Phase 0 Acceptance

| Item | Status | Evidence / command |
| --- | --- | --- |
| Worktree isolation verified | done | `pwd` and `git rev-parse --show-toplevel` returned `/Users/l3gi0n/work/workspace_cangjie/Metis/.worktrees/agentteam-s17-phase0-1-20260515`. |
| Real-home gate rejection tested with fake `HOME` | done | `bash scripts/agentteam-manual-acceptance-gate-test.sh` passed; the initial red run failed on missing Series/Phase evidence metadata before reaching the real-home assertion. |
| Redacted evidence pack generated under isolated home | done | `METIS_AGENTTEAM_SKIP_ENVSETUP=1 METIS_HOME=$(mktemp -d ...) scripts/agentteam-manual-acceptance-gate.sh` passed and wrote its report under the temporary home. |

## Phase 1 Acceptance

| Item | Status | Evidence / command |
| --- | --- | --- |
| CLI team CRUD/binding parameters covered | done | `cjpm test -i src/program --filter CliLocalFlowsAgentTeamTest --parallel 1 --no-color --no-progress` passed 8/8 cases. |
| CLI binding-only team update accepted | done | New `updateTeamAcceptsBindingOnlyAsMutationField` test passed; implementation treats `bindings` as an update mutation field. |
| RPC team CRUD and binding conflict atomicity covered | done | `cjpm test -i src/gateway/runtime --filter GatewayServerMethodsAgentsTest --parallel 1 --no-color --no-progress` passed 42 cases, including AgentTeam CRUD and binding conflict atomicity tests. |

## Verification Notes

| Command | Result |
| --- | --- |
| `bash scripts/agentteam-manual-acceptance-gate-test.sh` | passed |
| `cjpm test -i src/program --filter CliLocalFlowsAgentTeamTest --parallel 1 --no-color --no-progress` | passed 8/8 |
| `cjpm test -i src/gateway/runtime --filter GatewayServerMethodsAgentsTest --parallel 1 --no-color --no-progress` | passed 42, skipped unrelated 264 |
| `METIS_AGENTTEAM_SKIP_ENVSETUP=1 METIS_HOME=$(mktemp -d ...) scripts/agentteam-manual-acceptance-gate.sh` | passed with browser, Telegram, and Feishu live checks skipped by default |
| `git diff --check` | passed |

`cjpm test src/program --filter CliLocalFlowsAgentTeamTest` without `-i` returned package exit 9 with no failing test case output in this worktree. The same class passed with the incremental, serial command above.

## External Live Resource Blockers

The following remain blocked by operator-provided resources and are not required for this Phase 0-1 local closure:

- Telegram test bot, group/topic, and test user for real route/broadcast evidence.
- Feishu test app/bot, tenant, scopes, group/thread, and event subscription for real OAuth/OAPI/CardKit/rich-event evidence.
- Provider/model credentials for live per-agent model/auth smoke.
