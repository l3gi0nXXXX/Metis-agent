package metis.core.media_tests

import metis.core.*
import metis.core.config.{CliConfig, CliSettingManager, GatewayUserSettings, MetisConfigManager, MetisProcessEnvironmentLock}

import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.unittest.*
import std.time.DateTime
import stdx.encoding.json.{JsonArray, JsonFloat, JsonInt, JsonObject, JsonString}

private func pdfTestImageModel(provider: String, model: String): JsonObject {
    let entry = JsonObject()
    entry.put("provider", JsonString(provider))
    entry.put("model", JsonString(model))
    entry.put("capabilities", JsonArray([JsonString("image")]))
    entry
}

private func pdfTestImageConfig(provider: String, model: String): JsonObject {
    let config = JsonObject()
    let models = JsonArray([])
    models.add(pdfTestImageModel(provider, model))
    config.put("models", models)
    config
}

private func pdfConfigRoot(): JsonObject {
    let root = JsonObject()
    let agents = JsonObject()
    let defaults = JsonObject()
    let model = JsonObject()
    model.put("primary", JsonString("deepseek/deepseek-chat"))
    let pdfModel = JsonObject()
    pdfModel.put("primary", JsonString("anthropic/claude-sonnet-4-6"))
    pdfModel.put("fallbacks", JsonArray([JsonString("qwen/qwen-vl-max"), JsonString("openai/gpt-4o")]))
    defaults.put("model", model)
    defaults.put("pdfModel", pdfModel)
    defaults.put("pdfMaxBytesMb", JsonFloat(12.5))
    defaults.put("pdfMaxPages", JsonInt(7))
    agents.put("defaults", defaults)
    root.put("agents", agents)
    root
}

private func pdfConfigTestResetCaches(): Unit {
    CliConfig.invalidatePathCache()
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
}

private func pdfConfigTestTempHome(label: String): Path {
    Path("/tmp").join("metis-pdf-config-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
}

private func pdfConfigRestoreVariable(name: String, value: Option<String>): Unit {
    match (value) {
        case Some(v) => setVariable(name, v)
        case None => setVariable(name, "")
    }
}

private func withCleanPdfCandidateState<T>(label: String, block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = pdfConfigTestTempHome(label)
        try { remove(home, recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", home.toString())
        pdfConfigTestResetCaches()
        let oldModel = CliConfig.modelOrEmpty()
        let oldFallbacks = CliConfig.fallbackModels
        let oldImageModel = CliConfig.imageModelOrEmpty()
        let oldImageFallbacks = CliConfig.imageFallbackModels
        let oldPdfModel = CliConfig.pdfModelOrEmpty()
        let oldPdfFallbacks = CliConfig.pdfFallbackModels
        let oldPdfMaxBytesMb = CliConfig.pdfMaxBytesMb
        let oldPdfMaxPages = CliConfig.pdfMaxPages
        try {
            CliConfig.clearPrimaryModelForTest()
            CliConfig.fallbackModels = []
            CliConfig.clearImageModelForTest()
            CliConfig.imageFallbackModels = []
            CliConfig.clearPdfModelForTest()
            CliConfig.pdfFallbackModels = []
            CliConfig.pdfMaxBytesMb = 10.0
            CliConfig.pdfMaxPages = 20
            return block()
        } finally {
            if (oldModel.isEmpty()) {
                CliConfig.clearPrimaryModelForTest()
            } else {
                CliConfig.model = oldModel
            }
            CliConfig.fallbackModels = oldFallbacks
            if (oldImageModel.isEmpty()) {
                CliConfig.clearImageModelForTest()
            } else {
                CliConfig.imageModel = oldImageModel
            }
            CliConfig.imageFallbackModels = oldImageFallbacks
            if (oldPdfModel.isEmpty()) {
                CliConfig.clearPdfModelForTest()
            } else {
                CliConfig.pdfModel = oldPdfModel
            }
            CliConfig.pdfFallbackModels = oldPdfFallbacks
            CliConfig.pdfMaxBytesMb = oldPdfMaxBytesMb
            CliConfig.pdfMaxPages = oldPdfMaxPages
            pdfConfigRestoreVariable("METIS_HOME", oldHome)
            pdfConfigTestResetCaches()
            try { remove(home, recursive: true) } catch (_: Exception) { () }
        }
    }
}

@Test
public class GatewayMediaPdfConfigTest {
    @TestCase
    public func agentsDefaultsPdfModelAndLimitsMaterialize(): Unit {
        withCleanPdfCandidateState("pdf-config-materializes") {
            MetisConfigManager.writeRoot(pdfConfigRoot())
            CliSettingManager.invalidate()

            CliSettingManager.applyPersistedFieldsToCliConfig()

            @Expect(CliConfig.pdfModelOrEmpty(), "anthropic:claude-sonnet-4-6")
            @Expect(CliConfig.pdfFallbackModels.size, 2)
            @Expect(CliConfig.pdfFallbackModels[0], "dashscope:qwen-vl-max")
            @Expect(CliConfig.pdfFallbackModels[1], "openai:gpt-4o")
            @Expect(CliConfig.pdfMaxBytesMb, 12.5)
            @Expect(CliConfig.pdfMaxPages, 7)
            @Expect(gatewayPdfMaxBytes(), Int64(12.5 * 1024.0 * 1024.0))
            @Expect(gatewayPdfMaxPages(), 7)
        }
    }

    @TestCase
    public func pdfModelPrimaryWinsAndMarksNativeProvider(): Unit {
        withCleanPdfCandidateState("pdf-model-primary-wins") {
            var user = GatewayUserSettings()
            CliConfig.pdfModel = "anthropic:claude-sonnet-4-6"
            CliConfig.pdfFallbackModels = ["google/gemini-3.1-pro-preview"]
            CliConfig.imageModel = "dashscope:qwen-vl-max"
            CliConfig.model = "deepseek:deepseek-chat"

            let candidates = gatewayPdfBuildCandidates(user, channel: "telegram")

            @Expect(candidates.size, 4)
            @Expect(candidates[0].modelRef, "anthropic:claude-sonnet-4-6")
            @Expect(candidates[0].source, "agents.defaults.pdfModel.primary")
            @Expect(candidates[0].nativePdfSupported, true)
            @Expect(candidates[0].imageSupported, true)
            @Expect(candidates[1].modelRef, "google:gemini-3.1-pro-preview")
            @Expect(candidates[1].source, "agents.defaults.pdfModel.fallbacks")
            @Expect(candidates[1].nativePdfSupported, true)
        }
    }

    @TestCase
    public func imageModelFallbackIsUsedWhenPdfModelMissingAndSlashRefsNormalize(): Unit {
        withCleanPdfCandidateState("pdf-image-model-fallback") {
            var user = GatewayUserSettings()
            CliConfig.imageModel = "qwen/qwen-vl-max"
            CliConfig.model = "deepseek:deepseek-chat"

            let candidates = gatewayPdfBuildCandidates(user, channel: "telegram")

            @Expect(candidates.size, 2)
            @Expect(candidates[0].modelRef, "dashscope:qwen-vl-max")
            @Expect(candidates[0].source, "agents.defaults.imageModel.primary")
            @Expect(candidates[0].imageSupported, true)
            @Expect(candidates[0].nativePdfSupported, false)
            @Expect(candidates[1].modelRef, "deepseek:deepseek-chat")
            @Expect(candidates[1].source, "agents.defaults.model.primary")
            @Expect(candidates[1].imageSupported, false)
        }
    }

    @TestCase
    public func gatewayImageModelEntriesPrecedeImageModelFallback(): Unit {
        withCleanPdfCandidateState("pdf-gateway-image-models") {
            var user = GatewayUserSettings()
            user.media.image = pdfTestImageConfig("custom", "vision-x")
            CliConfig.imageModel = "qwen/qwen-vl-max"

            let candidates = gatewayPdfBuildCandidates(user, channel: "feishu")

            @Expect(candidates.size, 2)
            @Expect(candidates[0].modelRef, "custom:vision-x")
            @Expect(candidates[0].source, "gateway.media.image.models")
            @Expect(candidates[0].imageSupported, true)
            @Expect(candidates[1].modelRef, "dashscope:qwen-vl-max")
            @Expect(candidates[1].source, "agents.defaults.imageModel.primary")
        }
    }

    @TestCase
    public func defaultModelFallbackRemainsTextOnlyCandidate(): Unit {
        withCleanPdfCandidateState("pdf-default-text-model") {
            var user = GatewayUserSettings()
            CliConfig.model = "deepseek/deepseek-chat"

            let candidates = gatewayPdfBuildCandidates(user, channel: "telegram")

            @Expect(candidates.size, 1)
            @Expect(candidates[0].modelRef, "deepseek:deepseek-chat")
            @Expect(candidates[0].source, "agents.defaults.model.primary")
            @Expect(candidates[0].imageSupported, false)
            @Expect(candidates[0].nativePdfSupported, false)
        }
    }

    @TestCase
    public func nativePdfProviderDetectionUsesProviderAliases(): Unit {
        @Expect(providerSupportsNativePdf("anthropic"), true)
        @Expect(providerSupportsNativePdf("google"), true)
        @Expect(providerSupportsNativePdf("gemini"), true)
        @Expect(providerSupportsNativePdf("dashscope"), false)
    }
}
