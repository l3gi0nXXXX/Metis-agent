package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.logging.{gatewayLoggingCaptureConsoleForTest, gatewayLoggingCapturedConsoleForTest, gatewayLoggingResetForTest}
import metis.process.managedStdioBroker
import metis.utils.{ShellTimeoutException, ShellUtils}
import std.collection.ArrayList
import std.core.Duration
import std.env.{getVariable, removeVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.time.MonoTime
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue

private class GatewayHeapPolicyProbeResult {
    let exitCode: Int64
    let stdout: String
    let stderr: String
    let log: String
    let elapsedMs: Int64
    let brokerRunning: Bool
    let brokerResponsive: Bool
    let brokerGeneration: Int64
    let brokerPid: Int64
    let brokerOwnerCount: Int64
    let brokerReaderCount: Int64
    let brokerDispatcherCount: Int64

    init(exitCode: Int64, stdout: String, stderr: String, log: String, elapsedMs: Int64,
         brokerRunning: Bool, brokerResponsive: Bool, brokerGeneration: Int64, brokerPid: Int64,
         brokerOwnerCount: Int64, brokerReaderCount: Int64, brokerDispatcherCount: Int64) {
        this.exitCode = exitCode
        this.stdout = stdout
        this.stderr = stderr
        this.log = log
        this.elapsedMs = elapsedMs
        this.brokerRunning = brokerRunning
        this.brokerResponsive = brokerResponsive
        this.brokerGeneration = brokerGeneration
        this.brokerPid = brokerPid
        this.brokerOwnerCount = brokerOwnerCount
        this.brokerReaderCount = brokerReaderCount
        this.brokerDispatcherCount = brokerDispatcherCount
    }
}

private class GatewayHeapPolicyStartupTruth {
    var maxHeapBytes: Int64 = -1
    var warningCount: Int64 = 0
    var invalidCount: Int64 = 0
    var invalidReason: String = ""
    var invalidActualMaxHeapBytes: Int64 = -1
    var malformedOrNonJsonCount: Int64 = 0
}

private func gatewayHeapPolicyRunProbe(heapValue: Option<String>, secretMarker!: String = "",
                                       consoleLevel!: String = "error"): GatewayHeapPolicyProbeResult {
    let project = gatewayCjpmProjectDirForExternalServe()
    let home = Directory.createTemp(Path("/tmp"))
    let logPath = home.join("heap-policy.log")
    try {
        File.writeTo(home.join("metis.json"), "{\"gateway\":{\"enabled\":false}}\n".toArray())
        let args = ArrayList<String>()
        match (heapValue) {
            case Some(value) => args.add("cjHeapSize=${value}")
            case None =>
                args.add("-u")
                args.add("cjHeapSize")
        }
        args.add("METIS_HOME=${home.toString()}")
        args.add("METIS_LOG_FILE=${logPath.toString()}")
        args.add("METIS_LOG_LEVEL=info")
        args.add("METIS_CONSOLE_LEVEL=${consoleLevel}")
        args.add("METIS_CONSOLE_STYLE=compact")
        if (!secretMarker.isEmpty()) { args.add("METIS_S1_PRIVATE_SENTINEL=${secretMarker}") }
        args.add("cjpm")
        args.add("run")
        args.add("--skip-script")
        args.add("--skip-build")
        args.add("--name")
        args.add("metis")
        args.add("--run-args")
        args.add("gateway serve")
        let command = ArrayList<String>()
        command.add("/usr/bin/env")
        for (arg in args) { command.add(arg) }
        let startedAt = MonoTime.now()
        let (exitCode, stdout, stderr) = try {
            ShellUtils.execute(
                command.toArray(),
                timeout: Some(Duration.second * 20),
                withWrap: false,
                workDir: project
            )
        } catch (_: ShellTimeoutException) {
            (124, "", "probe_timeout")
        }
        let elapsedMs = (MonoTime.now() - startedAt).toMilliseconds()
        let log = if (exists(logPath)) {
            try { String.fromUtf8(File.readFrom(logPath)) } catch (_: Exception) { "invalid_response_encoding" }
        } else {
            ""
        }
        let broker = managedStdioBroker().snapshot()
        GatewayHeapPolicyProbeResult(
            exitCode,
            stdout,
            stderr,
            log,
            elapsedMs,
            broker.running,
            broker.responsive,
            broker.generation,
            broker.brokerPid,
            broker.ownerCount,
            broker.readerCount,
            broker.dispatcherCount
        )
    } finally {
        try { remove(home, recursive: true) } catch (_: Exception) { () }
    }
}

private func gatewayHeapPolicyStartupTruth(log: String): GatewayHeapPolicyStartupTruth {
    let truth = GatewayHeapPolicyStartupTruth()
    for (line in log.split("\n")) {
        if (line.trimAscii().isEmpty()) { continue }
        try {
            let row = JsonValue.fromStr(line).asObject()
            let event = row.get("event").getOrThrow().asString().getValue()
            let scope = match (row.get("scope")) {
                case Some(value) => try { value.asString().getValue() } catch (_: Exception) { "" }
                case None => ""
            }
            let status = match (row.get("status")) {
                case Some(value) => try { value.asString().getValue() } catch (_: Exception) { "" }
                case None => ""
            }
            if (event == "process.memory" && scope == "serve:startup_begin") {
                let level = row.get("level").getOrThrow().asString().getValue()
                let subsystem = row.get("subsystem").getOrThrow().asString().getValue()
                let message = row.get("message").getOrThrow().asString().getValue()
                let managedHeapStatus = row.get("managedHeapStatus").getOrThrow().asString().getValue()
                if (level != "info" || subsystem != "gateway/runtime" ||
                    message != "gateway process memory snapshot" || managedHeapStatus != "ok") {
                    throw Exception("invalid startup heap log")
                }
                truth.maxHeapBytes = row.get("maxHeapBytes").getOrThrow().asInt().getValue()
            }
            if (event == "process.memory" && status == "runtime_heap_below_recommended") {
                let level = row.get("level").getOrThrow().asString().getValue()
                let subsystem = row.get("subsystem").getOrThrow().asString().getValue()
                let message = row.get("message").getOrThrow().asString().getValue()
                let maxHeapBytes = row.get("maxHeapBytes").getOrThrow().asInt().getValue()
                let recommended = row.get("recommendedMinHeapBytes").getOrThrow().asInt().getValue()
                if (level != "warn" || subsystem != "gateway/runtime" ||
                    message != "gateway runtime heap is below the recommended minimum" || maxHeapBytes < 0 ||
                    recommended != 1073741824) {
                    throw Exception("invalid low heap warning log")
                }
                truth.warningCount += 1
            }
            if (event == "process.memory" && status == "runtime_heap_configuration_invalid") {
                let level = row.get("level").getOrThrow().asString().getValue()
                let subsystem = row.get("subsystem").getOrThrow().asString().getValue()
                let message = row.get("message").getOrThrow().asString().getValue()
                let reason = row.get("reason").getOrThrow().asString().getValue()
                let actualMaxHeapBytes = row.get("actualMaxHeapBytes").getOrThrow().asInt().getValue()
                if (level != "error" || subsystem != "gateway/runtime" ||
                    message != "gateway runtime heap configuration is invalid" || actualMaxHeapBytes <= 0 ||
                    (reason != "invalid_syntax" && reason != "overflow" &&
                     reason != "below_runtime_minimum" && reason != "effective_mismatch" &&
                     reason != "unsupported_platform")) {
                    throw Exception("invalid heap policy diagnostic")
                }
                truth.invalidCount += 1
                truth.invalidReason = reason
                truth.invalidActualMaxHeapBytes = actualMaxHeapBytes
            }
        } catch (_: Exception) {
            truth.malformedOrNonJsonCount += 1
        }
    }
    truth
}

private func gatewayHeapPolicyExpectProbeSettled(probe: GatewayHeapPolicyProbeResult): Unit {
    // ShellUtils allows 20s to the command, 3s to collect its terminal event,
    // and bounded broker start/owner cleanup and recovery phases. The 40s gate
    // includes those documented 35s budgets plus scheduler overhead.
    @Expect(probe.elapsedMs >= 0 && probe.elapsedMs < 40000, true)
    @Expect(probe.brokerRunning, true)
    @Expect(probe.brokerResponsive, true)
    @Expect(probe.brokerGeneration > 0, true)
    @Expect(probe.brokerPid > 1, true)
    @Expect(probe.brokerOwnerCount, 0)
    @Expect(probe.brokerReaderCount, 1)
    @Expect(probe.brokerDispatcherCount, 0)
}

private func gatewayHeapPolicyLineCount(text: String, expected: String): Int64 {
    var count: Int64 = 0
    for (line in text.split("\n")) {
        if (line.trimAscii() == expected) { count += 1 }
    }
    count
}

private func gatewayHeapPolicyRead(path: Path): String {
    try {
        String.fromUtf8(File.readFrom(path))
    } catch (_: Exception) {
        "invalid_response_encoding"
    }
}

@Test
public class GatewayHeapPolicyTest {
    @TestCase
    public func oomS1U2HeapParserAcceptsOnlyDocumentedRuneSafeUnits(): Unit {
        let unset = gatewayValidateRuntimeHeapPolicy(None<String>, 2147483648, "macos")
        @Expect(unset.ok, true)
        @Expect(unset.configured, false)
        @Expect(unset.status, "unset")

        let minimum = gatewayValidateRuntimeHeapPolicy(Some("4096KB"), 4194304, "linux")
        @Expect(minimum.ok, true)
        @Expect(minimum.expectedBytes, 4194304)
        @Expect(gatewayValidateRuntimeHeapPolicy(Some("512mb"), 536870912, "macos").ok, true)
        @Expect(gatewayValidateRuntimeHeapPolicy(Some("1GB"), 1073741824, "linux").ok, true)

        let syntaxCases = ["", "1", "+1GB", "1.5GB", " 1GB", "1GB ", "中文🙂GB"]
        for (value in syntaxCases) {
            let parsed = gatewayValidateRuntimeHeapPolicy(Some(value), 1073741824, "macos")
            @Expect(parsed.ok, false)
            @Expect(parsed.status, "invalid_syntax")
        }
        let tooSmall = gatewayValidateRuntimeHeapPolicy(Some("3MB"), 3145728, "macos")
        @Expect(tooSmall.ok, false)
        @Expect(tooSmall.status, "below_runtime_minimum")
        let overflow = gatewayValidateRuntimeHeapPolicy(Some("9223372036854775807GB"), 1073741824, "macos")
        @Expect(overflow.ok, false)
        @Expect(overflow.status, "overflow")
        let unsupported = gatewayValidateRuntimeHeapPolicy(None<String>, 1073741824, "ohos")
        @Expect(unsupported.ok, false)
        @Expect(unsupported.status, "unsupported_platform")
    }

    @TestCase
    public func oomS1B2ExplicitHeapMustMatchTheEffectiveRuntimeHeap(): Unit {
        let exact = gatewayValidateRuntimeHeapPolicy(Some("1GB"), 1073741824, "macos")
        @Expect(exact.ok, true)
        @Expect(exact.status, "ok")
        let fallback = gatewayValidateRuntimeHeapPolicy(Some("1GB"), 268435456, "macos")
        @Expect(fallback.ok, false)
        @Expect(fallback.configured, true)
        @Expect(fallback.expectedBytes, 1073741824)
        @Expect(fallback.status, "effective_mismatch")
    }

    @TestCase
    public func oomS1U1UnsetHeapUsesTwoGiBRunProfile(): Unit {
        let probe = gatewayHeapPolicyRunProbe(None<String>)
        gatewayHeapPolicyExpectProbeSettled(probe)
        let truth = gatewayHeapPolicyStartupTruth(probe.log)
        @Expect(probe.exitCode, 0)
        @Expect(truth.malformedOrNonJsonCount, 0)
        @Expect(truth.maxHeapBytes, 2147483648)
        @Expect(truth.warningCount, 0)
        @Expect(truth.invalidCount, 0)
    }

    @TestCase
    public func oomS1B1ExplicitHeapIsPreservedAndLowHeapWarnsOnce(): Unit {
        let explicit = gatewayHeapPolicyRunProbe(Some("1GB"))
        gatewayHeapPolicyExpectProbeSettled(explicit)
        let explicitTruth = gatewayHeapPolicyStartupTruth(explicit.log)
        @Expect(explicit.exitCode, 0)
        @Expect(explicitTruth.malformedOrNonJsonCount, 0)
        @Expect(explicitTruth.maxHeapBytes, 1073741824)
        @Expect(explicitTruth.warningCount, 0)
        @Expect(explicitTruth.invalidCount, 0)

        let lowSentinel = "s1-low-heap-private-sentinel"
        let low = gatewayHeapPolicyRunProbe(Some("512MB"), secretMarker: lowSentinel, consoleLevel: "warn")
        gatewayHeapPolicyExpectProbeSettled(low)
        let lowTruth = gatewayHeapPolicyStartupTruth(low.log)
        @Expect(low.exitCode, 0)
        @Expect(lowTruth.malformedOrNonJsonCount, 0)
        @Expect(lowTruth.maxHeapBytes, 536870912)
        @Expect(lowTruth.warningCount, 1)
        @Expect(lowTruth.invalidCount, 0)
        @Expect(low.stdout.contains("runtime_heap_below_recommended"), false)
        @Expect(low.stdout.contains("gateway runtime heap is below the recommended minimum"), false)
        let expectedWarning =
            "[gateway/runtime] warn process.memory gateway runtime heap is below the recommended minimum " +
                "status=\"runtime_heap_below_recommended\" maxHeapBytes=536870912 recommendedMinHeapBytes=1073741824"
        @Expect(gatewayHeapPolicyLineCount(low.stdout, expectedWarning), 0)
        @Expect(gatewayHeapPolicyLineCount(low.stderr, expectedWarning), 1)
        @Expect(low.stdout.contains(lowSentinel), false)
        @Expect(low.stderr.contains(lowSentinel), false)
        @Expect(low.log.contains(lowSentinel), false)
    }

    @TestCase
    public func oomS1P1DedicatedLauncherUsesTheUnifiedCjpmRunProfile(): Unit {
        let project = gatewayCjpmProjectDirForExternalServe()
        let launcher = gatewayHeapPolicyRead(project.join("src/gateway/runtime/gateway_external_console.cj"))
        let service = gatewayHeapPolicyRead(project.join("src/gateway/runtime/demo.cj"))
        let gatewayCli = gatewayHeapPolicyRead(project.join("src/gateway/runtime/gateway_cli.cj"))
        let programRunner = gatewayHeapPolicyRead(project.join("src/program_runner.cj"))
        let config = gatewayHeapPolicyRead(project.join("cjpm.toml"))
        @Expect(launcher.contains("cjpm run --name metis"), true)
        @Expect(launcher.contains("rtk cjpm run --skip-script --skip-build --name metis"), true)
        @Expect(launcher.contains("cjHeapSize"), false)
        @Expect(config.contains("[profile.run.env]"), true)
        @Expect(config.contains("cjHeapSize = { value = \"2GB\", splice-type = \"absent\" }"), true)
        @Expect(config.contains("[profile.test.env]\n  cjHeapSize = { value = \"64MB\", splice-type = \"replace\" }"), true)
        @Expect(service.contains("public func runGatewayService(verbose!: Bool = false): Int64"), true)
        @Expect(service.contains("public func runFeishuWebhookGatewayService(): Int64"), true)
        @Expect(gatewayCli.contains("let exitCode = runGatewayService(verbose: verbose)"), true)
        @Expect(gatewayCli.contains("gatewayCliTimingLog(flowName, \"exit\", startMs)\n    exitCode"), true)
        @Expect(programRunner.contains("return Some(runFeishuWebhookGatewayService())"), true)
    }

    @TestCase
    public func oomS1N2InvalidAndUnsupportedHeapPoliciesFailClosed(): Unit {
        let invalid = gatewayValidateRuntimeHeapPolicy(Some("not-a-size"), 268435456, "macos")
        @Expect(invalid.ok, false)
        @Expect(invalid.status, "invalid_syntax")
        let mismatch = gatewayValidateRuntimeHeapPolicy(Some("2GB"), 268435456, "linux")
        @Expect(mismatch.ok, false)
        @Expect(mismatch.status, "effective_mismatch")
        let unsupported = gatewayValidateRuntimeHeapPolicy(Some("2GB"), 2147483648, "windows")
        @Expect(unsupported.ok, false)
        @Expect(unsupported.status, "unsupported_platform")
    }

    @TestCase
    public func oomS1N1InvalidHeapFailsBeforeGatewayStartupWithoutEnvironmentLeak(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let oldHeap = getVariable("cjHeapSize")
            let oldHome = getVariable("METIS_HOME")
            let oldLogFile = getVariable("METIS_LOG_FILE")
            let oldLogLevel = getVariable("METIS_LOG_LEVEL")
            let oldConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
            let oldConsoleStyle = getVariable("METIS_CONSOLE_STYLE")
            let oldSentinel = getVariable("METIS_S1_PRIVATE_SENTINEL")
            let home = Directory.createTemp(Path("/tmp"))
            let logPath = home.join("heap-policy.log")
            let invalidRaw = "invalid-s1-heap"
            let sentinel = "s1-private-sentinel-must-not-leak"
            try {
                setVariable("cjHeapSize", invalidRaw)
                setVariable("METIS_HOME", home.toString())
                setVariable("METIS_LOG_FILE", logPath.toString())
                setVariable("METIS_LOG_LEVEL", "info")
                setVariable("METIS_CONSOLE_LEVEL", "error")
                setVariable("METIS_CONSOLE_STYLE", "compact")
                setVariable("METIS_S1_PRIVATE_SENTINEL", sentinel)
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                gatewayLoggingResetForTest()
                gatewayLoggingCaptureConsoleForTest()

                let exitCode = runGatewayService()
                var capturedConsole = ""
                for (line in gatewayLoggingCapturedConsoleForTest()) {
                    capturedConsole += line + "\n"
                }
                let log = if (exists(logPath)) {
                    try { String.fromUtf8(File.readFrom(logPath)) }
                    catch (_: Exception) { "invalid_response_encoding" }
                } else {
                    ""
                }
                let truth = gatewayHeapPolicyStartupTruth(log)
                @Expect(exitCode, 1)
                @Expect(truth.malformedOrNonJsonCount, 0)
                @Expect(truth.invalidCount, 1)
                @Expect(truth.invalidReason, "invalid_syntax")
                @Expect(truth.invalidActualMaxHeapBytes > 0, true)
                @Expect(truth.maxHeapBytes, -1)
                @Expect(truth.warningCount, 0)
                @Expect(log.contains("serve:startup_begin"), false)
                let expectedDiagnostic =
                    "[gateway/runtime] error process.memory gateway runtime heap configuration is invalid " +
                        "status=\"runtime_heap_configuration_invalid\" reason=\"invalid_syntax\" " +
                        "actualMaxHeapBytes=${truth.invalidActualMaxHeapBytes}"
                @Expect(gatewayHeapPolicyLineCount(capturedConsole, expectedDiagnostic), 1)
                @Expect(log.contains(invalidRaw), false)
                @Expect(capturedConsole.contains(invalidRaw), false)
                @Expect(log.contains(sentinel), false)
                @Expect(capturedConsole.contains(sentinel), false)
                @Expect(log.contains("Exception"), false)
                @Expect(capturedConsole.contains("Exception"), false)
                @Expect(capturedConsole.contains("stack trace"), false)
                @Expect(exists(home.join("gateway-serve.lock")), false)
                @Expect(exists(home.join("gateway-serve.stop-request")), false)
                @Expect(exists(home.join("gateway-serve.stop-complete")), false)
            } finally {
                match (oldHeap) { case Some(value) => setVariable("cjHeapSize", value) case None => removeVariable("cjHeapSize") }
                match (oldHome) { case Some(value) => setVariable("METIS_HOME", value) case None => removeVariable("METIS_HOME") }
                match (oldLogFile) { case Some(value) => setVariable("METIS_LOG_FILE", value) case None => removeVariable("METIS_LOG_FILE") }
                match (oldLogLevel) { case Some(value) => setVariable("METIS_LOG_LEVEL", value) case None => removeVariable("METIS_LOG_LEVEL") }
                match (oldConsoleLevel) { case Some(value) => setVariable("METIS_CONSOLE_LEVEL", value) case None => removeVariable("METIS_CONSOLE_LEVEL") }
                match (oldConsoleStyle) { case Some(value) => setVariable("METIS_CONSOLE_STYLE", value) case None => removeVariable("METIS_CONSOLE_STYLE") }
                match (oldSentinel) { case Some(value) => setVariable("METIS_S1_PRIVATE_SENTINEL", value) case None => removeVariable("METIS_S1_PRIVATE_SENTINEL") }
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                gatewayLoggingResetForTest()
                try { remove(home, recursive: true) } catch (_: Exception) { () }
            }
        }
    }
}
