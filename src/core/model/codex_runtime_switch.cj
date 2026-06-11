package metis.core.model

import std.collection.ArrayList

public let CODEX_RUNTIME_AUTO = "auto"
public let CODEX_RUNTIME_APP_SERVER = "codex_app_server"
public let CODEX_RUNTIME_CONFIG_DEFAULT_KEY = "agents.defaults.model.openaiRuntime"
public let CODEX_RUNTIME_CONFIG_AGENT_KEY = "agents.list[].model.openaiRuntime"

public class CodexRuntimeSwitchParseResult {
    public let desiredRuntime: Option<String>
    public let errors: Array<String>

    public init(desiredRuntime!: Option<String> = None<String>, errors!: Array<String> = []) {
        this.desiredRuntime = desiredRuntime
        this.errors = errors
    }
}

public class CodexRuntimeSwitchResult {
    public let success: Bool
    public let status: String
    public let oldValue: String
    public let newValue: String
    public let mutated: Bool
    public let requiresCacheInvalidation: Bool
    public let binaryOk: Bool
    public let codexVersion: String
    public let diagnostics: Array<String>
    public let message: String

    public init(
        success: Bool,
        status: String,
        oldValue!: String = CODEX_RUNTIME_AUTO,
        newValue!: String = CODEX_RUNTIME_AUTO,
        mutated!: Bool = false,
        requiresCacheInvalidation!: Bool = false,
        binaryOk!: Bool = false,
        codexVersion!: String = "",
        diagnostics!: Array<String> = [],
        message!: String = ""
    ) {
        this.success = success
        this.status = status.trimAscii()
        this.oldValue = oldValue.trimAscii()
        this.newValue = newValue.trimAscii()
        this.mutated = mutated
        this.requiresCacheInvalidation = requiresCacheInvalidation
        this.binaryOk = binaryOk
        this.codexVersion = codexVersion.trimAscii()
        this.diagnostics = diagnostics
        this.message = message.trimAscii()
    }
}

public func codexRuntimeIsValid(value: String): Bool {
    let clean = value.trimAscii().toAsciiLower()
    clean == CODEX_RUNTIME_AUTO || clean == CODEX_RUNTIME_APP_SERVER
}

public func normalizeCodexRuntimeValue(value: String): Option<String> {
    let clean = value.trimAscii().toAsciiLower()
    if (clean == CODEX_RUNTIME_AUTO || clean == CODEX_RUNTIME_APP_SERVER) {
        return Some(clean)
    }
    None<String>
}

public func codexRuntimeFallback(value: String): String {
    match (normalizeCodexRuntimeValue(value)) {
        case Some(runtime) => runtime
        case None => CODEX_RUNTIME_AUTO
    }
}

private func codexRuntimeFirstToken(rawArgs: String): String {
    for (part in rawArgs.trimAscii().split(" ")) {
        let token = part.trimAscii().toAsciiLower()
        if (!token.isEmpty()) {
            return token
        }
    }
    ""
}

public func parseCodexRuntimeSwitchArgs(rawArgs: String): CodexRuntimeSwitchParseResult {
    let token = codexRuntimeFirstToken(rawArgs)
    if (token.isEmpty() || token == "status") {
        return CodexRuntimeSwitchParseResult()
    }
    if (token == "on" || token == "codex" || token == "enable" || token == CODEX_RUNTIME_APP_SERVER) {
        return CodexRuntimeSwitchParseResult(desiredRuntime: Some(CODEX_RUNTIME_APP_SERVER))
    }
    if (token == "off" || token == "default" || token == "disable" || token == "hermes" || token == CODEX_RUNTIME_AUTO) {
        return CodexRuntimeSwitchParseResult(desiredRuntime: Some(CODEX_RUNTIME_AUTO))
    }
    CodexRuntimeSwitchParseResult(errors: ["Invalid codex runtime '${token}'. Use on, off, or status."])
}

private func codexRuntimeMigrationDiagnostics(migration: Option<CodexRuntimeConfigMigrationResult>): Array<String> {
    let out = ArrayList<String>()
    match (migration) {
        case Some(result) =>
            for (warning in result.warnings) {
                out.add(warning)
            }
            for (error in result.errors) {
                out.add(error)
            }
        case None => ()
    }
    out.toArray()
}

public func applyCodexRuntimeSwitch(
    currentRuntime: String,
    desiredRuntime: Option<String>,
    binaryCheck!: CodexAppServerBinaryCheck = CodexAppServerBinaryCheck(false, status: "not-checked"),
    migration!: Option<CodexRuntimeConfigMigrationResult> = None<CodexRuntimeConfigMigrationResult>
): CodexRuntimeSwitchResult {
    let current = codexRuntimeFallback(currentRuntime)
    let diagnostics = codexRuntimeMigrationDiagnostics(migration)

    match (desiredRuntime) {
        case None =>
            let runtimeLabel = if (current == CODEX_RUNTIME_APP_SERVER) {
                "codex_app_server"
            } else {
                "auto"
            }
            var message = "Codex runtime is ${runtimeLabel}."
            if (current == CODEX_RUNTIME_APP_SERVER && !binaryCheck.ok) {
                message = "${message} Binary check: ${binaryCheck.message}"
            }
            return CodexRuntimeSwitchResult(
                true,
                "status",
                oldValue: current,
                newValue: current,
                binaryOk: binaryCheck.ok,
                codexVersion: binaryCheck.version,
                diagnostics: diagnostics,
                message: message
            )
        case Some(targetRaw) =>
            match (normalizeCodexRuntimeValue(targetRaw)) {
                case None =>
                    return CodexRuntimeSwitchResult(
                        false,
                        "invalid-runtime",
                        oldValue: current,
                        newValue: current,
                        diagnostics: diagnostics,
                        message: "Invalid codex runtime '${targetRaw}'. Allowed values are auto and codex_app_server."
                    )
                case Some(target) =>
                    if (target == current) {
                        return CodexRuntimeSwitchResult(
                            true,
                            "unchanged",
                            oldValue: current,
                            newValue: current,
                            binaryOk: binaryCheck.ok,
                            codexVersion: binaryCheck.version,
                            diagnostics: diagnostics,
                            message: "Codex runtime is already ${current}."
                        )
                    }
                    if (target == CODEX_RUNTIME_APP_SERVER && !binaryCheck.ok) {
                        return CodexRuntimeSwitchResult(
                            false,
                            "binary-unavailable",
                            oldValue: current,
                            newValue: current,
                            binaryOk: false,
                            codexVersion: binaryCheck.version,
                            diagnostics: diagnostics,
                            message: "Cannot enable codex_app_server: ${binaryCheck.message}"
                        )
                    }
                    CodexRuntimeSwitchResult(
                        true,
                        "updated",
                        oldValue: current,
                        newValue: target,
                        mutated: true,
                        requiresCacheInvalidation: true,
                        binaryOk: target != CODEX_RUNTIME_APP_SERVER || binaryCheck.ok,
                        codexVersion: binaryCheck.version,
                        diagnostics: diagnostics,
                        message: "Codex runtime changed from ${current} to ${target}. The change takes effect on the next session turn."
                    )
            }
    }
}

public func renderCodexRuntimeSwitchResult(result: CodexRuntimeSwitchResult): String {
    let lines = ArrayList<String>()
    lines.add(result.message)
    if (!result.codexVersion.isEmpty()) {
        lines.add("Codex CLI version: ${result.codexVersion}")
    }
    if (result.requiresCacheInvalidation) {
        lines.add("Runtime cache invalidation required.")
    }
    for (diagnostic in result.diagnostics) {
        if (!diagnostic.trimAscii().isEmpty()) {
            lines.add("Migration note: ${diagnostic}")
        }
    }
    String.join(lines.toArray(), delimiter: "\n")
}
