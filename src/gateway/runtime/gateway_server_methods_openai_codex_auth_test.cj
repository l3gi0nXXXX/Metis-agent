package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, GatewayUserSettings, MetisConfigManager, MetisProcessEnvironmentLock, OpenAICodexClock, OpenAICodexHttpClient, OpenAICodexHttpResponse, readOpenAICodexOAuthProfile}
import metis.gateway.config.buildGatewayConfigFromUserSettings

import std.collection.ArrayList
import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString}

private class GatewayOpenAICodexAuthFakeClock <: OpenAICodexClock {
    private let nowSeconds: Int64

    public init(nowSeconds: Int64) {
        this.nowSeconds = nowSeconds
    }

    public func unixSeconds(): Int64 {
        this.nowSeconds
    }
}

private class GatewayOpenAICodexAuthFakeHttpClient <: OpenAICodexHttpClient {
    public let jsonUrls = ArrayList<String>()
    public let formUrls = ArrayList<String>()
    private let jsonResponses = ArrayList<OpenAICodexHttpResponse>()
    private let formResponses = ArrayList<OpenAICodexHttpResponse>()

    public init() {}

    public func queueJson(statusCode: Int64, body: String): Unit {
        this.jsonResponses.add(OpenAICodexHttpResponse(statusCode, body))
    }

    public func queueForm(statusCode: Int64, body: String): Unit {
        this.formResponses.add(OpenAICodexHttpResponse(statusCode, body))
    }

    public func postJson(url: String, _body: String): OpenAICodexHttpResponse {
        this.jsonUrls.add(url)
        if (this.jsonResponses.size == 0) {
            return OpenAICodexHttpResponse(500, "{\"error\":\"unexpected_json_call\"}")
        }
        this.jsonResponses.remove(at: 0)
    }

    public func postForm(url: String, _body: String): OpenAICodexHttpResponse {
        this.formUrls.add(url)
        if (this.formResponses.size == 0) {
            return OpenAICodexHttpResponse(500, "{\"error\":\"unexpected_form_call\"}")
        }
        this.formResponses.remove(at: 0)
    }
}

private func withGatewayOpenAICodexAuthTestHome<T>(name: String, block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/tmp/metis-gateway-openai-codex-auth-${name}")
        try { remove(home, recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", home.toString())
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        setGatewayOpenAICodexAuthRuntimeForTest(
            None<OpenAICodexHttpClient>,
            Some<OpenAICodexClock>(GatewayOpenAICodexAuthFakeClock(1000))
        )
        try {
            return block()
        } finally {
            setGatewayOpenAICodexAuthRuntimeForTest(None<OpenAICodexHttpClient>, None<OpenAICodexClock>)
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            try { remove(home, recursive: true) } catch (_: Exception) { () }
        }
    }
}

private func gatewayOpenAICodexAuthTestObject(root: JsonObject, key: String): JsonObject {
    match (root.get(key)) {
        case Some(value) => try { value.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func gatewayOpenAICodexAuthTestString(root: JsonObject, key: String): String {
    match (root.get(key)) {
        case Some(value) => try { value.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func gatewayOpenAICodexAuthTestBool(root: JsonObject, key: String): Bool {
    match (root.get(key)) {
        case Some(value) => try { value.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

private func gatewayOpenAICodexAuthFakeSuccessFlow(): GatewayOpenAICodexAuthFakeHttpClient {
    let http = GatewayOpenAICodexAuthFakeHttpClient()
    http.queueJson(200, "{\"device_auth_id\":\"dev-gateway\",\"user_code\":\"GW-CODE\",\"verification_uri\":\"https://auth.example/device\",\"interval\":3,\"expires_in\":900}")
    http.queueJson(200, "{\"authorization_code\":\"gateway-auth-code\",\"code_verifier\":\"gateway-verifier\"}")
    http.queueForm(200, "{\"access_token\":\"access-gateway-secret\",\"refresh_token\":\"refresh-gateway-secret\",\"expires_in\":3600}")
    http
}

@Test
public class GatewayServerMethodsOpenAICodexAuthTest {
    @TestCase
    public func statusRpcReturnsDashboardStatusWithoutRawSecrets(): Unit {
        withGatewayOpenAICodexAuthTestHome("status-rpc", { =>
            let response = gatewayDispatchLocalMethod(GatewayRpcRequest("models.auth.openai-codex.status"))
            @Expect(response.ok, true)
            let result = response.result.asObject()
            let auth = gatewayOpenAICodexAuthTestObject(result, "auth")
            let dashboard = gatewayOpenAICodexAuthTestObject(result, "dashboard")
            @Expect(gatewayOpenAICodexAuthTestString(auth, "provider"), "openai-codex")
            @Expect(gatewayOpenAICodexAuthTestBool(auth, "loggedIn"), false)
            @Expect(gatewayOpenAICodexAuthTestString(dashboard, "status"), "not_logged_in")
            @Expect(gatewayOpenAICodexAuthTestString(dashboard, "message").contains("metis models auth openai-codex login"), true)
        })
    }

    @TestCase
    public func startRpcUsesFakeDeviceFlowAndPersistsSingletonOAuthProfile(): Unit {
        withGatewayOpenAICodexAuthTestHome("start-rpc", { =>
            let http = gatewayOpenAICodexAuthFakeSuccessFlow()
            setGatewayOpenAICodexAuthRuntimeForTest(
                Some<OpenAICodexHttpClient>(http),
                Some<OpenAICodexClock>(GatewayOpenAICodexAuthFakeClock(2000))
            )
            let response = gatewayDispatchLocalMethod(GatewayRpcRequest("models.auth.openai-codex.start"))
            @Expect(response.ok, true)
            @Expect(http.jsonUrls.size, 2)
            @Expect(http.formUrls.size, 1)
            @Expect(readOpenAICodexOAuthProfile().isSome(), true)
            let result = response.result.asObject()
            let auth = gatewayOpenAICodexAuthTestObject(result, "auth")
            let flow = gatewayOpenAICodexAuthTestObject(result, "flow")
            @Expect(gatewayOpenAICodexAuthTestBool(auth, "loggedIn"), true)
            @Expect(gatewayOpenAICodexAuthTestString(flow, "userCode"), "GW-CODE")
            @Expect(result.toJsonString().contains("access-gateway-secret"), false)
            @Expect(result.toJsonString().contains("refresh-gateway-secret"), false)
        })
    }

    @TestCase
    public func startRpcDefaultNativeClientUsesConfiguredProxyDiagnostic(): Unit {
        withGatewayOpenAICodexAuthTestHome("start-rpc-native-proxy", { =>
            let root = JsonObject()
            let models = JsonObject()
            let providers = JsonObject()
            let codex = JsonObject()
            codex.put("proxy", JsonString("https://user:secret@127.0.0.1:7897"))
            providers.put("openai-codex", codex)
            models.put("providers", providers)
            root.put("models", models)
            MetisConfigManager.writeRoot(root)
            CliSettingManager.applyPersistedFieldsToCliConfig()

            let response = gatewayDispatchLocalMethod(GatewayRpcRequest("models.auth.openai-codex.start"))

            @Expect(response.ok, true)
            let flow = gatewayOpenAICodexAuthTestObject(response.result.asObject(), "flow")
            @Expect(gatewayOpenAICodexAuthTestString(flow, "status"), "failed")
            @Expect(gatewayOpenAICodexAuthTestString(flow, "errorCode"), "network_error")
            @Expect(gatewayOpenAICodexAuthTestString(flow, "message").contains("true HTTPS proxy is not implemented"), true)
            @Expect(flow.toJsonString().contains("unsupportedHttpsProxy"), true)
            @Expect(flow.toJsonString().contains("secret"), false)
            @Expect(flow.toJsonString().contains("[redacted]@127.0.0.1:7897"), true)
        })
    }

    @TestCase
    public func controlUiWsCompatRoutesStartThroughSameRpcPath(): Unit {
        withGatewayOpenAICodexAuthTestHome("ws-start", { =>
            let http = gatewayOpenAICodexAuthFakeSuccessFlow()
            setGatewayOpenAICodexAuthRuntimeForTest(
                Some<OpenAICodexHttpClient>(http),
                Some<OpenAICodexClock>(GatewayOpenAICodexAuthFakeClock(3000))
            )
            let response = gatewayControlUiWsCompatResponse(
                "oauth.openai-codex.start",
                JsonObject(),
                buildGatewayConfigFromUserSettings(GatewayUserSettings())
            ).getOrThrow()
            @Expect(response.ok, true)
            @Expect(http.jsonUrls.size, 2)
            @Expect(http.formUrls.size, 1)
            let result = response.result.asObject()
            @Expect(gatewayOpenAICodexAuthTestString(gatewayOpenAICodexAuthTestObject(result, "flow"), "userCode"), "GW-CODE")
            @Expect(result.toJsonString().contains("access-gateway-secret"), false)
        })
    }
}
