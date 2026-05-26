package metis.core.media_tests

import metis.core.*

import std.unittest.*

@Test
public class ProviderEndpointResolutionTest {
    @TestCase
    public func classifiesPublicAndCompatibleEndpoints(): Unit {
        @Expect(providerEndpointClassId(resolveProviderEndpoint("openai", "https://api.openai.com/v1/").endpointClass), "openai-public")
        @Expect(providerEndpointClassId(resolveProviderEndpoint("qwen", "https://dashscope.aliyuncs.com/compatible-mode/v1").endpointClass), "modelstudio-compatible")
        @Expect(providerEndpointClassId(resolveProviderEndpoint("qwen", "https://coding.dashscope.aliyuncs.com/v1").endpointClass), "modelstudio-coding")
        @Expect(providerEndpointClassId(resolveProviderEndpoint("openrouter", "https://openrouter.ai/api/v1").endpointClass), "openrouter")
        @Expect(providerEndpointClassId(resolveProviderEndpoint("anthropic", "https://api.anthropic.com").endpointClass), "anthropic-public")
    }

    @TestCase
    public func classifiesGoogleAzureLocalAndCustom(): Unit {
        @Expect(providerEndpointClassId(resolveProviderEndpoint("google", "https://generativelanguage.googleapis.com").endpointClass), "google-generative-ai")
        @Expect(providerEndpointClassId(resolveProviderEndpoint("azure", "https://metis-test.openai.azure.com/openai/v1").endpointClass), "azure-openai")
        @Expect(providerEndpointClassId(resolveProviderEndpoint("local", "http://127.0.0.1:8000/v1/").endpointClass), "local")
        @Expect(providerEndpointClassId(resolveProviderEndpoint("custom", "https://token-plan.cn-beijing.maas.aliyuncs.com/v1").endpointClass), "custom")
        @Expect(providerEndpointClassId(resolveProviderEndpoint("qwen", "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1").endpointClass), "openai-compatible-custom")
    }

    @TestCase
    public func normalizationDoesNotAppendBusinessPaths(): Unit {
        let resolution = resolveProviderEndpoint("qwen", " https://dashscope.aliyuncs.com/compatible-mode/v1/?token=secret#frag ")
        @Expect(resolution.normalizedBaseUrl, "https://dashscope.aliyuncs.com/compatible-mode/v1")
        @Expect(resolution.chatCompletionsUrl, "")
        @Expect(resolution.imagesGenerationsUrl, "")
        @Expect(resolution.audioSpeechUrl, "")
        @Expect(resolution.videoGenerationsUrl, "")
    }

    @TestCase
    public func resolvesDashScopeVideoAigcOriginOnlyForVideoAdapters(): Unit {
        @Expect(resolveDashScopeAigcOriginForVideo("https://dashscope.aliyuncs.com/compatible-mode/v1"), "https://dashscope.aliyuncs.com")
        @Expect(resolveDashScopeAigcOriginForVideo("https://coding-intl.dashscope.aliyuncs.com/v1"), "https://dashscope-intl.aliyuncs.com")
        @Expect(resolveDashScopeAigcOriginForVideo("https://token-plan.cn-beijing.maas.aliyuncs.com/v1"), "https://token-plan.cn-beijing.maas.aliyuncs.com/v1")
    }

    @TestCase
    public func resolvesDashScopeImageAigcBaseUrlFromCompatibleAndNativeInputs(): Unit {
        @Expect(resolveDashScopeAigcBaseUrlForImage("https://dashscope.aliyuncs.com/compatible-mode/v1"), "https://dashscope.aliyuncs.com/api/v1")
        @Expect(resolveDashScopeAigcBaseUrlForImage("https://dashscope-intl.aliyuncs.com/compatible-mode/v1"), "https://dashscope-intl.aliyuncs.com/api/v1")
        @Expect(resolveDashScopeAigcBaseUrlForImage("https://coding.dashscope.aliyuncs.com/v1"), "https://dashscope.aliyuncs.com/api/v1")
        @Expect(resolveDashScopeAigcBaseUrlForImage("https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"), "https://token-plan.cn-beijing.maas.aliyuncs.com/api/v1")
        @Expect(resolveDashScopeAigcBaseUrlForImage("https://token-plan.cn-beijing.maas.aliyuncs.com/api/v1"), "https://token-plan.cn-beijing.maas.aliyuncs.com/api/v1")
    }

    @TestCase
    public func invalidInputsRemainDiagnosable(): Unit {
        @Expect(providerEndpointClassId(resolveProviderEndpoint("openai", "").endpointClass), "invalid")
        @Expect(resolveProviderEndpoint("openai", "").reason, "empty_base_url")
        @Expect(providerEndpointClassId(resolveProviderEndpoint("openai", "not a url").endpointClass), "invalid")
    }
}
