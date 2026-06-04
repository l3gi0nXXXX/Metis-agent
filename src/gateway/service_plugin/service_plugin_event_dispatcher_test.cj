package metis.gateway.service_plugin

import std.collection.ArrayList
import std.unittest.testmacro.*

@Test
public class ServicePluginEventDispatcherTest {
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

    private func resetDispatcherHooks(): Unit {
        setServicePluginEventDeliveryForTest(None)
        setServicePluginGeneratedReplyHandlerForTest(None<(ServicePluginPendingJob, ServicePluginAcceptedGitCodeEvent) -> ServicePluginGeneratedReplyResult>)
        setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
        setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
        resetServicePluginGeneratedReplyStateForTest()
    }

    private func targetRows(targets: Array<ServicePluginDeliveryTarget>): ArrayList<ServicePluginDeliveryTarget> {
        let out = ArrayList<ServicePluginDeliveryTarget>()
        for (target in targets) {
            out.add(target)
        }
        out
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
            @Expect(result.status, "generated_reply_delivered")
            @Expect(result.targetCount, 1)
            @Expect(result.deliverySuccess, 1)
            @Expect(result.diagnosticHash.size, 64)
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("GitCode 回复草稿"), true)
            @Expect(messages[0].contains("https://gitcode.com/cangjie/community/pulls/71"), true)
            @Expect(servicePluginWebhookDispatchStatsSnapshot().size, 1)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func webhookAcceptedEventWithoutSubscribersDoesNotCallDraftHandler(): Unit {
        this.resetDispatcherHooks()
        let draftCalls = ArrayList<String>()
        setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
            ArrayList<ServicePluginDeliveryTarget>()
        }))
        setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
            draftCalls.add("called")
            ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "draft")
        }))
        try {
            let result = dispatchServicePluginEvent(this.acceptedFrame(), store: ServicePluginPendingJobStore())
            @Expect(result.ok, true)
            @Expect(result.status, "no_subscribers")
            @Expect(result.targetCount, 0)
            @Expect(draftCalls.size, 0)
        } finally {
            this.resetDispatcherHooks()
        }
    }

    @TestCase
    public func webhookAcceptedEventSupportsMultipleTargetsPartialFailureAndDedupe(): Unit {
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

            let duplicate = dispatchServicePluginEvent(this.acceptedFrame(), store: ServicePluginPendingJobStore())
            @Expect(duplicate.ok, true)
            @Expect(duplicate.status, "duplicate_event")
            @Expect(messages.size, 2)
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
            @Expect(acceptedResult.status, "generated_reply_delivered")
            @Expect(messages.size, 1)
            @Expect(messages[0].contains("GitCode 回复草稿"), true)
            @Expect(messages[0].contains("来源: cangjie/community PR #71 https://gitcode.com/cangjie/community/pulls/71"), true)
            @Expect(messages[0].contains("标题: 修复 xxx"), true)
            @Expect(messages[0].contains("请补充 cangjie/community 的对应测试。"), true)
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

            @Expect(dispatchServicePluginEvent(pr, store: store).status, "generated_reply_delivered")
            @Expect(dispatchServicePluginEvent(issue, store: store).status, "generated_reply_delivered")
            @Expect(dispatchServicePluginEvent(comment, store: store).status, "generated_reply_delivered")
            @Expect(messages.size, 3)

            @Expect(messages[0].contains("来源: cangjie/community PR #71 https://gitcode.com/cangjie/community/pulls/71"), true)
            @Expect(messages[0].contains("标题: PR title"), true)
            @Expect(messages[0].contains("状态: dryRun=true"), true)
            @Expect(messages[1].contains("来源: cangjie/community Issue #72 https://gitcode.com/cangjie/community/issues/72"), true)
            @Expect(messages[1].contains("标题: Issue title"), true)
            @Expect(messages[1].contains("状态: dryRun=true"), true)
            @Expect(messages[2].contains("来源: cangjie/community Comment #71 comment #9001 https://gitcode.com/cangjie/community/pulls/71#note_9001"), true)
            @Expect(messages[2].contains("标题: Comment title"), true)
            @Expect(messages[2].contains("状态: dryRun=true"), true)

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
}
