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
        @Expect(parseGitCodeCommand("/gitcode scan once --max-repos 1").action, "scan_once")
        @Expect(parseGitCodeCommand("/gitcode scan status gcm-scan-1").action, "scan_status")
        @Expect(parseGitCodeCommand("/gitcode scan cancel gcm-scan-1").action, "scan_cancel")
        let query = parseGitCodeCommand("/gitcode query 如何使用 HttpClient")
        @Expect(query.action, "query")
        @Expect(query.query.contains("HttpClient"), true)
        @Expect(parseGitCodeCommand("/gitcode nope").action, "unknown")
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
