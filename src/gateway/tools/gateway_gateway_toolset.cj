package metis.gateway.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*

import metis.core.{GatewayToolRuntimeContext, gatewayActionIsProtectedPathSensitive, gatewayActionIsReadOnly, gatewayActionNormalize, gatewayConfigPathIsProtected, gatewayActionRequiresExplicitUserRequest, gatewayActionRequiresOwner, gatewayCurrentToolRuntimeContext, gatewayInvokeCurrentToolRuntimeGatewayCall}
import metis.core.config.{CliSettingManager, GatewayUserSettings, MetisPaths}
import metis.io.PrintUtils

import std.fs.{Path, exists}
import std.process.executeWithOutput

import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

public func gatewayToolRequiresOwnerApproval(action: String): Bool {
    gatewayActionRequiresOwner(action)
}

public func gatewayToolRequiresExplicitRequestApproval(action: String): Bool {
    gatewayActionRequiresExplicitUserRequest(action)
}

private func gatewayToolRpcEnvelope(
    method: String,
    ok!: Bool,
    result!: JsonValue = JsonObject(),
    error!: String = "",
    errorCode!: String = ""
): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(ok))
    out.put("method", JsonString(method.trimAscii()))
    out.put("requestId", JsonString(""))
    if (ok) {
        out.put("result", result)
    } else {
        out.put("error", JsonString(error))
        out.put("errorCode", JsonString(errorCode))
        out.put("details", JsonObject())
    }
    out
}

private func gatewayToolConfigValueAtPath(user: GatewayUserSettings, path: String): Option<JsonValue> {
    let normalized = path.trimAscii().toAsciiLower()
    if (normalized.isEmpty() || normalized == "gateway") {
        return Some(user.toJsonValue())
    }
    match (normalized) {
        case "enabled" | "gateway.enabled" => Some(user.enabled.toJsonValue())
        case "port" | "gateway.port" => Some(user.port.toJsonValue())
        case "mode" | "gateway.mode" => Some(JsonString(user.mode))
        case "bind" | "gateway.bind" => Some(JsonString(user.bind))
        case "custombindhost" | "gateway.custombindhost" => Some(JsonString(user.customBindHost))
        case "session" | "gateway.session" => Some(user.session.toJsonValue())
        case "session.dmscope" | "gateway.session.dmscope" => Some(JsonString(user.session.dmScope))
        case "session.persistenceenabled" | "gateway.session.persistenceenabled" => Some(user.session.persistenceEnabled.toJsonValue())
        case "feishu" | "gateway.feishu" => Some(user.feishu.toJsonValue())
        case "qq" | "gateway.qq" => Some(user.qq.toJsonValue())
        case "telegram" | "gateway.telegram" => Some(user.telegram.toJsonValue())
        case "tools" | "gateway.tools" => Some(user.tools.toJsonValue())
        case "gatewayplugins" | "gateway.gatewayplugins" => Some(user.gatewayPlugins.toJsonValue())
        case "channelmodels" | "gateway.channelmodels" => Some(user.channelModels.toJsonValue())
        case "tls" | "gateway.tls" => Some(user.tls.toJsonValue())
        case "discovery" | "gateway.discovery" => Some(user.discovery.toJsonValue())
        case "controlui" | "gateway.controlui" => Some(user.controlUi.toJsonValue())
        case "auth" | "gateway.auth" => Some(user.auth.toJsonValue())
        case "tailscale" | "gateway.tailscale" => Some(user.tailscale.toJsonValue())
        case "remote" | "gateway.remote" => Some(user.remote.toJsonValue())
        case "reload" | "gateway.reload" => Some(user.reload.toJsonValue())
        case "http" | "gateway.http" => Some(user.http.toJsonValue())
        case "push" | "gateway.push" => Some(user.push.toJsonValue())
        case "nodes" | "gateway.nodes" => Some(user.nodes.toJsonValue())
        case "canvas" | "gateway.canvas" => Some(user.canvas.toJsonValue())
        case "talk" | "gateway.talk" => Some(user.talk.toJsonValue())
        case "webchat" | "gateway.webchat" => Some(user.webchat.toJsonValue())
        case "trustedproxies" | "gateway.trustedproxies" => Some(user.trustedProxies.toJsonValue())
        case "allowrealipfallback" | "gateway.allowrealipfallback" => Some(user.allowRealIpFallback.toJsonValue())
        case "channelsextra" | "gateway.channelsextra" =>
            match (user.channelsExtra) {
                case Some(v) => Some(v)
                case None => Some(JsonObject())
            }
        case _ => None<JsonValue>
    }
}

private func gatewayToolSchemaLookup(path: String): String {
    let normalized = path.trimAscii().toAsciiLower()
    match (normalized) {
        case "" | "gateway" =>
            "gateway: root object. Keys include enabled, port, mode, bind, session, feishu, qq, telegram, discovery, tls, controlUi, auth, remote, reload, http, push, nodes, canvas, talk, tools, gatewayPlugins, channelsExtra."
        case "enabled" | "gateway.enabled" =>
            "gateway.enabled: Bool. Master switch for the gateway runtime."
        case "port" | "gateway.port" =>
            "gateway.port: Int64. Primary gateway listen port."
        case "mode" | "gateway.mode" =>
            "gateway.mode: String. Gateway mode hint."
        case "bind" | "gateway.bind" =>
            "gateway.bind: String. Bind policy such as loopback, lan, auto, custom, or tailnet."
        case "session" | "gateway.session" =>
            "gateway.session: object. Keys: dmScope (String), persistenceEnabled (Bool)."
        case "feishu" | "gateway.feishu" =>
            "gateway.feishu: object. Feishu channel configuration."
        case "qq" | "gateway.qq" =>
            "gateway.qq: object. QQ channel configuration."
        case "telegram" | "gateway.telegram" =>
            "gateway.telegram: object. Telegram Bot API channel configuration."
        case "discovery" | "gateway.discovery" =>
            "gateway.discovery: object. Keys: wideArea, mdns."
        case "tls" | "gateway.tls" =>
            "gateway.tls: object. Keys: enabled, autoGenerate, certPath, keyPath, caPath."
        case "controlui" | "gateway.controlui" =>
            "gateway.controlUi: object. Control UI config surface."
        case "auth" | "gateway.auth" =>
            "gateway.auth: object. Keys: mode, token, password, allowTailscale, rateLimit, trustedProxy."
        case "http" | "gateway.http" =>
            "gateway.http: object. HTTP endpoints and security headers."
        case "gatewayplugins" | "gateway.gatewayplugins" =>
            "gateway.gatewayPlugins: array<object>. Each item has id and enabled."
        case _ =>
            "Unknown gateway config path: ${path.trimAscii()}"
    }
}

private func gatewayToolParamPath(params: Option<JsonObject>): String {
    match (params) {
        case Some(obj) =>
            match (obj.get("path")) {
                case Some(v) =>
                    let raw = try { v.asString().getValue().trimAscii() } catch (_: Exception) { "gateway" }
                    if (raw.isEmpty()) { "gateway" } else { raw }
                case None => "gateway"
            }
        case None => "gateway"
    }
}

private func gatewayToolInProcessConfigGet(method: String, params: Option<JsonObject>): JsonObject {
    let path = gatewayToolParamPath(params)
    match (gatewayToolConfigValueAtPath(CliSettingManager.readGatewaySettings(), path)) {
        case Some(value) =>
            let result = JsonObject()
            result.put("path", JsonString(path))
            result.put("value", value)
            gatewayToolRpcEnvelope(method, ok: true, result: result)
        case None =>
            gatewayToolRpcEnvelope(method, ok: false, error: "Unknown gateway config path.", errorCode: "unknown_config_path")
    }
}

private func gatewayToolInProcessSchemaLookup(method: String, params: Option<JsonObject>): JsonObject {
    let path = gatewayToolParamPath(params)
    let result = JsonObject()
    result.put("path", JsonString(path))
    result.put("schema", JsonString(gatewayToolSchemaLookup(path)))
    gatewayToolRpcEnvelope(method, ok: true, result: result)
}

public func gatewayToolAutoOwnerApprovedForSource(sourceLabel: String): Bool {
    let normalized = sourceLabel.trimAscii().toAsciiLower()
    normalized == "cli" || normalized == "control-ui" || normalized == "dashboard" || normalized == "cron"
}

private func gatewayToolScopeAllowsOwner(scopes: Array<String>): Bool {
    for (scope in scopes) {
        let normalized = scope.trimAscii().toAsciiLower()
        if (normalized == "admin" ||
            normalized == "write" ||
            normalized == "approvals" ||
            normalized == "operator" ||
            normalized == "operator.admin" ||
            normalized == "operator.write") {
            return true
        }
    }
    false
}

public func gatewayToolAutoOwnerApprovedForRuntimeContext(context: GatewayToolRuntimeContext): Bool {
    if (gatewayToolScopeAllowsOwner(context.operatorScopes)) {
        return true
    }
    if (!context.declaredUser.trimAscii().isEmpty() && gatewayToolAutoOwnerApprovedForSource(context.sourceLabel)) {
        return true
    }
    gatewayToolAutoOwnerApprovedForSource(context.sourceLabel)
}

private func gatewayToolPromptContainsAny(prompt: String, terms: Array<String>): Bool {
    let normalizedPrompt = prompt.trimAscii().toAsciiLower()
    if (normalizedPrompt.isEmpty()) {
        return false
    }
    for (term in terms) {
        let normalized = term.trimAscii().toAsciiLower()
        if (!normalized.isEmpty() && normalizedPrompt.contains(normalized)) {
            return true
        }
    }
    false
}

public func gatewayToolInfersExplicitRequestFromPrompt(
    action: String,
    prompt: String,
    path!: Option<String> = None<String>
): Bool {
    let normalized = gatewayActionNormalize(action)
    let normalizedPath = match (path) {
        case Some(value) => value.trimAscii().toAsciiLower()
        case None => ""
    }
    if (normalized == "config.patch" || normalized == "config.apply") {
        if (gatewayToolPromptContainsAny(prompt, [normalized, "config.patch", "config.apply", "apply config", "patch config", "update config", "modify config", "change config", "修改配置", "更新配置", "应用配置"])) {
            return true
        }
        return !normalizedPath.isEmpty() &&
            gatewayToolPromptContainsAny(prompt, [normalizedPath, normalizedPath.replace("gateway.", ""), "配置", "config"])
    }
    if (normalized == "update.run") {
        return gatewayToolPromptContainsAny(prompt, [normalized, "self-update", "update metis", "update gateway", "upgrade metis", "upgrade gateway", "更新 metis", "升级 metis", "更新 gateway", "升级 gateway"])
    }
    if (normalized == "restart") {
        return gatewayToolPromptContainsAny(prompt, [normalized, "restart gateway", "重启网关", "重启 gateway"])
    }
    if (normalized == "start") {
        return gatewayToolPromptContainsAny(prompt, [normalized, "start gateway", "启动网关", "启动 gateway"])
    }
    if (normalized == "stop") {
        return gatewayToolPromptContainsAny(prompt, [normalized, "stop gateway", "停止网关", "停止 gateway"])
    }
    if (normalized == "master_on") {
        return gatewayToolPromptContainsAny(prompt, [normalized, "master on", "开启主控", "打开主控"])
    }
    if (normalized == "master_off") {
        return gatewayToolPromptContainsAny(prompt, [normalized, "master off", "关闭主控"])
    }
    false
}

private func gatewayToolResolvedOwnerApproved(ownerApproved: Option<Bool>): Bool {
    match (ownerApproved) {
        case Some(value) => value
        case None =>
            match (gatewayCurrentToolRuntimeContext()) {
                case Some(context) => gatewayToolAutoOwnerApprovedForRuntimeContext(context)
                case None => false
            }
    }
}

private func gatewayToolResolvedExplicitRequest(action: String, path: Option<String>, explicitRequest: Option<Bool>): Bool {
    match (explicitRequest) {
        case Some(value) => value
        case None =>
            match (gatewayCurrentToolRuntimeContext()) {
                case Some(context) => gatewayToolInfersExplicitRequestFromPrompt(action, context.prompt, path: path)
                case None => false
            }
    }
}

public func gatewayToolDeniedActionJson(
    action: String,
    errorMessage!: Option<String> = None<String>,
    reasonCode!: Option<String> = None<String>,
    ownerApproved!: Bool = false,
    explicitRequest!: Bool = false,
    path!: Option<String> = None<String>,
    raw!: Option<String> = None<String>,
    note!: Option<String> = None<String>
): JsonObject {
    let normalized = gatewayActionNormalize(action)
    let out = JsonObject()
    out.put("ok", JsonBool(false))
    out.put("status", JsonString("denied"))
    out.put("action", JsonString(normalized))
    out.put(
        "error",
        JsonString(
            match (errorMessage) {
                case Some(v) =>
                    let trimmed = v.trimAscii()
                    if (trimmed.isEmpty()) {
                        "Gateway action `${normalized}` is registered on the unified Gateway main runtime, but the current authorization guard denied it."
                    } else {
                        trimmed
                    }
                case None => "Gateway action `${normalized}` is registered on the unified Gateway main runtime, but the current authorization guard denied it."
            }
        )
    )
    out.put("rejectionContract", JsonString("deny-with-reason"))
    out.put("authorizationMode", JsonString("owner-explicit-request-gated"))
    out.put("ownerRequired", gatewayToolRequiresOwnerApproval(normalized).toJsonValue())
    out.put("explicitRequestRequired", gatewayToolRequiresExplicitRequestApproval(normalized).toJsonValue())
    out.put("ownerApproved", ownerApproved.toJsonValue())
    out.put("explicitRequest", explicitRequest.toJsonValue())
    match (reasonCode) {
        case Some(v) =>
            let trimmed = v.trimAscii()
            if (!trimmed.isEmpty()) {
                out.put("reasonCode", JsonString(trimmed))
            }
        case None => ()
    }
    match (path) {
        case Some(v) =>
            let trimmed = v.trimAscii()
            if (!trimmed.isEmpty()) {
                out.put("path", JsonString(trimmed))
            }
        case None => ()
    }
    match (raw) {
        case Some(v) =>
            let trimmed = v.trimAscii()
            if (!trimmed.isEmpty()) {
                out.put("raw", JsonString(trimmed))
            }
        case None => ()
    }
    match (note) {
        case Some(v) =>
            let trimmed = v.trimAscii()
            if (!trimmed.isEmpty()) {
                out.put("note", JsonString(trimmed))
            }
        case None => ()
    }
    out
}

public func gatewayToolAuthorizationFailureJson(
    action: String,
    ownerApproved!: Bool = false,
    explicitRequest!: Bool = false,
    path!: Option<String> = None<String>,
    raw!: Option<String> = None<String>,
    note!: Option<String> = None<String>
): Option<JsonObject> {
    let normalized = gatewayActionNormalize(action)
    if (gatewayToolRequiresOwnerApproval(normalized) && !ownerApproved) {
        return Some(
            gatewayToolDeniedActionJson(
                normalized,
                errorMessage: Some("Gateway action `${normalized}` is visible on the unified Gateway main runtime, but it requires owner approval before execution."),
                reasonCode: Some("owner_required"),
                ownerApproved: ownerApproved,
                explicitRequest: explicitRequest,
                path: path,
                raw: raw,
                note: note
            )
        )
    }
    if (gatewayToolRequiresExplicitRequestApproval(normalized) && !explicitRequest) {
        return Some(
            gatewayToolDeniedActionJson(
                normalized,
                errorMessage: Some("Gateway action `${normalized}` is visible on the unified Gateway main runtime, but it requires an explicit user request before execution."),
                reasonCode: Some("explicit_request_required"),
                ownerApproved: ownerApproved,
                explicitRequest: explicitRequest,
                path: path,
                raw: raw,
                note: note
            )
        )
    }
    None<JsonObject>
}

@toolset
public class GatewayGatewayToolset {
    public func debugGatewayForTest(action: String, path: Option<String>): String {
        this.__tool_impl_of_gateway(
            action,
            path,
            None<String>,
            None<String>,
            None<Bool>,
            None<Bool>
        )
    }

    private func gatewayBinaryCommand(): (String, Option<Path>) {
        match (MetisPaths.projectRoot()) {
            case Some(root) =>
                let devBinary = root.join("target").join("release").join("bin").join("metis")
                if (exists(devBinary)) {
                    return (devBinary.toString(), Some(root))
                }
                return ("metis", Some(root))
            case None => ("metis", None<Path>)
        }
    }

    private func invokeGatewayCall(method: String, params!: Option<JsonObject> = None<JsonObject>): JsonObject {
        let normalizedMethod = gatewayActionNormalize(method)
        match (params) {
            case Some(obj) =>
                match (gatewayInvokeCurrentToolRuntimeGatewayCall(normalizedMethod, obj)) {
                    case Some(result) => return result
                    case None => ()
                }
            case None =>
                match (gatewayInvokeCurrentToolRuntimeGatewayCall(normalizedMethod, JsonObject())) {
                    case Some(result) => return result
                    case None => ()
                }
        }

        if (normalizedMethod == "config.get") {
            return gatewayToolInProcessConfigGet(normalizedMethod, params)
        }
        if (normalizedMethod == "config.schema.lookup") {
            return gatewayToolInProcessSchemaLookup(normalizedMethod, params)
        }
        if (gatewayActionIsReadOnly(normalizedMethod)) {
            return gatewayToolRpcEnvelope(
                normalizedMethod,
                ok: false,
                error: "No Gateway runtime hook or in-process reader is available for `${normalizedMethod}`; read-only Gateway tool call failed fast instead of self-calling the Gateway CLI.",
                errorCode: "gateway_call_unavailable"
            )
        }
        let (command, workDir) = this.gatewayBinaryCommand()
        let args = match (params) {
            case Some(obj) => ["gateway", "call", normalizedMethod, obj.toJsonString()]
            case None => ["gateway", "call", normalizedMethod]
        }
        let (exitCode, stdoutBytes, stderrBytes) = try {
            executeWithOutput(command, args, workingDirectory: workDir)
        } catch (e: Exception) {
            let err = gatewayToolRpcEnvelope(
                normalizedMethod,
                ok: false,
                error: "Gateway CLI subprocess failed fast: ${e.message}",
                errorCode: "gateway_call_failed"
            )
            err.put("exception", JsonString(e.message))
            return err
        }
        let stdout = try { String.fromUtf8(stdoutBytes).trimAscii() } catch (_: Exception) { "" }
        let stderr = try { String.fromUtf8(stderrBytes).trimAscii() } catch (_: Exception) { "" }
        if (!stdout.isEmpty()) {
            try {
                let obj = JsonValue.fromStr(stdout).asObject()
                obj.put("exitCode", exitCode.toJsonValue())
                if (!stderr.isEmpty()) {
                    obj.put("stderr", JsonString(stderr))
                }
                return obj
            } catch (_: Exception) {
                ()
            }
        }
        let out = JsonObject()
        out.put("ok", JsonBool(exitCode == 0))
        out.put("exitCode", exitCode.toJsonValue())
        out.put("stdout", JsonString(stdout))
        out.put("stderr", JsonString(stderr))
        out
    }

    @tool[
        description: "Operate the unified Gateway runtime through the Gateway RPC surface. Safe read actions are executed directly. High-risk control or mutation actions stay visible, but require owner approval and sometimes an explicit user request before execution.",
        parameters: {
            action: "Gateway action. Supported read actions: status, health, discover, discover.detail, config.get, config.schema.lookup. High-risk actions such as start, stop, restart, master_on, master_off, config.patch, config.apply, and update.run require owner approval; config.patch, config.apply, and update.run also require an explicit user request.",
            path: "Optional config path for config.get or config.schema.lookup, such as gateway, gateway.feishu, or gateway.session.dmScope.",
            raw: "Optional raw value for config.patch or config.apply. Ignored by read-only actions.",
            note: "Optional note echoed back in denied or unsupported responses.",
            ownerApproved: "Optional. Set true only when this action is authorized for the owner/operator on the current surface.",
            explicitRequest: "Optional. Set true only when the user explicitly requested this mutation or control action."
        }
    ]
    public func gateway(
        action: String,
        path: Option<String>,
        raw: Option<String>,
        note: Option<String>,
        ownerApproved: Option<Bool>,
        explicitRequest: Option<Bool>
    ): String {
        let act = gatewayActionNormalize(action)
        PrintUtils.printTool("gateway", shortMessage: act)
        let ownerApprovedValue = gatewayToolResolvedOwnerApproved(ownerApproved)
        let explicitRequestValue = gatewayToolResolvedExplicitRequest(act, path, explicitRequest)

        if (gatewayActionIsReadOnly(act) && !(act == "config.get" || act == "config.schema.lookup")) {
            let out = this.invokeGatewayCall(act).toJsonString()
            PrintUtils.printToolResult(out)
            return out
        }

        if (act == "config.get" || act == "config.schema.lookup") {
            let lookupPath = match (path) {
                case Some(v) => v.trimAscii()
                case None => "gateway"
            }
            let params = JsonObject()
            params.put("path", JsonString(if (lookupPath.isEmpty()) { "gateway" } else { lookupPath }))
            let out = this.invokeGatewayCall(act, params: Some(params)).toJsonString()
            PrintUtils.printToolResult(out)
            return out
        }

        match (
            gatewayToolAuthorizationFailureJson(
                act,
                ownerApproved: ownerApprovedValue,
                explicitRequest: explicitRequestValue,
                path: path,
                raw: raw,
                note: note
            )
        ) {
            case Some(denied) =>
                let out = denied.toJsonString()
                PrintUtils.printToolResult(out)
                return out
            case None => ()
        }

        if (
            act == "start" ||
            act == "stop" ||
            act == "restart" ||
            act == "master_on" ||
            act == "master_off" ||
            act == "update.run"
        ) {
            let out = this.invokeGatewayCall(act).toJsonString()
            PrintUtils.printToolResult(out)
            return out
        }

        if (act == "config.patch" || act == "config.apply") {
            let params = JsonObject()
            let patchPath = match (path) {
                case Some(v) =>
                    let trimmed = v.trimAscii()
                    if (trimmed.isEmpty()) { "gateway" } else { trimmed }
                case None => "gateway"
            }
            let patchRaw = match (raw) {
                case Some(v) => v
                case None => ""
            }
            if (gatewayActionIsProtectedPathSensitive(act) && gatewayConfigPathIsProtected(patchPath)) {
                let denied = gatewayToolDeniedActionJson(
                    act,
                    errorMessage: Some("Gateway action `${act}` cannot modify protected config path `${patchPath}` on the unified Gateway main runtime."),
                    reasonCode: Some("protected_path"),
                    ownerApproved: ownerApprovedValue,
                    explicitRequest: explicitRequestValue,
                    path: Some(patchPath),
                    raw: Some(patchRaw),
                    note: note
                )
                let out = denied.toJsonString()
                PrintUtils.printToolResult(out)
                return out
            }
            params.put("path", JsonString(patchPath))
            params.put("raw", JsonString(patchRaw))
            let out = this.invokeGatewayCall(act, params: Some(params)).toJsonString()
            PrintUtils.printToolResult(out)
            return out
        }

        let unsupported = JsonObject()
        unsupported.put("ok", JsonBool(false))
        unsupported.put("status", JsonString("unsupported"))
        unsupported.put("action", JsonString(act))
        unsupported.put("error", JsonString("Unsupported gateway action on the unified Gateway main runtime: ${act}"))
        match (note) {
            case Some(v) =>
                let trimmed = v.trimAscii()
                if (!trimmed.isEmpty()) {
                    unsupported.put("note", JsonString(trimmed))
                }
            case None => ()
        }
        let out = unsupported.toJsonString()
        PrintUtils.printToolResult(out)
        return out
    }
}
