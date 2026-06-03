package metis.gateway.gitcode_plugin

import metis.gateway.service_plugin.{ServicePluginDeliveryTarget, parseServicePluginJobStartPayload}
import std.unittest.testmacro.*

@Test
public class GitCodePluginContractTest {
    @TestCase
    public func parseGitCodeCommandsCoversStatusSubscribeScanQueryAndUnknown(): Unit {
        @Expect(parseGitCodeCommand("hello").handled, false)
        @Expect(parseGitCodeCommand("/gitcode status").action, "status")
        @Expect(parseGitCodeCommand("/gitcode subscribe").action, "subscribe")
        @Expect(parseGitCodeCommand("/gitcode unsubscribe").action, "unsubscribe")
        @Expect(parseGitCodeCommand("/gitcode scan once --max-repos 1").action, "scan_once_alias")
        @Expect(parseGitCodeCommand("/gitcode scan status gcm-scan-1").action, "scan_status")
        @Expect(parseGitCodeCommand("/gitcode scan cancel gcm-scan-1").action, "scan_cancel")
        @Expect(parseGitCodeCommand("/gitcode webhook status").action, "webhook_status")
        @Expect(parseGitCodeCommand("/gitcode webhook dead-letter list").action, "webhook_dead_letter_list")
        @Expect(parseGitCodeCommand("/gitcode webhook dead-letter inspect d-1").action, "webhook_dead_letter_inspect")
        @Expect(parseGitCodeCommand("/gitcode webhook replay d-1").action, "webhook_replay")
        @Expect(parseGitCodeCommand("/gitcode webhook cancel d-1").action, "webhook_cancel")
        @Expect(parseGitCodeCommand("/gitcode reconcile hooks").action, "reconcile_hooks")
        @Expect(parseGitCodeCommand("/gitcode reconcile hooks --apply").action, "reconcile_hooks_apply")
        @Expect(parseGitCodeCommand("/gitcode reconcile once --lookback-hours 24").action, "reconcile_once")
        let query = parseGitCodeCommand("/gitcode query 如何使用 HttpClient")
        @Expect(query.action, "query")
        @Expect(query.query.contains("HttpClient"), true)
        @Expect(parseGitCodeCommand("/gitcode nope").action, "unknown")
    }

    @TestCase
    public func webhookCommandArgsValidateDeliveryIdsAndReconcileOptions(): Unit {
        let delivery = parseGitCodeDeliveryArgs(["abc-123_456.789"])
        @Expect(delivery.ok, true)
        @Expect(delivery.args.deliveryId, "abc-123_456.789")
        @Expect(parseGitCodeDeliveryArgs([]).ok, false)
        @Expect(parseGitCodeDeliveryArgs(["../x"]).status, "invalid_delivery_id")
        @Expect(parseGitCodeDeliveryArgs(["a/b"]).status, "invalid_delivery_id")
        @Expect(parseGitCodeDeliveryArgs(["a b"]).status, "invalid_delivery_id")

        let hooks = parseGitCodeHookReconcileArgs([])
        @Expect(hooks.ok, true)
        @Expect(hooks.args.apply, false)
        let hooksApply = parseGitCodeHookReconcileArgs(["--apply"])
        @Expect(hooksApply.ok, true)
        @Expect(hooksApply.args.apply, true)
        @Expect(parseGitCodeHookReconcileArgs(["--bad"]).ok, false)

        let reconcile = parseGitCodeReconcileOnceArgs(["--lookback-hours", "24", "--max-repos", "10", "--max-items", "100", "--apply"])
        @Expect(reconcile.ok, true)
        @Expect(reconcile.args.lookbackHours, 24)
        @Expect(reconcile.args.maxRepos, 10)
        @Expect(reconcile.args.maxItems, 100)
        @Expect(reconcile.args.dryRun, false)
        @Expect(parseGitCodeReconcileOnceArgs(["--timeout-ms", "1"]).ok, false)
        @Expect(parseGitCodeReconcileOnceArgs(["--max-repos", "-1"]).ok, false)
        @Expect(parseGitCodeReconcileOnceArgs(["--unknown"]).ok, false)
    }

    @TestCase
    public func webhookPayloadBuildersRedactRequesterAndRenderHumanReadableOutput(): Unit {
        let context = GatewayCommandContext(channel: "telegram", accountId: "tg-gitcode-monitor", peerId: "chat-secret", senderId: "sender-secret")
        let target = ServicePluginDeliveryTarget("telegram", "tg-gitcode-monitor", "chat-secret", replyToMessageId: "24")
        let statusPayload = buildGitCodeWebhookStatusPayload(context)
        @Expect(statusPayload.contains("chat-secret"), false)
        @Expect(statusPayload.contains("sender-secret"), false)
        @Expect(statusPayload.contains("peerHash"), true)

        let replayPayload = buildGitCodeWebhookReplayPayload(context, "delivery-1")
        @Expect(replayPayload.contains("deliveryId"), true)
        @Expect(replayPayload.contains("delivery-1"), true)
        @Expect(replayPayload.contains("Authorization"), false)
        @Expect(replayPayload.contains("token"), false)

        let reconcilePayload = buildGitCodeEventReconcilePayload(context, GitCodeEventReconcileArgs(lookbackHours: 12, maxRepos: 3, maxItems: 9, dryRun: true), target, jobId: "gcm-reconcile-1", idempotencyKey: "idem-1")
        @Expect(reconcilePayload.contains("lookbackHours"), true)
        @Expect(reconcilePayload.contains("12"), true)
        @Expect(reconcilePayload.contains("gcm-reconcile-1"), true)
        @Expect(reconcilePayload.contains("idem-1"), true)
        @Expect(reconcilePayload.contains("chat-secret"), true)
        @Expect(reconcilePayload.contains("sender-secret"), false)

        let status = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"receiver\":\"running\",\"pending\":2,\"deadLetter\":1,\"lastError\":\"\"}")
        @Expect(status.contains("GitCode Webhook 状态"), true)
        @Expect(status.contains("{\"status\""), false)
        let dead = renderGitCodeDeadLetterListResult("{\"status\":\"ok\",\"count\":1,\"latest\":\"delivery-1\",\"errorKind\":\"payload_invalid\"}")
        @Expect(dead.contains("dead-letter"), true)
        @Expect(dead.contains("payload_invalid"), true)
        let event = renderGitCodeEventReconcileResult("{\"status\":\"completed\",\"lookbackHours\":12,\"repos\":2,\"candidates\":8,\"newEvents\":1,\"drafts\":1,\"notifications\":1,\"writes\":0}", aliasFromScanOnce: true)
        @Expect(event.contains("webhook-first"), true)
        @Expect(event.contains("新增事件 1"), true)
        @Expect(event.contains("\"status\""), false)
    }

    @TestCase
    public func webhookStatusRendererUsesRuntimeFieldsAndNeverFallsBackToRawJson(): Unit {
        let running = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"configStatus\":\"valid\",\"queueStatus\":\"ready\",\"listenerStatus\":\"listening\",\"processorStatus\":\"running\",\"webhookBind\":\"127.0.0.1:18080\",\"publicBaseUrlConfigured\":true,\"queue\":{\"pending\":0,\"processing\":1,\"processed\":3,\"deadLetter\":0,\"cancelled\":0},\"lastBatchProcessed\":1,\"lastError\":\"\"}")
        @Expect(running.contains("receiver: running"), true)
        @Expect(running.contains("listener: 127.0.0.1:18080 listening"), true)
        @Expect(running.contains("queue: pending=0 processing=1 processed=3 dead-letter=0 cancelled=0"), true)
        @Expect(running.contains("processor: running lastBatchProcessed=1"), true)
        @Expect(running.contains("publicBaseUrl: configured"), true)
        @Expect(running.contains("{\"status\""), false)
        @Expect(running.contains("\"listenerStatus\""), false)

        let degraded = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"configStatus\":\"valid\",\"queueStatus\":\"ready\",\"listenerStatus\":\"not_started\",\"processorStatus\":\"running\",\"lastError\":\"Authorization: Bearer secret /Users/name/private\"}")
        @Expect(degraded.contains("receiver: degraded"), true)
        @Expect(degraded.contains("listener: not_started"), true)
        @Expect(degraded.contains("lastError: [redacted]"), true)
        @Expect(degraded.contains("secret"), false)
        @Expect(degraded.contains("/Users/"), false)

        let missingFields = renderGitCodeWebhookStatusResult("{\"status\":\"ok\"}")
        @Expect(missingFields.contains("receiver: unknown"), true)
        @Expect(missingFields.contains("listener: unknown"), true)
        @Expect(missingFields.contains("{\"status\""), false)
    }

    @TestCase
    public func hookReconcileRendererShowsHumanReadableDriftAndApplyRejection(): Unit {
        let dryRun = renderGitCodeHookReconcileResult("{\"status\":\"ok\",\"apply\":false,\"aligned\":2,\"missing\":1,\"wrong_url\":3,\"wrong_events\":4,\"auth_failed\":5,\"failed\":0}")
        @Expect(dryRun.contains("GitCode webhook hook reconcile"), true)
        @Expect(dryRun.contains("aligned=2"), true)
        @Expect(dryRun.contains("missing=1"), true)
        @Expect(dryRun.contains("wrong_url=3"), true)
        @Expect(dryRun.contains("wrong_events=4"), true)
        @Expect(dryRun.contains("auth_failed=5"), true)
        @Expect(dryRun.contains("\"status\""), false)

        let rejected = renderGitCodeHookReconcileResult("{\"status\":\"apply_rejected\",\"applyRejected\":true,\"rejectReason\":\"publicBaseUrl missing token=secret /Users/name/private\",\"aligned\":0,\"missing\":1}")
        @Expect(rejected.contains("apply rejected"), true)
        @Expect(rejected.contains("reason=[redacted]"), true)
        @Expect(rejected.contains("token=secret"), false)
        @Expect(rejected.contains("/Users/"), false)
        @Expect(rejected.contains("{\"status\""), false)
    }

    @TestCase
    public func defaultScanOnceArgsAreUnboundedAndHaveNoUserTimeout(): Unit {
        let args = parseGitCodeScanOnceArgs([])
        @Expect(args.ok, true)
        @Expect(args.args.maxRepos, 0)
        @Expect(args.args.maxItems, 0)
        @Expect(args.args.timeoutMillis, 0)

        let payload = buildGitCodeScanOncePayload(args.args)
        @Expect(payload.contains("\"maxRepos\":0"), true)
        @Expect(payload.contains("\"maxItems\":0"), true)
        @Expect(payload.contains("timeoutMillis"), false)
        @Expect(payload.contains("\"timeoutMillis\":30000"), false)
    }

    @TestCase
    public func parseAndBuildAsyncScanPayloadIncludesDeliveryTargetAndExplicitLimits(): Unit {
        let parsed = parseGitCodeCommand("/gitcode scan once --max-repos 2 --max-items 20 --offline-fixture")
        let args = parseGitCodeScanOnceArgs(parsed.args)
        @Expect(args.ok, true)
        @Expect(args.args.maxRepos, 2)
        @Expect(args.args.maxItems, 20)
        @Expect(args.args.timeoutMillis, 0)
        @Expect(args.args.offlineFixture, true)

        let target = ServicePluginDeliveryTarget("telegram", "tg-gitcode-monitor", "chat-secret", replyToMessageId: "24")
        let payload = buildGitCodeAsyncScanPayload(
            GatewayCommandContext(channel: "telegram", accountId: "tg-gitcode-monitor", peerId: "chat-secret", senderId: "sender-secret"),
            args.args,
            "gcm-scan-1",
            "idem-1",
            target
        )
        let parsedPayload = parseServicePluginJobStartPayload(payload)
        @Expect(parsedPayload.ok, true)
        @Expect(parsedPayload.payload.mode, "async")
        @Expect(parsedPayload.payload.jobId, "gcm-scan-1")
        @Expect(parsedPayload.payload.deliveryTarget.peerId, "chat-secret")
        @Expect(parsedPayload.payload.offlineFixture, true)
        @Expect(parsedPayload.payload.limits.maxRepos, 2)
        @Expect(parsedPayload.payload.limits.maxItems, 20)
        @Expect(parsedPayload.payload.limits.maxDurationMillis, 0)
        @Expect(payload.contains("\"timeoutMillis\":30000"), false)
    }

    @TestCase
    public func defaultAsyncScanPayloadCarriesNoRepoItemOrDurationLimit(): Unit {
        let target = ServicePluginDeliveryTarget("telegram", "tg-gitcode-monitor", "chat-secret", replyToMessageId: "24")
        let payload = buildGitCodeAsyncScanPayload(
            GatewayCommandContext(channel: "telegram", accountId: "tg-gitcode-monitor", peerId: "chat-secret", senderId: "sender-secret"),
            GitCodeScanOnceArgs(),
            "gcm-scan-1",
            "idem-1",
            target
        )
        let parsedPayload = parseServicePluginJobStartPayload(payload)
        @Expect(parsedPayload.ok, true)
        @Expect(parsedPayload.payload.limits.maxRepos, 0)
        @Expect(parsedPayload.payload.limits.maxItems, 0)
        @Expect(parsedPayload.payload.limits.maxDurationMillis, 0)
        @Expect(payload.contains("\"maxRepos\":5"), false)
        @Expect(payload.contains("\"maxItems\":30"), false)
        @Expect(payload.contains("\"timeoutMillis\":30000"), false)
    }

    @TestCase
    public func scanArgsRejectInvalidNumbersBeforeInvokingGcm(): Unit {
        let negative = parseGitCodeScanOnceArgs(["--max-repos", "-1"])
        @Expect(negative.ok, false)
        @Expect(negative.status, "invalid_args")
        let missing = parseGitCodeScanOnceArgs(["--max-items"])
        @Expect(missing.ok, false)
        @Expect(missing.diagnostic.contains("requires"), true)
        let unknown = parseGitCodeScanOnceArgs(["--bad"])
        @Expect(unknown.ok, false)
        @Expect(unknown.diagnostic.contains("unknown"), true)

        let timeout = parseGitCodeScanOnceArgs(["--timeout-ms", "30000"])
        @Expect(timeout.ok, false)
        @Expect(timeout.status, "invalid_args")
        @Expect(timeout.diagnostic, "--timeout-ms is no longer supported for async scan jobs")
        @Expect(timeout.diagnostic.contains("{"), false)
        @Expect(timeout.diagnostic.contains("\"ok\""), false)

        let timeoutMissing = parseGitCodeScanOnceArgs(["--timeout-ms"])
        @Expect(timeoutMissing.ok, false)
        @Expect(timeoutMissing.diagnostic, "--timeout-ms is no longer supported for async scan jobs")
    }

    @TestCase
    public func statusAndScanCommandsRespectAuthorizationAndDoNotNeedGitCodeCredentials(): Unit {
        let unauthorized = handleGitCodeStatusCommand(GatewayCommandContext(authorized: false))
        @Expect(unauthorized.ok, false)
        @Expect(unauthorized.status, "unauthorized")
        let status = handleGitCodeStatusCommand(GatewayCommandContext())
        @Expect(status.ok, true)
        @Expect(status.message.contains("running=true"), true)

        let scanDenied = handleGitCodeScanOnceCommand(GatewayCommandContext(isOperator: false), GitCodeScanOnceArgs())
        @Expect(scanDenied.ok, false)
        @Expect(scanDenied.status, "unauthorized")
        let scan = handleGitCodeScanOnceCommand(GatewayCommandContext(isOperator: true), GitCodeScanOnceArgs(maxRepos: 1, maxItems: 2))
        @Expect(scan.ok, true)
        @Expect(scan.message.contains("gitcode.monitor.scan_once"), true)
        let payload = buildGitCodeScanOncePayload(GitCodeScanOnceArgs(maxRepos: -1, maxItems: 3))
        @Expect(payload.contains("\"maxRepos\":0"), true)
        @Expect(payload.contains("token"), false)
    }

    @TestCase
    public func subscriptionsAreIdempotentScopedAndDoNotExposeBotSecrets(): Unit {
        resetGitCodePluginHostForTest()
        let target = buildGitCodeSubscriptionTarget(GatewayCommandContext(channel: "telegram", accountId: "bot-a", peerId: "chat-1", threadId: "topic-2"))
        let first = saveGitCodeSubscription(target)
        @Expect(first.ok, true)
        @Expect(first.status, "created")
        let duplicate = saveGitCodeSubscription(target)
        @Expect(duplicate.ok, true)
        @Expect(duplicate.status, "already_present")
        @Expect(listGitCodeSubscriptions().size, 1)
        @Expect(formatGitCodeSubscribeResult(first).contains("chat-1"), false)
        let removed = removeGitCodeSubscription(target)
        @Expect(removed.ok, true)
        @Expect(removed.status, "removed")
        @Expect(listGitCodeSubscriptions().size, 0)
        @Expect(removeGitCodeSubscription(target).status, "already_absent")
    }

    @TestCase
    public func knowledgeQueryBuildsAgentRequestAndBypassesGcm(): Unit {
        let result = handleGitCodeKnowledgeQueryCommand(GatewayCommandContext(sessionKey: "s1"), "HttpClient 怎么用")
        @Expect(result.ok, true)
        @Expect(result.status, "agent_request")
        @Expect(result.message.contains("CKB"), true)
        let request = buildCangjieKnowledgeAgentRequest(GatewayCommandContext(sessionKey: "s1"), "query")
        @Expect(request.ckbRequired, true)
        @Expect(request.sessionKey, "s1")
    }

    @TestCase
    public func acceptedEventsNormalizeDedupeAndRawNotificationsFanout(): Unit {
        resetGitCodePluginHostForTest()
        let target = GitCodeSubscriptionTarget("feishu", "default", "chat")
        let _ = saveGitCodeSubscription(target, scope: GitCodeSubscriptionScope(rawEvents: true, generatedReplies: false))
        let payload = "{\"eventId\":\"e1\",\"repo\":\"Cangjie/community\",\"kind\":\"issue\",\"number\":\"1\",\"author\":\"alice\",\"url\":\"https://gitcode.com/Cangjie/community/issues/1\",\"content\":\"hello\"}"
        let normalized = normalizeGitCodeAcceptedEvent(payload)
        @Expect(normalized.ok, true)
        @Expect(normalized.event.repo, "Cangjie/community")
        @Expect(normalizeGitCodeAcceptedEvent("{\"token\":\"secret\"}").ok, false)
        @Expect(dedupeGitCodeEvent(normalized.event).duplicate, false)
        @Expect(dedupeGitCodeEvent(normalized.event).duplicate, true)
        let notification = publishGitCodeRawEventNotification(normalized.event)
        @Expect(notification.ok, true)
        @Expect(notification.delivered, 1)
        @Expect(notification.message.contains("https://gitcode.com"), true)
    }

    @TestCase
    public func generatedReplyNotificationAlwaysPublishesIndependentOfAutoReply(): Unit {
        resetGitCodePluginHostForTest()
        let _ = saveGitCodeSubscription(GitCodeSubscriptionTarget("telegram", "default", "peer"), scope: GitCodeSubscriptionScope(rawEvents: false, generatedReplies: true))
        let event = GitCodeAcceptedEvent("e2", "Cangjie/stdx", "issue", "2", "bob", "https://gitcode.com/Cangjie/stdx/issues/2", "HttpClient")
        let draft = GitCodeDraftResult("summary", "draft", citations: ["ckb://evidence"], knowledgeVersion: "ckb-v1")
        let notification = publishGeneratedReplyNotification(event, draft)
        @Expect(notification.ok, true)
        @Expect(notification.delivered, 1)
        @Expect(notification.message.contains("summary"), true)
        @Expect(notification.message.contains("ckb-v1"), true)
        let disabledWriteback = dispatchWritebackApplyResult(buildGcmWritebackApplyPayload(event, draft), autoReplyEnabled: false)
        @Expect(disabledWriteback.status, "writeback_dry_run")
        let enabledWriteback = dispatchWritebackApplyResult(buildGcmWritebackApplyPayload(event, draft), autoReplyEnabled: true)
        @Expect(enabledWriteback.status, "writeback_requested")
    }

    @TestCase
    public func agentBridgeRequiresCkbEvidenceAndDegradesSafely(): Unit {
        let event = GitCodeAcceptedEvent("e3", "Cangjie/compiler", "pr", "3", "carol", "https://gitcode.com/Cangjie/compiler/pulls/3", "panic")
        let request = buildGitCodeAgentDraftRequest(event)
        @Expect(request.ckbRequired, true)
        @Expect(attachCkbEvidencePolicy(request).prompt.contains("CKB"), true)
        let ok = invokeGitCodeDraftAgent(request, ckbAvailable: true)
        @Expect(assertCkbCitationPresent(ok), true)
        let degraded = invokeGitCodeDraftAgent(request, ckbAvailable: false)
        @Expect(degraded.degraded, true)
        @Expect(degraded.needsHumanReview, true)
        @Expect(assertCkbCitationPresent(degraded), false)
    }

    @TestCase
    public func fakeSmokesCoverMetisGcmMetisCkbAndEndToEndBoundaries(): Unit {
        let gcm = runMetisGcmPluginSmoke(MetisGcmSmokeConfig(subscribers: 1))
        @Expect(gcm.ok, true)
        @Expect(gcm.notificationCount, 1)
        let ckb = runMetisCkbEvidenceSmoke(MetisCkbSmokeConfig(ckbAvailable: true))
        @Expect(assertCkbCitationPresent(ckb), true)
        let degraded = runMetisCkbEvidenceSmoke(MetisCkbSmokeConfig(ckbAvailable: false))
        @Expect(degraded.needsHumanReview, true)

        let dry = runGitCodeMonitorEndToEndSmoke(EndToEndSmokeConfig(autoReplyEnabled: false, ckbAvailable: true, subscribers: 1))
        @Expect(assertEndToEndBoundaries(dry), true)
        @Expect(dry.generatedReplySent, true)
        @Expect(dry.writebackRequested, false)
        let write = runGitCodeMonitorEndToEndSmoke(EndToEndSmokeConfig(autoReplyEnabled: true, ckbAvailable: true, subscribers: 1))
        @Expect(write.writebackRequested, true)
        let blocked = runGitCodeMonitorEndToEndSmoke(EndToEndSmokeConfig(autoReplyEnabled: true, ckbAvailable: false, subscribers: 1))
        @Expect(blocked.needsHumanReview, true)
        @Expect(blocked.writebackRequested, false)
    }
}
