package metis.gateway.channels.feishu

import std.collection.{ArrayList, HashMap}
import std.convert.Parsable
import std.time.*
import stdx.encoding.json.{JsonArray, JsonInt, JsonObject, JsonString, JsonValue}
import stdx.encoding.url.URL
import stdx.net.http.*
import stdx.net.tls.*

public class FeishuLongConnectStartSpec {
    public let accountId: String
    public let appId: String
    public let appSecret: String
    public let domain: String
    public let verificationToken: String
    public let encryptKey: String

    public init(
        accountId!: String = "",
        appId!: String = "",
        appSecret!: String = "",
        domain!: String = "",
        verificationToken!: String = "",
        encryptKey!: String = ""
    ) {
        this.accountId = accountId.trimAscii()
        this.appId = appId.trimAscii()
        this.appSecret = appSecret
        this.domain = domain.trimAscii()
        this.verificationToken = verificationToken
        this.encryptKey = encryptKey
    }
}

public class FeishuLongConnectStartResult {
    public let ok: Bool
    public let status: String
    public let error: String

    public init(ok!: Bool = false, status!: String = "not_started", error!: String = "") {
        this.ok = ok
        this.status = if (status.trimAscii().isEmpty()) { if (ok) { "started" } else { "failed" } } else { status.trimAscii() }
        this.error = error.trimAscii()
    }
}

public interface FeishuLongConnectTransport {
    func start(spec: FeishuLongConnectStartSpec, eventHandler: (JsonObject) -> Unit): FeishuLongConnectStartResult
    func stop(): Unit
}

public class FeishuLongConnectFrameHeader {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        this.key = key
        this.value = value
    }
}

public class FeishuLongConnectFrame {
    public let seqId: Int64
    public let logId: Int64
    public let service: Int64
    public let method: Int64
    public let headers: Array<FeishuLongConnectFrameHeader>
    public let payloadEncoding: String
    public let payloadType: String
    public let payload: Array<Byte>
    public let logIdNew: String

    public init(
        seqId!: Int64 = 0,
        logId!: Int64 = 0,
        service!: Int64 = 0,
        method!: Int64 = 0,
        headers!: Array<FeishuLongConnectFrameHeader> = [],
        payloadEncoding!: String = "",
        payloadType!: String = "",
        payload!: Array<Byte> = [],
        logIdNew!: String = ""
    ) {
        this.seqId = seqId
        this.logId = logId
        this.service = service
        this.method = method
        this.headers = headers
        this.payloadEncoding = payloadEncoding
        this.payloadType = payloadType
        this.payload = payload
        this.logIdNew = logIdNew
    }

    public func headerValue(key: String): String {
        for (header in this.headers) {
            if (header.key == key) {
                return header.value
            }
        }
        ""
    }
}

public class FeishuLongConnectFrameHandleResult {
    public let eventRoots: Array<JsonObject>
    public let responseFrames: Array<FeishuLongConnectFrame>
    public let status: String

    public init(
        eventRoots!: Array<JsonObject> = [],
        responseFrames!: Array<FeishuLongConnectFrame> = [],
        status!: String = "ignored"
    ) {
        this.eventRoots = eventRoots
        this.responseFrames = responseFrames
        this.status = status
    }
}

private class FeishuLongConnectFragmentBuffer {
    public let total: Int64
    public let traceId: String
    private let parts = HashMap<Int64, Array<Byte>>()

    public init(total: Int64, traceId: String) {
        this.total = total
        this.traceId = traceId
    }

    public func put(seq: Int64, data: Array<Byte>): Unit {
        this.parts[seq] = data
    }

    public func complete(): Bool {
        if (this.total <= 0) {
            return false
        }
        for (i in 0..this.total) {
            if (!this.parts.contains(i)) {
                return false
            }
        }
        true
    }

    public func merge(): Array<Byte> {
        let out = ArrayList<Byte>()
        for (i in 0..this.total) {
            out.add(all: this.parts[i])
        }
        out.toArray()
    }
}

public class FeishuLongConnectFrameSession {
    private let fragments = HashMap<String, FeishuLongConnectFragmentBuffer>()

    public init() {}

    public func handleBytes(bytes: Array<Byte>): FeishuLongConnectFrameHandleResult {
        let frame = feishuLongConnectDecodeFrame(bytes)
        this.handleFrame(frame)
    }

    public func handleFrame(frame: FeishuLongConnectFrame): FeishuLongConnectFrameHandleResult {
        if (frame.method == 0) {
            return this.handleControlFrame(frame)
        }
        if (frame.method != 1) {
            return FeishuLongConnectFrameHandleResult(status: "ignored_method")
        }
        if (frame.headerValue("type") != "event") {
            return FeishuLongConnectFrameHandleResult(status: "ignored_type")
        }
        let payload = this.mergePayload(frame)
        if (payload.isNone()) {
            return FeishuLongConnectFrameHandleResult(status: "fragment_pending")
        }
        let root = JsonValue.fromStr(String.fromUtf8(payload.getOrThrow())).asObject()
        let response = this.responseFrame(frame, 200)
        FeishuLongConnectFrameHandleResult(eventRoots: [root], responseFrames: [response], status: "event")
    }

    private func handleControlFrame(frame: FeishuLongConnectFrame): FeishuLongConnectFrameHandleResult {
        if (frame.headerValue("type") == "ping") {
            let response = FeishuLongConnectFrame(
                seqId: frame.seqId,
                logId: frame.logId,
                service: frame.service,
                method: 0,
                headers: [FeishuLongConnectFrameHeader("type", "pong")],
                payload: "{}".toArray(),
                logIdNew: frame.logIdNew
            )
            return FeishuLongConnectFrameHandleResult(responseFrames: [response], status: "pong")
        }
        FeishuLongConnectFrameHandleResult(status: "control_ignored")
    }

    private func mergePayload(frame: FeishuLongConnectFrame): Option<Array<Byte>> {
        let sum = feishuLongConnectParseInt(frame.headerValue("sum"), defaultValue: 1)
        let seq = feishuLongConnectParseInt(frame.headerValue("seq"), defaultValue: 0)
        let messageId = frame.headerValue("message_id")
        if (sum <= 1 || messageId.isEmpty()) {
            return Some(frame.payload)
        }
        let buffer = match (this.fragments.get(messageId)) {
            case Some(v) => v
            case None =>
                let created = FeishuLongConnectFragmentBuffer(sum, frame.headerValue("trace_id"))
                this.fragments[messageId] = created
                created
        }
        buffer.put(seq, frame.payload)
        if (!buffer.complete()) {
            return None<Array<Byte>>
        }
        let merged = buffer.merge()
        this.fragments.remove(messageId)
        Some(merged)
    }

    private func responseFrame(frame: FeishuLongConnectFrame, code: Int64): FeishuLongConnectFrame {
        let headers = ArrayList<FeishuLongConnectFrameHeader>()
        for (header in frame.headers) {
            headers.add(header)
        }
        headers.add(FeishuLongConnectFrameHeader("biz_rt", "0"))
        FeishuLongConnectFrame(
            seqId: frame.seqId,
            logId: frame.logId,
            service: frame.service,
            method: frame.method,
            headers: headers.toArray(),
            payloadEncoding: frame.payloadEncoding,
            payloadType: frame.payloadType,
            payload: "{\"code\":${code}}".toArray(),
            logIdNew: frame.logIdNew
        )
    }
}

public class FeishuNativeLongConnectTransport <: FeishuLongConnectTransport {
    private var running = false
    private var generation: Int64 = 0

    public init() {}

    public func start(spec: FeishuLongConnectStartSpec, eventHandler: (JsonObject) -> Unit): FeishuLongConnectStartResult {
        if (spec.appId.trimAscii().isEmpty() || spec.appSecret.trimAscii().isEmpty()) {
            return FeishuLongConnectStartResult(ok: false, status: "invalid_config", error: "Feishu appId/appSecret are required")
        }
        this.running = true
        this.generation += 1
        let current = this.generation
        spawn {
            this.runLoop(spec, eventHandler, current)
        }
        return FeishuLongConnectStartResult(ok: true, status: "started")
    }

    public func stop(): Unit {
        this.running = false
        this.generation += 1
    }

    private func runLoop(spec: FeishuLongConnectStartSpec, eventHandler: (JsonObject) -> Unit, generation: Int64): Unit {
        var reconnectDelayMs: Int64 = 3000
        while (this.running && this.generation == generation) {
            try {
                let endpoint = this.pullEndpoint(spec)
                reconnectDelayMs = endpoint.reconnectIntervalMs
                this.connectAndServe(endpoint, eventHandler, generation)
            } catch (_e: Exception) {
                ()
            }
            if (this.running && this.generation == generation) {
                sleep(Duration.millisecond * reconnectDelayMs)
            }
        }
    }

    private func pullEndpoint(spec: FeishuLongConnectStartSpec): FeishuLongConnectEndpoint {
        let domain = feishuLongConnectNormalizeDomain(spec.domain)
        let url = "${domain}/callback/ws/endpoint"
        let body = JsonObject()
        body.put("AppID", JsonString(spec.appId.trimAscii()))
        body.put("AppSecret", JsonString(spec.appSecret))

        let builder = ClientBuilder()
        builder.readTimeout(Duration.second * 15)
        if (url.startsWith("https")) {
            var tlsConfig = TlsClientConfig()
            tlsConfig.domain = URL.parse(url).hostName
            tlsConfig.alpnProtocolsList = ["http/1.1"]
            builder.tlsConfig(tlsConfig)
        }
        let client = builder.build()
        try {
            let req = HttpRequestBuilder()
                .url(url)
                .post()
                .header("Content-Type", "application/json")
                .header("locale", "zh")
                .body(body.toJsonString())
                .build()
            let response = client.send(req)
            let responseBody = String.fromUtf8(feishuLongConnectReadAllBytes(response))
            if (response.status < 200 || response.status >= 300) {
                throw Exception("Feishu long-connect endpoint returned HTTP ${Int64(response.status)}")
            }
            let root = JsonValue.fromStr(responseBody).asObject()
            let code = feishuLongConnectJsonInt(root, "code", defaultValue: 0)
            if (code != 0) {
                throw Exception("Feishu long-connect endpoint returned code ${code}")
            }
            let data = feishuLongConnectJsonObject(root, "data")
            let config = feishuLongConnectJsonObject(data, "ClientConfig")
            FeishuLongConnectEndpoint(
                url: feishuLongConnectJsonString(data, "URL"),
                pingIntervalMs: feishuLongConnectJsonInt(config, "PingInterval", defaultValue: 120) * 1000,
                reconnectCount: feishuLongConnectJsonInt(config, "ReconnectCount", defaultValue: -1),
                reconnectIntervalMs: feishuLongConnectJsonInt(config, "ReconnectInterval", defaultValue: 120) * 1000,
                reconnectNonceMs: feishuLongConnectJsonInt(config, "ReconnectNonce", defaultValue: 30) * 1000
            )
        } finally {
            client.close()
        }
    }

    private func connectAndServe(endpoint: FeishuLongConnectEndpoint, eventHandler: (JsonObject) -> Unit, generation: Int64): Unit {
        if (endpoint.url.trimAscii().isEmpty()) {
            throw Exception("Feishu long-connect endpoint URL is empty")
        }
        let builder = ClientBuilder()
        builder.readTimeout(Duration.second * 180)
        if (endpoint.url.startsWith("wss://") || endpoint.url.startsWith("https://")) {
            var tlsConfig = TlsClientConfig()
            tlsConfig.domain = URL.parse(endpoint.url).hostName
            tlsConfig.alpnProtocolsList = ["http/1.1"]
            builder.tlsConfig(tlsConfig)
        }
        let client = builder.build()
        let websocket: WebSocket
        let _headers: HttpHeaders
        try {
            (websocket, _headers) = WebSocket.upgradeFromClient(client, URL.parse(endpoint.url))
        } finally {
            client.close()
        }
        let session = FeishuLongConnectFrameSession()
        let pingGeneration = generation
        spawn {
            this.pingLoop(websocket, endpoint, pingGeneration)
        }
        try {
            while (this.running && this.generation == generation) {
                let frame = websocket.read()
                if (frame.frameType == CloseWebFrame) {
                    break
                }
                if (frame.frameType == PingWebFrame) {
                    websocket.writePongFrame(frame.payload)
                    continue
                }
                if (frame.frameType != BinaryWebFrame) {
                    continue
                }
                let result = session.handleBytes(frame.payload)
                for (eventRoot in result.eventRoots) {
                    eventHandler(eventRoot)
                }
                for (response in result.responseFrames) {
                    websocket.write(BinaryWebFrame, feishuLongConnectEncodeFrame(response))
                }
            }
        } finally {
            try { websocket.closeConn() } catch (_e: Exception) { () }
        }
    }

    private func pingLoop(websocket: WebSocket, endpoint: FeishuLongConnectEndpoint, generation: Int64): Unit {
        let parsed = feishuLongConnectQueryParams(endpoint.url)
        let serviceId = match (parsed.get("service_id")) {
            case Some(v) => feishuLongConnectParseInt(v, defaultValue: 0)
            case None => 0
        }
        while (this.running && this.generation == generation) {
            let ping = FeishuLongConnectFrame(
                service: serviceId,
                method: 0,
                headers: [FeishuLongConnectFrameHeader("type", "ping")]
            )
            try {
                websocket.write(BinaryWebFrame, feishuLongConnectEncodeFrame(ping))
            } catch (_e: Exception) {
                break
            }
            sleep(Duration.millisecond * endpoint.pingIntervalMs)
        }
    }
}

private class FeishuLongConnectEndpoint {
    public let url: String
    public let pingIntervalMs: Int64
    public let reconnectCount: Int64
    public let reconnectIntervalMs: Int64
    public let reconnectNonceMs: Int64

    public init(
        url!: String,
        pingIntervalMs!: Int64 = 120000,
        reconnectCount!: Int64 = -1,
        reconnectIntervalMs!: Int64 = 120000,
        reconnectNonceMs!: Int64 = 30000
    ) {
        this.url = url.trimAscii()
        this.pingIntervalMs = if (pingIntervalMs <= 0) { 120000 } else { pingIntervalMs }
        this.reconnectCount = reconnectCount
        this.reconnectIntervalMs = if (reconnectIntervalMs <= 0) { 120000 } else { reconnectIntervalMs }
        this.reconnectNonceMs = if (reconnectNonceMs < 0) { 0 } else { reconnectNonceMs }
    }
}

public func feishuLongConnectEncodeFrame(frame: FeishuLongConnectFrame): Array<Byte> {
    let out = ArrayList<Byte>()
    feishuLongConnectWriteFieldVarint(out, 1, frame.seqId)
    feishuLongConnectWriteFieldVarint(out, 2, frame.logId)
    feishuLongConnectWriteFieldVarint(out, 3, frame.service)
    feishuLongConnectWriteFieldVarint(out, 4, frame.method)
    for (header in frame.headers) {
        let encodedHeader = feishuLongConnectEncodeHeader(header)
        feishuLongConnectWriteFieldBytes(out, 5, encodedHeader)
    }
    if (!frame.payloadEncoding.isEmpty()) {
        feishuLongConnectWriteFieldString(out, 6, frame.payloadEncoding)
    }
    if (!frame.payloadType.isEmpty()) {
        feishuLongConnectWriteFieldString(out, 7, frame.payloadType)
    }
    if (!frame.payload.isEmpty()) {
        feishuLongConnectWriteFieldBytes(out, 8, frame.payload)
    }
    if (!frame.logIdNew.isEmpty()) {
        feishuLongConnectWriteFieldString(out, 9, frame.logIdNew)
    }
    out.toArray()
}

public func feishuLongConnectDecodeFrame(bytes: Array<Byte>): FeishuLongConnectFrame {
    var cursor: Int64 = 0
    var seqId: Int64 = 0
    var logId: Int64 = 0
    var service: Int64 = 0
    var method: Int64 = 0
    let headers = ArrayList<FeishuLongConnectFrameHeader>()
    var payloadEncoding = ""
    var payloadType = ""
    var payload: Array<Byte> = []
    var logIdNew = ""
    while (cursor < bytes.size) {
        let tagResult = feishuLongConnectReadVarint(bytes, cursor)
        let tag = tagResult.value
        cursor = tagResult.next
        let field = tag >> 3
        let wire = tag & 7
        if (field == 1) {
            let v = feishuLongConnectReadVarint(bytes, cursor)
            seqId = v.value
            cursor = v.next
        } else if (field == 2) {
            let v = feishuLongConnectReadVarint(bytes, cursor)
            logId = v.value
            cursor = v.next
        } else if (field == 3) {
            let v = feishuLongConnectReadVarint(bytes, cursor)
            service = v.value
            cursor = v.next
        } else if (field == 4) {
            let v = feishuLongConnectReadVarint(bytes, cursor)
            method = v.value
            cursor = v.next
        } else if (field == 5 && wire == 2) {
            let fieldBytes = feishuLongConnectReadLengthDelimited(bytes, cursor)
            cursor = fieldBytes.next
            headers.add(feishuLongConnectDecodeHeader(fieldBytes.bytes))
        } else if (field == 6 && wire == 2) {
            let fieldBytes = feishuLongConnectReadLengthDelimited(bytes, cursor)
            cursor = fieldBytes.next
            payloadEncoding = String.fromUtf8(fieldBytes.bytes)
        } else if (field == 7 && wire == 2) {
            let fieldBytes = feishuLongConnectReadLengthDelimited(bytes, cursor)
            cursor = fieldBytes.next
            payloadType = String.fromUtf8(fieldBytes.bytes)
        } else if (field == 8 && wire == 2) {
            let fieldBytes = feishuLongConnectReadLengthDelimited(bytes, cursor)
            cursor = fieldBytes.next
            payload = fieldBytes.bytes
        } else if (field == 9 && wire == 2) {
            let fieldBytes = feishuLongConnectReadLengthDelimited(bytes, cursor)
            cursor = fieldBytes.next
            logIdNew = String.fromUtf8(fieldBytes.bytes)
        } else {
            cursor = feishuLongConnectSkipField(bytes, cursor, wire)
        }
    }
    FeishuLongConnectFrame(
        seqId: seqId,
        logId: logId,
        service: service,
        method: method,
        headers: headers.toArray(),
        payloadEncoding: payloadEncoding,
        payloadType: payloadType,
        payload: payload,
        logIdNew: logIdNew
    )
}

private func feishuLongConnectEncodeHeader(header: FeishuLongConnectFrameHeader): Array<Byte> {
    let out = ArrayList<Byte>()
    feishuLongConnectWriteFieldString(out, 1, header.key)
    feishuLongConnectWriteFieldString(out, 2, header.value)
    out.toArray()
}

private func feishuLongConnectDecodeHeader(bytes: Array<Byte>): FeishuLongConnectFrameHeader {
    var cursor: Int64 = 0
    var key = ""
    var value = ""
    while (cursor < bytes.size) {
        let tagResult = feishuLongConnectReadVarint(bytes, cursor)
        let tag = tagResult.value
        cursor = tagResult.next
        let field = tag >> 3
        let wire = tag & 7
        if (field == 1 && wire == 2) {
            let fieldBytes = feishuLongConnectReadLengthDelimited(bytes, cursor)
            cursor = fieldBytes.next
            key = String.fromUtf8(fieldBytes.bytes)
        } else if (field == 2 && wire == 2) {
            let fieldBytes = feishuLongConnectReadLengthDelimited(bytes, cursor)
            cursor = fieldBytes.next
            value = String.fromUtf8(fieldBytes.bytes)
        } else {
            cursor = feishuLongConnectSkipField(bytes, cursor, wire)
        }
    }
    FeishuLongConnectFrameHeader(key, value)
}

private class FeishuLongConnectVarintResult {
    public let value: Int64
    public let next: Int64
    public init(value: Int64, next: Int64) {
        this.value = value
        this.next = next
    }
}

private class FeishuLongConnectBytesResult {
    public let bytes: Array<Byte>
    public let next: Int64
    public init(bytes: Array<Byte>, next: Int64) {
        this.bytes = bytes
        this.next = next
    }
}

private func feishuLongConnectWriteFieldVarint(out: ArrayList<Byte>, field: Int64, value: Int64): Unit {
    feishuLongConnectWriteVarint(out, (field << 3) | 0)
    feishuLongConnectWriteVarint(out, value)
}

private func feishuLongConnectWriteFieldString(out: ArrayList<Byte>, field: Int64, value: String): Unit {
    feishuLongConnectWriteFieldBytes(out, field, value.toArray())
}

private func feishuLongConnectWriteFieldBytes(out: ArrayList<Byte>, field: Int64, bytes: Array<Byte>): Unit {
    feishuLongConnectWriteVarint(out, (field << 3) | 2)
    feishuLongConnectWriteVarint(out, bytes.size)
    out.add(all: bytes)
}

private func feishuLongConnectWriteVarint(out: ArrayList<Byte>, value: Int64): Unit {
    var v = value
    while (v >= 128) {
        out.add(UInt8((v & 0x7f) | 0x80))
        v = v >> 7
    }
    out.add(UInt8(v & 0x7f))
}

private func feishuLongConnectReadVarint(bytes: Array<Byte>, start: Int64): FeishuLongConnectVarintResult {
    var shift: Int64 = 0
    var value: Int64 = 0
    var cursor = start
    while (cursor < bytes.size) {
        let b = Int64(bytes[cursor])
        value = value | ((b & 0x7f) << shift)
        cursor += 1
        if ((b & 0x80) == 0) {
            return FeishuLongConnectVarintResult(value, cursor)
        }
        shift += 7
        if (shift > 63) {
            throw Exception("invalid Feishu long-connect varint")
        }
    }
    throw Exception("truncated Feishu long-connect varint")
}

private func feishuLongConnectReadLengthDelimited(bytes: Array<Byte>, start: Int64): FeishuLongConnectBytesResult {
    let lenResult = feishuLongConnectReadVarint(bytes, start)
    let end = lenResult.next + lenResult.value
    if (lenResult.value < 0 || end > bytes.size) {
        throw Exception("invalid Feishu long-connect length-delimited field")
    }
    FeishuLongConnectBytesResult(bytes[lenResult.next..end], end)
}

private func feishuLongConnectSkipField(bytes: Array<Byte>, start: Int64, wire: Int64): Int64 {
    if (wire == 0) {
        return feishuLongConnectReadVarint(bytes, start).next
    }
    if (wire == 2) {
        return feishuLongConnectReadLengthDelimited(bytes, start).next
    }
    throw Exception("unsupported Feishu long-connect protobuf wire type")
}

private func feishuLongConnectNormalizeDomain(domain: String): String {
    var d = domain.trimAscii()
    if (d.isEmpty()) {
        d = "https://open.feishu.cn"
    }
    while (d.endsWith("/")) {
        d = d[0..d.size - 1]
    }
    d
}

private func feishuLongConnectReadAllBytes(response: HttpResponse): Array<Byte> {
    let out = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let n = response.body.read(buffer)
        if (n <= 0) {
            break
        }
        out.add(all: buffer[..n])
    }
    out.toArray()
}

private func feishuLongConnectJsonObject(root: JsonObject, key: String): JsonObject {
    match (root.get(key)) {
        case Some(v) => try { v.asObject() } catch (_e: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func feishuLongConnectJsonString(root: JsonObject, key: String): String {
    match (root.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_e: Exception) { "" }
        case None => ""
    }
}

private func feishuLongConnectJsonInt(root: JsonObject, key: String, defaultValue!: Int64 = 0): Int64 {
    match (root.get(key)) {
        case Some(v) =>
            match (v) {
                case i: JsonInt => i.getValue()
                case s: JsonString => try { Int64.parse(s.getValue().trimAscii()) } catch (_e: Exception) { defaultValue }
                case _ => defaultValue
            }
        case None => defaultValue
    }
}

private func feishuLongConnectParseInt(value: String, defaultValue!: Int64 = 0): Int64 {
    try { Int64.parse(value.trimAscii()) } catch (_e: Exception) { defaultValue }
}

private func feishuLongConnectQueryParams(url: String): HashMap<String, String> {
    let out = HashMap<String, String>()
    let question = url.indexOf("?")
    if (question.isNone()) {
        return out
    }
    let query = url[question.getOrThrow() + 1..url.size]
    for (part in query.split("&")) {
        let eq = part.indexOf("=")
        if (eq.isSome()) {
            out[part[0..eq.getOrThrow()]] = part[eq.getOrThrow() + 1..part.size]
        }
    }
    out
}
