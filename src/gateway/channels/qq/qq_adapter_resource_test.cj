package metis.gateway.channels.qq

import metis.gateway.model.QQConfig
import std.collection.ArrayList
import std.fs.{Directory, Path}
import std.net.*
import std.sync.*
import std.time.*
import std.unittest.*
import stdx.crypto.digest.SHA1
import stdx.encoding.base64.toBase64String

private class ResourceQqPeer {
    let listener = TcpServerSocket(bindAt: 0u16)
    let upgraded = AtomicBool(false)
    let handshakeRequested = AtomicBool(false)
    let peerClosed = AtomicInt64(0)
    let observedFrames = AtomicInt64(0)
    let payloads: Array<Array<Byte>>
    let rejectUpgrade: Bool
    let closeFrame: Bool
    let binaryPrefix: Bool
    let holdUpgrade: Bool
    let dropOnIdentify: Bool

    init(payloads: Array<Array<Byte>>, rejectUpgrade!: Bool = false, closeFrame!: Bool = false, binaryPrefix!: Bool = false, holdUpgrade!: Bool = false, dropOnIdentify!: Bool = false) {
        this.payloads = payloads
        this.rejectUpgrade = rejectUpgrade
        this.closeFrame = closeFrame
        this.binaryPrefix = binaryPrefix
        this.holdUpgrade = holdUpgrade
        this.dropOnIdentify = dropOnIdentify
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
