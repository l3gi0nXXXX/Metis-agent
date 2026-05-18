package metis.gateway.runtime

import magic.jsonable.*

import metis.gateway.{
    GATEWAY_MCP_PATH,
    GATEWAY_MCP_PROTOCOL_VERSION,
    GATEWAY_MCP_SERVER_NAME,
    gatewayMcpGitCodeToolResultJson,
    gatewayMcpInitializeResultJson,
    gatewayMcpPingResultJson,
    gatewayMcpToolListResultJson
}

import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString}

private func testJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) =>
            try { v.asString().getValue() } catch (_e: Exception) { "" }
        case None => ""
    }
}

private func testJsonObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) =>
            try { v.asObject() } catch (_e: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func testJsonArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(v) =>
            try { v.asArray() } catch (_e: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func testJsonBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) =>
            match (v) {
                case b: JsonBool => b.getValue()
                case _ => false
            }
        case None => false
    }
}

private func testJsonInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            match (v) {
                case n: JsonInt => n.getValue()
                case _ => 0
            }
        case None => 0
    }
}

private func testToolListContains(tools: JsonArray, name: String): Bool {
    for (i in 0..tools.size()) {
        let row = try {
            tools[i].asObject()
        } catch (_e: Exception) {
            JsonObject()
        }
        if (testJsonString(row, "name") == name) {
            return true
        }
    }
    false
}

@Test
public class GatewayMcpHttpSharedTest {
    @TestCase
    public func initializeResultContainsProtocolAndServerInfo(): Unit {
        let result = gatewayMcpInitializeResultJson("1.2.3")
        @Expect(testJsonString(result, "protocolVersion"), GATEWAY_MCP_PROTOCOL_VERSION)
        let serverInfo = testJsonObject(result, "serverInfo")
        @Expect(testJsonString(serverInfo, "name"), GATEWAY_MCP_SERVER_NAME)
        @Expect(testJsonString(serverInfo, "version"), "1.2.3")
        let capabilities = testJsonObject(result, "capabilities")
        let tools = testJsonObject(capabilities, "tools")
        @Expect(testJsonBool(tools, "listChanged"), false)
    }

    @TestCase
    public func pingResultContainsProvidedServerTime(): Unit {
        let result = gatewayMcpPingResultJson(42)
        @Expect(testJsonBool(result, "ok"), true)
        @Expect(testJsonInt(result, "serverTime"), 42)
    }

    @TestCase
    public func toolListContainsGatewayStatusAndOptionalConfiguredMarker(): Unit {
        let baseTools = testJsonArray(gatewayMcpToolListResultJson(), "tools")
        @Expect(testToolListContains(baseTools, "gateway.status"), true)
        @Expect(testToolListContains(baseTools, "mcp.configured"), false)

        let configuredTools = testJsonArray(
            gatewayMcpToolListResultJson(includeConfiguredMarker: true),
            "tools"
        )
        @Expect(testToolListContains(configuredTools, "mcp.configured"), true)
    }

    @TestCase
    public func toolListContainsGitCodeToolsWithStableSchemas(): Unit {
        let tools = testJsonArray(gatewayMcpToolListResultJson(), "tools")
        for (name in [
            "gitcode_issue_summarize",
            "gitcode_pr_summarize",
            "gitcode_issue_draft_reply",
            "gitcode_pr_draft_reply",
            "gitcode_reply_safety_review"
        ]) {
            var found = JsonObject()
            for (i in 0..tools.size()) {
                let row = try { tools[i].asObject() } catch (_e: Exception) { JsonObject() }
                if (testJsonString(row, "name") == name) {
                    found = row
                }
            }
            @Expect(testJsonString(found, "name"), name)
            @Expect(found.get("inputSchema").isSome(), true)
            @Expect(found.get("resultSchema").isSome(), true)
            let meta = testJsonObject(found, "_meta")
            @Expect(testJsonBool(meta, "readOnly"), true)
            @Expect(testJsonBool(meta, "writebackImplemented"), false)
            @Expect(testJsonBool(meta, "genericContentToolDefaultDeny"), true)
            @Expect(testJsonBool(meta, "genericReplyToolDefaultDeny"), true)
        }
    }

    @TestCase
    public func gitCodeMissingRequiredFieldsReturnStructuredError(): Unit {
        let result = gatewayMcpGitCodeToolResultJson("gitcode_issue_summarize", JsonObject())
        @Expect(testJsonString(result, "status"), "error")
        @Expect(testJsonBool(result, "needsHumanReview"), true)
        let error = testJsonObject(result, "error")
        @Expect(testJsonString(error, "code"), "MISSING_REQUIRED_FIELD")
        @Expect(testJsonString(error, "field"), "repository")
    }

    @TestCase
    public func gitCodeUnknownToolReturnsStructuredError(): Unit {
        let args = JsonObject()
        args.put("requestId", JsonString("req-unknown"))
        let result = gatewayMcpGitCodeToolResultJson("gitcode_unknown", args)
        @Expect(testJsonString(result, "requestId"), "req-unknown")
        @Expect(testJsonString(result, "status"), "error")
        let error = testJsonObject(result, "error")
        @Expect(testJsonString(error, "code"), "UNKNOWN_GITCODE_TOOL")
    }

    @TestCase
    public func gitCodeSecretLikeInputsAreRejectedAndRedacted(): Unit {
        let args = JsonObject()
        args.put("requestId", JsonString("req-secret"))
        args.put("caller", JsonString("monitor"))
        args.put("repository", JsonString("owner/repo"))
        args.put("issueId", JsonString("42"))
        args.put("accessToken", JsonString("ghp_should_not_escape"))
        let result = gatewayMcpGitCodeToolResultJson("gitcode_issue_summarize", args)
        let raw = result.toJsonString()
        @Expect(testJsonString(result, "status"), "rejected")
        @Expect(testJsonBool(result, "needsHumanReview"), true)
        @Expect(raw.contains("ghp_should_not_escape"), false)
        @Expect(raw.contains("[REDACTED]"), true)
        let audit = testJsonObject(result, "audit")
        @Expect(testJsonBool(audit, "redacted"), true)
    }

    @TestCase
    public func gitCodeEvidenceAbsentKeepsCkbUnavailableAndNeedsHumanReview(): Unit {
        let args = JsonObject()
        args.put("requestId", JsonString("req-no-evidence"))
        args.put("caller", JsonString("monitor"))
        args.put("repository", JsonString("owner/repo"))
        args.put("issueId", JsonString("42"))
        let result = gatewayMcpGitCodeToolResultJson("gitcode_issue_summarize", args)
        @Expect(testJsonString(result, "status"), "needs_human_review")
        @Expect(testJsonBool(result, "needsHumanReview"), true)
        @Expect(testJsonBool(result, "readOnly"), true)
        let knowledge = testJsonObject(result, "knowledge")
        @Expect(testJsonBool(knowledge, "available"), false)
        @Expect(testJsonBool(knowledge, "localPathRead"), false)
        @Expect(testJsonString(knowledge, "knowledgeVersion"), "unavailable")
        @Expect(testJsonInt(knowledge, "hitCount"), 0)
        @Expect(testJsonBool(knowledge, "truncated"), false)
    }

    @TestCase
    public func gitCodeEvidencePresentCarriesKnowledgeVersionAndHitCount(): Unit {
        let args = JsonObject()
        args.put("requestId", JsonString("req-evidence"))
        args.put("caller", JsonString("monitor"))
        args.put("repository", JsonString("owner/repo"))
        args.put("prId", JsonString("7"))
        args.put("knowledgeVersion", JsonString("ckb-v1"))
        let evidence = JsonArray([])
        let row = JsonObject()
        row.put("source", JsonString("fixture"))
        row.put("text", JsonString("The tests failed on the lint step."))
        evidence.add(row)
        args.put("evidence", evidence)
        let result = gatewayMcpGitCodeToolResultJson("gitcode_pr_summarize", args)
        @Expect(testJsonString(result, "status"), "ok")
        @Expect(testJsonBool(result, "readOnly"), true)
        let knowledge = testJsonObject(result, "knowledge")
        @Expect(testJsonString(knowledge, "knowledgeVersion"), "ckb-v1")
        @Expect(testJsonInt(knowledge, "hitCount"), 1)
        @Expect(testJsonBool(knowledge, "truncated"), false)
    }

    @TestCase
    public func gitCodeFreshnessPolicyRecognizesEnsureRecentAndEnsureRefWithoutFetch(): Unit {
        let recentArgs = JsonObject()
        recentArgs.put("repository", JsonString("owner/repo"))
        recentArgs.put("issueId", JsonString("42"))
        let recentPolicy = JsonObject()
        recentPolicy.put("mode", JsonString("ensure_recent"))
        recentPolicy.put("maxAgeSeconds", 60.toJsonValue())
        recentArgs.put("freshnessPolicy", recentPolicy)
        let recent = testJsonObject(
            gatewayMcpGitCodeToolResultJson("gitcode_issue_summarize", recentArgs),
            "freshnessPolicy"
        )
        @Expect(testJsonString(recent, "mode"), "ensure_recent")
        @Expect(testJsonBool(recent, "recognized"), true)
        @Expect(testJsonBool(recent, "metisGitFetch"), false)
        @Expect(testJsonInt(recent, "maxAgeSeconds"), 60)

        let refArgs = JsonObject()
        refArgs.put("repository", JsonString("owner/repo"))
        refArgs.put("prId", JsonString("7"))
        let refPolicy = JsonObject()
        refPolicy.put("mode", JsonString("ensure_ref"))
        refPolicy.put("ref", JsonString("refs/heads/main"))
        refArgs.put("freshnessPolicy", refPolicy)
        let ref = testJsonObject(
            gatewayMcpGitCodeToolResultJson("gitcode_pr_summarize", refArgs),
            "freshnessPolicy"
        )
        @Expect(testJsonString(ref, "mode"), "ensure_ref")
        @Expect(testJsonString(ref, "ref"), "refs/heads/main")
        @Expect(testJsonBool(ref, "metisGitFetch"), false)
    }

    @TestCase
    public func mcpPathConstantMatchesGatewayRoute(): Unit {
        @Expect(GATEWAY_MCP_PATH, "/mcp")
    }
}
