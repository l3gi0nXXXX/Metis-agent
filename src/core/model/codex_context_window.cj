package metis.core.model

public struct CodexContextCacheEntry {
    public CodexContextCacheEntry(
        public let modelId: String,
        public let contextWindow: Int64
    ) {}
}

public func codexResolveContextWindow(
    modelId: String,
    accessToken!: Option<String> = None<String>,
    cache!: Array<CodexContextCacheEntry> = Array<CodexContextCacheEntry>()
): Int64 {
    let normalized = codexNormalizeContextModelId(modelId)
    for (entry in cache) {
        if (codexNormalizeContextModelId(entry.modelId) == normalized) {
            match (codexInvalidateStaleContextCache("openai-codex", entry.contextWindow)) {
                case Some(value) => return value
                case None => ()
            }
        }
    }
    codexContextFallback(normalized)
}

public func codexContextFallback(modelId: String): Int64 {
    let normalized = codexNormalizeContextModelId(modelId)
    if (normalized == "gpt-5.3-codex-spark" || normalized.contains("spark")) {
        return 128000
    }
    if (normalized == "gpt-5.5" || normalized == "gpt-5.4" || normalized == "gpt-5.4-mini" || normalized == "gpt-5.3-codex") {
        return 272000
    }
    272000
}

public func codexInvalidateStaleContextCache(providerId: String, cached: Int64): Option<Int64> {
    if (codexContextCanonicalProviderId(providerId) == "openai-codex" && cached >= 400000) {
        return None<Int64>
    }
    if (cached > 0) {
        return Some(cached)
    }
    None<Int64>
}

public func codexResolveDisplayContextLength(providerId: String, modelId: String): Int64 {
    if (codexContextCanonicalProviderId(providerId) != "openai-codex") {
        return 0
    }
    codexContextFallback(modelId)
}

private func codexContextCanonicalProviderId(providerId: String): String {
    let normalized = providerId.trimAscii().toAsciiLower()
    if (normalized == "codex") {
        "openai-codex"
    } else {
        normalized
    }
}

private func codexNormalizeContextModelId(modelId: String): String {
    var normalized = modelId.trimAscii().toAsciiLower()
    if (normalized.contains(":")) {
        let parts = normalized.split(":")
        if (parts.size >= 2) {
            normalized = String.join(parts[1..parts.size], delimiter: ":").trimAscii().toAsciiLower()
        }
    } else if (normalized.contains("/")) {
        let parts = normalized.split("/")
        if (parts.size >= 2) {
            normalized = String.join(parts[1..parts.size], delimiter: "/").trimAscii().toAsciiLower()
        }
    }
    normalized
}
