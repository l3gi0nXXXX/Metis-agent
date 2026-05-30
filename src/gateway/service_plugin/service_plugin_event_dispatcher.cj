package metis.gateway.service_plugin

import std.collection.{ArrayList, HashMap, HashSet}
import stdx.encoding.json.{JsonObject, JsonValue}

public class ServicePluginEventDeliveryResult {
    public let ok: Bool
    public let status: String
    public let messageId: String
    public let diagnostic: String

    public init(ok: Bool, status: String, messageId!: String = "", diagnostic!: String = "") {
        this.ok = ok
        this.status = status.trimAscii()
        this.messageId = messageId.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
    }
}

public class ServicePluginEventDispatchResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String

    public init(ok: Bool, status: String, diagnostic!: String = "") {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
    }
}

public class ServicePluginAcceptedGitCodeEvent {
    public let jobId: String
    public let eventId: String
    public let repo: String
    public let kind: String
    public let number: String
    public let commentId: String
    public let title: String
    public let url: String
    public let author: String
    public let content: String

    public init(
        jobId!: String = "",
        eventId!: String = "",
        repo!: String = "",
        kind!: String = "",
        number!: String = "",
        commentId!: String = "",
        title!: String = "",
        url!: String = "",
        author!: String = "",
        content!: String = ""
    ) {
        this.jobId = servicePluginAcceptedEventSafeField(jobId, maxBytes: 128)
        this.eventId = servicePluginAcceptedEventSafeField(eventId, maxBytes: 160)
        this.repo = servicePluginAcceptedEventSafeField(repo, maxBytes: 160)
        this.kind = servicePluginAcceptedEventSafeField(kind, maxBytes: 32).toAsciiLower()
        this.number = servicePluginAcceptedEventSafeField(number, maxBytes: 64)
        this.commentId = servicePluginAcceptedEventSafeField(commentId, maxBytes: 64)
        this.title = servicePluginAcceptedEventSafeField(title, maxBytes: 200)
        this.url = servicePluginAcceptedEventSafeField(url, maxBytes: 260)
        this.author = servicePluginAcceptedEventSafeField(author, maxBytes: 120)
        this.content = servicePluginAcceptedEventSafeField(content, maxBytes: 1200)
    }
}

public class ServicePluginGeneratedReplyResult {
    public let ok: Bool
    public let status: String
    public let draft: String
    public let diagnostic: String
    public let needsHumanReview: Bool

    public init(ok: Bool, status!: String = "", draft!: String = "", diagnostic!: String = "", needsHumanReview!: Bool = false) {
        this.ok = ok
        this.status = status.trimAscii()
        this.draft = servicePluginAcceptedEventSafeField(draft, maxBytes: 4096)
        this.diagnostic = servicePluginAcceptedEventSafeField(diagnostic, maxBytes: 512)
        this.needsHumanReview = needsHumanReview
    }
}

private class ServicePluginGeneratedReplyStats {
    public var draftsGenerated: Int64 = 0
    public var draftsFailed: Int64 = 0
    public var notificationsSent: Int64 = 0
    public var notificationsFailed: Int64 = 0
    public init() {}
}

private var servicePluginEventDeliveryForTest: Option<(ServicePluginDeliveryTarget, String) -> ServicePluginEventDeliveryResult> =
    None<(ServicePluginDeliveryTarget, String) -> ServicePluginEventDeliveryResult>
private var servicePluginGeneratedReplyHandlerForTest: Option<(ServicePluginPendingJob, ServicePluginAcceptedGitCodeEvent) -> ServicePluginGeneratedReplyResult> =
    None<(ServicePluginPendingJob, ServicePluginAcceptedGitCodeEvent) -> ServicePluginGeneratedReplyResult>
private let servicePluginGeneratedReplyKeys = HashSet<String>()
private let servicePluginGeneratedReplyStatsByJob = HashMap<String, ServicePluginGeneratedReplyStats>()

public func setServicePluginEventDelivery(
    delivery: Option<(ServicePluginDeliveryTarget, String) -> ServicePluginEventDeliveryResult>
): Unit {
    servicePluginEventDeliveryForTest = delivery
}

public func setServicePluginEventDeliveryForTest(
    delivery: Option<(ServicePluginDeliveryTarget, String) -> ServicePluginEventDeliveryResult>
): Unit {
    setServicePluginEventDelivery(delivery)
}

public func setServicePluginGeneratedReplyHandler(
    handler: Option<(ServicePluginPendingJob, ServicePluginAcceptedGitCodeEvent) -> ServicePluginGeneratedReplyResult>
): Unit {
    servicePluginGeneratedReplyHandlerForTest = handler
}

public func setServicePluginGeneratedReplyHandlerForTest(
    handler: Option<(ServicePluginPendingJob, ServicePluginAcceptedGitCodeEvent) -> ServicePluginGeneratedReplyResult>
): Unit {
    setServicePluginGeneratedReplyHandler(handler)
}

public func resetServicePluginGeneratedReplyStateForTest(): Unit {
    servicePluginGeneratedReplyKeys.clear()
    servicePluginGeneratedReplyStatsByJob.clear()
}

public func dispatchServicePluginEvent(
    frame: ServiceFrame,
    store!: ServicePluginPendingJobStore = servicePluginPendingJobStore()
): ServicePluginEventDispatchResult {
    if (frame.frameType != "event") {
        return ServicePluginEventDispatchResult(false, "unexpected_frame", diagnostic: "expected event frame")
    }
    if (frame.serviceId != "gitcode-monitor") {
        return ServicePluginEventDispatchResult(false, "service_mismatch", diagnostic: "unsupported event service")
    }
    if (frame.capabilityId == "gitcode.event.accepted") {
        return recordGitCodeAcceptedEventForFutureReply(frame, store: store)
    }
    let parsed = parseServicePluginJobEventPayload(frame.capabilityId, frame.payload)
    if (!parsed.ok) {
        return ServicePluginEventDispatchResult(false, parsed.status, diagnostic: parsed.diagnostic)
    }
    let event = parsed.payload
    let job = match (store.findByJobId(event.jobId)) {
        case Some(row) => row
        case None => return ServicePluginEventDispatchResult(false, "orphan_event", diagnostic: "pending job not found")
    }
    if (job.serviceId != frame.serviceId) {
        return ServicePluginEventDispatchResult(false, "service_mismatch", diagnostic: "job belongs to another service")
    }
    if (event.status == "progress") {
        store.markRunning(event.jobId, stage: event.stage)
        return ServicePluginEventDispatchResult(true, "progress_recorded")
    }
    if (job.status.endsWith("_delivered")) {
        return ServicePluginEventDispatchResult(true, "duplicate_event")
    }
    var text = renderServicePluginJobEventMessage(event)
    let replySummary = servicePluginGeneratedReplySummaryForJob(event.jobId)
    if (!replySummary.isEmpty() && event.status == "completed") {
        text += "\n\n${replySummary}"
    }
    let delivery = match (servicePluginEventDeliveryForTest) {
        case Some(sender) => sender(job.deliveryTarget, text)
        case None => ServicePluginEventDeliveryResult(false, "delivery_unconfigured", diagnostic: "service plugin event delivery is not configured")
    }
    if (!delivery.ok) {
        store.markDelivered(event.jobId, "${event.status}_delivery_failed", summary: text)
        return ServicePluginEventDispatchResult(false, "event_delivery_failed", diagnostic: redactServicePayload(delivery.diagnostic).text)
    }
    let deliveredStatus = match (event.status) {
        case "completed" => "completed_delivered"
        case "failed" => "failed_delivered"
        case "cancelled" => "cancelled_delivered"
        case "expired" => "failed_delivered"
        case _ => "${event.status}_delivered"
    }
    store.markDelivered(event.jobId, deliveredStatus, summary: text)
    ServicePluginEventDispatchResult(true, deliveredStatus)
}

private func recordGitCodeAcceptedEventForFutureReply(
    frame: ServiceFrame,
    store!: ServicePluginPendingJobStore = servicePluginPendingJobStore()
): ServicePluginEventDispatchResult {
    let root = match (servicePluginAcceptedEventPayloadRoot(frame.payload)) {
        case Some(obj) => obj
        case None => return ServicePluginEventDispatchResult(false, "event_payload_invalid", diagnostic: "accepted event payload must be a JSON object")
    }
    let diagnostics = ArrayList<String>()
    let event = parseServicePluginAcceptedGitCodeEvent(root, diagnostics)
    if (event.jobId.isEmpty()) { diagnostics.add("jobId is required") }
    if (event.eventId.isEmpty()) { diagnostics.add("eventId is required") }
    if (event.repo.isEmpty()) { diagnostics.add("repo is required") }
    if (diagnostics.size > 0) {
        return ServicePluginEventDispatchResult(false, "event_payload_invalid", diagnostic: String.join(diagnostics.toArray(), delimiter: "; "))
    }
    let job = match (store.findByJobId(event.jobId)) {
        case Some(row) => row
        case None => return ServicePluginEventDispatchResult(false, "orphan_event", diagnostic: "pending job not found for accepted event")
    }
    let key = "${event.jobId}:${event.eventId}"
    if (servicePluginGeneratedReplyKeys.contains(key)) {
        return ServicePluginEventDispatchResult(true, "duplicate_event")
    }
    servicePluginGeneratedReplyKeys.add(key)
    store.markRunning(event.jobId, stage: "event_accepted")
    let generated = match (servicePluginGeneratedReplyHandlerForTest) {
        case Some(handler) => handler(job, event)
        case None => ServicePluginGeneratedReplyResult(false, status: "handler_unconfigured", diagnostic: "generated reply handler is not configured", needsHumanReview: true)
    }
    let text = renderServicePluginGeneratedReplyNotification(event, generated)
    let delivery = match (servicePluginEventDeliveryForTest) {
        case Some(sender) => sender(job.deliveryTarget, text)
        case None => ServicePluginEventDeliveryResult(false, "delivery_unconfigured", diagnostic: "service plugin event delivery is not configured")
    }
    servicePluginRecordGeneratedReplyStats(event.jobId, generated, delivery)
    if (!delivery.ok) {
        return ServicePluginEventDispatchResult(false, "generated_reply_delivery_failed", diagnostic: redactServicePayload(delivery.diagnostic).text)
    }
    if (!generated.ok) {
        return ServicePluginEventDispatchResult(true, "generated_reply_degraded_delivered", diagnostic: generated.diagnostic)
    }
    ServicePluginEventDispatchResult(true, "generated_reply_delivered")
}

public func renderServicePluginGeneratedReplyNotification(event: ServicePluginAcceptedGitCodeEvent, result: ServicePluginGeneratedReplyResult): String {
    var text = "GitCode 回复草稿\n"
    text += "来源: ${servicePluginAcceptedEventSource(event)}\n"
    let title = if (!event.title.isEmpty()) { event.title } else { servicePluginAcceptedEventFirstLine(event.content) }
    if (!title.isEmpty()) {
        text += "标题: ${title}\n"
    }
    if (result.ok) {
        text += "状态: dryRun=true，未写回 GitCode\n\n草稿:\n${result.draft}"
    } else {
        let reason = if (result.diagnostic.isEmpty()) { result.status } else { result.diagnostic }
        text += "状态: needsHumanReview，未写回 GitCode\n原因: ${reason}\n\n草稿:\n"
    }
    redactServicePayload(text).text
}

private func servicePluginGeneratedReplySummaryForJob(jobId: String): String {
    match (servicePluginGeneratedReplyStatsByJob.get(jobId.trimAscii())) {
        case Some(stats) =>
            if (stats.draftsGenerated == 0 && stats.draftsFailed == 0 && stats.notificationsSent == 0 && stats.notificationsFailed == 0) {
                return ""
            }
            return "回复草稿状态:\n已生成草稿 ${stats.draftsGenerated} 条，生成失败 ${stats.draftsFailed} 条，通知成功 ${stats.notificationsSent} 条，通知失败 ${stats.notificationsFailed} 条。"
        case None => ""
    }
}

private func servicePluginRecordGeneratedReplyStats(jobId: String, result: ServicePluginGeneratedReplyResult, delivery: ServicePluginEventDeliveryResult): Unit {
    let key = jobId.trimAscii()
    if (!servicePluginGeneratedReplyStatsByJob.contains(key)) {
        servicePluginGeneratedReplyStatsByJob[key] = ServicePluginGeneratedReplyStats()
    }
    let stats = servicePluginGeneratedReplyStatsByJob[key]
    if (result.ok) {
        stats.draftsGenerated++
    } else {
        stats.draftsFailed++
    }
    if (delivery.ok) {
        stats.notificationsSent++
    } else {
        stats.notificationsFailed++
    }
}

private func servicePluginAcceptedEventPayloadRoot(payload: String): ?JsonObject {
    try {
        Some(JsonValue.fromStr(payload).asObject())
    } catch (_: Exception) {
        None<JsonObject>
    }
}

private func parseServicePluginAcceptedGitCodeEvent(root: JsonObject, diagnostics: ArrayList<String>): ServicePluginAcceptedGitCodeEvent {
    ServicePluginAcceptedGitCodeEvent(
        jobId: servicePluginAcceptedEventString(root, "jobId", diagnostics),
        eventId: servicePluginAcceptedEventString(root, "eventId", diagnostics),
        repo: servicePluginAcceptedEventString(root, "repo", diagnostics),
        kind: servicePluginAcceptedEventAnyString(root, "kind"),
        number: servicePluginAcceptedEventAnyString(root, "number"),
        commentId: servicePluginAcceptedEventAnyString(root, "commentId"),
        title: servicePluginAcceptedEventAnyString(root, "title"),
        url: servicePluginAcceptedEventAnyString(root, "url"),
        author: servicePluginAcceptedEventAnyString(root, "author"),
        content: servicePluginAcceptedEventAnyString(root, "content")
    )
}

private func servicePluginAcceptedEventString(root: JsonObject, key: String, diagnostics: ArrayList<String>): String {
    match (root.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) {
            diagnostics.add("${key} must be string")
            ""
        }
        case None => ""
    }
}

private func servicePluginAcceptedEventAnyString(root: JsonObject, key: String): String {
    match (root.get(key)) {
        case Some(v) =>
            try {
                v.asString().getValue().trimAscii()
            } catch (_: Exception) {
                v.toJsonString().trimAscii().replace("\"", "")
            }
        case None => ""
    }
}

private func servicePluginAcceptedEventSafeField(raw: String, maxBytes!: Int64 = 160): String {
    redactServicePayload(raw.trimAscii(), policy: RedactionPolicy(maxPayloadBytes: maxBytes)).text
}

private func servicePluginAcceptedEventSource(event: ServicePluginAcceptedGitCodeEvent): String {
    var text = if (event.repo.isEmpty()) { "unknown/repo" } else { event.repo }
    let kind = match (event.kind) {
        case "pr" | "pull_request" | "pullrequest" => "PR"
        case "issue" => "Issue"
        case "comment" => "Comment"
        case other => other
    }
    if (!kind.isEmpty()) {
        text += " ${kind}"
    }
    if (!event.number.isEmpty()) {
        text += " #${event.number}"
    }
    if (!event.commentId.isEmpty()) {
        text += " comment #${event.commentId}"
    }
    if (event.url.isEmpty()) {
        text += " 链接: unavailable"
    } else {
        text += " ${event.url}"
    }
    text
}

private func servicePluginAcceptedEventFirstLine(text: String): String {
    let trimmed = text.trimAscii()
    if (trimmed.isEmpty()) { return "" }
    trimmed.split("\n")[0].trimAscii()
}
