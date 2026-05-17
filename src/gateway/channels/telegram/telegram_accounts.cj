package metis.gateway.channels.telegram

import metis.gateway.model.TelegramConfig

import std.collection.{ArrayList, HashSet}
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

public class TelegramResolvedAccount {
    public let accountId: String
    public let config: TelegramConfig
    public let explicitAccount: Bool
    public let missingAccount: Bool
    public let configured: Bool
    public let credentialSource: String
    public let botTokenSource: String
    public let tokenFileSource: String
    public let securitySources: JsonObject
    public let inheritanceDiagnostics: JsonArray

    public init(
        accountId: String,
        config: TelegramConfig,
        explicitAccount!: Bool = false,
        missingAccount!: Bool = false,
        configured!: Bool = false,
        credentialSource!: String = "missing",
        botTokenSource!: String = "missing",
        tokenFileSource!: String = "missing",
        securitySources!: JsonObject = JsonObject(),
        inheritanceDiagnostics!: JsonArray = JsonArray([])
    ) {
        this.accountId = gatewayTelegramNormalizeAccountId(accountId)
        this.config = config
        this.explicitAccount = explicitAccount
        this.missingAccount = missingAccount
        this.configured = configured
        this.credentialSource = credentialSource.trimAscii()
        this.botTokenSource = botTokenSource.trimAscii()
        this.tokenFileSource = tokenFileSource.trimAscii()
        this.securitySources = securitySources
        this.inheritanceDiagnostics = inheritanceDiagnostics
    }
}

public func gatewayTelegramNormalizeAccountId(raw: String): String {
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty()) {
        return "default"
    }
    let lower = trimmed.toAsciiLower()
    for (prefix in ["telegram:", "tg:"]) {
        if (lower.startsWith(prefix)) {
            let suffix = trimmed[prefix.size..].trimAscii()
            return if (suffix.isEmpty()) { "default" } else { suffix }
        }
    }
    trimmed
}

public func gatewayTelegramDefaultAccountId(config: TelegramConfig): String {
    gatewayTelegramNormalizeAccountId(config.defaultAccount)
}

public func gatewayTelegramListAccountIds(config: TelegramConfig): Array<String> {
    let out = ArrayList<String>()
    let seen = HashSet<String>()
    let defaultAccount = gatewayTelegramDefaultAccountId(config)
    out.add(defaultAccount)
    seen.add(defaultAccount)
    match (config.accounts) {
        case Some(accounts) =>
            for (raw in accounts.getFields().keys()) {
                let id = gatewayTelegramNormalizeAccountId(raw)
                if (!seen.contains(id)) {
                    out.add(id)
                    seen.add(id)
                }
            }
        case None => ()
    }
    out.toArray()
}

public func gatewayTelegramResolveAccount(config: TelegramConfig, accountId: String): TelegramResolvedAccount {
    let normalized = if (accountId.trimAscii().isEmpty()) {
        gatewayTelegramDefaultAccountId(config)
    } else {
        gatewayTelegramNormalizeAccountId(accountId)
    }
    let defaultAccount = gatewayTelegramDefaultAccountId(config)
    let accountConfig = gatewayTelegramAccountOverride(config, normalized)
    let explicitAccount = accountConfig.isSome()
    let missingAccount = !explicitAccount && normalized != defaultAccount && config.accounts.isSome()
    let overrideObj = accountConfig ?? JsonObject()
    let merged = gatewayTelegramMergedConfig(config, normalized, overrideObj, missingAccount)
    let tokenFileSource = gatewayTelegramCredentialFieldSource(
        normalized,
        gatewayTelegramHasString(overrideObj, ["tokenFile", "token_file"]),
        !config.tokenFile.trimAscii().isEmpty(),
        missingAccount
    )
    let botTokenSource = gatewayTelegramCredentialFieldSource(
        normalized,
        gatewayTelegramHasString(overrideObj, ["botToken", "bot_token"]),
        !config.botToken.trimAscii().isEmpty(),
        missingAccount
    )
    let credentialSource = gatewayTelegramCredentialSourceSummary(botTokenSource, tokenFileSource)
    let securitySources = gatewayTelegramSecuritySources(config, normalized, overrideObj, missingAccount)
    let diagnostics = gatewayTelegramInheritanceDiagnostics(securitySources)
    TelegramResolvedAccount(
        normalized,
        merged,
        explicitAccount: explicitAccount,
        missingAccount: missingAccount,
        configured: !merged.botToken.trimAscii().isEmpty() || !merged.tokenFile.trimAscii().isEmpty(),
        credentialSource: credentialSource,
        botTokenSource: botTokenSource,
        tokenFileSource: tokenFileSource,
        securitySources: securitySources,
        inheritanceDiagnostics: diagnostics
    )
}

public func gatewayTelegramConfigForAccount(config: TelegramConfig, accountId: String): TelegramConfig {
    gatewayTelegramResolveAccount(config, accountId).config
}

private func gatewayTelegramAccountOverride(config: TelegramConfig, accountId: String): Option<JsonObject> {
    match (config.accounts) {
        case Some(accounts) =>
            match (accounts.get(accountId)) {
                case Some(value) => try { Some(value.asObject()) } catch (_: Exception) { None }
                case None =>
                    if (accountId == "default") {
                        let raw = match (accounts.get("telegram:default")) {
                            case Some(v) => Some(v)
                            case None => accounts.get("tg:default")
                        }
                        match (raw) {
                            case Some(value) => try { Some(value.asObject()) } catch (_: Exception) { None }
                            case None => None
                        }
                    } else {
                        let raw = match (accounts.get("telegram:${accountId}")) {
                            case Some(v) => Some(v)
                            case None => accounts.get("tg:${accountId}")
                        }
                        match (raw) {
                            case Some(value) => try { Some(value.asObject()) } catch (_: Exception) { None }
                            case None => None
                        }
                    }
            }
        case None => None
    }
}

private func gatewayTelegramString(obj: JsonObject, keys: Array<String>, fallback: String): String {
    for (key in keys) {
        match (obj.get(key)) {
            case Some(value) =>
                try {
                    return value.asString().getValue()
                } catch (_: Exception) {
                    ()
                }
            case None => ()
        }
    }
    fallback
}

private func gatewayTelegramHasString(obj: JsonObject, keys: Array<String>): Bool {
    !gatewayTelegramString(obj, keys, "").isEmpty()
}

private func gatewayTelegramHasAnyKey(obj: JsonObject, keys: Array<String>): Bool {
    for (key in keys) {
        if (obj.get(key).isSome()) {
            return true
        }
    }
    false
}

private func gatewayTelegramAccountLocalSource(accountId: String): String {
    if (gatewayTelegramNormalizeAccountId(accountId) == "default") {
        "default-account"
    } else {
        "account-local"
    }
}

private func gatewayTelegramCredentialFieldSource(
    accountId: String,
    accountHasValue: Bool,
    topLevelHasValue: Bool,
    missingAccount: Bool
): String {
    if (missingAccount) {
        return "missing-account"
    }
    if (accountHasValue) {
        return gatewayTelegramAccountLocalSource(accountId)
    }
    if (topLevelHasValue) {
        return "top-level-inherited"
    }
    "missing"
}

private func gatewayTelegramCredentialSourceSummary(botTokenSource: String, tokenFileSource: String): String {
    if (tokenFileSource != "missing" && tokenFileSource != "missing-account") {
        return tokenFileSource
    }
    if (botTokenSource != "missing" && botTokenSource != "missing-account") {
        return botTokenSource
    }
    if (botTokenSource == "missing-account" || tokenFileSource == "missing-account") {
        return "missing-account"
    }
    "missing"
}

private func gatewayTelegramStringArray(obj: JsonObject, keys: Array<String>, fallback: Array<String>): Array<String> {
    for (key in keys) {
        match (obj.get(key)) {
            case Some(value) =>
                try {
                    let arr = value.asArray()
                    let out = ArrayList<String>()
                    for (i in 0..arr.size()) {
                        try {
                            let item = arr[i].asString().getValue().trimAscii()
                            if (!item.isEmpty()) {
                                out.add(item)
                            }
                        } catch (_: Exception) {
                            ()
                        }
                    }
                    return out.toArray()
                } catch (_: Exception) {
                    return fallback
                }
            case None => ()
        }
    }
    fallback
}

private func gatewayTelegramArraySource(
    accountId: String,
    overrideObj: JsonObject,
    keys: Array<String>,
    topLevel: Array<String>,
    missingAccount: Bool
): String {
    if (missingAccount) {
        return "missing-account"
    }
    if (gatewayTelegramHasAnyKey(overrideObj, keys)) {
        let values = gatewayTelegramStringArray(overrideObj, keys, [])
        if (values.isEmpty()) {
            return "explicit-empty"
        }
        return gatewayTelegramAccountLocalSource(accountId)
    }
    if (!topLevel.isEmpty()) {
        return "top-level-inherited"
    }
    "missing"
}

private func gatewayTelegramObjectSource(
    accountId: String,
    overrideObj: JsonObject,
    key: String,
    topLevel: Option<JsonObject>,
    missingAccount: Bool
): String {
    if (missingAccount) {
        return "missing-account"
    }
    match (overrideObj.get(key)) {
        case Some(value) =>
            try {
                let obj = value.asObject()
                if (obj.size() == 0) {
                    return "explicit-empty"
                }
                return gatewayTelegramAccountLocalSource(accountId)
            } catch (_: Exception) {
                return "missing"
            }
        case None => ()
    }
    match (topLevel) {
        case Some(obj) =>
            if (obj.size() > 0) {
                return "top-level-inherited"
            }
        case None => ()
    }
    "missing"
}

private func gatewayTelegramStringSource(
    accountId: String,
    overrideObj: JsonObject,
    keys: Array<String>,
    topLevel: String,
    missingAccount: Bool
): String {
    if (missingAccount) {
        return "missing-account"
    }
    if (gatewayTelegramHasAnyKey(overrideObj, keys)) {
        return gatewayTelegramAccountLocalSource(accountId)
    }
    if (!topLevel.trimAscii().isEmpty()) {
        return "top-level-inherited"
    }
    "missing"
}

private func gatewayTelegramSecuritySources(
    config: TelegramConfig,
    accountId: String,
    overrideObj: JsonObject,
    missingAccount: Bool
): JsonObject {
    let out = JsonObject()
    out.put("dmPolicy", JsonString(gatewayTelegramStringSource(accountId, overrideObj, ["dmPolicy", "dm_policy"], config.dmPolicy, missingAccount)))
    out.put("allowFrom", JsonString(gatewayTelegramArraySource(accountId, overrideObj, ["allowFrom", "allow_from"], config.allowFrom, missingAccount)))
    out.put("groupPolicy", JsonString(gatewayTelegramStringSource(accountId, overrideObj, ["groupPolicy", "group_policy"], config.groupPolicy, missingAccount)))
    out.put("groupAllowFrom", JsonString(gatewayTelegramArraySource(accountId, overrideObj, ["groupAllowFrom", "group_allow_from"], config.groupAllowFrom, missingAccount)))
    out.put("groups", JsonString(gatewayTelegramObjectSource(accountId, overrideObj, "groups", config.groups, missingAccount)))
    out
}

private func gatewayTelegramInheritanceDiagnostics(sources: JsonObject): JsonArray {
    let out = JsonArray([])
    for (key in sources.getFields().keys()) {
        let source = try { sources.getFields()[key].asString().getValue() } catch (_: Exception) { "" }
        if (source == "top-level-inherited" || source == "explicit-empty") {
            let row = JsonObject()
            row.put("field", JsonString(key))
            row.put("source", JsonString(source))
            out.add(row)
        }
    }
    out
}

private func gatewayTelegramBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayTelegramObject(obj: JsonObject, key: String, fallback: Option<JsonObject>): Option<JsonObject> {
    match (obj.get(key)) {
        case Some(value) => try { Some(value.asObject()) } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayTelegramMergedConfig(base: TelegramConfig, accountId: String, overrideObj: JsonObject, missingAccount: Bool): TelegramConfig {
    TelegramConfig(
        accountId: accountId,
        defaultAccount: gatewayTelegramDefaultAccountId(base),
        enabled: gatewayTelegramBool(overrideObj, "enabled", base.enabled),
        botToken: if (missingAccount) { "" } else { gatewayTelegramString(overrideObj, ["botToken", "bot_token"], base.botToken) },
        tokenFile: if (missingAccount) { "" } else { gatewayTelegramString(overrideObj, ["tokenFile", "token_file"], base.tokenFile) },
        dmPolicy: gatewayTelegramString(overrideObj, ["dmPolicy", "dm_policy"], base.dmPolicy),
        allowFrom: gatewayTelegramStringArray(overrideObj, ["allowFrom", "allow_from"], if (missingAccount) { [] } else { base.allowFrom }),
        defaultTo: gatewayTelegramString(overrideObj, ["defaultTo", "default_to"], base.defaultTo),
        groupPolicy: gatewayTelegramString(overrideObj, ["groupPolicy", "group_policy"], base.groupPolicy),
        groupAllowFrom: gatewayTelegramStringArray(overrideObj, ["groupAllowFrom", "group_allow_from"], if (missingAccount) { [] } else { base.groupAllowFrom }),
        groups: if (missingAccount) { None<JsonObject> } else { gatewayTelegramObject(overrideObj, "groups", base.groups) },
        direct: gatewayTelegramObject(overrideObj, "direct", base.direct),
        dms: gatewayTelegramObject(overrideObj, "dms", base.dms),
        accounts: base.accounts,
        commandsNative: base.commandsNative,
        customCommands: base.customCommands,
        replyToMode: base.replyToMode,
        groupHistoryEnabled: base.groupHistoryEnabled,
        groupHistoryLimit: base.groupHistoryLimit,
        textChunkLimit: base.textChunkLimit,
        chunkMode: base.chunkMode,
        streaming: gatewayTelegramString(overrideObj, ["streaming"], base.streaming),
        blockStreaming: gatewayTelegramBool(overrideObj, "blockStreaming", base.blockStreaming),
        timeoutSeconds: base.timeoutSeconds,
        linkPreview: base.linkPreview,
        silent: base.silent,
        webhookUrl: gatewayTelegramString(overrideObj, ["webhookUrl", "webhook_url"], base.webhookUrl),
        webhookSecret: gatewayTelegramString(overrideObj, ["webhookSecret", "webhook_secret"], base.webhookSecret),
        webhookCertPath: gatewayTelegramString(overrideObj, ["webhookCertPath", "webhook_cert_path"], base.webhookCertPath),
        webhookPath: gatewayTelegramString(overrideObj, ["webhookPath", "webhook_path"], base.webhookPath),
        webhookHost: gatewayTelegramString(overrideObj, ["webhookHost", "webhook_host"], base.webhookHost),
        webhookPort: base.webhookPort,
        webhookMaxBodyBytes: base.webhookMaxBodyBytes,
        webhookBodyTimeoutMs: base.webhookBodyTimeoutMs,
        webhookRateLimitWindowMs: base.webhookRateLimitWindowMs,
        webhookRateLimitMaxRequests: base.webhookRateLimitMaxRequests,
        trustedProxies: base.trustedProxies,
        allowRealIpFallback: base.allowRealIpFallback,
        apiRoot: gatewayTelegramString(overrideObj, ["apiRoot", "api_root"], base.apiRoot),
        proxy: gatewayTelegramString(overrideObj, ["proxy"], base.proxy),
        reactionNotifications: base.reactionNotifications,
        reactionLevel: base.reactionLevel,
        ackReaction: base.ackReaction,
        removeAckAfterReply: base.removeAckAfterReply,
        configWrites: base.configWrites,
        actions: base.actions,
        inlineButtons: base.inlineButtons,
        execApprovals: base.execApprovals,
        errorPolicy: base.errorPolicy,
        autoTopicLabel: base.autoTopicLabel,
        threadBindings: base.threadBindings,
        media: base.media,
        network: base.network,
        policy: base.policy
    )
}
