package metis.core.config

public struct OpenAICodexSetupModelChoiceResult {
    public OpenAICodexSetupModelChoiceResult(
        public let status: String,
        public let shouldLogin: Bool,
        public let forceNewLogin: Bool,
        public let providerId: String,
        public let baseUrl: String,
        public let modelId: String,
        public let transcript: Array<String>
    ) {}
}

public func openAICodexSetupModelChoice(
    authStatus: String,
    userChoice: String,
    selectedModel: String,
    catalog: Array<String>
): OpenAICodexSetupModelChoiceResult {
    let status = authStatus.trimAscii().toAsciiLower().replace("-", "_")
    let choice = userChoice.trimAscii().toAsciiLower().replace("-", "_")
    let loggedIn = providerIsConfigured("openai-codex", status)
    let transcript = if (loggedIn) {
        if (choice == "reauth" || choice == "relogin") {
            ["auth_status", "reauth", "catalog", "validate", "persist"]
        } else if (choice == "cancel") {
            ["auth_status", "cancel"]
        } else {
            ["auth_status", "use_existing", "catalog", "validate", "persist"]
        }
    } else {
        ["auth_status", "login", "catalog", "validate", "persist"]
    }
    if (loggedIn && choice == "cancel") {
        return OpenAICodexSetupModelChoiceResult(
            "canceled",
            false,
            false,
            "",
            "",
            "",
            transcript
        )
    }
    let shouldLogin = !loggedIn || choice == "reauth" || choice == "relogin"
    let forceNewLogin = loggedIn && (choice == "reauth" || choice == "relogin")
    let requested = if (selectedModel.trimAscii().isEmpty()) {
        openAICodexSetupDefaultModel(catalog)
    } else {
        selectedModel
    }
    let modelId = openAICodexSetupValidateModelChoice(requested, catalog)
    OpenAICodexSetupModelChoiceResult(
        "persisted",
        shouldLogin,
        forceNewLogin,
        "openai-codex",
        codexProviderDefaultBaseUrl("openai-codex"),
        modelId,
        transcript
    )
}

private func openAICodexSetupDefaultModel(catalog: Array<String>): String {
    if (!catalog.isEmpty()) {
        let normalized = openAICodexSetupNormalizeModel(catalog[0])
        if (!normalized.isEmpty()) {
            return normalized
        }
    }
    "gpt-5.3-codex"
}

private func openAICodexSetupValidateModelChoice(requested: String, catalog: Array<String>): String {
    let normalized = openAICodexSetupNormalizeModel(requested)
    for (candidate in catalog) {
        let canonical = openAICodexSetupNormalizeModel(candidate)
        if (canonical == normalized) {
            return canonical
        }
    }
    let loose = normalized.trimAscii().toAsciiLower().replace("_", "-").replace(" ", "-")
    for (candidate in catalog) {
        let canonical = openAICodexSetupNormalizeModel(candidate)
        if (canonical.trimAscii().toAsciiLower().replace("_", "-").replace(" ", "-") == loose) {
            return canonical
        }
    }
    normalized
}

private func openAICodexSetupNormalizeModel(modelRef: String): String {
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
