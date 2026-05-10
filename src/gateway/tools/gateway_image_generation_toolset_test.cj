package metis.gateway.tools

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext, setGatewayImageGenerationRunnerForTest}
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager}

import std.collection.ArrayList
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString, JsonValue}

private func gatewayImageGenerationToolTestHome(label: String): String {
    "/tmp/metis-gateway-image-generation-toolset-${label}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}"
}

private func gatewayImageGenerationToolResetEnv(oldHome: Option<String>, home: String): Unit {
    match (oldHome) {
        case Some(value) => setVariable("METIS_HOME", value)
        case None => setVariable("METIS_HOME", "")
    }
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
    CliConfig.invalidatePathCache()
    try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
}

private func gatewayImageGenerationToolInstallConfig(home: String): Unit {
    let root = JsonObject()
    let gateway = JsonObject()
    let media = JsonObject()
    let imageGeneration = JsonObject()
    imageGeneration.put("enabled", JsonBool(true))
    imageGeneration.put("provider", JsonString("fake-image"))
    let outputRoot = Path(home).join("gateway-image-generation").toString()
    imageGeneration.put("outputRoot", JsonString(outputRoot))
    imageGeneration.put("allowedOutputRoots", JsonArray([JsonString(outputRoot)]))
    let providers = JsonObject()
    let provider = JsonObject()
    provider.put("kind", JsonString("fake-image-generation"))
    provider.put("model", JsonString("fake-image-model"))
    providers.put("fake-image", provider)
    imageGeneration.put("providers", providers)
    media.put("imageGeneration", imageGeneration)
    gateway.put("media", media)

    let telegram = JsonObject()
    let actions = JsonObject()
    actions.put("photo", JsonBool(true))
    telegram.put("actions", actions)
    gateway.put("telegram", telegram)

    root.put("gateway", gateway)
    MetisConfigManager.writeRoot(root)
    CliSettingManager.invalidate()
    Directory.create(Path(home).join("gateway-image-generation"), recursive: true)
}

@Test
public class GatewayImageGenerationToolsetTest {
    @TestCase
    public func imageGenerationToolReportsNotConfiguredWithoutProvider(): Unit {
        let home = gatewayImageGenerationToolTestHome("not-configured")
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
        debugSetGatewayImageGenerationToolCallRunnerForTest(Some({ method: String, _payload: JsonObject =>
            calls.add(method)
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out
        }))
        try {
            let out = GatewayImageGenerationToolset().debugGatewayImageGenerateForTest("draw an eagle", Some("telegram"), true)
            let result = JsonValue.fromStr(out).asObject()
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), false)
            @Expect(result.get("status").getOrThrow().asString().getValue(), "not_configured")
            @Expect(result.get("action").getOrThrow().asString().getValue(), "gateway_image_generate")
            @Expect(calls.size, 0)
        } finally {
            debugSetGatewayImageGenerationToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            gatewayImageGenerationToolResetEnv(oldHome, home)
        }
    }

    @TestCase
    public func imageGenerationToolDeliversPhotoThroughCurrentTelegramContext(): Unit {
        let home = gatewayImageGenerationToolTestHome("deliver")
        let oldHome = getVariable("METIS_HOME")
        try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home)
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        CliConfig.invalidatePathCache()
        gatewayImageGenerationToolInstallConfig(home)

        let imagePath = Path(home).join("gateway-image-generation").join("eagle.png")
        File.writeTo(imagePath, "fake-image".toArray())
        setGatewayImageGenerationRunnerForTest(Some({ _config: JsonObject, request: JsonObject =>
            @Expect(request.get("prompt").getOrThrow().asString().getValue(), "draw an eagle")
            let image = JsonObject()
            image.put("path", JsonString(imagePath.toString()))
            image.put("mimeType", JsonString("image/png"))
            image.put("fileName", JsonString("eagle.png"))
            let images = JsonArray([])
            images.add(image)
            let result = JsonObject()
            result.put("ok", JsonBool(true))
            result.put("status", JsonString("ok"))
            result.put("provider", JsonString("fake-image"))
            result.put("providerKind", JsonString("fake-image-generation"))
            result.put("model", JsonString("fake-image-model"))
            result.put("images", images)
            result
        }))

        let sentTexts = ArrayList<String>()
        debugSetGatewayImageGenerationToolCallRunnerForTest(Some({ method: String, payload: JsonObject =>
            @Expect(method, "channels.send")
            sentTexts.add(payload.get("text").getOrThrow().asString().getValue())
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out
        }))
        try {
            let context = GatewayToolRuntimeContext(
                "telegram",
                channelName: "telegram",
                sessionKey: "telegram:direct:user:1"
            )
            let out = gatewayWithToolRuntimeContext(context, { =>
                GatewayImageGenerationToolset().debugGatewayImageGenerateForTest("draw an eagle", Some("telegram"), true)
            })
            let result = JsonValue.fromStr(out).asObject()
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("delivered").getOrThrow().asBool().getValue(), true)
            @Expect(context.hasVisibleReplyDelivered(), true)
            @Expect(sentTexts.size, 1)
            @Expect(sentTexts[0].startsWith("[photo]"), true)
            @Expect(sentTexts[0].contains(imagePath.toString()), true)
        } finally {
            debugSetGatewayImageGenerationToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            setGatewayImageGenerationRunnerForTest(None<(JsonObject, JsonObject) -> JsonObject>)
            gatewayImageGenerationToolResetEnv(oldHome, home)
        }
    }

    @TestCase
    public func imageGenerationToolSkipsTelegramDeliveryWhenPhotoActionDisabled(): Unit {
        let home = gatewayImageGenerationToolTestHome("action-disabled")
        let oldHome = getVariable("METIS_HOME")
        try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home)
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        CliConfig.invalidatePathCache()
        gatewayImageGenerationToolInstallConfig(home)

        var settings = CliSettingManager.readGatewaySettings()
        settings.telegram.actions.photo = false
        CliSettingManager.setting.gateway = settings

        let imagePath = Path(home).join("gateway-image-generation").join("eagle.png")
        File.writeTo(imagePath, "fake-image".toArray())
        setGatewayImageGenerationRunnerForTest(Some({ _config: JsonObject, _request: JsonObject =>
            let image = JsonObject()
            image.put("path", JsonString(imagePath.toString()))
            image.put("mimeType", JsonString("image/png"))
            image.put("fileName", JsonString("eagle.png"))
            let images = JsonArray([])
            images.add(image)
            let result = JsonObject()
            result.put("ok", JsonBool(true))
            result.put("status", JsonString("ok"))
            result.put("images", images)
            result
        }))

        let calls = ArrayList<String>()
        debugSetGatewayImageGenerationToolCallRunnerForTest(Some({ method: String, _payload: JsonObject =>
            calls.add(method)
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out
        }))
        try {
            let context = GatewayToolRuntimeContext(
                "telegram",
                channelName: "telegram",
                sessionKey: "telegram:direct:user:1"
            )
            let out = gatewayWithToolRuntimeContext(context, { =>
                GatewayImageGenerationToolset().debugGatewayImageGenerateForTest("draw an eagle", Some("telegram"), true)
            })
            let result = JsonValue.fromStr(out).asObject()
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("delivered").getOrThrow().asBool().getValue(), false)
            @Expect(result.get("delivery").getOrThrow().asString().getValue(), "skipped_action_disabled")
            @Expect(calls.size, 0)
        } finally {
            debugSetGatewayImageGenerationToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            setGatewayImageGenerationRunnerForTest(None<(JsonObject, JsonObject) -> JsonObject>)
            gatewayImageGenerationToolResetEnv(oldHome, home)
        }
    }
}
