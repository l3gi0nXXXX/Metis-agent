package metis.core

import std.collection.ArrayList

public enum MediaCapability {
    | ImageGenerate
    | ImageEdit
    | ImageUnderstand
    | VideoGenerate
    | VideoUnderstand
    | AudioAsr
    | AudioTts
    | FileSave
    | FileSend
}

public struct MediaProviderDescriptor {
    public MediaProviderDescriptor(
        public let providerId: String,
        public let kind: String,
        public let aliases: Array<String>,
        public let capabilities: Array<MediaCapability>,
        public let defaultBaseUrl: String,
        public let acceptedEndpointClasses: Array<ProviderEndpointClass>
    ) {}
}

private let MEDIA_PROVIDER_DESCRIPTORS = [
    MediaProviderDescriptor("openai-images", "openai-images", ["openai", "openai-compatible", "openai-qwen-image"], [ImageGenerate, ImageEdit], "https://api.openai.com/v1", [OpenAiPublic, OpenAiCompatibleCustom, ModelStudioCompatible, OpenRouter, Local, Custom]),
    MediaProviderDescriptor("dashscope-qwen-image", "dashscope-qwen-image-generation", ["dashscope-qwen-image-generation", "qwen-image-native"], [ImageGenerate], "https://dashscope.aliyuncs.com/api/v1", [DashScopeAigcNative, ModelStudioCompatible, ModelStudioCoding, OpenAiCompatibleCustom, Custom]),
    MediaProviderDescriptor("google-image", "google-image-generation", ["gemini-image", "google"], [ImageGenerate, ImageUnderstand], "https://generativelanguage.googleapis.com/v1beta", [GoogleGenerativeAi, Custom]),
    MediaProviderDescriptor("minimax-image", "minimax-image-generation", ["minimax"], [ImageGenerate], "https://api.minimax.io", [Custom]),
    MediaProviderDescriptor("fal-image", "fal-image-generation", ["fal"], [ImageGenerate], "https://fal.run", [Custom]),
    MediaProviderDescriptor("vydra-image", "vydra-image-generation", ["vydra"], [ImageGenerate], "https://www.vydra.ai/api/v1", [Custom]),
    MediaProviderDescriptor("comfy-image", "comfy-image-generation", ["comfy", "comfyui"], [ImageGenerate, ImageEdit], "http://127.0.0.1:8188", [Local, Custom]),
    MediaProviderDescriptor("dashscope-qwen-video", "dashscope-qwen-video-generation", ["qwen-video", "wan", "dashscope-video"], [VideoGenerate], "https://dashscope.aliyuncs.com", [DashScopeAigcNative, ModelStudioCompatible, ModelStudioCoding]),
    MediaProviderDescriptor("openai-video", "openai-video-generation", ["openai-video"], [VideoGenerate], "https://api.openai.com/v1", [OpenAiPublic, OpenAiCompatibleCustom, Local, Custom]),
    MediaProviderDescriptor("google-video", "google-video-generation", ["google-video", "veo"], [VideoGenerate, VideoUnderstand], "https://generativelanguage.googleapis.com/v1beta", [GoogleGenerativeAi, Custom]),
    MediaProviderDescriptor("qwen-video-understanding", "qwen-vl-video", ["qwen-vl-video"], [VideoUnderstand], "https://dashscope.aliyuncs.com/compatible-mode/v1", [ModelStudioCompatible, OpenAiCompatibleCustom, OpenRouter, Local, Custom]),
    MediaProviderDescriptor("openai-asr", "openai-compatible-asr", ["openai-asr", "whisper"], [AudioAsr], "https://api.openai.com/v1", [OpenAiPublic, OpenAiCompatibleCustom, OpenRouter, Local, Custom]),
    MediaProviderDescriptor("openai-tts", "openai-compatible-tts", ["openai-tts"], [AudioTts], "https://api.openai.com/v1", [OpenAiPublic, OpenAiCompatibleCustom, Local, Custom]),
    MediaProviderDescriptor("dashscope-qwen-tts", "dashscope-qwen-tts", ["qwen-tts", "dashscope-tts"], [AudioTts], "https://dashscope.aliyuncs.com/api/v1", [DashScopeAigcNative]),
    MediaProviderDescriptor("metis-file", "metis-file", ["file", "local-file"], [FileSave, FileSend], "", [Local, Custom])
]

private func mediaProviderNormalize(input: String): String {
    input.trimAscii().toAsciiLower()
}

private func mediaProviderContainsCapability(items: Array<MediaCapability>, capability: MediaCapability): Bool {
    let expected = mediaCapabilityId(capability)
    for (item in items) {
        if (mediaCapabilityId(item) == expected) {
            return true
        }
    }
    false
}

public func mediaCapabilityId(capability: MediaCapability): String {
    match (capability) {
        case ImageGenerate => "image.generate"
        case ImageEdit => "image.edit"
        case ImageUnderstand => "image.understand"
        case VideoGenerate => "video.generate"
        case VideoUnderstand => "video.understand"
        case AudioAsr => "audio.asr"
        case AudioTts => "audio.tts"
        case FileSave => "file.save"
        case FileSend => "file.send"
    }
}

public func mediaProviderCatalogDescriptors(): Array<MediaProviderDescriptor> {
    MEDIA_PROVIDER_DESCRIPTORS
}

public func mediaFindProviderDescriptor(providerIdOrKind: String): Option<MediaProviderDescriptor> {
    let normalized = mediaProviderNormalize(providerIdOrKind)
    if (normalized.isEmpty()) {
        return None<MediaProviderDescriptor>
    }
    for (descriptor in MEDIA_PROVIDER_DESCRIPTORS) {
        if (descriptor.providerId == normalized || descriptor.kind == normalized) {
            return Some(descriptor)
        }
        for (alias in descriptor.aliases) {
            if (alias == normalized) {
                return Some(descriptor)
            }
        }
    }
    None<MediaProviderDescriptor>
}

public func mediaCanonicalProviderId(providerIdOrKind: String): String {
    match (mediaFindProviderDescriptor(providerIdOrKind)) {
        case Some(descriptor) => descriptor.providerId
        case None => mediaProviderNormalize(providerIdOrKind)
    }
}

public func mediaProviderSupportsCapability(providerIdOrKind: String, capability: MediaCapability): Bool {
    match (mediaFindProviderDescriptor(providerIdOrKind)) {
        case Some(descriptor) => mediaProviderContainsCapability(descriptor.capabilities, capability)
        case None => false
    }
}

public func mediaProviderAcceptedEndpointClasses(providerIdOrKind: String): Array<ProviderEndpointClass> {
    match (mediaFindProviderDescriptor(providerIdOrKind)) {
        case Some(descriptor) => descriptor.acceptedEndpointClasses
        case None => Array<ProviderEndpointClass>()
    }
}

public func mediaProviderDescriptorsForCapability(capability: MediaCapability): Array<MediaProviderDescriptor> {
    let out = ArrayList<MediaProviderDescriptor>()
    for (descriptor in MEDIA_PROVIDER_DESCRIPTORS) {
        if (mediaProviderContainsCapability(descriptor.capabilities, capability)) {
            out.add(descriptor)
        }
    }
    out.toArray()
}
