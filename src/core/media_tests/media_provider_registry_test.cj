package metis.core.media_tests

import metis.core.*

import std.unittest.*

@Test
public class MediaProviderRegistryTest {
    @TestCase
    public func resolvesCanonicalProvidersAndAliases(): Unit {
        @Expect(mediaCanonicalProviderId("openai-qwen-image"), "openai-images")
        @Expect(mediaCanonicalProviderId("qwen-tts"), "dashscope-qwen-tts")
        @Expect(mediaCanonicalProviderId("missing-provider"), "missing-provider")
    }

    @TestCase
    public func checksCapabilitiesWithoutCallingAdapters(): Unit {
        @Expect(mediaProviderSupportsCapability("openai-qwen-image", ImageGenerate), true)
        @Expect(mediaProviderSupportsCapability("openai-qwen-image", VideoGenerate), false)
        @Expect(mediaProviderSupportsCapability("qwen-video", VideoGenerate), true)
        @Expect(mediaCapabilityId(AudioTts), "audio.tts")
    }

    @TestCase
    public func descriptorsExposeEndpointClasses(): Unit {
        let classes = mediaProviderAcceptedEndpointClasses("dashscope-qwen-image-generation")
        var sawNative = false
        var sawCompatible = false
        for (item in classes) {
            if (providerEndpointClassId(item) == "dashscope-aigc-native") {
                sawNative = true
            }
            if (providerEndpointClassId(item) == "modelstudio-compatible") {
                sawCompatible = true
            }
        }
        @Expect(sawNative, true)
        @Expect(sawCompatible, false)
    }
}
