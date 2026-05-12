package metis.core.config

import magic.jsonable.*

import std.collection.{ArrayList, HashMap}
import std.fs.Path
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString, JsonValue}

private func scopeJsonObject(root: JsonObject, key: String): Option<JsonObject> {
    match (root.get(key)) {
        case Some(value) =>
            try { value.asObject() } catch (_: Exception) { None }
        case None => None
    }
}

private func scopeJsonArray(root: JsonObject, key: String): Option<JsonArray> {
    match (root.get(key)) {
        case Some(value) =>
            try { value.asArray() } catch (_: Exception) { None }
        case None => None
    }
}

private func scopeJsonString(root: JsonObject, key: String): Option<String> {
    match (root.get(key)) {
        case Some(value) =>
            try { Some(value.asString().getValue()) } catch (_: Exception) { None }
        case None => None
    }
}

private func scopeJsonBool(root: JsonObject, key: String): Option<Bool> {
    match (root.get(key)) {
        case Some(value) =>
            try { Some(value.asBool().getValue()) } catch (_: Exception) { None }
        case None => None
    }
}

private func scopeCloneValue(value: JsonValue): JsonValue {
    try {
        JsonValue.fromStr(value.toJsonString())
    } catch (_: Exception) {
        value
    }
}

private func scopeCloneObject(value: JsonObject): JsonObject {
    try {
        JsonValue.fromStr(value.toJsonString()).asObject()
    } catch (_: Exception) {
        JsonObject()
    }
}

private func scopeCloneArray(value: JsonArray): JsonArray {
    try {
        JsonValue.fromStr(value.toJsonString()).asArray()
    } catch (_: Exception) {
        JsonArray([])
    }
}

private func scopeAgents(root: JsonObject): JsonObject {
    match (scopeJsonObject(root, "agents")) {
        case Some(agents) => agents
        case None => JsonObject()
    }
}

private func scopeDefaults(root: JsonObject): JsonObject {
    match (scopeJsonObject(scopeAgents(root), "defaults")) {
        case Some(defaults) => defaults
        case None => JsonObject()
    }
}

private func scopeList(root: JsonObject): JsonArray {
    match (scopeJsonArray(scopeAgents(root), "list")) {
        case Some(list) => list
        case None => JsonArray([])
    }
}

private func scopeDiagnostic(code: String, message: String, agentId!: String = ""): JsonObject {
    let out = JsonObject()
    out.put("code", JsonString(code))
    out.put("message", JsonString(message))
    if (!agentId.trimAscii().isEmpty()) {
        out.put("agentId", JsonString(agentId.trimAscii()))
    }
    out
}

private func scopeAddDiagnostic(diagnostics: JsonArray, code: String, message: String, agentId!: String = ""): Unit {
    diagnostics.add(scopeDiagnostic(code, message, agentId: agentId))
}

private func scopeIsAgentIdRune(ch: Rune): Bool {
    (ch >= r'a' && ch <= r'z') ||
    (ch >= r'0' && ch <= r'9') ||
    ch == r'_' ||
    ch == r'-'
}

private func scopeTrimDashes(raw: String): String {
    var out = raw
    while (out.startsWith("-") && out.size > 0) {
        out = out[1..]
    }
    while (out.endsWith("-") && out.size > 0) {
        out = out[..out.size - 1]
    }
    out
}

private func scopeAppendRune(out: String, ch: Rune): String {
    "${out}${ch}"
}

private func scopeIsInvalidRawId(raw: String, normalized: String): Bool {
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty()) {
        return true
    }
    trimmed.toAsciiLower() != normalized
}

private func scopeAgentEntries(root: JsonObject, diagnostics: JsonArray): JsonArray {
    let entries = scopeList(root)
    let out = JsonArray([])
    let seen = HashMap<String, Bool>()
    for (i in 0..entries.size()) {
        let entry = try {
            entries[i].asObject()
        } catch (_: Exception) {
            scopeAddDiagnostic(diagnostics, "invalid-entry", "Agent entry is not an object.")
            continue
        }
        let rawId = scopeJsonString(entry, "id") ?? ""
        let normalized = MetisAgentScope.normalizeAgentId(rawId)
        if (scopeIsInvalidRawId(rawId, normalized)) {
            scopeAddDiagnostic(diagnostics, "invalid-agent-id", "Agent id \"${rawId}\" normalizes to \"${normalized}\".", agentId: normalized)
        }
        if (seen.contains(normalized)) {
            scopeAddDiagnostic(diagnostics, "duplicate-agent-id", "Duplicate agent id \"${normalized}\" ignored after the first entry.", agentId: normalized)
            continue
        }
        seen[normalized] = true
        out.add(entry)
    }
    out
}

private func scopeHasConfiguredAgent(root: JsonObject, agentId: String): Bool {
    let diagnostics = JsonArray([])
    let entries = scopeAgentEntries(root, diagnostics)
    for (i in 0..entries.size()) {
        let entry = try { entries[i].asObject() } catch (_: Exception) { JsonObject() }
        if (MetisAgentScope.normalizeAgentId(scopeJsonString(entry, "id") ?? "") == agentId) {
            return true
        }
    }
    false
}

private func scopeFindAgentEntry(root: JsonObject, agentId: String): Option<JsonObject> {
    let diagnostics = JsonArray([])
    let entries = scopeAgentEntries(root, diagnostics)
    for (i in 0..entries.size()) {
        let entry = try { entries[i].asObject() } catch (_: Exception) { JsonObject() }
        if (MetisAgentScope.normalizeAgentId(scopeJsonString(entry, "id") ?? "") == agentId) {
            return Some(entry)
        }
    }
    None
}

private func scopeDefaultAgentId(root: JsonObject, diagnostics: JsonArray): String {
    let entries = scopeAgentEntries(root, diagnostics)
    if (entries.size() == 0) {
        scopeAddDiagnostic(diagnostics, "general-alias", "No agents.list configured; Metis treats historical general callers as the main default agent.", agentId: "main")
        return "main"
    }
    var firstId = ""
    var defaultId = ""
    var defaultCount = 0
    for (i in 0..entries.size()) {
        let entry = try { entries[i].asObject() } catch (_: Exception) { JsonObject() }
        let id = MetisAgentScope.normalizeAgentId(scopeJsonString(entry, "id") ?? "")
        if (firstId.isEmpty()) {
            firstId = id
        }
        match (scopeJsonBool(entry, "default")) {
            case Some(true) =>
                defaultCount += 1
                if (defaultId.isEmpty()) {
                    defaultId = id
                }
            case _ => ()
        }
    }
    if (defaultCount > 1) {
        scopeAddDiagnostic(diagnostics, "multiple-default-agents", "Multiple agents are marked default=true; using the first default entry.", agentId: defaultId)
    }
    if (!defaultId.isEmpty()) {
        return defaultId
    }
    if (!firstId.isEmpty()) {
        return firstId
    }
    "main"
}

private func scopeRequestedAgentId(root: JsonObject, requested: String, defaultId: String, diagnostics: JsonArray): (String, String) {
    let raw = requested.trimAscii()
    if (raw.isEmpty()) {
        return (defaultId, "default")
    }
    let lowered = raw.toAsciiLower()
    if (lowered == "general" && !scopeHasConfiguredAgent(root, "general")) {
        scopeAddDiagnostic(diagnostics, "general-alias", "Requested historical agent id general; resolving it to the default agent.", agentId: defaultId)
        return (defaultId, "alias")
    }
    let normalized = MetisAgentScope.normalizeAgentId(raw)
    if (scopeIsInvalidRawId(raw, normalized)) {
        scopeAddDiagnostic(diagnostics, "invalid-agent-id", "Requested agent id \"${raw}\" normalizes to \"${normalized}\".", agentId: normalized)
    }
    (normalized, "request")
}

private func scopePath(raw: String, fallback: Path): Path {
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty()) {
        return fallback
    }
    Path(trimmed)
}

private func scopePolicyArray(value: JsonValue): JsonArray {
    try {
        let raw = value.asArray()
        let out = JsonArray([])
        for (i in 0..raw.size()) {
            try {
                let text = raw[i].asString().getValue().trimAscii()
                if (!text.isEmpty()) {
                    out.add(JsonString(text))
                }
            } catch (_: Exception) {
                ()
            }
        }
        out
    } catch (_: Exception) {
        JsonArray([])
    }
}

private func scopeSourceObject(source: String): JsonObject {
    let out = JsonObject()
    out.put("source", JsonString(source))
    out
}

private func scopeArrayPolicy(entryOpt: Option<JsonObject>, defaults: JsonObject, key: String, label: String): JsonObject {
    let out = JsonObject()
    match (entryOpt) {
        case Some(entry) =>
            match (entry.get(key)) {
                case Some(value) =>
                    out.put("source", JsonString("agents.list[].${key}"))
                    out.put("names", scopePolicyArray(value))
                    return out
                case None => ()
            }
        case None => ()
    }
    match (defaults.get(key)) {
        case Some(value) =>
            out.put("source", JsonString("agents.defaults.${key}"))
            out.put("names", scopePolicyArray(value))
        case None =>
            out.put("source", JsonString("unrestricted"))
            out.put("mode", JsonString("unrestricted-${label}"))
    }
    out
}

private func scopeObjectPolicy(entryOpt: Option<JsonObject>, defaults: JsonObject, key: String, label: String): JsonObject {
    let out = JsonObject()
    match (entryOpt) {
        case Some(entry) =>
            match (scopeJsonObject(entry, key)) {
                case Some(value) =>
                    out.put("source", JsonString("agents.list[].${key}"))
                    out.put("raw", scopeCloneObject(value))
                    return out
                case None => ()
            }
        case None => ()
    }
    match (scopeJsonObject(defaults, key)) {
        case Some(value) =>
            out.put("source", JsonString("agents.defaults.${key}"))
            out.put("raw", scopeCloneObject(value))
        case None =>
            out.put("source", JsonString("unrestricted"))
            out.put("mode", JsonString("unrestricted-${label}"))
    }
    out
}

private func scopeCopyRaw(entryOpt: Option<JsonObject>, defaults: JsonObject, out: JsonObject, key: String): Unit {
    match (entryOpt) {
        case Some(entry) =>
            match (entry.get(key)) {
                case Some(value) =>
                    out.put(key, scopeCloneValue(value))
                    return
                case None => ()
            }
        case None => ()
    }
    match (defaults.get(key)) {
        case Some(value) => out.put(key, scopeCloneValue(value))
        case None => ()
    }
}

private func scopeStringSetting(entryOpt: Option<JsonObject>, defaults: JsonObject, out: JsonObject, key: String): Unit {
    match (entryOpt) {
        case Some(entry) =>
            match (scopeJsonString(entry, key)) {
                case Some(value) =>
                    if (!value.trimAscii().isEmpty()) {
                        out.put(key, JsonString(value.trimAscii()))
                        out.put("${key}Source", JsonString("agents.list[].${key}"))
                        return
                    }
                case None => ()
            }
        case None => ()
    }
    match (scopeJsonString(defaults, key)) {
        case Some(value) =>
            if (!value.trimAscii().isEmpty()) {
                out.put(key, JsonString(value.trimAscii()))
                out.put("${key}Source", JsonString("agents.defaults.${key}"))
            }
        case None => ()
    }
}

private func scopeBoolSetting(entryOpt: Option<JsonObject>, defaults: JsonObject, out: JsonObject, key: String): Unit {
    match (entryOpt) {
        case Some(entry) =>
            match (scopeJsonBool(entry, key)) {
                case Some(value) =>
                    out.put(key, JsonBool(value))
                    out.put("${key}Source", JsonString("agents.list[].${key}"))
                    return
                case None => ()
            }
        case None => ()
    }
    match (scopeJsonBool(defaults, key)) {
        case Some(value) =>
            out.put(key, JsonBool(value))
            out.put("${key}Source", JsonString("agents.defaults.${key}"))
        case None => ()
    }
}

private func scopeCopyRuntimeDefaults(entryOpt: Option<JsonObject>, defaults: JsonObject): JsonObject {
    let out = JsonObject()
    for (key in ["thinkingDefault", "reasoningDefault", "verboseDefault"]) {
        scopeStringSetting(entryOpt, defaults, out, key)
    }
    scopeBoolSetting(entryOpt, defaults, out, "fastModeDefault")
    for (key in ["humanDelay", "heartbeat", "params", "runtime"]) {
        scopeCopyRaw(entryOpt, defaults, out, key)
    }
    out
}

private func scopeModelObject(raw: JsonValue): JsonObject {
    let out = JsonObject()
    try {
        let primary = raw.asString().getValue().trimAscii()
        if (!primary.isEmpty()) {
            out.put("primary", JsonString(primary))
        }
        return out
    } catch (_: Exception) {
        ()
    }
    try {
        raw.asObject()
    } catch (_: Exception) {
        out
    }
}

private func scopeModel(entryOpt: Option<JsonObject>, defaults: JsonObject): JsonObject {
    let out = JsonObject()
    var raw = JsonObject()
    var source = "unconfigured"
    match (entryOpt) {
        case Some(entry) =>
            match (entry.get("model")) {
                case Some(value) =>
                    raw = scopeModelObject(value)
                    source = "agents.list[].model"
                case None => ()
            }
        case None => ()
    }
    if (source == "unconfigured") {
        match (defaults.get("model")) {
            case Some(value) =>
                raw = scopeModelObject(value)
                source = "agents.defaults.model"
            case None => ()
        }
    }
    match (scopeJsonString(raw, "primary")) {
        case Some(primary) =>
            if (!primary.trimAscii().isEmpty()) {
                out.put("primary", JsonString(primary.trimAscii()))
            }
        case None => ()
    }
    out.put("primarySource", JsonString(source))

    var fallbacksSource = "unconfigured"
    var fallbacks = JsonArray([])
    var fallbacksSet = false
    match (entryOpt) {
        case Some(entry) =>
            match (entry.get("model")) {
                case Some(value) =>
                    let entryModel = scopeModelObject(value)
                    match (scopeJsonArray(entryModel, "fallbacks")) {
                        case Some(arr) =>
                            fallbacks = scopeCloneArray(arr)
                            fallbacksSource = "agents.list[].model.fallbacks"
                            fallbacksSet = true
                        case None => ()
                    }
                case None => ()
            }
        case None => ()
    }
    if (!fallbacksSet) {
        match (scopeJsonArray(scopeModelObject(defaults.get("model").getOrDefault { JsonObject() }), "fallbacks")) {
            case Some(arr) =>
                fallbacks = scopeCloneArray(arr)
                fallbacksSource = "agents.defaults.model.fallbacks"
                fallbacksSet = true
            case None => ()
        }
    }
    if (fallbacksSet) {
        out.put("fallbacks", fallbacks)
        out.put("fallbacksSource", JsonString(fallbacksSource))
        out.put("fallbacksExplicitlyDisabled", (fallbacks.size() == 0).toJsonValue())
    } else {
        out.put("fallbacksSource", JsonString(fallbacksSource))
        out.put("fallbacksExplicitlyDisabled", false.toJsonValue())
    }
    out.put("raw", scopeCloneObject(raw))
    out
}

public class MetisAgentScope {
    public static func normalizeAgentId(raw: String): String {
        let lower = raw.trimAscii().toAsciiLower()
        var out = ""
        var lastDash = false
        for (ch in lower.toRuneArray()) {
            if (scopeIsAgentIdRune(ch)) {
                out = scopeAppendRune(out, ch)
                lastDash = false
            } else if (!lastDash) {
                out += "-"
                lastDash = true
            }
            if (out.size >= 64) {
                break
            }
        }
        let trimmed = scopeTrimDashes(out)
        if (trimmed.isEmpty()) {
            return "main"
        }
        if (trimmed.size > 64) {
            return scopeTrimDashes(trimmed[..64])
        }
        trimmed
    }

    public static func resolve(
        root: JsonObject,
        agentId!: String = "",
        homeRoot!: Path = MetisPaths.homeRoot(),
        defaultWorkspace!: Path = MetisPaths.workspaceRoot()
    ): JsonObject {
        let diagnostics = JsonArray([])
        let defaultId = scopeDefaultAgentId(root, diagnostics)
        let (id, source) = scopeRequestedAgentId(root, agentId, defaultId, diagnostics)
        let entryOpt = scopeFindAgentEntry(root, id)
        let configured = entryOpt.isSome()
        if (!configured && source == "request") {
            scopeAddDiagnostic(diagnostics, "unknown-agent", "Agent \"${id}\" is not configured; defaults are used without widening skills or tools.", agentId: id)
        }
        let defaults = scopeDefaults(root)
        let stateRoot = homeRoot.join("agents").join(id)
        let fallbackAgentDir = stateRoot.join("agent")
        let agentDir = match (entryOpt) {
            case Some(entry) =>
                scopePath(scopeJsonString(entry, "agentDir") ?? "", fallbackAgentDir)
            case None => fallbackAgentDir
        }
        let defaultWorkspaceConfig = scopeJsonString(defaults, "workspace") ?? ""
        let fallbackWorkspace = if (id == defaultId) {
            scopePath(defaultWorkspaceConfig, defaultWorkspace)
        } else if (!defaultWorkspaceConfig.trimAscii().isEmpty()) {
            scopePath(defaultWorkspaceConfig, defaultWorkspace).join(id)
        } else {
            homeRoot.join("workspaces").join(id)
        }
        let workspaceDir = match (entryOpt) {
            case Some(entry) =>
                scopePath(scopeJsonString(entry, "workspace") ?? "", fallbackWorkspace)
            case None => fallbackWorkspace
        }

        let out = JsonObject()
        out.put("agentId", JsonString(id))
        out.put("requestedAgentId", JsonString(agentId.trimAscii()))
        out.put("agentIdSource", JsonString(source))
        out.put("defaultAgentId", JsonString(defaultId))
        out.put("configured", configured.toJsonValue())
        out.put("workspaceDir", JsonString(workspaceDir.toString()))
        out.put("agentDir", JsonString(agentDir.toString()))
        out.put("modelsJsonPath", JsonString(agentDir.join("models.json").toString()))
        out.put("authProfilesPath", JsonString(agentDir.join("auth-profiles.json").toString()))
        out.put("legacyAuthPath", JsonString(agentDir.join("auth.json").toString()))
        out.put("sessionsDir", JsonString(stateRoot.join("sessions").toString()))
        out.put("model", scopeModel(entryOpt, defaults))
        out.put("runtimeDefaults", scopeCopyRuntimeDefaults(entryOpt, defaults))
        out.put("skillsPolicy", scopeArrayPolicy(entryOpt, defaults, "skills", "skills"))
        out.put("toolsPolicy", scopeObjectPolicy(entryOpt, defaults, "tools", "tools"))
        out.put("identityPolicy", scopeObjectPolicy(entryOpt, defaults, "identity", "identity"))
        out.put("groupChatPolicy", scopeObjectPolicy(entryOpt, defaults, "groupChat", "groupChat"))
        out.put("subagentsPolicy", scopeObjectPolicy(entryOpt, defaults, "subagents", "subagents"))
        out.put("memorySearchPolicy", scopeObjectPolicy(entryOpt, defaults, "memorySearch", "memorySearch"))
        out.put("sandboxPolicy", scopeObjectPolicy(entryOpt, defaults, "sandbox", "sandbox"))
        let raw = JsonObject()
        for (key in ["identity", "groupChat", "subagents", "memorySearch", "sandbox", "tools", "skills", "humanDelay", "heartbeat", "params", "runtime"]) {
            scopeCopyRaw(entryOpt, defaults, raw, key)
        }
        out.put("raw", raw)
        out.put("diagnostics", diagnostics)
        out
    }

    public static func summary(
        root: JsonObject,
        homeRoot!: Path = MetisPaths.homeRoot(),
        defaultWorkspace!: Path = MetisPaths.workspaceRoot()
    ): JsonObject {
        let diagnostics = JsonArray([])
        let defaultId = scopeDefaultAgentId(root, diagnostics)
        let entries = scopeAgentEntries(root, diagnostics)
        let rows = JsonArray([])
        if (entries.size() == 0) {
            rows.add(resolve(root, agentId: defaultId, homeRoot: homeRoot, defaultWorkspace: defaultWorkspace))
        } else {
            for (i in 0..entries.size()) {
                let entry = try { entries[i].asObject() } catch (_: Exception) { JsonObject() }
                let id = normalizeAgentId(scopeJsonString(entry, "id") ?? "")
                rows.add(resolve(root, agentId: id, homeRoot: homeRoot, defaultWorkspace: defaultWorkspace))
            }
        }
        let out = JsonObject()
        out.put("defaultAgentId", JsonString(defaultId))
        out.put("agents", rows)
        out.put("diagnostics", diagnostics)
        out
    }
}
