package metis.core

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

public func metisSafeDiagnosticText(text: String, maxBytes!: Int64 = 4096): String {
    var cleaned = text.replace("\u{0000}", "")
    cleaned = cleaned.replace("\r", " ")
    metisSafeUtf8Prefix(cleaned, maxBytes, marker: "...[TRUNCATED]")
}

public func metisDecodeUtf8Bytes(bytes: Array<Byte>): MetisUtf8DecodeResult {
    try {
        MetisUtf8DecodeResult(true, text: String.fromUtf8(bytes))
    } catch (e: Exception) {
        let detail = if (e.message.trimAscii().isEmpty()) { "invalid utf8 byte sequence" } else { e.message }
        MetisUtf8DecodeResult(false, status: "invalid_response_encoding", diagnostic: detail)
    }
}
