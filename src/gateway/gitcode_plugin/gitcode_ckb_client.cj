package metis.gateway.gitcode_plugin

import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString}

public const GITCODE_CKB_EVIDENCE_PACK_CAPABILITY: String = "cangjie.evidence_pack"
public const GITCODE_CKB_SOURCE_ANALYSIS_CAPABILITY: String = "cangjie.source_analysis"

public class GitCodeCkbDiagnostic {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let degraded: Bool

    public init(code: String, message: String, retryable!: Bool = false, degraded!: Bool = false) {
        this.code = code.trimAscii()
        this.message = gitCodeReviewRedactSensitiveText(message.trimAscii())
        this.retryable = retryable
        this.degraded = degraded
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.put("code", JsonString(this.code))
        obj.put("message", JsonString(this.message))
        obj.put("retryable", JsonBool(this.retryable))
        obj.put("degraded", JsonBool(this.degraded))
        obj
    }
}

public class GitCodeCkbClientResult {
    public let ok: Bool
    public let status: String
    public let capabilityId: String
    public let payload: JsonObject
    public let retryable: Bool
    public let degraded: Bool
    public let diagnostics: Array<GitCodeCkbDiagnostic>

    public init(
        ok: Bool,
        status: String,
        capabilityId!: String = "",
        payload!: JsonObject = JsonObject(),
        retryable!: Bool = false,
        degraded!: Bool = false,
        diagnostics!: Array<GitCodeCkbDiagnostic> = []
    ) {
        this.ok = ok
        this.status = status.trimAscii()
        this.capabilityId = capabilityId.trimAscii()
        this.payload = payload
        this.retryable = retryable
        this.degraded = degraded
        this.diagnostics = diagnostics
    }
}

private var gitCodeCkbClientRunnerForTest: Option<(String, JsonObject) -> GitCodeCkbClientResult> =
    None<(String, JsonObject) -> GitCodeCkbClientResult>

public func setGitCodeCkbClientRunnerForTest(runner: Option<(String, JsonObject) -> GitCodeCkbClientResult>): Unit {
    gitCodeCkbClientRunnerForTest = runner
}

private func ckbInvoke(capabilityId: String, request: JsonObject): GitCodeCkbClientResult {
    match (gitCodeCkbClientRunnerForTest) {
        case Some(runner) =>
            let result = runner(capabilityId, request)
            if (result.ok) {
                return GitCodeCkbClientResult(true, "resolved", capabilityId: capabilityId, payload: result.payload, diagnostics: result.diagnostics)
            }
            let status = match (result.status) {
                case "timeout" => "ckb_timeout"
                case "capability_missing" => "ckb_capability_missing"
                case "disabled" => "source_analysis_disabled"
                case _ => "ckb_unavailable"
            }
            GitCodeCkbClientResult(false, status, capabilityId: capabilityId, retryable: status == "ckb_timeout", degraded: true, diagnostics: [
                GitCodeCkbDiagnostic(status, "CKB capability ${capabilityId} returned ${result.status}", retryable: status == "ckb_timeout", degraded: true)
            ])
        case None =>
            GitCodeCkbClientResult(false, "ckb_unavailable", capabilityId: capabilityId, degraded: true, diagnostics: [
                GitCodeCkbDiagnostic("ckb_unavailable", "CKB client runner is not configured.", degraded: true)
            ])
    }
}

public func queryCkbEvidencePack(q: String, budget!: Int64 = 5, includeCandidates!: Bool = false, parentUrl!: String = ""): GitCodeCkbClientResult {
    let request = JsonObject()
    request.put("q", JsonString(gitCodeReviewRedactSensitiveText(q)))
    request.put("budget", JsonInt(budget))
    request.put("includeCandidates", JsonBool(includeCandidates))
    if (!parentUrl.trimAscii().isEmpty()) {
        request.put("parentUrl", JsonString(parentUrl.trimAscii()))
    }
    ckbInvoke(GITCODE_CKB_EVIDENCE_PACK_CAPABILITY, request)
}

public func queryCkbSourceAnalysis(repo: String, ref: String, query: String, requiresSourceAnalysis!: Bool, sourceAvailable!: Bool): GitCodeCkbClientResult {
    if (!requiresSourceAnalysis) {
        return GitCodeCkbClientResult(false, "source_analysis_disabled", capabilityId: GITCODE_CKB_SOURCE_ANALYSIS_CAPABILITY, degraded: true, diagnostics: [
            GitCodeCkbDiagnostic("source_analysis_disabled", "Task policy does not require source analysis.", degraded: true)
        ])
    }
    if (!sourceAvailable) {
        return GitCodeCkbClientResult(false, "source_analysis_disabled", capabilityId: GITCODE_CKB_SOURCE_ANALYSIS_CAPABILITY, degraded: true, diagnostics: [
            GitCodeCkbDiagnostic("source_analysis_disabled", "Source context is unavailable for source analysis.", degraded: true)
        ])
    }
    let request = JsonObject()
    request.put("repo", JsonString(repo.trimAscii()))
    request.put("ref", JsonString(resolveSourceRef(ref)))
    request.put("query", JsonString(gitCodeReviewRedactSensitiveText(query)))
    ckbInvoke(GITCODE_CKB_SOURCE_ANALYSIS_CAPABILITY, request)
}

public func renderCkbDiagnostics(diagnostics: Array<GitCodeCkbDiagnostic>): String {
    let lines = ArrayList<String>()
    for (diag in diagnostics) {
        lines.add("${diag.code}: ${diag.message}")
    }
    gitCodeReviewRedactSensitiveText(String.join(lines.toArray(), delimiter: "\n"))
}

public func gitCodeCkbResultToContext(result: GitCodeCkbClientResult): JsonObject {
    let out = JsonObject()
    out.put("status", JsonString(result.status))
    out.put("capabilityId", JsonString(result.capabilityId))
    out.put("degraded", JsonBool(result.degraded))
    let diags = JsonArray([])
    for (diag in result.diagnostics) {
        diags.add(diag.toJson())
    }
    out.put("diagnostics", diags)
    match (result.payload.get("items")) {
        case Some(v) => out.put("items", v)
        case None => out.put("items", JsonArray([]))
    }
    match (result.payload.get("knowledgeVersion")) {
        case Some(v) => out.put("knowledgeVersion", v)
        case None => ()
    }
    out
}
