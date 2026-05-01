package metis.gateway.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*

import metis.core.gatewayCurrentToolRuntimeContext
import metis.io.PrintUtils

import std.fs.{Directory, File, Path, copy, exists}
import std.time.DateTime
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString}

private func telegramMediaToolString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_e: Exception) { "" }
        case None => ""
    }
}

private func telegramMediaToolBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_e: Exception) { false }
        case None => false
    }
}

private func telegramMediaToolRecords(): JsonArray {
    match (gatewayCurrentToolRuntimeContext()) {
        case Some(ctx) =>
            match (ctx.mediaContext.get("records")) {
                case Some(v) => try { v.asArray() } catch (_e: Exception) { JsonArray([]) }
                case None => JsonArray([])
            }
        case None => JsonArray([])
    }
}

private func telegramMediaToolRecordByTarget(mediaId: String, index: Int64): Option<JsonObject> {
    let records = telegramMediaToolRecords()
    var i: Int64 = 0
    for (item in records.getItems()) {
        let obj = try { item.asObject() } catch (_e: Exception) { JsonObject() }
        if (!mediaId.isEmpty() && telegramMediaToolString(obj, "mediaId") == mediaId) {
            return Some(obj)
        }
        if (mediaId.isEmpty() && i == index) {
            return Some(obj)
        }
        i += 1
    }
    None<JsonObject>
}

@toolset
public class GatewayTelegramMediaToolset {
    public func debugTelegramMediaListForTest(): String {
        this.renderTelegramMediaList()
    }

    public func debugTelegramMediaSaveForTest(destination: String, mediaId: Option<String>, index: Option<Int64>): String {
        this.saveTelegramMedia(destination, mediaId, index)
    }

    private func renderTelegramMediaList(): String {
        let records = telegramMediaToolRecords()
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("status", JsonString("ok"))
        out.put("count", records.size().toJsonValue())
        out.put("records", records)
        out.toJsonString()
    }

    private func saveTelegramMedia(destination: String, mediaId: Option<String>, index: Option<Int64>): String {
        let targetPathText = destination.trimAscii()
        let targetMediaId = match (mediaId) {
            case Some(v) => v.trimAscii()
            case None => ""
        }
        let targetIndex = match (index) {
            case Some(v) => v
            case None => 0
        }
        let out = JsonObject()
        if (targetPathText.isEmpty()) {
            out.put("ok", JsonBool(false))
            out.put("status", JsonString("error"))
            out.put("error", JsonString("destination is required"))
            return out.toJsonString()
        }
        let record = match (telegramMediaToolRecordByTarget(targetMediaId, targetIndex)) {
            case Some(v) => v
            case None =>
                out.put("ok", JsonBool(false))
                out.put("status", JsonString("error"))
                out.put("error", JsonString("media resource not found in current session turn"))
                return out.toJsonString()
        }
        let sourcePath = telegramMediaToolString(record, "localPath")
        if (sourcePath.isEmpty() || !telegramMediaToolBool(record, "downloaded") || !exists(Path(sourcePath))) {
            out.put("ok", JsonBool(false))
            out.put("status", JsonString("error"))
            out.put("error", JsonString("media resource has no downloaded localPath"))
            out.put("mediaId", JsonString(telegramMediaToolString(record, "mediaId")))
            return out.toJsonString()
        }
        let dest = Path(targetPathText)
        let parent = dest.parent
        if (!exists(parent)) {
            Directory.create(parent, recursive: true)
        }
        copy(Path(sourcePath), to: dest, overwrite: true)
        out.put("ok", JsonBool(true))
        out.put("status", JsonString("saved"))
        out.put("mediaId", JsonString(telegramMediaToolString(record, "mediaId")))
        out.put("mediaKind", JsonString(telegramMediaToolString(record, "mediaKind")))
        out.put("sourcePath", JsonString(sourcePath))
        out.put("destination", JsonString(dest.toString()))
        out.put("savedAtMs", DateTime.now().toUnixTimeStamp().toMilliseconds().toJsonValue())
        out.toJsonString()
    }

    @tool[
        description: "List structured Telegram media resources attached to the current Gateway session turn. Use this before saving or inspecting an image, file, voice, audio, or reply target media sent by the user.",
        parameters: {}
    ]
    public func telegram_media_list(): String {
        PrintUtils.printTool("telegram_media_list", shortMessage: "current")
        let text = this.renderTelegramMediaList()
        PrintUtils.printToolResult(text)
        return text
    }

    @tool[
        description: "Save one Telegram media resource from the current Gateway session turn to a destination path. Select by mediaId or zero-based index; defaults to index 0.",
        parameters: {
            destination: "Absolute or relative destination file path to write.",
            mediaId: "Optional mediaId returned by telegram_media_list.",
            index: "Optional zero-based media index. Defaults to 0 when mediaId is omitted."
        }
    ]
    public func telegram_media_save(destination: String, mediaId: Option<String>, index: Option<Int64>): String {
        PrintUtils.printTool("telegram_media_save", shortMessage: "current")
        let text = this.saveTelegramMedia(destination, mediaId, index)
        PrintUtils.printToolResult(text)
        return text
    }
}
