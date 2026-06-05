package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, GatewayUserSettings, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.core.{gatewayChannelRuntimeMarkFailure, gatewayChannelRuntimeMarkStarting, gatewayChannelRuntimeRegisterAccount}
import metis.gateway.config.buildGatewayConfigFromUserSettings

import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue

private func gatewayHttpSurfaceTestUser(): GatewayUserSettings {
    var user = GatewayUserSettings()
    user.auth.mode = "none"
    user
}

private func gatewayHttpSurfaceTestResult(raw: String): JsonValue {
    JsonValue.fromStr(raw).asObject().get("result").getOrThrow()
}

private func withGatewayHttpSurfaceTestSettings<T>(block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let testHome = "/tmp/metis-gateway-http-surface-test-home"
        try {
            remove(Path(testHome), recursive: true)
        } catch (_: Exception) {
            ()
        }
        Directory.create(testHome, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", testHome)
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        let _ = MetisConfigManager.setGatewaySettings(gatewayHttpSurfaceTestUser())
        CliSettingManager.invalidate()
        try {
            block()
        } finally {
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
        }
    }
}

@Test
public class GatewayHttpSurfaceTest {
    @TestCase
    public func buildChatTurnParamsPreservesUnifiedGatewayHttpIngress(): Unit {
        let params = gatewayHttpBuildChatTurnParams("agent:main:main", "ping")
        @Expect(params.get("session").getOrThrow().asString().getValue(), "agent:main:main")
        @Expect(params.get("text").getOrThrow().asString().getValue(), "ping")
        @Expect(params.get("source").getOrThrow().asString().getValue(), "gateway-http")
        @Expect(params.get("channel").getOrThrow().asString().getValue(), "gateway-http")
        @Expect(params.get("deliver").getOrThrow().asBool().getValue(), false)
    }

    @TestCase
    public func probeBodiesExposeGatewayStatusFields(): Unit {
        withGatewayHttpSurfaceTestSettings<Unit>({ =>
            let cfg = buildGatewayConfigFromUserSettings(GatewayUserSettings())
            let snapshot = GatewayHttpSurface.snapshot(cfg)
            @Expect(snapshot.get("health").isSome(), true)
            @Expect(snapshot.get("healthz").isSome(), true)
            @Expect(snapshot.get("ready").isSome(), true)
            @Expect(snapshot.get("readyz").isSome(), true)
            @Expect(snapshot.get("probePaths").isSome(), true)

            let healthz = JsonValue.fromStr(gatewayHttpHealthProbeJson(cfg)).asObject()
            @Expect(healthz.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(healthz.get("status").getOrThrow().asString().getValue(), "live")
            @Expect(healthz.get("gateway").isSome(), true)

            let readyz = JsonValue.fromStr(gatewayHttpReadyProbeJson(cfg)).asObject()
            @Expect(readyz.get("ready").isSome(), true)
            @Expect(readyz.get("ok").isSome(), true)
            @Expect(readyz.get("status").getOrThrow().asString().getValue(), "not-ready")
            @Expect(readyz.get("gateway").isSome(), true)
        })
    }

    @TestCase
    public func healthzStaysLiveWithFailedChannelRuntimeSnapshot(): Unit {
        withGatewayHttpSurfaceTestSettings<Unit>({ =>
            let user = gatewayHttpSurfaceTestUser()
            let cfg = buildGatewayConfigFromUserSettings(user)
            let _ = gatewayChannelRuntimeRegisterAccount("feishu", accountId: "work")
            let _ = gatewayChannelRuntimeMarkStarting("feishu", accountId: "work")
            let _ = gatewayChannelRuntimeMarkFailure("feishu", accountId: "work", error: "transport-timeout")

            let healthz = JsonValue.fromStr(gatewayHttpHealthProbeJson(cfg)).asObject()
            @Expect(healthz.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(healthz.get("status").getOrThrow().asString().getValue(), "live")
            @Expect(healthz.get("readiness").isNone(), true)
            @Expect(healthz.get("channels").isNone(), true)
        })
    }

    @TestCase
    public func readyzReportsDegradedFailedChannelRuntimeSnapshot(): Unit {
        withGatewayHttpSurfaceTestSettings<Unit>({ =>
            var user = gatewayHttpSurfaceTestUser()
            user.feishu.enabled = true
            user.feishu.defaultAccount = "work"
            user.feishu.appId = "feishu-work-app"
            user.feishu.appSecret = "feishu-work-secret"
            let _ = MetisConfigManager.setGatewaySettings(user)
            CliSettingManager.invalidate()
            let cfg = buildGatewayConfigFromUserSettings(user)
            let _ = gatewayChannelRuntimeRegisterAccount("feishu", accountId: "work")
            let _ = gatewayChannelRuntimeMarkStarting("feishu", accountId: "work")
            let _ = gatewayChannelRuntimeMarkFailure("feishu", accountId: "work", error: "transport-timeout")

            let readyz = JsonValue.fromStr(gatewayHttpReadyProbeJson(cfg)).asObject()
            @Expect(readyz.get("ok").getOrThrow().asBool().getValue(), false)
            @Expect(readyz.get("ready").getOrThrow().asBool().getValue(), false)
            @Expect(readyz.get("status").getOrThrow().asString().getValue(), "degraded")
            let readiness = readyz.get("readiness").getOrThrow().asObject()
            @Expect(readiness.get("degraded").getOrThrow().asBool().getValue(), true)
            @Expect(readiness.get("failedCount").getOrThrow().toJsonString(), "1")
            let accounts = readiness.get("accounts").getOrThrow().asArray()
            @Expect(accounts.size(), 1)
            let row = accounts[0].asObject()
            @Expect(row.get("channelId").getOrThrow().asString().getValue(), "feishu")
            @Expect(row.get("accountId").getOrThrow().asString().getValue(), "work")
            @Expect(row.get("lifecycleState").getOrThrow().asString().getValue(), "failed")
            @Expect(row.get("lastError").getOrThrow().asString().getValue(), "transport-timeout")
        })
    }

    @TestCase
    public func probeHelpersPreserveGatewayMethodSemantics(): Unit {
        @Expect(gatewayHttpProbeMethodAllowed("GET"), true)
        @Expect(gatewayHttpProbeMethodAllowed("HEAD"), true)
        @Expect(gatewayHttpProbeMethodAllowed("POST"), false)
        @Expect(gatewayHttpProbeResponseBody("HEAD", "{\"ok\":true}"), "")
        @Expect(gatewayHttpProbeResponseBody("GET", "{\"ok\":true}"), "{\"ok\":true}")
    }

    @TestCase
    public func mcpToolCatalogCarriesHttpSurfaceTools(): Unit {
        withGatewayHttpSurfaceTestSettings<Unit>({ =>
            let response = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"
            )
            @Expect(response.contains("gateway.readiness"), true)
            @Expect(response.contains("gateway.config.get"), true)
            @Expect(response.contains("gateway.config.schema.lookup"), true)
            @Expect(response.contains("gateway.http.status"), true)
            @Expect(response.contains("gateway.http.start"), true)
            @Expect(response.contains("gateway.webchat.status"), true)
            @Expect(response.contains("gateway.webchat.start"), true)
            @Expect(response.contains("gateway.channels.audit"), true)
        })
    }

    @TestCase
    public func mcpToolCatalogCarriesGitCodeToolsWithSchemas(): Unit {
        withGatewayHttpSurfaceTestSettings<Unit>({ =>
            let response = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"
            )
            for (name in [
                "gitcode_issue_summarize",
                "gitcode_pr_summarize",
                "gitcode_issue_draft_reply",
                "gitcode_pr_draft_reply",
                "gitcode_reply_safety_review"
            ]) {
                @Expect(response.contains(name), true)
            }
            @Expect(response.contains("\"inputSchema\""), true)
            @Expect(response.contains("\"resultSchema\""), true)
            @Expect(response.contains("\"ensure_recent\""), true)
            @Expect(response.contains("\"ensure_ref\""), true)
            @Expect(response.contains("\"force_candidate\""), true)
        })
    }

    @TestCase
    public func mcpToolCatalogCarriesGitCodeLegacyAliases(): Unit {
        withGatewayHttpSurfaceTestSettings<Unit>({ =>
            let response = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"
            )
            for (name in [
                "gitcode_issue_summary",
                "gitcode_pr_summary",
                "gitcode_safety_review"
            ]) {
                @Expect(response.contains(name), true)
            }
            @Expect(response.contains("Compatibility alias for gitcode_issue_summarize"), true)
            @Expect(response.contains("Compatibility alias for gitcode_pr_summarize"), true)
            @Expect(response.contains("Compatibility alias for gitcode_reply_safety_review"), true)
            @Expect(response.contains("\"canonicalName\""), true)
            @Expect(response.contains("\"writebackImplemented\""), true)
        })
    }

    @TestCase
    public func mcpGitCodeToolCallReturnsStructuredContentAndStaysReadOnly(): Unit {
        withGatewayHttpSurfaceTestSettings<Unit>({ =>
            let response = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"tools/call\",\"params\":{\"name\":\"gitcode_issue_summarize\",\"arguments\":{\"requestId\":\"req-runtime\",\"caller\":\"monitor\",\"repository\":\"owner/repo\",\"issueId\":\"42\"}}}"
            )
            let root = JsonValue.fromStr(response).asObject()
            let result = root.get("result").getOrThrow().asObject()
            let structured = result.get("structuredContent").getOrThrow().asObject()
            @Expect(structured.get("requestId").getOrThrow().asString().getValue(), "req-runtime")
            @Expect(structured.get("status").getOrThrow().asString().getValue(), "needs_human_review")
            @Expect(structured.get("needsHumanReview").getOrThrow().asBool().getValue(), true)
            @Expect(structured.get("readOnly").getOrThrow().asBool().getValue(), true)
            let audit = structured.get("audit").getOrThrow().asObject()
            @Expect(audit.get("writebackAttempted").getOrThrow().asBool().getValue(), false)
            @Expect(audit.get("modelProviderCalled").getOrThrow().asBool().getValue(), false)
            @Expect(audit.get("ckbLocalPathRead").getOrThrow().asBool().getValue(), false)
        })
    }

    @TestCase
    public func mcpGitCodeLegacyAliasToolCallReturnsCanonicalStructuredContent(): Unit {
        withGatewayHttpSurfaceTestSettings<Unit>({ =>
            let response = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":25,\"method\":\"tools/call\",\"params\":{\"name\":\" GitCode_Issue_Summary \",\"arguments\":{\"requestId\":\"req-runtime-alias\",\"caller\":\"monitor\",\"repository\":\"owner/repo\",\"issueId\":\"42\"}}}"
            )
            let root = JsonValue.fromStr(response).asObject()
            let result = root.get("result").getOrThrow().asObject()
            let structured = result.get("structuredContent").getOrThrow().asObject()
            @Expect(structured.get("requestId").getOrThrow().asString().getValue(), "req-runtime-alias")
            @Expect(structured.get("status").getOrThrow().asString().getValue(), "needs_human_review")
            @Expect(structured.get("tool").getOrThrow().asString().getValue(), "gitcode_issue_summarize")
            @Expect(structured.get("canonicalToolName").getOrThrow().asString().getValue(), "gitcode_issue_summarize")
            @Expect(structured.get("requestedToolName").getOrThrow().asString().getValue(), "gitcode_issue_summary")
            @Expect(response.contains("UNKNOWN_GITCODE_TOOL"), false)
            @Expect(structured.get("readOnly").getOrThrow().asBool().getValue(), true)
            let audit = structured.get("audit").getOrThrow().asObject()
            @Expect(audit.get("writebackAttempted").getOrThrow().asBool().getValue(), false)
        })
    }

    @TestCase
    public func mcpGitCodeSecretInputIsRejectedWithoutLeakingSecret(): Unit {
        withGatewayHttpSurfaceTestSettings<Unit>({ =>
            let response = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"tools/call\",\"params\":{\"name\":\"gitcode_issue_summarize\",\"arguments\":{\"requestId\":\"req-secret\",\"caller\":\"monitor\",\"repository\":\"owner/repo\",\"issueId\":\"42\",\"token\":\"ghp_runtime_secret\"}}}"
            )
            @Expect(response.contains("ghp_runtime_secret"), false)
            let root = JsonValue.fromStr(response).asObject()
            let structured = root.get("result").getOrThrow().asObject().get("structuredContent").getOrThrow().asObject()
            @Expect(structured.get("status").getOrThrow().asString().getValue(), "rejected")
            @Expect(structured.toJsonString().contains("[REDACTED]"), true)
        })
    }

    @TestCase
    public func mcpStatusExposesGitCodeRuntimeRegistryAuthAndAudit(): Unit {
        withGatewayHttpSurfaceTestSettings<Unit>({ =>
            let response = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"mcp/status\"}"
            )
            let root = JsonValue.fromStr(response).asObject()
            let result = root.get("result").getOrThrow().asObject()
            @Expect(result.get("registeredTools").isSome(), true)
            @Expect(result.get("auth").getOrThrow().asObject().get("mode").getOrThrow().asString().getValue(), "none")
            @Expect(result.get("audit").getOrThrow().asObject().get("recentErrors").isSome(), true)
            @Expect(result.get("ckbEvidence").getOrThrow().asObject().get("localPathRead").getOrThrow().asBool().getValue(), false)
        })
    }

    @TestCase
    public func mcpUnknownGitCodeToolReturnsStructuredError(): Unit {
        withGatewayHttpSurfaceTestSettings<Unit>({ =>
            let response = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"tools/call\",\"params\":{\"name\":\"gitcode_unknown\",\"arguments\":{\"requestId\":\"req-unknown\"}}}"
            )
            let root = JsonValue.fromStr(response).asObject()
            let structured = root.get("result").getOrThrow().asObject().get("structuredContent").getOrThrow().asObject()
            @Expect(structured.get("status").getOrThrow().asString().getValue(), "error")
            let error = structured.get("error").getOrThrow().asObject()
            @Expect(error.get("code").getOrThrow().asString().getValue(), "UNKNOWN_GITCODE_TOOL")
        })
    }

    @TestCase
    public func mcpToolsCallRejectsDeniedGatewayToolBeforeDispatch(): Unit {
        withGatewayHttpSurfaceTestSettings<Unit>({ =>
            var user = gatewayHttpSurfaceTestUser()
            user.tools.deny = ["gateway.http.start"]

            let response = gatewayHandleMcpRequest(
                user,
                "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"tools/call\",\"params\":{\"name\":\"gateway.http.start\",\"arguments\":{}}}"
            )

            @Expect(response.contains("\"error\""), true)
            @Expect(response.contains("tool denied by policy"), true)
            @Expect(response.contains("gateway.http.start"), true)
            @Expect(response.contains("\"started\""), false)
        })
    }

    @TestCase
    public func mcpHttpStartAndStatusForwardExistingPlatformMethods(): Unit {
        withGatewayHttpSurfaceTestSettings<Unit>({ =>
            let readinessResponse = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"gateway.readiness\",\"arguments\":{}}}"
            )
            @Expect(readinessResponse.contains("\"readiness\""), true)
            @Expect(readinessResponse.contains("\"surfaces\""), true)

            let configGetResponse = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"gateway.config.get\",\"arguments\":{\"path\":\"gateway.enabled\"}}}"
            )
            let configGet = gatewayHttpSurfaceTestResult(configGetResponse).asObject()
            @Expect(configGet.get("path").getOrThrow().asString().getValue(), "gateway.enabled")
            @Expect(configGet.get("value").isSome(), true)

            let schemaLookupResponse = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"gateway.config.schema.lookup\",\"arguments\":{\"path\":\"gateway\"}}}"
            )
            @Expect(schemaLookupResponse.contains("\"schema\""), true)

            let webchatStatusResponse = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"gateway.webchat.status\",\"arguments\":{}}}"
            )
            @Expect(webchatStatusResponse.contains("\"webchat\""), true)

            let webchatStartResponse = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/call\",\"params\":{\"name\":\"gateway.webchat.start\",\"arguments\":{}}}"
            )
            let webchatStart = gatewayHttpSurfaceTestResult(webchatStartResponse).asObject()
            @Expect(webchatStart.get("started").getOrThrow().asBool().getValue(), true)
            @Expect(webchatStart.get("webchat").isSome(), true)

            let startResponse = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"gateway.http.start\",\"arguments\":{}}}"
            )
            let start = gatewayHttpSurfaceTestResult(startResponse).asObject()
            @Expect(start.get("started").getOrThrow().asBool().getValue(), true)
            @Expect(start.get("http").isSome(), true)

            let statusResponse = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"gateway.http.status\",\"arguments\":{}}}"
            )
            @Expect(statusResponse.contains("\"http\""), true)
            @Expect(statusResponse.contains("\"probePaths\""), true)

            let channelsAuditResponse = gatewayHandleMcpRequest(
                gatewayHttpSurfaceTestUser(),
                "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"tools/call\",\"params\":{\"name\":\"gateway.channels.audit\",\"arguments\":{\"channelId\":\"telegram\"}}}"
            )
            @Expect(channelsAuditResponse.contains("\"gateway-channels-audit\""), true)
            @Expect(channelsAuditResponse.contains("\"T12\""), true)
            let channelsAudit = gatewayHttpSurfaceTestResult(channelsAuditResponse).asObject()
            let summary = channelsAudit.get("summary").getOrThrow().asObject()
            let consumers = summary.get("consumers").getOrThrow().asObject()
            @Expect(consumers.get("mcpOverHttp").getOrThrow().asBool().getValue(), true)
            @Expect(channelsAuditResponse.contains("\"telegramThreadBindingVisibleInControlUiWsSessions\""), true)
        })
    }
}
