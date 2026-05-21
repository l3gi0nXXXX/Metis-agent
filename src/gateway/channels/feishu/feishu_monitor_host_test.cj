package metis.gateway.channels.feishu

import metis.core.config.{CliConfig, CliSettingManager}
import metis.gateway.logging.gatewayLoggingResetForTest
import metis.gateway.model.FeishuConfig
import metis.utils.ShellUtils
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.JsonObject

private func feishuMonitorHostTestRoot(label: String): Path {
    let root = Path("/tmp/metis-feishu-monitor-host-${label}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
    if (exists(root)) {
        remove(root, recursive: true)
    }
    Directory.create(root, recursive: true)
    root
}

private func writeFeishuMonitorHostFixtureFile(path: Path, content: String): Unit {
    if (!exists(path.parent)) {
        Directory.create(path.parent, recursive: true)
    }
    File.writeTo(path, content.toArray())
}

private func feishuMonitorHostFakeScript(): String {
    "#!/usr/bin/env node\n" +
    "import fs from 'node:fs';\n" +
    "import process from 'node:process';\n" +
    "const args = process.argv.slice(2);\n" +
    "const value = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] ?? '' : ''; };\n" +
    "const appId = value('--app-id');\n" +
    "const argvText = args.join(' ');\n" +
    "let buffer = '';\n" +
    "let initialized = false;\n" +
    "const write = (frame) => process.stdout.write(JSON.stringify(frame) + '\\n');\n" +
    "process.stdin.setEncoding('utf8');\n" +
    "process.stdin.on('data', (chunk) => {\n" +
    "  if (initialized && String(chunk).includes('\"stop\"')) process.exit(0);\n" +
    "  buffer += chunk;\n" +
    "  const index = buffer.indexOf('\\n');\n" +
    "  if (index < 0) return;\n" +
    "  const line = buffer.slice(0, index).trim();\n" +
    "  buffer = buffer.slice(index + 1);\n" +
    "  if (initialized) return;\n" +
    "  let init;\n" +
    "  try { init = JSON.parse(line); } catch (err) { write({ type: 'error', message: 'invalid-init: ' + String(err) }); process.exit(2); }\n" +
    "  if (init.type !== 'init' || !init.appSecret) { write({ type: 'error', message: 'missing-init' }); process.exit(2); }\n" +
    "  if (argvText.includes(init.appSecret) || argvText.includes(init.verificationToken || '') || argvText.includes(init.encryptKey || '')) {\n" +
    "    write({ type: 'error', message: 'secret-leaked-to-argv' }); process.exit(2);\n" +
    "  }\n" +
    "  initialized = true;\n" +
    "  if (appId.includes('error')) { write({ type: 'error', message: 'synthetic-start-error' }); process.exit(2); }\n" +
    "  if (appId.includes('hang')) {\n" +
    "    if (process.env.METIS_FEISHU_TEST_PID_FILE) { fs.writeFileSync(process.env.METIS_FEISHU_TEST_PID_FILE, String(process.pid)); }\n" +
    "    setInterval(() => {}, 1000);\n" +
    "    return;\n" +
    "  }\n" +
    "  write({ type: 'ready' });\n" +
    "});\n" +
    "setInterval(() => {}, 1000);\n"
}

private func restoreFeishuMonitorHostEnv(name: String, oldValue: Option<String>): Unit {
    match (oldValue) {
        case Some(value) => setVariable(name, value)
        case None => setVariable(name, "")
    }
}

private func withFeishuMonitorHostLogCapture<T>(label: String, block: (String) -> T): T {
    let oldHome = getVariable("METIS_HOME")
    let oldLogLevel = getVariable("METIS_LOG_LEVEL")
    let oldLogFile = getVariable("METIS_LOG_FILE")
    let oldConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
    let root = feishuMonitorHostTestRoot("logs-${label}")
    let logPath = root.join("logs").join("feishu-monitor-host.log")
    try {
        setVariable("METIS_HOME", root.toString())
        setVariable("METIS_LOG_LEVEL", "debug")
        setVariable("METIS_LOG_FILE", logPath.toString())
        setVariable("METIS_CONSOLE_LEVEL", "silent")
        CliConfig.invalidatePathCache()
        CliSettingManager.invalidate()
        gatewayLoggingResetForTest()
        return block(logPath.toString())
    } finally {
        restoreFeishuMonitorHostEnv("METIS_HOME", oldHome)
        restoreFeishuMonitorHostEnv("METIS_LOG_LEVEL", oldLogLevel)
        restoreFeishuMonitorHostEnv("METIS_LOG_FILE", oldLogFile)
        restoreFeishuMonitorHostEnv("METIS_CONSOLE_LEVEL", oldConsoleLevel)
        CliConfig.invalidatePathCache()
        CliSettingManager.invalidate()
        gatewayLoggingResetForTest()
        try { remove(root, recursive: true) } catch (_e: Exception) { () }
    }
}

private func readFeishuMonitorHostLog(path: String): String {
    if (!exists(Path(path))) {
        return ""
    }
    String.fromUtf8(File.readFrom(Path(path)))
}

private func feishuMonitorHostLogFieldContains(raw: String, key: String, value: String): Bool {
    raw.contains("\"${key}\":\"${value}\"") || raw.contains("\"${key}\": \"${value}\"")
}

private func feishuMonitorHostLogContains(raw: String, phase: String, status: String): Bool {
    for (entry in raw.split("{")) {
        if (feishuMonitorHostLogFieldContains(entry, "phase", phase) &&
            feishuMonitorHostLogFieldContains(entry, "status", status)) {
            return true
        }
    }
    false
}

private func expectFeishuMonitorHostLogHas(raw: String, phase: String, status: String): Unit {
    @Expect(feishuMonitorHostLogContains(raw, phase, status), true)
}

private func expectFeishuMonitorHostLogSecretsRedacted(raw: String): Unit {
    @Expect(raw.contains("sidecar-secret-never-in-argv"), false)
    @Expect(raw.contains("verification-token-never-in-argv"), false)
    @Expect(raw.contains("encrypt-key-never-in-argv"), false)
}

private func createFeishuMonitorHostFixture(label: String): (Path, Path) {
    let root = feishuMonitorHostTestRoot(label)
    let script = root.join("scripts").join("feishu-ws-sidecar.mjs")
    let depsRoot = root.join("tools").join("feishu-official-sdk")
    writeFeishuMonitorHostFixtureFile(script, feishuMonitorHostFakeScript())
    writeFeishuMonitorHostFixtureFile(depsRoot.join("package.json"), "{\"type\":\"module\"}\n")
    writeFeishuMonitorHostFixtureFile(
        depsRoot.join("node_modules").join("@larksuiteoapi").join("node-sdk").join("package.json"),
        "{\"name\":\"@larksuiteoapi/node-sdk\"}\n"
    )
    (script, depsRoot)
}

private func feishuMonitorHostTestConfig(appId: String): FeishuConfig {
    FeishuConfig(
        enabled: true,
        appId: appId,
        appSecret: "sidecar-secret-never-in-argv",
        receiveMode: "long_connect",
        verificationToken: "verification-token-never-in-argv",
        encryptKey: "encrypt-key-never-in-argv"
    )
}

private func feishuMonitorHostProcessAlive(pidFile: Path): Bool {
    let quotedPath = feishuMonitorHostShellSingleQuote(pidFile.toString())
    let command = "if test -s ${quotedPath} && kill -0 $(cat ${quotedPath}) 2>/dev/null; then echo alive; fi"
    let (_, stdOut, _) = ShellUtils.execute(["sh", "-c", command], withWrap: false)
    stdOut.trimAscii() == "alive"
}

private class FeishuMonitorHostFailingNativeTransport <: FeishuLongConnectTransport {
    public func start(spec: FeishuLongConnectStartSpec, eventHandler: (JsonObject) -> Unit): FeishuLongConnectStartResult {
        FeishuLongConnectStartResult(ok: false, status: "failed", error: "synthetic-native-start-error")
    }

    public func stop(): Unit {}
}

@Test
public class FeishuMonitorHostTest {
    @TestCase
    public func ingressHintUsesNativeLongConnectWording(): Unit {
        let text = feishuMonitorHostIngressHintText()
        @Expect(text.contains("native long-connect transport"), true)
        @Expect(text.contains("official WebSocket"), false)
    }

    @TestCase
    public func stopFrameUsesJsonLineProtocol(): Unit {
        @Expect(feishuMonitorHostStopFrame(), "{\"type\":\"stop\"}\n")
    }

    @TestCase
    public func initFrameJsonEscapingKeepsSecretsParseable(): Unit {
        @Expect(feishuMonitorHostJsonEscape("a\"b\\c\n"), "a\\\"b\\\\c\\n")
    }

    @TestCase
    public func stopWaitWindowsStayShortAndBounded(): Unit {
        @Expect(feishuMonitorHostGraceStopWaitMs(), 400)
        @Expect(feishuMonitorHostForcedStopWaitMs(), 600)
    }

    @TestCase
    public func shellQuoteAndPsLookupStayScopedToScriptAndAppId(): Unit {
        @Expect(feishuMonitorHostShellSingleQuote("a'b"), "'a'\"'\"'b'")
        let command = feishuMonitorHostPsLookupCommand(
            "/tmp/scripts/feishu-ws-sidecar.mjs",
            "cli_test_app"
        )
        @Expect(command.contains("ps -axo pid=,ppid=,command="), true)
        @Expect(command.contains("grep -F --"), true)
        @Expect(command.contains("feishu-ws-sidecar.mjs"), true)
        @Expect(command.contains("--app-id cli_test_app"), true)
    }

    @TestCase
    public func parseMonitorHostPidsReadsLeadingPidColumn(): Unit {
        let raw = "12581     12550 node /tmp/feishu-ws-sidecar.mjs --app-id cli_a\n95093         1 node /tmp/feishu-ws-sidecar.mjs --app-id cli_a\n"
        let pids = feishuParseMonitorHostPids(raw)
        @Expect(pids.size, 2)
        @Expect(pids[0], 12581)
        @Expect(pids[1], 95093)
    }

    @TestCase
    public func parseMonitorHostPidsIgnoresEmptyAndNonNumericSegments(): Unit {
        let raw = "\n  \ninvalid token\n12581 extra\n"
        let pids = feishuParseMonitorHostPids(raw)
        @Expect(pids.size, 1)
        @Expect(pids[0], 12581)
    }

    @TestCase
    public func longConnectStartUsesNativeTransportEvenWhenMonitorHostFixtureExists(): Unit {
        let (script, depsRoot) = createFeishuMonitorHostFixture("ready")
        try {
            let adapter = FeishuAdapter(
                config: feishuMonitorHostTestConfig("metis-sidecar-ready"),
                monitorHostScriptForTest: script.toString(),
                monitorHostDepsRootForTest: depsRoot.toString(),
                monitorHostStartupTimeoutMsForTest: 800
            )
            adapter.start()
            @Expect(adapter.debugIsRunningForTest(), true)
            @Expect(adapter.debugFeishuMonitorProcessPresentForTest(), false)
            @Expect(adapter.debugFeishuMonitorLastErrorForTest(), "")
            @Expect(adapter.debugFeishuNativeLongConnectLastErrorForTest(), "")
            adapter.stop()
        } finally {
            try { remove(script.parent.parent, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func missingLongConnectCredentialsDoNotLaunchMonitorHostOrBlockOfflineQueue(): Unit {
        let adapter = FeishuAdapter(config: FeishuConfig(enabled: true, receiveMode: "long_connect"))
        adapter.start()
        @Expect(adapter.debugIsRunningForTest(), true)
        @Expect(adapter.debugFeishuMonitorProcessPresentForTest(), false)
        adapter.simulateIncomingText("om_offline", "oc_offline", "ou_sender", "hello")
        @Expect(adapter.pullInbound().size, 1)
        adapter.stop()
    }

    @TestCase
    public func longConnectNativeStartErrorLeavesAdapterNotRunning(): Unit {
        let adapter = FeishuAdapter(
            config: feishuMonitorHostTestConfig("metis-native-error"),
            longConnectTransport: FeishuMonitorHostFailingNativeTransport()
        )
        adapter.start()
        @Expect(adapter.debugIsRunningForTest(), false)
        @Expect(adapter.debugFeishuMonitorProcessPresentForTest(), false)
        @Expect(adapter.debugFeishuNativeLongConnectLastErrorForTest().contains("synthetic-native-start-error"), true)
    }

    @TestCase
    public func longConnectDoesNotStartLegacySidecarWhenFixtureWouldHang(): Unit {
        let (script, depsRoot) = createFeishuMonitorHostFixture("hang")
        let pidFile = script.parent.parent.join("hang.pid")
        let oldPidFile = getVariable("METIS_FEISHU_TEST_PID_FILE")
        setVariable("METIS_FEISHU_TEST_PID_FILE", pidFile.toString())
        try {
            let adapter = FeishuAdapter(
                config: feishuMonitorHostTestConfig("metis-sidecar-hang"),
                monitorHostScriptForTest: script.toString(),
                monitorHostDepsRootForTest: depsRoot.toString(),
                monitorHostStartupTimeoutMsForTest: 150
            )
            adapter.start()
            @Expect(adapter.debugIsRunningForTest(), true)
            @Expect(adapter.debugFeishuMonitorProcessPresentForTest(), false)
            @Expect(feishuMonitorHostProcessAlive(pidFile), false)
            adapter.stop()
        } finally {
            restoreFeishuMonitorHostEnv("METIS_FEISHU_TEST_PID_FILE", oldPidFile)
            try { remove(script.parent.parent, recursive: true) } catch (_e: Exception) { () }
        }
    }
}
