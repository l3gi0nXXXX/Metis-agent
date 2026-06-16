package metis.gateway.gitcode_plugin

import metis.core.config.MetisPaths
import std.collection.ArrayList
import std.convert.Parsable
import std.fs.{Path, canonicalize, exists}
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString}

public class GitCodeSourceWorkspaceConfig {
    public let root: String
    public let allowedHosts: Array<String>
    public let gitTimeoutMs: Int64
    public let maxFilesPerRequest: Int64
    public let maxFileBytes: Int64

    public init(
        root!: String = "~/.metis/gitcode/repo-source-code",
        allowedHosts!: Array<String> = ["gitcode.com"],
        gitTimeoutMs!: Int64 = 30000,
        maxFilesPerRequest!: Int64 = 30,
        maxFileBytes!: Int64 = 65536
    ) {
        this.root = root.trimAscii()
        this.allowedHosts = allowedHosts
        this.gitTimeoutMs = gitTimeoutMs
        this.maxFilesPerRequest = maxFilesPerRequest
        this.maxFileBytes = maxFileBytes
    }
}

public class GitCodePrReviewAdapterConfig {
    public let mode: String
    public let endpoint: String
    public let timeoutMs: Int64
    public let maxFindings: Int64
    public let maxFindingChars: Int64
    public let authHeaderEnv: String

    public init(
        mode!: String = "disabled",
        endpoint!: String = "",
        timeoutMs!: Int64 = 15000,
        maxFindings!: Int64 = 20,
        maxFindingChars!: Int64 = 2000,
        authHeaderEnv!: String = ""
    ) {
        this.mode = mode.trimAscii()
        this.endpoint = endpoint.trimAscii()
        this.timeoutMs = timeoutMs
        this.maxFindings = maxFindings
        this.maxFindingChars = maxFindingChars
        this.authHeaderEnv = authHeaderEnv.trimAscii()
    }
}

public class GitCodePromptTemplatesConfig {
    public let dir: String
    public let allowUserOverride: Bool
    public let reloadPolicy: String
    public let maxTemplateBytes: Int64
    public let strictValidation: Bool

    public init(
        dir!: String = "~/.metis/gitcodemonitor/prompt",
        allowUserOverride!: Bool = true,
        reloadPolicy!: String = "on_plugin_load",
        maxTemplateBytes!: Int64 = 32768,
        strictValidation!: Bool = true
    ) {
        this.dir = dir.trimAscii()
        this.allowUserOverride = allowUserOverride
        this.reloadPolicy = reloadPolicy.trimAscii()
        this.maxTemplateBytes = maxTemplateBytes
        this.strictValidation = strictValidation
    }
}

public class GitCodeCkbServiceConfig {
    public let enabled: Bool
    public let endpoint: String
    public let timeoutMs: Int64
    public let defaultBudget: Int64
    public let maxBudget: Int64
    public let includeCandidates: Bool
    public let sourceAnalysisEnabled: Bool

    public init(
        enabled!: Bool = false,
        endpoint!: String = "",
        timeoutMs!: Int64 = 5000,
        defaultBudget!: Int64 = 5,
        maxBudget!: Int64 = 10,
        includeCandidates!: Bool = false,
        sourceAnalysisEnabled!: Bool = false
    ) {
        this.enabled = enabled
        this.endpoint = endpoint.trimAscii()
        this.timeoutMs = timeoutMs
        this.defaultBudget = defaultBudget
        this.maxBudget = maxBudget
        this.includeCandidates = includeCandidates
        this.sourceAnalysisEnabled = sourceAnalysisEnabled
    }
}

public class GitCodeReviewRuntimeConfig {
    public let sourceWorkspace: GitCodeSourceWorkspaceConfig
    public let prReviewAdapter: GitCodePrReviewAdapterConfig
    public let promptTemplates: GitCodePromptTemplatesConfig
    public let ckbService: GitCodeCkbServiceConfig

    public init(
        sourceWorkspace!: GitCodeSourceWorkspaceConfig = GitCodeSourceWorkspaceConfig(),
        prReviewAdapter!: GitCodePrReviewAdapterConfig = GitCodePrReviewAdapterConfig(),
        promptTemplates!: GitCodePromptTemplatesConfig = GitCodePromptTemplatesConfig(),
        ckbService!: GitCodeCkbServiceConfig = GitCodeCkbServiceConfig()
    ) {
        this.sourceWorkspace = sourceWorkspace
        this.prReviewAdapter = prReviewAdapter
        this.promptTemplates = promptTemplates
        this.ckbService = ckbService
    }
}

public class GitCodeReviewConfigValidationResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String
    public let diagnostics: Array<String>

    public init(ok: Bool, status!: String = "ok", diagnostic!: String = "", diagnostics!: Array<String> = []) {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.diagnostics = diagnostics
    }
}

public class GitCodeReviewConfigParseResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String
    public let config: GitCodeReviewRuntimeConfig

    public init(ok: Bool, status!: String = "ok", diagnostic!: String = "", config!: GitCodeReviewRuntimeConfig = GitCodeReviewRuntimeConfig()) {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.config = config
    }
}

public func defaultGitCodeReviewRuntimeConfig(): GitCodeReviewRuntimeConfig {
    GitCodeReviewRuntimeConfig()
}

private func grObj(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func grStr(obj: JsonObject, key: String, fallback: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func grInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { v.asInt().getValue() } catch (_: Exception) { try { Int64.parse(v.toJsonString()) } catch (_: Exception) { fallback } }
        case None => fallback
    }
}

private func grBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func grStringArray(obj: JsonObject, key: String, fallback: Array<String>): Array<String> {
    match (obj.get(key)) {
        case Some(v) =>
            try {
                let arr = v.asArray()
                let out = ArrayList<String>()
                for (item in arr.getItems()) {
                    try {
                        let text = item.asString().getValue().trimAscii()
                        if (!text.isEmpty()) { out.add(text) }
                    } catch (_: Exception) { () }
                }
                if (out.size > 0) { out.toArray() } else { fallback }
            } catch (_: Exception) { fallback }
        case None => fallback
    }
}

public func parseGitCodeReviewRuntimeConfig(root: JsonObject): GitCodeReviewConfigParseResult {
    let gateway = grObj(root, "gateway")
    let cfg = grObj(gateway, "gitcodeReview")
    if (cfg.size() == 0) {
        return GitCodeReviewConfigParseResult(true, config: defaultGitCodeReviewRuntimeConfig())
    }
    let source = grObj(cfg, "sourceWorkspace")
    let adapter = grObj(cfg, "prReviewAdapter")
    let templates = grObj(cfg, "promptTemplates")
    let ckb = grObj(cfg, "ckbService")
    let config = GitCodeReviewRuntimeConfig(
        sourceWorkspace: GitCodeSourceWorkspaceConfig(
            root: grStr(source, "root", "~/.metis/gitcode/repo-source-code"),
            allowedHosts: grStringArray(source, "allowedHosts", ["gitcode.com"]),
            gitTimeoutMs: grInt(source, "gitTimeoutMs", 30000),
            maxFilesPerRequest: grInt(source, "maxFilesPerRequest", 30),
            maxFileBytes: grInt(source, "maxFileBytes", 65536)
        ),
        prReviewAdapter: GitCodePrReviewAdapterConfig(
            mode: grStr(adapter, "mode", "disabled"),
            endpoint: grStr(adapter, "endpoint", ""),
            timeoutMs: grInt(adapter, "timeoutMs", 15000),
            maxFindings: grInt(adapter, "maxFindings", 20),
            maxFindingChars: grInt(adapter, "maxFindingChars", 2000),
            authHeaderEnv: grStr(adapter, "authHeaderEnv", "")
        ),
        promptTemplates: GitCodePromptTemplatesConfig(
            dir: grStr(templates, "dir", "~/.metis/gitcodemonitor/prompt"),
            allowUserOverride: grBool(templates, "allowUserOverride", true),
            reloadPolicy: grStr(templates, "reloadPolicy", "on_plugin_load"),
            maxTemplateBytes: grInt(templates, "maxTemplateBytes", 32768),
            strictValidation: grBool(templates, "strictValidation", true)
        ),
        ckbService: GitCodeCkbServiceConfig(
            enabled: grBool(ckb, "enabled", false),
            endpoint: grStr(ckb, "endpoint", ""),
            timeoutMs: grInt(ckb, "timeoutMs", 5000),
            defaultBudget: grInt(ckb, "defaultBudget", 5),
            maxBudget: grInt(ckb, "maxBudget", 10),
            includeCandidates: grBool(ckb, "includeCandidates", false),
            sourceAnalysisEnabled: grBool(ckb, "sourceAnalysisEnabled", false)
        )
    )
    let validation = validateGitCodeReviewRuntimeConfig(config)
    GitCodeReviewConfigParseResult(validation.ok, status: validation.status, diagnostic: validation.diagnostic, config: config)
}

public func gitCodeReviewExpandHomePath(raw: String): String {
    let t = raw.trimAscii()
    if (t == "~/.metis" || t.startsWith("~/.metis/")) {
        let suffix = if (t.size > "~/.metis".size) { t["~/.metis/".size..] } else { "" }
        return if (suffix.isEmpty()) { MetisPaths.homeRootReadOnly().toString() } else { MetisPaths.homeRootReadOnly().join(suffix).toString() }
    }
    if (t.startsWith("~/")) {
        let homeRoot = MetisPaths.homeRootReadOnly()
        let parent = homeRoot.parent
        return parent.join(t[2..]).toString()
    }
    t
}

public func gitCodeReviewIsRepoRelativePath(path: String): Bool {
    let p = path.trimAscii()
    !p.isEmpty() && !p.startsWith("/") && !p.contains("..") && !p.contains("\\") && !p.startsWith("~")
}

public func gitCodeReviewRedactSensitiveText(raw: String): String {
    var out = raw
    let auth = "Authorization: Bearer "
    var authDone = false
    while (!authDone) {
        match (out.indexOf(auth)) {
            case Some(idx) =>
                let start = idx + auth.size
                var end = start
                while (end < out.size && out[end] != b' ' && out[end] != b'\n' && out[end] != b'\t' && out[end] != b'"' && out[end] != b',' && out[end] != b')') { end += 1 }
                out = out[..idx] + "Authorization: [redacted]" + out[end..]
            case None => authDone = true
        }
    }
    if (out.contains("Cookie=")) {
        out = out.replace("Cookie=", "Cookie=[redacted]")
    }
    let tokenMarker = "token="
    var tokenDone = false
    while (!tokenDone) {
        match (out.toAsciiLower().indexOf(tokenMarker)) {
            case Some(idx) =>
                let start = idx + tokenMarker.size
                var end = start
                while (end < out.size && out[end] != b' ' && out[end] != b'\n' && out[end] != b'\t' && out[end] != b'"' && out[end] != b',' && out[end] != b'&' && out[end] != b')') { end += 1 }
                out = out[..idx] + "[token-redacted]" + out[end..]
            case None => tokenDone = true
        }
    }
    let marker = "/Users/"
    var pathDone = false
    while (!pathDone) {
        match (out.indexOf(marker)) {
            case Some(idx) =>
                var end = idx
                while (end < out.size && out[end] != b' ' && out[end] != b'\n' && out[end] != b'\t' && out[end] != b',' && out[end] != b')') { end += 1 }
                out = out[..idx] + "[local-path-redacted]" + out[end..]
            case None => pathDone = true
        }
    }
    out
}

public func gitCodeReviewRepeat(text: String, count: Int64): String {
    let parts = ArrayList<String>()
    for (_i in 0..count) {
        parts.add(text)
    }
    String.join(parts.toArray(), delimiter: "")
}

public func gitCodeReviewContainsForbiddenContent(raw: String): Bool {
    let low = raw.toAsciiLower()
    raw.contains("/Users/") || low.contains("authorization: bearer") || low.contains("cookie=") || low.contains("gitcodemonitor") || low.contains("auto-reply")
}

private func addDiag(diags: ArrayList<String>, code: String): Unit {
    if (!diags.contains(code)) {
        diags.add(code)
    }
}

private func invalid(diags: ArrayList<String>): GitCodeReviewConfigValidationResult {
    let arr = diags.toArray()
    GitCodeReviewConfigValidationResult(false, status: "config_invalid", diagnostic: if (arr.size > 0) { arr[0] } else { "config_invalid" }, diagnostics: arr)
}

private func gitCodeCkbEndpointAllowed(endpoint: String): Bool {
    let e = endpoint.trimAscii()
    if (!e.startsWith("http://127.0.0.1:")) {
        return false
    }
    let rest = e["http://127.0.0.1:".size..]
    if (rest.isEmpty()) {
        return false
    }
    for (b in rest.toArray()) {
        if (b == b'/') {
            return true
        }
        if (b < b'0' || b > b'9') {
            return false
        }
    }
    true
}

public func validateGitCodeReviewRuntimeConfig(config: GitCodeReviewRuntimeConfig): GitCodeReviewConfigValidationResult {
    let diags = ArrayList<String>()
    let root = config.sourceWorkspace.root.trimAscii()
    let expandedRoot = gitCodeReviewExpandHomePath(root)
    if (root.isEmpty() || root.contains("..") || !(expandedRoot.startsWith("/"))) {
        addDiag(diags, "invalid_source_workspace_root")
    }
    let cwd = try { canonicalize(Path(".")).toString() } catch (_: Exception) { Path(".").toString() }
    if (!expandedRoot.isEmpty() && cwd.startsWith("/") && (expandedRoot == cwd || expandedRoot.startsWith(cwd + "/"))) {
        addDiag(diags, "invalid_source_workspace_root")
    }
    if (config.sourceWorkspace.allowedHosts.size != 1 || config.sourceWorkspace.allowedHosts[0] != "gitcode.com") {
        addDiag(diags, "sourceWorkspace.allowedHosts")
    }
    if (config.sourceWorkspace.gitTimeoutMs < 1000 || config.sourceWorkspace.gitTimeoutMs > 120000) {
        addDiag(diags, "sourceWorkspace.gitTimeoutMs")
    }
    if (config.sourceWorkspace.maxFilesPerRequest < 1 || config.sourceWorkspace.maxFilesPerRequest > 200) {
        addDiag(diags, "sourceWorkspace.maxFilesPerRequest")
    }
    if (config.sourceWorkspace.maxFileBytes < 1024 || config.sourceWorkspace.maxFileBytes > 1048576) {
        addDiag(diags, "sourceWorkspace.maxFileBytes")
    }

    let mode = config.prReviewAdapter.mode
    if (mode == "mock") {
        addDiag(diags, "mock_adapter_not_allowed_in_production_config")
    } else if (mode != "disabled" && mode != "external") {
        addDiag(diags, "prReviewAdapter.mode")
    }
    if (mode == "disabled" && !config.prReviewAdapter.endpoint.isEmpty()) {
        addDiag(diags, "prReviewAdapter.endpoint")
    }
    if (mode == "external" && !(config.prReviewAdapter.endpoint.startsWith("http://") || config.prReviewAdapter.endpoint.startsWith("https://"))) {
        addDiag(diags, "prReviewAdapter.endpoint")
    }
    if (config.prReviewAdapter.timeoutMs < 1000 || config.prReviewAdapter.timeoutMs > 60000) {
        addDiag(diags, "prReviewAdapter.timeoutMs")
    }
    if (config.prReviewAdapter.maxFindings < 1 || config.prReviewAdapter.maxFindings > 100) {
        addDiag(diags, "prReviewAdapter.maxFindings")
    }
    if (config.prReviewAdapter.maxFindingChars < 100 || config.prReviewAdapter.maxFindingChars > 10000) {
        addDiag(diags, "prReviewAdapter.maxFindingChars")
    }
    if (config.prReviewAdapter.authHeaderEnv.contains(" ") || config.prReviewAdapter.authHeaderEnv.contains("/")) {
        addDiag(diags, "prReviewAdapter.authHeaderEnv")
    }

    if (config.promptTemplates.dir.trimAscii().isEmpty() || config.promptTemplates.dir.contains("..")) {
        addDiag(diags, "promptTemplates.dir")
    }
    if (config.promptTemplates.reloadPolicy != "on_plugin_load") {
        addDiag(diags, "promptTemplates.reloadPolicy")
    }
    if (config.promptTemplates.maxTemplateBytes < 4096 || config.promptTemplates.maxTemplateBytes > 131072) {
        addDiag(diags, "promptTemplates.maxTemplateBytes")
    }
    if (!config.promptTemplates.strictValidation) {
        addDiag(diags, "promptTemplates.strictValidation")
    }

    let ckb = config.ckbService
    if (ckb.enabled) {
        if (ckb.endpoint.isEmpty() || !gitCodeCkbEndpointAllowed(ckb.endpoint)) {
            addDiag(diags, "ckbService.endpoint")
        }
    } else if (!ckb.endpoint.isEmpty() && !gitCodeCkbEndpointAllowed(ckb.endpoint)) {
        addDiag(diags, "ckbService.endpoint")
    }
    if (ckb.timeoutMs < 1000 || ckb.timeoutMs > 30000) {
        addDiag(diags, "ckbService.timeoutMs")
    }
    if (ckb.defaultBudget < 1 || ckb.defaultBudget > 20) {
        addDiag(diags, "ckbService.defaultBudget")
    }
    if (ckb.maxBudget < 1 || ckb.maxBudget > 20 || ckb.defaultBudget > ckb.maxBudget) {
        addDiag(diags, "ckbService.maxBudget")
    }
    if (diags.size > 0) {
        return invalid(diags)
    }
    GitCodeReviewConfigValidationResult(true)
}

public func gitCodeReviewJsonArrayString(values: Array<String>): JsonArray {
    let arr = JsonArray([])
    for (value in values) {
        arr.add(JsonString(value))
    }
    arr
}
