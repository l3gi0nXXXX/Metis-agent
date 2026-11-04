package metis.sandbox

import metis.process.{managedRecoveryLaunchOwned, managedRecoveryWaitForCommand}

import metis.process.managedRecoveryExecuteWithOutput

import magic.log.LogUtils
import metis.core.config.CliConfig
import metis.utils.{InfoUtils, StringUtils}

import std.process.*
import std.fs.*
import std.io.*
import std.collection.*
import std.posix.*
import std.time.*
import std.convert.*
import std.regex.*
import std.env.{getVariable, getVariables}

// Constants
private const LOCAL_DEV_SANDBOX_IMAGE_NAME = "magic-cli-sandbox"

/**
 * Container sandbox implementation (Docker/Podman)
 */
func startContainerSandbox(config: SandboxConfig, cliArgs: Array<String>): Int64 {
    let workdir = CliConfig.cwd
    let containerWorkdir = SandboxConfig.WORK_DIR
    let image = config.image

    // Check if image exists
    if (!ensureSandboxImageIsPresent(config.command, image)) {
        let msg = "Try running `./scripts/build-docker-image.sh` under the Metis repo to build it locally, or check the image name and your network connection."
        throw FatalSandboxError("Sandbox image '${image}' is missing or could not be pulled. ${msg}")
    }

    // Build container arguments
    let args = ArrayList([
        "run", "-i", "--rm", "--init", "--workdir", containerWorkdir
    ])

    // Enforce the docker image platform
    if (InfoUtils.os == "macos") {
        args.add("--platform=linux/amd64")
    }

    // Add TTY if stdin is TTY
    // How to check if the current stdin is a TTY?
    args.add("-t")

    // Add host gateway
    args.add(all: ["--add-host", "host.docker.internal:host-gateway"])

    // Mount current directory
    args.add(all: ["--volume", "${workdir}:${containerWorkdir}"])

    // Mount temp directory
    let tempDir = SandboxConfig.TMP_DIR
    args.add(all: ["--volume", "${tempDir}:${getContainerPath(tempDir)}"])

    // Generate container name
    let imageName = parseImageName(image)

    let (_, containerOutput, _) = managedRecoveryExecuteWithOutput(config.command, ["ps", "-a", "--format", "{{.Names}}"])
    let containerText = try { String.fromUtf8(containerOutput) }
        catch (_: Exception) { throw FatalSandboxError("sandbox_invalid_response_encoding") }
    let containerList = containerText.split("\n") |>
        map { c => c.trimAscii() } |>
        collectArray

    // Find available container name
    var index = 0
    var containerName = ""
    while (true) {
        let candidateName = "${imageName}-${index}"
        if (!containerList.contains(candidateName)) {
            containerName = candidateName
            break
        }
        index++
    }

    args.add(all: ["--name", containerName, "--hostname", containerName])

    // Set SANDBOX as container name
    args.add(all: ["--env", "MAGIC_CLI_IN_SANDBOX=${containerName}"])

    // Inherit environment variables
    for ((env, value) in getVariables()) {
        if (env.contains("API_KEY")) {
            args.add(all: ["--env", "${env}=${value}"])
        }
    }

    // for podman only, use empty --authfile to skip unnecessary auth refresh overhead
    if (config.command == "podman") {
        let emptyAuthFilePath = Path("${SandboxConfig.TMP_DIR}/empty_auth.json")
        File.create(emptyAuthFilePath).close()
        args.add(all: ["--authfile", emptyAuthFilePath.toString()])
    }

    let finalEntrypoint = buildEntrypoint(workdir.toString(), cliArgs.toArray())

    // Determine if the current user's UID/GID should be passed to the sandbox.
    if (shouldUseCurrentUserInSandbox()) {
        args.add("--user")
        args.add("root")

        let uidResult = managedRecoveryExecuteWithOutput("id", ["-u"])
        let gidResult = managedRecoveryExecuteWithOutput("id", ["-g"])
        let (_, uidOutput, _) = uidResult
        let (_, gidOutput, _) = gidResult
        let uid = uidOutput.toString().trimAscii()
        let gid = gidOutput.toString().trimAscii()

        let username = "magic-user"
        let homeDir = getContainerPath(SandboxConfig.HOME_DIR)

        let setupUserCommands = "groupadd -f -g ${gid} ${username} && id -u ${username} &>/dev/null || useradd -o -u ${uid} -g ${gid} -d ${homeDir} -s /bin/bash ${username}"
        let originalCommand = finalEntrypoint[2]
        let escapedOriginalCommand = originalCommand.replace("'", "'\\''")
        let suCommand = "su -p ${username} -c '${escapedOriginalCommand}'"

        finalEntrypoint[2] = "${setupUserCommands} && ${suCommand}"
    }

    // Add image and entrypoint
    args.add(image)

    // Add final entrypoint arguments
    for (arg in finalEntrypoint) {
        args.add(arg)
    }

    let sandboxArgs = args.toArray()
    LogUtils.info("Running container command: ${config.command} ${String.join(sandboxArgs, delimiter: " ")}")

    // Start sandbox process
    let sandboxProcess = managedRecoveryLaunchOwned(config.command, sandboxArgs, stdIn: Inherit, stdOut: Inherit, stdErr: Inherit)

    try { managedRecoveryWaitForCommand(sandboxProcess) } finally { sandboxProcess.closeStreams() }
}

/**
 * Helper function to get container path (Windows path conversion)
 */
func getContainerPath(hostPath: String): String {
    if (InfoUtils.os != "windows") {
        return hostPath
    }

    let withForwardSlashes = hostPath.replace("\\", "/")
    // Simple pattern matching for Windows drive letters
    if (withForwardSlashes.size >= 3) {
        let secondChar = withForwardSlashes[1]
        if (secondChar == 58) { // ASCII value for ':'
            let driveLetter = withForwardSlashes[0..0] // Get first character as string
            let restOfPath = withForwardSlashes[2..]   // Get from index 2 onwards
            return "/" + driveLetter.toAsciiLower() + restOfPath
        }
    }
    return hostPath
}

/**
 * Parse image name to remove invalid characters for container names
 * Docker does not allow container names to contain ':' or '/',
 * so we parse those out to shorten the name
 */
private func parseImageName(image: String): String {
    let parts = image.split(":")
    let fullName = parts[0]
    let tag = if (parts.size > 1) { parts[1] } else { "" }
    let nameParts = fullName.split("/")
    let name = nameParts.last ?? "unknown-image"
    return if (tag.isEmpty()) { name } else { "${name}-${tag}" }
}

/**
 * Check if should use current user in sandbox
 */
private func shouldUseCurrentUserInSandbox(): Bool {
    let envVarValue = (getVariable("SANDBOX_SET_UID_GID")?.toAsciiLower() ?? "").trimAscii()
    if (envVarValue == "1" || envVarValue == "true") {
        return true
    }
    if (envVarValue == "0" || envVarValue == "false") {
        return false
    }

    // Default logic for Linux systems
    if (InfoUtils.os == "linux") {
        let osReleasePath = Path("/etc/os-release")
        if (exists(osReleasePath)) {
            try {
                let allBytes = File.readFrom(osReleasePath)
                let content = String.fromUtf8(allBytes)
                if (content.contains("ID=debian") ||
                    content.contains("ID=ubuntu") ||
                    content.contains("ID_LIKE=.*debian.*") ||
                    content.contains("ID_LIKE=.*ubuntu.*")) {
                    println("INFO: Defaulting to use current user UID/GID for Debian/Ubuntu-based Linux.")
                    return true
                }
            } catch (e: Exception) {
                println("Warning: Could not read /etc/os-release to auto-detect Debian/Ubuntu for UID/GID default.")
            }
        }
    }
    return false
}

/**
 * Build entrypoint command for container
 */
private func buildEntrypoint(workdir: String, cliArgs: Array<String>): Array<String> {
    // Build final CLI command
    let magicCliStartCommand = ArrayList([
        "MAGIC_CLI_IN_SANDBOX=sandbox-exec" // Put the mark env
    ])
    // Add magic-cli command
    magicCliStartCommand.add("magic-cli")
    // Add command line arguments
    for (arg in cliArgs) {
        magicCliStartCommand.add("'${arg}'") // Quote CLI arguments
    }

    let finalCommand = String.join(magicCliStartCommand.toArray(), delimiter: " ")
    return ["bash", "-c", finalCommand]
}

/**
 * Check if Docker/Podman image exists
 */
func imageExists(sandbox: String, image: String): Bool {
    let (exitCode, stdout, _) = managedRecoveryExecuteWithOutput(sandbox, ["images", "-q", image])
    let text = try { String.fromUtf8(stdout) } catch (_: Exception) {
        LogUtils.error("sandbox_invalid_response_encoding")
        return false
    }
    exitCode == 0 && !text.trimAscii().isEmpty()
}

/**
 * Pull Docker/Podman image
 */
func pullImage(sandbox: String, image: String): Bool {
    LogUtils.info("Attempting to pull image ${image} using ${sandbox}...")
    let (exitCode, _, stderr) = managedRecoveryExecuteWithOutput(sandbox, ["pull", image])
    // Validate external text without reflecting untrusted command output into diagnostics.
    try { let _ = String.fromUtf8(stderr) } catch (_: Exception) {
        LogUtils.error("sandbox_invalid_response_encoding")
        return false
    }
    if (exitCode == 0) {
        LogUtils.info("Successfully pulled image ${image}.")
        return true
    }
    LogUtils.error("sandbox_pull_failed exitCode=${exitCode}")
    false
}

/**
 * Ensure sandbox image is present
 */
private func ensureSandboxImageIsPresent(sandbox: String, image: String): Bool {
    LogUtils.info("Checking for sandbox image: ${image}")
    if (imageExists(sandbox, image)) {
        LogUtils.info("Sandbox image ${image} found locally.")
        return true
    }

    LogUtils.info("Sandbox image ${image} not found locally.")
    if (image == LOCAL_DEV_SANDBOX_IMAGE_NAME) {
        return false // User needs to build it themselves
    }

    if (pullImage(sandbox, image)) {
        if (imageExists(sandbox, image)) {
            LogUtils.info("Sandbox image ${image} is now available after pulling.")
            return true
        } else {
            LogUtils.error("Sandbox image ${image} still not found after pull attempt.")
            return false
        }
    }

    LogUtils.error("Failed to obtain sandbox image ${image} after check and pull attempt.")
    return false
}
