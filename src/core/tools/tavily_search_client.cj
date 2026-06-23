package metis.core.tools

import magic.jsonable.*
import magic.utils.http.HttpUtils

import metis.core.metisSafeRuneEllipsis

import std.collection.{ArrayList, HashMap}
import std.sync.Mutex
import stdx.encoding.json.{JsonArray, JsonFloat, JsonInt, JsonNull, JsonObject, JsonString, JsonValue}

public struct TavilySearchResult {
    public let title: String
    public let url: String
    public let content: String
    public let score: Float64

    public init(title: String, url: String, content: String, score: Float64) {
        this.title = title
        this.url = url
        this.content = content
        this.score = score
    }
}

public struct TavilySearchResponse {
    public let query: String
    public let answer: Option<String>
    public let results: Array<TavilySearchResult>
    public let responseTime: Float64

    public init(query: String, answer: Option<String>, results: Array<TavilySearchResult>, responseTime: Float64) {
        this.query = query
        this.answer = answer
        this.results = results
        this.responseTime = responseTime
    }
}

public class TavilySearchHttpRequest {
    public let url: String
    public let headers: HashMap<String, String>
    public let body: JsonObject

    public init(url: String, headers: HashMap<String, String>, body: JsonObject) {
        this.url = url
        this.headers = headers
        this.body = body
    }
}

public class TavilySearchHttpResponse {
    public let statusCode: Int64
    public let body: String
    public let error: String

    public init(statusCode: Int64, body!: String = "", error!: String = "") {
        this.statusCode = statusCode
        this.body = body
        this.error = error
    }
}

private let tavilySearchRunnerLock = Mutex()
private var tavilySearchHttpRunnerForTest: Option<(TavilySearchHttpRequest) -> TavilySearchHttpResponse> =
    None<(TavilySearchHttpRequest) -> TavilySearchHttpResponse>

public func setTavilySearchHttpRunnerForTest(
    runner: Option<(TavilySearchHttpRequest) -> TavilySearchHttpResponse>
): Unit {
    synchronized(tavilySearchRunnerLock) {
        tavilySearchHttpRunnerForTest = runner
    }
}

private func tavilySearchHttpSend(request: TavilySearchHttpRequest): TavilySearchHttpResponse {
    synchronized(tavilySearchRunnerLock) {
        match (tavilySearchHttpRunnerForTest) {
            case Some(runner) => return runner(request)
            case None => ()
        }
    }
    match (HttpUtils.post(request.url, request.headers, request.body)) {
        case Some(raw) => TavilySearchHttpResponse(200, body: raw)
        case None => TavilySearchHttpResponse(0, error: "No response received from server")
    }
}

private func tavilySanitizeErrorDetail(raw: String): String {
    let text = raw.trimAscii()
    if (text.isEmpty()) {
        return ""
    }
    let lower = text.toAsciiLower()
    if (lower.contains("authorization") ||
        lower.contains("bearer ") ||
        lower.contains("token=") ||
        lower.contains("access_token") ||
        lower.contains("api_key") ||
        lower.contains("apikey") ||
        lower.contains("password") ||
        lower.contains("secret")) {
        return "Tavily request failed"
    }
    metisSafeRuneEllipsis(text, 240)
}

private func tavilyExtractString(obj: JsonObject, key: String): Option<String> {
    match (obj.get(key)) {
        case Some(value) =>
            match (value) {
                case jsonStr: JsonString => Some(jsonStr.getValue())
                case _ => None<String>
            }
        case None => None<String>
    }
}

private func tavilyExtractOptionalString(obj: JsonObject, key: String): Option<String> {
    match (obj.get(key)) {
        case Some(value) =>
            match (value) {
                case jsonStr: JsonString => Some(jsonStr.getValue())
                case _: JsonNull => None<String>
                case _ => None<String>
            }
        case None => None<String>
    }
}

private func tavilyExtractFloat(obj: JsonObject, key: String): Option<Float64> {
    match (obj.get(key)) {
        case Some(value) =>
            match (value) {
                case jsonNum: JsonInt => Some(Float64(jsonNum.getValue()))
                case jsonNum: JsonFloat => Some(jsonNum.getValue())
                case _ => None<Float64>
            }
        case None => None<Float64>
    }
}

private func tavilyParseSearchResponse(responseData: JsonValue): TavilySearchResponse {
    match (responseData) {
        case jsonObj: JsonObject =>
            let query = tavilyExtractString(jsonObj, "query") ?? ""
            let answer = tavilyExtractOptionalString(jsonObj, "answer")
            let responseTime = tavilyExtractFloat(jsonObj, "response_time") ?? 0.0
            let results = ArrayList<TavilySearchResult>()
            match (jsonObj.get("results")) {
                case Some(resultsValue) =>
                    match (resultsValue) {
                        case resultsArray: JsonArray =>
                            for (i in 0..resultsArray.size()) {
                                match (resultsArray[i]) {
                                    case objData: JsonObject =>
                                        let title = tavilyExtractString(objData, "title") ?? ""
                                        let url = tavilyExtractString(objData, "url") ?? ""
                                        let content = tavilyExtractString(objData, "content") ?? ""
                                        let score = tavilyExtractFloat(objData, "score") ?? 0.0
                                        results.add(TavilySearchResult(title, url, content, score))
                                    case _ => ()
                                }
                            }
                        case _ => ()
                    }
                case None => ()
            }
            TavilySearchResponse(query, answer, results.toArray(), responseTime)
        case _ => throw Exception("Invalid response format")
    }
}

public class TavilySearchClient {
    private let apiKey: String

    public init(apiKey: String) {
        this.apiKey = apiKey.trimAscii()
        if (this.apiKey.isEmpty()) {
            throw Exception("Tavily API key is not set (tools.search.tavily.apiKey / TAVILY_API_KEY)")
        }
    }

    public func search(
        query: String,
        maxResults!: Int64 = 5,
        includeAnswer!: Bool = true,
        searchDepth!: String = "basic"
    ): TavilySearchResponse {
        let safeQuery = query.trimAscii()
        if (safeQuery.isEmpty()) {
            throw Exception("Search query cannot be empty")
        }
        let safeMaxResults = max(1, min(20, maxResults))
        let safeDepth = match (searchDepth.trimAscii().toAsciiLower()) {
            case "advanced" => "advanced"
            case _ => "basic"
        }
        let headers = HashMap<String, String>([
            ("Content-Type", "application/json"),
            ("Authorization", "Bearer ${this.apiKey}")
        ])
        let requestMap = HashMap<String, JsonValue>()
        requestMap.add("query", JsonString(safeQuery))
        requestMap.add("max_results", safeMaxResults.toJsonValue())
        requestMap.add("include_answer", includeAnswer.toJsonValue())
        requestMap.add("search_depth", JsonString(safeDepth))
        requestMap.add("include_raw_content", false.toJsonValue())
        let request = TavilySearchHttpRequest("https://api.tavily.com/search", headers, JsonObject(requestMap))
        let response = tavilySearchHttpSend(request)
        if (response.statusCode == 0) {
            let detail = tavilySanitizeErrorDetail(response.error)
            throw Exception(if (detail.isEmpty()) { "No response received from server" } else { detail })
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
            throw Exception("HTTP status ${response.statusCode}")
        }
        let responseData = try {
            JsonValue.fromStr(response.body)
        } catch (e: Exception) {
            throw Exception("JSON parsing failed: ${e.message}")
        }
        tavilyParseSearchResponse(responseData)
    }

    public func renderSearchResponse(response: TavilySearchResponse): String {
        let results = ArrayList<String>()
        results.add("=== Tavily Search Results ===\n")
        results.add("Query: ${response.query}\n")
        results.add("Response time: ${response.responseTime}s\n\n")
        match (response.answer) {
            case Some(answer) =>
                results.add("[AI Summary Answer]\n")
                results.add("${answer}\n\n")
            case None => ()
        }
        results.add("[Search Results]\n")
        for (i in 0..response.results.size) {
            let searchResult = response.results[i]
            results.add("${i + 1}. ${searchResult.title}\n")
            results.add("   URL: ${searchResult.url}\n")
            results.add("   Relevance: ${searchResult.score}\n")
            results.add("   Content: ${searchResult.content}\n\n")
        }
        String.join(results.toArray(), delimiter: "")
    }

    public func searchAndRender(query: String): String {
        let safeQuery = query.trimAscii()
        if (safeQuery.isEmpty()) {
            return "Search query cannot be empty"
        }
        try {
            this.renderSearchResponse(this.search(safeQuery))
        } catch (e: Exception) {
            "Search failed: ${tavilySanitizeErrorDetail(e.message)}"
        }
    }
}
