package metis.core.model

import std.fs.{Directory, File, Path, exists, remove}
import std.process.executeWithOutput
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

@Test
public class CodexRuntimeSwitchTest {
    private func tempRoot(label: String): Path {
        let root = Path("/tmp/metis-m4-runtime-${label}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        root
    }

    private func fakeCodex(version: String): String {
        let path = this.tempRoot("codex").join("codex")
        File.writeTo(path, "#!/bin/sh\nprintf 'codex-cli ${version}\\n'\n".toArray())
        let (_exitCode, _stdout, _stderr) = executeWithOutput("chmod", ["+x", path.toString()])
        path.toString()
    }

    @TestCase
    public func runtimeParseAndConfigKeysAreFixed(): Unit {
        @Expect(CODEX_RUNTIME_CONFIG_DEFAULT_KEY, "agents.defaults.model.openaiRuntime")
        @Expect(CODEX_RUNTIME_CONFIG_AGENT_KEY, "agents.list[].model.openaiRuntime")
        @Expect(parseCodexRuntimeSwitchArgs("on").desiredRuntime.getOrThrow(), CODEX_RUNTIME_APP_SERVER)
        @Expect(parseCodexRuntimeSwitchArgs("codex").desiredRuntime.getOrThrow(), CODEX_RUNTIME_APP_SERVER)
        @Expect(parseCodexRuntimeSwitchArgs("off").desiredRuntime.getOrThrow(), CODEX_RUNTIME_AUTO)
        @Expect(parseCodexRuntimeSwitchArgs("status").desiredRuntime.isNone(), true)
        @Expect(parseCodexRuntimeSwitchArgs("").desiredRuntime.isNone(), true)
        @Expect(parseCodexRuntimeSwitchArgs("bogus").errors.isEmpty(), false)
        @Expect(normalizeCodexRuntimeValue("openai").isNone(), true)
    }

    @TestCase
    public func configMigrationMovesLegacyKeysAndFallsBackInvalidEnums(): Unit {
        let root = JsonObject()
        let agents = JsonObject()
        let defaults = JsonObject()
        let defaultModel = JsonObject()
        defaultModel.put("openai_runtime", JsonString(CODEX_RUNTIME_APP_SERVER))
        defaults.put("model", defaultModel)
        agents.put("defaults", defaults)

        let list = JsonArray([])
        let agent = JsonObject()
        let agentModel = JsonObject()
        agentModel.put("openaiRuntime", JsonString("bad-runtime"))
        agent.put("model", agentModel)
        list.add(agent)
        agents.put("list", list)
        root.put("agents", agents)

        let result = codexRuntimeMigrateConfig(root)
        @Expect(result.changed, true)
        @Expect(codexRuntimeReadDefaultRuntime(root), CODEX_RUNTIME_APP_SERVER)
        @Expect(agentModel.get("openaiRuntime").getOrThrow().asString().getValue(), CODEX_RUNTIME_AUTO)
        @Expect(result.errors.isEmpty(), false)
        @Expect(result.migratedPaths.contains("agents.defaults.model.openaiRuntime"), true)
        @Expect(result.migratedPaths.contains("agents.list[0].model.openaiRuntime"), true)
    }

    @TestCase
    public func migrationIgnoresUnknownProviderFieldsWithoutFatalError(): Unit {
        let root = JsonObject()
        let agents = JsonObject()
        let defaults = JsonObject()
        let model = JsonObject()
        model.put("provider", JsonString("future-provider"))
        defaults.put("model", model)
        agents.put("defaults", defaults)
        root.put("agents", agents)

        let result = codexRuntimeMigrateConfig(root)
        @Expect(result.changed, false)
        @Expect(result.errors.isEmpty(), true)
        @Expect(result.warnings.isEmpty(), false)
        @Expect(codexRuntimeReadDefaultRuntime(root), CODEX_RUNTIME_AUTO)
    }

    @TestCase
    public func binaryCheckUsesFakeExecutableAndVersionFloor(): Unit {
        @Expect(parseCodexAppServerVersion("codex-cli 0.130.0").getOrThrow(), "0.130.0")
        @Expect(compareCodexSemver("0.130.0"), 1)
        @Expect(compareCodexSemver("0.125.0"), 0)
        @Expect(compareCodexSemver("0.124.9"), -1)

        let good = checkCodexAppServerBinary(command: this.fakeCodex("0.130.0"))
        @Expect(good.ok, true)
        @Expect(good.version, "0.130.0")

        let old = checkCodexAppServerBinary(command: this.fakeCodex("0.124.9"))
        @Expect(old.ok, false)
        @Expect(old.status, "too-old")
    }

    @TestCase
    public func switchBlocksMissingBinaryAndRendersHumanOutput(): Unit {
        let missing = CodexAppServerBinaryCheck(false, status: "not-found", message: "Codex CLI was not found.")
        let result = applyCodexRuntimeSwitch("auto", Some(CODEX_RUNTIME_APP_SERVER), binaryCheck: missing)
        @Expect(result.success, false)
        @Expect(result.mutated, false)
        @Expect(result.newValue, CODEX_RUNTIME_AUTO)

        let human = renderCodexRuntimeSwitchResult(result)
        @Expect(human.contains("\"ok\""), false)
        @Expect(human.contains("\"result\""), false)
        @Expect(human.contains("\"sessions\""), false)
    }

    @TestCase
    public func switchEnablesDisablesAndKeepsMigrationDiagnosticsNonFatal(): Unit {
        let migration = CodexRuntimeConfigMigrationResult(
            true,
            runtime: CODEX_RUNTIME_AUTO,
            errors: ["Invalid legacy value fell back to auto."],
            migratedPaths: ["agents.defaults.model.openaiRuntime"]
        )
        let enabled = applyCodexRuntimeSwitch(
            "auto",
            Some(CODEX_RUNTIME_APP_SERVER),
            binaryCheck: CodexAppServerBinaryCheck(true, status: "ok", version: "0.130.0"),
            migration: Some(migration)
        )
        @Expect(enabled.success, true)
        @Expect(enabled.mutated, true)
        @Expect(enabled.requiresCacheInvalidation, true)
        @Expect(enabled.diagnostics.isEmpty(), false)

        let disabled = applyCodexRuntimeSwitch(
            CODEX_RUNTIME_APP_SERVER,
            Some(CODEX_RUNTIME_AUTO),
            binaryCheck: CodexAppServerBinaryCheck(false, status: "not-found", message: "missing")
        )
        @Expect(disabled.success, true)
        @Expect(disabled.newValue, CODEX_RUNTIME_AUTO)
        @Expect(disabled.mutated, true)
    }
}
