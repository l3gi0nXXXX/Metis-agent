package metis.gateway.tools

import metis.core.config.MetisConfigManager

import std.env.getVariable
import std.sync.Mutex
import stdx.encoding.json.{JsonObject, JsonString}

public class GatewayWebProviderResolution {
    public let providerId: String
    public let available: Bool
    public let status: String
    public let message: String
    public let requiresCredential: Bool
    public let configured: Bool
    public let rank: Int64
    public let configPath: String
    public let envVars: Array<String>
    public let supportsSearch: Bool
    public let supportsFetch: Bool
    public let supportsExtract: Bool

    public init(
        providerId!: String = "",
        available!: Bool = false,
        status!: String = "web_provider_unavailable",
        message!: String = "",
        requiresCredential!: Bool = false,
        configured!: Bool = false,
        rank!: Int64 = 0,
        configPath!: String = "",
        envVars!: Array<String> = [],
        supportsSearch!: Bool = false,
        supportsFetch!: Bool = false,
        supportsExtract!: Bool = false
    ) {
        this.providerId = providerId.trimAscii()
        this.available = available
        this.status = status.trimAscii()
        this.message = message.trimAscii()
        this.requiresCredential = requiresCredential
        this.configured = configured
        this.rank = rank
        this.configPath = configPath.trimAscii()
        this.envVars = envVars
        this.supportsSearch = supportsSearch
        this.supportsFetch = supportsFetch
        this.supportsExtract = supportsExtract
    }
}

public class GatewayWebProviderEntry {
    public let providerId: String
    public let requiresCredential: Bool
    public let rank: Int64
    public let supportsSearch: Bool

    public init(providerId: String, requiresCredential: Bool, rank: Int64, supportsSearch!: Bool = true) {
        this.providerId = providerId.trimAscii()
        this.requiresCredential = requiresCredential
        this.rank = rank
        this.supportsSearch = supportsSearch
    }
}

private let gatewayWebProviderResolverLock = Mutex()
private var gatewayWebProviderResolverForTest: Option<(String) -> GatewayWebProviderResolution> =
    None<(String) -> GatewayWebProviderResolution>

public func setGatewayWebProviderResolverForTest(
    resolver: Option<(String) -> GatewayWebProviderResolution>
): Unit {
    synchronized(gatewayWebProviderResolverLock) {
        gatewayWebProviderResolverForTest = resolver
    }
}

private func gatewayWebProviderObject(obj: JsonObject, key: String): Option<JsonObject> {
    match (obj.get(key)) {
        case Some(value) =>
            try { Some(value.asObject()) } catch (_: Exception) { None<JsonObject> }
        case None => None<JsonObject>
    }
}

private func gatewayWebProviderString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) =>
            match (value) {
                case str: JsonString => str.getValue().trimAscii()
                case _ => ""
            }
        case None => ""
    }
}

private func gatewayWebConfiguredSearchProvider(): String {
    match (MetisConfigManager.rawConfig()) {
        case Some(root) =>
            match (gatewayWebProviderObject(root, "tools")) {
                case Some(tools) =>
                    match (gatewayWebProviderObject(tools, "web")) {
                        case Some(web) =>
                            let provider = gatewayWebProviderString(web, "searchProvider").toAsciiLower().replace("-", "_")
                            if (!provider.isEmpty()) {
                                return provider
                            }
                        case None => ()
                    }
                    match (gatewayWebProviderObject(tools, "search")) {
                        case Some(search) =>
                            let provider = gatewayWebProviderString(search, "provider").toAsciiLower().replace("-", "_")
                            if (!provider.isEmpty()) {
                                return provider
                            }
                        case None => ()
                    }
                case None => ()
            }
        case None => ()
    }
    ""
}

public func listGatewayWebSearchProviders(): Array<GatewayWebProviderEntry> {
    [
        GatewayWebProviderEntry("tavily", true, 10),
        GatewayWebProviderEntry("duckduckgo", false, 100)
    ]
}

public func resolveTavilyProviderAvailability(): GatewayWebProviderResolution {
    let configured = MetisConfigManager.readTavilyApiKey().trimAscii()
    let envKey = match (getVariable("TAVILY_API_KEY")) {
        case Some(value) => value.trimAscii()
        case None => ""
    }
    if (!configured.isEmpty() || !envKey.isEmpty()) {
        return GatewayWebProviderResolution(
            providerId: "tavily",
            available: true,
            status: "ok",
            message: "Tavily provider is configured.",
            requiresCredential: true,
            configured: true,
            rank: 10,
            configPath: "tools.search.tavily.apiKey",
            envVars: ["TAVILY_API_KEY"],
            supportsSearch: true
        )
    }
    GatewayWebProviderResolution(
        providerId: "tavily",
        available: false,
        status: "web_provider_unavailable",
        message: "Tavily web search is unavailable because Tavily API key is not configured (tools.search.tavily.apiKey / TAVILY_API_KEY).",
        requiresCredential: true,
        configured: false,
        rank: 10,
        configPath: "tools.search.tavily.apiKey",
        envVars: ["TAVILY_API_KEY"],
        supportsSearch: true
    )
}

public func resolveDuckDuckGoProviderAvailability(): GatewayWebProviderResolution {
    GatewayWebProviderResolution(
        providerId: "duckduckgo",
        available: true,
        status: "ok",
        message: "DuckDuckGo keyless web search provider is available.",
        requiresCredential: false,
        configured: true,
        rank: 100,
        supportsSearch: true
    )
}

private func resolveGatewayWebSearchProvider(): GatewayWebProviderResolution {
    let explicit = gatewayWebConfiguredSearchProvider()
    if (explicit == "tavily") {
        return resolveTavilyProviderAvailability()
    }
    if (explicit == "duckduckgo") {
        return resolveDuckDuckGoProviderAvailability()
    }
    if (!explicit.isEmpty()) {
        return GatewayWebProviderResolution(
            providerId: explicit,
            available: false,
            status: "web_provider_unsupported_provider",
            message: "Unsupported web search provider '${explicit}'. Configure tools.web.searchProvider as tavily or duckduckgo.",
            supportsSearch: true
        )
    }
    let tavily = resolveTavilyProviderAvailability()
    if (tavily.available) {
        return tavily
    }
    resolveDuckDuckGoProviderAvailability()
}

public func resolveGatewayWebProvider(capability: String): GatewayWebProviderResolution {
    let normalized = capability.trimAscii().toAsciiLower().replace("-", "_")
    synchronized(gatewayWebProviderResolverLock) {
        match (gatewayWebProviderResolverForTest) {
            case Some(resolver) => return resolver(normalized)
            case None => ()
        }
    }
    match (normalized) {
        case "search" | "web_search" => resolveGatewayWebSearchProvider()
        case "fetch" | "web_fetch" =>
            GatewayWebProviderResolution(
                providerId: "metis-native-fetch",
                available: true,
                status: "ok",
                message: "Metis native web fetch runtime is available.",
                supportsFetch: true
            )
        case "extract" | "web_extract" =>
            GatewayWebProviderResolution(
                providerId: "metis-native-fetch",
                available: true,
                status: "ok",
                message: "Metis native web extract runtime is available.",
                supportsFetch: true,
                supportsExtract: true
            )
        case _ =>
            GatewayWebProviderResolution(
                available: false,
                status: "web_provider_unsupported_capability",
                message: "Unsupported web provider capability '${normalized}'."
            )
    }
}
