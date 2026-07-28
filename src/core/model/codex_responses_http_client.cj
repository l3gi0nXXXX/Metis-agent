package metis.core.model

import metis.core.config.{OpenAICodexOAuthRoute, OpenAICodexOAuthTransportConfig, buildOpenAICodexOAuthHttpClientBuilder, resolveOpenAICodexOAuthRoute}

import std.collection.{ArrayList, HashMap}
import stdx.encoding.json.*
import stdx.net.http.*

public type CodexResponsesHttpRunner = (CodexResponsesHttpRequest) -> CodexResponsesHttpResult

private var codexResponsesHttpRunnerForTest: Option<CodexResponsesHttpRunner> = None<CodexResponsesHttpRunner>

public func setCodexResponsesHttpRunnerForTest(runner: Option<CodexResponsesHttpRunner>): Unit {
    codexResponsesHttpRunnerForTest = runner
}

private func codexHttpString(obj: JsonObject, key: String): String {
    try {
        if (let Some(value) <- obj.get(key)) {
            return value.asString().getValue()
        }
    } catch (_: Exception) { () }
    return ""
}

private func codexHttpBool(obj: JsonObject, key: String): Bool {
    try {
        if (let Some(value) <- obj.get(key)) {
            return value.asBool().getValue()
        }
    } catch (_: Exception) { () }
    return false
}

private func codexHttpObject(obj: JsonObject, key: String): JsonObject {
    try {
        if (let Some(value) <- obj.get(key)) {
            return value.asObject()
        }
    } catch (_: Exception) { () }
    return JsonObject()
}

private func codexTrimResponsesBaseUrl(baseUrl: String): String {
    return baseUrl.trimAscii().trimEnd("/")
}

private func codexResponsesReadHttpBody(response: HttpResponse): String {
    let out = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let n = response.body.read(buffer)
        if (n <= 0) {
            break
        }
        out.add(all: buffer[..n])
    }
    try { String.fromUtf8(out.toArray()) } catch (_: Exception) { "" }
}

private func codexResponsesFlushSseData(events: ArrayList<JsonObject>, data: String): String {
    let raw = data.trimAscii()
    if (raw.isEmpty() || raw == "[DONE]") {
        return ""
    }
    try {
        events.add(JsonValue.fromStr(raw).asObject())
    } catch (_: Exception) { () }
    return ""
}

private func codexResponsesParseSseEvents(raw: String): Array<JsonObject> {
    let events = ArrayList<JsonObject>()
    var data = ""
    for (line0 in raw.replace("\r\n", "\n").replace("\r", "\n").split("\n")) {
        let line = line0.trimAscii()
        if (line.isEmpty()) {
            data = codexResponsesFlushSseData(events, data)
            continue
        }
        if (line.startsWith("data:")) {
            if (!data.isEmpty()) {
                data += "\n"
            }
            data += line["data:".size..].trimAscii()
        }
    }
    data = codexResponsesFlushSseData(events, data)
    return events.toArray()
}

private func codexResponsesRouteDiagnostic(route: OpenAICodexOAuthRoute): String {
    let parts = ArrayList<String>()
    if (!route.mode.isEmpty()) {
        parts.add("route=${route.mode}")
    }
    if (!route.proxySource.isEmpty()) {
        parts.add("proxySource=${route.proxySource}")
    }
    if (!route.redactedProxy.isEmpty()) {
        parts.add("proxy=${route.redactedProxy}")
    }
    if (!route.targetHost.isEmpty()) {
        parts.add("targetHost=${route.targetHost}")
    }
    String.join(parts.toArray(), delimiter: " ")
}

private func codexPreflightClientConfig(baseUrl: String, accessToken: String, payload: JsonObject): Unit {
    if (accessToken.trimAscii().isEmpty()) {
        throw CodexResponsesException("missing_token", "Codex Responses access token is missing")
    }
    if (baseUrl.trimAscii().isEmpty()) {
        throw CodexResponsesException("missing_base_url", "Codex Responses baseUrl is missing")
    }
    if (codexHttpString(payload, "model").trimAscii().isEmpty()) {
        throw CodexResponsesException("missing_model", "Codex Responses model is missing")
    }
}

public class CodexResponsesHttpClient {
    private let transportConfig: OpenAICodexOAuthTransportConfig

    public init(transportConfig!: Option<OpenAICodexOAuthTransportConfig> = None<OpenAICodexOAuthTransportConfig>) {
        this.transportConfig = match (transportConfig) {
            case Some(cfg) => cfg
            case None => OpenAICodexOAuthTransportConfig(timeoutMs: 120000)
        }
    }

    public func preparePostRequest(
        baseUrl: String,
        accessToken: String,
        payload: JsonObject,
        extraHeaders!: HashMap<String, String> = HashMap<String, String>(),
        timeoutMs!: Int64 = 0,
        stream!: Bool = false
    ): CodexResponsesHttpRequest {
        codexPreflightClientConfig(baseUrl, accessToken, payload)
        codexPreflightResponsesPayload(payload, allowStream: stream)
        let headers = HashMap<String, String>([
            ("Content-Type", "application/json"),
            ("Authorization", "Bearer ${accessToken}")
        ])
        if (stream) {
            headers.add("Accept", "text/event-stream")
        }
        for ((key, value) in extraHeaders) {
            headers.add(key, value)
        }
        let cfHeaders = codexCloudflareHeaders(accessToken)
        for ((key, value) in cfHeaders.getFields()) {
            try {
                headers.add(key, value.asString().getValue())
            } catch (_: Exception) { () }
        }
        var body = payload
        if (stream) {
            body = JsonValue.fromStr(payload.toJsonString()).asObject()
            body.put("stream", JsonBool(true))
        }
        let configuredTimeoutMs = if (timeoutMs > 0) {
            timeoutMs
        } else {
            this.transportConfig.timeoutMs
        }
        let executionRemainingMs = currentModelExecutionRemainingMs()
        let effectiveTimeoutMs = if (executionRemainingMs > 0) {
            min(configuredTimeoutMs, executionRemainingMs)
        } else {
            configuredTimeoutMs
        }
        return CodexResponsesHttpRequest(
            "POST",
            "${codexTrimResponsesBaseUrl(baseUrl)}/responses",
            headers,
            body,
            stream: stream,
            timeoutMs: effectiveTimeoutMs
        )
    }

    private func run(request: CodexResponsesHttpRequest): CodexResponsesHttpResult {
        if (let Some(runner) <- codexResponsesHttpRunnerForTest) {
            return runner(request)
        }
        try {
            return this.runNativePost(request)
        } catch (ex: CodexResponsesException) {
            throw ex
        } catch (ex: Exception) {
            throw CodexResponsesException("http_error", "Codex Responses HTTP request failed: ${ex.message}")
        }
    }

    private func requestTransportConfig(request: CodexResponsesHttpRequest): OpenAICodexOAuthTransportConfig {
        if (request.timeoutMs <= 0 || request.timeoutMs == this.transportConfig.timeoutMs) {
            return this.transportConfig
        }
        OpenAICodexOAuthTransportConfig(
            proxy: this.transportConfig.proxy,
            envProxyEnabled: this.transportConfig.envProxyEnabled,
            noProxy: this.transportConfig.noProxy,
            insecureSkipTlsVerify: this.transportConfig.insecureSkipTlsVerify,
            timeoutMs: request.timeoutMs,
            proxySource: this.transportConfig.proxySource
        )
    }

    private func runNativePost(request: CodexResponsesHttpRequest): CodexResponsesHttpResult {
        let cfg = this.requestTransportConfig(request)
        let route = resolveOpenAICodexOAuthRoute(request.url, cfg)
        if (route.mode == "unsupportedHttpsProxy" || route.mode == "unsupportedSocksProxy" || route.mode == "invalidProxy") {
            throw CodexResponsesException(
                "http_error",
                "Codex Responses HTTP request failed: ${route.error} ${codexResponsesRouteDiagnostic(route)}"
            )
        }
        let builderRoute = buildOpenAICodexOAuthHttpClientBuilder(request.url, cfg)
        let builder = builderRoute[0]
        let activeRoute = builderRoute[1]
        let client = builder.build()
        try {
            let reqBuilder = HttpRequestBuilder()
                .url(request.url)
                .post()
                .body(request.body.toJsonString())
            for ((key, value) in request.headers) {
                reqBuilder.header(key, value)
            }
            let response = client.send(reqBuilder.build())
            let body = codexResponsesReadHttpBody(response)
            if (request.stream && response.status >= 200 && response.status < 300) {
                return CodexResponsesHttpResult(Int64(response.status), body: body, streamEvents: codexResponsesParseSseEvents(body))
            }
            return CodexResponsesHttpResult(Int64(response.status), body: body)
        } catch (ex: Exception) {
            throw CodexResponsesException(
                "http_error",
                "Codex Responses HTTP request failed: ${ex.message} ${codexResponsesRouteDiagnostic(activeRoute)}"
            )
        } finally {
            client.close()
        }
    }

    private func resultToObject(result: CodexResponsesHttpResult, contextTokens!: Int64 = 0): JsonObject {
        if (result.statusCode >= 200 && result.statusCode < 300) {
            try {
                return JsonValue.fromStr(result.body).asObject()
            } catch (_: Exception) {
                throw CodexResponsesException("malformed_json", "Codex Responses returned malformed JSON")
            }
        }
        let errorClass = codexClassifyResponsesError(result.statusCode, result.body + result.error, contextTokens: contextTokens)
        throw CodexResponsesException(errorClass, "Codex Responses HTTP ${result.statusCode}: ${errorClass}")
    }

    public func postResponses(
        baseUrl: String,
        accessToken: String,
        payload: JsonObject,
        extraHeaders!: HashMap<String, String> = HashMap<String, String>(),
        timeoutMs!: Int64 = 0
    ): JsonObject {
        let request = this.preparePostRequest(baseUrl, accessToken, payload, extraHeaders: extraHeaders, timeoutMs: timeoutMs)
        let first = this.run(request)
        if (first.statusCode >= 200 && first.statusCode < 300) {
            return this.resultToObject(first, contextTokens: codexEstimateRequestContextTokens(payload))
        }
        let classification = codexClassifyResponsesError(first.statusCode, first.body + first.error, contextTokens: codexEstimateRequestContextTokens(payload))
        if (codexShouldRetryWithoutEncryptedReasoning(classification)) {
            let retryPayload = codexStripReasoningReplayForRetry(payload)
            let retryRequest = this.preparePostRequest(baseUrl, accessToken, retryPayload, extraHeaders: extraHeaders, timeoutMs: timeoutMs)
            return this.resultToObject(this.run(retryRequest), contextTokens: codexEstimateRequestContextTokens(retryPayload))
        }
        if (first.statusCode == 400) {
            let retry = codexUnsupportedParameterRetryPayload(payload, first.body + first.error)
            if (codexHttpBool(retry, "shouldRetry")) {
                let retryPayload = codexHttpObject(retry, "payload")
                let retryRequest = this.preparePostRequest(baseUrl, accessToken, retryPayload, extraHeaders: extraHeaders, timeoutMs: timeoutMs)
                return this.resultToObject(this.run(retryRequest), contextTokens: codexEstimateRequestContextTokens(retryPayload))
            }
        }
        return this.resultToObject(first, contextTokens: codexEstimateRequestContextTokens(payload))
    }

    public func streamResponses(
        baseUrl: String,
        accessToken: String,
        payload: JsonObject,
        extraHeaders!: HashMap<String, String> = HashMap<String, String>(),
        timeoutMs!: Int64 = 0,
        model!: String = ""
    ): CodexResponsesNormalized {
        let request = this.preparePostRequest(baseUrl, accessToken, payload, extraHeaders: extraHeaders, timeoutMs: timeoutMs, stream: true)
        let first = this.run(request)
        if (!first.error.isEmpty()) {
            let retry = this.run(request)
            if (!retry.error.isEmpty()) {
                throw CodexResponsesException("stream_transport_error", "Codex Responses stream transport failed after retry")
            }
            return codexNormalizeResponsesEvents(retry.streamEvents, model: model)
        }
        if (first.statusCode >= 400) {
            let classification = codexClassifyResponsesError(first.statusCode, first.body + first.error, contextTokens: codexEstimateRequestContextTokens(payload))
            throw CodexResponsesException(classification, "Codex Responses stream HTTP ${first.statusCode}: ${classification}")
        }
        return codexNormalizeResponsesEvents(first.streamEvents, model: model)
    }
}

public func codexResponsesRunStreamWithWatchdog(
    events: Array<JsonObject>,
    model!: String = "",
    ttfbTimeoutSeconds!: Float64 = 45.0,
    idleTimeoutSeconds!: Float64 = 45.0
): CodexResponsesHttpResult {
    let decision = codexResponsesWatchdogDecision(events, ttfbTimeoutSeconds: ttfbTimeoutSeconds, idleTimeoutSeconds: idleTimeoutSeconds)
    if (decision.action == "kill") {
        return CodexResponsesHttpResult(0, streamEvents: events, closeReason: decision.closeReason, error: decision.message)
    }
    try {
        let response = codexResponsesEventsToResponse(events, model: model)
        return CodexResponsesHttpResult(200, body: response.toJsonString(), streamEvents: events)
    } catch (ex: CodexResponsesException) {
        if (ex.code != "missing_terminal") {
            throw ex
        }
        let response = JsonObject()
        response.put("status", JsonString("completed"))
        response.put("model", JsonString(model))
        response.put("output", JsonArray())
        response.put("synthesized_terminal", JsonBool(true))
        return CodexResponsesHttpResult(200, body: response.toJsonString(), streamEvents: events, closeReason: "missing_terminal")
    }
}
