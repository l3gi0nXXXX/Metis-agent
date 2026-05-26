package metis.core.media_tests

import metis.core.*
import metis.core.config.GatewayUserSettings

import std.fs.{Directory, File, Path, remove}
import std.time.*
import std.unittest.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString}

private func mediaDiagTempRoot(label: String): Path {
    let root = Path("/tmp/metis-media-diag-runtime-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    Directory.create(root, recursive: true)
    root
}

private func mediaDiagImageRecord(path: String): JsonObject {
    let record = JsonObject()
    record.put("mediaKind", JsonString("photo"))
    record.put("mimeType", JsonString("image/png"))
    record.put("fileName", JsonString("sample.png"))
    record.put("localPath", JsonString(path))
    record.put("downloaded", JsonBool(true))
    record.put("channel", JsonString("telegram"))
    record.put("mediaId", JsonString("media-1"))
    record
}

private func mediaDiagQwenVideoConfig(providerId: String): JsonObject {
    let provider = JsonObject()
    provider.put("kind", JsonString("qwen-vl-video"))
    provider.put("apiKey", JsonString("test-video-key"))
    provider.put("baseUrl", JsonString("https://dashscope.aliyuncs.com/compatible-mode/v1"))
    provider.put("model", JsonString("qwen3-vl-plus"))
    provider.put("timeoutMs", JsonInt(25))
    let providers = JsonObject()
    providers.put(providerId, provider)
    let config = JsonObject()
    config.put("enabled", JsonBool(true))
    config.put("provider", JsonString(providerId))
    config.put("providers", providers)
    config
}

private func mediaDiagGenerationConfig(providerId: String, outputRoot: Path): JsonObject {
    let provider = JsonObject()
    provider.put("kind", JsonString("openai"))
    provider.put("model", JsonString("image-model"))
    let providers = JsonObject()
    providers.put(providerId, provider)
    let config = JsonObject()
    config.put("enabled", JsonBool(true))
    config.put("provider", JsonString(providerId))
    config.put("providers", providers)
    config.put("outputRoot", JsonString(outputRoot.toString()))
    config.put("allowedOutputRoots", JsonArray([JsonString(outputRoot.toString())]))
    config
}

private func mediaDiagVideoGenerationConfig(providerId: String, outputRoot: Path): JsonObject {
    let provider = JsonObject()
    provider.put("kind", JsonString("dashscope-qwen-video-generation"))
    provider.put("model", JsonString("wan2.1"))
    let providers = JsonObject()
    providers.put(providerId, provider)
    let config = JsonObject()
    config.put("enabled", JsonBool(true))
    config.put("provider", JsonString(providerId))
    config.put("providers", providers)
    config.put("outputRoot", JsonString(outputRoot.toString()))
    config.put("allowedOutputRoots", JsonArray([JsonString(outputRoot.toString())]))
    config
}

private func mediaDiagTtsConfig(providerId: String): JsonObject {
    let provider = JsonObject()
    provider.put("kind", JsonString("fake"))
    let providers = JsonObject()
    providers.put(providerId, provider)
    let config = JsonObject()
    config.put("enabled", JsonBool(true))
    config.put("provider", JsonString(providerId))
    config.put("providers", providers)
    config
}

private func mediaDiagRequest(prompt: String): JsonObject {
    let request = JsonObject()
    request.put("prompt", JsonString(prompt))
    request
}

@Test
public class MediaStructuredDiagnosticsRuntimeTest {
    @TestCase
    public func mediaUnderstandingEmitsStartedAttemptAndFinished(): Unit {
        let root = mediaDiagTempRoot("understanding")
        let image = root.join("sample.png")
        File.writeTo(image, "fake-image".toArray())
        let sink = MediaDiagnosticTestSink()
        setGatewayMediaDiagnosticSinkForRuntime(Some(sink))
        try {
            let record = mediaDiagImageRecord(image.toString())
            record.put("analysis", JsonString("cached image description"))

            let result = gatewayMediaUnderstandingForRecordWithSettings(record, GatewayUserSettings(), capability: "image")

            @Expect(mediaDiagnosticsString(result, "status"), "ok")
            @Expect(sink.countEvent(MediaDiagnosticEvent.mediaUnderstandingStarted), 1)
            @Expect(sink.countEvent(MediaDiagnosticEvent.mediaUnderstandingAttempt), 1)
            @Expect(sink.countEvent(MediaDiagnosticEvent.mediaUnderstandingFinished), 1)
            @Expect(sink.containsMeta(MediaDiagnosticEvent.mediaUnderstandingAttempt, "source", "media_record_cache"), true)
            @Expect(sink.containsMeta(MediaDiagnosticEvent.mediaUnderstandingFinished, "outputKind", "image.description"), true)
        } finally {
            resetGatewayMediaDiagnosticSinkForTest()
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func videoProviderHttpDiagnosticsIncludeRequestResponseAndRedaction(): Unit {
        let root = mediaDiagTempRoot("video-understanding")
        let clip = root.join("clip.mp4")
        File.writeTo(clip, "video-bytes".toArray())
        let sink = MediaDiagnosticTestSink()
        setGatewayMediaDiagnosticSinkForRuntime(Some(sink))
        setGatewayMediaVideoHttpRunnerForTest(Some({ _request: JsonObject =>
            GatewayMediaVideoHttpResult(
                200,
                bodyBytes: "{\"choices\":[{\"message\":{\"content\":\"clip summary\"}}]}".toArray(),
                contentType: "application/json"
            )
        }))
        try {
            let result = gatewayMediaVideoDescribePath(mediaDiagQwenVideoConfig("qwen"), clip.toString(), "video/mp4", "", outputRoot: root)

            @Expect(mediaDiagnosticsString(result, "status"), "ok")
            @Expect(sink.containsMeta(MediaDiagnosticEvent.mediaUnderstandingAttempt, "stage", "provider.request"), true)
            @Expect(sink.containsMeta(MediaDiagnosticEvent.mediaUnderstandingAttempt, "stage", "provider.response"), true)
            @Expect(sink.containsMeta(MediaDiagnosticEvent.mediaUnderstandingFinished, "status", "ok"), true)
            let requestMeta = sink.firstMeta(MediaDiagnosticEvent.mediaUnderstandingAttempt)
            @Expect(mediaDiagnosticsString(requestMeta, "urlPath"), "/compatible-mode/v1/chat/completions")
            @Expect(mediaDiagnosticsString(requestMeta, "targetHost"), "dashscope.aliyuncs.com")
            @Expect(mediaDiagnosticsInt(requestMeta, "fileBytes"), 11)
            @Expect(sink.rawJson().contains("test-video-key"), false)
            @Expect(sink.rawJson().contains("data:video"), false)
        } finally {
            setGatewayMediaVideoHttpRunnerForTest(None<(JsonObject) -> GatewayMediaVideoHttpResult>)
            resetGatewayMediaDiagnosticSinkForTest()
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func imageAndVideoGenerationRuntimesEmitLifecycleDiagnostics(): Unit {
        let root = mediaDiagTempRoot("generation")
        let sink = MediaDiagnosticTestSink()
        setGatewayMediaDiagnosticSinkForRuntime(Some(sink))
        setGatewayImageGenerationRunnerForTest(Some({ _config: JsonObject, _request: JsonObject =>
            let image = JsonObject()
            image.put("path", JsonString(root.join("generated.png").toString()))
            image.put("fileName", JsonString("generated.png"))
            image.put("mimeType", JsonString("image/png"))
            let result = JsonObject()
            result.put("ok", JsonBool(true))
            result.put("status", JsonString("ok"))
            result.put("images", JsonArray([image]))
            result
        }))
        setGatewayVideoGenerationRunnerForTest(Some({ _config: JsonObject, _request: JsonObject =>
            let video = JsonObject()
            video.put("path", JsonString(root.join("generated.mp4").toString()))
            video.put("fileName", JsonString("generated.mp4"))
            video.put("mimeType", JsonString("video/mp4"))
            let result = JsonObject()
            result.put("ok", JsonBool(true))
            result.put("status", JsonString("ok"))
            result.put("videos", JsonArray([video]))
            result
        }))
        try {
            let imageResult = gatewayImageGenerationGenerate(mediaDiagGenerationConfig("img", root), mediaDiagRequest("draw an orca"))
            let videoResult = gatewayVideoGenerationGenerate(mediaDiagVideoGenerationConfig("vid", root), mediaDiagRequest("make an orca clip"))

            @Expect(mediaDiagnosticsString(imageResult, "status"), "ok")
            @Expect(mediaDiagnosticsString(videoResult, "status"), "ok")
            @Expect(sink.containsMeta(MediaDiagnosticEvent.mediaGenerationStarted, "generationKind", "image"), true)
            @Expect(sink.containsMeta(MediaDiagnosticEvent.mediaGenerationFinished, "generationKind", "image"), true)
            @Expect(sink.containsMeta(MediaDiagnosticEvent.mediaGenerationStarted, "generationKind", "video"), true)
            @Expect(sink.containsMeta(MediaDiagnosticEvent.mediaGenerationFinished, "generationKind", "video"), true)
        } finally {
            setGatewayImageGenerationRunnerForTest(None<(JsonObject, JsonObject) -> JsonObject>)
            setGatewayVideoGenerationRunnerForTest(None<(JsonObject, JsonObject) -> JsonObject>)
            resetGatewayMediaDiagnosticSinkForTest()
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func speechTtsRuntimeEmitsAudioGenerationDiagnostics(): Unit {
        let root = mediaDiagTempRoot("tts")
        let sink = MediaDiagnosticTestSink()
        setGatewayMediaDiagnosticSinkForRuntime(Some(sink))
        try {
            let result = gatewaySpeechTtsSynthesize(mediaDiagTtsConfig("fake"), JsonObject(), JsonObject(), "hello", outputRoot: root)

            @Expect(mediaDiagnosticsString(result, "status"), "ok")
            @Expect(sink.containsMeta(MediaDiagnosticEvent.mediaGenerationStarted, "generationKind", "audio"), true)
            @Expect(sink.containsMeta(MediaDiagnosticEvent.mediaGenerationAttempt, "generationKind", "audio"), true)
            @Expect(sink.containsMeta(MediaDiagnosticEvent.mediaGenerationFinished, "generationKind", "audio"), true)
        } finally {
            resetGatewayMediaDiagnosticSinkForTest()
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }
    }
}
