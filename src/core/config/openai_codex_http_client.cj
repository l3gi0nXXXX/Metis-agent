package metis.core.config

import std.collection.{ArrayList, HashMap}
import std.time.*
import stdx.encoding.url.*
import stdx.net.http.*
import stdx.net.tls.*

private func openAICodexReadHttpBody(response: HttpResponse): String {
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

public class OpenAICodexNativeHttpClient <: OpenAICodexHttpClient {
    private let transportConfig: OpenAICodexOAuthTransportConfig

    public init(
        timeoutMs!: Int64 = 30000,
        transportConfig!: Option<OpenAICodexOAuthTransportConfig> = None<OpenAICodexOAuthTransportConfig>
    ) {
        let safeTimeoutMs = if (timeoutMs <= 0) { 30000 } else { timeoutMs }
        this.transportConfig = match (transportConfig) {
            case Some(cfg) => cfg
            case None => OpenAICodexOAuthTransportConfig(timeoutMs: safeTimeoutMs)
        }
    }

    public func postJson(url: String, body: String): OpenAICodexHttpResponse {
        this.post(url, body, "application/json")
    }

    public func postForm(url: String, body: String): OpenAICodexHttpResponse {
        this.post(url, body, "application/x-www-form-urlencoded")
    }

    private func post(url: String, body: String, contentType: String): OpenAICodexHttpResponse {
        try {
            let preflightRoute = resolveOpenAICodexOAuthRoute(url, this.transportConfig)
            if (preflightRoute.mode == "unsupportedHttpsProxy" ||
                preflightRoute.mode == "unsupportedSocksProxy" ||
                preflightRoute.mode == "invalidProxy") {
                return OpenAICodexHttpResponse(
                    0,
                    openAICodexHttpNetworkErrorBody(preflightRoute.error, route: Some(preflightRoute))
                )
            }
            let builderRoute = buildOpenAICodexOAuthHttpClientBuilder(url, this.transportConfig)
            let builder = builderRoute[0]
            let route = builderRoute[1]
            let client = builder.build()
            try {
                let reqBuilder = HttpRequestBuilder()
                    .url(url)
                    .post()
                    .body(body)
                    .header("Content-Type", contentType)
                    .header("Accept", "application/json, text/plain")
                let response = client.send(reqBuilder.build())
                OpenAICodexHttpResponse(Int64(response.status), openAICodexReadHttpBody(response))
            } catch (ex: Exception) {
                OpenAICodexHttpResponse(0, openAICodexHttpNetworkErrorBody(ex.message, route: Some(route)))
            } finally {
                client.close()
            }
        } catch (ex: Exception) {
            OpenAICodexHttpResponse(0, openAICodexHttpNetworkErrorBody(ex.message))
        }
    }
}

private func openAICodexHttpNetworkErrorBody(message: String, route!: Option<OpenAICodexOAuthRoute> = None<OpenAICodexOAuthRoute>): String {
    var routeMode = ""
    var proxySource = ""
    var redactedProxy = ""
    var targetHost = ""
    match (route) {
        case Some(r) =>
            routeMode = r.mode
            proxySource = r.proxySource
            redactedProxy = r.redactedProxy
            targetHost = r.targetHost
        case None => ()
    }
    var detail = message
    if (!routeMode.isEmpty()) {
        detail += " route=${routeMode}"
    }
    if (!proxySource.isEmpty()) {
        detail += " proxySource=${proxySource}"
    }
    if (!redactedProxy.isEmpty()) {
        detail += " proxy=${redactedProxy}"
    }
    if (!targetHost.isEmpty()) {
        detail += " targetHost=${targetHost}"
    }
    "{\"error\":\"network_error\",\"message\":\"${openAICodexHttpEscape(detail)}\",\"routeMode\":\"${openAICodexHttpEscape(routeMode)}\",\"proxySource\":\"${openAICodexHttpEscape(proxySource)}\",\"proxy\":\"${openAICodexHttpEscape(redactedProxy)}\",\"targetHost\":\"${openAICodexHttpEscape(targetHost)}\"}"
}

private func openAICodexHttpEscape(raw: String): String {
    raw
        .replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
}
