package metis.gateway.core

import std.regex.Regex
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString, JsonValue}

public class GatewayAcpConversationBinding {
    public let found: Bool
    public let agentId: String
    public let channel: String
    public let accountId: String
    public let peerKind: String
    public let peerId: String
    public let sessionKey: String
    public let mode: String
    public let lifecycle: String
    public let ready: Bool
    public let reset: Bool
    public let matchedBy: String
    public let binding: JsonObject

    public init(
        found: Bool,
        agentId!: String = "",
        channel!: String = "",
        accountId!: String = "",
        peerKind!: String = "",
        peerId!: String = "",
        sessionKey!: String = "",
        mode!: String = "",
        lifecycle!: String = "",
        ready!: Bool = false,
        reset!: Bool = false,
        matchedBy!: String = "",
        binding!: JsonObject = JsonObject()
    ) {
        this.found = found
        this.agentId = agentId
        this.channel = channel
        this.accountId = accountId
        this.peerKind = peerKind
        this.peerId = peerId
        this.sessionKey = sessionKey
        this.mode = mode
        this.lifecycle = lifecycle
        this.ready = ready
        this.reset = reset
        this.matchedBy = matchedBy
        this.binding = binding
    }
}

private func gatewayAcpToken(raw: String): String {
    raw.trimAscii().toAsciiLower()
}

private func gatewayAcpSanitizeId(raw: String): String {
    let value = raw.trimAscii().toAsciiLower().replace("/", "_").replace("\\", "_").replace("..", "_").replace(":", "_")
    if (value.isEmpty()) {
        return "main"
    }
    value
}

private func gatewayAcpBlockedAccountKey(value: String): Bool {
    value == "__proto__" || value == "prototype" || value == "constructor"
}

private func gatewayAcpNormalizeAccountId(raw: String): String {
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty()) {
        return "default"
    }
    var value = Regex("[^a-z0-9_-]+").replaceAll(trimmed.toAsciiLower(), "-")
    value = Regex("^-+").replaceAll(value, "")
    value = Regex("-+$").replaceAll(value, "")
    if (value.size > 64) {
        value = value[..64]
    }
    if (value.isEmpty() || gatewayAcpBlockedAccountKey(value)) {
        return "default"
    }
    value
}

private func gatewayAcpNormalizeAccountPattern(raw: String): String {
    let trimmed = raw.trimAscii()
    if (trimmed == "*") {
        return "*"
    }
    gatewayAcpNormalizeAccountId(trimmed)
}

private func gatewayAcpJsonString(obj: JsonObject, key: String, fallback!: String = ""): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_e: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayAcpJsonBool(obj: JsonObject, key: String, fallback!: Bool = false): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_e: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayAcpJsonObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_e: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func gatewayAcpJsonArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_e: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func gatewayAcpCloneValue(value: JsonValue): JsonValue {
    try {
        JsonValue.fromStr(value.toJsonString())
    } catch (_e: Exception) {
        value
    }
}

private func gatewayAcpCloneObject(obj: JsonObject): JsonObject {
    try {
        JsonValue.fromStr(obj.toJsonString()).asObject()
    } catch (_e: Exception) {
        JsonObject()
    }
}

private func gatewayAcpChannelDefaultAccount(root: JsonObject, channel: String, explicitDefault: String): String {
    if (!explicitDefault.trimAscii().isEmpty()) {
        return gatewayAcpNormalizeAccountId(explicitDefault)
    }
    let channels = gatewayAcpJsonObject(root, "channels")
    let channelObj = gatewayAcpJsonObject(channels, channel)
    let configuredDefault = gatewayAcpJsonString(channelObj, "defaultAccountId")
    if (!configuredDefault.isEmpty()) {
        return gatewayAcpNormalizeAccountId(configuredDefault)
    }
    let accounts = gatewayAcpJsonArray(channelObj, "accountIds")
    if (accounts.size() > 0) {
        try {
            let first = accounts[0].asString().getValue().trimAscii()
            if (!first.isEmpty()) {
                return gatewayAcpNormalizeAccountId(first)
            }
        } catch (_e: Exception) {
            ()
        }
    }
    "default"
}

private func gatewayAcpBindingType(binding: JsonObject): String {
    gatewayAcpJsonString(binding, "type").toAsciiLower()
}

private func gatewayAcpBindingEnabled(binding: JsonObject): Bool {
    gatewayAcpJsonBool(binding, "enabled", fallback: true)
}

private func gatewayAcpBindingMatch(binding: JsonObject): JsonObject {
    gatewayAcpJsonObject(binding, "match")
}

private func gatewayAcpBindingAccountPattern(matchObj: JsonObject, defaultAccountId: String): (String, Bool) {
    let raw = gatewayAcpJsonString(matchObj, "accountId")
    if (raw.isEmpty()) {
        return (defaultAccountId, false)
    }
    let normalized = gatewayAcpNormalizeAccountPattern(raw)
    if (normalized == "*") {
        return ("*", true)
    }
    if (normalized == "default") {
        return (defaultAccountId, true)
    }
    (normalized, true)
}

private func gatewayAcpAccountMatches(pattern: String, accountId: String): Bool {
    pattern == "*" || pattern == accountId
}

private func gatewayAcpMode(acp: JsonObject): String {
    let mode = gatewayAcpJsonString(acp, "mode").toAsciiLower()
    if (mode == "oneshot") {
        return "oneshot"
    }
    "persistent"
}

private func gatewayAcpLifecycle(ready: Bool, reset: Bool): String {
    if (reset) {
        return "reset"
    }
    if (ready) {
        return "ready"
    }
    "waiting"
}

public func gatewayAcpConversationSessionKey(
    agentId: String,
    channel: String,
    accountId: String,
    peerKind: String,
    peerId: String
): String {
    "acp:${gatewayAcpSanitizeId(agentId)}:${gatewayAcpToken(channel)}:${gatewayAcpNormalizeAccountId(accountId)}:${gatewayAcpToken(peerKind)}:${peerId.trimAscii()}"
}

private func gatewayAcpBindingResolution(
    binding: JsonObject,
    channel: String,
    accountId: String,
    peerKind: String,
    peerId: String
): GatewayAcpConversationBinding {
    let matchObj = gatewayAcpBindingMatch(binding)
    let peer = gatewayAcpJsonObject(matchObj, "peer")
    let bindingPeerKind = gatewayAcpToken(gatewayAcpJsonString(peer, "kind"))
    let bindingPeerId = gatewayAcpJsonString(peer, "id")
    if (bindingPeerKind.isEmpty() || bindingPeerId.isEmpty() || bindingPeerId == "*") {
        return GatewayAcpConversationBinding(false)
    }
    let agentId = gatewayAcpSanitizeId(gatewayAcpJsonString(binding, "agentId"))
    let acp = gatewayAcpJsonObject(binding, "acp")
    let ready = gatewayAcpJsonBool(acp, "ready", fallback: true)
    let reset = gatewayAcpJsonBool(acp, "reset", fallback: false)
    let mode = gatewayAcpMode(acp)
    GatewayAcpConversationBinding(
        true,
        agentId: agentId,
        channel: channel,
        accountId: accountId,
        peerKind: bindingPeerKind,
        peerId: bindingPeerId,
        sessionKey: gatewayAcpConversationSessionKey(agentId, channel, accountId, bindingPeerKind, bindingPeerId),
        mode: mode,
        lifecycle: gatewayAcpLifecycle(ready, reset),
        ready: ready,
        reset: reset,
        matchedBy: if (bindingPeerKind == peerKind && bindingPeerId == peerId) {
            "acp.binding.peer.exact"
        } else {
            "acp.binding.configured"
        },
        binding: gatewayAcpCloneObject(binding)
    )
}

public func gatewayResolveAcpConversationBinding(input: GatewayAgentRouteInput): GatewayAcpConversationBinding {
    let defaultAccountId = gatewayAcpChannelDefaultAccount(input.root, input.channel, input.defaultAccountId)
    let normalizedInputAccount = gatewayAcpNormalizeAccountId(input.accountId)
    let accountId = if (normalizedInputAccount == "default") {
        defaultAccountId
    } else {
        normalizedInputAccount
    }
    let bindings = gatewayAcpJsonArray(input.root, "bindings")
    for (i in 0..bindings.size()) {
        let binding = try { bindings[i].asObject() } catch (_e: Exception) { JsonObject() }
        if (gatewayAcpBindingType(binding) != "acp" || !gatewayAcpBindingEnabled(binding)) {
            continue
        }
        let matchObj = gatewayAcpBindingMatch(binding)
        if (gatewayAcpToken(gatewayAcpJsonString(matchObj, "channel")) != input.channel) {
            continue
        }
        let accountInfo = gatewayAcpBindingAccountPattern(matchObj, defaultAccountId)
        if (!gatewayAcpAccountMatches(accountInfo[0], accountId)) {
            continue
        }
        let peer = gatewayAcpJsonObject(matchObj, "peer")
        if (gatewayAcpToken(gatewayAcpJsonString(peer, "kind")) != input.peerKind) {
            continue
        }
        if (gatewayAcpJsonString(peer, "id") != input.peerId) {
            continue
        }
        return gatewayAcpBindingResolution(binding, input.channel, accountId, input.peerKind, input.peerId)
    }
    GatewayAcpConversationBinding(false)
}

public func gatewayAcpBindingRowJson(root: JsonObject, binding: JsonObject): JsonObject {
    let matchObj = gatewayAcpBindingMatch(binding)
    let channel = gatewayAcpToken(gatewayAcpJsonString(matchObj, "channel"))
    let defaultAccountId = gatewayAcpChannelDefaultAccount(root, channel, "")
    let accountInfo = gatewayAcpBindingAccountPattern(matchObj, defaultAccountId)
    let peer = gatewayAcpJsonObject(matchObj, "peer")
    let peerKind = gatewayAcpToken(gatewayAcpJsonString(peer, "kind"))
    let peerId = gatewayAcpJsonString(peer, "id")
    let resolved = gatewayAcpBindingResolution(binding, channel, accountInfo[0], peerKind, peerId)
    let agentId = if (resolved.found) {
        resolved.agentId
    } else {
        gatewayAcpSanitizeId(gatewayAcpJsonString(binding, "agentId"))
    }
    let row = JsonObject()
    row.put("type", JsonString("acp"))
    row.put("agentId", JsonString(agentId))
    row.put("channel", JsonString(channel))
    row.put("accountId", JsonString(accountInfo[0]))
    row.put("peerKind", JsonString(peerKind))
    row.put("peerId", JsonString(peerId))
    row.put("match", gatewayAcpCloneValue(matchObj).asObject())
    row.put("acp", gatewayAcpCloneValue(gatewayAcpJsonObject(binding, "acp")).asObject())
    row.put("sessionKey", JsonString(resolved.sessionKey))
    row.put("mode", JsonString(resolved.mode))
    row.put("lifecycle", JsonString(resolved.lifecycle))
    row.put("ready", JsonBool(resolved.ready))
    row.put("reset", JsonBool(resolved.reset))
    row.put("matchedBy", JsonString(resolved.matchedBy))
    row
}
