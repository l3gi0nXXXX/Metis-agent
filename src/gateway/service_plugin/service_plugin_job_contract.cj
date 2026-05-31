package metis.gateway.service_plugin

import std.collection.ArrayList
import std.convert.Parsable
import std.regex.{Regex, RegexFlag}
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString, JsonValue}

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

public class ServicePluginScanEventSummary {
    public let eventId: String
    public let repo: String
    public let kind: String
    public let number: String
    public let commentId: String
    public let title: String
    public let url: String
    public let status: String
    public let reason: String
    public let notification: String
    public let writeback: String

    public init(
        eventId!: String = "",
        repo!: String = "",
        kind!: String = "",
        number!: String = "",
        commentId!: String = "",
        title!: String = "",
        url!: String = "",
        status!: String = "",
        reason!: String = "",
        notification!: String = "",
        writeback!: String = ""
    ) {
        this.eventId = scanReportSafeField(eventId, maxRunes: 96)
        this.repo = scanReportSafeField(repo, maxRunes: 120)
        this.kind = scanReportSafeField(kind, maxRunes: 32).toAsciiLower()
        this.number = scanReportSafeField(number, maxRunes: 32)
        this.commentId = scanReportSafeField(commentId, maxRunes: 48)
        this.title = scanReportSafeField(title, maxRunes: 180)
        this.url = scanReportSafeField(url, maxRunes: 240)
        this.status = scanReportSafeField(status, maxRunes: 80)
        this.reason = scanReportSafeField(reason, maxRunes: 160)
        this.notification = scanReportSafeField(notification, maxRunes: 120)
        this.writeback = scanReportSafeField(writeback, maxRunes: 120)
    }
}

public class ServicePluginScanReportPayload {
    public let orgs: Array<String>
    public let maxRepos: Int64
    public let maxItems: Int64
    public let timeoutMillis: Int64
    public let stopReason: String
    public let scannedRepos: Int64
    public let checkedItems: Int64
    public let newEvents: Int64
    public let duplicateEvents: Int64
    public let filteredEvents: Int64
    public let failedEvents: Int64
    public let baselineEnabled: Bool
    public let baselineCreatedScopes: Int64
    public let baselineSeededEvents: Int64
    public let backfillEvents: Int64
    public let baselineBackfill: Bool
    public let baselineStatus: String
    public let draftsGenerated: Int64
    public let draftsFailed: Int64
    public let notificationsSent: Int64
    public let writes: Int64
    public let writeMode: String
    public let samplesNew: Array<ServicePluginScanEventSummary>
    public let samplesDuplicate: Array<ServicePluginScanEventSummary>
    public let samplesFiltered: Array<ServicePluginScanEventSummary>
    public let samplesFailed: Array<ServicePluginScanEventSummary>
    public let samplesBaseline: Array<ServicePluginScanEventSummary>

    public init(
        orgs!: Array<String> = [],
        maxRepos!: Int64 = 0,
        maxItems!: Int64 = 0,
        timeoutMillis!: Int64 = 0,
        stopReason!: String = "completed",
        scannedRepos!: Int64 = 0,
        checkedItems!: Int64 = 0,
        newEvents!: Int64 = 0,
        duplicateEvents!: Int64 = 0,
        filteredEvents!: Int64 = 0,
        failedEvents!: Int64 = 0,
        baselineEnabled!: Bool = false,
        baselineCreatedScopes!: Int64 = 0,
        baselineSeededEvents!: Int64 = 0,
        backfillEvents!: Int64 = 0,
        baselineBackfill!: Bool = false,
        baselineStatus!: String = "",
        draftsGenerated!: Int64 = 0,
        draftsFailed!: Int64 = 0,
        notificationsSent!: Int64 = 0,
        writes!: Int64 = 0,
        writeMode!: String = "",
        samplesNew!: Array<ServicePluginScanEventSummary> = [],
        samplesDuplicate!: Array<ServicePluginScanEventSummary> = [],
        samplesFiltered!: Array<ServicePluginScanEventSummary> = [],
        samplesFailed!: Array<ServicePluginScanEventSummary> = [],
        samplesBaseline!: Array<ServicePluginScanEventSummary> = []
    ) {
        this.orgs = orgs
        this.maxRepos = jobBoundNonNegative(maxRepos)
        this.maxItems = jobBoundNonNegative(maxItems)
        this.timeoutMillis = jobBoundNonNegative(timeoutMillis)
        this.stopReason = scanReportSafeField(stopReason, maxRunes: 80)
        this.scannedRepos = jobBoundNonNegative(scannedRepos)
        this.checkedItems = jobBoundNonNegative(checkedItems)
        this.newEvents = jobBoundNonNegative(newEvents)
        this.duplicateEvents = jobBoundNonNegative(duplicateEvents)
        this.filteredEvents = jobBoundNonNegative(filteredEvents)
        this.failedEvents = jobBoundNonNegative(failedEvents)
        this.baselineEnabled = baselineEnabled
        this.baselineCreatedScopes = jobBoundNonNegative(baselineCreatedScopes)
        this.baselineSeededEvents = jobBoundNonNegative(baselineSeededEvents)
        this.backfillEvents = jobBoundNonNegative(backfillEvents)
        this.baselineBackfill = baselineBackfill
        this.baselineStatus = scanReportSafeField(baselineStatus, maxRunes: 80).toAsciiLower()
        this.draftsGenerated = jobBoundNonNegative(draftsGenerated)
        this.draftsFailed = jobBoundNonNegative(draftsFailed)
        this.notificationsSent = jobBoundNonNegative(notificationsSent)
        this.writes = jobBoundNonNegative(writes)
        this.writeMode = scanReportSafeField(writeMode, maxRunes: 48).toAsciiLower()
        this.samplesNew = samplesNew
        this.samplesDuplicate = samplesDuplicate
        this.samplesFiltered = samplesFiltered
        this.samplesFailed = samplesFailed
        this.samplesBaseline = samplesBaseline
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
    public let report: Option<ServicePluginScanReportPayload>

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
        diagnosticHash!: String = "",
        report!: Option<ServicePluginScanReportPayload> = None<ServicePluginScanReportPayload>
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
        this.report = report
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
        diagnosticHash: jobOptionalString(root, "diagnosticHash", diagnostics),
        report: parseServicePluginScanReport(root)
    ))
}

public func renderServicePluginJobEventMessage(event: ServicePluginJobEventPayload): String {
    let status = event.status.trimAscii()
    if (status == "completed") {
        return renderServicePluginScanCompletedMessage(event)
    }
    if (status == "cancelled") {
        return "GitCode 扫描已取消。scanId=${event.jobId}"
    }
    if (status == "failed" || status == "expired") {
        let kind = if (event.errorKind.isEmpty()) { if (status == "expired") { "job_timeout" } else { "job_failed" } } else { event.errorKind }
        let stage = if (event.stage.isEmpty()) { "" } else { " stage=${event.stage}" }
        var text = "GitCode 扫描失败：status=${kind}${stage} retryable=${event.retryable}。可稍后重试。"
        let diagnostic = renderServicePluginJobDiagnosticLine(event.diagnostic)
        if (!diagnostic.isEmpty()) {
            text += "\n${diagnostic}"
        }
        return redactServicePayload(text).text
    }
    "GitCode 扫描状态：status=${status} stage=${event.stage} scanId=${event.jobId}"
}

private func renderServicePluginJobDiagnosticLine(raw: String): String {
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty()) {
        return ""
    }
    let structured = renderServicePluginJobDiagnosticObject(trimmed)
    let text = if (structured.isEmpty()) { sanitizeServicePluginJobDiagnostic(trimmed) } else { structured }
    if (text.isEmpty()) {
        return ""
    }
    "诊断: ${text}"
}

private func renderServicePluginJobDiagnosticObject(raw: String): String {
    let root = match (jobParseObject(raw)) {
        case Some(obj) => obj
        case None => return ""
    }
    let parts = ArrayList<String>()
    addServicePluginJobDiagnosticPart(parts, "repo", jobOptionalAnyString(root, "repo"))
    addServicePluginJobDiagnosticPart(parts, "eventId", jobOptionalAnyString(root, "eventId"))
    addServicePluginJobDiagnosticPart(parts, "kind", jobOptionalAnyString(root, "kind"))
    addServicePluginJobDiagnosticPart(parts, "item", jobOptionalAnyString(root, "item"))
    addServicePluginJobDiagnosticPart(parts, "itemId", jobOptionalAnyString(root, "itemId"))
    addServicePluginJobDiagnosticPart(parts, "stage", jobOptionalAnyString(root, "stage"))
    addServicePluginJobDiagnosticPart(parts, "errorKind", jobOptionalAnyString(root, "errorKind"))
    addServicePluginJobDiagnosticPart(parts, "errorHash", jobOptionalAnyString(root, "errorHash"))
    addServicePluginJobDiagnosticPart(parts, "exception", jobOptionalAnyString(root, "exception"))
    addServicePluginJobDiagnosticPart(parts, "exceptionHash", jobOptionalAnyString(root, "exceptionHash"))
    addServicePluginJobDiagnosticPart(parts, "message", jobOptionalAnyString(root, "message"))
    String.join(parts.toArray(), delimiter: " ")
}

private func addServicePluginJobDiagnosticPart(parts: ArrayList<String>, key: String, raw: String): Unit {
    let value = sanitizeServicePluginJobDiagnostic(raw)
    if (!value.isEmpty()) {
        parts.add("${key}=${value}")
    }
}

private func sanitizeServicePluginJobDiagnostic(raw: String): String {
    var out = raw.replace("\n", " ").replace("\r", " ").trimAscii()
    if (out.isEmpty()) {
        return ""
    }
    out = servicePluginJobRegexReplace(out, "Authorization\\s*[:=]\\s*Bearer\\s+[^\\s,;\\}\\]]+", "credential=[REDACTED]")
    out = servicePluginJobRegexReplace(out, "Authorization\\s*[:=]\\s*[^\\s,;\\}\\]]+", "credential=[REDACTED]")
    out = servicePluginJobRegexReplace(out, "Bearer\\s+[^\\s,;\\}\\]]+", "credential=[REDACTED]")
    out = servicePluginJobRegexReplace(out, "(access[_-]?token|token|cookie|password|private-token|app[_-]?secret)\\s*[:=]\\s*[^\\s,;\\}\\]]+", "credential=[REDACTED]")
    out = servicePluginJobRegexReplace(out, "(/Users|/home)/[^\\s,;\\}\\]]+", "[LOCAL_PATH]")
    out = servicePluginJobRegexReplace(out, "C:\\\\[^\\s,;\\}\\]]+", "[LOCAL_PATH]")
    redactServicePayload(out, policy: RedactionPolicy(maxPayloadBytes: 600)).text
}

private func servicePluginJobRegexReplace(text: String, pattern: String, replacement: String): String {
    try {
        Regex(pattern, [RegexFlag.IgnoreCase]).replaceAll(text, replacement)
    } catch (_: Exception) {
        text
    }
}

public func renderServicePluginScanCompletedMessage(event: ServicePluginJobEventPayload): String {
    match (event.report) {
        case Some(report) =>
            return redactServicePayload(renderServicePluginScanReportSummary(event, report)).text
        case None =>
            return "GitCode 扫描完成\n结果: accepted=${event.accepted} ignored=${event.ignored} emitted=${event.emitted}\n说明: 当前 GCM 未返回扫描明细，无法展示仓库和 PR/Issue 列表。"
    }
}

public func renderServicePluginJobSnapshotMessage(payload: String, fallbackJobId!: String = ""): String {
    let root = match (jobParseObject(payload)) {
        case Some(obj) => obj
        case None => return "GitCode 扫描状态：scanId=${fallbackJobId} status=unknown"
    }
    let diagnostics = ArrayList<String>()
    let status = jobOptionalString(root, "status", diagnostics)
    let jobId = jobOptionalString(root, "jobId", diagnostics)
    let scanId = if (jobId.isEmpty()) { fallbackJobId.trimAscii() } else { jobId }
    let report = parseServicePluginScanReport(root)
    if (status == "completed") {
        return renderServicePluginScanCompletedMessage(ServicePluginJobEventPayload(
            ok: jobOptionalBool(root, "ok", true, diagnostics),
            status: "completed",
            jobId: scanId,
            stage: jobOptionalString(root, "stage", diagnostics),
            accepted: jobOptionalInt(root, "accepted", 0, diagnostics),
            ignored: jobOptionalInt(root, "ignored", 0, diagnostics),
            emitted: jobOptionalInt(root, "emitted", 0, diagnostics),
            durationMs: jobOptionalInt(root, "durationMs", 0, diagnostics),
            stateSaved: jobOptionalBool(root, "stateSaved", false, diagnostics),
            report: report
        ))
    }
    var text = "GitCode 扫描状态：scanId=${scanId} status=${if (status.isEmpty()) { "unknown" } else { status }}"
    let stage = jobOptionalString(root, "stage", diagnostics)
    if (!stage.isEmpty()) {
        text += " stage=${stage}"
    }
    match (report) {
        case Some(r) =>
            text += " 已扫描仓库 ${r.scannedRepos} 个，候选事件 ${r.checkedItems} 条"
        case None => ()
    }
    redactServicePayload(text).text
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

private func parseServicePluginScanReport(root: JsonObject): Option<ServicePluginScanReportPayload> {
    let reportRoot = match (root.get("report")) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { return None<ServicePluginScanReportPayload> }
        case None => return None<ServicePluginScanReportPayload>
    }
    let diagnostics = ArrayList<String>()
    let limits = jobOptionalObjectLenient(reportRoot, "limits")
    let samples = jobOptionalObjectLenient(reportRoot, "samples")
    let baseline = jobOptionalObjectLenient(reportRoot, "baseline")
    let baselineDiagnostics = ArrayList<String>()
    let baselineCreatedScopes = jobOptionalInt(baseline, "createdScopes", jobOptionalInt(reportRoot, "baselineScopesCreated", 0, baselineDiagnostics), baselineDiagnostics)
    let baselineSeededEvents = jobOptionalInt(baseline, "seededEvents", jobOptionalInt(reportRoot, "baselineSeededEvents", 0, baselineDiagnostics), baselineDiagnostics)
    let backfillEvents = jobOptionalInt(baseline, "backfillEvents", jobOptionalInt(reportRoot, "backfillEvents", 0, baselineDiagnostics), baselineDiagnostics)
    Some(ServicePluginScanReportPayload(
        orgs: jobOptionalStringArray(reportRoot, "orgs"),
        maxRepos: jobOptionalInt(limits, "maxRepos", 0, diagnostics),
        maxItems: jobOptionalInt(limits, "maxItems", 0, diagnostics),
        timeoutMillis: jobOptionalInt(limits, "timeoutMillis", 0, diagnostics),
        stopReason: jobOptionalString(reportRoot, "stopReason", diagnostics),
        scannedRepos: jobOptionalInt(reportRoot, "scannedRepos", 0, diagnostics),
        checkedItems: jobOptionalInt(reportRoot, "checkedItems", 0, diagnostics),
        newEvents: jobOptionalInt(reportRoot, "newEvents", 0, diagnostics),
        duplicateEvents: jobOptionalInt(reportRoot, "duplicateEvents", 0, diagnostics),
        filteredEvents: jobOptionalInt(reportRoot, "filteredEvents", 0, diagnostics),
        failedEvents: jobOptionalInt(reportRoot, "failedEvents", 0, diagnostics),
        baselineEnabled: jobOptionalBool(baseline, "enabled", false, baselineDiagnostics),
        baselineCreatedScopes: baselineCreatedScopes,
        baselineSeededEvents: baselineSeededEvents,
        backfillEvents: backfillEvents,
        baselineBackfill: jobOptionalBool(baseline, "backfill", false, baselineDiagnostics),
        baselineStatus: jobOptionalAnyString(baseline, "status"),
        draftsGenerated: jobOptionalInt(reportRoot, "draftsGenerated", 0, diagnostics),
        draftsFailed: jobOptionalInt(reportRoot, "draftsFailed", 0, diagnostics),
        notificationsSent: jobOptionalInt(reportRoot, "notificationsSent", 0, diagnostics),
        writes: jobOptionalInt(reportRoot, "writes", 0, diagnostics),
        writeMode: jobOptionalString(reportRoot, "writeMode", diagnostics),
        samplesNew: parseServicePluginScanEventSamples(samples, "new"),
        samplesDuplicate: parseServicePluginScanEventSamples(samples, "duplicate"),
        samplesFiltered: parseServicePluginScanEventSamples(samples, "filtered"),
        samplesFailed: parseServicePluginScanEventSamples(samples, "failed"),
        samplesBaseline: parseServicePluginScanEventSamples(samples, "baseline")
    ))
}

private func parseServicePluginScanEventSamples(samples: JsonObject, key: String): Array<ServicePluginScanEventSummary> {
    let arr = match (samples.get(key)) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
    let out = ArrayList<ServicePluginScanEventSummary>()
    var count = 0
    for (item in arr.getItems()) {
        if (count >= 20) {
            break
        }
        try {
            let obj = item.asObject()
            out.add(ServicePluginScanEventSummary(
                eventId: jobOptionalAnyString(obj, "eventId"),
                repo: jobOptionalAnyString(obj, "repo"),
                kind: jobOptionalAnyString(obj, "kind"),
                number: jobOptionalAnyString(obj, "number"),
                commentId: jobOptionalAnyString(obj, "commentId"),
                title: jobOptionalAnyString(obj, "title"),
                url: jobOptionalAnyString(obj, "url"),
                status: jobOptionalAnyString(obj, "status"),
                reason: jobOptionalAnyString(obj, "reason"),
                notification: jobOptionalAnyString(obj, "notification"),
                writeback: jobOptionalAnyString(obj, "writeback")
            ))
            count++
        } catch (_: Exception) {
            ()
        }
    }
    out.toArray()
}

private func renderServicePluginScanReportSummary(event: ServicePluginJobEventPayload, report: ServicePluginScanReportPayload): String {
    var text = "GitCode 扫描完成\nscanId: ${event.jobId}\n"
    text += "耗时: ${formatJobDuration(event.durationMs)}\n"
    let scope = renderServicePluginScanScope(report)
    if (!scope.isEmpty()) {
        text += "范围: ${scope}\n"
    }
    let stopReason = renderServicePluginScanStopReason(report)
    if (!stopReason.isEmpty()) {
        text += "${stopReason}\n"
    }
    let mode = renderServicePluginBaselineModeLine(report)
    if (!mode.isEmpty()) {
        text += "模式: ${mode}\n"
    }
    text += "扫描: 仓库 ${report.scannedRepos} 个，候选 PR/Issue/comment ${report.checkedItems} 条\n"
    text += "结果: ${renderServicePluginScanResultLine(report)}\n"
    let warning = renderServicePluginBaselineWarningLine(report)
    if (!warning.isEmpty()) {
        text += "警告: ${warning}\n"
    }
    text += "回复: ${renderServicePluginScanReplyLine(report)}\n"
    text += "通知: ${renderServicePluginScanNotificationLine(report)}\n"
    text += "写回: ${renderServicePluginScanWriteLine(report)}"
    text += renderServicePluginSampleSection("新增事件", report.samplesNew, report.newEvents, true)
    text += renderServicePluginSampleSection("最近重复事件", report.samplesDuplicate, report.duplicateEvents, false)
    text += renderServicePluginSampleSection("基线历史事件样例", report.samplesBaseline, report.baselineSeededEvents, false)
    text += renderServicePluginSampleSection("过滤事件样例", report.samplesFiltered, report.filteredEvents, false)
    text += renderServicePluginSampleSection("失败事件样例", report.samplesFailed, report.failedEvents, false)
    text
}

private func renderServicePluginBaselineModeLine(report: ServicePluginScanReportPayload): String {
    if (!report.baselineEnabled && report.baselineCreatedScopes == 0 && report.baselineSeededEvents == 0 && report.backfillEvents == 0 && report.baselineStatus.isEmpty()) {
        return ""
    }
    match (report.baselineStatus) {
        case "created" => "首次基线"
        case "partial" => "首次基线未完成"
        case "state_save_failed" => "首次基线保存失败"
        case "existing" => "增量扫描"
        case "backfill" => "历史回填"
        case _ =>
            if (report.baselineCreatedScopes > 0 || report.baselineSeededEvents > 0) {
                return if (report.failedEvents > 0) { "首次基线未完成" } else { "首次基线" }
            }
            if (report.baselineEnabled) { "增量扫描" } else { "" }
    }
}

private func renderServicePluginScanResultLine(report: ServicePluginScanReportPayload): String {
    let mode = renderServicePluginBaselineModeLine(report)
    if (mode == "首次基线" || mode == "首次基线保存失败") {
        return "建立基线 ${report.baselineCreatedScopes} 个仓库，标记历史事件 ${report.baselineSeededEvents} 条"
    }
    if (mode == "首次基线未完成") {
        return "建立基线 ${report.baselineCreatedScopes} 个仓库，标记历史事件 ${report.baselineSeededEvents} 条，失败 ${report.failedEvents} 条"
    }
    "新增 ${report.newEvents} 条，重复 ${report.duplicateEvents} 条，过滤 ${report.filteredEvents} 条，失败 ${report.failedEvents} 条"
}

private func renderServicePluginBaselineWarningLine(report: ServicePluginScanReportPayload): String {
    if (report.baselineStatus == "state_save_failed") {
        return "基线状态保存失败，本次基线不能视为已生效。"
    }
    if (report.baselineStatus == "partial" || ((report.baselineCreatedScopes > 0 || report.baselineSeededEvents > 0) && report.failedEvents > 0)) {
        return "基线只完成部分仓库，未完成的仓库不会被视为已建立基线。"
    }
    ""
}

private func renderServicePluginScanScope(report: ServicePluginScanReportPayload): String {
    let parts = ArrayList<String>()
    if (report.orgs.size > 0) {
        parts.add("orgs=${String.join(report.orgs, delimiter: ",")}")
    }
    if (report.maxRepos > 0) {
        parts.add("maxRepos=${report.maxRepos}")
    }
    if (report.maxItems > 0) {
        parts.add("maxItems=${report.maxItems}")
    }
    String.join(parts.toArray(), delimiter: " ")
}

private func renderServicePluginScanStopReason(report: ServicePluginScanReportPayload): String {
    let reason = report.stopReason.trimAscii()
    if (reason.isEmpty() || reason == "completed") {
        return ""
    }
    if (reason == "max_repos_reached") {
        if (report.maxRepos > 0) {
            return "停止原因: 达到用户设置的 maxRepos=${report.maxRepos}"
        }
        return "停止原因: 达到用户设置的 maxRepos 限制"
    }
    if (reason == "max_items_reached") {
        if (report.maxItems > 0) {
            return "停止原因: 达到用户设置的 maxItems=${report.maxItems}"
        }
        return "停止原因: 达到用户设置的 maxItems 限制"
    }
    "停止原因: ${reason}"
}

private func renderServicePluginScanReplyLine(report: ServicePluginScanReportPayload): String {
    let mode = renderServicePluginBaselineModeLine(report)
    if (mode == "首次基线" || mode == "首次基线未完成" || mode == "首次基线保存失败") {
        return "本次只建立基线，不对历史 PR/Issue/comment 生成回复。后续新增事件会生成回复草稿。"
    }
    if (report.newEvents == 0) {
        return "本次没有新增未处理事件，因此未生成新回复。"
    }
    let human = countNeedsHumanReview(report.samplesNew)
    "已生成草稿 ${report.draftsGenerated} 条，需人工确认 ${human} 条，生成失败 ${report.draftsFailed} 条"
}

private func renderServicePluginScanNotificationLine(report: ServicePluginScanReportPayload): String {
    if (report.notificationsSent > 0) {
        return "已发送 ${report.notificationsSent} 条"
    }
    if (report.newEvents == 0) {
        return "本次无新增事件，未发送草稿通知"
    }
    "未返回通知明细"
}

private func renderServicePluginScanWriteLine(report: ServicePluginScanReportPayload): String {
    if (report.writeMode == "dry_run" || report.writeMode == "dryrun") {
        return "dryRun=true，未写回 GitCode。"
    }
    if (report.writes > 0) {
        return "已写回 ${report.writes} 条。"
    }
    "未写回 GitCode。"
}

private func renderServicePluginSampleSection(title: String, samples: Array<ServicePluginScanEventSummary>, total: Int64, detailed: Bool): String {
    if (samples.size == 0) {
        return ""
    }
    var text = "\n\n${title}:\n"
    let limit = 5
    var i = 0
    while (i < samples.size && i < limit) {
        let sample = samples[i]
        if (detailed) {
            text += "${i + 1}. 来源: ${renderServicePluginEventSource(sample)}\n"
            if (!sample.title.isEmpty()) {
                text += "   标题: ${sample.title}\n"
            }
            if (!sample.status.isEmpty()) {
                text += "   状态: ${renderServicePluginEventStatus(sample.status)}\n"
            }
            if (!sample.reason.isEmpty()) {
                text += "   原因: ${sample.reason}\n"
            }
            if (!sample.notification.isEmpty()) {
                text += "   通知: ${sample.notification}\n"
            }
            let write = renderServicePluginEventWriteback(sample)
            if (!write.isEmpty()) {
                text += "   写回: ${write}\n"
            }
        } else {
            let reason = if (sample.reason.isEmpty()) { sample.status } else { sample.reason }
            text += "${i + 1}. ${renderServicePluginCompactEvent(sample)}"
            if (!reason.isEmpty()) {
                text += " - ${reason}"
            }
            text += "\n"
        }
        i++
    }
    let remaining = if (total > i) { total - i } else { if (samples.size > i) { samples.size - i } else { 0 } }
    if (remaining > 0) {
        text += "... 还有 ${remaining} 条${sampleSectionItemName(title)}未展示"
    }
    text
}

private func renderServicePluginEventSource(sample: ServicePluginScanEventSummary): String {
    let base = renderServicePluginCompactEvent(sample)
    if (sample.url.isEmpty()) {
        return "${base} 链接: unavailable"
    }
    "${base} ${sample.url}"
}

private func renderServicePluginCompactEvent(sample: ServicePluginScanEventSummary): String {
    var text = if (sample.repo.isEmpty()) { "unknown/repo" } else { sample.repo }
    let kind = renderServicePluginEventKind(sample.kind)
    if (!kind.isEmpty()) {
        text += " ${kind}"
    }
    if (!sample.number.isEmpty()) {
        text += " #${sample.number}"
    }
    if (!sample.commentId.isEmpty()) {
        text += " comment #${sample.commentId}"
    }
    text
}

private func renderServicePluginEventKind(kind: String): String {
    match (kind.toAsciiLower()) {
        case "pr" | "pull_request" | "pullrequest" => "PR"
        case "issue" => "Issue"
        case "comment" => "Comment"
        case other => other
    }
}

private func renderServicePluginEventStatus(status: String): String {
    match (status.trimAscii()) {
        case "draft_generated" => "已生成回复草稿"
        case "draft_failed" => "回复生成失败"
        case "ckb_degraded" => "CKB 降级"
        case "llm_degraded" => "LLM 降级"
        case other => other
    }
}

private func renderServicePluginEventWriteback(sample: ServicePluginScanEventSummary): String {
    match (sample.writeback.toAsciiLower()) {
        case "dry_run" | "write_skipped_dry_run" => "dry_run，未写回"
        case "write_applied" => "已写回"
        case "write_failed" => "写回失败"
        case other => other
    }
}

private func sampleSectionItemName(title: String): String {
    if (title.contains("新增")) {
        return "新增事件"
    }
    if (title.contains("重复")) {
        return "重复事件"
    }
    if (title.contains("过滤")) {
        return "过滤事件"
    }
    if (title.contains("基线")) {
        return "基线历史事件"
    }
    "失败事件"
}

private func countNeedsHumanReview(samples: Array<ServicePluginScanEventSummary>): Int64 {
    var count: Int64 = 0
    for (sample in samples) {
        let status = sample.status.toAsciiLower()
        if (status.contains("needshumanreview") || status.contains("needs_human_review")) {
            count++
        }
    }
    count
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

private func jobOptionalObjectLenient(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func jobOptionalStringArray(obj: JsonObject, key: String): Array<String> {
    match (obj.get(key)) {
        case Some(v) =>
            try {
                let arr = v.asArray()
                let out = ArrayList<String>()
                for (item in arr.getItems()) {
                    try {
                        let value = scanReportSafeField(item.asString().getValue(), maxRunes: 80)
                        if (!value.isEmpty()) {
                            out.add(value)
                        }
                    } catch (_: Exception) {
                        ()
                    }
                }
                out.toArray()
            } catch (_: Exception) {
                []
            }
        case None => []
    }
}

private func jobOptionalAnyString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) =>
            try {
                return v.asString().getValue().trimAscii()
            } catch (_: Exception) {
                return v.toJsonString().trimAscii()
            }
        case None => ""
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

private func scanReportSafeField(raw: String, maxRunes!: Int64 = 160): String {
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty()) {
        return ""
    }
    redactServicePayload(trimmed, policy: RedactionPolicy(maxPayloadBytes: maxRunes)).text
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
