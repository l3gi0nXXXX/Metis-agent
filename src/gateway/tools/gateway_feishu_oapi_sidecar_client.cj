package metis.gateway.tools

import stdx.encoding.json.{JsonBool, JsonObject, JsonString}

public const FEISHU_SIDECAR_OAPI_SCHEMA: String = "metis.feishu.sidecar.oapi.v1"

public interface FeishuSidecarOapiRequestRunner {
    func run(request: JsonObject): JsonObject
}

public class FeishuSidecarNoopOapiRequestRunner <: FeishuSidecarOapiRequestRunner {
    public init() {}

    public func run(_request: JsonObject): JsonObject {
        let out = JsonObject()
        out.put("ok", JsonBool(false))
        out.put("status", JsonString("not_configured"))
        out.put("error", JsonString("Feishu sidecar OAPI runner is not configured."))
        out
    }
}

public class FeishuSidecarOapiClient <: FeishuOapiClient {
    private let runner: FeishuSidecarOapiRequestRunner

    public init(runner!: FeishuSidecarOapiRequestRunner = FeishuSidecarNoopOapiRequestRunner()) {
        this.runner = runner
    }

    public func invoke(request: FeishuOapiRequest): JsonObject {
        let payload = JsonObject()
        payload.put("schema", JsonString(FEISHU_SIDECAR_OAPI_SCHEMA))
        payload.put("operation", JsonString("oapi.invoke"))
        payload.put("accountId", JsonString(feishuSidecarOapiNormalizeAccountId(request.accountId)))
        payload.put("oapiRequest", request.toJson())
        let result = try {
            this.runner.run(payload)
        } catch (e: Exception) {
            let out = JsonObject()
            out.put("ok", JsonBool(false))
            out.put("status", JsonString("api_error"))
            out.put("error", JsonString(e.message))
            out
        }
        this.normalizeResult(request, result)
    }

    private func normalizeResult(request: FeishuOapiRequest, result: JsonObject): JsonObject {
        let out = request.toJson()
        let ok = feishuSidecarOapiJsonBool(result, "ok", fallback: false)
        let status = feishuSidecarOapiStatus(result)
        out.put("ok", JsonBool(ok))
        out.put("status", JsonString(status))
        out.put("client", JsonString("metis_feishu_sidecar_oapi_client"))
        let error = feishuSidecarOapiError(result)
        if (!error.isEmpty()) {
            out.put("error", JsonString(error))
            if (status == "invalid_request") {
                out.put("reason", JsonString(error))
            }
        }
        match (result.get("data")) {
            case Some(v) => out.put("data", v)
            case None => ()
        }
        this.copyIfPresent(result, out, "missing_scopes")
        this.copyIfPresent(result, out, "scope_diagnostic")
        this.copyIfPresent(result, out, "auth")
        this.copyIfPresent(result, out, "credential")
        this.copyIfPresent(result, out, "repair")
        out
    }

    private func copyIfPresent(source: JsonObject, target: JsonObject, key: String): Unit {
        match (source.get(key)) {
            case Some(v) => target.put(key, v)
            case None => ()
        }
    }
}

private func feishuSidecarOapiJsonString(obj: JsonObject, key: String, fallback!: String = ""): String {
    match (obj.get(key)) {
        case Some(v) =>
            try {
                v.asString().getValue().trimAscii()
            } catch (_e1: Exception) {
                match (v) {
                    case b: JsonBool => if (b.getValue()) { "true" } else { "false" }
                    case _ => fallback
                }
            }
        case None => fallback
    }
}

private func feishuSidecarOapiNormalizeAccountId(raw: String): String {
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty()) { "default" } else { trimmed }
}

private func feishuSidecarOapiJsonBool(obj: JsonObject, key: String, fallback!: Bool = false): Bool {
    match (obj.get(key)) {
        case Some(v) =>
            try {
                v.asBool().getValue()
            } catch (_e: Exception) {
                let text = feishuSidecarOapiJsonString(obj, key).toAsciiLower()
                if (text == "true" || text == "1" || text == "yes") {
                    true
                } else if (text == "false" || text == "0" || text == "no") {
                    false
                } else {
                    fallback
                }
            }
        case None => fallback
    }
}

private func feishuSidecarOapiStatus(result: JsonObject): String {
    let status = feishuSidecarOapiJsonString(result, "status")
    if (!status.isEmpty()) {
        return status
    }
    if (feishuSidecarOapiJsonBool(result, "ok", fallback: false)) {
        "ok"
    } else {
        "api_error"
    }
}

private func feishuSidecarOapiError(result: JsonObject): String {
    let raw = feishuSidecarOapiFirstString(result, ["error", "reason", "message", "detail"])
    let text = raw.trimAscii()
    if (text.isEmpty()) {
        return ""
    }
    let lower = text.toAsciiLower()
    if (lower.contains("authorization:") ||
        lower.contains("\"authorization\"") ||
        lower.contains("bearer ") ||
        lower.contains("access_token") ||
        lower.contains("refresh_token") ||
        lower.contains("tenant_secret") ||
        lower.contains("appsecret") ||
        lower.contains("app_secret") ||
        lower.contains("client_secret") ||
        lower.contains("secret") ||
        lower.contains("token=") ||
        lower.contains("password")) {
        return "[redacted]"
    }
    if (text.startsWith("{") || text.startsWith("[")) {
        return "Feishu sidecar returned structured OAPI error."
    }
    text
}

private func feishuSidecarOapiFirstString(obj: JsonObject, keys: Array<String>, fallback!: String = ""): String {
    for (key in keys) {
        let value = feishuSidecarOapiJsonString(obj, key)
        if (!value.isEmpty()) {
            return value
        }
    }
    fallback.trimAscii()
}
