package metis.core.config

import magic.jsonable.*

import std.collection.ArrayList
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists}
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonInt, JsonObject, JsonString, JsonValue}

private class FakeCodexClock <: OpenAICodexClock {
    public var nowSeconds: Int64

    public init(nowSeconds: Int64) {
        this.nowSeconds = nowSeconds
    }

    public func unixSeconds(): Int64 {
        this.nowSeconds
    }
}

private class FakeCodexHttpClient <: OpenAICodexHttpClient {
    public let jsonUrls = ArrayList<String>()
    public let jsonBodies = ArrayList<String>()
    public let formUrls = ArrayList<String>()
    public let formBodies = ArrayList<String>()
    private let jsonResponses = ArrayList<OpenAICodexHttpResponse>()
    private let formResponses = ArrayList<OpenAICodexHttpResponse>()

    public init() {}

    public func queueJson(statusCode: Int64, body: String): Unit {
        this.jsonResponses.add(OpenAICodexHttpResponse(statusCode, body))
    }

    public func queueForm(statusCode: Int64, body: String): Unit {
        this.formResponses.add(OpenAICodexHttpResponse(statusCode, body))
    }

    public func postJson(url: String, body: String): OpenAICodexHttpResponse {
        this.jsonUrls.add(url)
        this.jsonBodies.add(body)
        if (this.jsonResponses.size == 0) {
            return OpenAICodexHttpResponse(500, "{\"error\":\"unexpected_json_call\"}")
        }
        this.jsonResponses.remove(at: 0)
    }

    public func postForm(url: String, body: String): OpenAICodexHttpResponse {
        this.formUrls.add(url)
        this.formBodies.add(body)
        if (this.formResponses.size == 0) {
            return OpenAICodexHttpResponse(500, "{\"error\":\"unexpected_form_call\"}")
        }
        this.formResponses.remove(at: 0)
    }
}

private func oauthTestString(root: JsonObject, key: String): String {
    match (root.get(key)) {
        case Some(value) => try { value.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func oauthTestBool(root: JsonObject, key: String): Bool {
    match (root.get(key)) {
        case Some(value) => try { value.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

private func oauthTestInt(root: JsonObject, key: String): Int64 {
    match (root.get(key)) {
        case Some(value) => try { value.asInt().getValue() } catch (_: Exception) { 0 }
        case None => 0
    }
}

private func oauthTestObject(root: JsonObject, key: String): JsonObject {
    match (root.get(key)) {
        case Some(value) => try { value.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func oauthTestArray(root: JsonObject, key: String): JsonArray {
    match (root.get(key)) {
        case Some(value) => try { value.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func oauthTestProfile(access: String, refresh!: String = "refresh-secret", expiresAt!: Int64 = 5000, label!: String = "acct"): OpenAICodexOAuthProfile {
    OpenAICodexOAuthProfile(
        accessToken: access,
        refreshToken: refresh,
        expiresAtUnixSeconds: expiresAt,
        lastRefreshUnixSeconds: 1000,
        accountLabel: label,
        source: "device-code"
    )
}

private func oauthTestRootWithModelRef(modelRef: String): JsonObject {
    let root = JsonObject()
    let agents = JsonObject()
    let defaults = JsonObject()
    let model = JsonObject()
    model.put("primary", JsonString(modelRef))
    model.put("fallbacks", JsonArray([]))
    defaults.put("model", model)
    agents.put("defaults", defaults)
    root.put("agents", agents)
    root
}

private func oauthTestInstallProfile(root: JsonObject, profile: OpenAICodexOAuthProfile): Unit {
    let auth = JsonObject()
    let profiles = JsonObject()
    profiles.put(OPENAI_CODEX_DEFAULT_PROFILE_ID, profile.toJsonObject())
    auth.put("profiles", profiles)
    root.put("auth", auth)
}

private func oauthTestPoolEntry(
    id: String,
    source: String,
    access: String,
    status!: String = "ok",
    resetAt!: Int64 = 0
): JsonObject {
    OpenAICodexPoolEntry(
        id: id,
        source: source,
        accessToken: access,
        refreshToken: "refresh-${access}",
        expiresAtUnixSeconds: 9000,
        lastRefreshUnixSeconds: 1000,
        lastStatus: status,
        lastErrorResetAtUnixSeconds: resetAt,
        lastErrorCode: if (status == "ok") { "" } else { "invalid_grant" },
        lastErrorReason: if (status == "ok") { "" } else { "fake failure" }
    ).toJsonObject()
}

private func oauthTestInstallPool(root: JsonObject, entries: Array<JsonObject>): Unit {
    let auth = match (root.get("auth")) {
        case Some(value) => try { value.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
    let pool = JsonObject()
    let arr = JsonArray([])
    for (entry in entries) {
        arr.add(entry)
    }
    pool.put(OPENAI_CODEX_OAUTH_PROVIDER_ID, arr)
    auth.put("credentialPool", pool)
    root.put("auth", auth)
}

private func oauthTestResetEnv(name: String, value: Option<String>): Unit {
    match (value) {
        case Some(existing) => setVariable(name, existing)
        case None => setVariable(name, "")
    }
}

@Test
public class OpenAICodexOAuthStoreTest {
    @TestCase
    public func M1_U1_deviceFlowWritesCanonicalOauthProfileOnly(): Unit {
        withMetisConfigTestHome("m1-u1-device-flow") { _ =>
            let http = FakeCodexHttpClient()
            http.queueJson(200, "{\"device_auth_id\":\"dev-1\",\"user_code\":\"USER-1\",\"interval\":1,\"expires_in\":900}")
            http.queueJson(403, "{\"error\":\"authorization_pending\"}")
            http.queueJson(200, "{\"authorization_code\":\"auth-code-1\",\"code_verifier\":\"verifier-1\"}")
            http.queueForm(200, "{\"access_token\":\"access-secret-u1\",\"refresh_token\":\"refresh-secret-u1\",\"expires_in\":3600}")
            let result = loginOpenAICodexWithDeviceFlow(http, FakeCodexClock(1000), sleepBetweenPolls: false)
            @Expect(result.status, "ok")
            @Expect(http.jsonUrls[0], OPENAI_CODEX_DEVICE_AUTH_USERCODE_URL)
            @Expect(http.jsonBodies[0], "{\"client_id\":\"${OPENAI_CODEX_OAUTH_CLIENT_ID}\"}")
            @Expect(http.jsonUrls[1], OPENAI_CODEX_DEVICE_AUTH_TOKEN_URL)
            @Expect(http.jsonUrls[2], OPENAI_CODEX_DEVICE_AUTH_TOKEN_URL)
            @Expect(http.formUrls[0], OPENAI_CODEX_OAUTH_TOKEN_URL)
            @Expect(http.formBodies[0].contains("grant_type=authorization_code"), true)

            let profile = readOpenAICodexOAuthProfile().getOrThrow()
            @Expect(profile.provider, OPENAI_CODEX_OAUTH_PROVIDER_ID)
            @Expect(profile.profileId, OPENAI_CODEX_DEFAULT_PROFILE_ID)
            @Expect(profile.accessToken, "access-secret-u1")
            @Expect(profile.expiresAtUnixSeconds, 4600)

            let root = MetisConfigManager.rawConfig().getOrThrow()
            let provider = oauthTestObject(oauthTestObject(oauthTestObject(root, "models"), "providers"), "openai-codex")
            @Expect(provider.get("apiKey").isNone(), true)
            @Expect(openAICodexOAuthProfileSummary(profile).toJsonString().contains("access-secret-u1"), false)
        }
    }

    @TestCase
    public func M1_B1_U2_refreshSkewAndClassifiedErrorsDoNotLeakToken(): Unit {
        withMetisConfigTestHome("m1-b1-u2-refresh") { _ =>
            let clock = FakeCodexClock(1000)
            writeOpenAICodexOAuthProfile(oauthTestProfile("access-old", refresh: "refresh-old", expiresAt: 1120))
            let http = FakeCodexHttpClient()
            http.queueForm(200, "{\"access_token\":\"access-new\",\"refresh_token\":\"refresh-new\",\"expires_in\":7200}")
            let refreshed = resolveOpenAICodexAccessToken(clock, http)
            @Expect(refreshed.status, "ok")
            @Expect(refreshed.refreshed, true)
            @Expect(refreshed.refreshAttempted, true)
            @Expect(refreshed.accessToken, "access-new")
            @Expect(http.formBodies[0].contains("grant_type=refresh_token"), true)

            writeOpenAICodexOAuthProfile(oauthTestProfile("access-valid", refresh: "refresh-valid", expiresAt: 1121))
            let noRefreshHttp = FakeCodexHttpClient()
            let noRefresh = resolveOpenAICodexAccessToken(clock, noRefreshHttp)
            @Expect(noRefresh.status, "ok")
            @Expect(noRefresh.refreshed, false)
            @Expect(noRefreshHttp.formUrls.size, 0)

            let rateLimited = classifyOpenAICodexRefreshError(429, "{\"error\":\"rate_limit_exceeded\",\"refresh_token\":\"secret\"}")
            @Expect(rateLimited.code, "rate_limited")
            @Expect(rateLimited.reloginRequired, false)
            @Expect(rateLimited.retryable, true)
            @Expect(rateLimited.message.contains("secret"), false)
            let invalidGrant = classifyOpenAICodexRefreshError(400, "{\"error\":\"invalid_grant\",\"access_token\":\"secret\"}")
            @Expect(invalidGrant.reloginRequired, true)
            @Expect(invalidGrant.message.contains("secret"), false)
            let reused = classifyOpenAICodexRefreshError(400, "{\"error\":{\"code\":\"refresh_token_reused\"}}")
            @Expect(reused.code, "refresh_token_reused")
            @Expect(reused.reloginRequired, true)

            let missingRefresh = refreshOpenAICodexAccessToken(
                oauthTestProfile("access-no-refresh", refresh: "", expiresAt: 1000),
                clock,
                FakeCodexHttpClient()
            )
            @Expect(missingRefresh.status, "refresh_failed")
            @Expect(missingRefresh.error.getOrThrow().code, "missing_refresh_token")
            @Expect(missingRefresh.error.getOrThrow().message.contains("access-no-refresh"), false)
        }
    }

    @TestCase
    public func M1_U3_atomicStoreUsesPrivateModesAndPreservesCorruptJson(): Unit {
        withMetisConfigTestHome("m1-u3-store") { home =>
            let root = JsonObject()
            root.put("auth", JsonObject())
            let path = home.join("nested").join("auth-store.json")
            let written = saveOpenAICodexOAuthStoreAtomic(root, path: path)
            @Expect(written.status, "ok")
            @Expect(written.parentMode, "700")
            @Expect(written.fileMode, "600")
            @Expect(exists(path), true)

            File.writeTo(path, "{not-json".toArray())
            let loaded = loadOpenAICodexOAuthStore(path: path)
            @Expect(loaded.status, "corrupt")
            @Expect(exists(Path(loaded.corruptPath)), true)
            @Expect(loaded.root.size(), 0)
        }
    }

    @TestCase
    public func M1_U4_B3_poolFallbackAndReauthSyncRulesAreSourceAware(): Unit {
        withMetisConfigTestHome("m1-u4-b3-pool") { _ =>
            let root = oauthTestRootWithModelRef("openai-codex/gpt-5.5")
            oauthTestInstallProfile(root, oauthTestProfile("access-singleton-new", refresh: "refresh-singleton-new", expiresAt: 8000))
            oauthTestInstallPool(root, [
                oauthTestPoolEntry("future", OPENAI_CODEX_POOL_SOURCE_MANUAL_DEVICE_CODE, "access-future", resetAt: 9999),
                oauthTestPoolEntry("canonical", OPENAI_CODEX_POOL_SOURCE_DEVICE_CODE, "access-old", status: "dead"),
                oauthTestPoolEntry("manual-old", OPENAI_CODEX_POOL_SOURCE_MANUAL_DEVICE_CODE, "access-old"),
                oauthTestPoolEntry("manual-independent", OPENAI_CODEX_POOL_SOURCE_MANUAL_DEVICE_CODE, "access-independent")
            ])
            MetisConfigManager.writeRoot(root)

            let selected = selectOpenAICodexPoolEntry(1000).getOrThrow()
            @Expect(selected.id, "canonical")
            @Expect(selected.accessToken, "access-singleton-new")

            let previous = oauthTestProfile("access-singleton-new", refresh: "refresh-singleton-new", expiresAt: 8000)
            let next = oauthTestProfile("access-after-reauth", refresh: "refresh-after-reauth", expiresAt: 9000)
            let changed = syncOpenAICodexPoolOnReauth(Some(previous), next)
            @Expect(changed, 1)
            let entries = listOpenAICodexPoolEntries()
            var canonicalToken = ""
            var independentToken = ""
            for (entry in entries) {
                if (entry.id == "canonical") {
                    canonicalToken = entry.accessToken
                }
                if (entry.id == "manual-independent") {
                    independentToken = entry.accessToken
                }
            }
            @Expect(canonicalToken, "access-after-reauth")
            @Expect(independentToken, "access-independent")
        }
    }

    @TestCase
    public func M1_U5_manualDeviceCodeCredentialsDoNotOverwriteSingletonAndFirstActivatesProvider(): Unit {
        withMetisConfigTestHome("m1-u5-manual-pool") { _ =>
            let one = oauthTestProfile("access-manual-1", refresh: "refresh-manual-1")
            let two = oauthTestProfile("access-manual-2", refresh: "refresh-manual-2")
            let entryOne = addOpenAICodexManualDeviceCodeCredential("account-one", one)
            let entryTwo = addOpenAICodexManualDeviceCodeCredential("account-two", two)
            @Expect(entryOne.source, OPENAI_CODEX_POOL_SOURCE_MANUAL_DEVICE_CODE)
            @Expect(entryTwo.source, OPENAI_CODEX_POOL_SOURCE_MANUAL_DEVICE_CODE)
            @Expect(readOpenAICodexOAuthProfile().isNone(), true)
            let entries = listOpenAICodexPoolEntries()
            @Expect(entries.size, 2)
            @Expect(entries[0].accessToken, "access-manual-1")
            @Expect(entries[1].accessToken, "access-manual-2")
            let auth = oauthTestObject(MetisConfigManager.rawConfig().getOrThrow(), "auth")
            @Expect(oauthTestString(auth, "activeProvider"), "openai-codex")
        }
    }

    @TestCase
    public func M1_U6_statusPrefersPoolThenSingletonAndRendererRedacts(): Unit {
        withMetisConfigTestHome("m1-u6-status") { _ =>
            let loggedOut = getOpenAICodexAuthStatus(FakeCodexClock(1000))
            @Expect(loggedOut.status, "logged_out")

            writeOpenAICodexOAuthProfile(oauthTestProfile("access-singleton-visible", refresh: "refresh-singleton"))
            let singletonStatus = getOpenAICodexAuthStatus(FakeCodexClock(1000))
            @Expect(singletonStatus.status, "logged_in")
            @Expect(singletonStatus.source, "device-code")
            @Expect(renderOpenAICodexAuthStatus(singletonStatus).contains("access-singleton-visible"), false)

            addOpenAICodexManualDeviceCodeCredential("pooled", oauthTestProfile("access-pooled-visible", refresh: "refresh-pooled"))
            let pooledStatus = getOpenAICodexAuthStatus(FakeCodexClock(1000))
            @Expect(pooledStatus.source, OPENAI_CODEX_POOL_SOURCE_MANUAL_DEVICE_CODE)
            @Expect(renderOpenAICodexAuthStatus(pooledStatus).contains("access-pooled-visible"), false)
        }
    }

    @TestCase
    public func M1_U7_dashboardWorkerUsesFakeDeviceFlowAndReturnsRedactedSummary(): Unit {
        withMetisConfigTestHome("m1-u7-dashboard") { _ =>
            let http = FakeCodexHttpClient()
            http.queueJson(200, "{\"device_auth_id\":\"dev-dash\",\"user_code\":\"DASH-1\",\"interval\":3,\"expires_in\":900}")
            http.queueJson(200, "{\"authorization_code\":\"dash-code\",\"code_verifier\":\"dash-verifier\"}")
            http.queueForm(200, "{\"access_token\":\"access-dashboard-secret\",\"refresh_token\":\"refresh-dashboard-secret\",\"expires_in\":3600}")
            let out = startOpenAICodexDashboardDeviceFlow(http, FakeCodexClock(2000))
            @Expect(oauthTestString(out, "status"), "ok")
            @Expect(oauthTestString(out, "providerId"), "openai-codex")
            @Expect(oauthTestBool(out, "oauthConfigured"), true)
            @Expect(out.toJsonString().contains("access-dashboard-secret"), false)
            @Expect(readOpenAICodexOAuthProfile().isSome(), true)
        }
    }

    @TestCase
    public func M1_B2_N3_codexCliImportRequiresConsentAndDoesNotDeleteCodexHome(): Unit {
        withMetisConfigTestHome("m1-b2-n3-codex-cli") { home =>
            let codexHome = home.join(".codex")
            Directory.create(codexHome, recursive: true)
            File.writeTo(codexHome.join("auth.json"), "{\"access_token\":\"codex-cli-access\",\"refresh_token\":\"codex-cli-refresh\"}".toArray())
            let blocked = importCodexCliAuthWithConsent(codexHome, false)
            @Expect(blocked.status, "blocked")
            @Expect(readOpenAICodexOAuthProfile().isNone(), true)
            @Expect(exists(codexHome.join("auth.json")), true)

            let imported = importCodexCliAuthWithConsent(codexHome, true)
            @Expect(imported.status, "ok")
            @Expect(readOpenAICodexOAuthProfile().getOrThrow().source, "codex-cli-import")
            @Expect(exists(codexHome.join("auth.json")), true)
        }
    }

    @TestCase
    public func M1_B4_singletonLoginDecisionOrdersReuseCliImportThenFreshDeviceCode(): Unit {
        let existing = oauthTestProfile("access-existing", refresh: "refresh-existing")
        let cli = oauthTestProfile("access-cli", refresh: "refresh-cli")
        let fresh = oauthTestProfile("access-fresh", refresh: "refresh-fresh")

        let reuse = planOpenAICodexSingletonLogin(Some(existing), Some(cli), fresh)
        @Expect(reuse.status, "reuse_existing")
        @Expect(reuse.profile.getOrThrow().accessToken, "access-existing")

        let imported = planOpenAICodexSingletonLogin(
            Some(existing),
            Some(cli),
            fresh,
            forceNewLogin: true,
            importCodexCliWithConsent: true
        )
        @Expect(imported.status, "import_codex_cli")
        @Expect(imported.profile.getOrThrow().accessToken, "access-cli")

        let device = planOpenAICodexSingletonLogin(
            None<OpenAICodexOAuthProfile>,
            Some(cli),
            fresh,
            importCodexCliWithConsent: false
        )
        @Expect(device.status, "fresh_device_code")
        @Expect(device.transcript[0], "codex_cli_import_declined")
    }

    @TestCase
    public func M1_N1_N2_negativeDeviceFlowAndProfileMismatchDoNotSwitchAccounts(): Unit {
        withMetisConfigTestHome("m1-n1-n2-negative") { _ =>
            let deniedHttp = FakeCodexHttpClient()
            deniedHttp.queueJson(403, "{\"error\":\"access_denied\",\"access_token\":\"secret\"}")
            let denied = pollOpenAICodexDeviceToken("dev", "USER", deniedHttp, maxWaitSeconds: 3, sleepBetweenPolls: false)
            @Expect(denied.status, "access_denied")
            @Expect(denied.message.contains("secret"), false)

            let expiredHttp = FakeCodexHttpClient()
            expiredHttp.queueJson(404, "{\"error\":\"expired_token\"}")
            let expired = pollOpenAICodexDeviceToken("dev", "USER", expiredHttp, maxWaitSeconds: 3, sleepBetweenPolls: false)
            @Expect(expired.status, "expired_token")

            writeOpenAICodexOAuthProfile(oauthTestProfile("access-account-a", refresh: "refresh-account-a", expiresAt: 1000))
            let refreshHttp = FakeCodexHttpClient()
            refreshHttp.queueForm(200, "{\"access_token\":\"access-account-b\",\"refresh_token\":\"refresh-account-b\",\"expires_in\":3600}")
            let mismatch = resolveOpenAICodexAccessTokenForProfile(
                OPENAI_CODEX_DEFAULT_PROFILE_ID,
                Some("different-active-token"),
                FakeCodexClock(1000),
                refreshHttp
            )
            @Expect(mismatch.status, "profile_mismatch")
            @Expect(mismatch.refreshAttempted, false)
            @Expect(refreshHttp.formUrls.size, 0)
            @Expect(readOpenAICodexOAuthProfile().getOrThrow().accessToken, "access-account-a")
        }
    }

    @TestCase
    public func M1_N4_N5_removalSuppressesReseedAndLogoutResetDoesNotTouchCodexHome(): Unit {
        withMetisConfigTestHome("m1-n4-n5-logout-reset") { home =>
            let oldCodexHome = getVariable("CODEX_HOME")
            let codexHome = home.join(".codex")
            Directory.create(codexHome, recursive: true)
            File.writeTo(codexHome.join("auth.json"), "{\"access_token\":\"codex-home-stays\"}".toArray())
            try {
                setVariable("CODEX_HOME", codexHome.toString())
                let root = oauthTestRootWithModelRef("openai-codex/gpt-5.5")
                oauthTestInstallProfile(root, oauthTestProfile("access-logout", refresh: "refresh-logout"))
                let model = JsonObject()
                model.put("provider", JsonString("openai-codex"))
                model.put("baseUrl", JsonString("https://chatgpt.com/backend-api/codex"))
                root.put("model", model)
                MetisConfigManager.writeRoot(root)

                let removed = removeOpenAICodexOAuthProfile()
                @Expect(removed, true)
                @Expect(isOpenAICodexDeviceCodeReseedSuppressed(), true)
                @Expect(exists(codexHome.join("auth.json")), true)

                let resetRoot = MetisConfigManager.rawConfig().getOrThrow()
                let reset = logoutOpenAICodexAndResetModelConfig(resetRoot)
                @Expect(reset.status, "ok")
                @Expect(reset.resetProvider, true)
                @Expect(oauthTestString(oauthTestObject(resetRoot, "model"), "provider"), "auto")
                @Expect(exists(codexHome.join("auth.json")), true)
            } finally {
                oauthTestResetEnv("CODEX_HOME", oldCodexHome)
            }
        }
    }

    @TestCase
    public func M1_scopeCredentialSummaryReportsOauthExternalWithoutApiKeyOrToken(): Unit {
        withMetisConfigTestHome("m1-scope-oauth-summary") { home =>
            let root = oauthTestRootWithModelRef("openai-codex/gpt-5.5")
            oauthTestInstallProfile(root, oauthTestProfile("access-scope-secret", refresh: "refresh-scope-secret"))
            let models = JsonObject()
            let providers = JsonObject()
            let codex = JsonObject()
            codex.put("baseUrl", JsonString("https://chatgpt.com/backend-api/codex"))
            providers.put("openai-codex", codex)
            models.put("providers", providers)
            root.put("models", models)

            let scope = MetisAgentScope.resolve(root, homeRoot: home, defaultWorkspace: home.join("workspace"))
            let accountSummary = oauthTestObject(scope, "accountSummary")
            let rendered = accountSummary.toJsonString()
            @Expect(oauthTestString(accountSummary, "authKind"), "oauth_external")
            @Expect(oauthTestBool(accountSummary, "oauthConfigured"), true)
            @Expect(oauthTestBool(accountSummary, "apiKeyConfigured"), false)
            @Expect(rendered.contains("access-scope-secret"), false)
            @Expect(rendered.contains("refresh-scope-secret"), false)
        }
    }
}
