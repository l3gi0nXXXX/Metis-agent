package metis.core

import std.fs.{Directory, File, Path, exists}
import std.time.DateTime
import std.convert.*
import stdx.encoding.json.{JsonInt, JsonObject, JsonString, JsonValue}

public class GatewayMediaAsset {
    public let assetId: String
    public let channel: String
    public let accountId: String
    public let conversationId: String
    public let messageId: String
    public let kind: String
    public let mimeType: String
    public let fileName: String
    public let absolutePath: String
    public let createdAtMs: Int64
    public let source: String

    public init(
        assetId: String,
        channel: String,
        accountId: String,
        conversationId: String,
        messageId: String,
        kind: String,
        mimeType: String,
        fileName: String,
        absolutePath: String,
        createdAtMs: Int64,
        source!: String = ""
    ) {
        this.assetId = assetId
        this.channel = channel
        this.accountId = accountId
        this.conversationId = conversationId
        this.messageId = messageId
        this.kind = kind
        this.mimeType = mimeType
        this.fileName = fileName
        this.absolutePath = absolutePath
        this.createdAtMs = createdAtMs
        this.source = source
    }

    public func toJsonObject(): JsonObject {
        let out = JsonObject()
        out.put("assetId", JsonString(this.assetId))
        out.put("channel", JsonString(this.channel))
        out.put("accountId", JsonString(this.accountId))
        out.put("conversationId", JsonString(this.conversationId))
        out.put("messageId", JsonString(this.messageId))
        out.put("kind", JsonString(this.kind))
        out.put("mimeType", JsonString(this.mimeType))
        out.put("fileName", JsonString(this.fileName))
        out.put("absolutePath", JsonString(this.absolutePath))
        out.put("createdAtMs", JsonInt(this.createdAtMs))
        out.put("source", JsonString(this.source))
        out
    }
}

private func gatewayMediaAssetNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

private func gatewayMediaAssetJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func gatewayMediaAssetJsonInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { Int64.parse(v.toJsonString()) } catch (_: Exception) { 0 }
        case None => 0
    }
}

private func gatewayMediaAssetSafePart(raw: String, fallback: String): String {
    var out = raw.trimAscii()
    if (out.isEmpty()) {
        out = fallback
    }
    out = out.replace("/", "-").replace("\\", "-").replace(":", "-").replace(" ", "-")
    out = out.replace("..", "-")
    while (out.contains("--")) {
        out = out.replace("--", "-")
    }
    if (out.isEmpty() || out == "." || out == "-") {
        return fallback
    }
    out
}

private func gatewayMediaAssetExtension(fileName: String, mimeType: String, kind: String): String {
    let lowered = fileName.toAsciiLower()
    match (lowered.lastIndexOf(".")) {
        case Some(idx) =>
            let ext = lowered[idx + 1..].trimAscii()
            if (!ext.isEmpty() && ext.size <= 8 && !ext.contains("/") && !ext.contains("\\")) {
                return ext
            }
        case None => ()
    }
    let mime = mimeType.toAsciiLower()
    if (mime.contains("png")) { return "png" }
    if (mime.contains("jpeg") || mime.contains("jpg")) { return "jpg" }
    if (mime.contains("webp")) { return "webp" }
    if (mime.contains("gif")) { return "gif" }
    if (mime.contains("ogg")) { return "ogg" }
    if (mime.contains("mpeg") || mime.contains("mp3")) { return "mp3" }
    if (mime.contains("wav")) { return "wav" }
    if (mime.contains("mp4")) { return "mp4" }
    match (kind.toAsciiLower()) {
        case "image" => "png"
        case "audio" | "voice" => "ogg"
        case "video" => "mp4"
        case _ => "bin"
    }
}

private func gatewayMediaAssetFromJson(obj: JsonObject): GatewayMediaAsset {
    GatewayMediaAsset(
        gatewayMediaAssetJsonString(obj, "assetId"),
        gatewayMediaAssetJsonString(obj, "channel"),
        gatewayMediaAssetJsonString(obj, "accountId"),
        gatewayMediaAssetJsonString(obj, "conversationId"),
        gatewayMediaAssetJsonString(obj, "messageId"),
        gatewayMediaAssetJsonString(obj, "kind"),
        gatewayMediaAssetJsonString(obj, "mimeType"),
        gatewayMediaAssetJsonString(obj, "fileName"),
        gatewayMediaAssetJsonString(obj, "absolutePath"),
        gatewayMediaAssetJsonInt(obj, "createdAtMs"),
        source: gatewayMediaAssetJsonString(obj, "source")
    )
}

public class GatewayMediaAssetStore {
    public let root: Path

    public init(root: Path) {
        this.root = root
    }

    private func indexRoot(): Path {
        this.root.join("assets")
    }

    private func mediaRoot(): Path {
        this.root.join("media")
    }

    public func assertPathAllowed(path: Path): Bool {
        let rootText = this.root.toString()
        let pathText = path.toString()
        if (rootText.isEmpty() || pathText.isEmpty()) {
            return false
        }
        if (pathText.endsWith("metis.json") || pathText.contains("/.metis/metis.json") || pathText.contains("/../") || pathText.endsWith("/..")) {
            return false
        }
        pathText == rootText || pathText.startsWith("${rootText}/")
    }

    private func ensureRoots(): Unit {
        if (!exists(this.indexRoot())) {
            Directory.create(this.indexRoot(), recursive: true)
        }
        if (!exists(this.mediaRoot())) {
            Directory.create(this.mediaRoot(), recursive: true)
        }
    }

    private func assetId(channel: String, accountId: String, conversationId: String, messageId: String, kind: String): String {
        "${gatewayMediaAssetSafePart(channel, "channel")}-${gatewayMediaAssetSafePart(accountId, "account")}-${gatewayMediaAssetSafePart(conversationId, "conversation")}-${gatewayMediaAssetSafePart(messageId, "message")}-${gatewayMediaAssetSafePart(kind, "file")}"
    }

    private func assetPath(channel: String, accountId: String, conversationId: String, messageId: String, kind: String, fileName: String, mimeType: String): Path {
        let ext = gatewayMediaAssetExtension(fileName, mimeType, kind)
        let safeFileName = gatewayMediaAssetSafePart(fileName, "asset.${ext}")
        let finalName = if (safeFileName.contains(".")) { safeFileName } else { "${safeFileName}.${ext}" }
        this.mediaRoot()
            .join(gatewayMediaAssetSafePart(channel, "channel"))
            .join(gatewayMediaAssetSafePart(accountId, "account"))
            .join(gatewayMediaAssetSafePart(conversationId, "conversation"))
            .join(gatewayMediaAssetSafePart(messageId, "message"))
            .join(gatewayMediaAssetSafePart(kind, "file"))
            .join(finalName)
    }

    private func indexPath(assetId: String): Path {
        this.indexRoot().join("${gatewayMediaAssetSafePart(assetId, "asset")}.json")
    }

    public func saveBytes(
        bytes: Array<Byte>,
        channel!: String = "",
        accountId!: String = "",
        conversationId!: String = "",
        messageId!: String = "",
        kind!: String = "file",
        mimeType!: String = "",
        fileName!: String = "",
        source!: String = ""
    ): GatewayMediaAsset {
        this.ensureRoots()
        let normalizedChannel = gatewayMediaAssetSafePart(channel, "channel")
        let normalizedAccount = gatewayMediaAssetSafePart(accountId, "account")
        let normalizedConversation = gatewayMediaAssetSafePart(conversationId, "conversation")
        let normalizedMessage = gatewayMediaAssetSafePart(messageId, "message")
        let normalizedKind = gatewayMediaAssetSafePart(kind, "file")
        let id = this.assetId(normalizedChannel, normalizedAccount, normalizedConversation, normalizedMessage, normalizedKind)
        let outputPath = this.assetPath(normalizedChannel, normalizedAccount, normalizedConversation, normalizedMessage, normalizedKind, fileName, mimeType)
        if (!this.assertPathAllowed(outputPath)) {
            throw Exception("media asset output path is outside managed root")
        }
        let parent = outputPath.parent
        if (!exists(parent)) {
            Directory.create(parent, recursive: true)
        }
        File.writeTo(outputPath, bytes)
        let asset = GatewayMediaAsset(
            id,
            normalizedChannel,
            normalizedAccount,
            normalizedConversation,
            normalizedMessage,
            normalizedKind,
            mimeType.trimAscii(),
            outputPath.fileName,
            outputPath.toString(),
            gatewayMediaAssetNowMs(),
            source: source.trimAscii()
        )
        File.writeTo(this.indexPath(id), asset.toJsonObject().toJsonString().toArray())
        asset
    }

    public func importLocalPath(
        path: Path,
        channel!: String = "",
        accountId!: String = "",
        conversationId!: String = "",
        messageId!: String = "",
        kind!: String = "file",
        mimeType!: String = "",
        fileName!: String = "",
        source!: String = "local"
    ): GatewayMediaAsset {
        if (!this.assertPathAllowed(path)) {
            throw Exception("media asset import path is outside managed root")
        }
        let bytes = File.readFrom(path)
        let effectiveName = if (fileName.trimAscii().isEmpty()) { path.fileName } else { fileName.trimAscii() }
        this.saveBytes(bytes, channel: channel, accountId: accountId, conversationId: conversationId, messageId: messageId, kind: kind, mimeType: mimeType, fileName: effectiveName, source: source)
    }

    public func resolve(assetId: String): Option<GatewayMediaAsset> {
        let path = this.indexPath(assetId)
        if (!exists(path)) {
            return None<GatewayMediaAsset>
        }
        try {
            let text = String.fromUtf8(File.readFrom(path))
            let obj = JsonValue.fromStr(text).asObject()
            let asset = gatewayMediaAssetFromJson(obj)
            if (!this.assertPathAllowed(Path(asset.absolutePath))) {
                return None<GatewayMediaAsset>
            }
            return Some(asset)
        } catch (_: Exception) {
            return None<GatewayMediaAsset>
        }
    }
}

public func gatewayMediaAssetStoreForRoot(root: Path): GatewayMediaAssetStore {
    GatewayMediaAssetStore(root)
}
