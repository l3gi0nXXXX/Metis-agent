package metis.core.support_surface_tests

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager}
import metis.core.config.{OpenAICodexClock, OpenAICodexHttpClient, OpenAICodexHttpResponse, OpenAICodexOAuthProfile, listOpenAICodexPoolEntries, readOpenAICodexOAuthProfile, writeOpenAICodexOAuthProfile}
import metis.gateway.logging.{gatewayLoggingCurrentLogFile, gatewayLoggingResetForTest}
import metis.program.{executeCliLogsCommand, executeCliModelsAuthCommand}
import metis.program_support.*

import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.unittest.testmacro.*
import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonInt, JsonObject, JsonString, JsonValue}

private func withLogsCliTestHome<T>(block: () -> T): T {
    let testHome = "/tmp/metis-logs-cli-test-home"
    try {
        remove(Path(testHome), recursive: true)
    } catch (_e: Exception) {
        ()
    }
    Directory.create(testHome, recursive: true)
    let oldHome = getVariable("METIS_HOME")
    let oldMetisLogFile = getVariable("METIS_LOG_FILE")
    setVariable("METIS_HOME", testHome)
    CliConfig.invalidatePathCache()
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
    gatewayLoggingResetForTest()
    try {
        return block()
    } finally {
        match (oldHome) {
            case Some(value) => setVariable("METIS_HOME", value)
            case None => setVariable("METIS_HOME", "")
        }
        match (oldMetisLogFile) {
            case Some(value) => setVariable("METIS_LOG_FILE", value)
            case None => setVariable("METIS_LOG_FILE", "")
        }
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        gatewayLoggingResetForTest()
    }
}

private class CliAuthFakeClock <: OpenAICodexClock {
    public let nowSeconds: Int64

    public init(nowSeconds: Int64) {
        this.nowSeconds = nowSeconds
    }

    public func unixSeconds(): Int64 {
        this.nowSeconds
    }
}

private class CliAuthFakeHttpClient <: OpenAICodexHttpClient {
    public let jsonUrls = ArrayList<String>()
    public let formUrls = ArrayList<String>()
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
        if (this.jsonResponses.size == 0) {
            return OpenAICodexHttpResponse(500, "{\"error\":\"unexpected_json_call\"}")
        }
        this.jsonResponses.remove(at: 0)
    }

    public func postForm(url: String, body: String): OpenAICodexHttpResponse {
        this.formUrls.add(url)
        if (this.formResponses.size == 0) {
            return OpenAICodexHttpResponse(500, "{\"error\":\"unexpected_form_call\"}")
        }
        this.formResponses.remove(at: 0)
    }
}

private func withModelsAuthCliTestHome<T>(name: String, block: (Path) -> T): T {
    let testHome = "/tmp/${name}"
    try {
        remove(Path(testHome), recursive: true)
    } catch (_e: Exception) {
        ()
    }
    Directory.create(testHome, recursive: true)
    let oldHome = getVariable("METIS_HOME")
    let oldCodexHome = getVariable("CODEX_HOME")
    setVariable("METIS_HOME", testHome)
    setVariable("CODEX_HOME", "")
    CliConfig.invalidatePathCache()
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
    try {
        return block(Path(testHome))
    } finally {
        match (oldHome) {
            case Some(value) => setVariable("METIS_HOME", value)
            case None => setVariable("METIS_HOME", "")
        }
        match (oldCodexHome) {
            case Some(value) => setVariable("CODEX_HOME", value)
            case None => setVariable("CODEX_HOME", "")
        }
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
    }
}

private func cliAuthProfile(access: String, refresh!: String = "refresh-secret", expiresAt!: Int64 = 5000): OpenAICodexOAuthProfile {
    OpenAICodexOAuthProfile(
        accessToken: access,
        refreshToken: refresh,
        expiresAtUnixSeconds: expiresAt,
        lastRefreshUnixSeconds: 1000,
        accountLabel: "acct",
        source: "device-code"
    )
}

@Test
public class CliLocalFlowsTest {
    @BeforeAll
    public func isolateMetisHome(): Unit {
        setVariable("METIS_HOME", "/tmp/metis-program-cli-local-flows-test-home")
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
    }

    @TestCase
    public func localCommandSummaryRendersHumanTextWithoutRawJson(): Unit {
        let steps = ArrayList<JsonValue>()
        steps.add(JsonString("metis models current"))
        steps.add(JsonString("metis models providers"))

        let obj = JsonObject()
        obj.put("kind", JsonString("models"))
        obj.put("subcommand", JsonString("status"))
        obj.put("currentModel", JsonString("ark:kimi-k2-250905"))
        obj.put("provider", JsonString("ark"))
        obj.put("nextSteps", JsonArray(steps))

        let rendered = programSupportRenderLocalCommandSummary(obj)

        @Expect(rendered.contains("Metis models status"), true)
        @Expect(rendered.contains("Current model: ark:kimi-k2-250905"), true)
        @Expect(rendered.contains("Next steps:"), true)
        @Expect(rendered.contains("{"), false)
        @Expect(rendered.contains("\"kind\""), false)
        @Expect(rendered.contains("Machine output: rerun with --json."), true)
    }

    @TestCase
    public func localCommandSummaryHidesNestedCatalogDetails(): Unit {
        let providers = ArrayList<JsonValue>()
        providers.add(JsonString("ark"))

        let obj = JsonObject()
        obj.put("kind", JsonString("models"))
        obj.put("subcommand", JsonString("providers"))
        obj.put("providers", JsonArray(providers))

        let rendered = programSupportRenderLocalCommandSummary(obj)

        @Expect(rendered.contains("Metis models providers"), true)
        @Expect(rendered.contains("Catalog details: available with --json"), true)
    }

    @TestCase
    public func modelsStatusMentionsIndependentImageModel(): Unit {
        let root = JsonObject()
        let agents = JsonObject()
        let defaults = JsonObject()
        let model = JsonObject()
        model.put("primary", JsonString("deepseek/deepseek-v4-pro"))
        defaults.put("model", model)
        let imageModel = JsonObject()
        imageModel.put("primary", JsonString("qwen/qwen3.6-plus"))
        imageModel.put("fallbacks", JsonArray([JsonString("openai/gpt-4o")]))
        defaults.put("imageModel", imageModel)
        agents.put("defaults", defaults)
        root.put("agents", agents)
        root.put("gateway", JsonObject())
        MetisConfigManager.writeRoot(root)
        CliSettingManager.applyPersistedFieldsToCliConfig()

        let rendered = programSupportRenderModelsStatus()

        @Expect(rendered.contains("Image primary: qwen:qwen3.6-plus"), true)
        @Expect(rendered.contains("Image fallbacks: openai:gpt-4o"), true)
        @Expect(rendered.contains("independent from the main chat model"), true)
    }

    @TestCase
    public func pdfStatusRendersHumanTextWithoutRawJson(): Unit {
        let root = JsonObject()
        let agents = JsonObject()
        let defaults = JsonObject()
        let pdfModel = JsonObject()
        pdfModel.put("primary", JsonString("anthropic/claude-sonnet-4-5"))
        defaults.put("pdfModel", pdfModel)
        defaults.put("pdfMaxPages", JsonInt(12))
        agents.put("defaults", defaults)
        root.put("agents", agents)
        MetisConfigManager.writeRoot(root)
        CliSettingManager.applyPersistedFieldsToCliConfig()

        let rendered = programSupportRenderPdfStatus()

        @Expect(rendered.contains("PDF tool status"), true)
        @Expect(rendered.contains("Model candidates: 1 (configured)"), true)
        @Expect(rendered.contains("anthropic:claude-sonnet-4-5"), true)
        @Expect(rendered.contains("native PDF: yes"), true)
        @Expect(rendered.contains("maxPages=12"), true)
        @Expect(rendered.contains("pdfjs-dist"), true)
        @Expect(rendered.contains("{"), false)
        @Expect(rendered.contains("\"ok\""), false)
        @Expect(rendered.contains("\"result\""), false)
        @Expect(rendered.contains("\"sessions\""), false)
    }

    @TestCase
    public func logFileGetterIsStableWithinProcess(): Unit {
        withLogsCliTestHome({ =>
            let first = CliConfig.logFile.toString()
            let second = CliConfig.logFile.toString()
            @Expect(first, second)
        })
    }

    @TestCase
    public func logsCliRendersRecentCurrentTailAndJsonlWithoutRawJsonByDefault(): Unit {
        withLogsCliTestHome({ =>
            let first = "{\"ts\":\"2026-05-18T10:00:00.000Z\",\"level\":\"info\",\"subsystem\":\"gateway\",\"event\":\"ready\",\"message\":\"gateway ready\"}\n"
            let second = "{\"ts\":\"2026-05-18T10:00:01.000Z\",\"level\":\"warn\",\"subsystem\":\"gateway/channel/telegram\",\"event\":\"poll.retry\",\"message\":\"retrying poll\"}\n"
            let third = "plain fallback line\n"
            let logPath = CliConfig.logsDir.join("2026_05_18-10_00_00_000.log")
            File.writeTo(logPath, "${first}${second}${third}".toArray())
            setVariable("METIS_LOG_FILE", logPath.toString())
            gatewayLoggingResetForTest()

            let (recent, recentCode) = executeCliLogsCommand(["recent", "--limit", "1"])
            @Expect(recentCode, 0)
            @Expect(recent.contains("Recent log files:"), true)
            @Expect(recent.contains("2026_05_18-10_00_00_000.log"), true)
            @Expect(recent.contains("\"level\""), false)

            let (current, currentCode) = executeCliLogsCommand(["current"])
            @Expect(currentCode, 0)
            @Expect(current.contains("Current log file:"), true)
            @Expect(current.contains(logPath.toString()), true)
            @Expect(current.contains(gatewayLoggingCurrentLogFile()), true)

            let (tail, tailCode) = executeCliLogsCommand(["tail", "--limit", "2"])
            @Expect(tailCode, 0)
            @Expect(tail.contains("poll.retry retrying poll"), true)
            @Expect(tail.contains("plain fallback line"), true)
            @Expect(tail.contains("\"message\""), false)

            let (jsonl, jsonCode) = executeCliLogsCommand(["tail", "--limit", "1", "--json"])
            @Expect(jsonCode, 0)
            let rows = jsonl.split("\n")
            @Expect(JsonValue.fromStr(rows[0]).asObject().get("type").getOrThrow().asString().getValue(), "meta")
            @Expect(JsonValue.fromStr(rows[1]).asObject().get("type").getOrThrow().asString().getValue(), "raw")
        })
    }

    @TestCase
    public func logsCliTailHonorsCursorLimitAndMaxBytes(): Unit {
        withLogsCliTestHome({ =>
            let first = "{\"ts\":\"2026-05-18T10:00:00.000Z\",\"level\":\"info\",\"subsystem\":\"gateway\",\"event\":\"one\",\"message\":\"one\"}\n"
            let second = "{\"ts\":\"2026-05-18T10:00:01.000Z\",\"level\":\"info\",\"subsystem\":\"gateway\",\"event\":\"two\",\"message\":\"two\"}\n"
            let third = "{\"ts\":\"2026-05-18T10:00:02.000Z\",\"level\":\"info\",\"subsystem\":\"gateway\",\"event\":\"three\",\"message\":\"three\"}\n"
            let logPath = CliConfig.logsDir.join("2026_05_18-10_00_01_000.log")
            File.writeTo(logPath, "${first}${second}${third}".toArray())
            setVariable("METIS_LOG_FILE", logPath.toString())
            gatewayLoggingResetForTest()

            let cursor = Int64(first.toArray().size)
            let (cursorTail, cursorCode) = executeCliLogsCommand(["tail", "--cursor", "${cursor}", "--limit", "10", "--json"])
            @Expect(cursorCode, 0)
            @Expect(cursorTail.contains("\"event\":\"one\""), false)
            @Expect(cursorTail.contains("\"event\":\"two\""), true)
            @Expect(cursorTail.contains("\"event\":\"three\""), true)

            let (limited, limitedCode) = executeCliLogsCommand(["tail", "--limit", "1", "--json"])
            @Expect(limitedCode, 0)
            @Expect(limited.contains("\"event\":\"two\""), false)
            @Expect(limited.contains("\"event\":\"three\""), true)

            let (truncated, truncatedCode) = executeCliLogsCommand(["tail", "--cursor", "0", "--max-bytes", "80", "--json"])
            @Expect(truncatedCode, 0)
            @Expect(truncated.contains("\"type\":\"notice\""), true)
            @Expect(truncated.contains("truncated"), true)
        })
    }

    @TestCase
    public func logsCliTailKeepsUtf8WhenMaxBytesUsesByteCursor(): Unit {
        withLogsCliTestHome({ =>
            let first = "{\"ts\":\"2026-05-18T10:00:00.000Z\",\"level\":\"info\",\"subsystem\":\"gateway\",\"event\":\"first\",\"message\":\"前置日志\"}\n"
            let second = "{\"ts\":\"2026-05-18T10:00:01.000Z\",\"level\":\"info\",\"subsystem\":\"gateway\",\"event\":\"second\",\"message\":\"尾部中文\"}\n"
            let logPath = CliConfig.logsDir.join("2026_05_18-10_00_02_000.log")
            File.writeTo(logPath, "${first}${second}".toArray())
            setVariable("METIS_LOG_FILE", logPath.toString())
            gatewayLoggingResetForTest()

            let maxBytes = Int64(second.toArray().size)
            let (tail, code) = executeCliLogsCommand(["tail", "--limit", "5", "--max-bytes", "${maxBytes}", "--json"])

            @Expect(code, 0)
            @Expect(tail.contains("尾部中文"), true)
            @Expect(tail.contains("前置日志"), false)
        })
    }

    @TestCase
    public func modelsAuthOpenAICodexLoginStatusAndLogoutUseHumanRedactedOutput(): Unit {
        withModelsAuthCliTestHome("metis-models-auth-openai-codex-login", { _home: Path =>
            let http = CliAuthFakeHttpClient()
            http.queueJson(200, "{\"device_auth_id\":\"dev-1\",\"user_code\":\"USER-1\",\"verification_uri\":\"https://auth.example/device\",\"interval\":3,\"expires_in\":3}")
            http.queueJson(200, "{\"authorization_code\":\"auth-code-1\",\"code_verifier\":\"verifier-1\"}")
            http.queueForm(200, "{\"access_token\":\"access-secret-never-print\",\"refresh_token\":\"refresh-secret-never-print\",\"expires_in\":3600}")

            let (loginText, loginCode) = executeCliModelsAuthCommand(
                ["openai-codex", "login", "--force"],
                httpClient: Some<OpenAICodexHttpClient>(http),
                clock: CliAuthFakeClock(1000)
            )
            @Expect(loginCode, 0)
            @Expect(loginText.contains("OpenAI Codex device login"), true)
            @Expect(loginText.contains("USER-1"), true)
            @Expect(loginText.contains("logged in"), true)
            @Expect(loginText.contains("access-secret-never-print"), false)
            @Expect(loginText.contains("refresh-secret-never-print"), false)
            @Expect(readOpenAICodexOAuthProfile().isSome(), true)

            let (statusText, statusCode) = executeCliModelsAuthCommand(
                ["openai-codex", "status"],
                clock: CliAuthFakeClock(1001)
            )
            @Expect(statusCode, 0)
            @Expect(statusText.contains("OpenAI Codex OAuth: logged in"), true)
            @Expect(statusText.contains("access-secret-never-print"), false)

            let (logoutText, logoutCode) = executeCliModelsAuthCommand(["openai-codex", "logout"])
            @Expect(logoutCode, 0)
            @Expect(logoutText.contains("Logged out of OpenAI Codex"), true)
            @Expect(readOpenAICodexOAuthProfile().isNone(), true)
        })
    }

    @TestCase
    public func modelsAuthOpenAICodexDefaultNativeClientUsesConfiguredProxyDiagnostic(): Unit {
        withModelsAuthCliTestHome("metis-models-auth-openai-codex-native-proxy", { _home: Path =>
            let root = JsonObject()
            let models = JsonObject()
            let providers = JsonObject()
            let codex = JsonObject()
            codex.put("proxy", JsonString("https://user:secret@127.0.0.1:7897"))
            providers.put("openai-codex", codex)
            models.put("providers", providers)
            root.put("models", models)
            MetisConfigManager.writeRoot(root)
            CliSettingManager.applyPersistedFieldsToCliConfig()

            let (loginText, loginCode) = executeCliModelsAuthCommand(["openai-codex", "login", "--force"])

            @Expect(loginCode, 1)
            @Expect(loginText.contains("OpenAI Codex OAuth login failed"), true)
            @Expect(loginText.contains("true HTTPS proxy is not implemented"), true)
            @Expect(loginText.contains("unsupportedHttpsProxy"), true)
            @Expect(loginText.contains("secret"), false)
            @Expect(loginText.contains("[redacted]@127.0.0.1:7897"), true)
        })
    }

    @TestCase
    public func modelsAuthOpenAICodexImportRequiresExplicitConsent(): Unit {
        withModelsAuthCliTestHome("metis-models-auth-openai-codex-import", { home: Path =>
            let codexHome = home.join(".codex")
            Directory.create(codexHome, recursive: true)
            File.writeTo(
                codexHome.join("auth.json"),
                "{\"access_token\":\"codex-cli-access-secret\",\"refresh_token\":\"codex-cli-refresh-secret\",\"account_id\":\"cli-account\"}".toArray()
            )

            let (blockedText, blockedCode) = executeCliModelsAuthCommand(
                ["openai-codex", "import-codex-cli", "--codex-home", codexHome.toString()]
            )
            @Expect(blockedCode, 1)
            @Expect(blockedText.contains("explicit consent"), true)
            @Expect(readOpenAICodexOAuthProfile().isNone(), true)

            let (importText, importCode) = executeCliModelsAuthCommand(
                ["openai-codex", "import-codex-cli", "--codex-home", codexHome.toString(), "--yes"],
                clock: CliAuthFakeClock(2000)
            )
            @Expect(importCode, 0)
            @Expect(importText.contains("Imported OpenAI Codex OAuth credentials"), true)
            @Expect(importText.contains("codex-cli-access-secret"), false)
            @Expect(importText.contains("codex-cli-refresh-secret"), false)
            @Expect(readOpenAICodexOAuthProfile().getOrThrow().source, "codex-cli-import")
        })
    }

    @TestCase
    public func modelsAuthAddOpenAICodexWritesManualPoolWithoutReplacingSingleton(): Unit {
        withModelsAuthCliTestHome("metis-models-auth-openai-codex-add", { _home: Path =>
            writeOpenAICodexOAuthProfile(cliAuthProfile("singleton-access", refresh: "singleton-refresh"))
            let http = CliAuthFakeHttpClient()
            http.queueJson(200, "{\"device_auth_id\":\"dev-add\",\"user_code\":\"ADD-1\",\"verification_uri\":\"https://auth.example/device\",\"interval\":3,\"expires_in\":3}")
            http.queueJson(200, "{\"authorization_code\":\"add-code\",\"code_verifier\":\"add-verifier\"}")
            http.queueForm(200, "{\"access_token\":\"manual-access-secret\",\"refresh_token\":\"manual-refresh-secret\",\"expires_in\":3600}")

            let (addText, addCode) = executeCliModelsAuthCommand(
                ["add", "openai-codex", "--label", "work"],
                httpClient: Some<OpenAICodexHttpClient>(http),
                clock: CliAuthFakeClock(3000)
            )
            @Expect(addCode, 0)
            @Expect(addText.contains("OpenAI Codex account added"), true)
            @Expect(addText.contains("manual-access-secret"), false)
            @Expect(readOpenAICodexOAuthProfile().getOrThrow().accessToken, "singleton-access")
            let pool = listOpenAICodexPoolEntries()
            @Expect(pool.size, 1)
            @Expect(pool[0].label, "work")
            @Expect(pool[0].source, "manual:device_code")
        })
    }
}
