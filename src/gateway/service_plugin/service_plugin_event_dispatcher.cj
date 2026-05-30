package metis.gateway.service_plugin

import std.collection.ArrayList
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

private var servicePluginEventDeliveryForTest: Option<(ServicePluginDeliveryTarget, String) -> ServicePluginEventDeliveryResult> =
    None<(ServicePluginDeliveryTarget, String) -> ServicePluginEventDeliveryResult>

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
    let text = renderServicePluginJobEventMessage(event)
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
    let root = try {
        JsonValue.fromStr(frame.payload).asObject()
    } catch (_: Exception) {
        return ServicePluginEventDispatchResult(false, "event_payload_invalid", diagnostic: "accepted event payload must be a JSON object")
    }
    let diagnostics = ArrayList<String>()
    let eventId = jobAcceptedEventString(root, "eventId", diagnostics)
    let jobId = jobAcceptedEventString(root, "jobId", diagnostics)
    if (eventId.isEmpty()) {
        diagnostics.add("eventId is required")
    }
    if (diagnostics.size > 0) {
        return ServicePluginEventDispatchResult(false, "event_payload_invalid", diagnostic: String.join(diagnostics.toArray(), delimiter: "; "))
    }
    if (!jobId.isEmpty()) {
        match (store.findByJobId(jobId)) {
            case Some(_) => store.markRunning(jobId, stage: "event_accepted")
            case None => return ServicePluginEventDispatchResult(false, "orphan_event", diagnostic: "pending job not found for accepted event")
        }
    }
    ServicePluginEventDispatchResult(
        true,
        "accepted_event_recorded",
        diagnostic: "TODO generated_reply dispatch not implemented; accepted event recorded without terminal delivery"
    )
}

private func jobAcceptedEventString(root: JsonObject, key: String, diagnostics: ArrayList<String>): String {
    match (root.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) {
            diagnostics.add("${key} must be string")
            ""
        }
        case None => ""
    }
}
