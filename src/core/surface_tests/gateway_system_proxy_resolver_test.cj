package metis.core.surface_tests

import metis.core.*

import std.unittest.*

private class FakeGatewaySystemProxyReader <: GatewaySystemProxyReader {
    private let value: String

    public init(value: String) {
        this.value = value
    }

    public func readSystemProxy(): String {
        value
    }
}

@Test
public class GatewaySystemProxyResolverTest {
    @TestCase
    public func parseScutilPrefersHttpsProxy(): Unit {
        let raw =
            "HTTPEnable : 1\n" +
            "HTTPProxy : 127.0.0.1\n" +
            "HTTPPort : 7890\n" +
            "HTTPSEnable : 1\n" +
            "HTTPSProxy : 127.0.0.1\n" +
            "HTTPSPort : 7897\n"

        @Expect(parseGatewayScutilProxy(raw), "http://127.0.0.1:7897")
    }

    @TestCase
    public func parseScutilFallsBackToHttpProxy(): Unit {
        let raw =
            "HTTPSEnable : 0\n" +
            "HTTPSProxy : 127.0.0.1\n" +
            "HTTPSPort : 7897\n" +
            "HTTPEnable : 1\n" +
            "HTTPProxy : 127.0.0.1\n" +
            "HTTPPort : 7890\n"

        @Expect(parseGatewayScutilProxy(raw), "http://127.0.0.1:7890")
    }

    @TestCase
    public func parseScutilFallsBackToSocksWhenOnlySocksExists(): Unit {
        let raw =
            "HTTPSEnable : 0\n" +
            "HTTPEnable : 0\n" +
            "SOCKSEnable : 1\n" +
            "SOCKSProxy : 127.0.0.1\n" +
            "SOCKSPort : 1086\n"

        @Expect(parseGatewayScutilProxy(raw), "socks5://127.0.0.1:1086")
    }

    @TestCase
    public func resolveSystemProxyTrimsFakeReaderValue(): Unit {
        let reader = FakeGatewaySystemProxyReader("  http://127.0.0.1:7897  ")

        @Expect(resolveGatewaySystemProxy(systemProxyReader: reader), "http://127.0.0.1:7897")
    }
}
