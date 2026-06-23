package metis.gateway.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*

import metis.core.TavilySearchClient
import metis.core.config.MetisConfigManager
import metis.core.metisSafeRuneEllipsis

import std.collection.ArrayList
import std.env.getVariable
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}

public let GATEWAY_TOOL_WEB_SEARCH = "web_search"
public let GATEWAY_TOOL_WEB_FETCH = "web_fetch"
public let GATEWAY_TOOL_WEB_EXTRACT = "web_extract"

private func gatewayWebConfiguredTavilyApiKey(): String {
    let configured = MetisConfigManager.readTavilyApiKey().trimAscii()
    if (!configured.isEmpty()) {
        return configured
    }
    match (getVariable("TAVILY_API_KEY")) {
        case Some(value) => value.trimAscii()
        case None => ""
    }
}

public func gatewayWebHumanDiagnostic(code: String, message: String): String {
    let safeCode = if (code.trimAscii().isEmpty()) { "web_error" } else { code.trimAscii() }
    let safeMessage = metisSafeRuneEllipsis(message.replace("\r", " ").replace("\n", " ").trimAscii(), 240)
    "Status: error\nDiagnostic: code=${safeCode} message=${safeMessage}"
}

private func gatewayWebProviderDiagnostic(resolution: GatewayWebProviderResolution): String {
    gatewayWebHumanDiagnostic(
        if (resolution.status.trimAscii().isEmpty()) { "web_provider_unavailable" } else { resolution.status },
        if (resolution.message.trimAscii().isEmpty()) { "Web provider is unavailable." } else { resolution.message }
    )
}

private func gatewayWebSearchLimit(limit: Option<Int64>): Int64 {
    match (limit) {
        case Some(value) => max(1, min(10, value))
        case None => 5
    }
}

private func gatewayWebOptionalLower(value: Option<String>): String {
    match (value) {
        case Some(raw) => raw.trimAscii().toAsciiLower().replace("-", "_")
        case None => ""
    }
}

private func gatewayWebValidateSearchTopic(topic: Option<String>): Option<String> {
    let normalized = gatewayWebOptionalLower(topic)
    if (normalized.isEmpty() || normalized == "general" || normalized == "news") {
        return None<String>
    }
    Some("unsupported topic '${normalized}'")
}

private func gatewayWebValidateSearchTimeRange(timeRange: Option<String>): Option<String> {
    let normalized = gatewayWebOptionalLower(timeRange)
    if (normalized.isEmpty() ||
        normalized == "day" ||
        normalized == "week" ||
        normalized == "month" ||
        normalized == "year") {
        return None<String>
    }
    Some("unsupported time_range '${normalized}'")
}

private func gatewayWebFetchMaxChars(maxChars: Option<Int64>): Int64 {
    match (maxChars) {
        case Some(value) => max(256, min(50_000, value))
        case None => 12_000
    }
}

private func gatewayWebFetchFormat(mode: Option<String>): String {
    let normalized = gatewayWebOptionalLower(mode)
    if (normalized == "markdown") {
        return "markdown"
    }
    "text"
}

private func gatewayWebFetchAndExtract(url: String, format: String, maxChars: Int64): String {
    let fetch = gatewayWebFetchUrl(GatewayWebFetchRequest(url))
    let extracted = gatewayWebExtractText(fetch, format, maxChars)
    gatewayWebRenderExtractResult(extracted)
}

private func gatewayWebUrlsFromJson(raw: String): (Bool, Array<String>, String) {
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty()) {
        return (false, [], "urls_json is empty")
    }
    if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
        return (true, [trimmed], "")
    }
    let parsed = try {
        JsonValue.fromStr(trimmed)
    } catch (e: Exception) {
        return (false, [], "urls_json is not valid JSON or a single URL")
    }
    let urls = ArrayList<String>()
    match (parsed) {
        case arr: JsonArray =>
            for (i in 0..arr.size()) {
                match (arr[i]) {
                    case str: JsonString =>
                        let value = str.getValue().trimAscii()
                        if (!value.isEmpty()) {
                            urls.add(value)
                        }
                    case _ => return (false, [], "urls_json array must contain only strings")
                }
            }
        case obj: JsonObject =>
            match (obj.get("urls")) {
                case Some(value) =>
                    match (value) {
                        case arr: JsonArray =>
                            for (i in 0..arr.size()) {
                                match (arr[i]) {
                                    case str: JsonString =>
                                        let item = str.getValue().trimAscii()
                                        if (!item.isEmpty()) {
                                            urls.add(item)
                                        }
                                    case _ => return (false, [], "urls field must contain only strings")
                                }
                            }
                        case _ => return (false, [], "urls field must be an array")
                    }
                case None => return (false, [], "urls_json object must contain urls array")
            }
        case _ => return (false, [], "urls_json must be a JSON array, object with urls, or single URL")
    }
    if (urls.size == 0) {
        return (false, [], "no URLs provided")
    }
    return (true, urls.toArray(), "")
}

@toolset
public class GatewayWebToolset {
    private func webSearchInternal(query: String, limit: Option<Int64>, topic: Option<String>, timeRange: Option<String>): String {
        if (!isGatewayToolAllowed(GATEWAY_TOOL_WEB_SEARCH)) {
            return gatewayWebHumanDiagnostic("web_tool_denied", "Tool web_search has been disabled by gateway.tools policy.")
        }
        let safeQuery = query.trimAscii()
        if (safeQuery.isEmpty()) {
            return gatewayWebHumanDiagnostic("web_search_invalid_query", "Search query cannot be empty.")
        }
        match (gatewayWebValidateSearchTopic(topic)) {
            case Some(message) => return gatewayWebHumanDiagnostic("web_search_invalid_topic", message)
            case None => ()
        }
        match (gatewayWebValidateSearchTimeRange(timeRange)) {
            case Some(message) => return gatewayWebHumanDiagnostic("web_search_invalid_time_range", message)
            case None => ()
        }
        let provider = resolveGatewayWebProvider("search")
        if (!provider.available || !provider.supportsSearch) {
            return gatewayWebProviderDiagnostic(provider)
        }
        let apiKey = gatewayWebConfiguredTavilyApiKey()
        if (apiKey.isEmpty()) {
            return gatewayWebHumanDiagnostic(
                "web_provider_unavailable",
                "Real-time web search is unavailable because Tavily API key is not configured."
            )
        }
        let client = TavilySearchClient(apiKey)
        let response = try {
            client.search(safeQuery, maxResults: gatewayWebSearchLimit(limit))
        } catch (e: Exception) {
            return gatewayWebHumanDiagnostic("web_search_failed", e.message)
        }
        "Status: ok\nTool: web_search\nProvider: ${provider.providerId}\n\n" + client.renderSearchResponse(response)
    }

    private func webFetchInternal(url: String, extractMode: Option<String>, maxChars: Option<Int64>): String {
        if (!isGatewayToolAllowed(GATEWAY_TOOL_WEB_FETCH)) {
            return gatewayWebHumanDiagnostic("web_tool_denied", "Tool web_fetch has been disabled by gateway.tools policy.")
        }
        let provider = resolveGatewayWebProvider("fetch")
        if (!provider.available || !provider.supportsFetch) {
            return gatewayWebProviderDiagnostic(provider)
        }
        gatewayWebFetchAndExtract(url, gatewayWebFetchFormat(extractMode), gatewayWebFetchMaxChars(maxChars))
    }

    private func webExtractInternal(urlsJson: String, format: Option<String>, maxChars: Option<Int64>): String {
        if (!isGatewayToolAllowed(GATEWAY_TOOL_WEB_EXTRACT)) {
            return gatewayWebHumanDiagnostic("web_tool_denied", "Tool web_extract has been disabled by gateway.tools policy.")
        }
        let provider = resolveGatewayWebProvider("extract")
        if (!provider.available || !provider.supportsExtract) {
            return gatewayWebProviderDiagnostic(provider)
        }
        let parsed = gatewayWebUrlsFromJson(urlsJson)
        if (!parsed[0]) {
            return gatewayWebHumanDiagnostic("web_extract_invalid_urls", parsed[2])
        }
        let urls = parsed[1]
        let out = ArrayList<String>()
        out.add("Status: ok")
        out.add("Tool: web_extract")
        out.add("Provider: ${provider.providerId}")
        out.add("")
        for (i in 0..urls.size) {
            out.add("## URL ${i + 1}")
            out.add(gatewayWebFetchAndExtract(urls[i], gatewayWebFetchFormat(format), gatewayWebFetchMaxChars(maxChars)))
            if (i + 1 < urls.size) {
                out.add("")
            }
        }
        String.join(out.toArray(), delimiter: "\n")
    }

    @tool[
        description: "Search the public web for current information through Metis configured web provider. Use for latest news, current facts, or source discovery. Returns human-readable search results or a fail-closed diagnostic.",
        parameters: {
            query: "Search query string.",
            limit: "Optional max result count. Clamped to 1..10.",
            topic: "Optional topic: general or news. Unsupported values return a diagnostic.",
            time_range: "Optional time range hint: day, week, month, or year. Unsupported values return a diagnostic."
        }
    ]
    public func web_search(query: String, limit: Option<Int64>, topic: Option<String>, time_range: Option<String>): String {
        this.webSearchInternal(query, limit, topic, time_range)
    }

    @tool[
        description: "Fetch and extract readable text from one public HTTP/HTTPS URL with SSRF and secret-URL guardrails. Returns external content wrapped as untrusted text or a diagnostic.",
        parameters: {
            url: "Public http or https URL.",
            extract_mode: "Optional extraction mode: text or markdown. Current output is readable text for both modes.",
            max_chars: "Optional maximum characters to return. Clamped to 256..50000."
        }
    ]
    public func web_fetch(url: String, extract_mode: Option<String>, max_chars: Option<Int64>): String {
        this.webFetchInternal(url, extract_mode, max_chars)
    }

    @tool[
        description: "Fetch and extract readable text from one or more public HTTP/HTTPS URLs. Input can be a JSON string array, an object with urls, or a single URL. Each URL is isolated; one failure does not block the others.",
        parameters: {
            urls_json: "JSON array of URL strings, object {\"urls\":[...]}, or a single http/https URL.",
            format: "Optional extraction format: text or markdown. Current output is readable text for both formats.",
            max_chars: "Optional maximum characters per URL. Clamped to 256..50000."
        }
    ]
    public func web_extract(urls_json: String, format: Option<String>, max_chars: Option<Int64>): String {
        this.webExtractInternal(urls_json, format, max_chars)
    }

    public func webSearchForTest(query: String, limit: Option<Int64>, topic: Option<String>, timeRange: Option<String>): String {
        this.webSearchInternal(query, limit, topic, timeRange)
    }

    public func webFetchForTest(url: String, extractMode: Option<String>, maxChars: Option<Int64>): String {
        this.webFetchInternal(url, extractMode, maxChars)
    }

    public func webExtractForTest(urlsJson: String, format: Option<String>, maxChars: Option<Int64>): String {
        this.webExtractInternal(urlsJson, format, maxChars)
    }
}
