# Metis AgentTeam Series 17 Phase 4-6 Feishu Auth/OAPI Completion Note

Date: 2026-05-15

Scope: Phase 4-6 from
`develop_steps/metis-agent-team-series-17-post-phase16-source-recheck-gap-quantification-manual-acceptance-2026-05-15.md`.

## Source Basis

- Phase 4 requires Feishu account/group/thread route acceptance: account configured/running with secrets redacted, group policy/mention route gate, and thread-scoped session diagnostics for thread-capable and non-thread-capable groups (`develop_steps/metis-agent-team-series-17-post-phase16-source-recheck-gap-quantification-manual-acceptance-2026-05-15.md:179`).
- Phase 5 requires Feishu auth start/status/poll/complete/refresh/revoke redaction, scope/app-scope repair actions, and token-mode live smoke behavior for missing credentials (`develop_steps/metis-agent-team-series-17-post-phase16-source-recheck-gap-quantification-manual-acceptance-2026-05-15.md:187`).
- Phase 6 requires 3-5 low-risk Feishu OAPI read cases with success plus auth/scope diagnostics and redacted reports (`develop_steps/metis-agent-team-series-17-post-phase16-source-recheck-gap-quantification-manual-acceptance-2026-05-15.md:196`).

## Source Evidence

- Feishu account status uses redacted account descriptions, including configured/running flags, credential source, redacted appId/appSecret, route policy, threadSession, and media flags (`src/gateway/channels/feishu/feishu_accounts.cj:109`).
- Feishu route context records accountId/defaultAccountId, direct/group/thread peer kind, threadId, threadSessionKey, and skipped threadSessionDiagnostic when thread session is requested but unavailable (`src/gateway/channels/feishu/feishu_adapter.cj:1552`).
- Feishu group gate evaluates group enabled, allow list, sender allow list, bot sender policy, and requireMention before setting `triggerAgent` and diagnostic `reason` (`src/gateway/channels/feishu/feishu_adapter.cj:1608`).
- Feishu native auth live smoke now treats missing app credentials after live opt-in as `status=skipped`, `reason=external-resource-required`, `blocker=missing_app_credentials`, and `networkAttempted=false` (`src/gateway/channels/feishu/feishu_auth.cj:921`).
- Feishu OAPI live smoke now treats missing live env/resources after live opt-in as `status=skipped`, `reason=external-resource-required`, `blocker=missing_live_smoke_env`, and `networkAttempted=false` (`src/gateway/tools/gateway_feishu_oapi_client.cj:1733`).
- Feishu OAPI repair actions are generated for `auth_required`, `scope_missing`, `app_scope_missing`, and `missing_credential`; missing credentials are operator-required without network, user auth/scope repairs can point to `channels.feishu.auth.start`, and app-scope repairs remain operator-required (`src/gateway/tools/gateway_feishu_oapi_repair.cj:130`).

## Acceptance Matrix

| Phase | Item | Status | Acceptance Evidence |
| --- | --- | --- | --- |
| 4 | Account status redaction | aligned | `FeishuAdapterTest.accountDescriptionsExposeRuntimeStatusForEveryConfiguredAccount` and `GatewayServerMethodsChannelsTest.channelsStatusExposesRedactedFeishuAuthLifecycleSummary` assert configured/running account status without leaking appSecret/accessToken. |
| 4 | Group `requireMention` route | aligned | `FeishuAdapterTest.groupRequireMentionGateKeepsDiagnosticWithoutTrigger` and `FeishuAdapterTest.fakeFeishuGroupPolicyReachesSessionRouteAndAgentBridgeRuntime` assert gate diagnostics and routed group context. |
| 4 | `threadSession` diagnostic | aligned | `FeishuAdapterTest.threadSessionRequiresFakeThreadCapableGroup` and `FeishuAdapterTest.threadSessionCachesThreadCapabilityAndReportsSkippedReason` assert thread-scoped session keys and skipped diagnostics. |
| 5 | OAuth/UAT/TAT/app token missing config and missing scope repair | aligned | `GatewayFeishuOapiRepairTest.missingCredentialResultIncludesOperatorRepairActionWithoutStartingNetwork`, `oauthAppTokenMissingCredentialRepairActionIsOperatorRequiredAndRedacted`, and `uatScopeMissingRepairActionStartsNativeAuthMethod` assert token modes, repair methods, redaction, and `network=not_started`. |
| 5 | Native auth live gate without app credentials | aligned | `FeishuAuthFoundationTest.liveAuthSmokeWithOptInButMissingCredentialsReportsExternalResourceRequiredWithoutNetwork` asserts skipped external-resource-required, redacted report, and zero fake HTTP calls. |
| 6 | Low-risk OAPI read fake success/auth/scope/app-scope diagnostics | aligned | `GatewayFeishuOapiToolsetTest.lowRiskReadActionsHaveFakeSuccessAuthAndScopeDiagnosticsWithoutNetwork` covers `feishu_fetch_doc.default`, `feishu_wiki_space_node.get`, `feishu_drive_file.list`, `feishu_calendar_event.list`, and `feishu_task_tasklist.list`. |
| 6 | OAPI live gate without external resources | aligned | `GatewayFeishuOapiToolsetTest.liveSmokeHarnessWithOptInButMissingExternalResourcesSkipsWithoutNetwork` asserts skipped external-resource-required, redacted report, and `networkAttempted=false`. |
| 5-6 | Real live resource closure | blocked | No real Feishu test app, tenant, user OAuth grant, scopes, chat/thread ids, or read resources were provided in this worktree. Tests intentionally avoid real Feishu network access. |

## External Live Resource Blockers

- Feishu test app/bot credentials: appId, appSecret, and domain.
- Test tenant and user account capable of completing OAuth/UAT.
- Granted user scopes, including offline access and selected read scopes.
- Granted app scopes for app-token/TAT flows.
- Live OAPI credentials or token-mode inputs for UAT/TAT/app-token cases.
- Test group/chat IDs and a thread-capable group/topic for threadSession acceptance.
- Low-risk read resources for doc/wiki/drive/calendar/task cases.

No test in this Phase 4-6 pass writes real `~/.metis` state or contacts the real Feishu network.
