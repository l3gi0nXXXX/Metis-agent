package metis.core.config

import stdx.encoding.json.JsonObject

public func clearStaleProviderAuthFieldsOnSwitch(config: JsonObject, targetProvider: String): JsonObject {
    let canonical = cliCanonicalModelProviderId(targetProvider)
    if (!modelProviderSwitchShouldClearAuth(canonical)) {
        return config
    }
    match (modelProviderSwitchObject(config, "models")) {
        case Some(models) =>
            match (modelProviderSwitchObject(models, "providers")) {
                case Some(providers) =>
                    match (modelProviderSwitchObject(providers, canonical)) {
                        case Some(provider) =>
                            providers.put(canonical, modelProviderSwitchProviderWithoutStaleAuth(provider))
                        case None => ()
                    }
                case None => ()
            }
        case None => ()
    }
    config
}

private func modelProviderSwitchShouldClearAuth(providerId: String): Bool {
    match (cliFindModelProviderDescriptor(providerId)) {
        case Some(descriptor) => descriptor.groupId != "custom"
        case None => false
    }
}

private func modelProviderSwitchObject(root: JsonObject, key: String): Option<JsonObject> {
    match (root.get(key)) {
        case Some(value) =>
            try {
                Some(value.asObject())
            } catch (_: Exception) {
                None
            }
        case None => None
    }
}

private func modelProviderSwitchProviderWithoutStaleAuth(provider: JsonObject): JsonObject {
    let out = JsonObject()
    for ((key, value) in provider.getFields()) {
        if (key == "apiKey" || key == "apiMode") {
            continue
        }
        out.put(key, value)
    }
    out
}
