package metis.core

import metis.core.config.GatewayUserSettings

import magic.jsonable.*
import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

private func imageConfigCloneValue(value: JsonValue): JsonValue {
    try {
        JsonValue.fromStr(value.toJsonString())
    } catch (_: Exception) {
        value
    }
}

private func imageConfigCloneObject(obj: JsonObject): JsonObject {
    try {
        JsonValue.fromStr(obj.toJsonString()).asObject()
    } catch (_: Exception) {
        JsonObject()
    }
}

private func imageConfigReadObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func imageConfigReadString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func imageConfigHasMeaningfulProviderConfig(config: JsonObject): Bool {
    if (!imageConfigReadString(config, "provider").isEmpty()) {
        return true
    }
    imageConfigReadObject(config, "providers").size() > 0
}

private func imageConfigDeepMerge(base: JsonObject, override: JsonObject): JsonObject {
    let out = imageConfigCloneObject(base)
    for ((key, overrideValue) in override.getFields()) {
        match (out.get(key)) {
            case Some(baseValue) =>
                let merged = try {
                    let baseObj = baseValue.asObject()
                    let overrideObj = overrideValue.asObject()
                    imageConfigDeepMerge(baseObj, overrideObj).toJsonValue()
                } catch (_: Exception) {
                    imageConfigCloneValue(overrideValue)
                }
                out.put(key, merged)
            case None =>
                out.put(key, imageConfigCloneValue(overrideValue))
        }
    }
    out
}

private func imageConfigChannelImageGeneration(user: GatewayUserSettings, channel: String): JsonObject {
    let normalized = channel.trimAscii().toAsciiLower()
    match (normalized) {
        case "telegram" => return user.telegram.imageGeneration
        case "feishu" => return user.feishu.imageGeneration
        case "qq" => return user.qq.imageGeneration
        case _ => ()
    }
    match (user.channelsExtra) {
        case Some(extra) =>
            let channelObj = imageConfigReadObject(extra, normalized)
            imageConfigReadObject(channelObj, "imageGeneration")
        case None => JsonObject()
    }
}

private func imageConfigFinalize(config: JsonObject): JsonObject {
    let out = imageConfigCloneObject(config)
    if (imageConfigReadObject(out, "providers").size() == 0) {
        out.put("providers", JsonObject().toJsonValue())
    }
    out
}

private func imageConfigPutIfMissingString(obj: JsonObject, key: String, value: String): Unit {
    let normalized = value.trimAscii()
    if (normalized.isEmpty()) {
        return
    }
    if (imageConfigReadString(obj, key).isEmpty()) {
        obj.put(key, JsonString(normalized))
    }
}

private func imageConfigPutIfMissingBool(obj: JsonObject, key: String, value: Bool): Unit {
    if (obj.get(key).isNone()) {
        obj.put(key, JsonBool(value))
    }
}

private func imageConfigApplyTelegramTransportContext(config: JsonObject, user: GatewayUserSettings, channel: String): JsonObject {
    if (channel.trimAscii().toAsciiLower() != "telegram") {
        return config
    }
    let providers = imageConfigReadObject(config, "providers")
    for ((_, value) in providers.getFields()) {
        try {
            let provider = value.asObject()
            imageConfigPutIfMissingString(provider, "proxy", user.telegram.proxy)
            imageConfigPutIfMissingBool(provider, "envProxyEnabled", user.telegram.network.envProxyEnabled)
            imageConfigPutIfMissingBool(provider, "insecureSkipTlsVerify", user.telegram.network.insecureSkipTlsVerify)
        } catch (_: Exception) {
            ()
        }
    }
    config
}

public func gatewayMediaResolveImageGenerationConfig(user: GatewayUserSettings, channel!: String = ""): JsonObject {
    let shared = imageConfigFinalize(user.media.imageGeneration)
    let channelConfig = imageConfigFinalize(imageConfigChannelImageGeneration(user, channel))
    let hasShared = imageConfigHasMeaningfulProviderConfig(shared)
    let hasChannel = imageConfigHasMeaningfulProviderConfig(channelConfig)
    if (hasShared || hasChannel) {
        let merged = imageConfigDeepMerge(shared, channelConfig)
        merged.put("legacy", JsonBool(false))
        return imageConfigApplyTelegramTransportContext(merged, user, channel)
    }
    let out = JsonObject()
    out.put("providers", JsonObject().toJsonValue())
    out.put("legacy", JsonBool(false))
    imageConfigApplyTelegramTransportContext(out, user, channel)
}

public func gatewayImageGenerationResolveConfig(user: GatewayUserSettings, channel!: String = ""): JsonObject {
    gatewayMediaResolveImageGenerationConfig(user, channel: channel)
}
