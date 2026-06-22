package metis.gateway

import magic.jsonable.*

import metis.core.config.CliSettingManager

import std.collection.{ArrayList, HashMap}
import std.convert.Parsable
import std.sync.Mutex
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}

public let GATEWAY_MCP_PATH = "/mcp"
public let GATEWAY_MCP_PROTOCOL_VERSION = "2025-03-26"
public let GATEWAY_MCP_SERVER_NAME = "metis-gateway"
public let GATEWAY_MCP_DEFAULT_RESPONSE_ID = "mcp-local"

private let GATEWAY_MCP_GITCODE_ALLOWED_CALLERS = [
    "agent-bridge",
    "gateway-agent-bridge",
    "gateway",
    "gitcode-monitor",
    "monitor",
    "mcp-client",
    "test"
]
private let GATEWAY_MCP_GITCODE_MAX_INPUT_BYTES: Int64 = 65536
private let GATEWAY_MCP_GITCODE_MAX_EVIDENCE_ITEMS: Int64 = 20
private let GATEWAY_MCP_GITCODE_TIMEOUT_MS: Int64 = 8000
private let GATEWAY_MCP_GITCODE_RATE_LIMIT_PER_CALLER_TOOL: Int64 = 64

private let gatewayMcpGitCodeRuntimeMutex = Mutex()
private let gatewayMcpGitCodeRateCounters = HashMap<String, Int64>()
private let gatewayMcpGitCodeRecentAudits = ArrayList<JsonObject>()
private let gatewayMcpGitCodeRecentErrors = ArrayList<JsonObject>()

public type GatewayMcpGitCodeModelRunner = (String, JsonObject) -> String
public type GatewayMcpGitCodeKnowledgeRunner = (String, JsonObject) -> JsonObject

private func gatewayMcpGitCodeCanonicalToolNames(): Array<String> {
    [
        "gitcode_issue_summarize",
        "gitcode_pr_summarize",
        "gitcode_issue_draft_reply",
        "gitcode_pr_draft_reply",
        "gitcode_reply_safety_review"
    ]
}

public func gatewayMcpGitCodeToolAliasNames(): Array<String> {
    [
        "gitcode_issue_summary",
        "gitcode_pr_summary",
        "gitcode_safety_review"
    ]
}

public func gatewayMcpGitCodeRegisteredToolNames(): Array<String> {
    [
        "gitcode_issue_summarize",
        "gitcode_pr_summarize",
        "gitcode_issue_draft_reply",
        "gitcode_pr_draft_reply",
        "gitcode_reply_safety_review",
        "gitcode_issue_summary",
        "gitcode_pr_summary",
        "gitcode_safety_review"
    ]
}

public func gatewayMcpGitCodeCanonicalToolName(name: String): String {
    let normalized = name.trimAscii().toAsciiLower()
    if (normalized == "gitcode_issue_summary") {
        return "gitcode_issue_summarize"
    }
    if (normalized == "gitcode_pr_summary") {
        return "gitcode_pr_summarize"
    }
    if (normalized == "gitcode_safety_review") {
        return "gitcode_reply_safety_review"
    }
    normalized
}

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

private func gatewayMcpGitCodeQueryPlanSchema(): JsonObject {
    let schema = JsonObject()
    schema.put("type", JsonString("object"))
    schema.put("description", JsonString("Optional external CKB query plan. Metis treats it as input contract data only."))
    schema.put("additionalProperties", true.toJsonValue())
    schema
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
    props.put("queryPlan", gatewayMcpGitCodeQueryPlanSchema())
    props.put("ckbStatus", gatewayMcpSchemaStringEnum(["ok", "empty", "timeout", "unavailable"]))
    props.put("ckbTimeout", gatewayMcpSchemaBool(description: "Set when the external CKB evidence lookup timed out."))
    props.put("evidenceTruncated", gatewayMcpSchemaBool(description: "Set when upstream evidence was truncated before calling Metis."))
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
    props.put("queryPlan", gatewayMcpGitCodeQueryPlanSchema())
    props.put("ckbStatus", gatewayMcpSchemaStringEnum(["ok", "empty", "timeout", "unavailable"]))
    props.put("ckbTimeout", gatewayMcpSchemaBool(description: "Set when the external CKB evidence lookup timed out."))
    props.put("evidenceTruncated", gatewayMcpSchemaBool(description: "Set when upstream evidence was truncated before calling Metis."))
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
    inputSchema: JsonObject,
    canonicalName!: String = ""
): Unit {
    let canonical = if (canonicalName.trimAscii().isEmpty()) { name } else { canonicalName.trimAscii().toAsciiLower() }
    let row = JsonObject()
    row.put("name", JsonString(name))
    row.put("description", JsonString(description))
    row.put("inputSchema", inputSchema)
    row.put("resultSchema", gatewayMcpGitCodeResultSchema())
    let meta = JsonObject()
    meta.put("canonicalName", JsonString(canonical))
    meta.put("readOnly", true.toJsonValue())
    meta.put("writebackImplemented", false.toJsonValue())
    meta.put("directModelProviderCalls", false.toJsonValue())
    meta.put("genericContentToolDefaultDeny", false.toJsonValue())
    meta.put("genericReplyToolDefaultDeny", false.toJsonValue())
    meta.put("knowledgeClient", JsonString("cangjie-knowledge-client"))
    meta.put("callerAllowlist", gatewayMcpStringArray(GATEWAY_MCP_GITCODE_ALLOWED_CALLERS))
    meta.put("maxInputBytes", GATEWAY_MCP_GITCODE_MAX_INPUT_BYTES.toJsonValue())
    meta.put("timeoutMs", GATEWAY_MCP_GITCODE_TIMEOUT_MS.toJsonValue())
    meta.put("rateLimitPerCallerTool", GATEWAY_MCP_GITCODE_RATE_LIMIT_PER_CALLER_TOOL.toJsonValue())
    meta.put("structuredJsonOnly", true.toJsonValue())
    row.put("_meta", meta)
    tools.add(row)
}

public func gatewayMcpAppendGitCodeTools(tools: JsonArray): Unit {
    gatewayMcpAppendGitCodeTool(
        tools,
        "gitcode_issue_summarize",
        "Read-only GitCode issue summarization through AgentBridge and CKB evidence.",
        gatewayMcpGitCodeBaseInputSchema("issueId")
    )
    gatewayMcpAppendGitCodeTool(
        tools,
        "gitcode_pr_summarize",
        "Read-only GitCode pull request summarization through AgentBridge and CKB evidence.",
        gatewayMcpGitCodeBaseInputSchema("prId")
    )
    gatewayMcpAppendGitCodeTool(
        tools,
        "gitcode_issue_draft_reply",
        "Read-only GitCode issue reply draft through AgentBridge and CKB evidence. It never posts a reply.",
        gatewayMcpGitCodeDraftReplyInputSchema("issueId")
    )
    gatewayMcpAppendGitCodeTool(
        tools,
        "gitcode_pr_draft_reply",
        "Read-only GitCode pull request reply draft through AgentBridge and CKB evidence. It never posts a reply.",
        gatewayMcpGitCodeDraftReplyInputSchema("prId")
    )
    gatewayMcpAppendGitCodeTool(
        tools,
        "gitcode_reply_safety_review",
        "Read-only safety review contract for caller-provided GitCode reply text. It never posts a reply.",
        gatewayMcpGitCodeSafetyReviewInputSchema()
    )
    gatewayMcpAppendGitCodeTool(
        tools,
        "gitcode_issue_summary",
        "Compatibility alias for gitcode_issue_summarize. Read-only GitCode issue summarization through AgentBridge and CKB evidence.",
        gatewayMcpGitCodeBaseInputSchema("issueId"),
        canonicalName: "gitcode_issue_summarize"
    )
    gatewayMcpAppendGitCodeTool(
        tools,
        "gitcode_pr_summary",
        "Compatibility alias for gitcode_pr_summarize. Read-only GitCode pull request summarization through AgentBridge and CKB evidence.",
        gatewayMcpGitCodeBaseInputSchema("prId"),
        canonicalName: "gitcode_pr_summarize"
    )
    gatewayMcpAppendGitCodeTool(
        tools,
        "gitcode_safety_review",
        "Compatibility alias for gitcode_reply_safety_review. Read-only safety review contract for caller-provided GitCode reply text. It never posts a reply.",
        gatewayMcpGitCodeSafetyReviewInputSchema(),
        canonicalName: "gitcode_reply_safety_review"
    )
}

public func gatewayMcpIsGitCodeTool(name: String): Bool {
    let canonical = gatewayMcpGitCodeCanonicalToolName(name)
    for (tool in gatewayMcpGitCodeCanonicalToolNames()) {
        if (canonical == tool) {
            return true
        }
    }
    false
}

public func gatewayMcpGitCodeToolMetadataRegistryJson(): JsonObject {
    let out = JsonObject()
    let tools = JsonArray([])
    for (name in gatewayMcpGitCodeRegisteredToolNames()) {
        let row = JsonObject()
        row.put("name", JsonString(name))
        row.put("readOnly", true.toJsonValue())
        row.put("writebackImplemented", false.toJsonValue())
        row.put("directModelProviderCalls", false.toJsonValue())
        row.put("ckbLocalPathRead", false.toJsonValue())
        row.put("structuredJsonOnly", true.toJsonValue())
        row.put("timeoutMs", GATEWAY_MCP_GITCODE_TIMEOUT_MS.toJsonValue())
        tools.add(row)
    }
    out.put("tools", tools)
    out.put("toolCount", Int64(tools.size()).toJsonValue())
    out.put("callerAllowlist", gatewayMcpStringArray(GATEWAY_MCP_GITCODE_ALLOWED_CALLERS))
    out.put("maxInputBytes", GATEWAY_MCP_GITCODE_MAX_INPUT_BYTES.toJsonValue())
    out.put("maxEvidenceItems", GATEWAY_MCP_GITCODE_MAX_EVIDENCE_ITEMS.toJsonValue())
    out.put("rateLimitPerCallerTool", GATEWAY_MCP_GITCODE_RATE_LIMIT_PER_CALLER_TOOL.toJsonValue())
    out
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
    gatewayMcpAppendTool(tools, "gateway.canvas.invoke", "Invoke a gateway canvas node command.")
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

private func gatewayMcpGitCodeEvidenceSchemaValid(args: JsonObject): Bool {
    match (args.get("evidence")) {
        case Some(v) =>
            try {
                let _ = v.asArray()
                true
            } catch (_e: Exception) {
                false
            }
        case None => true
    }
}

private func gatewayMcpGitCodeEvidenceTruncated(args: JsonObject): Bool {
    gatewayMcpGitCodeJsonBool(args, "evidenceTruncated", false) ||
        gatewayMcpGitCodeEvidenceCount(args) > GATEWAY_MCP_GITCODE_MAX_EVIDENCE_ITEMS
}

private func gatewayMcpGitCodeCkbTimedOut(args: JsonObject): Bool {
    gatewayMcpGitCodeJsonBool(args, "ckbTimeout", false) ||
        gatewayMcpGitCodeJsonString(args, "ckbStatus").trimAscii().toAsciiLower() == "timeout"
}

private func gatewayMcpGitCodeCkbEmpty(args: JsonObject): Bool {
    gatewayMcpGitCodeEvidenceCount(args) == 0 ||
        gatewayMcpGitCodeJsonString(args, "ckbStatus").trimAscii().toAsciiLower() == "empty"
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

private func gatewayMcpGitCodeCallerAllowed(caller: String): Bool {
    let normalized = caller.trimAscii().toAsciiLower()
    if (normalized.isEmpty() || normalized == "unknown") {
        return true
    }
    for (allowed in GATEWAY_MCP_GITCODE_ALLOWED_CALLERS) {
        if (normalized == allowed) {
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
    let timedOut = gatewayMcpGitCodeCkbTimedOut(args)
    let empty = gatewayMcpGitCodeCkbEmpty(args)
    let truncated = gatewayMcpGitCodeEvidenceTruncated(args)
    let suppliedVersion = gatewayMcpGitCodeJsonString(args, "knowledgeVersion").trimAscii()
    let out = JsonObject()
    out.put("client", JsonString("cangjie-knowledge-client"))
    out.put("contract", JsonString("mcp-http-like-evidence-pack"))
    out.put("available", (hitCount > 0 && !timedOut).toJsonValue())
    out.put("localPathRead", false.toJsonValue())
    out.put("source", JsonString(if (timedOut) { "timeout" } else if (hitCount > 0) { "ckb-evidence-pack" } else { "unavailable" }))
    out.put("knowledgeVersion", JsonString(if (!suppliedVersion.isEmpty()) {
        suppliedVersion
    } else if (hitCount > 0) {
        "ckb-evidence-pack"
    } else {
        "unavailable"
    }))
    out.put("hitCount", hitCount.toJsonValue())
    out.put("truncated", truncated.toJsonValue())
    out.put("timeout", timedOut.toJsonValue())
    out.put("empty", empty.toJsonValue())
    let pack = JsonObject()
    pack.put("needsHumanReviewOnTimeoutOrEmpty", true.toJsonValue())
    pack.put("queryPlanAccepted", args.get("queryPlan").isSome().toJsonValue())
    pack.put("maxEvidenceItems", GATEWAY_MCP_GITCODE_MAX_EVIDENCE_ITEMS.toJsonValue())
    out.put("evidencePack", pack)
    out
}

private func gatewayMcpGitCodeCloneArgs(args: JsonObject): JsonObject {
    try {
        JsonValue.fromStr(args.toJsonString()).asObject()
    } catch (_e: Exception) {
        JsonObject()
    }
}

private func gatewayMcpGitCodeApplyKnowledgePack(args: JsonObject, pack: JsonObject): JsonObject {
    let out = gatewayMcpGitCodeCloneArgs(args)
    let status = gatewayMcpGitCodeJsonString(pack, "status").trimAscii().toAsciiLower()
    if (!status.isEmpty()) {
        out.put("ckbStatus", JsonString(status))
    }
    let version = gatewayMcpGitCodeJsonString(pack, "knowledgeVersion").trimAscii()
    if (!version.isEmpty()) {
        out.put("knowledgeVersion", JsonString(version))
    }
    if (gatewayMcpGitCodeJsonBool(pack, "truncated", false)) {
        out.put("evidenceTruncated", true.toJsonValue())
    }
    if (gatewayMcpGitCodeJsonBool(pack, "conflicting", false) || status == "conflicting") {
        out.put("conflictingEvidence", true.toJsonValue())
    }
    match (pack.get("evidence")) {
        case Some(value) =>
            try {
                out.put("evidence", value.asArray())
            } catch (_e: Exception) {
                ()
            }
        case None => ()
    }
    if (status == "timeout") {
        out.put("ckbTimeout", true.toJsonValue())
    }
    out
}

private func gatewayMcpGitCodeResolveKnowledge(
    tool: String,
    args: JsonObject,
    knowledgeRunner: Option<GatewayMcpGitCodeKnowledgeRunner>
): JsonObject {
    match (knowledgeRunner) {
        case Some(runner) =>
            try {
                return gatewayMcpGitCodeApplyKnowledgePack(args, runner(tool, gatewayMcpGitCodeCloneArgs(args)))
            } catch (_e: Exception) {
                let out = gatewayMcpGitCodeCloneArgs(args)
                out.put("ckbStatus", JsonString("timeout"))
                out.put("ckbTimeout", true.toJsonValue())
                return out
            }
        case None => args
    }
}

private func gatewayMcpGitCodeRemember(audit: JsonObject, error: Option<JsonObject>): Unit {
    synchronized(gatewayMcpGitCodeRuntimeMutex) {
        gatewayMcpGitCodeRecentAudits.add(audit)
        while (gatewayMcpGitCodeRecentAudits.size > 8) {
            gatewayMcpGitCodeRecentAudits.remove(at: 0)
        }
        match (error) {
            case Some(err) =>
                gatewayMcpGitCodeRecentErrors.add(err)
                while (gatewayMcpGitCodeRecentErrors.size > 8) {
                    gatewayMcpGitCodeRecentErrors.remove(at: 0)
                }
            case None => ()
        }
    }
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
    audit.put("operation", JsonString("read_only_agent_bridge_runtime"))
    audit.put("writebackAttempted", false.toJsonValue())
    audit.put("modelProviderCalled", (
        reason.startsWith("agent bridge generated") ||
        reason == "agent bridge safety review completed" ||
        reason == "model output rejected"
    ).toJsonValue())
    audit.put("ckbLocalPathRead", false.toJsonValue())
    audit.put("redacted", redacted.toJsonValue())
    audit.put("reason", JsonString(reason))
    let knowledge = gatewayMcpGitCodeKnowledge(args)
    audit.put("knowledgeVersion", JsonString(gatewayMcpGitCodeJsonString(knowledge, "knowledgeVersion")))
    audit.put("hitCount", gatewayMcpGitCodeJsonInt(knowledge, "hitCount", 0).toJsonValue())
    audit.put("truncated", gatewayMcpGitCodeJsonBool(knowledge, "truncated", false).toJsonValue())
    audit.put("timeoutMs", GATEWAY_MCP_GITCODE_TIMEOUT_MS.toJsonValue())
    audit.put("maxInputBytes", GATEWAY_MCP_GITCODE_MAX_INPUT_BYTES.toJsonValue())
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
    let audit = gatewayMcpGitCodeAudit(caller, tool, requestId, args, redacted, reason)
    out.put("audit", audit)
    out.put("knowledge", gatewayMcpGitCodeKnowledge(args))
    out.put("freshnessPolicy", gatewayMcpGitCodeFreshnessPolicy(args))
    let outputPolicy = JsonObject()
    outputPolicy.put("structuredJsonOnly", true.toJsonValue())
    outputPolicy.put("badJsonRejected", true.toJsonValue())
    outputPolicy.put("secretOutputRejected", true.toJsonValue())
    outputPolicy.put("autoPostAllowed", false.toJsonValue())
    out.put("outputPolicy", outputPolicy)
    let permissions = JsonObject()
    permissions.put("contentPlaceholderDefaultDeny", false.toJsonValue())
    permissions.put("replyPlaceholderDefaultDeny", false.toJsonValue())
    permissions.put("realGitCodeWriteback", false.toJsonValue())
    out.put("permissions", permissions)
    if (status == "error" || status == "rejected") {
        let err = JsonObject()
        err.put("requestId", JsonString(requestId))
        err.put("tool", JsonString(tool))
        err.put("status", JsonString(status))
        err.put("reason", JsonString(reason))
        gatewayMcpGitCodeRemember(audit, Some(err))
    } else {
        gatewayMcpGitCodeRemember(audit, None<JsonObject>)
    }
    out
}

private func gatewayMcpGitCodeSchemaErrorResult(tool: String, args: JsonObject, field: String, expected: String): JsonObject {
    let out = gatewayMcpGitCodeBaseResult(tool, args, "error", true, false, "invalid schema for `${field}`")
    let error = JsonObject()
    error.put("code", JsonString("INVALID_ARGUMENT_SCHEMA"))
    error.put("field", JsonString(field))
    error.put("expected", JsonString(expected))
    out.put("error", error)
    out
}

private func gatewayMcpGitCodeUnauthorizedResult(tool: String, args: JsonObject): JsonObject {
    let out = gatewayMcpGitCodeBaseResult(tool, args, "rejected", true, false, "caller not allowlisted")
    let error = JsonObject()
    error.put("code", JsonString("CALLER_NOT_ALLOWED"))
    error.put("message", JsonString("GitCode MCP caller is not allowlisted."))
    out.put("error", error)
    out
}

private func gatewayMcpGitCodeTooLargeResult(tool: String, args: JsonObject): JsonObject {
    let out = gatewayMcpGitCodeBaseResult(tool, args, "rejected", true, false, "input too large")
    let error = JsonObject()
    error.put("code", JsonString("INPUT_TOO_LARGE"))
    error.put("maxInputBytes", GATEWAY_MCP_GITCODE_MAX_INPUT_BYTES.toJsonValue())
    out.put("error", error)
    out
}

private func gatewayMcpGitCodeRateLimitResult(tool: String, args: JsonObject): JsonObject {
    let out = gatewayMcpGitCodeBaseResult(tool, args, "rejected", true, false, "rate limit exceeded")
    let error = JsonObject()
    error.put("code", JsonString("RATE_LIMITED"))
    error.put("limit", GATEWAY_MCP_GITCODE_RATE_LIMIT_PER_CALLER_TOOL.toJsonValue())
    out.put("error", error)
    out
}

private func gatewayMcpGitCodeRateAllowed(tool: String, caller: String): Bool {
    let normalizedCaller = if (caller.trimAscii().isEmpty()) { "unknown" } else { caller.trimAscii().toAsciiLower() }
    let key = "${normalizedCaller}:${tool.trimAscii().toAsciiLower()}"
    synchronized(gatewayMcpGitCodeRuntimeMutex) {
        let next = match (gatewayMcpGitCodeRateCounters.get(key)) {
            case Some(current) => current + 1
            case None => 1
        }
        gatewayMcpGitCodeRateCounters[key] = next
        next <= GATEWAY_MCP_GITCODE_RATE_LIMIT_PER_CALLER_TOOL
    }
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
    gatewayMcpGitCodeCkbEmpty(args) ||
        gatewayMcpGitCodeCkbTimedOut(args) ||
        gatewayMcpGitCodeJsonBool(args, "conflictingEvidence", false) ||
        gatewayMcpGitCodeEvidenceTruncated(args)
}

private func gatewayMcpGitCodeValidateBase(tool: String, args: JsonObject, idField: String): Option<JsonObject> {
    if (Int64(args.toJsonString().toArray().size) > GATEWAY_MCP_GITCODE_MAX_INPUT_BYTES) {
        return Some(gatewayMcpGitCodeTooLargeResult(tool, args))
    }
    if (gatewayMcpGitCodeJsonString(args, "repository").trimAscii().isEmpty()) {
        return Some(gatewayMcpGitCodeMissingResult(tool, args, "repository"))
    }
    if (gatewayMcpGitCodeJsonString(args, idField).trimAscii().isEmpty()) {
        return Some(gatewayMcpGitCodeMissingResult(tool, args, idField))
    }
    if (gatewayMcpGitCodeHasSecrets(args)) {
        return Some(gatewayMcpGitCodeRejectedResult(tool, args))
    }
    if (!gatewayMcpGitCodeEvidenceSchemaValid(args)) {
        return Some(gatewayMcpGitCodeSchemaErrorResult(tool, args, "evidence", "array"))
    }
    let caller = gatewayMcpGitCodeJsonString(args, "caller")
    if (!gatewayMcpGitCodeCallerAllowed(caller)) {
        return Some(gatewayMcpGitCodeUnauthorizedResult(tool, args))
    }
    if (!gatewayMcpGitCodeRateAllowed(tool, caller)) {
        return Some(gatewayMcpGitCodeRateLimitResult(tool, args))
    }
    None<JsonObject>
}

private func gatewayMcpGitCodeRuntimeUnavailableResult(tool: String, args: JsonObject): JsonObject {
    let out = gatewayMcpGitCodeBaseResult(tool, args, "needs_human_review", true, false, "agent bridge runtime unavailable")
    let error = JsonObject()
    error.put("code", JsonString("AGENT_BRIDGE_RUNTIME_UNAVAILABLE"))
    error.put("message", JsonString("GitCode MCP tool requires AgentBridge runtime or a deterministic test runner."))
    out.put("error", error)
    return out
}

private func gatewayMcpGitCodeOutputObject(parsed: JsonObject): JsonObject {
    match (parsed.get("output")) {
        case Some(value) =>
            try { value.asObject() } catch (_e: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func gatewayMcpGitCodeModelOutput(
    tool: String,
    args: JsonObject,
    modelRunner: Option<GatewayMcpGitCodeModelRunner>
): JsonObject {
    match (modelRunner) {
        case Some(runner) => gatewayMcpGitCodeParseStructuredOutputJson(runner(tool, gatewayMcpGitCodeCloneArgs(args)))
        case None => gatewayMcpGitCodeParseStructuredOutputJson("")
    }
}

private func gatewayMcpGitCodeSummaryResult(
    tool: String,
    args: JsonObject,
    idField: String,
    modelRunner: Option<GatewayMcpGitCodeModelRunner>,
    knowledgeRunner: Option<GatewayMcpGitCodeKnowledgeRunner>
): JsonObject {
    let runtimeArgs = gatewayMcpGitCodeResolveKnowledge(tool, args, knowledgeRunner)
    match (gatewayMcpGitCodeValidateBase(tool, runtimeArgs, idField)) {
        case Some(result) => return result
        case None => ()
    }
    let needsReview = gatewayMcpGitCodeNeedsReview(runtimeArgs)
    if (modelRunner.isNone() && !needsReview) {
        return gatewayMcpGitCodeRuntimeUnavailableResult(tool, runtimeArgs)
    }
    let parsed = if (needsReview) { JsonObject() } else { gatewayMcpGitCodeModelOutput(tool, runtimeArgs, modelRunner) }
    let modelOk = !needsReview && gatewayMcpGitCodeJsonString(parsed, "status") == "ok"
    let modelOut = gatewayMcpGitCodeOutputObject(parsed)
    let text = gatewayMcpGitCodeJsonString(modelOut, "text").trimAscii()
    let status = if (needsReview) { "needs_human_review" } else { "ok" }
    let reason = if (gatewayMcpGitCodeEvidenceCount(runtimeArgs) == 0) {
        "no evidence available from CKB"
    } else if (gatewayMcpGitCodeJsonBool(runtimeArgs, "conflictingEvidence", false)) {
        "conflicting evidence"
    } else if (!modelOk || text.isEmpty()) {
        "model output rejected"
    } else {
        "agent bridge generated from CKB evidence"
    }
    let out = gatewayMcpGitCodeBaseResult(tool, runtimeArgs, if (modelOk) { status } else { "needs_human_review" }, needsReview || !modelOk, false, reason)
    let summary = JsonObject()
    summary.put("repository", JsonString(gatewayMcpGitCodeJsonString(runtimeArgs, "repository")))
    summary.put("targetId", JsonString(gatewayMcpGitCodeJsonString(runtimeArgs, idField)))
    summary.put("title", JsonString(gatewayMcpGitCodeJsonString(runtimeArgs, "title")))
    summary.put("bodyPreview", JsonString(gatewayMcpGitCodeJsonString(runtimeArgs, "body")))
    summary.put("evidenceBased", (!needsReview).toJsonValue())
    summary.put("generatedByModel", modelOk.toJsonValue())
    summary.put("text", JsonString(if (modelOk) {
        text
    } else if (needsReview) {
        "Insufficient non-conflicting evidence to summarize without human review."
    } else {
        "Model output was rejected; human review is required."
    }))
    out.put("summary", summary)
    out
}

private func gatewayMcpGitCodeDraftReplyResult(
    tool: String,
    args: JsonObject,
    idField: String,
    modelRunner: Option<GatewayMcpGitCodeModelRunner>,
    knowledgeRunner: Option<GatewayMcpGitCodeKnowledgeRunner>
): JsonObject {
    let runtimeArgs = gatewayMcpGitCodeResolveKnowledge(tool, args, knowledgeRunner)
    match (gatewayMcpGitCodeValidateBase(tool, runtimeArgs, idField)) {
        case Some(result) => return result
        case None => ()
    }
    if (gatewayMcpGitCodeJsonString(runtimeArgs, "intent").trimAscii().isEmpty()) {
        return gatewayMcpGitCodeMissingResult(tool, runtimeArgs, "intent")
    }
    let proposedJson = gatewayMcpGitCodeJsonString(runtimeArgs, "proposedStructuredOutput").trimAscii()
    if (!proposedJson.isEmpty()) {
        let parsed = gatewayMcpGitCodeParseStructuredOutputJson(proposedJson)
        if (gatewayMcpGitCodeJsonString(parsed, "status") != "ok") {
            let out = gatewayMcpGitCodeBaseResult(tool, runtimeArgs, "rejected", true, false, "bad structured output rejected")
            out.put("outputParse", parsed)
            return out
        }
    }
    let needsReview = gatewayMcpGitCodeNeedsReview(runtimeArgs)
    if (modelRunner.isNone() && !needsReview) {
        return gatewayMcpGitCodeRuntimeUnavailableResult(tool, runtimeArgs)
    }
    let parsed = if (needsReview) { JsonObject() } else { gatewayMcpGitCodeModelOutput(tool, runtimeArgs, modelRunner) }
    let modelOk = !needsReview && gatewayMcpGitCodeJsonString(parsed, "status") == "ok"
    let modelOut = gatewayMcpGitCodeOutputObject(parsed)
    let body = gatewayMcpGitCodeJsonString(modelOut, "body").trimAscii()
    let ready = modelOk && !body.isEmpty() && gatewayMcpGitCodeJsonBool(modelOut, "readyToPost", true)
    let out = gatewayMcpGitCodeBaseResult(
        tool,
        runtimeArgs,
        if (ready) { "ok" } else { "needs_human_review" },
        !ready,
        false,
        if (needsReview) { "CKB evidence requires human review" } else if (!modelOk || body.isEmpty()) { "model output rejected" } else { "agent bridge generated draft from CKB evidence" }
    )
    let draft = JsonObject()
    draft.put("repository", JsonString(gatewayMcpGitCodeJsonString(runtimeArgs, "repository")))
    draft.put("targetId", JsonString(gatewayMcpGitCodeJsonString(runtimeArgs, idField)))
    draft.put("body", JsonString(if (ready) { body } else { "" }))
    draft.put("readyToPost", ready.toJsonValue())
    draft.put("placeholder", false.toJsonValue())
    draft.put("humanEditable", true.toJsonValue())
    draft.put("writebackImplemented", false.toJsonValue())
    draft.put("generatedByModel", modelOk.toJsonValue())
    out.put("draft", draft)
    out
}

private func gatewayMcpGitCodeSafetyReviewResult(
    tool: String,
    args: JsonObject,
    modelRunner: Option<GatewayMcpGitCodeModelRunner>,
    knowledgeRunner: Option<GatewayMcpGitCodeKnowledgeRunner>
): JsonObject {
    let runtimeArgs = gatewayMcpGitCodeResolveKnowledge(tool, args, knowledgeRunner)
    if (Int64(runtimeArgs.toJsonString().toArray().size) > GATEWAY_MCP_GITCODE_MAX_INPUT_BYTES) {
        return gatewayMcpGitCodeTooLargeResult(tool, runtimeArgs)
    }
    if (gatewayMcpGitCodeJsonString(runtimeArgs, "replyText").trimAscii().isEmpty()) {
        return gatewayMcpGitCodeMissingResult(tool, runtimeArgs, "replyText")
    }
    if (gatewayMcpGitCodeHasSecrets(runtimeArgs)) {
        return gatewayMcpGitCodeRejectedResult(tool, runtimeArgs)
    }
    if (!gatewayMcpGitCodeEvidenceSchemaValid(runtimeArgs)) {
        return gatewayMcpGitCodeSchemaErrorResult(tool, runtimeArgs, "evidence", "array")
    }
    let caller = gatewayMcpGitCodeJsonString(runtimeArgs, "caller")
    if (!gatewayMcpGitCodeCallerAllowed(caller)) {
        return gatewayMcpGitCodeUnauthorizedResult(tool, runtimeArgs)
    }
    if (!gatewayMcpGitCodeRateAllowed(tool, caller)) {
        return gatewayMcpGitCodeRateLimitResult(tool, runtimeArgs)
    }
    let needsReview = gatewayMcpGitCodeNeedsReview(runtimeArgs)
    if (modelRunner.isNone() && !needsReview) {
        return gatewayMcpGitCodeRuntimeUnavailableResult(tool, runtimeArgs)
    }
    let parsed = if (needsReview) { JsonObject() } else { gatewayMcpGitCodeModelOutput(tool, runtimeArgs, modelRunner) }
    let modelOk = !needsReview && gatewayMcpGitCodeJsonString(parsed, "status") == "ok"
    let modelOut = gatewayMcpGitCodeOutputObject(parsed)
    let safe = modelOk && gatewayMcpGitCodeJsonBool(modelOut, "safeToSend", false)
    let out = gatewayMcpGitCodeBaseResult(
        tool,
        runtimeArgs,
        if (safe) { "ok" } else { "needs_human_review" },
        !safe,
        false,
        if (needsReview) { "CKB evidence requires human review" } else if (!modelOk) { "model output rejected" } else { "agent bridge safety review completed" }
    )
    let review = JsonObject()
    review.put("safeToSend", safe.toJsonValue())
    review.put("readyToPost", safe.toJsonValue())
    review.put("writebackAllowed", false.toJsonValue())
    review.put("generatedByModel", modelOk.toJsonValue())
    review.put("reason", JsonString(if (modelOk) {
        gatewayMcpGitCodeJsonString(modelOut, "reason")
    } else if (needsReview) {
        "Needs human review before sending."
    } else {
        "Model output was rejected; human review is required."
    }))
    out.put("review", review)
    out
}

public func gatewayMcpGitCodeParseStructuredOutputJson(raw: String): JsonObject {
    let out = JsonObject()
    let text = raw.trimAscii()
    out.put("structuredJsonOnly", true.toJsonValue())
    if (text.isEmpty()) {
        out.put("status", JsonString("rejected"))
        out.put("code", JsonString("EMPTY_OUTPUT"))
        return out
    }
    try {
        let value = JsonValue.fromStr(text)
        let obj = value.asObject()
        if (gatewayMcpGitCodeHasSecrets(obj)) {
            out.put("status", JsonString("rejected"))
            out.put("code", JsonString("SECRET_OUTPUT_REJECTED"))
            return out
        }
        out.put("status", JsonString("ok"))
        out.put("output", obj)
        return out
    } catch (_e: Exception) {
        out.put("status", JsonString("rejected"))
        out.put("code", JsonString("BAD_JSON_OUTPUT"))
        return out
    }
}

public func gatewayMcpGitCodeRuntimeStatusJson(authMode!: String = "gateway-http"): JsonObject {
    let out = JsonObject()
    out.put("server", JsonString(GATEWAY_MCP_SERVER_NAME))
    out.put("protocolVersion", JsonString(GATEWAY_MCP_PROTOCOL_VERSION))
    out.put("registeredTools", gatewayMcpGitCodeToolMetadataRegistryJson())
    let auth = JsonObject()
    auth.put("mode", JsonString(authMode.trimAscii()))
    auth.put("httpSurfaceAuthorizesBeforeDispatch", true.toJsonValue())
    auth.put("callerAllowlistEnforced", true.toJsonValue())
    out.put("auth", auth)
    let audit = JsonObject()
    audit.put("redacted", true.toJsonValue())
    audit.put("recent", JsonArray([]))
    audit.put("recentErrors", JsonArray([]))
    synchronized(gatewayMcpGitCodeRuntimeMutex) {
        let recent = JsonArray([])
        for (row in gatewayMcpGitCodeRecentAudits) {
            recent.add(row)
        }
        let errors = JsonArray([])
        for (row in gatewayMcpGitCodeRecentErrors) {
            errors.add(row)
        }
        audit.put("recent", recent)
        audit.put("recentErrors", errors)
        audit.put("rateLimitKeys", Int64(gatewayMcpGitCodeRateCounters.size).toJsonValue())
    }
    out.put("audit", audit)
    let ckb = JsonObject()
    ckb.put("client", JsonString("cangjie-knowledge-client"))
    ckb.put("contract", JsonString("mcp-http-like-evidence-pack"))
    ckb.put("localMirrorBuiltIn", false.toJsonValue())
    ckb.put("localPathRead", false.toJsonValue())
    ckb.put("timeoutNeedsHumanReview", true.toJsonValue())
    ckb.put("emptyNeedsHumanReview", true.toJsonValue())
    out.put("ckbEvidence", ckb)
    out
}

private func gatewayMcpGitCodeAttachToolNames(result: JsonObject, requested: String, canonical: String): JsonObject {
    result.put("tool", JsonString(canonical))
    result.put("toolName", JsonString(canonical))
    result.put("canonicalToolName", JsonString(canonical))
    result.put("requestedToolName", JsonString(requested))
    let audit = try {
        result.get("audit").getOrThrow().asObject()
    } catch (_e: Exception) {
        JsonObject()
    }
    if (!requested.isEmpty()) {
        audit.put("requestedToolName", JsonString(requested))
    }
    audit.put("canonicalToolName", JsonString(canonical))
    result.put("audit", audit)
    result
}

public func gatewayMcpGitCodeToolResultJsonWithRuntime(
    name: String,
    args: JsonObject,
    modelRunner!: Option<GatewayMcpGitCodeModelRunner> = None<GatewayMcpGitCodeModelRunner>,
    knowledgeRunner!: Option<GatewayMcpGitCodeKnowledgeRunner> = None<GatewayMcpGitCodeKnowledgeRunner>
): JsonObject {
    let requested = name.trimAscii()
    let normalized = gatewayMcpGitCodeCanonicalToolName(name)
    if (normalized == "gitcode_issue_summarize") {
        return gatewayMcpGitCodeAttachToolNames(gatewayMcpGitCodeSummaryResult(normalized, args, "issueId", modelRunner, knowledgeRunner), requested, normalized)
    }
    if (normalized == "gitcode_pr_summarize") {
        return gatewayMcpGitCodeAttachToolNames(gatewayMcpGitCodeSummaryResult(normalized, args, "prId", modelRunner, knowledgeRunner), requested, normalized)
    }
    if (normalized == "gitcode_issue_draft_reply") {
        return gatewayMcpGitCodeAttachToolNames(gatewayMcpGitCodeDraftReplyResult(normalized, args, "issueId", modelRunner, knowledgeRunner), requested, normalized)
    }
    if (normalized == "gitcode_pr_draft_reply") {
        return gatewayMcpGitCodeAttachToolNames(gatewayMcpGitCodeDraftReplyResult(normalized, args, "prId", modelRunner, knowledgeRunner), requested, normalized)
    }
    if (normalized == "gitcode_reply_safety_review") {
        return gatewayMcpGitCodeAttachToolNames(gatewayMcpGitCodeSafetyReviewResult(normalized, args, modelRunner, knowledgeRunner), requested, normalized)
    }
    gatewayMcpGitCodeAttachToolNames(gatewayMcpGitCodeUnknownResult(normalized, args), requested, normalized)
}

public func gatewayMcpGitCodeToolResultJson(name: String, args: JsonObject): JsonObject {
    gatewayMcpGitCodeToolResultJsonWithRuntime(name, args)
}
