package metis.core.config

import magic.jsonable.*

import std.collection.ArrayList
import std.env.getVariable
import std.fs.{Directory, File, Path, copy, exists, remove, rename}
import std.posix.chmod
import std.process.executeWithOutput
import std.time.DateTime
import stdx.encoding.json.{JsonArray, JsonInt, JsonObject, JsonString, JsonValue}

public let OPENAI_CODEX_OAUTH_PROVIDER_ID: String = "openai-codex"
public let OPENAI_CODEX_DEFAULT_PROFILE_ID: String = "openai-codex:default"
public let OPENAI_CODEX_DEFAULT_BASE_URL: String = "https://chatgpt.com/backend-api/codex"
public let OPENAI_CODEX_OAUTH_CLIENT_ID: String = "app_EMoamEEZ73f0CkXaXp7hrann"
public let OPENAI_CODEX_OAUTH_TOKEN_URL: String = "https://auth.openai.com/oauth/token"
public let OPENAI_CODEX_REFRESH_SKEW_SECONDS: Int64 = 120

public interface OpenAICodexClock {
    func unixSeconds(): Int64
}

public class OpenAICodexSystemClock <: OpenAICodexClock {
    public init() {}

    public func unixSeconds(): Int64 {
        DateTime.now().toUnixTimeStamp().toSeconds()
    }
}

public class OpenAICodexHttpResponse {
    public let statusCode: Int64
    public let body: String

    public init(statusCode: Int64, body: String) {
        this.statusCode = statusCode
        this.body = body
    }
}

public interface OpenAICodexHttpClient {
    func postJson(url: String, body: String): OpenAICodexHttpResponse
    func postForm(url: String, body: String): OpenAICodexHttpResponse
}

public class OpenAICodexOAuthProfile {
    public let provider: String
    public let profileId: String
    public let authMethod: String
    public let baseUrl: String
    public let accessToken: String
    public let refreshToken: String
    public let expiresAtUnixSeconds: Int64
    public let lastRefreshUnixSeconds: Int64
    public let accountLabel: String
    public let source: String

    public init(
        provider!: String = OPENAI_CODEX_OAUTH_PROVIDER_ID,
        profileId!: String = OPENAI_CODEX_DEFAULT_PROFILE_ID,
        authMethod!: String = "oauth",
        baseUrl!: String = OPENAI_CODEX_DEFAULT_BASE_URL,
        accessToken!: String,
        refreshToken!: String,
        expiresAtUnixSeconds!: Int64,
        lastRefreshUnixSeconds!: Int64,
        accountLabel!: String = "",
        source!: String = "device-code"
    ) {
        this.provider = provider.trimAscii()
        this.profileId = profileId.trimAscii()
        this.authMethod = authMethod.trimAscii()
        this.baseUrl = baseUrl.trimAscii()
        this.accessToken = accessToken
        this.refreshToken = refreshToken
        this.expiresAtUnixSeconds = expiresAtUnixSeconds
        this.lastRefreshUnixSeconds = lastRefreshUnixSeconds
        this.accountLabel = accountLabel.trimAscii()
        this.source = source.trimAscii()
    }

    public func withTokens(
        accessToken!: String,
        refreshToken!: String,
        expiresAtUnixSeconds!: Int64,
        lastRefreshUnixSeconds!: Int64,
        source!: String = this.source
    ): OpenAICodexOAuthProfile {
        OpenAICodexOAuthProfile(
            provider: this.provider,
            profileId: this.profileId,
            authMethod: this.authMethod,
            baseUrl: this.baseUrl,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtUnixSeconds: expiresAtUnixSeconds,
            lastRefreshUnixSeconds: lastRefreshUnixSeconds,
            accountLabel: this.accountLabel,
            source: source
        )
    }

    public func toJsonObject(): JsonObject {
        let out = JsonObject()
        out.put("provider", JsonString(this.provider))
        out.put("profileId", JsonString(this.profileId))
        out.put("authMethod", JsonString(this.authMethod))
        out.put("baseUrl", JsonString(this.baseUrl))
        out.put("accessToken", JsonString(this.accessToken))
        out.put("refreshToken", JsonString(this.refreshToken))
        out.put("expiresAtUnixSeconds", JsonInt(this.expiresAtUnixSeconds))
        out.put("lastRefreshUnixSeconds", JsonInt(this.lastRefreshUnixSeconds))
        out.put("accountLabel", JsonString(this.accountLabel))
        out.put("source", JsonString(this.source))
        out
    }
}

public class OpenAICodexAuthError {
    public let code: String
    public let message: String
    public let reloginRequired: Bool
    public let retryable: Bool

    public init(code: String, message: String, reloginRequired!: Bool = false, retryable!: Bool = false) {
        this.code = code.trimAscii()
        this.message = message.trimAscii()
        this.reloginRequired = reloginRequired
        this.retryable = retryable
    }
}

public class OpenAICodexAccessTokenResult {
    public let status: String
    public let accessToken: String
    public let profile: Option<OpenAICodexOAuthProfile>
    public let error: Option<OpenAICodexAuthError>
    public let refreshed: Bool
    public let refreshAttempted: Bool

    public init(
        status: String,
        accessToken!: String = "",
        profile!: Option<OpenAICodexOAuthProfile> = None<OpenAICodexOAuthProfile>,
        error!: Option<OpenAICodexAuthError> = None<OpenAICodexAuthError>,
        refreshed!: Bool = false,
        refreshAttempted!: Bool = false
    ) {
        this.status = status.trimAscii()
        this.accessToken = accessToken
        this.profile = profile
        this.error = error
        this.refreshed = refreshed
        this.refreshAttempted = refreshAttempted
    }
}

public class OpenAICodexOAuthStoreLoadResult {
    public let status: String
    public let root: JsonObject
    public let corruptPath: String

    public init(status: String, root: JsonObject, corruptPath!: String = "") {
        this.status = status.trimAscii()
        this.root = root
        this.corruptPath = corruptPath.trimAscii()
    }
}

public class OpenAICodexOAuthStoreWriteResult {
    public let status: String
    public let path: String
    public let parentMode: String
    public let fileMode: String

    public init(status: String, path: String, parentMode!: String = "", fileMode!: String = "") {
        this.status = status.trimAscii()
        this.path = path.trimAscii()
        this.parentMode = parentMode.trimAscii()
        this.fileMode = fileMode.trimAscii()
    }
}

public class OpenAICodexAuthStatus {
    public let status: String
    public let loggedIn: Bool
    public let source: String
    public let accountLabel: String
    public let tokenPreview: String
    public let lastRefreshUnixSeconds: Int64
    public let expiresAtUnixSeconds: Int64
    public let oauthConfigured: Bool

    public init(
        status: String,
        loggedIn!: Bool,
        source!: String = "",
        accountLabel!: String = "",
        tokenPreview!: String = "",
        lastRefreshUnixSeconds!: Int64 = 0,
        expiresAtUnixSeconds!: Int64 = 0,
        oauthConfigured!: Bool = false
    ) {
        this.status = status.trimAscii()
        this.loggedIn = loggedIn
        this.source = source.trimAscii()
        this.accountLabel = accountLabel.trimAscii()
        this.tokenPreview = tokenPreview.trimAscii()
        this.lastRefreshUnixSeconds = lastRefreshUnixSeconds
        this.expiresAtUnixSeconds = expiresAtUnixSeconds
        this.oauthConfigured = oauthConfigured
    }
}

public class OpenAICodexLogoutResetResult {
    public let status: String
    public let removedProfile: Bool
    public let resetProvider: Bool
    public let message: String

    public init(status: String, removedProfile!: Bool, resetProvider!: Bool, message!: String) {
        this.status = status.trimAscii()
        this.removedProfile = removedProfile
        this.resetProvider = resetProvider
        this.message = message.trimAscii()
    }
}

private func codexJsonObject(root: JsonObject, key: String): Option<JsonObject> {
    match (root.get(key)) {
        case Some(value) => try { Some(value.asObject()) } catch (_: Exception) { None }
        case None => None
    }
}

private func codexJsonString(root: JsonObject, key: String): Option<String> {
    match (root.get(key)) {
        case Some(value) => try { Some(value.asString().getValue()) } catch (_: Exception) { None }
        case None => None
    }
}

private func codexJsonInt(root: JsonObject, key: String): Option<Int64> {
    match (root.get(key)) {
        case Some(value) => try { Some(value.asInt().getValue()) } catch (_: Exception) { None }
        case None => None
    }
}

private func codexJsonArray(root: JsonObject, key: String): Option<JsonArray> {
    match (root.get(key)) {
        case Some(value) => try { Some(value.asArray()) } catch (_: Exception) { None }
        case None => None
    }
}

private func codexEnsureObject(root: JsonObject, key: String): JsonObject {
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

private func codexCloneObject(root: JsonObject): JsonObject {
    try { JsonValue.fromStr(root.toJsonString()).asObject() } catch (_: Exception) { JsonObject() }
}

private func codexObjectWithoutKey(root: JsonObject, keyToRemove: String): JsonObject {
    let out = JsonObject()
    for ((key, value) in root.getFields()) {
        if (key != keyToRemove) {
            out.put(key, value)
        }
    }
    out
}

private func codexProfileFromJson(obj: JsonObject, expectedProfileId: String): Option<OpenAICodexOAuthProfile> {
    let provider = codexJsonString(obj, "provider").getOrDefault { "" }.trimAscii()
    let profileId = codexJsonString(obj, "profileId").getOrDefault { expectedProfileId }.trimAscii()
    let authMethod = codexJsonString(obj, "authMethod").getOrDefault { "" }.trimAscii()
    let baseUrl = codexJsonString(obj, "baseUrl").getOrDefault { "" }.trimAscii()
    let accessToken = codexJsonString(obj, "accessToken").getOrDefault { "" }
    let refreshToken = codexJsonString(obj, "refreshToken").getOrDefault { "" }
    let accountLabel = codexJsonString(obj, "accountLabel").getOrDefault { "" }.trimAscii()
    let source = codexJsonString(obj, "source").getOrDefault { "" }.trimAscii()
    match (codexJsonInt(obj, "expiresAtUnixSeconds")) {
        case Some(expiresAt) =>
            match (codexJsonInt(obj, "lastRefreshUnixSeconds")) {
                case Some(lastRefresh) =>
                    if (provider != OPENAI_CODEX_OAUTH_PROVIDER_ID || profileId != expectedProfileId || authMethod.isEmpty() ||
                        baseUrl.isEmpty() || accessToken.isEmpty() || refreshToken.isEmpty() || source.isEmpty()) {
                        return None<OpenAICodexOAuthProfile>
                    }
                    Some(OpenAICodexOAuthProfile(
                        provider: provider,
                        profileId: profileId,
                        authMethod: authMethod,
                        baseUrl: baseUrl,
                        accessToken: accessToken,
                        refreshToken: refreshToken,
                        expiresAtUnixSeconds: expiresAt,
                        lastRefreshUnixSeconds: lastRefresh,
                        accountLabel: accountLabel,
                        source: source
                    ))
                case None => None<OpenAICodexOAuthProfile>
            }
        case None => None<OpenAICodexOAuthProfile>
    }
}

public func readOpenAICodexOAuthProfile(profileId!: String = OPENAI_CODEX_DEFAULT_PROFILE_ID): Option<OpenAICodexOAuthProfile> {
    let requested = profileId.trimAscii()
    if (requested != OPENAI_CODEX_DEFAULT_PROFILE_ID) {
        return None<OpenAICodexOAuthProfile>
    }
    match (MetisConfigManager.readAuthProfile(OPENAI_CODEX_DEFAULT_PROFILE_ID)) {
        case Some(profile) => codexProfileFromJson(profile, OPENAI_CODEX_DEFAULT_PROFILE_ID)
        case None => None<OpenAICodexOAuthProfile>
    }
}

public func writeOpenAICodexOAuthProfile(profile: OpenAICodexOAuthProfile): OpenAICodexOAuthProfile {
    let normalizedBaseUrl = if (profile.baseUrl.isEmpty()) { OPENAI_CODEX_DEFAULT_BASE_URL } else { profile.baseUrl }
    let normalized = OpenAICodexOAuthProfile(
        provider: OPENAI_CODEX_OAUTH_PROVIDER_ID,
        profileId: OPENAI_CODEX_DEFAULT_PROFILE_ID,
        authMethod: if (profile.authMethod.isEmpty()) { "oauth" } else { profile.authMethod },
        baseUrl: normalizedBaseUrl,
        accessToken: profile.accessToken,
        refreshToken: profile.refreshToken,
        expiresAtUnixSeconds: profile.expiresAtUnixSeconds,
        lastRefreshUnixSeconds: profile.lastRefreshUnixSeconds,
        accountLabel: profile.accountLabel,
        source: if (profile.source.isEmpty()) { "device-code" } else { profile.source }
    )
    MetisConfigManager.writeAuthProfile(OPENAI_CODEX_DEFAULT_PROFILE_ID, normalized.toJsonObject())
    MetisConfigManager.removeProviderApiKeyIfPresent(OPENAI_CODEX_OAUTH_PROVIDER_ID)
    normalized
}

public func removeOpenAICodexOAuthProfile(suppressDeviceCodeReseed!: Bool = true): Bool {
    let removed = MetisConfigManager.removeAuthProfile(OPENAI_CODEX_DEFAULT_PROFILE_ID)
    if (suppressDeviceCodeReseed) {
        suppressOpenAICodexDeviceCodeReseed()
    }
    removed
}

private func codexUrlEncode(value: String): String {
    value
        .replace("%", "%25")
        .replace("+", "%2B")
        .replace("&", "%26")
        .replace("=", "%3D")
        .replace("?", "%3F")
        .replace("/", "%2F")
        .replace(":", "%3A")
        .replace(" ", "+")
}

public func openAICodexTokenForm(fields: Array<(String, String)>): String {
    let parts = ArrayList<String>()
    for ((key, value) in fields) {
        parts.add("${codexUrlEncode(key)}=${codexUrlEncode(value)}")
    }
    String.join(parts.toArray(), delimiter: "&")
}

private func codexErrorCodeFromBody(body: String): String {
    try {
        let obj = JsonValue.fromStr(body).asObject()
        match (codexJsonObject(obj, "error")) {
            case Some(errorObj) =>
                let nested = codexJsonString(errorObj, "code").getOrDefault {
                    codexJsonString(errorObj, "type").getOrDefault {
                        codexJsonString(errorObj, "message").getOrDefault { "" }
                    }
                }
                if (!nested.trimAscii().isEmpty()) {
                    return nested.trimAscii()
                }
            case None =>
                let direct = codexJsonString(obj, "error").getOrDefault {
                    codexJsonString(obj, "error_code").getOrDefault {
                        codexJsonString(obj, "code").getOrDefault { "" }
                    }
                }
                if (!direct.trimAscii().isEmpty()) {
                    return direct.trimAscii()
                }
        }
    } catch (_: Exception) {
        ()
    }
    ""
}

public func classifyOpenAICodexRefreshError(statusCode: Int64, body: String): OpenAICodexAuthError {
    let rawCode = codexErrorCodeFromBody(body).trimAscii()
    let normalized = rawCode.toAsciiLower()
    if (statusCode == 429 || normalized == "rate_limit_exceeded" || normalized == "too_many_requests") {
        return OpenAICodexAuthError(
            "rate_limited",
            "OpenAI Codex OAuth refresh is rate limited; retry later.",
            reloginRequired: false,
            retryable: true
        )
    }
    if (normalized == "refresh_token_reused") {
        return OpenAICodexAuthError(
            "refresh_token_reused",
            "OpenAI Codex refresh token was rejected as reused. Run codex again, then reconnect Metis.",
            reloginRequired: true,
            retryable: false
        )
    }
    if (normalized == "invalid_grant" || normalized == "invalid_token" || normalized == "invalid_request" ||
        statusCode == 401 || statusCode == 403) {
        let code = if (normalized.isEmpty()) { "codex_relogin_required" } else { normalized }
        return OpenAICodexAuthError(
            code,
            "OpenAI Codex OAuth credentials are no longer valid; reconnect the account.",
            reloginRequired: true,
            retryable: false
        )
    }
    OpenAICodexAuthError(
        if (normalized.isEmpty()) { "codex_refresh_failed" } else { normalized },
        "OpenAI Codex OAuth refresh failed.",
        reloginRequired: false,
        retryable: statusCode >= 500
    )
}

public func refreshOpenAICodexAccessToken(
    profile: OpenAICodexOAuthProfile,
    clock: OpenAICodexClock,
    httpClient: OpenAICodexHttpClient
): OpenAICodexAccessTokenResult {
    if (profile.refreshToken.trimAscii().isEmpty()) {
        return OpenAICodexAccessTokenResult(
            "refresh_failed",
            accessToken: profile.accessToken,
            profile: Some(profile),
            error: Some(OpenAICodexAuthError(
                "missing_refresh_token",
                "OpenAI Codex OAuth profile has no refresh token; reconnect the account.",
                reloginRequired: true,
                retryable: false
            )),
            refreshed: false,
            refreshAttempted: true
        )
    }
    let body = openAICodexTokenForm([
        ("grant_type", "refresh_token"),
        ("refresh_token", profile.refreshToken),
        ("client_id", OPENAI_CODEX_OAUTH_CLIENT_ID)
    ])
    let response = httpClient.postForm(OPENAI_CODEX_OAUTH_TOKEN_URL, body)
    if (response.statusCode < 200 || response.statusCode >= 300) {
        return OpenAICodexAccessTokenResult(
            "refresh_failed",
            accessToken: profile.accessToken,
            profile: Some(profile),
            error: Some(classifyOpenAICodexRefreshError(response.statusCode, response.body)),
            refreshed: false,
            refreshAttempted: true
        )
    }
    try {
        let payload = JsonValue.fromStr(response.body).asObject()
        let accessToken = codexJsonString(payload, "access_token").getOrDefault { "" }
        if (accessToken.isEmpty()) {
            return OpenAICodexAccessTokenResult(
                "refresh_failed",
                accessToken: profile.accessToken,
                profile: Some(profile),
                error: Some(OpenAICodexAuthError(
                    "missing_access_token",
                    "OpenAI Codex OAuth refresh response was missing an access token.",
                    reloginRequired: false,
                    retryable: false
                )),
                refreshed: false,
                refreshAttempted: true
            )
        }
        let refreshToken = codexJsonString(payload, "refresh_token").getOrDefault { profile.refreshToken }
        let expiresIn = codexJsonInt(payload, "expires_in").getOrDefault { 3600 }
        let now = clock.unixSeconds()
        let updated = profile.withTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtUnixSeconds: now + expiresIn,
            lastRefreshUnixSeconds: now
        )
        let persisted = writeOpenAICodexOAuthProfile(updated)
        OpenAICodexAccessTokenResult(
            "ok",
            accessToken: persisted.accessToken,
            profile: Some(persisted),
            refreshed: true,
            refreshAttempted: true
        )
    } catch (_: Exception) {
        OpenAICodexAccessTokenResult(
            "refresh_failed",
            accessToken: profile.accessToken,
            profile: Some(profile),
            error: Some(OpenAICodexAuthError(
                "invalid_refresh_response",
                "OpenAI Codex OAuth refresh response was not valid JSON.",
                reloginRequired: false,
                retryable: false
            )),
            refreshed: false,
            refreshAttempted: true
        )
    }
}

public func resolveOpenAICodexAccessToken(
    clock: OpenAICodexClock,
    httpClient: OpenAICodexHttpClient,
    refreshIfExpiring!: Bool = true
): OpenAICodexAccessTokenResult {
    match (readOpenAICodexOAuthProfile()) {
        case Some(profile) =>
            if (refreshIfExpiring && profile.expiresAtUnixSeconds - clock.unixSeconds() <= OPENAI_CODEX_REFRESH_SKEW_SECONDS) {
                return refreshOpenAICodexAccessToken(profile, clock, httpClient)
            }
            OpenAICodexAccessTokenResult("ok", accessToken: profile.accessToken, profile: Some(profile))
        case None =>
            OpenAICodexAccessTokenResult(
                "missing",
                error: Some(OpenAICodexAuthError(
                    "missing_oauth_profile",
                    "OpenAI Codex OAuth profile is not configured.",
                    reloginRequired: true,
                    retryable: false
                ))
            )
    }
}

public func resolveOpenAICodexAccessTokenForProfile(
    profileId: String,
    activeAccessToken: Option<String>,
    clock: OpenAICodexClock,
    httpClient: OpenAICodexHttpClient,
    refreshIfExpiring!: Bool = true
): OpenAICodexAccessTokenResult {
    let requested = profileId.trimAscii()
    if (requested != OPENAI_CODEX_DEFAULT_PROFILE_ID) {
        return OpenAICodexAccessTokenResult(
            "profile_mismatch",
            error: Some(OpenAICodexAuthError(
                "profile_mismatch",
                "Requested OpenAI Codex OAuth profile does not match the configured default profile.",
                reloginRequired: true,
                retryable: false
            ))
        )
    }
    match (readOpenAICodexOAuthProfile()) {
        case Some(profile) =>
            match (activeAccessToken) {
                case Some(token) =>
                    if (!token.isEmpty() && token != profile.accessToken) {
                        return OpenAICodexAccessTokenResult(
                            "profile_mismatch",
                            accessToken: profile.accessToken,
                            profile: Some(profile),
                            error: Some(OpenAICodexAuthError(
                                "profile_mismatch",
                                "OpenAI Codex OAuth refresh was blocked because the active token does not match the configured profile.",
                                reloginRequired: true,
                                retryable: false
                            )),
                            refreshed: false,
                            refreshAttempted: false
                        )
                    }
                case None => ()
            }
            resolveOpenAICodexAccessToken(clock, httpClient, refreshIfExpiring: refreshIfExpiring)
        case None => resolveOpenAICodexAccessToken(clock, httpClient, refreshIfExpiring: refreshIfExpiring)
    }
}

public func redactOpenAICodexTokenPreview(token: String): String {
    let trimmed = token.trimAscii()
    if (trimmed.isEmpty()) {
        return ""
    }
    if (trimmed.size <= 8) {
        return "redacted"
    }
    "${trimmed[0..4]}...${trimmed[trimmed.size - 4..trimmed.size]}"
}

public func openAICodexOAuthProfileSummary(profile: OpenAICodexOAuthProfile): JsonObject {
    let out = JsonObject()
    out.put("provider", JsonString(profile.provider))
    out.put("profileId", JsonString(profile.profileId))
    out.put("authMethod", JsonString(profile.authMethod))
    out.put("baseUrl", JsonString(profile.baseUrl))
    out.put("accountLabel", JsonString(profile.accountLabel))
    out.put("source", JsonString(profile.source))
    out.put("oauthConfigured", (!profile.accessToken.isEmpty() && !profile.refreshToken.isEmpty()).toJsonValue())
    out.put("tokenPreview", JsonString(redactOpenAICodexTokenPreview(profile.accessToken)))
    out.put("lastRefreshUnixSeconds", JsonInt(profile.lastRefreshUnixSeconds))
    out.put("expiresAtUnixSeconds", JsonInt(profile.expiresAtUnixSeconds))
    out
}

public func getOpenAICodexAuthStatus(clock: OpenAICodexClock): OpenAICodexAuthStatus {
    match (selectOpenAICodexPoolEntry(clock.unixSeconds())) {
        case Some(entry) =>
            return OpenAICodexAuthStatus(
                "logged_in",
                loggedIn: true,
                source: entry.source,
                accountLabel: entry.label,
                tokenPreview: redactOpenAICodexTokenPreview(entry.accessToken),
                lastRefreshUnixSeconds: entry.lastRefreshUnixSeconds,
                expiresAtUnixSeconds: entry.expiresAtUnixSeconds,
                oauthConfigured: true
            )
        case None => ()
    }
    match (readOpenAICodexOAuthProfile()) {
        case Some(profile) =>
            OpenAICodexAuthStatus(
                "logged_in",
                loggedIn: true,
                source: profile.source,
                accountLabel: profile.accountLabel,
                tokenPreview: redactOpenAICodexTokenPreview(profile.accessToken),
                lastRefreshUnixSeconds: profile.lastRefreshUnixSeconds,
                expiresAtUnixSeconds: profile.expiresAtUnixSeconds,
                oauthConfigured: true
            )
        case None =>
            OpenAICodexAuthStatus("logged_out", loggedIn: false, oauthConfigured: false)
    }
}

public func renderOpenAICodexAuthStatus(status: OpenAICodexAuthStatus): String {
    if (!status.loggedIn) {
        return "OpenAI Codex OAuth: logged out"
    }
    let label = if (status.accountLabel.isEmpty()) { status.source } else { "${status.accountLabel} (${status.source})" }
    "OpenAI Codex OAuth: logged in via ${label}; token ${status.tokenPreview}; expiresAt=${status.expiresAtUnixSeconds}"
}

public func loadOpenAICodexOAuthStore(path!: Path = MetisConfigManager.configPath()): OpenAICodexOAuthStoreLoadResult {
    if (!exists(path)) {
        return OpenAICodexOAuthStoreLoadResult("missing", JsonObject())
    }
    try {
        OpenAICodexOAuthStoreLoadResult("ok", JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject())
    } catch (_: Exception) {
        let corruptPath = Path("${path.toString()}.corrupt")
        try { copy(path, to: corruptPath, overwrite: true) } catch (_: Exception) { () }
        OpenAICodexOAuthStoreLoadResult("corrupt", JsonObject(), corruptPath: corruptPath.toString())
    }
}

public func openAICodexPathModeOctal(path: Path): String {
    try {
        let (exitCode, stdoutBytes, _) = executeWithOutput("stat", ["-f", "%Lp", path.toString()])
        if (exitCode == 0) {
            return String.fromUtf8(stdoutBytes).trimAscii()
        }
    } catch (_: Exception) {
        ()
    }
    ""
}

public func saveOpenAICodexOAuthStoreAtomic(root: JsonObject, path!: Path = MetisConfigManager.configPath()): OpenAICodexOAuthStoreWriteResult {
    let parent = path.parent
    Directory.create(parent, recursive: true)
    try { chmod(parent.toString(), UInt32(0o700)) } catch (_: Exception) { () }
    let tmpPath = Path("${path.toString()}.tmp")
    try { remove(tmpPath, recursive: true) } catch (_: Exception) { () }
    File.writeTo(tmpPath, root.toJsonString().toArray())
    try { chmod(tmpPath.toString(), UInt32(0o600)) } catch (_: Exception) { () }
    rename(tmpPath, to: path, overwrite: true)
    try { chmod(path.toString(), UInt32(0o600)) } catch (_: Exception) { () }
    OpenAICodexOAuthStoreWriteResult(
        "ok",
        path.toString(),
        parentMode: openAICodexPathModeOctal(parent),
        fileMode: openAICodexPathModeOctal(path)
    )
}

public func readCodexCliAuthProfile(codexHome: Path): Option<OpenAICodexOAuthProfile> {
    let authPath = codexHome.join("auth.json")
    if (!exists(authPath)) {
        return None<OpenAICodexOAuthProfile>
    }
    try {
        let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(authPath))).asObject()
        let accessToken = codexJsonString(root, "access_token").getOrDefault {
            codexJsonString(root, "accessToken").getOrDefault { "" }
        }
        let refreshToken = codexJsonString(root, "refresh_token").getOrDefault {
            codexJsonString(root, "refreshToken").getOrDefault { "" }
        }
        if (accessToken.isEmpty() || refreshToken.isEmpty()) {
            return None<OpenAICodexOAuthProfile>
        }
        let now = DateTime.now().toUnixTimeStamp().toSeconds()
        Some(OpenAICodexOAuthProfile(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtUnixSeconds: codexJsonInt(root, "expires_at").getOrDefault { now + 3600 },
            lastRefreshUnixSeconds: codexJsonInt(root, "last_refresh").getOrDefault { now },
            accountLabel: codexJsonString(root, "account_id").getOrDefault { "Codex CLI import" },
            source: "codex-cli-import"
        ))
    } catch (_: Exception) {
        None<OpenAICodexOAuthProfile>
    }
}

public func importCodexCliAuthWithConsent(codexHome: Path, consent: Bool): OpenAICodexAccessTokenResult {
    if (!consent) {
        return OpenAICodexAccessTokenResult(
            "blocked",
            error: Some(OpenAICodexAuthError(
                "codex_cli_import_requires_consent",
                "Codex CLI OAuth tokens are only imported after explicit consent.",
                reloginRequired: false,
                retryable: false
            ))
        )
    }
    match (readCodexCliAuthProfile(codexHome)) {
        case Some(profile) =>
            let persisted = writeOpenAICodexOAuthProfile(profile)
            OpenAICodexAccessTokenResult("ok", accessToken: persisted.accessToken, profile: Some(persisted))
        case None =>
            OpenAICodexAccessTokenResult(
                "missing",
                error: Some(OpenAICodexAuthError(
                    "missing_codex_cli_auth",
                    "Codex CLI auth.json does not contain importable OAuth tokens.",
                    reloginRequired: false,
                    retryable: false
                ))
            )
    }
}

public func openAICodexDefaultCodexHome(): Path {
    match (getVariable("CODEX_HOME")) {
        case Some(value) =>
            let trimmed = value.trimAscii()
            if (!trimmed.isEmpty()) {
                return Path(trimmed)
            }
        case None => ()
    }
    match (getVariable("HOME")) {
        case Some(home) => Path(home).join(".codex")
        case None => Path(".").join(".codex")
    }
}

public func logoutOpenAICodexAndResetModelConfig(root: JsonObject): OpenAICodexLogoutResetResult {
    var removedProfile = false
    match (codexJsonObject(root, "auth")) {
        case Some(auth) =>
            match (codexJsonObject(auth, "profiles")) {
                case Some(profiles) =>
                    if (profiles.get(OPENAI_CODEX_DEFAULT_PROFILE_ID).isSome()) {
                        auth.put("profiles", codexObjectWithoutKey(profiles, OPENAI_CODEX_DEFAULT_PROFILE_ID))
                        removedProfile = true
                    }
                case None => ()
            }
        case None => ()
    }
    var resetProvider = false
    match (codexJsonObject(root, "model")) {
        case Some(model) =>
            if (codexJsonString(model, "provider").getOrDefault { "" }.trimAscii() == OPENAI_CODEX_OAUTH_PROVIDER_ID) {
                model.put("provider", JsonString("auto"))
                model.put("baseUrl", JsonString("https://openrouter.ai/api/v1"))
                resetProvider = true
            }
        case None => ()
    }
    match (codexJsonObject(root, "agents")) {
        case Some(agents) =>
            match (codexJsonObject(agents, "defaults")) {
                case Some(defaults) =>
                    match (codexJsonObject(defaults, "model")) {
                        case Some(model) =>
                            let primary = codexJsonString(model, "primary").getOrDefault { "" }
                            if (primary.startsWith("openai-codex/") || primary.startsWith("openai-codex:")) {
                                model.put("primary", JsonString("auto"))
                                resetProvider = true
                            }
                        case None => ()
                    }
                case None => ()
            }
        case None => ()
    }
    OpenAICodexLogoutResetResult(
        "ok",
        removedProfile: removedProfile,
        resetProvider: resetProvider,
        message: "OpenAI Codex OAuth profile removed; provider reset=${resetProvider}."
    )
}

public func persistOpenAICodexLogoutAndReset(): OpenAICodexLogoutResetResult {
    let root = match (MetisConfigManager.rawConfig()) {
        case Some(existing) => codexCloneObject(existing)
        case None => JsonObject()
    }
    let result = logoutOpenAICodexAndResetModelConfig(root)
    MetisConfigManager.writeRoot(root)
    suppressOpenAICodexDeviceCodeReseed()
    result
}
