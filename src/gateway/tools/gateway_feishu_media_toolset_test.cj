package metis.gateway.tools

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext}

import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

@Test
public class GatewayFeishuMediaToolsetTest {
    private func mediaContext(downloaded!: Bool = true, skippedReason!: String = ""): JsonObject {
        let media = JsonObject()
        media.put("channel", JsonString("feishu"))
        media.put("accountId", JsonString("default"))
        let records = JsonArray([])
        let record = JsonObject()
        record.put("mediaId", JsonString("default:oc_1:om_1:image:img_1"))
        record.put("channel", JsonString("feishu"))
        record.put("accountId", JsonString("default"))
        record.put("peerId", JsonString("oc_1"))
        record.put("messageId", JsonString("om_1"))
        record.put("mediaKind", JsonString("image"))
        record.put("resourceType", JsonString("image"))
        record.put("fileKey", JsonString("img_1"))
        record.put("fileId", JsonString("img_1"))
        record.put("fileName", JsonString("diagram.png"))
        record.put("mimeType", JsonString("image/png"))
        record.put("fileSize", JsonInt(10))
        record.put("downloaded", JsonBool(downloaded))
        record.put("skippedReason", JsonString(skippedReason))
        record.put("localPath", JsonString(if (downloaded) { "/tmp/metis-feishu-media/default/oc_1/om_1/diagram.png" } else { "" }))
        records.add(record)
        media.put("records", records)
        media
    }

    @TestCase
    public func feishuMediaListReadsCurrentRuntimeContext(): Unit {
        let out = gatewayWithToolRuntimeContext(
            GatewayToolRuntimeContext("feishu", channelName: "feishu", sessionKey: "feishu:chat:1", mediaContext: this.mediaContext()),
            { => GatewayFeishuMediaToolset().debugFeishuMediaListForTest() }
        )
        let json = JsonValue.fromStr(out).asObject()
        @Expect(json.get("ok").getOrThrow().asBool().getValue(), true)
        @Expect(json.get("count").getOrThrow().asInt().getValue(), 1)
        let record = json.get("records").getOrThrow().asArray()[0].asObject()
        @Expect(record.get("fileKey").getOrThrow().asString().getValue(), "img_1")
    }

    @TestCase
    public func feishuFetchResourceReturnsDownloadedLocalPath(): Unit {
        let out = gatewayWithToolRuntimeContext(
            GatewayToolRuntimeContext("feishu", channelName: "feishu", sessionKey: "feishu:chat:1", mediaContext: this.mediaContext()),
            { => GatewayFeishuMediaToolset().debugFeishuFetchResourceForTest("om_1", "img_1", Some("image")) }
        )
        let json = JsonValue.fromStr(out).asObject()
        @Expect(json.get("ok").getOrThrow().asBool().getValue(), true)
        @Expect(json.get("status").getOrThrow().asString().getValue(), "ok")
        @Expect(json.get("saved_path").getOrThrow().asString().getValue().contains("diagram.png"), true)
        @Expect(json.get("content_type").getOrThrow().asString().getValue(), "image/png")
    }

    @TestCase
    public func feishuFetchResourceReportsSkippedReason(): Unit {
        let out = gatewayWithToolRuntimeContext(
            GatewayToolRuntimeContext("feishu", channelName: "feishu", sessionKey: "feishu:chat:1", mediaContext: this.mediaContext(downloaded: false, skippedReason: "forbidden")),
            { => GatewayFeishuMediaToolset().debugFeishuFetchResourceForTest("om_1", "img_1", Some("image")) }
        )
        let json = JsonValue.fromStr(out).asObject()
        @Expect(json.get("ok").getOrThrow().asBool().getValue(), false)
        @Expect(json.get("status").getOrThrow().asString().getValue(), "forbidden")
        @Expect(json.get("reason").getOrThrow().asString().getValue(), "forbidden")
    }
}
