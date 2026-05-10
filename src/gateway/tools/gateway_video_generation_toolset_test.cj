package metis.gateway.tools

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext, setGatewayVideoGenerationRunnerForTest}
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager}

import std.collection.ArrayList
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString, JsonValue}

private func gatewayVideoGenerationToolTestHome(label: String): String {
    "/tmp/metis-gateway-video-generation-toolset-${label}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}"
}

private func gatewayVideoGenerationToolResetEnv(oldHome: Option<String>, home: String): Unit {
    match (oldHome) {
        case Some(value) => setVariable("METIS_HOME", value)
        case None => setVariable("METIS_HOME", "")
    }
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
    CliConfig.invalidatePathCache()
    try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
}

private func gatewayVideoGenerationToolInstallConfig(home: String): Unit {
    let root = JsonObject()
    let gateway = JsonObject()
    let media = JsonObject()
    let videoGeneration = JsonObject()
    videoGeneration.put("enabled", JsonBool(true))
    videoGeneration.put("provider", JsonString("fake-video"))
    let outputRoot = Path(home).join("gateway-video-generation").toString()
    videoGeneration.put("outputRoot", JsonString(outputRoot))
    videoGeneration.put("allowedOutputRoots", JsonArray([JsonString(outputRoot)]))
    let providers = JsonObject()
    let provider = JsonObject()
    provider.put("kind", JsonString("fake-video-generation"))
    provider.put("model", JsonString("fake-wan"))
    providers.put("fake-video", provider)
    videoGeneration.put("providers", providers)
    media.put("videoGeneration", videoGeneration)
    gateway.put("media", media)

    let telegram = JsonObject()
    let actions = JsonObject()
    actions.put("video", JsonBool(true))
    telegram.put("actions", actions)
    gateway.put("telegram", telegram)

    root.put("gateway", gateway)
    MetisConfigManager.writeRoot(root)
    CliSettingManager.invalidate()
    Directory.create(Path(home).join("gateway-video-generation"), recursive: true)
}

@Test
public class GatewayVideoGenerationToolsetTest {
    @TestCase
    public func videoGenerationToolReportsNotConfiguredWithoutProvider(): Unit {
        let home = gatewayVideoGenerationToolTestHome("not-configured")
        let oldHome = getVariable("METIS_HOME")
        try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home)
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        CliConfig.invalidatePathCache()
        MetisConfigManager.writeRoot(JsonObject())
        CliSettingManager.invalidate()

        let calls = ArrayList<String>()
        debugSetGatewayVideoGenerationToolCallRunnerForTest(Some({ method: String, _payload: JsonObject =>
            calls.add(method)
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out
        }))
        try {
            let toolset = GatewayVideoGenerationToolset()
            let out = toolset.debugGatewayVideoGenerateForTest("make a short demo", Some("telegram"), true)
            let result = JsonValue.fromStr(out).asObject()
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), false)
            @Expect(result.get("status").getOrThrow().asString().getValue(), "not_configured")
            @Expect(result.get("action").getOrThrow().asString().getValue(), "gateway_video_generate")
            @Expect(result.get("error").getOrThrow().asString().getValue().contains("video generation provider is not configured"), true)
            @Expect(calls.size, 0)
        } finally {
            debugSetGatewayVideoGenerationToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            gatewayVideoGenerationToolResetEnv(oldHome, home)
        }
    }

    @TestCase
    public func videoGenerationToolDeliversFakeVideoThroughCurrentTelegramContext(): Unit {
        let home = gatewayVideoGenerationToolTestHome("deliver")
        let oldHome = getVariable("METIS_HOME")
        try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home)
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        CliConfig.invalidatePathCache()
        gatewayVideoGenerationToolInstallConfig(home)

        let videoPath = Path(home).join("gateway-video-generation").join("demo.mp4")
        File.writeTo(videoPath, "fake-video".toArray())
        setGatewayVideoGenerationRunnerForTest(Some({ _config: JsonObject, request: JsonObject =>
            @Expect(request.get("prompt").getOrThrow().asString().getValue(), "make a short demo")
            let video = JsonObject()
            video.put("path", JsonString(videoPath.toString()))
            video.put("mimeType", JsonString("video/mp4"))
            video.put("fileName", JsonString("demo.mp4"))
            let videos = JsonArray([])
            videos.add(video)
            let result = JsonObject()
            result.put("ok", JsonBool(true))
            result.put("status", JsonString("ok"))
            result.put("provider", JsonString("fake-video"))
            result.put("providerKind", JsonString("fake-video-generation"))
            result.put("model", JsonString("fake-wan"))
            result.put("videos", videos)
            result
        }))

        let sentTexts = ArrayList<String>()
        debugSetGatewayVideoGenerationToolCallRunnerForTest(Some({ method: String, payload: JsonObject =>
            @Expect(method, "channels.send")
            sentTexts.add(payload.get("text").getOrThrow().asString().getValue())
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out
        }))
        try {
            let toolset = GatewayVideoGenerationToolset()
            let context = GatewayToolRuntimeContext(
                "telegram",
                channelName: "telegram",
                sessionKey: "telegram:direct:user:1"
            )
            let out = gatewayWithToolRuntimeContext(context, { =>
                toolset.debugGatewayVideoGenerateForTest("make a short demo", Some("telegram"), true)
            })
            let result = JsonValue.fromStr(out).asObject()
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("status").getOrThrow().asString().getValue(), "ok")
            @Expect(result.get("delivered").getOrThrow().asBool().getValue(), true)
            @Expect(context.hasVisibleReplyDelivered(), true)
            @Expect(sentTexts.size, 1)
            @Expect(sentTexts[0].startsWith("[video]"), true)
            @Expect(sentTexts[0].contains(videoPath.toString()), true)
            @Expect(out.contains("fake-video-generation"), true)
        } finally {
            debugSetGatewayVideoGenerationToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            setGatewayVideoGenerationRunnerForTest(None<(JsonObject, JsonObject) -> JsonObject>)
            gatewayVideoGenerationToolResetEnv(oldHome, home)
        }
    }

    @TestCase
    public func videoGenerationToolSkipsTelegramDeliveryWhenVideoActionDisabled(): Unit {
        let home = gatewayVideoGenerationToolTestHome("action-disabled")
        let oldHome = getVariable("METIS_HOME")
        try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home)
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        CliConfig.invalidatePathCache()
        gatewayVideoGenerationToolInstallConfig(home)

        var settings = CliSettingManager.readGatewaySettings()
        settings.telegram.actions.video = false
        CliSettingManager.setting.gateway = settings

        let videoPath = Path(home).join("gateway-video-generation").join("demo.mp4")
        File.writeTo(videoPath, "fake-video".toArray())
        setGatewayVideoGenerationRunnerForTest(Some({ _config: JsonObject, _request: JsonObject =>
            let video = JsonObject()
            video.put("path", JsonString(videoPath.toString()))
            video.put("mimeType", JsonString("video/mp4"))
            video.put("fileName", JsonString("demo.mp4"))
            let videos = JsonArray([])
            videos.add(video)
            let result = JsonObject()
            result.put("ok", JsonBool(true))
            result.put("status", JsonString("ok"))
            result.put("provider", JsonString("fake-video"))
            result.put("providerKind", JsonString("fake-video-generation"))
            result.put("model", JsonString("fake-wan"))
            result.put("videos", videos)
            result
        }))

        let calls = ArrayList<String>()
        debugSetGatewayVideoGenerationToolCallRunnerForTest(Some({ method: String, _payload: JsonObject =>
            calls.add(method)
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out
        }))
        try {
            let toolset = GatewayVideoGenerationToolset()
            let context = GatewayToolRuntimeContext(
                "telegram",
                channelName: "telegram",
                sessionKey: "telegram:direct:user:1"
            )
            let out = gatewayWithToolRuntimeContext(context, { =>
                toolset.debugGatewayVideoGenerateForTest("make a short demo", Some("telegram"), true)
            })
            let result = JsonValue.fromStr(out).asObject()
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("delivered").getOrThrow().asBool().getValue(), false)
            @Expect(result.get("delivery").getOrThrow().asString().getValue(), "skipped_action_disabled")
            @Expect(context.hasVisibleReplyDelivered(), false)
            @Expect(calls.size, 0)
        } finally {
            debugSetGatewayVideoGenerationToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            setGatewayVideoGenerationRunnerForTest(None<(JsonObject, JsonObject) -> JsonObject>)
            gatewayVideoGenerationToolResetEnv(oldHome, home)
        }
    }

    @TestCase
    public func videoGenerationToolPassesTelegramNetworkContextToRuntimeConfig(): Unit {
        let home = gatewayVideoGenerationToolTestHome("telegram-network-context")
        let oldHome = getVariable("METIS_HOME")
        try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home)
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        CliConfig.invalidatePathCache()
        gatewayVideoGenerationToolInstallConfig(home)

        var settings = CliSettingManager.readGatewaySettings()
        settings.telegram.proxy = "http://user:secret@127.0.0.1:7897"
        settings.telegram.network.envProxyEnabled = true
        settings.telegram.network.insecureSkipTlsVerify = true
        CliSettingManager.setting.gateway = settings

        let capturedProxy = ArrayList<String>()
        setGatewayVideoGenerationRunnerForTest(Some({ config: JsonObject, _request: JsonObject =>
            let providers = config.get("providers").getOrThrow().asObject()
            let provider = providers.get("fake-video").getOrThrow().asObject()
            capturedProxy.add(provider.get("proxy").getOrThrow().asString().getValue())
            @Expect(provider.get("envProxyEnabled").getOrThrow().asBool().getValue(), true)
            @Expect(provider.get("insecureSkipTlsVerify").getOrThrow().asBool().getValue(), true)
            let result = JsonObject()
            result.put("ok", JsonBool(false))
            result.put("status", JsonString("provider_error"))
            result.put("message", JsonString("synthetic provider error"))
            result
        }))

        try {
            let toolset = GatewayVideoGenerationToolset()
            let out = toolset.debugGatewayVideoGenerateForTest("make a short demo", Some("telegram"), false)
            let result = JsonValue.fromStr(out).asObject()

            @Expect(result.get("status").getOrThrow().asString().getValue(), "provider_error")
            @Expect(capturedProxy.size, 1)
            @Expect(capturedProxy[0], "http://user:secret@127.0.0.1:7897")
            @Expect(out.contains("secret"), false)
        } finally {
            setGatewayVideoGenerationRunnerForTest(None<(JsonObject, JsonObject) -> JsonObject>)
            gatewayVideoGenerationToolResetEnv(oldHome, home)
        }
    }
}
