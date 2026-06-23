package metis.core.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*
import magic.log.LogUtils

import metis.core.config.MetisConfigManager
import metis.io.PrintUtils

import std.env.getVariable

@toolset
public class SearchToolset {
    public init() {}

    @tool[
        description: "Use Tavily for web search to get the latest online information. Returns 5 results by default, includes AI summary answers, with basic search depth",
        parameters: {
            query: "Search query string"
        }
    ]
    public func search(query: String): String {
        PrintUtils.printTool("Tavily Search", shortMessage: query)
        let tool = TavilyTool()
        return tool.search(query)
    }
}

class TavilyTool {
    private let apiKey: String
    private let client: TavilySearchClient

    public TavilyTool() {
        let configured = MetisConfigManager.readTavilyApiKey().trimAscii()
        this.apiKey = if (!configured.isEmpty()) {
            configured
        } else {
            getVariable("TAVILY_API_KEY") ?? ""
        }
        if (this.apiKey.isEmpty()) {
            throw Exception("Tavily API key is not set (tools.search.tavily.apiKey / TAVILY_API_KEY)")
        }
        this.client = TavilySearchClient(this.apiKey)
    }

    public func search(query: String): String {
        if (query.trimAscii().isEmpty()) {
            return "Search query cannot be empty"
        }
        try {
            return this.client.renderSearchResponse(this.client.search(query))
        } catch (e: Exception) {
            LogUtils.error("Tavily search failed: ${e.message}")
            return "Search failed: ${e.message}"
        }
    }
}
