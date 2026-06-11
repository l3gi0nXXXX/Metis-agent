package metis.core.config

import magic.jsonable.*

import std.time.*
import stdx.encoding.json.{JsonInt, JsonObject, JsonString, JsonValue}

public let OPENAI_CODEX_DEVICE_AUTH_USERCODE_URL: String =
    "https://auth.openai.com/api/accounts/deviceauth/usercode"
public let OPENAI_CODEX_DEVICE_AUTH_TOKEN_URL: String =
    "https://auth.openai.com/api/accounts/deviceauth/token"
public let OPENAI_CODEX_DEVICE_AUTH_REDIRECT_URI: String =
    "https://auth.openai.com/deviceauth/callback"

public class OpenAICodexDeviceAuthStartResult {
    public let status: String
    public let deviceAuthId: String
    public let userCode: String
    public let verificationUrl: String
    public let expiresInSeconds: Int64
    public let pollIntervalSeconds: Int64
    public let errorCode: String
    public let message: String

    public init(
        status: String,
        deviceAuthId!: String = "",
        userCode!: String = "",
        verificationUrl!: String = "",
        expiresInSeconds!: Int64 = 0,
        pollIntervalSeconds!: Int64 = 3,
        errorCode!: String = "",
        message!: String = ""
    ) {
        this.status = status.trimAscii()
        this.deviceAuthId = deviceAuthId.trimAscii()
        this.userCode = userCode.trimAscii()
        this.verificationUrl = verificationUrl.trimAscii()
        this.expiresInSeconds = expiresInSeconds
        this.pollIntervalSeconds = if (pollIntervalSeconds < 3) { 3 } else { pollIntervalSeconds }
        this.errorCode = errorCode.trimAscii()
        this.message = message.trimAscii()
    }
}

public class OpenAICodexDeviceTokenPollResult {
    public let status: String
    public let authorizationCode: String
    public let codeVerifier: String
    public let errorCode: String
    public let message: String
    public let pollAttempts: Int64
    public let pollIntervalSeconds: Int64
    public let maxWaitSeconds: Int64

    public init(
        status: String,
        authorizationCode!: String = "",
        codeVerifier!: String = "",
        errorCode!: String = "",
        message!: String = "",
        pollAttempts!: Int64 = 0,
        pollIntervalSeconds!: Int64 = 3,
        maxWaitSeconds!: Int64 = 900
    ) {
        this.status = status.trimAscii()
        this.authorizationCode = authorizationCode.trimAscii()
        this.codeVerifier = codeVerifier.trimAscii()
        this.errorCode = errorCode.trimAscii()
        this.message = message.trimAscii()
        this.pollAttempts = pollAttempts
        this.pollIntervalSeconds = if (pollIntervalSeconds < 3) { 3 } else { pollIntervalSeconds }
        this.maxWaitSeconds = maxWaitSeconds
    }
}

public class OpenAICodexTokenExchangeResult {
    public let status: String
    public let profile: Option<OpenAICodexOAuthProfile>
    public let errorCode: String
    public let message: String

    public init(
        status: String,
        profile!: Option<OpenAICodexOAuthProfile> = None<OpenAICodexOAuthProfile>,
        errorCode!: String = "",
        message!: String = ""
    ) {
        this.status = status.trimAscii()
        this.profile = profile
        this.errorCode = errorCode.trimAscii()
        this.message = message.trimAscii()
    }
}

public class OpenAICodexDeviceLoginResult {
    public let status: String
    public let start: OpenAICodexDeviceAuthStartResult
    public let poll: OpenAICodexDeviceTokenPollResult
    public let exchange: OpenAICodexTokenExchangeResult
    public let profile: Option<OpenAICodexOAuthProfile>

    public init(
        status: String,
        start: OpenAICodexDeviceAuthStartResult,
        poll: OpenAICodexDeviceTokenPollResult,
        exchange: OpenAICodexTokenExchangeResult,
        profile!: Option<OpenAICodexOAuthProfile> = None<OpenAICodexOAuthProfile>
    ) {
        this.status = status.trimAscii()
        this.start = start
        this.poll = poll
        this.exchange = exchange
        this.profile = profile
    }
}

private func deviceJsonString(root: JsonObject, key: String): Option<String> {
    match (root.get(key)) {
        case Some(value) => try { Some(value.asString().getValue()) } catch (_: Exception) { None }
        case None => None
    }
}

private func deviceJsonInt(root: JsonObject, key: String): Option<Int64> {
    match (root.get(key)) {
        case Some(value) => try { Some(value.asInt().getValue()) } catch (_: Exception) { None }
        case None => None
    }
}

private func deviceBodyErrorCode(body: String): String {
    try {
        let root = JsonValue.fromStr(body).asObject()
        let direct = deviceJsonString(root, "error").getOrDefault {
            deviceJsonString(root, "code").getOrDefault {
                deviceJsonString(root, "error_code").getOrDefault { "" }
            }
        }
        return direct.trimAscii()
    } catch (_: Exception) {
        ""
    }
}

public func beginOpenAICodexDeviceAuth(httpClient: OpenAICodexHttpClient): OpenAICodexDeviceAuthStartResult {
    let body = "{\"client_id\":\"${OPENAI_CODEX_OAUTH_CLIENT_ID}\"}"
    let response = httpClient.postJson(OPENAI_CODEX_DEVICE_AUTH_USERCODE_URL, body)
    if (response.statusCode < 200 || response.statusCode >= 300) {
        return OpenAICodexDeviceAuthStartResult(
            "failed",
            errorCode: deviceBodyErrorCode(response.body),
            message: "OpenAI Codex device authorization request failed."
        )
    }
    try {
        let payload = JsonValue.fromStr(response.body).asObject()
        let deviceAuthId = deviceJsonString(payload, "device_auth_id").getOrDefault {
            deviceJsonString(payload, "deviceAuthId").getOrDefault { "" }
        }
        let userCode = deviceJsonString(payload, "user_code").getOrDefault {
            deviceJsonString(payload, "userCode").getOrDefault { "" }
        }
        if (deviceAuthId.isEmpty() || userCode.isEmpty()) {
            return OpenAICodexDeviceAuthStartResult(
                "failed",
                errorCode: "missing_device_code",
                message: "OpenAI Codex device authorization response was incomplete."
            )
        }
        OpenAICodexDeviceAuthStartResult(
            "pending",
            deviceAuthId: deviceAuthId,
            userCode: userCode,
            verificationUrl: deviceJsonString(payload, "verification_uri").getOrDefault {
                deviceJsonString(payload, "verification_url").getOrDefault {
                    "https://auth.openai.com/codex/device"
                }
            },
            expiresInSeconds: deviceJsonInt(payload, "expires_in").getOrDefault { 900 },
            pollIntervalSeconds: deviceJsonInt(payload, "interval").getOrDefault { 3 },
            message: "Open the verification URL and enter the user code."
        )
    } catch (_: Exception) {
        OpenAICodexDeviceAuthStartResult(
            "failed",
            errorCode: "invalid_device_auth_response",
            message: "OpenAI Codex device authorization response was not valid JSON."
        )
    }
}

public func pollOpenAICodexDeviceToken(
    deviceAuthId: String,
    userCode: String,
    httpClient: OpenAICodexHttpClient,
    pollIntervalSeconds!: Int64 = 3,
    maxWaitSeconds!: Int64 = 900,
    sleepBetweenPolls!: Bool = true
): OpenAICodexDeviceTokenPollResult {
    let interval = if (pollIntervalSeconds < 3) { 3 } else { pollIntervalSeconds }
    let waitLimit = if (maxWaitSeconds > 900) { 900 } else { maxWaitSeconds }
    let maxAttempts = if (waitLimit <= 0) { 1 } else { max(Int64(1), waitLimit / interval) }
    var attempts: Int64 = 0
    let body = "{\"device_auth_id\":\"${deviceAuthId}\",\"user_code\":\"${userCode}\"}"
    while (attempts < maxAttempts) {
        attempts += 1
        let response = httpClient.postJson(OPENAI_CODEX_DEVICE_AUTH_TOKEN_URL, body)
        if (response.statusCode >= 200 && response.statusCode < 300) {
            try {
                let payload = JsonValue.fromStr(response.body).asObject()
                let code = deviceJsonString(payload, "authorization_code").getOrDefault {
                    deviceJsonString(payload, "code").getOrDefault { "" }
                }
                let verifier = deviceJsonString(payload, "code_verifier").getOrDefault {
                    deviceJsonString(payload, "codeVerifier").getOrDefault { "" }
                }
                if (!code.isEmpty() && !verifier.isEmpty()) {
                    return OpenAICodexDeviceTokenPollResult(
                        "authorized",
                        authorizationCode: code,
                        codeVerifier: verifier,
                        pollAttempts: attempts,
                        pollIntervalSeconds: interval,
                        maxWaitSeconds: waitLimit
                    )
                }
                return OpenAICodexDeviceTokenPollResult(
                    "failed",
                    errorCode: "missing_authorization_code",
                    message: "OpenAI Codex device token response was incomplete.",
                    pollAttempts: attempts,
                    pollIntervalSeconds: interval,
                    maxWaitSeconds: waitLimit
                )
            } catch (_: Exception) {
                return OpenAICodexDeviceTokenPollResult(
                    "failed",
                    errorCode: "invalid_device_token_response",
                    message: "OpenAI Codex device token response was not valid JSON.",
                    pollAttempts: attempts,
                    pollIntervalSeconds: interval,
                    maxWaitSeconds: waitLimit
                )
            }
        }
        if (response.statusCode == 403 || response.statusCode == 404) {
            let code = deviceBodyErrorCode(response.body).toAsciiLower()
            if (code == "authorization_pending" || code == "slow_down" || code.isEmpty()) {
                if (sleepBetweenPolls && attempts < maxAttempts) {
                    sleep(Duration.second * interval)
                }
                continue
            }
            if (code == "access_denied" || code == "expired_token" || code == "invalid_grant") {
                return OpenAICodexDeviceTokenPollResult(
                    code,
                    errorCode: code,
                    message: "OpenAI Codex device authorization did not complete.",
                    pollAttempts: attempts,
                    pollIntervalSeconds: interval,
                    maxWaitSeconds: waitLimit
                )
            }
        }
        let errorCode = deviceBodyErrorCode(response.body)
        return OpenAICodexDeviceTokenPollResult(
            "failed",
            errorCode: if (errorCode.isEmpty()) { "device_poll_failed" } else { errorCode },
            message: "OpenAI Codex device authorization polling failed.",
            pollAttempts: attempts,
            pollIntervalSeconds: interval,
            maxWaitSeconds: waitLimit
        )
    }
    OpenAICodexDeviceTokenPollResult(
        "timeout",
        errorCode: "device_auth_timeout",
        message: "OpenAI Codex device authorization timed out.",
        pollAttempts: attempts,
        pollIntervalSeconds: interval,
        maxWaitSeconds: waitLimit
    )
}

public func exchangeOpenAICodexAuthorizationCode(
    authorizationCode: String,
    codeVerifier: String,
    httpClient: OpenAICodexHttpClient,
    clock: OpenAICodexClock,
    accountLabel!: String = "",
    source!: String = "device-code"
): OpenAICodexTokenExchangeResult {
    let body = openAICodexTokenForm([
        ("grant_type", "authorization_code"),
        ("client_id", OPENAI_CODEX_OAUTH_CLIENT_ID),
        ("code", authorizationCode),
        ("code_verifier", codeVerifier),
        ("redirect_uri", OPENAI_CODEX_DEVICE_AUTH_REDIRECT_URI)
    ])
    let response = httpClient.postForm(OPENAI_CODEX_OAUTH_TOKEN_URL, body)
    if (response.statusCode < 200 || response.statusCode >= 300) {
        let err = classifyOpenAICodexRefreshError(response.statusCode, response.body)
        return OpenAICodexTokenExchangeResult("failed", errorCode: err.code, message: err.message)
    }
    try {
        let payload = JsonValue.fromStr(response.body).asObject()
        let accessToken = deviceJsonString(payload, "access_token").getOrDefault { "" }
        let refreshToken = deviceJsonString(payload, "refresh_token").getOrDefault { "" }
        if (accessToken.isEmpty() || refreshToken.isEmpty()) {
            return OpenAICodexTokenExchangeResult(
                "failed",
                errorCode: "missing_oauth_tokens",
                message: "OpenAI Codex OAuth token exchange response was incomplete."
            )
        }
        let now = clock.unixSeconds()
        let profile = OpenAICodexOAuthProfile(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtUnixSeconds: now + deviceJsonInt(payload, "expires_in").getOrDefault { 3600 },
            lastRefreshUnixSeconds: now,
            accountLabel: accountLabel,
            source: source
        )
        OpenAICodexTokenExchangeResult("ok", profile: Some(profile))
    } catch (_: Exception) {
        OpenAICodexTokenExchangeResult(
            "failed",
            errorCode: "invalid_token_exchange_response",
            message: "OpenAI Codex OAuth token exchange response was not valid JSON."
        )
    }
}

public func loginOpenAICodexWithDeviceFlow(
    httpClient: OpenAICodexHttpClient,
    clock: OpenAICodexClock,
    sleepBetweenPolls!: Bool = true
): OpenAICodexDeviceLoginResult {
    let start = beginOpenAICodexDeviceAuth(httpClient)
    if (start.status != "pending") {
        return OpenAICodexDeviceLoginResult(
            "failed",
            start,
            OpenAICodexDeviceTokenPollResult("not_started"),
            OpenAICodexTokenExchangeResult("not_started")
        )
    }
    let poll = pollOpenAICodexDeviceToken(
        start.deviceAuthId,
        start.userCode,
        httpClient,
        pollIntervalSeconds: start.pollIntervalSeconds,
        maxWaitSeconds: start.expiresInSeconds,
        sleepBetweenPolls: sleepBetweenPolls
    )
    if (poll.status != "authorized") {
        return OpenAICodexDeviceLoginResult("failed", start, poll, OpenAICodexTokenExchangeResult("not_started"))
    }
    let exchange = exchangeOpenAICodexAuthorizationCode(
        poll.authorizationCode,
        poll.codeVerifier,
        httpClient,
        clock
    )
    match (exchange.profile) {
        case Some(profile) =>
            let persisted = writeOpenAICodexOAuthProfile(profile)
            OpenAICodexDeviceLoginResult("ok", start, poll, exchange, profile: Some(persisted))
        case None =>
            OpenAICodexDeviceLoginResult("failed", start, poll, exchange)
    }
}

public func startOpenAICodexDashboardDeviceFlow(
    httpClient: OpenAICodexHttpClient,
    clock: OpenAICodexClock
): JsonObject {
    let login = loginOpenAICodexWithDeviceFlow(httpClient, clock)
    let out = JsonObject()
    out.put("status", JsonString(login.status))
    out.put("providerId", JsonString(OPENAI_CODEX_OAUTH_PROVIDER_ID))
    out.put("verificationUrl", JsonString(login.start.verificationUrl))
    out.put("userCode", JsonString(login.start.userCode))
    out.put("pollAttempts", JsonInt(login.poll.pollAttempts))
    match (login.profile) {
        case Some(profile) =>
            out.put("oauthConfigured", true.toJsonValue())
            out.put("summary", openAICodexOAuthProfileSummary(profile))
        case None => out.put("oauthConfigured", false.toJsonValue())
    }
    out
}
