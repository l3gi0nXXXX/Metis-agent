package metis.gateway.tools

import metis.core.config.{CliConfig, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.core.{TavilySearchHttpRequest, TavilySearchHttpResponse, setTavilySearchHttpRunnerForTest}

import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*

private func withGatewayWebToolsetTempHome<T>(label: String, block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/tmp/${label}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        try { remove(home, recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        let oldKey = getVariable("TAVILY_API_KEY")
        setVariable("METIS_HOME", home.toString())
        setVariable("TAVILY_API_KEY", "")
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        try {
            return block()
        } finally {
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            match (oldKey) {
                case Some(value) => setVariable("TAVILY_API_KEY", value)
                case None => setVariable("TAVILY_API_KEY", "")
            }
            setGatewayWebProviderResolverForTest(None<(String) -> GatewayWebProviderResolution>)
            setTavilySearchHttpRunnerForTest(None<(TavilySearchHttpRequest) -> TavilySearchHttpResponse>)
            setGatewayWebFetchHttpRunnerForTest(None<(GatewayWebFetchHttpRequest) -> GatewayWebFetchHttpResponse>)
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            try { remove(home, recursive: true) } catch (_: Exception) { () }
        }
    }
}

@Test
public class GatewayWebToolsetTest {
    @TestCase
    public func m2u1ProviderResolverReportsAvailableUnavailableAndUnknownCapability(): Unit {
        withGatewayWebToolsetTempHome("metis-web-provider-resolver", { =>
            setVariable("TAVILY_API_KEY", "fake-key")
            let available = resolveGatewayWebProvider("search")
            @Expect(available.available, true)
            @Expect(available.providerId, "tavily")
            @Expect(available.status, "ok")
            @Expect(available.supportsSearch, true)

            setVariable("TAVILY_API_KEY", "")
            let unavailable = resolveGatewayWebProvider("search")
            @Expect(unavailable.available, false)
            @Expect(unavailable.status, "web_provider_unavailable")
            @Expect(unavailable.providerId, "tavily")

            let unknown = resolveGatewayWebProvider("unknown")
            @Expect(unknown.available, false)
            @Expect(unknown.status, "web_provider_unsupported_capability")
        })
    }

    @TestCase
    public func m2b1WebSearchBoundariesReturnDiagnosticsOrClampLimit(): Unit {
        withGatewayWebToolsetTempHome("metis-web-search-boundary", { =>
            let toolset = GatewayWebToolset()
            @Expect(toolset.webSearchForTest("", None<Int64>, None<String>, None<String>).contains("web_search_invalid_query"), true)
            @Expect(toolset.webSearchForTest("q", None<Int64>, Some("bad-topic"), None<String>).contains("web_search_invalid_topic"), true)
            @Expect(toolset.webSearchForTest("q", None<Int64>, None<String>, Some("bad-time")).contains("web_search_invalid_time_range"), true)

            setVariable("TAVILY_API_KEY", "fake-key")
            setGatewayWebProviderResolverForTest(Some({ _capability: String =>
                GatewayWebProviderResolution(providerId: "tavily", available: true, status: "ok", supportsSearch: true)
            }))
            setTavilySearchHttpRunnerForTest(Some({ request: TavilySearchHttpRequest =>
                @Expect(request.body.get("max_results").getOrThrow().toJsonString(), "10")
                TavilySearchHttpResponse(
                    200,
                    body: "{\"query\":\"q\",\"answer\":\"ok\",\"response_time\":1,\"results\":[]}"
                )
            }))
            let clamped = toolset.webSearchForTest("q", Some(1000), None<String>, None<String>)
            @Expect(clamped.contains("Status: ok"), true)
            @Expect(clamped.contains("\"ok\""), false)
        })
    }

    @TestCase
    public func m2p1WebSearchUsesFakeTavilyAndReturnsHumanText(): Unit {
        withGatewayWebToolsetTempHome("metis-web-search-positive", { =>
            setVariable("TAVILY_API_KEY", "fake-key")
            setGatewayWebProviderResolverForTest(Some({ _capability: String =>
                GatewayWebProviderResolution(providerId: "tavily", available: true, status: "ok", supportsSearch: true)
            }))
            setTavilySearchHttpRunnerForTest(Some({ request: TavilySearchHttpRequest =>
                @Expect(request.body.get("query").getOrThrow().asString().getValue(), "today huawei news")
                @Expect(request.body.get("max_results").getOrThrow().toJsonString(), "2")
                TavilySearchHttpResponse(
                    200,
                    body: "{\"query\":\"today huawei news\",\"answer\":\"brief\",\"response_time\":0.5,\"results\":[{\"title\":\"News A\",\"url\":\"https://example.com/a\",\"content\":\"A summary\",\"score\":0.9},{\"title\":\"News B\",\"url\":\"https://example.com/b\",\"content\":\"B summary\",\"score\":0.8}]}"
                )
            }))
            let out = GatewayWebToolset().webSearchForTest("today huawei news", Some(2), None<String>, None<String>)
            @Expect(out.contains("Status: ok"), true)
            @Expect(out.contains("Tool: web_search"), true)
            @Expect(out.contains("Provider: tavily"), true)
            @Expect(out.contains("News A"), true)
            @Expect(out.contains("https://example.com/b"), true)
            @Expect(out.contains("\"result\""), false)
        })
    }

    @TestCase
    public func m2n1UnavailableProviderFailsClosedWithoutFakeNews(): Unit {
        withGatewayWebToolsetTempHome("metis-web-search-unavailable", { =>
            setGatewayWebProviderResolverForTest(Some({ _capability: String =>
                GatewayWebProviderResolution(
                    providerId: "tavily",
                    available: false,
                    status: "web_provider_unavailable",
                    message: "Real-time web search is unavailable.",
                    supportsSearch: true
                )
            }))
            let out = GatewayWebToolset().webSearchForTest("today news", Some(2), None<String>, None<String>)
            @Expect(out.contains("Status: error"), true)
            @Expect(out.contains("Diagnostic: code=web_provider_unavailable"), true)
            @Expect(out.contains("News A"), false)
            @Expect(out.contains("\"ok\""), false)
        })
    }

    @TestCase
    public func webFetchAndExtractUseFakeRuntimeAndIsolateFailures(): Unit {
        withGatewayWebToolsetTempHome("metis-web-fetch-extract", { =>
            setGatewayWebProviderResolverForTest(Some({ capability: String =>
                if (capability == "fetch") {
                    return GatewayWebProviderResolution(providerId: "metis-native-fetch", available: true, status: "ok", supportsFetch: true)
                }
                GatewayWebProviderResolution(providerId: "metis-native-fetch", available: true, status: "ok", supportsFetch: true, supportsExtract: true)
            }))
            setGatewayWebFetchHttpRunnerForTest(Some({ request: GatewayWebFetchHttpRequest =>
                if (request.url.contains("bad")) {
                    return GatewayWebFetchHttpResponse(500, bodyBytes: "bad".toArray(), contentType: "text/plain")
                }
                GatewayWebFetchHttpResponse(
                    200,
                    bodyBytes: "<html><head><title>T</title></head><body><p>正文🙂</p></body></html>".toArray(),
                    contentType: "text/html; charset=utf-8"
                )
            }))
            let fetch = GatewayWebToolset().webFetchForTest("https://example.com/good", None<String>, Some(2000))
            @Expect(fetch.contains("Status: ok"), true)
            @Expect(fetch.contains("正文🙂"), true)
            @Expect(fetch.contains("---BEGIN WEB CONTENT---"), true)

            let extracted = GatewayWebToolset().webExtractForTest("[\"https://example.com/good\",\"https://example.com/bad\"]", None<String>, Some(2000))
            @Expect(extracted.contains("Tool: web_extract"), true)
            @Expect(extracted.contains("正文🙂"), true)
            @Expect(extracted.contains("web_fetch_http_error"), true)
        })
    }
}
