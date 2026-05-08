package metis.core.tools

import metis.gateway.openclaw_sandbox.OpenClawSandboxGrantSet

import std.collection.ArrayList

public class OpenClawToolResultShape {
    public let okKey: String
    public let contentKey: String
    public let errorKey: String

    public init(okKey: String, contentKey: String, errorKey: String) {
        this.okKey = okKey.trimAscii()
        this.contentKey = contentKey.trimAscii()
        this.errorKey = errorKey.trimAscii()
    }
}

public class OpenClawToolRegistration {
    public let name: String
    public let inputSchema: String
    public let requiredPermissions: Array<String>
    public let timeoutMs: Int64
    public let contextScopes: Array<String>
    public let resultShape: OpenClawToolResultShape

    public init(
        name: String,
        inputSchema: String,
        requiredPermissions!: Array<String> = [],
        timeoutMs!: Int64 = 0,
        contextScopes!: Array<String> = [],
        resultOkKey!: String = "ok",
        resultContentKey!: String = "content",
        resultErrorKey!: String = "error"
    ) {
        this.name = name.trimAscii()
        this.inputSchema = inputSchema
        this.requiredPermissions = requiredPermissions
        this.timeoutMs = timeoutMs
        this.contextScopes = contextScopes
        this.resultShape = OpenClawToolResultShape(resultOkKey, resultContentKey, resultErrorKey)
    }
}

public class OpenClawToolProjection {
    public let name: String
    public let inputSchema: String
    public let requiredPermissions: Array<String>
    public let timeoutMs: Int64
    public let contextScopes: Array<String>
    public let resultShape: OpenClawToolResultShape
    public let allowed: Bool
    public let missingPermissions: Array<String>

    public init(registration: OpenClawToolRegistration, grants: OpenClawSandboxGrantSet) {
        this.name = registration.name
        this.inputSchema = registration.inputSchema
        this.requiredPermissions = registration.requiredPermissions
        this.timeoutMs = registration.timeoutMs
        this.contextScopes = registration.contextScopes
        this.resultShape = registration.resultShape
        this.missingPermissions = grants.missing(registration.requiredPermissions)
        this.allowed = this.missingPermissions.isEmpty()
    }
}

public class OpenClawToolBridge {
    public static func project(registration: OpenClawToolRegistration, grants: OpenClawSandboxGrantSet): OpenClawToolProjection {
        OpenClawToolProjection(registration, grants)
    }
}

public class OpenClawToolDispatchRequest {
    public let name: String
    public let inputJson: String
    public let channelId: String
    public let accountId: String
    public let peerId: String
    public let threadId: String

    public init(
        name: String,
        inputJson!: String = "{}",
        channelId!: String = "",
        accountId!: String = "",
        peerId!: String = "",
        threadId!: String = ""
    ) {
        this.name = name.trimAscii()
        this.inputJson = inputJson
        this.channelId = channelId.trimAscii()
        this.accountId = accountId.trimAscii()
        this.peerId = peerId.trimAscii()
        this.threadId = threadId.trimAscii()
    }
}

public class OpenClawToolDispatchResult {
    public let ok: Bool
    public let content: String
    public let error: String
    public let rawJson: String

    public init(ok: Bool, content!: String = "", error!: String = "", rawJson!: String = "") {
        this.ok = ok
        this.content = content
        this.error = error
        this.rawJson = rawJson
    }
}

public class OpenClawMetisToolRegistryEntry {
    public let projection: OpenClawToolProjection
    private let dispatcher: (OpenClawToolDispatchRequest) -> OpenClawToolDispatchResult

    public init(projection: OpenClawToolProjection, dispatcher: (OpenClawToolDispatchRequest) -> OpenClawToolDispatchResult) {
        this.projection = projection
        this.dispatcher = dispatcher
    }

    public func dispatch(request: OpenClawToolDispatchRequest): OpenClawToolDispatchResult {
        this.dispatcher(request)
    }
}

public class OpenClawMetisToolRegistry {
    private let entries = ArrayList<OpenClawMetisToolRegistryEntry>()

    public init() {}

    public func register(projection: OpenClawToolProjection, dispatcher: (OpenClawToolDispatchRequest) -> OpenClawToolDispatchResult): Unit {
        this.entries.add(OpenClawMetisToolRegistryEntry(projection, dispatcher))
    }

    public func list(): Array<OpenClawToolProjection> {
        let out = ArrayList<OpenClawToolProjection>()
        for (entry in this.entries) {
            out.add(entry.projection)
        }
        out.toArray()
    }

    public func dispatch(request: OpenClawToolDispatchRequest): OpenClawToolDispatchResult {
        for (entry in this.entries) {
            if (entry.projection.name == request.name.trimAscii()) {
                if (!entry.projection.allowed) {
                    return OpenClawToolDispatchResult(false, error: "permission_denied", rawJson: "{\"ok\":false,\"error\":\"permission_denied\"}")
                }
                return entry.dispatch(request)
            }
        }
        OpenClawToolDispatchResult(false, error: "tool_not_found", rawJson: "{\"ok\":false,\"error\":\"tool_not_found\"}")
    }
}
