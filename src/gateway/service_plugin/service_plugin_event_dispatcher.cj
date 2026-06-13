package metis.gateway.service_plugin

import std.collection.{ArrayList, HashMap, HashSet}
import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

private const SERVICE_PLUGIN_GITCODE_REVIEW_CONTRACT_VERSION: String = "gcm-metis-gitcode-review-v1"

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
    public let eventId: String
    public let eventIdHash: String
    public let capabilityId: String
    public let targetCount: Int64
    public let deliverySuccess: Int64
    public let deliveryFailed: Int64
    public let diagnosticHash: String
    public let failureDetails: Array<String>
    public let telegram: Int64
    public let feishu: Int64
    public let noSubscriberCount: Int64

    public init(
        ok: Bool,
        status: String,
        diagnostic!: String = "",
        eventId!: String = "",
        eventIdHash!: String = "",
        capabilityId!: String = "",
        targetCount!: Int64 = 0,
        deliverySuccess!: Int64 = 0,
        deliveryFailed!: Int64 = 0,
        diagnosticHash!: String = "",
        failureDetails!: Array<String> = [],
        telegram!: Int64 = 0,
        feishu!: Int64 = 0,
        noSubscriberCount!: Int64 = 0
    ) {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.eventId = eventId.trimAscii()
        this.eventIdHash = eventIdHash.trimAscii()
        this.capabilityId = capabilityId.trimAscii()
        this.targetCount = targetCount
        this.deliverySuccess = deliverySuccess
        this.deliveryFailed = deliveryFailed
        this.diagnosticHash = diagnosticHash.trimAscii()
        this.failureDetails = failureDetails
        this.telegram = telegram
        this.feishu = feishu
        this.noSubscriberCount = noSubscriberCount
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
    public let contractVersion: String
    public let reviewRequestRaw: String

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
        content!: String = "",
        contractVersion!: String = "",
        reviewRequestRaw!: String = ""
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
        this.contractVersion = servicePluginAcceptedEventSafeField(contractVersion, maxBytes: 128)
        this.reviewRequestRaw = servicePluginAcceptedEventSafeField(reviewRequestRaw, maxBytes: 24000)
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

public class ServicePluginWritebackApplyState {
    public let configured: Bool
    public let ok: Bool
    public let status: String
    public let posted: Bool
    public let skipped: Bool
    public let timedOut: Bool
    public let replyUrl: String
    public let diagnostic: String
    public let maintainerMentionAppended: Bool
    public let teamLeaderCount: Int64
    public let codeownerCount: Int64
    public let contextSource: String
    public let emailNotificationStatus: String
    public let emailSentCount: Int64
    public let emailFailedCount: Int64
    public let emailRetryable: Bool

    public init(
        configured!: Bool = false,
        ok!: Bool = true,
        status!: String = "not_configured",
        posted!: Bool = false,
        skipped!: Bool = false,
        timedOut!: Bool = false,
        replyUrl!: String = "",
        diagnostic!: String = "",
        maintainerMentionAppended!: Bool = false,
        teamLeaderCount!: Int64 = 0,
        codeownerCount!: Int64 = 0,
        contextSource!: String = "",
        emailNotificationStatus!: String = "",
        emailSentCount!: Int64 = 0,
        emailFailedCount!: Int64 = 0,
        emailRetryable!: Bool = false
    ) {
        this.configured = configured
        this.ok = ok
        this.status = status.trimAscii()
        this.posted = posted
        this.skipped = skipped
        this.timedOut = timedOut
        this.replyUrl = servicePluginAcceptedEventSafeField(replyUrl, maxBytes: 320)
        this.diagnostic = servicePluginAcceptedEventSafeField(diagnostic, maxBytes: 240)
        this.maintainerMentionAppended = maintainerMentionAppended
        this.teamLeaderCount = teamLeaderCount
        this.codeownerCount = codeownerCount
        this.contextSource = servicePluginAcceptedEventSafeField(contextSource, maxBytes: 80)
        this.emailNotificationStatus = servicePluginAcceptedEventSafeField(emailNotificationStatus, maxBytes: 80)
        this.emailSentCount = emailSentCount
        this.emailFailedCount = emailFailedCount
        this.emailRetryable = emailRetryable
    }
}

private var servicePluginEventDeliveryForTest: Option<(ServicePluginDeliveryTarget, String) -> ServicePluginEventDeliveryResult> =
    None<(ServicePluginDeliveryTarget, String) -> ServicePluginEventDeliveryResult>
private var servicePluginGeneratedReplyHandlerForTest: Option<(ServicePluginPendingJob, ServicePluginAcceptedGitCodeEvent) -> ServicePluginGeneratedReplyResult> =
    None<(ServicePluginPendingJob, ServicePluginAcceptedGitCodeEvent) -> ServicePluginGeneratedReplyResult>
private var servicePluginWebhookGeneratedReplyHandlerForTest: Option<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult> =
    None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>
private var servicePluginWebhookSubscribersProviderForTest: Option<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>> =
    None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>
private let servicePluginGeneratedReplyKeys = HashSet<String>()
private let servicePluginGeneratedReplyStatsByJob = HashMap<String, ServicePluginGeneratedReplyStats>()
private let servicePluginWebhookDispatchKeys = HashSet<String>()

public class ServicePluginWebhookDispatchStat {
    public let eventId: String
    public let eventIdHash: String
    public let status: String
    public let targetCount: Int64
    public let deliverySuccess: Int64
    public let deliveryFailed: Int64
    public let diagnosticHash: String
    public let noSubscriberCount: Int64
    public let telegram: Int64
    public let feishu: Int64
    public let updatedAtMs: Int64
    public init(
        eventId: String,
        eventIdHash: String,
        status: String,
        targetCount: Int64,
        deliverySuccess: Int64,
        deliveryFailed: Int64,
        diagnosticHash!: String = "",
        noSubscriberCount!: Int64 = 0,
        telegram!: Int64 = 0,
        feishu!: Int64 = 0,
        updatedAtMs!: Int64 = 0
    ) {
        this.eventId = eventId
        this.eventIdHash = eventIdHash
        this.status = status
        this.targetCount = targetCount
        this.deliverySuccess = deliverySuccess
        this.deliveryFailed = deliveryFailed
        this.diagnosticHash = diagnosticHash
        this.noSubscriberCount = noSubscriberCount
        this.telegram = telegram
        this.feishu = feishu
        this.updatedAtMs = updatedAtMs
    }
}

private let servicePluginWebhookDispatchStats = ArrayList<ServicePluginWebhookDispatchStat>()

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

public func setServicePluginWebhookGeneratedReplyHandler(
    handler: Option<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>
): Unit {
    servicePluginWebhookGeneratedReplyHandlerForTest = handler
}

public func setServicePluginWebhookGeneratedReplyHandlerForTest(
    handler: Option<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>
): Unit {
    setServicePluginWebhookGeneratedReplyHandler(handler)
}

public func setServicePluginWebhookSubscribersProvider(
    provider: Option<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>
): Unit {
    servicePluginWebhookSubscribersProviderForTest = provider
}

public func setServicePluginWebhookSubscribersProviderForTest(
    provider: Option<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>
): Unit {
    setServicePluginWebhookSubscribersProvider(provider)
}

public func resetServicePluginGeneratedReplyStateForTest(): Unit {
    servicePluginGeneratedReplyKeys.clear()
    servicePluginGeneratedReplyStatsByJob.clear()
    servicePluginWebhookDispatchKeys.clear()
    servicePluginWebhookDispatchStats.clear()
}

public func servicePluginWebhookDispatchStatsSnapshot(): ArrayList<ServicePluginWebhookDispatchStat> {
    let out = ArrayList<ServicePluginWebhookDispatchStat>()
    for (stat in servicePluginWebhookDispatchStats) {
        out.add(stat)
    }
    out
}

public func recordServicePluginWebhookDispatchStatForTest(stat: ServicePluginWebhookDispatchStat): Unit {
    servicePluginRecordWebhookDispatchStat(stat)
}

public func servicePluginWebhookDispatchStatsJson(): JsonObject {
    let root = JsonObject()
    var noSubscribers: Int64 = 0
    var success: Int64 = 0
    var partialFailed: Int64 = 0
    var failed: Int64 = 0
    var latestStatus = ""
    var latestEventIdHash = ""
    var latestTelegram: Int64 = 0
    var latestFeishu: Int64 = 0
    for (stat in servicePluginWebhookDispatchStats) {
        if (stat.noSubscriberCount > 0 || stat.status == "no_subscribers") {
            noSubscribers++
        } else if (stat.status == "generated_reply_partially_delivered") {
            partialFailed++
            failed += stat.deliveryFailed
        } else if (stat.deliveryFailed > 0 || stat.status == "generated_reply_delivery_failed") {
            failed += if (stat.deliveryFailed > 0) { stat.deliveryFailed } else { 1 }
        } else if (stat.status == "generated_reply_delivered" || stat.status == "generated_reply_degraded_delivered") {
            success++
        }
        latestStatus = stat.status
        latestEventIdHash = stat.eventIdHash
        latestTelegram = stat.telegram
        latestFeishu = stat.feishu
    }
    root.put("total", JsonInt(servicePluginWebhookDispatchStats.size))
    root.put("noSubscribers", JsonInt(noSubscribers))
    root.put("success", JsonInt(success))
    root.put("partialFailed", JsonInt(partialFailed))
    root.put("failed", JsonInt(failed))
    root.put("telegram", JsonInt(latestTelegram))
    root.put("feishu", JsonInt(latestFeishu))
    root.put("latestStatus", JsonString(latestStatus))
    root.put("latestEventIdHash", JsonString(latestEventIdHash))
    root
}

public func dispatchServicePluginEvent(
    frame: ServiceFrame,
    store!: ServicePluginPendingJobStore = servicePluginPendingJobStore()
): ServicePluginEventDispatchResult {
    if (frame.frameType != "event") {
        return servicePluginDispatchResult(frame, false, "unexpected_frame", diagnostic: "expected event frame")
    }
    if (frame.serviceId != "gitcode-monitor") {
        return servicePluginDispatchResult(frame, false, "service_mismatch", diagnostic: "unsupported event service")
    }
    if (frame.capabilityId != "gitcode.monitor.orphan_detected" && servicePluginRuntimeIsOrphanDrainingForDispatch(frame.serviceId)) {
        return servicePluginDispatchResult(frame, false, "service_orphan_draining", diagnostic: "service plugin is draining after orphan_detected")
    }
    if (frame.capabilityId == "gitcode.event.accepted") {
        return recordGitCodeAcceptedEventForFutureReply(frame, store: store)
    }
    if (frame.capabilityId == "gitcode.monitor.orphan_detected") {
        return recordGitCodeMonitorOrphanDetected(frame)
    }
    let parsed = parseServicePluginJobEventPayload(frame.capabilityId, frame.payload)
    if (!parsed.ok) {
        return servicePluginDispatchResult(frame, false, parsed.status, diagnostic: parsed.diagnostic)
    }
    let event = parsed.payload
    let job = match (store.findByJobId(event.jobId)) {
        case Some(row) => row
        case None => return servicePluginDispatchResult(frame, false, "orphan_event", diagnostic: "pending job not found")
    }
    if (job.serviceId != frame.serviceId) {
        return servicePluginDispatchResult(frame, false, "service_mismatch", diagnostic: "job belongs to another service")
    }
    if (event.status == "progress") {
        store.markRunning(event.jobId, stage: event.stage)
        return servicePluginDispatchResult(frame, true, "progress_recorded")
    }
    if (job.status.endsWith("_delivered")) {
        return servicePluginDispatchResult(frame, true, "duplicate_event")
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
        return servicePluginDispatchResult(frame, false, "event_delivery_failed", diagnostic: redactServicePayload(delivery.diagnostic).text, targetCount: 1, deliveryFailed: 1)
    }
    let deliveredStatus = match (event.status) {
        case "completed" => "completed_delivered"
        case "failed" => "failed_delivered"
        case "cancelled" => "cancelled_delivered"
        case "expired" => "failed_delivered"
        case _ => "${event.status}_delivered"
    }
    store.markDelivered(event.jobId, deliveredStatus, summary: text)
    servicePluginDispatchResult(frame, true, deliveredStatus, targetCount: 1, deliverySuccess: 1)
}

private func recordGitCodeMonitorOrphanDetected(frame: ServiceFrame): ServicePluginEventDispatchResult {
    let root = match (servicePluginAcceptedEventPayloadRoot(frame.payload)) {
        case Some(obj) => obj
        case None => return servicePluginDispatchResult(frame, false, "event_payload_invalid", diagnostic: "orphan payload must be a JSON object")
    }
    let status = servicePluginAcceptedEventAnyString(root, "status")
    if (status != "orphan_detected") {
        return servicePluginDispatchResult(frame, false, "event_payload_invalid", diagnostic: "unsupported orphan status: ${status}")
    }
    let sessionId = servicePluginAcceptedEventAnyString(root, "sessionId")
    let reason = servicePluginAcceptedEventAnyString(root, "orphanReason")
    let pid = servicePluginJsonInt(root, "pid")
    let parentPid = servicePluginJsonInt(root, "parentPid")
    let port = servicePluginJsonInt(root, "port")
    let diagnostic = "GCM service plugin orphan detected sessionId=${sessionId} pid=${pid} parentPid=${parentPid} port=${port} reason=${reason}"
    servicePluginDispatchResult(frame, false, "orphan_detected", diagnostic: diagnostic, eventId: sessionId)
}

private func recordGitCodeAcceptedEventForFutureReply(
    frame: ServiceFrame,
    store!: ServicePluginPendingJobStore = servicePluginPendingJobStore()
): ServicePluginEventDispatchResult {
    let root = match (servicePluginAcceptedEventPayloadRoot(frame.payload)) {
        case Some(obj) => obj
        case None => return servicePluginDispatchResult(frame, false, "event_payload_invalid", diagnostic: "accepted event payload must be a JSON object")
    }
    let diagnostics = ArrayList<String>()
    let event = parseServicePluginAcceptedGitCodeEvent(root, diagnostics)
    if (event.jobId.isEmpty()) { diagnostics.add("missing jobId") }
    if (event.eventId.isEmpty()) { diagnostics.add("missing eventId") }
    if (event.repo.isEmpty()) { diagnostics.add("missing repo") }
    if (event.url.isEmpty()) { diagnostics.add("missing url") }
    servicePluginValidateAcceptedReviewContract(event, diagnostics)
    if (diagnostics.size > 0) {
        return servicePluginDispatchResult(frame, false, "event_payload_invalid", diagnostic: diagnostics[0], eventId: event.eventId)
    }
    let job = match (store.findByJobId(event.jobId)) {
        case Some(row) => row
        case None =>
            if (event.jobId.startsWith("webhook-")) {
                return dispatchGitCodeWebhookAcceptedEvent(frame, event)
            }
            return servicePluginDispatchResult(frame, false, "orphan_event", diagnostic: "pending job not found for gitcode.event.accepted", eventId: event.eventId)
    }
    let key = "${event.jobId}:${event.eventId}"
    if (servicePluginGeneratedReplyKeys.contains(key)) {
        return servicePluginDispatchResult(frame, true, "duplicate_event", eventId: event.eventId)
    }
    servicePluginGeneratedReplyKeys.add(key)
    store.markRunning(event.jobId, stage: "event_accepted")
    let rawGenerated = match (servicePluginGeneratedReplyHandlerForTest) {
        case Some(handler) => handler(job, event)
        case None => ServicePluginGeneratedReplyResult(false, status: "handler_unconfigured", diagnostic: "generated reply handler is not configured", needsHumanReview: true)
    }
    let generated = normalizeServicePluginGeneratedReplyResult(rawGenerated)
    let writeback = servicePluginApplyGeneratedReplyWriteback(event, generated)
    let text = renderServicePluginGeneratedReplyNotification(event, generated, writeback: writeback)
    let delivery = match (servicePluginEventDeliveryForTest) {
        case Some(sender) => sender(job.deliveryTarget, text)
        case None => ServicePluginEventDeliveryResult(false, "delivery_unconfigured", diagnostic: "service plugin event delivery is not configured")
    }
    servicePluginRecordGeneratedReplyStats(event.jobId, generated, delivery)
    if (!delivery.ok) {
        return servicePluginDispatchResult(frame, false, "generated_reply_delivery_failed", diagnostic: redactServicePayload(delivery.diagnostic).text, eventId: event.eventId, targetCount: 1, deliveryFailed: 1)
    }
    if (!generated.ok || servicePluginWritebackDegraded(writeback)) {
        return servicePluginDispatchResult(frame, true, "generated_reply_degraded_delivered", diagnostic: generated.diagnostic, eventId: event.eventId, targetCount: 1, deliverySuccess: 1)
    }
    servicePluginDispatchResult(frame, true, "generated_reply_delivered", eventId: event.eventId, targetCount: 1, deliverySuccess: 1)
}

public func dispatchGitCodeWebhookAcceptedEvent(frame: ServiceFrame, event: ServicePluginAcceptedGitCodeEvent): ServicePluginEventDispatchResult {
    let key = servicePluginAcceptedEventDedupeKey(event)
    if (servicePluginWebhookDispatchKeys.contains(key)) {
        let result = servicePluginDispatchResult(frame, true, "duplicate_event", eventId: event.eventId)
        servicePluginRecordWebhookDispatchResult(result)
        return result
    }
    let targets = resolveGitCodeWebhookSubscribers(event)
    if (targets.size == 0) {
        let result = servicePluginDispatchResult(
            frame,
            true,
            "no_subscribers",
            diagnostic: servicePluginGitCodeNoSubscriberHint(),
            eventId: event.eventId,
            targetCount: 0,
            noSubscriberCount: 1
        )
        servicePluginRecordWebhookDispatchResult(result)
        return result
    }
    servicePluginWebhookDispatchKeys.add(key)
    var success: Int64 = 0
    var failed: Int64 = 0
    var telegram: Int64 = 0
    var feishu: Int64 = 0
    let failures = ArrayList<String>()
    let primary = targets[0]
    let rawGenerated = match (servicePluginWebhookGeneratedReplyHandlerForTest) {
        case Some(handler) => handler(event, primary)
        case None => ServicePluginGeneratedReplyResult(false, status: "handler_unconfigured", diagnostic: "generated reply handler is not configured", needsHumanReview: true)
    }
    let generated = normalizeServicePluginGeneratedReplyResult(rawGenerated)
    let writeback = servicePluginApplyGeneratedReplyWriteback(event, generated)
    let text = renderServicePluginGeneratedReplyNotification(event, generated, writeback: writeback)
    for (target in targets) {
        let delivery = servicePluginDeliverWebhookTarget(target, text)
        if (delivery.ok) {
            success++
            let channel = target.channel.toAsciiLower()
            if (channel == "telegram") {
                telegram++
            } else if (channel == "feishu") {
                feishu++
            }
        } else {
            failed++
            failures.add(servicePluginDeliveryFailureDetail(target, delivery))
        }
    }
    let writebackDegraded = servicePluginWritebackDegraded(writeback)
    let status = if (failed == 0 && generated.ok && !writebackDegraded) {
        "generated_reply_delivered"
    } else if (failed == 0) {
        "generated_reply_degraded_delivered"
    } else if (success > 0) {
        "generated_reply_partially_delivered"
    } else {
        "generated_reply_delivery_failed"
    }
    let result = servicePluginDispatchResult(
        frame,
        success > 0 || status == "generated_reply_degraded_delivered",
        status,
        diagnostic: generated.diagnostic,
        eventId: event.eventId,
        targetCount: targets.size,
        deliverySuccess: success,
        deliveryFailed: failed,
        failureDetails: failures.toArray(),
        telegram: telegram,
        feishu: feishu
    )
    servicePluginRecordWebhookDispatchResult(result)
    result
}

public func resolveGitCodeWebhookSubscribers(event: ServicePluginAcceptedGitCodeEvent): ArrayList<ServicePluginDeliveryTarget> {
    match (servicePluginWebhookSubscribersProviderForTest) {
        case Some(provider) => provider(event)
        case None => ArrayList<ServicePluginDeliveryTarget>()
    }
}

public func servicePluginAcceptedEventDedupeKey(event: ServicePluginAcceptedGitCodeEvent): String {
    if (!event.eventId.isEmpty()) { event.eventId } else { "${event.repo}:${event.kind}:${event.number}:${event.url}" }
}

public func servicePluginDispatchDiagnosticSummary(frame: ServiceFrame, result: ServicePluginEventDispatchResult): String {
    let eventHash = if (!result.eventIdHash.isEmpty()) { result.eventIdHash } else { servicePluginDiagnosticHash(frame.payload) }
    let diagnosticHash = if (!result.diagnosticHash.isEmpty()) { result.diagnosticHash } else { servicePluginDiagnosticHash(result.diagnostic) }
    var base = "serviceId=${frame.serviceId} capabilityId=${frame.capabilityId} status=${result.status} eventIdHash=${eventHash} diagnosticHash=${diagnosticHash} targetCount=${result.targetCount} deliverySuccess=${result.deliverySuccess} deliveryFailed=${result.deliveryFailed}"
    if (result.status == "orphan_detected" && !result.diagnostic.isEmpty()) {
        base += " diagnostic=${result.diagnostic}"
    }
    if (base.size <= 512) { return base }
    base[0..512]
}

public func renderServicePluginGeneratedReplyNotification(
    event: ServicePluginAcceptedGitCodeEvent,
    result: ServicePluginGeneratedReplyResult,
    writeback!: ServicePluginWritebackApplyState = ServicePluginWritebackApplyState()
): String {
    try {
        var text = "GitCode 回复草稿\n"
        text += "来源: ${servicePluginAcceptedEventSource(event)}\n"
        let title = if (!event.title.isEmpty()) { event.title } else { servicePluginAcceptedEventFirstLine(event.content) }
        if (!title.isEmpty()) {
            text += "标题: ${title}\n"
        }
        if (result.ok) {
            text += servicePluginWritebackNotificationLine(writeback)
            text += "\n\n草稿:\n${result.draft}"
        } else {
            let reason = servicePluginGeneratedReplyHumanReason(result)
            text += "状态: needsHumanReview，未写回 GitCode\n原因: ${reason}\n\n草稿:\n"
        }
        redactServicePayload(text).text
    } catch (e: Exception) {
        servicePluginGeneratedReplyNotificationFallback(event, e.message)
    }
}

private func servicePluginDeliverWebhookTarget(target: ServicePluginDeliveryTarget, text: String): ServicePluginEventDeliveryResult {
    try {
        match (servicePluginEventDeliveryForTest) {
            case Some(sender) => sender(target, text)
            case None => ServicePluginEventDeliveryResult(false, "delivery_unconfigured", diagnostic: "service plugin event delivery is not configured")
        }
    } catch (e: Exception) {
        ServicePluginEventDeliveryResult(false, "send_failed", diagnostic: redactServicePayload(e.message).text)
    }
}

private func servicePluginDeliveryFailureDetail(target: ServicePluginDeliveryTarget, delivery: ServicePluginEventDeliveryResult): String {
    let channel = target.channel.trimAscii()
    let accountId = target.accountId.trimAscii()
    let status = if (delivery.status.isEmpty()) { "send_failed" } else { delivery.status }
    let diagnostic = redactServicePayload(delivery.diagnostic).text
    var detail = "channel=${channel} accountId=${accountId} status=${status}"
    if (!diagnostic.isEmpty()) {
        detail += " diagnostic=${diagnostic}"
    }
    redactServicePayload(detail).text
}

private func servicePluginGeneratedReplyNotificationFallback(event: ServicePluginAcceptedGitCodeEvent, diagnostic: String): String {
    var text = "GitCode 回复草稿\n"
    text += "来源: ${servicePluginAcceptedEventSource(event)}\n"
    text += "状态: needsHumanReview，未写回 GitCode\n原因: render_failed\n"
    let safeDiagnostic = redactServicePayload(diagnostic).text
    if (!safeDiagnostic.isEmpty()) {
        text += "诊断: ${safeDiagnostic}\n"
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

private func servicePluginDispatchResult(
    frame: ServiceFrame,
    ok: Bool,
    status: String,
    diagnostic!: String = "",
    eventId!: String = "",
    targetCount!: Int64 = 0,
    deliverySuccess!: Int64 = 0,
    deliveryFailed!: Int64 = 0,
    failureDetails!: Array<String> = [],
    telegram!: Int64 = 0,
    feishu!: Int64 = 0,
    noSubscriberCount!: Int64 = 0
): ServicePluginEventDispatchResult {
    let safeDiagnostic = redactServicePayload(diagnostic).text
    let safeEventId = eventId.trimAscii()
    ServicePluginEventDispatchResult(
        ok,
        status,
        diagnostic: safeDiagnostic,
        eventId: safeEventId,
        eventIdHash: servicePluginDiagnosticHash(if (safeEventId.isEmpty()) { frame.payload } else { safeEventId }),
        capabilityId: frame.capabilityId,
        targetCount: targetCount,
        deliverySuccess: deliverySuccess,
        deliveryFailed: deliveryFailed,
        diagnosticHash: servicePluginDiagnosticHash(safeDiagnostic),
        failureDetails: failureDetails,
        telegram: telegram,
        feishu: feishu,
        noSubscriberCount: noSubscriberCount
    )
}

private func servicePluginDiagnosticHash(text: String): String {
    var out = hashRawPayload(text)
    while (out.size < 64) {
        out += hashRawPayload("${out}:${text.size}")
    }
    out[0..64]
}

private func servicePluginRecordWebhookDispatchResult(result: ServicePluginEventDispatchResult): Unit {
    servicePluginRecordWebhookDispatchStat(ServicePluginWebhookDispatchStat(
        result.eventId,
        result.eventIdHash,
        result.status,
        result.targetCount,
        result.deliverySuccess,
        result.deliveryFailed,
        diagnosticHash: result.diagnosticHash,
        noSubscriberCount: result.noSubscriberCount,
        telegram: result.telegram,
        feishu: result.feishu
    ))
}

private func servicePluginRecordWebhookDispatchStat(stat: ServicePluginWebhookDispatchStat): Unit {
    servicePluginWebhookDispatchStats.add(stat)
    while (servicePluginWebhookDispatchStats.size > 50) {
        servicePluginWebhookDispatchStats.remove(at: 0)
    }
}

private func servicePluginGitCodeNoSubscriberHint(): String {
    "当前没有 GitCode Webhook 通知目标。\n" +
        "请在要接收通知的 TG/Feishu 会话中发送 /gitcode subscribe。\n" +
        "静态 servicePlugins.imBindings 只用于命令路由授权，不包含真实 peerId，不能自动变成通知目标。"
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
        content: servicePluginAcceptedEventAnyString(root, "content"),
        contractVersion: servicePluginAcceptedEventAnyString(root, "contractVersion"),
        reviewRequestRaw: servicePluginAcceptedEventObjectString(root, "reviewRequest")
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

private func servicePluginAcceptedEventObjectString(root: JsonObject, key: String): String {
    match (root.get(key)) {
        case Some(v) => try { v.asObject().toJsonString().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func servicePluginValidateAcceptedReviewContract(event: ServicePluginAcceptedGitCodeEvent, diagnostics: ArrayList<String>): Unit {
    if (event.reviewRequestRaw.isEmpty()) {
        return
    }
    if (event.contractVersion.isEmpty()) {
        diagnostics.add("contract_version_missing")
    } else if (event.contractVersion != SERVICE_PLUGIN_GITCODE_REVIEW_CONTRACT_VERSION) {
        diagnostics.add("contract_version_unsupported")
    }
    let raw = event.reviewRequestRaw.toAsciiLower()
    if (raw.contains("/users/") || raw.contains("/var/folders/") || raw.contains("file://") || raw.contains("c:\\")) {
        diagnostics.add("payload_contains_local_path")
    }
    if (raw.contains("authorization:") || raw.contains("bearer ") || raw.contains("cookie:") || raw.contains("token=") || raw.contains("\"token\"")) {
        diagnostics.add("payload_contains_secret")
    }
}

private func servicePluginApplyGeneratedReplyWriteback(event: ServicePluginAcceptedGitCodeEvent, result: ServicePluginGeneratedReplyResult): ServicePluginWritebackApplyState {
    let safeResult = normalizeServicePluginGeneratedReplyResult(result)
    if (!safeResult.ok || safeResult.needsHumanReview || safeResult.draft.trimAscii().isEmpty()) {
        return ServicePluginWritebackApplyState()
    }
    let payload = servicePluginGeneratedReplyWritebackPayload(event, safeResult)
    let applied = invokeGitCodeWritebackApplyResult("gitcode-monitor", payload, 5000)
    servicePluginParseWritebackApplyResult(applied)
}

private func servicePluginGeneratedReplyWritebackPayload(event: ServicePluginAcceptedGitCodeEvent, result: ServicePluginGeneratedReplyResult): String {
    let root = JsonObject()
    root.put("contractVersion", JsonString(SERVICE_PLUGIN_GITCODE_REVIEW_CONTRACT_VERSION))
    root.put("eventId", JsonString(event.eventId))
    root.put("repo", JsonString(event.repo))
    root.put("kind", JsonString(event.kind))
    root.put("number", JsonString(event.number))
    root.put("commentId", JsonString(event.commentId))
    root.put("url", JsonString(event.url))
    root.put("draft", JsonString(result.draft))
    root.put("summary", JsonString(""))
    root.put("safety", JsonString(if (result.needsHumanReview) { "needs_human_review" } else { "approved" }))
    root.put("needsHumanReview", JsonBool(result.needsHumanReview))
    root.toJsonString()
}

private func servicePluginParseWritebackApplyResult(result: CapabilityInvokeResult): ServicePluginWritebackApplyState {
    if (!result.ok) {
        if (result.status == "invoke_timeout" || result.status == "timeout") {
            return ServicePluginWritebackApplyState(configured: true, ok: false, status: "writeback_timeout", timedOut: true, diagnostic: result.diagnostic)
        }
        return ServicePluginWritebackApplyState(configured: true, ok: false, status: result.status, diagnostic: result.diagnostic)
    }
    let root = try {
        JsonValue.fromStr(result.payload).asObject()
    } catch (_: Exception) {
        return ServicePluginWritebackApplyState(configured: true, ok: false, status: "writeback_response_decode_failed", diagnostic: "writeback_response_decode_failed")
    }
    let status = servicePluginAcceptedEventAnyString(root, "status")
    let posted = servicePluginJsonBool(root, "posted")
    let reason = servicePluginAcceptedEventAnyString(root, "reason")
    let skipped = servicePluginJsonBool(root, "skipped") ||
        status == "skipped" ||
        status == "dry_run" ||
        status == "auto_reply_disabled" ||
        servicePluginWritebackKnownSkipReason(status) ||
        servicePluginWritebackKnownSkipReason(reason)
    let replyUrl = servicePluginAcceptedEventAnyString(root, "replyUrl")
    let ok = posted || skipped || status == "posted" || status == "ok"
    ServicePluginWritebackApplyState(
        configured: true,
        ok: ok,
        status: if (status.isEmpty()) { if (posted) { "posted" } else { "ok" } } else { status },
        posted: posted || status == "posted",
        skipped: skipped,
        replyUrl: replyUrl,
        diagnostic: reason,
        maintainerMentionAppended: servicePluginJsonBool(root, "maintainerMentionAppended"),
        teamLeaderCount: servicePluginJsonInt(root, "teamLeaderCount"),
        codeownerCount: servicePluginJsonInt(root, "codeownerCount"),
        contextSource: servicePluginAcceptedEventAnyString(root, "contextSource"),
        emailNotificationStatus: servicePluginAcceptedEventAnyString(root, "emailNotificationStatus"),
        emailSentCount: servicePluginJsonInt(root, "emailSentCount"),
        emailFailedCount: servicePluginJsonInt(root, "emailFailedCount"),
        emailRetryable: servicePluginJsonBool(root, "emailRetryable")
    )
}

private func servicePluginJsonBool(root: JsonObject, key: String): Bool {
    match (root.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

private func servicePluginJsonInt(root: JsonObject, key: String): Int64 {
    match (root.get(key)) {
        case Some(v) => try { v.asInt().getValue() } catch (_: Exception) { 0 }
        case None => 0
    }
}

private func servicePluginWritebackDegraded(writeback: ServicePluginWritebackApplyState): Bool {
    writeback.configured && !writeback.ok
}

private func servicePluginWritebackNotificationLine(writeback: ServicePluginWritebackApplyState): String {
    if (!writeback.configured) {
        return "状态: dryRun=true，未写回 GitCode"
    }
    if (writeback.posted) {
        var text = "状态: GitCode 回复已写回"
        let mentionLine = servicePluginWritebackMaintainerMentionLine(writeback)
        if (!mentionLine.isEmpty()) {
            text += "\n${mentionLine}"
        }
        let emailLine = servicePluginWritebackEmailNotificationLine(writeback)
        if (!emailLine.isEmpty()) {
            text += "\n${emailLine}"
        }
        if (!writeback.replyUrl.isEmpty()) {
            text += "\n写回链接: ${writeback.replyUrl}"
        }
        return text
    }
    if (writeback.timedOut) {
        return "状态: 写回状态未知/超时，草稿已通知"
    }
    if (writeback.status == "capability_missing") {
        return "状态: 写回路由缺失（capability_missing），草稿已通知"
    }
    if (writeback.status == "service_missing") {
        return "状态: 写回服务缺失（service_missing），草稿已通知"
    }
    let humanSkip = servicePluginWritebackHumanSkipLine(writeback)
    if (!humanSkip.isEmpty()) {
        return humanSkip
    }
    if (!writeback.ok) {
        return "状态: 写回结果异常（${writeback.status}），草稿已通知"
    }
    if (writeback.skipped) {
        let reason = if (writeback.diagnostic.isEmpty()) { writeback.status } else { writeback.diagnostic }
        return "状态: 写回未执行（${reason}），草稿已通知"
    }
    "状态: 写回未执行（${writeback.status}），草稿已通知"
}

private func servicePluginWritebackMaintainerMentionLine(writeback: ServicePluginWritebackApplyState): String {
    if (!writeback.maintainerMentionAppended) {
        return ""
    }
    "维护者提及: 已追加 teamLeader=${writeback.teamLeaderCount} codeowner=${writeback.codeownerCount}"
}

private func servicePluginWritebackEmailNotificationLine(writeback: ServicePluginWritebackApplyState): String {
    let status = writeback.emailNotificationStatus.trimAscii()
    if (status.isEmpty()) {
        return ""
    }
    if (status == "sent") {
        if (writeback.emailSentCount > 0) {
            return "维护者邮件: 已发送 ${writeback.emailSentCount}"
        }
        return "维护者邮件: 已发送"
    }
    if (status == "email_disabled" || status == "disabled" || status == "not_configured") {
        return "维护者邮件: 未启用"
    }
    if (status == "email_unavailable" || status == "unavailable") {
        return "维护者邮件: 无可用邮箱"
    }
    if (status == "send_failed" || status == "failed") {
        var line = "维护者邮件: 发送失败"
        if (writeback.emailFailedCount > 0) {
            line += " ${writeback.emailFailedCount}"
        }
        if (writeback.emailRetryable) {
            line += "，可重试"
        }
        return line
    }
    ""
}

private func servicePluginWritebackKnownSkipReason(reason: String): Bool {
    let value = reason.trimAscii()
    value == "repo_denied_by_writeback_scope" || value == "repo_not_allowlisted"
}

private func servicePluginWritebackReason(writeback: ServicePluginWritebackApplyState): String {
    if (!writeback.diagnostic.isEmpty()) { return writeback.diagnostic }
    writeback.status
}

private func servicePluginWritebackHumanSkipLine(writeback: ServicePluginWritebackApplyState): String {
    let reason = servicePluginWritebackReason(writeback)
    if (reason == "repo_denied_by_writeback_scope") {
        return "状态: 该仓库被 GCM writebackScope.deniedRepos 排除，已生成草稿但未写回 GitCode"
    }
    if (reason == "repo_not_allowlisted") {
        return "状态: 当前仓库未命中 GCM writebackScope 允许范围，已生成草稿但未写回 GitCode"
    }
    if (reason == "dry_run") {
        return "状态: dryRun=true，未写回 GitCode（写回未执行），草稿已通知"
    }
    ""
}

private func servicePluginGeneratedReplyHumanReason(result: ServicePluginGeneratedReplyResult): String {
    let status = result.status.trimAscii()
    let diagnostic = result.diagnostic.trimAscii()
    if (status == "ckb_unavailable" || diagnostic.contains("ckb_unavailable")) {
        return "知识库不可用，已保守生成/需要人工确认"
    }
    if (status == "pr_review_timeout" || status == "review_adapter_timeout" || diagnostic.contains("review_adapter_timeout") || diagnostic.contains("adapter timeout")) {
        return "PR review 阶段超时，已保守生成草稿，需要人工确认"
    }
    if (status == "draft_invalid_tool_json") {
        return "模型返回了工具调用 JSON，已拦截，需要人工确认"
    }
    if (status == "draft_raw_json") {
        return "模型返回了原始 JSON，已拦截，需要人工确认"
    }
    if (status == "draft_contains_secret") {
        return "模型草稿包含敏感信息，已拦截，需要人工确认"
    }
    if (status == "draft_contains_local_path") {
        return "模型草稿包含本机路径，已拦截，需要人工确认"
    }
    if (status == "draft_forbidden_marker") {
        return "模型草稿包含禁止标记，已拦截，需要人工确认"
    }
    if (diagnostic.isEmpty()) { status } else { diagnostic }
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
