package metis.gateway.tools

import std.collection.ArrayList
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

private class FeishuOapiSidecarFakeRunner <: FeishuSidecarOapiRequestRunner {
    public let requests = ArrayList<JsonObject>()
    private let responses = ArrayList<JsonObject>()
    private var cursor: Int64 = 0

    public init() {}

    public func enqueue(response: JsonObject): Unit {
        this.responses.add(response)
    }

    public func run(request: JsonObject): JsonObject {
        this.requests.add(request)
        if (this.cursor >= this.responses.size) {
            let out = JsonObject()
            out.put("ok", JsonBool(false))
            out.put("status", JsonString("api_error"))
            out.put("error", JsonString("fake sidecar oapi response not queued"))
            return out
        }
        let response = this.responses[this.cursor]
        this.cursor++
        response
    }
}

private func feishuOapiSidecarTestResult(ok: Bool, status: String, error!: String = ""): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(ok))
    out.put("status", JsonString(status.trimAscii()))
    if (!error.trimAscii().isEmpty()) {
        out.put("error", JsonString(error.trimAscii()))
    }
    if (ok) {
        let data = JsonObject()
        data.put("message_id", JsonString("om_sidecar"))
        out.put("data", data)
    }
    out
}

private func feishuOapiSidecarString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_e: Exception) { "" }
        case None => ""
    }
}

private func feishuOapiSidecarObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_e: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

@Test
public class FeishuOapiSidecarClientTest {
    @TestCase
    public func toolEntryCanUseInjectedSidecarOapiExecutorWithoutTokenFiles(): Unit {
        let runner = FeishuOapiSidecarFakeRunner()
        runner.enqueue(feishuOapiSidecarTestResult(true, "ok"))
        debugSetGatewayFeishuOapiClientForTest(Some<FeishuOapiClient>(FeishuSidecarOapiClient(runner: runner)))
        try {
            let raw = GatewayFeishuOapiToolset().debugFeishuOapiInvokeForTest(
                "feishu_im_message",
                "send",
                Some("tenant-a"),
                Some("{\"message\":\"hello\",\"receive_id\":\"oc_chat\"}")
            )
            let result = JsonValue.fromStr(raw).asObject()
            let request = runner.requests[0]
            let oapi = feishuOapiSidecarObject(request, "oapiRequest")

            @Expect(feishuOapiSidecarString(result, "status"), "ok")
            @Expect(feishuOapiSidecarString(result, "client"), "metis_feishu_sidecar_oapi_client")
            @Expect(feishuOapiSidecarString(request, "operation"), "oapi.invoke")
            @Expect(feishuOapiSidecarString(request, "accountId"), "tenant-a")
            @Expect(feishuOapiSidecarString(oapi, "tool"), "feishu_im_message")
            @Expect(feishuOapiSidecarString(oapi, "action"), "send")
        } finally {
            debugSetGatewayFeishuOapiClientForTest(None<FeishuOapiClient>)
        }
    }

    @TestCase
    public func sidecarOapiExecutorPreservesStructuredFailuresAndRedactsSecrets(): Unit {
        let runner = FeishuOapiSidecarFakeRunner()
        runner.enqueue(feishuOapiSidecarTestResult(false, "auth_required", error: "auth missing"))
        runner.enqueue(feishuOapiSidecarTestResult(false, "scope_missing", error: "missing scope"))
        runner.enqueue(feishuOapiSidecarTestResult(false, "api_error", error: "{\"ok\":false,\"Authorization\":\"Bearer live-token\",\"app_secret\":\"secret\"}"))
        let client = FeishuSidecarOapiClient(runner: runner)
        let request = feishuOapiBuildRequest("feishu_im_message", "send", "tenant-a", JsonObject())

        let auth = client.invoke(request)
        let scope = client.invoke(request)
        let api = client.invoke(request)

        @Expect(feishuOapiSidecarString(auth, "status"), "auth_required")
        @Expect(feishuOapiSidecarString(scope, "status"), "scope_missing")
        @Expect(feishuOapiSidecarString(api, "status"), "api_error")
        @Expect(feishuOapiSidecarString(api, "error").contains("Bearer"), false)
        @Expect(feishuOapiSidecarString(api, "error").contains("live-token"), false)
        @Expect(feishuOapiSidecarString(api, "error").contains("\"ok\""), false)
    }
}
