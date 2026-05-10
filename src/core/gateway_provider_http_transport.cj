package metis.core

import std.collection.ArrayList
import std.convert.*
import std.env.getVariable
import std.net.{SocketAddress, TcpSocket}
import std.time.*
import stdx.encoding.base64.toBase64String
import stdx.encoding.json.JsonObject
import stdx.encoding.url.URL
import stdx.net.http.ClientBuilder
import stdx.net.tls.*

public class GatewayProviderHttpTransportConfig {
    public let proxy: String
    public let envProxyEnabled: Bool
    public let noProxy: String
    public let insecureSkipTlsVerify: Bool
    public let timeoutMs: Int64

    public init(
        proxy: String,
        envProxyEnabled: Bool,
        noProxy: String,
        insecureSkipTlsVerify: Bool,
        timeoutMs: Int64
    ) {
        this.proxy = proxy
        this.envProxyEnabled = envProxyEnabled
        this.noProxy = noProxy
        this.insecureSkipTlsVerify = insecureSkipTlsVerify
        this.timeoutMs = timeoutMs
    }
}

public class GatewayProviderHttpRoute {
    public let mode: String
    public let proxySource: String
    public let redactedProxy: String
    public let targetHost: String
    public let error: String

    public init(mode: String, proxySource: String, redactedProxy: String, targetHost: String, error!: String = "") {
        this.mode = mode
        this.proxySource = proxySource
        this.redactedProxy = redactedProxy
        this.targetHost = targetHost
        this.error = error
    }
}

public class GatewayProviderHttpProxyEndpoint {
    public let host: String
    public let port: UInt16
    public let auth: String
    public let scheme: String

    public init(host: String, port: UInt16, auth!: String = "", scheme!: String = "http") {
        this.host = host
        this.port = port
        this.auth = auth
        this.scheme = scheme
    }
}

private func providerHttpString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func providerHttpBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func providerHttpInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            try { Int64.parse(v.toJsonString()) } catch (_: Exception) {
                try { Int64.parse(v.asString().getValue().trimAscii()) } catch (_inner: Exception) { fallback }
            }
        case None => fallback
    }
}

private func providerHttpEnv(key: String): String {
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

public func resolveGatewayProviderHttpTransportConfig(providerConfig: JsonObject): GatewayProviderHttpTransportConfig {
    GatewayProviderHttpTransportConfig(
        providerHttpString(providerConfig, "proxy"),
        providerHttpBool(providerConfig, "envProxyEnabled", false),
        providerHttpString(providerConfig, "noProxy"),
        providerHttpBool(providerConfig, "insecureSkipTlsVerify", false),
        max(1, providerHttpInt(providerConfig, "timeoutMs", 120000))
    )
}

private func providerHttpTargetHost(url: String): String {
    try { URL.parse(url.trimAscii()).hostName.trimAscii().toAsciiLower() } catch (_: Exception) { "" }
}

private func providerHttpScheme(url: String): String {
    try { URL.parse(url.trimAscii()).scheme.trimAscii().toAsciiLower() } catch (_: Exception) { "" }
}

private func providerHttpNoProxyValue(cfg: GatewayProviderHttpTransportConfig): String {
    if (!cfg.noProxy.trimAscii().isEmpty()) {
        return cfg.noProxy.trimAscii()
    }
    let upper = providerHttpEnv("NO_PROXY")
    if (!upper.isEmpty()) {
        return upper
    }
    providerHttpEnv("no_proxy")
}

private func providerHttpNoProxyMatches(url: String, cfg: GatewayProviderHttpTransportConfig): Bool {
    let raw = providerHttpNoProxyValue(cfg)
    if (raw.isEmpty()) {
        return false
    }
    let host = providerHttpTargetHost(url)
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

private func providerHttpEnvProxyForUrl(url: String): String {
    if (providerHttpScheme(url) == "https") {
        let httpsProxy = providerHttpEnv("HTTPS_PROXY")
        if (!httpsProxy.isEmpty()) {
            return httpsProxy
        }
        let httpsProxyLower = providerHttpEnv("https_proxy")
        if (!httpsProxyLower.isEmpty()) {
            return httpsProxyLower
        }
    }
    let httpProxy = providerHttpEnv("HTTP_PROXY")
    if (!httpProxy.isEmpty()) {
        return httpProxy
    }
    providerHttpEnv("http_proxy")
}

private func providerHttpProxyForUrl(url: String, cfg: GatewayProviderHttpTransportConfig): (String, String) {
    if (!cfg.proxy.trimAscii().isEmpty()) {
        return (cfg.proxy.trimAscii(), "explicit")
    }
    if (!cfg.envProxyEnabled || providerHttpNoProxyMatches(url, cfg)) {
        return ("", "none")
    }
    let envProxy = providerHttpEnvProxyForUrl(url)
    if (!envProxy.isEmpty()) {
        return (envProxy, "env")
    }
    ("", "none")
}

private func providerHttpProxyScheme(proxy: String): String {
    let lower = proxy.trimAscii().toAsciiLower()
    if (lower.startsWith("https://")) {
        return "https"
    }
    if (lower.startsWith("http://")) {
        return "http"
    }
    "http"
}

public func redactGatewayProviderProxy(proxy: String): String {
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

public func resolveGatewayProviderHttpRoute(url: String, cfg: GatewayProviderHttpTransportConfig): GatewayProviderHttpRoute {
    let targetHost = providerHttpTargetHost(url)
    let targetScheme = providerHttpScheme(url)
    let proxyInfo = providerHttpProxyForUrl(url, cfg)
    let proxy = proxyInfo[0]
    let source = proxyInfo[1]
    if (proxy.isEmpty()) {
        return GatewayProviderHttpRoute("direct", "none", "", targetHost)
    }
    let proxyScheme = providerHttpProxyScheme(proxy)
    if (targetScheme == "https" && proxyScheme == "https") {
        return GatewayProviderHttpRoute(
            "unsupportedHttpsProxy",
            source,
            redactGatewayProviderProxy(proxy),
            targetHost,
            error: "true HTTPS proxy is not implemented; configure an HTTP proxy or bare host:port for HTTPS CONNECT"
        )
    }
    if (targetScheme == "https") {
        return GatewayProviderHttpRoute("httpConnectTunnel", source, redactGatewayProviderProxy(proxy), targetHost)
    }
    GatewayProviderHttpRoute("httpProxy", source, redactGatewayProviderProxy(proxy), targetHost)
}

public func parseGatewayProviderHttpProxyEndpoint(proxy: String): GatewayProviderHttpProxyEndpoint {
    let trimmed = proxy.trimAscii()
    let scheme = providerHttpProxyScheme(trimmed)
    let withoutScheme = if (trimmed.toAsciiLower().startsWith("http://")) {
        trimmed[7..]
    } else if (trimmed.toAsciiLower().startsWith("https://")) {
        trimmed[8..]
    } else {
        trimmed
    }
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
    var port: UInt16 = if (scheme == "https") { 443u16 } else { 80u16 }
    match (hostPort.lastIndexOf(":")) {
        case Some(idx) =>
            host = hostPort[..idx]
            let parsed = Int64.parse(hostPort[idx + 1..])
            if (parsed > 0 && parsed <= 65535) {
                port = UInt16(parsed)
            }
        case None => ()
    }
    if (host.trimAscii().isEmpty()) {
        throw Exception("invalid provider HTTP proxy host")
    }
    GatewayProviderHttpProxyEndpoint(host.trimAscii(), port, auth: auth, scheme: scheme)
}

public func buildGatewayProviderHttpConnectRequest(targetHost: String, targetPort: UInt16, endpoint: GatewayProviderHttpProxyEndpoint): String {
    var request =
        "CONNECT ${targetHost}:${targetPort} HTTP/1.1\r\n" +
            "Host: ${targetHost}:${targetPort}\r\n" +
            "Proxy-Connection: Keep-Alive\r\n"
    if (!endpoint.auth.isEmpty()) {
        request += "Proxy-Authorization: Basic ${toBase64String(endpoint.auth.toArray())}\r\n"
    }
    request + "\r\n"
}

private func readGatewayProviderHttpConnectResponse(socket: TcpSocket): String {
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

private func openGatewayProviderHttpConnectTunnel(
    socket: TcpSocket,
    targetHost: String,
    targetPort: UInt16,
    endpoint: GatewayProviderHttpProxyEndpoint
): Unit {
    socket.write(buildGatewayProviderHttpConnectRequest(targetHost, targetPort, endpoint).toArray())
    let response = readGatewayProviderHttpConnectResponse(socket)
    let firstLine = match (response.indexOf("\r\n")) {
        case Some(idx) => response[..idx]
        case None => response
    }
    if (!firstLine.contains(" 200 ")) {
        throw Exception("provider HTTP proxy CONNECT failed: ${firstLine}")
    }
}

public func buildGatewayProviderHttpClientBuilder(url: String, cfg: GatewayProviderHttpTransportConfig): (ClientBuilder, GatewayProviderHttpRoute) {
    let route = resolveGatewayProviderHttpRoute(url, cfg)
    if (route.mode == "unsupportedHttpsProxy") {
        throw Exception(route.error)
    }
    let builder = ClientBuilder()
    builder.readTimeout(Duration.millisecond * cfg.timeoutMs)
    let proxyInfo = providerHttpProxyForUrl(url, cfg)
    if (route.mode == "httpProxy") {
        builder.httpProxy(proxyInfo[0])
    }
    if (providerHttpScheme(url) == "https") {
        var tlsConfig = TlsClientConfig()
        if (cfg.insecureSkipTlsVerify) {
            tlsConfig.verifyMode = TrustAll
        }
        tlsConfig.domain = route.targetHost
        tlsConfig.alpnProtocolsList = ["http/1.1"]
        builder.tlsConfig(tlsConfig)
    }
    if (route.mode == "httpConnectTunnel") {
        let endpoint = parseGatewayProviderHttpProxyEndpoint(proxyInfo[0])
        let connectTimeoutMs = max(1, cfg.timeoutMs)
        let targetHost = route.targetHost
        let socketConnector = { _sa: SocketAddress =>
            let socket = TcpSocket(endpoint.host, endpoint.port)
            socket.readTimeout = Duration.millisecond * connectTimeoutMs
            socket.writeTimeout = Duration.millisecond * connectTimeoutMs
            socket.connect(timeout: Duration.millisecond * connectTimeoutMs)
            openGatewayProviderHttpConnectTunnel(socket, targetHost, 443u16, endpoint)
            return socket
        }
        builder.connector(socketConnector)
    }
    (builder, route)
}
