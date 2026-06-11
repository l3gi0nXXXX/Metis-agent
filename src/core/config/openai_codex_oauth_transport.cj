package metis.core.config

import std.collection.ArrayList
import std.convert.*
import std.env.getVariable
import std.net.{SocketAddress, TcpSocket}
import std.process.executeWithOutput
import std.time.*
import stdx.encoding.base64.toBase64String
import stdx.encoding.json.JsonObject
import stdx.encoding.url.URL
import stdx.net.http.ClientBuilder
import stdx.net.tls.*

public class OpenAICodexOAuthProxyEndpoint {
    public let host: String
    public let port: UInt16
    public let auth: String
    public let scheme: String

    public init(host: String, port: UInt16, auth!: String = "", scheme!: String = "http") {
        this.host = host.trimAscii()
        this.port = port
        this.auth = auth.trimAscii()
        this.scheme = scheme.trimAscii().toAsciiLower()
    }
}

public class OpenAICodexOAuthTransportConfig {
    public let proxy: String
    public let envProxyEnabled: Bool
    public let noProxy: String
    public let insecureSkipTlsVerify: Bool
    public let timeoutMs: Int64
    public let proxySource: String

    public init(
        proxy!: String = "",
        envProxyEnabled!: Bool = true,
        noProxy!: String = "",
        insecureSkipTlsVerify!: Bool = false,
        timeoutMs!: Int64 = 30000,
        proxySource!: String = "none"
    ) {
        this.proxy = proxy.trimAscii()
        this.envProxyEnabled = envProxyEnabled
        this.noProxy = noProxy.trimAscii()
        this.insecureSkipTlsVerify = insecureSkipTlsVerify
        this.timeoutMs = max(1, timeoutMs)
        this.proxySource = proxySource.trimAscii()
    }
}

public class OpenAICodexOAuthRoute {
    public let mode: String
    public let proxySource: String
    public let redactedProxy: String
    public let targetHost: String
    public let error: String

    public init(mode: String, proxySource: String, redactedProxy: String, targetHost: String, error!: String = "") {
        this.mode = mode.trimAscii()
        this.proxySource = proxySource.trimAscii()
        this.redactedProxy = redactedProxy.trimAscii()
        this.targetHost = targetHost.trimAscii()
        this.error = error.trimAscii()
    }
}

public interface OpenAICodexOAuthSystemProxyReader {
    func readSystemProxy(): String
}

public class OpenAICodexOAuthNoopSystemProxyReader <: OpenAICodexOAuthSystemProxyReader {
    public init() {}

    public func readSystemProxy(): String {
        ""
    }
}

public class OpenAICodexOAuthScutilSystemProxyReader <: OpenAICodexOAuthSystemProxyReader {
    public init() {}

    public func readSystemProxy(): String {
        try {
            let (exitCode, stdoutBytes, _) = executeWithOutput("scutil", ["--proxy"])
            if (exitCode != 0) {
                return ""
            }
            return parseOpenAICodexOAuthScutilProxy(String.fromUtf8(stdoutBytes))
        } catch (_: Exception) {
            return ""
        }
    }
}

private func oauthJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func oauthJsonBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func oauthJsonInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            try { Int64.parse(v.toJsonString()) } catch (_: Exception) {
                try { Int64.parse(v.asString().getValue().trimAscii()) } catch (_inner: Exception) { fallback }
            }
        case None => fallback
    }
}

private func oauthJsonObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func oauthEnv(key: String): String {
    match (getVariable(key)) {
        case Some(v) =>
            let trimmed = v.trimAscii()
            if (!trimmed.isEmpty()) {
                return trimmed
            }
        case None => ()
    }
    ""
}

private func oauthEnvProxyForHttpsTarget(): String {
    let httpsProxy = oauthEnv("HTTPS_PROXY")
    if (!httpsProxy.isEmpty()) {
        return httpsProxy
    }
    let httpsProxyLower = oauthEnv("https_proxy")
    if (!httpsProxyLower.isEmpty()) {
        return httpsProxyLower
    }
    let httpProxy = oauthEnv("HTTP_PROXY")
    if (!httpProxy.isEmpty()) {
        return httpProxy
    }
    oauthEnv("http_proxy")
}

private func oauthEnvNoProxy(): String {
    let upper = oauthEnv("NO_PROXY")
    if (!upper.isEmpty()) {
        return upper
    }
    oauthEnv("no_proxy")
}

private func oauthMergeNoProxy(configNoProxy: String): String {
    let configured = configNoProxy.trimAscii()
    let env = oauthEnvNoProxy()
    if (configured.isEmpty()) {
        return env
    }
    if (env.isEmpty()) {
        return configured
    }
    "${configured},${env}"
}

private func oauthProviderConfigFromRoot(root: JsonObject): JsonObject {
    oauthJsonObject(oauthJsonObject(oauthJsonObject(root, "models"), "providers"), OPENAI_CODEX_OAUTH_PROVIDER_ID)
}

public func readOpenAICodexOAuthProviderConfig(): JsonObject {
    match (MetisConfigManager.rawConfig()) {
        case Some(root) => oauthProviderConfigFromRoot(root)
        case None => JsonObject()
    }
}

public func resolveOpenAICodexOAuthTransportConfig(
    providerConfig: JsonObject,
    systemProxyReader!: OpenAICodexOAuthSystemProxyReader = OpenAICodexOAuthNoopSystemProxyReader()
): OpenAICodexOAuthTransportConfig {
    let explicitProxy = oauthJsonString(providerConfig, "proxy")
    let envProxyEnabled = oauthJsonBool(providerConfig, "envProxy", oauthJsonBool(providerConfig, "envProxyEnabled", true))
    let noProxy = oauthMergeNoProxy(oauthJsonString(providerConfig, "noProxy"))
    let insecureSkipTlsVerify = oauthJsonBool(providerConfig, "insecureSkipTlsVerify", false)
    let timeoutMs = max(1, oauthJsonInt(providerConfig, "timeoutMs", 30000))
    if (!explicitProxy.isEmpty()) {
        return OpenAICodexOAuthTransportConfig(
            proxy: explicitProxy,
            envProxyEnabled: envProxyEnabled,
            noProxy: noProxy,
            insecureSkipTlsVerify: insecureSkipTlsVerify,
            timeoutMs: timeoutMs,
            proxySource: "explicit"
        )
    }
    if (envProxyEnabled) {
        let envProxy = oauthEnvProxyForHttpsTarget()
        if (!envProxy.isEmpty()) {
            return OpenAICodexOAuthTransportConfig(
                proxy: envProxy,
                envProxyEnabled: envProxyEnabled,
                noProxy: noProxy,
                insecureSkipTlsVerify: insecureSkipTlsVerify,
                timeoutMs: timeoutMs,
                proxySource: "env"
            )
        }
    }
    let systemProxy = systemProxyReader.readSystemProxy().trimAscii()
    if (!systemProxy.isEmpty()) {
        return OpenAICodexOAuthTransportConfig(
            proxy: systemProxy,
            envProxyEnabled: envProxyEnabled,
            noProxy: noProxy,
            insecureSkipTlsVerify: insecureSkipTlsVerify,
            timeoutMs: timeoutMs,
            proxySource: "system"
        )
    }
    OpenAICodexOAuthTransportConfig(
        envProxyEnabled: envProxyEnabled,
        noProxy: noProxy,
        insecureSkipTlsVerify: insecureSkipTlsVerify,
        timeoutMs: timeoutMs
    )
}

public func resolveOpenAICodexOAuthTransportConfigFromMetis(
    systemProxyReader!: OpenAICodexOAuthSystemProxyReader = OpenAICodexOAuthScutilSystemProxyReader()
): OpenAICodexOAuthTransportConfig {
    resolveOpenAICodexOAuthTransportConfig(readOpenAICodexOAuthProviderConfig(), systemProxyReader: systemProxyReader)
}

private func oauthScutilValue(raw: String, key: String): String {
    for (line0 in raw.split("\n")) {
        let line = line0.trimAscii()
        if (!line.startsWith(key)) {
            continue
        }
        match (line.indexOf(":")) {
            case Some(idx) => return line[idx + 1..].trimAscii()
            case None => ()
        }
    }
    ""
}

private func oauthScutilEnabled(raw: String, key: String): Bool {
    let value = oauthScutilValue(raw, key).toAsciiLower()
    value.isEmpty() || value == "1" || value == "true" || value == "yes"
}

private func oauthScutilProxyCandidate(raw: String, prefix: String, scheme: String, defaultPort: UInt16): String {
    if (!oauthScutilEnabled(raw, "${prefix}Enable")) {
        return ""
    }
    let host = oauthScutilValue(raw, "${prefix}Proxy")
    if (host.isEmpty()) {
        return ""
    }
    var port = defaultPort
    let portText = oauthScutilValue(raw, "${prefix}Port")
    if (!portText.isEmpty()) {
        try {
            let parsed = Int64.parse(portText)
            if (parsed > 0 && parsed <= 65535) {
                port = UInt16(parsed)
            }
        } catch (_: Exception) {
            ()
        }
    }
    "${scheme}://${host}:${port}"
}

public func parseOpenAICodexOAuthScutilProxy(raw: String): String {
    let httpsProxy = oauthScutilProxyCandidate(raw, "HTTPS", "http", 443u16)
    if (!httpsProxy.isEmpty()) {
        return httpsProxy
    }
    let httpProxy = oauthScutilProxyCandidate(raw, "HTTP", "http", 80u16)
    if (!httpProxy.isEmpty()) {
        return httpProxy
    }
    oauthScutilProxyCandidate(raw, "SOCKS", "socks5", 1080u16)
}

private func oauthProxyScheme(proxy: String): String {
    let lower = proxy.trimAscii().toAsciiLower()
    if (lower.startsWith("https://")) {
        return "https"
    }
    if (lower.startsWith("socks5://") || lower.startsWith("socks://")) {
        return "socks5"
    }
    "http"
}

private func oauthStripProxyScheme(proxy: String): String {
    let trimmed = proxy.trimAscii()
    let lower = trimmed.toAsciiLower()
    if (lower.startsWith("https://")) {
        return trimmed[8..]
    }
    if (lower.startsWith("http://")) {
        return trimmed[7..]
    }
    if (lower.startsWith("socks5://")) {
        return trimmed[9..]
    }
    if (lower.startsWith("socks://")) {
        return trimmed[8..]
    }
    trimmed
}

public func parseOpenAICodexOAuthProxyEndpoint(proxy: String): OpenAICodexOAuthProxyEndpoint {
    let trimmed = proxy.trimAscii()
    let scheme = oauthProxyScheme(trimmed)
    let withoutScheme = oauthStripProxyScheme(trimmed)
    let authority = match (withoutScheme.indexOf("/")) {
        case Some(idx) => withoutScheme[..idx]
        case None => withoutScheme
    }
    var hostPort = authority
    var auth = ""
    match (authority.lastIndexOf("@")) {
        case Some(idx) =>
            auth = authority[..idx]
            hostPort = authority[idx + 1..]
        case None => ()
    }
    var host = hostPort
    var port: UInt16 = if (scheme == "https") { 443u16 } else if (scheme == "socks5") { 1080u16 } else { 80u16 }
    match (hostPort.lastIndexOf(":")) {
        case Some(idx) =>
            host = hostPort[..idx]
            try {
                let parsed = Int64.parse(hostPort[idx + 1..])
                if (parsed > 0 && parsed <= 65535) {
                    port = UInt16(parsed)
                }
            } catch (_: Exception) {
                ()
            }
        case None => ()
    }
    if (host.trimAscii().isEmpty()) {
        return OpenAICodexOAuthProxyEndpoint("", 0u16, auth: auth, scheme: scheme)
    }
    OpenAICodexOAuthProxyEndpoint(host, port, auth: auth, scheme: scheme)
}

public func redactOpenAICodexOAuthProxy(proxy: String): String {
    let trimmed = proxy.trimAscii()
    if (trimmed.isEmpty()) {
        return ""
    }
    let schemeEnd = match (trimmed.indexOf("://")) {
        case Some(idx) => idx + 3
        case None => 0
    }
    let prefix = trimmed[..schemeEnd]
    let rest = trimmed[schemeEnd..]
    match (rest.lastIndexOf("@")) {
        case Some(idx) => "${prefix}[redacted]@${rest[idx + 1..]}"
        case None => trimmed
    }
}

public func buildOpenAICodexOAuthHttpConnectRequest(
    targetHost: String,
    targetPort: UInt16,
    endpoint: OpenAICodexOAuthProxyEndpoint
): String {
    var request =
        "CONNECT ${targetHost}:${targetPort} HTTP/1.1\r\n" +
            "Host: ${targetHost}:${targetPort}\r\n" +
            "Proxy-Connection: Keep-Alive\r\n"
    if (!endpoint.auth.isEmpty()) {
        request += "Proxy-Authorization: Basic ${toBase64String(endpoint.auth.toArray())}\r\n"
    }
    request + "\r\n"
}

private func oauthTargetHost(url: String): String {
    try {
        return URL.parse(url.trimAscii()).hostName.trimAscii().toAsciiLower()
    } catch (_: Exception) {
        var rest = url.trimAscii()
        match (rest.indexOf("://")) {
            case Some(idx) => rest = rest[idx + 3..]
            case None => ()
        }
        match (rest.indexOf("/")) {
            case Some(idx) => rest = rest[..idx]
            case None => ()
        }
        match (rest.lastIndexOf(":")) {
            case Some(idx) => rest = rest[..idx]
            case None => ()
        }
        rest.trimAscii().toAsciiLower()
    }
}

private func oauthTargetScheme(url: String): String {
    try { URL.parse(url.trimAscii()).scheme.trimAscii().toAsciiLower() } catch (_: Exception) {
        let lower = url.trimAscii().toAsciiLower()
        if (lower.startsWith("https://")) {
            "https"
        } else if (lower.startsWith("http://")) {
            "http"
        } else {
            ""
        }
    }
}

private func oauthTargetPort(url: String): UInt16 {
    let scheme = oauthTargetScheme(url)
    if (scheme == "https") {
        return 443u16
    }
    80u16
}

private func oauthNoProxyMatches(url: String, cfg: OpenAICodexOAuthTransportConfig): Bool {
    let raw = cfg.noProxy.trimAscii()
    if (raw.isEmpty()) {
        return false
    }
    let host = oauthTargetHost(url)
    if (host.isEmpty()) {
        return false
    }
    for (part0 in raw.split(",")) {
        let part = part0.trimAscii().toAsciiLower()
        if (part.isEmpty()) {
            continue
        }
        if (part == "*" || part == host) {
            return true
        }
        if (part.startsWith(".")) {
            if (host.endsWith(part)) {
                return true
            }
        } else if (host.endsWith("." + part)) {
            return true
        }
    }
    false
}

public func resolveOpenAICodexOAuthProxyForUrl(url: String, cfg: OpenAICodexOAuthTransportConfig): (String, String) {
    if (cfg.proxy.isEmpty()) {
        return ("", "none")
    }
    let source = if (cfg.proxySource.isEmpty() || cfg.proxySource == "none") { "configured" } else { cfg.proxySource }
    if (source != "explicit" && oauthNoProxyMatches(url, cfg)) {
        return ("", "no_proxy")
    }
    (cfg.proxy, source)
}

public func resolveOpenAICodexOAuthRoute(url: String, cfg: OpenAICodexOAuthTransportConfig): OpenAICodexOAuthRoute {
    let targetHost = oauthTargetHost(url)
    let targetScheme = oauthTargetScheme(url)
    let proxyInfo = resolveOpenAICodexOAuthProxyForUrl(url, cfg)
    let proxy = proxyInfo[0]
    let source = proxyInfo[1]
    if (proxy.isEmpty()) {
        return OpenAICodexOAuthRoute("direct", source, "", targetHost)
    }
    let endpoint = parseOpenAICodexOAuthProxyEndpoint(proxy)
    if (endpoint.host.isEmpty() || endpoint.port == 0u16) {
        return OpenAICodexOAuthRoute(
            "invalidProxy",
            source,
            redactOpenAICodexOAuthProxy(proxy),
            targetHost,
            error: "OpenAI Codex OAuth proxy is invalid: ${redactOpenAICodexOAuthProxy(proxy)}"
        )
    }
    if (targetScheme == "https" && endpoint.scheme == "https") {
        return OpenAICodexOAuthRoute(
            "unsupportedHttpsProxy",
            source,
            redactOpenAICodexOAuthProxy(proxy),
            targetHost,
            error: "true HTTPS proxy is not implemented for OpenAI Codex OAuth; configure an HTTP proxy or bare host:port for HTTPS CONNECT"
        )
    }
    if (endpoint.scheme == "socks5") {
        return OpenAICodexOAuthRoute(
            "unsupportedSocksProxy",
            source,
            redactOpenAICodexOAuthProxy(proxy),
            targetHost,
            error: "SOCKS proxy is not implemented for OpenAI Codex OAuth; configure an HTTP proxy or bare host:port"
        )
    }
    if (targetScheme == "https") {
        return OpenAICodexOAuthRoute("httpConnectTunnel", source, redactOpenAICodexOAuthProxy(proxy), targetHost)
    }
    OpenAICodexOAuthRoute("httpProxy", source, redactOpenAICodexOAuthProxy(proxy), targetHost)
}

private func readOpenAICodexOAuthHttpConnectResponse(socket: TcpSocket): String {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(1024, repeat: 0)
    var total: Int64 = 0
    while (total < 8192) {
        let n = socket.read(buffer)
        if (n <= 0) {
            break
        }
        output.add(all: buffer[..n])
        total += n
        let text = String.fromUtf8(output.toArray())
        if (text.contains("\r\n\r\n")) {
            return text
        }
    }
    String.fromUtf8(output.toArray())
}

private func openOpenAICodexOAuthHttpConnectTunnel(
    socket: TcpSocket,
    targetHost: String,
    targetPort: UInt16,
    endpoint: OpenAICodexOAuthProxyEndpoint
): Unit {
    socket.write(buildOpenAICodexOAuthHttpConnectRequest(targetHost, targetPort, endpoint).toArray())
    let response = readOpenAICodexOAuthHttpConnectResponse(socket)
    let firstLine = match (response.indexOf("\r\n")) {
        case Some(idx) => response[..idx]
        case None => response
    }
    if (!firstLine.contains(" 200 ")) {
        throw Exception("OpenAI Codex OAuth HTTP proxy CONNECT failed: ${firstLine}")
    }
}

public func buildOpenAICodexOAuthHttpClientBuilder(
    url: String,
    cfg: OpenAICodexOAuthTransportConfig
): (ClientBuilder, OpenAICodexOAuthRoute) {
    let route = resolveOpenAICodexOAuthRoute(url, cfg)
    if (route.mode == "unsupportedHttpsProxy" || route.mode == "unsupportedSocksProxy" || route.mode == "invalidProxy") {
        throw Exception(route.error)
    }
    let builder = ClientBuilder()
    builder.readTimeout(Duration.millisecond * cfg.timeoutMs)
    let proxyInfo = resolveOpenAICodexOAuthProxyForUrl(url, cfg)
    if (route.mode == "httpProxy") {
        builder.httpProxy(proxyInfo[0])
    }
    if (oauthTargetScheme(url) == "https") {
        var tlsConfig = TlsClientConfig()
        if (cfg.insecureSkipTlsVerify) {
            tlsConfig.verifyMode = TrustAll
        }
        tlsConfig.domain = route.targetHost
        tlsConfig.alpnProtocolsList = ["http/1.1"]
        builder.tlsConfig(tlsConfig)
    }
    if (route.mode == "httpConnectTunnel") {
        let endpoint = parseOpenAICodexOAuthProxyEndpoint(proxyInfo[0])
        let connectTimeoutMs = max(1, cfg.timeoutMs)
        let targetHost = route.targetHost
        let targetPort = oauthTargetPort(url)
        let socketConnector = { _sa: SocketAddress =>
            let socket = TcpSocket(endpoint.host, endpoint.port)
            socket.readTimeout = Duration.millisecond * connectTimeoutMs
            socket.writeTimeout = Duration.millisecond * connectTimeoutMs
            socket.connect(timeout: Duration.millisecond * connectTimeoutMs)
            openOpenAICodexOAuthHttpConnectTunnel(socket, targetHost, targetPort, endpoint)
            return socket
        }
        builder.connector(socketConnector)
    }
    (builder, route)
}
