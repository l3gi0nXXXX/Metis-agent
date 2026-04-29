package metis.gateway.channels.telegram

import magic.jsonable.*
import magic.utils.http.*

import std.collection.HashMap
import stdx.encoding.json.*

public class TelegramTransportRequest {
    public let method: String
    public let url: String
    public let context: String
    public let accept: String
    public let body: String
    public let proxy: String
    public let timeoutSeconds: Int64

    public init(
        method: String,
        url: String,
        context!: String = "",
        accept!: String = "application/json",
        body!: String = "",
        proxy!: String = "",
        timeoutSeconds!: Int64 = 30
    ) {
        this.method = method
        this.url = url
        this.context = context
        this.accept = accept
        this.body = body
        this.proxy = proxy
        this.timeoutSeconds = timeoutSeconds
    }
}

public class TelegramTransportResponse {
    public let ok: Bool
    public let body: String
    public let error: String
    public let outcome: String
    public let statusCode: Int64

    public init(
        ok: Bool,
        body!: String = "",
        error!: String = "",
        outcome!: String = "",
        statusCode!: Int64 = 0
    ) {
        this.ok = ok
        this.body = body
        this.error = error
        this.outcome = outcome
        this.statusCode = statusCode
    }
}

private var telegramTransportRunnerOverride: Option<(TelegramTransportRequest) -> TelegramTransportResponse> = None<(TelegramTransportRequest) -> TelegramTransportResponse>

public func setTelegramTransportRunnerForTest(runner: Option<(TelegramTransportRequest) -> TelegramTransportResponse>): Unit {
    telegramTransportRunnerOverride = runner
}

public class TelegramTransport {
    private let proxy: String
    private let timeoutSeconds: Int64

    public init(proxy!: String = "", timeoutSeconds!: Int64 = 30) {
        this.proxy = proxy.trimAscii()
        this.timeoutSeconds = if (timeoutSeconds > 0) { timeoutSeconds } else { 30 }
    }

    public func get(url: String, accept!: String = "application/json", context!: String = "get"): TelegramTransportResponse {
        let request = TelegramTransportRequest(
            "GET",
            url,
            context: context,
            accept: accept,
            proxy: this.proxy,
            timeoutSeconds: this.timeoutSeconds
        )
        match (telegramTransportRunnerOverride) {
            case Some(runner) => return runner(request)
            case None => ()
        }
        let headers = HashMap<String, String>()
        headers["Accept"] = accept
        return try {
            match (HttpUtils.get(url, headers, None)) {
                case Some(raw) => TelegramTransportResponse(true, body: raw, outcome: "ok")
                case None => TelegramTransportResponse(false, error: "empty http response", outcome: "empty-response")
            }
        } catch (e: Exception) {
            TelegramTransportResponse(false, error: e.message, outcome: this.classifyException(e.message))
        }
    }

    public func postJson(url: String, body: JsonObject, context!: String = "postJson"): TelegramTransportResponse {
        let request = TelegramTransportRequest(
            "POST",
            url,
            context: context,
            accept: "application/json",
            body: body.toJsonString(),
            proxy: this.proxy,
            timeoutSeconds: this.timeoutSeconds
        )
        match (telegramTransportRunnerOverride) {
            case Some(runner) => return runner(request)
            case None => ()
        }
        let headers = HashMap<String, String>()
        headers["Content-Type"] = "application/json; charset=utf-8"
        return try {
            match (HttpUtils.post(url, headers, body)) {
                case Some(raw) => TelegramTransportResponse(true, body: raw, outcome: "ok")
                case None => TelegramTransportResponse(false, error: "empty http response", outcome: "empty-response")
            }
        } catch (e: Exception) {
            TelegramTransportResponse(false, error: e.message, outcome: this.classifyException(e.message))
        }
    }

    public func redactUrl(url: String): String {
        let marker = "/bot"
        match (url.indexOf(marker)) {
            case Some(idx) =>
                let tokenStart = idx + marker.size
                let rest = url[tokenStart..]
                match (rest.indexOf("/")) {
                    case Some(endIdx) =>
                        url[..tokenStart] + "<redacted>" + rest[endIdx..]
                    case None => url[..tokenStart] + "<redacted>"
                }
            case None => url
        }
    }

    private func classifyException(message: String): String {
        let lower = message.toAsciiLower()
        if (lower.contains("timeout") || lower.contains("timed out")) {
            return "timeout"
        }
        if (lower.contains("unauthorized") || lower.contains("401")) {
            return "unauthorized"
        }
        if (lower.contains("too many requests") || lower.contains("429")) {
            return "rate-limit"
        }
        if (lower.contains("conflict") || lower.contains("409")) {
            return "conflict"
        }
        "exception"
    }
}
