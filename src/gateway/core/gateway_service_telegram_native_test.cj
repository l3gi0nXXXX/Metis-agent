package metis.gateway.core

import metis.core.config.{CliSettingManager, GatewayUserSettings, MetisConfigManager}
import metis.gateway.model.{ChannelPolicyConfig, ChannelType, ChatType, InboundMessage, OutboundMessage, SendResult}

import magic.jsonable.*

import std.collection.{ArrayList, HashMap}
import std.env.setVariable
import std.fs.{Directory, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}

private class GatewayTelegramNativeTestAdapter <: ChannelAdapter {
    private let inbound = ArrayList<InboundMessage>()
    private let sent = ArrayList<OutboundMessage>()

    public prop name: String {
        get() { "telegram" }
    }

    public func start(): Unit {}

    public func stop(): Unit {}

    public func queue(text: String, sender!: String = "8734062810"): Unit {
        this.inbound.add(InboundMessage(
            ChannelType.Telegram,
            "msg-${this.inbound.size}",
            "8734062810",
            sender,
            ChatType.Direct,
            text,
            false,
            DateTime.now()
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
        "test-message-${this.sent.size}"
    }

    public func sentText(index: Int64): String {
        match (this.sent.get(index)) {
            case Some(v) => v.text
            case None => ""
        }
    }
}

private class GatewayTelegramSidecarMethodRecorder {
    private let methods = ArrayList<String>()

    public func add(method: String): Unit {
        this.methods.add(method)
    }

    public func count(method: String): Int64 {
        var out: Int64 = 0
        for (value in this.methods.toArray()) {
            if (value == method) {
                out += 1
            }
        }
        out
    }
}

private func gatewayTelegramNativeTestConfigRoot(): JsonObject {
    let root = JsonObject()
    let agents = JsonObject()
    let defaults = JsonObject()
    defaults.put("workspace", JsonString(""))
    agents.put("defaults", defaults)
    root.put("agents", agents)
    root.put("gateway", JsonObject())
    root.put("session", JsonObject())
    root.put("skills", JsonObject())
    root.put("tools", JsonObject())
    root.put("models", JsonObject())
    root.put("auth", JsonObject())
    root.put("channels", JsonObject())
    root.put("plugins", JsonObject())
    root.put("wizard", JsonObject())
    root.put("meta", JsonObject())
    root
}

private func withGatewayTelegramNativeTestHome<T>(block: () -> T): T {
    let testHome = "/tmp/metis-gateway-telegram-native-test-home"
    try { remove(Path(testHome), recursive: true) } catch (_: Exception) { () }
    Directory.create(testHome, recursive: true)
    setVariable("METIS_HOME", testHome)
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
    MetisConfigManager.writeRoot(gatewayTelegramNativeTestConfigRoot())
    CliSettingManager.applyPersistedFieldsToCliConfig()
    try {
        return block()
    } finally {
        setGatewayOpenClawPluginSidecarRunnerForTest(None)
        try { remove(Path(testHome), recursive: true) } catch (_: Exception) { () }
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
    }
}

private func gatewayTelegramNativeService(adapter: GatewayTelegramNativeTestAdapter): GatewayService {
    let policies = HashMap<String, ChannelPolicyConfig>()
    policies["telegram"] = ChannelPolicyConfig(enableDirect: true, allowFrom: ["*"])
    let service = GatewayService(GatewayRouter(policies))
    service.registerAdapter(adapter, channelId: "telegram", accountId: "default")
    service
}

@Test
public class GatewayServiceTelegramNativeTest {
    @TestCase
    public func modelsCommandReturnsTelegramInlineButtonsThroughGatewayService(): Unit {
        withGatewayTelegramNativeTestHome {
            var user = GatewayUserSettings()
            user.telegram.enabled = true
            user.telegram.allowFrom = ["8734062810"]
            user.telegram.actions.inlineKeyboard = true
            user.telegram.actions.callbackQuery = true
            CliSettingManager.writeGatewaySettings(user)

            let adapter = GatewayTelegramNativeTestAdapter()
            let service = gatewayTelegramNativeService(adapter)
            service.start()
            adapter.queue("/models")
            service.processOnce()

            let text = adapter.sentText(0)
            @Expect(text.contains("[inline-keyboard]"), true)
            @Expect(text.contains("callback:models:set:"), true)
            @Expect(text.contains("Telegram model"), true)
            @Expect(text.contains("Page:"), true)
        }
    }

    @TestCase
    public func modelsPageCallbackReturnsModelPageWithoutMutatingConfig(): Unit {
        withGatewayTelegramNativeTestHome {
            var user = GatewayUserSettings()
            user.telegram.enabled = true
            user.telegram.allowFrom = ["8734062810"]
            user.telegram.actions.inlineKeyboard = true
            user.telegram.actions.callbackQuery = true
            CliSettingManager.writeGatewaySettings(user)

            let adapter = GatewayTelegramNativeTestAdapter()
            let service = gatewayTelegramNativeService(adapter)
            service.start()
            adapter.queue("[telegram-callback]\nid=cb-page\nmessageId=1\ndata=models:page:1\nby=8734062810")
            service.processOnce()

            let text = adapter.sentText(0)
            @Expect(text.contains("[inline-keyboard]"), true)
            @Expect(text.contains("callback:models:set:"), true)
            @Expect(text.contains("Telegram model"), true)
            let updated = CliSettingManager.readGatewaySettings()
            @Expect(updated.channelModels.get("telegram") ?? "", "")
        }
    }

    @TestCase
    public func modelCallbackPersistsTelegramSessionModelForAuthorizedSender(): Unit {
        withGatewayTelegramNativeTestHome {
            var user = GatewayUserSettings()
            user.telegram.enabled = true
            user.telegram.allowFrom = ["tg:8734062810"]
            CliSettingManager.writeGatewaySettings(user)

            let adapter = GatewayTelegramNativeTestAdapter()
            let service = gatewayTelegramNativeService(adapter)
            service.start()
            adapter.queue("[telegram-callback]\nid=cb-1\nmessageId=1\ndata=models:set:qwen:qwen3.5-plus\nby=8734062810")
            service.processOnce()

            @Expect(adapter.sentText(0).contains("Telegram session model switched to qwen:qwen3.5-plus"), true)
            let updated = CliSettingManager.readGatewaySettings()
            @Expect(updated.channelModels.get("telegram") ?? "", "")
            @Expect(updated.channelModels.get("telegram:telegram:direct:8734062810") ?? "", "qwen:qwen3.5-plus")
        }
    }

    @TestCase
    public func modelCallbackRejectsUnauthorizedSenderBeforeMutation(): Unit {
        withGatewayTelegramNativeTestHome {
            var user = GatewayUserSettings()
            user.telegram.enabled = true
            user.telegram.allowFrom = ["tg:8734062810"]
            CliSettingManager.writeGatewaySettings(user)

            let adapter = GatewayTelegramNativeTestAdapter()
            let service = gatewayTelegramNativeService(adapter)
            service.start()
            adapter.queue("[telegram-callback]\nid=cb-2\nmessageId=1\ndata=models:set:openai:gpt-5.4\nby=123", sender: "123")
            service.processOnce()

            @Expect(adapter.sentText(0).contains("Model switch denied"), true)
            let updated = CliSettingManager.readGatewaySettings()
            @Expect(updated.channelModels.get("telegram") ?? "", "")
        }
    }

    @TestCase
    public func unknownTelegramCallbackIsHandledNativelyWithoutModelPath(): Unit {
        withGatewayTelegramNativeTestHome {
            var user = GatewayUserSettings()
            user.telegram.enabled = true
            user.telegram.allowFrom = ["*"]
            user.telegram.actions.callbackQuery = true
            CliSettingManager.writeGatewaySettings(user)

            let adapter = GatewayTelegramNativeTestAdapter()
            let service = gatewayTelegramNativeService(adapter)
            service.start()
            adapter.queue("[telegram-callback]\nid=cb-unknown\nmessageId=1\nactionType=unknown\ndata=unknown:action\nby=8734062810")
            service.processOnce()

            let text = adapter.sentText(0)
            @Expect(text.contains("\"action\":\"telegram_callback\""), true)
            @Expect(text.contains("\"reason\":\"unknown callback action\""), true)
        }
    }

    @TestCase
    public func pluginTelegramCallbackReportsNativeNotApplicable(): Unit {
        withGatewayTelegramNativeTestHome {
            var user = GatewayUserSettings()
            user.telegram.enabled = true
            user.telegram.allowFrom = ["*"]
            user.telegram.actions.callbackQuery = true
            CliSettingManager.writeGatewaySettings(user)

            let adapter = GatewayTelegramNativeTestAdapter()
            let service = gatewayTelegramNativeService(adapter)
            service.start()
            adapter.queue("[telegram-callback]\nid=cb-plugin\nmessageId=1\nactionType=plugin-not-applicable\ndata=plugin:demo:run\nby=8734062810")
            service.processOnce()

            let text = adapter.sentText(0)
            @Expect(text.contains("\"status\":\"not_applicable\""), true)
            @Expect(text.contains("OpenClaw plugin compatibility sidecar is disabled"), true)
        }
    }

    @TestCase
    public func pluginTelegramCallbackDispatchesThroughOpenClawSidecarBridge(): Unit {
        withGatewayTelegramNativeTestHome {
            var user = GatewayUserSettings()
            user.telegram.enabled = true
            user.telegram.allowFrom = ["*"]
            user.telegram.actions.callbackQuery = true
            CliSettingManager.writeGatewaySettings(user)
            let recorder = GatewayTelegramSidecarMethodRecorder()
            setGatewayOpenClawPluginSidecarRunnerForTest(Some({ method: String, payload: JsonObject =>
                recorder.add(method)
                let out = JsonObject()
                out.put("ok", true.toJsonValue())
                out.put("matched", (method == "interactive.dispatch").toJsonValue())
                if (method == "interactive.dispatch") {
                    @Expect(payload.get("data").getOrThrow().asString().getValue(), "plugin:demo:run")
                    let intents = JsonArray([])
                    let reply = JsonObject()
                    reply.put("type", JsonString("reply"))
                    reply.put("text", JsonString("plugin handled"))
                    intents.add(reply)
                    out.put("intents", intents)
                }
                if (method == "hook.message_sending") {
                    out.put("cancelled", false.toJsonValue())
                    out.put("text", payload.get("text").getOrThrow())
                }
                out
            }))

            let adapter = GatewayTelegramNativeTestAdapter()
            let service = gatewayTelegramNativeService(adapter)
            service.start()
            adapter.queue("[telegram-callback]\nid=cb-plugin\nmessageId=77\nactionType=plugin-not-applicable\ndata=plugin:demo:run\nby=8734062810")
            service.processOnce()

            @Expect(adapter.sentText(0), "plugin handled")
        }
    }

    @TestCase
    public func pluginCallbackWithEnabledSidecarAndNoHandlerReportsNotFound(): Unit {
        withGatewayTelegramNativeTestHome {
            var user = GatewayUserSettings()
            user.telegram.enabled = true
            user.telegram.allowFrom = ["*"]
            user.telegram.actions.callbackQuery = true
            CliSettingManager.writeGatewaySettings(user)
            setGatewayOpenClawPluginSidecarRunnerForTest(Some({ method: String, _payload: JsonObject =>
                let out = JsonObject()
                out.put("ok", true.toJsonValue())
                out.put("matched", false.toJsonValue())
                if (method == "interactive.dispatch") {
                    out.put("reason", JsonString("handler_not_found"))
                }
                out
            }))

            let adapter = GatewayTelegramNativeTestAdapter()
            let service = gatewayTelegramNativeService(adapter)
            service.start()
            adapter.queue("[telegram-callback]\nid=cb-missing\nmessageId=77\nactionType=plugin-not-applicable\ndata=plugin:missing:run\nby=8734062810")
            service.processOnce()

            @Expect(adapter.sentText(0).contains("\"status\":\"not_found\""), true)
            @Expect(adapter.sentText(0).contains("handler_not_found"), true)
        }
    }

    @TestCase
    public func duplicatePluginTelegramCallbackDoesNotRunSidecarTwice(): Unit {
        withGatewayTelegramNativeTestHome {
            var user = GatewayUserSettings()
            user.telegram.enabled = true
            user.telegram.allowFrom = ["*"]
            user.telegram.actions.callbackQuery = true
            CliSettingManager.writeGatewaySettings(user)
            let recorder = GatewayTelegramSidecarMethodRecorder()
            setGatewayOpenClawPluginSidecarRunnerForTest(Some({ method: String, payload: JsonObject =>
                recorder.add(method)
                let out = JsonObject()
                out.put("ok", true.toJsonValue())
                out.put("matched", (method == "interactive.dispatch").toJsonValue())
                if (method == "interactive.dispatch") {
                    let intents = JsonArray([])
                    let reply = JsonObject()
                    reply.put("type", JsonString("reply"))
                    reply.put("text", JsonString("plugin handled"))
                    intents.add(reply)
                    out.put("intents", intents)
                }
                if (method == "hook.message_sending") {
                    out.put("cancelled", false.toJsonValue())
                    out.put("text", payload.get("text").getOrThrow())
                }
                out
            }))

            let adapter = GatewayTelegramNativeTestAdapter()
            let service = gatewayTelegramNativeService(adapter)
            service.start()
            adapter.queue("[telegram-callback]\nid=cb-dup\nmessageId=77\nactionType=plugin-not-applicable\ndata=plugin:demo:run\nby=8734062810")
            adapter.queue("[telegram-callback]\nid=cb-dup\nmessageId=77\nactionType=plugin-not-applicable\ndata=plugin:demo:run\nby=8734062810")
            service.processOnce()

            @Expect(recorder.count("interactive.dispatch"), 1)
            @Expect(adapter.sentText(0), "plugin handled")
            @Expect(adapter.sentText(1).contains("duplicate callback ignored"), true)
        }
    }

    @TestCase
    public func pluginApprovalCallbackDispatchesThroughOpenClawSidecarBridge(): Unit {
        withGatewayTelegramNativeTestHome {
            var user = GatewayUserSettings()
            user.telegram.enabled = true
            user.telegram.allowFrom = ["*"]
            user.telegram.actions.callbackQuery = true
            CliSettingManager.writeGatewaySettings(user)
            setGatewayOpenClawPluginSidecarRunnerForTest(Some({ method: String, payload: JsonObject =>
                let out = JsonObject()
                out.put("ok", true.toJsonValue())
                out.put("matched", (method == "approval.dispatch").toJsonValue())
                if (method == "approval.dispatch") {
                    @Expect(payload.get("data").getOrThrow().asString().getValue(), "plugin-approval:demo:allow:approval-1")
                    let intents = JsonArray([])
                    let reply = JsonObject()
                    reply.put("type", JsonString("reply"))
                    reply.put("text", JsonString("approval handled"))
                    intents.add(reply)
                    out.put("intents", intents)
                }
                if (method == "hook.message_sending") {
                    out.put("cancelled", false.toJsonValue())
                    out.put("text", payload.get("text").getOrThrow())
                }
                if (method == "hook.message_sent") {
                    out.put("status", JsonString("ok"))
                }
                out
            }))

            let adapter = GatewayTelegramNativeTestAdapter()
            let service = gatewayTelegramNativeService(adapter)
            service.start()
            adapter.queue("[telegram-callback]\nid=cb-approval\nmessageId=77\nactionType=plugin-approval\ndata=plugin-approval:demo:allow:approval-1\nby=8734062810")
            service.processOnce()

            @Expect(adapter.sentText(0), "approval handled")
        }
    }

    @TestCase
    public func pluginCommandDispatchAndOutboundHookStayInsideGatewayService(): Unit {
        withGatewayTelegramNativeTestHome {
            var user = GatewayUserSettings()
            user.telegram.enabled = true
            user.telegram.allowFrom = ["*"]
            CliSettingManager.writeGatewaySettings(user)
            let recorder = GatewayTelegramSidecarMethodRecorder()
            setGatewayOpenClawPluginSidecarRunnerForTest(Some({ method: String, payload: JsonObject =>
                recorder.add(method)
                let out = JsonObject()
                out.put("ok", true.toJsonValue())
                if (method == "commands.list") {
                    let commands = JsonArray([])
                    let row = JsonObject()
                    row.put("command", JsonString("plugin_demo"))
                    row.put("description", JsonString("Plugin demo command"))
                    commands.add(row)
                    out.put("commands", commands)
                } else if (method == "command.dispatch") {
                    out.put("matched", true.toJsonValue())
                    let intents = JsonArray([])
                    let reply = JsonObject()
                    reply.put("type", JsonString("reply"))
                    reply.put("text", JsonString("command handled"))
                    intents.add(reply)
                    out.put("intents", intents)
                } else if (method == "hook.message_sending") {
                    out.put("cancelled", false.toJsonValue())
                    let text = payload.get("text").getOrThrow().asString().getValue()
                    out.put("text", JsonString("hooked:${text}"))
                } else if (method == "hook.message_sent") {
                    @Expect(payload.get("sentMessageId").getOrThrow().asString().getValue().startsWith("test-message-"), true)
                    out.put("status", JsonString("ok"))
                } else {
                    out.put("matched", false.toJsonValue())
                }
                out
            }))

            let adapter = GatewayTelegramNativeTestAdapter()
            let service = gatewayTelegramNativeService(adapter)
            service.start()
            adapter.queue("/plugin_demo now")
            service.processOnce()

            @Expect(adapter.sentText(0), "hooked:command handled")
            @Expect(recorder.count("hook.message_sending"), 1)
            @Expect(recorder.count("hook.message_sent"), 1)
        }
    }

    @TestCase
    public func pluginCallbackIntentCanEditClearButtonsAndDeleteViaTelegramPayloads(): Unit {
        withGatewayTelegramNativeTestHome {
            var user = GatewayUserSettings()
            user.telegram.enabled = true
            user.telegram.allowFrom = ["*"]
            user.telegram.actions.callbackQuery = true
            CliSettingManager.writeGatewaySettings(user)
            setGatewayOpenClawPluginSidecarRunnerForTest(Some({ method: String, payload: JsonObject =>
                let out = JsonObject()
                out.put("ok", true.toJsonValue())
                out.put("matched", (method == "interactive.dispatch").toJsonValue())
                if (method == "interactive.dispatch") {
                    let intents = JsonArray([])
                    for ((kind, text) in [("edit", "edited"), ("clear-buttons", ""), ("delete", "")]) {
                        let intent = JsonObject()
                        intent.put("type", JsonString(kind))
                        if (!text.isEmpty()) {
                            intent.put("text", JsonString(text))
                        }
                        intents.add(intent)
                    }
                    out.put("intents", intents)
                }
                if (method == "hook.message_sending") {
                    out.put("cancelled", false.toJsonValue())
                    out.put("text", payload.get("text").getOrThrow())
                }
                out
            }))

            let adapter = GatewayTelegramNativeTestAdapter()
            let service = gatewayTelegramNativeService(adapter)
            service.start()
            adapter.queue("[telegram-callback]\nid=cb-intents\nmessageId=77\nactionType=plugin-not-applicable\ndata=plugin:demo:run\nby=8734062810")
            service.processOnce()

            @Expect(adapter.sentText(0), "[edit]\nedited")
            @Expect(adapter.sentText(1), "[clear-buttons]")
            @Expect(adapter.sentText(2), "[delete]")
        }
    }

    @TestCase
    public func telegramNativeCommandsBypassModelForHelpSubagentsSessionsAndApprovals(): Unit {
        withGatewayTelegramNativeTestHome {
            var user = GatewayUserSettings()
            user.telegram.enabled = true
            user.telegram.allowFrom = ["*"]
            CliSettingManager.writeGatewaySettings(user)

            let adapter = GatewayTelegramNativeTestAdapter()
            let service = gatewayTelegramNativeService(adapter)
            service.start()
            adapter.queue("/help")
            adapter.queue("/subagents help")
            adapter.queue("/sessions list")
            adapter.queue("/approvals")
            service.processOnce()

            @Expect(JsonValue.fromStr(adapter.sentText(0)).asObject().get("action").getOrThrow().asString().getValue(), "help")
            @Expect(JsonValue.fromStr(adapter.sentText(1)).asObject().get("action").getOrThrow().asString().getValue(), "help")
            @Expect(adapter.sentText(1).contains("/subagents spawn"), true)
            @Expect(JsonValue.fromStr(adapter.sentText(2)).asObject().get("action").getOrThrow().asString().getValue(), "sessions")
            @Expect(JsonValue.fromStr(adapter.sentText(3)).asObject().get("action").getOrThrow().asString().getValue(), "approvals")
        }
    }
}
