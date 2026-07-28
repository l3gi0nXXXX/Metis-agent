package metis.utils

import magic.log.LogUtils

import std.process.*
import std.fs.{File, Path, remove}
import std.collection.ArrayList
import std.time.*
import std.sync.*
import std.io.*

// Timeout exception for shell command execution
public class ShellTimeoutException <: Exception {
    public init(message: String) {
        super(message)
    }
}

public let SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE: Int64 = 125
public let SHELL_INVALID_RESPONSE_ENCODING_DIAGNOSTIC: String = "invalid_response_encoding"
public let SHELL_PROCESS_TREE_DEGRADED_DIAGNOSTIC: String = "process_tree_termination_degraded"

public class ShellUtils {
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

        let process = launch(
            cmd,
            cmdArgs,
            stdOut: ProcessRedirect.Pipe,
            stdErr: ProcessRedirect.Pipe,
            workingDirectory: workDir
        )

        let stdoutFuture = spawn {
            let reader = StringReader(process.stdOutPipe)
            try {
                return reader.readToEnd()
            } catch (e: Exception) {
                LogUtils.debug("[ShellUtils] Failed to read stdout: ${e}")
                return ""
            }
        }
        let stderrFuture = spawn {
            let reader = StringReader(process.stdErrPipe)
            try {
                return reader.readToEnd()
            } catch (e: Exception) {
                LogUtils.debug("[ShellUtils] Failed to read stderr: ${e}")
                return ""
            }
        }

        try {
            let exitCode = process.wait(timeout: timeout)
            let stdout = try {
                stdoutFuture.get()
            } catch (e: Exception) {
                LogUtils.debug("[ShellUtils] Failed to collect stdout: ${e}")
                ""
            }
            let stderr = try {
                stderrFuture.get()
            } catch (e: Exception) {
                LogUtils.debug("[ShellUtils] Failed to collect stderr: ${e}")
                ""
            }

            if (exitCode != 0 && logFailures) {
                LogUtils.error("Shell command execution failed: ${exitCode}")
                LogUtils.error("  ${cmd} ${String.join(cmdArgs, delimiter: ' ')}")
            }
            return (exitCode, stdout, stderr)
        } catch(ex: TimeoutException) {
            try {
                process.terminate(force: true)
            } catch (terminateErr: Exception) {
                LogUtils.debug("[ShellUtils] Failed to terminate process after timeout: ${terminateErr}")
            }
            // Ensure pipe readers exit before bubbling up
            try { stdoutFuture.get() } catch (_: Exception) { }
            try { stderrFuture.get() } catch (_: Exception) { }
            throw ShellTimeoutException("Shell command execution timed out")
        }
    }

    /**
     * Execute a non-interactive shell command with a millisecond deadline.
     *
     * `Process.terminate` only terminates the wrapper shell. A command such as
     * `sleep 30` can otherwise keep inherited pipes open and make output readers
     * wait until the child exits naturally. On Unix this wrapper recursively
     * terminates descendants before returning the conventional timeout code 124.
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
        let seconds = "${effective / 1000}.${(effective % 1000).toString().padStart(3, padding: "0")}"
        let nonce = "${DateTime.now().toUnixTimeStamp().toNanoseconds()}-${Thread.currentThread.id}"
        let stdoutPath = Path("/tmp/metis-shell-deadline-${nonce}.out")
        let stderrPath = Path("/tmp/metis-shell-deadline-${nonce}.err")
        let wrapper = """
kill_tree() {
  child_pids=$("$5" -P "$1" 2>/dev/null)
  kill -TERM "$1" 2>/dev/null || true
  for child_pid in $child_pids; do
    kill_tree "$child_pid"
  done
  kill -KILL "$1" 2>/dev/null || true
}
umask 077
/bin/sh -c "$1" >>"$3" 2>>"$4" &
command_pid=$!
if [ -x "$5" ]; then
  ( sleep "$2"; kill_tree "$command_pid" ) </dev/null >/dev/null 2>&1 &
else
  printf '%s\n' 'process_tree_termination_degraded' >>"$4"
  ( sleep "$2"; kill -TERM "$command_pid" 2>/dev/null || true; kill -KILL "$command_pid" 2>/dev/null || true ) </dev/null >/dev/null 2>&1 &
fi
watchdog_pid=$!
wait "$command_pid"
status=$?
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
if [ "$status" -ge 128 ]; then
  exit 124
fi
exit "$status"
"""
        try {
            let result = execute(
                [
                    "/bin/sh", "-c", wrapper, "metis-deadline", command, seconds,
                    stdoutPath.toString(), stderrPath.toString(), pgrepPath
                ],
                timeout: Some(Duration.millisecond * (effective + 500)),
                workDir: workDir,
                withWrap: false,
                logFailures: false
            )
            var invalidEncoding = false
            let stdout = try {
                String.fromUtf8(File.readFrom(stdoutPath))
            } catch (_: Exception) {
                invalidEncoding = true
                ""
            }
            let stderr = try {
                String.fromUtf8(File.readFrom(stderrPath))
            } catch (_: Exception) {
                invalidEncoding = true
                ""
            }
            if (invalidEncoding) {
                LogUtils.debug("[ShellUtils] shell output decode failed: invalid_response_encoding")
                return (
                    SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE,
                    "",
                    SHELL_INVALID_RESPONSE_ENCODING_DIAGNOSTIC
                )
            }
            if (stderr.contains(SHELL_PROCESS_TREE_DEGRADED_DIAGNOSTIC)) {
                LogUtils.debug("[ShellUtils] process tree termination degraded: pgrep unavailable")
            }
            return (result[0], stdout, stderr)
        } finally {
            try { remove(stdoutPath) } catch (_: Exception) { () }
            try { remove(stderrPath) } catch (_: Exception) { () }
        }
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
