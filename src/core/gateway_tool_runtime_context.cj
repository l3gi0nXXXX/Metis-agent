package metis.core

import std.collection.{ArrayList, HashMap}
import std.sync.Mutex
import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

private func gatewayToolRuntimeCloneObject(value: JsonObject): JsonObject {
    try {
        JsonValue.fromStr(value.toJsonString()).asObject()
    } catch (_: Exception) {
        JsonObject()
    }
}

public class GatewayToolRuntimeContext {
    public let sourceLabel: String
    public let channelName: String
    public let sessionKey: String
    public let senderId: String
    public let declaredUser: String
    public let agentId: String
    public let workspaceDir: String
    public let agentDir: String
    public let modelsJsonPath: String
    public let authProfilesPath: String
    public let operatorScopes: Array<String>
    public let prompt: String
    public let mediaContext: JsonObject
    public let memorySearchPolicy: JsonObject
    public let cronJobId: String
    public let toolExecMode: String
    public let toolExecAllowlist: Array<String>
    public let lifecycleHook: Option<(String) -> Unit>
    public let gatewayCallHook: Option<(String, JsonObject) -> JsonObject>
    public let remainingMsHook: Option<() -> Int64>
    public let heartbeatHook: Option<() -> Unit>
    public let cancellationCheckHook: Option<() -> Unit>
    private var visibleReplyDelivered: Bool = false

    public init(
        sourceLabel: String,
        channelName!: String = "",
        sessionKey!: String = "",
        senderId!: String = "",
        declaredUser!: String = "",
        agentId!: String = "",
        workspaceDir!: String = "",
        agentDir!: String = "",
        modelsJsonPath!: String = "",
        authProfilesPath!: String = "",
        operatorScopes!: Array<String> = [],
        prompt!: String = "",
        mediaContext!: JsonObject = JsonObject(),
        memorySearchPolicy!: JsonObject = JsonObject(),
        cronJobId!: String = "",
        toolExecMode!: String = "",
        toolExecAllowlist!: Array<String> = [],
        lifecycleHook!: Option<(String) -> Unit> = None<(String) -> Unit>,
        gatewayCallHook!: Option<(String, JsonObject) -> JsonObject> = None<(String, JsonObject) -> JsonObject>,
        remainingMsHook!: Option<() -> Int64> = None<() -> Int64>,
        heartbeatHook!: Option<() -> Unit> = None<() -> Unit>,
        cancellationCheckHook!: Option<() -> Unit> = None<() -> Unit>
    ) {
        this.sourceLabel = sourceLabel.trimAscii().toAsciiLower()
        this.channelName = channelName.trimAscii().toAsciiLower()
        this.sessionKey = sessionKey.trimAscii()
        this.senderId = senderId.trimAscii()
        this.declaredUser = declaredUser.trimAscii()
        this.agentId = agentId.trimAscii()
        this.workspaceDir = workspaceDir.trimAscii()
        this.agentDir = agentDir.trimAscii()
        this.modelsJsonPath = modelsJsonPath.trimAscii()
        this.authProfilesPath = authProfilesPath.trimAscii()
        let normalizedScopes = ArrayList<String>()
        for (scope in operatorScopes) {
            let normalized = scope.trimAscii().toAsciiLower()
            if (!normalized.isEmpty() && !normalizedScopes.contains(normalized)) {
                normalizedScopes.add(normalized)
            }
        }
        this.operatorScopes = normalizedScopes.toArray()
        this.prompt = prompt
        this.mediaContext = mediaContext
        this.memorySearchPolicy = gatewayToolRuntimeCloneObject(memorySearchPolicy)
        this.cronJobId = cronJobId.trimAscii()
        this.toolExecMode = toolExecMode.trimAscii().toAsciiLower()
        let normalizedAllowlist = ArrayList<String>()
        for (entry in toolExecAllowlist) {
            let trimmed = entry.trimAscii()
            if (!trimmed.isEmpty() && !normalizedAllowlist.contains(trimmed)) {
                normalizedAllowlist.add(trimmed)
            }
        }
        this.toolExecAllowlist = normalizedAllowlist.toArray()
        this.lifecycleHook = lifecycleHook
        this.gatewayCallHook = gatewayCallHook
        this.remainingMsHook = remainingMsHook
        this.heartbeatHook = heartbeatHook
        this.cancellationCheckHook = cancellationCheckHook
    }

    public func notifyLifecycleStatus(status: String): Unit {
        let normalized = status.trimAscii().toAsciiLower()
        if (normalized.isEmpty()) {
            return
        }
        match (this.lifecycleHook) {
            case Some(hook) =>
                try {
                    hook(normalized)
                } catch (_e: Exception) {
                    ()
                }
            case None => ()
        }
    }

    public func markVisibleReplyDelivered(): Unit {
        this.visibleReplyDelivered = true
    }

    public func hasVisibleReplyDelivered(): Bool {
        this.visibleReplyDelivered
    }
}

private let gatewayToolRuntimeContextLock = Mutex()
private let gatewayToolRuntimeContextByThread = HashMap<Int64, ArrayList<GatewayToolRuntimeContext>>()

private func gatewayToolRuntimeThreadKey(): Int64 {
    Thread.currentThread.id
}

private func gatewayToolRuntimeContextStack(threadKey: Int64): ArrayList<GatewayToolRuntimeContext> {
    match (gatewayToolRuntimeContextByThread.get(threadKey)) {
        case Some(existing) => existing
        case None =>
            let created = ArrayList<GatewayToolRuntimeContext>()
            gatewayToolRuntimeContextByThread[threadKey] = created
            created
    }
}

public func gatewayPushToolRuntimeContext(context: GatewayToolRuntimeContext): Unit {
    synchronized(gatewayToolRuntimeContextLock) {
        gatewayToolRuntimeContextStack(gatewayToolRuntimeThreadKey()).add(context)
    }
}

public func gatewayPopToolRuntimeContext(): Unit {
    synchronized(gatewayToolRuntimeContextLock) {
        let threadKey = gatewayToolRuntimeThreadKey()
        match (gatewayToolRuntimeContextByThread.get(threadKey)) {
            case Some(stack) =>
                if (stack.size > 0) {
                    stack.remove(at: stack.size - 1)
                }
                if (stack.size == 0) {
                    gatewayToolRuntimeContextByThread.remove(threadKey)
                }
            case None => ()
        }
    }
}

public func gatewayCurrentToolRuntimeContext(): Option<GatewayToolRuntimeContext> {
    synchronized(gatewayToolRuntimeContextLock) {
        match (gatewayToolRuntimeContextByThread.get(gatewayToolRuntimeThreadKey())) {
            case Some(stack) =>
                if (stack.size > 0) {
                    Some(stack[stack.size - 1])
                } else {
                    None<GatewayToolRuntimeContext>
                }
            case None => None<GatewayToolRuntimeContext>
        }
    }
}

public func gatewayCurrentToolRemainingMs(defaultMs!: Int64 = 0): Int64 {
    match (gatewayCurrentToolRuntimeContext()) {
        case Some(context) => match (context.remainingMsHook) {
            case Some(read) => read()
            case None => defaultMs
        }
        case None => defaultMs
    }
}

public func gatewayCheckCurrentToolCancellation(): Unit {
    match (gatewayCurrentToolRuntimeContext()) {
        case Some(context) => match (context.cancellationCheckHook) {
            case Some(check) => check()
            case None => ()
        }
        case None => ()
    }
}

public func gatewayHeartbeatCurrentToolExecution(): Unit {
    match (gatewayCurrentToolRuntimeContext()) {
        case Some(context) => match (context.heartbeatHook) {
            case Some(heartbeat) => heartbeat()
            case None => ()
        }
        case None => ()
    }
}

public func gatewayToolRuntimeContextDebugSummary(context: GatewayToolRuntimeContext): JsonObject {
    let out = JsonObject()
    out.put("sourceLabel", JsonString(context.sourceLabel))
    out.put("channelName", JsonString(context.channelName))
    out.put("sessionKey", JsonString(context.sessionKey))
    out.put("cronJobId", JsonString(context.cronJobId))
    out.put("toolExecMode", JsonString(context.toolExecMode))
    out.put("allowlistSize", JsonInt(context.toolExecAllowlist.size))
    out
}

public func gatewayNotifyCurrentToolRuntimeStatus(status: String): Unit {
    match (gatewayCurrentToolRuntimeContext()) {
        case Some(context) => context.notifyLifecycleStatus(status)
        case None => ()
    }
}

public func gatewayMarkCurrentToolRuntimeVisibleReplyDelivered(): Unit {
    match (gatewayCurrentToolRuntimeContext()) {
        case Some(context) => context.markVisibleReplyDelivered()
        case None => ()
    }
}

public func gatewayInvokeCurrentToolRuntimeGatewayCall(method: String, params: JsonObject): Option<JsonObject> {
    match (gatewayCurrentToolRuntimeContext()) {
        case Some(context) =>
            match (context.gatewayCallHook) {
                case Some(hook) =>
                    try {
                        return Some(hook(method.trimAscii(), params))
                    } catch (e: Exception) {
                        let out = JsonObject()
                        out.put("ok", JsonBool(false))
                        out.put("status", JsonString("error"))
                        out.put("method", JsonString(method.trimAscii()))
                        out.put("error", JsonString(e.message))
                        return Some(out)
                    }
                case None => ()
            }
        case None => ()
    }
    None<JsonObject>
}

public func gatewayWithToolRuntimeContext<T>(context: GatewayToolRuntimeContext, block: () -> T): T {
    gatewayPushToolRuntimeContext(context)
    try {
        block()
    } finally {
        gatewayPopToolRuntimeContext()
    }
}
