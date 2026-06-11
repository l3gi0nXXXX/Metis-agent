package metis.core.model

public struct CodexModelChoiceValidationResult {
    public CodexModelChoiceValidationResult(
        public let status: String,
        public let modelId: String,
        public let warning: String
    ) {}
}

public func codexValidateModelChoice(requested: String, catalog: Array<String>): CodexModelChoiceValidationResult {
    let normalized = codexNormalizeExplicitModelForOpenAICodex(requested)
    if (normalized.isEmpty()) {
        return CodexModelChoiceValidationResult("acceptedWithWarning", normalized, "empty model choice")
    }
    for (candidate in catalog) {
        let canonicalCandidate = codexNormalizeExplicitModelForOpenAICodex(candidate)
        if (canonicalCandidate == normalized) {
            return CodexModelChoiceValidationResult("accepted", canonicalCandidate, "")
        }
    }
    let loose = codexLooseModelKey(normalized)
    for (candidate in catalog) {
        let canonicalCandidate = codexNormalizeExplicitModelForOpenAICodex(candidate)
        if (codexLooseModelKey(canonicalCandidate) == loose) {
            return CodexModelChoiceValidationResult("corrected", canonicalCandidate, "model spelling normalized")
        }
    }
    CodexModelChoiceValidationResult("acceptedWithWarning", normalized, "model not found in current Codex catalog")
}

public func codexNormalizeExplicitModelForOpenAICodex(modelRef: String): String {
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

public func codexDefaultModelForUntouchedDefault(catalog: Array<String>): String {
    if (!catalog.isEmpty()) {
        let normalized = codexNormalizeExplicitModelForOpenAICodex(catalog[0])
        if (!normalized.isEmpty()) {
            return normalized
        }
    }
    "gpt-5.3-codex"
}

private func codexLooseModelKey(modelId: String): String {
    modelId.trimAscii().toAsciiLower().replace("_", "-").replace(" ", "-")
}
