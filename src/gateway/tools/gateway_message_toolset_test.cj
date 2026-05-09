package metis.gateway.tools

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext}
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
}
