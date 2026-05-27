package metis.gateway.tools

import metis.core.{GatewaySpeechTtsDashScopeQwenHttpResult, GatewayToolRuntimeContext, gatewayWithToolRuntimeContext, setGatewaySpeechTtsDashScopeQwenRunnerForTest}
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager}

import std.collection.ArrayList
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

private func gatewayMessageToolTestHome(label: String): String {
    "/tmp/metis-gateway-message-toolset-${label}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}"
}

private func gatewayMessageToolInstallFakeTtsConfig(home: String, audioAsVoice!: Bool = true): Unit {
    let root = JsonObject()
    let gateway = JsonObject()
    let speech = JsonObject()
    let tts = JsonObject()
    tts.put("provider", JsonString("fake"))
    tts.put("providers", JsonObject())
    speech.put("tts", tts)
    gateway.put("speech", speech)

    let telegram = JsonObject()
    let telegramSpeech = JsonObject()
    telegramSpeech.put("audioAsVoice", JsonBool(audioAsVoice))
    telegramSpeech.put("autoReplyToVoice", JsonBool(true))
    telegram.put("speech", telegramSpeech)
    gateway.put("telegram", telegram)

    root.put("gateway", gateway)
    MetisConfigManager.writeRoot(root)
    CliSettingManager.invalidate()
    let ttsDir = Path(home).join("gateway-telegram").join("tts")
    Directory.create(ttsDir, recursive: true)
    let state = JsonObject()
    state.put("enabled", JsonBool(true))
    state.put("provider", JsonString("fake"))
    state.put("audioAsVoice", JsonBool(audioAsVoice))
    state.put("limit", JsonInt(4000))
    File.writeTo(ttsDir.join("state.json"), state.toJsonString().toArray())
}

private func gatewayMessageToolInstallDashScopeQwenTtsConfig(home: String, audioAsVoice!: Bool = true): Unit {
    let root = JsonObject()
    let gateway = JsonObject()
    let speech = JsonObject()
    let tts = JsonObject()
    tts.put("enabled", JsonBool(true))
    tts.put("provider", JsonString("dashscope"))
    tts.put("degradeMessage", JsonString("语音暂时发送失败，我先打字陪你。"))
    let providers = JsonObject()
    let provider = JsonObject()
    provider.put("kind", JsonString("dashscope-qwen-tts"))
    provider.put("baseUrl", JsonString("https://dashscope.aliyuncs.com/api/v1"))
    provider.put("apiKey", JsonString("test-dashscope-key"))
    provider.put("model", JsonString("qwen3-tts-flash"))
    provider.put("voice", JsonString("Chelsie"))
    provider.put("languageType", JsonString("Chinese"))
    provider.put("timeoutMs", JsonInt(1000))
    providers.put("dashscope", provider)
    tts.put("providers", providers)
    speech.put("tts", tts)
    gateway.put("speech", speech)

    let telegram = JsonObject()
    let telegramSpeech = JsonObject()
    telegramSpeech.put("audioAsVoice", JsonBool(audioAsVoice))
    telegramSpeech.put("autoReplyToVoice", JsonBool(true))
    telegram.put("speech", telegramSpeech)
    gateway.put("telegram", telegram)

    root.put("gateway", gateway)
    MetisConfigManager.writeRoot(root)
    CliSettingManager.invalidate()
    let ttsDir = Path(home).join("gateway-telegram").join("tts")
    Directory.create(ttsDir, recursive: true)
    let state = JsonObject()
    state.put("enabled", JsonBool(true))
    state.put("provider", JsonString("dashscope"))
    state.put("audioAsVoice", JsonBool(audioAsVoice))
    state.put("limit", JsonInt(4000))
    File.writeTo(ttsDir.join("state.json"), state.toJsonString().toArray())
}

@Test
public class GatewayMessageToolsetTest {
    @TestCase
    public func telegramVoiceInputMessageToolSynthesizesTextReplyToVoiceAndMarksDelivered(): Unit {
        let home = gatewayMessageToolTestHome("auto-voice")
        let oldHome = getVariable("METIS_HOME")
        try {
            remove(Path(home), recursive: true)
        } catch (_: Exception) {
            ()
        }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home)
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        CliConfig.invalidatePathCache()
        gatewayMessageToolInstallFakeTtsConfig(home)

        let sentTexts = ArrayList<String>()
        debugSetGatewayMessageToolCallRunnerForTest(Some({ method: String, payload: JsonObject =>
            @Expect(method, "channels.send")
            sentTexts.add(payload.get("text").getOrThrow().asString().getValue())
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out
        }))
        try {
            let toolset = GatewayMessageToolset()
            let context = GatewayToolRuntimeContext(
                "telegram",
                channelName: "telegram",
                sessionKey: "telegram:direct:user:1",
                prompt: "[voice]\nmediaKind=voice\ntranscript=语音测试"
            )
            let out = gatewayWithToolRuntimeContext(context, { =>
                toolset.debugMessageForTest("send", "telegram", "user:1", "这是文字回复")
            })
            let result = JsonValue.fromStr(out).asObject()
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("payloadKind").getOrThrow().asString().getValue(), "voice")
            @Expect(sentTexts.size, 1)
            @Expect(sentTexts[0].startsWith("[voice]"), true)
            @Expect(sentTexts[0].contains("caption=TTS (fake)"), true)
            @Expect(context.hasVisibleReplyDelivered(), true)
        } finally {
            debugSetGatewayMessageToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            CliConfig.invalidatePathCache()
            try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func telegramVoiceInputMessageToolUsesDashScopeQwenVoicePayloadWithoutDegradeText(): Unit {
        let home = gatewayMessageToolTestHome("dashscope-auto-voice")
        let oldHome = getVariable("METIS_HOME")
        try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home)
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        CliConfig.invalidatePathCache()
        gatewayMessageToolInstallDashScopeQwenTtsConfig(home)

        let sentTexts = ArrayList<String>()
        setGatewaySpeechTtsDashScopeQwenRunnerForTest(Some({ request: JsonObject =>
            let body = request.get("body").getOrThrow().asObject()
            let input = body.get("input").getOrThrow().asObject()
            @Expect(input.get("text").getOrThrow().asString().getValue(), "这是文字回复")
            @Expect(input.get("voice").getOrThrow().asString().getValue(), "Chelsie")
            GatewaySpeechTtsDashScopeQwenHttpResult(200, bodyBytes: "DASH-AUDIO".toArray())
        }))
        debugSetGatewayMessageToolCallRunnerForTest(Some({ method: String, payload: JsonObject =>
            @Expect(method, "channels.send")
            sentTexts.add(payload.get("text").getOrThrow().asString().getValue())
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out
        }))
        try {
            let toolset = GatewayMessageToolset()
            let context = GatewayToolRuntimeContext(
                "telegram",
                channelName: "telegram",
                sessionKey: "telegram:direct:user:1",
                prompt: "[voice]\nmediaKind=voice\ntranscript=语音测试"
            )
            let out = gatewayWithToolRuntimeContext(context, { =>
                toolset.debugMessageForTest("send", "telegram", "user:1", "这是文字回复")
            })
            let result = JsonValue.fromStr(out).asObject()
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("payloadKind").getOrThrow().asString().getValue(), "voice")
            @Expect(sentTexts.size, 1)
            @Expect(sentTexts[0].startsWith("[voice]"), true)
            @Expect(sentTexts[0].contains("caption=TTS (dashscope)"), true)
            @Expect(sentTexts[0].contains("语音暂时发送失败"), false)
            @Expect(context.hasVisibleReplyDelivered(), true)
        } finally {
            debugSetGatewayMessageToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            setGatewaySpeechTtsDashScopeQwenRunnerForTest(None<(JsonObject) -> GatewaySpeechTtsDashScopeQwenHttpResult>)
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            CliConfig.invalidatePathCache()
            try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func telegramTextVoiceRequestMessageToolKeepsTextReplyModelShouldUseTtsTool(): Unit {
        let home = gatewayMessageToolTestHome("explicit-voice")
        let oldHome = getVariable("METIS_HOME")
        try {
            remove(Path(home), recursive: true)
        } catch (_: Exception) {
            ()
        }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home)
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        CliConfig.invalidatePathCache()
        gatewayMessageToolInstallFakeTtsConfig(home)

        let sentTexts = ArrayList<String>()
        debugSetGatewayMessageToolCallRunnerForTest(Some({ method: String, payload: JsonObject =>
            @Expect(method, "channels.send")
            sentTexts.add(payload.get("text").getOrThrow().asString().getValue())
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out
        }))
        try {
            let toolset = GatewayMessageToolset()
            let context = GatewayToolRuntimeContext(
                "telegram",
                channelName: "telegram",
                sessionKey: "telegram:direct:user:1",
                prompt: "发一条语音信息给我，随便说点什么。"
            )
            let out = gatewayWithToolRuntimeContext(context, { =>
                toolset.debugMessageForTest("send", "telegram", "user:1", "这是语音回复内容")
            })
            let result = JsonValue.fromStr(out).asObject()
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("payloadKind").getOrThrow().asString().getValue(), "text")
            @Expect(sentTexts.size, 1)
            @Expect(sentTexts[0], "这是语音回复内容")
            @Expect(context.hasVisibleReplyDelivered(), true)
        } finally {
            debugSetGatewayMessageToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            CliConfig.invalidatePathCache()
            try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func telegramVoiceInputMessageToolKeepsTextWhenAudioAsVoiceFalse(): Unit {
        let home = gatewayMessageToolTestHome("auto-voice-disabled")
        let oldHome = getVariable("METIS_HOME")
        try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home)
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        CliConfig.invalidatePathCache()
        gatewayMessageToolInstallFakeTtsConfig(home, audioAsVoice: false)

        let sentTexts = ArrayList<String>()
        debugSetGatewayMessageToolCallRunnerForTest(Some({ method: String, payload: JsonObject =>
            @Expect(method, "channels.send")
            sentTexts.add(payload.get("text").getOrThrow().asString().getValue())
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out
        }))
        try {
            let toolset = GatewayMessageToolset()
            let context = GatewayToolRuntimeContext(
                "telegram",
                channelName: "telegram",
                sessionKey: "telegram:direct:user:1",
                prompt: "[voice]\nmediaKind=voice\ntranscript=语音测试"
            )
            let out = gatewayWithToolRuntimeContext(context, { =>
                toolset.debugMessageForTest("send", "telegram", "user:1", "这是文字回复")
            })
            let result = JsonValue.fromStr(out).asObject()
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("payloadKind").getOrThrow().asString().getValue(), "text")
            @Expect(sentTexts.size, 1)
            @Expect(sentTexts[0], "这是文字回复")
        } finally {
            debugSetGatewayMessageToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            CliConfig.invalidatePathCache()
            try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func telegramMessageToolStripsInternalDirectivesBeforeSending(): Unit {
        let sentTexts = ArrayList<String>()
        debugSetGatewayMessageToolCallRunnerForTest(Some({ method: String, payload: JsonObject =>
            @Expect(method, "channels.send")
            sentTexts.add(payload.get("text").getOrThrow().asString().getValue())
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out
        }))
        try {
            let toolset = GatewayMessageToolset()
            let out = toolset.debugMessageForTest(
                "send",
                "telegram",
                "user:1",
                "[[reply_to_current]] [[tts:text]]可以，这是一条回复。[[audio_as_voice]]"
            )
            let result = JsonValue.fromStr(out).asObject()
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("message").getOrThrow().asString().getValue(), "可以，这是一条回复。")
            @Expect(sentTexts.size, 1)
            @Expect(sentTexts[0], "可以，这是一条回复。")
        } finally {
            debugSetGatewayMessageToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
        }
    }

    @TestCase
    public func messagePhotoUsesRuntimeGatewayCallHookWhenInsideGatewayContext(): Unit {
        let calls = ArrayList<JsonObject>()
        let context = GatewayToolRuntimeContext(
            "feishu",
            channelName: "feishu",
            sessionKey: "agent:main:feishu:peer",
            gatewayCallHook: Some({ method: String, payload: JsonObject =>
                @Expect(method, "channels.send")
                calls.add(payload)
                let out = JsonObject()
                out.put("ok", JsonBool(true))
                out
            })
        )
        let out = gatewayWithToolRuntimeContext(context, { =>
            GatewayMessageToolset().debugMessageForTest("photo", "feishu", "ou_user", "/tmp/a.png")
        })
        let result = JsonValue.fromStr(out).asObject()
        @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
        @Expect(calls.size, 1)
        let payload = calls[0]
        @Expect(payload.get("channel").getOrThrow().asString().getValue(), "feishu")
        @Expect(payload.get("to").getOrThrow().asString().getValue(), "ou_user")
        @Expect(payload.get("text").getOrThrow().asString().getValue().startsWith("[photo]"), true)
        @Expect(context.hasVisibleReplyDelivered(), true)
    }

    @TestCase
    public func messagePhotoRejectsHumanCaptionTextBeforeGatewaySend(): Unit {
        let calls = ArrayList<JsonObject>()
        debugSetGatewayMessageToolCallRunnerForTest(Some({ _method: String, payload: JsonObject =>
            calls.add(payload)
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out
        }))
        try {
            let out = GatewayMessageToolset().debugMessageForTest(
                "photo",
                "telegram",
                "user:1059872384",
                "Metis Orca 吉祥物 一只跃出海面的虎鲸"
            )
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("ok").getOrThrow().asBool().getValue(), false)
            @Expect(json.get("status").getOrThrow().asString().getValue(), "error")
            @Expect(json.get("errorCode").getOrThrow().asString().getValue(), "invalid_media_reference")
            @Expect(calls.size, 0)
        } finally {
            debugSetGatewayMessageToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
        }
    }

    @TestCase
    public func messagePhotoRuntimeHookFailureReturnsStructuredError(): Unit {
        let context = GatewayToolRuntimeContext(
            "feishu",
            channelName: "feishu",
            sessionKey: "feishu:direct:ou_1",
            senderId: "ou_1",
            gatewayCallHook: Some({ _method: String, _payload: JsonObject =>
                let out = JsonObject()
                out.put("ok", JsonBool(false))
                out.put("status", JsonString("error"))
                out.put("error", JsonString("send failed"))
                out
            })
        )
        let out = gatewayWithToolRuntimeContext(context, { =>
            GatewayMessageToolset().debugMessageForTest("photo", "feishu", "ou_1", "/tmp/pic.png")
        })
        let json = JsonValue.fromStr(out).asObject()
        @Expect(json.get("ok").getOrThrow().asBool().getValue(), false)
        @Expect(json.get("status").getOrThrow().asString().getValue(), "error")
        @Expect(json.get("action").getOrThrow().asString().getValue(), "photo")
        @Expect(json.get("gateway").getOrThrow().asObject().get("error").getOrThrow().asString().getValue(), "send failed")
        @Expect(context.hasVisibleReplyDelivered(), false)
    }

    @TestCase
    public func messageToolSendUsesRuntimeHookInsideContext(): Unit {
        let calls = ArrayList<JsonObject>()
        let context = GatewayToolRuntimeContext(
            "telegram",
            channelName: "telegram",
            sessionKey: "telegram:direct:user:1",
            senderId: "user:1",
            gatewayCallHook: Some({ method: String, payload: JsonObject =>
                @Expect(method, "channels.send")
                calls.add(payload)
                let out = JsonObject()
                out.put("ok", JsonBool(true))
                out.put("messageId", JsonString("runtime-hook-message"))
                out
            })
        )
        let out = gatewayWithToolRuntimeContext(context, { =>
            GatewayMessageToolset().debugMessageForTest("send", "telegram", "user:1", "runtime hello")
        })
        let json = JsonValue.fromStr(out).asObject()
        @Expect(json.get("ok").getOrThrow().asBool().getValue(), true)
        @Expect(json.get("status").getOrThrow().asString().getValue(), "accepted")
        @Expect(calls.size, 1)
        @Expect(calls[0].get("channel").getOrThrow().asString().getValue(), "telegram")
        @Expect(calls[0].get("to").getOrThrow().asString().getValue(), "user:1")
        @Expect(calls[0].get("text").getOrThrow().asString().getValue(), "runtime hello")
        @Expect(context.hasVisibleReplyDelivered(), true)
    }

    @TestCase
    public func messageToolSendFailsFastWhenRuntimeHookMissing(): Unit {
        let context = GatewayToolRuntimeContext(
            "telegram",
            channelName: "telegram",
            sessionKey: "telegram:direct:user:1",
            senderId: "user:1"
        )
        let out = gatewayWithToolRuntimeContext(context, { =>
            GatewayMessageToolset().debugMessageForTest("send", "telegram", "user:1", "hook missing")
        })
        let json = JsonValue.fromStr(out).asObject()
        @Expect(json.get("ok").getOrThrow().asBool().getValue(), false)
        @Expect(json.get("status").getOrThrow().asString().getValue(), "error")
        let gateway = json.get("gateway").getOrThrow().asObject()
        @Expect(gateway.get("ok").getOrThrow().asBool().getValue(), false)
        @Expect(gateway.get("code").getOrThrow().asString().getValue(), "send_hook_missing")
        @Expect(gateway.get("method").getOrThrow().asString().getValue(), "channels.send")
        @Expect(gateway.get("selfCallPrevented").getOrThrow().asBool().getValue(), true)
        @Expect(context.hasVisibleReplyDelivered(), false)
    }

    @TestCase
    public func messageToolSendUsesCliFallbackOnlyOutsideRuntime(): Unit {
        let calls = ArrayList<JsonObject>()
        debugSetGatewayMessageToolCallRunnerForTest(Some({ method: String, payload: JsonObject =>
            @Expect(method, "channels.send")
            calls.add(payload)
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out.put("messageId", JsonString("legacy-fallback-message"))
            out
        }))
        try {
            let out = GatewayMessageToolset().debugMessageForTest("send", "telegram", "user:1", "fallback hello")
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(json.get("status").getOrThrow().asString().getValue(), "accepted")
            @Expect(calls.size, 1)
            @Expect(calls[0].get("channel").getOrThrow().asString().getValue(), "telegram")
            @Expect(calls[0].get("to").getOrThrow().asString().getValue(), "user:1")
        } finally {
            debugSetGatewayMessageToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
        }
    }

    @TestCase
    public func messageToolSendDefaultOutputIsHumanReadable(): Unit {
        debugSetGatewayMessageToolCallRunnerForTest(Some({ _method: String, _payload: JsonObject =>
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out
        }))
        try {
            let out = GatewayMessageToolset().debugMessageForTest("send", "telegram", "user:1", "hello default output")
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("payloadPreview").getOrThrow().asString().getValue(), "hello default output")
            @Expect(json.get("message").getOrThrow().asString().getValue(), "hello default output")
            @Expect(json.get("payloadPreview").getOrThrow().asString().getValue().contains("\"ok\""), false)
            @Expect(json.get("payloadPreview").getOrThrow().asString().getValue().contains("\"result\""), false)
            @Expect(json.get("payloadPreview").getOrThrow().asString().getValue().contains("\"sessions\""), false)
        } finally {
            debugSetGatewayMessageToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
        }
    }
}
