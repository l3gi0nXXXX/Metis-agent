package metis.gateway

import magic.jsonable.*

import metis.core.config.CliSettingManager

import std.convert.Parsable
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}

public let GATEWAY_MCP_PATH = "/mcp"
public let GATEWAY_MCP_PROTOCOL_VERSION = "2025-03-26"
public let GATEWAY_MCP_SERVER_NAME = "metis-gateway"
public let GATEWAY_MCP_DEFAULT_RESPONSE_ID = "mcp-local"

private func gatewayMcpAppendTool(tools: JsonArray, name: String, description: String): Unit {
    let row = JsonObject()
    row.put("name", JsonString(name))
    row.put("description", JsonString(description))
    tools.add(row)
}

private func gatewayMcpStringArray(values: Array<String>): JsonArray {
    let arr = JsonArray([])
    for (value in values) {
        arr.add(JsonString(value))
    }
    arr
}

private func gatewayMcpSchemaString(description!: String = ""): JsonObject {
    let schema = JsonObject()
    schema.put("type", JsonString("string"))
    if (!description.trimAscii().isEmpty()) {
        schema.put("description", JsonString(description))
    }
    schema
}

private func gatewayMcpSchemaBool(description!: String = ""): JsonObject {
    let schema = JsonObject()
    schema.put("type", JsonString("boolean"))
    if (!description.trimAscii().isEmpty()) {
        schema.put("description", JsonString(description))
    }
    schema
}

private func gatewayMcpSchemaInt(description!: String = ""): JsonObject {
    let schema = JsonObject()
    schema.put("type", JsonString("integer"))
    if (!description.trimAscii().isEmpty()) {
        schema.put("description", JsonString(description))
    }
    schema
}

private func gatewayMcpSchemaStringEnum(values: Array<String>, description!: String = ""): JsonObject {
    let schema = gatewayMcpSchemaString(description: description)
    schema.put("enum", gatewayMcpStringArray(values))
    schema
}

private func gatewayMcpSchemaEvidenceArray(): JsonObject {
    let item = JsonObject()
    item.put("type", JsonString("object"))
    let props = JsonObject()
    props.put("source", gatewayMcpSchemaString(description: "Evidence source label or URL."))
    props.put("title", gatewayMcpSchemaString(description: "Short evidence title."))
    props.put("text", gatewayMcpSchemaString(description: "Evidence text supplied by the caller."))
    props.put("ref", gatewayMcpSchemaString(description: "Optional immutable source reference."))
    item.put("properties", props)
    let arr = JsonObject()
    arr.put("type", JsonString("array"))
    arr.put("items", item)
    arr.put("description", JsonString("Caller-provided evidence. Metis does not read CKB local paths in this baseline."))
    arr
}

private func gatewayMcpGitCodeFreshnessPolicySchema(): JsonObject {
    let schema = JsonObject()
    schema.put("type", JsonString("object"))
    let props = JsonObject()
    props.put("mode", gatewayMcpSchemaStringEnum(
        ["use_active", "ensure_recent", "ensure_ref", "force_candidate"],
        description: "ACP freshness policy contract. This schema does not authorize Metis to run git fetch."
    ))
    props.put("maxAgeSeconds", gatewayMcpSchemaInt(description: "Required freshness age for ensure_recent."))
    props.put("ref", gatewayMcpSchemaString(description: "Required Git ref for ensure_ref."))
    props.put("candidateRef", gatewayMcpSchemaString(description: "Candidate ref label for force_candidate."))
    schema.put("properties", props)
    schema.put("additionalProperties", true.toJsonValue())
    schema
}

private func gatewayMcpGitCodeBaseInputSchema(requiredId: String): JsonObject {
    let schema = JsonObject()
    schema.put("type", JsonString("object"))
    let props = JsonObject()
    props.put("requestId", gatewayMcpSchemaString(description: "Caller-generated request correlation id."))
    props.put("caller", gatewayMcpSchemaString(description: "Calling bridge or monitor identity."))
    props.put("repository", gatewayMcpSchemaString(description: "GitCode repository, for example owner/name."))
    props.put(requiredId, gatewayMcpSchemaString(description: "GitCode issue or pull request identifier."))
    props.put("title", gatewayMcpSchemaString(description: "Caller-provided title."))
    props.put("body", gatewayMcpSchemaString(description: "Caller-provided body text."))
    props.put("evidence", gatewayMcpSchemaEvidenceArray())
    props.put("knowledgeVersion", gatewayMcpSchemaString(description: "Caller-provided knowledge index version."))
    props.put("conflictingEvidence", gatewayMcpSchemaBool(description: "Set when upstream evidence conflicts."))
    props.put("freshnessPolicy", gatewayMcpGitCodeFreshnessPolicySchema())
    schema.put("properties", props)
    schema.put("required", gatewayMcpStringArray(["repository", requiredId]))
    schema.put("additionalProperties", true.toJsonValue())
    schema
}

private func gatewayMcpGitCodeDraftReplyInputSchema(requiredId: String): JsonObject {
    let schema = gatewayMcpGitCodeBaseInputSchema(requiredId)
    let props = schema.get("properties").getOrThrow().asObject()
    props.put("intent", gatewayMcpSchemaString(description: "Requested reply intent or short instruction."))
    props.put("proposedReply", gatewayMcpSchemaString(description: "Optional caller-provided reply draft."))
    schema.put("required", gatewayMcpStringArray(["repository", requiredId, "intent"]))
    schema
}

private func gatewayMcpGitCodeSafetyReviewInputSchema(): JsonObject {
    let schema = JsonObject()
    schema.put("type", JsonString("object"))
    let props = JsonObject()
    props.put("requestId", gatewayMcpSchemaString(description: "Caller-generated request correlation id."))
    props.put("caller", gatewayMcpSchemaString(description: "Calling bridge or monitor identity."))
    props.put("repository", gatewayMcpSchemaString(description: "GitCode repository, for example owner/name."))
    props.put("targetType", gatewayMcpSchemaStringEnum(["issue", "pull_request", "unknown"]))
    props.put("targetId", gatewayMcpSchemaString(description: "GitCode issue or pull request identifier."))
    props.put("replyText", gatewayMcpSchemaString(description: "Reply text to review."))
    props.put("evidence", gatewayMcpSchemaEvidenceArray())
    props.put("knowledgeVersion", gatewayMcpSchemaString(description: "Caller-provided knowledge index version."))
    props.put("conflictingEvidence", gatewayMcpSchemaBool(description: "Set when upstream evidence conflicts."))
    props.put("freshnessPolicy", gatewayMcpGitCodeFreshnessPolicySchema())
    schema.put("properties", props)
    schema.put("required", gatewayMcpStringArray(["replyText"]))
    schema.put("additionalProperties", true.toJsonValue())
    schema
}

private func gatewayMcpGitCodeResultSchema(): JsonObject {
    let schema = JsonObject()
    schema.put("type", JsonString("object"))
    let props = JsonObject()
    props.put("requestId", gatewayMcpSchemaString())
    props.put("caller", gatewayMcpSchemaString())
    props.put("tool", gatewayMcpSchemaString())
    props.put("status", gatewayMcpSchemaStringEnum(["ok", "error", "rejected", "needs_human_review"]))
    props.put("needsHumanReview", gatewayMcpSchemaBool())
    props.put("readOnly", gatewayMcpSchemaBool())
    props.put("audit", gatewayMcpSchemaString(description: "Object in runtime results; string here preserves stable schema metadata for simple clients."))
    props.put("knowledge", gatewayMcpSchemaString(description: "Object in runtime results; includes knowledgeVersion, hitCount, truncated."))
    props.put("freshnessPolicy", gatewayMcpSchemaString(description: "Object in runtime results; never implies a Metis git fetch."))
    schema.put("properties", props)
    schema.put("required", gatewayMcpStringArray(["requestId", "caller", "tool", "status", "needsHumanReview", "readOnly", "audit"]))
    schema.put("additionalProperties", true.toJsonValue())
    schema
}

private func gatewayMcpAppendGitCodeTool(
    tools: JsonArray,
    name: String,
    description: String,
    inputSchema: JsonObject
): Unit {
    let row = JsonObject()
    row.put("name", JsonString(name))
    row.put("description", JsonString(description))
    row.put("inputSchema", inputSchema)
    row.put("resultSchema", gatewayMcpGitCodeResultSchema())
    let meta = JsonObject()
    meta.put("readOnly", true.toJsonValue())
    meta.put("writebackImplemented", false.toJsonValue())
    meta.put("directModelProviderCalls", false.toJsonValue())
    meta.put("genericContentToolDefaultDeny", true.toJsonValue())
    meta.put("genericReplyToolDefaultDeny", true.toJsonValue())
    meta.put("knowledgeClient", JsonString("contract-stub"))
    row.put("_meta", meta)
    tools.add(row)
}

public func gatewayMcpAppendGitCodeTools(tools: JsonArray): Unit {
    gatewayMcpAppendGitCodeTool(
        tools,
        "gitcode_issue_summarize",
        "Read-only GitCode issue summarization contract backed only by caller-provided evidence in this baseline.",
        gatewayMcpGitCodeBaseInputSchema("issueId")
    )
    gatewayMcpAppendGitCodeTool(
        tools,
        "gitcode_pr_summarize",
        "Read-only GitCode pull request summarization contract backed only by caller-provided evidence in this baseline.",
        gatewayMcpGitCodeBaseInputSchema("prId")
    )
    gatewayMcpAppendGitCodeTool(
        tools,
        "gitcode_issue_draft_reply",
        "Read-only GitCode issue reply draft placeholder. It never posts a reply.",
        gatewayMcpGitCodeDraftReplyInputSchema("issueId")
    )
    gatewayMcpAppendGitCodeTool(
        tools,
        "gitcode_pr_draft_reply",
        "Read-only GitCode pull request reply draft placeholder. It never posts a reply.",
        gatewayMcpGitCodeDraftReplyInputSchema("prId")
    )
    gatewayMcpAppendGitCodeTool(
        tools,
        "gitcode_reply_safety_review",
        "Read-only safety review contract for caller-provided GitCode reply text. It never posts a reply.",
        gatewayMcpGitCodeSafetyReviewInputSchema()
    )
}

public func gatewayMcpIsGitCodeTool(name: String): Bool {
    match (name.trimAscii().toAsciiLower()) {
        case "gitcode_issue_summarize" => true
        case "gitcode_pr_summarize" => true
        case "gitcode_issue_draft_reply" => true
        case "gitcode_pr_draft_reply" => true
        case "gitcode_reply_safety_review" => true
        case _ => false
    }
}

public func gatewayMcpConfigured(): Bool {
    match (CliSettingManager.setting.mcpServers) {
        case Some(obj) => obj.toJsonString().trimAscii() != "{}"
        case None => false
    }
}

public func gatewayMcpInitializeResultJson(serverVersion: String): JsonObject {
    let result = JsonObject()
    result.put("protocolVersion", JsonString(GATEWAY_MCP_PROTOCOL_VERSION))
    let serverInfo = JsonObject()
    serverInfo.put("name", JsonString(GATEWAY_MCP_SERVER_NAME))
    serverInfo.put("version", JsonString(serverVersion))
    result.put("serverInfo", serverInfo)
    let caps = JsonObject()
    let tools = JsonObject()
    tools.put("listChanged", false.toJsonValue())
    caps.put("tools", tools)
    result.put("capabilities", caps)
    result
}

public func gatewayMcpPingResultJson(serverTime: Int64): JsonObject {
    let result = JsonObject()
    result.put("ok", true.toJsonValue())
    result.put("serverTime", serverTime.toJsonValue())
    result
}

public func gatewayMcpToolListResultJson(includeConfiguredMarker!: Bool = false): JsonObject {
    let result = JsonObject()
    let tools = JsonArray([])
    gatewayMcpAppendTool(tools, "gateway.status", "Read gateway status.")
    gatewayMcpAppendTool(tools, "gateway.health", "Read gateway health.")
    gatewayMcpAppendTool(tools, "gateway.connect.status", "Read gateway RPC connection status.")
    gatewayMcpAppendTool(tools, "gateway.connect.summary", "Read gateway RPC runtime summary.")
    gatewayMcpAppendTool(tools, "gateway.connect.lifecycle", "Read gateway RPC lifecycle history.")
    gatewayMcpAppendTool(tools, "gateway.connect.actions", "Read gateway RPC recommended runtime actions.")
    gatewayMcpAppendTool(tools, "gateway.connect.stream.open", "Open one gateway RPC event stream session.")
    gatewayMcpAppendTool(tools, "gateway.connect.stream.attach", "Attach to one existing gateway RPC event stream session.")
    gatewayMcpAppendTool(tools, "gateway.connect.stream.detach", "Detach from one existing gateway RPC event stream session.")
    gatewayMcpAppendTool(tools, "gateway.connect.stream.status", "Read one gateway RPC event stream status.")
    gatewayMcpAppendTool(tools, "gateway.connect.stream.keepalive", "Refresh one gateway RPC event stream lease.")
    gatewayMcpAppendTool(tools, "gateway.connect.stream.resume", "Resume one gateway RPC event stream from the last cursor.")
    gatewayMcpAppendTool(tools, "gateway.connect.stream.next", "Read the next event chunk from one gateway RPC stream.")
    gatewayMcpAppendTool(tools, "gateway.connect.stream.push", "Publish one server-side event into a gateway RPC stream.")
    gatewayMcpAppendTool(tools, "gateway.connect.ping", "Ping gateway RPC transport/runtime.")
    gatewayMcpAppendTool(tools, "gateway.connect.reconnect", "Recycle one gateway RPC client connection.")
    gatewayMcpAppendTool(tools, "gateway.connect.stream.close", "Close one gateway RPC event stream.")
    gatewayMcpAppendTool(tools, "gateway.transport.runtime", "Read gateway transport runtime summary.")
    gatewayMcpAppendTool(tools, "gateway.transport.remote", "Read gateway remote transport runtime.")
    gatewayMcpAppendTool(tools, "gateway.transport.lifecycle", "Read gateway transport lifecycle history.")
    gatewayMcpAppendTool(tools, "gateway.transport.reconnect.history", "Read gateway transport reconnect history.")
    gatewayMcpAppendTool(tools, "gateway.transport.reconnect.state", "Read gateway transport reconnect state.")
    gatewayMcpAppendTool(tools, "gateway.transport.reconnect.window", "Read gateway transport reconnect stability window.")
    gatewayMcpAppendTool(tools, "gateway.transport.reconnect.plan", "Read gateway transport reconnect plan.")
    gatewayMcpAppendTool(tools, "gateway.transport.reconnect.audit", "Read gateway transport reconnect audit view.")
    gatewayMcpAppendTool(tools, "gateway.transport.reconnect.reset", "Reset gateway transport reconnect state.")
    gatewayMcpAppendTool(tools, "gateway.transport.stream.health", "Read gateway transport stream health.")
    gatewayMcpAppendTool(tools, "gateway.transport.stream.audit", "Read gateway transport stream audit view.")
    gatewayMcpAppendTool(tools, "gateway.transport.reconnect", "Reconnect gateway transport runtime.")
    gatewayMcpAppendTool(tools, "gateway.agents.summary", "Read gateway agent summary.")
    gatewayMcpAppendTool(tools, "gateway.agent.health", "Read one gateway agent health view.")
    gatewayMcpAppendTool(tools, "gateway.agent.actions", "Read one gateway agent remediation/action plan.")
    gatewayMcpAppendTool(tools, "gateway.agent.routing", "Read one gateway agent routing plan.")
    gatewayMcpAppendTool(tools, "gateway.chat.send", "Send a gateway chat message.")
    gatewayMcpAppendTool(tools, "gateway.agent.preview", "Preview a gateway agent invocation.")
    gatewayMcpAppendTool(tools, "gateway.agent.invoke", "Invoke a gateway agent by session and prompt.")
    gatewayMcpAppendTool(tools, "gateway.nodes.list", "List gateway nodes.")
    gatewayMcpAppendTool(tools, "gateway.nodes.health", "Read one gateway node health view.")
    gatewayMcpAppendTool(tools, "gateway.nodes.execute", "Run one step of pending gateway node work.")
    gatewayMcpAppendTool(tools, "gateway.nodes.restart", "Restart one gateway node lifecycle.")
    gatewayMcpAppendTool(tools, "gateway.nodes.policy.audit", "Read gateway node scheduling audit.")
    gatewayMcpAppendTool(tools, "gateway.nodes.policy.reconcile", "Reconcile gateway node scheduling policy.")
    gatewayMcpAppendTool(tools, "gateway.devices.health", "Read one gateway device health view.")
    gatewayMcpAppendTool(tools, "gateway.devices.unregister", "Remove one gateway device from runtime state.")
    gatewayMcpAppendTool(tools, "gateway.devices.policy.audit", "Read gateway device approval audit.")
    gatewayMcpAppendTool(tools, "gateway.devices.approve", "Approve one gateway device.")
    gatewayMcpAppendTool(tools, "gateway.devices.deny", "Deny one gateway device.")
    gatewayMcpAppendTool(tools, "gateway.push.deliveries", "List push deliveries.")
    gatewayMcpAppendTool(tools, "gateway.push.get", "Read one gateway push delivery.")
    gatewayMcpAppendTool(tools, "gateway.push.retry", "Retry one recorded push delivery.")
    gatewayMcpAppendTool(tools, "gateway.push.orchestration.audit", "Read gateway push orchestration audit.")
    gatewayMcpAppendTool(tools, "gateway.push.orchestration.actions", "Read gateway push orchestration remediation actions.")
    gatewayMcpAppendTool(tools, "gateway.push.orchestrate", "Run gateway push orchestration once.")
    gatewayMcpAppendTool(tools, "gateway.canvas.audit", "Read gateway canvas pipeline audit.")
    gatewayMcpAppendTool(tools, "gateway.canvas.actions", "Read gateway canvas remediation actions.")
    gatewayMcpAppendTool(tools, "gateway.talk.audit", "Read gateway talk pipeline audit.")
    gatewayMcpAppendTool(tools, "gateway.talk.actions", "Read gateway talk remediation actions.")
    gatewayMcpAppendTool(tools, "gateway.discover.detail", "Read gateway channel and plugin discovery detail.")
    gatewayMcpAppendTool(tools, "gateway.channels.status", "Read gateway channel status summary.")
    gatewayMcpAppendTool(tools, "gateway.channels.list", "List gateway channels.")
    gatewayMcpAppendTool(tools, "gateway.channels.get", "Read one gateway channel detail.")
    gatewayMcpAppendTool(tools, "gateway.channels.runtime", "Read one gateway channel runtime view.")
    gatewayMcpAppendTool(tools, "gateway.channels.health", "Read gateway channel health summary.")
    gatewayMcpAppendTool(tools, "gateway.channels.audit", "Read gateway channel audit summary.")
    gatewayMcpAppendTool(tools, "gateway.channels.bindings", "Read one gateway channel binding view.")
    gatewayMcpAppendTool(tools, "gateway.channels.policy", "Read gateway channel policy summary.")
    gatewayMcpAppendTool(tools, "gateway.channels.manager", "Read one gateway channel manager runtime view.")
    gatewayMcpAppendTool(tools, "gateway.channels.health.actions", "Read gateway channel health remediation actions.")
    gatewayMcpAppendTool(tools, "gateway.channels.start", "Start one gateway channel via host-backed runtime forwarder.")
    gatewayMcpAppendTool(tools, "gateway.channels.stop", "Stop one gateway channel via host-backed runtime forwarder.")
    gatewayMcpAppendTool(tools, "gateway.channels.send", "Send one test message through a gateway channel host forwarder.")
    gatewayMcpAppendTool(tools, "gateway.channels.logout", "Log out one gateway channel account.")
    gatewayMcpAppendTool(tools, "gateway.plugins.status", "Read gateway plugin status summary.")
    gatewayMcpAppendTool(tools, "gateway.plugins.list", "List gateway plugins.")
    gatewayMcpAppendTool(tools, "gateway.plugins.get", "Read one gateway plugin detail.")
    gatewayMcpAppendTool(tools, "gateway.plugins.runtime", "Read one gateway plugin runtime view.")
    gatewayMcpAppendTool(tools, "gateway.plugins.health", "Read gateway plugin health summary.")
    gatewayMcpAppendTool(tools, "gateway.plugins.bindings", "Read one gateway plugin binding view.")
    gatewayMcpAppendTool(tools, "gateway.plugins.policy", "Read gateway plugin policy summary.")
    gatewayMcpAppendTool(tools, "gateway.plugins.manager", "Read one gateway plugin manager runtime view.")
    gatewayMcpAppendTool(tools, "gateway.plugins.health.actions", "Read gateway plugin health remediation actions.")
    gatewayMcpAppendTool(tools, "gateway.plugins.actions", "Read gateway plugin action discovery from the compatibility host.")
    gatewayMcpAppendTool(tools, "gateway.plugins.approvals", "Read gateway plugin approval review state.")
    gatewayMcpAppendTool(tools, "gateway.plugins.package_state", "Read gateway plugin package probe state.")
    gatewayMcpAppendTool(tools, "gateway.plugins.setup", "Read gateway plugin setup state.")
    gatewayMcpAppendTool(tools, "gateway.plugins.setup.registry", "Read gateway plugin setup registry/validation capability.")
    gatewayMcpAppendTool(tools, "gateway.plugins.setup.apply", "Apply gateway plugin setup/config into persisted bindings.")
    gatewayMcpAppendTool(tools, "gateway.plugins.runtime.forwarders", "Read gateway plugin host runtime forwarders.")
    gatewayMcpAppendTool(tools, "gateway.plugins.resolve_account", "Resolve one gateway plugin account via the compatibility host.")
    gatewayMcpAppendTool(tools, "gateway.plugins.directory", "Read one gateway plugin live directory snapshot.")
    gatewayMcpAppendTool(tools, "gateway.plugins.targets", "Resolve one gateway plugin target against the live directory.")
    gatewayMcpAppendTool(tools, "gateway.plugins.actions.dispatch", "Dispatch one gateway plugin action through the compatibility host.")
    gatewayMcpAppendTool(tools, "gateway.plugins.start", "Start one gateway plugin account through the compatibility host.")
    gatewayMcpAppendTool(tools, "gateway.plugins.stop", "Stop one gateway plugin account through the compatibility host.")
    gatewayMcpAppendTool(tools, "gateway.plugins.send", "Send one test message through the compatibility host.")
    gatewayMcpAppendTool(tools, "gateway.plugins.logout", "Log out one gateway plugin account through the compatibility host.")
    gatewayMcpAppendTool(tools, "gateway.platform.runtime", "Read gateway platform runtime summary.")
    gatewayMcpAppendTool(tools, "gateway.control_ui.summary", "Read gateway control-ui runtime summary.")
    gatewayMcpAppendTool(tools, "gateway.control_ui.binding", "Read gateway control-ui server binding.")
    gatewayMcpAppendTool(tools, "gateway.control_ui.runtime", "Read gateway control-ui runtime envelope.")
    gatewayMcpAppendTool(tools, "gateway.control_ui.assets", "Read gateway control-ui asset/runtime paths.")
    gatewayMcpAppendTool(tools, "gateway.control_ui.stop", "Stop gateway control-ui runtime.")
    gatewayMcpAppendTool(tools, "gateway.control_ui.reload", "Reload gateway control-ui runtime.")
    gatewayMcpAppendTool(tools, "gateway.webchat.reload", "Reload gateway webchat runtime.")
    gatewayMcpAppendTool(tools, "gateway.probe", "Read gateway probe diagnostics.")
    gatewayMcpAppendTool(tools, "gateway.probe.actions", "Read gateway probe recommended actions.")
    gatewayMcpAppendTool(tools, "gateway.probe.remediation", "Read gateway probe remediation envelope.")
    gatewayMcpAppendTool(tools, "gateway.doctor.actions", "Read gateway doctor recommended actions.")
    gatewayMcpAppendTool(tools, "gateway.doctor.remediation", "Read gateway doctor remediation envelope.")
    gatewayMcpAppendTool(tools, "gateway.doctor", "Read gateway doctor diagnostics.")
    gatewayMcpAppendGitCodeTools(tools)
    if (includeConfiguredMarker) {
        gatewayMcpAppendTool(tools, "mcp.configured", "MCP servers are configured in metis.json; use the CLI/runtime to enumerate loaded tools.")
    }
    result.put("tools", tools)
    result
}

private func gatewayMcpGitCodeJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_e: Exception) { "" }
        case None => ""
    }
}

private func gatewayMcpGitCodeJsonBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_e: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayMcpGitCodeJsonInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            try {
                let raw = v.toJsonString().trimAscii()
                let normalized = if (raw.startsWith("\"") && raw.endsWith("\"") && raw.size >= 2) {
                    raw[1..raw.size - 1]
                } else {
                    raw
                }
                Int64.parse(normalized)
            } catch (_e: Exception) {
                fallback
            }
        case None => fallback
    }
}

private func gatewayMcpGitCodeJsonObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_e: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func gatewayMcpGitCodeEvidenceCount(args: JsonObject): Int64 {
    match (args.get("evidence")) {
        case Some(v) =>
            try { Int64(v.asArray().size()) } catch (_e: Exception) { 0 }
        case None => 0
    }
}

private func gatewayMcpGitCodeSecretKey(key: String): Bool {
    let normalized = key.trimAscii().toAsciiLower().replace("_", "").replace("-", "")
    normalized.contains("token") || normalized.contains("secret") ||
        normalized.contains("password") || normalized.contains("authorization") ||
        normalized.contains("apikey") || normalized.contains("credential")
}

private func gatewayMcpGitCodeSecretText(value: String): Bool {
    let normalized = value.trimAscii()
    let lower = normalized.toAsciiLower()
    lower.contains("bearer ") || lower.contains("authorization:") ||
        normalized.contains("ghp_") || normalized.contains("glpat-") ||
        normalized.contains("sk-") || normalized.contains("xoxb-")
}

private func gatewayMcpGitCodeHasSecretValue(key: String, value: JsonValue): Bool {
    if (gatewayMcpGitCodeSecretKey(key)) {
        return true
    }
    try {
        if (gatewayMcpGitCodeSecretText(value.asString().getValue())) {
            return true
        }
    } catch (_e: Exception) {
        ()
    }
    try {
        let obj = value.asObject()
        for ((childKey, childValue) in obj.getFields()) {
            if (gatewayMcpGitCodeHasSecretValue(childKey, childValue)) {
                return true
            }
        }
    } catch (_e: Exception) {
        ()
    }
    try {
        let arr = value.asArray()
        for (item in arr.getItems()) {
            if (gatewayMcpGitCodeHasSecretValue("", item)) {
                return true
            }
        }
    } catch (_e: Exception) {
        ()
    }
    false
}

private func gatewayMcpGitCodeHasSecrets(args: JsonObject): Bool {
    for ((key, value) in args.getFields()) {
        if (gatewayMcpGitCodeHasSecretValue(key, value)) {
            return true
        }
    }
    false
}

private func gatewayMcpGitCodeSanitizeValue(key: String, value: JsonValue): JsonValue {
    if (gatewayMcpGitCodeSecretKey(key)) {
        return JsonString("[REDACTED]")
    }
    try {
        let text = value.asString().getValue()
        if (gatewayMcpGitCodeSecretText(text)) {
            return JsonString("[REDACTED]")
        }
        return JsonString(text)
    } catch (_e: Exception) {
        ()
    }
    try {
        let obj = value.asObject()
        let out = JsonObject()
        for ((childKey, childValue) in obj.getFields()) {
            out.put(childKey, gatewayMcpGitCodeSanitizeValue(childKey, childValue))
        }
        return out
    } catch (_e: Exception) {
        ()
    }
    try {
        let arr = value.asArray()
        let out = JsonArray([])
        for (item in arr.getItems()) {
            out.add(gatewayMcpGitCodeSanitizeValue("", item))
        }
        return out
    } catch (_e: Exception) {
        ()
    }
    value
}

private func gatewayMcpGitCodeSanitizedArgs(args: JsonObject): JsonObject {
    let out = JsonObject()
    for ((key, value) in args.getFields()) {
        out.put(key, gatewayMcpGitCodeSanitizeValue(key, value))
    }
    out
}

private func gatewayMcpGitCodeFreshnessPolicy(args: JsonObject): JsonObject {
    let rawPolicy = gatewayMcpGitCodeJsonObject(args, "freshnessPolicy")
    let rawMode = gatewayMcpGitCodeJsonString(rawPolicy, "mode").trimAscii().toAsciiLower()
    let mode = if (rawMode == "ensure_recent" || rawMode == "ensure_ref" || rawMode == "force_candidate") {
        rawMode
    } else {
        "use_active"
    }
    let out = JsonObject()
    out.put("mode", JsonString(mode))
    out.put("recognized", true.toJsonValue())
    out.put("metisGitFetch", false.toJsonValue())
    out.put("requiresExternalFreshness", (mode != "use_active").toJsonValue())
    out.put("note", JsonString("ACP freshness policy data contract only; Metis does not fetch GitCode refs in this baseline."))
    if (mode == "ensure_recent") {
        out.put("maxAgeSeconds", gatewayMcpGitCodeJsonInt(rawPolicy, "maxAgeSeconds", 0).toJsonValue())
    }
    if (mode == "ensure_ref") {
        out.put("ref", JsonString(gatewayMcpGitCodeJsonString(rawPolicy, "ref")))
    }
    if (mode == "force_candidate") {
        out.put("candidateRef", JsonString(gatewayMcpGitCodeJsonString(rawPolicy, "candidateRef")))
    }
    out
}

private func gatewayMcpGitCodeKnowledge(args: JsonObject): JsonObject {
    let hitCount = gatewayMcpGitCodeEvidenceCount(args)
    let out = JsonObject()
    out.put("client", JsonString("contract-stub"))
    out.put("available", (hitCount > 0).toJsonValue())
    out.put("localPathRead", false.toJsonValue())
    out.put("source", JsonString(if (hitCount > 0) { "caller-provided-evidence" } else { "unavailable" }))
    out.put("knowledgeVersion", JsonString(if (hitCount > 0) {
        let supplied = gatewayMcpGitCodeJsonString(args, "knowledgeVersion").trimAscii()
        if (supplied.isEmpty()) { "caller-provided" } else { supplied }
    } else {
        "unavailable"
    }))
    out.put("hitCount", hitCount.toJsonValue())
    out.put("truncated", false.toJsonValue())
    out
}

private func gatewayMcpGitCodeAudit(
    caller: String,
    tool: String,
    requestId: String,
    args: JsonObject,
    redacted: Bool,
    reason: String
): JsonObject {
    let audit = JsonObject()
    audit.put("requestId", JsonString(requestId))
    audit.put("caller", JsonString(caller))
    audit.put("tool", JsonString(tool))
    audit.put("operation", JsonString("read_only_contract_stub"))
    audit.put("writebackAttempted", false.toJsonValue())
    audit.put("modelProviderCalled", false.toJsonValue())
    audit.put("ckbLocalPathRead", false.toJsonValue())
    audit.put("redacted", redacted.toJsonValue())
    audit.put("reason", JsonString(reason))
    audit.put("sanitizedInput", gatewayMcpGitCodeSanitizedArgs(args))
    audit
}

private func gatewayMcpGitCodeBaseResult(
    tool: String,
    args: JsonObject,
    status: String,
    needsHumanReview: Bool,
    redacted: Bool,
    reason: String
): JsonObject {
    let requestId = gatewayMcpGitCodeJsonString(args, "requestId")
    let caller = if (gatewayMcpGitCodeJsonString(args, "caller").trimAscii().isEmpty()) {
        "unknown"
    } else {
        gatewayMcpGitCodeJsonString(args, "caller")
    }
    let out = JsonObject()
    out.put("requestId", JsonString(requestId))
    out.put("caller", JsonString(caller))
    out.put("tool", JsonString(tool))
    out.put("status", JsonString(status))
    out.put("needsHumanReview", needsHumanReview.toJsonValue())
    out.put("readOnly", true.toJsonValue())
    out.put("audit", gatewayMcpGitCodeAudit(caller, tool, requestId, args, redacted, reason))
    out.put("knowledge", gatewayMcpGitCodeKnowledge(args))
    out.put("freshnessPolicy", gatewayMcpGitCodeFreshnessPolicy(args))
    let permissions = JsonObject()
    permissions.put("contentPlaceholderDefaultDeny", true.toJsonValue())
    permissions.put("replyPlaceholderDefaultDeny", true.toJsonValue())
    permissions.put("realGitCodeWriteback", false.toJsonValue())
    out.put("permissions", permissions)
    out
}

private func gatewayMcpGitCodeMissingResult(tool: String, args: JsonObject, field: String): JsonObject {
    let out = gatewayMcpGitCodeBaseResult(tool, args, "error", true, false, "missing required field `${field}`")
    let error = JsonObject()
    error.put("code", JsonString("MISSING_REQUIRED_FIELD"))
    error.put("field", JsonString(field))
    error.put("message", JsonString("Missing required GitCode MCP argument `${field}`."))
    out.put("error", error)
    out
}

private func gatewayMcpGitCodeRejectedResult(tool: String, args: JsonObject): JsonObject {
    let out = gatewayMcpGitCodeBaseResult(tool, args, "rejected", true, true, "secret-like input rejected")
    let error = JsonObject()
    error.put("code", JsonString("SECRET_INPUT_REJECTED"))
    error.put("message", JsonString("Secret-like input was rejected and redacted."))
    out.put("error", error)
    out
}

private func gatewayMcpGitCodeUnknownResult(tool: String, args: JsonObject): JsonObject {
    let out = gatewayMcpGitCodeBaseResult(tool, args, "error", true, false, "unknown gitcode tool")
    let error = JsonObject()
    error.put("code", JsonString("UNKNOWN_GITCODE_TOOL"))
    error.put("message", JsonString("Unsupported GitCode MCP tool `${tool}`."))
    out.put("error", error)
    out
}

private func gatewayMcpGitCodeNeedsReview(args: JsonObject): Bool {
    gatewayMcpGitCodeEvidenceCount(args) == 0 || gatewayMcpGitCodeJsonBool(args, "conflictingEvidence", false)
}

private func gatewayMcpGitCodeValidateBase(tool: String, args: JsonObject, idField: String): Option<JsonObject> {
    if (gatewayMcpGitCodeJsonString(args, "repository").trimAscii().isEmpty()) {
        return Some(gatewayMcpGitCodeMissingResult(tool, args, "repository"))
    }
    if (gatewayMcpGitCodeJsonString(args, idField).trimAscii().isEmpty()) {
        return Some(gatewayMcpGitCodeMissingResult(tool, args, idField))
    }
    if (gatewayMcpGitCodeHasSecrets(args)) {
        return Some(gatewayMcpGitCodeRejectedResult(tool, args))
    }
    None<JsonObject>
}

private func gatewayMcpGitCodeSummaryResult(tool: String, args: JsonObject, idField: String): JsonObject {
    match (gatewayMcpGitCodeValidateBase(tool, args, idField)) {
        case Some(result) => return result
        case None => ()
    }
    let needsReview = gatewayMcpGitCodeNeedsReview(args)
    let status = if (needsReview) { "needs_human_review" } else { "ok" }
    let reason = if (gatewayMcpGitCodeEvidenceCount(args) == 0) {
        "no evidence available from CKB contract stub"
    } else if (gatewayMcpGitCodeJsonBool(args, "conflictingEvidence", false)) {
        "conflicting evidence"
    } else {
        "caller evidence available"
    }
    let out = gatewayMcpGitCodeBaseResult(tool, args, status, needsReview, false, reason)
    let summary = JsonObject()
    summary.put("repository", JsonString(gatewayMcpGitCodeJsonString(args, "repository")))
    summary.put("targetId", JsonString(gatewayMcpGitCodeJsonString(args, idField)))
    summary.put("title", JsonString(gatewayMcpGitCodeJsonString(args, "title")))
    summary.put("bodyPreview", JsonString(gatewayMcpGitCodeJsonString(args, "body")))
    summary.put("evidenceBased", (!needsReview).toJsonValue())
    summary.put("generatedByModel", false.toJsonValue())
    summary.put("text", JsonString(if (needsReview) {
        "Insufficient non-conflicting evidence to summarize without human review."
    } else {
        "Caller-provided evidence is present; real summarization is intentionally not implemented in this baseline."
    }))
    out.put("summary", summary)
    out
}

private func gatewayMcpGitCodeDraftReplyResult(tool: String, args: JsonObject, idField: String): JsonObject {
    match (gatewayMcpGitCodeValidateBase(tool, args, idField)) {
        case Some(result) => return result
        case None => ()
    }
    if (gatewayMcpGitCodeJsonString(args, "intent").trimAscii().isEmpty()) {
        return gatewayMcpGitCodeMissingResult(tool, args, "intent")
    }
    let needsReview = true
    let out = gatewayMcpGitCodeBaseResult(tool, args, "needs_human_review", needsReview, false, "reply draft placeholder is default-deny")
    let draft = JsonObject()
    draft.put("repository", JsonString(gatewayMcpGitCodeJsonString(args, "repository")))
    draft.put("targetId", JsonString(gatewayMcpGitCodeJsonString(args, idField)))
    draft.put("body", JsonString(""))
    draft.put("readyToPost", false.toJsonValue())
    draft.put("placeholder", true.toJsonValue())
    draft.put("humanEditable", true.toJsonValue())
    draft.put("writebackImplemented", false.toJsonValue())
    out.put("draft", draft)
    out
}

private func gatewayMcpGitCodeSafetyReviewResult(tool: String, args: JsonObject): JsonObject {
    if (gatewayMcpGitCodeJsonString(args, "replyText").trimAscii().isEmpty()) {
        return gatewayMcpGitCodeMissingResult(tool, args, "replyText")
    }
    if (gatewayMcpGitCodeHasSecrets(args)) {
        return gatewayMcpGitCodeRejectedResult(tool, args)
    }
    let needsReview = gatewayMcpGitCodeNeedsReview(args)
    let out = gatewayMcpGitCodeBaseResult(
        tool,
        args,
        if (needsReview) { "needs_human_review" } else { "ok" },
        needsReview,
        false,
        if (needsReview) { "no non-conflicting evidence for safety review" } else { "caller evidence available" }
    )
    let review = JsonObject()
    review.put("safeToSend", false.toJsonValue())
    review.put("readyToPost", false.toJsonValue())
    review.put("writebackAllowed", false.toJsonValue())
    review.put("reason", JsonString(if (needsReview) {
        "Needs human review before sending."
    } else {
        "Baseline safety contract does not approve outbound replies automatically."
    }))
    out.put("review", review)
    out
}

public func gatewayMcpGitCodeToolResultJson(name: String, args: JsonObject): JsonObject {
    let normalized = name.trimAscii().toAsciiLower()
    if (normalized == "gitcode_issue_summarize") {
        return gatewayMcpGitCodeSummaryResult(normalized, args, "issueId")
    }
    if (normalized == "gitcode_pr_summarize") {
        return gatewayMcpGitCodeSummaryResult(normalized, args, "prId")
    }
    if (normalized == "gitcode_issue_draft_reply") {
        return gatewayMcpGitCodeDraftReplyResult(normalized, args, "issueId")
    }
    if (normalized == "gitcode_pr_draft_reply") {
        return gatewayMcpGitCodeDraftReplyResult(normalized, args, "prId")
    }
    if (normalized == "gitcode_reply_safety_review") {
        return gatewayMcpGitCodeSafetyReviewResult(normalized, args)
    }
    gatewayMcpGitCodeUnknownResult(normalized, args)
}
