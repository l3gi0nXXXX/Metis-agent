package metis.core

import metis.core.config.MetisConfigManager

import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.sync.Mutex
import std.time.*
import stdx.encoding.json.JsonInt
import stdx.net.http.*

public struct DuckDuckGoSearchResult {
    public let title: String
    public let url: String
    public let snippet: String

    public init(title: String, url: String, snippet: String) {
        this.title = title
        this.url = url
        this.snippet = snippet
    }
}

public struct DuckDuckGoSearchResponse {
    public let query: String
    public let results: Array<DuckDuckGoSearchResult>

    public init(query: String, results: Array<DuckDuckGoSearchResult>) {
        this.query = query
        this.results = results
    }
}

public class DuckDuckGoSearchHttpRequest {
    public let url: String
    public let headers: HashMap<String, String>
    public let timeoutMs: Int64
    public let maxBytes: Int64

    public init(url: String, headers: HashMap<String, String>, timeoutMs: Int64, maxBytes: Int64) {
        this.url = url.trimAscii()
        this.headers = headers
        this.timeoutMs = timeoutMs
        this.maxBytes = maxBytes
    }
}

public class DuckDuckGoSearchHttpResponse {
    public let statusCode: Int64
    public let bodyBytes: Array<Byte>
    public let error: String

    public init(statusCode: Int64, bodyBytes!: Array<Byte> = [], error!: String = "") {
        this.statusCode = statusCode
        this.bodyBytes = bodyBytes
        this.error = error.trimAscii()
    }
}

private let duckDuckGoSearchRunnerLock = Mutex()
private var duckDuckGoSearchHttpRunnerForTest: Option<(DuckDuckGoSearchHttpRequest) -> DuckDuckGoSearchHttpResponse> =
    None<(DuckDuckGoSearchHttpRequest) -> DuckDuckGoSearchHttpResponse>

public func setDuckDuckGoSearchHttpRunnerForTest(
    runner: Option<(DuckDuckGoSearchHttpRequest) -> DuckDuckGoSearchHttpResponse>
): Unit {
    synchronized(duckDuckGoSearchRunnerLock) {
        duckDuckGoSearchHttpRunnerForTest = runner
    }
}

private func duckDuckGoSearchByteHex(byte: Byte): String {
    let high = byte / 16
    let low = byte % 16
    let hi = if (high < 10) { String.fromUtf8([b'0' + high]) } else { String.fromUtf8([b'A' + (high - 10)]) }
    let lo = if (low < 10) { String.fromUtf8([b'0' + low]) } else { String.fromUtf8([b'A' + (low - 10)]) }
    "${hi}${lo}"
}

private func duckDuckGoSearchUrlEncode(raw: String): String {
    let out = StringBuilder()
    for (byte in raw.toArray()) {
        if ((byte >= b'a' && byte <= b'z') ||
            (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') ||
            byte == b'-' ||
            byte == b'_' ||
            byte == b'.' ||
            byte == b'~') {
            out.append(String.fromUtf8([byte]))
        } else if (byte == b' ') {
            out.append("+")
        } else {
            out.append("%")
            out.append(duckDuckGoSearchByteHex(byte))
        }
    }
    out.toString()
}

private func duckDuckGoSearchHexValue(ch: String): Int64 {
    let lower = ch.toAsciiLower()
    if (lower >= "0" && lower <= "9") {
        return Int64.parse(lower)
    }
    if (lower == "a") { return 10 }
    if (lower == "b") { return 11 }
    if (lower == "c") { return 12 }
    if (lower == "d") { return 13 }
    if (lower == "e") { return 14 }
    if (lower == "f") { return 15 }
    -1
}

private func duckDuckGoSearchPercentDecode(raw: String): String {
    let bytes = ArrayList<Byte>()
    let rawBytes = raw.toArray()
    var i: Int64 = 0
    while (i < raw.size) {
        let ch = raw[i..i + 1]
        if (ch == "+" ) {
            bytes.add(b' ')
            i += 1
        } else if (ch == "%" && i + 2 < raw.size) {
            let hi = duckDuckGoSearchHexValue(raw[i + 1..i + 2])
            let lo = duckDuckGoSearchHexValue(raw[i + 2..i + 3])
            if (hi >= 0 && lo >= 0) {
                bytes.add(UInt8(hi * 16 + lo))
                i += 3
            } else {
                bytes.add(rawBytes[i])
                i += 1
            }
        } else {
            bytes.add(rawBytes[i])
            i += 1
        }
    }
    try { String.fromUtf8(bytes.toArray()) } catch (_: Exception) { raw }
}

private func duckDuckGoSearchHtmlDecode(raw: String): String {
    raw
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

private func duckDuckGoSearchStripTags(raw: String): String {
    let out = StringBuilder()
    var inTag = false
    for (ch in raw.toRuneArray()) {
        if (ch == r'<') {
            inTag = true
        } else if (ch == r'>') {
            inTag = false
        } else if (!inTag) {
            out.append(ch)
        }
    }
    duckDuckGoSearchHtmlDecode(out.toString()).replace("\n", " ").replace("\r", " ").trimAscii()
}

private func duckDuckGoSearchAttrValue(raw: String, key: String): String {
    let marker = "${key}=\""
    match (raw.indexOf(marker)) {
        case Some(start) =>
            let rest = raw[start + marker.size..]
            match (rest.indexOf("\"")) {
                case Some(end) => return duckDuckGoSearchHtmlDecode(rest[..end]).trimAscii()
                case None => ()
            }
        case None => ()
    }
    ""
}

private func duckDuckGoSearchDirectUrl(href: String): String {
    let decoded = duckDuckGoSearchHtmlDecode(href.trimAscii())
    match (decoded.indexOf("uddg=")) {
        case Some(idx) =>
            var encoded = decoded[idx + 5..]
            match (encoded.indexOf("&")) {
                case Some(end) => encoded = encoded[..end]
                case None => ()
            }
            return duckDuckGoSearchPercentDecode(encoded).trimAscii()
        case None => ()
    }
    if (decoded.startsWith("//")) {
        return "https:${decoded}"
    }
    decoded
}

private func duckDuckGoSearchAnchorText(block: String): String {
    match (block.indexOf(">")) {
        case Some(start) =>
            let rest = block[start + 1..]
            match (rest.indexOf("</a>")) {
                case Some(end) => return duckDuckGoSearchStripTags(rest[..end])
                case None => ()
            }
        case None => ()
    }
    ""
}

private func duckDuckGoSearchSnippet(block: String): String {
    match (block.indexOf("result__snippet")) {
        case Some(idx) =>
            let rest = block[idx..]
            match (rest.indexOf(">")) {
                case Some(start) =>
                    let after = rest[start + 1..]
                    let end = match (after.indexOf("</a>")) {
                        case Some(value) => value
                        case None =>
                            match (after.indexOf("</div>")) {
                                case Some(value) => value
                                case None => min(after.size, 300)
                            }
                    }
                    return duckDuckGoSearchStripTags(after[..end])
                case None => ()
            }
        case None => ()
    }
    ""
}

private func duckDuckGoSearchLooksLikeChallenge(html: String): Bool {
    let lower = html.toAsciiLower()
    lower.contains("captcha") ||
        lower.contains("anomaly") ||
        lower.contains("challenge") ||
        lower.contains("verify you are a human")
}

private func duckDuckGoSearchParseHtml(query: String, html: String, limit: Int64): DuckDuckGoSearchResponse {
    if (duckDuckGoSearchLooksLikeChallenge(html)) {
        throw Exception("web_search_provider_challenge: DuckDuckGo returned a bot challenge")
    }
    let results = ArrayList<DuckDuckGoSearchResult>()
    let parts = html.split("result__a")
    for (i in 1..parts.size) {
        if (results.size >= limit) {
            break
        }
        let block = parts[i]
        let href = duckDuckGoSearchAttrValue(block, "href")
        let title = duckDuckGoSearchAnchorText(block)
        let url = duckDuckGoSearchDirectUrl(href)
        if (title.isEmpty() || url.isEmpty()) {
            continue
        }
        results.add(DuckDuckGoSearchResult(title, url, duckDuckGoSearchSnippet(block)))
    }
    DuckDuckGoSearchResponse(query, results.toArray())
}

private func duckDuckGoSearchReadLimitedBytes(response: HttpResponse, maxBytes: Int64): Array<Byte> {
    let out = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let n = response.body.read(buffer)
        if (n <= 0) {
            break
        }
        if (out.size + n > maxBytes) {
            throw Exception("DuckDuckGo response exceeds maxBytes")
        }
        out.add(all: buffer[..n])
    }
    out.toArray()
}

private func duckDuckGoSearchNativeSend(request: DuckDuckGoSearchHttpRequest): DuckDuckGoSearchHttpResponse {
    let transportConfigObject = MetisConfigManager.readWebHttpTransportConfig()
    transportConfigObject.put("timeoutMs", JsonInt(request.timeoutMs))
    let transportConfig = resolveGatewayProviderHttpTransportConfig(transportConfigObject)
    let route = resolveGatewayProviderHttpRoute(request.url, transportConfig)
    let builder = try {
        buildGatewayProviderHttpClientBuilder(request.url, transportConfig)[0]
    } catch (e: Exception) {
        return DuckDuckGoSearchHttpResponse(0, error: e.message)
    }
    builder.readTimeout(Duration.millisecond * request.timeoutMs)
    let client = builder.build()
    try {
        var reqBuilder = HttpRequestBuilder()
            .url(request.url)
            .get()
            .header("Accept", "text/html, application/xhtml+xml, text/plain")
        for ((key, value) in request.headers) {
            reqBuilder = reqBuilder.header(key, value)
        }
        let response = client.send(reqBuilder.build())
        DuckDuckGoSearchHttpResponse(Int64(response.status), bodyBytes: duckDuckGoSearchReadLimitedBytes(response, request.maxBytes))
    } catch (e: Exception) {
        DuckDuckGoSearchHttpResponse(0, error: if (route.error.isEmpty()) { e.message } else { route.error })
    } finally {
        client.close()
    }
}

private func duckDuckGoSearchHttpSend(request: DuckDuckGoSearchHttpRequest): DuckDuckGoSearchHttpResponse {
    synchronized(duckDuckGoSearchRunnerLock) {
        match (duckDuckGoSearchHttpRunnerForTest) {
            case Some(runner) => return runner(request)
            case None => ()
        }
    }
    duckDuckGoSearchNativeSend(request)
}

private func duckDuckGoSearchSanitizeError(raw: String): String {
    let text = raw.trimAscii()
    if (text.isEmpty()) {
        return "DuckDuckGo request failed"
    }
    let lower = text.toAsciiLower()
    if (lower.contains("authorization") ||
        lower.contains("token=") ||
        lower.contains("access_token") ||
        lower.contains("api_key") ||
        lower.contains("apikey") ||
        lower.contains("password") ||
        lower.contains("secret")) {
        return "DuckDuckGo request failed"
    }
    metisSafeRuneEllipsis(text, 240)
}

public class DuckDuckGoSearchClient {
    public init() {}

    public func search(
        query: String,
        limit!: Int64 = 5,
        region!: String = "wt-wt",
        safeSearch!: String = "moderate",
        timeoutMs!: Int64 = 10000
    ): DuckDuckGoSearchResponse {
        let safeQuery = query.trimAscii()
        if (safeQuery.isEmpty()) {
            throw Exception("Search query cannot be empty")
        }
        let safeLimit = max(1, min(10, limit))
        let safeRegion = if (region.trimAscii().isEmpty()) { "wt-wt" } else { region.trimAscii() }
        let safeParam = match (safeSearch.trimAscii().toAsciiLower()) {
            case "off" | "none" => "-2"
            case "strict" => "1"
            case _ => "-1"
        }
        let url = "https://html.duckduckgo.com/html/?q=${duckDuckGoSearchUrlEncode(safeQuery)}&kl=${duckDuckGoSearchUrlEncode(safeRegion)}&kp=${safeParam}"
        let headers = HashMap<String, String>([
            ("User-Agent", "MetisGatewayWebSearch/1.0"),
            ("Accept-Language", "en-US,en;q=0.9")
        ])
        let response = duckDuckGoSearchHttpSend(DuckDuckGoSearchHttpRequest(url, headers, max(1, timeoutMs), 1_000_000))
        if (response.statusCode == 0) {
            throw Exception(duckDuckGoSearchSanitizeError(response.error))
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
            throw Exception("DuckDuckGo HTTP status ${response.statusCode}")
        }
        let decoded = metisDecodeUtf8Bytes(response.bodyBytes)
        if (!decoded.ok) {
            throw Exception(decoded.diagnostic)
        }
        duckDuckGoSearchParseHtml(safeQuery, decoded.text, safeLimit)
    }

    public func renderSearchResponse(response: DuckDuckGoSearchResponse): String {
        let rows = ArrayList<String>()
        rows.add("=== DuckDuckGo Search Results ===\n")
        rows.add("Query: ${response.query}\n\n")
        rows.add("[Search Results]\n")
        if (response.results.size == 0) {
            rows.add("No search results found.\n")
        }
        for (i in 0..response.results.size) {
            let result = response.results[i]
            rows.add("${i + 1}. ${result.title}\n")
            rows.add("   URL: ${result.url}\n")
            if (!result.snippet.isEmpty()) {
                rows.add("   Content: ${result.snippet}\n")
            }
            rows.add("\n")
        }
        String.join(rows.toArray(), delimiter: "")
    }
}
