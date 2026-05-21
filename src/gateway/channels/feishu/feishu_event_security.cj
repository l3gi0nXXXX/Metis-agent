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
    try {
        let decoded = feishuEventSecurityDecodeBase64(encryptedPayload)
        if (decoded.size <= 16 || decoded.size % 16 != 0) {
            return FeishuEventDecryptResult(ok: false, status: "invalid_payload", error: "invalid Feishu encrypted payload length")
        }
        let keyHash = SHA256()
        keyHash.write(encryptKey.toArray())
        let plain = feishuEventSecurityAes256CbcDecrypt(
            keyHash.finish(),
            decoded[0..16],
            decoded[16..decoded.size]
        )
        FeishuEventDecryptResult(ok: true, status: "decrypted", payload: String.fromUtf8(plain))
    } catch (_e: Exception) {
        FeishuEventDecryptResult(ok: false, status: "decrypt_failed", error: "failed to decrypt Feishu encrypted event payload")
    }
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
        if (!decrypt.ok) {
            return FeishuEventSecurityValidationResult(
                ok: false,
                reason: decrypt.status,
                error: decrypt.error
            )
        }
        return feishuValidateEventSecurity(
            timestamp: timestamp,
            nonce: nonce,
            signature: signature,
            payload: decrypt.payload,
            verificationToken: verificationToken,
            encryptKey: encryptKey,
            requireSignature: requireSignature,
            maxSkewSeconds: maxSkewSeconds,
            nowSeconds: nowSeconds
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

private func feishuEventSecurityBase64Value(ch: Byte): Int64 {
    if (ch >= UInt8(65) && ch <= UInt8(90)) {
        return Int64(ch - UInt8(65))
    }
    if (ch >= UInt8(97) && ch <= UInt8(122)) {
        return Int64(ch - UInt8(97)) + 26
    }
    if (ch >= UInt8(48) && ch <= UInt8(57)) {
        return Int64(ch - UInt8(48)) + 52
    }
    if (ch == UInt8(43)) {
        return 62
    }
    if (ch == UInt8(47)) {
        return 63
    }
    -1
}

private func feishuEventSecurityDecodeBase64(data: String): Array<Byte> {
    let out = ArrayList<Byte>()
    var buffer: Int64 = 0
    var bits: Int64 = 0
    for (ch in data.toArray()) {
        if (ch == UInt8(61)) {
            break
        }
        let value = feishuEventSecurityBase64Value(ch)
        if (value < 0) {
            continue
        }
        buffer = (buffer << 6) | value
        bits += 6
        if (bits >= 8) {
            bits -= 8
            out.add(UInt8((buffer >> bits) & 255))
        }
    }
    out.toArray()
}

private let FEISHU_AES_SBOX: Array<Int64> = [
    99,124,119,123,242,107,111,197,48,1,103,43,254,215,171,118,
    202,130,201,125,250,89,71,240,173,212,162,175,156,164,114,192,
    183,253,147,38,54,63,247,204,52,165,229,241,113,216,49,21,
    4,199,35,195,24,150,5,154,7,18,128,226,235,39,178,117,
    9,131,44,26,27,110,90,160,82,59,214,179,41,227,47,132,
    83,209,0,237,32,252,177,91,106,203,190,57,74,76,88,207,
    208,239,170,251,67,77,51,133,69,249,2,127,80,60,159,168,
    81,163,64,143,146,157,56,245,188,182,218,33,16,255,243,210,
    205,12,19,236,95,151,68,23,196,167,126,61,100,93,25,115,
    96,129,79,220,34,42,144,136,70,238,184,20,222,94,11,219,
    224,50,58,10,73,6,36,92,194,211,172,98,145,149,228,121,
    231,200,55,109,141,213,78,169,108,86,244,234,101,122,174,8,
    186,120,37,46,28,166,180,198,232,221,116,31,75,189,139,138,
    112,62,181,102,72,3,246,14,97,53,87,185,134,193,29,158,
    225,248,152,17,105,217,142,148,155,30,135,233,206,85,40,223,
    140,161,137,13,191,230,66,104,65,153,45,15,176,84,187,22
]

private let FEISHU_AES_INV_SBOX: Array<Int64> = [
    82,9,106,213,48,54,165,56,191,64,163,158,129,243,215,251,
    124,227,57,130,155,47,255,135,52,142,67,68,196,222,233,203,
    84,123,148,50,166,194,35,61,238,76,149,11,66,250,195,78,
    8,46,161,102,40,217,36,178,118,91,162,73,109,139,209,37,
    114,248,246,100,134,104,152,22,212,164,92,204,93,101,182,146,
    108,112,72,80,253,237,185,218,94,21,70,87,167,141,157,132,
    144,216,171,0,140,188,211,10,247,228,88,5,184,179,69,6,
    208,44,30,143,202,63,15,2,193,175,189,3,1,19,138,107,
    58,145,17,65,79,103,220,234,151,242,207,206,240,180,230,115,
    150,172,116,34,231,173,53,133,226,249,55,232,28,117,223,110,
    71,241,26,113,29,41,197,137,111,183,98,14,170,24,190,27,
    252,86,62,75,198,210,121,32,154,219,192,254,120,205,90,244,
    31,221,168,51,136,7,199,49,177,18,16,89,39,128,236,95,
    96,81,127,169,25,181,74,13,45,229,122,159,147,201,156,239,
    160,224,59,77,174,42,245,176,200,235,187,60,131,83,153,97,
    23,43,4,126,186,119,214,38,225,105,20,99,85,33,12,125
]

private let FEISHU_AES_RCON: Array<Int64> = [
    0x00000000,0x01000000,0x02000000,0x04000000,0x08000000,0x10000000,0x20000000,0x40000000,
    0x80000000,0x1b000000,0x36000000
]

private func feishuEventSecurityAes256CbcDecrypt(key: Array<Byte>, iv: Array<Byte>, cipher: Array<Byte>): Array<Byte> {
    if (key.size != 32 || iv.size != 16 || cipher.size == 0 || cipher.size % 16 != 0) {
        throw Exception("invalid AES input")
    }
    let roundKeys = feishuEventSecurityAesKeyExpansion(key)
    var previous = iv
    let out = ArrayList<Byte>()
    var offset = 0
    while (offset < cipher.size) {
        let block = cipher[offset..offset + 16]
        let plainBlock = feishuEventSecurityAesDecryptBlock(block, roundKeys)
        for (i in 0..16) {
            out.add(UInt8(Int64(plainBlock[i]) ^ Int64(previous[i])))
        }
        previous = block
        offset += 16
    }
    let padded = out.toArray()
    if (padded.isEmpty()) {
        throw Exception("empty AES output")
    }
    let pad = Int64(padded[padded.size - 1])
    if (pad <= 0 || pad > 16 || pad > Int64(padded.size)) {
        throw Exception("invalid AES padding")
    }
    for (i in padded.size - Int64(pad)..padded.size) {
        if (Int64(padded[i]) != pad) {
            throw Exception("invalid AES padding")
        }
    }
    padded[0..padded.size - Int64(pad)]
}

private func feishuEventSecurityAesKeyExpansion(key: Array<Byte>): Array<Int64> {
    let words = Array<Int64>(60, repeat: 0)
    for (i in 0..8) {
        words[i] = (Int64(key[i * 4]) << 24) |
            (Int64(key[i * 4 + 1]) << 16) |
            (Int64(key[i * 4 + 2]) << 8) |
            Int64(key[i * 4 + 3])
    }
    for (i in 8..60) {
        var temp = words[i - 1]
        if (i % 8 == 0) {
            temp = feishuEventSecurityAesSubWord(feishuEventSecurityAesRotWord(temp)) ^ FEISHU_AES_RCON[i / 8]
        } else if (i % 8 == 4) {
            temp = feishuEventSecurityAesSubWord(temp)
        }
        words[i] = (words[i - 8] ^ temp) & 0xffffffff
    }
    words
}

private func feishuEventSecurityAesRotWord(w: Int64): Int64 {
    ((w << 8) | ((w >> 24) & 0xff)) & 0xffffffff
}

private func feishuEventSecurityAesSubWord(w: Int64): Int64 {
    (FEISHU_AES_SBOX[(w >> 24) & 0xff] << 24) |
        (FEISHU_AES_SBOX[(w >> 16) & 0xff] << 16) |
        (FEISHU_AES_SBOX[(w >> 8) & 0xff] << 8) |
        FEISHU_AES_SBOX[w & 0xff]
}

private func feishuEventSecurityAesDecryptBlock(block: Array<Byte>, roundKeys: Array<Int64>): Array<Byte> {
    let state = Array<Int64>(16, repeat: 0)
    for (i in 0..16) {
        state[i] = Int64(block[i])
    }
    feishuEventSecurityAesAddRoundKey(state, roundKeys, 14)
    for (round in 13..0:-1) {
        feishuEventSecurityAesInvShiftRows(state)
        feishuEventSecurityAesInvSubBytes(state)
        feishuEventSecurityAesAddRoundKey(state, roundKeys, round)
        feishuEventSecurityAesInvMixColumns(state)
    }
    feishuEventSecurityAesInvShiftRows(state)
    feishuEventSecurityAesInvSubBytes(state)
    feishuEventSecurityAesAddRoundKey(state, roundKeys, 0)
    let out = ArrayList<Byte>()
    for (i in 0..16) {
        out.add(UInt8(state[i] & 0xff))
    }
    out.toArray()
}

private func feishuEventSecurityAesAddRoundKey(state: Array<Int64>, roundKeys: Array<Int64>, round: Int64): Unit {
    for (c in 0..4) {
        let word = roundKeys[round * 4 + c]
        state[c * 4] = state[c * 4] ^ ((word >> 24) & 0xff)
        state[c * 4 + 1] = state[c * 4 + 1] ^ ((word >> 16) & 0xff)
        state[c * 4 + 2] = state[c * 4 + 2] ^ ((word >> 8) & 0xff)
        state[c * 4 + 3] = state[c * 4 + 3] ^ (word & 0xff)
    }
}

private func feishuEventSecurityAesInvSubBytes(state: Array<Int64>): Unit {
    for (i in 0..16) {
        state[i] = FEISHU_AES_INV_SBOX[state[i] & 0xff]
    }
}

private func feishuEventSecurityAesInvShiftRows(state: Array<Int64>): Unit {
    let copy = Array<Int64>(16, repeat: 0)
    for (i in 0..16) {
        copy[i] = state[i]
    }
    state[1] = copy[13]
    state[5] = copy[1]
    state[9] = copy[5]
    state[13] = copy[9]
    state[2] = copy[10]
    state[6] = copy[14]
    state[10] = copy[2]
    state[14] = copy[6]
    state[3] = copy[7]
    state[7] = copy[11]
    state[11] = copy[15]
    state[15] = copy[3]
}

private func feishuEventSecurityAesInvMixColumns(state: Array<Int64>): Unit {
    for (c in 0..4) {
        let i = c * 4
        let a0 = state[i]
        let a1 = state[i + 1]
        let a2 = state[i + 2]
        let a3 = state[i + 3]
        state[i] = feishuEventSecurityAesMul(a0, 14) ^ feishuEventSecurityAesMul(a1, 11) ^ feishuEventSecurityAesMul(a2, 13) ^ feishuEventSecurityAesMul(a3, 9)
        state[i + 1] = feishuEventSecurityAesMul(a0, 9) ^ feishuEventSecurityAesMul(a1, 14) ^ feishuEventSecurityAesMul(a2, 11) ^ feishuEventSecurityAesMul(a3, 13)
        state[i + 2] = feishuEventSecurityAesMul(a0, 13) ^ feishuEventSecurityAesMul(a1, 9) ^ feishuEventSecurityAesMul(a2, 14) ^ feishuEventSecurityAesMul(a3, 11)
        state[i + 3] = feishuEventSecurityAesMul(a0, 11) ^ feishuEventSecurityAesMul(a1, 13) ^ feishuEventSecurityAesMul(a2, 9) ^ feishuEventSecurityAesMul(a3, 14)
    }
}

private func feishuEventSecurityAesMul(a: Int64, b: Int64): Int64 {
    var aa = a & 0xff
    var bb = b
    var result: Int64 = 0
    while (bb > 0) {
        if ((bb & 1) != 0) {
            result = result ^ aa
        }
        let high = aa & 0x80
        aa = (aa << 1) & 0xff
        if (high != 0) {
            aa = aa ^ 0x1b
        }
        bb = bb >> 1
    }
    result & 0xff
}
