package metis.core.media_tests

import metis.core.*

import std.collection.ArrayList
import std.convert.*
import std.unittest.*
import stdx.encoding.json.{JsonInt, JsonObject, JsonString}

private class MediaDiagnosticCaptureSink <: GatewayMediaDiagnosticSink {
    public let events = ArrayList<JsonObject>()

    public func emit(level: String, event: String, message: String, meta: JsonObject): Unit {
        let row = JsonObject()
        row.put("level", JsonString(level))
        row.put("event", JsonString(event))
        row.put("message", JsonString(message))
        row.put("meta", meta)
        this.events.add(row)
    }
}

private func mediaDiagTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func mediaDiagTestInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { Int64.parse(v.toJsonString()) } catch (_: Exception) { 0 }
        case None => 0
    }
}

@Test
public class MediaDiagnosticsTest {
    @TestCase
    public func defaultSinkIsNoopAndRegisteredSinkCapturesEvents(): Unit {
        resetGatewayMediaDiagnosticSinkForTest()
        emitGatewayMediaDiagnostic(
            "info",
            MediaDiagnosticEvent.mediaUnderstandingStarted,
            "video understanding started",
            meta: mediaDiagnosticProviderMeta("qwen-video-understanding", providerKind: "qwen-vl-video", model: "qwen3-vl-plus", capability: "video")
        )

        let sink = MediaDiagnosticCaptureSink()
        setGatewayMediaDiagnosticSinkForRuntime(Some(sink))
        emitGatewayMediaDiagnostic(
            "debug",
            MediaDiagnosticEvent.mediaUnderstandingAttempt,
            "video provider attempt",
            meta: mediaDiagnosticProviderMeta("qwen-video-understanding", providerKind: "qwen-vl-video", model: "qwen3-vl-plus", capability: "video")
        )
        @Expect(sink.events.size, 1)
        let row = sink.events[0]
        @Expect(mediaDiagTestString(row, "event"), "media.understanding.attempt")
        let meta = row.get("meta").getOrThrow().asObject()
        @Expect(mediaDiagTestString(meta, "provider"), "qwen-video-understanding")
        @Expect(mediaDiagTestString(meta, "providerKind"), "qwen-vl-video")
        @Expect(mediaDiagTestString(meta, "model"), "qwen3-vl-plus")
        @Expect(mediaDiagTestString(meta, "capability"), "video")

        resetGatewayMediaDiagnosticSinkForTest()
        emitGatewayMediaDiagnostic("info", MediaDiagnosticEvent.mediaUnderstandingFinished, "ignored after reset")
        @Expect(sink.events.size, 1)
    }

    @TestCase
    public func diagnosticMetaHelpersRedactSecretsPathsAndLargePayloads(): Unit {
        let pathMeta = mediaDiagnosticPathMeta("/Users/l3gi0n/private/demo image.png", managedRoot: "/tmp/metis-managed")
        @Expect(mediaDiagTestString(pathMeta, "pathKind"), "external")
        @Expect(mediaDiagTestString(pathMeta, "pathBasename"), "demo image.png")
        @Expect(mediaDiagTestString(pathMeta, "pathHash").isEmpty(), false)
        @Expect(pathMeta.toJsonString().contains("/Users/l3gi0n/private"), false)

        let route = JsonObject()
        route.put("mode", JsonString("httpConnectTunnel"))
        route.put("proxySource", JsonString("explicit"))
        route.put("redactedProxy", JsonString("http://user:secret@127.0.0.1:7897"))
        route.put("targetHost", JsonString("dashscope.aliyuncs.com"))
        let request = JsonObject()
        request.put("url", JsonString("https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions?apiKey=secret"))
        request.put("authorization", JsonString("Bearer secret-token"))
        request.put("body", JsonString("data:video/mp4;base64,AAAA"))
        request.put("timeoutMs", JsonInt(120000))
        request.put("transportRoute", route)
        let httpMeta = mediaDiagnosticHttpMetaFromRequest(
            request,
            method: "POST",
            statusCode: 400,
            contentType: "application/json",
            responseBytes: 42,
            elapsedMs: 77
        )
        let raw = httpMeta.toJsonString()
        @Expect(mediaDiagTestString(httpMeta, "urlPath"), "/compatible-mode/v1/chat/completions")
        @Expect(mediaDiagTestString(httpMeta, "targetHost"), "dashscope.aliyuncs.com")
        @Expect(mediaDiagTestInt(httpMeta, "statusCode"), 400)
        @Expect(mediaDiagTestInt(httpMeta, "timeoutMs"), 120000)
        @Expect(raw.contains("secret-token"), false)
        @Expect(raw.contains("apiKey=secret"), false)
        @Expect(raw.contains("data:video"), false)
        @Expect(raw.contains("user:secret"), false)
        @Expect(raw.contains("http://[redacted]@127.0.0.1:7897"), true)
    }
}
