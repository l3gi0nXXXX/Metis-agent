package metis.core.config

import std.env.{getVariable, setVariable}
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString}

private class FakeOpenAICodexOAuthSystemProxyReader <: OpenAICodexOAuthSystemProxyReader {
    private let proxy: String

    public init(proxy: String) {
        this.proxy = proxy
    }

    public func readSystemProxy(): String {
        this.proxy
    }
}

private class FakeOpenAICodexOAuthScutilReader <: OpenAICodexOAuthSystemProxyReader {
    private let raw: String

    public init(raw: String) {
        this.raw = raw
    }

    public func readSystemProxy(): String {
        parseOpenAICodexOAuthScutilProxy(this.raw)
    }
}

private func oauthTransportProviderConfig(
    proxy!: String = "",
    envProxy!: Bool = true,
    noProxy!: String = "",
    insecure!: Bool = false,
    timeoutMs!: Int64 = 30000
): JsonObject {
    let obj = JsonObject()
    obj.put("proxy", JsonString(proxy))
    obj.put("envProxy", JsonBool(envProxy))
    obj.put("noProxy", JsonString(noProxy))
    obj.put("insecureSkipTlsVerify", JsonBool(insecure))
    obj.put("timeoutMs", JsonInt(timeoutMs))
    obj
}

private func oauthTransportRestoreEnv(key: String, value: Option<String>): Unit {
    match (value) {
        case Some(existing) => setVariable(key, existing)
        case None => setVariable(key, "")
    }
}

private func withCleanOAuthProxyEnv<T>(block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let oldHttps = getVariable("HTTPS_PROXY")
        let oldHttpsLower = getVariable("https_proxy")
        let oldHttp = getVariable("HTTP_PROXY")
        let oldHttpLower = getVariable("http_proxy")
        let oldNoProxy = getVariable("NO_PROXY")
        let oldNoProxyLower = getVariable("no_proxy")
        setVariable("HTTPS_PROXY", "")
        setVariable("https_proxy", "")
        setVariable("HTTP_PROXY", "")
        setVariable("http_proxy", "")
        setVariable("NO_PROXY", "")
        setVariable("no_proxy", "")
        try {
            return block()
        } finally {
            oauthTransportRestoreEnv("HTTPS_PROXY", oldHttps)
            oauthTransportRestoreEnv("https_proxy", oldHttpsLower)
            oauthTransportRestoreEnv("HTTP_PROXY", oldHttp)
            oauthTransportRestoreEnv("http_proxy", oldHttpLower)
            oauthTransportRestoreEnv("NO_PROXY", oldNoProxy)
            oauthTransportRestoreEnv("no_proxy", oldNoProxyLower)
        }
    }
}

@Test
public class OpenAICodexOAuthTransportTest {
    @TestCase
    public func OAUTH_PROXY_U1_explicitHttpProxyResolvesBeforeEnvAndSystem(): Unit {
        withCleanOAuthProxyEnv {
            setVariable("HTTPS_PROXY", "http://env.local:7897")
            let cfg = resolveOpenAICodexOAuthTransportConfig(
                oauthTransportProviderConfig(proxy: "http://explicit.local:8888"),
                systemProxyReader: FakeOpenAICodexOAuthSystemProxyReader("http://system.local:9999")
            )

            @Expect(cfg.proxy, "http://explicit.local:8888")
            @Expect(cfg.proxySource, "explicit")
        }
    }

    @TestCase
    public func OAUTH_PROXY_U2_envProxyUsedWhenExplicitEmptyAndEnvProxyEnabled(): Unit {
        withCleanOAuthProxyEnv {
            setVariable("HTTPS_PROXY", "http://env.local:7897")
            let cfg = resolveOpenAICodexOAuthTransportConfig(
                oauthTransportProviderConfig(),
                systemProxyReader: FakeOpenAICodexOAuthSystemProxyReader("http://system.local:9999")
            )

            @Expect(cfg.proxy, "http://env.local:7897")
            @Expect(cfg.proxySource, "env")
        }
    }

    @TestCase
    public func OAUTH_PROXY_U3_envProxyDisabledStillAllowsSystemProxyFallback(): Unit {
        withCleanOAuthProxyEnv {
            setVariable("HTTPS_PROXY", "http://env.local:7897")
            let cfg = resolveOpenAICodexOAuthTransportConfig(
                oauthTransportProviderConfig(envProxy: false),
                systemProxyReader: FakeOpenAICodexOAuthSystemProxyReader("http://system.local:9999")
            )

            @Expect(cfg.envProxyEnabled, false)
            @Expect(cfg.proxy, "http://system.local:9999")
            @Expect(cfg.proxySource, "system")
        }
    }

    @TestCase
    public func OAUTH_PROXY_B1_noProxyHostAndDomainBypassEnvironmentProxy(): Unit {
        let cfg = OpenAICodexOAuthTransportConfig(
            proxy: "http://env.local:7897",
            noProxy: "auth.openai.com,.internal.test",
            proxySource: "env"
        )

        let exact = resolveOpenAICodexOAuthProxyForUrl("https://auth.openai.com/oauth/token", cfg)
        let domain = resolveOpenAICodexOAuthProxyForUrl("https://api.internal.test/v1", cfg)
        let miss = resolveOpenAICodexOAuthProxyForUrl("https://chatgpt.com/backend-api/codex/responses", cfg)

        @Expect(exact[0], "")
        @Expect(exact[1], "no_proxy")
        @Expect(domain[0], "")
        @Expect(domain[1], "no_proxy")
        @Expect(miss[0], "http://env.local:7897")
        @Expect(miss[1], "env")
    }

    @TestCase
    public func OAUTH_PROXY_B2_httpsProxyEndpointPreservesSchemeForUnsupportedClassification(): Unit {
        let endpoint = parseOpenAICodexOAuthProxyEndpoint("https://proxy.local:8443")
        let route = resolveOpenAICodexOAuthRoute(
            "https://auth.openai.com/oauth/token",
            OpenAICodexOAuthTransportConfig(proxy: "https://proxy.local:8443", proxySource: "explicit")
        )

        @Expect(endpoint.host, "proxy.local")
        @Expect(endpoint.port, 8443u16)
        @Expect(endpoint.scheme, "https")
        @Expect(route.mode, "unsupportedHttpsProxy")
        @Expect(route.error.contains("true HTTPS proxy is not implemented"), true)
    }

    @TestCase
    public func OAUTH_PROXY_B3_proxyAuthCreatesBasicHeaderAndRedactionHidesPassword(): Unit {
        let endpoint = parseOpenAICodexOAuthProxyEndpoint("http://user:secret@127.0.0.1:7897")
        let request = buildOpenAICodexOAuthHttpConnectRequest("auth.openai.com", 443u16, endpoint)
        let redacted = redactOpenAICodexOAuthProxy("http://user:secret@127.0.0.1:7897")

        @Expect(endpoint.host, "127.0.0.1")
        @Expect(endpoint.port, 7897u16)
        @Expect(request.contains("CONNECT auth.openai.com:443 HTTP/1.1\r\n"), true)
        @Expect(request.contains("Proxy-Authorization: Basic dXNlcjpzZWNyZXQ="), true)
        @Expect(request.contains("user:secret"), false)
        @Expect(redacted, "http://[redacted]@127.0.0.1:7897")
        @Expect(redacted.contains("secret"), false)
    }

    @TestCase
    public func OAUTH_PROXY_P1_scutilReaderUsesHttpsProxyAfterExplicitAndEnvMissing(): Unit {
        withCleanOAuthProxyEnv {
            let raw =
                "<dictionary> {\n" +
                    "  HTTPEnable : 1\n" +
                    "  HTTPProxy : 127.0.0.1\n" +
                    "  HTTPPort : 8080\n" +
                    "  HTTPSEnable : 1\n" +
                    "  HTTPSProxy : 127.0.0.1\n" +
                    "  HTTPSPort : 7897\n" +
                    "  SOCKSEnable : 1\n" +
                    "  SOCKSProxy : 127.0.0.1\n" +
                    "  SOCKSPort : 1080\n" +
                    "}\n"
            let parsed = parseOpenAICodexOAuthScutilProxy(raw)
            let cfg = resolveOpenAICodexOAuthTransportConfig(
                oauthTransportProviderConfig(),
                systemProxyReader: FakeOpenAICodexOAuthScutilReader(raw)
            )

            @Expect(parsed, "http://127.0.0.1:7897")
            @Expect(cfg.proxy, "http://127.0.0.1:7897")
            @Expect(cfg.proxySource, "system")
        }
    }

    @TestCase
    public func OAUTH_PROXY_N1_malformedProxyProducesInvalidRouteWithoutPanic(): Unit {
        let endpoint = parseOpenAICodexOAuthProxyEndpoint("http://:bad")
        let route = resolveOpenAICodexOAuthRoute(
            "https://auth.openai.com/oauth/token",
            OpenAICodexOAuthTransportConfig(proxy: "http://user:secret@:bad", proxySource: "explicit")
        )

        @Expect(endpoint.host, "")
        @Expect(endpoint.port, 0u16)
        @Expect(route.mode, "invalidProxy")
        @Expect(route.error.contains("secret"), false)
    }

    @TestCase
    public func OAUTH_PROXY_N2_nativeClientReturnsRedactedProxyDiagnosticBeforeNetwork(): Unit {
        let client = OpenAICodexNativeHttpClient(transportConfig: Some(OpenAICodexOAuthTransportConfig(
            proxy: "https://user:secret@127.0.0.1:7897",
            proxySource: "explicit"
        )))
        let response = client.postJson(OPENAI_CODEX_DEVICE_AUTH_USERCODE_URL, "{\"client_id\":\"test\"}")

        @Expect(response.statusCode, 0)
        @Expect(response.body.contains("network_error"), true)
        @Expect(response.body.contains("unsupportedHttpsProxy"), true)
        @Expect(response.body.contains("true HTTPS proxy is not implemented"), true)
        @Expect(response.body.contains("secret"), false)
        @Expect(response.body.contains("[redacted]@127.0.0.1:7897"), true)
    }
}
