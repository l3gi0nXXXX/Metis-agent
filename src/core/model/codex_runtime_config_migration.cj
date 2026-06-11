package metis.core.model

import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

public class CodexRuntimeConfigMigrationResult {
    public let changed: Bool
    public let runtime: String
    public let warnings: Array<String>
    public let errors: Array<String>
    public let migratedPaths: Array<String>

    public init(
        changed: Bool,
        runtime!: String = CODEX_RUNTIME_AUTO,
        warnings!: Array<String> = [],
        errors!: Array<String> = [],
        migratedPaths!: Array<String> = []
    ) {
        this.changed = changed
        this.runtime = codexRuntimeFallback(runtime)
        this.warnings = warnings
        this.errors = errors
        this.migratedPaths = migratedPaths
    }
}

private func codexRuntimeJsonString(obj: JsonObject, key: String): Option<String> {
    match (obj.get(key)) {
        case Some(value) =>
            try {
                Some(value.asString().getValue().trimAscii())
            } catch (_: Exception) {
                None<String>
            }
        case None => None<String>
    }
}

private func codexRuntimeJsonObject(obj: JsonObject, key: String): Option<JsonObject> {
    match (obj.get(key)) {
        case Some(value) =>
            try {
                Some(value.asObject())
            } catch (_: Exception) {
                None<JsonObject>
            }
        case None => None<JsonObject>
    }
}

private func codexRuntimeEnsureObject(obj: JsonObject, key: String): JsonObject {
    match (codexRuntimeJsonObject(obj, key)) {
        case Some(child) => child
        case None =>
            let child = JsonObject()
            obj.put(key, child)
            child
    }
}

private func codexRuntimeModelObject(root: JsonObject, create!: Bool = false): Option<JsonObject> {
    match (codexRuntimeJsonObject(root, "agents")) {
        case Some(agents) =>
            match (codexRuntimeJsonObject(agents, "defaults")) {
                case Some(defaults) =>
                    match (codexRuntimeJsonObject(defaults, "model")) {
                        case Some(model) => Some(model)
                        case None =>
                            if (!create) {
                                None<JsonObject>
                            } else {
                                Some(codexRuntimeEnsureObject(defaults, "model"))
                            }
                    }
                case None =>
                    if (!create) {
                        None<JsonObject>
                    } else {
                        let defaults = codexRuntimeEnsureObject(agents, "defaults")
                        Some(codexRuntimeEnsureObject(defaults, "model"))
                    }
            }
        case None =>
            if (!create) {
                None<JsonObject>
            } else {
                let agents = codexRuntimeEnsureObject(root, "agents")
                let defaults = codexRuntimeEnsureObject(agents, "defaults")
                Some(codexRuntimeEnsureObject(defaults, "model"))
            }
    }
}

public func codexRuntimeReadDefaultRuntime(root: JsonObject): String {
    match (codexRuntimeModelObject(root)) {
        case Some(model) =>
            match (codexRuntimeJsonString(model, "openaiRuntime")) {
                case Some(value) => codexRuntimeFallback(value)
                case None => CODEX_RUNTIME_AUTO
            }
        case None => CODEX_RUNTIME_AUTO
    }
}

public func codexRuntimeSetDefaultRuntime(root: JsonObject, runtime: String): Bool {
    match (normalizeCodexRuntimeValue(runtime)) {
        case Some(clean) =>
            match (codexRuntimeModelObject(root, create: true)) {
                case Some(model) =>
                    model.put("openaiRuntime", JsonString(clean))
                    true
                case None => false
            }
        case None => false
    }
}

private func codexRuntimeProviderCandidate(raw: String): Option<String> {
    let value = raw.trimAscii().toAsciiLower()
    if (value == CODEX_RUNTIME_APP_SERVER || value == "codex" || value == "openai-codex") {
        return Some(CODEX_RUNTIME_APP_SERVER)
    }
    if (value == CODEX_RUNTIME_AUTO || value == "openai" || value == "default" || value == "hermes") {
        return Some(CODEX_RUNTIME_AUTO)
    }
    None<String>
}

private func codexRuntimeCandidateFromModel(
    model: JsonObject,
    path: String,
    warnings: ArrayList<String>,
    errors: ArrayList<String>
): Option<String> {
    for (key in ["openaiRuntime", "openai_runtime"]) {
        match (codexRuntimeJsonString(model, key)) {
            case Some(raw) =>
                match (normalizeCodexRuntimeValue(raw)) {
                    case Some(runtime) => return Some(runtime)
                    case None =>
                        errors.add("Invalid ${path}.${key} value '${raw}', falling back to auto.")
                        return Some(CODEX_RUNTIME_AUTO)
                }
            case None => ()
        }
    }

    for (key in ["openaiRuntimeProvider", "runtimeProvider", "providerRuntime", "provider"]) {
        match (codexRuntimeJsonString(model, key)) {
            case Some(raw) =>
                match (codexRuntimeProviderCandidate(raw)) {
                    case Some(runtime) =>
                        warnings.add("Migrated legacy ${path}.${key} to openaiRuntime.")
                        return Some(runtime)
                    case None =>
                        warnings.add("Ignored unknown legacy ${path}.${key} value '${raw}'.")
                }
            case None => ()
        }
    }
    None<String>
}

private func codexRuntimeMigrateModel(
    model: JsonObject,
    path: String,
    warnings: ArrayList<String>,
    errors: ArrayList<String>,
    migratedPaths: ArrayList<String>
): Bool {
    match (codexRuntimeCandidateFromModel(model, path, warnings, errors)) {
        case Some(runtime) =>
            let existing = codexRuntimeJsonString(model, "openaiRuntime")
            var shouldWrite = existing.isNone()
            match (existing) {
                case Some(raw) =>
                    match (normalizeCodexRuntimeValue(raw)) {
                        case Some(current) => shouldWrite = current != runtime
                        case None => shouldWrite = true
                    }
                case None => ()
            }
            if (shouldWrite) {
                model.put("openaiRuntime", JsonString(runtime))
                migratedPaths.add("${path}.openaiRuntime")
                return true
            }
            false
        case None => false
    }
}

private func codexRuntimeAgentList(root: JsonObject): Option<JsonArray> {
    match (codexRuntimeJsonObject(root, "agents")) {
        case Some(agents) =>
            match (agents.get("list")) {
                case Some(value) =>
                    try {
                        Some(value.asArray())
                    } catch (_: Exception) {
                        None<JsonArray>
                    }
                case None => None<JsonArray>
            }
        case None => None<JsonArray>
    }
}

public func codexRuntimeMigrateConfig(root: JsonObject): CodexRuntimeConfigMigrationResult {
    let warnings = ArrayList<String>()
    let errors = ArrayList<String>()
    let migratedPaths = ArrayList<String>()
    var changed = false

    match (codexRuntimeModelObject(root)) {
        case Some(model) =>
            if (codexRuntimeMigrateModel(model, "agents.defaults.model", warnings, errors, migratedPaths)) {
                changed = true
            }
        case None => ()
    }

    match (codexRuntimeAgentList(root)) {
        case Some(list) =>
            var idx = 0
            for (item in list.getItems()) {
                try {
                    let agent = item.asObject()
                    match (codexRuntimeJsonObject(agent, "model")) {
                        case Some(model) =>
                            if (codexRuntimeMigrateModel(model, "agents.list[${idx}].model", warnings, errors, migratedPaths)) {
                                changed = true
                            }
                        case None => ()
                    }
                } catch (_: Exception) {
                    warnings.add("Ignored non-object agents.list[${idx}] during runtime migration.")
                }
                idx += 1
            }
        case None => ()
    }

    CodexRuntimeConfigMigrationResult(
        changed,
        runtime: codexRuntimeReadDefaultRuntime(root),
        warnings: warnings.toArray(),
        errors: errors.toArray(),
        migratedPaths: migratedPaths.toArray()
    )
}
