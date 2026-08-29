package metis.gateway.core

import magic.config.Config
import magic.core.message.Message
import magic.core.model.{AsyncChatResponse, ChatModel, ChatRequest, ChatResponse}
import magic.core.tool.*
import magic.jsonable.TypeSchema
import magic.model.ModelManager
import metis.core.config.{CliConfig, CliModelRuntimeStateManager, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock, OpenAICodexOAuthProfile, writeOpenAICodexOAuthProfile}
import metis.core.{GatewayToolRuntimeContext, gatewayCurrentToolRuntimeContext, gatewayToolRuntimeContextDebugSummary, gatewayWithToolRuntimeContext}
import metis.core.model.{CodexResponsesHttpRequest, CodexResponsesHttpResult, CodexResponsesHttpRunner, setCodexResponsesHttpRunnerForTest}
import metis.gateway.logging.{gatewayLoggingCaptureConsoleForTest, gatewayLoggingCapturedConsoleForTest, gatewayLoggingCurrentLogFile, gatewayLoggingResetForTest}
import metis.gateway.session.{GatewayIngressSource, GatewaySessionRequest, GatewayTurnContext, gatewayResolveSessionContext}
import metis.process.{managedStdioBroker, resetManagedStdioBrokerForTest}

import std.collection.{ArrayList, HashMap}
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.process.executeWithOutput
import std.sync.{AtomicBool, Condition, Mutex}
import std.time.*
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonInt, JsonObject, JsonString, JsonValue}

private class AgentBridgeActivityControl <: GatewayExecutionControl {
    public var heartbeats: Int64 = 0
    public var checks: Int64 = 0
    public var cancelled: Bool = false

    public func remainingMs(): Int64 { if (this.cancelled) { 0 } else { 60000 } }
    public func heartbeat(): Unit {
        if (!this.cancelled) {
            this.heartbeats += 1
        }
    }
    public func isCancelled(): Bool { this.cancelled }
    public func throwIfCancelled(): Unit {
        this.checks += 1
        if (this.cancelled) {
            throw GatewayExecutionCancelledException("test_cancelled")
        }
    }
}

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

private func agentBridgeJoinFuture<T>(future: Option<Future<T>>, timeoutMs: Int64): Unit {
    match (future) {
        case Some(value) => try { let _ = value.get(Duration.millisecond * timeoutMs) } catch (_: Exception) { () }
        case None => ()
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

private func writeAgentBridgeParallelCodexAppServerAgentConfig(home: Path): Unit {
    let root = JsonObject()
    let agents = JsonObject()
    let defaults = JsonObject()
    defaults.put("workspace", JsonString(home.join("workspaces").toString()))
    agents.put("defaults", defaults)
    let list = JsonArray([])
    for (id in ["codex-a", "codex-b"]) {
        let entry = agentBridgeAgentEntry(
            id,
            home.join("workspaces").join(id),
            home.join("agents").join(id).join("agent"),
            "openai-codex:gpt-5.5"
        )
        let model = entry.get("model").getOrThrow().asObject()
        model.put("fallbacks", JsonArray([]))
        model.put("openaiRuntime", JsonString("codex_app_server"))
        list.add(entry)
    }
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

private func writeAgentBridgePhase1FallbackAgentConfig(
    home: Path,
    primary: String,
    fallbacks: Array<String>,
    appServer!: Bool = true
): Unit {
    let root = JsonObject()
    let agents = JsonObject()
    let defaults = JsonObject()
    defaults.put("workspace", JsonString(home.join("workspaces").toString()))
    agents.put("defaults", defaults)
    let list = JsonArray([])
    let entry = JsonObject()
    entry.put("id", JsonString("phase1"))
    entry.put("workspace", JsonString(home.join("workspaces").join("phase1").toString()))
    entry.put("agentDir", JsonString(home.join("agents").join("phase1").join("agent").toString()))
    let model = JsonObject()
    model.put("primary", JsonString(primary))
    let fallbackItems = JsonArray([])
    for (fallback in fallbacks) {
        fallbackItems.add(JsonString(fallback))
    }
    model.put("fallbacks", fallbackItems)
    if (appServer) {
        model.put("openaiRuntime", JsonString("codex_app_server"))
    }
    entry.put("model", model)
    list.add(entry)
    agents.put("list", list)
    root.put("agents", agents)
    File.writeTo(MetisConfigManager.configPath(), root.toJsonString().toArray())
    CliConfig.invalidatePathCache()
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
}

private func withAgentBridgeRuntimeLogCapture<T>(home: Path, name: String, block: (String) -> T): T {
    let oldLevel = Config.logLevel
    let oldFile = Config.logFile
    let oldMetisLevel = getVariable("METIS_LOG_LEVEL")
    let oldMetisFile = getVariable("METIS_LOG_FILE")
    let oldMetisConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
    let path = home.join("logs").join("agent-bridge-phase1-${name}.log").toString()
    Directory.create(Path(path).parent, recursive: true)
    try { remove(Path(path), recursive: true) } catch (_: Exception) { () }
    Config.logLevel = "debug"
    Config.logFile = path
    setVariable("METIS_LOG_LEVEL", "debug")
    setVariable("METIS_LOG_FILE", path)
    setVariable("METIS_CONSOLE_LEVEL", "debug")
    gatewayLoggingResetForTest()
    gatewayLoggingCaptureConsoleForTest()
    try {
        return block(path)
    } finally {
        Config.logLevel = oldLevel
        Config.logFile = oldFile
        match (oldMetisLevel) {
            case Some(value) => setVariable("METIS_LOG_LEVEL", value)
            case None => setVariable("METIS_LOG_LEVEL", "")
        }
        match (oldMetisFile) {
            case Some(value) => setVariable("METIS_LOG_FILE", value)
            case None => setVariable("METIS_LOG_FILE", "")
        }
        match (oldMetisConsoleLevel) {
            case Some(value) => setVariable("METIS_CONSOLE_LEVEL", value)
            case None => setVariable("METIS_CONSOLE_LEVEL", "")
        }
        gatewayLoggingResetForTest()
    }
}

private func agentBridgeRuntimeReadCapturedLog(path: String): String {
    let captured = String.join(gatewayLoggingCapturedConsoleForTest(), delimiter: "\n")
    let fileLog = if (exists(Path(path))) {
        String.fromUtf8(File.readFrom(Path(path)))
    } else {
        ""
    }
    fileLog + "\n" + captured
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

private func agentBridgeToolRequiredContains(schema: JsonValue, paramName: String): Bool {
    let obj = schema.asObject()
    let params = obj.get("parameters").getOrThrow().asObject()
    let required = params.get("required").getOrThrow().asArray().getItems()
    for (item in required) {
        if (item.asString().getValue() == paramName) {
            return true
        }
    }
    return false
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
    public let acceptHeaders = ArrayList<String>()

    public init() {}
}

private func agentBridgeCodexResponsesMessageItem(text: String): JsonObject {
    let item = JsonObject()
    item.put("type", JsonString("message"))
    item.put("role", JsonString("assistant"))
    let content = JsonArray()
    let part = JsonObject()
    part.put("type", JsonString("output_text"))
    part.put("text", JsonString(text))
    content.add(part)
    item.put("content", content)
    item
}

private func agentBridgeCodexResponsesCompletedEvent(text: String): JsonObject {
    let output = JsonArray()
    output.add(agentBridgeCodexResponsesMessageItem(text))
    let response = JsonObject()
    response.put("model", JsonString("gpt-5.5"))
    response.put("status", JsonString("completed"))
    response.put("output", output)
    let event = JsonObject()
    event.put("type", JsonString("response.completed"))
    event.put("response", response)
    event
}

private var agentBridgePhase1PrimaryCalls: Int64 = 0
private var agentBridgePhase1FallbackCalls: Int64 = 0

private class AgentBridgePhase1FallbackModel <: ChatModel {
    private var _maxTokens: Option<Int64> = None

    public prop provider: String {
        get() { "fake" }
    }

    public prop name: String {
        get() { "agent-bridge-phase1-fallback" }
    }

    public prop contextLength: Int64 {
        get() { 8192 }
    }

    public mut prop maxTokens: Option<Int64> {
        get() { this._maxTokens }
        set(v) { this._maxTokens = v }
    }

    public func create(_request: ChatRequest): ChatResponse {
        agentBridgePhase1FallbackCalls += 1
        ChatResponse(this.fullName, Message.assistant("phase1 fallback answer"))
    }

    public func asyncCreate(_request: ChatRequest): AsyncChatResponse {
        throw Exception("async not used in phase1 agent bridge tests")
    }
}

private class AgentBridgeS4RssOverlapProbe {
    private let lock = Mutex()
    private var condition: Condition
    private var entered: Int64 = 0
    private var active: Int64 = 0
    private var maxActive: Int64 = 0
    private var released: Bool = false
    private var value: Int64 = 1000

    public init() {
        synchronized(this.lock) { this.condition = this.lock.condition() }
    }

    public func next(): Int64 {
        synchronized(this.lock) {
            this.value += 10
            if (this.entered < 2) {
                this.entered++
                this.active++
                this.maxActive = max(this.maxActive, this.active)
                this.condition.notifyAll()
                while (!this.released) { this.condition.wait() }
                this.active--
                this.condition.notifyAll()
            }
            this.value
        }
    }

    public func release(): Unit {
        synchronized(this.lock) {
            this.released = true
            this.condition.notifyAll()
        }
    }

    public func awaitEntered(expected: Int64, timeoutMs: Int64): Bool {
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
        synchronized(this.lock) {
            while (this.entered < expected) {
                let remaining = deadline - DateTime.now().toUnixTimeStamp().toMilliseconds()
                if (remaining <= 0) { return false }
                let _ = this.condition.wait(timeout: Duration.millisecond * remaining)
            }
            true
        }
    }

    public func peak(): Int64 { synchronized(this.lock) { this.maxActive } }
}

private func resetAgentBridgePhase1FakeModels(): Unit {
    agentBridgePhase1PrimaryCalls = 0
    agentBridgePhase1FallbackCalls = 0
}

// C0 contract fixture: later recovery tests can drive exact model results without
// accessing a provider or interpreting the result as a production outcome.
private class AgentBridgeC0FakeModel {
    private let results: Array<String>
    private var cursor: Int64 = 0
    public var callCount: Int64 = 0

    public init(results: Array<String>) {
        this.results = results
    }

    public func nextResult(): String {
        this.callCount += 1
        if (this.cursor >= Int64(this.results.size)) {
            throw Exception("c0_fake_model_exhausted")
        }
        let result = this.results[this.cursor]
        this.cursor += 1
        if (result == "__c0_fake_model_throw__") {
            throw Exception("c0_fake_model_failure")
        }
        result
    }
}

private class AgentBridgeC0FakeTool {
    public var callCount: Int64 = 0

    public func invoke(): String {
        this.callCount += 1
        "fake_tool_result"
    }
}

private class AgentBridgeMemoryRssProbe {
    private var value: Int64 = 1000
    private var callCount: Int64 = 0

    public init() {}

    public func next(): Int64 {
        this.callCount += 1
        this.value += 10
        this.value
    }

    public func calls(): Int64 { this.callCount }
}

private func agentBridgeMemoryRows(path: String): Array<JsonObject> {
    let rows = ArrayList<JsonObject>()
    let raw = try {
        String.fromUtf8(File.readFrom(Path(path)))
    } catch (_: Exception) {
        ""
    }
    for (line in raw.split("\n")) {
        let trimmed = line.trimAscii()
        if (!trimmed.isEmpty()) {
            try {
                let row = JsonValue.fromStr(trimmed).asObject()
                if (agentBridgeJsonString(row, "event") == "process.memory") {
                    rows.add(row)
                }
            } catch (_: Exception) {
                ()
            }
        }
    }
    rows.toArray()
}

private func agentBridgeMemorySeparateFrameworkLog(home: Path): Unit {
    let _ = gatewayLoggingCurrentLogFile()
    Config.logFile = home.join("logs").join("framework-memory-test.log").toString()
}

private func agentBridgeWriteS4Evidence(label: String, analysis: GatewayMemoryAnalysisForTest): Unit {
    match (getVariable("METIS_MEMORY_S4_EVIDENCE_DIR")) {
        case Some(raw) =>
            let normalized = raw.trimAscii()
            if (!normalized.isEmpty()) {
                let dir = Path(normalized)
                if (!exists(dir)) { Directory.create(dir, recursive: true) }
                let row = JsonObject()
                row.put("experiment", JsonString(label))
                row.put("status", JsonString(analysis.status))
                row.put("sampledTurns", JsonInt(analysis.sampledTurns))
                row.put("enterRssSlopeKbPerTurn", JsonInt(analysis.enterRssSlopeKbPerTurn))
                row.put("lateEnterRssSlopeKbPerTurn", JsonInt(analysis.lateEnterRssSlopeKbPerTurn))
                row.put("providerDeltaKb", JsonInt(analysis.providerDeltaKb))
                row.put("correctionDeltaKb", JsonInt(analysis.correctionDeltaKb))
                row.put("persistDeltaKb", JsonInt(analysis.persistDeltaKb))
                row.put("releaseDeltaKb", JsonInt(analysis.releaseDeltaKb))
                row.put("settledFloorKb", JsonInt(analysis.settledFloorKb))
                File.writeTo(dir.join("${label}.json"), row.toJsonString().toArray())
            }
        case None => ()
    }
}

private func agentBridgeWaitForS4ExternalSampler(): Unit {
    match (getVariable("METIS_MEMORY_S4_SAMPLER_READY")) {
        case Some(raw) =>
            let normalized = raw.trimAscii()
            if (!normalized.isEmpty()) {
                let marker = Path(normalized)
                let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 5000
                while (!exists(marker) && DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
                    sleep(Duration.millisecond * 20)
                }
                @Expect(exists(marker), true)
            }
        case None => ()
    }
}

private func agentBridgeRunS4HundredTurnExperiment(
    home: Path,
    label: String,
    extraSystemPrompt: String,
    sameSession: Bool,
    externalRssOnly!: Bool = false
): GatewayMemoryAnalysisForTest {
    let modelName = "metis-test-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
    ModelManager.registerChatModel(modelName, { => AgentBridgePhase1FallbackModel() })
    writeAgentBridgePhase1FallbackAgentConfig(home, modelName, [], appServer: false)
    withAgentBridgeRuntimeLogCapture(home, label, { logPath: String =>
        resetGatewayMemoryObservationForTest()
        setGatewayProcessRssProviderForTest(if (externalRssOnly) {
            Some<() -> Int64>({ => 4096 })
        } else {
            None<() -> Int64>
        })
        agentBridgeMemorySeparateFrameworkLog(home)
        try {
            let bridge = AgentBridge(sessionStore: GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "phase1"))
            for (i in 1..=100) {
                let context = gatewayResolveSessionContext(GatewaySessionRequest(
                    GatewayIngressSource.DashboardRpc,
                    sessionHint: if (sameSession) { "${label}-shared" } else { "${label}-${i}" },
                    agentId: "phase1"
                ))
                let outcome = bridge.replyWithOutcome(
                    context.sessionKey,
                    "fixed-input-${i}",
                    channelName: "gitcode",
                    agentId: "phase1",
                    extraSystemPrompt: extraSystemPrompt,
                    turnContext: Some(context.turnContext)
                )
                @Expect(outcome.status, "valid_text")
                @Expect(outcome.modelAttempts, 1)
                let _ = gatewayLogServicePluginTurnReleased(
                    outcome.memoryTurnSequence,
                    outcome.memorySampled,
                    outcome.memoryBaselineRssKb,
                    gatewayLogIdentityHash(context.sessionKey),
                    meta: gatewayLogMeta().int("dispatchActive", 0).int("dispatchQueued", 0).object()
                )
            }
            let analysis = gatewayMemoryAnalyzeRowsForTest(agentBridgeMemoryRows(logPath))
            agentBridgeWriteS4Evidence(label, analysis)
            analysis
        } finally {
            resetGatewayMemoryObservationForTest()
        }
    })
}

private func agentBridgeLogS4Released(outcome: GatewayAgentReplyOutcome, sessionKey: String): Unit {
    let _ = gatewayLogServicePluginTurnReleased(
        outcome.memoryTurnSequence,
        outcome.memorySampled,
        outcome.memoryBaselineRssKb,
        gatewayLogIdentityHash(sessionKey),
        meta: gatewayLogMeta().int("dispatchActive", 0).int("dispatchQueued", 0).object()
    )
}

private func agentBridgeRunS4ConcurrencyExperiment(
    home: Path,
    label: String,
    parallel: Bool
): (GatewayMemoryAnalysisForTest, Int64) {
    let overlap = AgentBridgeS4RssOverlapProbe()
    let serialRss = AgentBridgeMemoryRssProbe()
    let modelName = "metis-test-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
    ModelManager.registerChatModel(modelName, { => AgentBridgePhase1FallbackModel() })
    writeAgentBridgePhase1FallbackAgentConfig(home, modelName, [], appServer: false)
    let captureHome = home.join(label)
    Directory.create(captureHome, recursive: true)
    let analysis = withAgentBridgeRuntimeLogCapture(captureHome, label, { logPath: String =>
        resetGatewayMemoryObservationForTest()
        setGatewayProcessRssProviderForTest(if (parallel) {
            Some<() -> Int64>({ => overlap.next() })
        } else {
            Some<() -> Int64>({ => serialRss.next() })
        })
        agentBridgeMemorySeparateFrameworkLog(captureHome)
        try {
            if (parallel) {
                let firstBridge = AgentBridge(sessionStore: GatewaySessionStore(home.join("sessions-a"), enabled: true, agentId: "phase1"))
                let secondBridge = AgentBridge(sessionStore: GatewaySessionStore(home.join("sessions-b"), enabled: true, agentId: "phase1"))
                for (i in 1..=10) {
                    let firstContext = gatewayResolveSessionContext(GatewaySessionRequest(
                        GatewayIngressSource.DashboardRpc, sessionHint: "${label}-a-${i}", agentId: "phase1"
                    ))
                    let secondContext = gatewayResolveSessionContext(GatewaySessionRequest(
                        GatewayIngressSource.DashboardRpc, sessionHint: "${label}-b-${i}", agentId: "phase1"
                    ))
                    let first = spawn {
                        firstBridge.replyWithOutcome(
                            firstContext.sessionKey, "parallel-a-${i}", channelName: "gitcode", agentId: "phase1",
                            turnContext: Some(firstContext.turnContext)
                        )
                    }
                    let second = spawn {
                        secondBridge.replyWithOutcome(
                            secondContext.sessionKey, "parallel-b-${i}", channelName: "gitcode", agentId: "phase1",
                            turnContext: Some(secondContext.turnContext)
                        )
                    }
                    if (i == 1) {
                        @Expect(overlap.awaitEntered(2, 5000), true)
                        overlap.release()
                    }
                    let firstOutcome = first.get(Duration.second * 10)
                    let secondOutcome = second.get(Duration.second * 10)
                    agentBridgeLogS4Released(firstOutcome, firstContext.sessionKey)
                    agentBridgeLogS4Released(secondOutcome, secondContext.sessionKey)
                }
            } else {
                let bridge = AgentBridge(sessionStore: GatewaySessionStore(home.join("sessions-serial"), enabled: true, agentId: "phase1"))
                for (i in 1..=20) {
                    let context = gatewayResolveSessionContext(GatewaySessionRequest(
                        GatewayIngressSource.DashboardRpc, sessionHint: "${label}-${i}", agentId: "phase1"
                    ))
                    let outcome = bridge.replyWithOutcome(
                        context.sessionKey, "serial-${i}", channelName: "gitcode", agentId: "phase1",
                        turnContext: Some(context.turnContext)
                    )
                    agentBridgeLogS4Released(outcome, context.sessionKey)
                }
            }
            let result = gatewayMemoryAnalyzeRowsForTest(agentBridgeMemoryRows(logPath))
            agentBridgeWriteS4Evidence(label, result)
            result
        } finally {
            overlap.release()
            resetGatewayMemoryObservationForTest()
        }
    })
    (analysis, if (parallel) { overlap.peak() } else { 1 })
}

private func agentBridgeC0ClassifyRawResult(text: String): String {
    if (text.isEmpty()) {
        return "empty"
    }
    if (text == "[\"web_fetch\"]") {
        return "tool_name_array"
    }
    if (text.contains("<tool_call>")) {
        return "blocked_xml"
    }
    "text"
}

private class AgentBridgeRuntimeContextProbeTool <: Tool {
    public prop name: String {
        get() { "agent_bridge_context_probe" }
    }

    public prop description: String {
        get() { "captures current gateway tool runtime context" }
    }

    public prop parameters: Array<ToolParameter> {
        get() { [] }
    }

    public prop retType: TypeSchema {
        get() { TypeSchema.Str }
    }

    public prop examples: Array<String> {
        get() { [] }
    }

    public prop extra: HashMap<String, String> {
        get() { HashMap<String, String>() }
    }

    public func invoke(_args: HashMap<String, JsonValue>): ToolResponse {
        match (gatewayCurrentToolRuntimeContext()) {
            case Some(context) =>
                ToolResponse(gatewayToolRuntimeContextDebugSummary(context).toJsonString())
            case None => ToolResponse("none", isError: true)
        }
    }

    public func toJsonValue(): JsonValue {
        JsonString(this.name)
    }
}

private func agentBridgeRuntimeWrappedProbeForContext(context: GatewayToolRuntimeContext): Tool {
    let tools = ArrayList<Tool>()
    tools.add(AgentBridgeRuntimeContextProbeTool())
    let wrapped = gatewayWithToolRuntimeContext(context, { =>
        gatewayLifecycleWrappedTools(
            tools,
            inventory: ["agent_bridge_context_probe"],
            capturedRuntimeContext: gatewayCurrentToolRuntimeContext()
        )
    })
    wrapped[0]
}

@Test
public class AgentBridgeC0ContractTest {
    @TestCase
    public func c0U01FakeModelAndToolPreserveRawResultClassesAndUtf8(): Unit {
        let model = AgentBridgeC0FakeModel([
            "正常中文😀",
            "",
            "[\"web_fetch\"]",
            "<tool_call>web_fetch</tool_call>",
            "__c0_fake_model_throw__",
            "异常后正常文本🙂"
        ])
        let tool = AgentBridgeC0FakeTool()

        let normal = model.nextResult()
        let empty = model.nextResult()
        let toolArray = model.nextResult()
        let blockedXml = model.nextResult()
        @Expect(agentBridgeC0ClassifyRawResult(normal), "text")
        @Expect(agentBridgeC0ClassifyRawResult(empty), "empty")
        @Expect(agentBridgeC0ClassifyRawResult(toolArray), "tool_name_array")
        @Expect(agentBridgeC0ClassifyRawResult(blockedXml), "blocked_xml")
        @Expect(String.fromUtf8(normal.toArray()), "正常中文😀")
        var error = ""
        try {
            let _ = model.nextResult()
        } catch (e: Exception) {
            error = e.message
        }
        @Expect(error, "c0_fake_model_failure")
        @Expect(model.nextResult(), "异常后正常文本🙂")
        @Expect(tool.invoke(), "fake_tool_result")
        @Expect(model.callCount, 6)
        @Expect(tool.callCount, 1)
    }
}

@Test
public class AgentBridgeRuntimeTest {
    @TestCase
    public func s1U1ModelTurnEmitsOrderedMemoryStagesWithStableDelta(): Unit {
        withAgentBridgeTempHome("metis-s1-memory-u1", { home: Path =>
            let modelName = "metis-test-s1-u1-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
            ModelManager.registerChatModel(modelName, { => AgentBridgePhase1FallbackModel() })
            writeAgentBridgePhase1FallbackAgentConfig(home, modelName, [], appServer: false)
            let context = gatewayResolveSessionContext(GatewaySessionRequest(
                GatewayIngressSource.DashboardRpc,
                sessionHint: "memory-u1",
                agentId: "phase1"
            ))
            withAgentBridgeRuntimeLogCapture(home, "memory-u1", { logPath: String =>
                let probe = AgentBridgeMemoryRssProbe()
                resetGatewayMemoryObservationForTest()
                setGatewayProcessRssProviderForTest(Some({ => probe.next() }))
                agentBridgeMemorySeparateFrameworkLog(home)
                try {
                    let bridge = AgentBridge(sessionStore: GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "phase1"))
                    @Expect(bridge.reply(context.sessionKey, "hello", channelName: "dashboard", agentId: "phase1",
                        turnContext: Some(context.turnContext)), "phase1 fallback answer")
                    let stages = ArrayList<String>()
                    for (row in agentBridgeMemoryRows(logPath)) {
                        stages.add(agentBridgeJsonString(row, "stage"))
                        @Expect(row.get("rssKb").getOrThrow().asInt().getValue() >= 0, true)
                        @Expect(row.get("rssDeltaKb").getOrThrow().asInt().getValue() >= 0, true)
                    }
                    @Expect(stages.toArray(), [
                        "turn_enter", "history_loaded", "model_input_built", "system_prompt_built",
                        "model_returned", "final_correction_ready", "session_persisted", "turn_exit", "turn_summary"
                    ])
                    @Expect(probe.calls(), 8)
                    @Expect(String.join(gatewayLoggingCapturedConsoleForTest(), delimiter: "\n").contains("process.memory"), false)
                } finally {
                    resetGatewayMemoryObservationForTest()
                }
            })
        })
    }

    @TestCase
    public func s1B1UnicodeAndLongPayloadRemainOutOfMemoryRows(): Unit {
        withAgentBridgeTempHome("metis-s1-memory-b1", { home: Path =>
            let modelName = "metis-test-s1-b1-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
            ModelManager.registerChatModel(modelName, { => AgentBridgePhase1FallbackModel() })
            writeAgentBridgePhase1FallbackAgentConfig(home, modelName, [], appServer: false)
            let context = gatewayResolveSessionContext(GatewaySessionRequest(
                GatewayIngressSource.DashboardRpc, sessionHint: "memory-b1", agentId: "phase1"
            ))
            withAgentBridgeRuntimeLogCapture(home, "memory-b1", { logPath: String =>
                resetGatewayMemoryObservationForTest()
                setGatewayProcessRssProviderForTest(Some({ => 2048 }))
                agentBridgeMemorySeparateFrameworkLog(home)
                try {
                    let secretText = "中文🙂-memory-payload-must-not-leak-" + "x" * 20000
                    let bridge = AgentBridge(sessionStore: GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "phase1"))
                    @Expect(bridge.reply(context.sessionKey, secretText, channelName: "dashboard", agentId: "phase1",
                        turnContext: Some(context.turnContext)), "phase1 fallback answer")
                    let rows = agentBridgeMemoryRows(logPath)
                    @Expect(rows.size, 9)
                    let memoryJson = String.join(rows.map({ row: JsonObject => row.toJsonString() }), delimiter: "\n")
                    @Expect(memoryJson.contains("中文"), false)
                    @Expect(memoryJson.contains("🙂"), false)
                    @Expect(memoryJson.contains("memory-payload-must-not-leak"), false)
                } finally {
                    resetGatewayMemoryObservationForTest()
                }
            })
        })
    }

    @TestCase
    public func s1P1SecondTurnReportsLargerPersistedTranscript(): Unit {
        withAgentBridgeTempHome("metis-s1-memory-p1", { home: Path =>
            let modelName = "metis-test-s1-p1-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
            ModelManager.registerChatModel(modelName, { => AgentBridgePhase1FallbackModel() })
            writeAgentBridgePhase1FallbackAgentConfig(home, modelName, [], appServer: false)
            let context = gatewayResolveSessionContext(GatewaySessionRequest(
                GatewayIngressSource.DashboardRpc, sessionHint: "memory-p1", agentId: "phase1"
            ))
            withAgentBridgeRuntimeLogCapture(home, "memory-p1", { logPath: String =>
                resetGatewayMemoryObservationForTest()
                setGatewayProcessRssProviderForTest(Some({ => 4096 }))
                agentBridgeMemorySeparateFrameworkLog(home)
                try {
                    let bridge = AgentBridge(sessionStore: GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "phase1"))
                    let _ = bridge.reply(context.sessionKey, "first", channelName: "dashboard", agentId: "phase1",
                        turnContext: Some(context.turnContext))
                    let _ = bridge.reply(context.sessionKey, "second 中文🙂", channelName: "dashboard", agentId: "phase1",
                        turnContext: Some(context.turnContext))
                    let persisted = ArrayList<Int64>()
                    for (row in agentBridgeMemoryRows(logPath)) {
                        if (agentBridgeJsonString(row, "stage") == "session_persisted") {
                            persisted.add(row.get("transcriptBytes").getOrThrow().asInt().getValue())
                        }
                    }
                    @Expect(persisted.size, 2)
                    @Expect(persisted[1] > persisted[0], true)
                } finally {
                    resetGatewayMemoryObservationForTest()
                }
            })
        })
    }

    @TestCase
    public func s1N1SlashBypassHasNoRowsAndModelFailureHasStableTerminal(): Unit {
        withAgentBridgeTempHome("metis-s1-memory-n1", { home: Path =>
            writeAgentBridgePhase1FallbackAgentConfig(home, "openai-codex:gpt-5.5", [])
            let context = gatewayResolveSessionContext(GatewaySessionRequest(
                GatewayIngressSource.DashboardRpc, sessionHint: "memory-n1", agentId: "phase1"
            ))
            withAgentBridgeRuntimeLogCapture(home, "memory-n1", { logPath: String =>
                resetGatewayMemoryObservationForTest()
                setGatewayProcessRssProviderForTest(Some({ => 8192 }))
                agentBridgeMemorySeparateFrameworkLog(home)
                let bridge = AgentBridge(sessionStore: GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "phase1"))
                setGatewayCodexAppServerRunnerForTest(Some({ _request: GatewayCodexAppServerTurnRequest =>
                    throw Exception("Authorization: Bearer failure-secret-must-not-leak")
                }))
                try {
                    let slash = bridge.replyWithOutcome(context.sessionKey, "/definitely_unknown", channelName: "dashboard",
                        agentId: "phase1", turnContext: Some(context.turnContext))
                    @Expect(slash.status, "valid_text")
                    @Expect(agentBridgeMemoryRows(logPath).size, 0)
                    var failed = false
                    try {
                        let _ = bridge.replyWithOutcome(context.sessionKey, "fail", channelName: "dashboard",
                            agentId: "phase1", turnContext: Some(context.turnContext))
                    } catch (_: Exception) {
                        failed = true
                    }
                    @Expect(failed, true)
                    let rows = agentBridgeMemoryRows(logPath)
                    @Expect(agentBridgeJsonString(rows[rows.size - 1], "stage"), "turn_summary")
                    @Expect(agentBridgeJsonString(rows[rows.size - 1], "status"), "failed")
                    @Expect(agentBridgeJsonString(rows[rows.size - 1], "errorKind"), "model_failed")
                    let memoryJson = String.join(rows.map({ row: JsonObject => row.toJsonString() }), delimiter: "\n")
                    @Expect(memoryJson.contains("failure-secret-must-not-leak"), false)
                    @Expect(memoryJson.contains("Authorization"), false)
                } finally {
                    setGatewayCodexAppServerRunnerForTest(None<(GatewayCodexAppServerTurnRequest) -> GatewayCodexAppServerRuntimeResult>)
                    resetGatewayMemoryObservationForTest()
                }
            })
        })
    }

    @TestCase
    public func s4P1R1HundredUniqueSessionsWithSmallPromptProduceCompleteEvidence(): Unit {
        withAgentBridgeTempHome("metis-memory-s4-r1", { home: Path =>
            let analysis = agentBridgeRunS4HundredTurnExperiment(home, "r1-unique-small", "", false)
            @Expect(analysis.status, "complete")
            @Expect(analysis.sampledTurns, 23)
            @Expect(analysis.settledFloorKb >= 0, true)
        })
    }

    @TestCase
    public func s4P1R2HundredUniqueSessionsWithLargePromptProduceCompleteEvidence(): Unit {
        withAgentBridgeTempHome("metis-memory-s4-r2", { home: Path =>
            let analysis = agentBridgeRunS4HundredTurnExperiment(home, "r2-unique-large", "系" * 35900, false)
            @Expect(analysis.status, "complete")
            @Expect(analysis.sampledTurns, 23)
            @Expect(analysis.settledFloorKb >= 0, true)
        })
    }

    @TestCase
    public func s4P1R3HundredTurnsInOneSessionProduceCompleteEvidence(): Unit {
        withAgentBridgeTempHome("metis-memory-s4-r3", { home: Path =>
            let analysis = agentBridgeRunS4HundredTurnExperiment(home, "r3-shared-small", "", true)
            @Expect(analysis.status, "complete")
            @Expect(analysis.sampledTurns, 23)
            @Expect(analysis.settledFloorKb >= 0, true)
        })
    }

    @TestCase
    public func s4P1R5SyntheticInternalRssAllowsIndependentExternalSampling(): Unit {
        withAgentBridgeTempHome("metis-memory-s4-r5", { home: Path =>
            agentBridgeWaitForS4ExternalSampler()
            let analysis = agentBridgeRunS4HundredTurnExperiment(
                home, "r5-external-small", "", false, externalRssOnly: true
            )
            @Expect(analysis.status, "complete")
            @Expect(analysis.sampledTurns, 23)
            @Expect(analysis.enterRssSlopeKbPerTurn, 0)
            @Expect(analysis.settledFloorKb, 4096)
        })
    }

    @TestCase
    public func s4P1R4TwoActiveTurnsExposeOverlapWithoutChangingCompletionTruth(): Unit {
        withAgentBridgeTempHome("metis-memory-s4-r4", { home: Path =>
            let serial = agentBridgeRunS4ConcurrencyExperiment(home, "r4-serial", false)
            let parallel = agentBridgeRunS4ConcurrencyExperiment(home, "r4-parallel", true)
            @Expect(serial[0].status, "complete")
            @Expect(parallel[0].status, "complete")
            @Expect(serial[0].sampledTurns, 7)
            @Expect(parallel[0].sampledTurns, 7)
            @Expect(serial[1], 1)
            @Expect(parallel[1], 2)
        })
    }

    @TestCase
    public func m3U2N2CoreCancellationDependencyStaysNeutralAndNoneKeepsOrdinaryCalls(): Unit {
        let propagationFiles = [
            "src/gateway/core/agent_bridge.cj",
            "src/gateway/core/gateway_session_executor.cj",
            "src/gateway/core/gateway_session_turn_runner.cj",
            "src/gateway/core/codex_app_server_gateway_runtime.cj"
        ]
        for (relative in propagationFiles) {
            let source = String.fromUtf8(File.readFrom(Path(relative)))
            @Expect(source.contains("GatewayExecutionControl"), true)
            @Expect(source.contains("CronExecutionControl"), false)
            @Expect(source.contains("import metis.gateway.runtime"), false)
        }
        let called = AtomicBool(false)
        let result = debugGatewayRunModelWithoutExecutionControlForTest(
            { =>
                called.store(true)
                "ordinary-none-中文🙂"
            }
        )
        @Expect(called.load(), true)
        @Expect(result, "ordinary-none-中文🙂")
    }

    @TestCase
    public func m3N4CronHeadlessProfileDeniesRecursiveInteractiveAndLifecycleTools(): Unit {
        for (name in ["cron", "gateway", "message", "clarify", "sessions_spawn", "sessions_batch_delegate", "process"]) {
            @Expect(gatewayCronHeadlessToolDenied(name), true)
        }
        for (name in ["web_search", "memory_search", "shellExecute"]) {
            @Expect(gatewayCronHeadlessToolDenied(name), false)
        }
    }

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
    public func gatewayLifecycleToolWrapperPropagatesCapturedCronRuntimeContext(): Unit {
        let activity = AgentBridgeActivityControl()
        let wrapped = agentBridgeRuntimeWrappedProbeForContext(
            GatewayToolRuntimeContext(
                "cron",
                channelName: "cron",
                sessionKey: "cron:writer:manual",
                cronJobId: "ut-p3-01",
                toolExecMode: "allowlist",
                toolExecAllowlist: ["curl", "python3"],
                heartbeatHook: Some<() -> Unit>({ => activity.heartbeat() }),
                cancellationCheckHook: Some<() -> Unit>({ => activity.throwIfCancelled() })
            )
        )

        let response = wrapped.invoke(HashMap<String, JsonValue>())
        let summary = JsonValue.fromStr(response.content).asObject()

        @Expect(response.isError, false)
        @Expect(agentBridgeJsonString(summary, "sourceLabel"), "cron")
        @Expect(agentBridgeJsonString(summary, "channelName"), "cron")
        @Expect(agentBridgeJsonString(summary, "sessionKey"), "cron:writer:manual")
        @Expect(agentBridgeJsonString(summary, "cronJobId"), "ut-p3-01")
        @Expect(agentBridgeJsonString(summary, "toolExecMode"), "allowlist")
        @Expect(summary.get("allowlistSize").getOrThrow().asInt().getValue(), 2)
        @Expect(activity.heartbeats, 2)
        @Expect(activity.checks, 2)
    }

    @TestCase
    public func c1P01CodexAppServerFakeResultEmitsOneActivityHeartbeat(): Unit {
        let activity = AgentBridgeActivityControl()
        setGatewayCodexAppServerRunnerForTest(Some({ _request: GatewayCodexAppServerTurnRequest =>
            GatewayCodexAppServerRuntimeResult(
                "完成中文😀",
                threadId: "thread-c1",
                turnId: "turn-c1",
                completed: true
            )
        }))
        try {
            let result = gatewayRunCodexAppServerTurn(GatewayCodexAppServerTurnRequest(
                "session-c1",
                "/tmp",
                "cron",
                "writer",
                "openai-codex:test",
                "system",
                "input",
                executionControl: Some<GatewayExecutionControl>(activity)
            ))
            @Expect(result.finalText, "完成中文😀")
            @Expect(activity.heartbeats, 1)
            @Expect(activity.checks, 2)
        } finally {
            setGatewayCodexAppServerRunnerForTest(None<(GatewayCodexAppServerTurnRequest) -> GatewayCodexAppServerRuntimeResult>)
        }
    }

    @TestCase
    public func c1N01CancelledCodexAppServerResultCannotReviveActivity(): Unit {
        let activity = AgentBridgeActivityControl()
        setGatewayCodexAppServerRunnerForTest(Some({ _request: GatewayCodexAppServerTurnRequest =>
            activity.cancelled = true
            GatewayCodexAppServerRuntimeResult("late-result", completed: true)
        }))
        var error = ""
        try {
            let _ = gatewayRunCodexAppServerTurn(GatewayCodexAppServerTurnRequest(
                "session-c1-late",
                "/tmp",
                "cron",
                "writer",
                "openai-codex:test",
                "system",
                "input",
                executionControl: Some<GatewayExecutionControl>(activity)
            ))
        } catch (e: Exception) {
            error = e.message
        } finally {
            setGatewayCodexAppServerRunnerForTest(None<(GatewayCodexAppServerTurnRequest) -> GatewayCodexAppServerRuntimeResult>)
        }
        @Expect(error, "test_cancelled")
        @Expect(activity.heartbeats, 0)
    }

    @TestCase
    public func p3P3FormalGatewayCodexTurnsRemainSessionIsolatedOnSharedBroker(): Unit {
        withAgentBridgeTempHome("metis-p3-codex-gateway", { home: Path =>
            writeAgentBridgeParallelCodexAppServerAgentConfig(home)
            let binDir = home.join("bin")
            Directory.create(binDir, recursive: true)
            // Runtime state materialization is not the subject of this test;
            // create independent agent roots before concurrent replies.
            Directory.create(home.join("agents").join("codex-a").join("agent"), recursive: true)
            Directory.create(home.join("agents").join("codex-b").join("agent"), recursive: true)
            Directory.create(home.join("workspaces").join("codex-a"), recursive: true)
            Directory.create(home.join("workspaces").join("codex-b"), recursive: true)
            let fakeCodex = binDir.join("codex")
            File.writeTo(fakeCodex, File.readFrom(Path("scripts").join("gateway-stdio-fake-codex-app-server.mjs")))
            let (chmodCode, _, _) = executeWithOutput("chmod", ["+x", fakeCodex.toString()])
            @Expect(chmodCode, 0)

            let oldPath = getVariable("PATH")
            let oldMode = getVariable("METIS_CODEX_FAKE_MODE")
            let oldLabel = getVariable("METIS_CODEX_FAKE_LABEL")
            let oldThreadLog = getVariable("METIS_CODEX_FAKE_THREAD_LOG")
            let oldIncludeThread = getVariable("METIS_CODEX_FAKE_INCLUDE_THREAD_IN_ANSWER")
            let threadLog = home.join("threads.log")
            let inheritedPath = oldPath ?? ""
            setVariable("PATH", "${binDir.toString()}:${inheritedPath}")
            setVariable("METIS_CODEX_FAKE_MODE", "session")
            setVariable("METIS_CODEX_FAKE_LABEL", "gateway")
            setVariable("METIS_CODEX_FAKE_THREAD_LOG", threadLog.toString())
            setVariable("METIS_CODEX_FAKE_INCLUDE_THREAD_IN_ANSWER", "1")
            setGatewayCodexAppServerRunnerForTest(None<(GatewayCodexAppServerTurnRequest) -> GatewayCodexAppServerRuntimeResult>)
            let baseline = managedStdioBroker().debugSnapshotForTest()
            var firstFuture = None<Future<String>>
            var secondFuture = None<Future<String>>
            try {
                let firstContext = gatewayResolveSessionContext(GatewaySessionRequest(
                    GatewayIngressSource.Channel("telegram"),
                    sessionHint: "session-a",
                    agentId: "codex-a"
                ))
                let secondContext = gatewayResolveSessionContext(GatewaySessionRequest(
                    GatewayIngressSource.Channel("feishu"),
                    sessionHint: "session-b",
                    agentId: "codex-b"
                ))
                let _ = CliModelRuntimeStateManager.ensureAgentRuntimeStateForScope(
                    Path(firstContext.turnContext.agentDir), firstContext.turnContext.agentScope
                )
                let _ = CliModelRuntimeStateManager.ensureAgentRuntimeStateForScope(
                    Path(secondContext.turnContext.agentDir), secondContext.turnContext.agentScope
                )
                let firstStore = GatewaySessionStore(home.join("sessions-a"), enabled: true, agentId: "codex-a")
                let secondStore = GatewaySessionStore(home.join("sessions-b"), enabled: true, agentId: "codex-b")
                let firstBridge = AgentBridge(sessionStore: firstStore)
                let secondBridge = AgentBridge(sessionStore: secondStore)
                firstFuture = Some(spawn {
                    try {
                        firstBridge.reply(
                            firstContext.sessionKey,
                            "input-a 中文🙂",
                            channelName: "telegram",
                            agentId: "codex-a",
                            turnContext: Some(firstContext.turnContext)
                        )
                    } catch (_: Exception) { "p3_first_error" }
                })
                secondFuture = Some(spawn {
                    try {
                        secondBridge.reply(
                            secondContext.sessionKey,
                            "input-b 中文🙂",
                            channelName: "feishu",
                            agentId: "codex-b",
                            turnContext: Some(secondContext.turnContext)
                        )
                    } catch (_: Exception) { "p3_second_error" }
                })
                let first = firstFuture.getOrThrow().get(Duration.second * 10)
                let second = secondFuture.getOrThrow().get(Duration.second * 10)
                let after = managedStdioBroker().debugSnapshotForTest()

                @Expect(first, "answer-codex-a-中文🙂 thread=thread-codex-a")
                @Expect(second, "answer-codex-b-中文🙂 thread=thread-codex-b")
                let firstTranscript = String.fromUtf8(File.readFrom(firstStore.transcriptPath(firstContext.sessionKey)))
                let secondTranscript = String.fromUtf8(File.readFrom(secondStore.transcriptPath(secondContext.sessionKey)))
                let firstCompact = firstTranscript.replace(" ", "").replace("\n", "").replace("\r", "").replace("\t", "")
                let secondCompact = secondTranscript.replace(" ", "").replace("\n", "").replace("\r", "").replace("\t", "")
                let threadLogText = String.fromUtf8(File.readFrom(threadLog))
                @Expect(threadLogText.contains("thread-codex-a"), true)
                @Expect(threadLogText.contains("thread-codex-b"), true)
                @Expect(firstCompact.contains("\"input\":12"), true)
                @Expect(firstCompact.contains("\"output\":7"), true)
                @Expect(secondCompact.contains("\"input\":12"), true)
                @Expect(secondCompact.contains("\"output\":7"), true)
                @Expect(firstTranscript.contains("thread-codex-a"), true)
                @Expect(secondTranscript.contains("thread-codex-b"), true)
                @Expect(firstTranscript.contains("thread-codex-b"), false)
                @Expect(secondTranscript.contains("thread-codex-a"), false)
                @Expect(firstTranscript.contains("answer-codex-b"), false)
                @Expect(secondTranscript.contains("answer-codex-a"), false)
                @Expect(after.readerCount, 1)
                @Expect(after.dispatcherCount, 1)
                @Expect(after.ownerCount, baseline.ownerCount)
            } finally {
                agentBridgeJoinFuture(firstFuture, 10000)
                agentBridgeJoinFuture(secondFuture, 10000)
                setGatewayCodexAppServerRunnerForTest(None<(GatewayCodexAppServerTurnRequest) -> GatewayCodexAppServerRuntimeResult>)
                let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                match (oldPath) {
                    case Some(value) => setVariable("PATH", value)
                    case None => setVariable("PATH", "")
                }
                match (oldMode) {
                    case Some(value) => setVariable("METIS_CODEX_FAKE_MODE", value)
                    case None => setVariable("METIS_CODEX_FAKE_MODE", "")
                }
                match (oldLabel) {
                    case Some(value) => setVariable("METIS_CODEX_FAKE_LABEL", value)
                    case None => setVariable("METIS_CODEX_FAKE_LABEL", "")
                }
                match (oldThreadLog) {
                    case Some(value) => setVariable("METIS_CODEX_FAKE_THREAD_LOG", value)
                    case None => setVariable("METIS_CODEX_FAKE_THREAD_LOG", "")
                }
                match (oldIncludeThread) {
                    case Some(value) => setVariable("METIS_CODEX_FAKE_INCLUDE_THREAD_IN_ANSWER", value)
                    case None => setVariable("METIS_CODEX_FAKE_INCLUDE_THREAD_IN_ANSWER", "")
                }
            }
        })
    }

    @TestCase
    public func c1P01AgentBridgeStreamingLoopHeartbeatsOnlyChangedNonEmptySnapshots(): Unit {
        withAgentBridgeTempHome("metis-c1-stream-activity", { home: Path =>
            let suffix = DateTime.now().toUnixTimeStamp().toMilliseconds().toString()
            let modelName = "metis-test-c1-stream-${suffix}"
            ModelManager.registerChatModel(modelName, { => AgentBridgePhase1FallbackModel() })
            writeAgentBridgePhase1FallbackAgentConfig(home, modelName, [], appServer: false)
            let context = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.DashboardRpc,
                    sessionHint: "main",
                    agentId: "phase1"
                )
            )
            let activity = AgentBridgeActivityControl()
            let streamed = ArrayList<String>()
            setGatewayAgentBridgeStreamingSnapshotsForTest(Some([
                "",
                "",
                "第一段中文😀",
                "第一段中文😀",
                "第一段中文😀第二段",
                "第一段中文😀第二段",
                "第一段中文😀第二段完成"
            ]))
            try {
                let bridge = AgentBridge(sessionStore: GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "phase1"))
                let reply = bridge.reply(
                    context.sessionKey,
                    "stream activity",
                    channelName: "dashboard",
                    agentId: "phase1",
                    streamingEnabled: true,
                    streamChunkHook: Some({ text: String => streamed.add(text) }),
                    turnContext: Some(context.turnContext),
                    executionControl: Some<GatewayExecutionControl>(activity)
                )
                @Expect(reply, "第一段中文😀第二段完成")
                @Expect(activity.heartbeats, 3)
                @Expect(streamed.toArray(), [
                    "第一段中文😀",
                    "第一段中文😀第二段",
                    "第一段中文😀第二段完成"
                ])
            } finally {
                setGatewayAgentBridgeStreamingSnapshotsForTest(None<Array<String>>)
            }
        })
    }

    @TestCase
    public func gatewayLifecycleToolWrapperKeepsConcurrentCronRuntimeContextsIsolated(): Unit {
        let first = agentBridgeRuntimeWrappedProbeForContext(
            GatewayToolRuntimeContext(
                "cron",
                channelName: "cron",
                sessionKey: "cron:writer:a",
                cronJobId: "bt-p3-01-a",
                toolExecMode: "allowlist",
                toolExecAllowlist: ["curl"]
            )
        )
        let second = agentBridgeRuntimeWrappedProbeForContext(
            GatewayToolRuntimeContext(
                "cron",
                channelName: "cron",
                sessionKey: "cron:writer:b",
                cronJobId: "bt-p3-01-b",
                toolExecMode: "deny"
            )
        )

        let firstRun = spawn {
            first.invoke(HashMap<String, JsonValue>()).content
        }
        let secondRun = spawn {
            second.invoke(HashMap<String, JsonValue>()).content
        }

        let firstOut = firstRun.get()
        let secondOut = secondRun.get()
        let firstSummary = JsonValue.fromStr(firstOut).asObject()
        let secondSummary = JsonValue.fromStr(secondOut).asObject()

        @Expect(agentBridgeJsonString(firstSummary, "cronJobId"), "bt-p3-01-a")
        @Expect(agentBridgeJsonString(firstSummary, "toolExecMode"), "allowlist")
        @Expect(firstSummary.get("allowlistSize").getOrThrow().asInt().getValue(), 1)
        @Expect(agentBridgeJsonString(secondSummary, "cronJobId"), "bt-p3-01-b")
        @Expect(agentBridgeJsonString(secondSummary, "toolExecMode"), "deny")
        @Expect(secondSummary.get("allowlistSize").getOrThrow().asInt().getValue(), 0)
    }

    @TestCase
    public func gatewayCronToolSchemaExposesOptionalParamsAsNonRequired(): Unit {
        let schema = gatewayDefaultChatToolJsonValue("cron").getOrThrow()
        @Expect(agentBridgeToolRequiredContains(schema, "action"), true)
        @Expect(agentBridgeToolRequiredContains(schema, "enabled"), false)
        @Expect(agentBridgeToolRequiredContains(schema, "bestEffortDeliver"), false)
        @Expect(agentBridgeToolRequiredContains(schema, "timeoutMs"), false)
        @Expect(agentBridgeToolRequiredContains(schema, "lightContext"), false)
        @Expect(agentBridgeToolRequiredContains(schema, "dueOnly"), false)
    }

    @TestCase
    public func emptyModelResponseFallsBackAndPersistsAssistantReply(): Unit {
        withAgentBridgeTempHome("metis-phase1-empty-response-fallback", { home: Path =>
            resetAgentBridgePhase1FakeModels()
            let suffix = DateTime.now().toUnixTimeStamp().toMilliseconds().toString()
            let primary = "openai-codex:gpt-5.5"
            let fallback = "metis-test-phase1-fallback-${suffix}"
            ModelManager.registerChatModel(fallback, { => AgentBridgePhase1FallbackModel() })
            writeAgentBridgePhase1FallbackAgentConfig(home, primary, [fallback])
            let context = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.DashboardRpc,
                    sessionHint: "main",
                    agentId: "phase1"
                )
            )
            let store = GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "phase1")
            let bridge = AgentBridge(sessionStore: store)
            setGatewayCodexAppServerRunnerForTest(Some({ _request: GatewayCodexAppServerTurnRequest =>
                agentBridgePhase1PrimaryCalls += 1
                throw Exception("  Http response body is empty\nAuthorization: Bearer phase1-secret-token token=abc")
            }))
            try {
                let reply = bridge.reply(
                    context.sessionKey,
                    "trigger empty response fallback",
                    channelName: "feishu",
                    agentId: "phase1",
                    turnContext: Some(context.turnContext)
                )

                @Expect(reply, "phase1 fallback answer")
                @Expect(agentBridgePhase1PrimaryCalls, 1)
                @Expect(agentBridgePhase1FallbackCalls > 0, true)
                let transcript = String.fromUtf8(File.readFrom(store.transcriptPath(context.sessionKey)))
                @Expect(transcript.contains("phase1 fallback answer"), true)
                @Expect(transcript.contains("agent-bridge-phase1-fallback"), true)
            } finally {
                setGatewayCodexAppServerRunnerForTest(None<(GatewayCodexAppServerTurnRequest) -> GatewayCodexAppServerRuntimeResult>)
            }
        })
    }

    @TestCase
    public func emptyModelResponseWithoutFallbackLogsConfigurationStateWithoutSecrets(): Unit {
        withAgentBridgeTempHome("metis-phase1-empty-response-no-fallback", { home: Path =>
            resetAgentBridgePhase1FakeModels()
            let primary = "openai-codex:gpt-5.5"
            writeAgentBridgePhase1FallbackAgentConfig(home, primary, [])
            let context = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.DashboardRpc,
                    sessionHint: "main",
                    agentId: "phase1"
                )
            )
            withAgentBridgeRuntimeLogCapture(home, "no-fallback", { logPath: String =>
                let store = GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "phase1")
                let bridge = AgentBridge(sessionStore: store)
                setGatewayCodexAppServerRunnerForTest(Some({ _request: GatewayCodexAppServerTurnRequest =>
                    agentBridgePhase1PrimaryCalls += 1
                    throw Exception("  Http response body is empty\nAuthorization: Bearer phase1-secret-token token=abc")
                }))
                var thrown = false
                try {
                    _ = bridge.reply(
                        context.sessionKey,
                        "trigger empty response without fallback",
                        channelName: "feishu",
                        agentId: "phase1",
                        turnContext: Some(context.turnContext)
                    )
                } catch (_: Exception) {
                    thrown = true
                } finally {
                    setGatewayCodexAppServerRunnerForTest(None<(GatewayCodexAppServerTurnRequest) -> GatewayCodexAppServerRuntimeResult>)
                }

                @Expect(thrown, true)
                @Expect(agentBridgePhase1PrimaryCalls, 1)
                @Expect(agentBridgePhase1FallbackCalls, 0)
                let log = agentBridgeRuntimeReadCapturedLog(logPath)
                @Expect(log.contains("fallbackConfigured=false") || log.contains("\"fallbackConfigured\":false"), true)
                @Expect(log.contains("fallbackCandidateCount=0") || log.contains("\"fallbackCandidateCount\":0"), true)
                @Expect(log.contains("errorClass=model_empty_response") || log.contains("\"errorClass\":\"model_empty_response\""), true)
                @Expect(log.contains("phase1-secret-token"), false)
                @Expect(log.contains("Authorization"), false)
                @Expect(log.contains("token=abc"), false)
            })
        })
    }

    @TestCase
    public func gatewayDefaultChatRuntimeNowIncludesCanvasTool(): Unit {
        let names = gatewayDefaultChatToolNames()
        @Expect(names.contains("canvas"), true)
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
    public func gatewayDefaultChatRuntimeNowIncludesWebTools(): Unit {
        let names = gatewayDefaultChatToolNames()
        @Expect(names.contains("web_search"), true)
        @Expect(names.contains("web_fetch"), true)
        @Expect(names.contains("web_extract"), true)
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
            updated.tools.deny = ["shellExecute", "process", "gateway", "canvas", "message", "subagents"]
            CliSettingManager.setting.gateway = updated
            let names = gatewayAuthorizedChatToolNames()
            @Expect(names.contains("weather"), true)
            @Expect(names.contains("shellExecute"), false)
            @Expect(names.contains("process"), false)
            @Expect(names.contains("gateway"), false)
            @Expect(names.contains("canvas"), false)
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
            updated.tools.deny = ["shellExecute", "process", "gateway", "canvas", "message", "subagents"]
            CliSettingManager.setting.gateway = updated
            let names = gatewayPolicyFilteredChatToolNames()
            @Expect(names.contains("weather"), true)
            @Expect(names.contains("shellExecute"), false)
            @Expect(names.contains("process"), false)
            @Expect(names.contains("gateway"), false)
            @Expect(names.contains("canvas"), false)
            @Expect(names.contains("message"), false)
            @Expect(names.contains("subagents"), false)
            @Expect(names.contains("sessions_spawn"), true)
        } finally {
            CliSettingManager.setting.gateway = original
        }
    }

    @TestCase
    public func gatewayPolicyFilteredChatToolNamesCanDenyWebTools(): Unit {
        let original = CliSettingManager.setting.gateway
        try {
            var updated = original
            updated.tools.allow = []
            updated.tools.deny = ["web"]
            CliSettingManager.setting.gateway = updated
            let names = gatewayPolicyFilteredChatToolNames()
            @Expect(names.contains("weather"), true)
            @Expect(names.contains("web_search"), false)
            @Expect(names.contains("web_fetch"), false)
            @Expect(names.contains("web_extract"), false)
        } finally {
            CliSettingManager.setting.gateway = original
        }
    }

    @TestCase
    public func gatewayPolicyFilteredSystemPromptOmitsWebAvailabilityWhenWebDenied(): Unit {
        let original = CliSettingManager.setting.gateway
        try {
            var updated = original
            updated.tools.allow = []
            updated.tools.deny = ["web"]
            CliSettingManager.setting.gateway = updated
            let prompt = gatewayPolicyFilteredSystemPrompt(channelName: "telegram", modelName: "test-model")

            @Expect(prompt.contains("Web tools:"), false)
            @Expect(prompt.contains("web_search: Search current web"), false)
            @Expect(prompt.contains("web_fetch: Fetch and extract"), false)
            @Expect(prompt.contains("web_extract: Fetch and extract"), false)
        } finally {
            CliSettingManager.setting.gateway = original
        }
    }

    @TestCase
    public func gatewayPolicyFilteredSystemPromptReportsDefaultDuckDuckGoAndProxyRouteWithoutSecrets(): Unit {
        withAgentBridgeTempHome("metis-web-prompt-summary", { _home: Path =>
            let oldTavilyKey = getVariable("TAVILY_API_KEY")
            setVariable("TAVILY_API_KEY", "")
            let root = JsonObject()
            let tools = JsonObject()
            let web = JsonObject()
            web.put("proxy", JsonString("http://user:secret@127.0.0.1:7897"))
            tools.put("web", web)
            root.put("tools", tools)
            MetisConfigManager.writeRoot(root)
            try {
                let prompt = gatewayPolicyFilteredSystemPrompt(channelName: "telegram", modelName: "test-model")

                @Expect(prompt.contains("Web tools: searchProvider=duckduckgo"), true)
                @Expect(prompt.contains("searchAvailable=true"), true)
                @Expect(prompt.contains("fetchRoute=httpConnectTunnel"), true)
                @Expect(prompt.contains("proxySource=explicit"), true)
                @Expect(prompt.contains("secret"), false)
                @Expect(prompt.contains("user:secret"), false)
                @Expect(prompt.contains("Authorization"), false)
            } finally {
                match (oldTavilyKey) {
                    case Some(value) => setVariable("TAVILY_API_KEY", value)
                    case None => setVariable("TAVILY_API_KEY", "")
                }
            }
        })
    }

    @TestCase
    public func gatewayAuthorizedAndPolicyFilteredChatToolNamesStayAligned(): Unit {
        let original = CliSettingManager.setting.gateway
        try {
            var updated = original
            updated.tools.allow = []
            updated.tools.deny = ["shellExecute", "process", "gateway", "canvas", "message", "subagents"]
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
            updated.tools.deny = ["shellExecute", "process", "gateway", "canvas", "message", "subagents"]
            CliSettingManager.setting.gateway = updated
            let prompt = gatewayPolicyFilteredSystemPrompt()
            @Expect(prompt.contains("shellExecute"), false)
            @Expect(prompt.contains("process(action=poll"), false)
            @Expect(prompt.contains("shellExecute/process"), false)
            @Expect(prompt.contains("canvas(action="), false)
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
    public func gatewayModelOrderUsesTurnModelOverrideOnly(): Unit {
        let context = GatewayTurnContext(
            "writer",
            modelRefOverride: "openai:gpt-4o-mini"
        )
        let models = gatewayDebugModelOrderForTurnContext(context)
        @Expect(models.size, 1)
        @Expect(models[0], "openai:gpt-4o-mini")
    }

    @TestCase
    public func gatewaySystemPromptAppliesThinkingAndLightContextOverride(): Unit {
        withAgentBridgeTempHome("metis-cron-agent-bridge-light-context", { home: Path =>
            writeAgentBridgeAgentConfig(home)
            let writerWorkspace = home.join("workspaces").join("writer")
            Directory.create(writerWorkspace, recursive: true)
            File.writeTo(writerWorkspace.join("SOUL.md"), "# Soul\n\ncron-light-context-should-not-appear\n".toArray())
            let resolved = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.Cron,
                    sessionHint: "main",
                    agentId: "writer"
                )
            )
            let base = resolved.turnContext
            let context = GatewayTurnContext(
                base.agentId,
                workspaceDir: base.workspaceDir,
                agentDir: base.agentDir,
                modelsJsonPath: base.modelsJsonPath,
                authProfilesPath: base.authProfilesPath,
                legacyAuthPath: base.legacyAuthPath,
                sessionsDir: base.sessionsDir,
                sessionKey: base.sessionKey,
                mainSessionKey: base.mainSessionKey,
                matchedBy: base.matchedBy,
                lastRoutePolicy: base.lastRoutePolicy,
                modelRef: base.modelRef,
                channelName: base.channelName,
                accountId: base.accountId,
                peerId: base.peerId,
                threadId: base.threadId,
                senderId: base.senderId,
                operatorScopes: base.operatorScopes,
                chatType: base.chatType,
                route: base.route,
                agentScope: base.agentScope,
                thinkingLevel: "high",
                lightContext: true
            )

            let prompt = gatewayPolicyFilteredSystemPromptForTurnContext(
                context,
                channelName: "cron",
                modelName: "openai:gpt-4o-mini"
            )
            @Expect(prompt.contains("thinking=high"), true)
            @Expect(prompt.contains("cron-light-context-should-not-appear"), false)
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
    public func agentBridgeDoesNotPersistToolProtocolJsonAsAssistantReply(): Unit {
        withAgentBridgeTempHome("metis-fg2-terminal-envelope", { home: Path =>
            writeAgentBridgeCodexAppServerAgentConfig(home)
            let context = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.Channel("feishu"),
                    channelName: "feishu",
                    sessionHint: "main",
                    agentId: "codex",
                    text: "status"
                )
            )
            setGatewayCodexAppServerRunnerForTest(Some({ request: GatewayCodexAppServerTurnRequest =>
                GatewayCodexAppServerRuntimeResult(
                    "{\"name\":\"answer\",\"arguments\":{\"result\":\"当前状态已获取成功🙂\"}}",
                    threadId: "thread-fg2",
                    turnId: "turn-fg2",
                    completed: true,
                    metadata: gatewayCodexAppServerRuntimeMetadata(
                        request.modelName,
                        request.channelName,
                        request.sessionKey,
                        threadId: "thread-fg2",
                        turnId: "turn-fg2",
                        completed: true
                    )
                )
            }))
            try {
                let store = GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "codex")
                let bridge = AgentBridge(sessionStore: store)
                let reply = bridge.reply(
                    context.sessionKey,
                    "status",
                    channelName: "feishu",
                    agentId: "codex",
                    turnContext: Some(context.turnContext)
                )

                @Expect(reply, "当前状态已获取成功🙂")
                let history = bridge.getHistory(context.sessionKey)
                @Expect(history[history.size - 1], "assistant: 当前状态已获取成功🙂")
                let transcript = String.fromUtf8(File.readFrom(store.transcriptPath(context.sessionKey)))
                @Expect(transcript.contains("当前状态已获取成功🙂"), true)
                @Expect(transcript.contains("\"arguments\""), false)
                @Expect(transcript.contains("\"name\""), false)
            } finally {
                setGatewayCodexAppServerRunnerForTest(None<(GatewayCodexAppServerTurnRequest) -> GatewayCodexAppServerRuntimeResult>)
            }
        })
    }

    @TestCase
    public func agentBridgeBlocksNonTerminalToolProtocolJsonBeforeSessionHistory(): Unit {
        withAgentBridgeTempHome("metis-fg2-nonterminal-tool-json", { home: Path =>
            writeAgentBridgeCodexAppServerAgentConfig(home)
            let context = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.Channel("telegram"),
                    channelName: "telegram",
                    sessionHint: "main",
                    agentId: "codex",
                    text: "status"
                )
            )
            setGatewayCodexAppServerRunnerForTest(Some({ request: GatewayCodexAppServerTurnRequest =>
                GatewayCodexAppServerRuntimeResult(
                    "{\"name\":\"session_status\",\"arguments\":{}}",
                    threadId: "thread-fg2-neg",
                    turnId: "turn-fg2-neg",
                    completed: true,
                    metadata: gatewayCodexAppServerRuntimeMetadata(
                        request.modelName,
                        request.channelName,
                        request.sessionKey,
                        threadId: "thread-fg2-neg",
                        turnId: "turn-fg2-neg",
                        completed: true
                    )
                )
            }))
            try {
                let store = GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "codex")
                let bridge = AgentBridge(sessionStore: store)
                let reply = bridge.reply(
                    context.sessionKey,
                    "status",
                    channelName: "telegram",
                    agentId: "codex",
                    turnContext: Some(context.turnContext)
                )

                @Expect(reply.contains("工具调用协议"), true)
                @Expect(reply.contains("session_status"), false)
                let history = bridge.getHistory(context.sessionKey)
                @Expect(history[history.size - 1].contains("工具调用协议"), true)
                @Expect(history[history.size - 1].contains("session_status"), false)
                let transcript = String.fromUtf8(File.readFrom(store.transcriptPath(context.sessionKey)))
                @Expect(transcript.contains("工具调用协议"), true)
                @Expect(transcript.contains("session_status"), false)
                @Expect(transcript.contains("\"arguments\""), false)
            } finally {
                setGatewayCodexAppServerRunnerForTest(None<(GatewayCodexAppServerTurnRequest) -> GatewayCodexAppServerRuntimeResult>)
            }
        })
    }

    @TestCase
    public func c3N01AgentBridgeReplyGuardUsesOnlyTurnAuthorizedToolNames(): Unit {
        withAgentBridgeTempHome("metis-c3-turn-authorized-tool-names", { home: Path =>
            writeAgentBridgeCodexAppServerAgentConfig(home)
            let originalGateway = CliSettingManager.setting.gateway
            var updatedGateway = originalGateway
            updatedGateway.tools.allow = []
            updatedGateway.tools.deny = ["web"]
            CliSettingManager.setting.gateway = updatedGateway
            let context = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.Channel("telegram"),
                    channelName: "telegram",
                    sessionHint: "main",
                    agentId: "codex",
                    text: "status"
                )
            )
            setGatewayCodexAppServerRunnerForTest(Some({ request: GatewayCodexAppServerTurnRequest =>
                GatewayCodexAppServerRuntimeResult(
                    "[\"web_fetch\"]",
                    threadId: "thread-c3-denied",
                    turnId: "turn-c3-denied",
                    completed: true,
                    metadata: gatewayCodexAppServerRuntimeMetadata(
                        request.modelName,
                        request.channelName,
                        request.sessionKey,
                        threadId: "thread-c3-denied",
                        turnId: "turn-c3-denied",
                        completed: true
                    )
                )
            }))
            try {
                let store = GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "codex")
                let bridge = AgentBridge(sessionStore: store)
                let reply = bridge.reply(
                    context.sessionKey,
                    "status",
                    channelName: "telegram",
                    agentId: "codex",
                    turnContext: Some(context.turnContext)
                )

                @Expect(reply, "[\"web_fetch\"]")
                let history = bridge.getHistory(context.sessionKey)
                @Expect(history[history.size - 1], "assistant: [\"web_fetch\"]")
            } finally {
                CliSettingManager.setting.gateway = originalGateway
                setGatewayCodexAppServerRunnerForTest(None<(GatewayCodexAppServerTurnRequest) -> GatewayCodexAppServerRuntimeResult>)
            }
        })
    }

    @TestCase
    public func c3U01AgentBridgeBlocksAuthorizedToolNameArrayBeforeSessionHistory(): Unit {
        withAgentBridgeTempHome("metis-c3-authorized-tool-name-array", { home: Path =>
            writeAgentBridgeCodexAppServerAgentConfig(home)
            let context = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.Channel("telegram"),
                    channelName: "telegram",
                    sessionHint: "main",
                    agentId: "codex",
                    text: "status"
                )
            )
            setGatewayCodexAppServerRunnerForTest(Some({ request: GatewayCodexAppServerTurnRequest =>
                GatewayCodexAppServerRuntimeResult(
                    "[\"web_fetch\"]",
                    threadId: "thread-c3-allowed",
                    turnId: "turn-c3-allowed",
                    completed: true,
                    metadata: gatewayCodexAppServerRuntimeMetadata(
                        request.modelName,
                        request.channelName,
                        request.sessionKey,
                        threadId: "thread-c3-allowed",
                        turnId: "turn-c3-allowed",
                        completed: true
                    )
                )
            }))
            try {
                let store = GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "codex")
                let bridge = AgentBridge(sessionStore: store)
                let reply = bridge.reply(
                    context.sessionKey,
                    "status",
                    channelName: "telegram",
                    agentId: "codex",
                    turnContext: Some(context.turnContext)
                )

                @Expect(reply.contains("工具调用协议"), true)
                @Expect(reply.contains("web_fetch"), false)
                let history = bridge.getHistory(context.sessionKey)
                @Expect(history[history.size - 1].contains("工具调用协议"), true)
                @Expect(history[history.size - 1].contains("web_fetch"), false)
                let transcript = String.fromUtf8(File.readFrom(store.transcriptPath(context.sessionKey)))
                @Expect(transcript.contains("工具调用协议"), true)
                @Expect(transcript.contains("web_fetch"), false)
            } finally {
                setGatewayCodexAppServerRunnerForTest(None<(GatewayCodexAppServerTurnRequest) -> GatewayCodexAppServerRuntimeResult>)
            }
        })
    }

    @TestCase
    public func agentBridgeBlocksTerminalEnvelopeContainingToolMarkerBeforeSessionHistory(): Unit {
        withAgentBridgeTempHome("metis-m2-terminal-marker", { home: Path =>
            writeAgentBridgeCodexAppServerAgentConfig(home)
            let context = gatewayResolveSessionContext(
                GatewaySessionRequest(
                    GatewayIngressSource.Channel("telegram"),
                    channelName: "telegram",
                    sessionHint: "main",
                    agentId: "codex",
                    text: "status"
                )
            )
            setGatewayCodexAppServerRunnerForTest(Some({ request: GatewayCodexAppServerTurnRequest =>
                GatewayCodexAppServerRuntimeResult(
                    "{\"name\":\"_answer_\",\"arguments\":{\"result\":\"\\\"functions._answer_\\\"\"}}",
                    threadId: "thread-m2-marker",
                    turnId: "turn-m2-marker",
                    completed: true,
                    metadata: gatewayCodexAppServerRuntimeMetadata(
                        request.modelName,
                        request.channelName,
                        request.sessionKey,
                        threadId: "thread-m2-marker",
                        turnId: "turn-m2-marker",
                        completed: true
                    )
                )
            }))
            try {
                let store = GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "codex")
                let bridge = AgentBridge(sessionStore: store)
                let reply = bridge.reply(
                    context.sessionKey,
                    "status",
                    channelName: "telegram",
                    agentId: "codex",
                    turnContext: Some(context.turnContext)
                )

                @Expect(reply.contains("工具调用协议"), true)
                @Expect(reply.contains("functions._answer_"), false)
                @Expect(reply.contains("\"arguments\""), false)
                let history = bridge.getHistory(context.sessionKey)
                @Expect(history[history.size - 1].contains("工具调用协议"), true)
                @Expect(history[history.size - 1].contains("functions._answer_"), false)
                @Expect(history[history.size - 1].contains("\"_answer_\""), false)
                let transcript = String.fromUtf8(File.readFrom(store.transcriptPath(context.sessionKey)))
                @Expect(transcript.contains("工具调用协议"), true)
                @Expect(transcript.contains("functions._answer_"), false)
                @Expect(transcript.contains("\"_answer_\""), false)
                @Expect(transcript.contains("\"arguments\""), false)
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
                capture.acceptHeaders.add(request.headers.get("Accept").getOrThrow())
                CodexResponsesHttpResult(200, streamEvents: [agentBridgeCodexResponsesCompletedEvent("codex responses ok")])
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
                for (accept in capture.acceptHeaders) {
                    @Expect(accept, "text/event-stream")
                }
                for (body in capture.bodies) {
                    @Expect(agentBridgeJsonString(body, "model"), "gpt-5.5")
                    @Expect(agentBridgeJsonBool(body, "store"), false)
                    @Expect(agentBridgeJsonBool(body, "stream"), true)
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
