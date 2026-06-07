package metis.gateway.gitcode_plugin

import std.collection.ArrayList
import std.fs.{Directory, File, Path, exists}
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString}

public class GitCodeGitRunnerResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String

    public init(ok: Bool, status!: String = "ok", diagnostic!: String = "") {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
    }
}

private var gitCodeSourceWorkspaceGitRunnerForTest: Option<(String, String, String, String) -> GitCodeGitRunnerResult> =
    None<(String, String, String, String) -> GitCodeGitRunnerResult>

public func setGitCodeSourceWorkspaceGitRunnerForTest(runner: Option<(String, String, String, String) -> GitCodeGitRunnerResult>): Unit {
    gitCodeSourceWorkspaceGitRunnerForTest = runner
}

public class GitCodeSourceWorkspaceResult {
    public let workspaceStatus: String
    public let sourceContextStatus: String
    public let cloneStatus: String
    public let updateStatus: String
    public let refStatus: String
    public let workspacePath: String
    public let repoKey: String
    public let ref: String
    public let diagnostics: Array<String>

    public init(
        workspaceStatus: String,
        sourceContextStatus!: String = "",
        cloneStatus!: String = "",
        updateStatus!: String = "",
        refStatus!: String = "trusted",
        workspacePath!: String = "",
        repoKey!: String = "",
        ref!: String = "",
        diagnostics!: Array<String> = []
    ) {
        this.workspaceStatus = workspaceStatus.trimAscii()
        this.sourceContextStatus = if (sourceContextStatus.trimAscii().isEmpty()) { this.workspaceStatus } else { sourceContextStatus.trimAscii() }
        this.cloneStatus = cloneStatus.trimAscii()
        this.updateStatus = updateStatus.trimAscii()
        this.refStatus = refStatus.trimAscii()
        this.workspacePath = workspacePath.trimAscii()
        this.repoKey = repoKey.trimAscii()
        this.ref = ref.trimAscii()
        this.diagnostics = diagnostics
    }
}

public class SourceContextFile {
    public let path: String
    public let summary: String
    public let symbols: Array<String>
    public let truncated: Bool

    public init(path: String, summary: String, symbols!: Array<String> = [], truncated!: Bool = false) {
        this.path = path.trimAscii()
        this.summary = gitCodeReviewRedactSensitiveText(summary.trimAscii())
        this.symbols = symbols
        this.truncated = truncated
    }
}

public class SourceContextPack {
    public let status: String
    public let ref: String
    public let files: Array<SourceContextFile>
    public let diagnostics: Array<String>

    public init(status: String, ref!: String = "", files!: Array<SourceContextFile> = [], diagnostics!: Array<String> = []) {
        this.status = status.trimAscii()
        this.ref = ref.trimAscii()
        this.files = files
        this.diagnostics = diagnostics
    }

    public func toJson(): JsonObject {
        let out = JsonObject()
        out.put("status", JsonString(this.status))
        out.put("ref", JsonString(this.ref))
        let arr = JsonArray([])
        for (file in this.files) {
            arr.add(gitCodeSourceContextFileToJson(file))
        }
        out.put("files", arr)
        out.put("diagnostics", gitCodeReviewJsonArrayString(this.diagnostics))
        out
    }
}

public func gitCodeSourceContextFileToJson(file: SourceContextFile): JsonObject {
    let obj = JsonObject()
    obj.put("path", JsonString(file.path))
    obj.put("summary", JsonString(file.summary))
    obj.put("symbols", gitCodeReviewJsonArrayString(file.symbols))
    obj.put("truncated", JsonBool(file.truncated))
    obj
}

private func sourceHostFromRepo(repo: String): String {
    let r = repo.trimAscii()
    if (r.startsWith("https://")) {
        let rest = r["https://".size..]
        match (rest.indexOf("/")) {
            case Some(slash) => rest[..slash]
            case None => rest
        }
    } else if (r.startsWith("http://")) {
        let rest = r["http://".size..]
        match (rest.indexOf("/")) {
            case Some(slash) => rest[..slash]
            case None => rest
        }
    } else {
        ""
    }
}

private func sourceRepoKey(repo: String): String {
    var r = repo.trimAscii()
    if (r.endsWith(".git")) { r = r[..r.size - 4] }
    let parts = r.split("/")
    if (parts.size >= 2) {
        let owner = parts[parts.size - 2].trimAscii()
        let name = parts[parts.size - 1].trimAscii()
        return "${owner}/${name}"
    }
    r
}

private func sourceHash(text: String): String {
    var hash: Int64 = 5381
    for (b in text.toArray()) {
        hash = (hash * 33 + Int64(b)) % 1000000007
    }
    if (hash < 0) { hash = -hash }
    hash.toString()
}

public func resolveSourceRef(ref: String): String {
    let r = ref.trimAscii()
    if (r.isEmpty()) { return "main" }
    if (r.contains("..") || r.startsWith("/") || r.startsWith("-") || r.contains(" ") || r.contains(";") || r.contains("\\") || r.contains("~")) {
        return "main"
    }
    r
}

private func refTrusted(ref: String): Bool {
    ref.trimAscii() == resolveSourceRef(ref)
}

private func runGit(action: String, repo: String, ref: String, path: String): GitCodeGitRunnerResult {
    match (gitCodeSourceWorkspaceGitRunnerForTest) {
        case Some(runner) => runner(action, repo, ref, path)
        case None => GitCodeGitRunnerResult(false, status: "${action}_runner_not_configured")
    }
}

public func ensureRepoWorkspace(repo: String, ref: String, config: GitCodeReviewRuntimeConfig): GitCodeSourceWorkspaceResult {
    let validation = validateGitCodeReviewRuntimeConfig(config)
    if (!validation.ok && validation.diagnostics.contains("invalid_source_workspace_root")) {
        return GitCodeSourceWorkspaceResult("invalid_workspace_root", diagnostics: validation.diagnostics)
    }
    let root = gitCodeReviewExpandHomePath(config.sourceWorkspace.root)
    if (root.trimAscii().isEmpty() || root.contains("..") || !root.startsWith("/")) {
        return GitCodeSourceWorkspaceResult("invalid_workspace_root")
    }
    let host = sourceHostFromRepo(repo)
    if (!config.sourceWorkspace.allowedHosts.contains(host)) {
        return GitCodeSourceWorkspaceResult("invalid_clone_host")
    }
    let safeRef = resolveSourceRef(ref)
    let refStatus = if (refTrusted(ref)) { "trusted" } else { "ref_untrusted" }
    let repoKey = sourceRepoKey(repo)
    let repoDir = Path(root).join(sourceHash("${host}/${repoKey}"))
    if (!exists(repoDir)) {
        Directory.create(repoDir.parent, recursive: true)
        let cloned = runGit("clone", repo, safeRef, repoDir.toString())
        if (!cloned.ok) {
            return GitCodeSourceWorkspaceResult("clone_failed", sourceContextStatus: "clone_failed", cloneStatus: "clone_failed", refStatus: refStatus, workspacePath: repoDir.toString(), repoKey: repoKey, ref: safeRef)
        }
        Directory.create(repoDir, recursive: true)
        return GitCodeSourceWorkspaceResult("ready", sourceContextStatus: "resolved", cloneStatus: "cloned", refStatus: refStatus, workspacePath: repoDir.toString(), repoKey: repoKey, ref: safeRef)
    }
    updateRepoWorkspace(repo, safeRef, config, workspacePath: repoDir.toString(), repoKey: repoKey, refStatus: refStatus)
}

public func updateRepoWorkspace(
    repo: String,
    ref: String,
    config: GitCodeReviewRuntimeConfig,
    workspacePath!: String = "",
    repoKey!: String = "",
    refStatus!: String = "trusted"
): GitCodeSourceWorkspaceResult {
    let root = gitCodeReviewExpandHomePath(config.sourceWorkspace.root)
    let path = if (workspacePath.trimAscii().isEmpty()) { Path(root).join(sourceHash(repo)).toString() } else { workspacePath.trimAscii() }
    let pulled = runGit("pull", repo, resolveSourceRef(ref), path)
    if (!pulled.ok) {
        return GitCodeSourceWorkspaceResult("ready", sourceContextStatus: "stale_available", updateStatus: "pull_failed", refStatus: refStatus, workspacePath: path, repoKey: repoKey, ref: resolveSourceRef(ref))
    }
    GitCodeSourceWorkspaceResult("ready", sourceContextStatus: "resolved", updateStatus: "pulled", refStatus: refStatus, workspacePath: path, repoKey: repoKey, ref: resolveSourceRef(ref))
}

private func sourceSummary(text: String, maxBytes: Int64): (String, Bool) {
    let safe = gitCodeReviewRedactSensitiveText(text)
    if (Int64(safe.size) <= maxBytes) {
        (safe, false)
    } else {
        (safe[..Int64(maxBytes)], true)
    }
}

public func buildSourceContextPack(paths: Array<String>, workspacePath: String, config: GitCodeReviewRuntimeConfig): SourceContextPack {
    let files = ArrayList<SourceContextFile>()
    let diagnostics = ArrayList<String>()
    let limit = config.sourceWorkspace.maxFilesPerRequest
    for (raw in paths) {
        if (Int64(files.size) >= limit) {
            diagnostics.add("max_files_reached")
            break
        }
        let rel = raw.trimAscii()
        if (!gitCodeReviewIsRepoRelativePath(rel)) {
            diagnostics.add("path_invalid")
            continue
        }
        let full = Path(workspacePath).join(rel)
        if (!exists(full)) {
            diagnostics.add("source_file_missing")
            continue
        }
        let bytes = File.readFrom(full)
        let text = String.fromUtf8(bytes)
        let (summary, truncated) = sourceSummary(text, config.sourceWorkspace.maxFileBytes)
        files.add(SourceContextFile(rel, summary, truncated: truncated))
    }
    SourceContextPack(if (files.size > 0) { "resolved" } else { "unavailable" }, files: files.toArray(), diagnostics: diagnostics.toArray())
}
