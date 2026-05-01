package metis.gateway.tools

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext}

import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString, JsonValue}

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
