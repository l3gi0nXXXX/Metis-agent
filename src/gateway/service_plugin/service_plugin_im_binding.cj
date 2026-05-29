package metis.gateway.service_plugin

import metis.core.config.GatewayUserSettings

import std.collection.ArrayList
import stdx.encoding.json.JsonObject

public class ServicePluginImBindingRule {
    public let pluginId: String
    public let channel: String
    public let accountId: String
    public let commandPrefix: String
    public let scopes: Array<String>
    public let enabled: Bool

    public init(
        pluginId: String,
        channel: String,
        accountId: String,
        commandPrefix: String,
        scopes!: Array<String> = [],
        enabled!: Bool = true
    ) {
        this.pluginId = pluginId.trimAscii()
        this.channel = servicePluginImNormalizeChannel(channel)
        this.accountId = servicePluginImNormalizeAccountId(this.channel, accountId)
        this.commandPrefix = commandPrefix.trimAscii()
        this.scopes = servicePluginImNormalizeScopes(scopes)
        this.enabled = enabled
    }
}

public class ServicePluginImDispatchMatch {
    public let matched: Bool
    public let pluginId: String
    public let channel: String
    public let accountId: String
    public let commandPrefix: String
    public let commandText: String
    public let reason: String
    public let prefixMatched: Bool

    public init(
        matched: Bool,
        pluginId!: String = "",
        channel!: String = "",
        accountId!: String = "",
        commandPrefix!: String = "",
        commandText!: String = "",
        reason!: String = "",
        prefixMatched!: Bool = false
    ) {
        this.matched = matched
        this.pluginId = pluginId.trimAscii()
        this.channel = servicePluginImNormalizeChannel(channel)
        this.accountId = servicePluginImNormalizeAccountId(this.channel, accountId)
        this.commandPrefix = commandPrefix.trimAscii()
        this.commandText = commandText
        this.reason = reason.trimAscii()
        this.prefixMatched = prefixMatched
    }
}

private func servicePluginImJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func servicePluginImJsonStringArray(obj: JsonObject, key: String): Array<String> {
    let out = ArrayList<String>()
    match (obj.get(key)) {
        case Some(v) =>
            try {
                let arr = v.asArray()
                for (item in arr.getItems()) {
                    try {
                        let text = item.asString().getValue().trimAscii()
                        if (!text.isEmpty()) {
                            out.add(text)
                        }
                    } catch (_: Exception) {
                        ()
                    }
                }
            } catch (_: Exception) {
                ()
            }
        case None => ()
    }
    out.toArray()
}

private func servicePluginImNormalizeChannel(raw: String): String {
    raw.trimAscii().toAsciiLower()
}

public func servicePluginImNormalizeAccountId(channel: String, raw: String): String {
    let normalizedChannel = servicePluginImNormalizeChannel(channel)
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty()) {
        return "default"
    }
    let lower = trimmed.toAsciiLower()
    let prefix = "${normalizedChannel}:"
    if (!normalizedChannel.isEmpty() && lower.startsWith(prefix)) {
        let suffix = trimmed[prefix.size..].trimAscii()
        if (suffix.isEmpty()) {
            return "default"
        }
        return suffix.toAsciiLower()
    }
    lower
}

private func servicePluginImNormalizeScopes(scopes: Array<String>): Array<String> {
    let out = ArrayList<String>()
    for (scope in scopes) {
        let normalized = scope.trimAscii().toAsciiLower()
        if (!normalized.isEmpty()) {
            out.add(normalized)
        }
    }
    out.toArray()
}

private func servicePluginImBindingTextMatchesPrefix(text: String, prefix: String): Bool {
    let command = text.trimAscii()
    let normalizedPrefix = prefix.trimAscii()
    if (command.isEmpty() || normalizedPrefix.isEmpty()) {
        return false
    }
    command == normalizedPrefix || command.startsWith("${normalizedPrefix} ")
}

public func buildServicePluginImBindingRules(user: GatewayUserSettings): Array<ServicePluginImBindingRule> {
    let out = ArrayList<ServicePluginImBindingRule>()
    for (plugin in user.servicePlugins) {
        let pluginId = plugin.pluginId.trimAscii()
        if (pluginId.isEmpty()) {
            continue
        }
        let bindings = plugin.imBindings
        for (rawChannel in bindings.getFields().keys()) {
            let channel = servicePluginImNormalizeChannel(rawChannel)
            if (channel.isEmpty()) {
                continue
            }
            let obj = match (bindings.get(rawChannel)) {
                case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
                case None => JsonObject()
            }
            let accountId = servicePluginImJsonString(obj, "accountId")
            let commandPrefix = servicePluginImJsonString(obj, "commandPrefix")
            let scopes = servicePluginImJsonStringArray(obj, "scopes")
            out.add(ServicePluginImBindingRule(pluginId, channel, accountId, commandPrefix, scopes: scopes, enabled: plugin.enabled))
        }
    }
    out.toArray()
}

public func matchServicePluginImBinding(
    rules: Array<ServicePluginImBindingRule>,
    channel: String,
    accountId: String,
    text: String
): ServicePluginImDispatchMatch {
    let normalizedChannel = servicePluginImNormalizeChannel(channel)
    let normalizedAccount = servicePluginImNormalizeAccountId(normalizedChannel, accountId)
    var disabledCandidate = None<ServicePluginImBindingRule>
    let enabledMatches = ArrayList<ServicePluginImBindingRule>()
    var sawChannelAccount = false
    var sawPrefixCandidate = false

    for (rule in rules) {
        if (rule.channel != normalizedChannel) {
            continue
        }
        if (rule.accountId != normalizedAccount) {
            continue
        }
        sawChannelAccount = true
        if (rule.commandPrefix.isEmpty()) {
            continue
        }
        if (!servicePluginImBindingTextMatchesPrefix(text, rule.commandPrefix)) {
            continue
        }
        sawPrefixCandidate = true
        if (!rule.enabled) {
            disabledCandidate = Some(rule)
            continue
        }
        enabledMatches.add(rule)
    }

    if (enabledMatches.size > 1) {
        let first = enabledMatches[0]
        return ServicePluginImDispatchMatch(
            false,
            pluginId: first.pluginId,
            channel: normalizedChannel,
            accountId: normalizedAccount,
            commandPrefix: first.commandPrefix,
            commandText: text,
            reason: "binding_conflict",
            prefixMatched: true
        )
    }
    if (enabledMatches.size == 1) {
        let rule = enabledMatches[0]
        return ServicePluginImDispatchMatch(
            true,
            pluginId: rule.pluginId,
            channel: normalizedChannel,
            accountId: normalizedAccount,
            commandPrefix: rule.commandPrefix,
            commandText: text,
            reason: "matched",
            prefixMatched: true
        )
    }
    match (disabledCandidate) {
        case Some(rule) =>
            return ServicePluginImDispatchMatch(
                false,
                pluginId: rule.pluginId,
                channel: normalizedChannel,
                accountId: normalizedAccount,
                commandPrefix: rule.commandPrefix,
                commandText: text,
                reason: "plugin_disabled",
                prefixMatched: true
            )
        case None => ()
    }
    ServicePluginImDispatchMatch(
        false,
        channel: normalizedChannel,
        accountId: normalizedAccount,
        commandText: text,
        reason: if (sawPrefixCandidate) {
            "no_enabled_binding"
        } else if (sawChannelAccount) {
            "prefix_not_matched"
        } else {
            "binding_not_found"
        },
        prefixMatched: false
    )
}
