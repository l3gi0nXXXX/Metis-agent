package metis.gateway.gitcode_plugin

import std.collection.{ArrayList, HashMap}
import std.fs.{Directory, File, Path, exists}
import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

public class GitCodeSubscriptionLoadResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String

    public init(ok: Bool, status!: String = "ok", diagnostic!: String = "") {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
    }
}

public class GitCodeSubscriptionStore {
    public let path: String
    public let limit: Int64
    private var rows = HashMap<String, GitCodeSubscriptionSnapshot>()
    public var lastLoadDiagnostic: String = ""

    public init(path: String, limit!: Int64 = 100) {
        this.path = path.trimAscii()
        this.limit = limit
    }

    public func load(): GitCodeSubscriptionLoadResult {
        this.rows = HashMap<String, GitCodeSubscriptionSnapshot>()
        this.lastLoadDiagnostic = ""
        if (this.path.isEmpty() || !exists(Path(this.path))) {
            return GitCodeSubscriptionLoadResult(true, status: "missing")
        }
        let raw = try {
            String.fromUtf8(File.readFrom(Path(this.path)))
        } catch (e: Exception) {
            return GitCodeSubscriptionLoadResult(false, status: "read_failed", diagnostic: e.message)
        }
        let lines = raw.split("\n")
        var lineNo: Int64 = 0
        for (line in lines) {
            lineNo++
            let trimmed = line.trimAscii()
            if (trimmed.isEmpty()) { continue }
            let parsed = try {
                Some(JsonValue.fromStr(trimmed).asObject())
            } catch (_: Exception) {
                this.lastLoadDiagnostic = "invalid_line:${lineNo}"
                None<JsonObject>
            }
            match (parsed) {
                case Some(root) =>
                    let target = GitCodeSubscriptionTarget(
                        storeJsonString(root, "channel"),
                        storeJsonString(root, "accountId"),
                        storeJsonString(root, "peerId"),
                        threadId: storeJsonString(root, "threadId")
                    )
                    if (!target.channel.isEmpty() && !target.accountId.isEmpty() && !target.peerId.isEmpty()) {
                        let scope = GitCodeSubscriptionScope(
                            rawEvents: storeJsonBool(root, "rawEvents", fallback: true),
                            generatedReplies: storeJsonBool(root, "generatedReplies", fallback: true)
                        )
                        this.rows[target.targetKey] = GitCodeSubscriptionSnapshot(target, scope, active: storeJsonBool(root, "active", fallback: true))
                    }
                case None => ()
            }
        }
        GitCodeSubscriptionLoadResult(true, diagnostic: this.lastLoadDiagnostic)
    }

    public func createOrUpdate(target: GitCodeSubscriptionTarget, scope!: GitCodeSubscriptionScope = GitCodeSubscriptionScope()): SubscriptionSaveResult {
        let validation = validateGitCodeSubscriptionTarget(target)
        if (!validation.isEmpty()) {
            return SubscriptionSaveResult(false, "invalid_target", targetKey: target.targetKey, diagnostic: validation)
        }
        let existing = this.rows.get(target.targetKey)
        let status = match (existing) {
            case Some(row) =>
                if (row.active) {
                    "already_present"
                } else {
                    if (this.listActive().size >= this.limit) {
                        return SubscriptionSaveResult(false, "subscription_limit_reached", targetKey: target.targetKey, diagnostic: "subscription limit reached", limit: this.limit)
                    }
                    "created"
                }
            case None =>
                if (this.listActive().size >= this.limit) {
                    return SubscriptionSaveResult(false, "subscription_limit_reached", targetKey: target.targetKey, diagnostic: "subscription limit reached", limit: this.limit)
                }
                "created"
        }
        this.rows[target.targetKey] = GitCodeSubscriptionSnapshot(target, scope, active: true)
        if (status == "created") {
            this.save()
        }
        SubscriptionSaveResult(true, status, targetKey: target.targetKey)
    }

    public func remove(target: GitCodeSubscriptionTarget): SubscriptionRemoveResult {
        match (this.rows.get(target.targetKey)) {
            case Some(row) =>
                if (!row.active) { return SubscriptionRemoveResult(true, "already_absent", targetKey: target.targetKey) }
                this.rows[target.targetKey] = GitCodeSubscriptionSnapshot(row.target, row.scope, active: false)
                this.save()
                SubscriptionRemoveResult(true, "removed", targetKey: target.targetKey)
            case None => SubscriptionRemoveResult(true, "already_absent", targetKey: target.targetKey)
        }
    }

    public func listActive(filter!: GitCodeSubscriptionFilter = GitCodeSubscriptionFilter()): ArrayList<GitCodeSubscriptionSnapshot> {
        let out = ArrayList<GitCodeSubscriptionSnapshot>()
        for ((_, row) in this.rows) {
            if (row.active && (filter.channel.isEmpty() || row.target.channel == filter.channel)) {
                out.add(row)
            }
        }
        out
    }

    public func save(): GitCodeSubscriptionLoadResult {
        if (this.path.isEmpty()) {
            return GitCodeSubscriptionLoadResult(false, status: "path_empty", diagnostic: "subscription path is empty")
        }
        let p = Path(this.path)
        let parent = p.parent
        if (!exists(parent)) {
            Directory.create(parent, recursive: true)
        }
        var body = ""
        for ((_, row) in this.rows) {
            if (!row.active) { continue }
            body += gitCodeSubscriptionSnapshotToJsonLine(row) + "\n"
        }
        try {
            File.writeTo(p, body.toArray())
            GitCodeSubscriptionLoadResult(true, status: "saved")
        } catch (e: Exception) {
            GitCodeSubscriptionLoadResult(false, status: "write_failed", diagnostic: e.message)
        }
    }
}

private func gitCodeSubscriptionSnapshotToJsonLine(row: GitCodeSubscriptionSnapshot): String {
    "{" +
        "\"channel\":${JsonString(row.target.channel).toJsonString()}," +
        "\"accountId\":${JsonString(row.target.accountId).toJsonString()}," +
        "\"peerId\":${JsonString(row.target.peerId).toJsonString()}," +
        "\"threadId\":${JsonString(row.target.threadId).toJsonString()}," +
        "\"rawEvents\":${if (row.scope.rawEvents) { "true" } else { "false" }}," +
        "\"generatedReplies\":${if (row.scope.generatedReplies) { "true" } else { "false" }}," +
        "\"active\":${if (row.active) { "true" } else { "false" }}" +
        "}"
}

public func loadGitCodeSubscriptionStore(path: String, limit!: Int64 = 100): GitCodeSubscriptionStore {
    let store = GitCodeSubscriptionStore(path, limit: limit)
    let _ = store.load()
    store
}

public func gitCodeSubscriptionSnapshotToJson(row: GitCodeSubscriptionSnapshot): JsonObject {
    let obj = JsonObject()
    obj.put("channel", JsonString(row.target.channel))
    obj.put("accountId", JsonString(row.target.accountId))
    obj.put("peerId", JsonString(row.target.peerId))
    obj.put("threadId", JsonString(row.target.threadId))
    obj.put("rawEvents", JsonBool(row.scope.rawEvents))
    obj.put("generatedReplies", JsonBool(row.scope.generatedReplies))
    obj.put("active", JsonBool(row.active))
    obj
}

private func validateGitCodeSubscriptionTarget(target: GitCodeSubscriptionTarget): String {
    if (target.channel.isEmpty()) { return "channel is empty" }
    if (target.accountId.isEmpty()) { return "accountId is empty" }
    if (target.peerId.isEmpty()) { return "peerId is empty" }
    ""
}

private func storeJsonString(root: JsonObject, key: String): String {
    match (root.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func storeJsonBool(root: JsonObject, key: String, fallback!: Bool = false): Bool {
    match (root.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}
