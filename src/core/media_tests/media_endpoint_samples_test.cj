package metis.core.media_tests

import metis.core.*

import std.unittest.*

@Test
public class MediaEndpointSamplesTest {
    @TestCase
    public func endpointSamplesCoverRequiredClasses(): Unit {
        let samples = [
            ("https://api.openai.com/v1", "openai-public"),
            ("https://api.anthropic.com", "anthropic-public"),
            ("https://dashscope.aliyuncs.com/compatible-mode/v1", "modelstudio-compatible"),
            ("https://coding.dashscope.aliyuncs.com/v1", "modelstudio-coding"),
            ("https://dashscope.aliyuncs.com/api/v1", "dashscope-aigc-native"),
            ("https://openrouter.ai/api/v1", "openrouter"),
            ("https://generativelanguage.googleapis.com/v1beta", "google-generative-ai"),
            ("https://resource.openai.azure.com/openai/v1", "azure-openai"),
            ("http://localhost:11434/v1", "local"),
            ("https://example.invalid/v1", "custom")
        ]
        for (sample in samples) {
            @Expect(providerEndpointClassId(resolveProviderEndpoint("sample", sample[0]).endpointClass), sample[1])
        }
    }

    @TestCase
    public func redactionHelperRejectsCommonSecretShapes(): Unit {
        @Expect(mediaDiagnosticsLooksRedacted(redactProviderEndpoint("https://u:p@example.invalid/v1?token=secret")), true)
        @Expect(mediaDiagnosticsLooksRedacted("Authorization Bearer secret"), false)
    }
}
