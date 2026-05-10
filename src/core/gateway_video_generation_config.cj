package metis.core

import metis.core.config.GatewayUserSettings

import magic.jsonable.*
import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

private func videoConfigCloneValue(value: JsonValue): JsonValue {
    try {
        JsonValue.fromStr(value.toJsonString())
    } catch (_: Exception) {
        value
    }
}

private func videoConfigCloneObject(obj: JsonObject): JsonObject {
    try {
        JsonValue.fromStr(obj.toJsonString()).asObject()
    } catch (_: Exception) {
        JsonObject()
    }
}

private func videoConfigReadObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func videoConfigReadString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func videoConfigHasMeaningfulProviderConfig(config: JsonObject): Bool {
    if (!videoConfigReadString(config, "provider").isEmpty()) {
        return true
    }
    videoConfigReadObject(config, "providers").size() > 0
}

private func videoConfigDeepMerge(base: JsonObject, override: JsonObject): JsonObject {
    let out = videoConfigCloneObject(base)
    for ((key, overrideValue) in override.getFields()) {
        match (out.get(key)) {
            case Some(baseValue) =>
                let merged = try {
                    let baseObj = baseValue.asObject()
                    let overrideObj = overrideValue.asObject()
                    videoConfigDeepMerge(baseObj, overrideObj).toJsonValue()
                } catch (_: Exception) {
                    videoConfigCloneValue(overrideValue)
                }
                out.put(key, merged)
            case None =>
                out.put(key, videoConfigCloneValue(overrideValue))
        }
    }
    out
}

private func videoConfigChannelVideoGeneration(user: GatewayUserSettings, channel: String): JsonObject {
    let normalized = channel.trimAscii().toAsciiLower()
    match (normalized) {
        case "telegram" => return user.telegram.videoGeneration
        case "feishu" => return user.feishu.videoGeneration
        case "qq" => return user.qq.videoGeneration
        case _ => ()
    }
    match (user.channelsExtra) {
        case Some(extra) =>
            let channelObj = videoConfigReadObject(extra, normalized)
            videoConfigReadObject(channelObj, "videoGeneration")
        case None => JsonObject()
    }
}

private func videoConfigFinalize(config: JsonObject): JsonObject {
    let out = videoConfigCloneObject(config)
    if (videoConfigReadObject(out, "providers").size() == 0) {
        out.put("providers", JsonObject().toJsonValue())
    }
    out
}

private func videoConfigPutIfMissingString(obj: JsonObject, key: String, value: String): Unit {
    if (value.trimAscii().isEmpty()) {
        return
    }
    if (videoConfigReadString(obj, key).isEmpty()) {
        obj.put(key, JsonString(value.trimAscii()))
    }
}

private func videoConfigPutIfMissingBool(obj: JsonObject, key: String, value: Bool): Unit {
    if (obj.get(key).isNone()) {
        obj.put(key, JsonBool(value))
    }
}

private func videoConfigApplyTelegramTransportContext(config: JsonObject, user: GatewayUserSettings, channel: String): JsonObject {
    if (channel.trimAscii().toAsciiLower() != "telegram") {
        return config
    }
    let providers = videoConfigReadObject(config, "providers")
    for ((_, value) in providers.getFields()) {
        try {
            let provider = value.asObject()
            videoConfigPutIfMissingString(provider, "proxy", user.telegram.proxy)
            videoConfigPutIfMissingBool(provider, "envProxyEnabled", user.telegram.network.envProxyEnabled)
            videoConfigPutIfMissingBool(provider, "insecureSkipTlsVerify", user.telegram.network.insecureSkipTlsVerify)
        } catch (_: Exception) {
            ()
        }
    }
    config
}

public func gatewayMediaResolveVideoGenerationConfig(user: GatewayUserSettings, channel!: String = ""): JsonObject {
    let shared = videoConfigFinalize(user.media.videoGeneration)
    let channelConfig = videoConfigFinalize(videoConfigChannelVideoGeneration(user, channel))
    let hasShared = videoConfigHasMeaningfulProviderConfig(shared)
    let hasChannel = videoConfigHasMeaningfulProviderConfig(channelConfig)
    if (hasShared || hasChannel) {
        let merged = videoConfigDeepMerge(shared, channelConfig)
        merged.put("legacy", JsonBool(false))
        return videoConfigApplyTelegramTransportContext(merged, user, channel)
    }
    let out = JsonObject()
    out.put("providers", JsonObject().toJsonValue())
    out.put("legacy", JsonBool(false))
    videoConfigApplyTelegramTransportContext(out, user, channel)
}

public func gatewayVideoGenerationResolveConfig(user: GatewayUserSettings, channel!: String = ""): JsonObject {
    gatewayMediaResolveVideoGenerationConfig(user, channel: channel)
}
