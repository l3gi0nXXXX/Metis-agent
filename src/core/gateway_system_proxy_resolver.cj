package metis.core

import std.convert.*
import std.process.executeWithOutput

public interface GatewaySystemProxyReader {
    func readSystemProxy(): String
}

public class GatewayNoopSystemProxyReader <: GatewaySystemProxyReader {
    public init() {}

    public func readSystemProxy(): String {
        ""
    }
}

public class GatewayScutilSystemProxyReader <: GatewaySystemProxyReader {
    public init() {}

    public func readSystemProxy(): String {
        try {
            let (exitCode, stdoutBytes, _) = executeWithOutput("scutil", ["--proxy"])
            if (exitCode != 0) {
                return ""
            }
            return parseGatewayScutilProxy(String.fromUtf8(stdoutBytes))
        } catch (_: Exception) {
            return ""
        }
    }
}

private func gatewayScutilValue(raw: String, key: String): String {
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

private func gatewayScutilEnabled(raw: String, key: String): Bool {
    let value = gatewayScutilValue(raw, key).toAsciiLower()
    value.isEmpty() || value == "1" || value == "true" || value == "yes"
}

private func gatewayScutilProxyCandidate(raw: String, prefix: String, scheme: String, defaultPort: UInt16): String {
    if (!gatewayScutilEnabled(raw, "${prefix}Enable")) {
        return ""
    }
    let host = gatewayScutilValue(raw, "${prefix}Proxy")
    if (host.isEmpty()) {
        return ""
    }
    var port = defaultPort
    let portText = gatewayScutilValue(raw, "${prefix}Port")
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

public func parseGatewayScutilProxy(raw: String): String {
    let httpsProxy = gatewayScutilProxyCandidate(raw, "HTTPS", "http", 443u16)
    if (!httpsProxy.isEmpty()) {
        return httpsProxy
    }
    let httpProxy = gatewayScutilProxyCandidate(raw, "HTTP", "http", 80u16)
    if (!httpProxy.isEmpty()) {
        return httpProxy
    }
    gatewayScutilProxyCandidate(raw, "SOCKS", "socks5", 1080u16)
}

public func resolveGatewaySystemProxy(systemProxyReader!: GatewaySystemProxyReader = GatewayScutilSystemProxyReader()): String {
    systemProxyReader.readSystemProxy().trimAscii()
}
