package metis.gateway.service_plugin
import std.collection.ArrayList
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonValue}

@Test
public class ServicePluginEventDispatcherTest {
    private let gitCodeReviewContractVersion = "gcm-metis-gitcode-review-v1"

    private func repeatText(text: String, count: Int64): String {
        let out = StringBuilder()
        for (_ in 0..count) {
            out.append(text)
        }
        out.toString()
    }

    private func jsonInt(obj: JsonObject, key: String): Int64 {
        try { obj.get(key).getOrThrow().asInt().getValue() } catch (_: Exception) { -1 }
    }

    private func jsonString(obj: JsonObject, key: String): String {
        try { obj.get(key).getOrThrow().asString().getValue() } catch (_: Exception) { "" }
    }

    private func jsonBool(obj: JsonObject, key: String): Bool {
        try { obj.get(key).getOrThrow().asBool().getValue() } catch (_: Exception) { false }
    }

    private func target(channel!: String = "telegram", peerId!: String = "peer-secret"): ServicePluginDeliveryTarget {
        ServicePluginDeliveryTarget(channel, "acct", peerId, replyToMessageId: "msg-1")
    }

    private func storeWithRunningJob(jobId!: String = "job-1"): ServicePluginPendingJobStore {
        let store = ServicePluginPendingJobStore()
        let _ = store.createOrGetByIdempotencyKey("gitcode-monitor", "gitcode.monitor.scan_once", jobId, "idem-${jobId}", this.target(), nowMillis: 1)
        store.markAccepted(jobId, nowMillis: 2)
        store.markRunning(jobId, stage: "scan_repo", nowMillis: 3)
        store
    }

    private func acceptedFrame(jobId!: String = "webhook-d1", eventId!: String = "gitcode:cangjie/community:pr:71", repo!: String = "cangjie/community", kind!: String = "pr", number!: String = "71", url!: String = "https://gitcode.com/cangjie/community/pulls/71", title!: String = "修复 xxx", content!: String = "please review"): ServiceFrame {
        ServiceFrame("event", "accepted-${eventId}", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.event.accepted", payload: "{\"jobId\":\"${jobId}\",\"eventId\":\"${eventId}\",\"repo\":\"${repo}\",\"kind\":\"${kind}\",\"number\":\"${number}\",\"title\":\"${title}\",\"url\":\"${url}\",\"content\":\"${content}\"}")
    }

    private func acceptedContractFrame(jobId!: String = "webhook-d1", eventId!: String = "gitcode:Cangjie/cangjie_tools:issue:123"): ServiceFrame {
        let payload = "{" +
            "\"jobId\":\"${jobId}\"," +
            "\"eventId\":\"${eventId}\"," +
            "\"repo\":\"Cangjie/cangjie_tools\"," +
            "\"kind\":\"issue\"," +
            "\"number\":\"123\"," +
            "\"title\":\"[Bug]: build failed\"," +
            "\"url\":\"https://gitcode.com/Cangjie/cangjie_tools/issues/123\"," +
            "\"content\":\"redacted compact legacy content\"," +
            "\"contractVersion\":\"${this.gitCodeReviewContractVersion}\"," +
            "\"reviewRequest\":{" +
                "\"schemaVersion\":1," +
                "\"event\":{\"eventId\":\"${eventId}\",\"eventType\":\"issue\",\"repo\":{\"fullName\":\"Cangjie/cangjie_tools\"},\"item\":{\"number\":\"123\",\"title\":\"[Bug]: build failed\",\"url\":\"https://gitcode.com/Cangjie/cangjie_tools/issues/123\"},\"comment\":{\"commentId\":\"\",\"body\":\"\",\"url\":\"\"}}," +
                "\"templates\":{\"issueKind\":\"bug\",\"fields\":{\"cjcVersion\":\"cjc 1.0.0\",\"branchVersions\":[\"main\"]}}," +
                "\"policy\":{\"requiresCkb\":true,\"requiresSourceWorkspace\":true,\"requiresCodeReview\":false}," +
                "\"diagnostics\":[]" +
            "}" +
        "}"
        ServiceFrame("event", "accepted-contract-${eventId}", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.event.accepted", payload: payload)
    }

    private func acceptedMaintainerContractFrame(jobId!: String = "webhook-d1", eventId!: String = "gitcode:Cangjie/cangjie_tools:issue:maintainer-123"): ServiceFrame {
        let payload = "{" +
            "\"jobId\":\"${jobId}\"," +
            "\"eventId\":\"${eventId}\"," +
            "\"repo\":\"Cangjie/cangjie_tools\"," +
            "\"kind\":\"issue\"," +
            "\"number\":\"123\"," +
            "\"title\":\"[Bug]: build failed\"," +
            "\"url\":\"https://gitcode.com/Cangjie/cangjie_tools/issues/123\"," +
            "\"content\":\"redacted compact legacy content\"," +
            "\"contractVersion\":\"${this.gitCodeReviewContractVersion}\"," +
            "\"reviewRequest\":{" +
                "\"schemaVersion\":1," +
                "\"event\":{\"eventId\":\"${eventId}\",\"eventType\":\"issue\",\"repo\":{\"fullName\":\"Cangjie/cangjie_tools\"},\"item\":{\"number\":\"123\",\"title\":\"[Bug]: build failed\",\"url\":\"https://gitcode.com/Cangjie/cangjie_tools/issues/123\"}}," +
                "\"maintainers\":{\"teamLeaderStatus\":\"resolved\",\"codeownerStatus\":\"resolved\",\"teamLeaders\":[{\"mention\":\"@alice\"}],\"codeowners\":[{\"mention\":\"@bob\"},{\"mention\":\"@carol\"}]}," +
                "\"diagnostics\":[]" +
            "}" +
        "}"
        ServiceFrame("event", "accepted-contract-maintainers-${eventId}", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.event.accepted", payload: payload)
    }

    private func acceptedCommentContextFrame(): ServiceFrame {
        let parentBody = this.repeatText("parent-context-", 650)
        let payload = "{" +
            "\"jobId\":\"webhook-context\"," +
            "\"eventId\":\"gitcode:Cangjie/community:comment:9003\"," +
            "\"repo\":\"Cangjie/community\"," +
            "\"kind\":\"comment\"," +
            "\"number\":\"4\"," +
            "\"commentId\":\"9003\"," +
            "\"title\":\"Issue 4\"," +
            "\"url\":\"https://gitcode.com/Cangjie/community/issues/4#note_9003\"," +
            "\"content\":\"trigger context final sentinel\"," +
            "\"contractVersion\":\"${this.gitCodeReviewContractVersion}\"," +
            "\"reviewRequest\":{" +
                "\"contractVersion\":\"${this.gitCodeReviewContractVersion}\"," +
                "\"jobId\":\"webhook-context\"," +
                "\"eventId\":\"gitcode:Cangjie/community:comment:9003\"," +
                "\"repo\":\"Cangjie/community\"," +
                "\"event\":{\"type\":\"comment\",\"itemKind\":\"issue\",\"number\":\"4\",\"commentId\":\"9003\",\"action\":\"comment\"}," +
                "\"author\":{\"login\":\"bob\"}," +
                "\"templates\":{\"issueKind\":\"question\",\"fields\":{\"branchVersions\":[]}}," +
                "\"pr\":{\"changedFiles\":[],\"reviewFindings\":[]}," +
                "\"content\":{\"title\":\"Issue 4\",\"body\":\"${parentBody}\"}," +
                "\"context\":{" +
                    "\"status\":\"resolved\"," +
                    "\"parent\":{\"kind\":\"issue\",\"number\":\"4\",\"title\":\"Issue 4\",\"body\":\"${parentBody}\",\"url\":\"https://gitcode.com/Cangjie/community/issues/4\",\"author\":\"alice\",\"authorUrl\":\"\",\"source\":\"api\"}," +
                    "\"triggerComment\":{\"id\":\"9003\",\"body\":\"trigger context final sentinel\",\"url\":\"https://gitcode.com/Cangjie/community/issues/4#note_9003\",\"author\":\"bob\",\"authorUrl\":\"\",\"createdAt\":\"\",\"createdAtMs\":3000,\"updatedAtMs\":3000}," +
                    "\"previousComments\":[{\"id\":\"9001\",\"body\":\"previous context final sentinel\",\"url\":\"https://gitcode.com/Cangjie/community/issues/4#note_9001\",\"author\":\"carol\",\"authorUrl\":\"\",\"createdAt\":\"\",\"createdAtMs\":1000,\"updatedAtMs\":1000}]," +
                    "\"previousCommentsTotal\":1," +
                    "\"previousCommentsIncluded\":1," +
                    "\"truncated\":false," +
                    "\"diagnostics\":[]" +
                "}" +
            "}" +
        "}"
        ServiceFrame("event", "accepted-comment-context", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.event.accepted", payload: payload)
    }

    private func acceptedLargeChineseReviewRequestFrame(): ServiceFrame {
        let context = this.repeatText("多轮中文上下文片段，包含历史评论和触发评论。", 1050)
        let eventId = "gitcode:Cangjie/community:comment:large-cn"
        let payload = "{" +
            "\"jobId\":\"webhook-large-cn\"," +
            "\"eventId\":\"${eventId}\"," +
            "\"repo\":\"Cangjie/community\"," +
            "\"kind\":\"comment\"," +
            "\"number\":\"4\"," +
            "\"commentId\":\"9003\"," +
            "\"title\":\"Issue 4\"," +
            "\"url\":\"https://gitcode.com/Cangjie/community/issues/4#note_9003\"," +
            "\"content\":\"触发评论\"," +
            "\"contractVersion\":\"${this.gitCodeReviewContractVersion}\"," +
            "\"reviewRequest\":{" +
                "\"schemaVersion\":1," +
                "\"event\":{\"eventId\":\"${eventId}\",\"eventType\":\"comment\",\"repo\":{\"fullName\":\"Cangjie/community\"},\"item\":{\"number\":\"4\",\"title\":\"Issue 4\",\"url\":\"https://gitcode.com/Cangjie/community/issues/4\"},\"comment\":{\"commentId\":\"9003\",\"body\":\"触发评论\",\"url\":\"https://gitcode.com/Cangjie/community/issues/4#note_9003\"}}," +
                "\"context\":{\"status\":\"resolved\",\"body\":\"中文上下文起点 ${context}\"}," +
                "\"maintainers\":{\"teamLeaderStatus\":\"resolved\",\"codeownerStatus\":\"resolved\",\"teamLeaders\":[{\"mention\":\"@alice\"}],\"codeowners\":[{\"mention\":\"@bob\"}]}," +
                "\"diagnostics\":[]" +
            "}" +
        "}"
        ServiceFrame("event", "accepted-large-cn", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.event.accepted", payload: payload)
    }

    private func registerGitCodeWritebackPlugin(): Unit {
        resetServicePluginHostForTest()
        let caps = ArrayList<ServiceCapabilityRecord>()
        caps.add(ServiceCapabilityRecord("gitcode.writeback.apply_result", "controlAction"))
        let manifest = ServicePluginManifest(
            schema: METIS_SERVICE_PLUGIN_SCHEMA,
            pluginId: "gitcode-monitor",
            displayName: "GitCode Monitor",
            kind: "service",
            protocolVersion: "1.0",
            entryCommand: "fake-gcm",
            hasConfigSchema: true,
            capabilityDeclarations: caps
        )
        let result = registerServicePlugin(ServicePluginRegistration(manifest))
        @Expect(result.ok, true)
    }

    private func resetDispatcherHooks(): Unit {
        setServicePluginEventDeliveryForTest(None)
        setServicePluginGeneratedReplyHandlerForTest(None<(ServicePluginPendingJob, ServicePluginAcceptedGitCodeEvent) -> ServicePluginGeneratedReplyResult>)
        setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
        setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
        resetServicePluginGeneratedReplyStateForTest()
        resetServicePluginHostForTest()
    }

    private func targetRows(targets: Array<ServicePluginDeliveryTarget>): ArrayList<ServicePluginDeliveryTarget> {
        let out = ArrayList<ServicePluginDeliveryTarget>()
        for (target in targets) {
            out.add(target)
        }
        out
    }

    private func assertWritebackNotificationSafe(text: String): Unit {
        @Expect(text.contains("\"ok\""), false)
        @Expect(text.contains("\"result\""), false)
        @Expect(text.contains("\"image\""), false)
        @Expect(text.contains("\"schedule\""), false)
        @Expect(text.contains("\"sessions\""), false)
        @Expect(text.contains("token"), false)
        @Expect(text.contains("/Users/"), false)
        @Expect(text.contains("auto-reply"), false)
        @Expect(text.contains("bot"), false)
        @Expect(text.contains("generated by"), false)
        @Expect(text.contains("GitCodeMonitor"), false)
        @Expect(text.contains("@Team Leader:"), false)
        @Expect(text.contains("@Codeowner:"), false)
    }

    private func dispatchWithFakeWritebackResponse(responsePayload: String, eventId!: String = "gitcode:Cangjie/cangjie_tools:issue:maintainer-response"): String {
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充回归测试。")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: responsePayload)
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        var message = ""
        try {
            let result = dispatchServicePluginEvent(this.acceptedContractFrame(eventId: eventId), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(messages.size, 1)
            message = messages[0]
        } finally {
            this.resetDispatcherHooks()
        }
        message
    }

    @TestCase
    public func webhookAcceptedEventWithoutPendingJobReportsOrphan(): Unit {
        this.resetDispatcherHooks()
        let result = dispatchServicePluginEvent(this.acceptedFrame(jobId: "job-without-pending"), store: ServicePluginPendingJobStore())
        @Expect(result.ok, false)
        @Expect(result.status, "orphan_event")
        @Expect(result.diagnostic, "pending job not found for gitcode.event.accepted")
        @Expect(result.capabilityId, "gitcode.event.accepted")
        @Expect(result.diagnosticHash.size, 64)
    }

    @TestCase
    public func orphanDetectedEventRecordsVisibleRuntimeDiagnostic(): Unit {
        // METIS-ORPHAN-P-001.
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let frame = ServiceFrame(
            "event",
            "orphan-session-1",
            "gitcode-monitor",
            method: "emitCapabilityEvent",
            capabilityId: "gitcode.monitor.orphan_detected",
            payload: "{\"ok\":true,\"status\":\"orphan_detected\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"gitcode-monitor-1\",\"pid\":1234,\"parentPid\":5678,\"port\":18080,\"orphanReason\":\"parent_lost\",\"token\":\"secret-token\",\"Authorization\":\"Bearer secret\"}"
        )
        let result = dispatchServicePluginEvent(frame, store: ServicePluginPendingJobStore())
        @Expect(result.ok, false)
        @Expect(result.status, "orphan_detected")
        @Expect(result.eventId, "gitcode-monitor-1")
        @Expect(result.diagnostic.contains("parent_lost"), true)
        @Expect(result.diagnostic.contains("pid=1234"), true)
        @Expect(result.diagnostic.contains("parentPid=5678"), true)
        @Expect(result.diagnostic.contains("port=18080"), true)
        @Expect(result.diagnostic.contains("secret-token"), false)
        @Expect(result.diagnostic.contains("Bearer secret"), false)
        recordServicePluginRuntimeDispatchForTest("gitcode-monitor", frame, result)
        match (getServicePluginSnapshot("gitcode-monitor")) {
            case Some(snapshot) =>
                @Expect(snapshot.status, "degraded")
                @Expect(snapshot.degradedReason, "orphan_detected")
                @Expect(snapshot.lastError.contains("status=orphan_detected"), true)
                @Expect(snapshot.lastError.contains("eventIdHash="), true)
                @Expect(snapshot.lastError.contains("reason=parent_lost"), true)
                @Expect(snapshot.lastError.contains("pid=1234"), true)
                @Expect(snapshot.lastError.contains("parentPid=5678"), true)
                @Expect(snapshot.lastError.contains("port=18080"), true)
                let diagnostic = renderServicePluginDiagnostics(snapshot)
                @Expect(diagnostic.contains("secret-token"), false)
                @Expect(diagnostic.contains("Bearer secret"), false)
            case None => @Expect(true, false)
        }
        this.resetDispatcherHooks()
    }

    @TestCase
    public func tP6P001OrphanDiagnosticKeepsLaterGitCodeEventsFailClosedInRuntime(): Unit {
        // METIS-ORPHAN-N-001, T-P6-P-001: once Metis records orphan_detected, later GCM business
        // frames from that process must not fan out to IM or writeback.
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let orphan = ServiceFrame(
            "event",
            "orphan-session-2",
            "gitcode-monitor",
            method: "emitCapabilityEvent",
            capabilityId: "gitcode.monitor.orphan_detected",
            payload: "{\"ok\":true,\"status\":\"orphan_detected\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"gitcode-monitor-2\",\"pid\":1234,\"parentPid\":5678,\"orphanReason\":\"parent_lost\"}"
        )
        let orphanResult = dispatchServicePluginEvent(orphan, store: ServicePluginPendingJobStore())
        recordServicePluginRuntimeDispatchForTest("gitcode-monitor", orphan, orphanResult)
        let messages = ArrayList<String>()
        let drafts = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            drafts.add("called")
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "must not run")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let accepted = this.acceptedFrame(eventId: "gitcode:cangjie/community:issue:orphan-after")
            let result = dispatchServicePluginEvent(accepted, store: ServicePluginPendingJobStore())
            recordServicePluginRuntimeDispatchForTest("gitcode-monitor", accepted, result)
            @Expect(result.ok, false)
            @Expect(result.status, "service_orphan_draining")
            @Expect(messages.size, 0)
            @Expect(drafts.size, 0)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tP6N001NormalGitCodeEventHasNoOrphanRuntimeDiagnostic(): Unit {
        // T-P6-N-001.
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "normal draft")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedFrame(eventId: "gitcode:cangjie/community:issue:normal-after"), store: ServicePluginPendingJobStore())
            recordServicePluginRuntimeDispatchForTest("gitcode-monitor", this.acceptedFrame(eventId: "gitcode:cangjie/community:issue:normal-after"), result)
            @Expect(result.ok, true)
            @Expect(result.status.contains("generated_reply"), true)
            @Expect(messages.size, 1)
            match (getServicePluginSnapshot("gitcode-monitor")) {
                case Some(snapshot) =>
                    @Expect(snapshot.degradedReason.contains("orphan"), false)
                    @Expect(snapshot.lastError.contains("orphan_detected"), false)
                case None => @Expect(true, false)
            }
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func acceptedEventInvalidPayloadStopsBeforeDeliveryAndDraft(): Unit {
        this.resetDispatcherHooks()
        let messages = ArrayList<String>()
        let draftCalls = ArrayList<String>()
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            draftCalls.add("called")
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "draft")
        }))
        try {
            let missingEventId = dispatchServicePluginEvent(this.acceptedFrame(eventId: ""), store: ServicePluginPendingJobStore())
            @Expect(missingEventId.ok, false)
            @Expect(missingEventId.status, "event_payload_invalid")
            @Expect(missingEventId.diagnostic, "missing eventId")

            let missingRepo = dispatchServicePluginEvent(this.acceptedFrame(repo: ""), store: ServicePluginPendingJobStore())
            @Expect(missingRepo.ok, false)
            @Expect(missingRepo.status, "event_payload_invalid")
            @Expect(missingRepo.diagnostic, "missing repo")

            let missingUrl = dispatchServicePluginEvent(this.acceptedFrame(url: ""), store: ServicePluginPendingJobStore())
            @Expect(missingUrl.ok, false)
            @Expect(missingUrl.status, "event_payload_invalid")
            @Expect(missingUrl.diagnostic, "missing url")
            @Expect(messages.size, 0)
            @Expect(draftCalls.size, 0)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func dispatchDiagnosticSummaryRedactsRawPayloadAndSensitiveText(): Unit {
        let frame = this.acceptedFrame(content: "Authorization: Bearer secret /Users/name/private")
        let result = ServicePluginEventDispatchResult(false, "orphan_event", diagnostic: "Authorization: Bearer secret /Users/name/private", eventId: "event-1", capabilityId: "gitcode.event.accepted")
        let summary = servicePluginDispatchDiagnosticSummary(frame, result)
        @Expect(summary.contains("serviceId=gitcode-monitor"), true)
        @Expect(summary.contains("capabilityId=gitcode.event.accepted"), true)
        @Expect(summary.contains("status=orphan_event"), true)
        @Expect(summary.contains("diagnosticHash="), true)
        @Expect(summary.contains("Authorization"), false)
        @Expect(summary.contains("Bearer"), false)
        @Expect(summary.contains("/Users/name/private"), false)
        @Expect(summary.contains("\"jobId\""), false)
    }

    @TestCase
    public func webhookAcceptedEventUsesSubscriptionFallbackAndDeliversDraft(): Unit {
        this.resetDispatcherHooks()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, target: ServicePluginDeliveryTarget =>
            @Expect(event.repo, "cangjie/community")
            @Expect(target.channel, "telegram")
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "请补充测试。")
        }))
        setServicePluginEventDeliveryForTest(Some({ target: ServicePluginDeliveryTarget, text: String =>
            @Expect(target.peerId, "tg-peer")
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedFrame(), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_degraded_delivered")
            @Expect(result.targetCount, 1)
            @Expect(result.deliverySuccess, 1)
            @Expect(result.diagnosticHash.size, 64)
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("GitCode 回复草稿"), true)
            @Expect(messages[0].contains("https://gitcode.com/cangjie/community/pulls/71"), true)
            @Expect(messages[0].contains("写回路由缺失"), true)
            @Expect(messages[0].contains("capability_missing"), true)
            @Expect(messages[0].contains("dryRun=true"), false)
            @Expect(servicePluginWebhookDispatchStatsSnapshot().size, 1)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func webhookAcceptedEventWithoutSubscribersDoesNotCallDraftHandler(): Unit {
        // A0-SUB-UT-001, A4-DIAG-UT-001, A5-E2E-UT-002
        this.resetDispatcherHooks()
        let draftCalls = ArrayList<String>()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            ArrayList<ServicePluginDeliveryTarget>()
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            draftCalls.add("called")
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "draft")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedFrame(), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(result.status, "no_subscribers")
            @Expect(result.targetCount, 0)
            @Expect(result.diagnostic.contains("当前没有 GitCode Webhook 通知目标"), true)
            @Expect(result.diagnostic.contains("/gitcode subscribe"), true)
            @Expect(draftCalls.size, 0)
            @Expect(messages.size, 0)
            let stats = servicePluginWebhookDispatchStatsJson()
            @Expect(this.jsonInt(stats, "total"), 1)
            @Expect(this.jsonInt(stats, "noSubscribers"), 1)
            @Expect(this.jsonInt(stats, "success"), 0)
            @Expect(this.jsonInt(stats, "failed"), 0)
            @Expect(this.jsonString(stats, "latestStatus"), "no_subscribers")
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func webhookAcceptedEventSupportsMultipleTargetsPartialFailureAndDedupe(): Unit {
        // A4-DIAG-NEG-001, A5-E2E-BND-001
        this.resetDispatcherHooks()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer"), this.target(channel: "feishu", peerId: "fs-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "draft")
        }))
        setServicePluginEventDeliveryForTest(Some({ target: ServicePluginDeliveryTarget, text: String =>
            messages.add("${target.channel}:${text}")
            if (target.channel == "telegram") {
                ServicePluginEventDeliveryResult(false, "send_failed", diagnostic: "tg failed")
            } else {
                ServicePluginEventDeliveryResult(true, "sent")
            }
        }))
        try {
            let first = dispatchServicePluginEvent(this.acceptedFrame(), store: ServicePluginPendingJobStore())
            @Expect(first.ok, true)
            @Expect(first.status, "generated_reply_partially_delivered")
            @Expect(first.targetCount, 2)
            @Expect(first.deliverySuccess, 1)
            @Expect(first.deliveryFailed, 1)
            @Expect(first.failureDetails.size, 1)
            @Expect(messages.size, 2)
            let stats = servicePluginWebhookDispatchStatsJson()
            @Expect(this.jsonInt(stats, "failed"), 1)
            @Expect(this.jsonString(stats, "latestStatus"), "generated_reply_partially_delivered")

            let duplicate = dispatchServicePluginEvent(this.acceptedFrame(), store: ServicePluginPendingJobStore())
            @Expect(duplicate.ok, true)
            @Expect(duplicate.status, "duplicate_event")
            @Expect(messages.size, 2)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tgU001WebhookFanoutContinuesWhenFirstTelegramSenderThrows(): Unit {
        // TG-U-001
        this.resetDispatcherHooks()
        let calls = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer"), this.target(channel: "feishu", peerId: "fs-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "draft")
        }))
        setServicePluginEventDeliveryForTest(Some({ target: ServicePluginDeliveryTarget, _text: String =>
            calls.add(target.channel)
            if (target.channel == "telegram") {
                throw Exception("telegram adapter not running Authorization: Bearer secret path=/Users/name/private")
            }
            ServicePluginEventDeliveryResult(true, "sent", messageId: "fs-msg")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedFrame(eventId: "tg-u-001"), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_partially_delivered")
            @Expect(result.deliverySuccess, 1)
            @Expect(result.deliveryFailed, 1)
            @Expect(calls.size, 2)
            @Expect(result.failureDetails.size, 1)
            @Expect(result.failureDetails[0].contains("telegram"), true)
            @Expect(result.failureDetails[0].contains("acct"), true)
            @Expect(result.failureDetails[0].contains("send_failed"), true)
            @Expect(result.failureDetails[0].contains("Authorization"), false)
            @Expect(result.failureDetails[0].contains("/Users/name/private"), false)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tgB001WebhookFanoutAttemptsAllTargetsAndRedactsFailureDetails(): Unit {
        // TG-B-001
        this.resetDispatcherHooks()
        let calls = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer"), this.target(channel: "feishu", peerId: "fs-peer"), this.target(channel: "telegram", peerId: "tg-peer-2")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "draft")
        }))
        setServicePluginEventDeliveryForTest(Some({ target: ServicePluginDeliveryTarget, _text: String =>
            calls.add("${target.channel}:${target.peerId}")
            if (target.peerId == "tg-peer") {
                throw Exception("tg1 not running token=abc Authorization: Bearer secret /Users/name/private")
            }
            if (target.peerId == "tg-peer-2") {
                ServicePluginEventDeliveryResult(false, "send_failed", diagnostic: "channel delivery returned empty message id token=abc")
            } else {
                ServicePluginEventDeliveryResult(true, "sent", messageId: "fs-msg")
            }
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedFrame(eventId: "tg-b-001"), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_partially_delivered")
            @Expect(result.deliverySuccess, 1)
            @Expect(result.deliveryFailed, 2)
            @Expect(calls.size, 3)
            @Expect(result.failureDetails.size, 2)
            for (detail in result.failureDetails) {
                @Expect(detail.contains("acct"), true)
                @Expect(detail.contains("send_failed"), true)
                @Expect(detail.contains("Authorization"), false)
                @Expect(detail.contains("Bearer"), false)
                @Expect(detail.contains("token=abc"), false)
                @Expect(detail.contains("/Users/name/private"), false)
            }
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tgP001WebhookFanoutAllTargetsSuccessReportsDelivered(): Unit {
        // TG-P-001
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let calls = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer"), this.target(channel: "feishu", peerId: "fs-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "draft")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"posted\",\"posted\":true,\"replyUrl\":\"https://gitcode.com/cangjie/community/pulls/71#note_1\"}")
        }))
        setServicePluginEventDeliveryForTest(Some({ target: ServicePluginDeliveryTarget, _text: String =>
            calls.add(target.channel)
            ServicePluginEventDeliveryResult(true, "sent", messageId: "${target.channel}-msg")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedFrame(eventId: "tg-p-001"), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_delivered")
            @Expect(result.deliverySuccess, 2)
            @Expect(result.deliveryFailed, 0)
            @Expect(calls.size, 2)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tgN001WebhookFanoutAllTargetsFailWithoutCrash(): Unit {
        // TG-N-001
        this.resetDispatcherHooks()
        let calls = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer"), this.target(channel: "feishu", peerId: "fs-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "draft")
        }))
        setServicePluginEventDeliveryForTest(Some({ target: ServicePluginDeliveryTarget, _text: String =>
            calls.add(target.channel)
            if (target.channel == "telegram") {
                throw Exception("telegram adapter not running token=abc")
            }
            ServicePluginEventDeliveryResult(false, "send_failed", diagnostic: "feishu send failed Authorization: Bearer secret")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedFrame(eventId: "tg-n-001"), store: ServicePluginPendingJobStore())
            @Expect(result.ok, false)
            @Expect(result.status, "generated_reply_delivery_failed")
            @Expect(result.deliverySuccess, 0)
            @Expect(result.deliveryFailed, 2)
            @Expect(calls.size, 2)
            @Expect(result.failureDetails.size, 2)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func a5WebhookAcceptedEventWithTelegramAndFeishuSubscribersDeliversGeneratedDraft(): Unit {
        // A5-E2E-UT-001, A5-E2E-POS-001, A5-E2E-BND-001, A4-DIAG-POS-001
        this.resetDispatcherHooks()
        let messages = ArrayList<String>()
        let draftCalls = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer"), this.target(channel: "feishu", peerId: "fs-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, target: ServicePluginDeliveryTarget =>
            draftCalls.add("${event.kind}:${target.channel}")
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "请补充测试。")
        }))
        setServicePluginEventDeliveryForTest(Some({ target: ServicePluginDeliveryTarget, text: String =>
            messages.add("${target.channel}:${text}")
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let issue = dispatchServicePluginEvent(this.acceptedFrame(eventId: "issue-1", kind: "issue", number: "1", url: "https://gitcode.com/cangjie/community/issues/1", title: "Issue title"), store: ServicePluginPendingJobStore())
            @Expect(issue.ok, true)
            @Expect(issue.status, "generated_reply_degraded_delivered")
            @Expect(issue.targetCount, 2)
            @Expect(issue.deliverySuccess, 2)
            @Expect(messages.size, 2)
            @Expect(draftCalls.size, 1)
            @Expect(messages[0].contains("GitCode 回复草稿"), true)
            @Expect(messages[0].contains("来源:"), true)
            @Expect(messages[0].contains("https://gitcode.com/cangjie/community/issues/1"), true)
            @Expect(messages[0].contains("写回路由缺失"), true)
            @Expect(messages[0].contains("capability_missing"), true)
            @Expect(messages[0].contains("dryRun=true"), false)

            for (_ in 0..9) {
                let duplicate = dispatchServicePluginEvent(this.acceptedFrame(eventId: "issue-1", kind: "issue", number: "1", url: "https://gitcode.com/cangjie/community/issues/1", title: "Issue title"), store: ServicePluginPendingJobStore())
                @Expect(duplicate.ok, true)
                @Expect(duplicate.status, "duplicate_event")
            }
            @Expect(messages.size, 2)
            @Expect(draftCalls.size, 1)

            @Expect(dispatchServicePluginEvent(this.acceptedFrame(eventId: "pr-1", kind: "pr", number: "2", url: "https://gitcode.com/cangjie/community/pulls/2"), store: ServicePluginPendingJobStore()).status, "generated_reply_degraded_delivered")
            @Expect(dispatchServicePluginEvent(this.acceptedFrame(eventId: "comment-1", kind: "comment", number: "2", url: "https://gitcode.com/cangjie/community/pulls/2#note_9", content: "comment"), store: ServicePluginPendingJobStore()).status, "generated_reply_degraded_delivered")
            @Expect(messages[2].contains("/pulls/2"), true)
            @Expect(messages[4].contains("#note_9"), true)

            let stats = servicePluginWebhookDispatchStatsJson()
            @Expect(this.jsonInt(stats, "success"), 3)
            @Expect(this.jsonInt(stats, "telegram"), 1)
            @Expect(this.jsonInt(stats, "feishu"), 1)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func a5WebhookAcceptedEventRedactsSecretsFromDraftPromptMessageAndDiagnostic(): Unit {
        // A5-E2E-NEG-001
        this.resetDispatcherHooks()
        let messages = ArrayList<String>()
        let prompts = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            prompts.add(event.content)
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "safe draft")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent", diagnostic: "Authorization: Bearer secret token=abc")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedFrame(content: "Authorization: Bearer secret token=abc https://gitcode.com/cangjie/community/issues/1"), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(result.diagnostic.contains("Bearer secret"), false)
            @Expect(prompts[0].contains("Bearer secret"), false)
            @Expect(prompts[0].contains("token=abc"), false)
            @Expect(messages[0].contains("Bearer secret"), false)
            @Expect(messages[0].contains("token=abc"), false)
            @Expect(messages[0].contains("https://gitcode.com/cangjie/community/pulls/71"), true)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func a4WebhookDispatchStatsKeepLatestFiftyRows(): Unit {
        // A4-DIAG-BND-001
        this.resetDispatcherHooks()
        try {
            for (i in 0..60) {
                recordServicePluginWebhookDispatchStatForTest(ServicePluginWebhookDispatchStat("event-${i}", "hash-${i}", "generated_reply_delivered", 2, 2, 0, diagnosticHash: "diag-${i}", noSubscriberCount: 0, telegram: 1, feishu: 1, updatedAtMs: i))
            }
            let rows = servicePluginWebhookDispatchStatsSnapshot()
            @Expect(rows.size, 50)
            @Expect(rows[0].eventId, "event-10")
            @Expect(rows[49].eventId, "event-59")
            let stats = servicePluginWebhookDispatchStatsJson()
            @Expect(this.jsonInt(stats, "total"), 50)
            @Expect(this.jsonString(stats, "latestStatus"), "generated_reply_delivered")
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func dispatchCompletedFailedAndCancelledEventsToOriginalTarget(): Unit {
        let messages = ArrayList<String>()
        setServicePluginEventDeliveryForTest(Some({ target: ServicePluginDeliveryTarget, text: String =>
            @Expect(target.peerId, "peer-secret")
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent", messageId: "m-${messages.size}")
        }))
        try {
            let store = this.storeWithRunningJob()
            let completed = ServiceFrame("event", "e1", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.monitor.scan_completed", payload: "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"job-1\",\"accepted\":2,\"ignored\":1,\"emitted\":3,\"durationMs\":1200,\"stateSaved\":true}")
            let result = dispatchServicePluginEvent(completed, store: store)
            @Expect(result.ok, true)
            @Expect(result.status, "completed_delivered")
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("GitCode 扫描完成"), true)
            @Expect(messages[0].contains("accepted=2"), true)
            @Expect((store.findByJobId("job-1") ?? ServicePluginPendingJob()).status, "completed_delivered")

            let duplicate = dispatchServicePluginEvent(completed, store: store)
            @Expect(duplicate.status, "duplicate_event")
            @Expect(messages.size, 1)

            let failedStore = this.storeWithRunningJob(jobId: "job-2")
            let failed = ServiceFrame("event", "e2", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.monitor.scan_failed", payload: "{\"ok\":false,\"status\":\"failed\",\"jobId\":\"job-2\",\"stage\":\"list_repos\",\"errorKind\":\"gitcode_timeout\",\"diagnostic\":\"Authorization: Bearer secret /Users/name/private\"}")
            let failedResult = dispatchServicePluginEvent(failed, store: failedStore)
            @Expect(failedResult.ok, true)
            @Expect(messages[1].contains("GitCode 扫描失败"), true)
            @Expect(messages[1].contains("secret"), false)
            @Expect(messages[1].contains("/Users/"), false)
        } finally {
            setServicePluginEventDeliveryForTest(None)
        }
    }

    @TestCase
    public func dispatchEpochGuardCancelsBeforeIrreversibleDelivery(): Unit {
        let messages = ArrayList<String>()
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let store = this.storeWithRunningJob(jobId: "epoch-guard-job")
            let completed = ServiceFrame("event", "epoch-guard-event", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.monitor.scan_completed", payload: "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"epoch-guard-job\",\"accepted\":1,\"ignored\":0,\"emitted\":1,\"durationMs\":1,\"stateSaved\":true}")
            let result = dispatchServicePluginEvent(completed, store: store, dispatchAllowed: { => false })
            @Expect(result.ok, false)
            @Expect(result.status, "dispatch_cancelled")
            @Expect(messages.size, 0)
            @Expect((store.findByJobId("epoch-guard-job") ?? ServicePluginPendingJob()).status, "running")
        } finally {
            setServicePluginEventDeliveryForTest(None)
        }
    }

    @TestCase
    public func dispatchRejectsUnknownInvalidAndProgressDoesNotDeliver(): Unit {
        let messages = ArrayList<String>()
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let store = this.storeWithRunningJob()
            let progress = ServiceFrame("event", "p1", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.monitor.scan_progress", payload: "{\"ok\":true,\"status\":\"progress\",\"jobId\":\"job-1\",\"stage\":\"scan_repo\",\"accepted\":1}")
            let progressResult = dispatchServicePluginEvent(progress, store: store)
            @Expect(progressResult.ok, true)
            @Expect(progressResult.status, "progress_recorded")
            @Expect(messages.size, 0)
            @Expect((store.findByJobId("job-1") ?? ServicePluginPendingJob()).stage, "scan_repo")

            let unknown = dispatchServicePluginEvent(ServiceFrame("event", "e3", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.monitor.scan_completed", payload: "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"missing\"}"), store: store)
            @Expect(unknown.ok, false)
            @Expect(unknown.status, "orphan_event")
            @Expect(messages.size, 0)

            let mismatch = dispatchServicePluginEvent(ServiceFrame("event", "e4", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.monitor.scan_failed", payload: "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"job-1\"}"), store: store)
            @Expect(mismatch.ok, false)
            @Expect(mismatch.status, "event_payload_invalid")
        } finally {
            setServicePluginEventDeliveryForTest(None)
        }
    }

    @TestCase
    public func acceptedGitCodeEventIsRecordedWithoutBreakingTerminalDelivery(): Unit {
        let messages = ArrayList<String>()
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        setServicePluginGeneratedReplyHandlerForTest(Some({ _job: ServicePluginPendingJob, event: ServicePluginAcceptedGitCodeEvent =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "请补充 ${event.repo} 的对应测试。")
        }))
        resetServicePluginGeneratedReplyStateForTest()
        try {
            let store = this.storeWithRunningJob()
            let accepted = ServiceFrame("event", "a1", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.event.accepted", payload: "{\"jobId\":\"job-1\",\"eventId\":\"e1\",\"repo\":\"cangjie/community\",\"kind\":\"pr\",\"number\":71,\"title\":\"修复 xxx\",\"url\":\"https://gitcode.com/cangjie/community/pulls/71\"}")
            let acceptedResult = dispatchServicePluginEvent(accepted, store: store)
            @Expect(acceptedResult.ok, true)
            @Expect(acceptedResult.status, "generated_reply_degraded_delivered")
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("GitCode 回复草稿"), true)
            @Expect(messages[0].contains("来源: cangjie/community PR #71 https://gitcode.com/cangjie/community/pulls/71"), true)
            @Expect(messages[0].contains("标题: 修复 xxx"), true)
            @Expect(messages[0].contains("请补充 cangjie/community 的对应测试。"), true)
            @Expect(messages[0].contains("写回路由缺失"), true)
            @Expect(messages[0].contains("capability_missing"), true)
            @Expect(messages[0].contains("dryRun=true"), false)
            @Expect(messages[0].contains("\"eventId\""), false)
            @Expect((store.findByJobId("job-1") ?? ServicePluginPendingJob()).status, "running")

            let duplicate = dispatchServicePluginEvent(accepted, store: store)
            @Expect(duplicate.status, "duplicate_event")
            @Expect(messages.size, 1)

            let completed = ServiceFrame("event", "e1", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.monitor.scan_completed", payload: "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"job-1\",\"accepted\":1,\"ignored\":0,\"emitted\":1,\"durationMs\":1200,\"stateSaved\":true}")
            let completedResult = dispatchServicePluginEvent(completed, store: store)
            @Expect(completedResult.ok, true)
            @Expect(completedResult.status, "completed_delivered")
            @Expect(messages.size, 2)
            @Expect(messages[1].contains("GitCode 扫描完成"), true)
            @Expect(messages[1].contains("回复草稿状态"), true)
            @Expect(messages[1].contains("已生成草稿 1 条"), true)
        } finally {
            setServicePluginEventDeliveryForTest(None)
            setServicePluginGeneratedReplyHandlerForTest(None<(ServicePluginPendingJob, ServicePluginAcceptedGitCodeEvent) -> ServicePluginGeneratedReplyResult>)
            resetServicePluginGeneratedReplyStateForTest()
        }
    }

    @TestCase
    public func acceptedGitCodePrIssueAndCommentEventsRenderSafeUserVisibleDrafts(): Unit {
        let messages = ArrayList<String>()
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        setServicePluginGeneratedReplyHandlerForTest(Some({ _job: ServicePluginPendingJob, event: ServicePluginAcceptedGitCodeEvent =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "draft for ${event.kind}: ${event.content}")
        }))
        resetServicePluginGeneratedReplyStateForTest()
        try {
            let store = ServicePluginPendingJobStore()
            let _ = store.createOrGetByIdempotencyKey("gitcode-monitor", "gitcode.webhook.reconcile_events", "job-pr", "idem-pr", this.target(), nowMillis: 1)
            let _ = store.createOrGetByIdempotencyKey("gitcode-monitor", "gitcode.webhook.reconcile_events", "job-issue", "idem-issue", this.target(), nowMillis: 1)
            let _ = store.createOrGetByIdempotencyKey("gitcode-monitor", "gitcode.webhook.reconcile_events", "job-comment", "idem-comment", this.target(), nowMillis: 1)
            store.markAccepted("job-pr", nowMillis: 2)
            store.markAccepted("job-issue", nowMillis: 2)
            store.markAccepted("job-comment", nowMillis: 2)

            let pr = ServiceFrame("event", "accepted-pr", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.event.accepted", payload: "{\"jobId\":\"job-pr\",\"eventId\":\"event-pr\",\"repo\":\"cangjie/community\",\"kind\":\"pr\",\"number\":\"71\",\"title\":\"PR title\",\"url\":\"https://gitcode.com/cangjie/community/pulls/71\",\"author\":\"alice\",\"content\":\"please review\"}")
            let issue = ServiceFrame("event", "accepted-issue", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.event.accepted", payload: "{\"jobId\":\"job-issue\",\"eventId\":\"event-issue\",\"repo\":\"cangjie/community\",\"kind\":\"issue\",\"number\":\"72\",\"title\":\"Issue title\",\"url\":\"https://gitcode.com/cangjie/community/issues/72\",\"author\":\"bob\",\"content\":\"bug report\"}")
            let comment = ServiceFrame("event", "accepted-comment", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.event.accepted", payload: "{\"jobId\":\"job-comment\",\"eventId\":\"event-comment\",\"repo\":\"cangjie/community\",\"kind\":\"comment\",\"number\":\"71\",\"commentId\":\"9001\",\"title\":\"Comment title\",\"url\":\"https://gitcode.com/cangjie/community/pulls/71#note_9001\",\"author\":\"carol\",\"content\":\"Authorization: Bearer secret token=abc path=/Users/name/private\"}")

            @Expect(dispatchServicePluginEvent(pr, store: store).status, "generated_reply_degraded_delivered")
            @Expect(dispatchServicePluginEvent(issue, store: store).status, "generated_reply_degraded_delivered")
            @Expect(dispatchServicePluginEvent(comment, store: store).status, "generated_reply_degraded_delivered")
            @Expect(messages.size, 3)

            @Expect(messages[0].contains("来源: cangjie/community PR #71 https://gitcode.com/cangjie/community/pulls/71"), true)
            @Expect(messages[0].contains("标题: PR title"), true)
            @Expect(messages[0].contains("写回路由缺失"), true)
            @Expect(messages[0].contains("capability_missing"), true)
            @Expect(messages[0].contains("dryRun=true"), false)
            @Expect(messages[1].contains("来源: cangjie/community Issue #72 https://gitcode.com/cangjie/community/issues/72"), true)
            @Expect(messages[1].contains("标题: Issue title"), true)
            @Expect(messages[1].contains("写回路由缺失"), true)
            @Expect(messages[1].contains("capability_missing"), true)
            @Expect(messages[1].contains("dryRun=true"), false)
            @Expect(messages[2].contains("来源: cangjie/community Comment #71 comment #9001 https://gitcode.com/cangjie/community/pulls/71#note_9001"), true)
            @Expect(messages[2].contains("标题: Comment title"), true)
            @Expect(messages[2].contains("写回路由缺失"), true)
            @Expect(messages[2].contains("capability_missing"), true)
            @Expect(messages[2].contains("dryRun=true"), false)

            for (message in messages) {
                @Expect(message.contains("\"jobId\""), false)
                @Expect(message.contains("\"eventId\""), false)
                @Expect(message.contains("Authorization"), false)
                @Expect(message.contains("Bearer secret"), false)
                @Expect(message.contains("token=abc"), false)
                @Expect(message.contains("/Users/"), false)
            }
        } finally {
            setServicePluginEventDeliveryForTest(None)
            setServicePluginGeneratedReplyHandlerForTest(None<(ServicePluginPendingJob, ServicePluginAcceptedGitCodeEvent) -> ServicePluginGeneratedReplyResult>)
            resetServicePluginGeneratedReplyStateForTest()
        }
    }

    @TestCase
    public func baselineOnlyCompletedEventDoesNotTriggerGeneratedReply(): Unit {
        let messages = ArrayList<String>()
        let generatedCalls = ArrayList<String>()
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        setServicePluginGeneratedReplyHandlerForTest(Some({ _job: ServicePluginPendingJob, _event: ServicePluginAcceptedGitCodeEvent =>
            generatedCalls.add("called")
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "should not be generated")
        }))
        resetServicePluginGeneratedReplyStateForTest()
        try {
            let store = this.storeWithRunningJob(jobId: "baseline-only")
            let completed = ServiceFrame("event", "baseline-completed", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.monitor.scan_completed", payload: "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"baseline-only\",\"accepted\":0,\"ignored\":31,\"emitted\":0,\"durationMs\":1200,\"stateSaved\":true,\"report\":{\"scannedRepos\":2,\"checkedItems\":31,\"newEvents\":0,\"duplicateEvents\":0,\"filteredEvents\":0,\"failedEvents\":0,\"draftsGenerated\":0,\"draftsFailed\":0,\"notificationsSent\":0,\"writes\":0,\"writeMode\":\"dry_run\",\"baseline\":{\"enabled\":true,\"createdScopes\":2,\"seededEvents\":31,\"backfill\":false,\"status\":\"created\"}}}")
            let result = dispatchServicePluginEvent(completed, store: store)
            @Expect(result.ok, true)
            @Expect(result.status, "completed_delivered")
            @Expect(generatedCalls.size, 0)
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("模式: 首次基线"), true)
            @Expect(messages[0].contains("GitCode 回复草稿"), false)
            @Expect(messages[0].contains("回复草稿状态"), false)
        } finally {
            setServicePluginEventDeliveryForTest(None)
            setServicePluginGeneratedReplyHandlerForTest(None<(ServicePluginPendingJob, ServicePluginAcceptedGitCodeEvent) -> ServicePluginGeneratedReplyResult>)
            resetServicePluginGeneratedReplyStateForTest()
        }
    }

    @TestCase
    public func acceptedGitCodeEventSendsDegradedNotificationWhenDraftFails(): Unit {
        let messages = ArrayList<String>()
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        setServicePluginGeneratedReplyHandlerForTest(Some({ _job: ServicePluginPendingJob, _event: ServicePluginAcceptedGitCodeEvent =>
            ServicePluginGeneratedReplyResult(false, status: "llm_degraded", diagnostic: "LLM timeout", needsHumanReview: true)
        }))
        resetServicePluginGeneratedReplyStateForTest()
        try {
            let store = this.storeWithRunningJob()
            let accepted = ServiceFrame("event", "a2", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.event.accepted", payload: "{\"jobId\":\"job-1\",\"eventId\":\"e2\",\"repo\":\"cangjie/community\",\"kind\":\"issue\",\"number\":\"72\",\"url\":\"https://gitcode.com/cangjie/community/issues/72\"}")
            let acceptedResult = dispatchServicePluginEvent(accepted, store: store)
            @Expect(acceptedResult.ok, true)
            @Expect(acceptedResult.status, "generated_reply_degraded_delivered")
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("状态: needsHumanReview"), true)
            @Expect(messages[0].contains("LLM timeout"), true)

            let completed = ServiceFrame("event", "e2", "gitcode-monitor", method: "emitCapabilityEvent", capabilityId: "gitcode.monitor.scan_completed", payload: "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"job-1\",\"accepted\":1,\"ignored\":0,\"emitted\":1,\"durationMs\":1200,\"stateSaved\":true}")
            let completedResult = dispatchServicePluginEvent(completed, store: store)
            @Expect(completedResult.ok, true)
            @Expect(messages[messages.size - 1].contains("生成失败 1 条"), true)
        } finally {
            setServicePluginEventDeliveryForTest(None)
            setServicePluginGeneratedReplyHandlerForTest(None<(ServicePluginPendingJob, ServicePluginAcceptedGitCodeEvent) -> ServicePluginGeneratedReplyResult>)
            resetServicePluginGeneratedReplyStateForTest()
        }
    }

    @TestCase
    public func tWriteback011DispatcherInvokesApplyResultWithContractPayload(): Unit {
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let calls = ArrayList<String>()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            @Expect(event.contractVersion, this.gitCodeReviewContractVersion)
            @Expect(event.reviewRequestRaw.contains("\"schemaVersion\""), true)
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充回归测试。")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            calls.add(request.capabilityId)
            @Expect(request.capabilityId, "gitcode.writeback.apply_result")
            @Expect(request.timeoutMillis, 15000)
            @Expect(request.payload.contains("\"contractVersion\""), true)
            @Expect(request.payload.contains(this.gitCodeReviewContractVersion), true)
            @Expect(request.payload.contains("\"eventId\""), true)
            @Expect(request.payload.contains("gitcode:Cangjie/cangjie_tools:issue:123"), true)
            @Expect(request.payload.contains("\"draft\""), true)
            @Expect(request.payload.contains("建议补充回归测试。"), true)
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"skipped\",\"posted\":false,\"reason\":\"dry_run\"}")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedContractFrame(), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(calls.toArray(), ["gitcode.writeback.apply_result"])
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("写回未执行"), true)
            @Expect(messages[0].contains("\"status\""), false)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tMaintainerEmailT0T2T5PayloadStaysMinimalAndDoesNotCarryMaintainerFacts(): Unit {
        // T0-METIS-UNIT-001, T2-METIS-REG-001, T5-E2E-POS-002.
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let payloads = ArrayList<String>()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            @Expect(event.reviewRequestRaw.contains("\"maintainers\""), true)
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充回归测试。")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            payloads.add(request.payload)
            let root = JsonValue.fromStr(request.payload).asObject()
            @Expect(this.jsonString(root, "contractVersion"), this.gitCodeReviewContractVersion)
            @Expect(this.jsonString(root, "eventId"), "gitcode:Cangjie/cangjie_tools:issue:maintainer-123")
            @Expect(this.jsonString(root, "repo"), "Cangjie/cangjie_tools")
            @Expect(this.jsonString(root, "kind"), "issue")
            @Expect(this.jsonString(root, "number"), "123")
            @Expect(this.jsonString(root, "commentId"), "")
            @Expect(this.jsonString(root, "url"), "https://gitcode.com/Cangjie/cangjie_tools/issues/123")
            @Expect(this.jsonString(root, "draft"), "建议补充回归测试。")
            @Expect(this.jsonString(root, "summary"), "")
            @Expect(this.jsonString(root, "safety"), "approved")
            @Expect(this.jsonBool(root, "needsHumanReview"), false)
            @Expect(request.payload.contains("\"maintainers\""), false)
            @Expect(request.payload.contains("\"reviewRequest\""), false)
            @Expect(request.payload.contains("\"teamLeaderCount\""), false)
            @Expect(request.payload.contains("\"codeownerCount\""), false)
            @Expect(request.payload.contains("\"emailNotificationStatus\""), false)
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"posted\",\"posted\":true,\"replyUrl\":\"https://gitcode.com/Cangjie/cangjie_tools/issues/123#note_9\"}")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedMaintainerContractFrame(), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_delivered")
            @Expect(payloads.size, 1)
            @Expect(messages.size, 1)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func draftM3B001PendingJobJsonArrayDraftNeedsHumanReviewWithoutWriteback(): Unit {
        // DRAFT-M3-B-001.
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let calls = ArrayList<String>()
        let messages = ArrayList<String>()
        setServicePluginGeneratedReplyHandlerForTest(Some({ _job: ServicePluginPendingJob, _event: ServicePluginAcceptedGitCodeEvent =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "[]")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            calls.add(request.capabilityId)
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"posted\",\"posted\":true}")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let store = this.storeWithRunningJob(jobId: "draft-m3-b-001")
            let accepted = this.acceptedFrame(jobId: "draft-m3-b-001", eventId: "gitcode:cangjie/community:issue:draft-m3-b-001")
            let result = dispatchServicePluginEvent(accepted, store: store)

            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_degraded_delivered")
            @Expect(calls.size, 0)
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("状态: needsHumanReview"), true)
            @Expect(messages[0].contains("原始 JSON"), true)
            @Expect(messages[0].contains("[]"), false)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func draftM3P001WebhookValidDraftWritesBackOnceAndNotifiesDraft(): Unit {
        // DRAFT-M3-P-001.
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let calls = ArrayList<String>()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充回归测试。")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            calls.add(request.capabilityId)
            @Expect(request.capabilityId, "gitcode.writeback.apply_result")
            @Expect(request.payload.contains("建议补充回归测试。"), true)
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"posted\",\"posted\":true,\"replyUrl\":\"https://gitcode.com/Cangjie/cangjie_tools/issues/123#note_9\"}")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedContractFrame(eventId: "gitcode:Cangjie/cangjie_tools:issue:draft-m3-p-001"), store: ServicePluginPendingJobStore())

            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_delivered")
            @Expect(calls.toArray(), ["gitcode.writeback.apply_result"])
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("建议补充回归测试。"), true)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func draftM3N001WebhookToolJsonDraftDoesNotWriteBackOrLeakRawJson(): Unit {
        // DRAFT-M3-N-001.
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let calls = ArrayList<String>()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "{\"tool\":\"functions._answer_\",\"reason\":\"当前任务只需要输出中文回复草稿\"}")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            calls.add(request.capabilityId)
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"posted\",\"posted\":true}")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedContractFrame(eventId: "gitcode:Cangjie/cangjie_tools:issue:draft-m3-n-001"), store: ServicePluginPendingJobStore())

            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_degraded_delivered")
            @Expect(calls.size, 0)
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("模型返回了工具调用 JSON"), true)
            @Expect(messages[0].contains("\"tool\""), false)
            @Expect(messages[0].contains("functions._answer_"), false)
            @Expect(messages[0].contains("\"reason\""), false)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func r4E2E002WebhookUnfinalizedToolProtocolDoesNotWriteBackOrLeakProtocol(): Unit {
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let calls = ArrayList<String>()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(false, status: "tool_protocol_unfinalized", diagnostic: "assistant to=functions.search {\"query\":\"secret\"}", needsHumanReview: true)
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            calls.add(request.capabilityId)
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"posted\",\"posted\":true}")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedContractFrame(eventId: "gitcode:Cangjie/cangjie_tools:issue:r4-e2e-002"), store: ServicePluginPendingJobStore())

            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_degraded_delivered")
            @Expect(calls.size, 0)
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("模型工具调用未收敛为最终文本，已转人工确认"), true)
            @Expect(messages[0].contains("functions.search"), false)
            @Expect(messages[0].contains("\"query\""), false)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func draftM3N002WebhookSecretDraftDoesNotWriteBackOrLeakSecret(): Unit {
        // DRAFT-M3-N-002.
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let calls = ArrayList<String>()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "token=secret")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            calls.add(request.capabilityId)
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"posted\",\"posted\":true}")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedContractFrame(eventId: "gitcode:Cangjie/cangjie_tools:issue:draft-m3-n-002"), store: ServicePluginPendingJobStore())

            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_degraded_delivered")
            @Expect(calls.size, 0)
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("敏感信息"), true)
            @Expect(messages[0].contains("secret"), false)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tDraftGuard001ToolJsonDraftDoesNotInvokeWriteback(): Unit {
        // DRAFT-E2E-001.
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let calls = ArrayList<String>()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "{\"tool\":\"functions._answer_\",\"reason\":\"当前任务只需要输出中文回复草稿\"}")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            calls.add(request.capabilityId)
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"posted\",\"posted\":true}")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedContractFrame(eventId: "gitcode:Cangjie/cangjie_tools:issue:draft-e2e-001"), store: ServicePluginPendingJobStore())

            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_degraded_delivered")
            @Expect(calls.size, 0)
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("状态: needsHumanReview"), true)
            @Expect(messages[0].contains("模型返回了工具调用 JSON"), true)
            @Expect(messages[0].contains("\"tool\""), false)
            @Expect(messages[0].contains("functions._answer_"), false)
            @Expect(messages[0].contains("\"reason\""), false)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tDraftGuard002SafeDraftStillInvokesWriteback(): Unit {
        // DRAFT-E2E-002.
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let calls = ArrayList<String>()
        let payloads = ArrayList<String>()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充回归测试。")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            calls.add(request.capabilityId)
            payloads.add(request.payload)
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"posted\",\"posted\":true}")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedContractFrame(eventId: "gitcode:Cangjie/cangjie_tools:issue:draft-e2e-002"), store: ServicePluginPendingJobStore())

            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_delivered")
            @Expect(calls.toArray(), ["gitcode.writeback.apply_result"])
            @Expect(payloads.size, 1)
            @Expect(payloads[0].contains("\"contractVersion\""), true)
            @Expect(payloads[0].contains(this.gitCodeReviewContractVersion), true)
            @Expect(payloads[0].contains("\"draft\""), true)
            @Expect(payloads[0].contains("建议补充回归测试。"), true)
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("建议补充回归测试。"), true)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func draftM4U002NeedsHumanReviewDraftNotificationDoesNotRenderDryRun(): Unit {
        // M4-U-002.
        let event = ServicePluginAcceptedGitCodeEvent(repo: "Cangjie/community", kind: "issue", number: "1", url: "https://gitcode.com/Cangjie/community/issues/1")
        let text = renderServicePluginGeneratedReplyNotification(
            event,
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "证据不足，请人工确认。", needsHumanReview: true)
        )
        @Expect(text.contains("状态: needsHumanReview"), true)
        @Expect(text.contains("已生成草稿但需要人工审核，未写回 GitCode"), true)
        @Expect(text.contains("证据不足，请人工确认。"), true)
        @Expect(text.contains("dryRun=true"), false)
        @Expect(text.contains("\"status\""), false)
        @Expect(text.contains("{"), false)
    }

    @TestCase
    public func draftM4U002WebhookNeedsHumanReviewDraftSkipsWriteback(): Unit {
        // M4-U-002.
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let calls = ArrayList<String>()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "证据不足，请人工确认。", needsHumanReview: true)
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            calls.add(request.capabilityId)
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"posted\",\"posted\":true}")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedContractFrame(eventId: "gitcode:Cangjie/cangjie_tools:issue:draft-m4-u-002"), store: ServicePluginPendingJobStore())

            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_degraded_delivered")
            @Expect(calls.size, 0)
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("状态: needsHumanReview"), true)
            @Expect(messages[0].contains("已生成草稿但需要人工审核，未写回 GitCode"), true)
            @Expect(messages[0].contains("证据不足，请人工确认。"), true)
            @Expect(messages[0].contains("dryRun=true"), false)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tContext001DispatcherPreservesLargeCommentReviewRequestContext(): Unit {
        this.resetDispatcherHooks()
        let calls = ArrayList<String>()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            calls.add(event.eventId)
            @Expect(event.reviewRequestRaw.contains("\"context\""), true)
            @Expect(event.reviewRequestRaw.contains("trigger context final sentinel"), true)
            @Expect(event.reviewRequestRaw.contains("previous context final sentinel"), true)
            ServicePluginGeneratedReplyResult(false, status: "llm_degraded", diagnostic: "test degraded", needsHumanReview: true)
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedCommentContextFrame(), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_degraded_delivered")
            @Expect(calls.size, 1)
            @Expect(messages.size, 1)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tMaintainerEmailT5Bound003LargeChineseReviewRequestDoesNotPolluteWriteback(): Unit {
        // T5-E2E-BOUND-003.
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let payloads = ArrayList<String>()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            @Expect(event.reviewRequestRaw.contains("中文上下文起点"), true)
            @Expect(event.reviewRequestRaw.contains("\"maintainers\""), true)
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充中文上下文回归测试。")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            payloads.add(request.payload)
            @Expect(request.payload.contains("\"eventId\""), true)
            @Expect(request.payload.contains("gitcode:Cangjie/community:comment:large-cn"), true)
            @Expect(request.payload.contains("\"draft\""), true)
            @Expect(request.payload.contains("建议补充中文上下文回归测试。"), true)
            @Expect(request.payload.contains("\"reviewRequest\""), false)
            @Expect(request.payload.contains("\"maintainers\""), false)
            @Expect(request.payload.contains("中文上下文起点"), false)
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"posted\",\"posted\":true,\"maintainerMentionAppended\":true,\"teamLeaderCount\":1,\"codeownerCount\":1,\"contextSource\":\"store\",\"emailNotificationStatus\":\"email_unavailable\"}")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedLargeChineseReviewRequestFrame(), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_delivered")
            @Expect(payloads.size, 1)
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("维护者提及: 已追加 teamLeader=1 codeowner=1"), true)
            @Expect(messages[0].contains("维护者邮件: 无可用邮箱"), true)
            this.assertWritebackNotificationSafe(messages[0])
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tWriteback012TimeoutStillNotifiesDraft(): Unit {
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "草稿仍需通知。")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            CapabilityInvokeResult(false, "invoke_timeout", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, diagnostic: "timeout")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedContractFrame(), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_degraded_delivered")
            @Expect(messages[0].contains("写回状态未知/超时"), true)
            @Expect(messages[0].contains("草稿仍需通知。"), true)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tSuite005RouteMissingWritebackIsVisibleAndNotDryRun(): Unit {
        // T-SUITE-005
        this.resetDispatcherHooks()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "已生成草稿。")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedContractFrame(eventId: "gitcode:Cangjie/cangjie_tools:issue:route-missing"), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_degraded_delivered")
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("写回路由缺失"), true)
            @Expect(messages[0].contains("capability_missing"), true)
            @Expect(messages[0].contains("dryRun=true"), false)
            @Expect(messages[0].contains("\"status\""), false)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tSuite005ServiceMissingWritebackStateRendersVisibleDiagnostic(): Unit {
        // T-SUITE-005
        let event = ServicePluginAcceptedGitCodeEvent(repo: "Cangjie/community", kind: "issue", number: "1", url: "https://gitcode.com/Cangjie/community/issues/1")
        let text = renderServicePluginGeneratedReplyNotification(
            event,
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "草稿。"),
            writeback: ServicePluginWritebackApplyState(configured: true, ok: false, status: "service_missing", diagnostic: "registered route points to missing service")
        )
        @Expect(text.contains("写回服务缺失"), true)
        @Expect(text.contains("service_missing"), true)
        @Expect(text.contains("dryRun=true"), false)
        @Expect(text.contains("\"status\""), false)
    }

    @TestCase
    public func tWriteback013MalformedResponseIsHumanReadable(): Unit {
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "草稿")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "not-json")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedContractFrame(), store: ServicePluginPendingJobStore())
            @Expect(result.status, "generated_reply_degraded_delivered")
            @Expect(messages[0].contains("writeback_response_decode_failed"), true)
            @Expect(messages[0].contains("not-json"), false)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tWriteback014PostedResponseRendersReplyUrl(): Unit {
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "已生成草稿。")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"posted\",\"posted\":true,\"replyUrl\":\"https://gitcode.com/Cangjie/cangjie_tools/issues/123#note_9\"}")
        }))
        setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
            messages.add(text)
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedContractFrame(), store: ServicePluginPendingJobStore())
            @Expect(result.status, "generated_reply_delivered")
            @Expect(messages[0].contains("GitCode 回复已写回"), true)
            @Expect(messages[0].contains("https://gitcode.com/Cangjie/cangjie_tools/issues/123#note_9"), true)
            @Expect(messages[0].contains("\"replyUrl\""), false)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tMaintainerEmailT4Pos001PostedMentionAndEmailSentAreHumanReadable(): Unit {
        // T4-METIS-POS-001.
        let parsed = this.dispatchWithFakeWritebackResponse("{\"status\":\"posted\",\"posted\":true,\"replyUrl\":\"https://gitcode.com/Cangjie/community/pulls/71#note_9\",\"maintainerMentionAppended\":true,\"teamLeaderCount\":1,\"codeownerCount\":2,\"contextSource\":\"store\",\"emailNotificationStatus\":\"sent\",\"emailSentCount\":2}")
        @Expect(parsed.contains("维护者提及: 已追加 teamLeader=1 codeowner=2"), true)
        @Expect(parsed.contains("维护者邮件: 已发送 2"), true)
        this.assertWritebackNotificationSafe(parsed)

        let event = ServicePluginAcceptedGitCodeEvent(repo: "Cangjie/community", kind: "pr", number: "71", url: "https://gitcode.com/Cangjie/community/pulls/71")
        let text = renderServicePluginGeneratedReplyNotification(
            event,
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充测试。"),
            writeback: ServicePluginWritebackApplyState(
                configured: true,
                ok: true,
                status: "posted",
                posted: true,
                replyUrl: "https://gitcode.com/Cangjie/community/pulls/71#note_9",
                maintainerMentionAppended: true,
                teamLeaderCount: 1,
                codeownerCount: 2,
                contextSource: "store",
                emailNotificationStatus: "sent",
                emailSentCount: 2
            )
        )
        @Expect(text.contains("GitCode 回复已写回"), true)
        @Expect(text.contains("维护者提及: 已追加 teamLeader=1 codeowner=2"), true)
        @Expect(text.contains("维护者邮件: 已发送 2"), true)
        this.assertWritebackNotificationSafe(text)
    }

    @TestCase
    public func tMaintainerEmailT4Neg001PostedWithSendFailedKeepsCommentSuccess(): Unit {
        // T4-METIS-NEG-001.
        let parsed = this.dispatchWithFakeWritebackResponse("{\"status\":\"posted\",\"posted\":true,\"maintainerMentionAppended\":true,\"teamLeaderCount\":1,\"codeownerCount\":0,\"emailNotificationStatus\":\"send_failed\",\"emailFailedCount\":2,\"emailRetryable\":true}", eventId: "gitcode:Cangjie/cangjie_tools:issue:send-failed")
        @Expect(parsed.contains("GitCode 回复已写回"), true)
        @Expect(parsed.contains("维护者邮件: 发送失败"), true)
        @Expect(parsed.contains("可重试"), true)
        @Expect(parsed.contains("写回结果异常"), false)
        this.assertWritebackNotificationSafe(parsed)

        let event = ServicePluginAcceptedGitCodeEvent(repo: "Cangjie/community", kind: "issue", number: "72", url: "https://gitcode.com/Cangjie/community/issues/72")
        let text = renderServicePluginGeneratedReplyNotification(
            event,
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充测试。"),
            writeback: ServicePluginWritebackApplyState(
                configured: true,
                ok: true,
                status: "posted",
                posted: true,
                maintainerMentionAppended: true,
                teamLeaderCount: 1,
                codeownerCount: 0,
                emailNotificationStatus: "send_failed",
                emailFailedCount: 2,
                emailRetryable: true
            )
        )
        @Expect(text.contains("GitCode 回复已写回"), true)
        @Expect(text.contains("维护者邮件: 发送失败"), true)
        @Expect(text.contains("2"), true)
        @Expect(text.contains("可重试"), true)
        @Expect(text.contains("写回结果异常"), false)
        this.assertWritebackNotificationSafe(text)
    }

    @TestCase
    public func tMaintainerEmailT4Bound001LegacyPostedResponseMissingFieldsStillRenders(): Unit {
        // T4-METIS-BOUND-001.
        let parsed = this.dispatchWithFakeWritebackResponse("{\"status\":\"posted\",\"posted\":true}", eventId: "gitcode:Cangjie/cangjie_tools:issue:legacy")
        @Expect(parsed.contains("GitCode 回复已写回"), true)
        @Expect(parsed.contains("维护者提及"), false)
        @Expect(parsed.contains("维护者邮件"), false)
        this.assertWritebackNotificationSafe(parsed)

        let event = ServicePluginAcceptedGitCodeEvent(repo: "Cangjie/community", kind: "issue", number: "72", url: "https://gitcode.com/Cangjie/community/issues/72")
        let text = renderServicePluginGeneratedReplyNotification(
            event,
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充测试。"),
            writeback: ServicePluginWritebackApplyState(configured: true, ok: true, status: "posted", posted: true)
        )
        @Expect(text.contains("GitCode 回复已写回"), true)
        @Expect(text.contains("维护者提及"), false)
        @Expect(text.contains("维护者邮件"), false)
        this.assertWritebackNotificationSafe(text)
    }

    @TestCase
    public func tMaintainerEmailUnavailableAndDisabledStatusesAreHumanReadable(): Unit {
        let parsedUnavailable = this.dispatchWithFakeWritebackResponse("{\"status\":\"posted\",\"posted\":true,\"emailNotificationStatus\":\"email_unavailable\"}", eventId: "gitcode:Cangjie/cangjie_tools:issue:email-unavailable")
        @Expect(parsedUnavailable.contains("维护者邮件: 无可用邮箱"), true)
        this.assertWritebackNotificationSafe(parsedUnavailable)

        let event = ServicePluginAcceptedGitCodeEvent(repo: "Cangjie/community", kind: "issue", number: "72", url: "https://gitcode.com/Cangjie/community/issues/72")
        let unavailable = renderServicePluginGeneratedReplyNotification(
            event,
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充测试。"),
            writeback: ServicePluginWritebackApplyState(configured: true, ok: true, status: "posted", posted: true, emailNotificationStatus: "email_unavailable")
        )
        @Expect(unavailable.contains("维护者邮件: 无可用邮箱"), true)
        this.assertWritebackNotificationSafe(unavailable)

        let disabled = renderServicePluginGeneratedReplyNotification(
            event,
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充测试。"),
            writeback: ServicePluginWritebackApplyState(configured: true, ok: true, status: "posted", posted: true, emailNotificationStatus: "email_disabled")
        )
        @Expect(disabled.contains("维护者邮件: 未启用"), true)
        this.assertWritebackNotificationSafe(disabled)
    }

    @TestCase
    public func tMaintainerEmailT4Reg001ExistingSkipReasonsRemainHumanReadable(): Unit {
        // T4-METIS-REG-001.
        let event = ServicePluginAcceptedGitCodeEvent(repo: "Cangjie/community", kind: "issue", number: "1", url: "https://gitcode.com/Cangjie/community/issues/1")
        let dryRun = renderServicePluginGeneratedReplyNotification(
            event,
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "草稿。"),
            writeback: ServicePluginWritebackApplyState(configured: true, ok: true, status: "dry_run", skipped: true, diagnostic: "dry_run")
        )
        @Expect(dryRun.contains("dryRun=true"), true)
        this.assertWritebackNotificationSafe(dryRun)

        let denied = renderServicePluginGeneratedReplyNotification(
            event,
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "草稿。"),
            writeback: ServicePluginWritebackApplyState(configured: true, ok: true, status: "skipped", skipped: true, diagnostic: "repo_denied_by_writeback_scope")
        )
        @Expect(denied.contains("该仓库被 GCM writebackScope.deniedRepos 排除，已生成草稿但未写回 GitCode"), true)
        this.assertWritebackNotificationSafe(denied)

        let notAllowlisted = renderServicePluginGeneratedReplyNotification(
            event,
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "草稿。"),
            writeback: ServicePluginWritebackApplyState(configured: true, ok: true, status: "repo_not_allowlisted", skipped: true)
        )
        @Expect(notAllowlisted.contains("当前仓库未命中 GCM writebackScope 允许范围，已生成草稿但未写回 GitCode"), true)
        this.assertWritebackNotificationSafe(notAllowlisted)
    }

    @TestCase
    public func wbScopeP3Neg001WritebackScopeDeniedReasonIsHumanReadable(): Unit {
        let event = ServicePluginAcceptedGitCodeEvent(repo: "Cangjie/community", kind: "issue", number: "1", url: "https://gitcode.com/Cangjie/community/issues/1")
        let denied = renderServicePluginGeneratedReplyNotification(
            event,
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充测试。"),
            writeback: ServicePluginWritebackApplyState(configured: true, ok: true, status: "skipped", skipped: true, diagnostic: "repo_denied_by_writeback_scope")
        )
        @Expect(denied.contains("该仓库被 GCM writebackScope.deniedRepos 排除，已生成草稿但未写回 GitCode"), true)
        @Expect(denied.contains("\"reason\""), false)
        @Expect(denied.contains("{"), false)

        let notAllowlisted = renderServicePluginGeneratedReplyNotification(
            event,
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充测试。"),
            writeback: ServicePluginWritebackApplyState(configured: true, ok: true, status: "repo_not_allowlisted", skipped: true)
        )
        @Expect(notAllowlisted.contains("当前仓库未命中 GCM writebackScope 允许范围，已生成草稿但未写回 GitCode"), true)
        @Expect(notAllowlisted.contains("\"reason\""), false)
        @Expect(notAllowlisted.contains("{"), false)
    }

    @TestCase
    public func wbScopeP3Reg001DryRunDraftModeStillShowsNotWrittenBack(): Unit {
        let event = ServicePluginAcceptedGitCodeEvent(repo: "Cangjie/community", kind: "issue", number: "1", url: "https://gitcode.com/Cangjie/community/issues/1")
        let text = renderServicePluginGeneratedReplyNotification(event, ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "草稿。"))
        @Expect(text.contains("dryRun=true"), true)
        @Expect(text.contains("未写回 GitCode"), true)
        @Expect(text.contains("\"status\""), false)
        @Expect(text.contains("{"), false)
    }

    @TestCase
    public func wbScopeP4E2E001FakeWebhookGeneratedReplyAndPostedWritebackNotifyAllTargets(): Unit {
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let calls = ArrayList<String>()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer"), this.target(channel: "feishu", peerId: "fs-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充回归测试。")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            calls.add(request.capabilityId)
            @Expect(request.capabilityId, "gitcode.writeback.apply_result")
            @Expect(request.payload.contains("Cangjie/cangjie_tools"), true)
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"posted\",\"posted\":true,\"replyUrl\":\"https://gitcode.com/Cangjie/cangjie_tools/issues/123#note_9\"}")
        }))
        setServicePluginEventDeliveryForTest(Some({ target: ServicePluginDeliveryTarget, text: String =>
            messages.add("${target.channel}:${text}")
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedContractFrame(), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_delivered")
            @Expect(result.deliverySuccess, 2)
            @Expect(calls.size, 1)
            @Expect(messages.size, 2)
            for (message in messages) {
                @Expect(message.contains("GitCode 回复已写回"), true)
                @Expect(message.contains("https://gitcode.com/Cangjie/cangjie_tools/issues/123#note_9"), true)
                @Expect(message.contains("\"replyUrl\""), false)
            }
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func wbScopeP4E2E002FakeWebhookGeneratedReplyAndDeniedWritebackNotifyDraftOnly(): Unit {
        this.resetDispatcherHooks()
        this.registerGitCodeWritebackPlugin()
        let calls = ArrayList<String>()
        let messages = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            this.targetRows([this.target(channel: "telegram", peerId: "tg-peer"), this.target(channel: "feishu", peerId: "fs-peer")])
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充回归测试。")
        }))
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            calls.add(request.capabilityId)
            CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"skipped\",\"posted\":false,\"reason\":\"repo_denied_by_writeback_scope\"}")
        }))
        setServicePluginEventDeliveryForTest(Some({ target: ServicePluginDeliveryTarget, text: String =>
            messages.add("${target.channel}:${text}")
            ServicePluginEventDeliveryResult(true, "sent")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedContractFrame(), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(result.status, "generated_reply_delivered")
            @Expect(result.deliverySuccess, 2)
            @Expect(calls.size, 1)
            @Expect(messages.size, 2)
            for (message in messages) {
                @Expect(message.contains("该仓库被 GCM writebackScope.deniedRepos 排除，已生成草稿但未写回 GitCode"), true)
                @Expect(message.contains("建议补充回归测试。"), true)
                @Expect(message.contains("GitCode 回复已写回"), false)
                @Expect(message.contains("\"reason\""), false)
                @Expect(message.contains("{"), false)
            }
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func tDiag005And006GeneratedReplyNotificationExplainsDegradedContext(): Unit {
        let event = ServicePluginAcceptedGitCodeEvent(repo: "Cangjie/cangjie_tools", kind: "issue", number: "123", url: "https://gitcode.com/Cangjie/cangjie_tools/issues/123")
        let ckb = renderServicePluginGeneratedReplyNotification(event, ServicePluginGeneratedReplyResult(false, status: "ckb_unavailable", diagnostic: "ckb_unavailable", needsHumanReview: true))
        @Expect(ckb.contains("知识库不可用，已保守生成/需要人工确认"), true)
        @Expect(ckb.contains("\"diagnostics\""), false)

        let pr = renderServicePluginGeneratedReplyNotification(event, ServicePluginGeneratedReplyResult(false, status: "pr_review_timeout", diagnostic: "adapter timeout raw={\"ok\":false}", needsHumanReview: true))
        @Expect(pr.contains("PR review 阶段超时，已保守生成草稿，需要人工确认"), true)
        @Expect(pr.contains("\"ok\""), false)

        let toolProtocol = renderServicePluginGeneratedReplyNotification(event, ServicePluginGeneratedReplyResult(false, status: "tool_protocol_unfinalized", diagnostic: "assistant to=functions.search {\"query\":\"secret\"}", needsHumanReview: true))
        @Expect(toolProtocol.contains("模型工具调用未收敛为最终文本，已转人工确认"), true)
        @Expect(toolProtocol.contains("functions.search"), false)
        @Expect(toolProtocol.contains("\"query\""), false)
    }
}
