package metis.gateway.core

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager}
import metis.core.model.{
    CliModelManager,
    CodexAppServerBinaryCheck,
    checkCodexAppServerBinary,
    codexRuntimeFallback,
    codexRuntimeReadDefaultRuntime,
    codexRuntimeSetDefaultRuntime,
    normalizeCodexRuntimeValue
}
import metis.gateway.model.{ChannelPolicyConfig, ChatType}
import metis.gateway.session.GatewayTurnContext

import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}

private var gatewayCodexRuntimeBinaryCheckForTest: Option<() -> CodexAppServerBinaryCheck> =
    None<() -> CodexAppServerBinaryCheck>

public func setGatewayCodexRuntimeBinaryCheckForTest(checker: Option<() -> CodexAppServerBinaryCheck>): Unit {
    gatewayCodexRuntimeBinaryCheckForTest = checker
}

private func gatewayCodexRuntimeIsCommand(raw: String): Bool {
    let clean = raw.trimAscii().toAsciiLower()
    clean == "/codex-runtime" || clean.startsWith("/codex-runtime ") ||
        clean == "/codex_runtime" || clean.startsWith("/codex_runtime ")
}

private func gatewayCodexRuntimeArgs(raw: String): String {
    let trimmed = raw.trimAscii()
    let commandSize = if (trimmed.toAsciiLower().startsWith("/codex_runtime")) {
        "/codex_runtime".size
    } else {
        "/codex-runtime".size
    }
    if (trimmed.size <= commandSize) {
        return ""
    }
    trimmed[commandSize..].trimAscii()
}

private func gatewayCodexRuntimeBinaryCheck(): CodexAppServerBinaryCheck {
    match (gatewayCodexRuntimeBinaryCheckForTest) {
        case Some(checker) => checker()
        case None => checkCodexAppServerBinary()
    }
}

private func gatewayCodexRuntimeCloneRoot(): JsonObject {
    match (MetisConfigManager.rawConfig()) {
        case Some(root) =>
            try {
                JsonValue.fromStr(root.toJsonString()).asObject()
            } catch (_: Exception) {
                JsonObject()
            }
        case None => JsonObject()
    }
}

private func gatewayCodexRuntimeString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) =>
            try {
                value.asString().getValue().trimAscii()
            } catch (_: Exception) {
                ""
            }
        case None => ""
    }
}

private func gatewayCodexRuntimeObject(obj: JsonObject, key: String): Option<JsonObject> {
    match (obj.get(key)) {
        case Some(value) =>
            try {
                Some(value.asObject())
            } catch (_: Exception) {
                None<JsonObject>
            }
        case None => None<JsonObject>
    }
}

private func gatewayCodexRuntimeArray(obj: JsonObject, key: String): Option<JsonArray> {
    match (obj.get(key)) {
        case Some(value) =>
            try {
                Some(value.asArray())
            } catch (_: Exception) {
                None<JsonArray>
            }
        case None => None<JsonArray>
    }
}

private func gatewayCodexRuntimeEnsureObject(obj: JsonObject, key: String): JsonObject {
    match (gatewayCodexRuntimeObject(obj, key)) {
        case Some(child) => child
        case None =>
            let child = JsonObject()
            obj.put(key, child)
            child
    }
}

private func gatewayCodexRuntimeStringArray(obj: JsonObject, key: String): Array<String> {
    let out = ArrayList<String>()
    match (gatewayCodexRuntimeArray(obj, key)) {
        case Some(arr) =>
            for (item in arr.getItems()) {
                try {
                    let text = item.asString().getValue().trimAscii()
                    if (!text.isEmpty()) {
                        out.add(text)
                    }
                } catch (_: Exception) {
                    ()
                }
            }
        case None => ()
    }
    out.toArray()
}

private func gatewayCodexRuntimeStringArrayAny(obj: JsonObject, keys: Array<String>): Array<String> {
    for (key in keys) {
        let values = gatewayCodexRuntimeStringArray(obj, key)
        if (!values.isEmpty()) {
            return values
        }
    }
    []
}

private func gatewayCodexRuntimePolicyRoot(route: JsonObject): JsonObject {
    for (key in ["slashAccess", "runtimePolicy", "policy", "groupPolicy"]) {
        match (gatewayCodexRuntimeObject(route, key)) {
            case Some(obj) =>
                if (!gatewayCodexRuntimeStringArrayAny(obj, ["allowAdminFrom", "allow_admin_from"]).isEmpty() ||
                    !gatewayCodexRuntimeStringArrayAny(obj, ["userAllowedCommands", "user_allowed_commands"]).isEmpty() ||
                    !gatewayCodexRuntimeStringArrayAny(obj, ["groupAllowAdminFrom", "group_allow_admin_from"]).isEmpty() ||
                    !gatewayCodexRuntimeStringArrayAny(obj, ["groupUserAllowedCommands", "group_user_allowed_commands"]).isEmpty()) {
                    return obj
                }
            case None => ()
        }
    }
    route
}

private func gatewayCodexRuntimeChannelPolicy(turnContext: Option<GatewayTurnContext>): ChannelPolicyConfig {
    match (turnContext) {
        case Some(ctx) =>
            let root = gatewayCodexRuntimePolicyRoot(ctx.route)
            ChannelPolicyConfig(
                allowAdminFrom: gatewayCodexRuntimeStringArrayAny(root, ["allowAdminFrom", "allow_admin_from"]),
                userAllowedCommands: gatewayCodexRuntimeStringArrayAny(root, ["userAllowedCommands", "user_allowed_commands"]),
                groupAllowAdminFrom: gatewayCodexRuntimeStringArrayAny(root, ["groupAllowAdminFrom", "group_allow_admin_from"]),
                groupUserAllowedCommands: gatewayCodexRuntimeStringArrayAny(root, ["groupUserAllowedCommands", "group_user_allowed_commands"])
            )
        case None => ChannelPolicyConfig()
    }
}

private func gatewayCodexRuntimeChatType(turnContext: Option<GatewayTurnContext>): String {
    match (turnContext) {
        case Some(ctx) =>
            match (ctx.chatType) {
                case Some(ChatType.Group) => "group"
                case Some(ChatType.Direct) => "direct"
                case None => "direct"
            }
        case None => "direct"
    }
}

private func gatewayCodexRuntimeScopedValue(agentScope: JsonObject): String {
    match (gatewayCodexRuntimeObject(agentScope, "model")) {
        case Some(model) =>
            let direct = gatewayCodexRuntimeString(model, "openaiRuntime")
            if (!direct.isEmpty()) {
                return codexRuntimeFallback(direct)
            }
            match (gatewayCodexRuntimeObject(model, "raw")) {
                case Some(raw) =>
                    let rawValue = gatewayCodexRuntimeString(raw, "openaiRuntime")
                    if (!rawValue.isEmpty()) {
                        return codexRuntimeFallback(rawValue)
                    }
                case None => ()
            }
        case None => ()
    }
    match (gatewayCodexRuntimeObject(agentScope, "runtimeDefaults")) {
        case Some(defaults) =>
            let value = gatewayCodexRuntimeString(defaults, "openaiRuntime")
            if (!value.isEmpty()) {
                return codexRuntimeFallback(value)
            }
        case None => ()
    }
    ""
}

private func gatewayCodexRuntimeAgentModel(root: JsonObject, agentId: String, create!: Bool = false): Option<JsonObject> {
    let target = agentId.trimAscii().toAsciiLower()
    if (target.isEmpty()) {
        return None<JsonObject>
    }
    match (gatewayCodexRuntimeObject(root, "agents")) {
        case Some(agents) =>
            match (gatewayCodexRuntimeArray(agents, "list")) {
                case Some(list) =>
                    for (item in list.getItems()) {
                        try {
                            let agent = item.asObject()
                            if (gatewayCodexRuntimeString(agent, "id").toAsciiLower() == target) {
                                match (gatewayCodexRuntimeObject(agent, "model")) {
                                    case Some(model) => return Some(model)
                                    case None =>
                                        if (create) {
                                            return Some(gatewayCodexRuntimeEnsureObject(agent, "model"))
                                        }
                                }
                            }
                        } catch (_: Exception) {
                            ()
                        }
                    }
                case None => ()
            }
        case None => ()
    }
    None<JsonObject>
}

private func gatewayCodexRuntimeAgentValue(root: JsonObject, agentId: String): String {
    match (gatewayCodexRuntimeAgentModel(root, agentId)) {
        case Some(model) =>
            let value = gatewayCodexRuntimeString(model, "openaiRuntime")
            if (!value.isEmpty()) {
                return codexRuntimeFallback(value)
            }
        case None => ()
    }
    ""
}

private func gatewayCodexRuntimeSetAgentValue(root: JsonObject, agentId: String, runtime: String): Bool {
    match (normalizeCodexRuntimeValue(runtime)) {
        case Some(clean) =>
            match (gatewayCodexRuntimeAgentModel(root, agentId, create: true)) {
                case Some(model) =>
                    model.put("openaiRuntime", JsonString(clean))
                    true
                case None => false
            }
        case None => false
    }
}

private func gatewayCodexRuntimeCurrentValue(turnContext: Option<GatewayTurnContext>): String {
    match (turnContext) {
        case Some(ctx) =>
            let scoped = gatewayCodexRuntimeScopedValue(ctx.agentScope)
            if (!scoped.isEmpty()) {
                return scoped
            }
            let root = gatewayCodexRuntimeCloneRoot()
            let agentValue = gatewayCodexRuntimeAgentValue(root, ctx.agentId)
            if (!agentValue.isEmpty()) {
                return agentValue
            }
            return codexRuntimeReadDefaultRuntime(root)
        case None => codexRuntimeReadDefaultRuntime(gatewayCodexRuntimeCloneRoot())
    }
}

private func gatewayCodexRuntimePersist(turnContext: Option<GatewayTurnContext>, runtime: String): Bool {
    let root = gatewayCodexRuntimeCloneRoot()
    var written = false
    match (turnContext) {
        case Some(ctx) =>
            written = gatewayCodexRuntimeSetAgentValue(root, ctx.agentId, runtime)
        case None => ()
    }
    if (!written) {
        written = codexRuntimeSetDefaultRuntime(root, runtime)
    }
    if (!written) {
        return false
    }
    try {
        MetisConfigManager.writeRoot(root)
        CliSettingManager.applyPersistedFieldsToCliConfig()
        CliConfig.invalidatePathCache()
        CliModelManager.resetRuntimeState()
        true
    } catch (_: Exception) {
        false
    }
}

private func gatewayCodexRuntimeSenderId(turnContext: Option<GatewayTurnContext>): String {
    match (turnContext) {
        case Some(ctx) => ctx.senderId
        case None => ""
    }
}

private func gatewayCodexRuntimeOperatorScopes(turnContext: Option<GatewayTurnContext>): Array<String> {
    match (turnContext) {
        case Some(ctx) => ctx.operatorScopes
        case None => []
    }
}

private func gatewayCodexRuntimeSessionKey(fallback: String, turnContext: Option<GatewayTurnContext>): String {
    match (turnContext) {
        case Some(ctx) =>
            if (!ctx.sessionKey.isEmpty()) {
                return ctx.sessionKey
            }
        case None => ()
    }
    fallback.trimAscii()
}

public func gatewayHandleCodexRuntimeCommandLine(
    raw: String,
    sessionKey: String,
    turnContext!: Option<GatewayTurnContext> = None<GatewayTurnContext>
): Option<String> {
    if (!gatewayCodexRuntimeIsCommand(raw)) {
        return None<String>
    }
    let guard = gatewayApplyRuntimeSwitchGuard(
        GatewayRuntimeSwitchGuardRequest(
            rawArgs: gatewayCodexRuntimeArgs(raw),
            channelPolicy: gatewayCodexRuntimeChannelPolicy(turnContext),
            senderId: gatewayCodexRuntimeSenderId(turnContext),
            operatorScopes: gatewayCodexRuntimeOperatorScopes(turnContext),
            chatType: gatewayCodexRuntimeChatType(turnContext),
            currentRuntime: gatewayCodexRuntimeCurrentValue(turnContext),
            binaryCheck: gatewayCodexRuntimeBinaryCheck(),
            running: false,
            readOnly: false,
            sessionKey: gatewayCodexRuntimeSessionKey(sessionKey, turnContext)
        )
    )
    if (guard.success && guard.mutated) {
        if (!gatewayCodexRuntimePersist(turnContext, guard.newValue)) {
            return Some("${guard.message}\nConfig write failed; the runtime change was not persisted.")
        }
        return Some("${guard.message}\nRuntime caches were refreshed.")
    }
    Some(guard.message)
}
