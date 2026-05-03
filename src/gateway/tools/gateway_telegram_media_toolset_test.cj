package metis.gateway.tools

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext}
import magic.core.message.Message
import magic.core.model.{AsyncChatResponse, ChatModel, ChatRequest, ChatResponse}
import magic.model.ModelManager

import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString, JsonValue}

private class TelegramMediaToolsetVisionFakeModel <: ChatModel {
    private var _maxTokens: Option<Int64> = None

    public prop provider: String {
        get() { "fake" }
    }

    public prop name: String {
        get() { "telegram-vision" }
    }

    public prop contextLength: Int64 {
        get() { 8192 }
    }

    public mut prop maxTokens: Option<Int64> {
        get() { this._maxTokens }
        set(v) { this._maxTokens = v }
    }

    public func create(request: ChatRequest): ChatResponse {
        let first = request.messageList[0]
        let prefix = match (first.image) {
            case Some(v) => if (v.startsWith("data:image/jpeg;base64,")) { "image-ok" } else { "image-bad" }
            case None => "image-missing"
        }
        ChatResponse(this.fullName, Message.assistant("${prefix}: a red square"))
    }

    public func asyncCreate(request: ChatRequest): AsyncChatResponse {
        throw Exception("async not used in telegram media toolset tests")
    }
}

@Test
public class GatewayTelegramMediaToolsetTest {
    private func mediaContext(localPath: String, mediaKind!: String = "photo", mimeType!: String = "image/jpeg", fileName!: String = "file_1.jpg", relation!: String = "current"): JsonObject {
        let media = JsonObject()
        let records = JsonArray([])
        let record = JsonObject()
        record.put("mediaId", JsonString("tg-default-user-101-photo-photo-file"))
        record.put("messageId", JsonString("101"))
        record.put("relation", JsonString(relation))
        record.put("mediaKind", JsonString(mediaKind))
        record.put("mimeType", JsonString(mimeType))
        record.put("originalFileName", JsonString(fileName))
        record.put("fileName", JsonString(fileName))
        record.put("localPath", JsonString(localPath))
        record.put("downloaded", JsonBool(true))
        if (mediaKind == "sticker") {
            record.put("fileId", JsonString("sticker-file-id"))
            record.put("fileUniqueId", JsonString("sticker-unique-id"))
            record.put("emoji", JsonString("🙂"))
            record.put("setName", JsonString("MetisStickers"))
            record.put("description", JsonString("friendly metis sticker"))
        }
        records.add(record)
        media.put("records", records)
        media
    }

    @TestCase
    public func telegramMediaListReadsCurrentRuntimeContext(): Unit {
        let toolset = GatewayTelegramMediaToolset()
        let context = this.mediaContext("/tmp/metis-media/file_1.jpg")
        let out = gatewayWithToolRuntimeContext(
            GatewayToolRuntimeContext("telegram", channelName: "telegram", sessionKey: "telegram:chat:1", mediaContext: context),
            { => toolset.debugTelegramMediaListForTest() }
        )
        let json = JsonValue.fromStr(out).asObject()
        @Expect(json.get("count").getOrThrow().asInt().getValue(), 1)
        @Expect(json.get("records").getOrThrow().asArray()[0].asObject().get("mediaId").getOrThrow().asString().getValue(), "tg-default-user-101-photo-photo-file")
        @Expect(json.get("records").getOrThrow().asArray()[0].asObject().get("localPath").getOrThrow().asString().getValue(), "/tmp/metis-media/file_1.jpg")
    }

    @TestCase
    public func telegramMediaSaveCopiesDownloadedCurrentMedia(): Unit {
        let root = Path("/tmp/metis-telegram-media-tool-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        Directory.create(root, recursive: true)
        let source = root.join("source.jpg")
        let dest = root.join("out").join("saved.jpg")
        File.writeTo(source, "fake-image-bytes".toArray())
        try {
            let toolset = GatewayTelegramMediaToolset()
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("telegram", channelName: "telegram", sessionKey: "telegram:chat:1", mediaContext: this.mediaContext(source.toString())),
                { => toolset.debugTelegramMediaSaveForTest(dest.toString(), None<String>, None<Int64>) }
            )
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("status").getOrThrow().asString().getValue(), "saved")
            @Expect(exists(dest), true)
            @Expect(String.fromUtf8(File.readFrom(dest)), "fake-image-bytes")
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func telegramMediaGetFindsByMediaIdAndRelation(): Unit {
        let toolset = GatewayTelegramMediaToolset()
        let context = this.mediaContext("/tmp/metis-media/file_1.jpg", relation: "replyTarget")
        let out = gatewayWithToolRuntimeContext(
            GatewayToolRuntimeContext("telegram", channelName: "telegram", sessionKey: "telegram:chat:1", mediaContext: context),
            { => toolset.debugTelegramMediaGetForTest(Some("tg-default-user-101-photo-photo-file"), None<Int64>, None<String>, Some("replyTarget")) }
        )
        let json = JsonValue.fromStr(out).asObject()
        @Expect(json.get("status").getOrThrow().asString().getValue(), "ok")
        @Expect(json.get("media").getOrThrow().asObject().get("relation").getOrThrow().asString().getValue(), "replyTarget")
    }

    @TestCase
    public func telegramMediaReadReadsTextDocumentsOnly(): Unit {
        let root = Path("/tmp/metis-telegram-media-read-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        Directory.create(root, recursive: true)
        let source = root.join("note.txt")
        File.writeTo(source, "hello from telegram file".toArray())
        try {
            let toolset = GatewayTelegramMediaToolset()
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext(
                    "telegram",
                    channelName: "telegram",
                    sessionKey: "telegram:chat:1",
                    mediaContext: this.mediaContext(source.toString(), mediaKind: "document", mimeType: "text/plain", fileName: "note.txt")
                ),
                { => toolset.debugTelegramMediaReadForTest(None<String>, None<Int64>, Some(100)) }
            )
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("readable").getOrThrow().asBool().getValue(), true)
            @Expect(json.get("content").getOrThrow().asString().getValue(), "hello from telegram file")
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func telegramMediaReadRefusesBinaryFiles(): Unit {
        let root = Path("/tmp/metis-telegram-media-binary-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        Directory.create(root, recursive: true)
        let source = root.join("file_1.jpg")
        File.writeTo(source, "fake-image".toArray())
        try {
            let toolset = GatewayTelegramMediaToolset()
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext(
                    "telegram",
                    channelName: "telegram",
                    sessionKey: "telegram:chat:1",
                    mediaContext: this.mediaContext(source.toString(), mediaKind: "photo", mimeType: "image/jpeg", fileName: "file_1.jpg")
                ),
                { => toolset.debugTelegramMediaReadForTest(None<String>, None<Int64>, None<Int64>) }
            )
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("readable").getOrThrow().asBool().getValue(), false)
            @Expect(json.get("reason").getOrThrow().asString().getValue().contains("not a text-readable"), true)
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func telegramMediaSaveRejectsProtectedConfigPath(): Unit {
        let root = Path("/tmp/metis-telegram-media-protected-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        Directory.create(root, recursive: true)
        let source = root.join("source.jpg")
        File.writeTo(source, "fake".toArray())
        try {
            let toolset = GatewayTelegramMediaToolset()
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("telegram", channelName: "telegram", sessionKey: "telegram:chat:1", mediaContext: this.mediaContext(source.toString())),
                { => toolset.debugTelegramMediaSaveForTest("/Users/test/.metis/metis.json", None<String>, None<Int64>) }
            )
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("status").getOrThrow().asString().getValue(), "denied")
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func telegramImageAnalyzeReadsVisionSidecar(): Unit {
        let root = Path("/tmp/metis-telegram-image-analysis-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        Directory.create(root, recursive: true)
        let source = root.join("image.jpg")
        File.writeTo(source, "fake".toArray())
        File.writeTo(Path(source.toString() + ".analysis.txt"), "a red square".toArray())
        try {
            let toolset = GatewayTelegramMediaToolset()
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("telegram", channelName: "telegram", sessionKey: "telegram:chat:1", mediaContext: this.mediaContext(source.toString())),
                { => toolset.debugTelegramImageAnalyzeForTest(None<String>, None<Int64>, Some("describe")) }
            )
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("status").getOrThrow().asString().getValue(), "ok")
            @Expect(json.get("analysis").getOrThrow().asString().getValue(), "a red square")
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func telegramImageAnalyzeUsesConfiguredVisionModelWhenNoSidecarExists(): Unit {
        let root = Path("/tmp/metis-telegram-image-model-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        Directory.create(root, recursive: true)
        let source = root.join("image.jpg")
        File.writeTo(source, "fake".toArray())
        let modelName = "metis-test-telegram-vision-${DateTime.now().toUnixTimeStamp().toMilliseconds()}"
        ModelManager.registerChatModel(modelName, { => TelegramMediaToolsetVisionFakeModel() })
        setGatewayTelegramMediaVisionCandidatesForTest(Some([modelName]))
        try {
            let toolset = GatewayTelegramMediaToolset()
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("telegram", channelName: "telegram", sessionKey: "telegram:chat:1", mediaContext: this.mediaContext(source.toString())),
                { => toolset.debugTelegramImageAnalyzeForTest(None<String>, None<Int64>, Some("describe this image")) }
            )
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("status").getOrThrow().asString().getValue(), "ok")
            @Expect(json.get("analysis").getOrThrow().asString().getValue().contains("image-ok"), true)
            @Expect(json.get("model").getOrThrow().asString().getValue(), "fake:telegram-vision")
        } finally {
            setGatewayTelegramMediaVisionCandidatesForTest(None<Array<String>>)
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func telegramAudioTranscribeReadsTranscriptSidecar(): Unit {
        let root = Path("/tmp/metis-telegram-audio-transcript-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        Directory.create(root, recursive: true)
        let source = root.join("voice.ogg")
        File.writeTo(source, "fake".toArray())
        File.writeTo(Path(source.toString() + ".transcript.txt"), "hello voice".toArray())
        try {
            let toolset = GatewayTelegramMediaToolset()
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext(
                    "telegram",
                    channelName: "telegram",
                    sessionKey: "telegram:chat:1",
                    mediaContext: this.mediaContext(source.toString(), mediaKind: "voice", mimeType: "audio/ogg", fileName: "voice.ogg")
                ),
                { => toolset.debugTelegramAudioTranscribeForTest(None<String>, None<Int64>) }
            )
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("transcript").getOrThrow().asString().getValue(), "hello voice")
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func telegramStickerSearchReadsCurrentContext(): Unit {
        let root = Path("/tmp/metis-telegram-sticker-cache-search-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        setGatewayTelegramStickerCacheRootForTest(Some(root))
        let toolset = GatewayTelegramMediaToolset()
        let context = this.mediaContext("/tmp/metis-media/sticker.webp", mediaKind: "sticker", mimeType: "image/webp", fileName: "sticker.webp")
        try {
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("telegram", channelName: "telegram", sessionKey: "telegram:chat:1", mediaContext: context),
                { => toolset.debugTelegramStickerSearchForTest("friendly", Some(5)) }
            )
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("count").getOrThrow().asInt().getValue(), 1)
            let first = json.get("stickers").getOrThrow().asArray()[0].asObject()
            @Expect(first.get("setName").getOrThrow().asString().getValue(), "MetisStickers")
        } finally {
            setGatewayTelegramStickerCacheRootForTest(None<Path>)
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func telegramStickerGetReadsCurrentContextByFileUniqueId(): Unit {
        let root = Path("/tmp/metis-telegram-sticker-cache-get-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        setGatewayTelegramStickerCacheRootForTest(Some(root))
        let toolset = GatewayTelegramMediaToolset()
        let context = this.mediaContext("/tmp/metis-media/sticker.webp", mediaKind: "sticker", mimeType: "image/webp", fileName: "sticker.webp")
        try {
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("telegram", channelName: "telegram", sessionKey: "telegram:chat:1", mediaContext: context),
                { => toolset.debugTelegramStickerGetForTest(None<String>, Some("sticker-unique-id"), None<String>) }
            )
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("status").getOrThrow().asString().getValue(), "ok")
            let sticker = json.get("sticker").getOrThrow().asObject()
            @Expect(sticker.get("fileId").getOrThrow().asString().getValue(), "sticker-file-id")
            @Expect(sticker.get("description").getOrThrow().asString().getValue(), "friendly metis sticker")
        } finally {
            setGatewayTelegramStickerCacheRootForTest(None<Path>)
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func telegramStickerCacheStatsCountsCurrentContext(): Unit {
        let root = Path("/tmp/metis-telegram-sticker-cache-stats-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        setGatewayTelegramStickerCacheRootForTest(Some(root))
        let toolset = GatewayTelegramMediaToolset()
        let context = this.mediaContext("/tmp/metis-media/sticker.webp", mediaKind: "sticker", mimeType: "image/webp", fileName: "sticker.webp")
        try {
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("telegram", channelName: "telegram", sessionKey: "telegram:chat:1", mediaContext: context),
                { => toolset.debugTelegramStickerCacheStatsForTest() }
            )
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("stickerCount").getOrThrow().asInt().getValue(), 1)
            @Expect(json.get("describedCount").getOrThrow().asInt().getValue(), 1)
            @Expect(exists(root.join("sticker-cache.json")), true)
        } finally {
            setGatewayTelegramStickerCacheRootForTest(None<Path>)
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func telegramStickerSearchReadsDurableCacheAfterContextClears(): Unit {
        let root = Path("/tmp/metis-telegram-sticker-cache-durable-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        setGatewayTelegramStickerCacheRootForTest(Some(root))
        try {
            let toolset = GatewayTelegramMediaToolset()
            let context = this.mediaContext("/tmp/metis-media/sticker.webp", mediaKind: "sticker", mimeType: "image/webp", fileName: "sticker.webp")
            let first = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("telegram", channelName: "telegram", sessionKey: "telegram:chat:1", mediaContext: context),
                { => toolset.debugTelegramStickerSearchForTest("friendly", Some(5)) }
            )
            @Expect(JsonValue.fromStr(first).asObject().get("count").getOrThrow().asInt().getValue(), 1)
            let second = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("telegram", channelName: "telegram", sessionKey: "telegram:chat:1", mediaContext: JsonObject()),
                { => GatewayTelegramMediaToolset().debugTelegramStickerSearchForTest("friendly", Some(5)) }
            )
            @Expect(JsonValue.fromStr(second).asObject().get("count").getOrThrow().asInt().getValue(), 1)
        } finally {
            setGatewayTelegramStickerCacheRootForTest(None<Path>)
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func telegramTargetListReadsAuditEnvelope(): Unit {
        let row = JsonObject()
        row.put("kind", JsonString("user"))
        row.put("id", JsonString("user:123"))
        row.put("displayName", JsonString("user:123"))
        row.put("accountId", JsonString("default"))
        let rows = JsonArray([row])
        let directory = JsonObject()
        directory.put("rows", rows)
        let telegram = JsonObject()
        telegram.put("directory", directory)
        let audit = JsonObject()
        audit.put("telegram", telegram)
        let envelope = JsonObject()
        envelope.put("audit", audit)
        let out = GatewayTelegramMediaToolset().debugTelegramTargetListFromAuditForTest(envelope)
        let json = JsonValue.fromStr(out).asObject()
        @Expect(json.get("count").getOrThrow().asInt().getValue(), 1)
        @Expect(json.get("targets").getOrThrow().asArray()[0].asObject().get("id").getOrThrow().asString().getValue(), "user:123")
    }

    @TestCase
    public func telegramDoctorReadsDiagnosticsEnvelope(): Unit {
        let summary = JsonObject()
        summary.put("state", JsonString("ready"))
        let diagnostics = JsonObject()
        diagnostics.put("summary", summary)
        let doctor = JsonObject()
        doctor.put("telegramDiagnostics", diagnostics)
        let envelope = JsonObject()
        envelope.put("doctor", doctor)
        let out = GatewayTelegramMediaToolset().debugTelegramDoctorFromEnvelopeForTest(envelope)
        let json = JsonValue.fromStr(out).asObject()
        @Expect(json.get("summary").getOrThrow().asObject().get("state").getOrThrow().asString().getValue(), "ready")
    }
}
