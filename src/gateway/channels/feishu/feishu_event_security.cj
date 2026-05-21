package metis.gateway.channels.feishu

import std.collection.ArrayList
import std.convert.Parsable
import std.time.DateTime
import stdx.crypto.digest.SHA256
import stdx.encoding.json.JsonValue

public class FeishuEventSecurityValidationResult {
    public let ok: Bool
    public let reason: String
    public let payload: String
    public let error: String

    public init(ok!: Bool = false, reason!: String = "failed", payload!: String = "", error!: String = "") {
        this.ok = ok
        this.reason = reason.trimAscii()
        this.payload = payload
        this.error = error.trimAscii()
    }
}

public class FeishuEventDecryptResult {
    public let ok: Bool
    public let status: String
    public let payload: String
    public let error: String

    public init(ok!: Bool = false, status!: String = "failed", payload!: String = "", error!: String = "") {
        this.ok = ok
        this.status = status.trimAscii()
        this.payload = payload
        this.error = error.trimAscii()
    }
}

public func feishuEventSecuritySignature(
    timestamp!: String,
    nonce!: String,
    encryptKey!: String,
    payload!: String
): String {
    let base = timestamp.trimAscii() + nonce.trimAscii() + encryptKey.trimAscii() + payload
    let sha = SHA256()
    sha.write(base.toArray())
    feishuEventSecurityBytesToHex(sha.finish())
}

public func feishuDecryptEncryptedEventPayload(encryptKey!: String, encryptedPayload!: String): FeishuEventDecryptResult {
    if (encryptedPayload.trimAscii().isEmpty()) {
        return FeishuEventDecryptResult(ok: false, status: "invalid_payload", error: "encrypted Feishu event payload is empty")
    }
    if (encryptKey.trimAscii().isEmpty()) {
        return FeishuEventDecryptResult(ok: false, status: "invalid_config", error: "Feishu encryptKey is required for AES decrypt")
    }
    FeishuEventDecryptResult(
        ok: false,
        status: "unsupported",
        error: "AES decrypt for encrypted Feishu event payload is not available in the native runtime yet"
    )
}

public func feishuValidateEventSecurity(
    timestamp!: String,
    nonce!: String,
    signature!: String,
    payload!: String,
    verificationToken!: String = "",
    encryptKey!: String = "",
    requireSignature!: Bool = true,
    maxSkewSeconds!: Int64 = 300,
    nowSeconds!: Int64 = DateTime.now().toUnixTimeStamp().toSeconds()
): FeishuEventSecurityValidationResult {
    let ts = try {
        Int64.parse(timestamp.trimAscii())
    } catch (_e: Exception) {
        return FeishuEventSecurityValidationResult(ok: false, reason: "invalid_timestamp", error: "invalid Feishu request timestamp")
    }
    let diff = if (nowSeconds >= ts) { nowSeconds - ts } else { ts - nowSeconds }
    if (diff > maxSkewSeconds) {
        return FeishuEventSecurityValidationResult(ok: false, reason: "timestamp_skew", error: "Feishu request timestamp is outside allowed skew")
    }

    let root = try {
        JsonValue.fromStr(payload).asObject()
    } catch (_e: Exception) {
        return FeishuEventSecurityValidationResult(ok: false, reason: "invalid_json", error: "invalid Feishu event JSON")
    }

    let encrypted = match (root.get("encrypt")) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_e: Exception) { "" }
        case None => ""
    }
    if (!encrypted.isEmpty()) {
        let decrypt = feishuDecryptEncryptedEventPayload(encryptKey: encryptKey, encryptedPayload: encrypted)
        return FeishuEventSecurityValidationResult(
            ok: false,
            reason: "encrypted_payload_unsupported",
            error: decrypt.error
        )
    }

    if (!verificationToken.trimAscii().isEmpty()) {
        let token = match (root.get("token")) {
            case Some(v) => try { v.asString().getValue() } catch (_e: Exception) { "" }
            case None => ""
        }
        if (!feishuEventSecurityConstantTimeEquals(token, verificationToken)) {
            return FeishuEventSecurityValidationResult(ok: false, reason: "invalid_token", error: "invalid Feishu verification token")
        }
    }

    if (requireSignature) {
        if (nonce.trimAscii().isEmpty()) {
            return FeishuEventSecurityValidationResult(ok: false, reason: "missing_nonce", error: "missing Feishu request nonce")
        }
        if (signature.trimAscii().isEmpty()) {
            return FeishuEventSecurityValidationResult(ok: false, reason: "missing_signature", error: "missing Feishu request signature")
        }
        if (encryptKey.trimAscii().isEmpty()) {
            return FeishuEventSecurityValidationResult(ok: false, reason: "missing_encrypt_key", error: "Feishu encryptKey is required for signature validation")
        }
        let expected = feishuEventSecuritySignature(
            timestamp: timestamp,
            nonce: nonce,
            encryptKey: encryptKey,
            payload: payload
        )
        if (!feishuEventSecurityConstantTimeEquals(signature.trimAscii().toAsciiLower(), expected)) {
            return FeishuEventSecurityValidationResult(ok: false, reason: "invalid_signature", error: "invalid Feishu request signature")
        }
    }

    FeishuEventSecurityValidationResult(ok: true, reason: "ok", payload: payload)
}

private func feishuEventSecurityBytesToHex(bytes: Array<Byte>): String {
    let out = ArrayList<String>()
    for (b in bytes) {
        let n = Int64(b)
        out.add("${feishuEventSecurityHexDigit(n / 16)}${feishuEventSecurityHexDigit(n % 16)}")
    }
    String.join(out.toArray(), delimiter: "")
}

private func feishuEventSecurityHexDigit(n: Int64): String {
    match (n) {
        case 0 => "0"
        case 1 => "1"
        case 2 => "2"
        case 3 => "3"
        case 4 => "4"
        case 5 => "5"
        case 6 => "6"
        case 7 => "7"
        case 8 => "8"
        case 9 => "9"
        case 10 => "a"
        case 11 => "b"
        case 12 => "c"
        case 13 => "d"
        case 14 => "e"
        case 15 => "f"
        case _ => "0"
    }
}

private func feishuEventSecurityConstantTimeEquals(a: String, b: String): Bool {
    let left = a.toArray()
    let right = b.toArray()
    var diff: Int64 = if (left.size == right.size) { 0 } else { 1 }
    let size = if (left.size >= right.size) { left.size } else { right.size }
    for (i in 0..size) {
        let la = if (i < left.size) { Int64(left[i]) } else { 0 }
        let rb = if (i < right.size) { Int64(right[i]) } else { 0 }
        diff = diff | (la ^ rb)
    }
    diff == 0
}
