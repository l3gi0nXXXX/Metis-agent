package metis.core

import stdx.encoding.url.URL

public enum ProviderEndpointClass {
    | OpenAiPublic
    | OpenAiCompatibleCustom
    | ModelStudioCompatible
    | ModelStudioCoding
    | DashScopeAigcNative
    | AnthropicPublic
    | GoogleGenerativeAi
    | GoogleVertex
    | AzureOpenAi
    | OpenRouter
    | Local
    | Custom
    | Invalid
}

public class ProviderEndpointResolution {
    public let originalBaseUrl: String
    public let rawBaseUrl: String
    public let normalizedBaseUrl: String
    public let host: String
    public let path: String
    public let endpointClass: ProviderEndpointClass
    public let isLocal: Bool
    public let isSecure: Bool
    public let reason: String
    public let chatCompletionsUrl: String
    public let responsesUrl: String
    public let imagesGenerationsUrl: String
    public let imagesEditsUrl: String
    public let audioTranscriptionsUrl: String
    public let audioSpeechUrl: String
    public let videoGenerationsUrl: String
    public let videoTasksUrl: String
    public let diagnosticLabel: String

    public init(
        originalBaseUrl: String,
        normalizedBaseUrl: String,
        host!: String = "",
        path!: String = "",
        endpointClass!: ProviderEndpointClass = Invalid,
        isLocal!: Bool = false,
        isSecure!: Bool = false,
        reason!: String = ""
    ) {
        this.originalBaseUrl = originalBaseUrl
        this.rawBaseUrl = originalBaseUrl
        this.normalizedBaseUrl = normalizedBaseUrl
        this.host = host
        this.path = path
        this.endpointClass = endpointClass
        this.isLocal = isLocal
        this.isSecure = isSecure
        this.reason = reason
        this.chatCompletionsUrl = ""
        this.responsesUrl = ""
        this.imagesGenerationsUrl = ""
        this.imagesEditsUrl = ""
        this.audioTranscriptionsUrl = ""
        this.audioSpeechUrl = ""
        this.videoGenerationsUrl = ""
        this.videoTasksUrl = ""
        this.diagnosticLabel = providerEndpointClassId(endpointClass)
    }
}

public func normalizeProviderBaseUrl(baseUrl: String): String {
    var out = baseUrl.trimAscii()
    match (out.indexOf("?")) {
        case Some(idx) => out = out[..idx]
        case None => ()
    }
    match (out.indexOf("#")) {
        case Some(idx) => out = out[..idx]
        case None => ()
    }
    while (out.endsWith("/") && out.size > 1) {
        out = out[..out.size - 1]
    }
    out
}

public func providerEndpointClassId(endpointClass: ProviderEndpointClass): String {
    match (endpointClass) {
        case OpenAiPublic => "openai-public"
        case OpenAiCompatibleCustom => "openai-compatible-custom"
        case ModelStudioCompatible => "modelstudio-compatible"
        case ModelStudioCoding => "modelstudio-coding"
        case DashScopeAigcNative => "dashscope-aigc-native"
        case AnthropicPublic => "anthropic-public"
        case GoogleGenerativeAi => "google-generative-ai"
        case GoogleVertex => "google-vertex"
        case AzureOpenAi => "azure-openai"
        case OpenRouter => "openrouter"
        case Local => "local"
        case Custom => "custom"
        case Invalid => "invalid"
    }
}

private func providerEndpointClassIsInvalid(endpointClass: ProviderEndpointClass): Bool {
    match (endpointClass) {
        case Invalid => true
        case _ => false
    }
}

private func providerEndpointPath(parsedPath: String): String {
    var out = parsedPath.trimAscii()
    while (out.endsWith("/") && out.size > 1) {
        out = out[..out.size - 1]
    }
    out
}

private func providerEndpointIsLocalHost(host: String): Bool {
    let lower = host.toAsciiLower()
    lower == "localhost" ||
        lower == "127.0.0.1" ||
        lower == "::1" ||
        lower.endsWith(".local") ||
        lower.endsWith(".internal")
}

private func providerEndpointClassFor(kind: String, host: String, path: String, scheme: String): ProviderEndpointClass {
    let lowerKind = kind.trimAscii().toAsciiLower()
    let lowerHost = host.toAsciiLower()
    let lowerPath = path.toAsciiLower()
    if (scheme != "http" && scheme != "https") {
        return Invalid
    }
    if (providerEndpointIsLocalHost(lowerHost)) {
        return Local
    }
    if (lowerHost == "api.openai.com") {
        return OpenAiPublic
    }
    if (lowerHost == "api.anthropic.com") {
        return AnthropicPublic
    }
    if (lowerHost == "openrouter.ai") {
        return OpenRouter
    }
    if (lowerHost == "generativelanguage.googleapis.com") {
        return GoogleGenerativeAi
    }
    if (lowerHost.contains("aiplatform.googleapis.com")) {
        return GoogleVertex
    }
    if (lowerHost.endsWith(".openai.azure.com")) {
        return AzureOpenAi
    }
    if (lowerHost == "coding.dashscope.aliyuncs.com" || lowerHost == "coding-intl.dashscope.aliyuncs.com") {
        return ModelStudioCoding
    }
    if ((lowerHost == "dashscope.aliyuncs.com" || lowerHost == "dashscope-intl.aliyuncs.com") &&
        lowerPath.startsWith("/compatible-mode")) {
        return ModelStudioCompatible
    }
    if (lowerPath.startsWith("/compatible-mode")) {
        return OpenAiCompatibleCustom
    }
    if ((lowerHost == "dashscope.aliyuncs.com" || lowerHost == "dashscope-intl.aliyuncs.com") &&
        (lowerPath == "/api/v1" || lowerPath.startsWith("/api/v1/") || lowerPath == "")) {
        return DashScopeAigcNative
    }
    if (lowerKind == "anthropic") {
        return AnthropicPublic
    }
    if (lowerKind == "openai" && lowerHost.contains("openai")) {
        return OpenAiCompatibleCustom
    }
    Custom
}

public func resolveProviderEndpoint(providerKind: String, baseUrl: String): ProviderEndpointResolution {
    let normalized = normalizeProviderBaseUrl(baseUrl)
    if (normalized.isEmpty()) {
        return ProviderEndpointResolution(baseUrl, normalized, endpointClass: Invalid, reason: "empty_base_url")
    }
    try {
        let parsed = URL.parse(normalized)
        let scheme = parsed.scheme.toAsciiLower()
        let host = parsed.hostName.toAsciiLower()
        if (host.isEmpty()) {
            return ProviderEndpointResolution(baseUrl, normalized, endpointClass: Invalid, reason: "missing_host")
        }
        let path = providerEndpointPath(parsed.path)
        let endpointClass = providerEndpointClassFor(providerKind, host, path, scheme)
        let reason = if (providerEndpointClassIsInvalid(endpointClass)) { "unsupported_scheme_or_malformed_url" } else { "classified" }
        ProviderEndpointResolution(
            baseUrl,
            normalized,
            host: host,
            path: path,
            endpointClass: endpointClass,
            isLocal: providerEndpointIsLocalHost(host),
            isSecure: scheme == "https",
            reason: reason
        )
    } catch (_: Exception) {
        ProviderEndpointResolution(baseUrl, normalized, endpointClass: Invalid, reason: "malformed_url")
    }
}

public func resolveDashScopeAigcOriginForVideo(baseUrl: String): String {
    let normalized = normalizeProviderBaseUrl(baseUrl)
    try {
        let parsed = URL.parse(normalized)
        let scheme = parsed.scheme.toAsciiLower()
        let host = parsed.hostName.toAsciiLower()
        if (host == "dashscope.aliyuncs.com" ||
            host == "dashscope-intl.aliyuncs.com" ||
            host == "coding.dashscope.aliyuncs.com" ||
            host == "coding-intl.dashscope.aliyuncs.com") {
            let resolvedHost = match (host) {
                case "coding.dashscope.aliyuncs.com" => "dashscope.aliyuncs.com"
                case "coding-intl.dashscope.aliyuncs.com" => "dashscope-intl.aliyuncs.com"
                case _ => host
            }
            return "${scheme}://${resolvedHost}"
        }
    } catch (_: Exception) {
        ()
    }
    if (normalized.startsWith("https://dashscope.aliyuncs.com/compatible-mode/")) {
        return "https://dashscope.aliyuncs.com"
    }
    if (normalized.startsWith("https://dashscope-intl.aliyuncs.com/compatible-mode/")) {
        return "https://dashscope-intl.aliyuncs.com"
    }
    normalized
}
