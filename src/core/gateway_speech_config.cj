package metis.core

import metis.core.config.{GatewayChannelSpeechUserSettings, GatewayUserSettings}

import magic.jsonable.*
import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

private func speechCloneValue(value: JsonValue): JsonValue {
    try {
        JsonValue.fromStr(value.toJsonString())
    } catch (_: Exception) {
        value
    }
}

private func speechCloneObject(obj: JsonObject): JsonObject {
    try {
        JsonValue.fromStr(obj.toJsonString()).asObject()
    } catch (_: Exception) {
        JsonObject()
    }
}

private func speechReadObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func speechReadString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func speechHasMeaningfulProviderConfig(config: JsonObject): Bool {
    if (!speechReadString(config, "provider").isEmpty()) {
        return true
    }
    if (speechReadObject(config, "providers").size() > 0) {
        return true
    }
    match (config.get("command")) {
        case Some(_) => true
        case None => false
    }
}

private func speechDeepMerge(base: JsonObject, override: JsonObject): JsonObject {
    let out = speechCloneObject(base)
    for ((key, overrideValue) in override.getFields()) {
        match (out.get(key)) {
            case Some(baseValue) =>
                let merged = try {
                    let baseObj = baseValue.asObject()
                    let overrideObj = overrideValue.asObject()
                    speechDeepMerge(baseObj, overrideObj).toJsonValue()
                } catch (_: Exception) {
                    speechCloneValue(overrideValue)
                }
                out.put(key, merged)
            case None =>
                out.put(key, speechCloneValue(overrideValue))
        }
    }
    out
}

private func speechChannelSettings(user: GatewayUserSettings, channel: String): GatewayChannelSpeechUserSettings {
    match (channel.trimAscii().toAsciiLower()) {
        case "telegram" => user.telegram.speech
        case "feishu" => user.feishu.speech
        case "qq" => user.qq.speech
        case _ => GatewayChannelSpeechUserSettings()
    }
}

private func speechChannelConfig(user: GatewayUserSettings, channel: String, key: String): JsonObject {
    let settings = speechChannelSettings(user, channel)
    if (key == "asr") {
        return settings.asr
    }
    settings.tts
}

private func speechSharedConfig(user: GatewayUserSettings, key: String): JsonObject {
    if (key == "asr") {
        return user.speech.asr
    }
    user.speech.tts
}

private func speechNormalizeProviderMap(config: JsonObject): JsonObject {
    let providers = speechReadObject(config, "providers")
    if (providers.size() > 0) {
        return providers
    }
    let provider = speechReadString(config, "provider")
    if (provider.isEmpty()) {
        return JsonObject()
    }
    match (config.get("command")) {
        case Some(command) =>
            let row = JsonObject()
            row.put("kind", JsonString("command"))
            row.put("command", speechCloneValue(command))
            match (config.get("outputExtension")) {
                case Some(v) => row.put("outputExtension", speechCloneValue(v))
                case None => ()
            }
            match (config.get("timeoutMs")) {
                case Some(v) => row.put("timeoutMs", speechCloneValue(v))
                case None => ()
            }
            let out = JsonObject()
            out.put(provider, row)
            out
        case None => JsonObject()
    }
}

private func speechFinalizeProviderMap(config: JsonObject): JsonObject {
    let out = speechCloneObject(config)
    out.put("providers", speechNormalizeProviderMap(out).toJsonValue())
    out
}

private func speechLegacyTelegramTts(user: GatewayUserSettings): JsonObject {
    let extra = match (user.channelsExtra) {
        case Some(obj) => obj
        case None => JsonObject()
    }
    var legacy = speechReadObject(extra, "telegramTts")
    if (legacy.size() == 0) {
        legacy = speechReadObject(speechReadObject(extra, "telegram"), "telegramTts")
    }
    if (legacy.size() == 0) {
        return JsonObject()
    }
    let provider = speechReadString(legacy, "provider")
    let normalizedProvider = if (provider.isEmpty()) { "legacy-command" } else { provider }
    let out = speechCloneObject(legacy)
    out.put("provider", JsonString(normalizedProvider))
    out.put("legacy", JsonBool(true))
    out.put("migrationHint", JsonString("Move gateway.channelsExtra.telegramTts to gateway.telegram.speech.tts or gateway.speech.tts."))
    speechFinalizeProviderMap(out)
}

private func speechResolveConfig(user: GatewayUserSettings, channel: String, key: String): JsonObject {
    let shared = speechFinalizeProviderMap(speechSharedConfig(user, key))
    let channelConfig = speechFinalizeProviderMap(speechChannelConfig(user, channel, key))
    let hasShared = speechHasMeaningfulProviderConfig(shared)
    let hasChannel = speechHasMeaningfulProviderConfig(channelConfig)
    if (hasShared || hasChannel) {
        let merged = speechDeepMerge(shared, channelConfig)
        merged.put("legacy", JsonBool(false))
        return merged
    }
    if (key == "tts" && channel.trimAscii().toAsciiLower() == "telegram") {
        return speechLegacyTelegramTts(user)
    }
    let out = JsonObject()
    out.put("providers", JsonObject().toJsonValue())
    out.put("legacy", JsonBool(false))
    out
}

public func gatewaySpeechResolveTtsConfig(user: GatewayUserSettings, channel!: String = ""): JsonObject {
    speechResolveConfig(user, channel, "tts")
}

public func gatewaySpeechResolveAsrConfig(user: GatewayUserSettings, channel!: String = ""): JsonObject {
    speechResolveConfig(user, channel, "asr")
}

public func gatewaySpeechResolveDeliveryPrefs(user: GatewayUserSettings, channel!: String = ""): JsonObject {
    let out = JsonObject()
    let normalized = channel.trimAscii().toAsciiLower()
    match (user.channelsExtra) {
        case Some(extra) =>
            let speech = speechReadObject(speechReadObject(extra, normalized), "speech")
            for ((key, value) in speech.getFields()) {
                out.put(key, speechCloneValue(value))
            }
        case None => ()
    }
    let typed = speechChannelSettings(user, normalized)
    match (typed.audioAsVoice) {
        case Some(value) => out.put("audioAsVoice", JsonBool(value))
        case None => ()
    }
    match (typed.autoReplyToVoice) {
        case Some(value) => out.put("autoReplyToVoice", JsonBool(value))
        case None => ()
    }
    out
}
