package metis.gateway.service_plugin

import std.fs.{Path, exists, remove}
import std.unittest.testmacro.*

@Test
public class ServicePluginJobStoreTest {
    private func target(channel!: String = "telegram", peerId!: String = "peer-secret"): ServicePluginDeliveryTarget {
        ServicePluginDeliveryTarget(channel, "acct", peerId, threadId: "thread-1", replyToMessageId: "msg-1", replyInThread: true)
    }

    @TestCase
    public func pendingJobStoreCreatesFindsMarksAndRedactsJobs(): Unit {
        let store = ServicePluginPendingJobStore()
        let first = store.createOrGetByIdempotencyKey("gitcode-monitor", "gitcode.monitor.scan_once", "job-1", "idem-1", this.target(), nowMillis: 10)
        @Expect(first.created, true)
        @Expect(first.job.status, "starting")
        let duplicate = store.createOrGetByIdempotencyKey("gitcode-monitor", "gitcode.monitor.scan_once", "job-other", "idem-1", this.target(), nowMillis: 11)
        @Expect(duplicate.created, false)
        @Expect(duplicate.job.jobId, "job-1")

        store.markAccepted("job-1", nowMillis: 12)
        store.markRunning("job-1", stage: "scan_repo", nowMillis: 13)
        match (store.findByJobId("job-1")) {
            case Some(job) =>
                @Expect(job.status, "running")
                @Expect(job.stage, "scan_repo")
                @Expect(job.deliveryTarget.peerId, "peer-secret")
                let summary = job.redactedSummary()
                @Expect(summary.contains("peer-secret"), false)
                @Expect(summary.contains("peerHash="), true)
            case None => @Expect(true, false)
        }

        store.markCompleted("job-1", summary: "accepted=1 ignored=2 emitted=3", nowMillis: 14)
        @Expect((store.findByJobId("job-1") ?? ServicePluginPendingJob()).status, "completed")
        @Expect(store.createOrGetByIdempotencyKey("gitcode-monitor", "gitcode.monitor.scan_once", "", "idem-2", this.target()).ok, false)
        @Expect(store.createOrGetByIdempotencyKey("gitcode-monitor", "gitcode.monitor.scan_once", "job-2", "idem-2", this.target(channel: "unknown")).ok, false)
        @Expect(store.createOrGetByIdempotencyKey("gitcode-monitor", "gitcode.monitor.scan_once", "job-3", "idem-3", this.target(peerId: "")).ok, false)
    }

    @TestCase
    public func pendingJobStoreScalesExpiresAndPersistsWithoutRealHome(): Unit {
        let store = ServicePluginPendingJobStore()
        for (i in 0..1000) {
            let id = "job-${i}"
            let _ = store.createOrGetByIdempotencyKey("gitcode-monitor", "gitcode.monitor.scan_once", id, "idem-${i}", this.target(peerId: "peer-${i}"), nowMillis: i)
        }
        @Expect((store.findByJobId("job-999") ?? ServicePluginPendingJob()).deliveryTarget.peerId, "peer-999")

        let expired = store.expireOldJobs(nowMillis: 2000, ttlMillis: 1500)
        @Expect(expired > 0, true)
        @Expect((store.findByJobId("job-999") ?? ServicePluginPendingJob()).status, "starting")

        let path = Path("/tmp").join("metis-service-plugin-pending-job-store-test.jsonl")
        if (exists(path)) { remove(path) }
        store.saveToFile(path.toString())
        @Expect(exists(path), true)
        let loaded = ServicePluginPendingJobStore.loadFromFile(path.toString())
        @Expect((loaded.findByJobId("job-999") ?? ServicePluginPendingJob()).deliveryTarget.peerId, "peer-999")
        remove(path)
    }
}
