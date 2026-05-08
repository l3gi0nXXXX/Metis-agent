package metis.gateway.openclaw_capabilities

import std.collection.ArrayList

public class OpenClawCapabilityScope {
    public let channelId: String
    public let accountId: String
    public let peerId: String
    public let threadId: String

    public init(channelId: String, accountId: String, peerId: String, threadId: String) {
        this.channelId = channelId.trimAscii()
        this.accountId = accountId.trimAscii()
        this.peerId = peerId.trimAscii()
        this.threadId = threadId.trimAscii()
    }

    public func routeKey(capabilityId: String): String {
        "${this.channelId}/${this.accountId}/${this.peerId}/${this.threadId}/${capabilityId.trimAscii()}"
    }
}

public class OpenClawCommandProjection {
    public let name: String
    public let summary: String
    public let aliases: Array<String>
    public let requiredPermissions: Array<String>

    public init(
        name: String,
        summary!: String = "",
        aliases!: Array<String> = [],
        requiredPermissions!: Array<String> = []
    ) {
        this.name = name.trimAscii()
        this.summary = summary.trimAscii()
        this.aliases = aliases
        this.requiredPermissions = requiredPermissions
    }

    public func catalogKey(): String {
        this.name
    }
}

public class OpenClawHookProjection {
    public let id: String
    public let lifecycleStages: Array<String>
    public let channelSpecific: Bool

    public init(id: String, lifecycleStages: Array<String>, channelSpecific!: Bool = false) {
        this.id = id.trimAscii()
        this.lifecycleStages = lifecycleStages
        this.channelSpecific = channelSpecific
    }

    public func canDispatch(stage: String, scope: OpenClawCapabilityScope): Bool {
        let normalized = stage.trimAscii().toAsciiLower()
        if (this.channelSpecific && scope.channelId.isEmpty()) {
            return false
        }
        this.lifecycleStages.contains(normalized)
    }
}

public class OpenClawRoutedProjection {
    public let id: String
    public let scope: OpenClawCapabilityScope

    public init(id: String, scope: OpenClawCapabilityScope) {
        this.id = id.trimAscii()
        this.scope = scope
    }

    public func routeKey(): String {
        this.scope.routeKey(this.id)
    }
}

public class OpenClawCommandDispatchRequest {
    public let name: String
    public let inputJson: String
    public let scope: OpenClawCapabilityScope

    public init(name: String, inputJson!: String = "{}", scope!: OpenClawCapabilityScope = OpenClawCapabilityScope("", "", "", "")) {
        this.name = name.trimAscii()
        this.inputJson = inputJson
        this.scope = scope
    }
}

public class OpenClawCommandDispatchResult {
    public let ok: Bool
    public let status: String
    public let payloadJson: String
    public let evidenceJson: String

    public init(ok: Bool, status!: String = "ok", payloadJson!: String = "{}", evidenceJson!: String = "{}") {
        this.ok = ok
        this.status = status.trimAscii()
        this.payloadJson = payloadJson
        this.evidenceJson = evidenceJson
    }
}

public class OpenClawCommandCatalogEntry {
    public let projection: OpenClawCommandProjection
    private let dispatcher: (OpenClawCommandDispatchRequest) -> OpenClawCommandDispatchResult

    public init(projection: OpenClawCommandProjection, dispatcher: (OpenClawCommandDispatchRequest) -> OpenClawCommandDispatchResult) {
        this.projection = projection
        this.dispatcher = dispatcher
    }

    public func matches(raw: String): Bool {
        let normalized = raw.trimAscii()
        if (this.projection.name == normalized) {
            return true
        }
        for (alias in this.projection.aliases) {
            if (alias.trimAscii() == normalized) {
                return true
            }
        }
        false
    }

    public func dispatch(request: OpenClawCommandDispatchRequest): OpenClawCommandDispatchResult {
        this.dispatcher(request)
    }
}

public class OpenClawCommandCatalog {
    private let entries = ArrayList<OpenClawCommandCatalogEntry>()
    private let cliEntries = ArrayList<OpenClawCommandCatalogEntry>()

    public init() {}

    public func register(command: OpenClawCommandProjection): Unit {
        this.register(command, { request: OpenClawCommandDispatchRequest =>
            OpenClawCommandDispatchResult(
                false,
                status: "not_supported",
                evidenceJson: "{\"kind\":\"command\",\"command\":\"${request.name}\",\"status\":\"not_supported\",\"reason\":\"dispatcher_not_configured\"}"
            )
        })
    }

    public func register(command: OpenClawCommandProjection, dispatcher: (OpenClawCommandDispatchRequest) -> OpenClawCommandDispatchResult): Unit {
        this.entries.add(OpenClawCommandCatalogEntry(command, dispatcher))
    }

    public func registerCli(command: OpenClawCommandProjection, dispatcher: (OpenClawCommandDispatchRequest) -> OpenClawCommandDispatchResult): Unit {
        this.cliEntries.add(OpenClawCommandCatalogEntry(command, dispatcher))
    }

    public func list(): Array<OpenClawCommandProjection> {
        let out = ArrayList<OpenClawCommandProjection>()
        for (entry in this.entries) {
            out.add(entry.projection)
        }
        out.toArray()
    }

    public func listCli(): Array<OpenClawCommandProjection> {
        let out = ArrayList<OpenClawCommandProjection>()
        for (entry in this.cliEntries) {
            out.add(entry.projection)
        }
        out.toArray()
    }

    public func contains(raw: String): Bool {
        for (entry in this.entries) {
            if (entry.matches(raw)) {
                return true
            }
        }
        false
    }

    public func dispatch(request: OpenClawCommandDispatchRequest): OpenClawCommandDispatchResult {
        this.dispatchFrom(this.entries, request, "command")
    }

    public func dispatchCli(request: OpenClawCommandDispatchRequest): OpenClawCommandDispatchResult {
        this.dispatchFrom(this.cliEntries, request, "cli")
    }

    private func dispatchFrom(entries: ArrayList<OpenClawCommandCatalogEntry>, request: OpenClawCommandDispatchRequest, kind: String): OpenClawCommandDispatchResult {
        for (entry in entries) {
            if (entry.matches(request.name)) {
                return entry.dispatch(request)
            }
        }
        OpenClawCommandDispatchResult(
            false,
            status: "not_supported",
            evidenceJson: "{\"kind\":\"${kind}\",\"command\":\"${request.name}\",\"status\":\"not_supported\",\"reason\":\"command_not_registered\"}"
        )
    }
}

public class OpenClawLifecycleHookEvent {
    public let stage: String
    public let payloadJson: String
    public let scope: OpenClawCapabilityScope

    public init(stage: String, payloadJson: String, scope: OpenClawCapabilityScope) {
        this.stage = stage.trimAscii().toAsciiLower()
        this.payloadJson = payloadJson
        this.scope = scope
    }
}

public class OpenClawLifecycleHookResult {
    public let ok: Bool
    public let status: String
    public let payloadJson: String
    public let evidenceJson: String

    public init(ok: Bool, status!: String = "ok", payloadJson!: String = "{}", evidenceJson!: String = "{}") {
        this.ok = ok
        this.status = status.trimAscii()
        this.payloadJson = payloadJson
        this.evidenceJson = evidenceJson
    }
}

public class OpenClawLifecycleHookRegistryEntry {
    public let projection: OpenClawHookProjection
    private let dispatcher: (OpenClawLifecycleHookEvent) -> OpenClawLifecycleHookResult

    public init(projection: OpenClawHookProjection, dispatcher: (OpenClawLifecycleHookEvent) -> OpenClawLifecycleHookResult) {
        this.projection = projection
        this.dispatcher = dispatcher
    }

    public func dispatch(event: OpenClawLifecycleHookEvent): OpenClawLifecycleHookResult {
        this.dispatcher(event)
    }
}

public class OpenClawLifecycleHookRegistry {
    private let entries = ArrayList<OpenClawLifecycleHookRegistryEntry>()

    public init() {}

    public func register(projection: OpenClawHookProjection, dispatcher: (OpenClawLifecycleHookEvent) -> OpenClawLifecycleHookResult): Unit {
        this.entries.add(OpenClawLifecycleHookRegistryEntry(projection, dispatcher))
    }

    public func dispatch(event: OpenClawLifecycleHookEvent): Array<OpenClawLifecycleHookResult> {
        let out = ArrayList<OpenClawLifecycleHookResult>()
        for (entry in this.entries) {
            if (entry.projection.canDispatch(event.stage, event.scope)) {
                out.add(entry.dispatch(event))
            }
        }
        out.toArray()
    }

    public func dispatchOne(event: OpenClawLifecycleHookEvent): OpenClawLifecycleHookResult {
        for (entry in this.entries) {
            if (entry.projection.canDispatch(event.stage, event.scope)) {
                return entry.dispatch(event)
            }
        }
        OpenClawLifecycleHookResult(
            false,
            status: "not_supported",
            evidenceJson: "{\"kind\":\"hook\",\"stage\":\"${event.stage}\",\"status\":\"not_supported\",\"reason\":\"hook_not_registered\"}"
        )
    }
}

public class OpenClawScopedDispatchRequest {
    public let id: String
    public let scope: OpenClawCapabilityScope
    public let payloadJson: String

    public init(id: String, scope: OpenClawCapabilityScope, payloadJson!: String = "{}") {
        this.id = id.trimAscii()
        this.scope = scope
        this.payloadJson = payloadJson
    }
}

public class OpenClawScopedDispatchResult {
    public let ok: Bool
    public let status: String
    public let payloadJson: String

    public init(ok: Bool, status!: String = "ok", payloadJson!: String = "{}") {
        this.ok = ok
        this.status = status.trimAscii()
        this.payloadJson = payloadJson
    }
}

public class OpenClawScopedDispatchRegistryEntry {
    public let route: OpenClawRoutedProjection
    private let dispatcher: (OpenClawScopedDispatchRequest) -> OpenClawScopedDispatchResult

    public init(route: OpenClawRoutedProjection, dispatcher: (OpenClawScopedDispatchRequest) -> OpenClawScopedDispatchResult) {
        this.route = route
        this.dispatcher = dispatcher
    }

    public func dispatch(request: OpenClawScopedDispatchRequest): OpenClawScopedDispatchResult {
        this.dispatcher(request)
    }
}

public class OpenClawScopedDispatchRegistry {
    private let approvals = ArrayList<OpenClawScopedDispatchRegistryEntry>()
    private let interactives = ArrayList<OpenClawScopedDispatchRegistryEntry>()

    public init() {}

    public func registerApproval(route: OpenClawRoutedProjection, dispatcher: (OpenClawScopedDispatchRequest) -> OpenClawScopedDispatchResult): Unit {
        this.approvals.add(OpenClawScopedDispatchRegistryEntry(route, dispatcher))
    }

    public func registerInteractive(route: OpenClawRoutedProjection, dispatcher: (OpenClawScopedDispatchRequest) -> OpenClawScopedDispatchResult): Unit {
        this.interactives.add(OpenClawScopedDispatchRegistryEntry(route, dispatcher))
    }

    public func dispatchApproval(request: OpenClawScopedDispatchRequest): OpenClawScopedDispatchResult {
        this.dispatchScoped(this.approvals, request)
    }

    public func dispatchInteractive(request: OpenClawScopedDispatchRequest): OpenClawScopedDispatchResult {
        this.dispatchScoped(this.interactives, request)
    }

    private func dispatchScoped(entries: ArrayList<OpenClawScopedDispatchRegistryEntry>, request: OpenClawScopedDispatchRequest): OpenClawScopedDispatchResult {
        let requestedKey = request.scope.routeKey(request.id)
        for (entry in entries) {
            if (entry.route.routeKey() == requestedKey) {
                return entry.dispatch(request)
            }
        }
        OpenClawScopedDispatchResult(false, status: "handler_not_found", payloadJson: "{\"ok\":false,\"status\":\"handler_not_found\"}")
    }
}
