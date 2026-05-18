package metis.core.media_tests

import metis.core.*

import metis.core.config.{CliConfig, GatewayUserSettings}
import magic.core.message.Message
import magic.core.model.{AsyncChatResponse, ChatModel, ChatRequest, ChatResponse}
import magic.model.ModelManager

import std.fs.{Directory, File, Path, remove}
import std.time.*
import std.unittest.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString}

private func mediaAsrTestTempRoot(label: String): Path {
    let root = Path("/tmp/metis-media-asr-config-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    Directory.create(root, recursive: true)
    root
}

private func mediaAsrTestRecord(path: String, channel!: String = "telegram"): JsonObject {
    let record = JsonObject()
    record.put("mediaKind", JsonString("voice"))
    record.put("mimeType", JsonString("audio/ogg"))
    record.put("localPath", JsonString(path))
    record.put("downloaded", JsonBool(true))
    record.put("channel", JsonString(channel))
    return record
}

private func mediaVideoTestRecord(path: String, channel!: String = "telegram"): JsonObject {
    let record = JsonObject()
    record.put("mediaKind", JsonString("video"))
    record.put("mimeType", JsonString("video/mp4"))
    record.put("localPath", JsonString(path))
    record.put("downloaded", JsonBool(true))
    record.put("channel", JsonString(channel))
    record
}

private func mediaImageTestRecord(path: String, channel!: String = "telegram", kind!: String = "photo"): JsonObject {
    let record = JsonObject()
    record.put("mediaKind", JsonString(kind))
    record.put("mimeType", JsonString("image/jpeg"))
    record.put("localPath", JsonString(path))
    record.put("downloaded", JsonBool(true))
    record.put("channel", JsonString(channel))
    record
}

private func mediaDocumentTestRecord(path: String, mime!: String = "application/pdf", fileName!: String = "report.pdf", channel!: String = "telegram"): JsonObject {
    let record = JsonObject()
    record.put("mediaKind", JsonString("document"))
    record.put("mimeType", JsonString(mime))
    record.put("fileName", JsonString(fileName))
    record.put("originalFileName", JsonString(fileName))
    record.put("localPath", JsonString(path))
    record.put("downloaded", JsonBool(true))
    record.put("channel", JsonString(channel))
    record
}

private class GatewayImageRuntimeFakeModel <: ChatModel {
    private var _maxTokens: Option<Int64> = None

    public prop provider: String {
        get() { "fake" }
    }

    public prop name: String {
        get() { "image-runtime" }
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
        ChatResponse(this.fullName, Message.assistant("${prefix}: configured runtime image"))
    }

    public func asyncCreate(request: ChatRequest): AsyncChatResponse {
        throw Exception("async not used in gateway image runtime tests")
    }
}

private class GatewayImageRuntimeProviderErrorFakeModel <: ChatModel {
    private var _maxTokens: Option<Int64> = None

    public prop provider: String {
        get() { "fake" }
    }

    public prop name: String {
        get() { "image-runtime-error" }
    }

    public prop contextLength: Int64 {
        get() { 8192 }
    }

    public mut prop maxTokens: Option<Int64> {
        get() { this._maxTokens }
        set(v) { this._maxTokens = v }
    }

    public func create(_request: ChatRequest): ChatResponse {
        throw Exception("Http status: 401 invalid_api_key Authorization: Bearer sk-live-secret https://provider.example/v1/chat?api_key=query-secret&token=query-token DASHSCOPE_API_KEY=dash-secret")
    }

    public func asyncCreate(_request: ChatRequest): AsyncChatResponse {
        throw Exception("async not used in gateway image runtime tests")
    }
}

private func mediaAsrTestProvider(text: String): JsonObject {
    let provider = JsonObject()
    provider.put("kind", JsonString("command"))
    provider.put("command", JsonArray([JsonString("sh"), JsonString("-c"), JsonString("printf '${text}'")]))
    return provider
}

private func mediaImageConfigForModel(modelRef: String): JsonObject {
    let entry = JsonObject()
    let parts = modelRef.split(":", 2)
    entry.put("provider", JsonString(parts[0]))
    entry.put("model", JsonString(parts[1]))
    entry.put("capabilities", JsonArray([JsonString("image")]))
    let models = JsonArray([])
    models.add(entry)
    let image = JsonObject()
    image.put("enabled", JsonBool(true))
    image.put("models", models)
    image
}

private func mediaImageConfigForModelWithoutCapabilities(modelRef: String): JsonObject {
    let entry = JsonObject()
    let parts = modelRef.split("/", 2)
    entry.put("provider", JsonString(parts[0]))
    entry.put("model", JsonString(parts[1]))
    let models = JsonArray([])
    models.add(entry)
    let image = JsonObject()
    image.put("enabled", JsonBool(true))
    image.put("models", models)
    image
}

private func mediaAsrTestConfig(providerId: String, provider: JsonObject): JsonObject {
    let providers = JsonObject()
    providers.put(providerId, provider)
    let config = JsonObject()
    config.put("enabled", JsonBool(true))
    config.put("provider", JsonString(providerId))
    config.put("providers", providers)
    return config
}

private func mediaAsrString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

@Test
public class GatewayMediaUnderstandingRuntimeTest {
    @TestCase
    public func recordTranscriptStaysAheadOfConfiguredAsrProvider(): Unit {
        let root = mediaAsrTestTempRoot("record")
        let audio = root.join("voice.ogg")
        File.writeTo(audio, "fake-audio".toArray())
        var user = GatewayUserSettings()
        user.speech.asr = mediaAsrTestConfig("shared", mediaAsrTestProvider("configured transcript"))
        let record = mediaAsrTestRecord(audio.toString())
        record.put("transcript", JsonString("record transcript"))

        let result = gatewayMediaUnderstandingForRecordWithSettings(record, user, capability: "audio")
        @Expect(mediaAsrString(result, "ASRStatus"), "transcribed")
        @Expect(mediaAsrString(result, "transcript"), "record transcript")
    }

    @TestCase
    public func testOverrideStaysAheadOfConfiguredAsrProvider(): Unit {
        let root = mediaAsrTestTempRoot("override")
        let audio = root.join("voice.ogg")
        File.writeTo(audio, "fake-audio".toArray())
        var user = GatewayUserSettings()
        user.speech.asr = mediaAsrTestConfig("shared", mediaAsrTestProvider("configured transcript"))
        setGatewayMediaAsrRunnerForTest(Some({ _path: String, _mime: String => "override transcript" }))
        try {
            let result = gatewayMediaUnderstandingForRecordWithSettings(mediaAsrTestRecord(audio.toString()), user, capability: "audio")
            @Expect(mediaAsrString(result, "ASRStatus"), "transcribed")
            @Expect(mediaAsrString(result, "transcript"), "override transcript")
        } finally {
            setGatewayMediaAsrRunnerForTest(None<(String, String) -> String>)
        }
    }

    @TestCase
    public func telegramChannelAsrProviderOverridesSharedProvider(): Unit {
        let root = mediaAsrTestTempRoot("channel")
        let audio = root.join("voice.ogg")
        File.writeTo(audio, "fake-audio".toArray())
        var user = GatewayUserSettings()
        user.speech.asr = mediaAsrTestConfig("shared", mediaAsrTestProvider("shared transcript"))
        user.telegram.speech.asr = mediaAsrTestConfig("telegram", mediaAsrTestProvider("telegram transcript"))

        let result = gatewayMediaUnderstandingForRecordWithSettings(mediaAsrTestRecord(audio.toString()), user, capability: "audio")
        @Expect(mediaAsrString(result, "ASRStatus"), "transcribed")
        @Expect(mediaAsrString(result, "transcript"), "telegram transcript")
    }

    @TestCase
    public func sharedAsrProviderIsUsedWhenChannelOverrideMissing(): Unit {
        let root = mediaAsrTestTempRoot("shared")
        let audio = root.join("voice.ogg")
        File.writeTo(audio, "fake-audio".toArray())
        var user = GatewayUserSettings()
        user.speech.asr = mediaAsrTestConfig("shared", mediaAsrTestProvider("shared transcript"))

        let result = gatewayMediaUnderstandingForRecordWithSettings(mediaAsrTestRecord(audio.toString()), user, capability: "audio")
        @Expect(mediaAsrString(result, "ASRStatus"), "transcribed")
        @Expect(mediaAsrString(result, "transcript"), "shared transcript")
    }

    @TestCase
    public func sharedAsrMaxBytesOverridesMediaDefaultLimit(): Unit {
        let root = mediaAsrTestTempRoot("maxbytes")
        let audio = root.join("voice.ogg")
        File.writeTo(audio, Array<Byte>(9000, repeat: 65))
        var user = GatewayUserSettings()
        let asr = mediaAsrTestConfig("shared", mediaAsrTestProvider("configured transcript"))
        asr.put("maxBytes", JsonString("26214400"))
        user.speech.asr = asr

        let result = gatewayMediaUnderstandingForRecordWithSettings(mediaAsrTestRecord(audio.toString()), user, capability: "audio")
        @Expect(mediaAsrString(result, "status"), "ok")
        @Expect(mediaAsrString(result, "ASRStatus"), "transcribed")
        @Expect(mediaAsrString(result, "transcript"), "configured transcript")
    }

    @TestCase
    public func configuredGeminiVideoProviderProducesVideoDescriptionOutput(): Unit {
        let root = mediaAsrTestTempRoot("video-gemini")
        let clip = root.join("clip.mp4")
        File.writeTo(clip, "fake-video".toArray())
        var user = GatewayUserSettings()
        let provider = JsonObject()
        provider.put("kind", JsonString("gemini-inline-video"))
        provider.put("apiKey", JsonString("test-video-key"))
        provider.put("baseUrl", JsonString("https://gemini.example/v1beta"))
        provider.put("model", JsonString("gemini-3-flash-preview"))
        let providers = JsonObject()
        providers.put("gemini", provider)
        user.media.video.put("enabled", JsonBool(true))
        user.media.video.put("provider", JsonString("gemini"))
        user.media.video.put("providers", providers)
        setGatewayMediaVideoHttpRunnerForTest(Some({ _request: JsonObject =>
            GatewayMediaVideoHttpResult(200, bodyBytes: "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"a short clip\"}]}}]}".toArray())
        }))
        try {
            let result = gatewayMediaUnderstandingForRecordWithSettings(mediaVideoTestRecord(clip.toString()), user, capability: "video")
            @Expect(mediaAsrString(result, "status"), "ok")
            @Expect(mediaAsrString(result, "videoDescription"), "a short clip")
            @Expect(mediaAsrString(result, "provider"), "gemini")
            let outputs = result.get("outputs").getOrThrow().asArray()
            @Expect(outputs[0].asObject().get("kind").getOrThrow().asString().getValue(), "video.description")
            @Expect(outputs[0].asObject().get("source").getOrThrow().asString().getValue(), "gateway_video_runtime")
        } finally {
            setGatewayMediaVideoHttpRunnerForTest(None<(JsonObject) -> GatewayMediaVideoHttpResult>)
        }
    }

    @TestCase
    public func configuredVideoProviderTooLargeStatusIsPropagated(): Unit {
        let root = mediaAsrTestTempRoot("video-large")
        let clip = root.join("clip.mp4")
        File.writeTo(clip, Array<Byte>(16, repeat: 65))
        var user = GatewayUserSettings()
        user.media.video.put("enabled", JsonBool(true))
        user.media.video.put("provider", JsonString("gemini"))
        let provider = JsonObject()
        provider.put("kind", JsonString("gemini-inline-video"))
        provider.put("apiKey", JsonString("test-video-key"))
        let providers = JsonObject()
        providers.put("gemini", provider)
        user.media.video.put("providers", providers)
        user.media.video.put("maxBytes", JsonString("4"))

        let result = gatewayMediaUnderstandingForRecordWithSettings(mediaVideoTestRecord(clip.toString()), user, capability: "video")
        @Expect(mediaAsrString(result, "status"), "too_large")
        @Expect(mediaAsrString(result, "videoUnderstandingStatus"), "too_large")
        @Expect(result.get("fileBytes").isSome(), true)
    }

    @TestCase
    public func pdfDocumentRecordUsesSharedPdfRuntimeHook(): Unit {
        let root = mediaAsrTestTempRoot("pdf-runtime-ok")
        let doc = root.join("report.pdf")
        File.writeTo(doc, "%PDF-1.7\nfake".toArray())
        setGatewayMediaPdfRuntimeForTest(Some({ path: String, mime: String, fileName: String, prompt: String, maxBytes: Int64 =>
            @Expect(path, doc.toString())
            @Expect(mime, "application/pdf")
            @Expect(fileName, "report.pdf")
            @Expect(prompt, "summarize")
            @Expect(maxBytes, 4096)
            let out = JsonObject()
            out.put("status", JsonString("ok"))
            out.put("text", JsonString("pdf summary"))
            out.put("provider", JsonString("fake"))
            out.put("model", JsonString("fake:pdf-runtime"))
            out
        }))
        try {
            let result = gatewayMediaUnderstandingForRecordWithSettings(
                mediaDocumentTestRecord(doc.toString()),
                GatewayUserSettings(),
                capability: "document",
                prompt: "summarize",
                maxBytes: 4096
            )
            @Expect(mediaAsrString(result, "status"), "ok")
            @Expect(mediaAsrString(result, "documentExtractStatus"), "ok")
            @Expect(mediaAsrString(result, "extractor"), "pdf_runtime")
            @Expect(mediaAsrString(result, "provider"), "fake")
            @Expect(gatewayMediaUnderstandingFirstText(result), "pdf summary")
            let outputs = result.get("outputs").getOrThrow().asArray()
            @Expect(outputs[0].asObject().get("source").getOrThrow().asString().getValue(), "gateway_pdf_runtime")
        } finally {
            setGatewayMediaPdfRuntimeForTest(None<(String, String, String, String, Int64) -> JsonObject>)
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func pdfProviderErrorIsPropagatedWithoutMetadataFallbackAndRedactsSecrets(): Unit {
        let root = mediaAsrTestTempRoot("pdf-provider-error")
        let doc = root.join("report.dat")
        File.writeTo(doc, "not-a-real-pdf".toArray())
        setGatewayMediaPdfRuntimeForTest(Some({ _path: String, _mime: String, _fileName: String, _prompt: String, _maxBytes: Int64 =>
            let out = JsonObject()
            out.put("status", JsonString("provider_error"))
            out.put("error", JsonString("Http status: 401 Authorization: Bearer sk-pdf-secret https://provider.example/pdf?api_key=query-secret&token=query-token"))
            out
        }))
        try {
            let result = gatewayMediaUnderstandingForRecordWithSettings(
                mediaDocumentTestRecord(doc.toString(), mime: "application/octet-stream", fileName: "report.pdf"),
                GatewayUserSettings(),
                capability: "document"
            )
            @Expect(mediaAsrString(result, "status"), "provider_error")
            @Expect(mediaAsrString(result, "documentExtractStatus"), "provider_error")
            @Expect(mediaAsrString(result, "extractor"), "pdf_runtime")
            @Expect(mediaAsrString(result, "error").contains("401"), true)
            @Expect(mediaAsrString(result, "status") == "metadata_only", false)
            @Expect(result.toJsonString().contains("sk-pdf-secret"), false)
            @Expect(result.toJsonString().contains("query-secret"), false)
            @Expect(result.toJsonString().contains("query-token"), false)
        } finally {
            setGatewayMediaPdfRuntimeForTest(None<(String, String, String, String, Int64) -> JsonObject>)
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func pdfMagicBytesWithoutConfiguredRuntimeReturnsNotConfigured(): Unit {
        let root = mediaAsrTestTempRoot("pdf-not-configured")
        let doc = root.join("report.bin")
        File.writeTo(doc, "%PDF-1.7\nfake".toArray())
        let oldModel = CliConfig.modelOrEmpty()
        let oldFallbacks = CliConfig.fallbackModels
        let oldImageModel = CliConfig.imageModelOrEmpty()
        let oldImageFallbacks = CliConfig.imageFallbackModels
        let oldPdfModel = CliConfig.pdfModelOrEmpty()
        let oldPdfFallbacks = CliConfig.pdfFallbackModels
        try {
            CliConfig.clearPrimaryModelForTest()
            CliConfig.fallbackModels = []
            CliConfig.clearImageModelForTest()
            CliConfig.imageFallbackModels = []
            CliConfig.clearPdfModelForTest()
            CliConfig.pdfFallbackModels = []

            let result = gatewayMediaUnderstandingForRecordWithSettings(
                mediaDocumentTestRecord(doc.toString(), mime: "application/octet-stream", fileName: "report.bin"),
                GatewayUserSettings(),
                capability: "document"
            )
            @Expect(mediaAsrString(result, "status"), "not_configured")
            @Expect(mediaAsrString(result, "documentExtractStatus"), "not_configured")
            @Expect(mediaAsrString(result, "extractor"), "pdf_runtime")
            @Expect(mediaAsrString(result, "error").contains("agents.defaults.pdfModel"), true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), false)
        } finally {
            if (oldModel.isEmpty()) {
                CliConfig.clearPrimaryModelForTest()
            } else {
                CliConfig.model = oldModel
            }
            CliConfig.fallbackModels = oldFallbacks
            if (oldImageModel.isEmpty()) {
                CliConfig.clearImageModelForTest()
            } else {
                CliConfig.imageModel = oldImageModel
            }
            CliConfig.imageFallbackModels = oldImageFallbacks
            if (oldPdfModel.isEmpty()) {
                CliConfig.clearPdfModelForTest()
            } else {
                CliConfig.pdfModel = oldPdfModel
            }
            CliConfig.pdfFallbackModels = oldPdfFallbacks
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func pdfDocumentRecordUsesConfiguredPdfRuntimeWithoutHook(): Unit {
        let root = mediaAsrTestTempRoot("pdf-configured-runtime")
        let doc = root.join("report.pdf")
        File.writeTo(doc, "%PDF-1.7\nfake".toArray())
        let modelRef = "fake:image-runtime"
        ModelManager.registerChatModel(modelRef, { => GatewayImageRuntimeFakeModel() })
        let oldModel = CliConfig.modelOrEmpty()
        let oldFallbacks = CliConfig.fallbackModels
        let oldImageModel = CliConfig.imageModelOrEmpty()
        let oldImageFallbacks = CliConfig.imageFallbackModels
        let oldPdfModel = CliConfig.pdfModelOrEmpty()
        let oldPdfFallbacks = CliConfig.pdfFallbackModels
        setPdfExtractorBridgeRunnerForTest(Some({ request: PdfExtractorBridgeRequest =>
            @Expect(request.inputPath, doc.toString())
            PdfExtractorProcessResult(
                0,
                stdout: "{\"ok\":true,\"status\":\"ok\",\"text\":\"extracted media pdf text\",\"pageCount\":1,\"selectedPages\":[1]}",
                stderr: ""
            )
        }))
        try {
            CliConfig.clearPrimaryModelForTest()
            CliConfig.fallbackModels = []
            CliConfig.clearImageModelForTest()
            CliConfig.imageFallbackModels = []
            CliConfig.pdfModel = modelRef
            CliConfig.pdfFallbackModels = []

            let result = gatewayMediaUnderstandingForRecordWithSettings(
                mediaDocumentTestRecord(doc.toString()),
                GatewayUserSettings(),
                capability: "document",
                prompt: "summarize"
            )

            @Expect(mediaAsrString(result, "status"), "ok")
            @Expect(mediaAsrString(result, "documentExtractStatus"), "ok")
            @Expect(mediaAsrString(result, "extractor"), "pdf_runtime")
            @Expect(mediaAsrString(result, "provider"), "fake")
            @Expect(mediaAsrString(result, "model"), "fake:image-runtime")
            @Expect(gatewayMediaUnderstandingFirstText(result).contains("configured runtime image"), true)
            let outputs = result.get("outputs").getOrThrow().asArray()
            @Expect(outputs[0].asObject().get("source").getOrThrow().asString().getValue(), "gateway_pdf_runtime")
        } finally {
            setPdfExtractorBridgeRunnerForTest(None<(PdfExtractorBridgeRequest) -> PdfExtractorProcessResult>)
            if (oldModel.isEmpty()) {
                CliConfig.clearPrimaryModelForTest()
            } else {
                CliConfig.model = oldModel
            }
            CliConfig.fallbackModels = oldFallbacks
            if (oldImageModel.isEmpty()) {
                CliConfig.clearImageModelForTest()
            } else {
                CliConfig.imageModel = oldImageModel
            }
            CliConfig.imageFallbackModels = oldImageFallbacks
            if (oldPdfModel.isEmpty()) {
                CliConfig.clearPdfModelForTest()
            } else {
                CliConfig.pdfModel = oldPdfModel
            }
            CliConfig.pdfFallbackModels = oldPdfFallbacks
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func configuredImageCandidateProducesImageDescriptionOutput(): Unit {
        let root = mediaAsrTestTempRoot("image-runtime")
        let image = root.join("image.jpg")
        File.writeTo(image, "fake-image".toArray())
        let modelRef = "fake:image-runtime"
        ModelManager.registerChatModel(modelRef, { => GatewayImageRuntimeFakeModel() })
        var user = GatewayUserSettings()
        let telegram = JsonObject()
        telegram.put("image", mediaImageConfigForModel(modelRef))
        let extra = JsonObject()
        extra.put("telegram", telegram)
        user.channelsExtra = Some(extra)

        let result = gatewayMediaUnderstandingForRecordWithSettings(mediaImageTestRecord(image.toString()), user, capability: "image")
        @Expect(mediaAsrString(result, "status"), "ok")
        @Expect(mediaAsrString(result, "imageDescription").contains("image-ok"), true)
        @Expect(mediaAsrString(result, "provider"), "fake")
        @Expect(mediaAsrString(result, "model"), "fake:image-runtime")
        let outputs = result.get("outputs").getOrThrow().asArray()
        @Expect(outputs[0].asObject().get("kind").getOrThrow().asString().getValue(), "image.description")
        @Expect(outputs[0].asObject().get("source").getOrThrow().asString().getValue(), "gateway_image_understanding_runtime")
    }

    @TestCase
    public func configuredImageProviderExceptionPropagatesProviderErrorAndRedactsSecrets(): Unit {
        let root = mediaAsrTestTempRoot("image-provider-error")
        let image = root.join("image.jpg")
        File.writeTo(image, "fake-image".toArray())
        let modelRef = "fake:image-runtime-error"
        ModelManager.registerChatModel(modelRef, { => GatewayImageRuntimeProviderErrorFakeModel() })
        var user = GatewayUserSettings()
        user.media.image = mediaImageConfigForModel(modelRef)

        let oldModel = CliConfig.modelOrEmpty()
        let oldFallbacks = CliConfig.fallbackModels
        let oldImageModel = CliConfig.imageModelOrEmpty()
        let oldImageFallbacks = CliConfig.imageFallbackModels
        try {
            CliConfig.clearPrimaryModelForTest()
            CliConfig.fallbackModels = []
            CliConfig.clearImageModelForTest()
            CliConfig.imageFallbackModels = []

            let result = gatewayMediaUnderstandingForRecordWithSettings(mediaImageTestRecord(image.toString()), user, capability: "image")

            @Expect(mediaAsrString(result, "status"), "provider_error")
            @Expect(mediaAsrString(result, "visionStatus"), "provider_error")
            @Expect(mediaAsrString(result, "error").contains("401"), true)
            @Expect(mediaAsrString(result, "error").contains("invalid_api_key"), true)
            @Expect(result.toJsonString().contains("sk-live-secret"), false)
            @Expect(result.toJsonString().contains("query-secret"), false)
            @Expect(result.toJsonString().contains("query-token"), false)
            @Expect(result.toJsonString().contains("dash-secret"), false)
            let attempts = result.get("attempts").getOrThrow().asArray()
            @Expect(attempts.size(), 1)
            @Expect(attempts[0].asObject().get("status").getOrThrow().asString().getValue(), "provider_error")
            @Expect(attempts[0].asObject().get("error").getOrThrow().asString().getValue().contains("401"), true)
        } finally {
            if (oldModel.isEmpty()) {
                CliConfig.clearPrimaryModelForTest()
            } else {
                CliConfig.model = oldModel
            }
            CliConfig.fallbackModels = oldFallbacks
            if (oldImageModel.isEmpty()) {
                CliConfig.clearImageModelForTest()
            } else {
                CliConfig.imageModel = oldImageModel
            }
            CliConfig.imageFallbackModels = oldImageFallbacks
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func configuredUnsupportedImageModelIsNotReportedAsNotConfigured(): Unit {
        let root = mediaAsrTestTempRoot("image-unsupported")
        let image = root.join("image.jpg")
        File.writeTo(image, "fake-image".toArray())
        var user = GatewayUserSettings()
        user.media.image = mediaImageConfigForModelWithoutCapabilities("deepseek/deepseek-v4-pro")

        let oldModel = CliConfig.modelOrEmpty()
        let oldFallbacks = CliConfig.fallbackModels
        let oldImageModel = CliConfig.imageModelOrEmpty()
        let oldImageFallbacks = CliConfig.imageFallbackModels
        try {
            CliConfig.clearPrimaryModelForTest()
            CliConfig.fallbackModels = []
            CliConfig.clearImageModelForTest()
            CliConfig.imageFallbackModels = []

            let result = gatewayMediaUnderstandingForRecordWithSettings(mediaImageTestRecord(image.toString()), user, capability: "image")

            @Expect(mediaAsrString(result, "status"), "unsupported")
            @Expect(mediaAsrString(result, "visionStatus"), "unsupported")
            @Expect(mediaAsrString(result, "error").contains("not configured"), false)
            let attempts = result.get("attempts").getOrThrow().asArray()
            @Expect(attempts.size(), 1)
            let capability = attempts[0].asObject().get("capability").getOrThrow().asObject()
            @Expect(capability.get("status").getOrThrow().asString().getValue(), "unsupported_model")
        } finally {
            if (oldModel.isEmpty()) {
                CliConfig.clearPrimaryModelForTest()
            } else {
                CliConfig.model = oldModel
            }
            CliConfig.fallbackModels = oldFallbacks
            if (oldImageModel.isEmpty()) {
                CliConfig.clearImageModelForTest()
            } else {
                CliConfig.imageModel = oldImageModel
            }
            CliConfig.imageFallbackModels = oldImageFallbacks
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func missingImageUnderstandingConfigReportsNotConfigured(): Unit {
        let root = mediaAsrTestTempRoot("image-not-configured")
        let image = root.join("image.jpg")
        File.writeTo(image, "fake-image".toArray())
        var user = GatewayUserSettings()

        let oldModel = CliConfig.modelOrEmpty()
        let oldFallbacks = CliConfig.fallbackModels
        let oldImageModel = CliConfig.imageModelOrEmpty()
        let oldImageFallbacks = CliConfig.imageFallbackModels
        try {
            CliConfig.clearPrimaryModelForTest()
            CliConfig.fallbackModels = []
            CliConfig.clearImageModelForTest()
            CliConfig.imageFallbackModels = []

            let result = gatewayMediaUnderstandingForRecordWithSettings(mediaImageTestRecord(image.toString()), user, capability: "image")

            @Expect(mediaAsrString(result, "status"), "not_configured")
            @Expect(mediaAsrString(result, "visionStatus"), "not_configured")
            @Expect(result.get("attempts").isNone(), true)
        } finally {
            if (oldModel.isEmpty()) {
                CliConfig.clearPrimaryModelForTest()
            } else {
                CliConfig.model = oldModel
            }
            CliConfig.fallbackModels = oldFallbacks
            if (oldImageModel.isEmpty()) {
                CliConfig.clearImageModelForTest()
            } else {
                CliConfig.imageModel = oldImageModel
            }
            CliConfig.imageFallbackModels = oldImageFallbacks
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }
    }
}
