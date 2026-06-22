package metis.gateway.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*

import metis.core.resolveCurrentCronShellExecutionDecision
import metis.io.{InputUtils, PrintUtils, Confirmation}
import metis.utils.{ShellUtils, ShellTimeoutException}

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

        let (exitCode, stdout, stderr) = ShellUtils.execute(
            [command],
            workDir: Path(path),
            timeout: Duration.second * 180,
            usePowerShellOnWindows: true
        )
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
