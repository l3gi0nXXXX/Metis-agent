package metis.cron

import metis.core.{metisDecodeUtf8Bytes, metisSafeRuneEllipsis}
import metis.gateway.logging.gatewayLogRedactText

import std.fs.{Path, exists}
import std.io.{InputStream, StringReader}
import std.process.*
import std.time.*

private let CRON_SCRIPT_TIMEOUT_MS: Int64 = 30000
private let CRON_SCRIPT_OUTPUT_MAX_RUNES: Int64 = 16000

public class CronScriptPathResult {
    public let ok: Bool
    public let path: Path
    public let status: String
    public let errorCode: String
    public let message: String

    public init(ok: Bool, path!: Path = Path(""), status!: String = "ok", errorCode!: String = "", message!: String = "") {
        this.ok = ok
        this.path = path
        this.status = status.trimAscii()
        this.errorCode = errorCode.trimAscii()
        this.message = message.trimAscii()
    }
}

public class CronScriptReadResult {
    public let ok: Bool
    public let status: String
    public let text: String
    public let diagnostic: String

    public init(ok: Bool, status!: String = "ok", text!: String = "", diagnostic!: String = "") {
        this.ok = ok
        this.status = status.trimAscii()
        this.text = text
        this.diagnostic = diagnostic.trimAscii()
    }
}

public class CronScriptRunResult {
    public let ok: Bool
    public let status: String
    public let errorCode: String
    public let output: String
    public let stderr: String
    public let exitCode: Int64
    public let timedOut: Bool
    public let empty: Bool
    public let message: String

    public init(
        ok: Bool,
        status!: String = "ok",
        errorCode!: String = "",
        output!: String = "",
        stderr!: String = "",
        exitCode!: Int64 = 0,
        timedOut!: Bool = false,
        message!: String = ""
    ) {
        this.ok = ok
        this.status = status.trimAscii()
        this.errorCode = errorCode.trimAscii()
        this.output = output
        this.stderr = stderr
        this.exitCode = exitCode
        this.timedOut = timedOut
        this.empty = output.trimAscii().isEmpty()
        this.message = message.trimAscii()
    }
}

public func cronScriptsDir(dotDir: Path): Path {
    dotDir.join("cron").join("scripts")
}

private func cronScriptInvalidPath(raw: String): Bool {
    let t = raw.trimAscii()
    if (t.isEmpty() || t.startsWith("/") || t.startsWith("~") || t.contains("\\") || t.contains("\u{0000}")) {
        return true
    }
    for (segment in t.split("/")) {
        let part = segment.trimAscii()
        if (part.isEmpty() || part == "." || part == "..") {
            return true
        }
    }
    false
}

private func cronScriptSupportedExtension(path: String): Bool {
    let lower = path.trimAscii().toAsciiLower()
    lower.endsWith(".sh") || lower.endsWith(".bash")
}

public func resolveCronScriptPath(dotDir: Path, raw: String): CronScriptPathResult {
    let t = raw.trimAscii()
    if (cronScriptInvalidPath(t)) {
        return CronScriptPathResult(
            false,
            status: "invalid_path",
            errorCode: "cron_script_invalid_path",
            message: "cron script path must be relative under cron/scripts and must not contain traversal"
        )
    }
    let root = cronScriptsDir(dotDir)
    let resolved = root.join(t)
    let rootPrefix = root.toString()
    let resolvedPath = resolved.toString()
    if (!(resolvedPath == rootPrefix || resolvedPath.startsWith(rootPrefix + "/"))) {
        return CronScriptPathResult(
            false,
            status: "invalid_path",
            errorCode: "cron_script_invalid_path",
            message: "cron script path escaped cron/scripts"
        )
    }
    CronScriptPathResult(true, path: resolved)
}

public func cronScriptDecodeBytesForTest(bytes: Array<Byte>): CronScriptReadResult {
    let decoded = metisDecodeUtf8Bytes(bytes)
    if (!decoded.ok) {
        return CronScriptReadResult(false, status: decoded.status, diagnostic: decoded.diagnostic)
    }
    CronScriptReadResult(true, text: decoded.text)
}

public func cronScriptSanitizeOutputForTest(text: String, maxRunes!: Int64 = CRON_SCRIPT_OUTPUT_MAX_RUNES): String {
    let cleaned = gatewayLogRedactText(text).replace("\u{0000}", "").replace("\r", " ")
    metisSafeRuneEllipsis(cleaned, maxRunes)
}

private func cronScriptReadPipe(reader: StringReader<InputStream>, label: String): CronScriptReadResult {
    try {
        CronScriptReadResult(true, text: reader.readToEnd())
    } catch (e: Exception) {
        let diagnostic = if (e.message.trimAscii().isEmpty()) {
            "${label}: invalid utf8 byte sequence"
        } else {
            "${label}: ${e.message}"
        }
        CronScriptReadResult(false, status: "invalid_response_encoding", diagnostic: diagnostic)
    }
}

private func cronScriptError(status: String, errorCode: String, message: String): CronScriptRunResult {
    CronScriptRunResult(false, status: status, errorCode: errorCode, message: message)
}

public func runCronJobScriptForJob(
    dotDir: Path,
    job: CronJob,
    remainingMs!: Int64 = CRON_SCRIPT_TIMEOUT_MS,
    cancellationCheck!: () -> Unit = { => () }
): CronScriptRunResult {
    try {
        cancellationCheck()
    } catch (e: Exception) {
        return cronScriptError("cancelled", "cron_script_cancelled", e.message)
    }
    if (remainingMs <= 0) {
        return CronScriptRunResult(
            false,
            status: "timeout",
            errorCode: "cron_script_timeout",
            timedOut: true,
            message: "cron script deadline reached before launch"
        )
    }
    let resolved = resolveCronScriptPath(dotDir, job.scriptPath)
    if (!resolved.ok) {
        return cronScriptError(resolved.status, resolved.errorCode, resolved.message)
    }
    let scriptPath = resolved.path
    if (!cronScriptSupportedExtension(scriptPath.toString())) {
        return cronScriptError(
            "unsupported_extension",
            "cron_script_unsupported_extension",
            "cron script extension must be .sh or .bash"
        )
    }
    if (!exists(scriptPath)) {
        return cronScriptError("not_found", "cron_script_not_found", "cron script file does not exist")
    }

    try {
        let process = launch(
            "/bin/bash",
            [scriptPath.toString()],
            stdOut: ProcessRedirect.Pipe,
            stdErr: ProcessRedirect.Pipe,
            workingDirectory: Some(cronScriptsDir(dotDir))
        )
        let stdoutFuture = spawn {
            cronScriptReadPipe(StringReader<InputStream>(process.stdOutPipe), "stdout")
        }
        let stderrFuture = spawn {
            cronScriptReadPipe(StringReader<InputStream>(process.stdErrPipe), "stderr")
        }
        let effectiveTimeoutMs = min(CRON_SCRIPT_TIMEOUT_MS, remainingMs)
        let exitCode = try {
            process.wait(timeout: Duration.millisecond * effectiveTimeoutMs)
        } catch (_: TimeoutException) {
            try { process.terminate(force: true) } catch (_: Exception) { () }
            try { let _ = process.wait(timeout: Duration.second) } catch (_: Exception) { () }
            try { stdoutFuture.get() } catch (_: Exception) { () }
            try { stderrFuture.get() } catch (_: Exception) { () }
            return CronScriptRunResult(
                false,
                status: "timeout",
                errorCode: "cron_script_timeout",
                timedOut: true,
                message: "cron script timed out after ${effectiveTimeoutMs}ms"
            )
        }
        try {
            cancellationCheck()
        } catch (e: Exception) {
            return cronScriptError("cancelled", "cron_script_cancelled", e.message)
        }
        let stdout = try { stdoutFuture.get() } catch (e: Exception) {
            CronScriptReadResult(false, status: "invalid_response_encoding", diagnostic: e.message)
        }
        let stderr = try { stderrFuture.get() } catch (e: Exception) {
            CronScriptReadResult(false, status: "invalid_response_encoding", diagnostic: e.message)
        }
        if (!stdout.ok) {
            return CronScriptRunResult(
                false,
                status: stdout.status,
                errorCode: "invalid_response_encoding",
                message: stdout.diagnostic
            )
        }
        if (!stderr.ok) {
            return CronScriptRunResult(
                false,
                status: stderr.status,
                errorCode: "invalid_response_encoding",
                output: cronScriptSanitizeOutputForTest(stdout.text),
                message: stderr.diagnostic
            )
        }
        let out = cronScriptSanitizeOutputForTest(stdout.text)
        let err = cronScriptSanitizeOutputForTest(stderr.text, maxRunes: 4000)
        if (exitCode != 0) {
            return CronScriptRunResult(
                false,
                status: "exit_nonzero",
                errorCode: "cron_script_exit_nonzero",
                output: out,
                stderr: err,
                exitCode: exitCode,
                message: if (err.trimAscii().isEmpty()) { "cron script exited with code ${exitCode}" } else { err }
            )
        }
        CronScriptRunResult(true, output: out, stderr: err, exitCode: exitCode)
    } catch (e: Exception) {
        cronScriptError("failed", "cron_script_failed", e.message)
    }
}
