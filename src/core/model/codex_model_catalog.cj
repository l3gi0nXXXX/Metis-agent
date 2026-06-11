package metis.core.model

import std.collection.ArrayList
import std.fs.{File, Path, exists}
import stdx.encoding.json.{JsonArray, JsonObject, JsonValue}

public struct CodexModelCatalogEntry {
    public CodexModelCatalogEntry(
        public let modelId: String,
        public let visibility: String,
        public let supportedInApi: Bool
    ) {}
}

public struct CodexModelCatalogResolution {
    public CodexModelCatalogResolution(
        public let modelIds: Array<String>,
        public let source: String
    ) {}
}

public func codexStaticModelCatalog(): Array<String> {
    [
        "gpt-5.5",
        "gpt-5.4-mini",
        "gpt-5.4",
        "gpt-5.3-codex",
        "gpt-5.3-codex-spark"
    ]
}

public func codexForwardCompatModelCatalog(base: Array<String>): Array<String> {
    let out = ArrayList<String>()
    let normalizedBase = codexNormalizeModelIds(base)
    for (preferred in codexStaticModelCatalog()) {
        if (!out.contains(preferred)) {
            out.add(preferred)
        }
    }
    for (item in normalizedBase) {
        if (!out.contains(item) && !codexModelCatalogIsDeprecated(item)) {
            out.add(item)
        }
    }
    out.toArray()
}

public func codexResolveModelIds(accessToken!: Option<String> = None<String>, codexHome!: Option<String> = None<String>): CodexModelCatalogResolution {
    match (codexHome) {
        case Some(homeText) =>
            let home = Path(homeText)
            let configPath = home.join("config.toml")
            if (exists(configPath)) {
                let ids = codexModelIdsFromConfigToml(String.fromUtf8(File.readFrom(configPath)))
                if (!ids.isEmpty()) {
                    return CodexModelCatalogResolution(codexForwardCompatModelCatalog(ids), "config.toml")
                }
            }
            let cachePath = home.join("models_cache.json")
            if (exists(cachePath)) {
                let ids = codexModelIdsFromCacheJson(String.fromUtf8(File.readFrom(cachePath)))
                if (!ids.isEmpty()) {
                    return CodexModelCatalogResolution(codexForwardCompatModelCatalog(ids), "models_cache.json")
                }
            }
        case None => ()
    }
    CodexModelCatalogResolution(codexStaticModelCatalog(), "static")
}

public func codexResolveModelIdsFromSources(
    liveIds!: Array<String> = Array<String>(),
    configText!: String = "",
    cacheText!: String = ""
): CodexModelCatalogResolution {
    let live = codexNormalizeModelIds(liveIds)
    if (!live.isEmpty()) {
        return CodexModelCatalogResolution(codexForwardCompatModelCatalog(live), "live")
    }
    let config = codexModelIdsFromConfigToml(configText)
    if (!config.isEmpty()) {
        return CodexModelCatalogResolution(codexForwardCompatModelCatalog(config), "config.toml")
    }
    let cache = codexModelIdsFromCacheJson(cacheText)
    if (!cache.isEmpty()) {
        return CodexModelCatalogResolution(codexForwardCompatModelCatalog(cache), "models_cache.json")
    }
    CodexModelCatalogResolution(codexStaticModelCatalog(), "static")
}

public func codexNormalizeModelId(providerId: String, modelRef: String): String {
    var value = modelRef.trimAscii()
    if (value.contains(":")) {
        let parts = value.split(":")
        if (parts.size >= 2) {
            value = String.join(parts[1..parts.size], delimiter: ":").trimAscii()
        }
    } else if (value.contains("/")) {
        let parts = value.split("/")
        if (parts.size >= 2) {
            value = String.join(parts[1..parts.size], delimiter: "/").trimAscii()
        }
    }
    value
}

public func codexFilterVisibleModels(entries: Array<CodexModelCatalogEntry>): Array<CodexModelCatalogEntry> {
    let out = ArrayList<CodexModelCatalogEntry>()
    for (entry in entries) {
        let id = codexNormalizeModelId("openai-codex", entry.modelId)
        let visibility = entry.visibility.trimAscii().toAsciiLower()
        if (id.isEmpty() || visibility == "hide" || visibility == "hidden" || codexModelCatalogIsDeprecated(id)) {
            continue
        }
        out.add(CodexModelCatalogEntry(id, entry.visibility, entry.supportedInApi))
    }
    out.toArray()
}

public func codexModelIdsFromEntries(entries: Array<CodexModelCatalogEntry>): Array<String> {
    let out = ArrayList<String>()
    for (entry in codexFilterVisibleModels(entries)) {
        if (!out.contains(entry.modelId)) {
            out.add(entry.modelId)
        }
    }
    out.toArray()
}

public func codexDefaultModelForEmptyRuntimeModel(providerId: String, currentModel: String, catalog: Array<String>): String {
    if (providerId.trimAscii().toAsciiLower() != "openai-codex" || !currentModel.trimAscii().isEmpty()) {
        return currentModel.trimAscii()
    }
    let normalized = codexNormalizeModelIds(catalog)
    if (!normalized.isEmpty()) {
        return normalized[0]
    }
    "gpt-5.3-codex"
}

private func codexNormalizeModelIds(values: Array<String>): Array<String> {
    let out = ArrayList<String>()
    for (value in values) {
        let normalized = codexNormalizeModelId("openai-codex", value)
        if (!normalized.isEmpty() && !codexModelCatalogIsDeprecated(normalized) && !out.contains(normalized)) {
            out.add(normalized)
        }
    }
    out.toArray()
}

private func codexModelCatalogIsDeprecated(modelId: String): Bool {
    let lower = modelId.trimAscii().toAsciiLower()
    lower == "gpt-5.2-codex" || lower == "gpt-5.2-codex-spark"
}

private func codexModelIdsFromConfigToml(text: String): Array<String> {
    let out = ArrayList<String>()
    for (rawLine in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")) {
        let line = rawLine.trimAscii()
        if (line.isEmpty() || line.startsWith("#") || !line.contains("=")) {
            continue
        }
        let parts = line.split("=")
        if (parts.size < 2) {
            continue
        }
        let key = parts[0].trimAscii().toAsciiLower().replace("-", "_")
        if (key != "model" && key != "model_id" && key != "default_model") {
            continue
        }
        let value = codexUnquoteTomlValue(String.join(parts[1..parts.size], delimiter: "="))
        let normalized = codexNormalizeModelId("openai-codex", value)
        if (!normalized.isEmpty() && !out.contains(normalized) && !codexModelCatalogIsDeprecated(normalized)) {
            out.add(normalized)
        }
    }
    out.toArray()
}

private func codexModelIdsFromCacheJson(text: String): Array<String> {
    let trimmed = text.trimAscii()
    if (trimmed.isEmpty()) {
        return Array<String>()
    }
    try {
        let root = JsonValue.fromStr(trimmed)
        return codexModelIdsFromJsonValue(root)
    } catch (_: Exception) {
        Array<String>()
    }
}

private func codexModelIdsFromJsonValue(value: JsonValue): Array<String> {
    try {
        return codexModelIdsFromJsonArray(value.asArray())
    } catch (_: Exception) {
        ()
    }
    try {
        let obj = value.asObject()
        match (obj.get("models")) {
            case Some(models) => return codexModelIdsFromJsonValue(models)
            case None => ()
        }
        match (obj.get("data")) {
            case Some(data) => return codexModelIdsFromJsonValue(data)
            case None => ()
        }
    } catch (_: Exception) {
        ()
    }
    Array<String>()
}

private func codexModelIdsFromJsonArray(arr: JsonArray): Array<String> {
    let entries = ArrayList<CodexModelCatalogEntry>()
    for (item in arr.getItems()) {
        try {
            entries.add(CodexModelCatalogEntry(item.asString().getValue(), "", true))
            continue
        } catch (_: Exception) {
            ()
        }
        try {
            let obj = item.asObject()
            let id = codexJsonString(obj, "id") ?? codexJsonString(obj, "model") ?? codexJsonString(obj, "name") ?? ""
            let visibility = codexJsonString(obj, "visibility").getOrDefault { "" }
            let supported = codexJsonBool(obj, "supported_in_api").getOrDefault { true }
            entries.add(CodexModelCatalogEntry(id, visibility, supported))
        } catch (_: Exception) {
            ()
        }
    }
    codexModelIdsFromEntries(entries.toArray())
}

private func codexJsonString(obj: JsonObject, key: String): Option<String> {
    match (obj.get(key)) {
        case Some(value) =>
            try {
                Some(value.asString().getValue().trimAscii())
            } catch (_: Exception) {
                None
            }
        case None => None
    }
}

private func codexJsonBool(obj: JsonObject, key: String): Option<Bool> {
    match (obj.get(key)) {
        case Some(value) =>
            try {
                Some(value.asBool().getValue())
            } catch (_: Exception) {
                None
            }
        case None => None
    }
}

private func codexUnquoteTomlValue(raw: String): String {
    var value = raw.trimAscii()
    match (value.indexOf("#")) {
        case Some(idx) => value = value[0..idx].trimAscii()
        case None => ()
    }
    if (value.size >= 2) {
        if ((value.startsWith("\"") && value.endsWith("\"")) || (value.startsWith("'") && value.endsWith("'"))) {
            return value[1..value.size - 1]
        }
    }
    value
}
