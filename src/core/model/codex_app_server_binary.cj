package metis.core.model

import std.convert.Parsable
import std.process.executeWithOutput
import std.regex.Regex

public let CODEX_APP_SERVER_MIN_VERSION = "0.125.0"
public let CODEX_APP_SERVER_INSTALL_HINT = "npm i -g @openai/codex"

public class CodexAppServerBinaryCheck {
    public let ok: Bool
    public let status: String
    public let command: String
    public let version: String
    public let message: String

    public init(
        ok: Bool,
        status!: String = "",
        command!: String = "codex",
        version!: String = "",
        message!: String = ""
    ) {
        this.ok = ok
        this.status = status.trimAscii()
        this.command = command.trimAscii()
        this.version = version.trimAscii()
        this.message = message.trimAscii()
    }
}

public func parseCodexAppServerVersion(output: String): Option<String> {
    try {
        for (md in Regex(#"(\d+)\.(\d+)\.(\d+)"#).findAll(output, group: true)) {
            return Some("${md.matchString(1)}.${md.matchString(2)}.${md.matchString(3)}")
        }
    } catch (_: Exception) {
        ()
    }
    None<String>
}

private func codexSemverPart(version: String, index: Int64): Int64 {
    let parts = version.trimAscii().split(".")
    if (index < 0 || index >= Int64(parts.size)) {
        return 0
    }
    var raw = "0"
    if (index == 0 && parts.size > 0) {
        raw = parts[0]
    } else if (index == 1 && parts.size > 1) {
        raw = parts[1]
    } else if (index == 2 && parts.size > 2) {
        raw = parts[2]
    }
    try {
        Int64.parse(raw.trimAscii())
    } catch (_: Exception) {
        0
    }
}

public func compareCodexSemver(version: String, minVersion!: String = CODEX_APP_SERVER_MIN_VERSION): Int64 {
    for (idx in 0..3) {
        let left = codexSemverPart(version, idx)
        let right = codexSemverPart(minVersion, idx)
        if (left > right) {
            return 1
        }
        if (left < right) {
            return -1
        }
    }
    0
}

private func codexBinaryDecode(bytes: Array<Byte>): String {
    try {
        String.fromUtf8(bytes)
    } catch (_: Exception) {
        ""
    }
}

private func codexBinaryFailure(status: String, command: String, message: String): CodexAppServerBinaryCheck {
    CodexAppServerBinaryCheck(
        false,
        status: status,
        command: command,
        message: "${message} Install with: ${CODEX_APP_SERVER_INSTALL_HINT}"
    )
}

public func checkCodexAppServerBinary(
    command!: String = "codex",
    minVersion!: String = CODEX_APP_SERVER_MIN_VERSION
): CodexAppServerBinaryCheck {
    let cleanCommand = command.trimAscii()
    if (cleanCommand.isEmpty()) {
        return codexBinaryFailure("missing-command", "codex", "Codex CLI command is empty.")
    }

    try {
        let (exitCode, stdoutBytes, stderrBytes) = executeWithOutput(cleanCommand, ["--version"])
        let stdout = codexBinaryDecode(stdoutBytes)
        let stderr = codexBinaryDecode(stderrBytes)
        let combined = "${stdout}\n${stderr}".trimAscii()
        if (exitCode != 0) {
            return codexBinaryFailure(
                "nonzero-exit",
                cleanCommand,
                "Codex CLI version check failed with exit code ${exitCode}."
            )
        }

        match (parseCodexAppServerVersion(combined)) {
            case Some(version) =>
                if (compareCodexSemver(version, minVersion: minVersion) < 0) {
                    return codexBinaryFailure(
                        "too-old",
                        cleanCommand,
                        "Codex CLI ${version} is older than required ${minVersion}."
                    )
                }
                CodexAppServerBinaryCheck(
                    true,
                    status: "ok",
                    command: cleanCommand,
                    version: version,
                    message: "Codex CLI ${version} supports codex_app_server."
                )
            case None =>
                codexBinaryFailure(
                    "unparseable-version",
                    cleanCommand,
                    "Codex CLI version output did not contain a semantic version."
                )
        }
    } catch (_: Exception) {
        codexBinaryFailure(
            "not-found",
            cleanCommand,
            "Codex CLI was not found or is not executable."
        )
    }
}
