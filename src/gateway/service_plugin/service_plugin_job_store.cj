package metis.gateway.service_plugin

import std.collection.{ArrayList, HashMap}
import std.convert.Parsable
import std.fs.{File, Path, exists}

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
