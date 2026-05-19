package metis.core.model

import metis.core.config.MetisConfigManager

import std.collection.ArrayList
import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

private func modelCapabilityTestEntry(id: String, input: Array<String>): JsonObject {
    let entry = JsonObject()
    entry.put("id", JsonString(id))
    let values = JsonArray([])
    for (item in input) {
        values.add(JsonString(item))
    }
    entry.put("input", values)
    entry
}

private func modelCapabilityTestStringArray(obj: JsonObject, key: String): Array<String> {
    let out = ArrayList<String>()
    match (obj.get(key)) {
        case Some(value) =>
            try {
                for (item in value.asArray().getItems()) {
                    out.add(item.asString().getValue())
                }
            } catch (_: Exception) {
                ()
            }
        case None => ()
    }
    out.toArray()
}

@Test
public class ModelCapabilityResolverTest {
    @TestCase
    public func knownDeepseekTextModelDoesNotSupportImageInput(): Unit {
        let decision = resolveModelImageCapability("deepseek/deepseek-v4-pro")

        @Expect(decision.normalizedRef, "deepseek:deepseek-v4-pro")
        @Expect(modelVisionSupportToString(decision.vision), "unsupported")
        @Expect(decision.source, "built-in-deny")
    }

    @TestCase
    public func knownQwenVisionModelSupportsSlashAndColonRefs(): Unit {
        let slashDecision = resolveModelImageCapability("qwen/qwen3.6-plus")
        let colonDecision = resolveModelImageCapability("dashscope:qwen3.6-plus")
        let modelstudioDecision = resolveModelImageCapability("modelstudio:qwen3.6-plus")

        @Expect(slashDecision.normalizedRef, "dashscope:qwen3.6-plus")
        @Expect(modelVisionSupportToString(slashDecision.vision), "supported")
        @Expect(modelVisionSupportToString(colonDecision.vision), "supported")
        @Expect(modelVisionSupportToString(modelstudioDecision.vision), "supported")
        @Expect(slashDecision.source, "built-in-model-catalog")
        @Expect(slashDecision.input, ["text", "image"])
    }

    @TestCase
    public func knownQwenTextModelIsRejectedByCatalogMetadata(): Unit {
        let decision = resolveModelImageCapability("qwen/qwen3-coder-plus")

        @Expect(decision.normalizedRef, "dashscope:qwen3-coder-plus")
        @Expect(modelVisionSupportToString(decision.vision), "unsupported")
        @Expect(decision.source, "built-in-model-catalog")
        @Expect(decision.input, ["text"])
    }

    @TestCase
    public func unknownQwenVlLookingNameDoesNotBecomeVisionBySubstring(): Unit {
        let decision = resolveModelImageCapability("qwen/custom-vl-looking-name")

        @Expect(decision.normalizedRef, "dashscope:custom-vl-looking-name")
        @Expect(modelVisionSupportToString(decision.vision), "unknown")
        @Expect(decision.source, "unknown")
    }

    @TestCase
    public func qwenCatalogMetadataIncludesKimiAndQwenVlDefault(): Unit {
        let kimi = resolveModelImageCapability("qwen/kimi-k2.5")
        let qwenVlDefault = resolveModelImageCapability("qwen/qwen-vl-max-latest")

        @Expect(modelVisionSupportToString(kimi.vision), "supported")
        @Expect(kimi.input, ["text", "image"])
        @Expect(modelVisionSupportToString(qwenVlDefault.vision), "supported")
        @Expect(qwenVlDefault.source, "built-in-model-catalog")
    }

    @TestCase
    public func explicitConfigCapabilitiesOverrideUnknownProviderHeuristic(): Unit {
        let entry = JsonObject()
        entry.put("provider", JsonString("custom"))
        entry.put("model", JsonString("vision-x"))
        entry.put("capabilities", JsonArray([JsonString("image")]))

        let decision = resolveModelImageCapabilityFromEntry(entry)

        @Expect(decision.normalizedRef, "custom:vision-x")
        @Expect(modelVisionSupportToString(decision.vision), "supported")
        @Expect(decision.source, "explicit-config")
        @Expect(decision.input, ["image"])
    }

    @TestCase
    public func unknownModelWithoutExplicitImageInputIsUnsupported(): Unit {
        let entry = JsonObject()
        entry.put("provider", JsonString("custom"))
        entry.put("model", JsonString("text-x"))

        let decision = resolveModelImageCapabilityFromEntry(entry)

        @Expect(decision.normalizedRef, "custom:text-x")
        @Expect(modelVisionSupportToString(decision.vision), "unknown")
        @Expect(decision.reason.contains("capability is unknown"), true)
    }

    @TestCase
    public func capabilityDecisionJsonIncludesInputMetadata(): Unit {
        let json = modelCapabilityDecisionToJson(resolveModelImageCapability("qwen/qwen3.6-plus"))

        @Expect(modelCapabilityTestStringArray(json, "input"), ["text", "image"])
        @Expect(json.get("source").getOrThrow().asString().getValue(), "built-in-model-catalog")
    }

    @TestCase
    public func configuredProviderModelInputMetadataFeedsResolverWithoutSecrets(): Unit {
        let rootPath = Path("/tmp/metis-model-capability-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        try { remove(rootPath, recursive: true) } catch (_: Exception) { () }
        Directory.create(rootPath, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", rootPath.toString())
        MetisConfigManager.invalidate()
        try {
            let root = JsonObject()
            let models = JsonObject()
            let providers = JsonObject()
            let custom = JsonObject()
            custom.put("apiKey", JsonString("secret-provider-key"))
            custom.put("Authorization", JsonString("Bearer secret-token"))
            let entries = JsonArray([])
            entries.add(modelCapabilityTestEntry("vision-x", ["text", "image"]))
            entries.add(modelCapabilityTestEntry("text-x", ["text"]))
            custom.put("models", entries)
            providers.put("custom", custom)
            models.put("providers", providers)
            root.put("models", models)
            MetisConfigManager.writeRoot(root)

            let vision = resolveModelImageCapability("custom/vision-x")
            let text = resolveModelImageCapability("custom/text-x")
            let missing = resolveModelImageCapability("custom/missing-x")
            let visionJson = modelCapabilityDecisionToJson(vision).toJsonString()

            @Expect(modelVisionSupportToString(vision.vision), "supported")
            @Expect(vision.source, "models.providers.custom.models")
            @Expect(vision.input, ["text", "image"])
            @Expect(modelVisionSupportToString(text.vision), "unsupported")
            @Expect(text.source, "models.providers.custom.models")
            @Expect(text.input, ["text"])
            @Expect(modelVisionSupportToString(missing.vision), "unknown")
            @Expect(visionJson.contains("secret-provider-key"), false)
            @Expect(visionJson.contains("secret-token"), false)
            @Expect(visionJson.contains("Authorization"), false)
        } finally {
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            MetisConfigManager.invalidate()
            try { remove(rootPath, recursive: true) } catch (_: Exception) { () }
        }
    }
}
