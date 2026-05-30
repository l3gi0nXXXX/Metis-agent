package metis.gateway.service_plugin

import std.collection.ArrayList
import std.convert.Parsable
import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

public class ServicePluginDeliveryTarget {
    public let channel: String
    public let accountId: String
    public let peerId: String
    public let threadId: String
    public let replyToMessageId: String
    public let replyInThread: Bool

    public init(
        channel: String,
        accountId: String,
        peerId: String,
        threadId!: String = "",
        replyToMessageId!: String = "",
        replyInThread!: Bool = false
    ) {
        this.channel = channel.trimAscii()
        this.accountId = accountId.trimAscii()
        this.peerId = peerId.trimAscii()
        this.threadId = threadId.trimAscii()
        this.replyToMessageId = replyToMessageId.trimAscii()
        this.replyInThread = replyInThread
    }
}

public class ServicePluginJobLimits {
    public let maxRepos: Int64
    public let maxItems: Int64
    public let maxDurationMillis: Int64
    public let perRequestTimeoutMillis: Int64
    public let progressIntervalMillis: Int64

    public init(
        maxRepos!: Int64 = 0,
        maxItems!: Int64 = 0,
        maxDurationMillis!: Int64 = 0,
        perRequestTimeoutMillis!: Int64 = 30000,
        progressIntervalMillis!: Int64 = 10000
    ) {
        this.maxRepos = jobBoundNonNegative(maxRepos)
        this.maxItems = jobBoundNonNegative(maxItems)
        this.maxDurationMillis = jobBoundNonNegative(maxDurationMillis)
        this.perRequestTimeoutMillis = jobBoundNonNegative(perRequestTimeoutMillis)
        this.progressIntervalMillis = jobBoundNonNegative(progressIntervalMillis)
    }
}

public class ServicePluginJobStartPayload {
    public let mode: String
    public let jobId: String
    public let idempotencyKey: String
    public let requestedBy: String
    public let deliveryTarget: ServicePluginDeliveryTarget
    public let limits: ServicePluginJobLimits
    public let dryRun: Bool
    public let offlineFixture: Bool

    public init(
        mode!: String = "",
        jobId!: String = "",
        idempotencyKey!: String = "",
        requestedBy!: String = "",
        deliveryTarget!: ServicePluginDeliveryTarget = ServicePluginDeliveryTarget("", "", ""),
        limits!: ServicePluginJobLimits = ServicePluginJobLimits(),
        dryRun!: Bool = true,
        offlineFixture!: Bool = false
    ) {
        this.mode = mode.trimAscii()
        this.jobId = jobId.trimAscii()
        this.idempotencyKey = idempotencyKey.trimAscii()
        this.requestedBy = requestedBy
        this.deliveryTarget = deliveryTarget
        this.limits = limits
        this.dryRun = dryRun
        this.offlineFixture = offlineFixture
    }
}

public class ServicePluginJobAcceptedPayload {
    public let ok: Bool
    public let status: String
    public let mode: String
    public let jobId: String
    public let alreadyRunning: Bool

    public init(ok!: Bool = false, status!: String = "", mode!: String = "", jobId!: String = "", alreadyRunning!: Bool = false) {
        this.ok = ok
        this.status = status.trimAscii()
        this.mode = mode.trimAscii()
        this.jobId = jobId.trimAscii()
        this.alreadyRunning = alreadyRunning
    }
}

public class ServicePluginJobEventPayload {
    public let ok: Bool
    public let status: String
    public let jobId: String
    public let stage: String
    public let accepted: Int64
    public let ignored: Int64
    public let emitted: Int64
    public let mcpCalls: Int64
    public let writes: Int64
    public let durationMs: Int64
    public let stateSaved: Bool
    public let errorKind: String
    public let retryable: Bool
    public let diagnostic: String
    public let diagnosticHash: String

    public init(
        ok!: Bool = false,
        status!: String = "",
        jobId!: String = "",
        stage!: String = "",
        accepted!: Int64 = 0,
        ignored!: Int64 = 0,
        emitted!: Int64 = 0,
        mcpCalls!: Int64 = 0,
        writes!: Int64 = 0,
        durationMs!: Int64 = 0,
        stateSaved!: Bool = false,
        errorKind!: String = "",
        retryable!: Bool = false,
        diagnostic!: String = "",
        diagnosticHash!: String = ""
    ) {
        this.ok = ok
        this.status = status.trimAscii()
        this.jobId = jobId.trimAscii()
        this.stage = stage.trimAscii()
        this.accepted = accepted
        this.ignored = ignored
        this.emitted = emitted
        this.mcpCalls = mcpCalls
        this.writes = writes
        this.durationMs = durationMs
        this.stateSaved = stateSaved
        this.errorKind = errorKind.trimAscii()
        this.retryable = retryable
        this.diagnostic = diagnostic
        this.diagnosticHash = diagnosticHash.trimAscii()
    }
}

public class ServicePluginJobStartParseResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String
    public let payload: ServicePluginJobStartPayload

    public init(ok: Bool, status!: String = "ok", diagnostic!: String = "", payload!: ServicePluginJobStartPayload = ServicePluginJobStartPayload()) {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.payload = payload
    }
}

public class ServicePluginJobAcceptedParseResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String
    public let payload: ServicePluginJobAcceptedPayload

    public init(ok: Bool, status!: String = "ok", diagnostic!: String = "", payload!: ServicePluginJobAcceptedPayload = ServicePluginJobAcceptedPayload()) {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.payload = payload
    }
}

public class ServicePluginJobEventParseResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String
    public let payload: ServicePluginJobEventPayload

    public init(ok: Bool, status!: String = "ok", diagnostic!: String = "", payload!: ServicePluginJobEventPayload = ServicePluginJobEventPayload()) {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.payload = payload
    }
}

public func parseServicePluginJobStartPayload(payload: String): ServicePluginJobStartParseResult {
    let root = match (jobParseObject(payload)) {
        case Some(obj) => obj
        case None => return ServicePluginJobStartParseResult(false, status: "job_payload_invalid", diagnostic: "payload must be a JSON object")
    }
    let diagnostics = ArrayList<String>()
    let mode = jobRequiredString(root, "mode", diagnostics)
    let jobId = jobRequiredString(root, "jobId", diagnostics)
    let idempotencyKey = jobRequiredString(root, "idempotencyKey", diagnostics)
    if (mode != "async") { diagnostics.add("mode must be async") }
    validateJobId(jobId, diagnostics)
    if (idempotencyKey.isEmpty()) { diagnostics.add("idempotencyKey is required") }

    let targetRoot = match (root.get("deliveryTarget")) {
        case Some(v) => try { v.asObject() } catch (_: Exception) {
            diagnostics.add("deliveryTarget must be object")
            JsonObject()
        }
        case None =>
            diagnostics.add("deliveryTarget is required")
            JsonObject()
    }
    let target = ServicePluginDeliveryTarget(
        jobRequiredString(targetRoot, "channel", diagnostics),
        jobRequiredString(targetRoot, "accountId", diagnostics),
        jobRequiredString(targetRoot, "peerId", diagnostics),
        threadId: jobOptionalString(targetRoot, "threadId", diagnostics),
        replyToMessageId: jobOptionalString(targetRoot, "replyToMessageId", diagnostics),
        replyInThread: jobOptionalBool(targetRoot, "replyInThread", false, diagnostics)
    )
    validateDeliveryTarget(target, diagnostics)

    let limitsRoot = jobOptionalObject(root, "limits", diagnostics)
    let limits = ServicePluginJobLimits(
        maxRepos: jobOptionalInt(limitsRoot, "maxRepos", 0, diagnostics),
        maxItems: jobOptionalInt(limitsRoot, "maxItems", 0, diagnostics),
        maxDurationMillis: jobOptionalInt(limitsRoot, "maxDurationMillis", 0, diagnostics),
        perRequestTimeoutMillis: jobOptionalInt(limitsRoot, "perRequestTimeoutMillis", 30000, diagnostics),
        progressIntervalMillis: jobOptionalInt(limitsRoot, "progressIntervalMillis", 10000, diagnostics)
    )
    let optionsRoot = jobOptionalObject(root, "options", diagnostics)
    if (diagnostics.size > 0) {
        return ServicePluginJobStartParseResult(false, status: "job_payload_invalid", diagnostic: String.join(diagnostics.toArray(), delimiter: "; "))
    }
    ServicePluginJobStartParseResult(true, payload: ServicePluginJobStartPayload(
        mode: mode,
        jobId: jobId,
        idempotencyKey: idempotencyKey,
        requestedBy: match (root.get("requestedBy")) { case Some(v) => v.toJsonString(); case None => "" },
        deliveryTarget: target,
        limits: limits,
        dryRun: jobOptionalBool(optionsRoot, "dryRun", true, diagnostics),
        offlineFixture: jobOptionalBool(optionsRoot, "offlineFixture", false, diagnostics)
    ))
}

public func parseServicePluginJobAcceptedPayload(payload: String, expectedJobId!: String = ""): ServicePluginJobAcceptedParseResult {
    let root = match (jobParseObject(payload)) {
        case Some(obj) => obj
        case None => return ServicePluginJobAcceptedParseResult(false, status: "job_payload_invalid", diagnostic: "payload must be a JSON object")
    }
    let diagnostics = ArrayList<String>()
    let ok = jobRequiredBool(root, "ok", diagnostics)
    let status = jobRequiredString(root, "status", diagnostics)
    let jobId = jobRequiredString(root, "jobId", diagnostics)
    validateJobId(jobId, diagnostics)
    if (!ok) { diagnostics.add("ok must be true") }
    if (status != "accepted") { diagnostics.add("status must be accepted") }
    let expected = expectedJobId.trimAscii()
    if (!expected.isEmpty() && jobId != expected) { diagnostics.add("jobId mismatch") }
    if (diagnostics.size > 0) {
        return ServicePluginJobAcceptedParseResult(false, status: "job_payload_invalid", diagnostic: String.join(diagnostics.toArray(), delimiter: "; "))
    }
    ServicePluginJobAcceptedParseResult(true, payload: ServicePluginJobAcceptedPayload(
        ok: ok,
        status: status,
        mode: jobOptionalString(root, "mode", diagnostics),
        jobId: jobId,
        alreadyRunning: jobOptionalBool(root, "alreadyRunning", false, diagnostics)
    ))
}

public func parseServicePluginJobEventPayload(capabilityId: String, payload: String): ServicePluginJobEventParseResult {
    let root = match (jobParseObject(payload)) {
        case Some(obj) => obj
        case None => return ServicePluginJobEventParseResult(false, status: "job_payload_invalid", diagnostic: "payload must be a JSON object")
    }
    let diagnostics = ArrayList<String>()
    let ok = jobRequiredBool(root, "ok", diagnostics)
    let status = jobRequiredString(root, "status", diagnostics)
    let jobId = jobRequiredString(root, "jobId", diagnostics)
    validateJobId(jobId, diagnostics)
    if (!jobStatusAllowed(status)) { diagnostics.add("unsupported job event status: ${status}") }
    if (!capabilityMatchesJobStatus(capabilityId, status)) { diagnostics.add("capabilityId/status mismatch") }
    let diagnostic = jobOptionalString(root, "diagnostic", diagnostics)
    if (diagnostic.size > 4096) { diagnostics.add("diagnostic too large: ${hashRawPayload(diagnostic)}") }
    if (diagnostics.size > 0) {
        return ServicePluginJobEventParseResult(false, status: "event_payload_invalid", diagnostic: String.join(diagnostics.toArray(), delimiter: "; "))
    }
    ServicePluginJobEventParseResult(true, payload: ServicePluginJobEventPayload(
        ok: ok,
        status: status,
        jobId: jobId,
        stage: jobOptionalString(root, "stage", diagnostics),
        accepted: jobOptionalInt(root, "accepted", 0, diagnostics),
        ignored: jobOptionalInt(root, "ignored", 0, diagnostics),
        emitted: jobOptionalInt(root, "emitted", 0, diagnostics),
        mcpCalls: jobOptionalInt(root, "mcpCalls", 0, diagnostics),
        writes: jobOptionalInt(root, "writes", 0, diagnostics),
        durationMs: jobOptionalInt(root, "durationMs", 0, diagnostics),
        stateSaved: jobOptionalBool(root, "stateSaved", false, diagnostics),
        errorKind: jobOptionalString(root, "errorKind", diagnostics),
        retryable: jobOptionalBool(root, "retryable", false, diagnostics),
        diagnostic: diagnostic,
        diagnosticHash: jobOptionalString(root, "diagnosticHash", diagnostics)
    ))
}

public func renderServicePluginJobEventMessage(event: ServicePluginJobEventPayload): String {
    let status = event.status.trimAscii()
    if (status == "completed") {
        return "GitCode 扫描完成：accepted=${event.accepted} ignored=${event.ignored} emitted=${event.emitted} duration=${formatJobDuration(event.durationMs)} stateSaved=${event.stateSaved}"
    }
    if (status == "cancelled") {
        return "GitCode 扫描已取消。scanId=${event.jobId}"
    }
    if (status == "failed" || status == "expired") {
        let kind = if (event.errorKind.isEmpty()) { if (status == "expired") { "job_timeout" } else { "job_failed" } } else { event.errorKind }
        let stage = if (event.stage.isEmpty()) { "" } else { " stage=${event.stage}" }
        return redactServicePayload("GitCode 扫描失败：status=${kind}${stage} retryable=${event.retryable}。可稍后重试。").text
    }
    "GitCode 扫描状态：status=${status} stage=${event.stage} scanId=${event.jobId}"
}

public func servicePluginDeliveryTargetToJson(target: ServicePluginDeliveryTarget): JsonObject {
    let obj = JsonObject()
    obj.put("channel", JsonString(target.channel))
    obj.put("accountId", JsonString(target.accountId))
    obj.put("peerId", JsonString(target.peerId))
    obj.put("threadId", JsonString(target.threadId))
    obj.put("replyToMessageId", JsonString(target.replyToMessageId))
    obj.put("replyInThread", JsonBool(target.replyInThread))
    obj
}

private func jobParseObject(payload: String): ?JsonObject {
    try {
        Some(JsonValue.fromStr(payload.trimAscii()).asObject())
    } catch (_: Exception) {
        None<JsonObject>
    }
}

private func jobOptionalObject(obj: JsonObject, key: String, diagnostics: ArrayList<String>): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) {
            diagnostics.add("${key} must be object")
            JsonObject()
        }
        case None => JsonObject()
    }
}

private func jobRequiredString(obj: JsonObject, key: String, diagnostics: ArrayList<String>): String {
    let value = jobOptionalString(obj, key, diagnostics)
    if (value.isEmpty()) { diagnostics.add("${key} is required") }
    value
}

private func jobOptionalString(obj: JsonObject, key: String, diagnostics: ArrayList<String>): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) {
            diagnostics.add("${key} must be string")
            ""
        }
        case None => ""
    }
}

private func jobRequiredBool(obj: JsonObject, key: String, diagnostics: ArrayList<String>): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) {
            diagnostics.add("${key} must be boolean")
            false
        }
        case None =>
            diagnostics.add("${key} is required")
            false
    }
}

private func jobOptionalBool(obj: JsonObject, key: String, fallback: Bool, diagnostics: ArrayList<String>): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) {
            diagnostics.add("${key} must be boolean")
            fallback
        }
        case None => fallback
    }
}

private func jobOptionalInt(obj: JsonObject, key: String, fallback: Int64, diagnostics: ArrayList<String>): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            let parsed = try { Int64.parse(v.toJsonString()) } catch (_: Exception) {
                diagnostics.add("${key} must be integer")
                fallback
            }
            jobBoundNonNegative(parsed)
        case None => fallback
    }
}

private func validateJobId(jobId: String, diagnostics: ArrayList<String>): Unit {
    if (jobId.isEmpty()) { diagnostics.add("jobId is required") }
    if (jobId.size > 128) { diagnostics.add("jobId too long") }
}

private func validateDeliveryTarget(target: ServicePluginDeliveryTarget, diagnostics: ArrayList<String>): Unit {
    if (!(target.channel == "telegram" || target.channel == "feishu")) { diagnostics.add("channel is invalid") }
    if (target.accountId.isEmpty()) { diagnostics.add("accountId is required") }
    if (target.peerId.isEmpty()) { diagnostics.add("peerId is required") }
}

private func jobStatusAllowed(status: String): Bool {
    status == "progress" || status == "completed" || status == "failed" || status == "cancelled" || status == "expired"
}

private func capabilityMatchesJobStatus(capabilityId: String, status: String): Bool {
    (capabilityId == "gitcode.monitor.scan_progress" && status == "progress") ||
        (capabilityId == "gitcode.monitor.scan_completed" && status == "completed") ||
        (capabilityId == "gitcode.monitor.scan_failed" && status == "failed") ||
        (capabilityId == "gitcode.monitor.scan_cancelled" && status == "cancelled") ||
        (capabilityId == "gitcode.monitor.scan_failed" && status == "expired")
}

private func jobBoundNonNegative(value: Int64): Int64 {
    if (value < 0) { 0 } else { value }
}

private func formatJobDuration(durationMs: Int64): String {
    if (durationMs <= 0) {
        return "0.0s"
    }
    let tenths = durationMs / 100
    "${tenths / 10}.${tenths % 10}s"
}
