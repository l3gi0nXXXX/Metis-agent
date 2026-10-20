package metis.gateway.channels.telegram

import metis.core.{GatewayProviderHttpTransportConfig, buildGatewayProviderHttpClientBuilder}
import metis.core.config.{OpenAICodexOAuthTransportConfig, buildOpenAICodexOAuthHttpClientBuilder}
import std.collection.ArrayList
import std.fs.{Directory, Path}
import std.net.*
import std.sync.*
import std.time.*
import std.unittest.*
import stdx.net.http.*

// Native CONNECT requests are exercised against an owned dynamic loopback port.
private class ResourceConnectProxy {
    let listener = TcpServerSocket(bindAt: 0u16)
    let peerClosed = AtomicInt64(0)
    let tunneled = AtomicInt64(0)
    let response: Array<Byte>
    let mode: String

    init(response: Array<Byte>, mode!: String = "reject") {
        this.response = response
        this.mode = mode
        this.listener.bind()
    }

    prop port: UInt16 {
        get() { (this.listener.localAddress as IPSocketAddress)?.port ?? 0u16 }
    }

    func serve(): Unit {
        try (peer = this.listener.accept(timeout: Some(Duration.second * 3))) {
            peer.readTimeout = Some(Duration.second * 8)
            let request = ArrayList<Byte>()
            let one = Array<Byte>(1, repeat: 0)
            while (request.size < 8192) {
                let n = peer.read(one)
                if (n == 0) { return }
                request.add(one[0])
                let size = request.size
                if (size >= 4 && request[size - 4] == 13 && request[size - 3] == 10 && request[size - 2] == 13 && request[size - 1] == 10) { break }
            }
            if (this.mode == "eof") { return }
            if (this.mode == "split") {
                // Deliberately split UTF-8 sequences across TCP writes.
                for (byte in this.response) { peer.write([byte]) }
            } else if (this.mode != "timeout") {
                peer.write(this.response)
            }
            let buffer = Array<Byte>(16384, repeat: 0)
            try {
                let n = peer.read(buffer)
                if (n == 0) { this.peerClosed.fetchAdd(1) }
                else if (this.mode == "tunnel") { this.tunneled.fetchAdd(1) }
            } catch (_: SocketTimeoutException) {
                // A timeout is deliberately not counted as a closed client.
            } catch (_: SocketException) {
                this.peerClosed.fetchAdd(1)
            }
        }
    }

    func close(): Unit { this.listener.close() }
}

private func resourceRunConnector(kind: Int64, port: UInt16): String {
    let proxy = "http://fixture:syntheticsecret@127.0.0.1:${port}"
    let url = "https://127.0.0.1/resource"
    if (kind == 0) {
        let response = TelegramTransport(proxy: proxy, timeoutSeconds: 1, dangerouslyAllowPrivateNetwork: true).get(url)
        return response.error
    }
    let builder = if (kind == 1) {
        buildGatewayProviderHttpClientBuilder(url, GatewayProviderHttpTransportConfig(proxy, false, "", true, 100))[0]
    } else {
        buildOpenAICodexOAuthHttpClientBuilder(url, OpenAICodexOAuthTransportConfig(proxy: proxy, envProxyEnabled: false, timeoutMs: 100))[0]
    }
    let client = builder.build()
    try {
        client.send(HttpRequestBuilder().url(url).get().build())
        ""
    } catch (e: Exception) {
        e.message
    } finally {
        client.close()
    }
}

private func resourceCheckConnectFailure(response: Array<Byte>, expected: String, mode!: String = "reject"): Unit {
    for (kind in 0..3) {
        let proxy = ResourceConnectProxy(response, mode: mode)
        let serving = spawn { proxy.serve() }
        try {
            let error = resourceRunConnector(kind, proxy.port)
            @Expect(error.isEmpty(), false)
            @Expect(error.contains("syntheticsecret"), false)
            @Expect(error.contains("Proxy-Authorization"), false)
            if (!expected.isEmpty()) { @Expect(error.contains(expected), true) }
            serving.get(Duration.second * 10)
            // EOF fixture closes its own half; all other cases require client close.
            if (mode != "eof") { @Expect(proxy.peerClosed.load(), 1) }
        } finally {
            proxy.close()
            try { serving.get(Duration.second) } catch (_: Exception) { () }
        }
    }
}

@Test
public class TelegramTransportResourceTest {
    @TestCase
    public func resourceF1N1RejectedConnectClosesAllThreeNativeConnectors(): Unit {
        for (status in [407, 502]) {
            resourceCheckConnectFailure("HTTP/1.1 ${status} syntheticsecret\r\n\r\n".toArray(), "status=${status}")
        }
        resourceCheckConnectFailure([], "", mode: "eof")
        resourceCheckConnectFailure([], "", mode: "timeout")
        let refused = TcpServerSocket(bindAt: 0u16)
        refused.bind()
        let port = (refused.localAddress as IPSocketAddress)?.port ?? 0u16
        refused.close()
        for (kind in 0..3) { @Expect(resourceRunConnector(kind, port).isEmpty(), false) }
        @Expect(TelegramTransport(timeoutSeconds: 1, dangerouslyAllowPrivateNetwork: true).get("http://127.0.0.1:${port}/resource").ok, false)
    }

    @TestCase
    public func resourceF1B2ConnectUnicodeBinaryAndOversizedHeadersAreSafe(): Unit {
        resourceCheckConnectFailure("HTTP/1.1 407 中文😀syntheticsecret\r\nX-Detail: 错误😀\r\n\r\n".toArray(), "CONNECT failed", mode: "split")
        resourceCheckConnectFailure([72u8, 84u8, 84u8, 80u8, 255u8, 13u8, 10u8, 13u8, 10u8], "invalid_response_encoding")
        resourceCheckConnectFailure(Array<Byte>(8192, repeat: 65), "response_too_large")
        resourceCheckConnectFailure("{malformed JSON 中文😀}\r\n\r\n".toArray(), "CONNECT failed")
    }

    @TestCase
    public func resourceF1P1SuccessfulConnectTransfersLiveSocketToTls(): Unit {
        for (kind in 0..3) {
            let proxy = ResourceConnectProxy("HTTP/1.1 200 Connection established\r\nX-Name: 中文😀\r\n\r\n".toArray(), mode: "tunnel")
            let serving = spawn { proxy.serve() }
            try {
                let _ = resourceRunConnector(kind, proxy.port)
                serving.get(Duration.second * 3)
                @Expect(proxy.tunneled.load(), 1)
            } finally {
                proxy.close()
                try { serving.get(Duration.second) } catch (_: Exception) { () }
            }
        }
    }

    @TestCase
    public func resourceF1P2ThirtyTwoFailureRoundsReturnSocketAndFdCounts(): Unit {
        // Warm up stdx/OpenSSL before recording the process descriptor baseline.
        resourceCheckConnectFailure("HTTP/1.1 407 Denied\r\n\r\n".toArray(), "CONNECT failed")
        let refused = TcpServerSocket(bindAt: 0u16)
        refused.bind()
        let port = (refused.localAddress as IPSocketAddress)?.port ?? 0u16
        refused.close()
        let before = Directory.readFrom(Path("/dev/fd")).size
        for (_ in 0..32) {
            resourceCheckConnectFailure("HTTP/1.1 407 Denied\r\n\r\n".toArray(), "CONNECT failed")
            resourceCheckConnectFailure([], "", mode: "eof")
            for (kind in 0..3) { @Expect(resourceRunConnector(kind, port).isEmpty(), false) }
            @Expect(TelegramTransport(timeoutSeconds: 1, dangerouslyAllowPrivateNetwork: true).get("http://127.0.0.1:${port}/resource").ok, false)
        }
        let after = Directory.readFrom(Path("/dev/fd")).size
        @Expect(after <= before + 1, true)
    }
}
