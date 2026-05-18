package metis.core.media_tests

import metis.core.*
import metis.core.config.CliConfig

import magic.core.message.Message
import magic.core.model.{AsyncChatResponse, ChatModel, ChatRequest, ChatResponse}
import magic.model.ModelManager

import std.fs.{Directory, File, Path, remove}
import std.time.*
import std.unittest.*
import stdx.encoding.json.{JsonBool, JsonObject, JsonString}

private class GatewayPdfRuntimeFakeModel <: ChatModel {
    private var _maxTokens: Option<Int64> = None

    public prop provider: String {
        get() { "fake" }
    }

    public prop name: String {
        get() { "pdf-runtime" }
    }

    public prop contextLength: Int64 {
        get() { 8192 }
    }

    public mut prop maxTokens: Option<Int64> {
        get() { this._maxTokens }
        set(v) { this._maxTokens = v }
    }

    public func create(_request: ChatRequest): ChatResponse {
        ChatResponse(this.fullName, Message.assistant("pdf runtime model summary"))
    }

    public func asyncCreate(_request: ChatRequest): AsyncChatResponse {
        throw Exception("async not used in PDF runtime tests")
    }
}

private func pdfRuntimeTestTempRoot(label: String): Path {
    let root = Path("/tmp/metis-pdf-runtime-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    Directory.create(root, recursive: true)
    root
}

private func pdfRuntimeTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func restorePdfRuntimeTestConfig(
    oldModel: String,
    oldFallbacks: Array<String>,
    oldImageModel: String,
    oldImageFallbacks: Array<String>,
    oldPdfModel: String,
    oldPdfFallbacks: Array<String>
): Unit {
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
}

@Test
public class GatewayPdfRuntimeTest {
    @TestCase
    public func gatewayPdfAnalyzeLoadsLocalPdfExtractsTextAndRunsConfiguredModel(): Unit {
        let root = pdfRuntimeTestTempRoot("ok")
        let pdf = root.join("report.pdf")
        File.writeTo(pdf, "%PDF-1.7\nfake".toArray())

        let oldModel = CliConfig.modelOrEmpty()
        let oldFallbacks = CliConfig.fallbackModels
        let oldImageModel = CliConfig.imageModelOrEmpty()
        let oldImageFallbacks = CliConfig.imageFallbackModels
        let oldPdfModel = CliConfig.pdfModelOrEmpty()
        let oldPdfFallbacks = CliConfig.pdfFallbackModels
        ModelManager.registerChatModel("fake:pdf-runtime", { => GatewayPdfRuntimeFakeModel() })
        setPdfExtractorBridgeRunnerForTest(Some({ request: PdfExtractorBridgeRequest =>
            @Expect(request.inputPath, pdf.toString())
            @Expect(request.maxPages, 20)
            PdfExtractorProcessResult(
                0,
                stdout: "{\"ok\":true,\"status\":\"ok\",\"text\":\"extracted pdf text\",\"pageCount\":1,\"selectedPages\":[1]}",
                stderr: ""
            )
        }))
        try {
            CliConfig.clearPrimaryModelForTest()
            CliConfig.fallbackModels = []
            CliConfig.clearImageModelForTest()
            CliConfig.imageFallbackModels = []
            CliConfig.pdfModel = "fake:pdf-runtime"
            CliConfig.pdfFallbackModels = []

            let request = JsonObject()
            request.put("pdf", JsonString(pdf.toString()))
            request.put("prompt", JsonString("summarize"))

            let result = gatewayPdfAnalyze(request)

            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(pdfRuntimeTestString(result, "status"), "ok")
            @Expect(pdfRuntimeTestString(result, "text"), "pdf runtime model summary")
            @Expect(pdfRuntimeTestString(result, "provider"), "fake")
            @Expect(pdfRuntimeTestString(result, "model"), "fake:pdf-runtime")
            @Expect(result.toJsonString().contains("\"details\""), true)
            @Expect(result.toJsonString().contains("\"ok\""), true)
        } finally {
            setPdfExtractorBridgeRunnerForTest(None<(PdfExtractorBridgeRequest) -> PdfExtractorProcessResult>)
            restorePdfRuntimeTestConfig(oldModel, oldFallbacks, oldImageModel, oldImageFallbacks, oldPdfModel, oldPdfFallbacks)
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func gatewayPdfAnalyzeReturnsReadableNotConfiguredWhenNoCandidatesExist(): Unit {
        let root = pdfRuntimeTestTempRoot("not-configured")
        let pdf = root.join("report.pdf")
        File.writeTo(pdf, "%PDF-1.7\nfake".toArray())

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

            let request = JsonObject()
            request.put("pdf", JsonString(pdf.toString()))

            let result = gatewayPdfAnalyze(request)

            @Expect(result.get("ok").getOrThrow().asBool().getValue(), false)
            @Expect(pdfRuntimeTestString(result, "status"), "not_configured")
            @Expect(pdfRuntimeTestString(result, "error").contains("agents.defaults.pdfModel"), true)
            @Expect(result.toJsonString().contains("runtime_unavailable"), false)
        } finally {
            restorePdfRuntimeTestConfig(oldModel, oldFallbacks, oldImageModel, oldImageFallbacks, oldPdfModel, oldPdfFallbacks)
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }
    }
}
