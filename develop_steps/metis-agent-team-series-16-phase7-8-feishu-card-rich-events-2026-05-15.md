# Metis AgentTeam Series 16 Phase 7-8: Feishu CardKit, Rich Events, And Resources

Date: 2026-05-15
Worker scope: Phase 7 Feishu CardKit streaming parity; Phase 8 rich events and historical resource reads.

## Result

This pass found that the core Phase 7-8 implementation already existed in the Feishu channel and OAPI media-tool boundary. The change set therefore stays small: it adds one explicit fake CardKit fixture for long text, markdown table content, image-key replacement, and rate-limit fallback, then documents the current fake and opt-in live acceptance surface.

No real Feishu network calls, real bot tokens, real tenant credentials, or real media downloads were used or added.

## Source Evidence

| Area | Evidence | Status | Notes |
| --- | --- | --- | --- |
| Card create/patch/finalize/abort | `src/gateway/channels/feishu/feishu_cards.cj` `FeishuStreamingCardController.create`, `patchChunk`, `finalize`, `abort`; `src/gateway/channels/feishu/feishu_adapter_test.cj` `streamingControllerLifecycleIncludesToolFooterAbortAndFallback` | aligned | Fake client covers the observable lifecycle without Feishu network. |
| Observable card state | `src/gateway/channels/feishu/feishu_cards.cj` `observableState`; `streamingControllerExposesCardKitFlushFallbackAndUnavailableState` | aligned | Exposes phase, CardKit id/sequence, text, flush, fallback, unavailable, footer metrics, and image resolver state. |
| Fallback matrix | `classifyFeishuCardFallback`; `cardFallbackClassificationSeparatesRateTableAndTerminalFailures`; `streamingControllerRecordsFallbackCategoryForCreateAndPatch` | aligned | Covers rate limit, table/content limits, unavailable message, and unrecoverable errors. |
| Long text, markdown table, image replacement, rate limit | `streamingControllerPreservesLongTextMarkdownTableImagesAndRateLimitFallback` | aligned | Added in this pass to make the acceptance fixture explicit. |
| Card action event | `mapCardActionToInbound`; `cardActionTriggerBecomesSafeSystemEvent`; event replay fixture `card_action` | aligned | Includes account id, message id, operator id, system-event kind, and thread context. |
| Rich events | `mapReactionEventToInbound`, `mapDriveCommentEventToInbound`, `mapBotMembershipEventToInbound`, `mapVcInvitedEventToInbound`, `mapBitableFieldChangedEventToInbound`; `botVcAndBitableEventsBecomeStructuredSystemEvents` | aligned | Events become safe system events or explicit ignored diagnostics. |
| Event replay | `src/gateway/channels/feishu/feishu_event_replay_samples.json`; `sanitizedFeishuEventReplayFixtureCoversSupportedAndIgnoredShapes` | aligned | 16 redacted samples cover supported and ignored shapes, dedup, account/app ownership, media metadata, and thread projection. |
| Unsupported diagnostics | `unsupportedAndMalformedEventsReturnExplicitIgnoredDiagnostics` | aligned | Unsupported event/message and malformed payloads return structured ignored responses. |
| Thread projection | `webhookThreadPayloadProjectsUnifiedImRouteContext`, `groupThreadKeepsThreadPeerAndReplyInThread`, `threadSessionRequiresFakeThreadCapableGroup`, `threadSessionCachesThreadCapabilityAndReportsSkippedReason` | aligned | Covers route context, reply-in-thread, thread capability, and skipped diagnostics. |
| Current-turn resources | `attachFeishuAttachmentContext`; `imageFileMediaAndAudioCreateAttachmentContextWithoutDownload`; `imageResourceDownloadPersistsToConfiguredSafeTempPath`; `resourceDownloadReportsPermissionAndRateLimitFailures` | aligned | Default is metadata-only; configured fake download persists only to safe temp paths. |
| Historical resources | `src/gateway/tools/gateway_feishu_media_toolset.cj` historical OAPI boundary; `src/gateway/tools/gateway_feishu_media_toolset_test.cj` `feishuHistoricalFetchDefaultsToOapiAuthRequiredWhenNoTestRunnerIsConfigured`, `feishuHistoricalFetchOapiAuthAndScopeDiagnosticsAreStructured`, `feishuHistoricalFetchCanUseOapiResourceClientAndPreservesSafeTempCache` | aligned | Existing fake tests cover auth-required, scope-missing, and success cases without real Feishu network. |

## Acceptance Matrix

| Item | Fake acceptance | Live acceptance |
| --- | --- | --- |
| Card create | Fake `sendInteractiveCard` returns `fake-feishu-card-*`. | Send a test group reply and capture the redacted card message id. |
| Card patch | Fake patch updates one card id and increments sequence. | Verify the same card updates during a streaming answer. |
| Finalize | Fake finalize appends footer metrics and completes the card. | Verify final card text and footer metrics are visible. |
| Abort | Fake abort updates card text to an aborted state. | Trigger an interrupted test turn and capture the aborted card state. |
| Fallback | Fake rate/table/unavailable errors send text fallback. | Temporarily force or observe a recoverable card failure and confirm no empty reply. |
| Long text/table/image | Fake long text and markdown table are preserved; resolved `img_` keys replace remote URLs. | Send a long markdown/table answer with a pre-uploaded test image key. |
| Rich events | Replay fixtures cover message, post, image, file, audio, video, interactive, reaction, drive comment, bot membership, VC, bitable, and ignored diagnostics. | Use test app event subscriptions and record redacted inbound event kinds. |
| Dedup | Duplicate fake events return `duplicate_event`. | Replay the same redacted event id through the test channel and confirm one inbound row. |
| Thread projection | Fake thread events project `peerKind=thread` and parent group context. | Use a test Feishu thread/topic and confirm route/session keys. |
| Historical resource auth | Fake no-token path returns `auth_required`. | Run with a test user before OAuth and confirm structured auth diagnostic. |
| Historical resource scope | Fake missing-scope path returns `scope_missing` and required scopes. | Remove a test scope or use a limited test app and capture missing scope names only. |
| Historical resource success | Fake OAPI client writes bytes to a temporary safe cache path. | With test tenant/user scope, fetch a non-sensitive test image/file into an isolated temp cache. |

## Opt-In Live Checklist

Required user resources for real Feishu card/event/resource validation:

- Test Feishu app and bot, not a production app.
- App id and app secret configured only in backend Gateway config.
- Verification token and encrypt key if webhook validation is enabled.
- Test tenant, test group, test thread/topic, and test user.
- Event subscriptions for message receive, card action, reaction, drive comment, bot membership, VC, and bitable events as applicable.
- Granted scopes for user OAuth and message/resource reads; keep a redacted list of granted and missing scopes.
- Temporary `METIS_HOME`, report directory, and media cache under `/tmp` or another isolated test path.
- Explicit opt-in env vars: `METIS_FEISHU_LIVE_CARD_SMOKE=1` and `METIS_FEISHU_LIVE_EVENT_REPLAY_SMOKE=1`.

Redaction rules:

- Do not persist bot tokens, app secrets, access tokens, refresh tokens, device codes, `Authorization` headers, proxy credentials, raw user private content, or raw media bytes in docs.
- Store only redacted ids, timestamps, status strings, event kinds, missing scope names, and pass/fail notes.

## Remaining Risk

The fake matrix is aligned for Phase 7-8, but live parity remains unproven until a user provides the test Feishu resources above. True live CardKit behavior can still vary by tenant app capabilities, enabled scopes, event subscription shape, and Feishu rate limits.
