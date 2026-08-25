package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, GatewayServicePluginUserSettings, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.process.gatewayStdioBrokerSnapshot
import metis.gateway.service_plugin.loadServicePluginManifest
import metis.gateway.core.GatewayStopResult
import metis.process.{currentProcessInstanceIdentity, managedStdioResolveBrokerScriptPath, probeProcessInstance, processInstanceKillSignal, processInstanceTermSignal, resetManagedStdioBrokerForTest, signalProcessInstance}
import std.collection.ArrayList
import std.convert.Parsable
import std.core.Duration
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.net.*
import std.process.{ProcessRedirect, SubProcess, executeWithOutput, launch}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue
import stdx.net.http.*

private func gatewayServeStopTemporaryPort(): Int64 {
    for (_ in 0..8) {
        try (socket = TcpServerSocket(bindAt: 0u16)) {
            socket.bind()
            let port = (socket.localAddress as IPSocketAddress)?.port ?? 0u16
            let value = Int64(port)
            if (value > 0 && value != 18080 && value != 18788 && value != 60271) { return value }
        }
    }
    0
}

private func gatewayServeStopWaitUntil(timeoutMs: Int64, predicate: () -> Bool): Bool {
    let started = MonoTime.now()
    while ((MonoTime.now() - started).toMilliseconds() < timeoutMs) {
        if (predicate()) { return true }
        sleep(Duration.millisecond * 20)
    }
    predicate()
}

private func gatewayServeStopPidAlive(pid: Int64): Bool {
    if (pid <= 0) { return false }
    executeWithOutput("/bin/kill", ["-0", "${pid}"])[0] == 0
}

private func gatewayServeStopPortListening(port: Int64): Bool {
    executeWithOutput("/usr/sbin/lsof", ["-nP", "-iTCP:${port}", "-sTCP:LISTEN", "-t"])[0] == 0
}

private func gatewayServeStopReadLines(path: Path): Array<String> {
    try { String.fromUtf8(File.readFrom(path)).split("\n") } catch (_: Exception) { [] }
}

private func gatewayServeStopCompletionField(text: String, key: String): String {
    for (line in text.split("\n")) {
        let parts = line.trimAscii().split(":")
        if (parts.size >= 2 && parts[0].trimAscii() == key) {
            let value = ArrayList<String>()
            for (index in 1..parts.size) { value.add(parts[index]) }
            return String.join(value.toArray(), delimiter: ":").trimAscii()
        }
    }
    ""
}

private func gatewayServeStopProcessGroup(pid: Int64): Int64 {
    let result = executeWithOutput("/bin/ps", ["-o", "pgid=", "-p", "${pid}"])
    if (result[0] != 0) { return 0 }
    try { Int64.parse(String.fromUtf8(result[1]).trimAscii()) } catch (_: Exception) { 0 }
}

private func gatewayServeStopChildPid(parentPid: Int64, commandNeedle: String): Int64 {
    let result = executeWithOutput("/usr/bin/pgrep", ["-P", "${parentPid}", "-f", commandNeedle])
    if (result[0] != 0) { return 0 }
    let rows: Array<String> = try { String.fromUtf8(result[1]).trimAscii().split("\n") } catch (_: Exception) { [] }
    if (rows.isEmpty()) { return 0 }
    try { Int64.parse(rows[0].trimAscii()) } catch (_: Exception) { 0 }
}

private func gatewayServeStopParentPid(pid: Int64): Int64 {
    let result = executeWithOutput("/bin/ps", ["-o", "ppid=", "-p", "${pid}"])
    if (result[0] != 0) { return 0 }
    try { Int64.parse(String.fromUtf8(result[1]).trimAscii()) } catch (_: Exception) { 0 }
}

private func gatewayServeStopCommandContains(pid: Int64, expected: String): Bool {
    if (pid <= 1 || expected.isEmpty()) { return false }
    let command = executeWithOutput("/bin/ps", ["-o", "command=", "-p", "${pid}"])
    if (command[0] != 0) { return false }
    let commandText = try { String.fromUtf8(command[1]).trimAscii() } catch (_: Exception) { return false }
    commandText.contains(expected)
}

private func gatewayServeStopHomeOwnsIdentity(home: Path, identity: GatewayServeIdentity): Bool {
    for (name in ["gateway-serve.lock", "gateway-serve.stop-complete"]) {
        let path = home.join(name)
        if (!exists(path)) { continue }
        let matches = try {
            match (gatewayParseServeIdentity(String.fromUtf8(File.readFrom(path)))) {
                case Some(found) => found.matches(identity)
                case None => false
            }
        } catch (_: Exception) {
            false
        }
        if (matches) { return true }
    }
    false
}

private func gatewayServeStopCaptureOwnedIdentity(
    home: Path,
    pid: Int64,
    expectedBinary: Path,
    timeoutMs: Int64
): Option<GatewayServeIdentity> {
    let started = MonoTime.now()
    while ((MonoTime.now() - started).toMilliseconds() < timeoutMs) {
        if (!gatewayServeStopCommandContains(pid, expectedBinary.toString()) ||
            !gatewayServeStopCommandContains(pid, "gateway run")) { return None<GatewayServeIdentity> }
        let path = home.join("gateway-serve.lock")
        if (exists(path)) {
            let parsed = try {
                gatewayParseServeIdentity(String.fromUtf8(File.readFrom(path)))
            } catch (_: Exception) {
                None<GatewayServeIdentity>
            }
            match (parsed) {
                case Some(value) =>
                    if (value.pid == pid && value.processIdentity.isSome()) { return Some(value) }
                case None => ()
            }
        }
        sleep(Duration.millisecond * 20)
    }
    None<GatewayServeIdentity>
}

private class GatewayServeStopResourceCapture {
    var brokerStarted: Bool = false
    var brokerCaptured: Bool = false
    var brokerPid: Int64 = 0
    var fixtureStarted: Bool = false
    var fixtureCaptured: Bool = false
    var rootPid: Int64 = 0
    var childPid: Int64 = 0
    var pgid: Int64 = 0

    func brokerTerminalStatus(): String {
        if (!this.brokerStarted || !this.brokerCaptured || this.brokerPid <= 1) { return "unknown" }
        if (gatewayServeStopPidAlive(this.brokerPid)) { "alive" } else { "gone" }
    }

    func fixtureTerminalStatus(): String {
        if (!this.fixtureStarted || !this.fixtureCaptured || this.pgid <= 1) { return "unknown" }
        if (gatewayServeStopGroupGone(this.pgid)) { "gone" } else { "alive" }
    }
}

private func gatewayServeStopMatchingPids(commandNeedle: String): Array<Int64> {
    let result = executeWithOutput("/usr/bin/pgrep", ["-f", commandNeedle])
    if (result[0] != 0) { return [] }
    let rows: Array<String> = try {
        String.fromUtf8(result[1]).trimAscii().split("\n")
    } catch (_: Exception) {
        return []
    }
    let pids = ArrayList<Int64>()
    for (row in rows) {
        let pid = try { Int64.parse(row.trimAscii()) } catch (_: Exception) { 0 }
        if (pid > 1 && gatewayServeStopCommandContains(pid, commandNeedle)) { pids.add(pid) }
    }
    pids.toArray()
}

private func gatewayServeStopCaptureResources(
    gatewayPid: Int64,
    brokerScript: Path,
    fixturePath: Path,
    readyPath: Path,
    timeoutMs: Int64
): GatewayServeStopResourceCapture {
    let captured = GatewayServeStopResourceCapture()
    let started = MonoTime.now()
    while ((MonoTime.now() - started).toMilliseconds() < timeoutMs) {
        if (!captured.brokerCaptured) {
            let brokerPid = gatewayServeStopChildPid(gatewayPid, "metis-stdio-broker.mjs")
            if (brokerPid > 1) {
                captured.brokerStarted = true
                if (gatewayServeStopCommandContains(brokerPid, brokerScript.toString()) &&
                    gatewayServeStopParentPid(brokerPid) == gatewayPid) {
                    captured.brokerCaptured = true
                    captured.brokerPid = brokerPid
                }
            }
        }
        if (!captured.fixtureCaptured) {
            let fixturePids = gatewayServeStopMatchingPids(fixturePath.toString())
            if (!fixturePids.isEmpty()) { captured.fixtureStarted = true }
            var rootPid: Int64 = 0
            var childPid: Int64 = 0
            var pgid: Int64 = 0
            var ownedResources = GatewayServeStopResourceCapture()
            let readyRows: Array<String> = if (exists(readyPath)) { gatewayServeStopReadLines(readyPath) } else { [] }
            if (readyRows.size >= 3) {
                rootPid = try { Int64.parse(readyRows[0].trimAscii()) } catch (_: Exception) { 0 }
                childPid = try { Int64.parse(readyRows[1].trimAscii()) } catch (_: Exception) { 0 }
                pgid = try { Int64.parse(readyRows[2].trimAscii()) } catch (_: Exception) { 0 }
            } else if (captured.brokerCaptured) {
                for (pid in fixturePids) {
                    if (gatewayServeStopParentPid(pid) == captured.brokerPid) {
                        rootPid = pid
                        pgid = gatewayServeStopProcessGroup(pid)
                        break
                    }
                }
                if (rootPid > 1 && pgid > 1) {
                    for (pid in fixturePids) {
                        if (pid != rootPid && gatewayServeStopProcessGroup(pid) == pgid) {
                            childPid = pid
                            break
                        }
                    }
                }
            }
            if (rootPid > 1 && childPid > 1 && pgid > 1 &&
                gatewayServeStopCommandContains(rootPid, fixturePath.toString()) &&
                gatewayServeStopCommandContains(childPid, fixturePath.toString()) &&
                gatewayServeStopProcessGroup(rootPid) == pgid && gatewayServeStopProcessGroup(childPid) == pgid) {
                captured.fixtureStarted = true
                captured.fixtureCaptured = true
                captured.rootPid = rootPid
                captured.childPid = childPid
                captured.pgid = pgid
            }
        }
        if (captured.brokerCaptured && captured.fixtureCaptured) { break }
        sleep(Duration.millisecond * 20)
    }
    captured
}

private func gatewayServeStopReapOwnedGateway(
    identity: Option<GatewayServeIdentity>,
    expectedBinary: Path,
    home: Path
): Unit {
    let captured = match (identity) {
        case Some(value) => value
        case None => return
    }
    let instance = match (captured.processIdentity) {
        case Some(value) => value
        case None => return
    }
    if (instance.pid != captured.pid || !gatewayServeStopHomeOwnsIdentity(home, captured) ||
        !gatewayServeStopCommandContains(captured.pid, expectedBinary.toString()) ||
        !gatewayServeStopCommandContains(captured.pid, "gateway run")) { return }
    let deadline = MonoTime.now() + Duration.second * 5
    let initial = probeProcessInstance(instance, deadline)
    if (!initial.conclusive || !initial.alive) { return }
    let _ = signalProcessInstance(instance, processInstanceTermSignal(), deadline)
    let termDeadline = deadline - Duration.second * 2
    while (MonoTime.now() < termDeadline) {
        let current = probeProcessInstance(instance, deadline)
        if (current.conclusive && !current.alive) { return }
        sleep(Duration.millisecond * 20)
    }
    let beforeKill = probeProcessInstance(instance, deadline)
    if (!beforeKill.conclusive || !beforeKill.alive) { return }
    let _ = signalProcessInstance(instance, processInstanceKillSignal(), deadline)
    let _ = gatewayServeStopWaitUntil(2000, { =>
        let current = probeProcessInstance(instance, deadline)
        current.conclusive && !current.alive
    })
}

private func gatewayServeStopReapOwnedHandle(
    process: Option<SubProcess>,
    expectedBinary: Path
): Unit {
    let owned = match (process) {
        case Some(value) => value
        case None => return
    }
    if (!owned.isAlive()) { return }
    if (!gatewayServeStopCommandContains(owned.pid, expectedBinary.toString()) ||
        !gatewayServeStopCommandContains(owned.pid, "gateway run")) { return }
    try { owned.terminate(force: false) } catch (_: Exception) { () }
    if (gatewayServeStopWaitUntil(1000, { => !owned.isAlive() })) { return }
    if (!gatewayServeStopCommandContains(owned.pid, expectedBinary.toString()) ||
        !gatewayServeStopCommandContains(owned.pid, "gateway run")) { return }
    try { owned.terminate(force: true) } catch (_: Exception) { () }
}

private func gatewayServeStopWaitOwnedProcess(process: Option<SubProcess>): Bool {
    match (process) {
        case Some(value) =>
            try {
                let _ = value.wait(timeout: Some(Duration.second * 2))
                true
            } catch (_: Exception) {
                false
            }
        case None => true
    }
}

private func gatewayServeStopReapCompletedOwnedProcess(process: Option<SubProcess>): Bool {
    match (process) {
        case Some(value) =>
            try {
                let _ = value.wait(timeout: Some(Duration.second * 2))
                true
            } catch (_: Exception) {
                false
            }
        case None => false
    }
}

private func gatewayServeStopReapOwnedFixtureGroup(
    pgid: Int64,
    rootPid: Int64,
    childPid: Int64,
    fixturePath: Path
): Unit {
    if (pgid <= 1 || rootPid <= 1 || childPid <= 1) { return }
    let listed = executeWithOutput("/usr/bin/pgrep", ["-g", "${pgid}"])
    if (listed[0] != 0) { return }
    let rows: Array<String> = try { String.fromUtf8(listed[1]).trimAscii().split("\n") } catch (_: Exception) { return }
    var rootSeen = false
    var childSeen = false
    for (row in rows) {
        let member = try { Int64.parse(row.trimAscii()) } catch (_: Exception) { return }
        if (member == rootPid) { rootSeen = true }
        if (member == childPid) { childSeen = true }
        if (gatewayServeStopProcessGroup(member) != pgid ||
            !gatewayServeStopCommandContains(member, fixturePath.toString())) { return }
    }
    if (!rootSeen && !childSeen) { return }
    let _ = executeWithOutput("/bin/kill", ["-KILL", "-${pgid}"])
    let _ = gatewayServeStopWaitUntil(3000, { => executeWithOutput("/usr/bin/pgrep", ["-g", "${pgid}"])[0] != 0 })
}

private func gatewayServeStopGroupGone(pgid: Int64): Bool {
    pgid > 1 && executeWithOutput("/usr/bin/pgrep", ["-g", "${pgid}"])[0] != 0
}

private func gatewayServeStopRuntimeOwnerCount(path: Path): Int64 {
    try {
        let text = String.fromUtf8(File.readFrom(path))
        let marker = "\"brokerOwnerCount\":"
        if (!text.contains(marker)) { return 0 }
        let tail = text.split(marker)[1]
        Int64.parse(tail.split(",")[0].split("}")[0].trimAscii())
    } catch (_: Exception) {
        0
    }
}

private class GatewayServeStopLiveOwnerProof {
    var httpStatus: Int64 = 0
    var running: Bool = false
    var ownerCount: Int64 = 0

    func refresh(url: String): Unit {
        this.httpStatus = 0
        this.running = false
        this.ownerCount = 0
        let builder = ClientBuilder()
        builder.readTimeout(Duration.millisecond * 500)
        let client = builder.build()
        try {
            let response = client.send(HttpRequestBuilder().url(url).get().build())
            this.httpStatus = Int64(response.status)
            let bytes = ArrayList<Byte>()
            let buffer = Array<Byte>(1024, repeat: 0)
            while (bytes.size <= 64 * 1024) {
                let count = response.body.read(buffer)
                if (count <= 0) { break }
                bytes.add(all: buffer[..count])
            }
            if (bytes.size > 64 * 1024) { return }
            let root = JsonValue.fromStr(String.fromUtf8(bytes.toArray())).asObject()
            let broker = root.get("readiness").getOrThrow().asObject()
                .get("operational").getOrThrow().asObject()
                .get("broker").getOrThrow().asObject()
            this.running = broker.get("running").getOrThrow().asBool().getValue()
            this.ownerCount = broker.get("ownerCount").getOrThrow().asInt().getValue()
        } catch (_: Exception) {
            this.httpStatus = 0
            this.running = false
            this.ownerCount = 0
        } finally {
            client.close()
        }
    }
}

private func gatewayServeStopConfigureFormalFixture(
    home: Path,
    gatewayPort: Int64,
    pluginPort: Int64,
    descendantPort: Int64,
    mode: String,
    ready: Path
): Path {
    let fixture = Path(managedStdioResolveBrokerScriptPath()).parent.join("metis-gateway-stop-fake-service-plugin.mjs")
    let fixtureCopy = home.join("metis-gateway-stop-fake-service-plugin.mjs")
    File.writeTo(fixtureCopy, File.readFrom(fixture))
    let manifest = home.join("gateway-stop-fixture.manifest.json")
    File.writeTo(
        manifest,
        ("{\"schema\":\"metis.servicePlugin.v1\",\"pluginId\":\"gateway-stop-fixture\",\"kind\":\"service\",\"protocolVersion\":\"1.0\",\"entry\":{\"command\":\"/usr/bin/env\",\"args\":[\"node\",\"${fixtureCopy.toString()}\",\"${mode}\",\"${pluginPort}\",\"${descendantPort}\",\"${ready.toString()}\"]},\"configSchema\":{\"type\":\"object\"},\"capabilityDeclarations\":[{\"capabilityId\":\"gateway.stop.fixture\",\"kind\":\"controlAction\"}]}").toArray()
    )
    var settings = CliSettingManager.readGatewaySettings()
    settings.enabled = true
    settings.port = gatewayPort
    var plugin = GatewayServicePluginUserSettings()
    plugin.pluginId = "gateway-stop-fixture"
    plugin.enabled = true
    plugin.autostart = true
    plugin.startupTimeoutMs = 5000
    plugin.manifestPath = manifest.toString()
    settings.servicePlugins = [plugin]
    let _ = MetisConfigManager.setGatewaySettings(settings)
    CliSettingManager.invalidate()
    fixture
}

private class GatewayServeStopPolicyScenario {
    let original = GatewayServeIdentity(24626, 1000, "serve-原始-🔒")
    let replacement = GatewayServeIdentity(24626, 2000, "serve-replacement")
    let signals = ArrayList<String>()
    var nowMs: Int64 = 0
    var completionAtMs: Int64 = -1
    var pidGoneAtMs: Int64 = -1
    var replacementAtMs: Int64 = -1
    var completionStatus = "graceful"
    var completionFound = true
    var completionMarksPidGone = true
    var completionMissingStatus = "missing"
    var signalSucceeds = true
    var requestSucceeds = true
    var pidProbeConclusive = true
    var pidProbeStatus = "pid_probe_permission_denied"
    var killed = false

    func waitMs(durationMs: Int64): Unit { this.nowMs += durationMs }

    func probe(_pid: Int64, _timeoutMs: Int64): GatewayServePidProbeResult {
        if (!this.pidProbeConclusive) { return GatewayServePidProbeResult(false, false, this.pidProbeStatus) }
        let gone = this.killed || (this.pidGoneAtMs >= 0 && this.nowMs >= this.pidGoneAtMs) ||
            (this.completionMarksPidGone && this.completionAtMs >= 0 && this.nowMs >= this.completionAtMs)
        GatewayServePidProbeResult(true, !gone, if (gone) { "gone" } else { "alive" })
    }

    func identity(): Option<GatewayServeIdentity> {
        if (this.replacementAtMs >= 0 && this.nowMs >= this.replacementAtMs) { Some(this.replacement) } else { Some(this.original) }
    }

    func completion(_identity: GatewayServeIdentity): GatewayServeCompletionResult {
        if (this.completionAtMs >= 0 && this.nowMs >= this.completionAtMs) {
            if (this.completionFound) {
                GatewayServeCompletionResult(
                    true,
                    status: this.completionStatus,
                    fullTerminal: this.completionStatus == "graceful"
                )
            } else {
                GatewayServeCompletionResult(false, status: this.completionMissingStatus)
            }
        } else {
            GatewayServeCompletionResult(false)
        }
    }

    func signal(expected: GatewayServeIdentity, signal: String, _timeoutMs: Int64): Bool {
        if (!expected.matches(this.original)) { return false }
        this.signals.add(signal)
        if (signal == "KILL" && this.signalSucceeds) { this.killed = true }
        this.signalSucceeds
    }

    func request(expected: GatewayServeIdentity): Bool {
        if (!expected.matches(this.original)) { return false }
        this.signals.add("REQUEST")
        this.requestSucceeds
    }

    func run(): GatewayServeTerminationResult {
        gatewayTerminateServeProcessWithPolicy(
            this.original,
            { => this.nowMs },
            { millis => this.waitMs(millis) },
            { pid, timeoutMs => this.probe(pid, timeoutMs) },
            { => this.identity() },
            { identity => this.completion(identity) },
            { identity => this.request(identity) },
            { identity, signal, timeoutMs => this.signal(identity, signal, timeoutMs) }
        )
    }
}

private class GatewayStopDeadlineTestClock {
    var elapsedMs: Int64 = 0
}

@Test
public class GatewayServeLockLogicTest {
    @TestCase
    public func parsePidListTextDeduplicatesAndSkipsInvalidRows(): Unit {
        let pids = gatewayParsePidListText("24626\n\nabc\n39668\n24626\n")
        @Expect(pids.size, 2)
        @Expect(pids[0], 24626)
        @Expect(pids[1], 39668)
    }

    @TestCase
    public func looksLikeServeCommandRequiresGatewayServeAndKnownBinary(): Unit {
        @Expect(
            gatewayLooksLikeServeCommand(
                "/bin/zsh -lc rtk cjpm run --skip-build --name metis --run-args gateway serve"
            ),
            true
        )
        @Expect(
            gatewayLooksLikeServeCommand("/usr/bin/python3 -m http.server 18788"),
            false
        )
    }

    @TestCase
    public func resolveStopTargetsPrefersVerifiedListenersOverLockPid(): Unit {
        let listener = gatewayResolveStopTargetPids([24626, 24627], lockPid: Some(39668))
        @Expect(listener.size, 2)
        @Expect(listener[0], 24626)
        @Expect(listener[1], 24627)

        let fallback = gatewayResolveStopTargetPids([], lockPid: Some(39668))
        @Expect(fallback.size, 1)
        @Expect(fallback[0], 39668)
    }

    @TestCase
    public func s4B1CliDiscoveryAndMultipleTargetsShareOneAbsoluteDeadline(): Unit {
        let origin = MonoTime.now()
        let deadline = origin + Duration.millisecond * 1000
        let clock = GatewayStopDeadlineTestClock()
        let observedRemaining = ArrayList<Int64>()
        let discovered = gatewayStopDiscoverWithinDeadline(
            deadline,
            { stopDeadline =>
                observedRemaining.add((stopDeadline - (origin + Duration.millisecond * clock.elapsedMs)).toMilliseconds())
                clock.elapsedMs = 200
                GatewayServeListenerDiscoveryResult(true, [24626, 24627], "ok")
            }
        )
        let results = gatewayStopTargetsWithinDeadline(
            discovered.pids,
            deadline,
            { _pid, stopDeadline =>
                observedRemaining.add((stopDeadline - (origin + Duration.millisecond * clock.elapsedMs)).toMilliseconds())
                clock.elapsedMs += 100
                GatewayServeTerminationResult(true, "graceful", pidStatus: "gone")
            }
        )

        @Expect(results.size, 2)
        @Expect(results[0][0], 24626)
        @Expect(results[1][0], 24627)
        @Expect(observedRemaining.size, 3)
        @Expect(observedRemaining[0], 1000)
        @Expect(observedRemaining[1], 800)
        @Expect(observedRemaining[2], 700)
        @Expect(clock.elapsedMs, 400)
    }

    @TestCase
    public func s4U1GracefulTimeoutKillAndIdentityFenceHaveExactSignals(): Unit {
        let graceful = GatewayServeStopPolicyScenario()
        graceful.completionAtMs = 100
        let gracefulResult = graceful.run()
        @Expect(gracefulResult.ok, true)
        @Expect(gracefulResult.status, "graceful")
        @Expect(graceful.signals.size, 1)
        @Expect(graceful.signals[0], "REQUEST")

        let forced = GatewayServeStopPolicyScenario()
        let forcedResult = forced.run()
        @Expect(forcedResult.ok, false)
        @Expect(forcedResult.status, "cleanup_pending")
        @Expect(forcedResult.killSent, true)
        @Expect(forced.signals.size, 3)
        @Expect(forced.signals[0], "REQUEST")
        @Expect(forced.signals[1], "TERM")
        @Expect(forced.signals[2], "KILL")

        let terminalBeforeKill = GatewayServeStopPolicyScenario()
        terminalBeforeKill.completionAtMs = 100
        terminalBeforeKill.completionMarksPidGone = false
        let terminalBeforeKillResult = terminalBeforeKill.run()
        @Expect(terminalBeforeKillResult.ok, true)
        @Expect(terminalBeforeKillResult.status, "force_terminated")
        @Expect(terminalBeforeKillResult.killSent, true)
        @Expect(terminalBeforeKill.signals.size, 3)

        let replacement = GatewayServeStopPolicyScenario()
        replacement.replacementAtMs = 900
        let stale = replacement.run()
        @Expect(stale.ok, false)
        @Expect(stale.status, "stale_identity")
        @Expect(replacement.signals.size, 1)
        @Expect(replacement.signals[0], "REQUEST")
    }

    @TestCase
    public func s4B1CompletionAtTermDeadlineMinusOneEqualAndPlusOneIsStable(): Unit {
        for (_ in 0..3) {
            for (completionAt in [Int64(899), Int64(900), Int64(901)]) {
                let scenario = GatewayServeStopPolicyScenario()
                scenario.completionAtMs = completionAt
                let result = scenario.run()
                if (completionAt <= 900) {
                    @Expect(result.status, "graceful")
                    @Expect(scenario.signals.size, 1)
                } else {
                    @Expect(result.status, "graceful")
                    @Expect(scenario.signals.size, 2)
                }
            }
        }
        for (_ in 0..3) {
            for (completionAt in [Int64(1199), Int64(1200), Int64(1201)]) {
                let scenario = GatewayServeStopPolicyScenario()
                scenario.completionAtMs = completionAt
                let result = scenario.run()
                @Expect(scenario.signals[0], "REQUEST")
                @Expect(scenario.signals[1], "TERM")
                if (completionAt <= 1200) {
                    @Expect(result.ok, true)
                    @Expect(result.status, "graceful")
                    @Expect(result.termSent, true)
                    @Expect(result.killSent, false)
                    @Expect(scenario.signals.size, 2)
                } else {
                    @Expect(result.ok, false)
                    @Expect(result.status, "cleanup_pending")
                    @Expect(result.termSent, true)
                    @Expect(result.killSent, true)
                    @Expect(scenario.signals.size, 3)
                    @Expect(scenario.signals[2], "KILL")
                }
            }
        }
    }

    @TestCase
    public func s4N1MissingMarkerWriterFailureAndUnknownPidStayCleanupPending(): Unit {
        let ignoresRequestAndTerm = GatewayServeStopPolicyScenario()
        let ignored = ignoresRequestAndTerm.run()
        @Expect(ignored.ok, false)
        @Expect(ignored.status, "cleanup_pending")
        @Expect(ignoresRequestAndTerm.signals.size, 3)
        @Expect(ignoresRequestAndTerm.signals[0], "REQUEST")
        @Expect(ignoresRequestAndTerm.signals[1], "TERM")
        @Expect(ignoresRequestAndTerm.signals[2], "KILL")

        let replacement = GatewayServeStopPolicyScenario()
        replacement.replacementAtMs = 900
        let replaced = replacement.run()
        @Expect(replaced.ok, false)
        @Expect(replaced.status, "stale_identity")
        @Expect(replacement.signals.size, 1)
        @Expect(replacement.signals[0], "REQUEST")

        let missingMarker = GatewayServeStopPolicyScenario()
        missingMarker.pidGoneAtMs = 100
        let missing = missingMarker.run()
        @Expect(missing.ok, false)
        @Expect(missing.status, "cleanup_pending")
        @Expect(missingMarker.signals.size, 1)

        let requestFailure = GatewayServeStopPolicyScenario()
        requestFailure.requestSucceeds = false
        let failed = requestFailure.run()
        @Expect(failed.ok, false)
        @Expect(failed.status, "cleanup_pending")
        @Expect(failed.pidStatus, "request_write_failed")
        @Expect(requestFailure.signals.size, 1)
        @Expect(requestFailure.signals[0], "REQUEST")

        let signalFailure = GatewayServeStopPolicyScenario()
        signalFailure.signalSucceeds = false
        let signalFailed = signalFailure.run()
        @Expect(signalFailed.ok, false)
        @Expect(signalFailed.status, "cleanup_pending")
        @Expect(signalFailure.signals.size, 2)

        for (markerStatus in ["write_failed", "invalid_response_encoding"]) {
            let markerFailure = GatewayServeStopPolicyScenario()
            markerFailure.completionAtMs = 100
            markerFailure.completionFound = false
            markerFailure.completionMissingStatus = markerStatus
            let markerPending = markerFailure.run()
            @Expect(markerPending.ok, false)
            @Expect(markerPending.status, "cleanup_pending")
            @Expect(markerFailure.signals.size, 1)
            @Expect(markerFailure.signals[0], "REQUEST")
        }

        let explicitPending = GatewayServeStopPolicyScenario()
        explicitPending.completionAtMs = 100
        explicitPending.completionStatus = "cleanup_pending"
        let pending = explicitPending.run()
        @Expect(pending.ok, false)
        @Expect(pending.status, "cleanup_pending")
        @Expect(explicitPending.signals.size, 1)

        for (status in ["pid_probe_permission_denied", "pid_probe_unavailable", "invalid_response_encoding"]) {
            let unknownPid = GatewayServeStopPolicyScenario()
            unknownPid.pidProbeConclusive = false
            unknownPid.pidProbeStatus = status
            let unknown = unknownPid.run()
            @Expect(unknown.ok, false)
            @Expect(unknown.status, "cleanup_pending")
            @Expect(unknown.pidStatus, status)
            @Expect(unknownPid.signals.size, 0)
        }
    }

    @TestCase
    public func s4N1ServeIdentityParserRejectsLegacyAndMalformedPayloads(): Unit {
        @Expect(gatewayParseServeIdentity("gateway-serve-active-v2\npid:24626\n").isNone(), true)
        @Expect(gatewayParseServeIdentity("gateway-serve-active-v3\npid:abc\nstartedAtMs:1\nnonce:x\n").isNone(), true)
        let parsed = gatewayParseServeIdentity("gateway-serve-active-v3\npid:24626\nstartedAtMs:1000\nnonce:中文-🔒\n").getOrThrow()
        @Expect(parsed.pid, 24626)
        @Expect(parsed.startedAtMs, 1000)
        @Expect(parsed.nonce, "中文-🔒")
        @Expect(gatewayParseServeStopRequestIdentity("gateway-serve-active-v4\npid:24626\nstartedAtMs:1000\nnonce:x\nrequestedAtMs:1\n").isNone(), true)
        match (currentProcessInstanceIdentity()) {
            case Some(instance) =>
                let request = gatewayParseServeStopRequestIdentity(
                    "gateway-serve-active-v4\npid:24626\nstartedAtMs:1000\nnonce:中文-🔒\nprocessIdentity:${instance.serialize()}\nrequestedAtMs:2\n"
                )
                @Expect(request.isSome(), true)
                @Expect(request.getOrThrow().nonce, "中文-🔒")
            case None => ()
        }
    }

    @TestCase
    public func s4N1SurfaceFailurePreventsFullTerminalCompletion(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let home = Path("/tmp/metis-s4-surface-completion-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            let oldHome = getVariable("METIS_HOME")
            try {
                Directory.create(home, recursive: true)
                setVariable("METIS_HOME", home.toString())
                CliConfig.invalidatePathCache()
                let identity = GatewayServeIdentity(24626, 1000, "surface-failure")
                let core = GatewayStopResult(
                    true,
                    "stopped",
                    inboundStatus: "stopped",
                    compatStatus: "stopped",
                    sidecarStatus: "disabled",
                    servicePluginIngressStatus: "not_applicable",
                    servicePluginDispatchStatus: "not_applicable",
                    servicePluginOwnerStatus: "not_applicable",
                    servicePluginLeaseStatus: "not_applicable",
                    servicePluginPortStatus: "not_applicable",
                    channelsStatus: "stopped",
                    brokerStatus: "stopped"
                )
                @Expect(gatewayWriteServeCompletionMarker(identity, core, httpStatus: "close_failed", canvasStatus: "already_stopped", gatewayServerStatus: "stopped"), true)
                let failed = try { String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))) } catch (_: Exception) { "" }
                @Expect(gatewayServeStopCompletionField(failed, "status"), "cleanup_pending")
                @Expect(gatewayServeStopCompletionField(failed, "fullTerminal"), "0")
                @Expect(gatewayWriteServeCompletionMarker(identity, core, httpStatus: "stopped", canvasStatus: "already_stopped", gatewayServerStatus: "stopped"), true)
                let stopped = try { String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))) } catch (_: Exception) { "" }
                @Expect(gatewayServeStopCompletionField(stopped, "status"), "graceful")
                @Expect(gatewayServeStopCompletionField(stopped, "fullTerminal"), "1")
            } finally {
                match (oldHome) {
                    case Some(value) => setVariable("METIS_HOME", value)
                    case None => setVariable("METIS_HOME", "")
                }
                CliConfig.invalidatePathCache()
                try { remove(home, recursive: true) } catch (_: Exception) { () }
            }
        }
    }

    @TestCase
    public func s4P1FormalGatewayStopClosesFakeGatewayAndGcmResources(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let home = Path("/tmp/metis-s4-stop-e2e-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            let gatewayPort = gatewayServeStopTemporaryPort()
            let pluginPort = gatewayServeStopTemporaryPort()
            let descendantPort = gatewayServeStopTemporaryPort()
            @Expect(gatewayPort > 0 && pluginPort > 0 && descendantPort > 0, true)
            @Expect(gatewayPort != pluginPort && gatewayPort != descendantPort && pluginPort != descendantPort, true)
            let oldHome = getVariable("METIS_HOME")
            let oldRoot = getVariable("METIS_CJPM_ROOT")
            let brokerScript = Path(managedStdioResolveBrokerScriptPath())
            let project = brokerScript.parent.parent
            let binary = project.join("target").join("release").join("bin").join("metis")
            var gatewayProcess: Option<SubProcess> = None<SubProcess>
            var gatewayIdentity: Option<GatewayServeIdentity> = None<GatewayServeIdentity>
            var gatewayPid: Int64 = 0
            var brokerPid: Int64 = 0
            var rootPid: Int64 = 0
            var childPid: Int64 = 0
            var pgid: Int64 = 0
            var ownedResources = GatewayServeStopResourceCapture()
            let output = ArrayList<String>()
            try {
                Directory.create(home, recursive: true)
                setVariable("METIS_HOME", home.toString())
                let fixture = brokerScript.parent.join("metis-gateway-stop-fake-service-plugin.mjs")
                setVariable("METIS_CJPM_ROOT", project.toString())
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                var settings = CliSettingManager.readGatewaySettings()
                settings.enabled = true
                settings.port = gatewayPort
                let diagnosticLog = home.join("gateway-stop-diagnostic.log")
                settings.logging.file = diagnosticLog.toString()
                settings.logging.level = "info"
                let manifest = home.join("gateway-stop-fixture.manifest.json")
                let ready = home.join("gateway-stop-fixture.ready")
                let fixtureCopy = home.join("metis-gateway-stop-fake-service-plugin.mjs")
                File.writeTo(fixtureCopy, File.readFrom(fixture))
                File.writeTo(
                    manifest,
                    ("{\"schema\":\"metis.servicePlugin.v1\",\"pluginId\":\"gateway-stop-fixture\",\"kind\":\"service\",\"protocolVersion\":\"1.0\",\"entry\":{\"command\":\"/usr/bin/env\",\"args\":[\"node\",\"${fixtureCopy.toString()}\",\"graceful\",\"${pluginPort}\",\"${descendantPort}\",\"${ready.toString()}\"]},\"configSchema\":{\"type\":\"object\"},\"capabilityDeclarations\":[{\"capabilityId\":\"gateway.stop.fixture\",\"kind\":\"controlAction\"}]}").toArray()
                )
                let loadedManifest = loadServicePluginManifest(manifest.toString())
                @Expect(loadedManifest.ok, true)
                @Expect(loadedManifest.status, "accepted")
                var plugin = GatewayServicePluginUserSettings()
                plugin.pluginId = "gateway-stop-fixture"
                plugin.enabled = true
                plugin.autostart = true
                plugin.startupTimeoutMs = 5000
                plugin.manifestPath = manifest.toString()
                settings.servicePlugins = [plugin]
                let _ = MetisConfigManager.setGatewaySettings(settings)
                CliSettingManager.invalidate()
                let persistedPlugins = CliSettingManager.readGatewaySettings().servicePlugins
                @Expect(persistedPlugins.size, 1)
                if (persistedPlugins.size == 1) {
                    @Expect(persistedPlugins[0].pluginId, "gateway-stop-fixture")
                    @Expect(persistedPlugins[0].autostart, true)
                }

                @Expect(exists(fixture), true)
                @Expect(exists(binary), true)
                let launched = launch(
                    binary.toString(),
                    ["gateway", "run"],
                    stdIn: ProcessRedirect.Discard,
                    stdOut: ProcessRedirect.Discard,
                    stdErr: ProcessRedirect.Discard
                )
                gatewayPid = launched.pid
                gatewayProcess = Some(launched)
                gatewayIdentity = gatewayServeStopCaptureOwnedIdentity(home, gatewayPid, binary, 5000)
                @Expect(gatewayIdentity.isSome(), true)
                ownedResources = gatewayServeStopCaptureResources(
                    gatewayPid,
                    brokerScript,
                    fixtureCopy,
                    ready,
                    10000
                )
                @Expect(ownedResources.brokerStarted, true)
                @Expect(ownedResources.brokerCaptured, true)
                @Expect(ownedResources.fixtureStarted, true)
                @Expect(ownedResources.fixtureCaptured, true)
                brokerPid = ownedResources.brokerPid
                rootPid = ownedResources.rootPid
                childPid = ownedResources.childPid
                pgid = ownedResources.pgid
                let runtimeState = home.join("gateway-runtime-state.json")
                let readyzUrl = "http://127.0.0.1:${gatewayPort}/readyz"
                let liveOwner = GatewayServeStopLiveOwnerProof()
                let _ = gatewayServeStopWaitUntil(15000, { =>
                    liveOwner.refresh(readyzUrl)
                    exists(ready) && liveOwner.httpStatus == 200 && liveOwner.running && liveOwner.ownerCount >= 1 &&
                        gatewayServeStopPortListening(gatewayPort) && gatewayServeStopPortListening(pluginPort) &&
                        gatewayServeStopPortListening(descendantPort)
                })
                let gatewayAlive = gatewayServeStopPidAlive(gatewayPid)
                let lockV4 = try {
                    String.fromUtf8(File.readFrom(home.join("gateway-serve.lock"))).contains("gateway-serve-active-v4")
                } catch (_: Exception) {
                    false
                }
                let gatewayPortReady = gatewayServeStopPortListening(gatewayPort)
                let runtimeStatePresent = exists(runtimeState)
                liveOwner.refresh(readyzUrl)
                let ownerReady = liveOwner.ownerCount >= 1
                let brokerReady = brokerPid > 0
                let brokerCommandOwned = gatewayServeStopCommandContains(brokerPid, brokerScript.toString())
                let brokerParentOwned = gatewayServeStopParentPid(brokerPid) == gatewayPid
                let fixtureReady = exists(ready)
                let rootPortReady = gatewayServeStopPortListening(pluginPort)
                let childPortReady = gatewayServeStopPortListening(descendantPort)
                let diagnosticText = try {
                    String.fromUtf8(File.readFrom(diagnosticLog))
                } catch (_: Exception) {
                    ""
                }
                let registered = diagnosticText.contains("service_plugin.registered")
                let autostartRunning = diagnosticText.contains("service_plugin.autostart.running")
                let degraded = diagnosticText.contains("service_plugin.degraded") ||
                    diagnosticText.contains("service_plugin.autostart.degraded")
                let processStartFailed = diagnosticText.contains("process_start_failed")
                let initializeTimeout = diagnosticText.contains("initialize_timeout")
                let validationError = diagnosticText.contains("validation_error")
                let setupRequired = diagnosticText.contains("setup-required")
                let conflict = diagnosticText.contains("conflict")
                let jsonParseError = diagnosticText.contains("json_parse_error")
                @Expect(gatewayAlive, true)
                @Expect(lockV4, true)
                @Expect(gatewayPortReady, true)
                @Expect(runtimeStatePresent, true)
                @Expect(liveOwner.httpStatus, 200)
                @Expect(liveOwner.running, true)
                @Expect(ownerReady, true)
                @Expect(brokerReady, true)
                @Expect(brokerCommandOwned, true)
                @Expect(brokerParentOwned, true)
                @Expect(fixtureReady, true)
                @Expect(rootPortReady, true)
                @Expect(childPortReady, true)
                @Expect(registered, true)
                @Expect(autostartRunning, true)
                @Expect(degraded, false)
                @Expect(processStartFailed, false)
                @Expect(initializeTimeout, false)
                @Expect(validationError, false)
                @Expect(setupRequired, false)
                @Expect(conflict, false)
                @Expect(jsonParseError, false)
                let rows = gatewayServeStopReadLines(ready)
                @Expect(rows.size >= 6, true)
                if (rows.size < 6) { return }
                let readyRootPid = Int64.parse(rows[0].trimAscii())
                let readyChildPid = Int64.parse(rows[1].trimAscii())
                let readyPgid = Int64.parse(rows[2].trimAscii())
                let lease = Path(rows[5].trimAscii())
                @Expect(readyRootPid, rootPid)
                @Expect(readyChildPid, childPid)
                @Expect(readyPgid, pgid)
                @Expect(rootPid > 0 && childPid > 0 && pgid > 0, true)
                @Expect(gatewayServeStopProcessGroup(rootPid), pgid)
                @Expect(gatewayServeStopProcessGroup(childPid), pgid)
                let lockText = String.fromUtf8(File.readFrom(home.join("gateway-serve.lock")))
                @Expect(lockText.contains("gateway-serve-active-v4"), true)
                @Expect(lockText.contains("processIdentity:"), true)
                @Expect(lockText.contains("gracefulShutdownTimeoutMs:60000"), true)
                let stopIdentity = gatewayParseServeIdentity(lockText).getOrThrow()
                @Expect(stopIdentity.pid, gatewayPid)
                @Expect(stopIdentity.processIdentity.isSome(), true)
                @Expect(gatewayIdentity.getOrThrow().matches(stopIdentity), true)

                setGatewayStopOutputForTest(Some({ line => output.add(line) }))
                let exitCode = gatewayExecuteStopServe()
                let outputText = String.join(output.toArray(), delimiter: "\n")
                let humanCleanupPending = outputText.contains("子进程清理未完成")
                @Expect(exitCode, 0)
                @Expect(outputText.contains("已正常停止"), true)
                @Expect(outputText.contains("\"ok\""), false)
                @Expect(humanCleanupPending, false)
                let stoppedBrokerPid = brokerPid
                let stoppedRootPid = rootPid
                let stoppedChildPid = childPid
                let completionPath = home.join("gateway-serve.stop-complete")
                let immediateCompletion = try {
                    String.fromUtf8(File.readFrom(completionPath))
                } catch (_: Exception) {
                    ""
                }
                @Expect(gatewayServeStopCompletionField(immediateCompletion, "status"), "graceful")
                @Expect(gatewayServeStopCompletionField(immediateCompletion, "fullTerminal"), "1")
                let gatewayReaped = gatewayServeStopReapCompletedOwnedProcess(gatewayProcess)
                @Expect(gatewayReaped, true)
                if (gatewayReaped) { gatewayProcess = None<SubProcess> }
                let postStopStarted = MonoTime.now()
                var terminalElapsedMs: Int64 = -1
                var completionObserved = false
                var gatewayGone = false
                var brokerGone = false
                var rootGone = false
                var childGone = false
                var groupGone = false
                var gatewayPortGone = false
                var rootPortGone = false
                var childPortGone = false
                var leaseStopped = false
                var lockGone = false
                while ((MonoTime.now() - postStopStarted).toMilliseconds() < 15000) {
                    completionObserved = if (exists(completionPath)) {
                        try {
                            let completionText = String.fromUtf8(File.readFrom(completionPath))
                            match (gatewayParseServeIdentity(completionText)) {
                                case Some(found) => found.matches(stopIdentity)
                                case None => false
                            }
                        } catch (_: Exception) {
                            false
                        }
                    } else {
                        false
                    }
                    gatewayGone = gatewayReaped
                    brokerGone = !gatewayServeStopPidAlive(stoppedBrokerPid)
                    rootGone = !gatewayServeStopPidAlive(stoppedRootPid)
                    childGone = !gatewayServeStopPidAlive(stoppedChildPid)
                    groupGone = executeWithOutput("/usr/bin/pgrep", ["-g", "${pgid}"])[0] != 0
                    gatewayPortGone = !gatewayServeStopPortListening(gatewayPort)
                    rootPortGone = !gatewayServeStopPortListening(pluginPort)
                    childPortGone = !gatewayServeStopPortListening(descendantPort)
                    leaseStopped = try {
                        String.fromUtf8(File.readFrom(lease)).contains("\"state\":\"stopped\"")
                    } catch (_: Exception) {
                        false
                    }
                    lockGone = !exists(home.join("gateway-serve.lock"))
                    if (completionObserved && gatewayGone && brokerGone && rootGone && childGone && groupGone &&
                        gatewayPortGone && rootPortGone && childPortGone && leaseStopped && lockGone) {
                        terminalElapsedMs = (MonoTime.now() - postStopStarted).toMilliseconds()
                        break
                    }
                    sleep(Duration.millisecond * 20)
                }
                let terminalWithin8s = terminalElapsedMs >= 0 && terminalElapsedMs <= 8000
                let terminalWithin11s = terminalElapsedMs >= 0 && terminalElapsedMs <= 11000
                let terminalWithin15s = terminalElapsedMs >= 0 && terminalElapsedMs <= 15000
                @Expect(completionObserved, true)
                @Expect(gatewayGone, true)
                @Expect(brokerGone, true)
                @Expect(rootGone, true)
                @Expect(childGone, true)
                @Expect(groupGone, true)
                @Expect(gatewayPortGone, true)
                @Expect(rootPortGone, true)
                @Expect(childPortGone, true)
                @Expect(leaseStopped, true)
                @Expect(lockGone, true)
                @Expect(terminalWithin8s, true)
                @Expect(terminalWithin11s, true)
                @Expect(terminalWithin15s, true)
                @Expect(exists(completionPath), true)
                let completion = if (exists(completionPath)) {
                    try { String.fromUtf8(File.readFrom(completionPath)) } catch (_: Exception) { "" }
                } else {
                    ""
                }
                @Expect(gatewayServeStopCompletionField(completion, "status"), "graceful")
                @Expect(gatewayServeStopCompletionField(completion, "fullTerminal"), "1")
                @Expect(gatewayServeStopCompletionField(completion, "inboundStatus"), "stopped")
                @Expect(gatewayServeStopCompletionField(completion, "compatStatus"), "stopped")
                let completionSidecarStatus = gatewayServeStopCompletionField(completion, "sidecarStatus")
                @Expect(completionSidecarStatus == "stopped" || completionSidecarStatus == "disabled", true)
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginIngressStatus"), "sent")
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginDispatchStatus"), "drained")
                let completionOwnerStatus = gatewayServeStopCompletionField(completion, "servicePluginOwnerStatus")
                @Expect(completionOwnerStatus, "graceful_exited")
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginLeaseStatus"), "stopped")
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginPortStatus"), "released")
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginPendingCount"), "0")
                @Expect(gatewayServeStopCompletionField(completion, "channelsStatus"), "stopped")
                @Expect(gatewayServeStopCompletionField(completion, "brokerStatus"), "stopped")
                @Expect(gatewayServeStopCompletionField(completion, "httpStatus"), "stopped")
                let canvasStatus = gatewayServeStopCompletionField(completion, "canvasStatus")
                @Expect(canvasStatus == "already_stopped" || canvasStatus == "not_applicable", true)
                @Expect(gatewayServeStopCompletionField(completion, "gatewayServerStatus"), "stopped")
                let shutdownDiagnosticText = try {
                    String.fromUtf8(File.readFrom(diagnosticLog))
                } catch (_: Exception) {
                    ""
                }
                let loggedCleanupPending = shutdownDiagnosticText.contains("cleanup_pending")
                let loggedDispatchPending = shutdownDiagnosticText.contains("dispatch_pending")
                let loggedLeaseNotStopped = shutdownDiagnosticText.contains("lease_not_stopped")
                let loggedPortReleaseTimeout = shutdownDiagnosticText.contains("port_release_timeout")
                @Expect(loggedCleanupPending, false)
                @Expect(loggedDispatchPending, false)
                @Expect(loggedLeaseNotStopped, false)
                @Expect(loggedPortReleaseTimeout, false)
                @Expect(completion.contains("status:graceful"), true)
                @Expect(completion.contains("fullTerminal:1"), true)
                @Expect(completion.contains("servicePluginIngressStatus:"), true)
                @Expect(completion.contains("servicePluginDispatchStatus:"), true)
                @Expect(completion.contains("servicePluginOwnerStatus:"), true)
                @Expect(completion.contains("servicePluginLeaseStatus:stopped"), true)
                @Expect(completion.contains("servicePluginPortStatus:released"), true)
                @Expect(completion.contains("servicePluginPendingCount:0"), true)
                @Expect(completion.contains("channelsStatus:"), true)
                @Expect(completion.contains("brokerStatus:stopped"), true)
                @Expect(gatewayServeStopRuntimeOwnerCount(runtimeState), 0)
            } finally {
                setGatewayStopOutputForTest(None<(String) -> Unit>)
                if (gatewayIdentity.isSome()) {
                    try { gatewayServeStopReapOwnedGateway(gatewayIdentity, binary, home) } catch (_: Exception) { () }
                }
                try { gatewayServeStopReapOwnedHandle(gatewayProcess, binary) } catch (_: Exception) { () }
                let gatewaySettled = try { gatewayServeStopWaitOwnedProcess(gatewayProcess) } catch (_: Exception) { false }
                let capturedBrokerPid = brokerPid
                let brokerGone = try {
                    ownedResources.brokerCaptured && gatewayServeStopWaitUntil(
                        3000,
                        { => !gatewayServeStopPidAlive(capturedBrokerPid) }
                    )
                } catch (_: Exception) {
                    false
                }
                try {
                    gatewayServeStopReapOwnedFixtureGroup(
                        pgid,
                        rootPid,
                        childPid,
                        home.join("metis-gateway-stop-fake-service-plugin.mjs")
                    )
                } catch (_: Exception) { () }
                let groupGone = try {
                    ownedResources.fixtureCaptured && gatewayServeStopGroupGone(pgid)
                } catch (_: Exception) {
                    false
                }
                let brokerTerminalStatus = ownedResources.brokerTerminalStatus()
                let fixtureTerminalStatus = ownedResources.fixtureTerminalStatus()
                try { let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000) } catch (_: Exception) { () }
                match (oldHome) {
                    case Some(value) => setVariable("METIS_HOME", value)
                    case None => setVariable("METIS_HOME", "")
                }
                match (oldRoot) {
                    case Some(value) => setVariable("METIS_CJPM_ROOT", value)
                    case None => setVariable("METIS_CJPM_ROOT", "")
                }
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                try { remove(home, recursive: true) } catch (_: Exception) { () }
                @Expect(gatewaySettled, true)
                @Expect(brokerGone, true)
                @Expect(groupGone, true)
                @Expect(brokerTerminalStatus, "gone")
                @Expect(fixtureTerminalStatus, "gone")
            }
        }
    }

    @TestCase
    public func s4N1FormalGatewayStopReapsIgnoreTermTreeAndRejectsStaleIdentity(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let suffix = DateTime.now().toUnixTimeStamp().toNanoseconds()
            let ignoreHome = Path("/tmp/metis-s4-stop-negative-ignore-${suffix}")
            let replacementHome = Path("/tmp/metis-s4-stop-negative-replacement-${suffix}")
            let oldHome = getVariable("METIS_HOME")
            let oldRoot = getVariable("METIS_CJPM_ROOT")
            let brokerScript = Path(managedStdioResolveBrokerScriptPath())
            let project = brokerScript.parent.parent
            let binary = project.join("target").join("release").join("bin").join("metis")
            var ignoreProcess: Option<SubProcess> = None<SubProcess>
            var oldProcess: Option<SubProcess> = None<SubProcess>
            var replacementProcess: Option<SubProcess> = None<SubProcess>
            var ignoreGatewayIdentity: Option<GatewayServeIdentity> = None<GatewayServeIdentity>
            var oldGatewayIdentity: Option<GatewayServeIdentity> = None<GatewayServeIdentity>
            var replacementGatewayIdentity: Option<GatewayServeIdentity> = None<GatewayServeIdentity>
            var ignoreGatewayPid: Int64 = 0
            var ignoreBrokerPid: Int64 = 0
            var ignoreRootPid: Int64 = 0
            var ignoreChildPid: Int64 = 0
            var ignorePgid: Int64 = 0
            var oldGatewayPid: Int64 = 0
            var oldBrokerPid: Int64 = 0
            var oldRootPid: Int64 = 0
            var oldChildPid: Int64 = 0
            var oldPgid: Int64 = 0
            var replacementPid: Int64 = 0
            var replacementBrokerPid: Int64 = 0
            var replacementRootPid: Int64 = 0
            var replacementChildPid: Int64 = 0
            var replacementPgid: Int64 = 0
            var ignoreResources = GatewayServeStopResourceCapture()
            var oldResources = GatewayServeStopResourceCapture()
            var replacementResources = GatewayServeStopResourceCapture()
            try {
                Directory.create(ignoreHome, recursive: true)
                setVariable("METIS_HOME", ignoreHome.toString())
                setVariable("METIS_CJPM_ROOT", project.toString())
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                let ignoreGatewayPort = gatewayServeStopTemporaryPort()
                let ignorePluginPort = gatewayServeStopTemporaryPort()
                let ignoreDescendantPort = gatewayServeStopTemporaryPort()
                let ignoreReady = ignoreHome.join("ignore.ready")
                let _ = gatewayServeStopConfigureFormalFixture(
                    ignoreHome,
                    ignoreGatewayPort,
                    ignorePluginPort,
                    ignoreDescendantPort,
                    "ignore-term",
                    ignoreReady
                )
                let ignoreLaunched = launch(binary.toString(), ["gateway", "run"], stdIn: ProcessRedirect.Discard,
                    stdOut: ProcessRedirect.Discard, stdErr: ProcessRedirect.Discard)
                ignoreGatewayPid = ignoreLaunched.pid
                ignoreProcess = Some(ignoreLaunched)
                ignoreGatewayIdentity = gatewayServeStopCaptureOwnedIdentity(ignoreHome, ignoreGatewayPid, binary, 5000)
                @Expect(ignoreGatewayIdentity.isSome(), true)
                ignoreResources = gatewayServeStopCaptureResources(
                    ignoreGatewayPid,
                    brokerScript,
                    ignoreHome.join("metis-gateway-stop-fake-service-plugin.mjs"),
                    ignoreReady,
                    10000
                )
                @Expect(ignoreResources.brokerStarted, true)
                @Expect(ignoreResources.brokerCaptured, true)
                @Expect(ignoreResources.fixtureStarted, true)
                @Expect(ignoreResources.fixtureCaptured, true)
                ignoreBrokerPid = ignoreResources.brokerPid
                ignoreRootPid = ignoreResources.rootPid
                ignoreChildPid = ignoreResources.childPid
                ignorePgid = ignoreResources.pgid
                @Expect(gatewayServeStopWaitUntil(10000, { =>
                    exists(ignoreReady) && gatewayServeStopPortListening(ignoreGatewayPort) &&
                        gatewayServeStopPortListening(ignorePluginPort) && gatewayServeStopPortListening(ignoreDescendantPort)
                }), true)
                let rows = gatewayServeStopReadLines(ignoreReady)
                @Expect(rows.size >= 6, true)
                if (rows.size < 6) { return }
                let readyIgnoreRootPid = Int64.parse(rows[0].trimAscii())
                let readyIgnoreChildPid = Int64.parse(rows[1].trimAscii())
                let readyIgnorePgid = Int64.parse(rows[2].trimAscii())
                let ignoreLease = Path(rows[5].trimAscii())
                @Expect(readyIgnoreRootPid, ignoreRootPid)
                @Expect(readyIgnoreChildPid, ignoreChildPid)
                @Expect(readyIgnorePgid, ignorePgid)
                @Expect(ignoreRootPid > 0 && ignoreChildPid > 0 && ignoreBrokerPid > 0, true)
                @Expect(gatewayServeStopCommandContains(ignoreBrokerPid, brokerScript.toString()), true)
                @Expect(gatewayServeStopParentPid(ignoreBrokerPid), ignoreGatewayPid)
                @Expect(gatewayServeStopProcessGroup(ignoreRootPid), ignorePgid)
                @Expect(gatewayServeStopProcessGroup(ignoreChildPid), ignorePgid)
                let stoppedIgnoreBrokerPid = ignoreBrokerPid
                let stoppedIgnoreRootPid = ignoreRootPid
                let stoppedIgnoreChildPid = ignoreChildPid
                let ignoreLockText = try {
                    String.fromUtf8(File.readFrom(ignoreHome.join("gateway-serve.lock")))
                } catch (_: Exception) {
                    ""
                }
                let ignoreIdentity = gatewayParseServeIdentity(ignoreLockText).getOrThrow()
                @Expect(ignoreIdentity.pid, ignoreGatewayPid)
                @Expect(ignoreIdentity.processIdentity.isSome(), true)
                @Expect(ignoreGatewayIdentity.getOrThrow().matches(ignoreIdentity), true)
                let ignoreOutput = ArrayList<String>()
                setGatewayStopOutputForTest(Some({ line => ignoreOutput.add(line) }))
                @Expect(gatewayExecuteStopServe(), 1)
                setGatewayStopOutputForTest(None<(String) -> Unit>)
                @Expect(String.join(ignoreOutput.toArray(), delimiter: "\n").contains("子进程清理未完成"), true)
                let ignoreLeaseStopped = try {
                    String.fromUtf8(File.readFrom(ignoreLease)).contains("\"state\":\"stopped\"")
                } catch (_: Exception) {
                    false
                }
                @Expect(ignoreLeaseStopped, false)
                let ignoreCompletionPath = ignoreHome.join("gateway-serve.stop-complete")
                let ignoreCompletion = try {
                    String.fromUtf8(File.readFrom(ignoreCompletionPath))
                } catch (_: Exception) {
                    ""
                }
                @Expect(gatewayParseServeIdentity(ignoreCompletion).getOrThrow().matches(ignoreIdentity), true)
                @Expect(gatewayServeStopCompletionField(ignoreCompletion, "status"), "cleanup_pending")
                @Expect(gatewayServeStopCompletionField(ignoreCompletion, "fullTerminal"), "0")
                @Expect(exists(ignoreHome.join("gateway-serve.lock")), false)
                @Expect(exists(ignoreHome.join("gateway-serve.stop-request")), false)
                @Expect(gatewayAcquireServeLockForRunningProcess(), false)
                @Expect(exists(ignoreCompletionPath), true)
                let ignoreGatewayReaped = gatewayServeStopReapCompletedOwnedProcess(ignoreProcess)
                @Expect(ignoreGatewayReaped, true)
                if (ignoreGatewayReaped) { ignoreProcess = None<SubProcess> }
                let ignoreRuntimeState = ignoreHome.join("gateway-runtime-state.json")
                @Expect(gatewayServeStopWaitUntil(15000, { =>
                    ignoreGatewayReaped && !gatewayServeStopPidAlive(stoppedIgnoreBrokerPid) &&
                        !gatewayServeStopPidAlive(stoppedIgnoreRootPid) && !gatewayServeStopPidAlive(stoppedIgnoreChildPid) &&
                        !gatewayServeStopPortListening(ignoreGatewayPort) && !gatewayServeStopPortListening(ignorePluginPort) &&
                        !gatewayServeStopPortListening(ignoreDescendantPort) && exists(ignoreRuntimeState) &&
                        gatewayServeStopRuntimeOwnerCount(ignoreRuntimeState) == 0
                }), true)
                @Expect(executeWithOutput("/usr/bin/pgrep", ["-g", "${ignorePgid}"])[0] != 0, true)

                Directory.create(replacementHome, recursive: true)
                setVariable("METIS_HOME", replacementHome.toString())
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                let replacementGatewayPort = gatewayServeStopTemporaryPort()
                let replacementPluginPort = gatewayServeStopTemporaryPort()
                let replacementDescendantPort = gatewayServeStopTemporaryPort()
                let oldReady = replacementHome.join("old.ready")
                let _ = gatewayServeStopConfigureFormalFixture(
                    replacementHome,
                    replacementGatewayPort,
                    replacementPluginPort,
                    replacementDescendantPort,
                    "graceful",
                    oldReady
                )
                let oldLaunched = launch(binary.toString(), ["gateway", "run"], stdIn: ProcessRedirect.Discard,
                    stdOut: ProcessRedirect.Discard, stdErr: ProcessRedirect.Discard)
                oldGatewayPid = oldLaunched.pid
                oldProcess = Some(oldLaunched)
                oldGatewayIdentity = gatewayServeStopCaptureOwnedIdentity(replacementHome, oldGatewayPid, binary, 5000)
                @Expect(oldGatewayIdentity.isSome(), true)
                oldResources = gatewayServeStopCaptureResources(
                    oldGatewayPid,
                    brokerScript,
                    replacementHome.join("metis-gateway-stop-fake-service-plugin.mjs"),
                    oldReady,
                    10000
                )
                @Expect(oldResources.brokerStarted, true)
                @Expect(oldResources.brokerCaptured, true)
                @Expect(oldResources.fixtureStarted, true)
                @Expect(oldResources.fixtureCaptured, true)
                oldBrokerPid = oldResources.brokerPid
                oldRootPid = oldResources.rootPid
                oldChildPid = oldResources.childPid
                oldPgid = oldResources.pgid
                @Expect(gatewayServeStopWaitUntil(10000, { =>
                    exists(oldReady) && gatewayServeStopPortListening(replacementGatewayPort) &&
                        gatewayServeStopPortListening(replacementPluginPort) && gatewayServeStopPortListening(replacementDescendantPort)
                }), true)
                let oldRows = gatewayServeStopReadLines(oldReady)
                @Expect(oldRows.size >= 6, true)
                if (oldRows.size < 6) { return }
                let readyOldRootPid = Int64.parse(oldRows[0].trimAscii())
                let readyOldChildPid = Int64.parse(oldRows[1].trimAscii())
                let readyOldPgid = Int64.parse(oldRows[2].trimAscii())
                @Expect(readyOldRootPid, oldRootPid)
                @Expect(readyOldChildPid, oldChildPid)
                @Expect(readyOldPgid, oldPgid)
                @Expect(oldRootPid > 0 && oldChildPid > 0 && oldBrokerPid > 0, true)
                @Expect(gatewayServeStopCommandContains(oldBrokerPid, brokerScript.toString()), true)
                @Expect(gatewayServeStopParentPid(oldBrokerPid), oldGatewayPid)
                let stoppedOldBrokerPid = oldBrokerPid
                let stoppedOldRootPid = oldRootPid
                let stoppedOldChildPid = oldChildPid
                let stoppedOldPgid = oldPgid
                let oldLockText = try {
                    String.fromUtf8(File.readFrom(replacementHome.join("gateway-serve.lock")))
                } catch (_: Exception) {
                    ""
                }
                let oldIdentity = gatewayParseServeIdentity(oldLockText).getOrThrow()
                @Expect(oldIdentity.pid, oldGatewayPid)
                @Expect(oldIdentity.processIdentity.isSome(), true)
                @Expect(oldGatewayIdentity.getOrThrow().matches(oldIdentity), true)
                @Expect(gatewayExecuteStopServe(), 0)
                let oldCompletion = try {
                    String.fromUtf8(File.readFrom(replacementHome.join("gateway-serve.stop-complete")))
                } catch (_: Exception) {
                    ""
                }
                @Expect(gatewayParseServeIdentity(oldCompletion).getOrThrow().matches(oldIdentity), true)
                @Expect(gatewayServeStopCompletionField(oldCompletion, "status"), "graceful")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "fullTerminal"), "1")
                let oldGatewayReaped = gatewayServeStopReapCompletedOwnedProcess(oldProcess)
                @Expect(oldGatewayReaped, true)
                if (oldGatewayReaped) { oldProcess = None<SubProcess> }
                @Expect(gatewayServeStopWaitUntil(10000, { =>
                    oldGatewayReaped && !gatewayServeStopPidAlive(stoppedOldBrokerPid) &&
                        !gatewayServeStopPidAlive(stoppedOldRootPid) && !gatewayServeStopPidAlive(stoppedOldChildPid) &&
                        executeWithOutput("/usr/bin/pgrep", ["-g", "${stoppedOldPgid}"])[0] != 0 &&
                        !gatewayServeStopPortListening(replacementGatewayPort) &&
                        !gatewayServeStopPortListening(replacementPluginPort) &&
                        !gatewayServeStopPortListening(replacementDescendantPort)
                }), true)
                let replacementReady = replacementHome.join("replacement.ready")
                let _ = gatewayServeStopConfigureFormalFixture(
                    replacementHome,
                    replacementGatewayPort,
                    replacementPluginPort,
                    replacementDescendantPort,
                    "graceful",
                    replacementReady
                )
                let replacementLaunched = launch(binary.toString(), ["gateway", "run"], stdIn: ProcessRedirect.Discard,
                    stdOut: ProcessRedirect.Discard, stdErr: ProcessRedirect.Discard)
                replacementPid = replacementLaunched.pid
                replacementProcess = Some(replacementLaunched)
                replacementGatewayIdentity = gatewayServeStopCaptureOwnedIdentity(
                    replacementHome,
                    replacementPid,
                    binary,
                    5000
                )
                @Expect(replacementGatewayIdentity.isSome(), true)
                replacementResources = gatewayServeStopCaptureResources(
                    replacementPid,
                    brokerScript,
                    replacementHome.join("metis-gateway-stop-fake-service-plugin.mjs"),
                    replacementReady,
                    10000
                )
                @Expect(replacementResources.brokerStarted, true)
                @Expect(replacementResources.brokerCaptured, true)
                @Expect(replacementResources.fixtureStarted, true)
                @Expect(replacementResources.fixtureCaptured, true)
                replacementBrokerPid = replacementResources.brokerPid
                replacementRootPid = replacementResources.rootPid
                replacementChildPid = replacementResources.childPid
                replacementPgid = replacementResources.pgid
                @Expect(gatewayServeStopWaitUntil(10000, { =>
                    exists(replacementReady) && gatewayServeStopPortListening(replacementGatewayPort) &&
                        gatewayServeStopPortListening(replacementPluginPort) && gatewayServeStopPortListening(replacementDescendantPort)
                }), true)
                let replacementRows = gatewayServeStopReadLines(replacementReady)
                @Expect(replacementRows.size >= 6, true)
                if (replacementRows.size < 6) { return }
                let readyReplacementRootPid = Int64.parse(replacementRows[0].trimAscii())
                let readyReplacementChildPid = Int64.parse(replacementRows[1].trimAscii())
                let readyReplacementPgid = Int64.parse(replacementRows[2].trimAscii())
                @Expect(readyReplacementRootPid, replacementRootPid)
                @Expect(readyReplacementChildPid, replacementChildPid)
                @Expect(readyReplacementPgid, replacementPgid)
                @Expect(gatewayServeStopCommandContains(replacementBrokerPid, brokerScript.toString()), true)
                @Expect(gatewayServeStopParentPid(replacementBrokerPid), replacementPid)
                let stoppedReplacementBrokerPid = replacementBrokerPid
                let stoppedReplacementRootPid = replacementRootPid
                let stoppedReplacementChildPid = replacementChildPid
                let replacementLockBefore = try {
                    String.fromUtf8(File.readFrom(replacementHome.join("gateway-serve.lock")))
                } catch (_: Exception) {
                    ""
                }
                let replacementIdentity = gatewayParseServeIdentity(replacementLockBefore).getOrThrow()
                @Expect(replacementIdentity.pid, replacementPid)
                @Expect(replacementIdentity.processIdentity.isSome(), true)
                @Expect(replacementGatewayIdentity.getOrThrow().matches(replacementIdentity), true)
                @Expect(replacementIdentity.matches(oldIdentity), false)
                let stale = gatewayTryTerminateServeProcess(oldGatewayPid)
                @Expect(stale.ok, false)
                @Expect(stale.status, "stale_identity")
                @Expect(gatewayServeStopPidAlive(replacementPid), true)
                @Expect(gatewayServeStopPidAlive(replacementBrokerPid), true)
                @Expect(gatewayServeStopPidAlive(replacementRootPid), true)
                @Expect(gatewayServeStopPidAlive(replacementChildPid), true)
                @Expect(gatewayServeStopPortListening(replacementGatewayPort), true)
                @Expect(gatewayServeStopPortListening(replacementPluginPort), true)
                @Expect(gatewayServeStopPortListening(replacementDescendantPort), true)
                let replacementLockAfterStale = try {
                    String.fromUtf8(File.readFrom(replacementHome.join("gateway-serve.lock")))
                } catch (_: Exception) {
                    ""
                }
                @Expect(gatewayParseServeIdentity(replacementLockAfterStale).getOrThrow().matches(replacementIdentity), true)
                @Expect(gatewayExecuteStopServe(), 0)
                let replacementCompletion = try {
                    String.fromUtf8(File.readFrom(replacementHome.join("gateway-serve.stop-complete")))
                } catch (_: Exception) {
                    ""
                }
                @Expect(gatewayParseServeIdentity(replacementCompletion).getOrThrow().matches(replacementIdentity), true)
                @Expect(gatewayServeStopCompletionField(replacementCompletion, "status"), "graceful")
                @Expect(gatewayServeStopCompletionField(replacementCompletion, "fullTerminal"), "1")
                let replacementGatewayReaped = gatewayServeStopReapCompletedOwnedProcess(replacementProcess)
                @Expect(replacementGatewayReaped, true)
                if (replacementGatewayReaped) { replacementProcess = None<SubProcess> }
                @Expect(gatewayServeStopWaitUntil(10000, { =>
                    replacementGatewayReaped && !gatewayServeStopPidAlive(stoppedReplacementBrokerPid) &&
                        !gatewayServeStopPidAlive(stoppedReplacementRootPid) && !gatewayServeStopPidAlive(stoppedReplacementChildPid) &&
                        !gatewayServeStopPortListening(replacementGatewayPort) &&
                        !gatewayServeStopPortListening(replacementPluginPort) &&
                        !gatewayServeStopPortListening(replacementDescendantPort)
                }), true)
            } finally {
                setGatewayStopOutputForTest(None<(String) -> Unit>)
                if (replacementGatewayIdentity.isSome()) {
                    try { gatewayServeStopReapOwnedGateway(replacementGatewayIdentity, binary, replacementHome) } catch (_: Exception) { () }
                }
                try { gatewayServeStopReapOwnedHandle(replacementProcess, binary) } catch (_: Exception) { () }
                if (oldGatewayIdentity.isSome()) {
                    try { gatewayServeStopReapOwnedGateway(oldGatewayIdentity, binary, replacementHome) } catch (_: Exception) { () }
                }
                try { gatewayServeStopReapOwnedHandle(oldProcess, binary) } catch (_: Exception) { () }
                if (ignoreGatewayIdentity.isSome()) {
                    try { gatewayServeStopReapOwnedGateway(ignoreGatewayIdentity, binary, ignoreHome) } catch (_: Exception) { () }
                }
                try { gatewayServeStopReapOwnedHandle(ignoreProcess, binary) } catch (_: Exception) { () }
                let replacementGatewaySettled = try { gatewayServeStopWaitOwnedProcess(replacementProcess) } catch (_: Exception) { false }
                let oldGatewaySettled = try { gatewayServeStopWaitOwnedProcess(oldProcess) } catch (_: Exception) { false }
                let ignoreGatewaySettled = try { gatewayServeStopWaitOwnedProcess(ignoreProcess) } catch (_: Exception) { false }
                let capturedReplacementBrokerPid = replacementBrokerPid
                let capturedOldBrokerPid = oldBrokerPid
                let capturedIgnoreBrokerPid = ignoreBrokerPid
                let replacementBrokerGone = try {
                    replacementResources.brokerCaptured && gatewayServeStopWaitUntil(
                        3000,
                        { => !gatewayServeStopPidAlive(capturedReplacementBrokerPid) }
                    )
                } catch (_: Exception) {
                    false
                }
                let oldBrokerGone = try {
                    oldResources.brokerCaptured && gatewayServeStopWaitUntil(
                        3000,
                        { => !gatewayServeStopPidAlive(capturedOldBrokerPid) }
                    )
                } catch (_: Exception) {
                    false
                }
                let ignoreBrokerGone = try {
                    ignoreResources.brokerCaptured && gatewayServeStopWaitUntil(
                        3000,
                        { => !gatewayServeStopPidAlive(capturedIgnoreBrokerPid) }
                    )
                } catch (_: Exception) {
                    false
                }
                try {
                    gatewayServeStopReapOwnedFixtureGroup(
                        replacementPgid,
                        replacementRootPid,
                        replacementChildPid,
                        replacementHome.join("metis-gateway-stop-fake-service-plugin.mjs")
                    )
                } catch (_: Exception) { () }
                try {
                    gatewayServeStopReapOwnedFixtureGroup(
                        oldPgid,
                        oldRootPid,
                        oldChildPid,
                        replacementHome.join("metis-gateway-stop-fake-service-plugin.mjs")
                    )
                } catch (_: Exception) { () }
                try {
                    gatewayServeStopReapOwnedFixtureGroup(
                        ignorePgid,
                        ignoreRootPid,
                        ignoreChildPid,
                        ignoreHome.join("metis-gateway-stop-fake-service-plugin.mjs")
                    )
                } catch (_: Exception) { () }
                let replacementGroupGone = try {
                    replacementResources.fixtureCaptured && gatewayServeStopGroupGone(replacementPgid)
                } catch (_: Exception) { false }
                let oldGroupGone = try {
                    oldResources.fixtureCaptured && gatewayServeStopGroupGone(oldPgid)
                } catch (_: Exception) { false }
                let ignoreGroupGone = try {
                    ignoreResources.fixtureCaptured && gatewayServeStopGroupGone(ignorePgid)
                } catch (_: Exception) { false }
                let replacementBrokerStatus = replacementResources.brokerTerminalStatus()
                let oldBrokerStatus = oldResources.brokerTerminalStatus()
                let ignoreBrokerStatus = ignoreResources.brokerTerminalStatus()
                let replacementFixtureStatus = replacementResources.fixtureTerminalStatus()
                let oldFixtureStatus = oldResources.fixtureTerminalStatus()
                let ignoreFixtureStatus = ignoreResources.fixtureTerminalStatus()
                try { let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000) } catch (_: Exception) { () }
                match (oldHome) {
                    case Some(value) => setVariable("METIS_HOME", value)
                    case None => setVariable("METIS_HOME", "")
                }
                match (oldRoot) {
                    case Some(value) => setVariable("METIS_CJPM_ROOT", value)
                    case None => setVariable("METIS_CJPM_ROOT", "")
                }
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                try { remove(ignoreHome, recursive: true) } catch (_: Exception) { () }
                try { remove(replacementHome, recursive: true) } catch (_: Exception) { () }
                @Expect(replacementGatewaySettled, true)
                @Expect(oldGatewaySettled, true)
                @Expect(ignoreGatewaySettled, true)
                @Expect(replacementBrokerGone, true)
                @Expect(oldBrokerGone, true)
                @Expect(ignoreBrokerGone, true)
                @Expect(replacementGroupGone, true)
                @Expect(oldGroupGone, true)
                @Expect(ignoreGroupGone, true)
                @Expect(replacementBrokerStatus, "gone")
                @Expect(oldBrokerStatus, "gone")
                @Expect(ignoreBrokerStatus, "gone")
                @Expect(replacementFixtureStatus, "gone")
                @Expect(oldFixtureStatus, "gone")
                @Expect(ignoreFixtureStatus, "gone")
            }
        }
    }
}
