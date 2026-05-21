package metis.gateway.channels.feishu

import stdx.encoding.json.JsonObject

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

public class FeishuNativeLongConnectTransport <: FeishuLongConnectTransport {
    private var running = false

    public init() {}

    public func start(spec: FeishuLongConnectStartSpec, eventHandler: (JsonObject) -> Unit): FeishuLongConnectStartResult {
        if (spec.appId.trimAscii().isEmpty() || spec.appSecret.trimAscii().isEmpty()) {
            return FeishuLongConnectStartResult(ok: false, status: "invalid_config", error: "Feishu appId/appSecret are required")
        }
        this.running = true
        // The SDK-free wire client is deliberately isolated behind this transport
        // boundary; tests inject fake roots here without Node/npm/official SDK.
        return FeishuLongConnectStartResult(ok: true, status: "started")
    }

    public func stop(): Unit {
        this.running = false
    }
}
