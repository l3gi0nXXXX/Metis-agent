package metis.gateway.runtime

import metis.core.metisSafeRuneEllipsis
import metis.gateway.logging.gatewayLogRedactText

public class CronWebDiagnostic {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        this.code = code.trimAscii()
        this.message = message.trimAscii()
    }
}

private func cronWebDiagnosticCodeToken(raw: String): String {
    let token = raw.trimAscii().split(" ")[0].trimAscii()
    token.replace(".", "").replace(",", "").replace(";", "")
}

private func cronWebDiagnosticKnownCode(code: String): Bool {
    let normalized = code.trimAscii().toAsciiLower()
    normalized.startsWith("web_") || normalized == "invalid_response_encoding"
}

private func cronWebDiagnosticLine(raw: String): String {
    raw.split("\n", 2)[0].replace("\r", " ").trimAscii()
}

private func cronWebRedactAfterMarker(raw: String, marker: String): String {
    let parts = raw.split(marker, 2)
    if (parts.size < 2) {
        return raw
    }
    parts[0] + marker + "[redacted]"
}

private func cronWebRedactUrlUserInfo(raw: String): String {
    let schemeParts = raw.split("://", 2)
    if (schemeParts.size < 2) {
        return raw
    }
    let restParts = schemeParts[1].split("@", 2)
    if (restParts.size < 2) {
        return raw
    }
    schemeParts[0] + "://[redacted]@" + restParts[1]
}

public func cronWebSanitizeDiagnosticMessage(raw: String, maxRunes!: Int64 = 240): String {
    var out = gatewayLogRedactText(raw.replace("\r", " ").replace("\n", " ").trimAscii())
    out = cronWebRedactUrlUserInfo(out)
    out = cronWebRedactAfterMarker(out, "Authorization: Bearer ")
    out = cronWebRedactAfterMarker(out, "authorization: bearer ")
    out = cronWebRedactAfterMarker(out, "Authorization=")
    out = cronWebRedactAfterMarker(out, "authorization=")
    out = cronWebRedactAfterMarker(out, "Bearer ")
    out = cronWebRedactAfterMarker(out, "bearer ")
    out = cronWebRedactAfterMarker(out, "api_key=")
    out = cronWebRedactAfterMarker(out, "apiKey=")
    out = cronWebRedactAfterMarker(out, "token=")
    out = cronWebRedactAfterMarker(out, "access_token=")
    out = cronWebRedactAfterMarker(out, "auth_token=")
    out = cronWebRedactAfterMarker(out, "password=")
    out = cronWebRedactAfterMarker(out, "passwd=")
    metisSafeRuneEllipsis(out, maxRunes)
}

private func cronWebDiagnosticMessageFromTail(tail: String, code: String): String {
    let messageParts = tail.split("message=", 2)
    let raw = if (messageParts.size >= 2) {
        cronWebDiagnosticLine(messageParts[1])
    } else {
        cronWebDiagnosticLine(tail)
    }
    let fallback = if (raw.isEmpty()) { code } else { raw }
    cronWebSanitizeDiagnosticMessage(fallback, maxRunes: 240)
}

public func cronWebDiagnosticFromText(text: String): Option<CronWebDiagnostic> {
    var scan = text
    while (true) {
        let parts = scan.split("Diagnostic: code=", 2)
        if (parts.size < 2) {
            return None<CronWebDiagnostic>
        }
        let tail = parts[1]
        let code = cronWebDiagnosticCodeToken(tail)
        if (cronWebDiagnosticKnownCode(code)) {
            return Some(CronWebDiagnostic(code, cronWebDiagnosticMessageFromTail(tail, code)))
        }
        scan = tail
    }
    None<CronWebDiagnostic>
}
