package metis.gateway.tools

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext}

import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString, JsonValue}

@Test
public class GatewayTelegramMediaToolsetTest {
    private func mediaContext(localPath: String): JsonObject {
        let media = JsonObject()
        let records = JsonArray([])
        let record = JsonObject()
        record.put("mediaId", JsonString("tg-default-user-101-photo-photo-file"))
        record.put("mediaKind", JsonString("photo"))
        record.put("mimeType", JsonString("image/jpeg"))
        record.put("originalFileName", JsonString("file_1.jpg"))
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
}
