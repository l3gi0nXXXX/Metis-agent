package metis.core.model

import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}

public struct ModelCapabilityCatalogEntry {
    public ModelCapabilityCatalogEntry(
        public let provider: String,
        public let model: String,
        public let displayName: String,
        public let input: Array<String>,
        public let source: String
    ) {}
}

private func modelCapabilityCatalogEntry(
    provider: String,
    model: String,
    input: Array<String>,
    source: String
): ModelCapabilityCatalogEntry {
    ModelCapabilityCatalogEntry(provider, model, model, input, source)
}

private let MODEL_CAPABILITY_CATALOG_ENTRIES = [
    modelCapabilityCatalogEntry("qwen", "qwen3.5-plus", ["text", "image"], "openclaw-qwen-model-catalog"),
    modelCapabilityCatalogEntry("qwen", "qwen3.6-plus", ["text", "image"], "openclaw-qwen-model-catalog"),
    modelCapabilityCatalogEntry("qwen", "qwen3-max", ["text"], "openclaw-qwen-model-catalog"),
    modelCapabilityCatalogEntry("qwen", "qwen3-coder-next", ["text"], "openclaw-qwen-model-catalog"),
    modelCapabilityCatalogEntry("qwen", "qwen3-coder-plus", ["text"], "openclaw-qwen-model-catalog"),
    modelCapabilityCatalogEntry("qwen", "MiniMax-M2.5", ["text"], "openclaw-qwen-model-catalog"),
    modelCapabilityCatalogEntry("qwen", "glm-5", ["text"], "openclaw-qwen-model-catalog"),
    modelCapabilityCatalogEntry("qwen", "glm-4.7", ["text"], "openclaw-qwen-model-catalog"),
    modelCapabilityCatalogEntry("qwen", "kimi-k2.5", ["text", "image"], "openclaw-qwen-model-catalog"),
    modelCapabilityCatalogEntry("qwen", "qwen-vl-max-latest", ["text", "image"], "openclaw-qwen-media-default")
]

private func modelCapabilityCatalogCanonicalProvider(provider: String): String {
    let normalized = provider.trimAscii().toAsciiLower()
    match (normalized) {
        case "qwen" | "dashscope" | "modelstudio" | "bailian" | "qwencloud" => "qwen"
        case _ => normalized
    }
}

public func modelCapabilityCatalogProviderAliases(provider: String): Array<String> {
    let canonical = modelCapabilityCatalogCanonicalProvider(provider)
    match (canonical) {
        case "qwen" => ["qwen", "dashscope", "modelstudio", "bailian", "qwencloud"]
        case _ => [canonical]
    }
}

public func modelCapabilityCatalogEntrySupportsInput(entry: ModelCapabilityCatalogEntry, input: String): Bool {
    let expected = input.trimAscii().toAsciiLower()
    if (expected.isEmpty()) {
        return false
    }
    for (item in entry.input) {
        if (item.trimAscii().toAsciiLower() == expected) {
            return true
        }
    }
    false
}

public func modelCapabilityCatalogEntrySupportsImage(entry: ModelCapabilityCatalogEntry): Bool {
    modelCapabilityCatalogEntrySupportsInput(entry, "image")
}

public func findModelCapabilityCatalogEntry(provider: String, model: String): Option<ModelCapabilityCatalogEntry> {
    let canonicalProvider = modelCapabilityCatalogCanonicalProvider(provider)
    let normalizedModel = model.trimAscii().toAsciiLower()
    if (canonicalProvider.isEmpty() || normalizedModel.isEmpty()) {
        return None
    }
    for (entry in MODEL_CAPABILITY_CATALOG_ENTRIES) {
        if (
            modelCapabilityCatalogCanonicalProvider(entry.provider) == canonicalProvider &&
            entry.model.trimAscii().toAsciiLower() == normalizedModel
        ) {
            return Some(entry)
        }
    }
    None
}

public func modelCapabilityCatalogEntriesForProvider(provider: String): Array<ModelCapabilityCatalogEntry> {
    let canonicalProvider = modelCapabilityCatalogCanonicalProvider(provider)
    let out = ArrayList<ModelCapabilityCatalogEntry>()
    for (entry in MODEL_CAPABILITY_CATALOG_ENTRIES) {
        if (modelCapabilityCatalogCanonicalProvider(entry.provider) == canonicalProvider) {
            out.add(entry)
        }
    }
    out.toArray()
}

private func modelCapabilityCatalogJsonArray(values: Array<String>): JsonArray {
    let out = ArrayList<JsonValue>()
    for (value in values) {
        out.add(JsonString(value))
    }
    JsonArray(out)
}

public func modelCapabilityCatalogEntryToJson(entry: ModelCapabilityCatalogEntry): JsonObject {
    let out = JsonObject()
    out.put("provider", JsonString(entry.provider))
    out.put("model", JsonString(entry.model))
    out.put("displayName", JsonString(entry.displayName))
    out.put("input", modelCapabilityCatalogJsonArray(entry.input))
    out.put("source", JsonString(entry.source))
    out
}
