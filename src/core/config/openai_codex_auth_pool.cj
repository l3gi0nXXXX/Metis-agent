package metis.core.config

import magic.jsonable.*

import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonInt, JsonObject, JsonString, JsonValue}

public let OPENAI_CODEX_POOL_SOURCE_DEVICE_CODE: String = "device_code"
public let OPENAI_CODEX_POOL_SOURCE_MANUAL_DEVICE_CODE: String = "manual:device_code"
public let OPENAI_CODEX_POOL_SUPPRESSION_DEVICE_CODE: String = "device_code"

public class OpenAICodexPoolEntry {
    public let id: String
    public let label: String
    public let source: String
    public let authType: String
    public let accessToken: String
    public let refreshToken: String
    public let baseUrl: String
    public let expiresAtUnixSeconds: Int64
    public let lastRefreshUnixSeconds: Int64
    public let lastStatus: String
    public let lastErrorResetAtUnixSeconds: Int64
    public let lastErrorCode: String
    public let lastErrorReason: String

    public init(
        id!: String,
        label!: String = "",
        source!: String,
        authType!: String = "oauth",
        accessToken!: String,
        refreshToken!: String,
        baseUrl!: String = OPENAI_CODEX_DEFAULT_BASE_URL,
        expiresAtUnixSeconds!: Int64 = 0,
        lastRefreshUnixSeconds!: Int64 = 0,
        lastStatus!: String = "ok",
        lastErrorResetAtUnixSeconds!: Int64 = 0,
        lastErrorCode!: String = "",
        lastErrorReason!: String = ""
    ) {
        this.id = id.trimAscii()
        this.label = label.trimAscii()
        this.source = source.trimAscii()
        this.authType = authType.trimAscii()
        this.accessToken = accessToken
        this.refreshToken = refreshToken
        this.baseUrl = baseUrl.trimAscii()
        this.expiresAtUnixSeconds = expiresAtUnixSeconds
        this.lastRefreshUnixSeconds = lastRefreshUnixSeconds
        this.lastStatus = lastStatus.trimAscii()
        this.lastErrorResetAtUnixSeconds = lastErrorResetAtUnixSeconds
        this.lastErrorCode = lastErrorCode.trimAscii()
        this.lastErrorReason = lastErrorReason.trimAscii()
    }

    public func toJsonObject(): JsonObject {
        let out = JsonObject()
        out.put("id", JsonString(this.id))
        out.put("label", JsonString(this.label))
        out.put("source", JsonString(this.source))
        out.put("authType", JsonString(this.authType))
        out.put("accessToken", JsonString(this.accessToken))
        out.put("refreshToken", JsonString(this.refreshToken))
        out.put("baseUrl", JsonString(this.baseUrl))
        out.put("expiresAtUnixSeconds", JsonInt(this.expiresAtUnixSeconds))
        out.put("lastRefreshUnixSeconds", JsonInt(this.lastRefreshUnixSeconds))
        out.put("lastStatus", JsonString(this.lastStatus))
        out.put("lastErrorResetAtUnixSeconds", JsonInt(this.lastErrorResetAtUnixSeconds))
        out.put("lastErrorCode", JsonString(this.lastErrorCode))
        out.put("lastErrorReason", JsonString(this.lastErrorReason))
        out
    }
}

public class OpenAICodexSingletonLoginDecision {
    public let status: String
    public let selectedSource: String
    public let transcript: Array<String>
    public let profile: Option<OpenAICodexOAuthProfile>

    public init(
        status: String,
        selectedSource!: String,
        transcript!: Array<String>,
        profile!: Option<OpenAICodexOAuthProfile> = None<OpenAICodexOAuthProfile>
    ) {
        this.status = status.trimAscii()
        this.selectedSource = selectedSource.trimAscii()
        this.transcript = transcript
        this.profile = profile
    }
}

private func poolJsonObject(root: JsonObject, key: String): Option<JsonObject> {
    match (root.get(key)) {
        case Some(value) => try { Some(value.asObject()) } catch (_: Exception) { None }
        case None => None
    }
}

private func poolJsonArray(root: JsonObject, key: String): Option<JsonArray> {
    match (root.get(key)) {
        case Some(value) => try { Some(value.asArray()) } catch (_: Exception) { None }
        case None => None
    }
}

private func poolJsonString(root: JsonObject, key: String): Option<String> {
    match (root.get(key)) {
        case Some(value) => try { Some(value.asString().getValue()) } catch (_: Exception) { None }
        case None => None
    }
}

private func poolJsonInt(root: JsonObject, key: String): Option<Int64> {
    match (root.get(key)) {
        case Some(value) => try { Some(value.asInt().getValue()) } catch (_: Exception) { None }
        case None => None
    }
}

private func poolEnsureObject(root: JsonObject, key: String): JsonObject {
    match (root.get(key)) {
        case Some(value) =>
            try {
                value.asObject()
            } catch (_: Exception) {
                let obj = JsonObject()
                root.put(key, obj)
                obj
            }
        case None =>
            let obj = JsonObject()
            root.put(key, obj)
            obj
    }
}

private func poolEnsureArray(root: JsonObject, key: String): JsonArray {
    match (root.get(key)) {
        case Some(value) =>
            try {
                value.asArray()
            } catch (_: Exception) {
                let arr = JsonArray([])
                root.put(key, arr)
                arr
            }
        case None =>
            let arr = JsonArray([])
            root.put(key, arr)
            arr
    }
}

private func poolEntryFromJson(obj: JsonObject): Option<OpenAICodexPoolEntry> {
    let id = poolJsonString(obj, "id").getOrDefault { "" }.trimAscii()
    let source = poolJsonString(obj, "source").getOrDefault { "" }.trimAscii()
    let accessToken = poolJsonString(obj, "accessToken").getOrDefault { "" }
    let refreshToken = poolJsonString(obj, "refreshToken").getOrDefault { "" }
    if (id.isEmpty() || source.isEmpty()) {
        return None<OpenAICodexPoolEntry>
    }
    Some(OpenAICodexPoolEntry(
        id: id,
        label: poolJsonString(obj, "label").getOrDefault { "" },
        source: source,
        authType: poolJsonString(obj, "authType").getOrDefault { "oauth" },
        accessToken: accessToken,
        refreshToken: refreshToken,
        baseUrl: poolJsonString(obj, "baseUrl").getOrDefault { OPENAI_CODEX_DEFAULT_BASE_URL },
        expiresAtUnixSeconds: poolJsonInt(obj, "expiresAtUnixSeconds").getOrDefault { 0 },
        lastRefreshUnixSeconds: poolJsonInt(obj, "lastRefreshUnixSeconds").getOrDefault { 0 },
        lastStatus: poolJsonString(obj, "lastStatus").getOrDefault { "ok" },
        lastErrorResetAtUnixSeconds: poolJsonInt(obj, "lastErrorResetAtUnixSeconds").getOrDefault { 0 },
        lastErrorCode: poolJsonString(obj, "lastErrorCode").getOrDefault { "" },
        lastErrorReason: poolJsonString(obj, "lastErrorReason").getOrDefault { "" }
    ))
}

private func openAICodexPoolArray(root: JsonObject): JsonArray {
    match (poolJsonObject(root, "auth")) {
        case Some(auth) =>
            match (poolJsonObject(auth, "credentialPool")) {
                case Some(pool) => poolJsonArray(pool, OPENAI_CODEX_OAUTH_PROVIDER_ID).getOrDefault { JsonArray([]) }
                case None => JsonArray([])
            }
        case None => JsonArray([])
    }
}

private func openAICodexMutablePoolArray(root: JsonObject): JsonArray {
    let auth = poolEnsureObject(root, "auth")
    let pool = poolEnsureObject(auth, "credentialPool")
    poolEnsureArray(pool, OPENAI_CODEX_OAUTH_PROVIDER_ID)
}

private func openAICodexSuppressionArray(root: JsonObject): JsonArray {
    let auth = poolEnsureObject(root, "auth")
    let suppressed = poolEnsureObject(auth, "suppressedSources")
    poolEnsureArray(suppressed, OPENAI_CODEX_OAUTH_PROVIDER_ID)
}

private func clonePoolRoot(): JsonObject {
    match (MetisConfigManager.rawConfig()) {
        case Some(root) => try { JsonValue.fromStr(root.toJsonString()).asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func persistPoolRoot(root: JsonObject): Unit {
    MetisConfigManager.writeRoot(root)
}

private func poolStatusTerminal(status: String): Bool {
    let value = status.trimAscii().toAsciiLower()
    value == "exhausted" || value == "dead" || value == "invalid_grant" || value == "refresh_token_reused"
}

private func poolEntryUsable(entry: OpenAICodexPoolEntry, nowSeconds: Int64): Bool {
    if (entry.accessToken.isEmpty()) {
        return false
    }
    if (entry.lastErrorResetAtUnixSeconds > nowSeconds) {
        return false
    }
    if (poolStatusTerminal(entry.lastStatus) && entry.lastErrorResetAtUnixSeconds <= 0) {
        return false
    }
    true
}

public func listOpenAICodexPoolEntries(): Array<OpenAICodexPoolEntry> {
    let out = ArrayList<OpenAICodexPoolEntry>()
    match (MetisConfigManager.rawConfig()) {
        case Some(root) =>
            for (item in openAICodexPoolArray(root).getItems()) {
                let obj = try { item.asObject() } catch (_: Exception) { JsonObject() }
                match (poolEntryFromJson(obj)) {
                    case Some(entry) => out.add(entry)
                    case None => ()
                }
            }
        case None => ()
    }
    out.toArray()
}

public func selectOpenAICodexPoolEntry(nowSeconds: Int64): Option<OpenAICodexPoolEntry> {
    var root = clonePoolRoot()
    var mutated = false
    let singleton = readOpenAICodexOAuthProfile()
    let arr = openAICodexMutablePoolArray(root)
    let replacement = JsonArray([])
    var selected = None<OpenAICodexPoolEntry>
    for (item in arr.getItems()) {
        let obj = try { item.asObject() } catch (_: Exception) { JsonObject() }
        match (poolEntryFromJson(obj)) {
            case Some(entry) =>
                var candidate = entry
                if (entry.source == OPENAI_CODEX_POOL_SOURCE_DEVICE_CODE && poolStatusTerminal(entry.lastStatus)) {
                    match (singleton) {
                        case Some(profile) =>
                            if (!profile.accessToken.isEmpty() && profile.accessToken != entry.accessToken) {
                                candidate = OpenAICodexPoolEntry(
                                    id: entry.id,
                                    label: entry.label,
                                    source: entry.source,
                                    authType: entry.authType,
                                    accessToken: profile.accessToken,
                                    refreshToken: profile.refreshToken,
                                    baseUrl: profile.baseUrl,
                                    expiresAtUnixSeconds: profile.expiresAtUnixSeconds,
                                    lastRefreshUnixSeconds: profile.lastRefreshUnixSeconds,
                                    lastStatus: "ok",
                                    lastErrorResetAtUnixSeconds: 0,
                                    lastErrorCode: "",
                                    lastErrorReason: ""
                                )
                                mutated = true
                            }
                        case None => ()
                    }
                }
                replacement.add(candidate.toJsonObject())
                if (selected.isNone() && poolEntryUsable(candidate, nowSeconds)) {
                    selected = Some(candidate)
                }
            case None => replacement.add(item)
        }
    }
    if (mutated) {
        let auth = poolEnsureObject(root, "auth")
        let pool = poolEnsureObject(auth, "credentialPool")
        pool.put(OPENAI_CODEX_OAUTH_PROVIDER_ID, replacement)
        persistPoolRoot(root)
    }
    selected
}

public func syncOpenAICodexPoolOnReauth(previousProfile: Option<OpenAICodexOAuthProfile>, newProfile: OpenAICodexOAuthProfile): Int64 {
    let root = clonePoolRoot()
    let arr = openAICodexMutablePoolArray(root)
    let replacement = JsonArray([])
    var changed: Int64 = 0
    let previousToken = match (previousProfile) {
        case Some(profile) => profile.accessToken
        case None => ""
    }
    for (item in arr.getItems()) {
        let obj = try { item.asObject() } catch (_: Exception) { JsonObject() }
        match (poolEntryFromJson(obj)) {
            case Some(entry) =>
                let shouldSync = entry.source == OPENAI_CODEX_POOL_SOURCE_DEVICE_CODE ||
                    (entry.source == OPENAI_CODEX_POOL_SOURCE_MANUAL_DEVICE_CODE && !previousToken.isEmpty() &&
                        entry.accessToken == previousToken)
                if (shouldSync) {
                    let updated = OpenAICodexPoolEntry(
                        id: entry.id,
                        label: entry.label,
                        source: entry.source,
                        authType: entry.authType,
                        accessToken: newProfile.accessToken,
                        refreshToken: newProfile.refreshToken,
                        baseUrl: newProfile.baseUrl,
                        expiresAtUnixSeconds: newProfile.expiresAtUnixSeconds,
                        lastRefreshUnixSeconds: newProfile.lastRefreshUnixSeconds,
                        lastStatus: "ok",
                        lastErrorResetAtUnixSeconds: 0,
                        lastErrorCode: "",
                        lastErrorReason: ""
                    )
                    replacement.add(updated.toJsonObject())
                    changed += 1
                } else {
                    replacement.add(obj)
                }
            case None => replacement.add(item)
        }
    }
    if (changed > 0) {
        let auth = poolEnsureObject(root, "auth")
        let pool = poolEnsureObject(auth, "credentialPool")
        pool.put(OPENAI_CODEX_OAUTH_PROVIDER_ID, replacement)
        persistPoolRoot(root)
    }
    changed
}

public func addOpenAICodexManualDeviceCodeCredential(label: String, profile: OpenAICodexOAuthProfile): OpenAICodexPoolEntry {
    let root = clonePoolRoot()
    let arr = openAICodexMutablePoolArray(root)
    let wasEmpty = arr.size() == 0
    let entry = OpenAICodexPoolEntry(
        id: "manual:device_code:${arr.size() + 1}",
        label: label,
        source: OPENAI_CODEX_POOL_SOURCE_MANUAL_DEVICE_CODE,
        accessToken: profile.accessToken,
        refreshToken: profile.refreshToken,
        baseUrl: profile.baseUrl,
        expiresAtUnixSeconds: profile.expiresAtUnixSeconds,
        lastRefreshUnixSeconds: profile.lastRefreshUnixSeconds,
        lastStatus: "ok"
    )
    arr.add(entry.toJsonObject())
    if (wasEmpty) {
        let auth = poolEnsureObject(root, "auth")
        auth.put("activeProvider", JsonString(OPENAI_CODEX_OAUTH_PROVIDER_ID))
    }
    clearOpenAICodexDeviceCodeSuppression(root)
    persistPoolRoot(root)
    entry
}

public func clearOpenAICodexDeviceCodeSuppression(root: JsonObject): Unit {
    let arr = openAICodexSuppressionArray(root)
    let replacement = JsonArray([])
    for (item in arr.getItems()) {
        let value = try { item.asString().getValue() } catch (_: Exception) { "" }
        if (value != OPENAI_CODEX_POOL_SUPPRESSION_DEVICE_CODE) {
            replacement.add(JsonString(value))
        }
    }
    let auth = poolEnsureObject(root, "auth")
    let suppressed = poolEnsureObject(auth, "suppressedSources")
    suppressed.put(OPENAI_CODEX_OAUTH_PROVIDER_ID, replacement)
}

public func suppressOpenAICodexDeviceCodeReseed(): Unit {
    let root = clonePoolRoot()
    let arr = openAICodexSuppressionArray(root)
    var exists = false
    for (item in arr.getItems()) {
        let value = try { item.asString().getValue() } catch (_: Exception) { "" }
        if (value == OPENAI_CODEX_POOL_SUPPRESSION_DEVICE_CODE) {
            exists = true
            break
        }
    }
    if (!exists) {
        arr.add(JsonString(OPENAI_CODEX_POOL_SUPPRESSION_DEVICE_CODE))
        persistPoolRoot(root)
    }
}

public func unsuppressOpenAICodexDeviceCodeReseed(): Unit {
    let root = clonePoolRoot()
    clearOpenAICodexDeviceCodeSuppression(root)
    persistPoolRoot(root)
}

public func isOpenAICodexDeviceCodeReseedSuppressed(): Bool {
    match (MetisConfigManager.rawConfig()) {
        case Some(root) =>
            match (poolJsonObject(root, "auth")) {
                case Some(auth) =>
                    match (poolJsonObject(auth, "suppressedSources")) {
                        case Some(suppressed) =>
                            let arr = poolJsonArray(suppressed, OPENAI_CODEX_OAUTH_PROVIDER_ID).getOrDefault { JsonArray([]) }
                            for (item in arr.getItems()) {
                                let value = try { item.asString().getValue() } catch (_: Exception) { "" }
                                if (value == OPENAI_CODEX_POOL_SUPPRESSION_DEVICE_CODE) {
                                    return true
                                }
                            }
                        case None => ()
                    }
                case None => ()
            }
        case None => ()
    }
    false
}

public func removeOpenAICodexPoolCredential(id: String): Bool {
    let root = clonePoolRoot()
    let arr = openAICodexMutablePoolArray(root)
    let replacement = JsonArray([])
    var removed = false
    for (item in arr.getItems()) {
        let obj = try { item.asObject() } catch (_: Exception) { JsonObject() }
        let entryId = poolJsonString(obj, "id").getOrDefault { "" }
        if (entryId == id) {
            removed = true
        } else {
            replacement.add(obj)
        }
    }
    let auth = poolEnsureObject(root, "auth")
    let pool = poolEnsureObject(auth, "credentialPool")
    pool.put(OPENAI_CODEX_OAUTH_PROVIDER_ID, replacement)
    if (removed) {
        suppressOpenAICodexDeviceCodeReseedInRoot(root)
        persistPoolRoot(root)
    }
    removed
}

private func suppressOpenAICodexDeviceCodeReseedInRoot(root: JsonObject): Unit {
    let arr = openAICodexSuppressionArray(root)
    var exists = false
    for (item in arr.getItems()) {
        let value = try { item.asString().getValue() } catch (_: Exception) { "" }
        if (value == OPENAI_CODEX_POOL_SUPPRESSION_DEVICE_CODE) {
            exists = true
            break
        }
    }
    if (!exists) {
        arr.add(JsonString(OPENAI_CODEX_POOL_SUPPRESSION_DEVICE_CODE))
    }
}

public func planOpenAICodexSingletonLogin(
    existingProfile: Option<OpenAICodexOAuthProfile>,
    codexCliProfile: Option<OpenAICodexOAuthProfile>,
    freshDeviceProfile: OpenAICodexOAuthProfile,
    forceNewLogin!: Bool = false,
    importCodexCliWithConsent!: Bool = false
): OpenAICodexSingletonLoginDecision {
    let transcript = ArrayList<String>()
    match (existingProfile) {
        case Some(profile) =>
            if (!forceNewLogin && !profile.accessToken.isEmpty()) {
                transcript.add("reuse_existing_metis_oauth")
                return OpenAICodexSingletonLoginDecision(
                    "reuse_existing",
                    selectedSource: profile.source,
                    transcript: transcript.toArray(),
                    profile: Some(profile)
                )
            }
        case None => ()
    }
    match (codexCliProfile) {
        case Some(profile) =>
            if (importCodexCliWithConsent) {
                transcript.add("import_codex_cli_with_explicit_consent")
                return OpenAICodexSingletonLoginDecision(
                    "import_codex_cli",
                    selectedSource: "codex-cli-import",
                    transcript: transcript.toArray(),
                    profile: Some(profile)
                )
            }
            transcript.add("codex_cli_import_declined")
        case None => transcript.add("codex_cli_auth_missing")
    }
    transcript.add("start_fresh_device_code")
    OpenAICodexSingletonLoginDecision(
        "fresh_device_code",
        selectedSource: "device-code",
        transcript: transcript.toArray(),
        profile: Some(freshDeviceProfile)
    )
}
