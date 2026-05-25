package metis.core

import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.convert.*
import stdx.encoding.json.{JsonInt, JsonObject, JsonString, JsonValue}

public class GatewayMediaRecentStateKey {
    public let channel: String
    public let accountId: String
    public let conversationId: String
    public let sessionId: String

    public init(channel: String, accountId: String, conversationId: String, sessionId!: String = "") {
        this.channel = channel.trimAscii().toAsciiLower()
        this.accountId = accountId.trimAscii()
        this.conversationId = conversationId.trimAscii()
        this.sessionId = sessionId.trimAscii()
    }
}

private func gatewayMediaRecentNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

private func gatewayMediaRecentSafePart(raw: String, fallback: String): String {
    var out = raw.trimAscii()
    if (out.isEmpty()) {
        out = fallback
    }
    out = out.replace("/", "-").replace("\\", "-").replace(":", "-").replace(" ", "-").replace("..", "-")
    while (out.contains("--")) {
        out = out.replace("--", "-")
    }
    if (out.isEmpty() || out == "." || out == "-") {
        return fallback
    }
    out
}

private func gatewayMediaRecentString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func gatewayMediaRecentInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { Int64.parse(v.toJsonString()) } catch (_: Exception) { 0 }
        case None => 0
    }
}

public class GatewayMediaRecentStateStore {
    public let root: Path

    public init(root: Path) {
        this.root = root
    }

    private func stateRoot(): Path {
        this.root.join("recent")
    }

    private func keyPath(key: GatewayMediaRecentStateKey): Path {
        this.stateRoot()
            .join(gatewayMediaRecentSafePart(key.channel, "channel"))
            .join(gatewayMediaRecentSafePart(key.accountId, "account"))
            .join(gatewayMediaRecentSafePart(key.conversationId, "conversation"))
            .join("${gatewayMediaRecentSafePart(key.sessionId, "session")}.json")
    }

    private func ensureRoot(path: Path): Unit {
        let parent = path.parent
        if (!exists(parent)) {
            Directory.create(parent, recursive: true)
        }
    }

    public func remember(key: GatewayMediaRecentStateKey, asset: GatewayMediaAsset): Unit {
        let path = this.keyPath(key)
        this.ensureRoot(path)
        let obj = asset.toJsonObject()
        obj.put("rememberedAtMs", JsonInt(gatewayMediaRecentNowMs()))
        File.writeTo(path, obj.toJsonString().toArray())
    }

    public func lookup(key: GatewayMediaRecentStateKey, maxAgeMs!: Int64 = 0): Option<GatewayMediaAsset> {
        let path = this.keyPath(key)
        if (!exists(path)) {
            return None<GatewayMediaAsset>
        }
        try {
            let obj = JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
            let rememberedAt = gatewayMediaRecentInt(obj, "rememberedAtMs")
            if (maxAgeMs > 0 && rememberedAt > 0 && gatewayMediaRecentNowMs() - rememberedAt > maxAgeMs) {
                return None<GatewayMediaAsset>
            }
            return Some(GatewayMediaAsset(
                gatewayMediaRecentString(obj, "assetId"),
                gatewayMediaRecentString(obj, "channel"),
                gatewayMediaRecentString(obj, "accountId"),
                gatewayMediaRecentString(obj, "conversationId"),
                gatewayMediaRecentString(obj, "messageId"),
                gatewayMediaRecentString(obj, "kind"),
                gatewayMediaRecentString(obj, "mimeType"),
                gatewayMediaRecentString(obj, "fileName"),
                gatewayMediaRecentString(obj, "absolutePath"),
                gatewayMediaRecentInt(obj, "createdAtMs"),
                source: gatewayMediaRecentString(obj, "source")
            ))
        } catch (_: Exception) {
            return None<GatewayMediaAsset>
        }
    }

    public func expire(key: GatewayMediaRecentStateKey): Unit {
        let path = this.keyPath(key)
        if (exists(path)) {
            remove(path)
        }
    }
}

public func gatewayMediaRecentStateStoreForRoot(root: Path): GatewayMediaRecentStateStore {
    GatewayMediaRecentStateStore(root)
}
