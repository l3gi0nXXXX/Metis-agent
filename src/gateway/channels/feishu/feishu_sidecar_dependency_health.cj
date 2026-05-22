package metis.gateway.channels.feishu

import metis.core.config.CliConfig
import metis.utils.ShellUtils

import std.collection.ArrayList
import std.fs.{Path, exists}
import std.time.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString}

private let FEISHU_SIDECAR_INSTALL_HINT = "Run `npm --prefix tools/feishu-sidecar install` from the Metis repository root."
private var feishuSidecarDependencyHealthProviderForTest: Option<() -> FeishuSidecarDependencyHealth> =
    None<() -> FeishuSidecarDependencyHealth>

public class FeishuSidecarDependencyCommandProbeResult {
    public let ok: Bool
    public let version: String
    public let error: String

    public init(ok: Bool, version: String, error: String) {
        this.ok = ok
        this.version = version.trimAscii()
        this.error = error.trimAscii()
    }
}

public class FeishuSidecarDependencyHealth {
    public let ready: Bool
    public let status: String
    public let projectRoot: String
    public let runtimeRoot: String
    public let scriptPath: String
    public let installHint: String
    public let details: String
    public let missingRequirements: Array<String>
    public let invalidRequirements: Array<String>
    public let nodeVersion: String
    public let npmVersion: String

    public init(
        ready: Bool,
        status: String,
        projectRoot: String,
        runtimeRoot: String,
        scriptPath: String,
        installHint: String,
        details: String,
        missingRequirements: Array<String>,
        invalidRequirements: Array<String>,
        nodeVersion: String,
        npmVersion: String
    ) {
        this.ready = ready
        this.status = status.trimAscii()
        this.projectRoot = projectRoot
        this.runtimeRoot = runtimeRoot
        this.scriptPath = scriptPath
        this.installHint = installHint
        this.details = feishuSidecarDependencyRedactDiagnosticText(details)
        this.missingRequirements = missingRequirements
        this.invalidRequirements = invalidRequirements
        this.nodeVersion = nodeVersion
        this.npmVersion = npmVersion
    }

    public func toJson(): JsonObject {
        let out = JsonObject()
        out.put("ready", JsonBool(this.ready))
        out.put("status", JsonString(this.status))
        out.put("projectRoot", JsonString(this.projectRoot))
        out.put("runtimeRoot", JsonString(this.runtimeRoot))
        out.put("scriptPath", JsonString(this.scriptPath))
        out.put("installHint", JsonString(this.installHint))
        out.put("details", JsonString(this.details))
        out.put("missingRequirements", this.stringArrayJson(this.missingRequirements))
        out.put("invalidRequirements", this.stringArrayJson(this.invalidRequirements))
        out.put("nodeVersion", JsonString(this.nodeVersion))
        out.put("npmVersion", JsonString(this.npmVersion))
        out
    }

    private func stringArrayJson(values: Array<String>): JsonArray {
        let out = JsonArray([])
        for (value in values) {
            out.add(JsonString(value))
        }
        out
    }
}

private func feishuSidecarDependencyRedactDiagnosticText(raw: String): String {
    let text = raw.trimAscii()
    if (text.isEmpty()) {
        return ""
    }
    let lower = text.toAsciiLower()
    if (
        lower.contains("authorization") ||
        lower.contains("bearer ") ||
        lower.contains("secret") ||
        lower.contains("token") ||
        lower.contains("password") ||
        lower.contains("api_key") ||
        lower.contains("apikey") ||
        lower.contains("access_token")
    ) {
        return "[redacted]"
    }
    text
}

public func setFeishuSidecarDependencyHealthProviderForTest(provider: Option<() -> FeishuSidecarDependencyHealth>): Unit {
    feishuSidecarDependencyHealthProviderForTest = provider
}

public func feishuSidecarDependencyHealthSnapshot(): FeishuSidecarDependencyHealth {
    match (feishuSidecarDependencyHealthProviderForTest) {
        case Some(provider) => provider()
        case None => feishuSidecarDependencyHealth()
    }
}

private func feishuSidecarDefaultCommandProbe(command: String, args: Array<String>): FeishuSidecarDependencyCommandProbeResult {
    try {
        let commandArgs = ArrayList<String>()
        commandArgs.add(command)
        for (arg in args) {
            commandArgs.add(arg)
        }
        let (code, stdout, stderr) = ShellUtils.execute(
            commandArgs.toArray(),
            timeout: Some(Duration.second * 2),
            withWrap: false
        )
        if (code == 0) {
            return FeishuSidecarDependencyCommandProbeResult(true, stdout.trimAscii(), "")
        }
        FeishuSidecarDependencyCommandProbeResult(false, "", stderr.trimAscii())
    } catch (e: Exception) {
        FeishuSidecarDependencyCommandProbeResult(false, "", e.message)
    }
}

private func feishuSidecarAddMissingIfAbsent(missing: ArrayList<String>, requirement: String): Unit {
    if (!missing.contains(requirement)) {
        missing.add(requirement)
    }
}

private func feishuSidecarHealthDetails(missing: Array<String>, invalid: Array<String>, commandErrors: Array<String>): String {
    if (missing.isEmpty() && invalid.isEmpty()) {
        return "Feishu sidecar dependencies are ready."
    }
    let parts = ArrayList<String>()
    if (!missing.isEmpty()) {
        parts.add("missing=${String.join(missing, delimiter: ",")}")
    }
    if (!invalid.isEmpty()) {
        parts.add("invalid=${String.join(invalid, delimiter: ",")}")
    }
    if (!commandErrors.isEmpty()) {
        parts.add("commands=${String.join(commandErrors, delimiter: "; ")}")
    }
    "${String.join(parts.toArray(), delimiter: "; ")}. ${FEISHU_SIDECAR_INSTALL_HINT}"
}

public func feishuSidecarDependencyHealth(
    projectRoot!: Path = CliConfig.cwd,
    runtimeRoot!: Path = CliConfig.cwd.join("tools").join("feishu-sidecar"),
    commandProbe!: (String, Array<String>) -> FeishuSidecarDependencyCommandProbeResult = feishuSidecarDefaultCommandProbe
): FeishuSidecarDependencyHealth {
    let missing = ArrayList<String>()
    let invalid = ArrayList<String>()
    let commandErrors = ArrayList<String>()
    let scriptPath = projectRoot.join("scripts").join("feishu-sidecar.mjs")
    let packageJson = runtimeRoot.join("package.json")
    let packageLock = runtimeRoot.join("package-lock.json")
    let nodeModules = runtimeRoot.join("node_modules")
    let sdkPackage = nodeModules.join("@larksuiteoapi").join("node-sdk").join("package.json")
    let proxyPackage = nodeModules.join("https-proxy-agent").join("package.json")

    if (!exists(scriptPath)) {
        feishuSidecarAddMissingIfAbsent(missing, "sidecar_script")
    }
    if (!exists(runtimeRoot)) {
        feishuSidecarAddMissingIfAbsent(missing, "runtime_root")
    }
    if (!exists(packageJson)) {
        feishuSidecarAddMissingIfAbsent(missing, "package_json")
    }
    if (!exists(packageLock)) {
        invalid.add("package_lock")
    }
    if (!exists(nodeModules)) {
        feishuSidecarAddMissingIfAbsent(missing, "node_modules")
    }
    if (!exists(sdkPackage)) {
        feishuSidecarAddMissingIfAbsent(missing, "@larksuiteoapi/node-sdk")
    }
    if (!exists(proxyPackage)) {
        feishuSidecarAddMissingIfAbsent(missing, "https-proxy-agent")
    }

    let node = commandProbe("node", ["--version"])
    if (!node.ok) {
        feishuSidecarAddMissingIfAbsent(missing, "node")
        if (!node.error.isEmpty()) {
            commandErrors.add("node=${node.error}")
        }
    }
    let npm = commandProbe("npm", ["--version"])
    if (!npm.ok) {
        feishuSidecarAddMissingIfAbsent(missing, "npm")
        if (!npm.error.isEmpty()) {
            commandErrors.add("npm=${npm.error}")
        }
    }

    let missingArray = missing.toArray()
    let invalidArray = invalid.toArray()
    let status = if (!invalidArray.isEmpty() && missingArray.isEmpty()) {
        "invalid"
    } else if (!missingArray.isEmpty()) {
        "missing"
    } else {
        "ready"
    }
    let ready = status == "ready"
    FeishuSidecarDependencyHealth(
        ready,
        status,
        projectRoot.toString(),
        runtimeRoot.toString(),
        scriptPath.toString(),
        FEISHU_SIDECAR_INSTALL_HINT,
        feishuSidecarHealthDetails(missingArray, invalidArray, commandErrors.toArray()),
        missingArray,
        invalidArray,
        node.version,
        npm.version
    )
}
