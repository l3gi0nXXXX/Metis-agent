package metis.core.media_tests

import metis.core.*

import std.collection.ArrayList
import stdx.encoding.json.{JsonObject, JsonString}

public func mediaDiagnosticsLooksRedacted(text: String): Bool {
    !(text.contains("Authorization") ||
        text.contains("Bearer ") ||
        text.contains("api_key=secret") ||
        text.contains("token=secret") ||
        text.contains("password"))
}

public class MediaDiagnosticTestSink <: GatewayMediaDiagnosticSink {
    public let events = ArrayList<JsonObject>()

    public func emit(level: String, event: String, message: String, meta: JsonObject): Unit {
        let row = JsonObject()
        row.put("level", JsonString(level))
        row.put("event", JsonString(event))
        row.put("message", JsonString(message))
        row.put("meta", meta)
        this.events.add(row)
    }

    public func countEvent(event: String): Int64 {
        var count: Int64 = 0
        for (row in this.events) {
            if (mediaDiagnosticsString(row, "event") == event) {
                count += 1
            }
        }
        count
    }

    public func firstMeta(event: String): JsonObject {
        for (row in this.events) {
            if (mediaDiagnosticsString(row, "event") == event) {
                return mediaDiagnosticsObject(row, "meta")
            }
        }
        JsonObject()
    }

    public func metaAt(event: String, index: Int64): JsonObject {
        var seen: Int64 = 0
        for (row in this.events) {
            if (mediaDiagnosticsString(row, "event") == event) {
                if (seen == index) {
                    return mediaDiagnosticsObject(row, "meta")
                }
                seen += 1
            }
        }
        JsonObject()
    }

    public func containsMeta(event: String, key: String, value: String): Bool {
        for (row in this.events) {
            if (mediaDiagnosticsString(row, "event") == event) {
                let meta = mediaDiagnosticsObject(row, "meta")
                if (mediaDiagnosticsString(meta, key) == value) {
                    return true
                }
            }
        }
        false
    }

    public func rawJson(): String {
        let rows = JsonObject()
        var index: Int64 = 0
        for (row in this.events) {
            rows.put(index.toString(), row)
            index += 1
        }
        rows.toJsonString()
    }
}

public func mediaDiagnosticsString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

public func mediaDiagnosticsInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { v.asInt().getValue() } catch (_: Exception) { 0 }
        case None => 0
    }
}

public func mediaDiagnosticsObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}
