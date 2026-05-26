package metis.core.media_tests

import metis.core.*

import std.collection.ArrayList
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.time.*
import std.unittest.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString}

private func imageRuntimeTempRoot(label: String): Path {
    let root = Path("/tmp/metis-image-generation-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    Directory.create(root, recursive: true)
    root
}

private func imageRuntimeString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func imageRuntimeBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

private func imageRuntimeObj(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func imageRuntimeArr(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func imageRuntimeProvider(): JsonObject {
    let provider = JsonObject()
    provider.put("kind", JsonString("openai-images"))
    provider.put("baseUrl", JsonString("https://api.openai.com/v1"))
    provider.put("apiKey", JsonString("image-secret-key"))
    provider.put("model", JsonString("gpt-image-1"))
    provider.put("timeoutMs", JsonInt(120000))
    provider.put("maxImageBytes", JsonInt(1024 * 1024))
    provider
}

private func imageRuntimeDashScopeProvider(): JsonObject {
    let provider = JsonObject()
    provider.put("kind", JsonString("dashscope-qwen-image-generation"))
    provider.put("baseUrl", JsonString("https://dashscope.aliyuncs.com/api/v1"))
    provider.put("apiKey", JsonString("dashscope-secret-key"))
    provider.put("model", JsonString("qwen-image-2.0-pro"))
    provider.put("timeoutMs", JsonInt(120000))
    provider.put("maxImageBytes", JsonInt(1024 * 1024))
    provider
}

private func imageRuntimeProviderKind(kind: String, model: String, baseUrl: String): JsonObject {
    let provider = JsonObject()
    provider.put("kind", JsonString(kind))
    provider.put("baseUrl", JsonString(baseUrl))
    provider.put("apiKey", JsonString("${kind}-secret-key"))
    provider.put("model", JsonString(model))
    provider.put("timeoutMs", JsonInt(120000))
    provider.put("maxImageBytes", JsonInt(1024 * 1024))
    provider
}

private func imageRuntimeConfig(providerId: String, providerObj: JsonObject, outputRoot!: Path = imageRuntimeTempRoot("default")): JsonObject {
    let config = JsonObject()
    let providers = JsonObject()
    providers.put(providerId, providerObj)
    config.put("enabled", JsonBool(true))
    config.put("provider", JsonString(providerId))
    config.put("providers", providers)
    config.put("outputRoot", JsonString(outputRoot.toString()))
    config.put("allowedOutputRoots", JsonArray([JsonString(outputRoot.toString())]))
    config.put("maxPromptChars", JsonInt(4000))
    config
}

private func imageRuntimeRequest(prompt: String): JsonObject {
    let request = JsonObject()
    request.put("prompt", JsonString(prompt))
    request.put("filename", JsonString("eagle image.png"))
    request.put("size", JsonString("1024x1024"))
    request.put("count", JsonInt(1))
    request
}

@Test
public class GatewayImageGenerationRuntimeTest {
    @TestCase
    public func runtimeReturnsNotConfiguredWhenProviderMissing(): Unit {
        let result = gatewayImageGenerationGenerate(JsonObject(), imageRuntimeRequest("draw an eagle"))

        @Expect(imageRuntimeBool(result, "ok"), false)
        @Expect(imageRuntimeString(result, "status"), "not_configured")
        @Expect(imageRuntimeArr(result, "images").size(), 0)
    }

    @TestCase
    public func runtimeRejectsUnsafeOutputRootBeforeProvider(): Unit {
        let config = imageRuntimeConfig("openai", imageRuntimeProvider())
        config.put("outputRoot", JsonString("/Users/l3gi0n/work/workspace_cangjie/Metis"))
        config.put("allowedOutputRoots", JsonArray([]))

        let result = gatewayImageGenerationGenerate(config, imageRuntimeRequest("draw an eagle"))

        @Expect(imageRuntimeBool(result, "ok"), false)
        @Expect(imageRuntimeString(result, "status"), "invalid_request")
        @Expect(imageRuntimeString(result, "message").contains("outputRoot"), true)
    }

    @TestCase
    public func openAiProviderParsesBase64ImageAndWritesFile(): Unit {
        let root = imageRuntimeTempRoot("openai-b64")
        let requests = ArrayList<String>()
        setGatewayImageGenerationOpenAiRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            requests.add(request.toJsonString())
            let body = imageRuntimeObj(request, "body")
            @Expect(imageRuntimeString(request, "url"), "https://api.openai.com/v1/images/generations")
            @Expect(imageRuntimeString(request, "authorization"), "Bearer image-secret-key")
            @Expect(imageRuntimeString(body, "model"), "gpt-image-1")
            @Expect(imageRuntimeString(body, "prompt"), "draw an eagle")
            @Expect(imageRuntimeString(body, "size"), "1024x1024")
            @Expect(request.toJsonString().contains("apiKey"), false)
            GatewayImageGenerationHttpResult(200, bodyBytes: "{\"data\":[{\"b64_json\":\"SU1BR0U=\"}]}".toArray(), contentType: "application/json")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("openai", imageRuntimeProvider(), outputRoot: root), imageRuntimeRequest("draw an eagle"))
            let image = imageRuntimeArr(result, "images")[0].asObject()
            let imagePath = Path(imageRuntimeString(image, "path"))

            @Expect(imageRuntimeBool(result, "ok"), true)
            @Expect(imageRuntimeString(result, "status"), "ok")
            @Expect(imageRuntimeString(result, "provider"), "openai")
            @Expect(imageRuntimeString(result, "providerKind"), "openai-images")
            @Expect(imageRuntimeString(image, "mimeType"), "image/png")
            @Expect(imageRuntimeString(image, "fileName"), "eagle-image.png")
            @Expect(exists(imagePath), true)
            @Expect(String.fromUtf8(File.readFrom(imagePath)), "IMAGE")
            @Expect(requests.size, 1)
        } finally {
            setGatewayImageGenerationOpenAiRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func dashScopeQwenImageProviderPostsNativeRequestAndDownloadsImage(): Unit {
        let root = imageRuntimeTempRoot("dashscope-qwen")
        let requests = ArrayList<String>()
        let downloads = ArrayList<String>()
        setGatewayImageGenerationDashScopeRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            requests.add(request.toJsonString())
            let body = imageRuntimeObj(request, "body")
            let input = imageRuntimeObj(body, "input")
            let parameters = imageRuntimeObj(body, "parameters")
            let messages = imageRuntimeArr(input, "messages")
            let message = messages[0].asObject()
            let content = imageRuntimeArr(message, "content")
            let text = content[0].asObject()

            @Expect(imageRuntimeString(request, "url"), "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")
            @Expect(imageRuntimeString(request, "authorization"), "Bearer dashscope-secret-key")
            @Expect(imageRuntimeString(body, "model"), "qwen-image-2.0-pro")
            @Expect(imageRuntimeString(message, "role"), "user")
            @Expect(imageRuntimeString(text, "text"), "draw an eagle")
            @Expect(imageRuntimeString(parameters, "size"), "1024*1024")
            @Expect(parameters.get("n").getOrThrow().asInt().getValue(), 1)
            @Expect(request.toJsonString().contains("apiKey"), false)
            GatewayImageGenerationHttpResult(200, bodyBytes: "{\"output\":{\"choices\":[{\"message\":{\"content\":[{\"image\":\"https://dashscope-result.example/eagle.png\"}]}}]}}".toArray(), contentType: "application/json")
        }))
        setGatewayImageGenerationDownloaderForTest(Some({ url: String, _timeoutMs: Int64, _maxBytes: Int64, _providerConfig: JsonObject =>
            downloads.add(url)
            GatewayImageGenerationHttpResult(200, bodyBytes: "DASH_IMAGE".toArray(), contentType: "image/png")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("dashscope", imageRuntimeDashScopeProvider(), outputRoot: root), imageRuntimeRequest("draw an eagle"))
            let image = imageRuntimeArr(result, "images")[0].asObject()
            let imagePath = Path(imageRuntimeString(image, "path"))

            @Expect(imageRuntimeBool(result, "ok"), true)
            @Expect(imageRuntimeString(result, "status"), "ok")
            @Expect(imageRuntimeString(result, "provider"), "dashscope")
            @Expect(imageRuntimeString(result, "providerKind"), "dashscope-qwen-image-generation")
            @Expect(imageRuntimeString(result, "model"), "qwen-image-2.0-pro")
            @Expect(imageRuntimeString(image, "mimeType"), "image/png")
            @Expect(imageRuntimeString(image, "fileName"), "eagle-image.png")
            @Expect(exists(imagePath), true)
            @Expect(String.fromUtf8(File.readFrom(imagePath)), "DASH_IMAGE")
            @Expect(requests.size, 1)
            @Expect(downloads.size, 1)
            @Expect(downloads[0], "https://dashscope-result.example/eagle.png")
        } finally {
            setGatewayImageGenerationDashScopeRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
            setGatewayImageGenerationDownloaderForTest(None<(String, Int64, Int64, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func dashScopeQwenImageProviderUsesNativeAigcEndpointWhenBaseUrlIsCompatibleMode(): Unit {
        let root = imageRuntimeTempRoot("dashscope-qwen-compatible")
        let provider = imageRuntimeDashScopeProvider()
        provider.put("baseUrl", JsonString("https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"))
        let dashScopeRequests = ArrayList<String>()
        let openAiRequests = ArrayList<String>()
        setGatewayImageGenerationDashScopeRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            dashScopeRequests.add(request.toJsonString())
            let body = imageRuntimeObj(request, "body")
            let input = imageRuntimeObj(body, "input")
            let parameters = imageRuntimeObj(body, "parameters")
            let messages = imageRuntimeArr(input, "messages")
            let message = messages[0].asObject()
            let content = imageRuntimeArr(message, "content")
            let text = content[0].asObject()

            @Expect(imageRuntimeString(request, "url"), "https://token-plan.cn-beijing.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")
            @Expect(imageRuntimeString(request, "authorization"), "Bearer dashscope-secret-key")
            @Expect(imageRuntimeString(body, "model"), "qwen-image-2.0-pro")
            @Expect(imageRuntimeString(message, "role"), "user")
            @Expect(imageRuntimeString(text, "text"), "draw an eagle")
            @Expect(imageRuntimeString(parameters, "size"), "1024*1024")
            GatewayImageGenerationHttpResult(200, bodyBytes: "{\"output\":{\"choices\":[{\"message\":{\"content\":[{\"image\":\"https://token-plan-result.example/eagle.png\"}]}}]}}".toArray(), contentType: "application/json")
        }))
        setGatewayImageGenerationOpenAiRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            openAiRequests.add(request.toJsonString())
            GatewayImageGenerationHttpResult(500, error: "OpenAI runner must not be used for dashscope-qwen-image compatible-mode")
        }))
        setGatewayImageGenerationDownloaderForTest(Some({ _url: String, _timeoutMs: Int64, _maxBytes: Int64, _providerConfig: JsonObject =>
            GatewayImageGenerationHttpResult(200, bodyBytes: "TOKEN_PLAN_IMAGE".toArray(), contentType: "image/png")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("dashscope", provider, outputRoot: root), imageRuntimeRequest("draw an eagle"))
            let image = imageRuntimeArr(result, "images")[0].asObject()
            let imagePath = Path(imageRuntimeString(image, "path"))

            @Expect(imageRuntimeBool(result, "ok"), true)
            @Expect(imageRuntimeString(result, "status"), "ok")
            @Expect(imageRuntimeString(result, "provider"), "dashscope")
            @Expect(imageRuntimeString(result, "providerKind"), "dashscope-qwen-image-generation")
            @Expect(imageRuntimeString(result, "model"), "qwen-image-2.0-pro")
            @Expect(imageRuntimeString(image, "mimeType"), "image/png")
            @Expect(imageRuntimeString(image, "fileName"), "eagle-image.png")
            @Expect(exists(imagePath), true)
            @Expect(String.fromUtf8(File.readFrom(imagePath)), "TOKEN_PLAN_IMAGE")
            @Expect(dashScopeRequests.size, 1)
            @Expect(openAiRequests.size, 0)
        } finally {
            setGatewayImageGenerationDashScopeRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
            setGatewayImageGenerationOpenAiRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
            setGatewayImageGenerationDownloaderForTest(None<(String, Int64, Int64, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func dashScopeQwenImageProviderUsesExactEndpointWithoutSwitchingProtocol(): Unit {
        let root = imageRuntimeTempRoot("dashscope-qwen-compatible-endpoint")
        let provider = imageRuntimeDashScopeProvider()
        provider.put("endpoint", JsonString("https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"))
        let dashScopeRequests = ArrayList<String>()
        let openAiRequests = ArrayList<String>()
        setGatewayImageGenerationDashScopeRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            dashScopeRequests.add(request.toJsonString())
            let body = imageRuntimeObj(request, "body")
            @Expect(imageRuntimeString(request, "url"), "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")
            @Expect(imageRuntimeString(body, "model"), "qwen-image-2.0-pro")
            GatewayImageGenerationHttpResult(200, bodyBytes: "{\"output\":{\"images\":[\"https://dashscope-endpoint.example/eagle.png\"]}}".toArray(), contentType: "application/json")
        }))
        setGatewayImageGenerationOpenAiRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            openAiRequests.add(request.toJsonString())
            GatewayImageGenerationHttpResult(500, error: "OpenAI runner must not be used for DashScope endpoint")
        }))
        setGatewayImageGenerationDownloaderForTest(Some({ _url: String, _timeoutMs: Int64, _maxBytes: Int64, _providerConfig: JsonObject =>
            GatewayImageGenerationHttpResult(200, bodyBytes: "DASH-ENDPOINT".toArray(), contentType: "image/png")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("dashscope", provider, outputRoot: root), imageRuntimeRequest("draw an eagle"))
            let image = imageRuntimeArr(result, "images")[0].asObject()
            let imagePath = Path(imageRuntimeString(image, "path"))

            @Expect(imageRuntimeBool(result, "ok"), true)
            @Expect(imageRuntimeString(result, "providerKind"), "dashscope-qwen-image-generation")
            @Expect(String.fromUtf8(File.readFrom(imagePath)), "DASH-ENDPOINT")
            @Expect(dashScopeRequests.size, 1)
            @Expect(openAiRequests.size, 0)
        } finally {
            setGatewayImageGenerationDashScopeRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
            setGatewayImageGenerationOpenAiRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
            setGatewayImageGenerationDownloaderForTest(None<(String, Int64, Int64, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func openAiQwenImageKindAliasUsesOpenAiCompatibleImagesApi(): Unit {
        let root = imageRuntimeTempRoot("openai-qwen-compatible")
        let provider = imageRuntimeProvider()
        provider.put("kind", JsonString("openai-qwen-image"))
        provider.put("baseUrl", JsonString("https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"))
        provider.put("model", JsonString("qwen-image-2.0-pro"))
        setGatewayImageGenerationOpenAiRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            let body = imageRuntimeObj(request, "body")
            @Expect(imageRuntimeString(request, "url"), "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/images/generations")
            @Expect(imageRuntimeString(body, "model"), "qwen-image-2.0-pro")
            @Expect(imageRuntimeString(body, "prompt"), "draw an eagle")
            GatewayImageGenerationHttpResult(200, bodyBytes: "{\"data\":[{\"b64_json\":\"T1BFTkFJLVFXRU4=\"}]}".toArray(), contentType: "application/json")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("openai-qwen", provider, outputRoot: root), imageRuntimeRequest("draw an eagle"))
            let image = imageRuntimeArr(result, "images")[0].asObject()
            let imagePath = Path(imageRuntimeString(image, "path"))

            @Expect(imageRuntimeBool(result, "ok"), true)
            @Expect(imageRuntimeString(result, "provider"), "openai-qwen")
            @Expect(imageRuntimeString(result, "providerKind"), "openai-images")
            @Expect(String.fromUtf8(File.readFrom(imagePath)), "OPENAI-QWEN")
        } finally {
            setGatewayImageGenerationOpenAiRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func openAiImagesEndpointIsExactAndNotAutoAppended(): Unit {
        let root = imageRuntimeTempRoot("openai-exact-endpoint")
        let provider = imageRuntimeProvider()
        provider.put("endpoint", JsonString("https://example.test/custom/image"))
        setGatewayImageGenerationOpenAiRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            let body = imageRuntimeObj(request, "body")
            @Expect(imageRuntimeString(request, "url"), "https://example.test/custom/image")
            @Expect(imageRuntimeString(body, "model"), "gpt-image-1")
            GatewayImageGenerationHttpResult(200, bodyBytes: "{\"data\":[{\"b64_json\":\"RVhBQ1Q=\"}]}".toArray(), contentType: "application/json")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("openai", provider, outputRoot: root), imageRuntimeRequest("draw an eagle"))
            let image = imageRuntimeArr(result, "images")[0].asObject()
            let imagePath = Path(imageRuntimeString(image, "path"))

            @Expect(imageRuntimeBool(result, "ok"), true)
            @Expect(imageRuntimeString(result, "providerKind"), "openai-images")
            @Expect(String.fromUtf8(File.readFrom(imagePath)), "EXACT")
        } finally {
            setGatewayImageGenerationOpenAiRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func googleGeminiImageProviderBuildsGenerateContentAndParsesInlineData(): Unit {
        let root = imageRuntimeTempRoot("google-image")
        let provider = imageRuntimeProviderKind("google-gemini-image", "gemini-3.1-flash-image-preview", "https://generativelanguage.googleapis.com")
        setGatewayImageGenerationGoogleRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            let body = imageRuntimeObj(request, "body")
            @Expect(imageRuntimeString(request, "url"), "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image-preview:generateContent")
            let contents = imageRuntimeArr(body, "contents")
            let first = contents[0].asObject()
            let parts = imageRuntimeArr(first, "parts")
            @Expect(imageRuntimeString(parts[0].asObject(), "text"), "draw an eagle")
            GatewayImageGenerationHttpResult(200, bodyBytes: "{\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"R09PR0xF\"}}]}}]}".toArray(), contentType: "application/json")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("google", provider, outputRoot: root), imageRuntimeRequest("draw an eagle"))
            let image = imageRuntimeArr(result, "images")[0].asObject()
            let imagePath = Path(imageRuntimeString(image, "path"))

            @Expect(imageRuntimeBool(result, "ok"), true)
            @Expect(imageRuntimeString(result, "providerKind"), "google-gemini-image")
            @Expect(String.fromUtf8(File.readFrom(imagePath)), "GOOGLE")
        } finally {
            setGatewayImageGenerationGoogleRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func minimaxImageProviderUsesOriginAndParsesBase64Images(): Unit {
        let root = imageRuntimeTempRoot("minimax-image")
        let provider = imageRuntimeProviderKind("minimax-image", "image-01", "https://api.minimax.io/anthropic")
        setGatewayImageGenerationMiniMaxRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            let body = imageRuntimeObj(request, "body")
            @Expect(imageRuntimeString(request, "url"), "https://api.minimax.io/v1/image_generation")
            @Expect(imageRuntimeString(body, "model"), "image-01")
            @Expect(imageRuntimeString(body, "response_format"), "base64")
            GatewayImageGenerationHttpResult(200, bodyBytes: "{\"base_resp\":{\"status_code\":0},\"data\":{\"image_base64\":[\"TUlOSU1BWA==\"]}}".toArray(), contentType: "application/json")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("minimax", provider, outputRoot: root), imageRuntimeRequest("draw an eagle"))
            let image = imageRuntimeArr(result, "images")[0].asObject()
            let imagePath = Path(imageRuntimeString(image, "path"))

            @Expect(imageRuntimeBool(result, "ok"), true)
            @Expect(imageRuntimeString(result, "providerKind"), "minimax-image")
            @Expect(String.fromUtf8(File.readFrom(imagePath)), "MINIMAX")
        } finally {
            setGatewayImageGenerationMiniMaxRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func falImageProviderPostsModelPathAndDownloadsImageUrl(): Unit {
        let root = imageRuntimeTempRoot("fal-image")
        let provider = imageRuntimeProviderKind("fal-image", "fal-ai/flux/dev", "https://fal.run")
        let downloads = ArrayList<String>()
        setGatewayImageGenerationFalRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            let body = imageRuntimeObj(request, "body")
            @Expect(imageRuntimeString(request, "url"), "https://fal.run/fal-ai/flux/dev")
            @Expect(imageRuntimeString(body, "prompt"), "draw an eagle")
            GatewayImageGenerationHttpResult(200, bodyBytes: "{\"images\":[{\"url\":\"https://fal-result.example/eagle.png\",\"content_type\":\"image/png\"}]}".toArray(), contentType: "application/json")
        }))
        setGatewayImageGenerationDownloaderForTest(Some({ url: String, _timeoutMs: Int64, _maxBytes: Int64, _providerConfig: JsonObject =>
            downloads.add(url)
            GatewayImageGenerationHttpResult(200, bodyBytes: "FAL_IMAGE".toArray(), contentType: "image/png")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("fal", provider, outputRoot: root), imageRuntimeRequest("draw an eagle"))
            let image = imageRuntimeArr(result, "images")[0].asObject()
            let imagePath = Path(imageRuntimeString(image, "path"))

            @Expect(imageRuntimeBool(result, "ok"), true)
            @Expect(imageRuntimeString(result, "providerKind"), "fal-image")
            @Expect(String.fromUtf8(File.readFrom(imagePath)), "FAL_IMAGE")
            @Expect(downloads[0], "https://fal-result.example/eagle.png")
        } finally {
            setGatewayImageGenerationFalRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
            setGatewayImageGenerationDownloaderForTest(None<(String, Int64, Int64, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func googleGeminiImageProviderIncludesReferenceImageAndImageConfig(): Unit {
        let root = imageRuntimeTempRoot("google-reference-image")
        let ref = root.join("ref.png")
        File.writeTo(ref, "REF".toArray())
        let request = imageRuntimeRequest("edit the reference")
        request.put("referenceImage", JsonString(ref.toString()))
        request.put("aspectRatio", JsonString("1:1"))
        let provider = imageRuntimeProviderKind("google-gemini-image", "gemini-3.1-flash-image-preview", "https://generativelanguage.googleapis.com")
        setGatewayImageGenerationGoogleRunnerForTest(Some({ requestObj: JsonObject, _providerConfig: JsonObject =>
            let body = imageRuntimeObj(requestObj, "body")
            let contents = imageRuntimeArr(body, "contents")
            let parts = imageRuntimeArr(contents[0].asObject(), "parts")
            let inline = imageRuntimeObj(parts[0].asObject(), "inlineData")
            let text = parts[1].asObject()
            let generationConfig = imageRuntimeObj(body, "generationConfig")
            let imageConfig = imageRuntimeObj(generationConfig, "imageConfig")
            @Expect(imageRuntimeString(inline, "mimeType"), "image/png")
            @Expect(imageRuntimeString(inline, "data"), "UkVG")
            @Expect(imageRuntimeString(text, "text"), "edit the reference")
            @Expect(imageRuntimeString(imageConfig, "aspectRatio"), "1:1")
            GatewayImageGenerationHttpResult(200, bodyBytes: "{\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"R09PR0xFX0VESVQ=\"}}]}}]}".toArray(), contentType: "application/json")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("google", provider, outputRoot: root), request)
            let image = imageRuntimeArr(result, "images")[0].asObject()
            @Expect(imageRuntimeBool(result, "ok"), true)
            @Expect(String.fromUtf8(File.readFrom(Path(imageRuntimeString(image, "path")))), "GOOGLE_EDIT")
        } finally {
            setGatewayImageGenerationGoogleRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func minimaxImageProviderIncludesSubjectReference(): Unit {
        let root = imageRuntimeTempRoot("minimax-reference-image")
        let ref = root.join("ref.png")
        File.writeTo(ref, "REF".toArray())
        let request = imageRuntimeRequest("edit the reference")
        request.put("referenceImage", JsonString(ref.toString()))
        let provider = imageRuntimeProviderKind("minimax-image", "image-01", "https://api.minimax.io/anthropic")
        setGatewayImageGenerationMiniMaxRunnerForTest(Some({ requestObj: JsonObject, _providerConfig: JsonObject =>
            let body = imageRuntimeObj(requestObj, "body")
            let refs = imageRuntimeArr(body, "subject_reference")
            let refObj = refs[0].asObject()
            @Expect(imageRuntimeString(refObj, "type"), "base64")
            @Expect(imageRuntimeString(refObj, "image_base64"), "UkVG")
            @Expect(imageRuntimeString(refObj, "mime_type"), "image/png")
            GatewayImageGenerationHttpResult(200, bodyBytes: "{\"base_resp\":{\"status_code\":0},\"data\":{\"image_base64\":[\"TUlOSU1BWF9FRElU\"]}}".toArray(), contentType: "application/json")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("minimax", provider, outputRoot: root), request)
            let image = imageRuntimeArr(result, "images")[0].asObject()
            @Expect(imageRuntimeBool(result, "ok"), true)
            @Expect(String.fromUtf8(File.readFrom(Path(imageRuntimeString(image, "path")))), "MINIMAX_EDIT")
        } finally {
            setGatewayImageGenerationMiniMaxRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func falImageProviderAppendsImageToImageAndSendsReferenceDataUrl(): Unit {
        let root = imageRuntimeTempRoot("fal-reference-image")
        let ref = root.join("ref.png")
        File.writeTo(ref, "REF".toArray())
        let request = imageRuntimeRequest("edit the reference")
        request.put("referenceImage", JsonString(ref.toString()))
        let provider = imageRuntimeProviderKind("fal-image", "fal-ai/flux/dev", "https://fal.run")
        setGatewayImageGenerationFalRunnerForTest(Some({ requestObj: JsonObject, _providerConfig: JsonObject =>
            let body = imageRuntimeObj(requestObj, "body")
            @Expect(imageRuntimeString(requestObj, "url"), "https://fal.run/fal-ai/flux/dev/image-to-image")
            @Expect(imageRuntimeString(body, "image_url"), "data:image/png;base64,UkVG")
            GatewayImageGenerationHttpResult(200, bodyBytes: "{\"images\":[{\"url\":\"https://fal-result.example/edit.png\"}]}".toArray(), contentType: "application/json")
        }))
        setGatewayImageGenerationDownloaderForTest(Some({ _url: String, _timeoutMs: Int64, _maxBytes: Int64, _providerConfig: JsonObject =>
            GatewayImageGenerationHttpResult(200, bodyBytes: "FAL_EDIT".toArray(), contentType: "image/png")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("fal", provider, outputRoot: root), request)
            let image = imageRuntimeArr(result, "images")[0].asObject()
            @Expect(imageRuntimeBool(result, "ok"), true)
            @Expect(String.fromUtf8(File.readFrom(Path(imageRuntimeString(image, "path")))), "FAL_EDIT")
        } finally {
            setGatewayImageGenerationFalRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
            setGatewayImageGenerationDownloaderForTest(None<(String, Int64, Int64, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func vydraImageProviderSubmitsModelPathAndDownloadsImageUrl(): Unit {
        let root = imageRuntimeTempRoot("vydra-image")
        let provider = imageRuntimeProviderKind("vydra-image", "grok-imagine", "https://vydra.ai")
        let downloads = ArrayList<String>()
        setGatewayImageGenerationVydraRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            let body = imageRuntimeObj(request, "body")
            @Expect(imageRuntimeString(request, "url"), "https://www.vydra.ai/api/v1/models/grok-imagine")
            @Expect(imageRuntimeString(body, "prompt"), "draw an eagle")
            @Expect(imageRuntimeString(body, "model"), "text-to-image")
            GatewayImageGenerationHttpResult(200, bodyBytes: "{\"imageUrl\":\"https://vydra-result.example/eagle.png\"}".toArray(), contentType: "application/json")
        }))
        setGatewayImageGenerationDownloaderForTest(Some({ url: String, _timeoutMs: Int64, _maxBytes: Int64, _providerConfig: JsonObject =>
            downloads.add(url)
            GatewayImageGenerationHttpResult(200, bodyBytes: "VYDRA_IMAGE".toArray(), contentType: "image/png")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("vydra", provider, outputRoot: root), imageRuntimeRequest("draw an eagle"))
            let image = imageRuntimeArr(result, "images")[0].asObject()
            let imagePath = Path(imageRuntimeString(image, "path"))

            @Expect(imageRuntimeBool(result, "ok"), true)
            @Expect(imageRuntimeString(result, "providerKind"), "vydra-image")
            @Expect(String.fromUtf8(File.readFrom(imagePath)), "VYDRA_IMAGE")
            @Expect(downloads[0], "https://vydra-result.example/eagle.png")
        } finally {
            setGatewayImageGenerationVydraRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
            setGatewayImageGenerationDownloaderForTest(None<(String, Int64, Int64, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func vydraImageProviderPollsJobUntilImageUrlIsAvailable(): Unit {
        let root = imageRuntimeTempRoot("vydra-poll")
        let provider = imageRuntimeProviderKind("vydra-image", "grok-imagine", "https://vydra.ai")
        provider.put("pollIntervalMs", JsonInt(0))
        let calls = ArrayList<String>()
        setGatewayImageGenerationVydraRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            calls.add(imageRuntimeString(request, "method") + " " + imageRuntimeString(request, "url"))
            if (imageRuntimeString(request, "method") == "GET") {
                @Expect(imageRuntimeString(request, "url"), "https://www.vydra.ai/api/v1/jobs/job-1")
                GatewayImageGenerationHttpResult(200, bodyBytes: "{\"status\":\"completed\",\"imageUrl\":\"https://vydra-result.example/poll.png\"}".toArray(), contentType: "application/json")
            } else {
                GatewayImageGenerationHttpResult(200, bodyBytes: "{\"jobId\":\"job-1\"}".toArray(), contentType: "application/json")
            }
        }))
        setGatewayImageGenerationDownloaderForTest(Some({ _url: String, _timeoutMs: Int64, _maxBytes: Int64, _providerConfig: JsonObject =>
            GatewayImageGenerationHttpResult(200, bodyBytes: "VYDRA_POLL".toArray(), contentType: "image/png")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("vydra", provider, outputRoot: root), imageRuntimeRequest("draw an eagle"))
            let image = imageRuntimeArr(result, "images")[0].asObject()
            @Expect(imageRuntimeBool(result, "ok"), true)
            @Expect(String.fromUtf8(File.readFrom(Path(imageRuntimeString(image, "path")))), "VYDRA_POLL")
            @Expect(calls.size, 2)
        } finally {
            setGatewayImageGenerationVydraRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
            setGatewayImageGenerationDownloaderForTest(None<(String, Int64, Int64, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func vydraImageProviderPollFailureAndTimeoutAreStructured(): Unit {
        let root = imageRuntimeTempRoot("vydra-poll-failure")
        let provider = imageRuntimeProviderKind("vydra-image", "grok-imagine", "https://vydra.ai")
        provider.put("pollIntervalMs", JsonInt(0))
        setGatewayImageGenerationVydraRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            if (imageRuntimeString(request, "method") == "GET") {
                GatewayImageGenerationHttpResult(200, bodyBytes: "{\"status\":\"failed\",\"message\":\"bad prompt\"}".toArray(), contentType: "application/json")
            } else {
                GatewayImageGenerationHttpResult(200, bodyBytes: "{\"jobId\":\"job-2\"}".toArray(), contentType: "application/json")
            }
        }))
        try {
            let failed = gatewayImageGenerationGenerate(imageRuntimeConfig("vydra", provider, outputRoot: root), imageRuntimeRequest("draw an eagle"))
            @Expect(imageRuntimeBool(failed, "ok"), false)
            @Expect(imageRuntimeString(failed, "status"), "provider_error")
            @Expect(imageRuntimeString(failed, "message").contains("bad prompt"), true)
        } finally {
            setGatewayImageGenerationVydraRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
        }

        let timeoutProvider = imageRuntimeProviderKind("vydra-image", "grok-imagine", "https://vydra.ai")
        timeoutProvider.put("pollIntervalMs", JsonInt(0))
        timeoutProvider.put("pollMaxAttempts", JsonInt(1))
        setGatewayImageGenerationVydraRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            if (imageRuntimeString(request, "method") == "GET") {
                GatewayImageGenerationHttpResult(200, bodyBytes: "{\"status\":\"running\"}".toArray(), contentType: "application/json")
            } else {
                GatewayImageGenerationHttpResult(200, bodyBytes: "{\"jobId\":\"job-3\"}".toArray(), contentType: "application/json")
            }
        }))
        try {
            let timedOut = gatewayImageGenerationGenerate(imageRuntimeConfig("vydra", timeoutProvider, outputRoot: root), imageRuntimeRequest("draw an eagle"))
            @Expect(imageRuntimeBool(timedOut, "ok"), false)
            @Expect(imageRuntimeString(timedOut, "status"), "timeout")
        } finally {
            setGatewayImageGenerationVydraRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func comfyImageProviderFailsFastWithWorkflowDiagnostic(): Unit {
        let root = imageRuntimeTempRoot("comfy-image")
        let provider = imageRuntimeProviderKind("comfy-image", "workflow", "http://127.0.0.1:8188")

        let result = gatewayImageGenerationGenerate(imageRuntimeConfig("comfy", provider, outputRoot: root), imageRuntimeRequest("draw an eagle"))

        @Expect(imageRuntimeBool(result, "ok"), false)
        @Expect(imageRuntimeString(result, "status"), "not_configured")
        @Expect(imageRuntimeString(result, "providerKind"), "comfy-image")
        @Expect(imageRuntimeString(result, "message").contains("workflow"), true)
    }

    @TestCase
    public func comfyImageProviderSubmitsWorkflowPollsAndDownloadsImage(): Unit {
        let root = imageRuntimeTempRoot("comfy-success")
        let provider = imageRuntimeProviderKind("comfy-image", "workflow", "http://127.0.0.1:8188")
        let workflow = JsonObject()
        workflow.put("1", JsonObject())
        provider.put("workflow", workflow)
        provider.put("promptNodeId", JsonString("1"))
        provider.put("pollIntervalMs", JsonInt(0))
        setGatewayImageGenerationComfyRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            if (imageRuntimeString(request, "method") == "GET") {
                @Expect(imageRuntimeString(request, "url"), "http://127.0.0.1:8188/history/prompt-1")
                GatewayImageGenerationHttpResult(200, bodyBytes: "{\"status\":{\"status_str\":\"success\"},\"imageUrl\":\"https://comfy-result.example/eagle.png\"}".toArray(), contentType: "application/json")
            } else {
                let body = imageRuntimeObj(request, "body")
                @Expect(imageRuntimeString(request, "url"), "http://127.0.0.1:8188/prompt")
                @Expect(imageRuntimeString(body, "promptText"), "draw an eagle")
                @Expect(imageRuntimeString(body, "promptNodeId"), "1")
                GatewayImageGenerationHttpResult(200, bodyBytes: "{\"prompt_id\":\"prompt-1\"}".toArray(), contentType: "application/json")
            }
        }))
        setGatewayImageGenerationDownloaderForTest(Some({ _url: String, _timeoutMs: Int64, _maxBytes: Int64, _providerConfig: JsonObject =>
            GatewayImageGenerationHttpResult(200, bodyBytes: "COMFY_IMAGE".toArray(), contentType: "image/png")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("comfy", provider, outputRoot: root), imageRuntimeRequest("draw an eagle"))
            let image = imageRuntimeArr(result, "images")[0].asObject()
            @Expect(imageRuntimeBool(result, "ok"), true)
            @Expect(imageRuntimeString(result, "providerKind"), "comfy-image")
            @Expect(String.fromUtf8(File.readFrom(Path(imageRuntimeString(image, "path")))), "COMFY_IMAGE")
        } finally {
            setGatewayImageGenerationComfyRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
            setGatewayImageGenerationDownloaderForTest(None<(String, Int64, Int64, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func comfyImageProviderPollFailureAndTimeoutAreStructured(): Unit {
        let root = imageRuntimeTempRoot("comfy-failure")
        let provider = imageRuntimeProviderKind("comfy-image", "workflow", "http://127.0.0.1:8188")
        let workflow = JsonObject()
        workflow.put("1", JsonObject())
        provider.put("workflow", workflow)
        provider.put("promptNodeId", JsonString("1"))
        provider.put("pollIntervalMs", JsonInt(0))
        setGatewayImageGenerationComfyRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            if (imageRuntimeString(request, "method") == "GET") {
                GatewayImageGenerationHttpResult(200, bodyBytes: "{\"status\":{\"status_str\":\"failed\"},\"message\":\"node failed\"}".toArray(), contentType: "application/json")
            } else {
                GatewayImageGenerationHttpResult(200, bodyBytes: "{\"prompt_id\":\"prompt-2\"}".toArray(), contentType: "application/json")
            }
        }))
        try {
            let failed = gatewayImageGenerationGenerate(imageRuntimeConfig("comfy", provider, outputRoot: root), imageRuntimeRequest("draw an eagle"))
            @Expect(imageRuntimeBool(failed, "ok"), false)
            @Expect(imageRuntimeString(failed, "status"), "provider_error")
            @Expect(imageRuntimeString(failed, "message").contains("node failed"), true)
        } finally {
            setGatewayImageGenerationComfyRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
        }

        let timeoutProvider = imageRuntimeProviderKind("comfy-image", "workflow", "http://127.0.0.1:8188")
        let timeoutWorkflow = JsonObject()
        timeoutWorkflow.put("1", JsonObject())
        timeoutProvider.put("workflow", timeoutWorkflow)
        timeoutProvider.put("promptNodeId", JsonString("1"))
        timeoutProvider.put("pollIntervalMs", JsonInt(0))
        timeoutProvider.put("pollMaxAttempts", JsonInt(1))
        setGatewayImageGenerationComfyRunnerForTest(Some({ request: JsonObject, _providerConfig: JsonObject =>
            if (imageRuntimeString(request, "method") == "GET") {
                GatewayImageGenerationHttpResult(200, bodyBytes: "{\"status\":{\"status_str\":\"running\"}}".toArray(), contentType: "application/json")
            } else {
                GatewayImageGenerationHttpResult(200, bodyBytes: "{\"prompt_id\":\"prompt-3\"}".toArray(), contentType: "application/json")
            }
        }))
        try {
            let timedOut = gatewayImageGenerationGenerate(imageRuntimeConfig("comfy", timeoutProvider, outputRoot: root), imageRuntimeRequest("draw an eagle"))
            @Expect(imageRuntimeBool(timedOut, "ok"), false)
            @Expect(imageRuntimeString(timedOut, "status"), "timeout")
        } finally {
            setGatewayImageGenerationComfyRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func dashScopeQwenImageRejectsReferenceImageBeforeProviderCall(): Unit {
        let root = imageRuntimeTempRoot("dashscope-reference")
        let ref = root.join("ref.png")
        File.writeTo(ref, "PNG".toArray())
        let request = imageRuntimeRequest("edit this image")
        request.put("referenceImage", JsonString(ref.toString()))
        let requests = ArrayList<String>()
        setGatewayImageGenerationDashScopeRunnerForTest(Some({ requestObj: JsonObject, _providerConfig: JsonObject =>
            requests.add(requestObj.toJsonString())
            GatewayImageGenerationHttpResult(200, bodyBytes: "{}".toArray(), contentType: "application/json")
        }))
        try {
            let result = gatewayImageGenerationGenerate(imageRuntimeConfig("dashscope", imageRuntimeDashScopeProvider(), outputRoot: root), request)

            @Expect(imageRuntimeBool(result, "ok"), false)
            @Expect(imageRuntimeString(result, "status"), "provider_unsupported")
            @Expect(imageRuntimeString(result, "providerKind"), "dashscope-qwen-image-generation")
            @Expect(imageRuntimeString(result, "message").contains("referenceImage"), true)
            @Expect(requests.size, 0)
        } finally {
            setGatewayImageGenerationDashScopeRunnerForTest(None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>)
        }
    }

    @TestCase
    public func providerRejectsUnsupportedReferenceImageWithoutNetwork(): Unit {
        let root = imageRuntimeTempRoot("reference-unsupported")
        let ref = root.join("ref.png")
        File.writeTo(ref, "PNG".toArray())
        let request = imageRuntimeRequest("edit this eagle")
        request.put("referenceImage", JsonString(ref.toString()))
        let provider = imageRuntimeProvider()
        provider.put("supportsEdit", JsonBool(false))

        let result = gatewayImageGenerationGenerate(imageRuntimeConfig("openai", provider, outputRoot: root), request)

        @Expect(imageRuntimeBool(result, "ok"), false)
        @Expect(imageRuntimeString(result, "status"), "provider_unsupported")
        @Expect(imageRuntimeString(result, "message").contains("referenceImage"), true)
    }

    @TestCase
    public func defaultOutputRootUsesMetisHome(): Unit {
        let testHome = imageRuntimeTempRoot("home").toString()
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", testHome)
        try {
            let config = imageRuntimeConfig("openai", imageRuntimeProvider(), outputRoot: Path("/tmp/metis-unused"))
            config.put("outputRoot", JsonString(""))
            let resolved = gatewayImageGenerationResolveOutputRoot(config)

            @Expect(resolved.toString().startsWith(Path(testHome).join("gateway-image-generation").toString()), true)
        } finally {
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            try { remove(Path(testHome), recursive: true) } catch (_: Exception) { () }
        }
    }
}
