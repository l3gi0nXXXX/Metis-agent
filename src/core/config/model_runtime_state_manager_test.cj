package metis.core.config

import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path}
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonInt, JsonObject, JsonString, JsonValue}

private func runtimeStateTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func runtimeStateTestBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

private func runtimeStateTestInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asInt().getValue() } catch (_: Exception) { 0 }
        case None => 0
    }
}

private func runtimeStateTestRead(path: Path): JsonObject {
    JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
}

private func runtimeStateTestProvider(root: JsonObject, providerId: String): JsonObject {
    match (root.get("providers")) {
        case Some(value) =>
            let providers = try { value.asArray() } catch (_: Exception) { JsonArray([]) }
            for (item in providers.getItems()) {
                let row = try { item.asObject() } catch (_: Exception) { JsonObject() }
                if (runtimeStateTestString(row, "provider") == providerId) {
                    return row
                }
            }
        case None => ()
    }
    JsonObject()
}

private func runtimeStateRestoreEnv(name: String, value: Option<String>): Unit {
    match (value) {
        case Some(existing) => setVariable(name, existing)
        case None => setVariable(name, "")
    }
}

private func runtimeStateTestRoot(agentId: String, modelRef: String): JsonObject {
    let root = JsonObject()
    let agents = JsonObject()
    let list = JsonArray([])
    let entry = JsonObject()
    entry.put("id", JsonString(agentId))
    let model = JsonObject()
    model.put("primary", JsonString(modelRef))
    entry.put("model", model)
    list.add(entry)
    agents.put("list", list)
    root.put("agents", agents)
    root
}

@Test
public class CliModelRuntimeStateManagerTest {
    @TestCase
    public func materializedRuntimeStateNormalizesZeroDefaultOutputLimit(): Unit {
        withMetisConfigTestHome("runtime-state-zero-output-normalized", { _home: Path =>
            let oldInput = CliConfig.defaultModelInputLimit
            let oldOutput = CliConfig.defaultModelOutputLimit
            try {
                CliConfig.defaultModelInputLimit = 0
                CliConfig.defaultModelOutputLimit = 0
                CliModelRuntimeStateManager.writeMaterializedRuntimeState()
                let root = runtimeStateTestRead(CliModelRuntimeStateManager.runtimePath())
                @Expect(runtimeStateTestInt(root, "defaultInputLimit") > 0, true)
                @Expect(runtimeStateTestInt(root, "defaultOutputLimit") > 0, true)
            } finally {
                CliConfig.defaultModelInputLimit = oldInput
                CliConfig.defaultModelOutputLimit = oldOutput
            }
        })
    }

    @TestCase
    public func materializedRuntimeStateMarksOpenAICodexAsOAuthCodexResponsesWithoutApiKey(): Unit {
        withMetisConfigTestHome("runtime-state-openai-codex-provider-row", { _home: Path =>
            CliModelRuntimeStateManager.writeMaterializedRuntimeState()
            let root = runtimeStateTestRead(CliModelRuntimeStateManager.runtimePath())
            let codex = runtimeStateTestProvider(root, "openai-codex")
            @Expect(runtimeStateTestString(codex, "runtimeProvider"), "openai-codex")
            @Expect(runtimeStateTestString(codex, "apiMode"), "codex_responses")
            @Expect(runtimeStateTestString(codex, "authKind"), "oauth_external")
            @Expect(runtimeStateTestString(codex, "runtimeMode"), "metis_tool_loop")
            @Expect(runtimeStateTestBool(codex, "requiresApiKey"), false)
            @Expect(runtimeStateTestString(codex, "baseUrl"), "https://chatgpt.com/backend-api/codex")
            @Expect(runtimeStateTestBool(codex, "configured"), false)
        })
    }

    @TestCase
    public func openAIEnvConfiguresOpenAIProviderButNotOpenAICodex(): Unit {
        withMetisConfigTestHome("runtime-state-openai-env-not-codex", { _home: Path =>
            let oldOpenAI = getVariable("OPENAI_API_KEY")
            try {
                setVariable("OPENAI_API_KEY", "test-openai-key")
                CliModelRuntimeStateManager.writeMaterializedRuntimeState()
                let root = runtimeStateTestRead(CliModelRuntimeStateManager.runtimePath())
                @Expect(runtimeStateTestBool(runtimeStateTestProvider(root, "openai"), "configured"), true)
                @Expect(runtimeStateTestBool(runtimeStateTestProvider(root, "openai-codex"), "configured"), false)
            } finally {
                runtimeStateRestoreEnv("OPENAI_API_KEY", oldOpenAI)
            }
        })
    }

    @TestCase
    public func applyingRuntimeStateIgnoresZeroDefaultOutputLimit(): Unit {
        withMetisConfigTestHome("runtime-state-zero-output-ignored", { _home: Path =>
            let oldInput = CliConfig.defaultModelInputLimit
            let oldOutput = CliConfig.defaultModelOutputLimit
            try {
                CliConfig.defaultModelInputLimit = 128 * 1024
                CliConfig.defaultModelOutputLimit = 32 * 1024
                let root = JsonObject()
                root.put("runtimePrimaryModelRef", JsonString("deepseek:deepseek-v4-pro"))
                root.put("defaultInputLimit", JsonInt(0))
                root.put("defaultOutputLimit", JsonInt(0))
                File.writeTo(CliModelRuntimeStateManager.runtimePath(), root.toJsonString().toArray())

                CliModelRuntimeStateManager.applyRuntimeStateToCliConfig()

                @Expect(CliConfig.model, "deepseek:deepseek-v4-pro")
                @Expect(CliConfig.defaultModelInputLimit, 128 * 1024)
                @Expect(CliConfig.defaultModelOutputLimit, 32 * 1024)
            } finally {
                CliConfig.defaultModelInputLimit = oldInput
                CliConfig.defaultModelOutputLimit = oldOutput
            }
        })
    }

    @TestCase
    public func refreshAgentRuntimeStateUpdatesGeneratedModelsJsonForChangedScope(): Unit {
        withMetisConfigTestHome("agent-runtime-refresh-generated", { home: Path =>
            let agentDir = home.join("agents").join("writer").join("agent")
            let workspace = home.join("workspace")
            let initialScope = MetisAgentScope.resolve(runtimeStateTestRoot("writer", "openai:gpt-4o-mini"), agentId: "writer", homeRoot: home, defaultWorkspace: workspace)
            let path = CliModelRuntimeStateManager.ensureAgentRuntimeStateForScope(agentDir, initialScope)
            let initial = runtimeStateTestRead(path)

            @Expect(runtimeStateTestString(initial, "runtimePrimaryModelRef"), "openai:gpt-4o-mini")
            @Expect(runtimeStateTestBool(initial, "generated"), true)
            @Expect(runtimeStateTestString(initial, "materializedSource"), "agent-scope")

            let updatedScope = MetisAgentScope.resolve(runtimeStateTestRoot("writer", "anthropic:claude-3-5-sonnet"), agentId: "writer", homeRoot: home, defaultWorkspace: workspace)
            let refresh = CliModelRuntimeStateManager.refreshAgentRuntimeStateForScope(agentDir, updatedScope)
            let updated = runtimeStateTestRead(path)

            @Expect(refresh.status, "refreshed")
            @Expect(refresh.refreshed, true)
            @Expect(runtimeStateTestString(updated, "runtimePrimaryModelRef"), "anthropic:claude-3-5-sonnet")
            @Expect(runtimeStateTestString(updated, "scopeFingerprint").contains("writer"), true)
        })
    }

    @TestCase
    public func refreshAgentRuntimeStatePreservesManualModelsJson(): Unit {
        withMetisConfigTestHome("agent-runtime-refresh-manual", { home: Path =>
            let agentDir = home.join("agents").join("writer").join("agent")
            let path = CliModelRuntimeStateManager.agentRuntimePath(agentDir)
            Directory.create(agentDir, recursive: true)
            File.writeTo(path, "{\"primaryModelRef\":\"manual:model\",\"runtimePrimaryModelRef\":\"manual:model\",\"providers\":[]}".toArray())

            let scope = MetisAgentScope.resolve(runtimeStateTestRoot("writer", "qwen/qwen3.6-plus"), agentId: "writer", homeRoot: home, defaultWorkspace: home.join("workspace"))
            let refresh = CliModelRuntimeStateManager.refreshAgentRuntimeStateForScope(agentDir, scope)
            let preserved = runtimeStateTestRead(path)

            @Expect(refresh.status, "skipped")
            @Expect(refresh.reason, "manual-runtime-state")
            @Expect(refresh.refreshed, false)
            @Expect(runtimeStateTestString(preserved, "runtimePrimaryModelRef"), "manual:model")
            @Expect(preserved.toJsonString().contains("qwen-plus"), false)
        })
    }
}
