package metis.gateway.core

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock, OpenAICodexOAuthProfile, writeOpenAICodexOAuthProfile}
import metis.core.model.{CodexResponsesHttpRequest, CodexResponsesHttpResult, CodexResponsesHttpRunner, setCodexResponsesHttpRunnerForTest}
import metis.gateway.session.{GatewayIngressSource, GatewaySessionRequest, GatewayTurnContext, gatewayResolveSessionContext}

import std.collection.ArrayList
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonInt, JsonObject, JsonString, JsonValue}

private func withAgentBridgeTempHome<T>(label: String, block: (Path) -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/tmp/${label}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        try { remove(home, recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", home.toString())
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        try {
            return block(home)
        } finally {
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            try { remove(home, recursive: true) } catch (_: Exception) { () }
        }
    }
}

private func agentBridgeAgentEntry(id: String, workspace: Path, agentDir: Path, modelRef: String): JsonObject {
    let entry = JsonObject()
    entry.put("id", JsonString(id))
    entry.put("workspace", JsonString(workspace.toString()))
    entry.put("agentDir", JsonString(agentDir.toString()))
    let model = JsonObject()
    model.put("primary", JsonString(modelRef))
    entry.put("model", model)
    entry
}

private func writeAgentBridgeAgentConfig(home: Path): Unit {
    let root = JsonObject()
    let agents = JsonObject()
    let defaults = JsonObject()
    defaults.put("workspace", JsonString(home.join("workspaces").toString()))
    agents.put("defaults", defaults)
    let list = JsonArray([])
    list.add(agentBridgeAgentEntry("writer", home.join("workspaces").join("writer"), home.join("agents").join("writer").join("agent"), "openai:gpt-4o-mini"))
    list.add(agentBridgeAgentEntry("ops", home.join("workspaces").join("ops"), home.join("agents").join("ops").join("agent"), "qwen/qwen3.6-plus"))
    agents.put("list", list)
    root.put("agents", agents)
    File.writeTo(MetisConfigManager.configPath(), root.toJsonString().toArray())
    CliConfig.invalidatePathCache()
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
}

private func writeAgentBridgeCodexAppServerAgentConfig(home: Path): Unit {
    let root = JsonObject()
    let agents = JsonObject()
    let defaults = JsonObject()
    defaults.put("workspace", JsonString(home.join("workspaces").toString()))
    agents.put("defaults", defaults)
    let list = JsonArray([])
    let entry = JsonObject()
    entry.put("id", JsonString("codex"))
    entry.put("workspace", JsonString(home.join("workspaces").join("codex").toString()))
    entry.put("agentDir", JsonString(home.join("agents").join("codex").join("agent").toString()))
    let model = JsonObject()
    model.put("primary", JsonString("openai-codex:gpt-5.5"))
    model.put("fallbacks", JsonArray([]))
    model.put("openaiRuntime", JsonString("codex_app_server"))
    entry.put("model", model)
    list.add(entry)
    agents.put("list", list)
    root.put("agents", agents)
    File.writeTo(MetisConfigManager.configPath(), root.toJsonString().toArray())
    CliConfig.invalidatePathCache()
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
}

private func writeAgentBridgeCodexResponsesAgentConfig(home: Path): Unit {
    let root = JsonObject()
    let agents = JsonObject()
    let defaults = JsonObject()
    defaults.put("workspace", JsonString(home.join("workspaces").toString()))
    agents.put("defaults", defaults)
    let list = JsonArray([])
    let entry = JsonObject()
    entry.put("id", JsonString("codex"))
    entry.put("workspace", JsonString(home.join("workspaces").join("codex").toString()))
    entry.put("agentDir", JsonString(home.join("agents").join("codex").join("agent").toString()))
    let model = JsonObject()
    model.put("primary", JsonString("openai-codex:gpt-5.5"))
    model.put("fallbacks", JsonArray([]))
    entry.put("model", model)
    list.add(entry)
    agents.put("list", list)
    root.put("agents", agents)
    File.writeTo(MetisConfigManager.configPath(), root.toJsonString().toArray())
    CliConfig.invalidatePathCache()
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
}

private func writeAgentBridgeAuthProfile(path: Path, provider: String, secret: String): Unit {
    Directory.create(path.parent, recursive: true)
    let root = JsonObject()
    let providers = JsonObject()
    let row = JsonObject()
    row.put("apiKey", JsonString(secret))
    providers.put(provider, row)
    root.put("providers", providers)
    File.writeTo(path, root.toJsonString().toArray())
}

private func readAgentBridgeJson(path: Path): JsonObject {
    JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
}

private func agentBridgeJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) => try { return value.asString().getValue().trimAscii() } catch (_: Exception) { () }
        case None => ()
    }
    ""
}

private func agentBridgeJsonBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(value) => try { return value.asBool().getValue() } catch (_: Exception) { () }
        case None => ()
    }
    false
}

private class MockGitCodeMcpRuntimeAdapter <: GatewayGitCodeMcpRuntimeAdapter {
    public var called: Bool = false
    public var toolName: String = ""

    public init() {}

    public func invoke(toolName: String, args: JsonObject): JsonObject {
        this.called = true
        this.toolName = toolName
        let out = JsonObject()
        out.put("status", JsonString("ok"))
        out.put("tool", JsonString(toolName))
        out.put("readOnly", JsonValue.fromStr("true"))
        out.put("providerClientConstructed", JsonValue.fromStr("false"))
        out
    }
}

private class AgentBridgeCodexAppServerCapture {
    public var called: Bool = false
    public var workspace: String = ""
    public var model: String = ""
    public var input: String = ""

    public init() {}
}

private class AgentBridgeCodexResponsesCapture {
    public var callCount: Int64 = 0
    public let urls = ArrayList<String>()
    public let bodies = ArrayList<JsonObject>()
    public let authHeaders = ArrayList<String>()

    public init() {}
}

@Test
public class AgentBridgeRuntimeTest {
    @TestCase
    public func gatewaySkillSelectionUserNoticeStaysSilentWhenNoSkillMatches(): Unit {
        @Expect(gatewaySkillSelectionUserNotice(true, None<String>), "")
        @Expect(gatewaySkillSelectionUserNotice(false, None<String>), "")
    }

    @TestCase
    public func gatewayDefaultChatRuntimeExposesUnifiedCoreTools(): Unit {
        @Expect(gatewayDefaultChatRuntimeHasUnifiedCoreTools(), true)
    }

    @TestCase
    public func gatewayDefaultChatRuntimeNowIncludesCronTool(): Unit {
        let names = gatewayDefaultChatToolNames()
        var found = false
        for (name in names) {
            if (name == "cron") {
                found = true
                break
            }
        }
        @Expect(found, true)
    }

    @TestCase
    public func gitCodeMcpAgentBridgeAdapterUsesRuntimeSeamWithoutProviderClient(): Unit {
        let adapter = MockGitCodeMcpRuntimeAdapter()
        let args = JsonObject()
        args.put("caller", JsonString("agent-bridge"))
        args.put("repository", JsonString("owner/repo"))
        args.put("issueId", JsonString("42"))
        let result = gatewayAgentBridgeInvokeGitCodeMcpRuntime(adapter, "gitcode_issue_summarize", args)
        @Expect(adapter.called, true)
        @Expect(adapter.toolName, "gitcode_issue_summarize")
        @Expect(result.get("status").getOrThrow().asString().getValue(), "ok")
        @Expect(result.get("readOnly").getOrThrow().asBool().getValue(), true)
        @Expect(result.get("providerClientConstructed").getOrThrow().asBool().getValue(), false)
    }

    @TestCase
    public func gatewayDefaultChatRuntimeNowIncludesProcessTool(): Unit {
        let names = gatewayDefaultChatToolNames()
        var found = false
        for (name in names) {
            if (name == "process") {
                found = true
                break
            }
        }
        @Expect(found, true)
    }

    @TestCase
    public func gatewayDefaultChatRuntimeNowIncludesGatewayTool(): Unit {
        let names = gatewayDefaultChatToolNames()
        var found = false
        for (name in names) {
            if (name == "gateway") {
                found = true
                break
            }
        }
        @Expect(found, true)
    }

    @TestCase
    public func gatewayDefaultChatRuntimeNowIncludesMessageTool(): Unit {
        let names = gatewayDefaultChatToolNames()
        var found = false
        for (name in names) {
            if (name == "message") {
                found = true
                break
            }
        }
        @Expect(found, true)
    }

    @TestCase
    public func gatewayDefaultChatRuntimeNowIncludesVideoGenerationTool(): Unit {
        let names = gatewayDefaultChatToolNames()
        @Expect(names.contains("gateway_video_generate"), true)
    }

    @TestCase
    public func gatewayDefaultChatRuntimeNowIncludesImageGenerationTool(): Unit {
        let names = gatewayDefaultChatToolNames()
        @Expect(names.contains("gateway_image_generate"), true)
    }

    @TestCase
    public func gatewayDefaultChatRuntimeNowIncludesTelegramMediaTools(): Unit {
        let names = gatewayDefaultChatToolNames()
        @Expect(names.contains("telegram_media_list"), true)
        @Expect(names.contains("telegram_media_get"), true)
        @Expect(names.contains("telegram_media_save"), true)
        @Expect(names.contains("telegram_media_read"), true)
        @Expect(names.contains("telegram_image_analyze"), true)
        @Expect(names.contains("telegram_audio_transcribe"), true)
        @Expect(names.contains("telegram_sticker_search"), true)
        @Expect(names.contains("telegram_sticker_get"), true)
        @Expect(names.contains("telegram_sticker_cache_stats"), true)
        @Expect(names.contains("telegram_media_send"), true)
        @Expect(names.contains("telegram_target_list"), true)
        @Expect(names.contains("telegram_doctor"), true)
    }

    @TestCase
    public func gatewayDefaultChatRuntimeIncludesFeishuOapiToolsAndFiltersByName(): Unit {
        let names = gatewayDefaultChatToolNames()
        @Expect(names.contains("feishu_fetch_doc"), true)
        @Expect(names.contains("feishu_drive_file"), true)
        @Expect(names.contains("feishu_search_doc_wiki"), true)
        @Expect(names.contains("feishu_bitable_app"), true)
        @Expect(names.contains("feishu_calendar_event"), true)
        @Expect(names.contains("feishu_task_task"), true)
        @Expect(names.contains("feishu_sheet"), true)
        @Expect(names.contains("feishu_chat"), true)
        @Expect(names.contains("feishu_get_user"), true)
        @Expect(names.contains("feishu_im_user_fetch_resource"), true)

        let original = CliSettingManager.setting.gateway
        try {
            var updated = original
            updated.tools.allow = []
            updated.tools.deny = ["feishu_drive_file", "feishu_calendar_event"]
            CliSettingManager.setting.gateway = updated
            let filtered = gatewayPolicyFilteredChatToolNames()
            @Expect(filtered.contains("feishu_fetch_doc"), true)
            @Expect(filtered.contains("feishu_drive_file"), false)
            @Expect(filtered.contains("feishu_calendar_event"), false)

            updated.tools.allow = ["feishu_fetch_doc"]
            updated.tools.deny = []
            CliSettingManager.setting.gateway = updated
            let allowed = gatewayPolicyFilteredChatToolNames()
            @Expect(allowed.contains("feishu_fetch_doc"), true)
            @Expect(allowed.contains("feishu_drive_file"), false)
        } finally {
            CliSettingManager.setting.gateway = original
        }
    }

    @TestCase
    public func gatewayDefaultChatRuntimeNowIncludesSessionsSpawnTool(): Unit {
        let names = gatewayDefaultChatToolNames()
        var found = false
        for (name in names) {
            if (name == "sessions_spawn") {
                found = true
                break
            }
        }
        @Expect(found, true)
    }

    @TestCase
    public func gatewayDefaultChatRuntimeNowIncludesSubagentsTool(): Unit {
        let names = gatewayDefaultChatToolNames()
        var found = false
        for (name in names) {
            if (name == "subagents") {
                found = true
                break
            }
        }
        @Expect(found, true)
    }

    @TestCase
    public func gatewayAuthorizedChatToolNamesRespectToolsDenyPolicy(): Unit {
        let original = CliSettingManager.setting.gateway
        try {
            var updated = original
            updated.tools.allow = []
            updated.tools.deny = ["shellExecute", "process", "gateway", "message", "subagents"]
            CliSettingManager.setting.gateway = updated
            let names = gatewayAuthorizedChatToolNames()
            @Expect(names.contains("weather"), true)
            @Expect(names.contains("shellExecute"), false)
            @Expect(names.contains("process"), false)
            @Expect(names.contains("gateway"), false)
            @Expect(names.contains("message"), false)
            @Expect(names.contains("subagents"), false)
        } finally {
            CliSettingManager.setting.gateway = original
        }
    }

    @TestCase
    public func gatewayPolicyFilteredChatToolNamesActuallyFiltersLiveToolManager(): Unit {
        let original = CliSettingManager.setting.gateway
        try {
            var updated = original
            updated.tools.allow = []
            updated.tools.deny = ["shellExecute", "process", "gateway", "message", "subagents"]
            CliSettingManager.setting.gateway = updated
            let names = gatewayPolicyFilteredChatToolNames()
            @Expect(names.contains("weather"), true)
            @Expect(names.contains("shellExecute"), false)
            @Expect(names.contains("process"), false)
            @Expect(names.contains("gateway"), false)
            @Expect(names.contains("message"), false)
            @Expect(names.contains("subagents"), false)
            @Expect(names.contains("sessions_spawn"), true)
        } finally {
            CliSettingManager.setting.gateway = original
        }
    }

    @TestCase
    public func gatewayAuthorizedAndPolicyFilteredChatToolNamesStayAligned(): Unit {
        let original = CliSettingManager.setting.gateway
        try {
            var updated = original
            updated.tools.allow = []
            updated.tools.deny = ["shellExecute", "process", "gateway", "message", "subagents"]
            CliSettingManager.setting.gateway = updated
            let authorized = gatewayAuthorizedChatToolNames()
            let filtered = gatewayPolicyFilteredChatToolNames()
            @Expect(authorized.size, filtered.size)
            for (i in 0..authorized.size) {
                @Expect(authorized[i], filtered[i])
            }
        } finally {
            CliSettingManager.setting.gateway = original
        }
    }

    @TestCase
    public func gatewayPolicyFilteredSystemPromptDoesNotInjectDeniedTools(): Unit {
        let original = CliSettingManager.setting.gateway
        try {
            var updated = original
            updated.tools.allow = []
            updated.tools.deny = ["shellExecute", "process", "gateway", "message", "subagents"]
            CliSettingManager.setting.gateway = updated
            let prompt = gatewayPolicyFilteredSystemPrompt()
            @Expect(prompt.contains("shellExecute"), false)
            @Expect(prompt.contains("process(action=poll"), false)
            @Expect(prompt.contains("shellExecute/process"), false)
            @Expect(prompt.contains("## Metis Self-Update"), false)
            @Expect(prompt.contains("### message tool"), false)
            @Expect(prompt.contains("subagents"), false)
            @Expect(prompt.contains("weather"), true)
            @Expect(prompt.contains("sessions_spawn"), true)
        } finally {
            CliSettingManager.setting.gateway = original
        }
    }

    @TestCase
    public func gatewayTurnRouteToolPolicyNarrowsLiveToolManager(): Unit {
        let route = JsonObject()
        let tools = JsonObject()
        tools.put("allow", JsonArray([JsonString("weather")]))
        route.put("tools", tools)
        let context = GatewayTurnContext(
            "writer",
            sessionKey: "agent:writer:telegram:group:-100",
            channelName: "telegram",
            accountId: "bot-a",
            peerId: "group:-100",
            route: route
        )

        let names = gatewayPolicyFilteredChatToolNamesForTurnContext(context)

        @Expect(names.contains("weather"), true)
        @Expect(names.contains("shellExecute"), false)
        @Expect(names.contains("sessions_spawn"), false)
    }

    @TestCase
    public func gatewaySystemPromptUsesTurnWorkspaceBootstrap(): Unit {
        withAgentBridgeTempHome("metis-phase4-agent-bridge-prompt", { home: Path =>
            writeAgentBridgeAgentConfig(home)
            let writerWorkspace = home.join("workspaces").join("writer")
            let opsWorkspace = home.join("workspaces").join("ops")
            Directory.create(writerWorkspace, recursive: true)
            Directory.create(opsWorkspace, recursive: true)
            File.writeTo(writerWorkspace.join("SOUL.md"), "# Soul\n\nwriter-only-soul\n".toArray())
            File.writeTo(opsWorkspace.join("SOUL.md"), "# Soul\n\nops-only-soul\n".toArray())

            let writerContext = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.DashboardRpc,
                    sessionHint: "main",
                    agentId: "writer"
                )
            )
            let opsContext = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.DashboardRpc,
                    sessionHint: "main",
                    agentId: "ops"
                )
            )

            let writerPrompt = gatewayPolicyFilteredSystemPromptForTurnContext(
                writerContext.turnContext,
                channelName: "dashboard",
                modelName: "openai:gpt-4o-mini"
            )
            let opsPrompt = gatewayPolicyFilteredSystemPromptForTurnContext(
                opsContext.turnContext,
                channelName: "dashboard",
                modelName: "qwen/qwen3.6-plus"
            )

            @Expect(writerPrompt.contains("writer-only-soul"), true)
            @Expect(writerPrompt.contains("ops-only-soul"), false)
            @Expect(opsPrompt.contains("ops-only-soul"), true)
            @Expect(opsPrompt.contains("writer-only-soul"), false)
        })
    }

    @TestCase
    public func gatewayModelOrderAndRuntimeFilesUseTurnAgentDir(): Unit {
        withAgentBridgeTempHome("metis-phase4-agent-bridge-models", { home: Path =>
            writeAgentBridgeAgentConfig(home)
            let writerContext = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.DashboardRpc,
                    sessionHint: "main",
                    agentId: "writer"
                )
            )
            let opsContext = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.DashboardRpc,
                    sessionHint: "main",
                    agentId: "ops"
                )
            )

            let writerModels = gatewayDebugModelOrderForTurnContext(writerContext.turnContext)
            let opsModels = gatewayDebugModelOrderForTurnContext(opsContext.turnContext)

            @Expect(writerModels.size > 0, true)
            @Expect(opsModels.size > 0, true)
            @Expect(writerModels[0], "openai:gpt-4o-mini")
            @Expect(opsModels[0], "dashscope:qwen3.6-plus")
            @Expect(exists(home.join("agents").join("writer").join("agent").join("models.json")), true)
            @Expect(exists(home.join("agents").join("ops").join("agent").join("models.json")), true)
            @Expect(exists(home.join("models.json")), false)
        })
    }

    @TestCase
    public func gatewayRuntimeStateUsesSelectedAgentAuthProfileWithoutLeakingPeerSecrets(): Unit {
        withAgentBridgeTempHome("metis-s07-agent-bridge-auth-source", { home: Path =>
            writeAgentBridgeAgentConfig(home)
            let writerAuth = home.join("agents").join("writer").join("agent").join("auth-profiles.json")
            let opsAuth = home.join("agents").join("ops").join("agent").join("auth-profiles.json")
            writeAgentBridgeAuthProfile(writerAuth, "openai", "writer-secret-never-log")
            writeAgentBridgeAuthProfile(opsAuth, "qwen", "ops-secret-never-log")

            let writerContext = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.DashboardRpc,
                    sessionHint: "main",
                    agentId: "writer"
                )
            )
            let opsContext = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.DashboardRpc,
                    sessionHint: "main",
                    agentId: "ops"
                )
            )

            @Expect(gatewayDebugModelOrderForTurnContext(writerContext.turnContext)[0], "openai:gpt-4o-mini")
            @Expect(gatewayDebugModelOrderForTurnContext(opsContext.turnContext)[0], "dashscope:qwen3.6-plus")

            let writerModelsPath = home.join("agents").join("writer").join("agent").join("models.json")
            let opsModelsPath = home.join("agents").join("ops").join("agent").join("models.json")
            let writerRuntime = readAgentBridgeJson(writerModelsPath).toJsonString()
            let opsRuntime = readAgentBridgeJson(opsModelsPath).toJsonString()

            @Expect(writerRuntime.contains("agent.auth-profiles.openai"), true)
            @Expect(writerRuntime.contains("agent.auth-profiles.qwen"), false)
            @Expect(opsRuntime.contains("agent.auth-profiles.qwen"), true)
            @Expect(opsRuntime.contains("agent.auth-profiles.openai"), false)
            @Expect(writerRuntime.contains("writer-secret-never-log"), false)
            @Expect(writerRuntime.contains("ops-secret-never-log"), false)
            @Expect(opsRuntime.contains("writer-secret-never-log"), false)
            @Expect(opsRuntime.contains("ops-secret-never-log"), false)
        })
    }

    @TestCase
    public func codexAppServerBranchRunsInsideAgentBridgeAttemptWithoutRealCli(): Unit {
        withAgentBridgeTempHome("metis-m6-agent-bridge-codex-app-server", { home: Path =>
            writeAgentBridgeCodexAppServerAgentConfig(home)
            let context = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.DashboardRpc,
                    sessionHint: "main",
                    agentId: "codex"
                )
            )
            let capture = AgentBridgeCodexAppServerCapture()
            setGatewayCodexAppServerRunnerForTest(Some({ request: GatewayCodexAppServerTurnRequest =>
                capture.called = true
                capture.workspace = request.workspaceDir
                capture.model = request.modelName
                capture.input = gatewayBuildCodexAppServerInput(request.systemPrompt, request.modelInput)
                let usage = JsonObject()
                usage.put("promptTokens", JsonInt(12))
                usage.put("outputTokens", JsonInt(4))
                GatewayCodexAppServerRuntimeResult(
                    "codex app-server reply",
                    threadId: "thread-m6",
                    turnId: "turn-m6",
                    completed: true,
                    promptTokens: 12,
                    completionTokens: 4,
                    usage: Some(usage),
                    metadata: gatewayCodexAppServerRuntimeMetadata(
                        request.modelName,
                        request.channelName,
                        request.sessionKey,
                        threadId: "thread-m6",
                        turnId: "turn-m6",
                        completed: true,
                        usage: Some(usage)
                    )
                )
            }))
            try {
                let store = GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "codex")
                let bridge = AgentBridge(sessionStore: store)
                let reply = bridge.reply(
                    context.sessionKey,
                    "hello codex",
                    channelName: "dashboard",
                    agentId: "codex",
                    turnContext: Some(context.turnContext)
                )

                @Expect(reply, "codex app-server reply")
                @Expect(capture.called, true)
                @Expect(capture.workspace, home.join("workspaces").join("codex").toString())
                @Expect(capture.model, "openai-codex:gpt-5.5")
                @Expect(capture.input.contains("<system>"), true)
                @Expect(capture.input.contains("<input>"), true)
                @Expect(capture.input.contains("hello codex"), true)
                let transcript = String.fromUtf8(File.readFrom(store.transcriptPath(context.sessionKey)))
                @Expect(transcript.contains("codex app-server reply"), true)
                @Expect(transcript.contains("openai-codex:gpt-5.5"), true)
                @Expect(transcript.contains("\"usage\""), true)
                @Expect(transcript.contains("\"input\""), true)
                @Expect(transcript.contains("\"output\""), true)
                @Expect(transcript.contains("12"), true)
                @Expect(transcript.contains("4"), true)
            } finally {
                setGatewayCodexAppServerRunnerForTest(None<(GatewayCodexAppServerTurnRequest) -> GatewayCodexAppServerRuntimeResult>)
            }
        })
    }

    @TestCase
    public func codexAppServerInputAndMetadataStayHumanSafeAndStructured(): Unit {
        let usage = JsonObject()
        usage.put("promptTokens", JsonInt(3))
        usage.put("outputTokens", JsonInt(2))
        let input = gatewayBuildCodexAppServerInput("system rule", "user: hi")
        let meta = gatewayCodexAppServerRuntimeMetadata(
            "openai-codex:gpt-5.5",
            "Telegram",
            "agent:codex:telegram:direct:u1",
            threadId: "thread-1",
            turnId: "turn-1",
            completed: true,
            interrupted: false,
            toolIterations: 1,
            usage: Some(usage)
        )

        @Expect(input.contains("<system>\nsystem rule\n</system>"), true)
        @Expect(input.contains("<input>\nuser: hi\n</input>"), true)
        @Expect(meta.get("runtime").getOrThrow().asString().getValue(), "codex_app_server")
        @Expect(meta.get("channel").getOrThrow().asString().getValue(), "telegram")
        @Expect(meta.get("completed").getOrThrow().asBool().getValue(), true)
        @Expect(meta.get("toolIterations").getOrThrow().asInt().getValue(), 1)
        @Expect(gatewayCodexAppServerUsageInt(Some(usage), "promptTokens"), 3)
        @Expect(gatewayCodexAppServerUsageInt(Some(usage), "missing"), -1)
    }

    @TestCase
    public func codexResponsesDefaultModelFlowsThroughGatewaySessionForImChannels(): Unit {
        withAgentBridgeTempHome("metis-m3-codex-responses-im", { home: Path =>
            writeAgentBridgeCodexResponsesAgentConfig(home)
            let now = DateTime.now().toUnixTimeStamp().toSeconds()
            let _ = writeOpenAICodexOAuthProfile(OpenAICodexOAuthProfile(
                accessToken: "m3-access-token-never-log",
                refreshToken: "m3-refresh-token-never-log",
                expiresAtUnixSeconds: now + 3600,
                lastRefreshUnixSeconds: now,
                accountLabel: "m3",
                source: "test"
            ))
            let capture = AgentBridgeCodexResponsesCapture()
            setCodexResponsesHttpRunnerForTest(Some({ request: CodexResponsesHttpRequest =>
                capture.callCount += 1
                capture.urls.add(request.url)
                capture.bodies.add(request.body)
                capture.authHeaders.add(request.headers.get("Authorization").getOrThrow())
                CodexResponsesHttpResult(200, body: "{\"model\":\"gpt-5.5\",\"status\":\"completed\",\"output_text\":\"codex responses ok\"}")
            }))
            try {
                let store = GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "codex")
                let bridge = AgentBridge(sessionStore: store)
                for (channel in ["telegram", "feishu", "qq"]) {
                    let request = GatewaySessionRequest(
                        GatewayIngressSource.Channel(channel),
                        channelName: channel,
                        sessionHint: "m3-${channel}",
                        agentId: "codex",
                        text: "hello ${channel}",
                        accountId: "acct-${channel}",
                        peerId: "peer-${channel}"
                    )
                    let turn = gatewayExecuteSessionRequestTurn(
                        bridge,
                        request,
                        "hello ${channel}",
                        streamingEnabled: false
                    )
                    @Expect(turn.context.channelName, channel)
                    @Expect(turn.execution.answer, "codex responses ok")
                    @Expect(turn.execution.delivered, false)
                }

                @Expect(capture.callCount >= 3, true)
                for (url in capture.urls) {
                    @Expect(url, "https://chatgpt.com/backend-api/codex/responses")
                }
                for (auth in capture.authHeaders) {
                    @Expect(auth, "Bearer m3-access-token-never-log")
                }
                for (body in capture.bodies) {
                    @Expect(agentBridgeJsonString(body, "model"), "gpt-5.5")
                    @Expect(agentBridgeJsonBool(body, "store"), false)
                    @Expect(body.get("max_output_tokens").isNone(), true)
                }
            } finally {
                setCodexResponsesHttpRunnerForTest(None<CodexResponsesHttpRunner>)
            }
        })
    }

    @TestCase
    public func gatewayTurnGroupPolicySystemPromptIsAddedToRuntimePromptAndToolsAreNarrowed(): Unit {
        let route = JsonObject()
        let groupPolicy = JsonObject()
        groupPolicy.put("systemPrompt", JsonString("group-a-only-system-prompt"))
        groupPolicy.put("skills", JsonArray([JsonString("feishu-docs")]))
        let tools = JsonObject()
        tools.put("allow", JsonArray([JsonString("feishu_fetch_doc")]))
        groupPolicy.put("tools", tools)
        route.put("groupPolicy", groupPolicy)
        let context = GatewayTurnContext(
            "writer",
            sessionKey: "agent:writer:feishu:group:oc_a",
            channelName: "feishu",
            accountId: "tenant-a",
            peerId: "oc_a",
            route: route
        )

        let names = gatewayPolicyFilteredChatToolNamesForTurnContext(context)
        let prompt = gatewayPolicyFilteredSystemPromptForTurnContext(
            context,
            channelName: "feishu",
            modelName: "openai:gpt-4o-mini"
        )

        @Expect(names.contains("feishu_fetch_doc"), true)
        @Expect(names.contains("feishu_drive_file"), false)
        @Expect(prompt.contains("group-a-only-system-prompt"), true)
    }

    // @TestCase
    // public func gatewayProviderTimingSummaryIncludesCoreFields(): Unit {
    //     let line = gatewayProviderTimingSummary(
    //         "telegram",
    //         "qwen/qwen3.6-plus",
    //         1,
    //         39077,
    //         105,
    //         7204,
    //         "success",
    //         localPreCallMs: 11
    //     )
    //     @Expect(line.contains("channel=telegram"), true)
    //     @Expect(line.contains("provider=qwen"), true)
    //     @Expect(line.contains("model=qwen/qwen3.6-plus"), true)
    //     @Expect(line.contains("attempt=1"), true)
    //     @Expect(line.contains("status=success"), true)
    //     @Expect(line.contains("promptChars=39077"), true)
    //     @Expect(line.contains("answerChars=105"), true)
    //     @Expect(line.contains("elapsedMs=7204"), true)
    //     @Expect(line.contains("localPreCallMs=11"), true)
    // }

    // @TestCase
    // public func gatewayProviderTimingSummarySanitizesFailureError(): Unit {
    //     let line = gatewayProviderTimingSummary(
    //         "cli",
    //         "qwen/qwen3.6-plus",
    //         1,
    //         0,
    //         0,
    //         3000,
    //         "failed",
    //         error: "timeout\nprovider unavailable"
    //     )
    //     @Expect(line.contains("status=failed"), true)
    //     @Expect(line.contains("error=timeout provider unavailable"), true)
    // }

    // @TestCase
    // public func buildGatewayModelInputUsesCompactHistoryShape(): Unit {
    //     let history = ArrayList<String>()
    //     history.add("user: hello")
    //     history.add("assistant: hi")
    //     history.add("user: summarize this")
    //     let input = buildGatewayModelInput(
    //         history.toArray(),
    //         "reply with ok",
    //         "<available_skills>\n<skill name=\"weather\" enabled=\"true\" location=\"/tmp/weather\">forecast lookup</skill>\n</available_skills>"
    //     )
    //     @Expect(input.contains("<history>"), true)
    //     @Expect(input.contains("以下是最近对话历史"), false)
    //     @Expect(input.contains("用户当前问题"), false)
    //     @Expect(input.contains("user: reply with ok"), true)
    //     @Expect(input.contains("Use <skills> only to decide"), true)
    // }
}
