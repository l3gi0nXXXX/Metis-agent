package metis.cron

import metis.core.{metisDecodeUtf8Bytes, metisRedactSensitiveText, metisSafeRuneEllipsis}
import metis.process.{ManagedStdioOwnerSpec, managedStdioBroker}

import std.fs.{Path, exists}
import std.sync.Mutex
import std.time.*

private let CRON_SCRIPT_TIMEOUT_MS: Int64 = 30000
private let CRON_SCRIPT_OUTPUT_MAX_RUNES: Int64 = 16000
private let CRON_SCRIPT_STDERR_MAX_RUNES: Int64 = 4000
private let CRON_SCRIPT_OUTPUT_MAX_BYTES: Int64 = 65536
private let cronScriptOwnerLock = Mutex()
private var cronScriptOwnerSequence: Int64 = 0

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
    let cleaned = metisRedactSensitiveText(text).replace("\u{0000}", "").replace("\r", " ")
    metisSafeRuneEllipsis(cleaned, maxRunes)
}

public func cronScriptOutputMaxBytesForTest(): Int64 {
    CRON_SCRIPT_OUTPUT_MAX_BYTES
}

private func nextCronScriptOwnerId(): String {
    synchronized(cronScriptOwnerLock) {
        cronScriptOwnerSequence += 1
        "cron-script-${cronScriptOwnerSequence}"
    }
}

private func cronScriptError(status: String, errorCode: String, message: String): CronScriptRunResult {
    CronScriptRunResult(
        false,
        status: status,
        errorCode: errorCode,
        message: cronScriptSanitizeOutputForTest(message, maxRunes: CRON_SCRIPT_STDERR_MAX_RUNES)
    )
}

private func cronScriptStopAndDrain(ownerId: String, generation: Int64, timeoutMs: Int64): Unit {
    let broker = managedStdioBroker()
    let _ = broker.stopOwner(ownerId, timeoutMs: max(1, timeoutMs), expectedGeneration: Some(generation))
    while (broker.readOwnerLine(ownerId, timeoutMs: 0).isSome()) { () }
}

private func cronScriptTerminalError(
    status: String,
    output: String,
    stderr: String
): CronScriptRunResult {
    let out = cronScriptSanitizeOutputForTest(output)
    let err = cronScriptSanitizeOutputForTest(stderr, maxRunes: CRON_SCRIPT_STDERR_MAX_RUNES)
    if (status == "invalid_response_encoding") {
        return CronScriptRunResult(
            false,
            status: status,
            errorCode: "invalid_response_encoding",
            output: out,
            stderr: err,
            message: "cron script output contained invalid utf8"
        )
    }
    let capacity = status == "output_too_large" || status == "buffer_capacity_exceeded" ||
        status == "subscriber_capacity_exceeded" || status == "line_too_large"
    CronScriptRunResult(
        false,
        status: if (capacity) { "output_limit" } else { "failed" },
        errorCode: if (capacity) { "cron_script_output_too_large" } else { "cron_script_failed" },
        output: out,
        stderr: err,
        message: "cron script process failed: ${cronScriptSanitizeOutputForTest(status, maxRunes: 80)}"
    )
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

    let effectiveTimeoutMs = min(CRON_SCRIPT_TIMEOUT_MS, remainingMs)
    let deadlineMs = DateTime.now().toUnixTimeStamp().toMilliseconds() + effectiveTimeoutMs
    let ownerId = nextCronScriptOwnerId()
    let broker = managedStdioBroker()
    let started = broker.startOwner(ManagedStdioOwnerSpec(
        ownerId,
        "/bin/bash",
        args: [scriptPath.toString()],
        workingDirectory: Some(cronScriptsDir(dotDir).toString()),
        stdinMode: "closed",
        outputMode: "stream",
        deadlineMs: effectiveTimeoutMs,
        maxLineBytes: CRON_SCRIPT_OUTPUT_MAX_BYTES,
        maxBufferedBytes: CRON_SCRIPT_OUTPUT_MAX_BYTES,
        maxTotalOutputBytes: CRON_SCRIPT_OUTPUT_MAX_BYTES
    ), timeoutMs: min(3000, effectiveTimeoutMs))
    if (!started.ok) {
        if (started.status == "start_timeout" || DateTime.now().toUnixTimeStamp().toMilliseconds() >= deadlineMs) {
            return CronScriptRunResult(
                false,
                status: "timeout",
                errorCode: "cron_script_timeout",
                timedOut: true,
                message: "cron script timed out after ${effectiveTimeoutMs}ms"
            )
        }
        return cronScriptError("failed", "cron_script_failed", "cron script process failed: ${started.status}")
    }
    let stdout = StringBuilder()
    let stderr = StringBuilder()
    try {
        var completed = None<CronScriptRunResult>
        while (completed.isNone()) {
            try {
                cancellationCheck()
            } catch (cancelled: Exception) {
                cronScriptStopAndDrain(ownerId, started.generation, 1000)
                completed = Some(cronScriptError("cancelled", "cron_script_cancelled", cancelled.message))
                continue
            }
            let remaining = deadlineMs - DateTime.now().toUnixTimeStamp().toMilliseconds()
            if (remaining <= 0) {
                cronScriptStopAndDrain(ownerId, started.generation, 1000)
                completed = Some(CronScriptRunResult(
                    false,
                    status: "timeout",
                    errorCode: "cron_script_timeout",
                    timedOut: true,
                    message: "cron script timed out after ${effectiveTimeoutMs}ms"
                ))
                continue
            }
            match (broker.readOwnerLine(ownerId, timeoutMs: min(25, remaining))) {
                case Some(event) =>
                    if (event.eventType == "owner.stdout") {
                        stdout.append(event.text)
                    } else if (event.eventType == "owner.stderr") {
                        stderr.append(event.text)
                    } else if (event.eventType == "owner.timeout") {
                        completed = Some(CronScriptRunResult(
                            false,
                            status: "timeout",
                            errorCode: "cron_script_timeout",
                            output: cronScriptSanitizeOutputForTest(stdout.toString()),
                            stderr: cronScriptSanitizeOutputForTest(stderr.toString(), maxRunes: CRON_SCRIPT_STDERR_MAX_RUNES),
                            timedOut: true,
                            message: "cron script timed out after ${effectiveTimeoutMs}ms"
                        ))
                    } else if (event.eventType == "owner.error") {
                        completed = Some(cronScriptTerminalError(event.status, stdout.toString(), stderr.toString()))
                    } else if (event.eventType == "owner.exit") {
                        let out = cronScriptSanitizeOutputForTest(stdout.toString())
                        let err = cronScriptSanitizeOutputForTest(stderr.toString(), maxRunes: CRON_SCRIPT_STDERR_MAX_RUNES)
                        if (event.exitCode != 0) {
                            completed = Some(CronScriptRunResult(
                                false,
                                status: "exit_nonzero",
                                errorCode: "cron_script_exit_nonzero",
                                output: out,
                                stderr: err,
                                exitCode: event.exitCode,
                                message: if (err.trimAscii().isEmpty()) { "cron script exited with code ${event.exitCode}" } else { err }
                            ))
                        } else {
                            completed = Some(CronScriptRunResult(true, output: out, stderr: err, exitCode: event.exitCode))
                        }
                    }
                case None => ()
            }
        }
        completed.getOrThrow()
    } catch (e: Exception) {
        cronScriptError("failed", "cron_script_failed", e.message)
    } finally {
        cronScriptStopAndDrain(ownerId, started.generation, 1000)
    }
}
