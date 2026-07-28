package metis.cron

import metis.gateway.logging.gatewayLogRedactText
import std.fs.{Directory, File, Path, exists, remove, rename}
import std.posix.chmod
import std.time.DateTime
import stdx.encoding.json.*

public class CronDeliveryIntentArtifact {
    public let executionId: String
    public let jobId: String
    public let answer: String
    public let mode: String
    public let channel: String
    public let to: String
    public let accountId: String
    public let startedAtMs: Int64
    public let bestEffortDeliver: Bool

    public init(executionId: String, jobId: String, answer: String, mode: String, channel: String, to: String, accountId: String, startedAtMs: Int64, bestEffortDeliver: Bool) {
        this.executionId = executionId
        this.jobId = jobId
        this.answer = answer
        this.mode = mode
        this.channel = channel
        this.to = to
        this.accountId = accountId
        this.startedAtMs = startedAtMs
        this.bestEffortDeliver = bestEffortDeliver
    }
}

public class CronDeliveryIntentReadResult {
    public let ok: Bool
    public let status: String
    public let artifact: Option<CronDeliveryIntentArtifact>
    public init(ok: Bool, status: String, artifact!: Option<CronDeliveryIntentArtifact> = None<CronDeliveryIntentArtifact>) {
        this.ok = ok
        this.status = status
        this.artifact = artifact
    }
}

private func cronDeliveryIntentRef(executionId: String): String {
    let hash = executionId.hashCode()
    "intent-${if (hash < 0) { "n${-hash}" } else { hash.toString() }}.json"
}

private func cronDeliveryIntentDir(storePath: Path): Path {
    storePath.parent.join("delivery-intents")
}

public func cronDeliveryIntentPath(storePath: Path, artifactRef: String): Path {
    let safe = artifactRef.trimAscii()
    if (!safe.startsWith("intent-") || !safe.endsWith(".json") || safe.contains("/") || safe.contains("\\") || safe.contains("..")) {
        throw Exception("invalid delivery intent artifact ref")
    }
    cronDeliveryIntentDir(storePath).join(safe)
}

public func saveCronDeliveryIntentArtifact(storePath: Path, artifact: CronDeliveryIntentArtifact): String {
    if (
        gatewayLogRedactText(artifact.answer) != artifact.answer ||
        artifact.answer.contains("/Users/") ||
        artifact.answer.contains("/home/")
    ) {
        throw Exception("delivery intent contains sensitive content")
    }
    let dir = cronDeliveryIntentDir(storePath)
    if (!exists(dir)) { Directory.create(dir, recursive: true) }
    chmod(dir.toString(), UInt32(0o700))
    let artifactRef = cronDeliveryIntentRef(artifact.executionId)
    let target = cronDeliveryIntentPath(storePath, artifactRef)
    let tmp = dir.join(".${artifactRef}.${DateTime.now().toUnixTimeStamp().toNanoseconds()}.tmp")
    let root = JsonObject()
    root.put("version", JsonInt(1))
    root.put("executionId", JsonString(artifact.executionId))
    root.put("jobId", JsonString(artifact.jobId))
    root.put("answer", JsonString(artifact.answer))
    root.put("mode", JsonString(artifact.mode))
    root.put("channel", JsonString(artifact.channel))
    root.put("to", JsonString(artifact.to))
    root.put("accountId", JsonString(artifact.accountId))
    root.put("startedAtMs", JsonInt(artifact.startedAtMs))
    root.put("bestEffortDeliver", JsonBool(artifact.bestEffortDeliver))
    File.writeTo(tmp, root.toJsonString().toArray())
    chmod(tmp.toString(), UInt32(0o600))
    rename(tmp, to: target, overwrite: true)
    chmod(target.toString(), UInt32(0o600))
    artifactRef
}

public func loadCronDeliveryIntentArtifact(storePath: Path, artifactRef: String, expectedExecutionId!: String = ""): CronDeliveryIntentReadResult {
    let path = try { cronDeliveryIntentPath(storePath, artifactRef) } catch (_: Exception) {
        return CronDeliveryIntentReadResult(false, "invalid_artifact_ref")
    }
    if (!exists(path)) { return CronDeliveryIntentReadResult(false, "not_found") }
    let text = try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) {
        return CronDeliveryIntentReadResult(false, "invalid_response_encoding")
    }
    try {
        let root = JsonValue.fromStr(text).asObject()
        let executionId = root.get("executionId").getOrThrow().asString().getValue()
        if (!expectedExecutionId.isEmpty() && executionId != expectedExecutionId) {
            return CronDeliveryIntentReadResult(false, "identity_mismatch")
        }
        CronDeliveryIntentReadResult(true, "ok", artifact: Some(CronDeliveryIntentArtifact(
            executionId,
            root.get("jobId").getOrThrow().asString().getValue(),
            root.get("answer").getOrThrow().asString().getValue(),
            root.get("mode").getOrThrow().asString().getValue(),
            root.get("channel").getOrThrow().asString().getValue(),
            root.get("to").getOrThrow().asString().getValue(),
            root.get("accountId").getOrThrow().asString().getValue(),
            root.get("startedAtMs").getOrThrow().asInt().getValue(),
            root.get("bestEffortDeliver").getOrThrow().asBool().getValue()
        )))
    } catch (_: Exception) {
        CronDeliveryIntentReadResult(false, "malformed_json")
    }
}

public func deleteCronDeliveryIntentArtifact(storePath: Path, artifactRef: String): Bool {
    try {
        let path = cronDeliveryIntentPath(storePath, artifactRef)
        if (exists(path)) { remove(path) }
        true
    } catch (_: Exception) {
        false
    }
}
