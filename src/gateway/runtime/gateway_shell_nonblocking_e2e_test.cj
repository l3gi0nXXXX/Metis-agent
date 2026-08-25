package metis.gateway.runtime

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext}
import metis.core.config.{CliConfig, CliModelRuntimeStateManager, CliSettingManager, GatewayUserSettings,
    MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.config.buildGatewayConfigFromUserSettings
import metis.gateway.core.{AgentBridge, ChannelAdapter, GatewayRouter, GatewayService, GatewaySessionStore,
    setGatewayAgentBridgeReplyRunnerForTest}
import metis.gateway.model.{ChannelPolicyConfig, ChannelType, ChatType, InboundMessage, OutboundMessage, SendResult}
import metis.gateway.openclaw_runtime.{OpenClawCompatHostClient, OpenClawCompatHostLaunchSpec,
    OpenClawCompatHostStartResult, OpenClawCompatHostTransport, OpenClawCompatStdioProcessRunner}
import metis.gateway.session.{GatewayIngressSource, GatewaySessionRequest, gatewayResolveSessionContext}
import metis.gateway.tools.{GatewayManagedSessionsToolset, debugGatewayShellExecuteForTest}
import metis.process.{managedStdioBroker, managedStdioResolveBrokerScriptPath, resetManagedStdioBrokerForTest}
import std.collection.{ArrayList, HashMap}
import std.core.Duration
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.net.*
import std.process.executeWithOutput
import std.sync.{AtomicBool, Mutex}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}
import stdx.net.http.*

private func withGatewayShellE2eHome<T>(body: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = "/tmp/metis-gateway-shell-e2e-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
        let oldHome = getVariable("METIS_HOME")
        try {
            remove(Path(home), recursive: true)
        } catch (_: Exception) {
            ()
        }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home)
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        try {
            body()
        } finally {
            setGatewayAgentBridgeReplyRunnerForTest(
                None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>)
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            try {
                remove(Path(home), recursive: true)
            } catch (_: Exception) {
                ()
            }
        }
    }
}

private class GatewayShellE2eAdapter <: ChannelAdapter {
    private let adapterName: String
    private let lock = Mutex()
    private let inbound = ArrayList<InboundMessage>()
    private let sent = ArrayList<String>()
    private var pulls: Int64 = 0

    init(adapterName: String) {
        this.adapterName = adapterName
    }

    public prop name: String {
        get() {
            this.adapterName
        }
    }
    public func start(): Unit {}
    public func stop(): Unit {}

    public func pullInbound(): Array<InboundMessage> {
        synchronized(this.lock) {
            this.pulls += 1
            let messages = this.inbound.toArray()
            this.inbound.clear()
            messages
        }
    }

    public func enqueue(index: Int64): Unit {
        let channel = if (this.adapterName == "telegram") {
            ChannelType.Telegram
        } else {
            ChannelType.Feishu
        }
        synchronized(this.lock) {
            this.inbound.add(
                InboundMessage(
                    channel,
                    "${this.adapterName}-${index}",
                    "${this.adapterName}-peer",
                    "${this.adapterName}-sender",
                    ChatType.Direct,
                    "${this.adapterName}-shell-${index}-中文🙂",
                    true,
                    DateTime.now()
                )
            )
        }
    }

    public func send(message: OutboundMessage): SendResult {
        synchronized(this.lock) { this.sent.add(message.text) }
        SendResult.Success
    }

    public func sendWithMessageId(message: OutboundMessage): String {
        synchronized(this.lock) {
            this.sent.add(message.text)
            "${this.adapterName}-sent-${this.sent.size}"
        }
    }

    public func countExact(expected: String): Int64 {
        synchronized(this.lock) {
            var count: Int64 = 0
            for (text in this.sent) {
                if (text == expected) {
                    count += 1
                }
            }
            count
        }
    }

    public func pullCount(): Int64 {
        synchronized(this.lock) { this.pulls }
    }
}

private func gatewayShellE2eService(feishu: GatewayShellE2eAdapter, telegram: GatewayShellE2eAdapter): GatewayService {
    let policies = HashMap<String, ChannelPolicyConfig>()
    policies["feishu"] = ChannelPolicyConfig(enableDirect: true, enableGroup: true, requireMentionInGroup: false)
    policies["telegram"] = ChannelPolicyConfig(enableDirect: true, enableGroup: true, requireMentionInGroup: false)
    let service = GatewayService(GatewayRouter(policies))
    service.registerAdapter(feishu, channelId: "feishu", accountId: "shell-e2e-feishu")
    service.registerAdapter(telegram, channelId: "telegram", accountId: "shell-e2e-telegram")
    service
}

private func gatewayShellE2eAwait(predicate: () -> Bool, timeoutMs!: Int64 = 3000): Bool {
    let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
    while (!predicate() && DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
        sleep(Duration.millisecond * 2)
    }
    predicate()
}

private class GatewayShellHealthResult {
    let status: Int64
    let body: String

    init(status: Int64, body: String) {
        this.status = status
        this.body = body
    }
}

private func gatewayShellReadHealthBody(response: HttpResponse): String {
    let bytes = ArrayList<Byte>()
    let buffer = Array<Byte>(1024, repeat: 0)
    while (bytes.size <= 64 * 1024) {
        let count = response.body.read(buffer)
        if (count <= 0) {
            break
        }
        bytes.add(all: buffer[..count])
    }
    if (bytes.size > 64 * 1024) {
        return "response_too_large"
    }
    try {
        String.fromUtf8(bytes.toArray())
    } catch (_: Exception) {
        "invalid_response_encoding"
    }
}

private func gatewayShellFetchHealthz(url: String): GatewayShellHealthResult {
    let builder = ClientBuilder()
    builder.readTimeout(Duration.millisecond * 500)
    let client = builder.build()
    try {
        let response = client.send(HttpRequestBuilder().url(url).get().build())
        GatewayShellHealthResult(Int64(response.status), gatewayShellReadHealthBody(response))
    } catch (_: Exception) {
        GatewayShellHealthResult(0, "")
    } finally {
        client.close()
    }
}

private func gatewayShellHealthMatchesPort(url: String, expectedPort: Int64): Bool {
    let response = gatewayShellFetchHealthz(url)
    if (response.status != 200) { return false }
    try {
        let health = JsonValue.fromStr(response.body).asObject()
        health.get("ok").getOrThrow().asBool().getValue() &&
            health.get("status").getOrThrow().asString().getValue() == "live" &&
            health.get("gateway").getOrThrow().asObject().get("port").getOrThrow().asInt().getValue() == expectedPort
    } catch (_: Exception) {
        false
    }
}

private func gatewayShellTemporaryHealthPort(): Int64 {
    for (_ in 0..8) {
        try (socket = TcpServerSocket(bindAt: 0u16)) {
            socket.bind()
            let port = (socket.localAddress as IPSocketAddress)?.port ?? 0u16
            let value = Int64(port)
            if (value > 0 && value != 18788 && value != 60271) {
                return value
            }
        }
    }
    0
}

private func gatewayShellReadyCount(path: Path): Int64 {
    if (!exists(path)) { return 0 }
    try {
        var count: Int64 = 0
        for (line in String.fromUtf8(File.readFrom(path)).split("\n")) {
            if (!line.trimAscii().isEmpty()) { count += 1 }
        }
        count
    } catch (_: Exception) {
        0
    }
}

private func gatewayShellFormalTimedLoad(command: String): Bool {
    let output = gatewayWithToolRuntimeContext(
        GatewayToolRuntimeContext(
            "cron",
            cronJobId: "p3-p5-shell-load",
            toolExecMode: "yolo",
            remainingMsHook: Some({=> 30000})
        ),
        {=> debugGatewayShellExecuteForTest(CliConfig.cwd.toString(), command, None<String>, Some(false))}
    )
    output.contains("Command executed successfully") && output.contains("released-中文🙂")
}

private func gatewayShellJoinLoads(loads: ArrayList<Future<Bool>>, timeoutMs: Int64): Bool {
    var allSettled = true
    for (load in loads) {
        try {
            if (!load.get(Duration.millisecond * timeoutMs)) {
                allSettled = false
            }
        } catch (_: Exception) {
            allSettled = false
        }
    }
    allSettled
}

private func gatewayP3IntegrationJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) => try { value.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func gatewayP3IntegrationWaitManaged(
    toolset: GatewayManagedSessionsToolset,
    runId: String,
    timeoutMs!: Int64 = 5000
): JsonObject {
    let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
    var last = JsonObject()
    while (DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
        last = JsonValue.fromStr(toolset.subagentsForTest(Some("status"), Some(runId), None<String>, None<Int64>)).asObject()
        let run = match (last.get("run")) {
            case Some(value) => try { value.asObject() } catch (_: Exception) { JsonObject() }
            case None => JsonObject()
        }
        let status = gatewayP3IntegrationJsonString(run, "status")
        if (status == "succeeded" || status == "failed" || status == "timed_out" || status == "cancelled") {
            return run
        }
        sleep(Duration.millisecond * 10)
    }
    JsonObject()
}

private func gatewayP3IntegrationWriteCodexConfig(home: Path): Unit {
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

private func gatewayP3IntegrationJoin<T>(future: Option<Future<T>>, timeoutMs: Int64): Bool {
    match (future) {
        case Some(value) => try { let _ = value.get(Duration.millisecond * timeoutMs); true } catch (_: Exception) { false }
        case None => true
    }
}

private func gatewayP3IntegrationSettleManaged(toolset: GatewayManagedSessionsToolset, runId: String): Bool {
    if (runId.isEmpty()) { return true }
    var run = gatewayP3IntegrationWaitManaged(toolset, runId, timeoutMs: 1000)
    var status = gatewayP3IntegrationJsonString(run, "status")
    if (status != "succeeded" && status != "failed" && status != "timed_out" && status != "cancelled") {
        let _ = toolset.subagentsForTest(Some("kill"), Some(runId), None<String>, None<Int64>)
        run = gatewayP3IntegrationWaitManaged(toolset, runId, timeoutMs: 5000)
        status = gatewayP3IntegrationJsonString(run, "status")
    }
    status == "succeeded" || status == "failed" || status == "timed_out" || status == "cancelled"
}

@Test
public class GatewayShellNonblockingE2eTest {
    @TestCase
    public func p4P1BlockedFeishuTurnKeepsTelegramPollAndRealHealthzResponsive(): Unit {
        withGatewayShellE2eHome({ =>
            let feishu = GatewayShellE2eAdapter("feishu")
            let telegram = GatewayShellE2eAdapter("telegram")
            let gateway = gatewayShellE2eService(feishu, telegram)
            let feishuStarted = AtomicBool(false)
            let releaseFeishu = AtomicBool(false)
            var healthUrl = ""
            var healthPort: Int64 = 0
            setGatewayAgentBridgeReplyRunnerForTest(Some({
                _sessionKey, prompt, channel, _agentId, _streaming, _hook =>
                if (channel == "feishu") {
                    feishuStarted.store(true)
                    while (!releaseFeishu.load()) { sleep(Duration.millisecond) }
                }
                "${channel}-reply:${prompt}"
            }))
            GatewayHttpSurface.stopIfRunning()
            gateway.start()
            try {
                for (_ in 0..5) {
                    let candidate = gatewayShellTemporaryHealthPort()
                    if (candidate <= 0) { continue }
                    var user = GatewayUserSettings()
                    user.port = candidate
                    user.bind = "loopback"
                    user.customBindHost = ""
                    user.auth.mode = "none"
                    user.http.endpoints.chatCompletions.enabled = true
                    GatewayHttpSurface.startIfNeeded(buildGatewayConfigFromUserSettings(user))
                    let candidateUrl = "http://127.0.0.1:${candidate}/healthz"
                    if (gatewayShellE2eAwait({ => gatewayShellHealthMatchesPort(candidateUrl, candidate) })) {
                        healthPort = candidate
                        healthUrl = candidateUrl
                        break
                    }
                    GatewayHttpSurface.stopIfRunning()
                }
                @Expect(healthPort > 0, true)
                if (healthPort <= 0) { throw Exception("P4 isolated health surface unavailable") }

                feishu.enqueue(0)
                gateway.processOnce()
                @Expect(gatewayShellE2eAwait({ => feishuStarted.load() }), true)

                for (index in 0..4) {
                    let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
                    telegram.enqueue(index)
                    gateway.processOnce()
                    let reply = "telegram-reply:telegram-shell-${index}-中文🙂"
                    @Expect(gatewayShellE2eAwait({ => telegram.countExact(reply) == 1 }, timeoutMs: 500), true)
                    @Expect(gatewayShellHealthMatchesPort(healthUrl, healthPort), true)
                    @Expect(DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt < 500, true)
                    @Expect(feishu.countExact("feishu-reply:feishu-shell-0-中文🙂"), 0)
                }
                @Expect(feishu.pullCount() >= 5, true)
                @Expect(telegram.pullCount() >= 5, true)

                releaseFeishu.store(true)
                @Expect(gateway.awaitInboundIdleForTest(timeoutMs: 2000), true)
                @Expect(feishu.countExact("feishu-reply:feishu-shell-0-中文🙂"), 1)
                for (index in 0..4) {
                    @Expect(telegram.countExact("telegram-reply:telegram-shell-${index}-中文🙂"), 1)
                }
            } finally {
                releaseFeishu.store(true)
                GatewayHttpSurface.stopIfRunning()
                gateway.stop()
            }
        })
    }

    @TestCase
    public func p3IP2P3FormalChildrenOverlapDoubleImPollAndRealHealthz(): Unit {
        withGatewayShellE2eHome({ =>
            let home = CliConfig.dotDir
            gatewayP3IntegrationWriteCodexConfig(home)
            let binDir = home.join("bin")
            let agentDir = home.join("agents").join("codex").join("agent")
            let workspace = home.join("workspaces").join("codex")
            Directory.create(binDir, recursive: true)
            Directory.create(agentDir, recursive: true)
            Directory.create(workspace, recursive: true)
            let fakeCodex = binDir.join("codex")
            File.writeTo(fakeCodex, File.readFrom(Path("scripts").join("gateway-stdio-fake-codex-app-server.mjs")))
            let (chmodCode, _, _) = executeWithOutput("chmod", ["+x", fakeCodex.toString()])
            @Expect(chmodCode, 0)
            let delayedManaged = home.join("p3-i-delayed-managed.mjs")
            File.writeTo(delayedManaged, (
                "setTimeout(() => { process.stdout.write('managed-p3-i-中文🙂'); process.exit(0); }, 350);\n"
            ).toArray())
            let delayedCompat = home.join("p3-i-delayed-compat.mjs")
            File.writeTo(delayedCompat, (
                "import{createInterface}from'node:readline';" +
                "createInterface({input:process.stdin}).on('line',line=>{" +
                "const f=JSON.parse(line);setTimeout(()=>process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:f.id,result:{ok:true,text:'compat-p3-i-中文🙂'}})+'\\n'),350)});\n"
            ).toArray())

            let oldPath = getVariable("PATH")
            let oldMode = getVariable("METIS_CODEX_FAKE_MODE")
            let oldDelay = getVariable("METIS_CODEX_FAKE_DELAY_MS")
            let oldThread = getVariable("METIS_CODEX_FAKE_INCLUDE_THREAD_IN_ANSWER")
            let inheritedPath = oldPath ?? ""
            setVariable("PATH", "${binDir.toString()}:${inheritedPath}")
            setVariable("METIS_CODEX_FAKE_MODE", "delayed-response")
            setVariable("METIS_CODEX_FAKE_DELAY_MS", "350")
            setVariable("METIS_CODEX_FAKE_INCLUDE_THREAD_IN_ANSWER", "1")

            let feishu = GatewayShellE2eAdapter("feishu")
            let telegram = GatewayShellE2eAdapter("telegram")
            let gateway = gatewayShellE2eService(feishu, telegram)
            let toolset = GatewayManagedSessionsToolset()
            toolset.debugSetManagedSubagentCommandSpecForTest(
                Some<(String, String, String, String, String, String) -> (String, Array<String>, Path)>(
                    { _session, _agent, _task, cwd, _agentDir, _model =>
                        ("node", [delayedManaged.toString()], Path(cwd))
                    }
                )
            )
            var codexFuture = None<Future<String>>
            var compatFuture = None<Future<String>>
            var compatTransport = None<OpenClawCompatHostTransport>
            var healthUrl = ""
            var healthPort: Int64 = 0
            var acpRunId = ""
            var subagentRunId = ""
            GatewayHttpSurface.stopIfRunning()
            gateway.start()
            try {
                for (_ in 0..5) {
                    let candidate = gatewayShellTemporaryHealthPort()
                    if (candidate <= 0) { continue }
                    var user = GatewayUserSettings()
                    user.port = candidate
                    user.bind = "loopback"
                    user.customBindHost = ""
                    user.auth.mode = "none"
                    user.http.endpoints.chatCompletions.enabled = true
                    GatewayHttpSurface.startIfNeeded(buildGatewayConfigFromUserSettings(user))
                    let candidateUrl = "http://127.0.0.1:${candidate}/healthz"
                    if (gatewayShellE2eAwait({ => gatewayShellHealthMatchesPort(candidateUrl, candidate) })) {
                        healthPort = candidate
                        healthUrl = candidateUrl
                        break
                    }
                    GatewayHttpSurface.stopIfRunning()
                }
                @Expect(healthPort > 0, true)
                if (healthPort <= 0) { throw Exception("P3-I isolated health surface unavailable") }

                let context = gatewayResolveSessionContext(GatewaySessionRequest(
                    GatewayIngressSource.Channel("telegram"), sessionHint: "p3-i-codex", agentId: "codex"
                ))
                let _ = CliModelRuntimeStateManager.ensureAgentRuntimeStateForScope(
                    Path(context.turnContext.agentDir), context.turnContext.agentScope
                )
                let bridge = AgentBridge(sessionStore: GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "codex"))
                codexFuture = Some(spawn {
                    bridge.reply(
                        context.sessionKey,
                        "p3-i formal codex 中文🙂",
                        channelName: "telegram",
                        agentId: "codex",
                        turnContext: Some(context.turnContext)
                    )
                })
                @Expect(gatewayShellE2eAwait({ => managedStdioBroker().snapshot().ownerCount >= 1 }), true)

                // The formal AgentBridge call has already passed the test seam and owns a broker child.
                setGatewayAgentBridgeReplyRunnerForTest(Some({
                    _sessionKey, prompt, channel, _agentId, _streaming, _hook => "${channel}-reply:${prompt}"
                }))

                let compatRunner = OpenClawCompatStdioProcessRunner()
                match (compatRunner.start(OpenClawCompatHostLaunchSpec("node", delayedCompat.toString(), [], 1000))) {
                    case OpenClawCompatHostStartResult.Started(transport) =>
                        compatTransport = Some<OpenClawCompatHostTransport>(transport)
                        let client = OpenClawCompatHostClient(transport, defaultTimeoutMs: 1000)
                        compatFuture = Some(spawn {
                            let result = client.request("test.timeout", timeoutMs: 500)
                            if (result.ok) { gatewayP3IntegrationJsonString(result.result, "text") } else { result.status }
                        })
                    case OpenClawCompatHostStartResult.Failed(reason) => throw Exception("compat start failed: ${reason}")
                }

                acpRunId = gatewayWithToolRuntimeContext(
                    GatewayToolRuntimeContext("telegram", sessionKey: "telegram:p3-i-acp")) {
                    let accepted = JsonValue.fromStr(toolset.sessionsSpawnForCommand(
                        "p3-i-acp", Some("p3-i-acp"), Some("acp"),
                        Some("cmd:node ${delayedManaged.toString()}"), None<String>, None<String>, None<String>,
                        Some(CliConfig.cwd.toString()), Some(5), None<Int64>, None<String>, None<String>, None<Bool>,
                        None<String>, None<String>, None<String>, None<String>
                    )).asObject()
                    @Expect(gatewayP3IntegrationJsonString(accepted, "status"), "accepted")
                    gatewayP3IntegrationJsonString(accepted, "runId")
                }
                subagentRunId = gatewayWithToolRuntimeContext(
                    GatewayToolRuntimeContext("feishu", sessionKey: "feishu:p3-i-subagent")) {
                    let accepted = JsonValue.fromStr(toolset.sessionsSpawnForCommand(
                        "p3-i-subagent", Some("p3-i-subagent"), Some("subagent"), Some("explorer"),
                        None<String>, None<String>, None<String>, Some(CliConfig.cwd.toString()), Some(5), None<Int64>,
                        Some("fresh"), Some("shared"), Some(false), None<String>, Some("keep"), None<String>, None<String>
                    )).asObject()
                    @Expect(gatewayP3IntegrationJsonString(accepted, "status"), "accepted")
                    gatewayP3IntegrationJsonString(accepted, "runId")
                }

                @Expect(gatewayShellE2eAwait({ => managedStdioBroker().snapshot().ownerCount >= 4 }), true)

                for (index in 0..4) {
                    feishu.enqueue(index)
                    telegram.enqueue(index)
                    gateway.processOnceAndAwaitForTest()
                    let response = gatewayShellFetchHealthz(healthUrl)
                    @Expect(response.status, 200)
                    @Expect(gatewayShellHealthMatchesPort(healthUrl, healthPort), true)
                    let feishuReply = "feishu-reply:feishu-shell-${index}-中文🙂"
                    let telegramReply = "telegram-reply:telegram-shell-${index}-中文🙂"
                    @Expect(feishu.countExact(feishuReply), 1)
                    @Expect(telegram.countExact(telegramReply), 1)
                    @Expect(feishu.countExact(telegramReply), 0)
                    @Expect(telegram.countExact(feishuReply), 0)
                    sleep(Duration.millisecond * 30)
                }

                @Expect(compatFuture.getOrThrow().get(Duration.second * 3), "compat-p3-i-中文🙂")
                @Expect(
                    codexFuture.getOrThrow().get(Duration.second * 5),
                    "answer-codex-中文🙂 thread=thread-codex"
                )
                let acpRun = gatewayP3IntegrationWaitManaged(toolset, acpRunId)
                @Expect(gatewayP3IntegrationJsonString(acpRun, "status"), "succeeded")
                @Expect(gatewayP3IntegrationJsonString(acpRun, "resultSummary"), "managed-p3-i-中文🙂")
                let subagentRun = gatewayP3IntegrationWaitManaged(toolset, subagentRunId)
                @Expect(
                    gatewayP3IntegrationJsonString(subagentRun, "status"),
                    "succeeded"
                )
                @Expect(gatewayP3IntegrationJsonString(subagentRun, "resultSummary"), "managed-p3-i-中文🙂")
                for (index in 0..4) {
                    let feishuReply = "feishu-reply:feishu-shell-${index}-中文🙂"
                    let telegramReply = "telegram-reply:telegram-shell-${index}-中文🙂"
                    @Expect(feishu.countExact(feishuReply), 1)
                    @Expect(telegram.countExact(telegramReply), 1)
                    @Expect(feishu.countExact(telegramReply), 0)
                    @Expect(telegram.countExact(feishuReply), 0)
                }
                @Expect(managedStdioBroker().snapshot().readerCount, 1)
                match (compatTransport) {
                    case Some(transport) => transport.close()
                    case None => ()
                }
                @Expect(gatewayShellE2eAwait({ => managedStdioBroker().snapshot().ownerCount == 0 }), true)
            } finally {
                setGatewayAgentBridgeReplyRunnerForTest(
                    None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>)
                match (compatTransport) {
                    case Some(transport) => try { transport.close() } catch (_: Exception) { () }
                    case None => ()
                }
                let codexSettled = gatewayP3IntegrationJoin(codexFuture, 5000)
                let compatSettled = gatewayP3IntegrationJoin(compatFuture, 3000)
                let acpSettled = gatewayP3IntegrationSettleManaged(toolset, acpRunId)
                let subagentSettled = gatewayP3IntegrationSettleManaged(toolset, subagentRunId)
                toolset.debugSetManagedSubagentCommandSpecForTest(
                    None<(String, String, String, String, String, String) -> (String, Array<String>, Path)>)
                GatewayHttpSurface.stopIfRunning()
                try { let _ = gateway.stop() } catch (_: Exception) { () }
                let ownersCleared = gatewayShellE2eAwait({ => managedStdioBroker().snapshot().ownerCount == 0 })
                let reset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                match (oldPath) { case Some(value) => setVariable("PATH", value) case None => setVariable("PATH", "") }
                match (oldMode) { case Some(value) => setVariable("METIS_CODEX_FAKE_MODE", value) case None => setVariable("METIS_CODEX_FAKE_MODE", "") }
                match (oldDelay) { case Some(value) => setVariable("METIS_CODEX_FAKE_DELAY_MS", value) case None => setVariable("METIS_CODEX_FAKE_DELAY_MS", "") }
                match (oldThread) { case Some(value) => setVariable("METIS_CODEX_FAKE_INCLUDE_THREAD_IN_ANSWER", value) case None => setVariable("METIS_CODEX_FAKE_INCLUDE_THREAD_IN_ANSWER", "") }
                @Expect(codexSettled, true)
                @Expect(compatSettled, true)
                @Expect(acpSettled, true)
                @Expect(subagentSettled, true)
                @Expect(ownersCleared, true)
                @Expect(reset.ok, true)
            }
        })
    }

    @TestCase
    public func p3P5FormalGatewayShellLoadKeepsImPollAndRealHealthzResponsive(): Unit {
        withGatewayShellE2eHome(
            {
                =>
                setGatewayAgentBridgeReplyRunnerForTest(
                    Some({
                        _sessionKey, prompt, channel, _agentId, _streaming, _hook => "${channel}-reply:${prompt}"
                    }))
                let feishu = GatewayShellE2eAdapter("feishu")
                let telegram = GatewayShellE2eAdapter("telegram")
                let gateway = gatewayShellE2eService(feishu, telegram)
                let loads = ArrayList<Future<Bool>>()
                let fixture = Path(managedStdioResolveBrokerScriptPath())
                    .parent
                    .join("gateway-stdio-fake-command-child.mjs")
                    .toString()
                let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds()
                let readyPath = Path("/tmp/metis-gateway-shell-e2e-${nonce}.ready")
                let releasePath = Path("/tmp/metis-gateway-shell-e2e-${nonce}.release")
                let command = "node '${fixture}' wait-release '${readyPath.toString()}' '${releasePath.toString()}'"
                var healthUrl = ""
                var healthPort: Int64 = 0
                try { remove(readyPath) } catch (_: Exception) { () }
                try { remove(releasePath) } catch (_: Exception) { () }
                GatewayHttpSurface.stopIfRunning()
                gateway.start()
                try {
                    for (_ in 0..6) {
                        loads.add(spawn {gatewayShellFormalTimedLoad(command)})
                    }
                    @Expect(gatewayShellE2eAwait({ =>
                        managedStdioBroker().snapshot().ownerCount == 6 && gatewayShellReadyCount(readyPath) == 6
                    }), true)

                    for (_ in 0..5) {
                        let candidate = gatewayShellTemporaryHealthPort()
                        if (candidate <= 0) {
                            continue
                        }
                        var user = GatewayUserSettings()
                        user.port = candidate
                        user.bind = "loopback"
                        user.customBindHost = ""
                        user.auth.mode = "none"
                        user.http.endpoints.chatCompletions.enabled = true
                        let cfg = buildGatewayConfigFromUserSettings(user)
                        let candidateUrl = "http://127.0.0.1:${candidate}/healthz"
                        GatewayHttpSurface.startIfNeeded(cfg)
                        if (gatewayShellE2eAwait({=> gatewayShellHealthMatchesPort(candidateUrl, candidate)})) {
                            healthPort = candidate
                            healthUrl = candidateUrl
                            break
                        }
                        GatewayHttpSurface.stopIfRunning()
                    }
                    @Expect(healthPort > 0, true)
                    if (healthPort <= 0) {
                        throw Exception("P3-P5 isolated health surface unavailable")
                    }

                    for (index in 0..4) {
                        @Expect(managedStdioBroker().snapshot().ownerCount, 6)
                        feishu.enqueue(index)
                        telegram.enqueue(index)
                        let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
                        gateway.processOnceAndAwaitForTest()
                        let response = gatewayShellFetchHealthz(healthUrl)
                        let elapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt
                        let health = JsonValue.fromStr(response.body).asObject()
                        @Expect(response.status, 200)
                        @Expect(health.get("ok").getOrThrow().asBool().getValue(), true)
                        @Expect(health.get("status").getOrThrow().asString().getValue(), "live")
                        @Expect(
                        health.get("gateway").getOrThrow().asObject().get("port").getOrThrow().asInt().getValue(),
                        healthPort
                        )
                        @Expect(elapsed < 1000, true)
                        @Expect(managedStdioBroker().snapshot().ownerCount, 6)
                        let feishuReply = "feishu-reply:feishu-shell-${index}-中文🙂"
                        let telegramReply = "telegram-reply:telegram-shell-${index}-中文🙂"
                        @Expect(feishu.countExact(feishuReply), 1)
                        @Expect(telegram.countExact(telegramReply), 1)
                        @Expect(feishu.countExact(telegramReply), 0)
                        @Expect(telegram.countExact(feishuReply), 0)
                    }
                    // Recheck every indexed reply after all poll turns so a late duplicate
                    // or cross-channel delivery cannot be hidden by an earlier assertion.
                    for (index in 0..4) {
                        let feishuReply = "feishu-reply:feishu-shell-${index}-中文🙂"
                        let telegramReply = "telegram-reply:telegram-shell-${index}-中文🙂"
                        @Expect(feishu.countExact(feishuReply), 1)
                        @Expect(telegram.countExact(telegramReply), 1)
                        @Expect(feishu.countExact(telegramReply), 0)
                        @Expect(telegram.countExact(feishuReply), 0)
                    }
                    File.writeTo(releasePath, "release".toArray())
                    for (load in loads) {
                        @Expect(load.get(Duration.second * 5), true)
                    }
                    @Expect(gatewayShellE2eAwait({ => managedStdioBroker().snapshot().ownerCount == 0 }), true)
                } finally {
                    try { File.writeTo(releasePath, "release".toArray()) } catch (_: Exception) { () }
                    GatewayHttpSurface.stopIfRunning()
                    try {
                        gateway.stop()
                    } catch (_: Exception) {
                        ()
                    }
                    var loadsSettled = gatewayShellJoinLoads(loads, 5000)
                    var ownersCleared = gatewayShellE2eAwait({ =>
                        managedStdioBroker().snapshot().ownerCount == 0
                    })
                    if (!loadsSettled || !ownersCleared) {
                        let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                        loadsSettled = gatewayShellJoinLoads(loads, 5000)
                        ownersCleared = gatewayShellE2eAwait({ =>
                            managedStdioBroker().snapshot().ownerCount == 0
                        })
                    }
                    try { remove(readyPath) } catch (_: Exception) { () }
                    try { remove(releasePath) } catch (_: Exception) { () }
                    @Expect(loadsSettled, true)
                    @Expect(ownersCleared, true)
                }
            }
        )
    }
}
