package metis.core

import metis.core.config.GatewayUserSettings

import magic.jsonable.*
import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

private func mediaCloneValue(value: JsonValue): JsonValue {
    try {
        JsonValue.fromStr(value.toJsonString())
    } catch (_: Exception) {
        value
    }
}

private func mediaCloneObject(obj: JsonObject): JsonObject {
    try {
        JsonValue.fromStr(obj.toJsonString()).asObject()
    } catch (_: Exception) {
        JsonObject()
    }
}

private func mediaReadObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func mediaReadString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func mediaDeepMerge(base: JsonObject, override: JsonObject): JsonObject {
    let out = mediaCloneObject(base)
    for ((key, overrideValue) in override.getFields()) {
        match (out.get(key)) {
            case Some(baseValue) =>
                let merged = try {
                    mediaDeepMerge(baseValue.asObject(), overrideValue.asObject()).toJsonValue()
                } catch (_: Exception) {
                    mediaCloneValue(overrideValue)
                }
                out.put(key, merged)
            case None =>
                out.put(key, mediaCloneValue(overrideValue))
        }
    }
    out
}

private func mediaHasProviderConfig(config: JsonObject): Bool {
    !mediaReadString(config, "provider").trimAscii().isEmpty() ||
        mediaReadObject(config, "providers").size() > 0
}

private func mediaChannelVideoConfig(user: GatewayUserSettings, channel: String): JsonObject {
    match (channel.trimAscii().toAsciiLower()) {
        case "telegram" => user.telegram.video
        case "feishu" => user.feishu.video
        case "qq" => user.qq.video
        case _ => JsonObject()
    }
}

public func gatewayMediaResolveVideoConfig(user: GatewayUserSettings, channel!: String = ""): JsonObject {
    let shared = mediaCloneObject(user.media.video)
    let channelConfig = mediaCloneObject(mediaChannelVideoConfig(user, channel))
    if (mediaHasProviderConfig(shared) || mediaHasProviderConfig(channelConfig)) {
        let merged = mediaDeepMerge(shared, channelConfig)
        if (merged.get("enabled").isNone()) {
            merged.put("enabled", JsonBool(true))
        }
        if (merged.get("providers").isNone()) {
            merged.put("providers", JsonObject())
        }
        merged.put("legacy", JsonBool(false))
        return merged
    }
    let out = JsonObject()
    out.put("providers", JsonObject())
    out.put("legacy", JsonBool(false))
    out
}
