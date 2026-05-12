package metis.core.config

import std.fs.Path
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString}

private func scopeTestHome(name: String): Path {
    Path("/tmp").join("metis-agent-scope-test").join(name)
}

private func scopeTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func scopeTestBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

private func scopeTestArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func scopeAgentConfigRoot(defaults!: JsonObject = JsonObject(), list!: JsonArray = JsonArray([])): JsonObject {
    let root = JsonObject()
    let agents = JsonObject()
    if (defaults.size() > 0) {
        agents.put("defaults", defaults)
    }
    if (list.size() > 0) {
        agents.put("list", list)
    }
    if (agents.size() > 0) {
        root.put("agents", agents)
    }
    root
}

private func scopeModel(primary: String, fallbacks!: JsonArray = JsonArray([]), hasFallbacks!: Bool = true): JsonObject {
    let model = JsonObject()
    model.put("primary", JsonString(primary))
    if (hasFallbacks) {
        model.put("fallbacks", fallbacks)
    }
    model
}

private func scopeStringArray(values: Array<String>): JsonArray {
    let out = JsonArray([])
    for (value in values) {
        out.add(JsonString(value))
    }
    out
}

@Test
public class MetisAgentScopeTest {
    @TestCase
    public func emptyConfigResolvesMainWithLegacyGeneralDiagnostic(): Unit {
        let home = scopeTestHome("empty")
        let workspace = home.join("workspace")
        let scope = MetisAgentScope.resolve(JsonObject(), homeRoot: home, defaultWorkspace: workspace)
        @Expect(scopeTestString(scope, "agentId"), "main")
        @Expect(scopeTestString(scope, "defaultAgentId"), "main")
        @Expect(scopeTestString(scope, "workspaceDir"), workspace.toString())
        @Expect(scopeTestString(scope, "agentDir"), home.join("agents").join("main").join("agent").toString())
        @Expect(scopeTestString(scope, "modelsJsonPath"), home.join("agents").join("main").join("agent").join("models.json").toString())
        @Expect(scopeTestString(scope, "authProfilesPath"), home.join("agents").join("main").join("agent").join("auth-profiles.json").toString())
        @Expect(scopeTestString(scope, "legacyAuthPath"), home.join("agents").join("main").join("agent").join("auth.json").toString())
        @Expect(scopeTestString(scope, "sessionsDir"), home.join("agents").join("main").join("sessions").toString())
        @Expect(scopeTestArray(scope, "diagnostics").toJsonString().contains("general-alias"), true)
    }

    @TestCase
    public func singleAgentPreservesExplicitPathsAndRawPolicies(): Unit {
        let home = scopeTestHome("single")
        let defaults = JsonObject()
        defaults.put("workspace", JsonString(home.join("team").toString()))
        defaults.put("model", scopeModel("openai/gpt-4.1", fallbacks: scopeStringArray(["dashscope/qwen-max"])))
        defaults.put("skills", scopeStringArray(["read", "write"]))
        let defaultTools = JsonObject()
        defaultTools.put("allow", scopeStringArray(["fileRead"]))
        defaults.put("tools", defaultTools)
        defaults.put("thinkingDefault", JsonString("medium"))
        defaults.put("verboseDefault", JsonString("on"))
        let entry = JsonObject()
        entry.put("id", JsonString("Cangjie"))
        entry.put("default", JsonBool(true))
        entry.put("workspace", JsonString(home.join("cj-workspace").toString()))
        entry.put("agentDir", JsonString(home.join("custom-agent-dir").toString()))
        entry.put("model", scopeModel("local/cj", fallbacks: scopeStringArray(["openai/cj-fallback"])))
        entry.put("skills", scopeStringArray(["cangjie-docs"]))
        let tools = JsonObject()
        tools.put("allow", scopeStringArray(["grepSearch"]))
        entry.put("tools", tools)
        let identity = JsonObject()
        identity.put("name", JsonString("Cangjie Expert"))
        entry.put("identity", identity)
        let groupChat = JsonObject()
        groupChat.put("mentionRequired", JsonBool(true))
        entry.put("groupChat", groupChat)
        let subagents = JsonObject()
        subagents.put("allowAgents", scopeStringArray(["reviewer"]))
        entry.put("subagents", subagents)
        let memorySearch = JsonObject()
        memorySearch.put("enabled", JsonBool(true))
        entry.put("memorySearch", memorySearch)
        let sandbox = JsonObject()
        sandbox.put("mode", JsonString("workspace-write"))
        entry.put("sandbox", sandbox)
        entry.put("runtime", JsonObject())
        entry.put("fastModeDefault", JsonBool(true))
        let list = JsonArray([])
        list.add(entry)
        let scope = MetisAgentScope.resolve(scopeAgentConfigRoot(defaults: defaults, list: list), agentId: "cangjie", homeRoot: home, defaultWorkspace: home.join("workspace"))
        @Expect(scopeTestString(scope, "agentId"), "cangjie")
        @Expect(scopeTestString(scope, "workspaceDir"), home.join("cj-workspace").toString())
        @Expect(scopeTestString(scope, "agentDir"), home.join("custom-agent-dir").toString())
        let model = scope.get("model").getOrThrow().asObject()
        @Expect(scopeTestString(model, "primary"), "local/cj")
        @Expect(scopeTestArray(model, "fallbacks").toJsonString().contains("openai/cj-fallback"), true)
        let runtimeDefaults = scope.get("runtimeDefaults").getOrThrow().asObject()
        @Expect(scopeTestString(runtimeDefaults, "thinkingDefault"), "medium")
        @Expect(scopeTestString(runtimeDefaults, "verboseDefault"), "on")
        @Expect(scopeTestBool(runtimeDefaults, "fastModeDefault"), true)
        @Expect(scope.get("raw").getOrThrow().asObject().toJsonString().contains("Cangjie Expert"), true)
        @Expect(scope.get("identityPolicy").getOrThrow().asObject().toJsonString().contains("agents.list[].identity"), true)
        @Expect(scope.get("skillsPolicy").getOrThrow().asObject().toJsonString().contains("cangjie-docs"), true)
        @Expect(scope.get("toolsPolicy").getOrThrow().asObject().toJsonString().contains("grepSearch"), true)
    }

    @TestCase
    public func multiAgentDefaultDuplicateAndInvalidIdsAreDiagnosed(): Unit {
        let home = scopeTestHome("multi")
        let defaults = JsonObject()
        defaults.put("workspace", JsonString(home.join("team").toString()))
        let list = JsonArray([])
        let first = JsonObject()
        first.put("id", JsonString("PM"))
        first.put("default", JsonBool(true))
        list.add(first)
        let second = JsonObject()
        second.put("id", JsonString("../Research Agent"))
        second.put("default", JsonBool(true))
        list.add(second)
        let duplicate = JsonObject()
        duplicate.put("id", JsonString("pm"))
        list.add(duplicate)
        let root = scopeAgentConfigRoot(defaults: defaults, list: list)
        let summary = MetisAgentScope.summary(root, homeRoot: home, defaultWorkspace: home.join("workspace"))
        @Expect(scopeTestString(summary, "defaultAgentId"), "pm")
        @Expect(scopeTestArray(summary, "agents").size(), 2)
        let diagnostics = scopeTestArray(summary, "diagnostics").toJsonString()
        @Expect(diagnostics.contains("multiple-default-agents"), true)
        @Expect(diagnostics.contains("duplicate-agent-id"), true)
        @Expect(diagnostics.contains("invalid-agent-id"), true)
        let research = MetisAgentScope.resolve(root, agentId: "../Research Agent", homeRoot: home, defaultWorkspace: home.join("workspace"))
        @Expect(scopeTestString(research, "agentId"), "research-agent")
        @Expect(scopeTestString(research, "workspaceDir"), home.join("team").join("research-agent").toString())
        @Expect(scopeTestString(research, "agentDir"), home.join("agents").join("research-agent").join("agent").toString())
        @Expect(scopeTestString(research, "sessionsDir"), home.join("agents").join("research-agent").join("sessions").toString())
    }

    @TestCase
    public func explicitEmptyFallbacksDisableDefaultFallbacks(): Unit {
        let home = scopeTestHome("fallbacks")
        let defaults = JsonObject()
        defaults.put("model", scopeModel("openai/main", fallbacks: scopeStringArray(["openai/fallback"])))
        let entry = JsonObject()
        entry.put("id", JsonString("writer"))
        entry.put("model", scopeModel("openai/writer", fallbacks: JsonArray([])))
        let list = JsonArray([])
        list.add(entry)
        let scope = MetisAgentScope.resolve(scopeAgentConfigRoot(defaults: defaults, list: list), agentId: "writer", homeRoot: home, defaultWorkspace: home.join("workspace"))
        let model = scope.get("model").getOrThrow().asObject()
        @Expect(scopeTestArray(model, "fallbacks").size(), 0)
        @Expect(scopeTestBool(model, "fallbacksExplicitlyDisabled"), true)
        @Expect(scopeTestString(model, "fallbacksSource"), "agents.list[].model.fallbacks")
    }

    @TestCase
    public func unknownAgentFallsBackToDefaultsWithoutExpandingPolicies(): Unit {
        let home = scopeTestHome("unknown")
        let defaults = JsonObject()
        defaults.put("skills", scopeStringArray(["safe-skill"]))
        let tools = JsonObject()
        tools.put("allow", scopeStringArray(["safe-tool"]))
        defaults.put("tools", tools)
        let scope = MetisAgentScope.resolve(scopeAgentConfigRoot(defaults: defaults), agentId: "unknown", homeRoot: home, defaultWorkspace: home.join("workspace"))
        @Expect(scopeTestString(scope, "agentId"), "unknown")
        @Expect(scopeTestBool(scope, "configured"), false)
        @Expect(scope.get("skillsPolicy").getOrThrow().asObject().toJsonString().contains("safe-skill"), true)
        @Expect(scope.get("toolsPolicy").getOrThrow().asObject().toJsonString().contains("safe-tool"), true)
        @Expect(scopeTestArray(scope, "diagnostics").toJsonString().contains("unknown-agent"), true)
    }
}
