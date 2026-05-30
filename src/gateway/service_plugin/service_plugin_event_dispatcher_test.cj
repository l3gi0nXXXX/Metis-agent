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
}
