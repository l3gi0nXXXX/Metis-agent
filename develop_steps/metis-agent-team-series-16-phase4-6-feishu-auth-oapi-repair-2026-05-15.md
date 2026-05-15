# Metis AgentTeam Series 16 Phase 4-6: Feishu Auth/OAPI Repair Evidence

Date: 2026-05-15
Worker scope: Phase 4 Feishu account/thread/route fake coverage check, Phase 5 OAuth/UAT/TAT/app-scope closure, Phase 6 tool-level auto-auth repair and scope merge.

## Summary

This pass keeps the fix inside the Feishu channel/auth/OAPI tool boundary. Tools return structured, redacted repair actions that Gateway, IM commands, and Control UI can consume; the toolset does not write real token files, app secrets, or authorization headers.

## Source-Backed Capability Matrix

| Capability | Metis source evidence | Status | Gap after this pass | Acceptance/test |
| --- | --- | --- | --- | --- |
| Feishu account/thread route fake coverage | `src/gateway/core/gateway_im_route_session_context_test.cj` covers multiple Feishu accounts and thread session keys; `src/gateway/runtime/gateway_server_methods_agents_test.cj` covers Feishu thread route binding and fake IM E2E. | aligned | No code change required in route resolver or rich event/card logic. | Run `GatewayImRouteSessionContextTest.fakeTelegramAndFeishuE2eRoutesMultipleChannelsAccountsThreadsAndConflicts` and `GatewayServerMethodsAgentsTest.agentTeamFakeImE2eCoversTelegramFeishuRoutesAndBroadcast`. |
| OAuth lifecycle and token-store boundary | `src/gateway/channels/feishu/feishu_auth.cj` owns start/status/poll/complete/revoke/liveSmoke; `src/gateway/channels/feishu/feishu_auth_test.cj` verifies redacted token persistence and opt-in live smoke. | aligned | Real tenant evidence still pending user-provided Feishu app and tenant. | Run `FeishuAuthFoundationTest`; live smoke remains skipped by default. |
| UAT/TAT/bot/app token mode closure | `src/gateway/tools/gateway_feishu_oapi_client.cj` maps OpenClaw action keys to `user_access_token`, `tenant_access_token`, `bot_access_token`, and `app_access_token`; `src/gateway/tools/gateway_feishu_oapi_toolset_test.cj` now exercises tenant, bot, and app token issuance with fake clients. | aligned | Real Feishu token endpoint success still needs opt-in live resources. | `GatewayFeishuOapiToolsetTest.appTokenProviderFetchesCachesTenantBotAndAppTokensWithFakeClient`. |
| Tool-level user auth repair | `src/gateway/tools/gateway_feishu_oapi_repair.cj` attaches redacted `repair_action` for `auth_required` and `scope_missing`, pointing consumers at `channels.feishu.auth.start`. | aligned | IM/UI still choose how to render or trigger the action. | `GatewayFeishuOapiRepairTest.authRequiredResultIncludesReadyRedactedRepairActionWithContext`; `scopeMissingRepairMergesScopesForSameTurnAccountAndUser`. |
| Tool-level app-scope repair | `src/gateway/tools/gateway_feishu_oapi_repair.cj` returns `feishu_oapi_app_scope_repair` with `operator_required` and no network start. | aligned | Operator must grant scopes in Feishu developer console. | `GatewayFeishuOapiRepairTest.appScopeMissingRepairActionIsOperatorRequiredAndRedacted`. |
| Tool-level missing credential repair | `src/gateway/tools/gateway_feishu_oapi_repair.cj` now attaches `feishu_oapi_credential_repair` for `missing_credential`, with missing `app_id`/`app_secret`, `operator_required`, and `network=not_started`. | aligned | Operator must configure app credentials through Gateway-backed configuration. | `GatewayFeishuOapiRepairTest.missingCredentialResultIncludesOperatorRepairActionWithoutStartingNetwork`. |
| Scope merge | `FeishuOapiAuthRequestMerger` merges missing scopes for the same turn/account/user into `merged_scopes`. | aligned | Merge is diagnostic only; it does not write token files. | `GatewayFeishuOapiRepairTest.scopeMissingRepairMergesScopesForSameTurnAccountAndUser`; `GatewayFeishuOapiToolsetTest.authRequestMergeHelperProducesOneMergedRequestForSameTurnScopes`. |
| Live OAuth/OAPI smoke | OAuth live smoke and OAPI live smoke are explicit opt-in and redacted by default; OAPI writes `report.json` when `METIS_FEISHU_OAPI_LIVE_REPORT_DIR` is set. | partial | Needs real Feishu app credentials, authorized user, tenant/chat, and granted scopes. | Default skipped tests and redacted report checks remain required. |

## Behavior Contract

- `auth_required`: tool result includes `repair_action.kind=feishu_oapi_auth_repair`, `can_start=true`, and `repair_method=channels.feishu.auth.start` when turn/chat/user context exists.
- `scope_missing`: same repair kind, merged with previous same-turn user auth requests.
- `app_scope_missing`: tool result includes `repair_action.kind=feishu_oapi_app_scope_repair`, `operator_required`, and no network start.
- `missing_credential`: tool result includes `repair_action.kind=feishu_oapi_credential_repair`, `operator_required`, `missing_fields=["app_id","app_secret"]`, and no network start.
- `token_mode_unsupported`: must not occur for action keys whose token mode is one of the supported modes: `user_access_token`, `tenant_access_token`, `bot_access_token`, or `app_access_token`.

## Live Acceptance Inputs Still Needed

- Feishu test app and bot with app ID/app secret.
- Test tenant, test chat, and test user that can authorize OAuth.
- Granted app scopes and user scopes matching the selected OAPI live cases.
- Explicit opt-in environment for OAuth/OAPI live smoke and a temporary report directory.
- Redacted acceptance artifacts only; no real bot tokens, access tokens, refresh tokens, device codes, app secrets, or authorization headers in reports.
