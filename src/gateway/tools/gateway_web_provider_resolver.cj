package metis.gateway.tools

import metis.core.config.MetisConfigManager

import std.env.getVariable
import std.sync.Mutex

public class GatewayWebProviderResolution {
    public let providerId: String
    public let available: Bool
    public let status: String
    public let message: String
    public let supportsSearch: Bool
    public let supportsFetch: Bool
    public let supportsExtract: Bool

    public init(
        providerId!: String = "",
        available!: Bool = false,
        status!: String = "web_provider_unavailable",
        message!: String = "",
        supportsSearch!: Bool = false,
        supportsFetch!: Bool = false,
        supportsExtract!: Bool = false
    ) {
        this.providerId = providerId.trimAscii()
        this.available = available
        this.status = status.trimAscii()
        this.message = message.trimAscii()
        this.supportsSearch = supportsSearch
        this.supportsFetch = supportsFetch
        this.supportsExtract = supportsExtract
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
            supportsSearch: true
        )
    }
    GatewayWebProviderResolution(
        providerId: "tavily",
        available: false,
        status: "web_provider_unavailable",
        message: "Real-time web search is unavailable because Tavily API key is not configured.",
        supportsSearch: true
    )
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
        case "search" | "web_search" => resolveTavilyProviderAvailability()
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
