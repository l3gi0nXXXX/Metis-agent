package metis.gateway.tools

import std.collection.ArrayList
import std.convert.Parsable
import stdx.encoding.url.URL

public class GatewayWebUrlDecision {
    public let allowed: Bool
    public let code: String
    public let message: String
    public let normalizedUrl: String
    public let redactedUrl: String

    public init(
        allowed!: Bool = false,
        code!: String = "web_fetch_invalid_url",
        message!: String = "",
        normalizedUrl!: String = "",
        redactedUrl!: String = ""
    ) {
        this.allowed = allowed
        this.code = code.trimAscii()
        this.message = message.trimAscii()
        this.normalizedUrl = normalizedUrl.trimAscii()
        this.redactedUrl = redactedUrl.trimAscii()
    }
}

private func gatewayWebUrlScheme(raw: String): String {
    let lower = raw.trimAscii().toAsciiLower()
    if (lower.startsWith("https://")) {
        return "https"
    }
    if (lower.startsWith("http://")) {
        return "http"
    }
    ""
}

private func gatewayWebUrlAuthority(raw: String): String {
    let scheme = gatewayWebUrlScheme(raw)
    if (scheme.isEmpty()) {
        return ""
    }
    let trimmed = raw.trimAscii()
    let rest = if (scheme == "https") { trimmed[8..] } else { trimmed[7..] }
    let noPath = rest.split("/")[0]
    let noQuery = noPath.split("?")[0]
    noQuery.split("#")[0]
}

private func gatewayWebUrlQuery(raw: String): String {
    let trimmed = raw.trimAscii()
    match (trimmed.indexOf("?")) {
        case Some(idx) =>
            let tail = trimmed[idx + 1..]
            match (tail.indexOf("#")) {
                case Some(hashIdx) => tail[..hashIdx]
                case None => tail
            }
        case None => ""
    }
}

private func gatewayWebUrlPath(raw: String): String {
    let scheme = gatewayWebUrlScheme(raw)
    if (scheme.isEmpty()) {
        return ""
    }
    let trimmed = raw.trimAscii()
    let rest = if (scheme == "https") { trimmed[8..] } else { trimmed[7..] }
    match (rest.indexOf("/")) {
        case Some(idx) =>
            let target = rest[idx..]
            match (target.indexOf("?")) {
                case Some(q) => target[..q]
                case None => target
            }
        case None => ""
    }
}

private func gatewayWebUrlHasSecretQuery(query: String): Bool {
    for (part in query.split("&")) {
        let rawKey = part.split("=")[0].trimAscii().toAsciiLower().replace("-", "_")
        if (
            rawKey.contains("token") ||
            rawKey.contains("password") ||
            rawKey.contains("passwd") ||
            rawKey == "auth" ||
            rawKey.contains("authorization") ||
            rawKey == "api_key" ||
            rawKey == "apikey" ||
            rawKey == "client_secret" ||
            rawKey == "secret" ||
            rawKey == "session_key"
        ) {
            return true
        }
    }
    false
}

private func gatewayWebUrlHasSecretPath(path: String): Bool {
    let p = path.trimAscii().toAsciiLower()
    p.contains("/token/") ||
        p.contains("/password/") ||
        p.contains("/auth/") ||
        p.contains("/authorization/") ||
        p.contains("/api_key/") ||
        p.contains("/secret/")
}

private func gatewayWebUrlIpv4Parts(host: String): Option<Array<Int64>> {
    let parts = host.split(".")
    if (parts.size != 4) {
        return None<Array<Int64>>
    }
    let nums = ArrayList<Int64>()
    for (part in parts) {
        let t = part.trimAscii()
        if (t.isEmpty()) {
            return None<Array<Int64>>
        }
        let n = try { Int64.parse(t) } catch (_: Exception) { return None<Array<Int64>> }
        if (n < 0 || n > 255) {
            return None<Array<Int64>>
        }
        nums.add(n)
    }
    Some(nums.toArray())
}

private func gatewayWebUrlBlockedIpv4(host: String): Bool {
    match (gatewayWebUrlIpv4Parts(host)) {
        case Some(nums) =>
            let a = nums[0]
            let b = nums[1]
            let c = nums[2]
            a == 0 ||
                a == 10 ||
                a == 127 ||
                (a == 100 && b >= 64 && b <= 127) ||
                (a == 169 && b == 254) ||
                (a == 172 && b >= 16 && b <= 31) ||
                (a == 192 && b == 168) ||
                (a == 192 && b == 0) ||
                (a == 192 && b == 88 && c == 99) ||
                (a == 198 && (b == 18 || b == 19)) ||
                (a == 198 && b == 51 && c == 100) ||
                (a == 203 && b == 0 && c == 113) ||
                a >= 224
        case None => false
    }
}

private func gatewayWebUrlBlockedIpv6(host: String): Bool {
    let h = host.trimAscii().toAsciiLower().replace("[", "").replace("]", "")
    if (!h.contains(":")) {
        return false
    }
    if (
        h == "::" ||
        h == "::1" ||
        h.startsWith("0:0:0:0:0:0:0:1") ||
        h.startsWith("fc") ||
        h.startsWith("fd") ||
        h.startsWith("fe8") ||
        h.startsWith("fe9") ||
        h.startsWith("fea") ||
        h.startsWith("feb") ||
        h.startsWith("ff")
    ) {
        return true
    }
    if (h.startsWith("::ffff:")) {
        let mapped = h[7..]
        return gatewayWebUrlBlockedIpv4(mapped)
    }
    false
}

private func gatewayWebUrlBlockedHostReason(host: String): String {
    let h = host.trimAscii().toAsciiLower().replace("[", "").replace("]", "")
    if (h.isEmpty()) {
        return "empty host"
    }
    if (h == "localhost" || h.endsWith(".localhost")) {
        return "localhost is not allowed"
    }
    if (h == "metadata.google.internal") {
        return "metadata host is not allowed"
    }
    if (gatewayWebUrlBlockedIpv4(h) || gatewayWebUrlBlockedIpv6(h)) {
        return "private or reserved IP address is not allowed"
    }
    if (!h.contains(".") && !h.contains(":")) {
        return "unqualified host is not allowed"
    }
    ""
}

public func gatewayWebRedactUrlForLog(raw: String): String {
    let trimmed = raw.trimAscii()
    let scheme = gatewayWebUrlScheme(trimmed)
    if (scheme.isEmpty()) {
        return "invalid-url"
    }
    let parsed = try { URL.parse(trimmed) } catch (_: Exception) { return "${scheme}://invalid-host" }
    let host = parsed.hostName.trimAscii().toAsciiLower()
    "${scheme}://${host}/redacted-path-len-${max(0, trimmed.size - (scheme.size + 3 + host.size))}"
}

public func gatewayWebValidateUrl(raw: String): GatewayWebUrlDecision {
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty()) {
        return GatewayWebUrlDecision(code: "web_fetch_invalid_url", message: "URL is empty.")
    }
    if (trimmed.size > 4096) {
        return GatewayWebUrlDecision(
            code: "web_fetch_invalid_url",
            message: "URL is too long.",
            redactedUrl: gatewayWebRedactUrlForLog(trimmed)
        )
    }

    let scheme = gatewayWebUrlScheme(trimmed)
    if (scheme.isEmpty()) {
        return GatewayWebUrlDecision(
            code: "web_fetch_invalid_url",
            message: "Only http and https URLs are allowed.",
            redactedUrl: gatewayWebRedactUrlForLog(trimmed)
        )
    }

    let authority = gatewayWebUrlAuthority(trimmed)
    if (authority.contains("@")) {
        return GatewayWebUrlDecision(
            code: "web_fetch_secret_url",
            message: "URL userinfo is not allowed.",
            redactedUrl: gatewayWebRedactUrlForLog(trimmed)
        )
    }

    let parsed = try {
        URL.parse(trimmed)
    } catch (_: Exception) {
        return GatewayWebUrlDecision(
            code: "web_fetch_invalid_url",
            message: "URL is malformed.",
            redactedUrl: gatewayWebRedactUrlForLog(trimmed)
        )
    }

    let host = parsed.hostName.trimAscii().toAsciiLower()
    let blockedReason = gatewayWebUrlBlockedHostReason(host)
    if (!blockedReason.isEmpty()) {
        return GatewayWebUrlDecision(
            code: "web_fetch_blocked_url",
            message: blockedReason,
            redactedUrl: gatewayWebRedactUrlForLog(trimmed)
        )
    }

    if (gatewayWebUrlHasSecretQuery(gatewayWebUrlQuery(trimmed)) || gatewayWebUrlHasSecretPath(gatewayWebUrlPath(trimmed))) {
        return GatewayWebUrlDecision(
            code: "web_fetch_secret_url",
            message: "URL contains sensitive credential-like fields.",
            redactedUrl: gatewayWebRedactUrlForLog(trimmed)
        )
    }

    GatewayWebUrlDecision(
        allowed: true,
        code: "ok",
        message: "URL is allowed.",
        normalizedUrl: trimmed,
        redactedUrl: gatewayWebRedactUrlForLog(trimmed)
    )
}
