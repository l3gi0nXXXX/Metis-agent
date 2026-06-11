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
    private let timeoutMs: Int64

    public init(timeoutMs!: Int64 = 30000) {
        this.timeoutMs = if (timeoutMs <= 0) { 30000 } else { timeoutMs }
    }

    public func postJson(url: String, body: String): OpenAICodexHttpResponse {
        this.post(url, body, "application/json")
    }

    public func postForm(url: String, body: String): OpenAICodexHttpResponse {
        this.post(url, body, "application/x-www-form-urlencoded")
    }

    private func post(url: String, body: String, contentType: String): OpenAICodexHttpResponse {
        let builder = ClientBuilder()
        builder.readTimeout(Duration.millisecond * this.timeoutMs)
        if (url.startsWith("https://")) {
            var tlsConfig = TlsClientConfig()
            tlsConfig.domain = URL.parse(url).hostName
            tlsConfig.alpnProtocolsList = ["http/1.1"]
            builder.tlsConfig(tlsConfig)
        }
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
            OpenAICodexHttpResponse(0, "{\"error\":\"network_error\",\"message\":\"${openAICodexHttpEscape(ex.message)}\"}")
        } finally {
            client.close()
        }
    }
}

private func openAICodexHttpEscape(raw: String): String {
    raw
        .replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
}
