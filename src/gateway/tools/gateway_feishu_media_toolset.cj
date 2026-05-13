package metis.gateway.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*

import metis.core.gatewayCurrentToolRuntimeContext
import metis.io.PrintUtils

import std.collection.HashMap
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

private func feishuMediaToolString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_e: Exception) { "" }
        case None => ""
    }
}

private func feishuMediaToolBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_e: Exception) { false }
        case None => false
    }
}

private func feishuMediaToolInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { v.asInt().getValue() } catch (_e: Exception) { 0 }
        case None => 0
    }
}

private func feishuMediaToolRecords(): JsonArray {
    match (gatewayCurrentToolRuntimeContext()) {
        case Some(ctx) =>
            let channel = if (!ctx.channelName.isEmpty()) { ctx.channelName } else { ctx.sourceLabel }
            let mediaChannel = feishuMediaToolString(ctx.mediaContext, "channel")
            if (!(channel == "feishu" || mediaChannel == "feishu")) {
                return JsonArray([])
            }
            match (ctx.mediaContext.get("records")) {
                case Some(v) => try { v.asArray() } catch (_e: Exception) { JsonArray([]) }
                case None => JsonArray([])
            }
        case None => JsonArray([])
    }
}

private func feishuMediaToolRecordMatches(record: JsonObject, messageId: String, fileKey: String, resourceType: String): Bool {
    let requestedType = resourceType.trimAscii().toAsciiLower()
    if (!messageId.trimAscii().isEmpty() && feishuMediaToolString(record, "messageId") != messageId.trimAscii()) {
        return false
    }
    if (!fileKey.trimAscii().isEmpty()) {
        let keyMatches =
            feishuMediaToolString(record, "fileKey") == fileKey.trimAscii() ||
            feishuMediaToolString(record, "fileId") == fileKey.trimAscii() ||
            feishuMediaToolString(record, "mediaId") == fileKey.trimAscii()
        if (!keyMatches) {
            return false
        }
    }
    if (!requestedType.isEmpty()) {
        let recordType = feishuMediaToolString(record, "resourceType").toAsciiLower()
        let mediaKind = feishuMediaToolString(record, "mediaKind").toAsciiLower()
        if (!(recordType == requestedType || mediaKind == requestedType || (requestedType == "file" && mediaKind != "image"))) {
            return false
        }
    }
    true
}

private func feishuMediaToolFindRecord(messageId: String, fileKey: String, resourceType: String): Option<JsonObject> {
    let records = feishuMediaToolRecords()
    for (item in records.getItems()) {
        let record = try { item.asObject() } catch (_e: Exception) { JsonObject() }
        if (feishuMediaToolRecordMatches(record, messageId, fileKey, resourceType)) {
            return Some(record)
        }
    }
    None<JsonObject>
}

private func feishuMediaToolError(status: String, messageId: String, fileKey: String, resourceType: String, reason!: String = ""): String {
    let out = JsonObject()
    out.put("ok", JsonBool(false))
    out.put("status", JsonString(status))
    out.put("message_id", JsonString(messageId.trimAscii()))
    out.put("file_key", JsonString(fileKey.trimAscii()))
    out.put("type", JsonString(resourceType.trimAscii()))
    if (!reason.trimAscii().isEmpty()) {
        out.put("reason", JsonString(reason.trimAscii()))
    }
    out.toJsonString()
}

private func feishuMediaToolFetchResource(messageId: String, fileKey: String, resourceType: String): String {
    if (messageId.trimAscii().isEmpty() || fileKey.trimAscii().isEmpty()) {
        return feishuMediaToolError("invalid_request", messageId, fileKey, resourceType, reason: "message_id and file_key are required")
    }
    match (feishuMediaToolFindRecord(messageId, fileKey, resourceType)) {
        case Some(record) =>
            let skippedReason = feishuMediaToolString(record, "skippedReason")
            if (!feishuMediaToolBool(record, "downloaded")) {
                return feishuMediaToolError(
                    if (skippedReason.isEmpty()) { "not_downloaded" } else { skippedReason },
                    messageId,
                    fileKey,
                    resourceType,
                    reason: skippedReason
                )
            }
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out.put("status", JsonString("ok"))
            out.put("message_id", JsonString(messageId.trimAscii()))
            out.put("file_key", JsonString(fileKey.trimAscii()))
            out.put("type", JsonString(resourceType.trimAscii()))
            out.put("saved_path", JsonString(feishuMediaToolString(record, "localPath")))
            out.put("content_type", JsonString(feishuMediaToolString(record, "mimeType")))
            out.put("size_bytes", JsonInt(feishuMediaToolInt(record, "fileSize")))
            out.put("file_name", JsonString(feishuMediaToolString(record, "fileName")))
            out.toJsonString()
        case None =>
            feishuMediaToolError("not_found", messageId, fileKey, resourceType, reason: "resource is not present in current Feishu media context")
    }
}

@toolset
public class GatewayFeishuMediaToolset {
    public init() {}

    public func debugFeishuMediaListForTest(): String {
        let records = feishuMediaToolRecords()
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("count", JsonInt(records.size()))
        out.put("records", records)
        out.toJsonString()
    }

    public func debugFeishuFetchResourceForTest(messageId: String, fileKey: String, resourceType: Option<String>): String {
        feishuMediaToolFetchResource(messageId, fileKey, resourceType ?? "file")
    }

    @tool[
        description: "List Feishu media resources attached to the current turn. The list contains only metadata and local paths already staged by the Feishu channel runtime."
    ]
    public func feishu_media_list(): String {
        PrintUtils.printTool("feishu_media_list", shortMessage: "current")
        let records = feishuMediaToolRecords()
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("count", JsonInt(records.size()))
        out.put("records", records)
        out.toJsonString()
    }

    @tool[
        description: "Fetch a Feishu IM message resource from the current turn context. Parameters are message_id, file_key, and type. Use type=image for image resources and type=file for file/audio/video resources. This returns the staged local file path when the Feishu channel already downloaded the resource; otherwise it returns a structured permission or download diagnostic."
    ]
    public func feishu_im_user_fetch_resource(message_id: String, file_key: String, `type`: Option<String>): String {
        PrintUtils.printTool("feishu_im_user_fetch_resource", shortMessage: "current")
        feishuMediaToolFetchResource(message_id, file_key, `type` ?? "file")
    }
}
