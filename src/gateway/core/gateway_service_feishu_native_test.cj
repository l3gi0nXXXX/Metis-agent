package metis.gateway.core

import metis.core.config.{CliConfig, CliSettingManager, GatewayServicePluginUserSettings, GatewayUserSettings, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.model.{ChannelPolicyConfig, ChannelType, ChatType, InboundMessage, OutboundMessage, SendResult}
import metis.gateway.security.gatewayPairingAccountStore
import metis.gateway.service_plugin.{CapabilityInvokeResult, CapabilityInvokeRequest, ServicePluginRegistration, resetServicePluginPendingJobStoreForTest, setServicePluginCapabilityInvokerForTest}

import magic.core.message.Message
import magic.core.model.{AsyncChatResponse, ChatModel, ChatRequest, ChatResponse}
import magic.model.ModelManager

import std.collection.{ArrayList, HashMap}
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString, JsonValue}

private class GatewayFeishuNativeTestAdapter <: ChannelAdapter {
    private let inbound = ArrayList<InboundMessage>()
    private let sent = ArrayList<OutboundMessage>()
    private let accountId: String

    public init(accountId!: String = "default") {
        this.accountId = if (accountId.trimAscii().isEmpty()) { "default" } else { accountId.trimAscii() }
    }

    public prop name: String {
        get() { "feishu" }
    }

    public func start(): Unit {}

    public func stop(): Unit {}

    public func queueDirect(text: String): Unit {
        this.inbound.add(InboundMessage(
            ChannelType.Feishu,
            "om-${this.inbound.size}",
            "ou_peer",
            "ou_sender",
            ChatType.Direct,
            text,
            true,
            DateTime.now(),
            accountId: this.accountId
        ))
    }

    public func queueDirectWithRoute(text: String, mediaContext: JsonObject): Unit {
        this.inbound.add(InboundMessage(
            ChannelType.Feishu,
            "om-${this.inbound.size}",
            "ou_peer",
            "ou_sender",
            ChatType.Direct,
            text,
            true,
            DateTime.now(),
            accountId: this.accountId,
            mediaContext: mediaContext
        ))
    }

    public func queueGroup(text: String): Unit {
        this.inbound.add(InboundMessage(
            ChannelType.Feishu,
            "om-group-${this.inbound.size}",
            "oc_group",
            "ou_sender",
            ChatType.Group,
            text,
            false,
            DateTime.now(),
            accountId: this.accountId
        ))
    }

    public func pullInbound(): Array<InboundMessage> {
        let out = this.inbound.toArray()
        this.inbound.clear()
        out
    }

    public func send(message: OutboundMessage): SendResult {
        this.sent.add(message)
        SendResult.Success
    }

    public func sendWithMessageId(message: OutboundMessage): String {
        this.sent.add(message)
        "feishu-native-${this.sent.size}"
    }

    public func sentText(index: Int64): String {
        match (this.sent.get(index)) {
            case Some(v) => v.text
            case None => ""
        }
    }

    public func sentAccount(index: Int64): String {
        match (this.sent.get(index)) {
            case Some(v) => v.accountId
            case None => ""
        }
    }

    public func sentReplyTo(index: Int64): String {
        match (this.sent.get(index)) {
            case Some(v) => v.replyToMessageId ?? ""
            case None => ""
        }
    }

    public func sentCount(): Int64 {
        this.sent.size
    }
}

private class GatewayFeishuNativeFakeModel <: ChatModel {
    private let answer: String
    private var _maxTokens: Option<Int64> = None

    public init(answer!: String = "feishu final answer") {
        this.answer = answer
    }

    public prop provider: String {
        get() { "fake" }
    }

    public prop name: String {
        get() { "feishu-native" }
    }

    public prop contextLength: Int64 {
        get() { 8192 }
    }

    public mut prop maxTokens: Option<Int64> {
        get() { this._maxTokens }
        set(v) { this._maxTokens = v }
    }

    public func create(_request: ChatRequest): ChatResponse {
        ChatResponse(this.fullName, Message.assistant(this.answer))
    }

    public func asyncCreate(_request: ChatRequest): AsyncChatResponse {
        throw Exception("async not used in feishu native tests")
    }
}

private func gatewayFeishuNativeTestRoot(appSecret!: String = ""): JsonObject {
    let root = JsonObject()
    let gateway = JsonObject()
    let feishu = JsonObject()
    feishu.put("enabled", JsonBool(true))
    feishu.put("defaultAccount", JsonString("default"))
    feishu.put("receiveMode", JsonString("long_connect"))
    feishu.put("domain", JsonString("https://open.feishu.cn"))
    feishu.put("appId", JsonString("cli_test_app"))
    feishu.put("appSecret", JsonString(appSecret))
    gateway.put("feishu", feishu)
    root.put("gateway", gateway)
    root.put("agents", JsonArray([]))
    root.put("bindings", JsonArray([]))
    root
}

private func gatewayFeishuNativeAckRoot(enabled: Bool, removeAfterReply!: Bool = true): JsonObject {
    let root = gatewayFeishuNativeTestRoot()
    let gateway = root.get("gateway").getOrThrow().asObject()
    let feishu = gateway.get("feishu").getOrThrow().asObject()
    let ack = JsonObject()
    ack.put("enabled", JsonBool(enabled))
    ack.put("reaction", JsonString("敲键盘"))
    ack.put("removeAfterReply", JsonBool(removeAfterReply))
    ack.put("scope", JsonString("handled"))
    feishu.put("ack", ack)
    root
}

private func gatewayFeishuNativeBroadcastAgent(id: String, isDefault!: Bool = false): JsonObject {
    let agent = JsonObject()
    agent.put("id", JsonString(id))
    if (isDefault) {
        agent.put("default", JsonBool(true))
    }
    let model = JsonObject()
    model.put("primary", JsonString("fake:${id}"))
    agent.put("model", model)
    agent
}

private func gatewayFeishuNativeBroadcastBinding(agentId: String): JsonObject {
    let binding = JsonObject()
    binding.put("type", JsonString("route"))
    binding.put("agentId", JsonString(agentId))
    let matchObj = JsonObject()
    matchObj.put("channel", JsonString("feishu"))
    matchObj.put("accountId", JsonString("*"))
    let peer = JsonObject()
    peer.put("kind", JsonString("direct"))
    peer.put("id", JsonString("ou_peer"))
    matchObj.put("peer", peer)
    binding.put("match", matchObj)
    binding
}

private func gatewayFeishuNativeBroadcastMember(agentId: String): JsonObject {
    let member = JsonObject()
    member.put("agentId", JsonString(agentId))
    member
}

private func gatewayFeishuNativeBroadcastRoot(): JsonObject {
    let root = gatewayFeishuNativeTestRoot()
    let agents = JsonObject()
    agents.put("list", JsonArray([
        gatewayFeishuNativeBroadcastAgent("main", isDefault: true),
        gatewayFeishuNativeBroadcastAgent("ops"),
        gatewayFeishuNativeBroadcastAgent("writer"),
        gatewayFeishuNativeBroadcastAgent("reviewer")
    ]))
    root.put("agents", agents)

    let bindings = JsonArray([])
    bindings.add(gatewayFeishuNativeBroadcastBinding("ops"))
    root.put("bindings", bindings)

    let team = JsonObject()
    team.put("id", JsonString("content"))
    team.put("displayName", JsonString("Content Team"))
    team.put("defaultAgentId", JsonString("ops"))
    team.put("members", JsonArray([
        gatewayFeishuNativeBroadcastMember("ops"),
        gatewayFeishuNativeBroadcastMember("writer"),
        gatewayFeishuNativeBroadcastMember("reviewer")
    ]))
    team.put("bindings", JsonArray([gatewayFeishuNativeBroadcastBinding("ops")]))
    let broadcast = JsonObject()
    broadcast.put("enabled", JsonBool(true))
    broadcast.put("members", JsonArray([
        JsonString("writer"),
        JsonString("reviewer")
    ]))
    team.put("broadcast", broadcast)
    let agentTeams = JsonObject()
    agentTeams.put("list", JsonArray([team]))
    root.put("agentTeams", agentTeams)
    root
}

private func gatewayFeishuNativeBroadcastMediaContext(): JsonObject {
    let media = JsonObject()
    let context = JsonObject()
    let route = JsonObject()
    route.put("accountId", JsonString("default"))
    route.put("defaultAccountId", JsonString("default"))
    route.put("peerKind", JsonString("direct"))
    route.put("peerId", JsonString("ou_peer"))
    context.put("imRoute", route)
    media.put("context", context)
    media
}

private func withGatewayFeishuNativeTestHome<T>(label: String, root: JsonObject, block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let testHome = "/tmp/metis-gateway-feishu-native-${label}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}"
        try { remove(Path(testHome), recursive: true) } catch (_e: Exception) { () }
        Directory.create(testHome, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", testHome)
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        MetisConfigManager.writeRoot(root)
        CliSettingManager.applyPersistedFieldsToCliConfig()
        try {
            return block()
        } finally {
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            try { remove(Path(testHome), recursive: true) } catch (_e: Exception) { () }
        }
    }
}

private func gatewayFeishuNativeService(adapter: GatewayFeishuNativeTestAdapter, enableGroup!: Bool = true, accountId!: String = "default"): GatewayService {
    let policies = HashMap<String, ChannelPolicyConfig>()
    policies["feishu"] = ChannelPolicyConfig(enableDirect: true, enableGroup: enableGroup, requireMentionInGroup: true)
    let service = GatewayService(GatewayRouter(policies))
    service.registerAdapter(adapter, channelId: "feishu", accountId: accountId)
    service
}

private func gatewayFeishuNativeGitcodePluginSettings(accountId: String, manifestPath!: String = ""): GatewayServicePluginUserSettings {
    var plugin = GatewayServicePluginUserSettings()
    plugin.pluginId = "gitcode-monitor"
    plugin.enabled = true
    if (manifestPath.isEmpty()) {
        let generated = CliConfig.dotDir.join("feishu-gitcode-monitor-service-plugin.json")
        File.writeTo(
            generated,
            (
                "{\"schema\":\"metis.servicePlugin.v1\",\"pluginId\":\"gitcode-monitor\",\"kind\":\"service\",\"protocolVersion\":\"1.0\"," +
                "\"entry\":{\"command\":\"gitcode-monitor\"}," +
                "\"configSchema\":{}," +
                "\"capabilityDeclarations\":[" +
                "{\"capabilityId\":\"gitcode.monitor.status\",\"kind\":\"controlAction\"}," +
                "{\"capabilityId\":\"gitcode.monitor.scan_once\",\"kind\":\"controlAction\"}," +
                "{\"capabilityId\":\"gitcode.webhook.status\",\"kind\":\"controlAction\"}," +
                "{\"capabilityId\":\"gitcode.webhook.dead_letter_list\",\"kind\":\"controlAction\"}," +
                "{\"capabilityId\":\"gitcode.webhook.dead_letter_inspect\",\"kind\":\"controlAction\"}," +
                "{\"capabilityId\":\"gitcode.webhook.replay\",\"kind\":\"controlAction\"}," +
                "{\"capabilityId\":\"gitcode.webhook.cancel\",\"kind\":\"controlAction\"}," +
                "{\"capabilityId\":\"gitcode.webhook.reconcile_hooks\",\"kind\":\"controlAction\"}," +
                "{\"capabilityId\":\"gitcode.webhook.reconcile_events\",\"kind\":\"controlAction\"}" +
                "]}"
            ).toArray()
        )
        plugin.manifestPath = generated.toString()
    } else {
        plugin.manifestPath = manifestPath
    }
    plugin.grants = ["host.agent.invoke", "host.notification.publish", "host.audit.append"]
    let binding = JsonObject()
    binding.put("accountId", JsonString(accountId))
    binding.put("commandPrefix", JsonString("/gitcode"))
    binding.put("scopes", JsonArray([JsonString("direct"), JsonString("group")]))
    plugin.imBindings.put("feishu", binding)
    plugin
}

@Test
public class GatewayServiceFeishuNativeTest {
    @TestCase
    public func feishuGitcodeCommandDispatchesBeforeAgentRoute(): Unit {
        withGatewayFeishuNativeTestHome("gitcode-dispatch", gatewayFeishuNativeTestRoot(), { =>
            var user = CliSettingManager.readGatewaySettings()
            user.servicePlugins = [gatewayFeishuNativeGitcodePluginSettings("feishu-gitcode-monitor")]
            CliSettingManager.writeGatewaySettings(user)

            let adapter = GatewayFeishuNativeTestAdapter(accountId: "feishu-gitcode-monitor")
            let service = gatewayFeishuNativeService(adapter, enableGroup: false, accountId: "feishu-gitcode-monitor")
            service.start()
            try {
                setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
                    @Expect(request.capabilityId, "gitcode.monitor.status")
                    CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"ok\":true,\"status\":\"running\",\"summary\":\"dryRun=true seen=0\"}")
                }))

                adapter.queueDirect("/gitcode status")
                service.processOnce()

                @Expect(adapter.sentCount(), 1)
                @Expect(adapter.sentText(0).contains("GitCode status:"), true)
                @Expect(adapter.sentText(0).contains("dryRun=true"), true)
                @Expect(adapter.sentAccount(0), "feishu-gitcode-monitor")
            } finally {
                setServicePluginCapabilityInvokerForTest(None)
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuGitcodeWebhookStatusShowsGcmDiagnosticsWithoutRawJson(): Unit {
        withGatewayFeishuNativeTestHome("gitcode-webhook-status", gatewayFeishuNativeTestRoot(), { =>
            var user = CliSettingManager.readGatewaySettings()
            user.servicePlugins = [gatewayFeishuNativeGitcodePluginSettings("feishu-gitcode-monitor")]
            CliSettingManager.writeGatewaySettings(user)

            let adapter = GatewayFeishuNativeTestAdapter(accountId: "feishu-gitcode-monitor")
            let service = gatewayFeishuNativeService(adapter, enableGroup: false, accountId: "feishu-gitcode-monitor")
            service.start()
            try {
                setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
                    @Expect(request.capabilityId, "gitcode.webhook.status")
                    CapabilityInvokeResult(true, "ok", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"status\":\"running\",\"receiver\":\"running\",\"listener\":{\"status\":\"listening\",\"bind\":\"127.0.0.1:18080\",\"lastStatus\":202,\"lastDurationMs\":2,\"healthz\":\"ok\"},\"processor\":{\"status\":\"running\",\"pending\":0,\"processing\":0,\"processed\":10,\"deadLetter\":0,\"emptyTicks\":42},\"stateSave\":{\"status\":\"skipped_empty_queue\",\"lastDurationMs\":0,\"bytes\":215647,\"auditCount\":595,\"auditMax\":1000},\"authorization\":\"Bearer must-not-show\"}")
                }))

                adapter.queueDirect("/gitcode webhook status")
                service.processOnce()

                @Expect(adapter.sentCount(), 1)
                let text = adapter.sentText(0)
                @Expect(text.contains("GitCode Webhook 状态"), true)
                @Expect(text.contains("GitCode Webhook 状态：运行正常"), true)
                @Expect(text.contains("接收端：正在监听（地址 127.0.0.1:18080）；最近 HTTP 202，耗时 2ms；健康检查正常。"), true)
                @Expect(text.contains("队列：没有积压，已处理 10 条，失败 0 条，取消 0 条。"), true)
                @Expect(text.contains("处理器：正在运行；最近未领取新事件，处理 10 条；空闲轮询 42 次。"), true)
                @Expect(text.contains("状态保存：空队列，无需保存状态，耗时 0ms，写入 215647 字节，审计记录 595/1000。"), true)
                @Expect(text.contains("{"), false)
                @Expect(text.contains("\"status\""), false)
                @Expect(text.contains("Bearer"), false)
                @Expect(text.contains("must-not-show"), false)
                @Expect(text.contains("unknown"), false)
                @Expect(text.contains("diagnostics-missing"), false)
                @Expect(adapter.sentAccount(0), "feishu-gitcode-monitor")
            } finally {
                setServicePluginCapabilityInvokerForTest(None)
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuGitcodeScanOnceUsesWebhookReconcileAliasWithRedactedPayload(): Unit {
        withGatewayFeishuNativeTestHome("gitcode-scan", gatewayFeishuNativeTestRoot(), { =>
            var user = CliSettingManager.readGatewaySettings()
            user.servicePlugins = [gatewayFeishuNativeGitcodePluginSettings("feishu-gitcode-monitor")]
            CliSettingManager.writeGatewaySettings(user)

            let adapter = GatewayFeishuNativeTestAdapter(accountId: "feishu-gitcode-monitor")
            let service = gatewayFeishuNativeService(adapter, enableGroup: false, accountId: "feishu-gitcode-monitor")
            service.start()
            try {
                resetServicePluginPendingJobStoreForTest()
                let payloads = ArrayList<String>()
                setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
                    payloads.add(request.payload)
                    @Expect(request.capabilityId, "gitcode.webhook.reconcile_events")
                    @Expect(request.timeoutMillis <= 60000, true)
                    let root = JsonValue.fromStr(request.payload).asObject()
                    @Expect(root.get("mode").getOrThrow().asString().getValue(), "async")
                    let jobId = root.get("jobId").getOrThrow().asString().getValue()
                    CapabilityInvokeResult(true, "accepted", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, payload: "{\"ok\":true,\"status\":\"accepted\",\"mode\":\"async\",\"jobId\":\"${jobId}\",\"alreadyRunning\":false}")
                }))

                adapter.queueDirect("/gitcode scan once")
                service.processOnce()
                adapter.queueDirect("/gitcode scan once --max-repos 2 --max-items 20")
                service.processOnce()

                @Expect(adapter.sentCount(), 2)
                @Expect(adapter.sentText(0).contains("GitCode webhook-first reconcile 已启动"), true)
                @Expect(adapter.sentText(0).contains("scanId=gcm-scan-"), true)
                @Expect(adapter.sentText(0).contains("status=queued capability="), false)
                @Expect(adapter.sentText(0).contains("\"accepted\""), false)
                @Expect(adapter.sentText(1).contains("GitCode webhook-first reconcile 已启动"), true)
                @Expect(adapter.sentAccount(0), "feishu-gitcode-monitor")
                @Expect(adapter.sentAccount(1), "feishu-gitcode-monitor")
                @Expect(payloads.size, 2)
                let defaultLimits = JsonValue.fromStr(payloads[0]).asObject().get("limits").getOrThrow().asObject()
                @Expect(defaultLimits.get("maxRepos").getOrThrow().asInt().getValue(), 0)
                @Expect(defaultLimits.get("maxItems").getOrThrow().asInt().getValue(), 0)
                @Expect(payloads[0].contains("Authorization"), false)
                let explicitLimits = JsonValue.fromStr(payloads[1]).asObject().get("limits").getOrThrow().asObject()
                @Expect(explicitLimits.get("maxRepos").getOrThrow().asInt().getValue(), 2)
                @Expect(explicitLimits.get("maxItems").getOrThrow().asInt().getValue(), 20)
            } finally {
                setServicePluginCapabilityInvokerForTest(None)
                resetServicePluginPendingJobStoreForTest()
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuGitcodeScanOnceRejectsTimeoutWithoutInvokingGcm(): Unit {
        withGatewayFeishuNativeTestHome("gitcode-timeout", gatewayFeishuNativeTestRoot(), { =>
            var user = CliSettingManager.readGatewaySettings()
            user.servicePlugins = [gatewayFeishuNativeGitcodePluginSettings("feishu-gitcode-monitor")]
            CliSettingManager.writeGatewaySettings(user)

            let adapter = GatewayFeishuNativeTestAdapter(accountId: "feishu-gitcode-monitor")
            let service = gatewayFeishuNativeService(adapter, enableGroup: false, accountId: "feishu-gitcode-monitor")
            service.start()
            try {
                resetServicePluginPendingJobStoreForTest()
                let payloads = ArrayList<String>()
                setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
                    payloads.add(request.payload)
                    CapabilityInvokeResult(false, "unexpected_invocation", serviceId: "gitcode-monitor", capabilityId: request.capabilityId)
                }))

                adapter.queueDirect("/gitcode scan once --timeout-ms 1000")
                service.processOnce()

                @Expect(adapter.sentCount(), 1)
                @Expect(adapter.sentText(0).contains("--timeout-ms is not supported for webhook-first reconcile"), true)
                @Expect(adapter.sentText(0).contains("{"), false)
                @Expect(adapter.sentText(0).contains("\"ok\""), false)
                @Expect(adapter.sentText(0).contains("scanId=gcm-scan-"), false)
                @Expect(payloads.size, 0)
            } finally {
                setServicePluginCapabilityInvokerForTest(None)
                resetServicePluginPendingJobStoreForTest()
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuGitcodeFailureDoesNotExposeRawJsonDiagnostic(): Unit {
        withGatewayFeishuNativeTestHome("gitcode-failure", gatewayFeishuNativeTestRoot(), { =>
            var user = CliSettingManager.readGatewaySettings()
            user.servicePlugins = [gatewayFeishuNativeGitcodePluginSettings("feishu-gitcode-monitor")]
            CliSettingManager.writeGatewaySettings(user)

            let adapter = GatewayFeishuNativeTestAdapter(accountId: "feishu-gitcode-monitor")
            let service = gatewayFeishuNativeService(adapter, enableGroup: false, accountId: "feishu-gitcode-monitor")
            service.start()
            try {
                resetServicePluginPendingJobStoreForTest()
                let diagnostic = "{ \"ok\": true, \"status\": \"ok\", \"capabilities\": 8 }"
                setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
                    @Expect(request.capabilityId.startsWith("gitcode."), true)
                    CapabilityInvokeResult(false, "initialize_failed", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, diagnostic: diagnostic)
                }))

                adapter.queueDirect("/gitcode status")
                service.processOnce()
                adapter.queueDirect("/gitcode scan once")
                service.processOnce()

                @Expect(adapter.sentCount(), 2)
                let statusText = adapter.sentText(0)
                let scanText = adapter.sentText(1)
                @Expect(statusText.contains("GitCode status failed:"), true)
                @Expect(scanText.contains("GitCode reconcile failed:"), true)
                @Expect(statusText.contains("{"), false)
                @Expect(statusText.contains("}"), false)
                @Expect(statusText.contains("\"ok\""), false)
                @Expect(statusText.contains("\"status\""), false)
                @Expect(statusText.contains("\"capabilities\""), false)
                @Expect(scanText.contains("{"), false)
                @Expect(scanText.contains("}"), false)
                @Expect(scanText.contains("\"ok\""), false)
                @Expect(scanText.contains("\"status\""), false)
                @Expect(scanText.contains("\"capabilities\""), false)
                @Expect(adapter.sentAccount(0), "feishu-gitcode-monitor")
                @Expect(adapter.sentAccount(1), "feishu-gitcode-monitor")
            } finally {
                setServicePluginCapabilityInvokerForTest(None)
                resetServicePluginPendingJobStoreForTest()
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuGitcodeProtocolFailuresAreHumanReadable(): Unit {
        withGatewayFeishuNativeTestHome("gitcode-protocol-failure", gatewayFeishuNativeTestRoot(), { =>
            var user = CliSettingManager.readGatewaySettings()
            user.servicePlugins = [gatewayFeishuNativeGitcodePluginSettings("feishu-gitcode-monitor")]
            CliSettingManager.writeGatewaySettings(user)

            let adapter = GatewayFeishuNativeTestAdapter(accountId: "feishu-gitcode-monitor")
            let service = gatewayFeishuNativeService(adapter, enableGroup: false, accountId: "feishu-gitcode-monitor")
            service.start()
            try {
                resetServicePluginPendingJobStoreForTest()
                setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
                    CapabilityInvokeResult(false, "stdout_protocol_violation", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, diagnostic: "{\"ok\":false,\"status\":\"stdout_protocol_violation\",\"diagnostic\":\"Authorization: Bearer secret /Users/name/private\"}")
                }))
                adapter.queueDirect("/gitcode scan once --max-repos 1")
                service.processOnce()

                setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
                    CapabilityInvokeResult(false, "unexpected_frame", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, diagnostic: "{\"ok\":false,\"status\":\"unexpected_frame\",\"diagnostic\":\"Authorization: Bearer secret /Users/name/private\"}")
                }))
                adapter.queueDirect("/gitcode scan once --max-repos 2")
                service.processOnce()

                setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
                    CapabilityInvokeResult(false, "payload_invalid", serviceId: "gitcode-monitor", capabilityId: request.capabilityId, diagnostic: "{\"ok\":false,\"status\":\"payload_invalid\",\"diagnostic\":\"Authorization: Bearer secret /Users/name/private\"}")
                }))
                adapter.queueDirect("/gitcode scan once --max-repos 3")
                service.processOnce()

                @Expect(adapter.sentCount(), 3)
                @Expect(adapter.sentText(0), "GitCode reconcile failed: service plugin wrote invalid data to stdout before the response.")
                @Expect(adapter.sentText(1), "GitCode reconcile failed: service plugin returned a response for a different request.")
                @Expect(adapter.sentText(2), "GitCode reconcile failed: service plugin returned an invalid payload.")
                for (i in 0..3) {
                    let text = adapter.sentText(i)
                    @Expect(text.contains("{"), false)
                    @Expect(text.contains("}"), false)
                    @Expect(text.contains("\"ok\""), false)
                    @Expect(text.contains("\"status\""), false)
                    @Expect(text.contains("secret"), false)
                    @Expect(text.contains("/Users/"), false)
                }
            } finally {
                setServicePluginCapabilityInvokerForTest(None)
                resetServicePluginPendingJobStoreForTest()
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuGitcodeManifestMissingReturnsDegradedReply(): Unit {
        withGatewayFeishuNativeTestHome("gitcode-manifest-missing", gatewayFeishuNativeTestRoot(), { =>
            var user = CliSettingManager.readGatewaySettings()
            user.servicePlugins = [
                gatewayFeishuNativeGitcodePluginSettings(
                    "feishu-gitcode-monitor",
                    manifestPath: "/tmp/metis-missing-gitcode-service-plugin-manifest-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.json"
                )
            ]
            CliSettingManager.writeGatewaySettings(user)

            let adapter = GatewayFeishuNativeTestAdapter(accountId: "feishu-gitcode-monitor")
            let service = gatewayFeishuNativeService(adapter, enableGroup: false, accountId: "feishu-gitcode-monitor")
            service.start()
            try {
                adapter.queueDirect("/gitcode status")
                service.processOnce()

                @Expect(adapter.sentCount(), 1)
                @Expect(adapter.sentText(0).contains("degraded"), true)
                @Expect(adapter.sentText(0).contains("manifest_missing"), true)
                @Expect(adapter.sentAccount(0), "feishu-gitcode-monitor")
            } finally {
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuStartNativeCommandBypassesGroupGate(): Unit {
        withGatewayFeishuNativeTestHome("start", gatewayFeishuNativeTestRoot(), { =>
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter, enableGroup: false)
            service.start()
            try {
                adapter.queueGroup("/feishu start")
                service.processOnce()
                @Expect(adapter.sentCount(), 1)
                @Expect(adapter.sentText(0).contains("Metis Feishu start"), true)
                @Expect(adapter.sentText(0).contains("accountId: default"), true)
            } finally {
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuStartShowsConnectionConfigurationAndAccountStatus(): Unit {
        withGatewayFeishuNativeTestHome("start-status", gatewayFeishuNativeTestRoot(appSecret: "start-secret"), { =>
            setGatewayFeishuNativeAuthStatusRunnerForTest(Some({ accountId: String, _user: GatewayUserSettings =>
                let out = JsonObject()
                out.put("status", JsonString("authorized"))
                out.put("accountId", JsonString(accountId))
                out.put("tokenStatus", JsonString("authorized"))
                out.put("scopeSummary", JsonString("offline_access im:message"))
                out.put("refreshToken", JsonString("must-not-render"))
                out
            }))
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter, enableGroup: false)
            service.start()
            try {
                adapter.queueGroup("/feishu start")
                service.processOnce()
                let reply = adapter.sentText(0)
                @Expect(adapter.sentCount(), 1)
                @Expect(reply.contains("connection: configured"), true)
                @Expect(reply.contains("configuration: enabled=true"), true)
                @Expect(reply.contains("accountStatus: credentials=configured oauth=authorized"), true)
                @Expect(reply.contains("OAPI: external-resource-required"), true)
                @Expect(reply.contains("start-secret"), false)
                @Expect(reply.contains("must-not-render"), false)
            } finally {
                service.stop()
                setGatewayFeishuNativeAuthStatusRunnerForTest(None<(String, GatewayUserSettings) -> JsonObject>)
            }
        })
    }

    @TestCase
    public func feishuDoctorReportsMissingBindingsAndRedactsSecret(): Unit {
        withGatewayFeishuNativeTestHome("doctor", gatewayFeishuNativeTestRoot(appSecret: "top-secret"), { =>
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            service.start()
            try {
                adapter.queueDirect("/feishu doctor")
                service.processOnce()
                let reply = adapter.sentText(0)
                @Expect(adapter.sentCount(), 1)
                @Expect(reply.contains("Metis Feishu doctor"), true)
                @Expect(reply.contains("credentials: configured"), true)
                @Expect(reply.contains("bindings: missing"), true)
                @Expect(reply.contains("top-secret"), false)
            } finally {
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuDiagnoseAliasRunsDoctorAndHelpDocumentsEquivalence(): Unit {
        withGatewayFeishuNativeTestHome("diagnose-alias", gatewayFeishuNativeTestRoot(appSecret: "diagnose-secret"), { =>
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            service.start()
            try {
                adapter.queueDirect("/feishu_diagnose")
                adapter.queueDirect("/feishu help")
                service.processOnce()
                service.processOnce()
                @Expect(adapter.sentCount(), 2)

                let diagnose = adapter.sentText(0)
                @Expect(diagnose.contains("Metis Feishu doctor"), true)
                @Expect(diagnose.contains("diagnose-secret"), false)
                @Expect(diagnose.contains("\"ok\""), false)
                @Expect(diagnose.contains("\"result\""), false)

                let help = adapter.sentText(1)
                @Expect(help.contains("/feishu_diagnose"), true)
                @Expect(help.contains("alias of /feishu doctor"), true)
                @Expect(help.contains("\"ok\""), false)
                @Expect(help.contains("\"result\""), false)
            } finally {
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuDoctorStatesHelperActionDecisionsWithoutAdvertisingUnsupportedActions(): Unit {
        withGatewayFeishuNativeTestHome("helper-decisions", gatewayFeishuNativeTestRoot(appSecret: "helper-secret"), { =>
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            service.start()
            try {
                adapter.queueDirect("/feishu doctor")
                service.processOnce()
                let reply = adapter.sentText(0)
                @Expect(reply.contains("helper typing: not-advertised"), true)
                @Expect(reply.contains("helper forward: not-advertised"), true)
                @Expect(reply.contains("helper chat-manage: tool-level-only feishu_chat/feishu_chat_members"), true)
                @Expect(reply.contains("helper-secret"), false)
            } finally {
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuNativeCommandsExposePairingCountsWithoutCodesOrSenderDetails(): Unit {
        withGatewayFeishuNativeTestHome("pairing-visible", gatewayFeishuNativeTestRoot(appSecret: "pairing-secret"), { =>
            let store = gatewayPairingAccountStore(channel: "feishu", accountId: "default", rootDir: CliConfig.dotDir)
            let approvedCode = store.ensurePending("ou_approved")
            @Expect(store.approve(approvedCode), true)
            let pendingCode = store.ensurePending("ou_pending")
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            service.start()
            try {
                adapter.queueDirect("/feishu start")
                adapter.queueDirect("/feishu doctor")
                adapter.queueDirect("/feishu info --all")
                service.processOnce()
                service.processOnce()
                service.processOnce()
                @Expect(adapter.sentCount(), 3)
                let all = adapter.sentText(0) + "\n" + adapter.sentText(1) + "\n" + adapter.sentText(2)
                @Expect(all.contains("dmPolicy: pairing"), true)
                @Expect(all.contains("pairing pending=1 approved=1"), true)
                @Expect(all.contains("metis pairing approve feishu <CODE> --account default"), true)
                @Expect(all.contains(pendingCode), false)
                @Expect(all.contains(approvedCode), false)
                @Expect(all.contains("ou_pending"), false)
                @Expect(all.contains("ou_approved"), false)
                @Expect(all.contains("pairing-secret"), false)
            } finally {
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuDoctorWarnsWhenDmPolicyIsOpen(): Unit {
        let root = gatewayFeishuNativeTestRoot(appSecret: "open-secret")
        let gateway = root.get("gateway").getOrThrow().asObject()
        let feishu = gateway.get("feishu").getOrThrow().asObject()
        feishu.put("dmPolicy", JsonString("open"))
        withGatewayFeishuNativeTestHome("doctor-open-policy", root, { =>
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            service.start()
            try {
                adapter.queueDirect("/feishu doctor")
                service.processOnce()
                let reply = adapter.sentText(0)
                @Expect(reply.contains("dmPolicy: open"), true)
                @Expect(reply.contains("warning: dmPolicy=open allows any Feishu DM user"), true)
                @Expect(reply.contains("open-secret"), false)
            } finally {
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuDoctorDistinguishesOAuthOapiCardAndLiveResourceStates(): Unit {
        withGatewayFeishuNativeTestHome("doctor-oauth-oapi", gatewayFeishuNativeTestRoot(appSecret: "doctor-secret"), { =>
            setGatewayFeishuNativeAuthStatusRunnerForTest(Some({ accountId: String, _user: GatewayUserSettings =>
                let out = JsonObject()
                out.put("status", JsonString("pending"))
                out.put("accountId", JsonString(accountId))
                out.put("tokenStatus", JsonString("missing"))
                out.put("verificationUri", JsonString("https://verify.example/activate"))
                out.put("userCode", JsonString("ABCD-EFGH"))
                out.put("deviceCode", JsonString("device-secret"))
                out.put("diagnostic", JsonString("Authorization: Bearer access-secret"))
                out
            }))
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            service.start()
            try {
                adapter.queueDirect("/feishu doctor")
                service.processOnce()
                let reply = adapter.sentText(0)
                @Expect(adapter.sentCount(), 1)
                @Expect(reply.contains("credentials: configured"), true)
                @Expect(reply.contains("OAuth/user authorization: pending"), true)
                @Expect(reply.contains("OAPI: oauth_pending"), true)
                @Expect(reply.contains("CardKit/live cards: external-resource-required"), true)
                @Expect(reply.contains("live resource smoke: external-resource-required"), true)
                @Expect(reply.contains("device-secret"), false)
                @Expect(reply.contains("access-secret"), false)
                @Expect(reply.contains("doctor-secret"), false)
            } finally {
                service.stop()
                setGatewayFeishuNativeAuthStatusRunnerForTest(None<(String, GatewayUserSettings) -> JsonObject>)
            }
        })
    }

    @TestCase
    public func feishuNativeCommandsRenderLiveReadyReadinessWithoutSecrets(): Unit {
        let root = gatewayFeishuNativeBroadcastRoot()
        let gateway = root.get("gateway").getOrThrow().asObject()
        let feishu = gateway.get("feishu").getOrThrow().asObject()
        feishu.put("appSecret", JsonString("readiness-secret"))
        withGatewayFeishuNativeTestHome("native-readiness", root, { =>
            setGatewayFeishuNativeAuthStatusRunnerForTest(Some({ accountId: String, _user: GatewayUserSettings =>
                let out = JsonObject()
                out.put("status", JsonString("authorized"))
                out.put("accountId", JsonString(accountId))
                out.put("tokenStatus", JsonString("authorized"))
                out.put("scopeSummary", JsonString("offline_access im:message im:message.resource:read"))
                out.put("accessToken", JsonString("access-secret"))
                out
            }))
            setGatewayFeishuNativeAuthRunnerForTest(Some({ accountId: String, _user: GatewayUserSettings =>
                let out = JsonObject()
                out.put("status", JsonString("pending"))
                out.put("accountId", JsonString(accountId))
                out.put("verificationUri", JsonString("https://verify.example/activate"))
                out.put("userCode", JsonString("SAFE-CODE"))
                out.put("expiresInSeconds", JsonString("600"))
                out.put("intervalSeconds", JsonString("5"))
                out.put("scopeSummary", JsonString("offline_access im:message im:message.resource:read"))
                out.put("message", JsonString("Open the verification URL and enter the user code."))
                out.put("deviceCode", JsonString("device-secret"))
                out.put("refreshToken", JsonString("refresh-secret"))
                out
            }))
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            service.start()
            try {
                adapter.queueDirect("/feishu start")
                adapter.queueDirect("/feishu doctor")
                adapter.queueDirect("/feishu auth")
                service.processOnce()
                service.processOnce()
                service.processOnce()
                @Expect(adapter.sentCount(), 3)
                let start = adapter.sentText(0)
                let doctor = adapter.sentText(1)
                let auth = adapter.sentText(2)

                @Expect(start.contains("route: native-command peer=ou_peer chatType=direct account=default"), true)
                @Expect(start.contains("OAPI readiness: external-resource-required"), true)
                @Expect(start.contains("CardKit readiness: external-resource-required"), true)
                @Expect(start.contains("live resource readiness: external-resource-required"), true)
                @Expect(start.contains("AgentTeam readiness: ready bindings=1 agents=4"), true)

                @Expect(doctor.contains("route: native-command peer=ou_peer chatType=direct account=default"), true)
                @Expect(doctor.contains("OAPI readiness: external-resource-required"), true)
                @Expect(doctor.contains("CardKit readiness: external-resource-required"), true)
                @Expect(doctor.contains("live resource readiness: external-resource-required"), true)
                @Expect(doctor.contains("AgentTeam readiness: ready bindings=1 agents=4"), true)

                @Expect(auth.contains("route: native-command peer=ou_peer chatType=direct account=default"), true)
                @Expect(auth.contains("OAPI readiness: oauth_pending"), true)
                @Expect(auth.contains("CardKit readiness: external-resource-required"), true)
                @Expect(auth.contains("live resource readiness: external-resource-required"), true)
                @Expect(auth.contains("AgentTeam readiness: ready bindings=1 agents=4"), true)
                @Expect(auth.contains("verificationUrl: https://verify.example/activate"), true)
                @Expect(auth.contains("SAFE-CODE"), true)

                let all = start + "\n" + doctor + "\n" + auth
                @Expect(all.contains("access-secret"), false)
                @Expect(all.contains("device-secret"), false)
                @Expect(all.contains("refresh-secret"), false)
                @Expect(all.contains("readiness-secret"), false)
                @Expect(all.contains("Authorization"), false)
            } finally {
                service.stop()
                setGatewayFeishuNativeAuthStatusRunnerForTest(None<(String, GatewayUserSettings) -> JsonObject>)
                setGatewayFeishuNativeAuthRunnerForTest(None<(String, GatewayUserSettings) -> JsonObject>)
            }
        })
    }

    @TestCase
    public func feishuAuthCommandReturnsExplicitAuthorizationGuidance(): Unit {
        withGatewayFeishuNativeTestHome("auth", gatewayFeishuNativeTestRoot(), { =>
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            service.start()
            try {
                adapter.queueDirect("/feishu auth")
                service.processOnce()
                let reply = adapter.sentText(0)
                @Expect(adapter.sentCount(), 1)
                @Expect(reply.contains("Metis Feishu auth"), true)
                @Expect(reply.contains("OAuth/user authorization: not completed"), true)
            } finally {
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuAuthCommandRendersOnlySafeOAuthFields(): Unit {
        withGatewayFeishuNativeTestHome("auth-safe-fields", gatewayFeishuNativeTestRoot(appSecret: "auth-secret"), { =>
            setGatewayFeishuNativeAuthRunnerForTest(Some({ accountId: String, _user: GatewayUserSettings =>
                let out = JsonObject()
                out.put("status", JsonString("pending"))
                out.put("accountId", JsonString(accountId))
                out.put("verificationUri", JsonString("https://verify.example/activate"))
                out.put("userCode", JsonString("SAFE-CODE"))
                out.put("expiresInSeconds", JsonString("600"))
                out.put("intervalSeconds", JsonString("5"))
                out.put("tokenStatus", JsonString("missing"))
                out.put("scopeSummary", JsonString("offline_access im:message"))
                out.put("message", JsonString("Open the verification URL and enter the user code."))
                out.put("deviceCode", JsonString("device-secret"))
                out.put("accessToken", JsonString("access-secret"))
                out.put("refreshToken", JsonString("refresh-secret"))
                out.put("Authorization", JsonString("Bearer bearer-secret"))
                out
            }))
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            service.start()
            try {
                adapter.queueDirect("/feishu auth")
                service.processOnce()
                let reply = adapter.sentText(0)
                @Expect(adapter.sentCount(), 1)
                @Expect(reply.contains("OAuth/user authorization: pending"), true)
                @Expect(reply.contains("verificationUrl: https://verify.example/activate"), true)
                @Expect(reply.contains("userCode: SAFE-CODE"), true)
                @Expect(reply.contains("expiresInSeconds: 600"), true)
                @Expect(reply.contains("intervalSeconds: 5"), true)
                @Expect(reply.contains("scopes: offline_access im:message"), true)
                @Expect(reply.contains("device-secret"), false)
                @Expect(reply.contains("access-secret"), false)
                @Expect(reply.contains("refresh-secret"), false)
                @Expect(reply.contains("bearer-secret"), false)
                @Expect(reply.contains("auth-secret"), false)
            } finally {
                service.stop()
                setGatewayFeishuNativeAuthRunnerForTest(None<(String, GatewayUserSettings) -> JsonObject>)
            }
        })
    }

    @TestCase
    public func feishuAuthCommandUsesDefaultAccountCredentialOverrides(): Unit {
        let root = gatewayFeishuNativeTestRoot(appSecret: "top-secret-never-visible")
        let gateway = root.get("gateway").getOrThrow().asObject()
        let feishu = gateway.get("feishu").getOrThrow().asObject()
        feishu.put("defaultAccount", JsonString("tenant-a"))
        feishu.put("appId", JsonString(""))
        let accounts = JsonObject()
        let tenant = JsonObject()
        tenant.put("appId", JsonString("tenant-app"))
        accounts.put("tenant-a", tenant)
        feishu.put("accounts", accounts)

        withGatewayFeishuNativeTestHome("auth-account-override", root, { =>
            let adapter = GatewayFeishuNativeTestAdapter(accountId: "tenant-a")
            let service = gatewayFeishuNativeService(adapter, accountId: "tenant-a")
            service.start()
            try {
                adapter.queueDirect("/feishu auth")
                service.processOnce()
                let reply = adapter.sentText(0)
                @Expect(adapter.sentCount(), 1)
                @Expect(reply.contains("accountId: tenant-a"), true)
                @Expect(reply.contains("app credentials: configured"), true)
                @Expect(reply.contains("authStatus: not_configured"), true)
                @Expect(reply.contains("tenant-app"), false)
                @Expect(reply.contains("top-secret-never-visible"), false)
            } finally {
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuAuthCommandUsesInjectedDeviceFlowWithoutLeakingSecrets(): Unit {
        withGatewayFeishuNativeTestHome("auth-flow", gatewayFeishuNativeTestRoot(appSecret: "native-secret"), { =>
            setGatewayFeishuNativeAuthRunnerForTest(Some({ accountId: String, _user: GatewayUserSettings =>
                let out = JsonObject()
                out.put("status", JsonString("pending"))
                out.put("accountId", JsonString(accountId))
                out.put("verificationUri", JsonString("https://verify.example/activate"))
                out.put("userCode", JsonString("ABCD-EFGH"))
                out.put("expiresInSeconds", JsonString("600"))
                out.put("tokenStatus", JsonString("missing"))
                out.put("scopeSummary", JsonString("offline_access im:message"))
                out.put("accessToken", JsonString("must-not-render"))
                out
            }))
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            service.start()
            try {
                adapter.queueDirect("/feishu auth")
                service.processOnce()
                let reply = adapter.sentText(0)
                @Expect(adapter.sentCount(), 1)
                @Expect(reply.contains("Metis Feishu auth"), true)
                @Expect(reply.contains("OAuth/user authorization: pending"), true)
                @Expect(reply.contains("storedToken: missing"), true)
                @Expect(reply.contains("https://verify.example/activate"), true)
                @Expect(reply.contains("ABCD-EFGH"), true)
                @Expect(reply.contains("offline_access im:message"), true)
                @Expect(reply.contains("native-secret"), false)
                @Expect(reply.contains("must-not-render"), false)
            } finally {
                service.stop()
                setGatewayFeishuNativeAuthRunnerForTest(None<(String, GatewayUserSettings) -> JsonObject>)
            }
        })
    }

    @TestCase
    public func feishuAckLifecycleAddsReplyAndRemovesTypingReaction(): Unit {
        withGatewayFeishuNativeTestHome("ack-lifecycle", gatewayFeishuNativeAckRoot(true), { =>
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            setGatewayAgentBridgeReplyRunnerForTest(Some({
                _sessionKey: String,
                _prompt: String,
                _channelName: String,
                _agentId: String,
                _streamingEnabled: Bool,
                _streamChunkHook: Option<(String) -> Unit> =>
                    "feishu final answer"
            }))
            service.start()
            try {
                adapter.queueDirect("hello")
                service.processOnce()

                @Expect(adapter.sentCount(), 3)
                @Expect(adapter.sentText(0), "[reaction]\ntoken=Typing\nrender=Typing")
                @Expect(adapter.sentReplyTo(0), "om-0")
                @Expect(adapter.sentText(1), "feishu final answer")
                @Expect(adapter.sentText(2), "[reaction]\nremove=true\ntoken=Typing\nrender=Typing")
                @Expect(adapter.sentReplyTo(2), "om-0")
            } finally {
                service.stop()
                setGatewayAgentBridgeReplyRunnerForTest(None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>)
            }
        })
    }

    @TestCase
    public func feishuAckLifecycleKeepsReactionWhenRemovalDisabled(): Unit {
        withGatewayFeishuNativeTestHome("ack-no-remove", gatewayFeishuNativeAckRoot(true, removeAfterReply: false), { =>
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            setGatewayAgentBridgeReplyRunnerForTest(Some({
                _sessionKey: String,
                _prompt: String,
                _channelName: String,
                _agentId: String,
                _streamingEnabled: Bool,
                _streamChunkHook: Option<(String) -> Unit> =>
                    "feishu final answer"
            }))
            service.start()
            try {
                adapter.queueDirect("hello")
                service.processOnce()

                @Expect(adapter.sentCount(), 2)
                @Expect(adapter.sentText(0), "[reaction]\ntoken=Typing\nrender=Typing")
                @Expect(adapter.sentText(1), "feishu final answer")
            } finally {
                service.stop()
                setGatewayAgentBridgeReplyRunnerForTest(None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>)
            }
        })
    }

    @TestCase
    public func feishuNativeCommandDoesNotEmitAckReaction(): Unit {
        withGatewayFeishuNativeTestHome("ack-command", gatewayFeishuNativeAckRoot(true), { =>
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            service.start()
            try {
                adapter.queueDirect("/feishu doctor")
                service.processOnce()

                @Expect(adapter.sentCount(), 1)
                @Expect(adapter.sentText(0).contains("[reaction]"), false)
                @Expect(adapter.sentText(0).contains("Metis Feishu doctor"), true)
            } finally {
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuAckLifecycleUsesGuardedFinalAnswerFromTerminalToolEnvelope(): Unit {
        withGatewayFeishuNativeTestHome("ack-final-guard", gatewayFeishuNativeAckRoot(true), { =>
            let modelName = "metis-test-feishu-final-guard-${DateTime.now().toUnixTimeStamp().toMilliseconds()}"
            ModelManager.registerChatModel(modelName, { =>
                GatewayFeishuNativeFakeModel(answer: "{\"tool\":\"final_answer\",\"answer\":\"guarded feishu answer\"}")
            })
            var user = CliSettingManager.readGatewaySettings()
            user.channelModels["feishu"] = modelName
            CliSettingManager.writeGatewaySettings(user)
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            service.start()
            try {
                adapter.queueDirect("hello")
                service.processOnce()

                @Expect(adapter.sentCount(), 3)
                @Expect(adapter.sentText(0), "[reaction]\ntoken=Typing\nrender=Typing")
                @Expect(adapter.sentText(1), "guarded feishu answer")
                @Expect(adapter.sentText(1).contains("final_answer"), false)
                @Expect(adapter.sentText(1).contains("\"tool\""), false)
                @Expect(adapter.sentText(2), "[reaction]\nremove=true\ntoken=Typing\nrender=Typing")
            } finally {
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuAgentTeamBroadcastExecutesSelectedMembersOnly(): Unit {
        withGatewayFeishuNativeTestHome("broadcast", gatewayFeishuNativeBroadcastRoot(), { =>
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            let capturedAgents = ArrayList<String>()
            setGatewayAgentBridgeReplyRunnerForTest(Some({
                _sessionKey: String,
                _prompt: String,
                _channelName: String,
                agentId: String,
                _streamingEnabled: Bool,
                _streamChunkHook: Option<(String) -> Unit> =>
                    capturedAgents.add(agentId)
                    "reply:${agentId}"
            }))
            service.start()
            try {
                adapter.queueDirectWithRoute("hello team", gatewayFeishuNativeBroadcastMediaContext())
                service.processOnce()
                @Expect(adapter.sentCount(), 2)
                @Expect(capturedAgents.size, 2)
                @Expect(capturedAgents.contains("writer"), true)
                @Expect(capturedAgents.contains("reviewer"), true)
                @Expect(capturedAgents.contains("ops"), false)
                @Expect(adapter.sentText(0).contains("reply:"), true)
                @Expect(adapter.sentText(1).contains("reply:"), true)
            } finally {
                service.stop()
                setGatewayAgentBridgeReplyRunnerForTest(None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>)
            }
        })
    }
}
