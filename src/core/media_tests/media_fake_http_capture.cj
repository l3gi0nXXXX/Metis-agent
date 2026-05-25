package metis.core.media_tests

import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonInt, JsonObject, JsonString}

public class MediaFakeHttpRequest {
    public let method: String
    public let url: String
    public let body: String
    public let timeoutMs: Int64
    public let attemptIndex: Int64

    public init(method: String, url: String, body!: String = "", timeoutMs!: Int64 = 0, attemptIndex!: Int64 = 0) {
        this.method = method
        this.url = url
        this.body = body
        this.timeoutMs = timeoutMs
        this.attemptIndex = attemptIndex
    }
}

public class MediaFakeHttpCapture {
    private let requests: ArrayList<MediaFakeHttpRequest> = ArrayList<MediaFakeHttpRequest>()

    public func record(method: String, url: String, body!: String = "", timeoutMs!: Int64 = 0, attemptIndex!: Int64 = 0): Unit {
        this.requests.add(MediaFakeHttpRequest(method, url, body: body, timeoutMs: timeoutMs, attemptIndex: attemptIndex))
    }

    public func size(): Int64 {
        Int64(this.requests.size)
    }

    public func lastUrl(): String {
        if (this.requests.size == 0) {
            return ""
        }
        this.requests[this.requests.size - 1].url
    }

    public func toJson(): JsonArray {
        let out = JsonArray([])
        for (request in this.requests) {
            let obj = JsonObject()
            obj.put("method", JsonString(request.method))
            obj.put("url", JsonString(request.url))
            obj.put("body", JsonString(request.body))
            obj.put("timeoutMs", JsonInt(request.timeoutMs))
            obj.put("attemptIndex", JsonInt(request.attemptIndex))
            out.add(obj)
        }
        out
    }
}
