package metis.utils

import magic.log.LogUtils
import metis.process.{ManagedStdioBrokerClient, ManagedStdioOwnerSpec, managedStdioBroker}
import std.process.*
import std.fs.Path
import std.time.*
import std.sync.*

// Timeout exception for shell command execution
public class ShellTimeoutException <: Exception {
    public init(message: String) {
        super(message)
    }
}

public let SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE: Int64 = 125
public let SHELL_INVALID_RESPONSE_ENCODING_DIAGNOSTIC: String = "invalid_response_encoding"
public let SHELL_PROCESS_TREE_DEGRADED_DIAGNOSTIC: String = "process_tree_termination_degraded"
public let SHELL_BROKER_CLEANUP_FAILED_DIAGNOSTIC: String = "broker_cleanup_failed"
public let SHELL_CAPTURE_OUTPUT_LIMIT_BYTES: Int64 = 4 * 1024 * 1024
private let shellBrokerOwnerLock = Mutex()
private var shellBrokerOwnerSequence: Int64 = 0
private var shellBrokerProviderForTest: Option<() -> ManagedStdioBrokerClient> = None<() -> ManagedStdioBrokerClient>

private class ShellBrokerCaptureResult {
    public let status: String
    public let exitCode: Int64
    public let stdout: String
    public let stderr: String

    public init(status: String, exitCode!: Int64 = 1, stdout!: String = "", stderr!: String = "") {
        this.status = status
        this.exitCode = exitCode
        this.stdout = stdout
        this.stderr = stderr
    }
}

private func nextShellBrokerOwnerId(): String {
    synchronized(shellBrokerOwnerLock) {
        shellBrokerOwnerSequence += 1
        "shell-command-${shellBrokerOwnerSequence}"
    }
}

private func shellBrokerClient(): ManagedStdioBrokerClient {
    let provider = synchronized(shellBrokerOwnerLock) {
        shellBrokerProviderForTest
    }
    match (provider) {
        case Some(value) => value()
        case None => managedStdioBroker()
    }
}

public func debugSetShellBrokerProviderForTest(provider: Option<() -> ManagedStdioBrokerClient>): Unit {
    synchronized(shellBrokerOwnerLock) {
        shellBrokerProviderForTest = provider
    }
}

public class ShellUtils {
    private static func durationMilliseconds(timeout: Duration): Int64 {
        let nanos = timeout.toNanoseconds()
        max(1, nanos / 1000000 + if (nanos % 1000000 == 0) {
            0
        } else {
            1
        })
    }

    private static func executeCapturedWithBroker(
        cmd: String,
        cmdArgs: Array<String>,
        timeoutMs: Int64,
        workDir: Option<Path>
    ): ShellBrokerCaptureResult {
        let broker = shellBrokerClient()
        let ownerId = nextShellBrokerOwnerId()
        let started = broker.startOwner(
            ManagedStdioOwnerSpec(
                ownerId,
                cmd,
                args: cmdArgs,
                workingDirectory: match (workDir) {
                    case Some(value) => Some(value.toString())
                    case None => None<String>
                },
                stdinMode: "closed",
                outputMode: "stream",
                deadlineMs: max(1, timeoutMs),
                maxLineBytes: SHELL_CAPTURE_OUTPUT_LIMIT_BYTES,
                maxBufferedBytes: SHELL_CAPTURE_OUTPUT_LIMIT_BYTES,
                maxTotalOutputBytes: SHELL_CAPTURE_OUTPUT_LIMIT_BYTES
            )
        )
        if (!started.ok) {
            return ShellBrokerCaptureResult(started.status, stderr: started.status)
        }
        let stdout = StringBuilder()
        let stderr = StringBuilder()
        // Total bound: command deadline + 3s broker TERM/KILL collection grace,
        // followed by at most 1.5s stop and 1.5s terminal/event drain.
        let collectionDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + max(1, timeoutMs) + 3000
        var terminalConsumed = false
        var loopDone = false
        var cleanupComplete = false
        var outcome = ShellBrokerCaptureResult(
            "timed_out", exitCode: 124, stdout: stdout.toString(), stderr: stderr.toString())
        try {
            while (!loopDone && DateTime.now().toUnixTimeStamp().toMilliseconds() < collectionDeadline) {
                match (broker.readOwnerLine(ownerId, timeoutMs: 250)) {
                    case Some(event) =>
                        if (event.eventType == "owner.stdout") {
                            stdout.append(event.text)
                        } else if (event.eventType == "owner.stderr") {
                            stderr.append(event.text)
                        } else if (event.eventType == "owner.exit") {
                            terminalConsumed = true
                            loopDone = true
                            outcome = ShellBrokerCaptureResult("exited", exitCode: event.exitCode,
                                stdout: stdout.toString(), stderr: stderr.toString())
                        } else if (event.eventType == "owner.timeout") {
                            terminalConsumed = true
                            loopDone = true
                            outcome = ShellBrokerCaptureResult("timed_out", exitCode: 124, stdout: stdout.toString(),
                                stderr: stderr.toString())
                        } else if (event.eventType == "owner.error") {
                            terminalConsumed = true
                            loopDone = true
                            let diagnostic = if (event.status.isEmpty()) {
                                "broker_error"
                            } else {
                                event.status
                            }
                            outcome = ShellBrokerCaptureResult(diagnostic, stdout: stdout.toString(), stderr: diagnostic)
                        }
                    case None =>
                        let snapshot = broker.snapshot()
                        if (snapshot.generation != started.generation || !snapshot.running || !snapshot.responsive) {
                            loopDone = true
                            outcome = ShellBrokerCaptureResult("broker_unavailable", stdout: stdout.toString(),
                                stderr: "broker_unavailable")
                        }
                }
            }
            if (!loopDone) {
                outcome = ShellBrokerCaptureResult(
                    "timed_out", exitCode: 124, stdout: stdout.toString(), stderr: stderr.toString())
            }
        } finally {
            // Stop and drain each receive a separate 1.5s cleanup budget. Draining the unique,
            // never-reused owner is required to remove its settled broker record.
            let stopped = broker.stopOwner(ownerId, timeoutMs: 1500, expectedGeneration: Some(started.generation))
            let drainDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 1500
            var terminalDrained = terminalConsumed || stopped.status == "already_stopped"
            while (!terminalDrained && DateTime.now().toUnixTimeStamp().toMilliseconds() < drainDeadline) {
                match (broker.readOwnerLine(ownerId, timeoutMs: 100)) {
                    case Some(event) => terminalDrained = event.eventType == "owner.exit" || event.eventType ==
                        "owner.timeout" || event.eventType == "owner.error"
                    case None =>
                        let snapshot = broker.snapshot()
                        terminalDrained = stopped.ok || snapshot.generation != started.generation || !snapshot.running
                }
            }
            if (!terminalDrained) {
                let snapshot = broker.snapshot()
                terminalDrained = snapshot.generation != started.generation || !snapshot.running
            }
            cleanupComplete = terminalDrained
        }
        if (!cleanupComplete) {
            // A missing terminal after the owner stop budget means the broker may no
            // longer be servicing this generation. Probe only the generation that
            // launched this owner. The broker's existing unresponsive path reaps
            // every process tree from that failed generation; a concurrently started
            // replacement generation is never stopped here.
            let stalled = broker.snapshot()
            if (stalled.generation == started.generation && stalled.running) {
                let _ = broker.probeBrokerForGeneration(started.generation, timeoutMs: 500)
            }
            let recoveryDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 1500
            var oldRecordRemoved = false
            while (!oldRecordRemoved &&
                DateTime.now().toUnixTimeStamp().toMilliseconds() < recoveryDeadline) {
                match (broker.readOwnerLine(ownerId, timeoutMs: 100)) {
                    case Some(_) => ()
                    case None => oldRecordRemoved = true
                }
            }
            let recovered = broker.snapshot()
            cleanupComplete = oldRecordRemoved &&
                (recovered.generation != started.generation || !recovered.running)
            return ShellBrokerCaptureResult(
                SHELL_BROKER_CLEANUP_FAILED_DIAGNOSTIC,
                stdout: outcome.stdout,
                stderr: SHELL_BROKER_CLEANUP_FAILED_DIAGNOSTIC
            )
        }
        outcome
    }

    private static func buildCommandArgs(command: Array<String>, withWrap: Bool, usePowerShellOnWindows: Bool): (String, Array<String>) {
        if (!withWrap) {
            let args: Array<String> = if (command.size > 1) { command[1..] } else { [] }
            return (command[0], args)
        }
        if (InfoUtils.os == "windows") {
            // 如果在windows上，可以指定使用PowerShell，否则默认使用cmd，其他os上则不受这个参数的影响
            if (usePowerShellOnWindows) {
                return ("powershell", ["-Command", String.join(command, delimiter: " ")])
            } else {
                return ("cmd", ["/c", String.join(command, delimiter: " ")])
            }
        } else {
            return ("sh", ["-c", String.join(command, delimiter: " ")])
        }
    }

    public static func execute(command: Array<String>,
                               timeout!: Option<Duration> = None,
                               workDir!: Option<Path> = None,
                               withWrap!: Bool = true,
                               usePowerShellOnWindows!: Bool = false,
                               logFailures!: Bool = true): (Int64, String, String) {
        let (cmd, cmdArgs) = buildCommandArgs(command, withWrap, usePowerShellOnWindows)

        match (timeout) {
            case None =>
                let (exitCode, stdoutBytes, stderrBytes) = executeWithOutput(
                    cmd,
                    cmdArgs,
                    workingDirectory: workDir
                )
                let stdout = try {
                    String.fromUtf8(stdoutBytes)
                } catch (e: Exception) {
                    LogUtils.debug("[ShellUtils] Failed to decode stdout: ${e}")
                    ""
                }
                let stderr = try {
                    String.fromUtf8(stderrBytes)
                } catch (e: Exception) {
                    LogUtils.debug("[ShellUtils] Failed to decode stderr: ${e}")
                    ""
                }
                if (exitCode != 0 && logFailures) {
                    LogUtils.error("Shell command execution failed: ${exitCode}")
                    LogUtils.error("  ${cmd} ${String.join(cmdArgs, delimiter: ' ')}")
                }
                return (exitCode, stdout, stderr)
            case Some(_) => ()
        }

        let result = executeCapturedWithBroker(cmd, cmdArgs, durationMilliseconds(timeout.getOrThrow()), workDir)
        if (result.status == "timed_out") {
            throw ShellTimeoutException("Shell command execution timed out")
        }
        if (result.status == SHELL_INVALID_RESPONSE_ENCODING_DIAGNOSTIC) {
            return (SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE, "", SHELL_INVALID_RESPONSE_ENCODING_DIAGNOSTIC)
        }
        if (result.exitCode != 0 && logFailures) {
            LogUtils.error("Shell command execution failed: ${result.exitCode}")
        }
        (result.exitCode, result.stdout, result.stderr)
    }

    /**
     * Execute a non-interactive shell command with a millisecond deadline.
     *
     * The managed stdio broker owns the command process group, drains both
     * output streams, and reaps descendants before returning timeout code 124.
     */
    public static func executeWithDeadline(
        command: String,
        timeoutMs: Int64,
        workDir!: Option<Path> = None,
        pgrepPath!: String = "/usr/bin/pgrep"
    ): (Int64, String, String) {
        let effective = max(1, timeoutMs)
        if (InfoUtils.os != "macos" && InfoUtils.os != "linux") {
            return execute(
                [command],
                timeout: Some(Duration.millisecond * effective),
                workDir: workDir,
                usePowerShellOnWindows: true,
                logFailures: false
            )
        }
        let result = executeCapturedWithBroker("/bin/sh", ["-c", command], effective, workDir)
        if (result.status == SHELL_INVALID_RESPONSE_ENCODING_DIAGNOSTIC) {
            LogUtils.debug("[ShellUtils] shell output decode failed: invalid_response_encoding")
            return (SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE, "", SHELL_INVALID_RESPONSE_ENCODING_DIAGNOSTIC)
        }
        var stderr = result.stderr
        let pgrepExecutable = try {
            executeWithOutput("/bin/test", ["-x", pgrepPath])[0] == 0
        } catch (_: Exception) {
            false
        }
        if (!pgrepExecutable) {
            stderr = if (stderr.isEmpty()) {
                SHELL_PROCESS_TREE_DEGRADED_DIAGNOSTIC
            } else {
                "${stderr}\n${SHELL_PROCESS_TREE_DEGRADED_DIAGNOSTIC}"
            }
            LogUtils.debug("[ShellUtils] process tree termination degraded: compatibility pgrep path unavailable")
        }
        (if (result.status == "timed_out") {
                124
            } else {
                result.exitCode
            }, result.stdout, stderr)
    }

    /**
     * Execute a command attached to the current terminal (no output capture).
     */
    public static func executeInteractive(command: Array<String>,
                                          timeout!: Option<Duration> = None,
                                          workDir!: Option<Path> = None,
                                          withWrap!: Bool = true,
                                          usePowerShellOnWindows!: Bool = false): Int64 {
        let (cmd, cmdArgs) = buildCommandArgs(command, withWrap, usePowerShellOnWindows)

        let process = launch(
            cmd,
            cmdArgs,
            stdIn: Inherit,
            stdOut: Inherit,
            stdErr: Inherit,
            workingDirectory: workDir
        )

        try {
            return process.wait(timeout: timeout)
        } catch(ex: TimeoutException) {
            try {
                process.terminate(force: true)
            } catch (terminateErr: Exception) {
                LogUtils.debug("[ShellUtils] Failed to terminate interactive process after timeout: ${terminateErr}")
            }
            throw ShellTimeoutException("Interactive shell command execution timed out")
        }
    }
}
