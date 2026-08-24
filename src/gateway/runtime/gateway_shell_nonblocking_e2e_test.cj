package metis.gateway.runtime

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext}
import metis.core.config.{CliConfig, CliSettingManager, GatewayUserSettings, MetisConfigManager,
    MetisProcessEnvironmentLock}
import metis.gateway.config.buildGatewayConfigFromUserSettings
import metis.gateway.core.{ChannelAdapter, GatewayRouter, GatewayService, setGatewayAgentBridgeReplyRunnerForTest}
import metis.gateway.model.{ChannelPolicyConfig, ChannelType, ChatType, InboundMessage, OutboundMessage, SendResult}
import metis.gateway.tools.debugGatewayShellExecuteForTest
import metis.process.{managedStdioBroker, managedStdioResolveBrokerScriptPath, resetManagedStdioBrokerForTest}
import std.collection.{ArrayList, HashMap}
import std.core.Duration
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.net.*
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue
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
    private let inbound = ArrayList<InboundMessage>()
    private let sent = ArrayList<String>()

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
        let messages = this.inbound.toArray()
        this.inbound.clear()
        messages
    }

    public func enqueue(index: Int64): Unit {
        let channel = if (this.adapterName == "telegram") {
            ChannelType.Telegram
        } else {
            ChannelType.Feishu
        }
        this
            .inbound
            .add(
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

    public func send(message: OutboundMessage): SendResult {
        this.sent.add(message.text)
        SendResult.Success
    }

    public func sendWithMessageId(message: OutboundMessage): String {
        this.sent.add(message.text)
        "${this.adapterName}-sent-${this.sent.size}"
    }

    public func countExact(expected: String): Int64 {
        var count: Int64 = 0
        for (text in this.sent) {
            if (text == expected) {
                count += 1
            }
        }
        count
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

@Test
public class GatewayShellNonblockingE2eTest {
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
                        gateway.processOnce()
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
