package metis.core

import magic.prelude.*

import std.collection.ArrayList
import std.fs.Path
import std.sync.Mutex

import stdx.encoding.json.{JsonObject, JsonString}

private let gatewaySubagentNoticeDeliveryHookLock = Mutex()
private var gatewaySubagentNoticeDeliveryHook: Option<(String, String, String, String, String, Bool) -> String> = None<(String, String, String, String, String, Bool) -> String>
private let gatewaySubagentNoticeEventHookLock = Mutex()
private var gatewaySubagentNoticeEventHook: Option<(String, String, String, String) -> Int64> = None<(String, String, String, String) -> Int64>

public func gatewayRegisterSubagentNoticeDeliveryHook(hook: (String, String, String, String, String, Bool) -> String): Unit {
    synchronized(gatewaySubagentNoticeDeliveryHookLock) {
        gatewaySubagentNoticeDeliveryHook = Some(hook)
    }
}

public func gatewayClearSubagentNoticeDeliveryHook(): Unit {
    synchronized(gatewaySubagentNoticeDeliveryHookLock) {
        gatewaySubagentNoticeDeliveryHook = None<(String, String, String, String, String, Bool) -> String>
    }
}

public func gatewayRegisterSubagentNoticeEventHook(hook: (String, String, String, String) -> Int64): Unit {
    synchronized(gatewaySubagentNoticeEventHookLock) {
        gatewaySubagentNoticeEventHook = Some(hook)
    }
}

public func gatewayClearSubagentNoticeEventHook(): Unit {
    synchronized(gatewaySubagentNoticeEventHookLock) {
        gatewaySubagentNoticeEventHook = None<(String, String, String, String) -> Int64>
    }
}

public func gatewaySubagentPublishNoticeEvent(
    sessionKey: String,
    runId: String,
    status: String,
    notice: String
): Int64 {
    synchronized(gatewaySubagentNoticeEventHookLock) {
        match (gatewaySubagentNoticeEventHook) {
            case Some(publish) => return publish(
                sessionKey.trimAscii(),
                runId.trimAscii(),
                status.trimAscii(),
                notice
            )
            case None => return 0
        }
    }
}

public func gatewaySubagentDeliverNoticeToChannel(
    channelName: String,
    accountId: String,
    peerId: String,
    notice: String,
    replyToMessageId!: String = "",
    replyInThread!: Bool = false
): String {
    synchronized(gatewaySubagentNoticeDeliveryHookLock) {
        match (gatewaySubagentNoticeDeliveryHook) {
            case Some(send) => return send(
                channelName.trimAscii(),
                accountId.trimAscii(),
                peerId.trimAscii(),
                notice,
                replyToMessageId.trimAscii(),
                replyInThread
            )
            case None => ()
        }
    }
    throw Exception("subagent notice delivery hook is unavailable")
}

public func gatewaySubagentNoticeTargetSession(record: JsonObject): String {
    let requester = gatewaySubagentRunRecordString(record, "requesterSessionKey")
    if (!requester.isEmpty()) {
        return requester
    }
    gatewaySubagentRunRecordString(record, "parentSessionKey")
}

public func gatewaySubagentNoticeShouldDeliver(record: JsonObject): Bool {
    let status = gatewaySubagentRunRecordString(record, "status")
    if (!gatewaySubagentRunStatusIsTerminal(status)) {
        return false
    }
    gatewaySubagentRunRecordString(record, "noticeStatus") != "delivered"
}

private func gatewaySubagentNormalizeNoticeStatus(noticeStatus: String): String {
    match (noticeStatus.trimAscii().toAsciiLower()) {
        case "delivered" => "delivered"
        case "failed" => "failed"
        case "pending" => "pending"
        case _ => "none"
    }
}

private func subagentNoticePreview(text: String): String {
    let trimmed = text.trimAscii()
    let runes = trimmed.toRuneArray()
    if (runes.size <= 1200) {
        return trimmed
    }
    "${String(runes[0..1200])}\n... (truncated)"
}

private func subagentNoticeLogsHint(record: JsonObject): String {
    let runId = gatewaySubagentRunRecordString(record, "runId")
    let transcriptPath = gatewaySubagentRunRecordString(record, "transcriptPath")
    if (!runId.isEmpty()) {
        return "Logs: /subagents logs ${runId}"
    }
    if (!transcriptPath.isEmpty()) {
        return "Logs: ${transcriptPath}"
    }
    "Logs: unavailable"
}

public func gatewaySubagentRenderNotice(record: JsonObject): String {
    let status = gatewaySubagentRunRecordString(record, "status")
    let runId = gatewaySubagentRunRecordString(record, "runId")
    let agentId = gatewaySubagentRunRecordString(record, "agentId")
    let summary = gatewaySubagentRunRecordString(record, "resultSummary")
    let error = gatewaySubagentRunRecordString(record, "error")
    let bodyLabel = if (status == "succeeded") { "Summary" } else { "Detail" }
    let body = if (!summary.trimAscii().isEmpty()) {
        summary
    } else if (!error.trimAscii().isEmpty()) {
        error
    } else {
        status
    }
    let lines = ArrayList<String>()
    lines.add("[Subagent ${status}] ${agentId} ${runId}")
    lines.add("Status: ${status}")
    lines.add("${bodyLabel}:")
    lines.add(subagentNoticePreview(body))
    lines.add(subagentNoticeLogsHint(record))
    String.join(lines.toArray(), delimiter: "\n")
}

public func gatewaySubagentUpdateNoticeStatus(
    sessionsRoot: Path,
    runIdOrSessionKey: String,
    noticeStatus: String,
    error!: String = ""
): Bool {
    let record = match (gatewaySubagentResolveRunRecord(sessionsRoot, runIdOrSessionKey)) {
        case Some(v) => v
        case None => return false
    }
    let normalized = gatewaySubagentNormalizeNoticeStatus(noticeStatus)
    let attempts = gatewaySubagentRunRecordInt(record, "noticeAttempts")
    record.put("noticeStatus", JsonString(normalized))
    record.put("noticeAttempts", (attempts + 1).toJsonValue())
    record.put("lastNoticeError", JsonString(error.trimAscii()))
    gatewaySubagentWriteRunRecord(sessionsRoot, record)
}

public func gatewaySubagentUpdateChannelNoticeStatus(
    sessionsRoot: Path,
    runIdOrSessionKey: String,
    noticeStatus: String,
    error!: String = "",
    messageId!: String = ""
): Bool {
    let record = match (gatewaySubagentResolveRunRecord(sessionsRoot, runIdOrSessionKey)) {
        case Some(v) => v
        case None => return false
    }
    let normalized = gatewaySubagentNormalizeNoticeStatus(noticeStatus)
    let attempts = gatewaySubagentRunRecordInt(record, "channelNoticeAttempts")
    record.put("channelNoticeStatus", JsonString(normalized))
    record.put("channelNoticeAttempts", (attempts + 1).toJsonValue())
    record.put("lastChannelNoticeError", JsonString(error.trimAscii()))
    if (!messageId.trimAscii().isEmpty()) {
        record.put("channelNoticeMessageId", JsonString(messageId.trimAscii()))
    }
    gatewaySubagentWriteRunRecord(sessionsRoot, record)
}

public func gatewaySubagentUpdateRealtimeNoticeStatus(
    sessionsRoot: Path,
    runIdOrSessionKey: String,
    noticeStatus: String,
    error!: String = ""
): Bool {
    let record = match (gatewaySubagentResolveRunRecord(sessionsRoot, runIdOrSessionKey)) {
        case Some(v) => v
        case None => return false
    }
    let normalized = gatewaySubagentNormalizeNoticeStatus(noticeStatus)
    let attempts = gatewaySubagentRunRecordInt(record, "realtimeNoticeAttempts")
    record.put("realtimeNoticeStatus", JsonString(normalized))
    record.put("realtimeNoticeAttempts", (attempts + 1).toJsonValue())
    record.put("lastRealtimeNoticeError", JsonString(error.trimAscii()))
    gatewaySubagentWriteRunRecord(sessionsRoot, record)
}
