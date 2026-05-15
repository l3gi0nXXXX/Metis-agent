# Metis AgentTeam Series 16 Phase 3: Telegram route acceptance

Date: 2026-05-15
Scope: Telegram-first AgentTeam route acceptance for account routes, group/topic isolation, alias routing, broadcast aggregate evidence, and opt-in live gating.

## Conclusion

Phase 3 is fake-tested in the shared Gateway route/session architecture and live-gated for operator-provided Telegram resources. The implementation still does not run real Telegram network checks by default, does not require real bot tokens in tests, and does not read real `~/.metis` during the manual gate.

## Capability Matrix

| Capability | Metis source evidence | Status | Gap | Acceptance and tests |
| --- | --- | --- | --- | --- |
| Telegram account route | `src/gateway/core/gateway_agent_route_resolver.cj:561-626`; `src/gateway/core/gateway_agent_route_resolver_test.cj:361` | aligned | No fake-test gap after this phase. Live proof still needs a user test bot account. | `telegramAccountGroupAndTopicsResolveToIsolatedAgentSessions` asserts `telegram:bot-a` routes to the bound agent and agent-scoped direct session. |
| Telegram group route | `src/gateway/core/gateway_agent_route_resolver.cj:436-545`; `src/gateway/core/gateway_agent_route_resolver_test.cj:381` | aligned | No fake-test gap after this phase. Live proof still needs a test group. | Same route test asserts the group peer binding resolves to `agent:ops:telegram:group:-100_acceptance`. |
| Telegram topic isolation | `src/gateway/channels/telegram/telegram_adapter_test.cj:413`; `src/gateway/core/gateway_agent_route_resolver_test.cj:390` | aligned | No fake-test gap after this phase. Live proof still needs a forum topic or topic-capable supergroup. | Adapter fake inbound projects topic route context; route resolver fake test asserts two topic ids produce different agent-scoped session keys. |
| Telegram alias routing | `src/gateway/channels/telegram/telegram_adapter_test.cj:441`; `src/gateway/core/gateway_agent_route_resolver.cj:561-626` | aligned | No fake-test gap after this phase. Live proof still needs a group message using the configured alias. | Existing fake test asserts `/agent writer` and `@writer` route to `writer`, while a normal message falls back to default. |
| Telegram team broadcast aggregate | `src/gateway/core/gateway_agent_team_broadcast.cj:405-487`; `src/gateway/core/gateway_agent_team_broadcast.cj:540-602`; `src/gateway/core/gateway_agent_team_broadcast_test.cj:314` | aligned | No fake-test gap after this phase. Live proof still needs a test group where broadcast is enabled. | New Telegram-specific broadcast test asserts selected members get isolated `telegram` session keys and aggregate rows retain per-agent session evidence. |
| Telegram live gate | `scripts/agentteam-manual-acceptance-gate.sh:169-176`; `docs/user/agent-team.md:54`; `docs/user/agent-team.md:450` | partial | The gate is intentionally read-only and manual; it cannot prove live Telegram success without operator resources. | Default run prints skipped. Opt-in requires `METIS_AGENTTEAM_LIVE_TELEGRAM=1`, `METIS_AGENTTEAM_TELEGRAM_ACCOUNT_ID`, and `METIS_AGENTTEAM_TELEGRAM_TEST_CHAT_ID`. |

## Live Acceptance Inputs Still Required

- Telegram test bot token configured in an isolated `METIS_HOME`.
- Telegram AgentTeam account id matching the configured test bot account.
- Test direct user or private chat for account/direct route checks.
- Test group or supergroup id.
- Test forum topic id when validating topic isolation.
- Configured AgentTeam aliases such as `@writer` or `/agent writer`.
- Broadcast-enabled team with selected members and model/provider credentials suitable for a manual reply path.
- Redacted Gateway logs showing `Gateway.inbound: channel=telegram`, resolved agent id, session key, and delivery result.

No report should contain bot tokens, proxy credentials, authorization headers, provider keys, or real user `~/.metis` paths.
