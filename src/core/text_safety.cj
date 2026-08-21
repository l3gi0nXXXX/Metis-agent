package metis.core

import std.regex.{MatchData, Regex, RegexFlag}

public class MetisUtf8DecodeResult {
    public let ok: Bool
    public let status: String
    public let text: String
    public let diagnostic: String

    public init(ok: Bool, status!: String = "ok", text!: String = "", diagnostic!: String = "") {
        this.ok = ok
        this.status = status.trimAscii()
        this.text = text
        this.diagnostic = diagnostic.trimAscii()
    }
}

public func metisSafeUtf8Prefix(text: String, maxBytes: Int64, marker!: String = ""): String {
    if (maxBytes <= 0) {
        return if (text.isEmpty()) { "" } else { marker }
    }
    if (text.size <= maxBytes) {
        return text
    }
    let out = StringBuilder()
    var used: Int64 = 0
    for (rune in text.toRuneArray()) {
        let piece = String([rune])
        let next = used + piece.size
        if (next > maxBytes) {
            return out.toString() + marker
        }
        out.append(piece)
        used = next
    }
    out.toString()
}

private func appendRunePrefix(out: StringBuilder, runes: Array<Rune>, maxRunes: Int64): Unit {
    var idx: Int64 = 0
    while (idx < maxRunes && idx < runes.size) {
        out.append(String([runes[idx]]))
        idx += 1
    }
}

public func metisSafeRuneEllipsis(text: String, maxRunes: Int64, marker!: String = "..."): String {
    if (maxRunes <= 0) {
        return ""
    }
    let runes = text.toRuneArray()
    if (runes.size <= maxRunes) {
        return text
    }
    let markerRunes = marker.toRuneArray()
    if (markerRunes.size == 0) {
        let out = StringBuilder()
        appendRunePrefix(out, runes, maxRunes)
        return out.toString()
    }
    let out = StringBuilder()
    if (maxRunes <= markerRunes.size) {
        appendRunePrefix(out, markerRunes, maxRunes)
        return out.toString()
    }
    appendRunePrefix(out, runes, maxRunes - markerRunes.size)
    out.append(marker)
    out.toString()
}

public func metisSafeDiagnosticText(text: String, maxBytes!: Int64 = 4096): String {
    var cleaned = text.replace("\u{0000}", "")
    cleaned = cleaned.replace("\r", " ")
    metisSafeUtf8Prefix(cleaned, maxBytes, marker: "...[TRUNCATED]")
}

private func metisSensitiveRegexReplace(text: String, pattern: String, replacement: String): String {
    try { Regex(pattern, [RegexFlag.IgnoreCase]).replaceAll(text, replacement) } catch (_: Exception) { text }
}

private func metisSensitiveRegexReplaceMatch(text: String, pattern: String, replacement: (MatchData) -> String): String {
    try {
        let builder = StringBuilder()
        var previous: Int64 = 0
        for (matched in Regex(pattern, [RegexFlag.IgnoreCase]).findAll(text, group: true)) {
            let position = matched.matchPosition()
            builder.append(text[previous..position.start])
            builder.append(replacement(matched))
            previous = position.end
        }
        builder.append(text[previous..])
        builder.toString()
    } catch (_: Exception) { text }
}

public func metisRedactSensitiveText(text: String, marker!: String = "[redacted]"): String {
    var out = text
    out = metisSensitiveRegexReplaceMatch(out, "(\\b[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD)\\b\\s*[=:]\\s*[\"']?)[^\\s\"'\\\\]+([\"']?)", { matched =>
        "${matched.matchString(1)}${marker}${matched.matchString(2)}"
    })
    out = metisSensitiveRegexReplaceMatch(out, "(\"(?:apiKey|token|secret|password|passwd|accessToken|refreshToken)\"\\s*:\\s*\")[^\"]+(\")", { matched =>
        "${matched.matchString(1)}${marker}${matched.matchString(2)}"
    })
    out = metisSensitiveRegexReplaceMatch(out, "(--(?:api[-_]?key|token|secret|password|passwd)\\s+[\"']?)[^\\s\"']+([\"']?)", { matched =>
        "${matched.matchString(1)}${marker}${matched.matchString(2)}"
    })
    out = metisSensitiveRegexReplaceMatch(out, "(Authorization\\s*[:=]\\s*Bearer\\s+)[A-Za-z0-9._\\-+=]+", { matched =>
        "${matched.matchString(1)}${marker}"
    })
    out = metisSensitiveRegexReplaceMatch(out, "(Authorization\\s*[:=]\\s*)[^\\s,;\\}\\]]+", { matched =>
        "${matched.matchString(1)}${marker}"
    })
    out = metisSensitiveRegexReplaceMatch(out, "(\\bBearer\\s+)[A-Za-z0-9._\\-+=]{18,}\\b", { matched =>
        "${matched.matchString(1)}${marker}"
    })
    out = metisSensitiveRegexReplaceMatch(out, "(-----BEGIN [A-Z ]*PRIVATE KEY-----)[\\s\\S]+?(-----END [A-Z ]*PRIVATE KEY-----)", { matched =>
        "${matched.matchString(1)}\n${marker}\n${matched.matchString(2)}"
    })
    out = metisSensitiveRegexReplace(out, "\\bsk-[A-Za-z0-9_-]{8,}\\b", marker)
    out = metisSensitiveRegexReplace(out, "\\bghp_[A-Za-z0-9]{20,}\\b", marker)
    out = metisSensitiveRegexReplace(out, "\\bgithub_pat_[A-Za-z0-9_]{20,}\\b", marker)
    out = metisSensitiveRegexReplace(out, "\\bxox[baprs]-[A-Za-z0-9-]{10,}\\b", marker)
    out = metisSensitiveRegexReplace(out, "\\bxapp-[A-Za-z0-9-]{10,}\\b", marker)
    out = metisSensitiveRegexReplace(out, "\\bgsk_[A-Za-z0-9_-]{10,}\\b", marker)
    out = metisSensitiveRegexReplace(out, "\\bAIza[0-9A-Za-z\\-_]{20,}\\b", marker)
    out = metisSensitiveRegexReplace(out, "\\bpplx-[A-Za-z0-9_-]{10,}\\b", marker)
    out = metisSensitiveRegexReplace(out, "\\bnpm_[A-Za-z0-9]{10,}\\b", marker)
    out = metisSensitiveRegexReplace(out, "\\bbot[0-9]{6,}:[A-Za-z0-9_-]{20,}\\b", "bot${marker}")
    out = metisSensitiveRegexReplace(out, "\\b[0-9]{6,}:[A-Za-z0-9_-]{20,}\\b", marker)
    out = metisSensitiveRegexReplace(out, "\\b[0-9]{5,}:[A-Za-z0-9_-]{6,}\\b", marker)
    out = metisSensitiveRegexReplace(out, "app[_-]?secret[_a-zA-Z0-9-]*", marker)
    out = metisSensitiveRegexReplaceMatch(out, "(api[_-]?key\\s*[:=]\\s*)[^\\s,;\\}\\]]+", { matched =>
        "${matched.matchString(1)}${marker}"
    })
    out = metisSensitiveRegexReplaceMatch(out, "(https?://[^\\s:/@]+:)[^\\s/@]+(@)", { matched =>
        "${matched.matchString(1)}${marker}${matched.matchString(2)}"
    })
    metisSensitiveRegexReplace(out, "(/Users/|/home/)[^\\s\"']+", "[redacted-path]")
}

public func metisDecodeUtf8Bytes(bytes: Array<Byte>): MetisUtf8DecodeResult {
    try {
        MetisUtf8DecodeResult(true, text: String.fromUtf8(bytes))
    } catch (e: Exception) {
        let detail = if (e.message.trimAscii().isEmpty()) { "invalid utf8 byte sequence" } else { e.message }
        MetisUtf8DecodeResult(false, status: "invalid_response_encoding", diagnostic: detail)
    }
}
