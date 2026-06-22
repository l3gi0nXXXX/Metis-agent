package metis.gateway.channels.feishu

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.core.{GatewayRouter, GatewayService, setGatewayAgentBridgeReplyRunnerForTest}
import metis.gateway.model.{ChannelPolicyConfig, FeishuConfig}
import magic.core.message.Message
import magic.core.model.{AsyncChatResponse, ChatModel, ChatRequest, ChatResponse}
import magic.model.ModelManager
import std.collection.{ArrayList, HashMap}
import std.env.setVariable
import std.fs.{Directory, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString}

private const FEISHU_BOT_E2E_ACCOUNT = "tenant-a"
private const FEISHU_BOT_E2E_CHAT = "oc_test_chat"

private class FeishuBotE2eLongConnectTransport <: FeishuLongConnectTransport {
    private let events: ArrayList<JsonObject>
    public var startCount: Int64 = 0
    public var stopCount: Int64 = 0
    public var lastSpec = FeishuLongConnectStartSpec()

    public init(events!: Array<JsonObject> = []) {
        this.events = ArrayList<JsonObject>()
        for (event in events) {
            this.events.add(event)
        }
    }

    public func start(spec: FeishuLongConnectStartSpec, eventHandler: (JsonObject) -> Unit): FeishuLongConnectStartResult {
        this.startCount += 1
        this.lastSpec = spec
        for (event in this.events) {
            eventHandler(event)
        }
        FeishuLongConnectStartResult(ok: true, status: "ready")
    }

    public func stop(): Unit {
        this.stopCount += 1
    }
}

private func feishuBotE2eTempHome(name: String): Path {
    CliConfig.cwd.join("target").join("tmp").join(name)
}

private func withFeishuBotE2eHome(name: String, body: () -> Unit): Unit {
    synchronized(MetisProcessEnvironmentLock) {
        let home = feishuBotE2eTempHome(name)
        try { remove(home, recursive: true) } catch (_e: Exception) { () }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home.toString())
        CliConfig.invalidatePathCache()
        CliSettingManager.invalidate()
        MetisConfigManager.invalidate()
        MetisConfigManager.writeRoot(feishuBotE2eRoot())
        try {
            body()
        } finally {
            setGatewayAgentBridgeReplyRunnerForTest(None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>)
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            CliConfig.invalidatePathCache()
            setVariable("METIS_HOME", "")
            try { remove(home, recursive: true) } catch (_e: Exception) { () }
        }
    }
}

private func feishuBotE2eRoot(): JsonObject {
    feishuBotE2eRootWithModel("fake:main", [])
}

private func feishuBotE2eRootWithModel(primary: String, fallbacks: Array<String>): JsonObject {
    let root = JsonObject()
    let gateway = JsonObject()
    let feishu = JsonObject()
    feishu.put("enabled", JsonBool(true))
    feishu.put("defaultAccount", JsonString(FEISHU_BOT_E2E_ACCOUNT))
    feishu.put("receiveMode", JsonString("long_connect"))
    feishu.put("transportMode", JsonString("sidecar"))
    feishu.put("appId", JsonString("cli_test_app"))
    feishu.put("appSecret", JsonString("secret-never-visible"))
    feishu.put("groupPolicy", JsonString("allowlist"))
    let allow = JsonArray()
    allow.add(JsonString(FEISHU_BOT_E2E_CHAT))
    feishu.put("groupAllowFrom", allow)
    feishu.put("requireMention", JsonBool(false))
    feishu.put("streaming", JsonString("text"))
    gateway.put("feishu", feishu)
    root.put("gateway", gateway)

    let agents = JsonObject()
    let list = JsonArray()
    let agent = JsonObject()
    agent.put("id", JsonString("main"))
    agent.put("default", JsonBool(true))
    let model = JsonObject()
    model.put("primary", JsonString(primary))
    let fallbackItems = JsonArray()
    for (fallback in fallbacks) {
        fallbackItems.add(JsonString(fallback))
    }
    model.put("fallbacks", fallbackItems)
    agent.put("model", model)
    list.add(agent)
    agents.put("list", list)
    root.put("agents", agents)
    root
}

private func feishuBotE2eWriteModelRoot(primary: String, fallbacks: Array<String>): Unit {
    MetisConfigManager.writeRoot(feishuBotE2eRootWithModel(primary, fallbacks))
    CliConfig.invalidatePathCache()
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
}

private class FeishuBotE2eEmptyResponseModel <: ChatModel {
    private let modelName: String
    private var _maxTokens: Option<Int64> = None

    public init(modelName: String) {
        this.modelName = modelName
    }

    public prop provider: String {
        get() { "fake" }
    }

    public prop name: String {
        get() { this.modelName }
    }

    public prop contextLength: Int64 {
        get() { 8192 }
    }

    public mut prop maxTokens: Option<Int64> {
        get() { this._maxTokens }
        set(v) { this._maxTokens = v }
    }

    public func create(_request: ChatRequest): ChatResponse {
        throw Exception("Http response body is empty")
    }

    public func asyncCreate(_request: ChatRequest): AsyncChatResponse {
        throw Exception("async not used in feishu bot e2e tests")
    }
}

private class FeishuBotE2eAnswerModel <: ChatModel {
    private let modelName: String
    private let answer: String
    private var _maxTokens: Option<Int64> = None

    public init(modelName: String, answer: String) {
        this.modelName = modelName
        this.answer = answer
    }

    public prop provider: String {
        get() { "fake" }
    }

    public prop name: String {
        get() { this.modelName }
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
        throw Exception("async not used in feishu bot e2e tests")
    }
}

private func feishuBotE2eService(adapter: FeishuAdapter): GatewayService {
    let policies = HashMap<String, ChannelPolicyConfig>()
    policies["feishu"] = ChannelPolicyConfig(enableDirect: true, enableGroup: true, requireMentionInGroup: false)
    let router = GatewayRouter(policies)
    let service = GatewayService(router)
    service.registerAdapter(adapter, channelId: "feishu", accountId: FEISHU_BOT_E2E_ACCOUNT)
    service
}

private func feishuBotE2eConfig(groupPolicy!: String = "allowlist"): FeishuConfig {
    FeishuConfig(
        enabled: true,
        appId: "cli_test_app",
        appSecret: "secret-never-visible",
        receiveMode: "long_connect",
        transportMode: "sidecar",
        groupPolicy: groupPolicy,
        groupAllowFrom: [FEISHU_BOT_E2E_CHAT],
        requireMention: false,
        streaming: "text"
    )
}

private func feishuBotE2eTextEvent(messageId: String, text: String, chatId!: String = FEISHU_BOT_E2E_CHAT): JsonObject {
    let root = JsonObject()
    let header = JsonObject()
    header.put("event_type", JsonString("im.message.receive_v1"))
    header.put("account_id", JsonString(FEISHU_BOT_E2E_ACCOUNT))
    root.put("header", header)

    let event = JsonObject()
    let sender = JsonObject()
    let senderId = JsonObject()
    senderId.put("open_id", JsonString("ou_test_sender"))
    sender.put("sender_id", senderId)
    event.put("sender", sender)

    let message = JsonObject()
    message.put("message_id", JsonString(messageId))
    message.put("chat_id", JsonString(chatId))
    message.put("chat_type", JsonString("group"))
    message.put("message_type", JsonString("text"))
    message.put("content", JsonString("{\"text\":\"${text}\"}"))
    event.put("message", message)
    root.put("event", event)
    root
}

private func feishuBotE2eString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) =>
            match (value) {
                case v: JsonString => v.getValue()
                case _ => ""
            }
        case None => ""
    }
}

private func feishuBotE2eBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(value) =>
            match (value) {
                case v: JsonBool => v.getValue()
                case _ => false
            }
        case None => false
    }
}

@Test
public func sidecarTextInboundReachesGatewaySessionAndFeishuReplySend(): Unit {
    withFeishuBotE2eHome("feishu_bot_e2e_text_reply", { =>
        let prompts = ArrayList<String>()
        setGatewayAgentBridgeReplyRunnerForTest(Some({
            _sessionKey: String, prompt: String, channelName: String, agentId: String, _streamingEnabled: Bool, _streamChunkHook: Option<(String) -> Unit> =>
                prompts.add("${channelName}:${agentId}:${prompt}")
                "reply-for-${prompt}"
        }))

        let apiClient = FeishuFakeApiClient()
        let transport = FeishuBotE2eLongConnectTransport(events: [feishuBotE2eTextEvent("om_test_1", "12345")])
        let adapter = FeishuAdapter(
            config: feishuBotE2eConfig(),
            accountId: FEISHU_BOT_E2E_ACCOUNT,
            apiClient: apiClient,
            longConnectTransport: transport
        )
        let service = feishuBotE2eService(adapter)

        service.start()
        service.processOnce()
        service.stop()

        @Expect(transport.startCount == 1)
        @Expect(prompts.size == 1)
        @Expect(prompts[0].contains("feishu:main:12345"))
        @Expect(apiClient.textSendCount() == 1)
        let request = apiClient.lastTextMessageRequest()
        @Expect(feishuBotE2eString(request, "accountId") == FEISHU_BOT_E2E_ACCOUNT)
        @Expect(feishuBotE2eString(request, "receiveId") == FEISHU_BOT_E2E_CHAT)
        @Expect(feishuBotE2eString(request, "receiveIdType") == "chat_id")
        @Expect(feishuBotE2eString(request, "text").contains("reply-for-12345"))
        @Expect(feishuBotE2eString(request, "replyToMessageId") == "om_test_1")
        @Expect(!feishuBotE2eBool(request, "replyInThread"))
    })
}

@Test
public func duplicateSidecarInboundDoesNotSendDuplicateReply(): Unit {
    withFeishuBotE2eHome("feishu_bot_e2e_dedup", { =>
        let agentRuns = ArrayList<String>()
        setGatewayAgentBridgeReplyRunnerForTest(Some({
            _sessionKey: String, prompt: String, _channelName: String, _agentId: String, _streamingEnabled: Bool, _streamChunkHook: Option<(String) -> Unit> =>
                agentRuns.add("run")
                "dedup-reply-${prompt}"
        }))

        let event = feishuBotE2eTextEvent("om_same", "hello")
        let apiClient = FeishuFakeApiClient()
        let transport = FeishuBotE2eLongConnectTransport(events: [event, event])
        let adapter = FeishuAdapter(
            config: feishuBotE2eConfig(),
            accountId: FEISHU_BOT_E2E_ACCOUNT,
            apiClient: apiClient,
            longConnectTransport: transport
        )
        let service = feishuBotE2eService(adapter)

        service.start()
        service.processOnce()
        service.stop()

        @Expect(agentRuns.size == 1)
        @Expect(apiClient.textSendCount() == 1)
    })
}

@Test
public func groupGateBlocksAgentAndSendWhenChatIsNotAllowed(): Unit {
    withFeishuBotE2eHome("feishu_bot_e2e_gate_block", { =>
        let agentRuns = ArrayList<String>()
        setGatewayAgentBridgeReplyRunnerForTest(Some({
            _sessionKey: String, _prompt: String, _channelName: String, _agentId: String, _streamingEnabled: Bool, _streamChunkHook: Option<(String) -> Unit> =>
                agentRuns.add("run")
                "blocked"
        }))

        let apiClient = FeishuFakeApiClient()
        let transport = FeishuBotE2eLongConnectTransport(
            events: [feishuBotE2eTextEvent("om_blocked", "blocked", chatId: "oc_not_allowed")]
        )
        let adapter = FeishuAdapter(
            config: feishuBotE2eConfig(),
            accountId: FEISHU_BOT_E2E_ACCOUNT,
            apiClient: apiClient,
            longConnectTransport: transport
        )
        let service = feishuBotE2eService(adapter)

        service.start()
        service.processOnce()
        service.stop()

        @Expect(agentRuns.size == 0)
        @Expect(apiClient.textSendCount() == 0)
    })
}

@Test
public func sidecarTextInboundEmptyModelResponseUsesFallbackAndRepliesCronDeliveryChannel(): Unit {
    withFeishuBotE2eHome("feishu_bot_e2e_empty_model_fallback", { =>
        let suffix = DateTime.now().toUnixTimeStamp().toMilliseconds().toString()
        let primaryName = "phase4-empty-primary-${suffix}"
        let fallbackName = "phase4-cron-fallback-${suffix}"
        let primaryRef = "fake:${primaryName}"
        let fallbackRef = "fake:${fallbackName}"
        ModelManager.registerChatModel(primaryRef, { => FeishuBotE2eEmptyResponseModel(primaryName) })
        ModelManager.registerChatModel(fallbackRef, { =>
            FeishuBotE2eAnswerModel(
                fallbackName,
                "每日国际新闻与华为影响简报 的投递通道是 telegram，目标是 1059872384。"
            )
        })
        feishuBotE2eWriteModelRoot(primaryRef, [fallbackRef])

        let apiClient = FeishuFakeApiClient()
        let transport = FeishuBotE2eLongConnectTransport(
            events: [feishuBotE2eTextEvent("om_cron_channel", "这个定时任务的投递通道是什么")]
        )
        let adapter = FeishuAdapter(
            config: feishuBotE2eConfig(),
            accountId: FEISHU_BOT_E2E_ACCOUNT,
            apiClient: apiClient,
            longConnectTransport: transport
        )
        let service = feishuBotE2eService(adapter)

        service.start()
        try {
            service.processOnce()
        } finally {
            service.stop()
        }

        @Expect(apiClient.textSendCount() == 1)
        let request = apiClient.lastTextMessageRequest()
        let text = feishuBotE2eString(request, "text")
        @Expect(text.contains("telegram"))
        @Expect(text.contains("1059872384"))
        @Expect(text.contains("模型服务本轮"), false)
        @Expect(feishuBotE2eString(request, "replyToMessageId") == "om_cron_channel")
    })
}

@Test
public func sidecarTextInboundEmptyModelResponseWithoutFallbackSendsVisibleDiagnostic(): Unit {
    withFeishuBotE2eHome("feishu_bot_e2e_empty_model_diagnostic", { =>
        let suffix = DateTime.now().toUnixTimeStamp().toMilliseconds().toString()
        let primaryName = "phase4-empty-only-${suffix}"
        let primaryRef = "fake:${primaryName}"
        ModelManager.registerChatModel(primaryRef, { => FeishuBotE2eEmptyResponseModel(primaryName) })
        feishuBotE2eWriteModelRoot(primaryRef, [])

        let apiClient = FeishuFakeApiClient()
        let transport = FeishuBotE2eLongConnectTransport(
            events: [feishuBotE2eTextEvent("om_empty_diag", "这个定时任务的投递通道是什么")]
        )
        let adapter = FeishuAdapter(
            config: feishuBotE2eConfig(),
            accountId: FEISHU_BOT_E2E_ACCOUNT,
            apiClient: apiClient,
            longConnectTransport: transport
        )
        let service = feishuBotE2eService(adapter)

        service.start()
        try {
            service.processOnce()
        } finally {
            service.stop()
        }

        @Expect(apiClient.textSendCount() == 1)
        let request = apiClient.lastTextMessageRequest()
        let text = feishuBotE2eString(request, "text")
        @Expect(text, "模型服务本轮返回空响应，未能完成回复。请稍后重试或切换模型。")
        @Expect(feishuBotE2eString(request, "replyToMessageId") == "om_empty_diag")
    })
}
