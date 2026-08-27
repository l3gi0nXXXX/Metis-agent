package metis.gateway.service_plugin

import metis.core.config.MetisPaths
import std.collection.{ArrayList, HashMap}
import std.convert.Parsable
import std.fs.{Directory, File, FileInfo, Path, canonicalize, exists, remove, rename}
import std.posix.chmod
import std.sync.*
import std.time.DateTime
import stdx.crypto.digest.SHA256
import stdx.encoding.json.{JsonInt, JsonObject, JsonString, JsonValue}

public class ServicePluginPendingJob {
    public let jobId: String
    public let serviceId: String
    public let capabilityId: String
    public let idempotencyKey: String
    public let deliveryTarget: ServicePluginDeliveryTarget
    public var status: String
    public var stage: String
    public var summary: String
    public var lastError: String
    public let createdAtMillis: Int64
    public var updatedAtMillis: Int64

    public init(
        jobId!: String = "",
        serviceId!: String = "",
        capabilityId!: String = "",
        idempotencyKey!: String = "",
        deliveryTarget!: ServicePluginDeliveryTarget = ServicePluginDeliveryTarget("", "", ""),
        status!: String = "",
        stage!: String = "",
        summary!: String = "",
        lastError!: String = "",
        createdAtMillis!: Int64 = 0,
        updatedAtMillis!: Int64 = 0
    ) {
        this.jobId = jobId.trimAscii()
        this.serviceId = serviceId.trimAscii()
        this.capabilityId = capabilityId.trimAscii()
        this.idempotencyKey = idempotencyKey.trimAscii()
        this.deliveryTarget = deliveryTarget
        this.status = status.trimAscii()
        this.stage = stage.trimAscii()
        this.summary = summary.trimAscii()
        this.lastError = lastError.trimAscii()
        this.createdAtMillis = createdAtMillis
        this.updatedAtMillis = updatedAtMillis
    }

    public func redactedSummary(): String {
        "jobId=${this.jobId} serviceId=${this.serviceId} status=${this.status} peerHash=${hashRawPayload(this.deliveryTarget.peerId)} senderHash=redacted"
    }
}

public class ServicePluginPendingJobCreateResult {
    public let ok: Bool
    public let created: Bool
    public let status: String
    public let diagnostic: String
    public let job: ServicePluginPendingJob

    public init(ok: Bool, created!: Bool = false, status!: String = "ok", diagnostic!: String = "", job!: ServicePluginPendingJob = ServicePluginPendingJob()) {
        this.ok = ok
        this.created = created
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.job = job
    }
}

public class ServicePluginPendingJobStore {
    private let byJobId = HashMap<String, ServicePluginPendingJob>()
    private let byIdempotencyKey = HashMap<String, String>()

    public init() {}

    public func createOrGetByIdempotencyKey(
        serviceId: String,
        capabilityId: String,
        jobId: String,
        idempotencyKey: String,
        deliveryTarget: ServicePluginDeliveryTarget,
        nowMillis!: Int64 = 0
    ): ServicePluginPendingJobCreateResult {
        let idem = idempotencyKey.trimAscii()
        if (!idem.isEmpty() && this.byIdempotencyKey.contains(idem)) {
            let existingId = this.byIdempotencyKey[idem]
            return ServicePluginPendingJobCreateResult(true, created: false, status: "job_already_running", job: this.byJobId[existingId])
        }
        let diagnostics = ArrayList<String>()
        if (jobId.trimAscii().isEmpty()) { diagnostics.add("jobId is required") }
        if (jobId.trimAscii().size > 128) { diagnostics.add("jobId too long") }
        if (serviceId.trimAscii().isEmpty()) { diagnostics.add("serviceId is required") }
        if (capabilityId.trimAscii().isEmpty()) { diagnostics.add("capabilityId is required") }
        if (idem.isEmpty()) { diagnostics.add("idempotencyKey is required") }
        if (!(deliveryTarget.channel == "telegram" || deliveryTarget.channel == "feishu")) { diagnostics.add("channel is invalid") }
        if (deliveryTarget.accountId.isEmpty()) { diagnostics.add("accountId is required") }
        if (deliveryTarget.peerId.isEmpty()) { diagnostics.add("peerId is required") }
        if (diagnostics.size > 0) {
            return ServicePluginPendingJobCreateResult(false, status: "job_payload_invalid", diagnostic: String.join(diagnostics.toArray(), delimiter: "; "))
        }
        if (this.byJobId.contains(jobId.trimAscii())) {
            return ServicePluginPendingJobCreateResult(true, created: false, status: "job_already_running", job: this.byJobId[jobId.trimAscii()])
        }
        let job = ServicePluginPendingJob(
            jobId: jobId,
            serviceId: serviceId,
            capabilityId: capabilityId,
            idempotencyKey: idem,
            deliveryTarget: deliveryTarget,
            status: "starting",
            createdAtMillis: nowMillis,
            updatedAtMillis: nowMillis
        )
        this.byJobId[job.jobId] = job
        this.byIdempotencyKey[idem] = job.jobId
        ServicePluginPendingJobCreateResult(true, created: true, status: "created", job: job)
    }

    public func findByJobId(jobId: String): ?ServicePluginPendingJob {
        match (this.byJobId.get(jobId.trimAscii())) {
            case Some(job) => Some(job)
            case None => None<ServicePluginPendingJob>
        }
    }

    public func markAccepted(jobId: String, nowMillis!: Int64 = 0): Unit {
        this.mark(jobId, "accepted", stage: "", summary: "", error: "", nowMillis: nowMillis)
    }

    public func markRunning(jobId: String, stage!: String = "", nowMillis!: Int64 = 0): Unit {
        this.mark(jobId, "running", stage: stage, summary: "", error: "", nowMillis: nowMillis)
    }

    public func markCompleted(jobId: String, summary!: String = "", nowMillis!: Int64 = 0): Unit {
        this.mark(jobId, "completed", stage: "done", summary: summary, error: "", nowMillis: nowMillis)
    }

    public func markFailed(jobId: String, error!: String = "", nowMillis!: Int64 = 0): Unit {
        this.mark(jobId, "failed", stage: "", summary: "", error: error, nowMillis: nowMillis)
    }

    public func markCancelled(jobId: String, nowMillis!: Int64 = 0): Unit {
        this.mark(jobId, "cancelled", stage: "cancelled", summary: "", error: "", nowMillis: nowMillis)
    }

    public func markDelivered(jobId: String, status: String, summary!: String = "", nowMillis!: Int64 = 0): Unit {
        this.mark(jobId, status, stage: "delivered", summary: summary, error: "", nowMillis: nowMillis)
    }

    public func expireOldJobs(nowMillis!: Int64, ttlMillis!: Int64): Int64 {
        var count: Int64 = 0
        for ((_, job) in this.byJobId) {
            if (!servicePluginJobTerminal(job.status) && nowMillis - job.updatedAtMillis > ttlMillis) {
                job.status = "expired"
                job.updatedAtMillis = nowMillis
                count++
            }
        }
        count
    }

    public func saveToFile(path: String): Unit {
        let lines = ArrayList<String>()
        for ((_, job) in this.byJobId) {
            lines.add(servicePluginPendingJobEncode(job))
        }
        File.writeTo(Path(path), (String.join(lines.toArray(), delimiter: "\n") + "\n").toArray())
    }

    public static func loadFromFile(path: String): ServicePluginPendingJobStore {
        let store = ServicePluginPendingJobStore()
        let p = Path(path)
        if (!exists(p)) {
            return store
        }
        let raw = try {
            String.fromUtf8(File.readFrom(p))
        } catch (_: Exception) {
            return store
        }
        for (line in raw.split("\n")) {
            let job = servicePluginPendingJobDecode(line)
            if (!job.jobId.isEmpty() && !job.idempotencyKey.isEmpty()) {
                store.byJobId[job.jobId] = job
                store.byIdempotencyKey[job.idempotencyKey] = job.jobId
            }
        }
        store
    }

    private func mark(jobId: String, status: String, stage!: String = "", summary!: String = "", error!: String = "", nowMillis!: Int64 = 0): Unit {
        match (this.byJobId.get(jobId.trimAscii())) {
            case Some(job) =>
                job.status = status.trimAscii()
                if (!stage.trimAscii().isEmpty()) { job.stage = stage.trimAscii() }
                if (!summary.trimAscii().isEmpty()) { job.summary = summary.trimAscii() }
                if (!error.trimAscii().isEmpty()) { job.lastError = redactServicePayload(error).text }
                job.updatedAtMillis = nowMillis
            case None => ()
        }
    }
}

private var defaultServicePluginPendingJobStore = ServicePluginPendingJobStore()

public func servicePluginPendingJobStore(): ServicePluginPendingJobStore {
    defaultServicePluginPendingJobStore
}

public func resetServicePluginPendingJobStoreForTest(): Unit {
    defaultServicePluginPendingJobStore = ServicePluginPendingJobStore()
}

public class ServicePluginWebhookReceiptDecision {
    public let status: String

    public init(status: String) {
        this.status = status.trimAscii()
    }
}

private class ServicePluginWebhookReceiptIdentity {
    let serviceId: String
    let deliveryId: String
    let eventId: String

    init(serviceId: String, deliveryId: String, eventId: String) {
        this.serviceId = serviceId
        this.deliveryId = deliveryId
        this.eventId = eventId
    }
}

public class ServicePluginWebhookReceipt {
    public let serviceId: String
    public let deliveryId: String
    public let eventId: String
    public let attemptToken: String
    public let state: String

    public init(serviceId: String, deliveryId: String, eventId: String, attemptToken: String, state: String) {
        this.serviceId = serviceId
        this.deliveryId = deliveryId
        this.eventId = eventId
        this.attemptToken = attemptToken
        this.state = state
    }
}

public class ServicePluginWebhookReceiptListResult {
    public let ok: Bool
    public let status: String
    public let receipts: ArrayList<ServicePluginWebhookReceipt>

    public init(ok: Bool, status: String, receipts!: ArrayList<ServicePluginWebhookReceipt> = ArrayList<ServicePluginWebhookReceipt>()) {
        this.ok = ok
        this.status = status
        this.receipts = receipts
    }
}

private class ServicePluginWebhookReceiptRootGuard {
    let lock = Mutex()
    init() {}
}

private let servicePluginWebhookReceiptRootGuardRegistryLock = Mutex()
private let servicePluginWebhookReceiptRootGuards = HashMap<String, ServicePluginWebhookReceiptRootGuard>()

private func servicePluginWebhookReceiptRootGuard(path: Path): ServicePluginWebhookReceiptRootGuard {
    // The Gateway serve lock permits one active process per METIS_HOME; this
    // registry supplies the remaining same-process, multi-Store exclusion.
    // The cross-process premise is covered by GatewayServeLockLogicTest.
    let key = try {
        if (!exists(path)) { Directory.create(path, recursive: true) }
        canonicalize(path).toString()
    } catch (_: Exception) {
        path.normalize().toString()
    }
    synchronized(servicePluginWebhookReceiptRootGuardRegistryLock) {
        match (servicePluginWebhookReceiptRootGuards.get(key)) {
            case Some(value) => value
            case None =>
                let value = ServicePluginWebhookReceiptRootGuard()
                servicePluginWebhookReceiptRootGuards[key] = value
                value
        }
    }
}

private const SERVICE_PLUGIN_WEBHOOK_RECEIPT_LIMIT: Int64 = 4096

public class ServicePluginWebhookReceiptStore {
    private let root: Path
    private let guard: ServicePluginWebhookReceiptRootGuard
    private let persistHook: Option<(String) -> Bool>
    private let maxReceipts: Int64

    public init(
        path: String,
        persistHook!: Option<(String) -> Bool> = None<(String) -> Bool>,
        maxReceipts!: Int64 = SERVICE_PLUGIN_WEBHOOK_RECEIPT_LIMIT
    ) {
        this.root = Path(path)
        this.guard = servicePluginWebhookReceiptRootGuard(this.root)
        this.persistHook = persistHook
        this.maxReceipts = max(1, maxReceipts)
    }

    public func reserve(serviceId: String, deliveryId: String, eventId: String, attemptToken!: String = "legacy-test-attempt"): ServicePluginWebhookReceiptDecision {
        if (!servicePluginWebhookReceiptIdentityValid(serviceId, deliveryId, eventId) || !servicePluginWebhookReceiptTokenValid(attemptToken)) {
            return ServicePluginWebhookReceiptDecision("store_unavailable")
        }
        synchronized(this.guard.lock) {
            let identity = ServicePluginWebhookReceiptIdentity(serviceId, deliveryId, eventId)
            let current = this.readLocked(identity)
            if (current.state == "completed_unconfirmed") {
                if (current.attemptToken != attemptToken && !this.persistLocked(identity, "completed_unconfirmed", attemptToken)) {
                    return ServicePluginWebhookReceiptDecision("store_unavailable")
                }
                return ServicePluginWebhookReceiptDecision("completed_unconfirmed")
            }
            if (current.state == "in_flight" || current.state == "store_unavailable") {
                return ServicePluginWebhookReceiptDecision(current.state)
            }
            if (this.receiptCountLocked() >= this.maxReceipts) {
                return ServicePluginWebhookReceiptDecision("store_full")
            }
            if (!this.persistLocked(identity, "in_flight", attemptToken)) { return ServicePluginWebhookReceiptDecision("store_unavailable") }
            ServicePluginWebhookReceiptDecision("reserved")
        }
    }

    public func complete(serviceId: String, deliveryId: String, eventId: String, attemptToken!: String = "legacy-test-attempt"): ServicePluginWebhookReceiptDecision {
        if (!servicePluginWebhookReceiptIdentityValid(serviceId, deliveryId, eventId) || !servicePluginWebhookReceiptTokenValid(attemptToken)) {
            return ServicePluginWebhookReceiptDecision("store_unavailable")
        }
        synchronized(this.guard.lock) {
            let identity = ServicePluginWebhookReceiptIdentity(serviceId, deliveryId, eventId)
            let current = this.readLocked(identity)
            if (current.state == "completed_unconfirmed" && current.attemptToken == attemptToken) {
                return ServicePluginWebhookReceiptDecision("completed_unconfirmed")
            }
            if (current.state != "in_flight" || current.attemptToken != attemptToken) {
                return ServicePluginWebhookReceiptDecision("store_unavailable")
            }
            if (!this.persistLocked(identity, "completed_unconfirmed", attemptToken)) { return ServicePluginWebhookReceiptDecision("store_unavailable") }
            ServicePluginWebhookReceiptDecision("completed_unconfirmed")
        }
    }

    public func confirmAndRemove(serviceId: String, deliveryId: String, eventId: String, attemptToken: String): ServicePluginWebhookReceiptDecision {
        if (!servicePluginWebhookReceiptIdentityValid(serviceId, deliveryId, eventId) || !servicePluginWebhookReceiptTokenValid(attemptToken)) {
            return ServicePluginWebhookReceiptDecision("store_unavailable")
        }
        synchronized(this.guard.lock) {
            let identity = ServicePluginWebhookReceiptIdentity(serviceId, deliveryId, eventId)
            let current = this.readLocked(identity)
            if (current.state != "completed_unconfirmed" || current.attemptToken != attemptToken) {
                return ServicePluginWebhookReceiptDecision("confirmation_mismatch")
            }
            if (!this.persistPhaseAllowed("remove")) { return ServicePluginWebhookReceiptDecision("store_unavailable") }
            try {
                remove(this.receiptPath(identity))
                ServicePluginWebhookReceiptDecision("confirmed")
            } catch (_: Exception) { ServicePluginWebhookReceiptDecision("store_unavailable") }
        }
    }

    public func abandonReserved(serviceId: String, deliveryId: String, eventId: String): ServicePluginWebhookReceiptDecision {
        if (!servicePluginWebhookReceiptIdentityValid(serviceId, deliveryId, eventId)) {
            return ServicePluginWebhookReceiptDecision("store_unavailable")
        }
        synchronized(this.guard.lock) {
            let identity = ServicePluginWebhookReceiptIdentity(serviceId, deliveryId, eventId)
            if (this.readLocked(identity).state != "in_flight") { return ServicePluginWebhookReceiptDecision("store_unavailable") }
            if (!this.persistPhaseAllowed("remove")) { return ServicePluginWebhookReceiptDecision("store_unavailable") }
            try {
                remove(this.receiptPath(identity))
                ServicePluginWebhookReceiptDecision("abandoned")
            } catch (_: Exception) {
                ServicePluginWebhookReceiptDecision("store_unavailable")
            }
        }
    }

    public func state(serviceId: String, deliveryId: String, eventId: String): String {
        if (!servicePluginWebhookReceiptIdentityValid(serviceId, deliveryId, eventId)) { return "store_unavailable" }
        synchronized(this.guard.lock) {
            this.readLocked(ServicePluginWebhookReceiptIdentity(serviceId, deliveryId, eventId)).state
        }
    }

    public func listUnconfirmed(limit!: Int64 = 8): ServicePluginWebhookReceiptListResult {
        let out = ArrayList<ServicePluginWebhookReceipt>()
        synchronized(this.guard.lock) {
            if (!exists(this.root)) { return ServicePluginWebhookReceiptListResult(true, "ok", receipts: out) }
            let unavailable = ArrayList<Bool>()
            unavailable.add(false)
            Directory.walk(this.root) { info: FileInfo =>
                if (!info.isRegular() || !info.path.toString().endsWith(".json")) { return true }
                let row = this.readPathLocked(info.path)
                if (row.state == "store_unavailable") {
                    unavailable[0] = true
                    return false
                }
                if (row.state == "completed_unconfirmed") { out.add(row) }
                out.size < max(1, limit)
            }
            if (unavailable[0]) { ServicePluginWebhookReceiptListResult(false, "store_unavailable") }
            else { ServicePluginWebhookReceiptListResult(true, "ok", receipts: out) }
        }
    }

    public func receiptCountForTest(): Int64 { synchronized(this.guard.lock) { this.receiptCountLocked() } }

    public func receiptPathForTest(serviceId: String, deliveryId: String, eventId: String): Path {
        this.receiptPath(ServicePluginWebhookReceiptIdentity(serviceId, deliveryId, eventId))
    }

    private func readLocked(identity: ServicePluginWebhookReceiptIdentity): ServicePluginWebhookReceipt {
        let path = this.receiptPath(identity)
        if (!exists(path)) { return ServicePluginWebhookReceipt(identity.serviceId, identity.deliveryId, identity.eventId, "", "missing") }
        let row = this.readPathLocked(path)
        if (row.serviceId != identity.serviceId || row.deliveryId != identity.deliveryId || row.eventId != identity.eventId) {
            return ServicePluginWebhookReceipt(identity.serviceId, identity.deliveryId, identity.eventId, "", "store_unavailable")
        }
        row
    }

    private func readPathLocked(path: Path): ServicePluginWebhookReceipt {
        let unavailable = ServicePluginWebhookReceipt("", "", "", "", "store_unavailable")
        let raw = try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { return unavailable }
        try {
            let json = JsonValue.fromStr(raw).asObject()
            let version = json.get("version").getOrThrow().asInt().getValue()
            let serviceId = json.get("serviceId").getOrThrow().asString().getValue().trimAscii()
            let deliveryId = json.get("deliveryId").getOrThrow().asString().getValue().trimAscii()
            let eventId = json.get("eventId").getOrThrow().asString().getValue().trimAscii()
            let attemptToken = json.get("attemptToken").getOrThrow().asString().getValue().trimAscii()
            let state = json.get("state").getOrThrow().asString().getValue().trimAscii()
            if (version != 2 || !servicePluginWebhookReceiptIdentityValid(serviceId, deliveryId, eventId) ||
                !servicePluginWebhookReceiptTokenValid(attemptToken) || !(state == "in_flight" || state == "completed_unconfirmed")) {
                return unavailable
            }
            ServicePluginWebhookReceipt(serviceId, deliveryId, eventId, attemptToken, state)
        } catch (_: Exception) {
            unavailable
        }
    }

    private func persistLocked(identity: ServicePluginWebhookReceiptIdentity, state: String, attemptToken: String): Bool {
        let target = this.receiptPath(identity)
        let tmp = this.root.join(".${target.toString().hashCode()}.${DateTime.now().toUnixTimeStamp().toNanoseconds()}.tmp")
        try {
            if (!exists(this.root)) { Directory.create(this.root, recursive: true) }
            chmod(this.root.toString(), UInt32(0o700))
            if (!this.persistPhaseAllowed("temp")) { throw Exception("receipt temp rejected") }
            let root = JsonObject()
            root.put("version", JsonInt(2))
            root.put("serviceId", JsonString(identity.serviceId))
            root.put("deliveryId", JsonString(identity.deliveryId))
            root.put("eventId", JsonString(identity.eventId))
            root.put("attemptToken", JsonString(attemptToken))
            root.put("state", JsonString(state))
            if (!this.persistPhaseAllowed("write")) { throw Exception("receipt write rejected") }
            File.writeTo(tmp, root.toJsonString().toArray())
            chmod(tmp.toString(), UInt32(0o600))
            if (!this.persistPhaseAllowed("rename")) { throw Exception("receipt rename rejected") }
            rename(tmp, to: target, overwrite: true)
            chmod(target.toString(), UInt32(0o600))
            true
        } catch (_: Exception) {
            try { if (exists(tmp)) { remove(tmp) } } catch (_: Exception) { () }
            false
        }
    }

    private func persistPhaseAllowed(phase: String): Bool {
        match (this.persistHook) {
            case Some(hook) => hook(phase)
            case None => true
        }
    }

    private func receiptCountLocked(): Int64 {
        if (!exists(this.root)) { return 0 }
        let count = ArrayList<Int64>()
        count.add(0)
        Directory.walk(this.root) { info: FileInfo =>
            if (info.isRegular() && info.path.toString().endsWith(".json")) { count[0]++ }
            true
        }
        count[0]
    }

    private func receiptPath(identity: ServicePluginWebhookReceiptIdentity): Path {
        this.root.join("${servicePluginWebhookReceiptHash(identity)}.json")
    }
}

private let servicePluginWebhookReceiptStoreLock = Mutex()
private var defaultServicePluginWebhookReceiptStore: Option<ServicePluginWebhookReceiptStore> = None<ServicePluginWebhookReceiptStore>
private var defaultServicePluginWebhookReceiptStorePath: String = ""

public func servicePluginWebhookReceiptStore(): ServicePluginWebhookReceiptStore {
    let path = MetisPaths.homeRoot().join("service-plugin").join("webhook-receipts").toString()
    synchronized(servicePluginWebhookReceiptStoreLock) {
        if (path != defaultServicePluginWebhookReceiptStorePath || defaultServicePluginWebhookReceiptStore.isNone()) {
            defaultServicePluginWebhookReceiptStore = Some(ServicePluginWebhookReceiptStore(path))
            defaultServicePluginWebhookReceiptStorePath = path
        }
        defaultServicePluginWebhookReceiptStore.getOrThrow()
    }
}

public func resetServicePluginWebhookReceiptStoreForTest(): Unit {
    synchronized(servicePluginWebhookReceiptStoreLock) {
        defaultServicePluginWebhookReceiptStore = None<ServicePluginWebhookReceiptStore>
        defaultServicePluginWebhookReceiptStorePath = ""
    }
}

private func servicePluginWebhookReceiptIdentityValid(serviceId: String, deliveryId: String, eventId: String): Bool {
    !serviceId.isEmpty() && serviceId.size <= 4096 && !deliveryId.isEmpty() && deliveryId.size <= 4096 &&
        !eventId.isEmpty() && eventId.size <= 4096
}

private func servicePluginWebhookReceiptTokenValid(attemptToken: String): Bool {
    !attemptToken.isEmpty() && attemptToken.size <= 4096
}

private func servicePluginWebhookReceiptHash(identity: ServicePluginWebhookReceiptIdentity): String {
    let sha = SHA256()
    sha.write("${identity.serviceId.size}:${identity.serviceId}${identity.deliveryId.size}:${identity.deliveryId}${identity.eventId.size}:${identity.eventId}".toArray())
    let out = StringBuilder()
    let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    for (byte in sha.finish()) {
        out.append(digits[Int64(byte >> 4)])
        out.append(digits[Int64(byte & 0x0f)])
    }
    out.toString()
}

private func servicePluginJobTerminal(status: String): Bool {
    status == "completed" ||
        status == "completed_delivered" ||
        status == "completed_delivery_failed" ||
        status == "failed" ||
        status == "failed_delivered" ||
        status == "cancelled" ||
        status == "cancelled_delivered" ||
        status == "expired" ||
        status == "lost"
}

private func servicePluginPendingJobEncode(job: ServicePluginPendingJob): String {
    [
        job.jobId,
        job.serviceId,
        job.capabilityId,
        job.idempotencyKey,
        job.deliveryTarget.channel,
        job.deliveryTarget.accountId,
        job.deliveryTarget.peerId,
        job.deliveryTarget.threadId,
        job.deliveryTarget.replyToMessageId,
        if (job.deliveryTarget.replyInThread) { "true" } else { "false" },
        job.status,
        job.stage,
        job.summary,
        job.lastError,
        "${job.createdAtMillis}",
        "${job.updatedAtMillis}"
    ].map({ item: String => servicePluginJobEscape(item) }) |> { items: Array<String> => String.join(items, delimiter: "\t") }
}

private func servicePluginPendingJobDecode(line: String): ServicePluginPendingJob {
    let trimmed = line.trimAscii()
    if (trimmed.isEmpty()) {
        return ServicePluginPendingJob()
    }
    let parts = trimmed.split("\t")
    if (parts.size < 16) {
        return ServicePluginPendingJob()
    }
    ServicePluginPendingJob(
        jobId: servicePluginJobUnescape(parts[0]),
        serviceId: servicePluginJobUnescape(parts[1]),
        capabilityId: servicePluginJobUnescape(parts[2]),
        idempotencyKey: servicePluginJobUnescape(parts[3]),
        deliveryTarget: ServicePluginDeliveryTarget(
            servicePluginJobUnescape(parts[4]),
            servicePluginJobUnescape(parts[5]),
            servicePluginJobUnescape(parts[6]),
            threadId: servicePluginJobUnescape(parts[7]),
            replyToMessageId: servicePluginJobUnescape(parts[8]),
            replyInThread: servicePluginJobUnescape(parts[9]) == "true"
        ),
        status: servicePluginJobUnescape(parts[10]),
        stage: servicePluginJobUnescape(parts[11]),
        summary: servicePluginJobUnescape(parts[12]),
        lastError: servicePluginJobUnescape(parts[13]),
        createdAtMillis: try { Int64.parse(parts[14]) } catch (_: Exception) { 0 },
        updatedAtMillis: try { Int64.parse(parts[15]) } catch (_: Exception) { 0 }
    )
}

private func servicePluginJobEscape(raw: String): String {
    raw.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")
}

private func servicePluginJobUnescape(raw: String): String {
    var out = ""
    var i = 0
    while (i < raw.size) {
        if (raw[i] == 92u8 && i + 1 < raw.size) {
            let next = raw[i + 1]
            if (next == 116u8) {
                out += "\t"
                i += 2
                continue
            }
            if (next == 110u8) {
                out += "\n"
                i += 2
                continue
            }
            if (next == 92u8) {
                out += "\\"
                i += 2
                continue
            }
        }
        out += raw[i..(i + 1)]
        i++
    }
    out
}
