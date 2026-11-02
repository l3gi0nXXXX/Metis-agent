package metis.gateway.channels.qq

import magic.config.Config
import metis.core.config.CliConfig
import metis.gateway.logging.gatewayLoggingResetForTest
import metis.gateway.model.QQConfig
import metis.process.{ProcessFdSnapshot, captureCurrentProcessFdSnapshot}
import std.collection.ArrayList
import std.env.{getVariable, removeVariable, setVariable}
import std.fs.{Directory, Path, exists, remove}
import std.net.*
import std.sync.*
import std.time.*
import std.unittest.*
import stdx.crypto.digest.SHA1
import stdx.encoding.base64.toBase64String
import stdx.encoding.json.JsonValue

private class ResourceQqPeer {
    let listener = TcpServerSocket(bindAt: 0u16)
    let upgraded = AtomicBool(false)
    let handshakeRequested = AtomicBool(false)
    let peerClosed = AtomicInt64(0)
    let peerEof = AtomicInt64(0)
    let observedFrames = AtomicInt64(0)
    let identifyFrames = AtomicInt64(0)
    let payloads: Array<Array<Byte>>
    let rejectUpgrade: Bool
    let closeFrame: Bool
    let binaryPrefix: Bool
    let holdUpgrade: Bool
    let dropOnIdentify: Bool
    let observeIdentify: Bool

    init(payloads: Array<Array<Byte>>, rejectUpgrade!: Bool = false, closeFrame!: Bool = false, binaryPrefix!: Bool = false, holdUpgrade!: Bool = false, dropOnIdentify!: Bool = false, observeIdentify!: Bool = false) {
        this.payloads = payloads
        this.rejectUpgrade = rejectUpgrade
        this.closeFrame = closeFrame
        this.binaryPrefix = binaryPrefix
        this.holdUpgrade = holdUpgrade
        this.dropOnIdentify = dropOnIdentify
        this.observeIdentify = observeIdentify
        this.listener.bind()
    }

    prop port: UInt16 {
        get() { (this.listener.localAddress as IPSocketAddress)?.port ?? 0u16 }
    }

    func serve(): Unit {
        try (peer = this.listener.accept(timeout: Some(Duration.second * 3))) {
            peer.readTimeout = Some(Duration.second * 3)
            let bytes = ArrayList<Byte>()
            let one = Array<Byte>(1, repeat: 0)
            while (bytes.size < 8192) {
                if (peer.read(one) == 0) { return }
                bytes.add(one[0])
                let n = bytes.size
                if (n >= 4 && bytes[n - 4] == 13 && bytes[n - 3] == 10 && bytes[n - 2] == 13 && bytes[n - 1] == 10) { break }
            }
            let request = try { String.fromUtf8(bytes.toArray()) } catch (_: Exception) { "" }
            this.handshakeRequested.store(true)
            if (this.holdUpgrade) {
                ()
            } else if (this.rejectUpgrade) {
                peer.write("HTTP/1.1 500 Bad Gateway\r\nContent-Length: 0\r\n\r\n".toArray())
            } else {
                var key = ""
                for (line in request.split("\r\n")) {
                    if (line.toAsciiLower().startsWith("sec-websocket-key:")) {
                        key = line.replace("Sec-WebSocket-Key:", "").replace("sec-websocket-key:", "").trimAscii()
                    }
                }
                let digest = SHA1()
                digest.write((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").toArray())
                let accept = toBase64String(digest.finish())
                peer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n").toArray())
                this.upgraded.store(true)
                if (this.binaryPrefix) { peer.write([130u8, 2u8, 255u8, 0u8]) }
                for (payload in this.payloads) {
                    if (payload.size <= 125) {
                        peer.write([129u8, UInt8(payload.size)])
                    } else {
                        peer.write([129u8, 126u8, UInt8(payload.size / 256), UInt8(payload.size % 256)])
                    }
                    peer.write(payload)
                }
                if (this.closeFrame) { peer.write([136u8, 2u8, 3u8, 232u8]) }
            }
            if (this.observeIdentify) {
                let header = resourceQqReadExact(peer, 2)
                if (header[0] != 129 || (header[1] & 128) == 0) {
                    throw Exception("qq_positive_identify_invalid_frame")
                }
                var size = Int64(header[1] & 127)
                if (size == 126) {
                    let extended = resourceQqReadExact(peer, 2)
                    size = Int64(extended[0]) * 256 + Int64(extended[1])
                } else if (size == 127) { throw Exception("qq_positive_identify_oversize") }
                if (size <= 0 || size > 8192) { throw Exception("qq_positive_identify_oversize") }
                let mask = resourceQqReadExact(peer, 4)
                let payload = resourceQqReadExact(peer, size)
                for (index in 0..size) { payload[index] = payload[index] ^ mask[index % 4] }
                let text = try { String.fromUtf8(payload) }
                    catch (_: Exception) { throw Exception("qq_positive_identify_invalid_encoding") }
                let root = try { JsonValue.fromStr(text).asObject() }
                    catch (_: Exception) { throw Exception("qq_positive_identify_malformed_json") }
                if (root.get("op").map({ value => value.toJsonString() }) != Some("2")) {
                    throw Exception("qq_positive_identify_wrong_operation")
                }
                this.identifyFrames.fetchAdd(1)
                this.observedFrames.fetchAdd(1)
            }
            if (this.dropOnIdentify) {
                let prefix = Array<Byte>(8, repeat: 0)
                let n = peer.read(prefix)
                if (n > 0) { this.observedFrames.fetchAdd(1) }
                // Closing with a partially unread IDENTIFY produces a native write failure.
                return
            }
            let buffer = Array<Byte>(65536, repeat: 0)
            try {
                while (true) {
                    let n = peer.read(buffer)
                    if (n == 0) {
                        this.peerEof.fetchAdd(1)
                        this.peerClosed.fetchAdd(1)
                        break
                    }
                    this.observedFrames.fetchAdd(1)
                }
            } catch (_: SocketTimeoutException) {
                // A stalled connection is a failure, not successful cleanup.
            } catch (_: SocketException) {
                this.peerClosed.fetchAdd(1)
            }
        }
    }

    func close(): Unit { this.listener.close() }
}

private func resourceQqReadExact(peer: TcpSocket, size: Int64): Array<Byte> {
    if (size <= 0 || size > 8192) { throw Exception("qq_positive_identify_read_bound") }
    let bytes = Array<Byte>(size, repeat: 0)
    let one = Array<Byte>(1, repeat: 0)
    for (index in 0..size) {
        if (peer.read(one) != 1) { throw Exception("qq_positive_identify_truncated") }
        bytes[index] = one[0]
    }
    bytes
}

private func resourceQqAdapter(peer: ResourceQqPeer): QQAdapter {
    let adapter = QQAdapter(config: QQConfig(enabled: true, appId: "fixture-app", appSecret: "syntheticsecret", officialWebsocketUrl: "ws://127.0.0.1:${peer.port}/resource"))
    adapter.debugCacheOfficialTokenForTest("resource-fixture-token")
    adapter
}

private func resourceAwaitQqUpgrade(peer: ResourceQqPeer): Unit {
    let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 2000
    while (!peer.upgraded.load() && DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
        sleep(Duration.millisecond)
    }
    @Expect(peer.upgraded.load(), true)
}

private func resourceQqFailedConnection(payloads: Array<Array<Byte>>, expected: String, rejectUpgrade!: Bool = false, closeFrame!: Bool = false, binaryPrefix!: Bool = false, expectOutbound!: Bool = false): Unit {
    let peer = ResourceQqPeer(payloads, rejectUpgrade: rejectUpgrade, closeFrame: closeFrame, binaryPrefix: binaryPrefix)
    let serving = spawn { peer.serve() }
    let adapter = resourceQqAdapter(peer)
    try {
        adapter.start()
        serving.get(Duration.second * 4)
        @Expect(peer.peerClosed.load(), 1)
        if (expectOutbound) { @Expect(peer.observedFrames.load() > 0, true) }
        adapter.stop()
        @Expect(adapter.debugOfficialWorkersForTest(), 0)
        let error = adapter.debugLastSendErrorForTest()
        if (!expected.isEmpty()) { @Expect(error.contains(expected), true) }
        @Expect(error.contains("syntheticsecret"), false)
    } finally {
        adapter.stop()
        peer.close()
        try { serving.get(Duration.second) } catch (_: Exception) { () }
    }
}

private class ResourceQqPositiveOwnership {
    public var settled: Bool = true
}

private func resourceQqOwnedLogHome(block: (ResourceQqPositiveOwnership) -> Unit): Unit {
    let home = Path("/tmp/metis-qq-positive-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    if (exists(home)) { throw Exception("qq_positive_home_exists") }
    let names = ["METIS_HOME", "METIS_LOG_FILE", "METIS_LOG_LEVEL", "METIS_CONSOLE_LEVEL"]
    let previous = Array<Option<String>>(names.size, { index => getVariable(names[index]) })
    let previousLogFile = Config.logFile
    let ownership = ResourceQqPositiveOwnership()
    Directory.create(home)
    try {
        setVariable("METIS_HOME", home.toString())
        setVariable("METIS_LOG_FILE", home.join("diagnostic.log").toString())
        setVariable("METIS_LOG_LEVEL", "info")
        setVariable("METIS_CONSOLE_LEVEL", "off")
        CliConfig.invalidatePathCache()
        gatewayLoggingResetForTest()
        block(ownership)
    } finally {
        gatewayLoggingResetForTest()
        for (index in 0..names.size) {
            match (previous[index]) {
                case Some(value) => setVariable(names[index], value)
                case None => removeVariable(names[index])
            }
        }
        CliConfig.invalidatePathCache()
        Config.logFile = previousLogFile
        if (ownership.settled) { remove(home, recursive: true) }
        @Expect(ownership.settled, true)
        @Expect(exists(home), false)
    }
}

// A positive business cycle must complete before any finally fallback cleanup.
private func resourceQqSuccessfulBusinessRound(ownership: ResourceQqPositiveOwnership, round: Int64): Unit {
    let messageId = "qq-positive-${round}"
    let text = "positive ${round} 中文😀"
    let peer = ResourceQqPeer([
        "{\"op\":10,\"d\":{\"heartbeat_interval\":60000}}".toArray(),
        ("{\"op\":0,\"t\":\"C2C_MESSAGE_CREATE\",\"d\":{\"id\":\"${messageId}\",\"user_openid\":\"fixture-peer\",\"content\":\"${text}\"}}").toArray()
    ], observeIdentify: true)
    let port = peer.port
    let adapter = resourceQqAdapter(peer)
    let serving = spawn { peer.serve() }
    ownership.settled = false
    try {
        adapter.start()
        let deadline = MonoTime.now() + Duration.second * 2
        var received: Int64 = 0
        while (MonoTime.now() < deadline && (received == 0 || peer.identifyFrames.load() == 0)) {
            let incoming = adapter.pullInbound()
            for (message in incoming) {
                if (message.messageId != messageId || message.text != text || message.peerId != "user:fixture-peer") {
                    throw Exception("qq_positive_business_mismatch")
                }
                received += 1
            }
            sleep(Duration.millisecond * 10)
        }
        if (received != 1 || !peer.upgraded.load() || peer.identifyFrames.load() != 1 ||
            !adapter.pullInbound().isEmpty()) { throw Exception("qq_positive_business_incomplete") }
        adapter.stop()
        serving.get(Duration.second * 2)
        if (adapter.debugOfficialWorkersForTest() != 0 || peer.peerClosed.load() != 1 || peer.peerEof.load() != 1) {
            throw Exception("qq_positive_formal_cleanup_incomplete")
        }
        peer.close()
        // Rebinding the exact owned loopback port proves that listener ownership ended.
        let portProbe = TcpServerSocket(bindAt: port)
        try { portProbe.bind() } finally { portProbe.close() }
    } finally {
        adapter.stop()
        peer.close()
        let peerJoined = try {
            serving.get(Duration.second)
            true
        } catch (_: Exception) { false }
        ownership.settled = peerJoined && adapter.debugOfficialWorkersForTest() == 0
        @Expect(ownership.settled, true)
    }
}

private func resourceQqPrintClassifiedFd(round: Int64, sample: ProcessFdSnapshot): Unit {
    println("QQ_POSITIVE_FD round=${round} status=${sample.status} total=${sample.fdCount} limit=${sample.fdLimit} " +
        "vnode=${sample.vnodeCount} socket=${sample.socketCount} pipe=${sample.pipeCount} other=${sample.otherCount}")
}

@Test
public class QqAdapterResourceTest {
    @TestCase
    public func resourceF1U1UpgradeReadAndHelloFailureReleaseOwnedConnection(): Unit {
        resourceQqFailedConnection([], "", rejectUpgrade: true)
        resourceQqFailedConnection([[255u8, 254u8]], "invalid_response_encoding")
        resourceQqFailedConnection(["{\"op\":10,\"d\":[]}".toArray()], "")
    }

    @TestCase
    public func resourceF1U1IdentifyWriteFailurePreservesErrorAndClosesNativeSocket(): Unit {
        let peer = ResourceQqPeer(["{\"op\":10,\"d\":{\"heartbeat_interval\":60000}}".toArray()], dropOnIdentify: true)
        let adapter = resourceQqAdapter(peer)
        let token = try { String.fromUtf8(Array<Byte>(2 * 1024 * 1024, repeat: 65)) } catch (_: Exception) { "" }
        adapter.debugCacheOfficialTokenForTest(token)
        let before = Directory.readFrom(Path("/dev/fd")).size
        let serving = spawn { peer.serve() }
        try {
            adapter.start()
            serving.get(Duration.second * 3)
            let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 3000
            while (adapter.debugLastSendErrorForTest().isEmpty() && DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
                sleep(Duration.millisecond)
            }
            let error = adapter.debugLastSendErrorForTest().toAsciiLower()
            @Expect(error.contains("send") || error.contains("write"), true)
            @Expect(peer.observedFrames.load(), 1)
            adapter.stop()
            @Expect(adapter.debugOfficialWorkersForTest(), 0)
            let after = Directory.readFrom(Path("/dev/fd")).size
            @Expect(after <= before, true)
        } finally {
            adapter.stop()
            peer.close()
            try { serving.get(Duration.second) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func resourceF1B1StopInterruptsBlockedReadAndOldGenerationCannotCloseNewConnection(): Unit {
        let peer = ResourceQqPeer(["{\"op\":10,\"d\":{\"heartbeat_interval\":60000}}".toArray()])
        let adapter = resourceQqAdapter(peer)
        let serving = spawn { peer.serve() }
        try {
            adapter.start()
            resourceAwaitQqUpgrade(peer)
            adapter.stop()
            serving.get(Duration.second * 2)
            @Expect(peer.peerClosed.load(), 1)
            @Expect(adapter.debugOfficialWorkersForTest(), 0)
            // Reuse the same adapter/listener so a late old worker could corrupt the replacement.
            peer.upgraded.store(false)
            let second = spawn { peer.serve() }
            try {
                adapter.start()
                resourceAwaitQqUpgrade(peer)
                @Expect(adapter.debugOfficialWorkersForTest() > 0, true)
                adapter.stop()
                second.get(Duration.second * 2)
                @Expect(peer.peerClosed.load(), 2)
                @Expect(adapter.debugOfficialWorkersForTest(), 0)
            } finally {
                adapter.stop()
                try { second.get(Duration.second) } catch (_: Exception) { () }
            }
        } finally {
            adapter.stop()
            peer.close()
            try { serving.get(Duration.second) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func resourceF1B1StopInterruptsBlockedUpgrade(): Unit {
        let peer = ResourceQqPeer([], holdUpgrade: true)
        let adapter = resourceQqAdapter(peer)
        let serving = spawn { peer.serve() }
        try {
            adapter.start()
            let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 2000
            while (!peer.handshakeRequested.load() && DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
                sleep(Duration.millisecond)
            }
            @Expect(peer.handshakeRequested.load(), true)
            adapter.stop()
            @Expect(adapter.debugOfficialWorkersForTest(), 0)
            serving.get(Duration.second * 2)
            @Expect(peer.peerClosed.load(), 1)
        } finally {
            adapter.stop()
            peer.close()
            try { serving.get(Duration.second) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func resourceF1P1HelloUnicodeMalformedJsonAndReconnectRetainProtocol(): Unit {
        resourceQqFailedConnection([
            "{\"op\":10,\"d\":{\"heartbeat_interval\":60000}}".toArray(),
            "{malformed JSON 中文😀}".toArray(),
            "{\"op\":0,\"t\":\"UNKNOWN\",\"d\":{\"content\":\"中文😀\"}}".toArray(),
            Array<Byte>(8192, repeat: 65),
            "{\"op\":7}".toArray()
        ], "reconnect requested", binaryPrefix: true, expectOutbound: true)
        resourceQqFailedConnection(["{\"op\":10,\"d\":{\"heartbeat_interval\":60000}}".toArray()], "reconnect requested", closeFrame: true, expectOutbound: true)
    }

    @TestCase
    public func resourceS0P1ThirtyTwoSuccessfulC2cRoundsReleaseClassifiedFds(): Unit {
        resourceQqOwnedLogHome({ ownership =>
            let original = captureCurrentProcessFdSnapshot()
            resourceQqSuccessfulBusinessRound(ownership, 0)
            let warm = captureCurrentProcessFdSnapshot()
            if (warm.status != "ok") { throw Exception("qq_positive_fd_probe_unavailable") }
            resourceQqPrintClassifiedFd(0, warm)
            let deadline = MonoTime.now() + Duration.second * 120
            var succeeded: Int64 = 0
            for (round in 1..=32) {
                if (MonoTime.now() >= deadline) { throw Exception("qq_positive_measurement_deadline") }
                resourceQqSuccessfulBusinessRound(ownership, round)
                let sample = captureCurrentProcessFdSnapshot()
                resourceQqPrintClassifiedFd(round, sample)
                if (sample.status != "ok" || sample.fdLimit != warm.fdLimit || sample.fdCount > warm.fdCount + 2) {
                    throw Exception("qq_positive_fd_growth")
                }
                succeeded += 1
                if (MonoTime.now() >= deadline) { throw Exception("qq_positive_measurement_deadline") }
            }
            @Expect(succeeded, 32)
            @Expect(captureCurrentProcessFdSnapshot().fdLimit, original.fdLimit)
            println("QQ_POSITIVE_FORMAL successes=${succeeded} warmSuccesses=1 workers=0 peerEof=33 listenerPortsClosed=33")
        })
    }

    @TestCase
    public func resourceF1P2ThirtyTwoFailedWebsocketsLeaveNoWorkersOrGrowingFds(): Unit {
        resourceQqFailedConnection([[255u8]], "invalid_response_encoding")
        let before = Directory.readFrom(Path("/dev/fd")).size
        for (_ in 0..32) {
            resourceQqFailedConnection([[255u8]], "invalid_response_encoding")
        }
        let after = Directory.readFrom(Path("/dev/fd")).size
        @Expect(after <= before + 1, true)
    }
}
