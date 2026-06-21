package metis.cron

import magic.log.LogUtils

import std.collection.ArrayList
import std.convert.Parsable
import std.io.StringReader
import std.net.{SocketAddress, TcpSocket}
import std.sync.Mutex
import std.time.DateTime

import stdx.encoding.url.URL
import stdx.encoding.json.{JsonInt, JsonObject, JsonString}
import stdx.net.http.*
import stdx.net.tls.TlsClientConfig

public struct CronWebhookUrlDecision {
    public var ok: Bool
    public var normalizedUrl: String
    public var errorKind: String
    public var redactedUrl: String

    public init(
        ok!: Bool = false,
        normalizedUrl!: String = "",
        errorKind!: String = "",
        redactedUrl!: String = ""
    ) {
        this.ok = ok
        this.normalizedUrl = normalizedUrl
        this.errorKind = errorKind
        this.redactedUrl = redactedUrl
    }
}

public class CronWebhookHttpRequest {
    public let url: String
    public let body: JsonObject
    public let timeoutMs: Int64
    public let verifyTls: Bool

    public init(url: String, body: JsonObject, timeoutMs: Int64, verifyTls: Bool) {
        this.url = url
        this.body = body
        this.timeoutMs = timeoutMs
        this.verifyTls = verifyTls
    }
}

public class CronWebhookHttpResponse {
    public let ok: Bool
    public let statusCode: Int64
    public let errorKind: String

    public init(ok: Bool, statusCode!: Int64 = 0, errorKind!: String = "") {
        this.ok = ok
        this.statusCode = statusCode
        this.errorKind = errorKind
    }
}

private let cronWebhookRunnerLock = Mutex()
private var cronWebhookHttpRunnerForTest: Option<(CronWebhookHttpRequest) -> CronWebhookHttpResponse> =
    None<(CronWebhookHttpRequest) -> CronWebhookHttpResponse>

public func setCronWebhookHttpRunnerForTest(runner: Option<(CronWebhookHttpRequest) -> CronWebhookHttpResponse>): Unit {
    synchronized(cronWebhookRunnerLock) {
        cronWebhookHttpRunnerForTest = runner
    }
}

public func cronWebhookTimeoutMs(jobTimeoutMs: Int64): Int64 {
    if (jobTimeoutMs <= 0) {
        return 30_000
    }
    max(1_000, min(120_000, jobTimeoutMs))
}

private func cronWebhookScheme(url: String): String {
    let low = url.toAsciiLower()
    if (low.startsWith("https://")) {
        return "https"
    }
    if (low.startsWith("http://")) {
        return "http"
    }
    ""
}

private func cronWebhookAuthority(url: String): String {
    let scheme = cronWebhookScheme(url)
    if (scheme.isEmpty()) {
        return ""
    }
    let rest = if (scheme == "https") { url[8..] } else { url[7..] }
    let noPath = rest.split("/")[0]
    let noQuery = noPath.split("?")[0]
    noQuery.split("#")[0]
}

private func cronWebhookPrivateIpv4(host: String): Bool {
    let parts = host.split(".")
    if (parts.size != 4) {
        return false
    }
    let nums = ArrayList<Int64>()
    for (part in parts) {
        let t = part.trimAscii()
        if (t.isEmpty()) {
            return false
        }
        let n = try {
            Int64.parse(t)
        } catch (_: Exception) {
            return false
        }
        if (n < 0 || n > 255) {
            return false
        }
        nums.add(n)
    }
    let a = nums[0]
    let b = nums[1]
    a == 0 ||
        a == 10 ||
        a == 127 ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 100 && b >= 64 && b <= 127)
}

private func cronWebhookPrivateIpv6(host: String): Bool {
    let h = host.trimAscii().toAsciiLower().replace("[", "").replace("]", "")
    if (!h.contains(":")) {
        return false
    }
    h == "::1" ||
        h.startsWith("0:0:0:0:0:0:0:1") ||
        h.startsWith("fc") ||
        h.startsWith("fd") ||
        h.startsWith("fe80") ||
        h.startsWith("::ffff:127.")
}

private func cronWebhookHostBlocked(host: String): String {
    let h = host.trimAscii().toAsciiLower()
    if (h.isEmpty()) {
        return "empty_host"
    }
    if (h == "localhost" || h.endsWith(".localhost")) {
        return "localhost"
    }
    if (h == "metadata.google.internal") {
        return "metadata_host"
    }
    if (cronWebhookPrivateIpv4(h)) {
        return "private_ip"
    }
    if (cronWebhookPrivateIpv6(h)) {
        return "private_ip"
    }
    if (!h.contains(".") && !h.contains(":")) {
        return "unresolved_host"
    }
    ""
}

public func redactCronWebhookUrlForLog(raw: String): String {
    let t = raw.trimAscii()
    let scheme = cronWebhookScheme(t)
    if (scheme.isEmpty()) {
        return "invalid-url"
    }
    let parsed = try {
        URL.parse(t)
    } catch (_: Exception) {
        return "${scheme}://invalid-host"
    }
    let host = parsed.hostName.trimAscii().toAsciiLower()
    "${scheme}://${host}/redacted-path-len-${max(0, t.size - (scheme.size + 3 + host.size))}"
}

public func validateCronWebhookUrl(raw: String): CronWebhookUrlDecision {
    let t = raw.trimAscii()
    if (t.isEmpty()) {
        return CronWebhookUrlDecision(errorKind: "empty_url")
    }
    let scheme = cronWebhookScheme(t)
    if (scheme.isEmpty()) {
        return CronWebhookUrlDecision(errorKind: "unsupported_scheme")
    }
    let authority = cronWebhookAuthority(t)
    if (authority.contains("@")) {
        return CronWebhookUrlDecision(errorKind: "userinfo_not_allowed", redactedUrl: redactCronWebhookUrlForLog(t))
    }
    let parsed = try {
        URL.parse(t)
    } catch (_: Exception) {
        return CronWebhookUrlDecision(errorKind: "malformed_url", redactedUrl: redactCronWebhookUrlForLog(t))
    }
    let host = parsed.hostName.trimAscii().toAsciiLower()
    let hostError = cronWebhookHostBlocked(host)
    if (!hostError.isEmpty()) {
        return CronWebhookUrlDecision(errorKind: hostError, redactedUrl: redactCronWebhookUrlForLog(t))
    }
    CronWebhookUrlDecision(ok: true, normalizedUrl: t, redactedUrl: redactCronWebhookUrlForLog(t))
}

private func cronWebhookReadBody(response: HttpResponse): String {
    try {
        StringReader(response.body).readToEnd()
    } catch (_: Exception) {
        ""
    }
}

private func cronWebhookBuildClient(url: String, timeoutMs: Int64): Client {
    let builder = ClientBuilder()
    builder.readTimeout(Duration.millisecond * max(1, timeoutMs))
    if (url.toAsciiLower().startsWith("https://")) {
        var tlsConfig = TlsClientConfig()
        tlsConfig.domain = URL.parse(url).hostName
        builder.tlsConfig(tlsConfig)
    }
    let effectiveTimeout = max(1, timeoutMs)
    let connector = { sa: SocketAddress =>
        let socket = TcpSocket(sa)
        socket.readTimeout = Duration.millisecond * effectiveTimeout
        socket.writeTimeout = Duration.millisecond * effectiveTimeout
        socket.connect(timeout: Duration.millisecond * effectiveTimeout)
        socket
    }
    builder.connector(connector)
    builder.build()
}

private func cronWebhookNativePost(request: CronWebhookHttpRequest): CronWebhookHttpResponse {
    let client = cronWebhookBuildClient(request.url, request.timeoutMs)
    try {
        let req = HttpRequestBuilder()
            .url(request.url)
            .post()
            .header("Content-Type", "application/json")
            .body(request.body.toJsonString())
            .build()
        let response = client.send(req)
        let status = Int64(response.status)
        let _ = cronWebhookReadBody(response)
        CronWebhookHttpResponse(status >= 200 && status < 300, statusCode: status)
    } catch (e: Exception) {
        let msg = e.message.toAsciiLower()
        let kind = if (msg.contains("timeout") || msg.contains("timed out")) {
            "timeout"
        } else {
            "request_failed"
        }
        CronWebhookHttpResponse(false, errorKind: kind)
    } finally {
        client.close()
    }
}

/** Cron 成功/失败 webhook 投递（JSON POST）。 */
public func postCronWebhookJson(url: String, body: JsonObject, timeoutMs!: Int64 = 30_000): Bool {
    let decision = validateCronWebhookUrl(url)
    if (!decision.ok) {
        LogUtils.info("CronWebhook: rejected url=${decision.redactedUrl} errorKind=${decision.errorKind}")
        return false
    }
    let started = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let effectiveTimeout = cronWebhookTimeoutMs(timeoutMs)
    let request = CronWebhookHttpRequest(decision.normalizedUrl, body, effectiveTimeout, true)
    try {
        let runnerOpt = synchronized(cronWebhookRunnerLock) {
            cronWebhookHttpRunnerForTest
        }
        let response = match (runnerOpt) {
            case Some(runner) => runner(request)
            case None => cronWebhookNativePost(request)
        }
        let ended = DateTime.now().toUnixTimeStamp().toMilliseconds()
        if (response.ok) {
            return true
        }
        LogUtils.info(
            "CronWebhook: post_failed url=${decision.redactedUrl} status=${response.statusCode} errorKind=${response.errorKind} durationMs=${ended - started}"
        )
        false
    } catch (_: Exception) {
        let ended = DateTime.now().toUnixTimeStamp().toMilliseconds()
        LogUtils.info("CronWebhook: post_failed url=${decision.redactedUrl} status=0 errorKind=request_failed durationMs=${ended - started}")
        false
    }
}

public func buildCronWebhookSuccessBody(
    jobId: String,
    status: String,
    summary: String,
    runAtMs: Int64,
    sessionTarget: String
): JsonObject {
    let o = JsonObject()
    o.put("source", JsonString("metis-cron"))
    o.put("jobId", JsonString(jobId))
    o.put("status", JsonString(status))
    o.put("summary", JsonString(summary))
    o.put("runAtMs", JsonInt(runAtMs))
    o.put("sessionTarget", JsonString(sessionTarget))
    o
}

public func buildCronWebhookFailureBody(jobId: String, error: String, runAtMs: Int64, sessionTarget: String): JsonObject {
    let o = JsonObject()
    o.put("source", JsonString("metis-cron"))
    o.put("jobId", JsonString(jobId))
    o.put("status", JsonString("error"))
    o.put("error", JsonString(error))
    o.put("runAtMs", JsonInt(runAtMs))
    o.put("sessionTarget", JsonString(sessionTarget))
    o
}
