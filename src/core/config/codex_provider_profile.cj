package metis.core.config

private const OPENAI_CODEX_PROVIDER_ID = "openai-codex"
private const OPENAI_CODEX_BASE_URL = "https://chatgpt.com/backend-api/codex"

public func codexCanonicalProviderId(providerId: String): String {
    let canonical = cliCanonicalModelProviderId(providerId)
    if (canonical == "codex") {
        OPENAI_CODEX_PROVIDER_ID
    } else {
        canonical
    }
}

public func codexProviderDefaultBaseUrl(providerId: String): String {
    if (codexCanonicalProviderId(providerId) == OPENAI_CODEX_PROVIDER_ID) {
        return OPENAI_CODEX_BASE_URL
    }
    match (cliFindModelProviderDescriptor(providerId)) {
        case Some(descriptor) => descriptor.defaultBaseUrl
        case None => ""
    }
}

public func codexProviderApiMode(providerId: String, baseUrl: String): String {
    if (codexCanonicalProviderId(providerId) == OPENAI_CODEX_PROVIDER_ID) {
        return "codex_responses"
    }
    match (detectApiModeForBaseUrl(baseUrl)) {
        case Some(mode) => mode
        case None => cliProviderApiMode(providerId)
    }
}

public func codexProviderAuthKind(providerId: String): String {
    if (codexCanonicalProviderId(providerId) == OPENAI_CODEX_PROVIDER_ID) {
        return "oauth_external"
    }
    cliProviderAuthKind(providerId)
}

public func codexProviderIsCodexBackend(providerId: String, baseUrl: String): Bool {
    if (codexCanonicalProviderId(providerId) == OPENAI_CODEX_PROVIDER_ID) {
        return true
    }
    codexNormalizeBaseUrl(baseUrl) == OPENAI_CODEX_BASE_URL
}

public func providerIsConfigured(providerId: String, authStatus: String): Bool {
    let status = authStatus.trimAscii().toAsciiLower().replace("-", "_")
    if (codexCanonicalProviderId(providerId) == OPENAI_CODEX_PROVIDER_ID) {
        return status == "configured" || status == "logged_in" || status == "oauth_configured"
    }
    status == "configured" || status == "logged_in" || status == "api_key_configured"
}

public func resolveProviderApiMode(configuredProvider: String, runtimeProvider: String, configuredApiMode: String): String {
    let configured = codexCanonicalProviderId(configuredProvider)
    let runtime = codexCanonicalProviderId(runtimeProvider)
    let explicit = configuredApiMode.trimAscii().toAsciiLower()
    if (configured == runtime && codexApiModeIsSupported(explicit)) {
        return explicit
    }
    cliProviderApiMode(runtime)
}

public func detectApiModeForBaseUrl(baseUrl: String): Option<String> {
    let parsed = codexParseBaseUrl(baseUrl)
    let host = parsed[0]
    let path = parsed[1]
    if (host.isEmpty()) {
        return None
    }
    if (host == "api.openai.com" || host == "api.x.ai") {
        return Some("codex_responses")
    }
    if (host == "api.kimi.com" && (path == "/coding" || path.startsWith("/coding/"))) {
        return Some("anthropic_messages")
    }
    if (path == "/anthropic" || path.endsWith("/anthropic")) {
        return Some("anthropic_messages")
    }
    None
}

private func codexApiModeIsSupported(value: String): Bool {
    value == "chat_completions" ||
        value == "codex_responses" ||
        value == "anthropic_messages" ||
        value == "codex_app_server"
}

private func codexNormalizeBaseUrl(raw: String): String {
    var value = raw.trimAscii()
    while (value.size > 1 && value.endsWith("/")) {
        value = value[..value.size - 1]
    }
    value
}

private func codexParseBaseUrl(raw: String): Array<String> {
    var rest = raw.trimAscii()
    match (rest.indexOf("://")) {
        case Some(idx) => rest = rest[idx + 3..]
        case None => ()
    }
    match (rest.indexOf("@")) {
        case Some(idx) => rest = rest[idx + 1..]
        case None => ()
    }

    var authority = rest
    var path = ""
    let slashIndex = rest.indexOf("/")
    let queryIndex = rest.indexOf("?")
    let hashIndex = rest.indexOf("#")
    var cut = rest.size
    match (slashIndex) {
        case Some(idx) => if (idx < cut) { cut = idx }
        case None => ()
    }
    match (queryIndex) {
        case Some(idx) => if (idx < cut) { cut = idx }
        case None => ()
    }
    match (hashIndex) {
        case Some(idx) => if (idx < cut) { cut = idx }
        case None => ()
    }
    authority = rest[0..cut]
    if (cut < rest.size && rest[cut..].startsWith("/")) {
        path = rest[cut..]
        match (path.indexOf("?")) {
            case Some(idx) => path = path[0..idx]
            case None => ()
        }
        match (path.indexOf("#")) {
            case Some(idx) => path = path[0..idx]
            case None => ()
        }
        while (path.size > 1 && path.endsWith("/")) {
            path = path[..path.size - 1]
        }
    }

    var host = authority
    if (host.startsWith("[")) {
        match (host.indexOf("]")) {
            case Some(idx) => host = host[0..idx + 1]
            case None => ()
        }
    } else {
        match (host.indexOf(b':')) {
            case Some(idx) => host = host[0..idx]
            case None => ()
        }
    }
    [host.trimAscii().toAsciiLower(), path.trimAscii().toAsciiLower()]
}
