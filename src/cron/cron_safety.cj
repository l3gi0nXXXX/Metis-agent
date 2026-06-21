package metis.cron

import std.regex.{Regex, RegexFlag}
import stdx.encoding.json.{JsonInt, JsonObject, JsonString}

public class CronPromptScanResult {
    public let ok: Bool
    public let threatId: String
    public let message: String

    public init(ok: Bool, threatId!: String = "", message!: String = "") {
        this.ok = ok
        this.threatId = threatId
        this.message = message
    }
}

private let CRON_SECRET_VAR_PATTERN = #"[$]\{?\w*(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|API)\w*\}?"#

private func cronRegexContains(text: String, pattern: String): Bool {
    try {
        for (_match in Regex(pattern, [RegexFlag.IgnoreCase]).findAll(text)) {
            return true
        }
    } catch (_: Exception) {
        return false
    }
    false
}

private func cronRegexReplace(text: String, pattern: String, replacement: String): String {
    try {
        Regex(pattern, [RegexFlag.IgnoreCase]).replaceAll(text, replacement)
    } catch (_: Exception) {
        text
    }
}

private func cronPromptStripSafeConstructs(prompt: String): String {
    let githubAuthPattern =
        "curl\\s+[^\\n]*(?:-H|--header)\\s+[\\\"']Authorization:\\s*token\\s+" +
        CRON_SECRET_VAR_PATTERN +
        "[\\\"']\\s+[\\\"']?https://api\\.github\\.com(?:/|\\b)[^\\n]*"
    cronRegexReplace(prompt, githubAuthPattern, "curl https://api.github.com/user")
}

private func cronRuneIsEmojiNeighbour(ch: Rune): Bool {
    (r'\u{1F000}' <= ch && ch <= r'\u{1FFFF}') ||
    (r'\u{2600}' <= ch && ch <= r'\u{27BF}') ||
    (r'\u{2300}' <= ch && ch <= r'\u{23FF}') ||
    (r'\u{1F1E6}' <= ch && ch <= r'\u{1F1FF}') ||
    ch == r'\u{20E3}'
}

private func cronZwjHasEmojiNeighbour(runes: Array<Rune>, idx: Int64): Bool {
    var left = idx - 1
    while (left >= 0 && runes[left] == r'\u{FE0F}') {
        left -= 1
    }
    var right = idx + 1
    while (right < runes.size && runes[right] == r'\u{FE0F}') {
        right += 1
    }
    left >= 0 && right < runes.size && cronRuneIsEmojiNeighbour(runes[left]) && cronRuneIsEmojiNeighbour(runes[right])
}

private func cronPromptHiddenRuneThreat(ch: Rune, runes: Array<Rune>, idx: Int64): Option<String> {
    if (ch == r'\u{200D}' && cronZwjHasEmojiNeighbour(runes, idx)) {
        return None<String>
    }
    if (
        ch == r'\u{200B}' ||
        ch == r'\u{200C}' ||
        ch == r'\u{200D}' ||
        ch == r'\u{2060}' ||
        ch == r'\u{FEFF}' ||
        ch == r'\u{202A}' ||
        ch == r'\u{202B}' ||
        ch == r'\u{202C}' ||
        ch == r'\u{202D}' ||
        ch == r'\u{202E}'
    ) {
        return Some("invisible_unicode")
    }
    None<String>
}

private func cronPromptInvisibleThreat(prompt: String): Option<String> {
    let runes = prompt.toRuneArray()
    var i: Int64 = 0
    while (i < runes.size) {
        match (cronPromptHiddenRuneThreat(runes[i], runes, i)) {
            case Some(threat) => return Some(threat)
            case None => ()
        }
        i += 1
    }
    None<String>
}

private func cronThreatMessage(threatId: String): String {
    "Cron prompt blocked by safety scanner: threatId=${threatId}"
}

private func cronBlocked(threatId: String): CronPromptScanResult {
    CronPromptScanResult(false, threatId: threatId, message: cronThreatMessage(threatId))
}

private func scanCronPromptWithPatterns(prompt: String, patterns: Array<(String, String)>, includeExfilPatterns: Bool): CronPromptScanResult {
    let promptToScan = cronPromptStripSafeConstructs(prompt)
    match (cronPromptInvisibleThreat(promptToScan)) {
        case Some(threat) => return cronBlocked(threat)
        case None => ()
    }
    for ((pattern, threatId) in patterns) {
        if (cronRegexContains(promptToScan, pattern)) {
            return cronBlocked(threatId)
        }
    }
    if (includeExfilPatterns) {
        for ((pattern, threatId) in cronExfilCommandPatterns()) {
            if (cronRegexContains(promptToScan, pattern)) {
                return cronBlocked(threatId)
            }
        }
    }
    CronPromptScanResult(true)
}

private func cronStrictThreatPatterns(): Array<(String, String)> {
    [
        (#"ignore\s+(?:\w+\s+)*(?:previous|all|above|prior)\s+(?:\w+\s+)*instructions"#, "prompt_injection"),
        (#"do\s+not\s+tell\s+the\s+user"#, "deception_hide"),
        (#"system\s+prompt\s+override"#, "sys_prompt_override"),
        (#"disregard\s+(your|all|any)\s+(instructions|rules|guidelines)"#, "disregard_rules"),
        (#"cat\s+[^\n]*(\.env|credentials|\.netrc|\.pgpass)"#, "read_secrets"),
        (#"authorized_keys"#, "ssh_backdoor"),
        (#"/etc/sudoers|visudo"#, "sudoers_mod"),
        (#"rm\s+-rf\s+/"#, "destructive_root_rm")
    ]
}

private func cronAssembledThreatPatterns(): Array<(String, String)> {
    [
        (#"ignore\s+(?:\w+\s+)*(?:previous|all|above|prior)\s+(?:\w+\s+)*instructions"#, "prompt_injection"),
        (#"do\s+not\s+tell\s+the\s+user"#, "deception_hide"),
        (#"system\s+prompt\s+override"#, "sys_prompt_override"),
        (#"disregard\s+(your|all|any)\s+(instructions|rules|guidelines)"#, "disregard_rules")
    ]
}

private func cronExfilCommandPatterns(): Array<(String, String)> {
    [
        ("curl\\s+[^\\n]*https?://[^\\n]*" + CRON_SECRET_VAR_PATTERN, "exfil_curl_url"),
        ("wget\\s+[^\\n]*https?://[^\\n]*" + CRON_SECRET_VAR_PATTERN, "exfil_wget_url"),
        ("curl\\s+[^\\n]*(?:--data(?:-raw|-binary|-urlencode)?|-d|--form|-F)\\s+[^\\n]*" + CRON_SECRET_VAR_PATTERN, "exfil_curl_data"),
        ("wget\\s+[^\\n]*--post-(?:data|file)=[^\\n]*" + CRON_SECRET_VAR_PATTERN, "exfil_wget_post"),
        ("curl\\s+[^\\n]*(?:-H|--header)\\s+[\\\"']Authorization:\\s*(?:Bearer|token)\\s+" + CRON_SECRET_VAR_PATTERN + "[\\\"']", "exfil_curl_auth_header")
    ]
}

public func scanCronPromptStrict(prompt: String): CronPromptScanResult {
    scanCronPromptWithPatterns(prompt, cronStrictThreatPatterns(), true)
}

public func scanCronPromptAssembled(prompt: String): CronPromptScanResult {
    scanCronPromptWithPatterns(prompt, cronAssembledThreatPatterns(), false)
}

public func cronPromptChars(prompt: String): Int64 {
    prompt.toRuneArray().size
}

public func cronPromptStableHash(prompt: String): String {
    var h: UInt64 = 5381
    let bytes = prompt.toArray()
    var i: Int64 = 0
    while (i < bytes.size) {
        h = ((h << 5) + h) + UInt64(UInt8(bytes[i]))
        i += 1
    }
    h.toString()
}

public func cronPromptScanMeta(jobId: String, scan: CronPromptScanResult, prompt: String, source: String): JsonObject {
    let meta = JsonObject()
    if (!jobId.trimAscii().isEmpty()) {
        meta.put("jobId", JsonString(jobId.trimAscii()))
    }
    meta.put("threatId", JsonString(scan.threatId))
    meta.put("promptChars", JsonInt(cronPromptChars(prompt)))
    meta.put("promptHash", JsonString(cronPromptStableHash(prompt)))
    meta.put("source", JsonString(source.trimAscii()))
    meta
}
