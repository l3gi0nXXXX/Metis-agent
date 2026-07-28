package metis.gateway.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*

import metis.core.{gatewayCheckCurrentToolCancellation, gatewayCurrentToolRemainingMs, gatewayHeartbeatCurrentToolExecution, resolveCurrentCronShellExecutionDecision}
import metis.io.{InputUtils, PrintUtils, Confirmation}
import metis.utils.{SHELL_INVALID_RESPONSE_ENCODING_DIAGNOSTIC, SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE, ShellUtils, ShellTimeoutException}

import std.fs.Path

@tool[
    description: "Executes a shell command inside an absolute working directory with optional interactive mode.",
    parameters: {
        path: "Absolute working directory path.",
        command: "Shell command to execute.",
        description: "Optional short description shown to the user before confirmation.",
        interactive: "Optional. When true, run attached to the terminal."
    }
]
protected func shellExecute(path: String, command: String, description: Option<String>, interactive: Option<Bool>): String {
    gatewayShellExecuteInternal(path, command, description, interactive, true)
}

private func gatewayShellPrintToolResult(text: String, emitToolResult: Bool): Unit {
    if (emitToolResult) {
        PrintUtils.printToolResult(text)
    }
}

private func gatewayShellExecuteInternal(path: String, command: String, description: Option<String>, interactive: Option<Bool>, emitToolResult: Bool): String {
    gatewayCheckCurrentToolCancellation()
    let cronDecision = resolveCurrentCronShellExecutionDecision(command)
    if (cronDecision.applies) {
        if (!cronDecision.approved) {
            return cronDecision.message
        }
    } else {
        if (InputUtils.confirm("Shell", description ?? "", command) == Confirmation.Deny) {
            return "User denied the operation"
        }
    }

    try {
        let isInteractive = interactive ?? false
        if (isInteractive) {
            InputUtils.lockTerminalInput()
            InputUtils.exitRawMode()
            try {
                let exitCode = ShellUtils.executeInteractive(
                    [command],
                    workDir: Path(path),
                    usePowerShellOnWindows: true
                )
                return "Interactive command finished with exit code ${exitCode}."
            } finally {
                InputUtils.enterRawMode()
                InputUtils.unlockTerminalInput()
            }
        }

        let remainingMs = gatewayCurrentToolRemainingMs(defaultMs: 180000)
        if (remainingMs <= 0) {
            return "Command execution cancelled: execution deadline reached"
        }
        let effectiveTimeoutMs = min(180000, remainingMs)
        let (exitCode, stdout, stderr) = ShellUtils.executeWithDeadline(
            command,
            effectiveTimeoutMs,
            workDir: Some(Path(path))
        )
        gatewayCheckCurrentToolCancellation()
        gatewayHeartbeatCurrentToolExecution()
        if (exitCode == 124) {
            gatewayShellPrintToolResult("Timeout", emitToolResult)
            return "Command execution timeout after ${effectiveTimeoutMs}ms"
        }
        if (exitCode == SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE) {
            gatewayShellPrintToolResult(SHELL_INVALID_RESPONSE_ENCODING_DIAGNOSTIC, emitToolResult)
            return "Command execution failed: ${SHELL_INVALID_RESPONSE_ENCODING_DIAGNOSTIC}"
        }
        if (exitCode == 0) {
            let outString = stdout.trimAscii()
            gatewayShellPrintToolResult(outString, emitToolResult)
            return "Command executed successfully, output:\n${outString}"
        }
        let errString = stderr.trimAscii()
        gatewayShellPrintToolResult(errString, emitToolResult)
        return "Command execution failed, error output:\n${errString}"
    } catch (e: ShellTimeoutException) {
        gatewayShellPrintToolResult("Timeout", emitToolResult)
        return "Command execution timeout after 3 minutes: ${e.message}"
    } catch (e: Exception) {
        gatewayShellPrintToolResult("Exception", emitToolResult)
        return "Exception occurred while executing command: ${e}\nCommand: ${command}"
    }
}

public func debugGatewayShellExecuteForTest(path: String, command: String, description: Option<String>, interactive: Option<Bool>): String {
    gatewayShellExecuteInternal(path, command, description, interactive, false)
}

@toolset[
    tools: [
        shellExecute
    ]
]
public class GatewayShellToolset {
}
