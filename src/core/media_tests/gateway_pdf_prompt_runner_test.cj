package metis.core.media_tests

import metis.core.*

import magic.core.message.Message
import magic.core.model.{AsyncChatResponse, ChatModel, ChatRequest, ChatResponse}
import magic.model.ModelManager

import std.unittest.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

private var pdfRunnerCapturedHttpRequest: JsonObject = JsonObject()
private var pdfRunnerHttpCalls: Int64 = 0
private var pdfRunnerCapturedModelRequest: JsonObject = JsonObject()
private var pdfRunnerModelCalls: Int64 = 0
private var pdfRunnerExtractorCalls: Int64 = 0
private var pdfRunnerFakeResponseText: String = "pdf model summary"
private var pdfRunnerFakeModelName: String = "pdf-runner"

private class PdfRunnerFakeModel <: ChatModel {
    private var _maxTokens: Option<Int64> = None

    public prop provider: String {
        get() { "fake" }
    }

    public prop name: String {
        get() { pdfRunnerFakeModelName }
    }

    public prop contextLength: Int64 {
        get() { 8192 }
    }

    public mut prop maxTokens: Option<Int64> {
        get() { this._maxTokens }
        set(v) { this._maxTokens = v }
    }

    public func create(request: ChatRequest): ChatResponse {
        pdfRunnerModelCalls += 1
        pdfRunnerCapturedModelRequest = request.toJsonValue().asObject()
        ChatResponse(this.fullName, Message.assistant(pdfRunnerFakeResponseText))
    }

    public func asyncCreate(_request: ChatRequest): AsyncChatResponse {
        throw Exception("async not used in PDF prompt runner tests")
    }
}

private func pdfRunnerReset(): Unit {
    pdfRunnerCapturedHttpRequest = JsonObject()
    pdfRunnerHttpCalls = 0
    pdfRunnerCapturedModelRequest = JsonObject()
    pdfRunnerModelCalls = 0
    pdfRunnerExtractorCalls = 0
    pdfRunnerFakeResponseText = "pdf model summary"
    pdfRunnerFakeModelName = "pdf-runner"
}

private func pdfRunnerString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func pdfRunnerObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func pdfRunnerArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func pdfRunnerPdf(): Array<GatewayPdfInput> {
    [GatewayPdfInput("JVBERi0xLjQ=", filename: "report.pdf")]
}

private func pdfRunnerCandidate(
    modelRef: String,
    native!: Bool = false,
    image!: Bool = false,
    apiKey!: String = "",
    baseUrl!: String = "https://provider.example"
): GatewayPdfPromptCandidate {
    GatewayPdfPromptCandidate(
        modelRef,
        source: "test",
        nativePdfSupported: native,
        imageSupported: image,
        apiKey: apiKey,
        baseUrl: baseUrl,
        maxTokens: 1024,
        timeoutMs: 1000
    )
}

private func pdfRunnerTextExtraction(): Array<GatewayPdfExtraction> {
    [GatewayPdfExtraction("This is extracted PDF text. This is extracted PDF text. This is extracted PDF text. This is extracted PDF text. This is extracted PDF text. This is extracted PDF text. This is extracted PDF text. This is extracted PDF text. This is extracted PDF text. This is extracted PDF text. This is extracted PDF text. This is extracted PDF text.")]
}

@Test
public class GatewayPdfPromptRunnerTest {
    @TestCase
    public func nativeAnthropicBuildsDocumentBlocksAndBetaHeader(): Unit {
        pdfRunnerReset()
        setGatewayPdfNativeHttpRunnerForTest(Some({ request: JsonObject =>
            pdfRunnerHttpCalls += 1
            pdfRunnerCapturedHttpRequest = request
            GatewayPdfNativeHttpResult(200, bodyBytes: "{\"content\":[{\"type\":\"text\",\"text\":\"anthropic summary\"}]}".toArray())
        }))
        try {
            let result = gatewayPdfRunPrompt(
                pdfRunnerPdf(),
                "Summarize",
                [pdfRunnerCandidate("anthropic:claude-sonnet", native: true, apiKey: "anthropic-test-key")],
                { =>
                    pdfRunnerExtractorCalls += 1
                    pdfRunnerTextExtraction()
                }
            )

            @Expect(result.ok, true)
            @Expect(result.text, "anthropic summary")
            @Expect(pdfRunnerHttpCalls, 1)
            @Expect(pdfRunnerExtractorCalls, 0)
            let headers = pdfRunnerObject(pdfRunnerCapturedHttpRequest, "headers")
            @Expect(pdfRunnerString(headers, "anthropic-beta"), "pdfs-2024-09-25")
            @Expect(pdfRunnerString(headers, "anthropic-version"), "2023-06-01")
            let body = pdfRunnerObject(pdfRunnerCapturedHttpRequest, "body")
            let messages = pdfRunnerArray(body, "messages")
            let content = messages[0].asObject().get("content").getOrThrow().asArray()
            let doc = content[0].asObject()
            @Expect(pdfRunnerString(doc, "type"), "document")
            let source = pdfRunnerObject(doc, "source")
            @Expect(pdfRunnerString(source, "media_type"), "application/pdf")
            @Expect(pdfRunnerString(source, "data"), "JVBERi0xLjQ=")
        } finally {
            setGatewayPdfNativeHttpRunnerForTest(None<(JsonObject) -> GatewayPdfNativeHttpResult>)
        }
    }

    @TestCase
    public func nativeGeminiBuildsInlineDataPdfParts(): Unit {
        pdfRunnerReset()
        setGatewayPdfNativeHttpRunnerForTest(Some({ request: JsonObject =>
            pdfRunnerHttpCalls += 1
            pdfRunnerCapturedHttpRequest = request
            GatewayPdfNativeHttpResult(200, bodyBytes: "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"gemini summary\"}]}}]}".toArray())
        }))
        try {
            let result = gatewayPdfRunPrompt(
                pdfRunnerPdf(),
                "Summarize",
                [pdfRunnerCandidate("google:gemini-2.5-pro", native: true, apiKey: "gemini-test-key")],
                { => pdfRunnerTextExtraction() }
            )

            @Expect(result.ok, true)
            @Expect(result.text, "gemini summary")
            @Expect(pdfRunnerHttpCalls, 1)
            @Expect(pdfRunnerString(pdfRunnerCapturedHttpRequest, "url").contains("key=gemini-test-key"), true)
            let body = pdfRunnerObject(pdfRunnerCapturedHttpRequest, "body")
            let contents = pdfRunnerArray(body, "contents")
            let parts = contents[0].asObject().get("parts").getOrThrow().asArray()
            let inlineData = parts[0].asObject().get("inline_data").getOrThrow().asObject()
            @Expect(pdfRunnerString(inlineData, "mime_type"), "application/pdf")
            @Expect(pdfRunnerString(inlineData, "data"), "JVBERi0xLjQ=")
        } finally {
            setGatewayPdfNativeHttpRunnerForTest(None<(JsonObject) -> GatewayPdfNativeHttpResult>)
        }
    }

    @TestCase
    public func nativePagesFailsBeforeHttpAndExtractor(): Unit {
        pdfRunnerReset()
        setGatewayPdfNativeHttpRunnerForTest(Some({ request: JsonObject =>
            pdfRunnerCapturedHttpRequest = request
            pdfRunnerHttpCalls += 1
            GatewayPdfNativeHttpResult(200, bodyBytes: "{}".toArray())
        }))
        try {
            let result = gatewayPdfRunPrompt(
                pdfRunnerPdf(),
                "Only page one",
                [pdfRunnerCandidate("anthropic:claude-sonnet", native: true, apiKey: "anthropic-test-key")],
                { =>
                    pdfRunnerExtractorCalls += 1
                    pdfRunnerTextExtraction()
                },
                pageNumbers: [1]
            )

            @Expect(result.ok, false)
            @Expect(result.error.contains("pages is not supported with native PDF providers"), true)
            @Expect(pdfRunnerHttpCalls, 0)
            @Expect(pdfRunnerExtractorCalls, 0)
            @Expect(result.attempts[0].status, "unsupported_pages")
        } finally {
            setGatewayPdfNativeHttpRunnerForTest(None<(JsonObject) -> GatewayPdfNativeHttpResult>)
        }
    }

    @TestCase
    public func fallbackTextOnlySendsPromptAndPdfTextWithoutImage(): Unit {
        pdfRunnerReset()
        pdfRunnerFakeModelName = "pdf-runner-text"
        let modelRef = "fake:pdf-runner-text"
        ModelManager.registerChatModel(modelRef, { => PdfRunnerFakeModel() })

        let result = gatewayPdfRunPrompt(
            pdfRunnerPdf(),
            "Answer from the document",
            [pdfRunnerCandidate(modelRef, image: false)],
            { => pdfRunnerTextExtraction() }
        )

        @Expect(result.ok, true)
        @Expect(result.native, false)
        @Expect(pdfRunnerModelCalls, 1)
        let messages = pdfRunnerArray(pdfRunnerCapturedModelRequest, "messages")
        @Expect(messages.size(), 1)
        let first = messages[0].asObject()
        @Expect(pdfRunnerString(first, "content").contains("[PDF text]"), true)
        @Expect(pdfRunnerString(first, "content").contains("Answer from the document"), true)
        @Expect(first.get("image").isNone(), true)
    }

    @TestCase
    public func fallbackImagesUseMultipleUserMessagesWithAtMostOneImageEach(): Unit {
        pdfRunnerReset()
        pdfRunnerFakeModelName = "pdf-runner-image"
        let modelRef = "fake:pdf-runner-image"
        ModelManager.registerChatModel(modelRef, { => PdfRunnerFakeModel() })

        let result = gatewayPdfRunPrompt(
            pdfRunnerPdf(),
            "Describe pages",
            [pdfRunnerCandidate(modelRef, image: true)],
            { => [
                GatewayPdfExtraction(
                    "short text",
                    images: [
                        GatewayPdfExtractedImage("image/png", "page-one", pageNumber: 1),
                        GatewayPdfExtractedImage("image/png", "page-two", pageNumber: 2)
                    ]
                )
            ] }
        )

        @Expect(result.ok, true)
        @Expect(pdfRunnerModelCalls, 1)
        let messages = pdfRunnerArray(pdfRunnerCapturedModelRequest, "messages")
        @Expect(messages.size(), 2)
        let first = messages[0].asObject()
        let second = messages[1].asObject()
        @Expect(pdfRunnerString(first, "content").contains("[PDF text]"), true)
        @Expect(pdfRunnerString(first, "content").contains("Describe pages"), true)
        @Expect(pdfRunnerString(first, "image"), "data:image/png;base64,page-one")
        @Expect(pdfRunnerString(second, "image"), "data:image/png;base64,page-two")
    }

    @TestCase
    public func fallbackTextOnlyModelDropsImagesWhenTextExists(): Unit {
        pdfRunnerReset()
        pdfRunnerFakeModelName = "pdf-runner-downgrade"
        let modelRef = "fake:pdf-runner-downgrade"
        ModelManager.registerChatModel(modelRef, { => PdfRunnerFakeModel() })

        let result = gatewayPdfRunPrompt(
            pdfRunnerPdf(),
            "Use text if possible",
            [pdfRunnerCandidate(modelRef, image: false)],
            { => [
                GatewayPdfExtraction(
                    "extractable text",
                    images: [GatewayPdfExtractedImage("image/png", "page-one", pageNumber: 1)]
                )
            ] }
        )

        @Expect(result.ok, true)
        @Expect(result.attempts[0].status, "ok_text_only_downgrade")
        @Expect(result.attempts[0].error.contains("discarded rendered page images"), true)
        let messages = pdfRunnerArray(pdfRunnerCapturedModelRequest, "messages")
        @Expect(messages.size(), 1)
        @Expect(messages[0].asObject().get("image").isNone(), true)
        @Expect(pdfRunnerString(messages[0].asObject(), "content").contains("extractable text"), true)
    }

    @TestCase
    public func fallbackTextOnlyModelFailsWhenPdfHasOnlyImages(): Unit {
        pdfRunnerReset()
        pdfRunnerFakeModelName = "pdf-runner-no-text"
        let modelRef = "fake:pdf-runner-no-text"
        ModelManager.registerChatModel(modelRef, { => PdfRunnerFakeModel() })

        let result = gatewayPdfRunPrompt(
            pdfRunnerPdf(),
            "Read the image",
            [pdfRunnerCandidate(modelRef, image: false)],
            { => [
                GatewayPdfExtraction(
                    "",
                    images: [GatewayPdfExtractedImage("image/png", "page-one", pageNumber: 1)]
                )
            ] }
        )

        @Expect(result.ok, false)
        @Expect(result.error, "model_does_not_support_images_and_pdf_has_no_extractable_text")
        @Expect(pdfRunnerModelCalls, 0)
        @Expect(result.attempts[0].status, "unsupported_images")
    }

    @TestCase
    public func nativeProviderErrorsAreRecordedAndRedacted(): Unit {
        pdfRunnerReset()
        setGatewayPdfNativeHttpRunnerForTest(Some({ request: JsonObject =>
            pdfRunnerCapturedHttpRequest = request
            pdfRunnerHttpCalls += 1
            GatewayPdfNativeHttpResult(
                401,
                bodyBytes: "Authorization: Bearer pdf-secret https://provider.example/v1?key=pdf-secret&token=query-token api_key=body-secret x-api-key: pdf-secret".toArray()
            )
        }))
        try {
            let result = gatewayPdfRunPrompt(
                pdfRunnerPdf(),
                "Summarize",
                [pdfRunnerCandidate("anthropic:claude-sonnet", native: true, apiKey: "pdf-secret")],
                { => pdfRunnerTextExtraction() }
            )

            @Expect(result.ok, false)
            @Expect(result.attempts[0].status, "provider_error")
            @Expect(result.error.contains("401"), true)
            @Expect(result.error.contains("pdf-secret"), false)
            @Expect(result.error.contains("query-token"), false)
            @Expect(result.attemptsJson().toJsonString().contains("pdf-secret"), false)
            @Expect(result.attemptsJson().toJsonString().contains("query-token"), false)
        } finally {
            setGatewayPdfNativeHttpRunnerForTest(None<(JsonObject) -> GatewayPdfNativeHttpResult>)
        }
    }
}
