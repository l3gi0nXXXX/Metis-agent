package metis.core.model

import magic.core.model.ChatRequest

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock, OpenAICodexOAuthProfile, writeOpenAICodexOAuthProfile}

import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString}

private func codexFactoryTestRestoreVariable(name: String, value: Option<String>): Unit {
    match (value) {
        case Some(v) => setVariable(name, v)
        case None => setVariable(name, "")
    }
}

private func codexFactoryTestResetCaches(): Unit {
    CliConfig.invalidatePathCache()
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
}

private func withCodexFactoryTestHome<T>(label: String, block: (Path) -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/tmp").join("metis-codex-factory-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        try { remove(home, recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", home.toString())
        codexFactoryTestResetCaches()
        try {
            return block(home)
        } finally {
            codexFactoryTestRestoreVariable("METIS_HOME", oldHome)
            codexFactoryTestResetCaches()
            try { remove(home, recursive: true) } catch (_: Exception) { () }
        }
    }
}

@Test
public class CodexResponsesModelFactoryTest {
    @TestCase
    public func factoryBuildsCodexResponsesModelFromOAuthProfile(): Unit {
        withCodexFactoryTestHome("m2-cli-manager-codex-profile") { _home =>
            let now = DateTime.now().toUnixTimeStamp().toSeconds()
            let _ = writeOpenAICodexOAuthProfile(OpenAICodexOAuthProfile(
                accessToken: "factory-access-token",
                refreshToken: "factory-refresh-token",
                expiresAtUnixSeconds: now + 3600,
                lastRefreshUnixSeconds: now,
                accountLabel: "factory",
                source: "test"
            ))
            let model = buildOpenAICodexResponsesChatModelForRef("openai-codex:gpt-5.5")
            @Expect(model.fullName, "openai-codex:gpt-5.5")
            @Expect(model is CodexResponsesChatModel, true)
        }
    }

    @TestCase
    public func factoryReturnsUnavailableModelWhenOAuthProfileMissing(): Unit {
        withCodexFactoryTestHome("m2-cli-manager-codex-missing") { _home =>
            let model = buildOpenAICodexResponsesChatModelForRef("openai-codex:gpt-5.5")
            @Expect(model.fullName, "openai-codex:gpt-5.5")
            @Expect(model is CodexAuthUnavailableChatModel, true)
            var message = ""
            try {
                let _ = model.create(ChatRequest("hello"))
            } catch (e: Exception) {
                message = e.message
            }
            @Expect(message.contains("metis models auth openai-codex login"), true)
        }
    }

    @TestCase
    public func factoryCodexResponsesModelUsesConfiguredTransportDiagnostic(): Unit {
        withCodexFactoryTestHome("m5-codex-responses-proxy", { _home =>
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

            let now = DateTime.now().toUnixTimeStamp().toSeconds()
            let _ = writeOpenAICodexOAuthProfile(OpenAICodexOAuthProfile(
                accessToken: "factory-access-token-never-print",
                refreshToken: "factory-refresh-token-never-print",
                expiresAtUnixSeconds: now + 3600,
                lastRefreshUnixSeconds: now,
                accountLabel: "factory",
                source: "test"
            ))
            let model = buildOpenAICodexResponsesChatModelForRef("openai-codex:gpt-5.5")
            var message = ""
            try {
                let _ = model.create(ChatRequest("hello"))
            } catch (ex: Exception) {
                message = ex.message
            }

            @Expect(message.contains("Codex Responses HTTP request failed"), true)
            @Expect(message.contains("true HTTPS proxy is not implemented"), true)
            @Expect(message.contains("unsupportedHttpsProxy"), true)
            @Expect(message.contains("[redacted]@127.0.0.1:7897"), true)
            @Expect(message.contains("secret"), false)
            @Expect(message.contains("factory-access-token-never-print"), false)
        })
    }
}
