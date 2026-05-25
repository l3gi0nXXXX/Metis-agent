package metis.core

import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString}

public enum MediaProviderAttemptStatus {
    | Skipped
    | Started
    | Succeeded
    | Failed
}

public class MediaProviderAttempt {
    public let providerId: String
    public let kind: String
    public let capability: String
    public let model: String
    public let endpointClass: String
    public let requestUrlRedacted: String
    public let resolvedEndpoint: String
    public let status: MediaProviderAttemptStatus
    public let statusCode: Int64
    public let errorCategory: String
    public let errorCode: String
    public let message: String
    public let redactedMessage: String
    public let durationMs: Int64

    public init(
        providerId: String,
        kind: String,
        status: MediaProviderAttemptStatus,
        capability!: String = "",
        model!: String = "",
        endpointClass!: String = "",
        requestUrlRedacted!: String = "",
        resolvedEndpoint!: String = "",
        statusCode!: Int64 = 0,
        errorCategory!: String = "",
        errorCode!: String = "",
        message!: String = "",
        redactedMessage!: String = "",
        durationMs!: Int64 = 0
    ) {
        this.providerId = providerId
        this.kind = kind
        this.capability = capability
        this.model = model
        this.endpointClass = endpointClass
        this.requestUrlRedacted = redactProviderEndpoint(requestUrlRedacted)
        this.resolvedEndpoint = redactProviderEndpoint(resolvedEndpoint)
        this.status = status
        this.statusCode = statusCode
        this.errorCategory = errorCategory
        this.errorCode = errorCode
        this.message = redactProviderSecret(message)
        this.redactedMessage = if (redactedMessage.trimAscii().isEmpty()) { redactProviderSecret(message) } else { redactProviderSecret(redactedMessage) }
        this.durationMs = durationMs
    }
}

private func mediaProviderAttemptStatusId(status: MediaProviderAttemptStatus): String {
    match (status) {
        case Skipped => "skipped"
        case Started => "started"
        case Succeeded => "succeeded"
        case Failed => "failed"
    }
}

private func mediaProviderAttemptStatusIs(status: MediaProviderAttemptStatus, expected: String): Bool {
    mediaProviderAttemptStatusId(status) == expected
}

public func mediaProviderAttemptJsonObject(attempt: MediaProviderAttempt): JsonObject {
    let obj = JsonObject()
    obj.put("providerId", JsonString(attempt.providerId))
    obj.put("kind", JsonString(attempt.kind))
    obj.put("capability", JsonString(attempt.capability))
    obj.put("model", JsonString(attempt.model))
    obj.put("endpointClass", JsonString(attempt.endpointClass))
    obj.put("requestUrl", JsonString(attempt.requestUrlRedacted))
    obj.put("resolvedEndpoint", JsonString(attempt.resolvedEndpoint))
    obj.put("status", JsonString(mediaProviderAttemptStatusId(attempt.status)))
    obj.put("statusCode", JsonInt(attempt.statusCode))
    obj.put("errorCategory", JsonString(attempt.errorCategory))
    obj.put("errorCode", JsonString(attempt.errorCode))
    obj.put("message", JsonString(attempt.redactedMessage))
    obj.put("durationMs", JsonInt(attempt.durationMs))
    obj
}

public func mediaProviderAttemptToJson(attempt: MediaProviderAttempt): String {
    mediaProviderAttemptJsonObject(attempt).toJsonString()
}

public func summarizeMediaProviderAttempts(attempts: Array<MediaProviderAttempt>): String {
    let arr = JsonArray([])
    var lastErrorCode = ""
    var lastErrorMessage = ""
    var ok = false
    for (attempt in attempts) {
        arr.add(mediaProviderAttemptJsonObject(attempt))
        if (mediaProviderAttemptStatusIs(attempt.status, "succeeded")) {
            ok = true
        }
        if (mediaProviderAttemptStatusIs(attempt.status, "failed") || mediaProviderAttemptStatusIs(attempt.status, "skipped")) {
            if (!attempt.errorCode.isEmpty()) {
                lastErrorCode = attempt.errorCode
            }
            if (!attempt.redactedMessage.isEmpty()) {
                lastErrorMessage = attempt.redactedMessage
            }
        }
    }
    let out = JsonObject()
    out.put("ok", JsonBool(ok))
    out.put("attempts", arr)
    out.put("lastErrorCode", JsonString(lastErrorCode))
    out.put("lastErrorMessage", JsonString(lastErrorMessage))
    out.toJsonString()
}

public func mediaProviderAttemptMessages(attempts: Array<MediaProviderAttempt>): Array<String> {
    let out = ArrayList<String>()
    for (attempt in attempts) {
        let message = attempt.redactedMessage.trimAscii()
        if (!message.isEmpty()) {
            out.add(message)
        }
    }
    out.toArray()
}
