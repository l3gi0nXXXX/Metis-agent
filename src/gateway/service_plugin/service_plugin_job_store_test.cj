package metis.gateway.service_plugin

import std.collection.ArrayList
import std.fs.{Directory, File, Path, exists, remove}
import std.process.executeWithOutput
import std.sync.*
import std.time.*
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue

private func decodeReceiptTestOutputOrEmpty(bytes: Array<UInt8>): String {
    try { String.fromUtf8(bytes) } catch (_: Exception) { "" }
}

private class ServicePluginReceiptTestGate {
    private let lock = Mutex()
    private let condition: Condition
    private var entered = false
    private var released = false
    init() { synchronized(this.lock) { this.condition = this.lock.condition() } }
    func enterAndWait(): Bool {
        synchronized(this.lock) {
            this.entered = true
            this.condition.notifyAll()
            this.condition.waitUntil({ => this.released }, timeout: Duration.second * 3)
        }
    }
    func awaitEntered(): Bool { synchronized(this.lock) { this.condition.waitUntil({ => this.entered }, timeout: Duration.second) } }
    func release(): Unit { synchronized(this.lock) { this.released = true; this.condition.notifyAll() } }
}

@Test
public class ServicePluginJobStoreTest {
    private func receiptPath(label: String): Path {
        let root = Path("/tmp").join("metis-webhook-receipt-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        Directory.create(root, recursive: true)
        root
    }

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

    @TestCase
    public func hS5N101WebhookReceiptRoundTripsCompletedIdentityWithoutSensitiveFields(): Unit {
        let path = this.receiptPath("roundtrip")
        try {
            let expectedAttemptToken = "synthetic-attempt-h-s5-n1-01"
            let first = ServicePluginWebhookReceiptStore(path.toString())
            @Expect(first.reserve("gitcode-monitor", "delivery-中文🙂", "event-1", attemptToken: expectedAttemptToken).status, "reserved")
            @Expect(first.complete("gitcode-monitor", "delivery-中文🙂", "event-1", attemptToken: expectedAttemptToken).status, "completed_unconfirmed")
            let receiptPath = first.receiptPathForTest("gitcode-monitor", "delivery-中文🙂", "event-1")
            let raw = String.fromUtf8(File.readFrom(receiptPath))
            let receipt = JsonValue.fromStr(raw).asObject()
            @Expect(receipt.get("serviceId").getOrThrow().asString().getValue(), "gitcode-monitor")
            @Expect(receipt.get("deliveryId").getOrThrow().asString().getValue(), "delivery-中文🙂")
            @Expect(receipt.get("eventId").getOrThrow().asString().getValue(), "event-1")
            @Expect(receipt.get("state").getOrThrow().asString().getValue(), "completed_unconfirmed")
            @Expect(receipt.get("attemptToken").getOrThrow().asString().getValue(), expectedAttemptToken)
            @Expect(raw.contains("draft"), false)
            @Expect(raw.contains("payload"), false)
            @Expect(raw.contains("authorization"), false)
            @Expect(raw.contains("real-secret"), false)
            @Expect(raw.contains("/tmp/"), false)
            @Expect(decodeReceiptTestOutputOrEmpty(executeWithOutput("/usr/bin/stat", ["-f", "%Lp", path.toString()])[1]).trimAscii(), "700")
            @Expect(decodeReceiptTestOutputOrEmpty(executeWithOutput("/usr/bin/stat", ["-f", "%Lp", receiptPath.toString()])[1]).trimAscii(), "600")

            let replacement = ServicePluginWebhookReceiptStore(path.toString())
            @Expect(replacement.reserve("gitcode-monitor", "delivery-中文🙂", "event-1", attemptToken: expectedAttemptToken).status, "completed_unconfirmed")
        } finally {
            remove(path, recursive: true)
        }
    }

    @TestCase
    public func hS5N103WebhookReceiptFailsClosedForInflightMalformedAndInvalidUtf8(): Unit {
        let inflightPath = this.receiptPath("inflight")
        let malformedPath = this.receiptPath("malformed")
        let utf8Path = this.receiptPath("utf8")
        try {
            let first = ServicePluginWebhookReceiptStore(inflightPath.toString())
            @Expect(first.reserve("gitcode-monitor", "delivery-1", "event-1").status, "reserved")
            @Expect(ServicePluginWebhookReceiptStore(inflightPath.toString()).reserve("gitcode-monitor", "delivery-1", "event-1").status, "in_flight")

            let malformedStore = ServicePluginWebhookReceiptStore(malformedPath.toString())
            File.writeTo(malformedStore.receiptPathForTest("gitcode-monitor", "delivery-2", "event-2"), "{not-json".toArray())
            @Expect(ServicePluginWebhookReceiptStore(malformedPath.toString()).reserve("gitcode-monitor", "delivery-2", "event-2").status, "store_unavailable")
            let utf8Store = ServicePluginWebhookReceiptStore(utf8Path.toString())
            File.writeTo(utf8Store.receiptPathForTest("gitcode-monitor", "delivery-3", "event-3"), [UInt8(0xff), UInt8(0xfe)])
            @Expect(ServicePluginWebhookReceiptStore(utf8Path.toString()).reserve("gitcode-monitor", "delivery-3", "event-3").status, "store_unavailable")
        } finally {
            remove(inflightPath, recursive: true)
            remove(malformedPath, recursive: true)
            remove(utf8Path, recursive: true)
        }
    }

    @TestCase
    public func hS5N105WebhookReceiptAtomicFailuresPreserveOldTerminal(): Unit {
        for (phase in ["temp", "write", "rename"]) {
            let path = this.receiptPath("atomic-${phase}")
            let completionPath = this.receiptPath("atomic-complete-${phase}")
            try {
                let baseline = ServicePluginWebhookReceiptStore(path.toString())
                @Expect(baseline.reserve("gitcode-monitor", "delivery-old", "event-old").status, "reserved")
                @Expect(baseline.complete("gitcode-monitor", "delivery-old", "event-old").status, "completed_unconfirmed")
                let failing = ServicePluginWebhookReceiptStore(path.toString(), persistHook: Some({ current: String => current != phase }))
                @Expect(failing.reserve("gitcode-monitor", "delivery-new", "event-new").status, "store_unavailable")
                let replacement = ServicePluginWebhookReceiptStore(path.toString())
                @Expect(replacement.reserve("gitcode-monitor", "delivery-old", "event-old").status, "completed_unconfirmed")
                @Expect(replacement.state("gitcode-monitor", "delivery-new", "event-new"), "missing")

                let failEnabled = ArrayList<Bool>()
                failEnabled.add(false)
                let completionStore = ServicePluginWebhookReceiptStore(completionPath.toString(), persistHook: Some({ current: String => !failEnabled[0] || current != phase }))
                @Expect(completionStore.reserve("gitcode-monitor", "delivery-complete", "event-complete").status, "reserved")
                failEnabled[0] = true
                @Expect(completionStore.complete("gitcode-monitor", "delivery-complete", "event-complete").status, "store_unavailable")
                @Expect(ServicePluginWebhookReceiptStore(completionPath.toString()).state("gitcode-monitor", "delivery-complete", "event-complete"), "in_flight")
            } finally {
                remove(path, recursive: true)
                remove(completionPath, recursive: true)
            }
        }
    }

    @TestCase
    public func hS5N104WebhookReceiptCapacityIsHardBoundedWithoutEviction(): Unit {
        let path = this.receiptPath("capacity")
        try {
            let store = ServicePluginWebhookReceiptStore(path.toString(), maxReceipts: 2)
            @Expect(store.reserve("gitcode-monitor", "delivery-1", "event-1").status, "reserved")
            @Expect(store.reserve("gitcode-monitor", "delivery-2", "event-2").status, "reserved")
            @Expect(store.reserve("gitcode-monitor", "delivery-3", "event-3").status, "store_full")
            @Expect(store.receiptCountForTest(), 2)
            @Expect(store.state("gitcode-monitor", "delivery-1", "event-1"), "in_flight")
            @Expect(store.state("gitcode-monitor", "delivery-2", "event-2"), "in_flight")
        } finally {
            remove(path, recursive: true)
        }
    }

    @TestCase
    public func c12SharedRootSerializesIdentityAndCapacityAcrossStoreInstances(): Unit {
        let samePath = this.receiptPath("c12-same")
        let capPath = this.receiptPath("c12-cap")
        try {
            let gate = ServicePluginReceiptTestGate()
            let firstStore = ServicePluginWebhookReceiptStore(samePath.toString(), persistHook: Some({ phase: String =>
                if (phase == "temp") { gate.enterAndWait() } else { true }
            }))
            let replacement = ServicePluginWebhookReceiptStore(samePath.toString())
            let first = spawn { firstStore.reserve("gitcode-monitor", "delivery-same", "event-same", attemptToken: "attempt-1").status }
            @Expect(gate.awaitEntered(), true)
            let second = spawn { replacement.reserve("gitcode-monitor", "delivery-same", "event-same", attemptToken: "attempt-2").status }
            gate.release()
            @Expect(first.get(), "reserved")
            @Expect(second.get(), "in_flight")
            @Expect(replacement.receiptCountForTest(), 1)

            let capA = ServicePluginWebhookReceiptStore(capPath.toString(), maxReceipts: 1)
            let capB = ServicePluginWebhookReceiptStore(capPath.toString(), maxReceipts: 1)
            let a = spawn { capA.reserve("gitcode-monitor", "delivery-a", "event-a", attemptToken: "attempt-a").status }
            let b = spawn { capB.reserve("gitcode-monitor", "delivery-b", "event-b", attemptToken: "attempt-b").status }
            let statuses = [a.get(), b.get()]
            var reserved: Int64 = 0
            var full: Int64 = 0
            for (status in statuses) {
                if (status == "reserved") { reserved++ }
                if (status == "store_full") { full++ }
            }
            @Expect(reserved, 1)
            @Expect(full, 1)
            @Expect(capA.receiptCountForTest(), 1)
        } finally {
            remove(samePath, recursive: true)
            remove(capPath, recursive: true)
        }
    }

    @TestCase
    public func c13ConfirmedReceiptReleasesCapacityAndReplayRebindsAttempt(): Unit {
        let path = this.receiptPath("c13-confirm")
        try {
            let store = ServicePluginWebhookReceiptStore(path.toString(), maxReceipts: 1)
            @Expect(store.reserve("gitcode-monitor", "delivery-1", "event-1", attemptToken: "attempt-1").status, "reserved")
            @Expect(store.complete("gitcode-monitor", "delivery-1", "event-1", attemptToken: "attempt-1").status, "completed_unconfirmed")
            @Expect(store.reserve("gitcode-monitor", "delivery-1", "event-1", attemptToken: "attempt-2").status, "completed_unconfirmed")
            let rows = store.listUnconfirmed(limit: 8)
            @Expect(rows.ok, true)
            @Expect(rows.receipts.size, 1)
            @Expect(rows.receipts[0].attemptToken, "attempt-2")
            @Expect(store.reserve("gitcode-monitor", "delivery-2", "event-2", attemptToken: "attempt-other").status, "store_full")
            @Expect(store.confirmAndRemove("gitcode-monitor", "delivery-1", "event-1", "attempt-1").status, "confirmation_mismatch")
            @Expect(store.confirmAndRemove("gitcode-monitor", "delivery-1", "event-1", "attempt-2").status, "confirmed")
            @Expect(store.receiptCountForTest(), 0)
            @Expect(store.reserve("gitcode-monitor", "delivery-2", "event-2", attemptToken: "attempt-other").status, "reserved")
        } finally { remove(path, recursive: true) }
    }
}
