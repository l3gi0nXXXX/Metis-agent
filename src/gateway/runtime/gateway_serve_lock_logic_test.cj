package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, GatewayServicePluginUserSettings, MetisConfigManager, MetisProcessEnvironmentLock, cliProviderApiKeyEnvAliases, cliProviderBaseUrlEnvAliases}
import metis.gateway.process.{gatewayStdioBrokerReady, gatewayStdioBrokerSnapshot}
import metis.gateway.service_plugin.loadServicePluginManifest
import metis.gateway.core.GatewayStopResult
import metis.gateway.channels.qq.QQAdapter
import metis.gateway.channels.telegram.TelegramTransport
import metis.gateway.model.QQConfig
import magic.utils.http.HttpUtils
import magic.config.Config
import metis.gateway.logging.gatewayLoggingResetForTest
import metis.process.{ProcessInstanceIdentity, currentProcessInstanceIdentity, managedStdioBroker, managedStdioResolveBrokerScriptPath, probeProcessInstance, processInstanceKillSignal, processInstanceTermSignal, resetManagedStdioBrokerForTest, shutdownManagedStdioBroker, signalProcessInstance}
import metis.utils.{InfoUtils, ShellTimeoutException}
import std.collection.{ArrayList, HashMap, HashSet}
import std.convert.Parsable
import std.core.Duration
import std.env.{getProcessId, getVariable, removeVariable, setVariable}
import std.fs.{Directory, File, FileInfo, OpenMode, Path, SymbolicLink, exists, remove}
import std.net.*
import std.process.{ProcessRedirect, SubProcess, executeWithOutput, launch}
import std.sync.AtomicInt64
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}
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

private func gatewayServeStaleProcessIdentity(current: ProcessInstanceIdentity): ProcessInstanceIdentity {
    ProcessInstanceIdentity(
        current.platform,
        current.pid,
        value0: current.value0,
        value1: current.value1,
        value2: current.value2,
        value3: current.value3,
        value4: current.value4,
        value5: current.value5,
        value6: current.value6,
        value7: current.value7,
        value8: current.value8,
        value9: current.value9 + 1
    )
}

private func gatewayServeHistoricalCleanupResult(leaseStatus!: String = "stopped"): GatewayStopResult {
    GatewayStopResult(
        false,
        "cleanup_pending",
        inboundStatus: "stopped",
        compatStatus: "stopped",
        sidecarStatus: "disabled",
        servicePluginIngressStatus: "sent",
        servicePluginDispatchStatus: "cleanup_pending",
        servicePluginOwnerStatus: "force_terminated",
        servicePluginLeaseStatus: leaseStatus,
        servicePluginPortStatus: "released",
        servicePluginPendingCount: 1,
        channelsStatus: "stopped",
        brokerStatus: "stopped"
    )
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

private class GatewayHeartbeatCommandProbeResult {
    let status: String

    init(status: String) {
        this.status = status
    }
}

private func gatewayHeartbeatProbeGatewayCommand(pid: Int64, expectedBinary: Path): GatewayHeartbeatCommandProbeResult {
    if (pid <= 1) { return GatewayHeartbeatCommandProbeResult("unavailable") }
    let result = executeWithOutput("/bin/ps", ["-o", "command=", "-p", "${pid}"])
    if (result[0] != 0) { return GatewayHeartbeatCommandProbeResult("unavailable") }
    let command = try {
        String.fromUtf8(result[1]).trimAscii()
    } catch (_: Exception) {
        return GatewayHeartbeatCommandProbeResult("unavailable")
    }
    if (command.isEmpty()) { return GatewayHeartbeatCommandProbeResult("unavailable") }
    if (command.contains(expectedBinary.toString()) && command.contains("gateway run")) {
        GatewayHeartbeatCommandProbeResult("match")
    } else {
        GatewayHeartbeatCommandProbeResult("mismatch")
    }
}

private class GatewayHeartbeatIdentityCaptureResult {
    let identity: Option<GatewayServeIdentity>
    let status: String
    let attempts: Int64
    let unavailableCount: Int64
    let lockSeen: Bool

    init(
        identity: Option<GatewayServeIdentity>,
        status: String,
        attempts: Int64,
        unavailableCount: Int64,
        lockSeen: Bool
    ) {
        this.identity = identity
        this.status = status
        this.attempts = attempts
        this.unavailableCount = unavailableCount
        this.lockSeen = lockSeen
    }
}

private func gatewayHeartbeatCaptureOwnedIdentityDetailed(
    home: Path,
    process: SubProcess,
    expectedBinary: Path,
    timeoutMs: Int64
): GatewayHeartbeatIdentityCaptureResult {
    let deadline = MonoTime.now() + Duration.millisecond * max(1, timeoutMs)
    var attempts: Int64 = 0
    var unavailableCount: Int64 = 0
    var lockSeen = false
    var sawInvalidLock = false
    while (MonoTime.now() < deadline) {
        attempts += 1
        if (!process.isAlive()) {
            return GatewayHeartbeatIdentityCaptureResult(
                None<GatewayServeIdentity>, "process_exited", attempts, unavailableCount, lockSeen)
        }
        let lockPath = home.join("gateway-serve.lock")
        if (exists(lockPath)) {
            lockSeen = true
            let identity = try {
                gatewayParseServeIdentity(String.fromUtf8(File.readFrom(lockPath)))
            } catch (_: Exception) {
                None<GatewayServeIdentity>
            }
            match (identity) {
                case Some(value) =>
                    if (value.pid != process.pid || !value.processIdentity.isSome()) {
                        return GatewayHeartbeatIdentityCaptureResult(
                            None<GatewayServeIdentity>, "identity_mismatch", attempts, unavailableCount, lockSeen)
                    }
                    let alive = probeProcessInstance(value.processIdentity.getOrThrow(), deadline)
                    if (alive.conclusive && !alive.alive) {
                        return GatewayHeartbeatIdentityCaptureResult(
                            None<GatewayServeIdentity>, "process_exited", attempts, unavailableCount, lockSeen)
                    }
                    if (alive.conclusive && alive.alive) {
                        let command = gatewayHeartbeatProbeGatewayCommand(process.pid, expectedBinary)
                        if (command.status == "unavailable") { unavailableCount += 1 }
                        if (command.status == "match") {
                            return GatewayHeartbeatIdentityCaptureResult(
                                Some(value), "captured", attempts, unavailableCount, lockSeen)
                        }
                        if (command.status == "mismatch") {
                            return GatewayHeartbeatIdentityCaptureResult(
                                None<GatewayServeIdentity>, "command_mismatch", attempts, unavailableCount, lockSeen)
                        }
                    }
                case None =>
                    sawInvalidLock = true
            }
        }
        sleep(Duration.millisecond * 20)
    }
    GatewayHeartbeatIdentityCaptureResult(
        None<GatewayServeIdentity>, if (sawInvalidLock) { "lock_invalid" } else { "capture_timeout" },
        attempts, unavailableCount, lockSeen)
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

private func gatewayHeartbeatRuntimeInt(path: Path, key: String): Int64 {
    if (!exists(path)) { return 0 }
    try {
        JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
            .get(key).getOrThrow().asInt().getValue()
    } catch (_: Exception) {
        0
    }
}

private func gatewayHeartbeatHttpStatus(url: String): Int64 {
    let builder = ClientBuilder()
    builder.readTimeout(Duration.millisecond * 500)
    let client = builder.build()
    try {
        Int64(client.send(HttpRequestBuilder().url(url).get().build()).status)
    } catch (_: Exception) {
        0
    } finally {
        client.close()
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

private class GatewayS5P1Capture {
    var brokerPid: Int64 = 0
    var gcmPid: Int64 = 0
    var gcmPgid: Int64 = 0
    var leasePath = Path("")
    var leaseDirExists: Bool = false
    var leaseFileCount: Int64 = 0
    var leaseUtf8: Bool = false
    var leaseJson: Bool = false
    var leaseIdentityMatches: Bool = false
    var leasePidMatches: Bool = false
    var leasePortMatches: Bool = false
    var leaseRunning: Bool = false
    var leaseStopped: Bool = false

    func refreshLease(home: Path, expectedPid: Int64, expectedParentPid: Int64, expectedPort: Int64): Unit {
        let dir = home.join("service-plugin").join("runtime").join("gitcode-monitor")
        this.leaseDirExists = exists(dir)
        this.leaseFileCount = 0
        this.leaseUtf8 = false
        this.leaseJson = false
        this.leaseIdentityMatches = false
        this.leasePidMatches = false
        this.leasePortMatches = false
        this.leaseRunning = false
        this.leaseStopped = false
        if (this.leaseDirExists) {
            try {
                for (entry in Directory.readFrom(dir)) {
                    if (entry.isRegular() && entry.name.endsWith(".lease.json")) { this.leaseFileCount++ }
                }
            } catch (_: Exception) { () }
        }
        this.leasePath = gatewayS5FindLease(home)
        if (this.leasePath.toString().isEmpty()) { return }
        let text = try {
            let decoded = String.fromUtf8(File.readFrom(this.leasePath))
            this.leaseUtf8 = true
            decoded
        } catch (_: Exception) {
            return
        }
        let root = try {
            let decoded = JsonValue.fromStr(text).asObject()
            this.leaseJson = true
            decoded
        } catch (_: Exception) {
            return
        }
        let pluginId = try { root.get("pluginId").getOrThrow().asString().getValue() } catch (_: Exception) { "" }
        let sessionId = try { root.get("sessionId").getOrThrow().asString().getValue() } catch (_: Exception) { "" }
        let parentPid = try { root.get("parentPid").getOrThrow().asInt().getValue() } catch (_: Exception) { 0 }
        let pid = try { root.get("pid").getOrThrow().asInt().getValue() } catch (_: Exception) { 0 }
        let port = try { root.get("port").getOrThrow().asInt().getValue() } catch (_: Exception) { 0 }
        let state = try { root.get("state").getOrThrow().asString().getValue() } catch (_: Exception) { "" }
        this.leaseIdentityMatches = pluginId == "gitcode-monitor" && !sessionId.isEmpty() && parentPid == expectedParentPid
        this.leasePidMatches = pid == expectedPid
        this.leasePortMatches = port == expectedPort
        this.leaseRunning = state == "running"
        this.leaseStopped = state == "stopped"
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

private class GatewayS5DependencyProcess {
    let process: SubProcess
    let port: Int64
    let eventsPath: Path

    init(process: SubProcess, port: Int64, eventsPath: Path) {
        this.process = process
        this.port = port
        this.eventsPath = eventsPath
    }
}

private func gatewayS5GcmRoot(): Path {
    Path(getVariable("METIS_S5_GCM_ROOT").getOrDefault { "" }.trimAscii())
}

private func gatewayS5GcmBinary(): Path {
    gatewayS5GcmRoot().join("target").join("release").join("bin").join("gitcodemonitor")
}

private func gatewayFormalMetisBinary(project: Path): Option<Path> {
    let configured = getVariable("METIS_TEST_BIN").getOrDefault { "" }.trimAscii()
    if (configured.isEmpty()) {
        return Some(project.join("target").join("release").join("bin").join("metis"))
    }
    let candidate = Path(configured)
    if (!candidate.isAbsolute() || !exists(candidate)) { return None<Path> }
    try {
        for (entry in Directory.readFrom(candidate.parent)) {
            if (entry.path.toString() == candidate.toString()) {
                return if (entry.isRegular()) { Some(candidate) } else { None<Path> }
            }
        }
    } catch (_: Exception) {
        return None<Path>
    }
    None<Path>
}

private func gatewayS5HeapEnvironmentMatches(expected: Option<String>): Bool {
    match ((expected, getVariable("cjHeapSize"))) {
        case (Some(want), Some(actual)) => want == actual
        case (None, None) => true
        case _ => false
    }
}

private func gatewayS5LaunchGateway(binary: Path): SubProcess {
    let oldHeap = getVariable("cjHeapSize")
    setVariable("cjHeapSize", "2GB")
    try {
        launch(
            binary.toString(),
            ["gateway", "run"],
            stdIn: ProcessRedirect.Discard,
            stdOut: ProcessRedirect.Discard,
            stdErr: ProcessRedirect.Discard
        )
    } finally {
        match (oldHeap) {
            case Some(value) => setVariable("cjHeapSize", value)
            case None => removeVariable("cjHeapSize")
        }
    }
}

private func gatewayS5StartDependencies(
    home: Path,
    script: Path,
    replyMarker!: String = "s5-p1-exact-once",
    processorEntered!: Option<Path> = None<Path>,
    processorRelease!: Option<Path> = None<Path>,
    modelEntered!: Option<Path> = None<Path>,
    modelRelease!: Option<Path> = None<Path>,
    modelMetrics!: Option<Path> = None<Path>
): GatewayS5DependencyProcess {
    let readyPath = home.join("s5-dependencies.ready.json")
    let eventsPath = home.join("s5-dependencies.events.jsonl")
    let args = ArrayList<String>()
    args.add("node")
    args.add(script.toString())
    args.add(readyPath.toString())
    args.add(eventsPath.toString())
    args.add(replyMarker)
    match ((processorEntered, processorRelease)) {
        case (Some(entered), Some(release)) =>
            args.add(entered.toString())
            args.add(release.toString())
        case _ => ()
    }
    match ((modelEntered, modelRelease, modelMetrics)) {
        case (Some(entered), Some(release), Some(metrics)) =>
            if (args.size == 5) {
                args.add("")
                args.add("")
            }
            args.add(entered.toString())
            args.add(release.toString())
            args.add(metrics.toString())
        case _ => ()
    }
    let process = launch(
        "/usr/bin/env",
        args.toArray(),
        stdIn: ProcessRedirect.Discard,
        stdOut: ProcessRedirect.Discard,
        stdErr: ProcessRedirect.Discard
    )
    let ready = gatewayServeStopWaitUntil(5000, { => exists(readyPath) })
    let port = if (ready) {
        try {
            JsonValue.fromStr(String.fromUtf8(File.readFrom(readyPath))).asObject()
                .get("port").getOrThrow().asInt().getValue()
        } catch (_: Exception) {
            0
        }
    } else {
        0
    }
    GatewayS5DependencyProcess(process, port, eventsPath)
}

private func gatewayS5StopDependencies(dependencies: Option<GatewayS5DependencyProcess>): Bool {
    match (dependencies) {
        case Some(value) =>
            if (value.process.isAlive()) {
                try { value.process.terminate(force: false) } catch (_: Exception) { () }
            }
            try {
                let _ = value.process.wait(timeout: Some(Duration.second * 2))
                true
            } catch (_: Exception) {
                if (value.process.isAlive()) {
                    try { value.process.terminate(force: true) } catch (_: Exception) { () }
                }
                try {
                    let _ = value.process.wait(timeout: Some(Duration.second * 2))
                    true
                } catch (_: Exception) {
                    false
                }
            }
        case None => true
    }
}

private func gatewayS5WriteGcmManifest(path: Path, binary: Path): Unit {
    File.writeTo(
        path,
        ("{" +
            "\"schema\":\"metis.servicePlugin.v1\",\"pluginId\":\"gitcode-monitor\",\"displayName\":\"GitCode Monitor S5\"," +
            "\"kind\":\"service\",\"protocolVersion\":\"1.0\"," +
            "\"entry\":{\"command\":\"${binary.toString()}\",\"args\":[\"plugin-stdio\"]}," +
            "\"configSchema\":{\"type\":\"object\"}," +
            "\"capabilityDeclarations\":[" +
                "{\"capabilityId\":\"gitcode.monitor.status\",\"kind\":\"controlAction\"}," +
                "{\"capabilityId\":\"gitcode.event.accepted\",\"kind\":\"event\"}," +
                "{\"capabilityId\":\"gitcode.writeback.apply_result\",\"kind\":\"controlAction\"}" +
            "]}").toArray()
    )
}

private func gatewayS5WriteBlockedGcmManifest(path: Path, wrapper: Path, binary: Path): Unit {
    File.writeTo(
        path,
        ("{" +
            "\"schema\":\"metis.servicePlugin.v1\",\"pluginId\":\"gitcode-monitor\",\"displayName\":\"GitCode Monitor S5 N1\"," +
            "\"kind\":\"service\",\"protocolVersion\":\"1.0\"," +
            "\"entry\":{\"command\":\"${wrapper.toString()}\",\"args\":[\"${binary.toString()}\",\"plugin-stdio\"]}," +
            "\"configSchema\":{\"type\":\"object\"}," +
            "\"capabilityDeclarations\":[" +
                "{\"capabilityId\":\"gitcode.monitor.status\",\"kind\":\"controlAction\"}," +
                "{\"capabilityId\":\"gitcode.event.accepted\",\"kind\":\"event\"}," +
                "{\"capabilityId\":\"gitcode.writeback.apply_result\",\"kind\":\"controlAction\"}" +
            "]}").toArray()
    )
}

private func gatewayS5WriteGcmConfig(
    path: Path,
    statePath: Path,
    queuePath: Path,
    webhookPort: Int64,
    dependencyPort: Int64,
    liveWriteback!: Bool = false
): Unit {
    File.writeTo(
        path,
        ("{" +
            "\"monitor\":{\"fullScanIntervalMinutes\":10,\"dryRun\":${if (liveWriteback) { "false" } else { "true" }}," +
                "\"autoReply\":${if (liveWriteback) { "true" } else { "false" }}," +
                "\"writebackScope\":{\"allowedRepos\":[\"cangjie/compiler\"]},\"statePath\":\"${statePath.toString()}\"}," +
            "\"gitcode\":{\"baseUrl\":\"http://127.0.0.1:${dependencyPort}/api/v5\",\"token\":\"fake-s5-gitcode-token\",\"webhook\":{" +
                "\"enabled\":true,\"bindHost\":\"127.0.0.1\",\"port\":${webhookPort},\"queueDir\":\"${queuePath.toString()}\"," +
                "\"processor\":{\"enabled\":true,\"maxBatchSize\":4}," +
                "\"endpoints\":[{\"id\":\"main\",\"path\":\"/webhooks/gitcode/main\",\"token\":\"fake-s5-webhook-token\",\"allowedEvents\":[\"Issue Hook\"]}]" +
            "}}}").toArray()
    )
}

private func gatewayS5WriteSubscription(home: Path, includeFeishu!: Bool = false): Unit {
    let path = home.join("service-plugin").join("gitcode").join("subscriptions.jsonl")
    Directory.create(path.parent, recursive: true)
    File.writeTo(
        path,
        ("{\"channel\":\"telegram\",\"accountId\":\"default\",\"peerId\":\"8734062810\",\"threadId\":\"\",\"rawEvents\":true,\"generatedReplies\":true,\"active\":true}\n" +
            if (includeFeishu) {
                "{\"channel\":\"feishu\",\"accountId\":\"default\",\"peerId\":\"oc_s5_p1\",\"threadId\":\"\",\"rawEvents\":true,\"generatedReplies\":true,\"active\":true}\n"
            } else { "" }).toArray()
    )
}

private func gatewayS5ConfigureFormalGateway(
    home: Path,
    gatewayPort: Int64,
    webhookPort: Int64,
    dependencyPort: Int64,
    binary: Path,
    liveWriteback!: Bool = false,
    includeFeishu!: Bool = false,
    feishuPort!: Int64 = 0
): (Path, Path, Path, Path) {
    let manifestPath = home.join("gcm-s5.manifest.json")
    let configPath = home.join("gcm-s5.config.json")
    let statePath = home.join("gcm-s5.state.json")
    let queuePath = home.join("gcm-s5.queue")
    gatewayS5WriteGcmManifest(manifestPath, binary)
    gatewayS5WriteGcmConfig(configPath, statePath, queuePath, webhookPort, dependencyPort, liveWriteback: liveWriteback)
    gatewayS5WriteSubscription(home, includeFeishu: includeFeishu)

    var settings = CliSettingManager.readGatewaySettings()
    settings.enabled = true
    settings.port = gatewayPort
    settings.cronEnabled = false
    settings.logging.file = home.join("s5-gateway.log").toString()
    settings.logging.level = "info"
    var telegram = settings.telegram
    telegram.enabled = true
    telegram.botToken = "123456:FAKE-S5"
    telegram.dmPolicy = "open"
    telegram.allowFrom = ["*"]
    telegram.apiRoot = "http://127.0.0.1:${dependencyPort}"
    telegram.timeoutSeconds = 1
    telegram.commandsNative = "off"
    var network = telegram.network
    network.dangerouslyAllowPrivateNetwork = true
    telegram.network = network
    settings.telegram = telegram
    settings.feishu.enabled = includeFeishu
    if (includeFeishu) {
        settings.feishu.appId = "fake-s5-feishu-app"
        settings.feishu.appSecret = "fake-s5-feishu-secret"
        settings.feishu.domain = "http://127.0.0.1:${feishuPort}"
        settings.feishu.receiveMode = "webhook"
    }
    settings.qq.enabled = false
    settings.channelModels["telegram"] = "openai:gpt-5.4"
    settings.channelModels["feishu"] = "openai:gpt-5.4"
    var plugin = GatewayServicePluginUserSettings()
    plugin.pluginId = "gitcode-monitor"
    plugin.enabled = true
    plugin.autostart = true
    plugin.startupTimeoutMs = 10000
    plugin.manifestPath = manifestPath.toString()
    plugin.configRef = configPath.toString()
    settings.servicePlugins = [plugin]
    let _ = MetisConfigManager.setGatewaySettings(settings)
    let _ = MetisConfigManager.setPrimaryModelRef("openai:gpt-5.4")
    let _ = MetisConfigManager.setProviderApiKey("openai", "fake-s5-openai-key")
    let _ = MetisConfigManager.setProviderBaseUrl("openai", "http://127.0.0.1:${dependencyPort}/v1")
    CliSettingManager.invalidate()
    (statePath, queuePath, manifestPath, configPath)
}

private func gatewayS5PostWebhook(port: Int64, deliveryId: String, iid!: Int64 = 7001): Int64 {
    let body = "{" +
        "\"object_kind\":\"issue\",\"project\":{\"path_with_namespace\":\"cangjie/compiler\"}," +
        "\"object_attributes\":{\"iid\":${iid},\"action\":\"open\",\"title\":\"S5 正式链路 中文🙂 ${deliveryId}\",\"description\":\"cross project\",\"url\":\"https://gitcode.com/cangjie/compiler/issues/${iid}\"}," +
        "\"user\":{\"name\":\"alice\",\"username\":\"alice\"}}"
    let builder = ClientBuilder()
    builder.readTimeout(Duration.second)
    let client = builder.build()
    try {
        let response = client.send(
            HttpRequestBuilder()
                .url("http://127.0.0.1:${port}/webhooks/gitcode/main")
                .post()
                .header("content-type", "application/json")
                .header("x-gitcode-token", "fake-s5-webhook-token")
                .header("x-gitcode-event", "Issue Hook")
                .header("x-gitcode-delivery", deliveryId)
                .body(body)
                .build()
        )
        Int64(response.status)
    } catch (_: Exception) {
        0
    } finally {
        client.close()
    }
}

private func gatewayS5EventCount(path: Path, kind: String): Int64 {
    if (!exists(path)) { return 0 }
    let text = try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { return -1 }
    var count: Int64 = 0
    for (line in text.split("\n")) {
        if (line.contains("\"kind\":\"${kind}\"")) { count++ }
    }
    count
}

private func gatewayS5EventCount(path: Path, kind: String, fragment: String): Int64 {
    if (!exists(path)) { return 0 }
    let text = try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { return -1 }
    var count: Int64 = 0
    for (line in text.split("\n")) {
        if (line.contains("\"kind\":\"${kind}\"") && line.contains(fragment)) { count++ }
    }
    count
}

private func gatewayS5FileContains(path: Path, fragment: String): Bool {
    if (path.toString().isEmpty()) { return false }
    if (!exists(path)) { return false }
    try { String.fromUtf8(File.readFrom(path)).contains(fragment) } catch (_: Exception) { false }
}

private func gatewayS5JsonInt(path: Path, key: String): Int64 {
    if (!exists(path)) { return 0 }
    try {
        JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
            .get(key).getOrThrow().asInt().getValue()
    } catch (_: Exception) {
        0
    }
}

private func gatewayS5JsonString(path: Path, key: String): String {
    if (!exists(path)) { return "" }
    try {
        JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
            .get(key).getOrThrow().asString().getValue()
    } catch (_: Exception) {
        ""
    }
}

private class GatewayHeartbeatBrokerDiagnostic {
    var valid: Bool = false
    var parseStatus: String = "missing"
    var generation: Int64 = 0
    var brokerPid: Int64 = 0
    var startParentPid: Int64 = 0
    var observedParentPid: Int64 = 0
    var sequence: Int64 = 0
    var closeEntryCount: Int64 = 0
    var closeEntryOwnerCount: Int64 = -1
    var ownerTerminalCount: Int64 = 0
    var ownerStartCount: Int64 = 0
    var classifiedOwnerTerminalCount: Int64 = 0
    var servicePluginStarts: Int64 = 0
    var pidProbeStarts: Int64 = 0
    var lsofProbeStarts: Int64 = 0
    var otherStarts: Int64 = 0
    var servicePluginTerminals: Int64 = 0
    var pidProbeTerminals: Int64 = 0
    var lsofProbeTerminals: Int64 = 0
    var otherTerminals: Int64 = 0
    var brokerClosedCallbackCount: Int64 = 0
    var brokerClosedEnqueuedCount: Int64 = 0
    var closeAckCallbackSeen: Bool = false
    var writerFailureKind: String = ""
    var writerFailurePhase: String = ""
    var ownerCount: Int64 = -1
    var exitScheduledCount: Int64 = 0
    var lastExitScheduledCode: Int64 = -1
    var firstEventBrokerStarted: Bool = false
    var filenameMatches: Bool = false

    init(path: Path, fileName!: String = "") {
        if (!exists(path)) { return }
        let text = try {
            String.fromUtf8(File.readFrom(path))
        } catch (_: Exception) {
            this.parseStatus = "invalid_utf8"
            return
        }
        let root = try {
            JsonValue.fromStr(text).asObject()
        } catch (_: Exception) {
            this.parseStatus = "malformed_json"
            return
        }
        try {
            if (root.get("protocolVersion").getOrThrow().asString().getValue() != "1.0") {
                this.parseStatus = "protocol_mismatch"
                return
            }
            this.generation = root.get("generation").getOrThrow().asInt().getValue()
            this.brokerPid = root.get("brokerPid").getOrThrow().asInt().getValue()
            this.startParentPid = root.get("startParentPid").getOrThrow().asInt().getValue()
            this.observedParentPid = root.get("observedParentPid").getOrThrow().asInt().getValue()
            this.sequence = root.get("sequence").getOrThrow().asInt().getValue()
            this.closeEntryCount = root.get("closeEntryCount").getOrThrow().asInt().getValue()
            this.closeEntryOwnerCount = root.get("closeEntryOwnerCount").getOrThrow().asInt().getValue()
            this.ownerTerminalCount = root.get("ownerTerminalCount").getOrThrow().asInt().getValue()
            let ownerStarts = root.get("ownerStartCounts").getOrThrow().asObject()
            let ownerTerminals = root.get("ownerTerminalCounts").getOrThrow().asObject()
            this.servicePluginStarts = ownerStarts.get("service_plugin").getOrThrow().asInt().getValue()
            this.pidProbeStarts = ownerStarts.get("pid_probe").getOrThrow().asInt().getValue()
            this.lsofProbeStarts = ownerStarts.get("lsof_probe").getOrThrow().asInt().getValue()
            this.otherStarts = ownerStarts.get("other").getOrThrow().asInt().getValue()
            this.servicePluginTerminals = ownerTerminals.get("service_plugin").getOrThrow().asInt().getValue()
            this.pidProbeTerminals = ownerTerminals.get("pid_probe").getOrThrow().asInt().getValue()
            this.lsofProbeTerminals = ownerTerminals.get("lsof_probe").getOrThrow().asInt().getValue()
            this.otherTerminals = ownerTerminals.get("other").getOrThrow().asInt().getValue()
            this.ownerStartCount = this.servicePluginStarts + this.pidProbeStarts +
                this.lsofProbeStarts + this.otherStarts
            this.classifiedOwnerTerminalCount = this.servicePluginTerminals + this.pidProbeTerminals +
                this.lsofProbeTerminals + this.otherTerminals
            this.brokerClosedCallbackCount = root.get("brokerClosedCallbackCount").getOrThrow().asInt().getValue()
            this.brokerClosedEnqueuedCount = root.get("brokerClosedEnqueuedCount").getOrThrow().asInt().getValue()
            this.closeAckCallbackSeen = root.get("closeAckCallbackSeen").getOrThrow().asBool().getValue()
            this.writerFailureKind = root.get("writerFailureKind").getOrThrow().asString().getValue()
            this.writerFailurePhase = root.get("writerFailurePhase").getOrThrow().asString().getValue()
            this.ownerCount = root.get("ownerCount").getOrThrow().asInt().getValue()
            this.exitScheduledCount = root.get("exitScheduledCount").getOrThrow().asInt().getValue()
            this.lastExitScheduledCode = root.get("lastExitScheduledCode").getOrThrow().asInt().getValue()
            let events = root.get("events").getOrThrow().asArray()
            if (events.size() > 0) {
                this.firstEventBrokerStarted = events[0].asObject().get("event").getOrThrow()
                    .asString().getValue() == "broker_started"
            }
            let kindValid = this.writerFailureKind.isEmpty() || this.writerFailureKind == "output_error" ||
                this.writerFailureKind == "callback_error" || this.writerFailureKind == "queue_capacity" ||
                this.writerFailureKind == "write_exception"
            let phaseValid = this.writerFailurePhase.isEmpty() || this.writerFailurePhase == "broker_closed" ||
                this.writerFailurePhase == "owner_terminal" || this.writerFailurePhase == "other"
            this.valid = this.generation > 0 && this.brokerPid > 1 && this.startParentPid > 1 &&
                this.observedParentPid >= 1 &&
                this.sequence > 0 && this.firstEventBrokerStarted && kindValid && phaseValid &&
                this.classifiedOwnerTerminalCount == this.ownerTerminalCount
            this.parseStatus = if (this.valid) { "schema_valid" } else { "invalid_field" }
            this.filenameMatches = fileName == "broker-g${this.generation}-p${this.brokerPid}.json"
        } catch (_: Exception) {
            this.valid = false
            this.parseStatus = "invalid_field"
        }
    }

    func parentStatus(expectedParentPid: Int64): String {
        if (!this.valid || this.startParentPid != expectedParentPid) { return "unexpected_parent" }
        if (this.observedParentPid == expectedParentPid) { return "original_parent" }
        if (this.observedParentPid == 1) { return "reparented" }
        "unexpected_parent"
    }

    func safeSummary(role: String, expectedParentPid: Int64): String {
        "role=${role} parse=${this.parseStatus} filename=${this.filenameMatches} " +
            "first=${this.firstEventBrokerStarted} parent=${this.parentStatus(expectedParentPid)} " +
            "generation=${this.generation} sequence=${this.sequence} " +
            "starts=${this.servicePluginStarts}/${this.pidProbeStarts}/${this.lsofProbeStarts}/${this.otherStarts} " +
            "terminals=${this.servicePluginTerminals}/${this.pidProbeTerminals}/${this.lsofProbeTerminals}/${this.otherTerminals} " +
            "terminalMatch=${this.classifiedOwnerTerminalCount == this.ownerTerminalCount} " +
            "close=${this.closeEntryCount}/${this.closeEntryOwnerCount} " +
            "closed=${this.brokerClosedEnqueuedCount}/${this.brokerClosedCallbackCount}/${this.closeAckCallbackSeen} " +
            "failure=${this.writerFailureKind}/${this.writerFailurePhase} ownerCount=${this.ownerCount} " +
            "exit=${this.exitScheduledCount}/${this.lastExitScheduledCode}"
    }
}

private func gatewayHeartbeatBrokerDiagnostics(path: Path): ArrayList<GatewayHeartbeatBrokerDiagnostic> {
    let values = ArrayList<GatewayHeartbeatBrokerDiagnostic>()
    if (!exists(path)) { return values }
    try {
        for (entry in Directory.readFrom(path)) {
            if (!entry.isRegular() || !entry.name.startsWith("broker-g") || !entry.name.endsWith(".json")) {
                continue
            }
            values.add(GatewayHeartbeatBrokerDiagnostic(entry.path, fileName: entry.name))
        }
    } catch (_: Exception) {
        values.clear()
    }
    values
}

private func gatewayHeartbeatBrokerDiagnosticOverflow(path: Path): Bool {
    let overflow = path.join("overflow.json")
    if (!exists(overflow)) { return false }
    try {
        let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(overflow))).asObject()
        root.get("overflow").getOrThrow().asBool().getValue() &&
            root.get("capacity").getOrThrow().asInt().getValue() == 16
    } catch (_: Exception) {
        false
    }
}

private class GatewayHeartbeatBrokerDirectoryProof {
    var status: String = "missing"
    var identityCount: Int64 = 0
    var slotCount: Int64 = 0
    var tempCount: Int64 = 0
    var overflow: Bool = false

    init(path: Path) {
        if (!exists(path)) { return }
        var invalidEntry = false
        var invalidMarker = false
        try {
            for (entry in Directory.readFrom(path)) {
                if (entry.isDirectory()) {
                    var slotValid = false
                    for (slot in 0..16) {
                        if (entry.name == ".identity-slot-${slot}") { slotValid = true }
                    }
                    if (!slotValid) { invalidEntry = true } else { this.slotCount++ }
                    continue
                }
                if (!entry.isRegular()) {
                    invalidEntry = true
                    continue
                }
                if (entry.name == "overflow.json") {
                    if (gatewayHeartbeatBrokerDiagnosticOverflow(path)) {
                        this.overflow = true
                    } else {
                        invalidEntry = true
                    }
                    continue
                }
                if (entry.name.startsWith("broker-g") && entry.name.contains(".json.tmp-")) {
                    this.tempCount++
                    continue
                }
                if (!entry.name.startsWith("broker-g") || !entry.name.endsWith(".json")) {
                    invalidEntry = true
                    continue
                }
                this.identityCount++
                let value = GatewayHeartbeatBrokerDiagnostic(entry.path, fileName: entry.name)
                if (!value.valid || !value.filenameMatches) {
                    invalidMarker = true
                }
            }
            this.status = if (invalidEntry) {
                "invalid_entry"
            } else if (invalidMarker) {
                "marker_invalid"
            } else if (this.identityCount > 16) {
                "identity_limit_exceeded"
            } else if (this.overflow) {
                "overflow"
            } else if (this.tempCount > 0) {
                "temp_present"
            } else if (this.slotCount != this.identityCount) {
                "slot_identity_mismatch"
            } else {
                "valid"
            }
        } catch (_: Exception) {
            this.status = "scan_failed"
        }
    }

    func safeSummary(phase: String): String {
        "phase=${phase} status=${this.status} identities=${this.identityCount} slots=${this.slotCount} " +
            "temps=${this.tempCount} overflow=${this.overflow}"
    }
}

private func gatewayHeartbeatBrokerDiagnosticForPid(
    path: Path,
    expectedPid: Int64
): Option<GatewayHeartbeatBrokerDiagnostic> {
    for (value in gatewayHeartbeatBrokerDiagnostics(path)) {
        if (value.valid && value.brokerPid == expectedPid) { return Some(value) }
    }
    None<GatewayHeartbeatBrokerDiagnostic>
}

private func gatewayHeartbeatBrokerPidsGone(path: Path): Bool {
    let values = gatewayHeartbeatBrokerDiagnostics(path)
    if (values.isEmpty()) { return false }
    for (value in values) {
        if (value.brokerPid <= 1 || gatewayServeStopPidAlive(value.brokerPid)) { return false }
    }
    true
}

private func gatewayS5RegularFileCount(path: Path): Int64 {
    if (!exists(path)) { return 0 }
    var count: Int64 = 0
    try {
        for (entry in Directory.readFrom(path)) {
            if (entry.isRegular()) { count++ }
        }
    } catch (_: Exception) {
        return -1
    }
    count
}

private class GatewayS5StrictLedger {
    private let counts = HashMap<String, Int64>()
    private let writebackIidCounts = HashMap<String, Int64>()
    private var invalidRows: Int64 = 0
    private var unknownRows: Int64 = 0

    init(path: Path, expected: HashSet<String>, expectedWritebacks: HashMap<String, String>) {
        let text = try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) {
            this.invalidRows++
            return
        }
        for (line in text.split("\n")) {
            let normalized = line.trimAscii()
            if (normalized.isEmpty()) { continue }
            let root = try { JsonValue.fromStr(normalized).asObject() } catch (_: Exception) {
                this.invalidRows++
                continue
            }
            let kind = try { root.get("kind").getOrThrow().asString().getValue() } catch (_: Exception) { "" }
            if (!(kind == "model_response" || kind == "gitcode_writeback" ||
                kind == "telegram_send" || kind == "feishu_send")) { continue }
            let deliveryId = try {
                root.get("deliveryId").getOrThrow().asString().getValue()
            } catch (_: Exception) {
                ""
            }
            if (deliveryId.isEmpty() || !expected.contains(deliveryId)) {
                this.unknownRows++
                continue
            }
            if (kind == "gitcode_writeback") {
                let iid = try {
                    root.get("iid").getOrThrow().asString().getValue()
                } catch (_: Exception) {
                    ""
                }
                let expectedDelivery = expectedWritebacks.get(iid) ?? ""
                if (iid.isEmpty() || expectedDelivery != deliveryId) {
                    this.unknownRows++
                    continue
                }
                this.writebackIidCounts[iid] = (this.writebackIidCounts.get(iid) ?? 0) + 1
            }
            let key = "${kind}|${deliveryId}"
            this.counts[key] = (this.counts.get(key) ?? 0) + 1
        }
    }

    func exactWritebacks(expected: HashMap<String, String>, deliveries: HashSet<String>): Bool {
        if (!this.exactOnce("gitcode_writeback", deliveries)) { return false }
        for ((iid, _deliveryId) in expected) {
            if ((this.writebackIidCounts.get(iid) ?? 0) != 1) { return false }
        }
        this.writebackIidCounts.size == expected.size
    }

    func exactOnce(kind: String, expected: HashSet<String>): Bool {
        for (deliveryId in expected) {
            if ((this.counts.get("${kind}|${deliveryId}") ?? 0) != 1) { return false }
        }
        var matching: Int64 = 0
        for ((key, count) in this.counts) {
            if (key.startsWith("${kind}|") && count > 0) { matching++ }
        }
        matching == expected.size
    }

    func valid(): Bool { this.invalidRows == 0 && this.unknownRows == 0 }
}

private class GatewayS5ProxyReadySnapshot {
    let wrapperPid: Int64
    let brokerPid: Int64
    let helloPid: Int64
    let generation: Int64
    let ownerPid: Int64
    let ownerId: String

    init(wrapperPid: Int64, brokerPid: Int64, helloPid: Int64, generation: Int64, ownerPid: Int64, ownerId: String) {
        this.wrapperPid = wrapperPid
        this.brokerPid = brokerPid
        this.helloPid = helloPid
        this.generation = generation
        this.ownerPid = ownerPid
        this.ownerId = ownerId
    }

    func sameOwner(other: GatewayS5ProxyReadySnapshot): Bool {
        this.brokerPid == other.brokerPid && this.generation == other.generation &&
            this.ownerPid == other.ownerPid && this.ownerId == other.ownerId
    }
}

private func gatewayS5ProxyReadySnapshot(path: Path): Option<GatewayS5ProxyReadySnapshot> {
    if (!exists(path)) { return None<GatewayS5ProxyReadySnapshot> }
    try {
        let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
        let wrapperPid = root.get("wrapperPid").getOrThrow().asInt().getValue()
        let brokerPid = root.get("brokerPid").getOrThrow().asInt().getValue()
        let helloPid = root.get("helloBrokerPid").getOrThrow().asInt().getValue()
        let generation = root.get("generation").getOrThrow().asInt().getValue()
        let ownerPid = root.get("gcmOwnerPid").getOrThrow().asInt().getValue()
        let ownerId = root.get("gcmOwnerId").getOrThrow().asString().getValue()
        let ownerStartSeq = root.get("gcmOwnerStartSeq").getOrThrow().asInt().getValue()
        let ownerInitializeSeq = root.get("gcmOwnerInitializeSeq").getOrThrow().asInt().getValue()
        if (wrapperPid <= 1 || brokerPid <= 1 || helloPid <= 1 || generation <= 0 || ownerPid <= 1 ||
            ownerStartSeq <= 0 || ownerInitializeSeq <= ownerStartSeq ||
            ownerId.isEmpty() || ownerId.size > 4096 || ownerId.contains("\u{0000}") ||
            ownerId.contains("\r") || ownerId.contains("\n")) {
            return None<GatewayS5ProxyReadySnapshot>
        }
        Some(GatewayS5ProxyReadySnapshot(wrapperPid, brokerPid, helloPid, generation, ownerPid, ownerId))
    } catch (_: Exception) {
        None<GatewayS5ProxyReadySnapshot>
    }
}

private func gatewayS5DropMarkerProof(path: Path, expectedStatus: String, expectedDeliveryId: String): (Bool, Int64, String, Int64, String, String) {
    if (!exists(path)) { return (false, 0, "", 0, "", "") }
    try {
        let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
        let sequence = root.get("sequence").getOrThrow().asInt().getValue()
        let status = root.get("status").getOrThrow().asString().getValue()
        let generation = root.get("generation").getOrThrow().asInt().getValue()
        let ownerId = root.get("ownerId").getOrThrow().asString().getValue()
        let requestId = root.get("requestId").getOrThrow().asString().getValue()
        let deliveryId = root.get("deliveryId").getOrThrow().asString().getValue()
        let attemptToken = root.get("attemptToken").getOrThrow().asString().getValue()
        (
            sequence > 0 && status == expectedStatus && generation > 0 && !ownerId.isEmpty() &&
                !requestId.isEmpty() && deliveryId == expectedDeliveryId && !attemptToken.isEmpty(),
            sequence,
            attemptToken,
            generation,
            ownerId,
            requestId
        )
    } catch (_: Exception) {
        (false, 0, "", 0, "", "")
    }
}

private func gatewayS5QueueDeliveryProof(path: Path, expectedDeliveryId: String): (Bool, String, String, String) {
    if (!exists(path)) { return (false, "", "", "") }
    try {
        let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
        let deliveryId = root.get("deliveryId").getOrThrow().asString().getValue()
        let status = root.get("status").getOrThrow().asString().getValue()
        let admissionState = root.get("admissionState").getOrThrow().asString().getValue()
        let admissionToken = root.get("admissionToken").getOrThrow().asString().getValue()
        (deliveryId == expectedDeliveryId && !admissionToken.isEmpty(), status, admissionState, admissionToken)
    } catch (_: Exception) {
        (false, "", "", "")
    }
}

private func gatewayS5ReceiptProof(rootPath: Path, expectedDeliveryId: String): (Bool, Int64, String, String, String) {
    if (!exists(rootPath)) { return (false, 0, "", "", "") }
    var count: Int64 = 0
    var valid = false
    var eventId = ""
    var attemptToken = ""
    var state = ""
    try {
        for (entry in Directory.readFrom(rootPath)) {
            if (!entry.isRegular() || !entry.name.endsWith(".json")) { continue }
            count++
            let receipt = JsonValue.fromStr(String.fromUtf8(File.readFrom(entry.path))).asObject()
            let serviceId = receipt.get("serviceId").getOrThrow().asString().getValue()
            let deliveryId = receipt.get("deliveryId").getOrThrow().asString().getValue()
            eventId = receipt.get("eventId").getOrThrow().asString().getValue()
            attemptToken = receipt.get("attemptToken").getOrThrow().asString().getValue()
            state = receipt.get("state").getOrThrow().asString().getValue()
            valid = serviceId == "gitcode-monitor" && deliveryId == expectedDeliveryId &&
                !eventId.isEmpty() && !attemptToken.isEmpty() && !state.isEmpty()
        }
    } catch (_: Exception) {
        return (false, count, "", "", "")
    }
    (valid && count == 1, count, eventId, attemptToken, state)
}

private func gatewayS5FindLease(home: Path): Path {
    let dir = home.join("service-plugin").join("runtime").join("gitcode-monitor")
    if (!exists(dir)) { return Path("") }
    try {
        for (entry in Directory.readFrom(dir)) {
            if (entry.isRegular() && entry.name.endsWith(".lease.json")) { return entry.path }
        }
    } catch (_: Exception) { () }
    Path("")
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

private func gatewayHeartbeatProbeExecutable(path: Path, body: String): Unit {
    File.writeTo(path, ("#!/bin/sh\n" + body + "\n").toArray())
    @Expect(executeWithOutput("/bin/chmod", ["700", path.toString()])[0], 0)
}

private func gatewayHeartbeatBrokerIsFullyStopped(): Bool {
    let snapshot = managedStdioBroker().snapshot()
    @Expect(snapshot.running, false)
    @Expect(snapshot.brokerPid, 0)
    @Expect(snapshot.ownerCount, 0)
    @Expect(snapshot.readerCount, 0)
    @Expect(snapshot.dispatcherCount, 0)
    !snapshot.running && snapshot.brokerPid == 0 && snapshot.ownerCount == 0 &&
        snapshot.readerCount == 0 && snapshot.dispatcherCount == 0
}

private func withGatewayHeartbeatProbeEnvironment(name: String, block: (Path, Path) -> Unit): Unit {
    synchronized(MetisProcessEnvironmentLock) {
        let root = Path("/tmp/metis-heartbeat-probe-${name}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        let bin = root.join("bin")
        Directory.create(bin, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        let oldPath = getVariable("PATH")
        let inheritedPath = match (oldPath) { case Some(value) => value case None => "/usr/bin:/bin" }
        setVariable("METIS_HOME", root.toString())
        setVariable("PATH", "${bin.toString()}:${inheritedPath}")
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        try {
            setGatewayServePortProbeForTest(None<(Int64, Int64) -> (Int64, String, String)>)
            let initialReset = resetManagedStdioBrokerForTest()
            @Expect(initialReset.ok, true)
            let initialStopped = gatewayHeartbeatBrokerIsFullyStopped()
            if (!initialReset.ok || !initialStopped) { return }
            block(root, bin)
        } finally {
            setGatewayServePortProbeForTest(None<(Int64, Int64) -> (Int64, String, String)>)
            gatewayReleaseServeLockQuiet()
            let finalReset = resetManagedStdioBrokerForTest()
            @Expect(finalReset.ok, true)
            match (oldHome) { case Some(value) => setVariable("METIS_HOME", value) case None => setVariable("METIS_HOME", "") }
            match (oldPath) { case Some(value) => setVariable("PATH", value) case None => setVariable("PATH", "") }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            let finalStopped = gatewayHeartbeatBrokerIsFullyStopped()
            @Expect(finalStopped, true)
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }
    }
}

private func gatewayShutdownPhaseNegativeProof(root: Path, identity: GatewayServeIdentity): Unit {
    let previousMarker = getVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_MARKER")
    let previousNonce = getVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_NONCE")
    let phaseBase = root.join("shutdown-phase")
    try {
        setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_MARKER", "")
        setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_NONCE", "")
        @Expect(gatewayPublishShutdownPhaseForTest(identity, "stop_request_observed"), false)
        @Expect(exists(Path("${phaseBase.toString()}.1.json")), false)
        let invalidParent = root.join("invalid-parent")
        File.writeTo(invalidParent, "file\n".toArray())
        setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_MARKER", invalidParent.join("phase").toString())
        setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_NONCE", "hb-br-n5-invalid")
        @Expect(gatewayPublishShutdownPhaseForTest(identity, "stop_request_observed"), false)
    } finally {
        match (previousMarker) {
            case Some(value) => setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_MARKER", value)
            case None => setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_MARKER", "")
        }
        match (previousNonce) {
            case Some(value) => setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_NONCE", value)
            case None => setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_NONCE", "")
        }
    }
}


// Keep parent logging state from pointing into a home that has been removed.
private func withHrFormalEnvironment(name: String, block: (Path, Path) -> Unit): Unit {
    let oldLog = Config.logFile
    let oldCurl = getVariable("CURL_HOME")
    let oldXdg = getVariable("XDG_CONFIG_HOME")
    try {
        withGatewayHeartbeatProbeEnvironment(name, { home, bin =>
            let curl = home.join("curl")
            Directory.create(curl)
            File.writeTo(curl.join(".curlrc"), [])
            File.writeTo(curl.join("curlrc"), [])
            setVariable("CURL_HOME", curl.toString())
            setVariable("XDG_CONFIG_HOME", curl.toString())
            block(home, bin)
        })
    } finally {
        hrFormalRestore("CURL_HOME", oldCurl)
        hrFormalRestore("XDG_CONFIG_HOME", oldXdg)
        gatewayLoggingResetForTest()
        Config.logFile = oldLog
    }
}

// Formal actors use the production CLI/host/broker. Only the owned HTTP component
// is released through a barrier; the component writes its own terminal lease.
private func hrFormalRead(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { "" }
}

private func hrFormalNumber(path: Path, key: String): Int64 {
    try { JsonValue.fromStr(hrFormalRead(path)).asObject().get(key).getOrThrow().asInt().getValue() }
    catch (_: Exception) { 0 }
}

private func hrFormalRestore(key: String, old: Option<String>): Unit {
    match (old) { case Some(value) => setVariable(key, value) case None => removeVariable(key) }
}

private func hrFormalFixture(home: Path, project: Path): Path {
    let source = project.join("scripts").join("gateway-historical-recovery-fake-service.cj")
    let configured = getVariable("METIS_HR_FIXTURE_BIN").getOrDefault { "" }.trimAscii()
    if (!configured.isEmpty()) {
        let binary = Path(configured)
        let info = FileInfo(binary)
        if (!binary.isAbsolute() || !info.isRegular() || info.isSymbolicLink() ||
            info.lastModificationTime < FileInfo(source).lastModificationTime) {
            throw Exception("historical_fixture_stale_or_unsafe")
        }
        return binary
    }
    // A normal clean/build/test invocation is self-contained. This standalone
    // compilation belongs to this case's home and is removed by its environment.
    let magic = Path(getVariable("MAGIC_PATH").getOrDefault { project.parent.join("CangjieMagic").toString() })
    let stdx = magic.join("libs/cangjie-stdx-mac-aarch64-1.0.0.1/darwin_aarch64_llvm/dynamic/stdx")
    let binary = home.join("historical-fake-service")
    let result = executeWithOutput("cjc", [source.toString(), "--import-path", stdx.toString(), "-L", stdx.toString(),
        "-lstdx.encoding.json", "--link-options", "-rpath ${stdx.toString()}", "-o", binary.toString()], workingDirectory: Some(home))
    @Expect(result[0], 0)
    if (result[0] != 0 || !exists(binary)) { throw Exception("historical_fixture_compile_failed") }
    binary
}

private class HrFormalGateway {
    let home: Path
    let project: Path
    let binary: Path
    let fixture: Path
    let port: Int64
    let children = ArrayList<SubProcess>()
    let stderrFiles = ArrayList<Path>()
    let stdoutFiles = HashMap<Int64, Path>()
    let brokerPids = ArrayList<Int64>()
    let pluginPorts = ArrayList<Int64>()
    let instances = ArrayList<ProcessInstanceIdentity>()
    var current: Option<SubProcess> = None

    init(home: Path) {
        this.home = home
        this.project = Path(managedStdioResolveBrokerScriptPath()).parent.parent
        this.binary = gatewayFormalMetisBinary(this.project).getOrThrow()
        this.fixture = hrFormalFixture(home, this.project)
        this.port = gatewayServeStopTemporaryPort()
        @Expect(this.port > 0, true)
    }

    func launchOwned(command: Path, args: Array<String>, name: String): SubProcess {
        let stderrPath = this.home.join("${name}-${this.children.size}.stderr")
        this.stderrFiles.add(stderrPath)
        File.writeTo(stderrPath, [])
        let stdoutPath = this.home.join("${name}-${this.children.size}.stdout")
        File.writeTo(stdoutPath, [])
        var owned = None<SubProcess>
        try (input = File("/dev/null", OpenMode.Read), output = File(stdoutPath, OpenMode.Write),
            error = File(stderrPath, OpenMode.Write)) {
            let child = launch(command.toString(), args, stdIn: ProcessRedirect.FromFile(input),
                stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error))
            this.children.add(child)
            this.stdoutFiles[child.pid] = stdoutPath
            owned = Some(child)
        }
        owned.getOrThrow()
    }

    func configure(args: Array<String>): Unit {
        let manifest = this.home.join("historical-service.manifest.json")
        let root = JsonObject()
        root.put("schema", JsonString("metis.servicePlugin.v1"))
        root.put("pluginId", JsonString("gitcode-monitor"))
        root.put("kind", JsonString("service"))
        root.put("protocolVersion", JsonString("1.0"))
        let entry = JsonObject()
        entry.put("command", JsonString(this.fixture.toString()))
        let items = JsonArray()
        for (arg in args) { items.add(JsonString(arg)) }
        entry.put("args", items)
        root.put("entry", entry)
        let schema = JsonObject()
        schema.put("type", JsonString("object"))
        root.put("configSchema", schema)
        let declarations = JsonArray()
        let capability = JsonObject()
        capability.put("capabilityId", JsonString("gateway.historical.fixture"))
        capability.put("kind", JsonString("controlAction"))
        declarations.add(capability)
        root.put("capabilityDeclarations", declarations)
        File.writeTo(manifest, root.toJsonString().toArray())
        @Expect(loadServicePluginManifest(manifest.toString()).ok, true)
        var settings = CliSettingManager.readGatewaySettings()
        settings.enabled = true
        settings.port = this.port
        settings.logging.file = this.home.join("formal-gateway.log").toString()
        settings.logging.level = "info"
        var plugin = GatewayServicePluginUserSettings()
        plugin.pluginId = "gitcode-monitor"
        plugin.enabled = true
        plugin.autostart = true
        plugin.startupTimeoutMs = 5000
        plugin.manifestPath = manifest.toString()
        settings.servicePlugins = [plugin]
        let _ = MetisConfigManager.setGatewaySettings(settings)
        CliSettingManager.invalidate()
    }

    func launchGateway(nonzeroBroker!: Bool = false, directServe!: Bool = false): SubProcess {
        let oldScript = getVariable("METIS_STDIO_BROKER_SCRIPT")
        let oldReal = getVariable("METIS_HR_REAL_BROKER")
        let oldHeap = getVariable("cjHeapSize")
        try {
            setVariable("cjHeapSize", "2GB")
            if (nonzeroBroker) {
                setVariable("METIS_STDIO_BROKER_SCRIPT", this.project.join("scripts/gateway-historical-recovery-broker-nonzero.mjs").toString())
                setVariable("METIS_HR_REAL_BROKER", this.project.join("scripts/metis-stdio-broker.mjs").toString())
            }
            this.launchOwned(this.binary, ["gateway", if (directServe) { "serve" } else { "run" }], "gateway")
        } finally {
            hrFormalRestore("METIS_STDIO_BROKER_SCRIPT", oldScript)
            hrFormalRestore("METIS_HR_REAL_BROKER", oldReal)
            hrFormalRestore("cjHeapSize", oldHeap)
        }
    }

    func awaitReady(process: SubProcess, ready: Path): Unit {
        let proof = GatewayServeStopLiveOwnerProof()
        let accepted = gatewayServeStopWaitUntil(20000, { =>
            proof.refresh("http://127.0.0.1:${this.port}/readyz")
            process.isAlive() && exists(ready) && proof.httpStatus == 200 && proof.running && proof.ownerCount == 1
        })
        @Expect(accepted, true)
        if (!accepted) {
            throw Exception("historical_formal_not_ready alive=${process.isAlive()} ready=${exists(ready)} http=${proof.httpStatus} brokerRunning=${proof.running} ownerCount=${proof.ownerCount}")
        }
        let identity = gatewayParseServeIdentity(hrFormalRead(this.home.join("gateway-serve.lock")))
        @Expect(identity.isSome(), true)
        @Expect(identity.getOrThrow().pid, process.pid)
        let instance = identity.getOrThrow().processIdentity.getOrThrow()
        let probe = probeProcessInstance(instance, MonoTime.now() + Duration.second)
        @Expect(probe.conclusive && probe.alive, true)
        this.instances.add(instance)
        let pluginPort = hrFormalNumber(ready, "port")
        @Expect(pluginPort > 0 && gatewayServeStopPortListening(pluginPort), true)
        this.pluginPorts.add(pluginPort)
        let broker = gatewayServeStopChildPid(process.pid, "broker")
        @Expect(broker > 1, true)
        if (broker > 1) { this.brokerPids.add(broker) }
        this.current = Some(process)
    }

    func startService(name: String, nonzeroBroker!: Bool = false, directServe!: Bool = false): SubProcess {
        let ready = this.home.join("${name}.ready")
        let args = ArrayList<String>()
        for (arg in ["service", ready.toString(), this.home.join("${name}.release").toString(), this.home.join("${name}.stop").toString()]) { args.add(arg) }
        this.configure(args.toArray())
        let process = this.launchGateway(nonzeroBroker: nonzeroBroker, directServe: directServe)
        this.awaitReady(process, ready)
        process
    }

    func startPendingGeneration(): SubProcess {
        let ready = this.home.join("old-worker.ready")
        let registration = this.home.join("old-registration.json")
        let registered = this.home.join("old-registered")
        let worker = this.launchOwned(this.fixture, ["worker", ready.toString(), this.home.join("old-worker.release").toString(),
            registration.toString(), registered.toString()], "worker")
        @Expect(gatewayServeStopWaitUntil(5000, { => exists(ready) }), true)
        this.configure(["delegate", ready.toString(), registration.toString(), registered.toString(), this.home.join("old-delegate.stop").toString()])
        let process = this.launchGateway(nonzeroBroker: true)
        this.awaitReady(process, ready)
        @Expect(exists(registered), true)
        let oldLease = gatewayS5FindLease(this.home)
        @Expect(hrFormalRead(oldLease).contains("running"), true)
        @Expect(hrFormalNumber(oldLease, "parentPid"), process.pid)
        @Expect(hrFormalNumber(oldLease, "pid") > 1, true)
        worker
    }

    func releaseWorker(worker: SubProcess): Unit {
        let lease = gatewayS5FindLease(this.home)
        let port = hrFormalNumber(lease, "port")
        @Expect(worker.isAlive(), true)
        @Expect(gatewayServeStopPortListening(port), true)
        @Expect(hrFormalRead(lease).contains("running"), true)
        File.writeTo(this.home.join("old-worker.release"), "release\n".toArray())
        @Expect(worker.wait(timeout: Some(Duration.second * 2)), 0)
        @Expect(worker.isAlive(), false)
        @Expect(gatewayServeStopPidAlive(worker.pid), false)
        @Expect(gatewayServeStopPortListening(port), false)
        let terminal = JsonValue.fromStr(hrFormalRead(lease)).asObject()
        @Expect(terminal.get("state").getOrThrow().asString().getValue(), "stopped")
    }

    func concurrentRecoveredService(name: String): SubProcess {
        let ready = this.home.join("${name}.ready")
        this.configure(["service", ready.toString(), this.home.join("${name}.release").toString(),
            this.home.join("${name}.stop").toString(), this.home.join("business.pending").toString(),
            this.home.join("business.receipt").toString(), this.home.join("business.effects").toString()])
        // Both independent CLIs compete for the same production exclusive lock.
        let first = this.launchGateway(directServe: true)
        let second = this.launchGateway(directServe: true)
        @Expect(gatewayServeStopWaitUntil(20000, { => exists(ready) }), true)
        let lock = gatewayParseServeIdentity(hrFormalRead(this.home.join("gateway-serve.lock"))).getOrThrow()
        @Expect(lock.pid == first.pid || lock.pid == second.pid, true)
        let winner = if (lock.pid == first.pid) { first } else { second }
        let loser = if (lock.pid == first.pid) { second } else { first }
        // Existing foreground CLI semantics report lock refusal with exit zero;
        // refusal is proved by one live lock/owner and no second initialization.
        @Expect(loser.wait(timeout: Some(Duration.second * 2)), 0)
        @Expect(loser.isAlive(), false)
        @Expect(gatewayServeStopPidAlive(loser.pid), false)
        @Expect(hrFormalRead(this.stdoutFiles.get(loser.pid).getOrThrow()).contains("无法启动"), true)
        this.awaitReady(winner, ready)
        @Expect(gatewayParseServeIdentity(hrFormalRead(this.home.join("gateway-serve.lock"))).getOrThrow().pid, winner.pid)
        @Expect(exists(this.home.join("gateway-serve.stop-complete")), false)
        @Expect(hrFormalArchiveOriginals(this.home).size, 1)
        var reconciled: Int64 = 0
        for (row in hrFormalRead(this.home.join("formal-gateway.log")).split("\n")) {
            if (row.contains("gateway.recovery.reconciled")) { reconciled++ }
        }
        @Expect(reconciled, 1)
        this.assertJournal(Path(ready.toString() + ".initializations.jsonl"), hrFormalNumber(ready, "pid"))
        winner
    }

    func stopCurrent(expected: Int64): String {
        let output = ArrayList<String>()
        setGatewayStopOutputForTest(Some({ text => output.add(text) }))
        let result = try { gatewayExecuteStopServe() } finally { setGatewayStopOutputForTest(None<(String) -> Unit>) }
        @Expect(result, expected)
        let process = this.current.getOrThrow()
        // SubProcess has no automatic reaper; wait before its alive/PID probes.
        @Expect(process.wait(timeout: Some(Duration.second * 2)), expected)
        @Expect(process.isAlive(), false)
        @Expect(gatewayServeStopPidAlive(process.pid), false)
        @Expect(gatewayServeStopPortListening(this.port), false)
        hrFormalRead(this.home.join("gateway-serve.stop-complete"))
    }

    func assertJournal(path: Path, pid: Int64): Unit {
        @Expect(gatewayServeStopWaitUntil(1000, { => hrFormalRead(path).trimAscii().split("\n").size == 2 }), true)
        let rows = hrFormalRead(path).trimAscii().split("\n")
        @Expect(rows.size, 2)
        var started: Int64 = 0
        var initialized: Int64 = 0
        for (row in rows) {
            let root = JsonValue.fromStr(row).asObject()
            @Expect(root.get("pid").getOrThrow().asInt().getValue(), pid)
            let event = root.get("event").getOrThrow().asString().getValue()
            if (event == "started") { started++ }
            if (event == "initialized") { initialized++ }
        }
        @Expect(started, 1)
        @Expect(initialized, 1)
    }

    func assertClean(): Unit {
        // Stop CLI/probe shell commands own a separate broker in this test parent.
        // Close that owner through the real boundary before zero-residue assertions.
        let parent = managedStdioBroker().snapshot()
        if (parent.brokerPid > 1) {
            @Expect(gatewayServeStopParentPid(parent.brokerPid), getProcessId())
            for (childBroker in this.brokerPids) { @Expect(parent.brokerPid != childBroker, true) }
        }
        let closed = shutdownManagedStdioBroker()
        @Expect(closed.ok, true)
        @Expect(closed.externalTerminal, true)
        if (parent.brokerPid > 1) { @Expect(gatewayServeStopPidAlive(parent.brokerPid), false) }
        // All assertions precede the finally fallback reaper.
        for (process in this.children) {
            @Expect(process.isAlive(), false)
            @Expect(gatewayServeStopPidAlive(process.pid), false)
        }
        for (instance in this.instances) {
            let probe = probeProcessInstance(instance, MonoTime.now() + Duration.second)
            @Expect(probe.conclusive && !probe.alive, true)
        }
        for (pid in this.brokerPids) { @Expect(gatewayServeStopPidAlive(pid), false) }
        for (port in this.pluginPorts) { @Expect(gatewayServeStopPortListening(port), false) }
        @Expect(gatewayServeStopPortListening(this.port), false)
        @Expect(exists(this.home.join("gateway-serve.lock")), false)
        for (path in this.stderrFiles) { @Expect(hrFormalRead(path).contains("protocol writer failed"), false) }
        @Expect(gatewayHeartbeatBrokerIsFullyStopped(), true)
    }

    func cleanup(): Unit {
        setGatewayStopOutputForTest(None<(String) -> Unit>)
        for (process in this.children) {
            if (process.isAlive()) { try { process.terminate(force: true) } catch (_: Exception) { () } }
            try { let _ = process.wait(timeout: Some(Duration.second * 2)) } catch (_: Exception) { () }
        }
    }
}

private func hrFormalArchiveOriginals(home: Path): Array<String> {
    let result = ArrayList<String>()
    let dir = home.join("gateway-serve.recovery-history")
    if (!exists(dir)) { return [] }
    for (entry in Directory.readFrom(dir)) {
        if (entry.isRegular() && entry.name.endsWith(".completion")) { result.add(hrFormalRead(entry.path)) }
    }
    result.toArray()
}


private func hrFormalPendingProof(formal: HrFormalGateway): String {
    let completion = formal.stopCurrent(1)
    @Expect(gatewayServeStopCompletionField(completion, "status"), "cleanup_pending")
    @Expect(gatewayServeStopCompletionField(completion, "fullTerminal"), "0")
    @Expect(gatewayServeStopCompletionField(completion, "servicePluginLeaseStatus"), "cleanup_pending")
    @Expect(gatewayServeStopCompletionField(completion, "servicePluginPortStatus"), "cleanup_pending")
    @Expect(gatewayServeStopCompletionField(completion, "brokerStatus"), "broker_close_exit_nonzero")
    @Expect(gatewayServeStopCompletionField(completion, "brokerExternalTerminal"), "1")
    @Expect(gatewayServeStopCompletionField(completion, "brokerTerminalBasis"), "closed_ack_exit_observed")
    @Expect(exists(formal.home.join("old-delegate.stop")), true)
    completion
}

private func hrFormalBusinessInput(home: Path): String {
    let original = "{\"id\":\"pending-中文-😀\",\"payload\":\"keep exact business truth\"}\n"
    File.writeTo(home.join("business.pending"), original.toArray())
    original
}

private func hrFormalBusinessProof(home: Path, original: String): Unit {
    @Expect(hrFormalRead(home.join("business.pending")), original)
    let rows = hrFormalRead(home.join("business.effects")).trimAscii().split("\n")
    @Expect(rows.size, 1)
    let effect = JsonValue.fromStr(rows[0]).asObject()
    @Expect(effect.get("id").getOrThrow().asString().getValue(), "pending-中文-😀")
    @Expect(effect.get("status").getOrThrow().asString().getValue(), "recovered")
    @Expect(exists(home.join("business.receipt")), true)
}

private func hrFormalRecoveryChain(formal: HrFormalGateway): Unit {
    let business = hrFormalBusinessInput(formal.home)
    let worker = formal.startPendingGeneration()
    let oldPid = formal.current.getOrThrow().pid
    let original = hrFormalPendingProof(formal)
    @Expect(hrFormalRead(formal.home.join("business.pending")), business)
    @Expect(exists(formal.home.join("business.effects")), false)
    formal.releaseWorker(worker)
    let preview = gatewayHistoricalServeCompletionRecoveryStatus()
    @Expect(preview.ok, true)
    @Expect(preview.status, "recoverable")
    @Expect(hrFormalRead(formal.home.join("gateway-serve.stop-complete")), original)
    let winner = formal.concurrentRecoveredService("new")
    @Expect(winner.pid != oldPid, true)
    let archives = hrFormalArchiveOriginals(formal.home)
    @Expect(archives.size, 1)
    @Expect(archives[0], original)
    @Expect(gatewayServeStopCompletionField(archives[0], "status"), "cleanup_pending")
    @Expect(gatewayServeStopCompletionField(archives[0], "brokerStatus"), "broker_close_exit_nonzero")
    hrFormalBusinessProof(formal.home, business)
    let final = formal.stopCurrent(0)
    @Expect(gatewayServeStopCompletionField(final, "status"), "graceful")
    @Expect(gatewayServeStopCompletionField(final, "fullTerminal"), "1")
    hrFormalBusinessProof(formal.home, business)
    formal.assertClean()
}

// Legacy input producer: constructs the documented pre-evidence v4 format from
// independently captured process identity. It never edits a live/new writer's marker.
private func hrFormalLegacyProducer(identity: GatewayServeIdentity, version: String): String {
    let instance = identity.processIdentity.getOrThrow().serialize()
    let historical = "gateway-serve-active-v4\npid:${identity.pid}\nstartedAtMs:${identity.startedAtMs}\nnonce:${identity.nonce}\n" +
        "processIdentity:${instance}\ngracefulShutdownTimeoutMs:60000\nstatus:cleanup_pending\nfullTerminal:0\n" +
        "inboundStatus:stopped\ncompatStatus:stopped\nsidecarStatus:disabled\nservicePluginIngressStatus:sent\n" +
        "servicePluginDispatchStatus:drained\nservicePluginOwnerStatus:graceful_exited\nservicePluginLeaseStatus:terminal\n" +
        "servicePluginPortStatus:terminal\nservicePluginPendingCount:0\nchannelsStatus:stopped\nbrokerStatus:broker_close_exit_nonzero\n" +
        "httpStatus:stopped\ncanvasStatus:already_stopped\ngatewayServerStatus:stopped\n"
    if (version.isEmpty()) { historical }
    else { historical + "recoveryEvidenceVersion:${version}\nbrokerExternalTerminal:1\nbrokerTerminalBasis:closed_ack_exit_observed\n" }
}


private func hrFormalAssertAllLeasesStopped(home: Path): Unit {
    let dir = home.join("service-plugin/runtime/gitcode-monitor")
    @Expect(exists(dir), true)
    var leases: Int64 = 0
    for (entry in Directory.readFrom(dir)) {
        if (!entry.isRegular() || !entry.name.endsWith(".lease.json")) { continue }
        leases++
        let root = JsonValue.fromStr(hrFormalRead(entry.path)).asObject()
        @Expect(root.get("state").getOrThrow().asString().getValue(), "stopped")
        @Expect(gatewayServeStopPidAlive(root.get("pid").getOrThrow().asInt().getValue()), false)
        @Expect(gatewayServeStopPortListening(root.get("port").getOrThrow().asInt().getValue()), false)
    }
    @Expect(leases > 0, true)
}

private func hrFormalFaultTraffic(): Unit {
    // No child launch/compilation occurs in the descriptor measurement window.
    // The peer sees EOF caused by each production transport's own failure cleanup.
    for (kind in 0..3) {
        let listener = TcpServerSocket(bindAt: 0u16)
        listener.bind()
        let port = (listener.localAddress as IPSocketAddress)?.port ?? 0u16
        let eof = AtomicInt64(0)
        let serving = spawn {
            try (peer = listener.accept(timeout: Some(Duration.second * 3))) {
                peer.readTimeout = Some(Duration.second * 5)
                let header = ArrayList<Byte>()
                let one = Array<Byte>(1, repeat: 0)
                while (header.size < 8192) {
                    if (peer.read(one) == 0) { return }
                    header.add(one[0])
                    let n = header.size
                    if (n >= 4 && header[n - 4] == 13 && header[n - 3] == 10 && header[n - 2] == 13 && header[n - 1] == 10) { break }
                }
                if (kind == 0) { peer.write("HTTP/1.1 407 Denied\r\n\r\n".toArray()) }
                else if (kind == 1) { peer.write("HTTP/1.1 500 Bad Gateway\r\nContent-Length: 0\r\n\r\n".toArray()) }
                else {
                    peer.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\n".toArray())
                    peer.write([255u8, 254u8])
                }
                try { if (peer.read(one) == 0) { eof.fetchAdd(1) } }
                catch (_: SocketTimeoutException) { () }
                catch (_: SocketException) { let _ = eof.fetchAdd(1) }
            }
        }
        try {
            if (kind == 0) {
                let response = TelegramTransport(proxy: "http://127.0.0.1:${port}", timeoutSeconds: 1,
                    dangerouslyAllowPrivateNetwork: true).get("https://127.0.0.1/joint")
                @Expect(response.ok, false)
                @Expect(response.error.contains("407"), true)
            } else if (kind == 1) {
                let adapter = QQAdapter(config: QQConfig(enabled: true, appId: "joint-fixture", appSecret: "synthetic-only",
                    officialWebsocketUrl: "ws://127.0.0.1:${port}/joint"))
                adapter.debugCacheOfficialTokenForTest("joint-fixture-token")
                try {
                    adapter.start()
                    serving.get(Duration.second * 8)
                    adapter.stop()
                    @Expect(adapter.debugOfficialWorkersForTest(), 0)
                } finally { adapter.stop() }
            } else {
                var decodeFailed = false
                try {
                    let _ = HttpUtils.get("http://127.0.0.1:${port}/joint", HashMap<String, String>(), None, verify: false)
                } catch (_: Exception) { decodeFailed = true }
                // The default curl backend retains the original SDK decode error;
                // the boundary catches it without relying on SDK-specific wording.
                @Expect(decodeFailed, true)
            }
            serving.get(Duration.second * 8)
            @Expect(eof.load(), 1)
        } finally {
            listener.close()
            try { serving.get(Duration.second) } catch (_: Exception) { () }
        }
    }
}

@Test
public class GatewayServeLockLogicTest {
    @TestCase
    public func hrS4B1FormalRecoveryFailureInjectionKeepsEvidenceAndResourcesSafe(): Unit {
        withHrFormalEnvironment("hr-s4-b1", { home, _ =>
            let formal = HrFormalGateway(home)
            try {
                let worker = formal.startPendingGeneration()
                let original = hrFormalPendingProof(formal)
                formal.releaseWorker(worker)
                let sourceLease = gatewayS5FindLease(home)
                let leaseBytes = File.readFrom(sourceLease)
                // Negative fixture copies originate in a real stopped generation.
                // The original home/marker is never mutated by fault injection.
                for (mode in ["timeout", "replacement", "encoding"]) {
                    let negative = home.join("negative-${mode}")
                    Directory.create(negative, recursive: true)
                    setVariable("METIS_HOME", negative.toString())
                    CliConfig.invalidatePathCache()
                    MetisConfigManager.invalidate()
                    CliSettingManager.invalidate()
                    try {
                        var settings = CliSettingManager.readGatewaySettings()
                        settings.enabled = true
                        settings.port = formal.port
                        let _ = MetisConfigManager.setGatewaySettings(settings)
                        CliSettingManager.invalidate()
                        @Expect(gatewayAcquireServeLockForRunningProcess(), true)
                        let leaseDir = negative.join("service-plugin/runtime/gitcode-monitor")
                        Directory.create(leaseDir, recursive: true)
                        File.writeTo(leaseDir.join(sourceLease.fileName), leaseBytes)
                        let marker = negative.join("gateway-serve.stop-complete")
                        File.writeTo(marker, original.toArray())
                        let evidence = gatewayCollectHistoricalRecoveryEvidence(MonoTime.now() + Duration.second * 5)
                        @Expect(evidence.status, "recoverable")
                        let replacement = original.replace("nonce:", "nonce:replacement-中文😀-")
                        if (mode == "replacement") { File.writeTo(marker, replacement.toArray()) }
                        if (mode == "encoding") { File.writeTo(marker, [255u8, 254u8]) }
                        let deadline = if (mode == "timeout") { MonoTime.now() - Duration.millisecond } else { MonoTime.now() + Duration.second * 5 }
                        let committed = gatewayCommitHistoricalRecovery(evidence, deadline)
                        @Expect(committed.ok, false)
                        @Expect(committed.status, if (mode == "timeout") { "deadline_exceeded" } else if (mode == "replacement") { "identity_changed" } else { "invalid_response_encoding" })
                        @Expect(exists(marker), true)
                        if (mode == "encoding") { @Expect(File.readFrom(marker), [255u8, 254u8]) }
                        else { @Expect(hrFormalRead(marker), if (mode == "replacement") { replacement } else { original }) }
                    } finally {
                        gatewayReleaseServeLockQuiet()
                        @Expect(exists(negative.join("gateway-serve.lock")), false)
                        setVariable("METIS_HOME", home.toString())
                        CliConfig.invalidatePathCache()
                        MetisConfigManager.invalidate()
                        CliSettingManager.invalidate()
                    }
                }
                @Expect(hrFormalRead(home.join("gateway-serve.stop-complete")), original)
                hrFormalAssertAllLeasesStopped(home)
                formal.assertClean()
            } finally { formal.cleanup() }
        })
    }

    @TestCase
    public func hrS4P1FormalTwoGenerationNormalRestartStaysClean(): Unit {
        withHrFormalEnvironment("hr-s4-p1", { home, _ =>
            let formal = HrFormalGateway(home)
            try {
                let first = formal.startService("first")
                let firstPluginPid = hrFormalNumber(home.join("first.ready"), "pid")
                let launchCount = AtomicInt64(0)
                let restarted = gatewayExecuteRestartServe(launchServe: { =>
                    let _ = launchCount.fetchAdd(1)
                    @Expect(first.wait(timeout: Some(Duration.second * 2)), 0)
                    @Expect(first.isAlive(), false)
                    @Expect(gatewayServeStopPidAlive(first.pid), false)
                    hrFormalAssertAllLeasesStopped(home)
                    let old = hrFormalRead(home.join("gateway-serve.stop-complete"))
                    @Expect(gatewayServeStopCompletionField(old, "status"), "graceful")
                    @Expect(gatewayServeStopCompletionField(old, "brokerStatus"), "stopped")
                    @Expect(gatewayServeStopCompletionField(old, "brokerExternalTerminal"), "1")
                    @Expect(gatewayServeStopCompletionField(old, "brokerTerminalBasis"), "closed_ack_exit_observed")
                    @Expect(gatewayServeStopCompletionField(old, "fullTerminal"), "1")
                    let _ = formal.startService("second")
                    true
                })
                @Expect(restarted, 0)
                @Expect(launchCount.load(), 1)
                @Expect(formal.current.getOrThrow().pid != first.pid, true)
                @Expect(hrFormalNumber(home.join("second.ready"), "pid") != firstPluginPid, true)
                formal.assertJournal(home.join("first.ready.initializations.jsonl"), firstPluginPid)
                formal.assertJournal(home.join("second.ready.initializations.jsonl"), hrFormalNumber(home.join("second.ready"), "pid"))
                let final = formal.stopCurrent(0)
                @Expect(gatewayServeStopCompletionField(final, "status"), "graceful")
                @Expect(gatewayServeStopCompletionField(final, "brokerStatus"), "stopped")
                @Expect(gatewayServeStopCompletionField(final, "brokerExternalTerminal"), "1")
                @Expect(gatewayServeStopCompletionField(final, "brokerTerminalBasis"), "closed_ack_exit_observed")
                @Expect(gatewayServeStopCompletionField(final, "fullTerminal"), "1")
                @Expect(hrFormalArchiveOriginals(home).size, 0)
                hrFormalAssertAllLeasesStopped(home)
                formal.assertClean()
            } finally { formal.cleanup() }
        })
    }

    @TestCase
    public func hrS4N1FormalActiveCleanupStillRejectsRecovery(): Unit {
        withHrFormalEnvironment("hr-s4-n1", { home, _ =>
            let formal = HrFormalGateway(home)
            try {
                let worker = formal.startPendingGeneration()
                let original = hrFormalPendingProof(formal)
                let port = hrFormalNumber(home.join("old-worker.ready"), "port")
                let checked = gatewayHistoricalServeCompletionRecoveryStatus()
                @Expect(checked.ok, false)
                @Expect(checked.status, "lease_active")
                let launchCount = AtomicInt64(0)
                @Expect(gatewayExecuteRestartServe(launchServe: { => let _ = launchCount.fetchAdd(1); true }), 1)
                @Expect(launchCount.load(), 0)
                @Expect(hrFormalRead(home.join("gateway-serve.stop-complete")), original)
                @Expect(hrFormalArchiveOriginals(home).size, 0)
                @Expect(worker.isAlive(), true)
                @Expect(gatewayServeStopPortListening(port), true)
                @Expect(exists(home.join("old-worker.release")), false)
                // The real active work component self-terminates only on release.
                // Actual blocked host dispatch is additionally covered by the S0/S3 host cases.
                formal.releaseWorker(worker)
                @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "recoverable")
                @Expect(hrFormalRead(home.join("gateway-serve.stop-complete")), original)
                formal.assertClean()
            } finally { formal.cleanup() }
        })
    }

    @TestCase
    public func hrE2e01AbnormalStopLateLeaseTerminalAndRestartPreserveBusinessTruth(): Unit {
        withHrFormalEnvironment("hr-e2e01", { home, _ =>
            let formal = HrFormalGateway(home)
            try { hrFormalRecoveryChain(formal) } finally { formal.cleanup() }
        })
    }

    @TestCase
    public func hrE2e02V4AndExplicitEvidenceDirectServeRecoveryAgree(): Unit {
        for (mode in ["explicit-v1", "legacy-v4", "unsupported"]) {
            withHrFormalEnvironment("hr-e2e02-${mode}", { home, _ =>
                let formal = HrFormalGateway(home)
                try {
                    let first = formal.startService("old", nonzeroBroker: mode == "explicit-v1")
                    let identity = gatewayParseServeIdentity(hrFormalRead(home.join("gateway-serve.lock"))).getOrThrow()
                    let stopped = formal.stopCurrent(if (mode == "explicit-v1") { 1 } else { 0 })
                    @Expect(gatewayServeStopCompletionField(stopped, "brokerStatus"), if (mode == "explicit-v1") { "broker_close_exit_nonzero" } else { "stopped" })
                    let marker = home.join("gateway-serve.stop-complete")
                    let original = if (mode == "explicit-v1") { stopped } else {
                        // Historical producer is an initial input for this direct-serve phase,
                        // not a modified current-writer completion.
                        let historical = hrFormalLegacyProducer(identity, if (mode == "legacy-v4") { "" } else { "99" })
                        remove(marker)
                        File.writeTo(marker, historical.toArray())
                        historical
                    }
                    if (mode == "unsupported") {
                        @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "evidence_version_unsupported")
                        let refused = formal.launchGateway(directServe: true)
                        @Expect(refused.wait(timeout: Some(Duration.second * 2)), 0)
                        @Expect(refused.isAlive(), false)
                        @Expect(gatewayServeStopPidAlive(refused.pid), false)
                        @Expect(hrFormalRead(formal.stdoutFiles.get(refused.pid).getOrThrow()).contains("无法启动"), true)
                        @Expect(hrFormalRead(marker), original)
                        @Expect(hrFormalArchiveOriginals(home).size, 0)
                    } else {
                        @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "recoverable")
                        let second = formal.startService("new", directServe: true)
                        @Expect(second.pid != first.pid, true)
                        @Expect(hrFormalArchiveOriginals(home).size, 1)
                        @Expect(hrFormalArchiveOriginals(home)[0], original)
                        @Expect(exists(marker), false)
                        formal.assertJournal(home.join("new.ready.initializations.jsonl"), hrFormalNumber(home.join("new.ready"), "pid"))
                        let final = formal.stopCurrent(0)
                        @Expect(gatewayServeStopCompletionField(final, "fullTerminal"), "1")
                    }
                    hrFormalAssertAllLeasesStopped(home)
                    formal.assertClean()
                } finally { formal.cleanup() }
            })
        }
    }

    @TestCase
    public func hrFE2e01LocalTransportFailuresThenHistoricalRecoveryAndNewGenerationStop(): Unit {
        withHrFormalEnvironment("hr-joint-e2e01", { home, _ =>
            let formal = HrFormalGateway(home)
            try {
                hrFormalFaultTraffic()
                let before = Directory.readFrom(Path("/dev/fd")).size
                for (_ in 0..4) { hrFormalFaultTraffic() }
                let after = Directory.readFrom(Path("/dev/fd")).size
                @Expect(after <= before + 1, true)
                // This very same case continues from settled fault traffic through
                // a real stop-produced pending marker, competing new CLIs and final stop.
                hrFormalRecoveryChain(formal)
            } finally { formal.cleanup() }
        })
    }


    @TestCase
    public func hrS0U1HistoricalNonterminalSnapshotBlocksDespiteStoppedResources(): Unit {
        hrRuntimeHome({ home, identity =>
            let original = hrRuntimeWriteMarker(identity)
            let _ = hrRuntimeWriteLease(home, identity)
            let result = gatewayHistoricalServeCompletionRecoveryStatus()
            @Expect(result.status, "recoverable")
            @Expect(String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))), original)
        })
    }

    @TestCase
    public func hrS0P1ExistingTerminalSnapshotRecoveryRemainsValid(): Unit {
        this.s5U1StaleCleanupMarkerWithTerminalResourcesCanBeReconciled()
    }

    @TestCase
    public func hrS0N1LiveAndUncertainResourcesRemainBlocked(): Unit {
        this.s5N1CleanupMarkerReconciliationFailsClosed()
        hrRuntimeHome({ home, identity =>
            let _ = hrRuntimeWriteMarker(identity)
            let _ = hrRuntimeWriteLease(home, identity, state: "running")
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().ok, false)
        })
    }

    @TestCase
    public func hrS1U3CompletionPersistsBrokerTerminalEvidence(): Unit {
        hrRuntimeHome({ _, identity =>
            for (terminal in [true, false]) {
                let text = hrRuntimeWriteMarker(identity, legacy: false, terminal: terminal)
                @Expect(gatewayServePayloadField(text, "status"), "cleanup_pending")
                @Expect(gatewayServePayloadField(text, "brokerStatus"), "broker_close_exit_nonzero")
                @Expect(gatewayServePayloadField(text, "recoveryEvidenceVersion"), "1")
                @Expect(gatewayServePayloadField(text, "brokerExternalTerminal"), if (terminal) { "1" } else { "0" })
                @Expect(gatewayServePayloadField(text, "brokerTerminalBasis"), if (terminal) { "closed_ack_exit_observed" } else { "unknown" })
            }
        })
    }

    @TestCase
    public func hrS3P1StopPreviewRestartAndDirectServeShareRecoveryGate(): Unit {
        hrRuntimeHome({ home, identity =>
            let original = hrRuntimeWriteMarker(identity)
            let _ = hrRuntimeWriteLease(home, identity)
            let output = ArrayList<String>()
            setGatewayStopOutputForTest(Some({ line => output.add(line) }))
            @Expect(gatewayExecuteStopServe(), 0)
            @Expect(String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))), original)
            @Expect(gatewayExecuteRestartServe(launchServe: { => gatewayAcquireServeLockForRunningProcess() }), 0)
            @Expect(gatewayPeekServeLockPid().getOrThrow() != identity.pid, true)
            @Expect(exists(home.join("gateway-serve.stop-complete")), false)
            gatewayReleaseServeLockQuiet()
            let _ = hrRuntimeWriteMarker(identity)
            @Expect(gatewayAcquireServeLockForRunningProcess(), true)
            @Expect(exists(home.join("gateway-serve.stop-complete")), false)
        })
    }

    @TestCase
    public func hrS3N1LaunchRechecksChangedPreview(): Unit {
        hrRuntimeHome({ home, identity =>
            let _ = hrRuntimeWriteMarker(identity)
            let lease = hrRuntimeWriteLease(home, identity)
            @Expect(gatewayExecuteStopServe(), 0)
            let original = String.fromUtf8(File.readFrom(lease))
            let result = gatewayExecuteRestartServe(launchServe: { =>
                File.writeTo(lease, original.replace("stopped", "running").toArray())
                gatewayAcquireServeLockForRunningProcess()
            })
            @Expect(result, 1)
            @Expect(exists(home.join("gateway-serve.stop-complete")), true)
            @Expect(exists(home.join("gateway-serve.lock")), false)
            @Expect(String.fromUtf8(File.readFrom(lease)).contains("running"), true)
        })
        hrRuntimeHome({ home, identity =>
            let originalMarker = hrRuntimeWriteMarker(identity)
            let lease = hrRuntimeWriteLease(home, identity)
            @Expect(gatewayExecuteStopServe(), 0)
            let replacement = lease.parent.join("replacement-session.lease.json")
            let payload = JsonValue.fromStr(hrFormalRead(lease)).asObject()
            payload.put("sessionId", JsonString("replacement-session"))
            payload.put("state", JsonString("running"))
            if (payload.get("status").isSome()) { payload.put("status", JsonString("running")) }
            let replacementBytes = payload.toJsonString().toArray()
            let result = gatewayExecuteRestartServe(launchServe: { =>
                remove(lease)
                File.writeTo(replacement, replacementBytes)
                gatewayAcquireServeLockForRunningProcess()
            })
            @Expect(result, 1)
            @Expect(hrFormalRead(home.join("gateway-serve.stop-complete")), originalMarker)
            @Expect(exists(home.join("gateway-serve.lock")), false)
            @Expect(exists(lease), false)
            @Expect(File.readFrom(replacement), replacementBytes)
        })
    }

    @TestCase
    public func hbBrU10HeartbeatCadenceOverrideRequiresCompleteTestIdentity(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let keys = [
                "METIS_TEST_GATEWAY_HEARTBEAT_CADENCE_MODE",
                "METIS_TEST_GATEWAY_HEARTBEAT_CADENCE_NONCE",
                "METIS_TEST_GATEWAY_HEARTBEAT_CADENCE_POLLS"
            ]
            let previous = ArrayList<(String, Option<String>)>()
            for (key in keys) { previous.add((key, getVariable(key))) }
            try {
                for (key in keys) { setVariable(key, "") }
                @Expect(gatewayHeartbeatPollCadenceForTest(), 50)
                setVariable(keys[0], "1")
                @Expect(gatewayHeartbeatPollCadenceForTest(), 50)
                setVariable(keys[0], "1")
                setVariable(keys[1], "wrong-nonce")
                setVariable(keys[2], "2")
                @Expect(gatewayHeartbeatPollCadenceForTest(), 50)
                setVariable(keys[0], "1")
                setVariable(keys[1], "heartbeat-e2e-v1")
                setVariable(keys[2], "1")
                @Expect(gatewayHeartbeatPollCadenceForTest(), 50)
                setVariable(keys[0], "1")
                setVariable(keys[1], "heartbeat-e2e-v1")
                setVariable(keys[2], "2")
                @Expect(gatewayHeartbeatPollCadenceForTest(), 2)
                setVariable(keys[0], "1")
                setVariable(keys[1], "heartbeat-e2e-v1")
                setVariable(keys[2], "5")
                @Expect(gatewayHeartbeatPollCadenceForTest(), 5)
                for (key in keys) {
                    @Expect(getVariable(key).getOrDefault { "" }.trimAscii().isEmpty(), true)
                }
            } finally {
                for ((key, value) in previous) {
                    match (value) {
                        case Some(oldValue) => setVariable(key, oldValue)
                        case None => setVariable(key, "")
                    }
                }
            }
        }
    }

    @TestCase
    public func hbBrU8FormalMetisBinaryOverrideIsStrictAndDefaultsToProjectTarget(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let root = Path("/tmp/metis-hb-formal-bin-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            let project = root.join("project")
            let binary = root.join("metis")
            let previous = getVariable("METIS_TEST_BIN")
            try {
                Directory.create(root, recursive: true)
                File.writeTo(binary, "fixture".toArray())

                setVariable("METIS_TEST_BIN", "")
                let defaultValue = gatewayFormalMetisBinary(project)
                @Expect(defaultValue.isSome(), true)
                if (defaultValue.isNone()) { return }
                @Expect(defaultValue.getOrThrow().toString(), project.join("target").join("release").join("bin").join("metis").toString())

                setVariable("METIS_TEST_BIN", binary.toString())
                let validValue = gatewayFormalMetisBinary(project)
                @Expect(validValue.isSome(), true)
                if (validValue.isSome()) {
                    @Expect(validValue.getOrThrow().toString(), binary.toString())
                }

                setVariable("METIS_TEST_BIN", "relative/metis")
                @Expect(gatewayFormalMetisBinary(project).isNone(), true)
                setVariable("METIS_TEST_BIN", root.join("missing").toString())
                @Expect(gatewayFormalMetisBinary(project).isNone(), true)
            } finally {
                match (previous) {
                    case Some(value) => setVariable("METIS_TEST_BIN", value)
                    case None => setVariable("METIS_TEST_BIN", "")
                }
                try { remove(root, recursive: true) } catch (_: Exception) { () }
            }
        }
    }

    @TestCase
    public func hbBrU3ShutdownStopsProcessIoBeforeClosingBroker(): Unit {
        let project = Path(managedStdioResolveBrokerScriptPath()).parent.parent
        let source = try {
            String.fromUtf8(File.readFrom(project.join("src").join("gateway").join("runtime").join("demo.cj")))
        } catch (_: Exception) {
            ""
        }
        @Expect(source.isEmpty(), false)
        if (source.isEmpty()) { return }
        let memoryStop = source.indexOf("MemoryRuntime.stopActiveMaintenance()")
        let canvasStop = source.indexOf("GatewayCanvasHostRuntime.stopDetailed(shutdownDeadline)")
        let httpStop = source.indexOf(
            "GatewayHttpSurface.stopDetailed(shutdownDeadline, shutdownIdentity: serveIdentity)"
        )
        let serverStop = source.indexOf("GatewayServer.defaultServer().stopServerDetailed(reason: \"gateway-serve-shutdown\")")
        let gatewayStop = source.indexOf("let gatewayStop = try {")
        @Expect(memoryStop.isSome(), true)
        @Expect(canvasStop.isSome(), true)
        @Expect(httpStop.isSome(), true)
        @Expect(serverStop.isSome(), true)
        @Expect(gatewayStop.isSome(), true)
        if (!memoryStop.isSome() || !canvasStop.isSome() || !httpStop.isSome() ||
            !serverStop.isSome() || !gatewayStop.isSome()) { return }
        let brokerBoundary = gatewayStop.getOrThrow()
        @Expect(memoryStop.getOrThrow() < brokerBoundary, true)
        @Expect(canvasStop.getOrThrow() < brokerBoundary, true)
        @Expect(httpStop.getOrThrow() < brokerBoundary, true)
        @Expect(serverStop.getOrThrow() < brokerBoundary, true)
    }

    @TestCase
    public func oomS0H1RuntimeHeapLifecycleScopesAreOrdered(): Unit {
        let project = Path(managedStdioResolveBrokerScriptPath()).parent.parent
        let source = try {
            String.fromUtf8(File.readFrom(project.join("src").join("gateway").join("runtime").join("demo.cj")))
        } catch (_: Exception) {
            ""
        }
        @Expect(source.isEmpty(), false)
        if (source.isEmpty()) { return }
        let startup = source.indexOf("gatewayLogProcessMemory(\"serve:startup_begin\")")
        let before = source.indexOf("gatewayLogProcessMemory(\"serve:gateway_start_before\")")
        let startCall = source.indexOf("        gateway.start()\n        gatewayLogProcessMemory(\"serve:gateway_start_after\")")
        let after = source.indexOf("gatewayLogProcessMemory(\"serve:gateway_start_after\")")
        let ready = source.indexOf("gatewayLogProcessMemory(\"serve:ready\")")
        let stop = source.indexOf("gatewayLogProcessMemory(\"serve:stop_begin\")")
        @Expect(startup.isSome(), true)
        @Expect(before.isSome(), true)
        @Expect(startCall.isSome(), true)
        @Expect(after.isSome(), true)
        @Expect(ready.isSome(), true)
        @Expect(stop.isSome(), true)
        if (startup.isNone() || before.isNone() || startCall.isNone() || after.isNone() || ready.isNone() || stop.isNone()) {
            return
        }
        @Expect(startup.getOrThrow() < before.getOrThrow(), true)
        @Expect(before.getOrThrow() < startCall.getOrThrow(), true)
        @Expect(startCall.getOrThrow() < after.getOrThrow(), true)
        @Expect(after.getOrThrow() < ready.getOrThrow(), true)
        @Expect(ready.getOrThrow() < stop.getOrThrow(), true)
    }

    @TestCase
    public func hbBrN6ShutdownPhaseMarkersPreserveSurfaceOrderAndIdentity(): Unit {
        withGatewayHeartbeatProbeEnvironment("hb-br-n6-phase", {root, _bin =>
            let instance = currentProcessInstanceIdentity()
            @Expect(instance.isSome(), true)
            if (instance.isNone()) { return }
            let identity = GatewayServeIdentity(
                Int64(getProcessId()),
                DateTime.now().toUnixTimeStamp().toMilliseconds(),
                "hb-br-n6-phase",
                processIdentity: instance
            )
            let markerBase = root.join("shutdown-phase")
            let previousMarker = getVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_MARKER")
            let previousNonce = getVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_NONCE")
            setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_MARKER", markerBase.toString())
            setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_NONCE", "hb-br-n6-nonce")
            try {
                @Expect(gatewayPublishShutdownPhaseForTest(identity, "canvas_done"), false)
                for ((sequence, phase) in [
                    (Int64(1), "stop_request_observed"),
                    (Int64(2), "canvas_done"),
                    (Int64(3), "http_close_enter"),
                    (Int64(4), "http_close_returned"),
                    (Int64(5), "http_probe_done"),
                    (Int64(6), "gateway_stop_enter"),
                    (Int64(7), "owners_enter"),
                    (Int64(8), "owners_done"),
                    (Int64(9), "channels_enter"),
                    (Int64(10), "channels_done"),
                    (Int64(11), "broker_enter"),
                    (Int64(12), "broker_done"),
                    (Int64(13), "gateway_stop_returned"),
                    (Int64(14), "completion_written")
                ]) {
                    @Expect(gatewayPublishShutdownPhaseForTest(identity, phase), true)
                    let markerPath = Path("${markerBase.toString()}.${sequence}.json")
                    let markerProof = try {
                        let marker = JsonValue.fromStr(String.fromUtf8(File.readFrom(markerPath))).asObject()
                        (marker.get("phase").getOrThrow().asString().getValue() == phase &&
                            marker.get("sequence").getOrThrow().asInt().getValue() == sequence &&
                            marker.get("pid").getOrThrow().asInt().getValue() == identity.pid &&
                            marker.get("startedAtMs").getOrThrow().asInt().getValue() == identity.startedAtMs &&
                            marker.get("nonce").getOrThrow().asString().getValue() == identity.nonce &&
                            marker.get("processIdentity").getOrThrow().asString().getValue() ==
                                identity.processIdentity.getOrThrow().serialize() &&
                            marker.get("testNonce").getOrThrow().asString().getValue() == "hb-br-n6-nonce",
                            marker.get("observedMonotonicMs").getOrThrow().asInt().getValue())
                    } catch (_: Exception) {
                        (false, Int64(-1))
                    }
                    @Expect(markerProof[0], true)
                    @Expect(markerProof[1] >= 0, true)
                    if (sequence > 1) {
                        let previousObserved = try {
                            let previousMarker = JsonValue.fromStr(String.fromUtf8(File.readFrom(
                                Path("${markerBase.toString()}.${sequence - 1}.json")
                            ))).asObject()
                            previousMarker.get("observedMonotonicMs").getOrThrow().asInt().getValue()
                        } catch (_: Exception) {
                            Int64(-1)
                        }
                        @Expect(previousObserved >= 0, true)
                        @Expect(markerProof[1] >= previousObserved, true)
                    }
                    let mode = executeWithOutput("/usr/bin/stat", ["-f", "%Lp", markerPath.toString()])
                    @Expect(mode[0], 0)
                    let modeText = try { String.fromUtf8(mode[1]).trimAscii() } catch (_: Exception) { "" }
                    @Expect(modeText, "600")
                }

                let project = Path(managedStdioResolveBrokerScriptPath()).parent.parent
                let demo = try {
                    String.fromUtf8(File.readFrom(
                        project.join("src").join("gateway").join("runtime").join("demo.cj")
                    ))
                } catch (_: Exception) {
                    ""
                }
                let http = try {
                    String.fromUtf8(File.readFrom(
                        project.join("src").join("gateway").join("runtime").join("gateway_http_surface.cj")
                    ))
                } catch (_: Exception) {
                    ""
                }
                @Expect(!demo.isEmpty() && !http.isEmpty(), true)
                if (demo.isEmpty() || http.isEmpty()) { return }
                let canvasStop = demo.indexOf("GatewayCanvasHostRuntime.stopDetailed(shutdownDeadline)")
                let canvasDone = demo.indexOf("gatewayPublishShutdownPhaseForTest(identity, \"canvas_done\")")
                let httpStop = demo.indexOf("GatewayHttpSurface.stopDetailed(shutdownDeadline, shutdownIdentity: serveIdentity)")
                let gatewayStop = demo.indexOf("gatewayPublishShutdownPhaseForTest(identity, \"gateway_stop_enter\")")
                let observerCall = demo.indexOf("gateway.stop(shutdownObserver: shutdownObserver)")
                let gatewayReturned = demo.indexOf("gatewayPublishShutdownPhaseForTest(identity, \"gateway_stop_returned\")")
                @Expect(canvasStop.isSome() && canvasDone.isSome() && httpStop.isSome() && gatewayStop.isSome() &&
                    observerCall.isSome() && gatewayReturned.isSome(), true)
                if (!canvasStop.isSome() || !canvasDone.isSome() || !httpStop.isSome() || !gatewayStop.isSome() ||
                    !observerCall.isSome() || !gatewayReturned.isSome()) { return }
                @Expect(canvasStop.getOrThrow() < canvasDone.getOrThrow(), true)
                @Expect(canvasDone.getOrThrow() < httpStop.getOrThrow(), true)
                @Expect(httpStop.getOrThrow() < gatewayStop.getOrThrow(), true)
                @Expect(gatewayStop.getOrThrow() < observerCall.getOrThrow(), true)
                @Expect(observerCall.getOrThrow() < gatewayReturned.getOrThrow(), true)

                let closeEnter = http.indexOf("gatewayPublishShutdownPhaseForTest(identity, \"http_close_enter\")")
                let closeCall = http.indexOf("case Some(s) => s.close()")
                let probeCall = http.indexOf("gatewayServePortReleasedUntil(detached[2], deadline)")
                @Expect(closeEnter.isSome() && closeCall.isSome() && probeCall.isSome(), true)
                if (!closeEnter.isSome() || !closeCall.isSome() || !probeCall.isSome()) { return }
                let closeReturned = http.indexOf(
                    "gatewayPublishShutdownPhaseForTest(identity, \"http_close_returned\")",
                    closeCall.getOrThrow()
                )
                let probeDone = http.indexOf(
                    "gatewayPublishShutdownPhaseForTest(identity, \"http_probe_done\")",
                    probeCall.getOrThrow()
                )
                @Expect(closeEnter.isSome() && closeCall.isSome() && closeReturned.isSome() && probeCall.isSome() && probeDone.isSome(), true)
                if (!closeEnter.isSome() || !closeCall.isSome() || !closeReturned.isSome() || !probeCall.isSome() || !probeDone.isSome()) { return }
                @Expect(closeEnter.getOrThrow() < closeCall.getOrThrow(), true)
                @Expect(closeCall.getOrThrow() < closeReturned.getOrThrow(), true)
                @Expect(closeReturned.getOrThrow() < probeCall.getOrThrow(), true)
                @Expect(probeCall.getOrThrow() < probeDone.getOrThrow(), true)
            } finally {
                match (previousMarker) {
                    case Some(value) => setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_MARKER", value)
                    case None => setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_MARKER", "")
                }
                match (previousNonce) {
                    case Some(value) => setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_NONCE", value)
                    case None => setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_NONCE", "")
                }
            }
        })
    }

    @TestCase
    public func hbBrD2ClassifiesOriginalReparentedAndUnexpectedBrokerParents(): Unit {
        let root = Path("/tmp/metis-hb-br-d2-cj-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        try {
            Directory.create(root, recursive: true)
            for ((observedParentPid, expectedStatus) in [
                (Int64(24626), "original_parent"),
                (Int64(1), "reparented"),
                (Int64(31313), "unexpected_parent")
            ]) {
                let fileName = "broker-g7-p27182.json"
                let path = root.join(fileName)
                File.writeTo(
                    path,
                    ("{\"protocolVersion\":\"1.0\",\"generation\":7,\"brokerPid\":27182," +
                        "\"startParentPid\":24626,\"observedParentPid\":${observedParentPid},\"sequence\":1," +
                        "\"events\":[{\"sequence\":1,\"event\":\"broker_started\"}]," +
                        "\"closeEntryCount\":0,\"closeEntryOwnerCount\":-1,\"ownerTerminalCount\":0," +
                        "\"ownerStartCounts\":{\"service_plugin\":0,\"pid_probe\":0,\"lsof_probe\":0,\"other\":0}," +
                        "\"ownerTerminalCounts\":{\"service_plugin\":0,\"pid_probe\":0,\"lsof_probe\":0,\"other\":0}," +
                        "\"brokerClosedEnqueuedCount\":0,\"brokerClosedCallbackCount\":0," +
                        "\"closeAckCallbackSeen\":false,\"writerFailureKind\":\"\",\"writerFailurePhase\":\"\"," +
                        "\"ownerCount\":0,\"exitScheduledCount\":0,\"lastExitScheduledCode\":-1," +
                        "\"closing\":false,\"closeFinished\":false}\n").toArray()
                )
                let value = GatewayHeartbeatBrokerDiagnostic(path, fileName: fileName)
                @Expect(value.valid, true)
                @Expect(value.parseStatus, "schema_valid")
                @Expect(value.filenameMatches, true)
                @Expect(value.parentStatus(24626), expectedStatus)
            }
        } finally {
            try { remove(root, recursive: true) } catch (_: Exception) { () }
            @Expect(exists(root), false)
        }
    }

    @TestCase
    public func hbBrD3ClassifiesTemporaryEvidenceAndStaleSlotMismatch(): Unit {
        let root = Path("/tmp/metis-hb-br-d3-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        let temporaryRoot = root.join("temporary")
        let staleSlotRoot = root.join("stale-slot")
        try {
            Directory.create(temporaryRoot, recursive: true)
            File.writeTo(temporaryRoot.join("broker-g1-p2.json.tmp-2"), "{}".toArray())
            let temporary = GatewayHeartbeatBrokerDirectoryProof(temporaryRoot)
            @Expect(temporary.status, "temp_present")
            @Expect(temporary.identityCount, 0)
            @Expect(temporary.slotCount, 0)
            @Expect(temporary.tempCount, 1)
            @Expect(temporary.overflow, false)

            Directory.create(staleSlotRoot.join(".identity-slot-0"), recursive: true)
            let staleSlot = GatewayHeartbeatBrokerDirectoryProof(staleSlotRoot)
            @Expect(staleSlot.status, "slot_identity_mismatch")
            @Expect(staleSlot.identityCount, 0)
            @Expect(staleSlot.slotCount, 1)
            @Expect(staleSlot.tempCount, 0)
            @Expect(staleSlot.overflow, false)
        } finally {
            try { remove(root, recursive: true) } catch (_: Exception) { () }
            @Expect(exists(root), false)
        }
    }

    @TestCase
    public func s1U1ListenerDiscoveryTimeoutIsStableAndNonThrowing(): Unit {
        withGatewayHeartbeatProbeEnvironment("s1-u1", {_root, bin =>
            gatewayHeartbeatProbeExecutable(bin.join("lsof"), "sleep 1\nprintf '24626\\n'")
            let result = gatewayFindVerifiedListenerPidsOnPortDetailed(port: 49101, timeoutMs: 30)
            @Expect(result.conclusive, false)
            @Expect(result.pids.size, 0)
            @Expect(result.status, "listener_discovery_timeout")
        })
    }

    @TestCase
    public func s1B1ExpiredDiscoveryDeadlineDoesNotStartShellOrBroker(): Unit {
        withGatewayHeartbeatProbeEnvironment("s1-b1", {root, bin =>
            let marker = root.join("lsof-called")
            gatewayHeartbeatProbeExecutable(bin.join("lsof"), "printf called > '${marker.toString()}'\nexit 1")
            let before = gatewayStdioBrokerSnapshot()
            let result = gatewayFindVerifiedListenerPidsOnPortUntil(
                MonoTime.now() - Duration.millisecond,
                port: 49102
            )
            let after = gatewayStdioBrokerSnapshot()
            @Expect(result.conclusive, false)
            @Expect(result.status, "listener_discovery_timeout")
            @Expect(exists(marker), false)
            @Expect(
                after.get("running").getOrThrow().asBool().getValue(),
                before.get("running").getOrThrow().asBool().getValue()
            )
            @Expect(
                after.get("ownerCount").getOrThrow().asInt().getValue(),
                before.get("ownerCount").getOrThrow().asInt().getValue()
            )
        })
    }

    @TestCase
    public func s1P1NoListenerExitIsConclusive(): Unit {
        withGatewayHeartbeatProbeEnvironment("s1-p1", {root, bin =>
            let marker = root.join("lsof-called")
            let brokerLauncher = bin.join("node-with-isolated-path")
            let brokerPath = getVariable("PATH").getOrDefault { "" }.trimAscii()
            let oldNodeCommand = getVariable("METIS_STDIO_BROKER_NODE_COMMAND")
            let oldBrokerPathCarrier = getVariable("METIS_TEST_S1P1_BROKER_PATH")
            @Expect(brokerPath.isEmpty(), false)
            if (brokerPath.isEmpty()) { return }
            gatewayHeartbeatProbeExecutable(
                bin.join("lsof"),
                "printf called > '${marker.toString()}'\nexit 1"
            )
            gatewayHeartbeatProbeExecutable(
                brokerLauncher,
                "export PATH=\"$METIS_TEST_S1P1_BROKER_PATH\"\nunset METIS_TEST_S1P1_BROKER_PATH\nexec node \"$@\""
            )
            try {
                setVariable("METIS_TEST_S1P1_BROKER_PATH", brokerPath)
                setVariable("METIS_STDIO_BROKER_NODE_COMMAND", brokerLauncher.toString())
                let setupReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                @Expect(setupReset.ok, true)
                let setupStopped = gatewayHeartbeatBrokerIsFullyStopped()
                if (!setupReset.ok || !setupStopped) { return }
                let brokerReady = gatewayStdioBrokerReady(timeoutMs: 5000)
                @Expect(brokerReady.ok, true)
                @Expect(brokerReady.status, "ready")
                @Expect(brokerReady.generation > 0, true)
                @Expect(brokerReady.pid > 1, true)
                if (!brokerReady.ok || brokerReady.status != "ready" ||
                    brokerReady.generation <= 0 || brokerReady.pid <= 1) { return }
                let before = managedStdioBroker().snapshot()
                @Expect(before.running, true)
                @Expect(before.responsive, true)
                @Expect(before.generation, brokerReady.generation)
                @Expect(before.brokerPid, brokerReady.pid)
                @Expect(before.ownerCount, 0)
                let result = gatewayFindVerifiedListenerPidsOnPortDetailed(port: 49103, timeoutMs: 800)
                let after = managedStdioBroker().snapshot()
                @Expect(exists(marker), true)
                @Expect(result.conclusive, true)
                @Expect(result.pids.size, 0)
                @Expect(result.status, "no_listener")
                @Expect(after.generation, before.generation)
                @Expect(after.brokerPid, before.brokerPid)
                @Expect(after.ownerCount, 0)
            } finally {
                let finalReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                @Expect(finalReset.ok, true)
                let _ = gatewayHeartbeatBrokerIsFullyStopped()
                match (oldNodeCommand) {
                    case Some(value) => setVariable("METIS_STDIO_BROKER_NODE_COMMAND", value)
                    case None => setVariable("METIS_STDIO_BROKER_NODE_COMMAND", "")
                }
                match (oldBrokerPathCarrier) {
                    case Some(value) => setVariable("METIS_TEST_S1P1_BROKER_PATH", value)
                    case None => setVariable("METIS_TEST_S1P1_BROKER_PATH", "")
                }
            }
        })
    }

    @TestCase
    public func s1N1ListenerDiscoveryFailureIsStableAndRedacted(): Unit {
        withGatewayHeartbeatProbeEnvironment("s1-n1", {_root, bin =>
            gatewayHeartbeatProbeExecutable(bin.join("lsof"), "printf 'private-detail' >&2\nexit 2")
            let result = gatewayFindVerifiedListenerPidsOnPortDetailed(port: 49104, timeoutMs: 800)
            @Expect(result.conclusive, false)
            @Expect(result.pids.size, 0)
            @Expect(result.status, "listener_discovery_failed")
            @Expect(result.status.contains("private-detail"), false)
        })
    }

    @TestCase
    public func s1N2InconclusiveListenerProbePreservesLiveLockTruth(): Unit {
        withGatewayHeartbeatProbeEnvironment("s1-n2", {_root, bin =>
            gatewayHeartbeatProbeExecutable(bin.join("lsof"), "exit 1")
            @Expect(gatewayAcquireServeLockForRunningProcess(), true)
            gatewayHeartbeatProbeExecutable(bin.join("lsof"), "sleep 1\nexit 1")
            @Expect(gatewayAnotherServeInstanceSeemsRunning(), true)
            @Expect(exists(gatewayServeLockPath()), true)
        })
    }

    @TestCase
    public func hbBrN5SurfacePortProbeCapsHangingLsofAndFailsClosed(): Unit {
        withGatewayHeartbeatProbeEnvironment("hb-br-n5-surface", {root, _bin =>
            let marker = root.join("lsof-called")
            let callCount = AtomicInt64(0)
            try {
                setGatewayServePortProbeForTest(Some({port: Int64, budgetMs: Int64 =>
                    callCount.fetchAdd(1)
                    @Expect(port, 49107)
                    @Expect(budgetMs > 0 && budgetMs <= 500, true)
                    File.writeTo(marker, "called\n".toArray())
                    throw ShellTimeoutException("test port probe timed out")
                }))
                let started = MonoTime.now()
                let result = gatewayServePortReleasedUntil(49107, MonoTime.now() + Duration.second * 5)
                let elapsedMs = (MonoTime.now() - started).toMilliseconds()
                @Expect(exists(marker), true)
                @Expect(callCount.load(), 1)
                @Expect(result.ok, false)
                @Expect(result.status, "cleanup_pending")
                @Expect(result.portStatus, "port_probe_timeout")
                @Expect(elapsedMs < 1000, true)
                let instance = currentProcessInstanceIdentity()
                @Expect(instance.isSome(), true)
                if (instance.isNone()) { return }
                let identity = GatewayServeIdentity(
                    Int64(getProcessId()),
                    DateTime.now().toUnixTimeStamp().toMilliseconds(),
                    "hb-br-n5-surface",
                    processIdentity: instance
                )
                gatewayShutdownPhaseNegativeProof(root, identity)
                @Expect(gatewayWriteServeCompletionMarker(
                    identity,
                    GatewayStopResult(false, "cleanup_pending"),
                    httpStatus: result.status
                ), true)
                let completion = try {
                    String.fromUtf8(File.readFrom(root.join("gateway-serve.stop-complete")))
                } catch (_: Exception) {
                    ""
                }
                @Expect(gatewayServeStopCompletionField(completion, "status"), "cleanup_pending")
            } finally {
                setGatewayServePortProbeForTest(None<(Int64, Int64) -> (Int64, String, String)>)
            }
        })
    }

    @TestCase
    public func hbBrB3SurfacePortReleaseHasLocalTotalBudget(): Unit {
        withGatewayHeartbeatProbeEnvironment("hb-br-b3-surface", {_root, _bin =>
            let callCount = AtomicInt64(0)
            try {
                setGatewayServePortProbeForTest(Some({_port: Int64, _budgetMs: Int64 =>
                    callCount.fetchAdd(1)
                    (Int64(0), "", "")
                }))
                let started = MonoTime.now()
                let result = gatewayServePortReleasedUntil(49108, MonoTime.now() + Duration.second * 60)
                let elapsedMs = (MonoTime.now() - started).toMilliseconds()
                @Expect(callCount.load() > 1, true)
                @Expect(elapsedMs < 3000, true)
                @Expect(result.ok, false)
                @Expect(result.status, "cleanup_pending")
                @Expect(result.portStatus, "port_release_timeout")
            } finally {
                setGatewayServePortProbeForTest(None<(Int64, Int64) -> (Int64, String, String)>)
            }
        })
    }

    @TestCase
    public func hbBrU4SurfacePortReleaseStillObservesReleasedListener(): Unit {
        withGatewayHeartbeatProbeEnvironment("hb-br-u4-surface", {_root, _bin =>
            let callCount = AtomicInt64(0)
            try {
                setGatewayServePortProbeForTest(Some({_port: Int64, _budgetMs: Int64 =>
                    let previousCallCount = callCount.fetchAdd(1)
                    if (previousCallCount == 0) { (Int64(0), "", "") } else { (Int64(1), "", "") }
                }))
                let result = gatewayServePortReleasedUntil(49109, MonoTime.now() + Duration.second * 60)
                @Expect(callCount.load(), 2)
                @Expect(result.ok, true)
                @Expect(result.status, "stopped")
                @Expect(result.portStatus, "released")
            } finally {
                setGatewayServePortProbeForTest(None<(Int64, Int64) -> (Int64, String, String)>)
            }
        })
    }

    @TestCase
    public func hS1U1VerifiedListenerPidsRemainHistoricalTruth(): Unit {
        withGatewayHeartbeatProbeEnvironment("h-s1-u1", {root, bin =>
            let lsofMarker = root.join("lsof-called")
            let psMarker = root.join("ps-called")
            gatewayHeartbeatProbeExecutable(bin.join("lsof"), "printf called > '${lsofMarker.toString()}'\nprintf '24626\\n'")
            gatewayHeartbeatProbeExecutable(bin.join("ps"), "printf called > '${psMarker.toString()}'\nprintf 'metis gateway serve\\n'")
            let result = gatewayFindVerifiedListenerPidsOnPortDetailed(port: 49105, timeoutMs: 3000)
            @Expect(result.conclusive, true)
            @Expect(result.status, "listeners_verified")
            @Expect(result.pids.size, 1)
            @Expect(exists(lsofMarker), true)
            @Expect(exists(psMarker), true)
            if (result.pids.size != 1) { return }
            @Expect(result.pids[0], 24626)
        })
    }

    @TestCase
    public func hS1N1InvalidUtf8ListenerOutputIsStable(): Unit {
        withGatewayHeartbeatProbeEnvironment("h-s1-n1", {_root, bin =>
            gatewayHeartbeatProbeExecutable(bin.join("lsof"), "printf '\\377\\376\\375'")
            let result = gatewayFindVerifiedListenerPidsOnPortDetailed(port: 49106, timeoutMs: 800)
            @Expect(result.conclusive, false)
            @Expect(result.pids.size, 0)
            @Expect(result.status, "invalid_response_encoding")
        })
    }

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
    public func s5U1StaleCleanupMarkerWithTerminalResourcesCanBeReconciled(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let home = Path("/tmp/metis-s5-stale-cleanup-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            let port = gatewayServeStopTemporaryPort()
            let oldHome = getVariable("METIS_HOME")
            let oldPath = getVariable("PATH")
            try {
                @Expect(port > 0, true)
                Directory.create(home, recursive: true)
                setVariable("METIS_HOME", home.toString())
                let bin = home.join("bin")
                Directory.create(bin, recursive: true)
                if (InfoUtils.os == "macos") {
                    SymbolicLink.create(bin.join("lsof"), to: Path("/usr/bin/false"))
                } else {
                    gatewayHeartbeatProbeExecutable(bin.join("lsof"), "exit 1")
                }
                let inheritedPath = match (oldPath) { case Some(value) => value case None => "/usr/bin:/bin" }
                setVariable("PATH", "${bin.toString()}:${inheritedPath}")
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                var settings = CliSettingManager.readGatewaySettings()
                settings.port = port
                let persistedSettings = MetisConfigManager.setGatewaySettings(settings)
                @Expect(persistedSettings.port, port)
                CliSettingManager.invalidate()
                let initialReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                @Expect(initialReset.ok, true)
                if (!initialReset.ok) { return }
                let current = currentProcessInstanceIdentity().getOrThrow()
                let stale = gatewayServeStaleProcessIdentity(current)
                let identity = GatewayServeIdentity(
                    stale.pid,
                    DateTime.now().toUnixTimeStamp().toMilliseconds(),
                    "历史-cleanup-🙂",
                    processIdentity: Some(stale)
                )
                @Expect(
                    gatewayWriteServeCompletionMarker(
                        identity,
                        gatewayServeHistoricalCleanupResult(),
                        httpStatus: "stopped",
                        canvasStatus: "already_stopped",
                        gatewayServerStatus: "stopped"
                    ),
                    true
                )
                let marker = home.join("gateway-serve.stop-complete")
                @Expect(exists(marker), true)
                let recoverable = gatewayHistoricalServeCompletionRecoveryStatus()
                @Expect(recoverable.ok, true)
                @Expect(recoverable.status, "recoverable")
                @Expect(exists(marker), true)
                let withoutLock = gatewayReconcileHistoricalServeCompletion()
                @Expect(withoutLock.ok, false)
                @Expect(withoutLock.status, "lock_not_owned")
                @Expect(exists(marker), true)
                @Expect(gatewayAcquireServeLockForRunningProcess(), true)
                @Expect(exists(marker), false)
                gatewayReleaseServeLockQuiet()

                @Expect(
                    gatewayWriteServeCompletionMarker(
                        identity,
                        gatewayServeHistoricalCleanupResult(),
                        httpStatus: "stopped",
                        canvasStatus: "already_stopped",
                        gatewayServerStatus: "stopped"
                    ),
                    true
                )
                let output = ArrayList<String>()
                setGatewayStopOutputForTest(Some({ line => output.add(line) }))
                @Expect(gatewayExecuteStopServe(), 0)
                setGatewayStopOutputForTest(None<(String) -> Unit>)
                @Expect(exists(marker), true)
                @Expect(String.join(output.toArray(), delimiter: "\n").contains("未发现"), true)
                @Expect(gatewayAcquireServeLockForRunningProcess(), true)
                @Expect(exists(marker), false)
                gatewayReleaseServeLockQuiet()
            } finally {
                setGatewayStopOutputForTest(None<(String) -> Unit>)
                gatewayReleaseServeLockQuiet()
                let finalReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                @Expect(finalReset.ok, true)
                let broker = gatewayStdioBrokerSnapshot()
                @Expect(broker.get("running").getOrThrow().asBool().getValue(), false)
                @Expect(broker.get("brokerPid").getOrThrow().asInt().getValue(), 0)
                @Expect(broker.get("ownerCount").getOrThrow().asInt().getValue(), 0)
                @Expect(broker.get("readerCount").getOrThrow().asInt().getValue(), 0)
                match (oldHome) {
                    case Some(value) => setVariable("METIS_HOME", value)
                    case None => setVariable("METIS_HOME", "")
                }
                match (oldPath) { case Some(value) => setVariable("PATH", value) case None => setVariable("PATH", "") }
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                try { remove(home, recursive: true) } catch (_: Exception) { () }
            }
        }
    }

    @TestCase
    public func s5N1CleanupMarkerReconciliationFailsClosed(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let home = Path("/tmp/metis-s5-unsafe-cleanup-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            let oldHome = getVariable("METIS_HOME")
            try {
                Directory.create(home, recursive: true)
                setVariable("METIS_HOME", home.toString())
                CliConfig.invalidatePathCache()
                let current = currentProcessInstanceIdentity().getOrThrow()
                let aliveIdentity = GatewayServeIdentity(
                    current.pid,
                    DateTime.now().toUnixTimeStamp().toMilliseconds(),
                    "alive-🙂",
                    processIdentity: Some(current)
                )
                @Expect(
                    gatewayWriteServeCompletionMarker(
                        aliveIdentity,
                        gatewayServeHistoricalCleanupResult(),
                        httpStatus: "stopped",
                        canvasStatus: "already_stopped",
                        gatewayServerStatus: "stopped"
                    ),
                    true
                )
                let marker = home.join("gateway-serve.stop-complete")
                let alive = gatewayHistoricalServeCompletionRecoveryStatus()
                @Expect(alive.ok, false)
                @Expect(alive.status, "identity_alive")
                @Expect(exists(marker), true)
                @Expect(gatewayAcquireServeLockForRunningProcess(), false)

                remove(marker)
                let stale = gatewayServeStaleProcessIdentity(current)
                let staleIdentity = GatewayServeIdentity(
                    stale.pid,
                    DateTime.now().toUnixTimeStamp().toMilliseconds(),
                    "unsafe-🙂",
                    processIdentity: Some(stale)
                )
                @Expect(
                    gatewayWriteServeCompletionMarker(
                        staleIdentity,
                        gatewayServeHistoricalCleanupResult(leaseStatus: "cleanup_pending"),
                        httpStatus: "stopped",
                        canvasStatus: "already_stopped",
                        gatewayServerStatus: "stopped"
                    ),
                    true
                )
                let nonTerminal = gatewayHistoricalServeCompletionRecoveryStatus()
                @Expect(nonTerminal.ok, false)
                @Expect(nonTerminal.status, "resources_not_terminal")
                @Expect(exists(marker), true)
                @Expect(gatewayExecuteStopServe(), 1)
                @Expect(exists(marker), true)

                remove(marker)
                File.writeTo(marker, [0xffu8, 0xfeu8, 0xfdu8])
                let invalid = gatewayHistoricalServeCompletionRecoveryStatus()
                @Expect(invalid.ok, false)
                @Expect(invalid.status, "invalid_response_encoding")
                @Expect(exists(marker), true)
            } finally {
                setGatewayStopOutputForTest(None<(String) -> Unit>)
                gatewayReleaseServeLockQuiet()
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
            let brokerEnvironmentKeys = [
                "METIS_STDIO_BROKER_NODE_COMMAND", "METIS_S5_BROKER_PROXY_READY",
                "METIS_S5_BROKER_PROXY_FAIL", "METIS_S5_BROKER_PROXY_WRITER_CLOSED",
                "METIS_S5_BROKER_PROXY_CLEANUP", "METIS_S5_BROKER_PROXY_DROP_DELIVERY_ID",
                "METIS_S5_BROKER_PROXY_ADMISSION_SEEN", "METIS_S5_BROKER_PROXY_COMPLETION_DROPPED",
                "METIS_S5_BROKER_PROXY_HOLD_ENTERED", "METIS_S5_BROKER_PROXY_HOLD_RELEASE",
                "METIS_S5_BROKER_PROXY_HOLD_RELEASED"
            ]
            let oldBrokerEnvironment = ArrayList<(String, Option<String>)>()
            for (key in brokerEnvironmentKeys) { oldBrokerEnvironment.add((key, getVariable(key))) }
            let brokerScript = Path(managedStdioResolveBrokerScriptPath())
            let project = brokerScript.parent.parent
            let binaryValue = gatewayFormalMetisBinary(project)
            @Expect(binaryValue.isSome(), true)
            if (binaryValue.isNone()) { return }
            let binary = binaryValue.getOrThrow()
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
                for (key in brokerEnvironmentKeys) { setVariable(key, "") }
                let parentSetupReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                @Expect(parentSetupReset.ok, true)
                let parentSetupStopped = gatewayHeartbeatBrokerIsFullyStopped()
                if (!parentSetupReset.ok || !parentSetupStopped) { return }
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
                let parentFinalReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                @Expect(parentFinalReset.ok, true)
                for ((key, value) in oldBrokerEnvironment) {
                    match (value) {
                        case Some(previous) => setVariable(key, previous)
                        case None => setVariable(key, "")
                    }
                }
                let parentFinalStopped = gatewayHeartbeatBrokerIsFullyStopped()
                @Expect(parentFinalStopped, true)
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
    public func heartbeatE2eHb01TwoGenerationsSurviveProbeTimeoutAndStopTerminal(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let home = Path("/tmp/metis-heartbeat-e2e-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            let gatewayPort = gatewayServeStopTemporaryPort()
            let webhookPort = gatewayServeStopTemporaryPort()
            @Expect(gatewayPort > 0 && webhookPort > 0 && gatewayPort != webhookPort, true)
            let oldHome = getVariable("METIS_HOME")
            let oldRoot = getVariable("METIS_CJPM_ROOT")
            let oldPath = getVariable("PATH")
            let oldTestDyld = getVariable("METIS_TEST_GATEWAY_DYLD_LIBRARY_PATH")
            let oldBrokerDiagnostic = getVariable("METIS_TEST_GATEWAY_BROKER_DIAGNOSTIC_MARKER")
            let brokerEnvironmentKeys = [
                "METIS_STDIO_BROKER_NODE_COMMAND", "METIS_S5_BROKER_PROXY_READY",
                "METIS_S5_BROKER_PROXY_FAIL", "METIS_S5_BROKER_PROXY_WRITER_CLOSED",
                "METIS_S5_BROKER_PROXY_CLEANUP", "METIS_S5_BROKER_PROXY_DROP_DELIVERY_ID",
                "METIS_S5_BROKER_PROXY_ADMISSION_SEEN", "METIS_S5_BROKER_PROXY_COMPLETION_DROPPED",
                "METIS_S5_BROKER_PROXY_HOLD_ENTERED", "METIS_S5_BROKER_PROXY_HOLD_RELEASE",
                "METIS_S5_BROKER_PROXY_HOLD_RELEASED"
            ]
            let oldBrokerEnvironment = ArrayList<(String, Option<String>)>()
            for (key in brokerEnvironmentKeys) { oldBrokerEnvironment.add((key, getVariable(key))) }
            let brokerScript = Path(managedStdioResolveBrokerScriptPath())
            let project = brokerScript.parent.parent
            let metisBinaryValue = gatewayFormalMetisBinary(project)
            @Expect(metisBinaryValue.isSome(), true)
            if (metisBinaryValue.isNone()) { return }
            let metisBinary = metisBinaryValue.getOrThrow()
            let gcmSource = gatewayS5GcmBinary()
            let gcmBinary = home.join("gitcodemonitor")
            let dependencyScript = brokerScript.parent.join("metis-s5-loopback-dependencies.mjs")
            let faultMarker = home.join("listener-timeout.enabled")
            let lsofCalled = home.join("listener-timeout.called")
            let bin = home.join("bin")
            let launchWrapper = home.join("gateway-run-with-stderr.sh")
            var dependencies = None<GatewayS5DependencyProcess>
            var gatewayProcess = None<SubProcess>
            var gatewayIdentity = None<GatewayServeIdentity>
            var gatewayPid: Int64 = 0
            var brokerPid: Int64 = 0
            var gcmPid: Int64 = 0
            var gcmPgid: Int64 = 0
            var firstGatewayPid: Int64 = 0
            var firstIdentity = None<GatewayServeIdentity>
            var businessEntered = false
            var allTerminal = false
            try {
                for (key in brokerEnvironmentKeys) { setVariable(key, "") }
                let parentSetupReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                @Expect(parentSetupReset.ok, true)
                let parentSetupStopped = gatewayHeartbeatBrokerIsFullyStopped()
                if (!parentSetupReset.ok || !parentSetupStopped) { return }
                Directory.create(bin, recursive: true)
                setVariable("METIS_HOME", home.toString())
                setVariable("METIS_CJPM_ROOT", project.toString())
                let inheritedPath = match (oldPath) { case Some(value) => value case None => "/usr/bin:/bin" }
                File.writeTo(
                    bin.join("lsof"),
                    ("#!/bin/sh\nif [ -f '${faultMarker.toString()}' ]; then\n" +
                        "  printf called > '${lsofCalled.toString()}'\n  sleep 1\n  exit 1\nfi\n" +
                        "exec /usr/sbin/lsof \"$@\"\n").toArray()
                )
                @Expect(executeWithOutput("/bin/chmod", ["700", bin.join("lsof").toString()])[0], 0)
                File.writeTo(
                    launchWrapper,
                    ("#!/bin/sh\nexport DYLD_LIBRARY_PATH=\"$METIS_TEST_GATEWAY_DYLD_LIBRARY_PATH\"\n" +
                        "export METIS_STDIO_BROKER_TEST_MODE=1\n" +
                        "export METIS_STDIO_BROKER_DIAGNOSTIC_MARKER=\"$METIS_TEST_GATEWAY_BROKER_DIAGNOSTIC_MARKER\"\n" +
                        "export METIS_TEST_GATEWAY_HEARTBEAT_CADENCE_MODE=1\n" +
                        "export METIS_TEST_GATEWAY_HEARTBEAT_CADENCE_NONCE=heartbeat-e2e-v1\n" +
                        "export METIS_TEST_GATEWAY_HEARTBEAT_CADENCE_POLLS=2\n" +
                        "unset METIS_TEST_GATEWAY_DYLD_LIBRARY_PATH METIS_TEST_GATEWAY_BROKER_DIAGNOSTIC_MARKER\n" +
                        "exec \"$1\" gateway run 2>\"$2\"\n").toArray()
                )
                @Expect(executeWithOutput("/bin/chmod", ["700", launchWrapper.toString()])[0], 0)
                setVariable("PATH", "${bin.toString()}:${inheritedPath}")
                let taskDyld = getVariable("DYLD_LIBRARY_PATH").getOrDefault { "" }.trimAscii()
                @Expect(taskDyld.isEmpty(), false)
                if (taskDyld.isEmpty()) { return }
                setVariable("METIS_TEST_GATEWAY_DYLD_LIBRARY_PATH", taskDyld)
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                @Expect(exists(metisBinary), true)
                @Expect(exists(gcmSource), true)
                @Expect(exists(dependencyScript), true)
                @Expect(executeWithOutput("/bin/cp", [gcmSource.toString(), gcmBinary.toString()])[0], 0)
                @Expect(executeWithOutput("/bin/chmod", ["700", gcmBinary.toString()])[0], 0)
                dependencies = Some(gatewayS5StartDependencies(home, dependencyScript, replyMarker: "heartbeat-e2e"))
                let dependencyPort = dependencies.getOrThrow().port
                @Expect(dependencyPort > 0, true)
                let configured = gatewayS5ConfigureFormalGateway(
                    home,
                    gatewayPort,
                    webhookPort,
                    dependencyPort,
                    gcmBinary
                )
                @Expect(exists(configured[2]), true)

                for (generation in 0..2) {
                    if (generation > 0) {
                        try { remove(home.join("gateway-serve.stop-complete")) } catch (_: Exception) { () }
                    }
                    let stderrPath = home.join("gateway-${generation}.stderr.log")
                    let brokerDiagnosticPath = home.join("gateway-${generation}.broker-diagnostics")
                    Directory.create(brokerDiagnosticPath, recursive: true)
                    setVariable("METIS_TEST_GATEWAY_BROKER_DIAGNOSTIC_MARKER", brokerDiagnosticPath.toString())
                    let launched = launch(
                        launchWrapper.toString(),
                        [metisBinary.toString(), stderrPath.toString()],
                        stdIn: ProcessRedirect.Discard,
                        stdOut: ProcessRedirect.Discard,
                        stdErr: ProcessRedirect.Discard
                    )
                    setVariable("METIS_TEST_GATEWAY_BROKER_DIAGNOSTIC_MARKER", "")
                    gatewayPid = launched.pid
                    gatewayProcess = Some(launched)
                    let capturedIdentity = gatewayHeartbeatCaptureOwnedIdentityDetailed(
                        home, launched, metisBinary, 15000)
                    @Expect(capturedIdentity.status, "captured")
                    @Expect(capturedIdentity.attempts > 0, true)
                    if (capturedIdentity.status != "captured") { return }
                    @Expect(capturedIdentity.identity.isSome(), true)
                    if (!capturedIdentity.identity.isSome()) { return }
                    gatewayIdentity = capturedIdentity.identity
                    businessEntered = true
                    let currentIdentity = gatewayIdentity.getOrThrow()
                    if (generation == 0) {
                        firstGatewayPid = gatewayPid
                        firstIdentity = Some(currentIdentity)
                    } else {
                        @Expect(gatewayPid != firstGatewayPid, true)
                        @Expect(firstIdentity.isSome(), true)
                        if (!firstIdentity.isSome()) { return }
                        @Expect(firstIdentity.getOrThrow().matches(currentIdentity), false)
                    }

                    let stableGatewayPid = gatewayPid
                    let processCapture = GatewayS5P1Capture()
                    @Expect(gatewayServeStopWaitUntil(15000, { =>
                        processCapture.brokerPid = gatewayServeStopChildPid(stableGatewayPid, brokerScript.toString())
                        processCapture.brokerPid > 0 &&
                            gatewayServeStopParentPid(processCapture.brokerPid) == stableGatewayPid
                    }), true)
                    brokerPid = processCapture.brokerPid
                    let stableBrokerPid = brokerPid
                    @Expect(gatewayServeStopWaitUntil(5000, { =>
                        gatewayHeartbeatBrokerDiagnosticForPid(brokerDiagnosticPath, stableBrokerPid).isSome()
                    }), true)
                    let preStopBrokerDirectory = GatewayHeartbeatBrokerDirectoryProof(brokerDiagnosticPath)
                    println("HB-BR-DIAGNOSTIC ${preStopBrokerDirectory.safeSummary("pre_stop")}")
                    @Expect(preStopBrokerDirectory.status, "valid")
                    @Expect(preStopBrokerDirectory.identityCount, 1)
                    @Expect(preStopBrokerDirectory.slotCount, 1)
                    @Expect(preStopBrokerDirectory.tempCount, 0)
                    @Expect(preStopBrokerDirectory.overflow, false)
                    let preStopBrokerMarker = gatewayHeartbeatBrokerDiagnosticForPid(
                        brokerDiagnosticPath,
                        stableBrokerPid
                    )
                    @Expect(preStopBrokerMarker.isSome(), true)
                    if (!preStopBrokerMarker.isSome()) { return }
                    @Expect(preStopBrokerMarker.getOrThrow().parseStatus, "schema_valid")
                    @Expect(preStopBrokerMarker.getOrThrow().parentStatus(stableGatewayPid), "original_parent")
                    @Expect(gatewayServeStopWaitUntil(15000, { =>
                        processCapture.gcmPid = gatewayServeStopChildPid(stableBrokerPid, gcmBinary.toString())
                        processCapture.gcmPgid = gatewayServeStopProcessGroup(processCapture.gcmPid)
                        processCapture.gcmPid > 0 && processCapture.gcmPgid > 0 &&
                            gatewayServeStopParentPid(processCapture.gcmPid) == stableBrokerPid
                    }), true)
                    gcmPid = processCapture.gcmPid
                    gcmPgid = processCapture.gcmPgid
                    let readyzUrl = "http://127.0.0.1:${gatewayPort}/readyz"
                    let liveOwner = GatewayServeStopLiveOwnerProof()
                    let stableGcmPid = gcmPid
                    @Expect(gatewayServeStopWaitUntil(15000, { =>
                        liveOwner.refresh(readyzUrl)
                        processCapture.refreshLease(home, stableGcmPid, stableGatewayPid, webhookPort)
                        liveOwner.httpStatus == 200 && liveOwner.running && liveOwner.ownerCount == 1 &&
                            processCapture.leaseIdentityMatches && processCapture.leasePidMatches &&
                            processCapture.leasePortMatches && processCapture.leaseRunning
                    }), true)

                    let runtimePath = home.join("gateway-runtime-state.json")
                    let initialHeartbeat = gatewayHeartbeatRuntimeInt(runtimePath, "updatedAtMs")
                    let firstHeartbeat = ArrayList<Int64>()
                    @Expect(gatewayServeStopWaitUntil(15000, { =>
                        let value = gatewayHeartbeatRuntimeInt(runtimePath, "updatedAtMs")
                        if (value > initialHeartbeat) {
                            firstHeartbeat.clear()
                            firstHeartbeat.add(value)
                            true
                        } else { false }
                    }), true)
                    @Expect(firstHeartbeat.size, 1)
                    if (firstHeartbeat.size != 1) { return }
                    let firstHeartbeatValue = firstHeartbeat[0]
                    liveOwner.refresh(readyzUrl)
                    processCapture.refreshLease(home, stableGcmPid, stableGatewayPid, webhookPort)
                    @Expect(liveOwner.httpStatus, 200)
                    @Expect(liveOwner.running, true)
                    @Expect(liveOwner.ownerCount, 1)
                    @Expect(processCapture.leaseIdentityMatches, true)
                    @Expect(processCapture.leasePidMatches, true)
                    @Expect(processCapture.leasePortMatches, true)
                    @Expect(processCapture.leaseRunning, true)
                    @Expect(gatewayServeStopPidAlive(stableGatewayPid), true)
                    @Expect(gatewayServeStopPidAlive(stableGcmPid), true)
                    let secondHeartbeatObserved = gatewayServeStopWaitUntil(15000, { =>
                        gatewayHeartbeatRuntimeInt(runtimePath, "updatedAtMs") > firstHeartbeatValue
                    })
                    @Expect(secondHeartbeatObserved, true)
                    if (!secondHeartbeatObserved) { return }
                    liveOwner.refresh(readyzUrl)
                    processCapture.refreshLease(home, stableGcmPid, stableGatewayPid, webhookPort)
                    @Expect(liveOwner.httpStatus, 200)
                    @Expect(liveOwner.running, true)
                    @Expect(liveOwner.ownerCount, 1)
                    @Expect(processCapture.leaseIdentityMatches, true)
                    @Expect(processCapture.leasePidMatches, true)
                    @Expect(processCapture.leasePortMatches, true)
                    @Expect(processCapture.leaseRunning, true)
                    @Expect(gatewayServeStopPidAlive(stableGatewayPid), true)
                    @Expect(gatewayServeStopPidAlive(stableGcmPid), true)

                    if (generation == 0) {
                        for (_ in 0..40) {
                            @Expect(gatewayHeartbeatHttpStatus("http://127.0.0.1:${webhookPort}/healthz"), 200)
                            @Expect(gatewayServeStopPidAlive(stableGcmPid), true)
                        }
                        let beforeFaultHeartbeat = gatewayHeartbeatRuntimeInt(runtimePath, "updatedAtMs")
                        File.writeTo(faultMarker, "enabled".toArray())
                        @Expect(gatewayServeStopWaitUntil(15000, { =>
                            gatewayHeartbeatRuntimeInt(runtimePath, "updatedAtMs") > beforeFaultHeartbeat
                        }), true)
                        liveOwner.refresh(readyzUrl)
                        @Expect(exists(lsofCalled), false)
                        @Expect(liveOwner.httpStatus, 200)
                        @Expect(liveOwner.running, true)
                        @Expect(gatewayServeStopPidAlive(stableGatewayPid), true)
                        @Expect(gatewayServeStopPidAlive(stableGcmPid), true)
                        let timeout = gatewayFindVerifiedListenerPidsOnPortDetailed(port: gatewayPort, timeoutMs: 30)
                        @Expect(timeout.conclusive, false)
                        @Expect(timeout.status, "listener_discovery_timeout")
                        @Expect(exists(lsofCalled), true)
                        liveOwner.refresh(readyzUrl)
                        @Expect(liveOwner.httpStatus, 200)
                        @Expect(liveOwner.running, true)
                        @Expect(gatewayServeStopPidAlive(stableGatewayPid), true)
                        @Expect(gatewayServeStopPidAlive(stableGcmPid), true)
                        try { remove(faultMarker) } catch (_: Exception) { () }
                    }

                    let preStopStderr = try {
                        String.fromUtf8(File.readFrom(stderrPath))
                    } catch (_: Exception) {
                        ""
                    }
                    @Expect(preStopStderr.contains("metis stdio broker protocol writer failed"), false)

                    let lockText = try { String.fromUtf8(File.readFrom(home.join("gateway-serve.lock"))) } catch (_: Exception) { "" }
                    let stopIdentity = gatewayParseServeIdentity(lockText)
                    @Expect(stopIdentity.isSome(), true)
                    if (!stopIdentity.isSome()) { return }
                    @Expect(stopIdentity.getOrThrow().matches(currentIdentity), true)
                    @Expect(gatewayExecuteStopServe(), 0)
                    let completionPath = home.join("gateway-serve.stop-complete")
                    @Expect(exists(completionPath), true)
                    let completion = try { String.fromUtf8(File.readFrom(completionPath)) } catch (_: Exception) { "" }
                    @Expect(gatewayServeStopCompletionField(completion, "status"), "graceful")
                    @Expect(gatewayServeStopCompletionField(completion, "fullTerminal"), "1")
                    @Expect(gatewayServeStopCompletionField(completion, "brokerStatus"), "stopped")
                    @Expect(gatewayServeStopCompletionField(completion, "servicePluginOwnerStatus"), "graceful_exited")
                    @Expect(gatewayServeStopCompletionField(completion, "servicePluginPortStatus"), "released")
                    @Expect(gatewayServeStopReapCompletedOwnedProcess(gatewayProcess), true)
                    gatewayProcess = None<SubProcess>
                    @Expect(gatewayServeStopWaitUntil(5000, { => !gatewayServeStopPidAlive(stableGatewayPid) }), true)
                    @Expect(gatewayServeStopWaitUntil(5000, { => !gatewayServeStopPidAlive(stableBrokerPid) }), true)
                    @Expect(gatewayServeStopWaitUntil(5000, { =>
                        gatewayHeartbeatBrokerPidsGone(brokerDiagnosticPath)
                    }), true)
                    @Expect(gatewayServeStopWaitUntil(5000, { => !gatewayServeStopPidAlive(stableGcmPid) }), true)
                    let stableGcmPgid = gcmPgid
                    @Expect(gatewayServeStopWaitUntil(5000, { => gatewayServeStopGroupGone(stableGcmPgid) }), true)
                    @Expect(gatewayServeStopPortListening(gatewayPort), false)
                    @Expect(gatewayServeStopPortListening(webhookPort), false)
                    processCapture.refreshLease(home, stableGcmPid, stableGatewayPid, webhookPort)
                    @Expect(processCapture.leaseStopped, true)
                    @Expect(gatewayServeStopRuntimeOwnerCount(runtimePath), 0)
                    let diagnostic = try {
                        String.fromUtf8(File.readFrom(home.join("s5-gateway.log")))
                    } catch (_: Exception) {
                        ""
                    }
                    @Expect(diagnostic.contains("writer_failure"), false)
                    @Expect(diagnostic.contains("broker_write_failed"), false)
                    let terminalStderr = try {
                        String.fromUtf8(File.readFrom(stderrPath))
                    } catch (_: Exception) {
                        ""
                    }
                    let brokerDiagnostics = gatewayHeartbeatBrokerDiagnostics(brokerDiagnosticPath)
                    let terminalBrokerDirectory = GatewayHeartbeatBrokerDirectoryProof(brokerDiagnosticPath)
                    println("HB-BR-DIAGNOSTIC ${terminalBrokerDirectory.safeSummary("terminal")}")
                    @Expect(terminalBrokerDirectory.status, "valid")
                    @Expect(terminalBrokerDirectory.identityCount <= 16, true)
                    @Expect(terminalBrokerDirectory.slotCount, terminalBrokerDirectory.identityCount)
                    @Expect(terminalBrokerDirectory.tempCount, 0)
                    @Expect(terminalBrokerDirectory.overflow, false)
                    for (value in brokerDiagnostics) {
                        let role = if (value.brokerPid == stableBrokerPid) { "frozen" } else { "replacement" }
                        println("HB-BR-MARKER ${value.safeSummary(role, stableGatewayPid)}")
                        @Expect(value.parseStatus, "schema_valid")
                        @Expect(value.filenameMatches, true)
                        @Expect(value.parentStatus(stableGatewayPid), "original_parent")
                    }
                    let brokerDiagnosticMatch = gatewayHeartbeatBrokerDiagnosticForPid(
                        brokerDiagnosticPath,
                        stableBrokerPid
                    )
                    @Expect(brokerDiagnosticMatch.isSome(), true)
                    if (!brokerDiagnosticMatch.isSome()) { return }
                    let brokerDiagnostic = brokerDiagnosticMatch.getOrThrow()
                    @Expect(brokerDiagnostic.valid, true)
                    @Expect(brokerDiagnostic.brokerPid == stableBrokerPid, true)
                    @Expect(brokerDiagnostic.startParentPid == stableGatewayPid, true)
                    @Expect(brokerDiagnostics.size, 1)
                    @Expect(brokerDiagnostic.closeEntryCount, 1)
                    @Expect(brokerDiagnostic.closeEntryOwnerCount, 0)
                    @Expect(brokerDiagnostic.ownerTerminalCount >= 1, true)
                    @Expect(brokerDiagnostic.brokerClosedCallbackCount, 1)
                    @Expect(brokerDiagnostic.brokerClosedEnqueuedCount, 1)
                    @Expect(brokerDiagnostic.closeAckCallbackSeen, true)
                    @Expect(brokerDiagnostic.writerFailureKind, "")
                    @Expect(brokerDiagnostic.writerFailurePhase, "")
                    @Expect(brokerDiagnostic.otherStarts, 0)
                    @Expect(brokerDiagnostic.otherTerminals, 0)
                    @Expect(brokerDiagnostic.ownerCount, 0)
                    @Expect(brokerDiagnostic.exitScheduledCount, 1)
                    @Expect(brokerDiagnostic.lastExitScheduledCode, 0)
                    @Expect(terminalStderr.contains("metis stdio broker protocol writer failed"), false)
                    gatewayIdentity = None<GatewayServeIdentity>
                    gatewayPid = 0
                    brokerPid = 0
                    gcmPid = 0
                    gcmPgid = 0
                }
                allTerminal = true
            } finally {
                if (gatewayIdentity.isSome()) {
                    try { gatewayServeStopReapOwnedGateway(gatewayIdentity, metisBinary, home) } catch (_: Exception) { () }
                }
                try { gatewayServeStopReapOwnedHandle(gatewayProcess, metisBinary) } catch (_: Exception) { () }
                let dependenciesStopped = gatewayS5StopDependencies(dependencies)
                let parentFinalReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                @Expect(parentFinalReset.ok, true)
                for ((key, value) in oldBrokerEnvironment) {
                    match (value) {
                        case Some(previous) => setVariable(key, previous)
                        case None => setVariable(key, "")
                    }
                }
                match (oldPath) { case Some(value) => setVariable("PATH", value) case None => setVariable("PATH", "") }
                let parentFinalStopped = gatewayHeartbeatBrokerIsFullyStopped()
                @Expect(parentFinalStopped, true)
                match (oldHome) { case Some(value) => setVariable("METIS_HOME", value) case None => setVariable("METIS_HOME", "") }
                match (oldRoot) { case Some(value) => setVariable("METIS_CJPM_ROOT", value) case None => setVariable("METIS_CJPM_ROOT", "") }
                match (oldTestDyld) {
                    case Some(value) => setVariable("METIS_TEST_GATEWAY_DYLD_LIBRARY_PATH", value)
                    case None => setVariable("METIS_TEST_GATEWAY_DYLD_LIBRARY_PATH", "")
                }
                match (oldBrokerDiagnostic) {
                    case Some(value) => setVariable("METIS_TEST_GATEWAY_BROKER_DIAGNOSTIC_MARKER", value)
                    case None => setVariable("METIS_TEST_GATEWAY_BROKER_DIAGNOSTIC_MARKER", "")
                }
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                try { remove(home, recursive: true) } catch (_: Exception) { () }
                @Expect(dependenciesStopped, true)
                if (businessEntered) { @Expect(allTerminal, true) }
                @Expect(exists(home), false)
            }
        }
    }

    @TestCase
    public func s5P1FormalGatewayGcmWebhookDeliversExactlyOnceAndStopsAllResources(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let home = Path("/tmp/metis-s5-p1-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            let gatewayPort = gatewayServeStopTemporaryPort()
            let webhookPort = gatewayServeStopTemporaryPort()
            @Expect(gatewayPort > 0 && webhookPort > 0 && gatewayPort != webhookPort, true)
            let oldHome = getVariable("METIS_HOME")
            let oldRoot = getVariable("METIS_CJPM_ROOT")
            let openaiApiKeyAliases = cliProviderApiKeyEnvAliases("openai")
            let openaiBaseUrlAliases = cliProviderBaseUrlEnvAliases("openai")
            let oldProviderEnv = ArrayList<(String, Option<String>)>()
            for (key in openaiApiKeyAliases) {
                oldProviderEnv.add((key, getVariable(key)))
            }
            for (key in openaiBaseUrlAliases) {
                oldProviderEnv.add((key, getVariable(key)))
            }
            let oldPrimaryModel = CliConfig._model
            let oldFallbackModels = CliConfig.fallbackModels
            let oldImageModel = CliConfig._imageModel
            let oldImageFallbackModels = CliConfig.imageFallbackModels
            let oldPdfModel = CliConfig._pdfModel
            let oldPdfFallbackModels = CliConfig.pdfFallbackModels
            let oldPdfMaxBytesMb = CliConfig.pdfMaxBytesMb
            let oldPdfMaxPages = CliConfig.pdfMaxPages
            let oldFastModel = CliConfig._fastModel
            let oldTemperature = CliConfig.temperature
            let oldDefaultModelInputLimit = CliConfig.defaultModelInputLimit
            let oldDefaultModelOutputLimit = CliConfig.defaultModelOutputLimit
            let oldWorkspaceDirOverride = CliConfig.workspaceDirOverride
            let brokerScript = Path(managedStdioResolveBrokerScriptPath())
            let project = brokerScript.parent.parent
            let metisBinaryValue = gatewayFormalMetisBinary(project)
            @Expect(metisBinaryValue.isSome(), true)
            if (metisBinaryValue.isNone()) { return }
            let metisBinary = metisBinaryValue.getOrThrow()
            let gcmBinarySource = gatewayS5GcmBinary()
            let gcmBinary = home.join("gitcodemonitor")
            let dependencyScript = brokerScript.parent.join("metis-s5-loopback-dependencies.mjs")
            var dependencies = None<GatewayS5DependencyProcess>
            var gatewayProcess = None<SubProcess>
            var gatewayIdentity = None<GatewayServeIdentity>
            var gatewayPid: Int64 = 0
            var brokerPid: Int64 = 0
            var gcmPid: Int64 = 0
            var gcmPgid: Int64 = 0
            var leasePath = Path("")
            var brokerCaptured = false
            var gcmCaptured = false
            var gatewaySettled = false
            var brokerGone = false
            var gcmGone = false
            var gcmGroupGone = false
            var dependenciesSettled = false
            let output = ArrayList<String>()
            try {
                Directory.create(home, recursive: true)
                setVariable("METIS_HOME", home.toString())
                setVariable("METIS_CJPM_ROOT", project.toString())
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                @Expect(exists(metisBinary), true)
                @Expect(exists(gcmBinarySource), true)
                @Expect(exists(dependencyScript), true)
                let copied = executeWithOutput("/bin/cp", [gcmBinarySource.toString(), gcmBinary.toString()])
                @Expect(copied[0], 0)
                @Expect(exists(gcmBinary), true)

                dependencies = Some(gatewayS5StartDependencies(
                    home, dependencyScript, replyMarker: "s5-p1-exact-once"
                ))
                let dependencyPort = dependencies.getOrThrow().port
                @Expect(dependencyPort > 0, true)
                @Expect(gatewayServeStopPortListening(dependencyPort), true)
                @Expect(openaiApiKeyAliases.isEmpty(), false)
                @Expect(openaiBaseUrlAliases.isEmpty(), false)
                for (key in openaiApiKeyAliases) { setVariable(key, "fake-s5-openai-key") }
                for (key in openaiBaseUrlAliases) {
                    setVariable(key, "http://127.0.0.1:${dependencyPort}/v1")
                }
                let configured = gatewayS5ConfigureFormalGateway(
                    home,
                    gatewayPort,
                    webhookPort,
                    dependencyPort,
                    gcmBinary
                )
                let statePath = configured[0]
                let queuePath = configured[1]
                let manifestPath = configured[2]
                let loaded = loadServicePluginManifest(manifestPath.toString())
                @Expect(loaded.ok, true)
                @Expect(loaded.status, "accepted")

                let parentHeapBeforeLaunch = getVariable("cjHeapSize")
                let launched = gatewayS5LaunchGateway(metisBinary)
                @Expect(gatewayS5HeapEnvironmentMatches(parentHeapBeforeLaunch), true)
                gatewayPid = launched.pid
                gatewayProcess = Some(launched)
                gatewayIdentity = gatewayServeStopCaptureOwnedIdentity(home, gatewayPid, metisBinary, 5000)
                @Expect(gatewayIdentity.isSome(), true)

                let processCapture = GatewayS5P1Capture()
                let stableGatewayPid = gatewayPid
                let brokerReady = gatewayServeStopWaitUntil(15000, { =>
                    processCapture.brokerPid = gatewayServeStopChildPid(stableGatewayPid, brokerScript.toString())
                    processCapture.brokerPid > 0 &&
                        gatewayServeStopCommandContains(processCapture.brokerPid, brokerScript.toString()) &&
                        gatewayServeStopParentPid(processCapture.brokerPid) == stableGatewayPid
                })
                @Expect(brokerReady, true)
                brokerPid = processCapture.brokerPid
                brokerCaptured = brokerReady
                let gcmReady = gatewayServeStopWaitUntil(15000, { =>
                    processCapture.gcmPid = gatewayServeStopChildPid(processCapture.brokerPid, gcmBinary.toString())
                    processCapture.gcmPgid = gatewayServeStopProcessGroup(processCapture.gcmPid)
                    processCapture.gcmPid > 0 && processCapture.gcmPgid > 0 &&
                        gatewayServeStopCommandContains(processCapture.gcmPid, gcmBinary.toString()) &&
                        gatewayServeStopParentPid(processCapture.gcmPid) == processCapture.brokerPid
                })
                @Expect(gcmReady, true)
                gcmPid = processCapture.gcmPid
                gcmPgid = processCapture.gcmPgid
                gcmCaptured = gcmReady
                let liveOwner = GatewayServeStopLiveOwnerProof()
                let readyzUrl = "http://127.0.0.1:${gatewayPort}/readyz"
                let expectedGcmPid = gcmPid
                let expectedGatewayPid = stableGatewayPid
                @Expect(gatewayServeStopWaitUntil(15000, { =>
                    liveOwner.refresh(readyzUrl)
                    processCapture.refreshLease(home, expectedGcmPid, expectedGatewayPid, webhookPort)
                    liveOwner.httpStatus == 200 && liveOwner.running && liveOwner.ownerCount >= 1 &&
                        gatewayServeStopPortListening(gatewayPort) && gatewayServeStopPortListening(webhookPort) &&
                        processCapture.leaseIdentityMatches && processCapture.leasePidMatches &&
                        processCapture.leasePortMatches && processCapture.leaseRunning
                }), true)
                leasePath = processCapture.leasePath
                @Expect(liveOwner.httpStatus, 200)
                @Expect(liveOwner.running, true)
                @Expect(liveOwner.ownerCount >= 1, true)
                @Expect(gatewayServeStopPortListening(gatewayPort), true)
                @Expect(gatewayServeStopPortListening(webhookPort), true)
                @Expect(processCapture.leaseDirExists, true)
                @Expect(processCapture.leaseFileCount, 1)
                @Expect(processCapture.leaseUtf8, true)
                @Expect(processCapture.leaseJson, true)
                @Expect(processCapture.leaseIdentityMatches, true)
                @Expect(processCapture.leasePidMatches, true)
                @Expect(processCapture.leasePortMatches, true)
                @Expect(processCapture.leaseRunning, true)

                let deliveryId = "s5-p1-exact-once"
                let eventId = "gitcode:cangjie/compiler:issue:7001"
                let stableDependencies = dependencies.getOrThrow()
                let first = gatewayS5PostWebhook(webhookPort, deliveryId)
                let duplicate = gatewayS5PostWebhook(webhookPort, deliveryId)
                @Expect(first >= 200 && first < 300, true)
                @Expect(duplicate >= 200 && duplicate < 300, true)
                @Expect(gatewayServeStopWaitUntil(15000, { =>
                    gatewayS5EventCount(stableDependencies.eventsPath, "telegram_send", deliveryId) == 1 &&
                        gatewayS5EventCount(stableDependencies.eventsPath, "model_response") == 1 &&
                        gatewayS5FileContains(statePath, eventId) &&
                        gatewayS5FileContains(queuePath.join("processed").join("${deliveryId}.json"), deliveryId)
                }), true)
                @Expect(gatewayS5EventCount(dependencies.getOrThrow().eventsPath, "telegram_send", deliveryId), 1)
                @Expect(gatewayS5EventCount(dependencies.getOrThrow().eventsPath, "model_response"), 1)
                @Expect(gatewayS5EventCount(dependencies.getOrThrow().eventsPath, "model_response", "\"stream\":false"), 1)
                @Expect(gatewayS5EventCount(dependencies.getOrThrow().eventsPath, "model_response", "\"responseMode\":\"json\""), 1)
                @Expect(gatewayS5FileContains(stableDependencies.eventsPath, "S5 本地模型回复 中文🙂 s5-p1-exact-once"), true)
                @Expect(gatewayS5FileContains(stableDependencies.eventsPath, "_answer_"), false)
                @Expect(gatewayS5FileContains(stableDependencies.eventsPath, "<answer>"), false)
                @Expect(gatewayS5FileContains(stableDependencies.eventsPath, "taskKind"), false)
                @Expect(gatewayS5FileContains(stableDependencies.eventsPath, "replyBody"), false)
                @Expect(exists(queuePath), true)
                @Expect(gatewayS5FileContains(queuePath.join("processed").join("${deliveryId}.json"), deliveryId), true)
                @Expect(gatewayS5FileContains(statePath, eventId), true)

                let lockText = String.fromUtf8(File.readFrom(home.join("gateway-serve.lock")))
                let stopIdentity = gatewayParseServeIdentity(lockText).getOrThrow()
                @Expect(stopIdentity.pid, gatewayPid)
                @Expect(gatewayIdentity.getOrThrow().matches(stopIdentity), true)
                setGatewayStopOutputForTest(Some({ line => output.add(line) }))
                let exitCode = gatewayExecuteStopServe()
                let outputText = String.join(output.toArray(), delimiter: "\n")
                @Expect(exitCode, 0)
                @Expect(outputText.contains("已正常停止"), true)
                @Expect(outputText.contains("\"ok\""), false)
                @Expect(outputText.contains("\"result\""), false)

                let completionPath = home.join("gateway-serve.stop-complete")
                @Expect(exists(completionPath), true)
                let completion = String.fromUtf8(File.readFrom(completionPath))
                @Expect(gatewayParseServeIdentity(completion).getOrThrow().matches(stopIdentity), true)
                @Expect(gatewayServeStopCompletionField(completion, "status"), "graceful")
                @Expect(gatewayServeStopCompletionField(completion, "fullTerminal"), "1")
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginIngressStatus"), "sent")
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginDispatchStatus"), "drained")
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginOwnerStatus"), "graceful_exited")
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginLeaseStatus"), "stopped")
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginPortStatus"), "released")
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginPendingCount"), "0")
                @Expect(gatewayServeStopCompletionField(completion, "channelsStatus"), "stopped")
                @Expect(gatewayServeStopCompletionField(completion, "brokerStatus"), "stopped")

                gatewaySettled = gatewayServeStopReapCompletedOwnedProcess(gatewayProcess)
                @Expect(gatewaySettled, true)
                if (gatewaySettled) { gatewayProcess = None<SubProcess> }
                let capturedBrokerPid = brokerPid
                let capturedGcmPid = gcmPid
                let capturedGcmPgid = gcmPgid
                brokerGone = gatewayServeStopWaitUntil(5000, { => !gatewayServeStopPidAlive(capturedBrokerPid) })
                gcmGone = gatewayServeStopWaitUntil(5000, { => !gatewayServeStopPidAlive(capturedGcmPid) })
                gcmGroupGone = gatewayServeStopWaitUntil(5000, { =>
                    executeWithOutput("/usr/bin/pgrep", ["-g", "${capturedGcmPgid}"])[0] != 0
                })
                @Expect(brokerGone, true)
                @Expect(gcmGone, true)
                @Expect(gcmGroupGone, true)
                @Expect(gatewayServeStopPortListening(gatewayPort), false)
                @Expect(gatewayServeStopPortListening(webhookPort), false)
                processCapture.refreshLease(home, expectedGcmPid, expectedGatewayPid, webhookPort)
                @Expect(processCapture.leaseIdentityMatches, true)
                @Expect(processCapture.leasePidMatches, true)
                @Expect(processCapture.leasePortMatches, true)
                @Expect(processCapture.leaseStopped, true)
                @Expect(gatewayServeStopRuntimeOwnerCount(home.join("gateway-runtime-state.json")), 0)
            } finally {
                setGatewayStopOutputForTest(None<(String) -> Unit>)
                if (gatewayIdentity.isSome()) {
                    try { gatewayServeStopReapOwnedGateway(gatewayIdentity, metisBinary, home) } catch (_: Exception) { () }
                }
                try { gatewayServeStopReapOwnedHandle(gatewayProcess, metisBinary) } catch (_: Exception) { () }
                if (!gatewaySettled) {
                    gatewaySettled = try { gatewayServeStopWaitOwnedProcess(gatewayProcess) } catch (_: Exception) { false }
                }
                let capturedBrokerPid = brokerPid
                let capturedGcmPid = gcmPid
                let capturedGcmPgid = gcmPgid
                if (!brokerGone) {
                    brokerGone = brokerCaptured && gatewayServeStopWaitUntil(3000, { => !gatewayServeStopPidAlive(capturedBrokerPid) })
                }
                if (!gcmGone) {
                    gcmGone = gcmCaptured && gatewayServeStopWaitUntil(3000, { => !gatewayServeStopPidAlive(capturedGcmPid) })
                }
                if (!gcmGroupGone) {
                    gcmGroupGone = gcmCaptured && gatewayServeStopWaitUntil(3000, { =>
                        executeWithOutput("/usr/bin/pgrep", ["-g", "${capturedGcmPgid}"])[0] != 0
                    })
                }
                dependenciesSettled = gatewayS5StopDependencies(dependencies)
                try { let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000) } catch (_: Exception) { () }
                match (oldHome) {
                    case Some(value) => setVariable("METIS_HOME", value)
                    case None => setVariable("METIS_HOME", "")
                }
                match (oldRoot) {
                    case Some(value) => setVariable("METIS_CJPM_ROOT", value)
                    case None => setVariable("METIS_CJPM_ROOT", "")
                }
                for ((key, value) in oldProviderEnv) {
                    match (value) {
                        case Some(previous) => setVariable(key, previous)
                        case None => setVariable(key, "")
                    }
                }
                CliConfig._model = oldPrimaryModel
                CliConfig.fallbackModels = oldFallbackModels
                CliConfig._imageModel = oldImageModel
                CliConfig.imageFallbackModels = oldImageFallbackModels
                CliConfig._pdfModel = oldPdfModel
                CliConfig.pdfFallbackModels = oldPdfFallbackModels
                CliConfig.pdfMaxBytesMb = oldPdfMaxBytesMb
                CliConfig.pdfMaxPages = oldPdfMaxPages
                CliConfig._fastModel = oldFastModel
                CliConfig.temperature = oldTemperature
                CliConfig.defaultModelInputLimit = oldDefaultModelInputLimit
                CliConfig.defaultModelOutputLimit = oldDefaultModelOutputLimit
                CliConfig.workspaceDirOverride = oldWorkspaceDirOverride
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                try { remove(home, recursive: true) } catch (_: Exception) { () }
                @Expect(gatewaySettled, true)
                @Expect(brokerGone, true)
                @Expect(gcmGone, true)
                @Expect(gcmGroupGone, true)
                @Expect(dependenciesSettled, true)
            }
        }
    }

    @TestCase
    public func s5P1Formal140BurstDrainsExactlyOnceAndStopsTerminal(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let home = Path("/tmp/metis-s5-p1-140-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            let gatewayPort = gatewayServeStopTemporaryPort()
            let webhookPort = gatewayServeStopTemporaryPort()
            @Expect(gatewayPort > 0 && webhookPort > 0 && gatewayPort != webhookPort, true)
            let oldHome = getVariable("METIS_HOME")
            let oldRoot = getVariable("METIS_CJPM_ROOT")
            let apiKeyAliases = cliProviderApiKeyEnvAliases("openai")
            let baseUrlAliases = cliProviderBaseUrlEnvAliases("openai")
            let oldProviderEnv = ArrayList<(String, Option<String>)>()
            for (key in apiKeyAliases) { oldProviderEnv.add((key, getVariable(key))) }
            for (key in baseUrlAliases) { oldProviderEnv.add((key, getVariable(key))) }
            let oldPrimaryModel = CliConfig._model
            let oldFallbackModels = CliConfig.fallbackModels
            let oldImageModel = CliConfig._imageModel
            let oldImageFallbackModels = CliConfig.imageFallbackModels
            let oldPdfModel = CliConfig._pdfModel
            let oldPdfFallbackModels = CliConfig.pdfFallbackModels
            let oldPdfMaxBytesMb = CliConfig.pdfMaxBytesMb
            let oldPdfMaxPages = CliConfig.pdfMaxPages
            let oldFastModel = CliConfig._fastModel
            let oldTemperature = CliConfig.temperature
            let oldDefaultModelInputLimit = CliConfig.defaultModelInputLimit
            let oldDefaultModelOutputLimit = CliConfig.defaultModelOutputLimit
            let oldWorkspaceDirOverride = CliConfig.workspaceDirOverride
            let brokerScript = Path(managedStdioResolveBrokerScriptPath())
            let project = brokerScript.parent.parent
            let metisBinaryValue = gatewayFormalMetisBinary(project)
            @Expect(metisBinaryValue.isSome(), true)
            if (metisBinaryValue.isNone()) { return }
            let metisBinary = metisBinaryValue.getOrThrow()
            let gcmBinarySource = gatewayS5GcmBinary()
            let gcmBinary = home.join("gitcodemonitor")
            let dependencyScript = brokerScript.parent.join("metis-s5-loopback-dependencies.mjs")
            let modelEnteredPath = home.join("s5-p1-model-entered")
            let modelReleasePath = home.join("s5-p1-model-release")
            let modelMetricsPath = home.join("s5-p1-model-metrics.json")
            var dependencies = None<GatewayS5DependencyProcess>
            var feishuDependencies = None<GatewayS5DependencyProcess>
            var gatewayProcess = None<SubProcess>
            var gatewayIdentity = None<GatewayServeIdentity>
            var gatewayPid: Int64 = 0
            var brokerPid: Int64 = 0
            var gcmPid: Int64 = 0
            var gcmPgid: Int64 = 0
            var brokerCaptured = false
            var gcmCaptured = false
            var gatewaySettled = false
            var brokerGone = false
            var gcmGone = false
            var gcmGroupGone = false
            var dependenciesSettled = false
            var feishuDependenciesSettled = false
            let output = ArrayList<String>()
            try {
                Directory.create(home, recursive: true)
                setVariable("METIS_HOME", home.toString())
                setVariable("METIS_CJPM_ROOT", project.toString())
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                @Expect(exists(metisBinary), true)
                @Expect(exists(gcmBinarySource), true)
                @Expect(exists(dependencyScript), true)
                @Expect(executeWithOutput("/bin/cp", [gcmBinarySource.toString(), gcmBinary.toString()])[0], 0)

                dependencies = Some(gatewayS5StartDependencies(
                    home,
                    dependencyScript,
                    replyMarker: "s5-p1-140",
                    modelEntered: Some(modelEnteredPath),
                    modelRelease: Some(modelReleasePath),
                    modelMetrics: Some(modelMetricsPath)
                ))
                let feishuHome = home.join("feishu-loopback")
                Directory.create(feishuHome, recursive: true)
                feishuDependencies = Some(gatewayS5StartDependencies(feishuHome, dependencyScript))
                let stableDependencies = dependencies.getOrThrow()
                let stableFeishuDependencies = feishuDependencies.getOrThrow()
                @Expect(stableDependencies.port > 0, true)
                @Expect(stableFeishuDependencies.port > 0, true)
                @Expect(stableDependencies.port != stableFeishuDependencies.port, true)
                @Expect(gatewayServeStopPortListening(stableDependencies.port), true)
                @Expect(gatewayServeStopPortListening(stableFeishuDependencies.port), true)
                for (key in apiKeyAliases) { setVariable(key, "fake-s5-openai-key") }
                for (key in baseUrlAliases) {
                    setVariable(key, "http://127.0.0.1:${stableDependencies.port}/v1")
                }
                let configured = gatewayS5ConfigureFormalGateway(
                    home,
                    gatewayPort,
                    webhookPort,
                    stableDependencies.port,
                    gcmBinary,
                    liveWriteback: true,
                    includeFeishu: true,
                    feishuPort: stableFeishuDependencies.port
                )
                let queuePath = configured[1]
                let manifestPath = configured[2]
                let loaded = loadServicePluginManifest(manifestPath.toString())
                @Expect(loaded.ok, true)
                @Expect(loaded.status, "accepted")

                let parentHeapBeforeLaunch = getVariable("cjHeapSize")
                let launched = gatewayS5LaunchGateway(metisBinary)
                @Expect(gatewayS5HeapEnvironmentMatches(parentHeapBeforeLaunch), true)
                gatewayPid = launched.pid
                gatewayProcess = Some(launched)
                gatewayIdentity = gatewayServeStopCaptureOwnedIdentity(home, gatewayPid, metisBinary, 5000)
                @Expect(gatewayIdentity.isSome(), true)

                let processCapture = GatewayS5P1Capture()
                let stableGatewayPid = gatewayPid
                @Expect(gatewayServeStopWaitUntil(15000, { =>
                    processCapture.brokerPid = gatewayServeStopChildPid(stableGatewayPid, brokerScript.toString())
                    processCapture.brokerPid > 0 &&
                        gatewayServeStopCommandContains(processCapture.brokerPid, brokerScript.toString()) &&
                        gatewayServeStopParentPid(processCapture.brokerPid) == stableGatewayPid
                }), true)
                brokerPid = processCapture.brokerPid
                brokerCaptured = brokerPid > 0
                @Expect(gatewayServeStopWaitUntil(15000, { =>
                    processCapture.gcmPid = gatewayServeStopChildPid(processCapture.brokerPid, gcmBinary.toString())
                    processCapture.gcmPgid = gatewayServeStopProcessGroup(processCapture.gcmPid)
                    processCapture.gcmPid > 0 && processCapture.gcmPgid > 0 &&
                        gatewayServeStopCommandContains(processCapture.gcmPid, gcmBinary.toString()) &&
                        gatewayServeStopParentPid(processCapture.gcmPid) == processCapture.brokerPid
                }), true)
                gcmPid = processCapture.gcmPid
                gcmPgid = processCapture.gcmPgid
                gcmCaptured = gcmPid > 0
                let readyzUrl = "http://127.0.0.1:${gatewayPort}/readyz"
                let liveOwner = GatewayServeStopLiveOwnerProof()
                let expectedGcmPid = gcmPid
                let expectedGatewayPid = gatewayPid
                @Expect(gatewayServeStopWaitUntil(15000, { =>
                    liveOwner.refresh(readyzUrl)
                    processCapture.refreshLease(home, expectedGcmPid, expectedGatewayPid, webhookPort)
                    liveOwner.httpStatus == 200 && liveOwner.running && liveOwner.ownerCount >= 1 &&
                        processCapture.leaseIdentityMatches && processCapture.leasePidMatches &&
                        processCapture.leasePortMatches && processCapture.leaseRunning
                }), true)

                let deliveryIds = ArrayList<String>()
                let expectedDeliveries = HashSet<String>()
                let expectedWritebacks = HashMap<String, String>()
                for (index in 0..140) {
                    let suffix = if (index < 10) { "000${index}" } else if (index < 100) { "00${index}" } else { "0${index}" }
                    let deliveryId = "s5-p1-${suffix}-end"
                    deliveryIds.add(deliveryId)
                    expectedDeliveries.add(deliveryId)
                    expectedWritebacks["${8000 + index}"] = deliveryId
                }
                @Expect(expectedDeliveries.size, 140)
                @Expect(expectedWritebacks.size, 140)
                for (index in 0..140) {
                    let deliveryId = deliveryIds[index]
                    let status = gatewayS5PostWebhook(webhookPort, deliveryId, iid: 8000 + index)
                    @Expect(status >= 200 && status < 300, true)
                }
                @Expect(gatewayServeStopWaitUntil(30000, { =>
                    gatewayS5JsonInt(modelMetricsPath, "entered") == 2 &&
                        gatewayS5JsonInt(modelMetricsPath, "active") == 2 &&
                        gatewayS5JsonInt(modelMetricsPath, "maxActive") == 2 &&
                        gatewayS5RegularFileCount(queuePath.join("awaiting-host")) == 130 &&
                        gatewayS5RegularFileCount(queuePath.join("pending")) == 10
                }), true)
                @Expect(gatewayS5RegularFileCount(queuePath.join("awaiting-host")), 130)
                @Expect(gatewayS5RegularFileCount(queuePath.join("pending")), 10)
                for (_ in 0..8) {
                    liveOwner.refresh(readyzUrl)
                    processCapture.refreshLease(home, expectedGcmPid, expectedGatewayPid, webhookPort)
                    @Expect(liveOwner.httpStatus, 200)
                    @Expect(liveOwner.running, true)
                    @Expect(gatewayServeStopPidAlive(expectedGatewayPid), true)
                    @Expect(gatewayServeStopPidAlive(expectedGcmPid), true)
                    @Expect(gatewayServeStopProcessGroup(expectedGcmPid), gcmPgid)
                    @Expect(processCapture.leaseIdentityMatches, true)
                    @Expect(processCapture.leaseRunning, true)
                }

                File.writeTo(modelReleasePath, "release\n".toArray())
                @Expect(gatewayServeStopWaitUntil(60000, { =>
                    let mainLedger = GatewayS5StrictLedger(
                        stableDependencies.eventsPath, expectedDeliveries, expectedWritebacks
                    )
                    let feishuLedger = GatewayS5StrictLedger(
                        stableFeishuDependencies.eventsPath, expectedDeliveries, expectedWritebacks
                    )
                    var processed = gatewayS5RegularFileCount(queuePath.join("processed")) == 140
                    if (processed) {
                        for (deliveryId in deliveryIds) {
                            if (!exists(queuePath.join("processed").join("${deliveryId}.json"))) {
                                processed = false
                                break
                            }
                        }
                    }
                    mainLedger.valid() && feishuLedger.valid() &&
                        mainLedger.exactOnce("model_response", expectedDeliveries) &&
                        mainLedger.exactWritebacks(expectedWritebacks, expectedDeliveries) &&
                        mainLedger.exactOnce("telegram_send", expectedDeliveries) &&
                        feishuLedger.exactOnce("feishu_send", expectedDeliveries) && processed &&
                        gatewayS5RegularFileCount(queuePath.join("pending")) == 0 &&
                        gatewayS5RegularFileCount(queuePath.join("awaiting-host")) == 0
                }), true)
                let mainLedger = GatewayS5StrictLedger(
                    stableDependencies.eventsPath, expectedDeliveries, expectedWritebacks
                )
                let feishuLedger = GatewayS5StrictLedger(
                    stableFeishuDependencies.eventsPath, expectedDeliveries, expectedWritebacks
                )
                @Expect(mainLedger.valid(), true)
                @Expect(feishuLedger.valid(), true)
                @Expect(mainLedger.exactOnce("model_response", expectedDeliveries), true)
                @Expect(mainLedger.exactWritebacks(expectedWritebacks, expectedDeliveries), true)
                @Expect(mainLedger.exactOnce("telegram_send", expectedDeliveries), true)
                @Expect(feishuLedger.exactOnce("feishu_send", expectedDeliveries), true)
                @Expect(gatewayS5JsonInt(modelMetricsPath, "entered"), 140)
                @Expect(gatewayS5JsonInt(modelMetricsPath, "active"), 0)
                @Expect(gatewayS5JsonInt(modelMetricsPath, "maxActive"), 2)
                @Expect(gatewayS5RegularFileCount(queuePath.join("processed")), 140)
                @Expect(gatewayS5RegularFileCount(queuePath.join("pending")), 0)
                @Expect(gatewayS5RegularFileCount(queuePath.join("awaiting-host")), 0)

                let lockText = String.fromUtf8(File.readFrom(home.join("gateway-serve.lock")))
                let stopIdentity = gatewayParseServeIdentity(lockText).getOrThrow()
                @Expect(stopIdentity.pid, gatewayPid)
                @Expect(gatewayIdentity.getOrThrow().matches(stopIdentity), true)
                setGatewayStopOutputForTest(Some({ line => output.add(line) }))
                @Expect(gatewayExecuteStopServe(), 0)
                let completionPath = home.join("gateway-serve.stop-complete")
                @Expect(exists(completionPath), true)
                let completion = String.fromUtf8(File.readFrom(completionPath))
                @Expect(gatewayParseServeIdentity(completion).getOrThrow().matches(stopIdentity), true)
                @Expect(gatewayServeStopCompletionField(completion, "status"), "graceful")
                @Expect(gatewayServeStopCompletionField(completion, "fullTerminal"), "1")
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginDispatchStatus"), "drained")
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginOwnerStatus"), "graceful_exited")
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginLeaseStatus"), "stopped")
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginPortStatus"), "released")
                @Expect(gatewayServeStopCompletionField(completion, "servicePluginPendingCount"), "0")
                @Expect(gatewayServeStopCompletionField(completion, "channelsStatus"), "stopped")
                @Expect(gatewayServeStopCompletionField(completion, "brokerStatus"), "stopped")

                gatewaySettled = gatewayServeStopReapCompletedOwnedProcess(gatewayProcess)
                @Expect(gatewaySettled, true)
                if (gatewaySettled) { gatewayProcess = None<SubProcess> }
                let capturedBrokerPid = brokerPid
                let capturedGcmPid = gcmPid
                let capturedGcmPgid = gcmPgid
                brokerGone = gatewayServeStopWaitUntil(5000, { => !gatewayServeStopPidAlive(capturedBrokerPid) })
                gcmGone = gatewayServeStopWaitUntil(5000, { => !gatewayServeStopPidAlive(capturedGcmPid) })
                gcmGroupGone = gatewayServeStopWaitUntil(5000, { => gatewayServeStopGroupGone(capturedGcmPgid) })
                @Expect(brokerGone, true)
                @Expect(gcmGone, true)
                @Expect(gcmGroupGone, true)
                @Expect(gatewayServeStopPortListening(gatewayPort), false)
                @Expect(gatewayServeStopPortListening(webhookPort), false)
                processCapture.refreshLease(home, expectedGcmPid, expectedGatewayPid, webhookPort)
                @Expect(processCapture.leaseStopped, true)
                @Expect(gatewayServeStopRuntimeOwnerCount(home.join("gateway-runtime-state.json")), 0)
                dependenciesSettled = gatewayS5StopDependencies(dependencies)
                feishuDependenciesSettled = gatewayS5StopDependencies(feishuDependencies)
                @Expect(dependenciesSettled, true)
                @Expect(feishuDependenciesSettled, true)
                @Expect(gatewayServeStopPortListening(stableDependencies.port), false)
                @Expect(gatewayServeStopPortListening(stableFeishuDependencies.port), false)
            } finally {
                setGatewayStopOutputForTest(None<(String) -> Unit>)
                if (gatewayIdentity.isSome()) {
                    try { gatewayServeStopReapOwnedGateway(gatewayIdentity, metisBinary, home) } catch (_: Exception) { () }
                }
                try { gatewayServeStopReapOwnedHandle(gatewayProcess, metisBinary) } catch (_: Exception) { () }
                if (!gatewaySettled) {
                    gatewaySettled = try { gatewayServeStopWaitOwnedProcess(gatewayProcess) } catch (_: Exception) { false }
                }
                let capturedBrokerPid = brokerPid
                let capturedGcmPid = gcmPid
                let capturedGcmPgid = gcmPgid
                if (!brokerGone) {
                    brokerGone = brokerCaptured && gatewayServeStopWaitUntil(3000, { => !gatewayServeStopPidAlive(capturedBrokerPid) })
                }
                if (!gcmGone) {
                    gcmGone = gcmCaptured && gatewayServeStopWaitUntil(3000, { => !gatewayServeStopPidAlive(capturedGcmPid) })
                }
                if (!gcmGroupGone) {
                    gcmGroupGone = gcmCaptured && gatewayServeStopWaitUntil(3000, { => gatewayServeStopGroupGone(capturedGcmPgid) })
                }
                if (!dependenciesSettled) { dependenciesSettled = gatewayS5StopDependencies(dependencies) }
                if (!feishuDependenciesSettled) {
                    feishuDependenciesSettled = gatewayS5StopDependencies(feishuDependencies)
                }
                try { let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000) } catch (_: Exception) { () }
                match (oldHome) {
                    case Some(value) => setVariable("METIS_HOME", value)
                    case None => setVariable("METIS_HOME", "")
                }
                match (oldRoot) {
                    case Some(value) => setVariable("METIS_CJPM_ROOT", value)
                    case None => setVariable("METIS_CJPM_ROOT", "")
                }
                for ((key, value) in oldProviderEnv) {
                    match (value) {
                        case Some(previous) => setVariable(key, previous)
                        case None => setVariable(key, "")
                    }
                }
                CliConfig._model = oldPrimaryModel
                CliConfig.fallbackModels = oldFallbackModels
                CliConfig._imageModel = oldImageModel
                CliConfig.imageFallbackModels = oldImageFallbackModels
                CliConfig._pdfModel = oldPdfModel
                CliConfig.pdfFallbackModels = oldPdfFallbackModels
                CliConfig.pdfMaxBytesMb = oldPdfMaxBytesMb
                CliConfig.pdfMaxPages = oldPdfMaxPages
                CliConfig._fastModel = oldFastModel
                CliConfig.temperature = oldTemperature
                CliConfig.defaultModelInputLimit = oldDefaultModelInputLimit
                CliConfig.defaultModelOutputLimit = oldDefaultModelOutputLimit
                CliConfig.workspaceDirOverride = oldWorkspaceDirOverride
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                try { remove(home, recursive: true) } catch (_: Exception) { () }
                @Expect(gatewaySettled, true)
                @Expect(brokerGone, true)
                @Expect(gcmGone, true)
                @Expect(gcmGroupGone, true)
                @Expect(dependenciesSettled, true)
                @Expect(feishuDependenciesSettled, true)
            }
        }
    }

    @TestCase
    public func s5N1FormalDroppedCompletionRecoversSameDeliveryWithoutRepeatingEffects(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let home = Path("/tmp/metis-s5-n1-dropped-completion-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            let gatewayPort = gatewayServeStopTemporaryPort()
            let webhookPort = gatewayServeStopTemporaryPort()
            @Expect(gatewayPort > 0 && webhookPort > 0 && gatewayPort != webhookPort, true)
            let oldHome = getVariable("METIS_HOME")
            let oldRoot = getVariable("METIS_CJPM_ROOT")
            let proxyEnvironmentKeys = [
                "METIS_STDIO_BROKER_NODE_COMMAND", "METIS_S5_BROKER_PROXY_READY",
                "METIS_S5_BROKER_PROXY_FAIL", "METIS_S5_BROKER_PROXY_WRITER_CLOSED",
                "METIS_S5_BROKER_PROXY_CLEANUP", "METIS_S5_BROKER_PROXY_DROP_DELIVERY_ID",
                "METIS_S5_BROKER_PROXY_ADMISSION_SEEN", "METIS_S5_BROKER_PROXY_COMPLETION_DROPPED"
            ]
            let oldProxyEnvironment = ArrayList<(String, Option<String>)>()
            for (key in proxyEnvironmentKeys) { oldProxyEnvironment.add((key, getVariable(key))) }
            let apiKeyAliases = cliProviderApiKeyEnvAliases("openai")
            let baseUrlAliases = cliProviderBaseUrlEnvAliases("openai")
            let oldProviderEnvironment = ArrayList<(String, Option<String>)>()
            for (key in apiKeyAliases) { oldProviderEnvironment.add((key, getVariable(key))) }
            for (key in baseUrlAliases) { oldProviderEnvironment.add((key, getVariable(key))) }
            let oldPrimaryModel = CliConfig._model
            let oldFallbackModels = CliConfig.fallbackModels
            let oldImageModel = CliConfig._imageModel
            let oldImageFallbackModels = CliConfig.imageFallbackModels
            let oldPdfModel = CliConfig._pdfModel
            let oldPdfFallbackModels = CliConfig.pdfFallbackModels
            let oldPdfMaxBytesMb = CliConfig.pdfMaxBytesMb
            let oldPdfMaxPages = CliConfig.pdfMaxPages
            let oldFastModel = CliConfig._fastModel
            let oldTemperature = CliConfig.temperature
            let oldDefaultModelInputLimit = CliConfig.defaultModelInputLimit
            let oldDefaultModelOutputLimit = CliConfig.defaultModelOutputLimit
            let oldWorkspaceDirOverride = CliConfig.workspaceDirOverride
            let brokerScript = Path(managedStdioResolveBrokerScriptPath())
            let project = brokerScript.parent.parent
            let metisBinaryValue = gatewayFormalMetisBinary(project)
            @Expect(metisBinaryValue.isSome(), true)
            if (metisBinaryValue.isNone()) { return }
            let metisBinary = metisBinaryValue.getOrThrow()
            let dependencyScript = brokerScript.parent.join("metis-s5-loopback-dependencies.mjs")
            let proxySource = brokerScript.parent.join("metis-s5-broker-writer-failure-proxy.mjs")
            let gcmSource = gatewayS5GcmBinary()
            let gcmBinary = home.join("gitcodemonitor")
            let proxy = home.join("metis-s5-broker-writer-failure-proxy.mjs")
            let proxyReady = home.join("broker-proxy.ready.json")
            let admissionSeen = home.join("admission-seen.json")
            let completionDropped = home.join("completion-dropped.json")
            let deliveryId = "s5-p1-9101-end"
            let iid: Int64 = 9101
            let expectedDeliveries = HashSet<String>()
            expectedDeliveries.add(deliveryId)
            let expectedWritebacks = HashMap<String, String>()
            expectedWritebacks["${iid}"] = deliveryId
            var dependencies = None<GatewayS5DependencyProcess>
            var feishuDependencies = None<GatewayS5DependencyProcess>
            var oldGatewayProcess = None<SubProcess>
            var replacementGatewayProcess = None<SubProcess>
            var oldGatewayIdentity = None<GatewayServeIdentity>
            var replacementGatewayIdentity = None<GatewayServeIdentity>
            let stopOutput = ArrayList<String>()
            try {
                Directory.create(home, recursive: true)
                @Expect(exists(metisBinary), true)
                @Expect(exists(gcmSource), true)
                @Expect(exists(proxySource), true)
                @Expect(exists(dependencyScript), true)
                @Expect(executeWithOutput("/bin/cp", [gcmSource.toString(), gcmBinary.toString()])[0], 0)
                @Expect(executeWithOutput("/bin/cp", [proxySource.toString(), proxy.toString()])[0], 0)
                @Expect(executeWithOutput("/bin/chmod", ["700", gcmBinary.toString()])[0], 0)
                @Expect(executeWithOutput("/bin/chmod", ["700", proxy.toString()])[0], 0)
                setVariable("METIS_HOME", home.toString())
                setVariable("METIS_CJPM_ROOT", project.toString())
                setVariable("METIS_STDIO_BROKER_NODE_COMMAND", proxy.toString())
                setVariable("METIS_S5_BROKER_PROXY_READY", proxyReady.toString())
                setVariable("METIS_S5_BROKER_PROXY_FAIL", "")
                setVariable("METIS_S5_BROKER_PROXY_WRITER_CLOSED", "")
                setVariable("METIS_S5_BROKER_PROXY_CLEANUP", "")
                setVariable("METIS_S5_BROKER_PROXY_DROP_DELIVERY_ID", deliveryId)
                setVariable("METIS_S5_BROKER_PROXY_ADMISSION_SEEN", admissionSeen.toString())
                setVariable("METIS_S5_BROKER_PROXY_COMPLETION_DROPPED", completionDropped.toString())
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()

                dependencies = Some(gatewayS5StartDependencies(home, dependencyScript, replyMarker: "s5-n1-dropped-completion"))
                let feishuHome = home.join("feishu-loopback")
                Directory.create(feishuHome, recursive: true)
                feishuDependencies = Some(gatewayS5StartDependencies(feishuHome, dependencyScript))
                let stableDependencies = dependencies.getOrThrow()
                let stableFeishuDependencies = feishuDependencies.getOrThrow()
                @Expect(stableDependencies.port > 0 && stableFeishuDependencies.port > 0, true)
                @Expect(stableDependencies.port != stableFeishuDependencies.port, true)
                for (key in apiKeyAliases) { setVariable(key, "fake-s5-openai-key") }
                for (key in baseUrlAliases) { setVariable(key, "http://127.0.0.1:${stableDependencies.port}/v1") }
                let configured = gatewayS5ConfigureFormalGateway(
                    home, gatewayPort, webhookPort, stableDependencies.port, gcmBinary,
                    liveWriteback: true, includeFeishu: true, feishuPort: stableFeishuDependencies.port
                )
                let queuePath = configured[1]
                let manifestPath = configured[2]
                gatewayS5WriteGcmManifest(manifestPath, gcmBinary)
                @Expect(loadServicePluginManifest(manifestPath.toString()).ok, true)

                let parentHeapBeforeOldLaunch = getVariable("cjHeapSize")
                let launchedOld = gatewayS5LaunchGateway(metisBinary)
                @Expect(gatewayS5HeapEnvironmentMatches(parentHeapBeforeOldLaunch), true)
                oldGatewayProcess = Some(launchedOld)
                let oldGatewayPid = launchedOld.pid
                oldGatewayIdentity = gatewayServeStopCaptureOwnedIdentity(home, oldGatewayPid, metisBinary, 5000)
                @Expect(oldGatewayIdentity.isSome(), true)
                if (oldGatewayIdentity.isNone()) { return }
                let oldCapture = GatewayS5P1Capture()
                let stableOldGatewayPid = oldGatewayPid
                let oldOwner = GatewayServeStopLiveOwnerProof()
                let readyzUrl = "http://127.0.0.1:${gatewayPort}/readyz"
                let stableOldProxyReady = ArrayList<GatewayS5ProxyReadySnapshot>()
                let oldReady = gatewayServeStopWaitUntil(15000, { =>
                    let first = gatewayS5ProxyReadySnapshot(proxyReady)
                    if (first.isNone()) { return false }
                    let candidate = first.getOrThrow()
                    let candidatePgid = gatewayServeStopProcessGroup(candidate.ownerPid)
                    if (candidate.helloPid != candidate.brokerPid || !gatewayServeStopPidAlive(candidate.ownerPid) ||
                        gatewayServeStopParentPid(candidate.ownerPid) != candidate.brokerPid || candidatePgid <= 1) {
                        return false
                    }
                    oldCapture.refreshLease(home, candidate.ownerPid, oldGatewayPid, webhookPort)
                    oldOwner.refresh(readyzUrl)
                    if (!oldCapture.leaseDirExists || oldCapture.leaseFileCount != 1 ||
                        !oldCapture.leaseUtf8 || !oldCapture.leaseJson || !oldCapture.leaseIdentityMatches ||
                        !oldCapture.leasePidMatches || !oldCapture.leasePortMatches || !oldCapture.leaseRunning ||
                        oldOwner.httpStatus != 200 || !oldOwner.running || oldOwner.ownerCount < 1 ||
                        !gatewayServeStopPortListening(webhookPort)) {
                        return false
                    }
                    let second = gatewayS5ProxyReadySnapshot(proxyReady)
                    if (second.isNone() || !candidate.sameOwner(second.getOrThrow())) { return false }
                    stableOldProxyReady.clear()
                    stableOldProxyReady.add(candidate)
                    true
                })
                @Expect(oldReady, true)
                if (!oldReady) { return }
                @Expect(stableOldProxyReady.size, 1)
                if (stableOldProxyReady.size != 1) { return }
                let frozenOldProxyReady = stableOldProxyReady[0]
                let oldProxyPid = frozenOldProxyReady.wrapperPid
                let oldBrokerPid = frozenOldProxyReady.brokerPid
                let oldHelloBrokerPid = frozenOldProxyReady.helloPid
                let oldBrokerGeneration = frozenOldProxyReady.generation
                let oldGcmPid = frozenOldProxyReady.ownerPid
                let oldGcmPgid = gatewayServeStopProcessGroup(oldGcmPid)
                oldCapture.brokerPid = oldBrokerPid
                oldCapture.gcmPid = oldGcmPid
                oldCapture.gcmPgid = oldGcmPgid
                @Expect(oldProxyPid > 1 && oldBrokerPid > 1 && oldGcmPid > 1 && oldGcmPgid > 1, true)
                @Expect(oldHelloBrokerPid, oldBrokerPid)
                @Expect(oldBrokerGeneration > 0, true)
                @Expect(gatewayServeStopParentPid(oldProxyPid), oldGatewayPid)
                @Expect(gatewayServeStopParentPid(oldBrokerPid), oldProxyPid)
                @Expect(gatewayServeStopParentPid(oldGcmPid), oldBrokerPid)
                @Expect(gatewayServeStopProcessGroup(oldGcmPid), oldGcmPgid)
                let oldLeaseReady = gatewayServeStopWaitUntil(5000, { =>
                    oldCapture.refreshLease(home, oldGcmPid, oldGatewayPid, webhookPort)
                    oldCapture.leaseDirExists && oldCapture.leaseFileCount == 1 && oldCapture.leaseUtf8 &&
                        oldCapture.leaseJson && oldCapture.leaseIdentityMatches && oldCapture.leasePidMatches &&
                        oldCapture.leasePortMatches && oldCapture.leaseRunning
                })
                @Expect(oldLeaseReady, true)
                @Expect(oldCapture.leaseDirExists, true)
                @Expect(oldCapture.leaseFileCount, 1)
                @Expect(oldCapture.leaseUtf8, true)
                @Expect(oldCapture.leaseJson, true)
                @Expect(oldCapture.leaseIdentityMatches, true)
                @Expect(oldCapture.leasePidMatches, true)
                @Expect(oldCapture.leasePortMatches, true)
                @Expect(oldCapture.leaseRunning, true)
                if (!oldLeaseReady) { return }

                let beforePostProxyReady = gatewayS5ProxyReadySnapshot(proxyReady)
                oldCapture.refreshLease(home, oldGcmPid, oldGatewayPid, webhookPort)
                let oldOwnerStableBeforePost = beforePostProxyReady.isSome() &&
                    frozenOldProxyReady.sameOwner(beforePostProxyReady.getOrThrow()) &&
                    gatewayServeStopPidAlive(oldGcmPid) && gatewayServeStopParentPid(oldGcmPid) == oldBrokerPid &&
                    gatewayServeStopProcessGroup(oldGcmPid) == oldGcmPgid && oldCapture.leaseIdentityMatches &&
                    oldCapture.leasePidMatches && oldCapture.leasePortMatches && oldCapture.leaseRunning
                @Expect(oldOwnerStableBeforePost, true)
                if (!oldOwnerStableBeforePost) { return }
                let posted = gatewayS5PostWebhook(webhookPort, deliveryId, iid: iid)
                @Expect(posted >= 200 && posted < 300, true)
                let dropMarkersReady = gatewayServeStopWaitUntil(20000, { =>
                    gatewayS5DropMarkerProof(admissionSeen, "broker_written", deliveryId)[0] &&
                        gatewayS5DropMarkerProof(completionDropped, "owner_written_synthesized", deliveryId)[0]
                })
                @Expect(dropMarkersReady, true)
                if (!dropMarkersReady) { return }
                let admissionMarker = gatewayS5DropMarkerProof(admissionSeen, "broker_written", deliveryId)
                let completionMarker = gatewayS5DropMarkerProof(completionDropped, "owner_written_synthesized", deliveryId)
                @Expect(admissionMarker[0], true)
                @Expect(admissionMarker[1], 1)
                @Expect(completionMarker[0], true)
                @Expect(completionMarker[1], 2)
                @Expect(completionMarker[2] == admissionMarker[2], true)
                @Expect(admissionMarker[3], oldBrokerGeneration)
                @Expect(completionMarker[3], oldBrokerGeneration)
                @Expect(admissionMarker[4].isEmpty(), false)
                @Expect(completionMarker[4], admissionMarker[4])
                @Expect(admissionMarker[5].isEmpty(), false)
                @Expect(completionMarker[5].isEmpty(), false)
                @Expect(completionMarker[5] == admissionMarker[5], false)
                let afterMarkersProxyReady = gatewayS5ProxyReadySnapshot(proxyReady)
                oldCapture.refreshLease(home, oldGcmPid, oldGatewayPid, webhookPort)
                let oldOwnerStableAfterMarkers = afterMarkersProxyReady.isSome() &&
                    frozenOldProxyReady.sameOwner(afterMarkersProxyReady.getOrThrow()) &&
                    admissionMarker[4] == frozenOldProxyReady.ownerId &&
                    completionMarker[4] == frozenOldProxyReady.ownerId && gatewayServeStopPidAlive(oldGcmPid) &&
                    gatewayServeStopParentPid(oldGcmPid) == oldBrokerPid && oldCapture.leaseIdentityMatches &&
                    oldCapture.leasePidMatches && oldCapture.leasePortMatches && oldCapture.leaseRunning
                @Expect(oldOwnerStableAfterMarkers, true)
                if (!oldOwnerStableAfterMarkers) { return }
                oldOwner.refresh(readyzUrl)
                @Expect(oldOwner.httpStatus == 200 && oldOwner.running && oldOwner.ownerCount >= 1, true)
                let oldAttemptToken = admissionMarker[2]
                let awaitingPath = queuePath.join("awaiting-host").join("${deliveryId}.json")
                let receiptRoot = home.join("service-plugin").join("webhook-receipts")
                let receiptReady = gatewayServeStopWaitUntil(10000, { =>
                    let queueProof = gatewayS5QueueDeliveryProof(awaitingPath, deliveryId)
                    let receiptProof = gatewayS5ReceiptProof(receiptRoot, deliveryId)
                    queueProof[0] && queueProof[1] == "awaiting-host" && queueProof[2] == "admitted" &&
                        queueProof[3] == oldAttemptToken && receiptProof[0] &&
                        receiptProof[3] == oldAttemptToken && receiptProof[4] == "completed_unconfirmed"
                })
                @Expect(receiptReady, true)
                if (!receiptReady) { return }
                let oldEffectsReady = gatewayServeStopWaitUntil(10000, { =>
                    let mainLedger = GatewayS5StrictLedger(stableDependencies.eventsPath, expectedDeliveries, expectedWritebacks)
                    let feishuLedger = GatewayS5StrictLedger(stableFeishuDependencies.eventsPath, expectedDeliveries, expectedWritebacks)
                    mainLedger.valid() && feishuLedger.valid() &&
                        mainLedger.exactOnce("model_response", expectedDeliveries) &&
                        mainLedger.exactWritebacks(expectedWritebacks, expectedDeliveries) &&
                        mainLedger.exactOnce("telegram_send", expectedDeliveries) &&
                        feishuLedger.exactOnce("feishu_send", expectedDeliveries)
                })
                @Expect(oldEffectsReady, true)
                if (!oldEffectsReady) { return }

                setGatewayStopOutputForTest(Some({ line => stopOutput.add(line) }))
                let oldStopExit = gatewayExecuteStopServe()
                setGatewayStopOutputForTest(None<(String) -> Unit>)
                @Expect(oldStopExit, 0)
                let oldCompletionPath = home.join("gateway-serve.stop-complete")
                let oldCompletion = try { String.fromUtf8(File.readFrom(oldCompletionPath)) } catch (_: Exception) { "" }
                @Expect(gatewayServeStopCompletionField(oldCompletion, "status"), "graceful")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "fullTerminal"), "1")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "servicePluginDispatchStatus"), "drained")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "servicePluginOwnerStatus"), "graceful_exited")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "servicePluginLeaseStatus"), "stopped")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "servicePluginPortStatus"), "released")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "servicePluginPendingCount"), "0")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "channelsStatus"), "stopped")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "brokerStatus"), "stopped")
                let oldStopTerminal = oldStopExit == 0 &&
                    gatewayServeStopCompletionField(oldCompletion, "status") == "graceful" &&
                    gatewayServeStopCompletionField(oldCompletion, "fullTerminal") == "1"
                if (!oldStopTerminal) { return }
                @Expect(gatewayServeStopReapCompletedOwnedProcess(oldGatewayProcess), true)
                oldGatewayProcess = None<SubProcess>
                @Expect(gatewayServeStopWaitUntil(5000, { => !gatewayServeStopPidAlive(stableOldGatewayPid) }), true)
                @Expect(gatewayServeStopWaitUntil(5000, { => !gatewayServeStopPidAlive(oldProxyPid) }), true)
                @Expect(gatewayServeStopWaitUntil(5000, { => !gatewayServeStopPidAlive(oldBrokerPid) }), true)
                @Expect(gatewayServeStopWaitUntil(5000, { => gatewayServeStopGroupGone(oldGcmPgid) }), true)
                @Expect(gatewayServeStopPortListening(gatewayPort), false)
                @Expect(gatewayServeStopPortListening(webhookPort), false)
                oldCapture.refreshLease(home, oldGcmPid, oldGatewayPid, webhookPort)
                @Expect(oldCapture.leaseStopped, true)
                @Expect(gatewayServeStopRuntimeOwnerCount(home.join("gateway-runtime-state.json")), 0)
                let pendingPath = queuePath.join("pending").join("${deliveryId}.json")
                @Expect(gatewayServeStopWaitUntil(5000, { =>
                    let pending = gatewayS5QueueDeliveryProof(pendingPath, deliveryId)
                    pending[0] && pending[1] == "pending" && pending[2] == "recovered" && pending[3] == oldAttemptToken
                }), true)
                let retainedReceipt = gatewayS5ReceiptProof(receiptRoot, deliveryId)
                @Expect(retainedReceipt[0], true)
                @Expect(retainedReceipt[3] == oldAttemptToken, true)
                @Expect(retainedReceipt[4], "completed_unconfirmed")

                stopOutput.clear()
                for (key in proxyEnvironmentKeys) { setVariable(key, "") }
                CliSettingManager.invalidate()
                let parentHeapBeforeReplacementLaunch = getVariable("cjHeapSize")
                let launchedReplacement = gatewayS5LaunchGateway(metisBinary)
                @Expect(gatewayS5HeapEnvironmentMatches(parentHeapBeforeReplacementLaunch), true)
                replacementGatewayProcess = Some(launchedReplacement)
                let replacementGatewayPid = launchedReplacement.pid
                replacementGatewayIdentity = gatewayServeStopCaptureOwnedIdentity(home, replacementGatewayPid, metisBinary, 5000)
                @Expect(replacementGatewayIdentity.isSome(), true)
                if (replacementGatewayIdentity.isNone()) { return }
                @Expect(oldGatewayIdentity.getOrThrow().matches(replacementGatewayIdentity.getOrThrow()), false)
                let replacementCapture = GatewayS5P1Capture()
                let replacementOwner = GatewayServeStopLiveOwnerProof()
                let stableReplacementGatewayPid = replacementGatewayPid
                let replacementReady = gatewayServeStopWaitUntil(15000, { =>
                    replacementCapture.brokerPid = gatewayServeStopChildPid(stableReplacementGatewayPid, brokerScript.toString())
                    replacementCapture.gcmPid = gatewayServeStopChildPid(replacementCapture.brokerPid, gcmBinary.toString())
                    replacementCapture.gcmPgid = gatewayServeStopProcessGroup(replacementCapture.gcmPid)
                    replacementOwner.refresh(readyzUrl)
                    replacementCapture.brokerPid > 1 && replacementCapture.gcmPid > 1 && replacementCapture.gcmPgid > 1 &&
                        replacementOwner.httpStatus == 200 && replacementOwner.running && replacementOwner.ownerCount >= 1 &&
                        gatewayServeStopPortListening(webhookPort)
                })
                @Expect(replacementReady, true)
                if (!replacementReady) { return }
                let replacementBrokerPid = replacementCapture.brokerPid
                let replacementGcmPid = replacementCapture.gcmPid
                let replacementGcmPgid = replacementCapture.gcmPgid
                @Expect(replacementGatewayPid != oldGatewayPid, true)
                @Expect(replacementBrokerPid != oldBrokerPid, true)
                @Expect(replacementGcmPid != oldGcmPid, true)
                let replacementLeaseReady = gatewayServeStopWaitUntil(5000, { =>
                    replacementCapture.refreshLease(home, replacementGcmPid, replacementGatewayPid, webhookPort)
                    replacementCapture.leaseDirExists && replacementCapture.leaseFileCount == 1 &&
                        replacementCapture.leaseUtf8 && replacementCapture.leaseJson &&
                        replacementCapture.leaseIdentityMatches && replacementCapture.leasePidMatches &&
                        replacementCapture.leasePortMatches && replacementCapture.leaseRunning
                })
                @Expect(replacementLeaseReady, true)
                @Expect(replacementCapture.leaseDirExists, true)
                @Expect(replacementCapture.leaseFileCount, 1)
                @Expect(replacementCapture.leaseUtf8, true)
                @Expect(replacementCapture.leaseJson, true)
                @Expect(replacementCapture.leaseIdentityMatches, true)
                @Expect(replacementCapture.leasePidMatches, true)
                @Expect(replacementCapture.leasePortMatches, true)
                @Expect(replacementCapture.leaseRunning, true)
                if (!replacementLeaseReady) { return }
                let processedPath = queuePath.join("processed").join("${deliveryId}.json")
                let replacementObservations = HashSet<String>()
                let replacementProcessed = gatewayServeStopWaitUntil(30000, { =>
                    let processed = gatewayS5QueueDeliveryProof(processedPath, deliveryId)
                    let awaiting = gatewayS5QueueDeliveryProof(awaitingPath, deliveryId)
                    if (awaiting[0] && awaiting[3] != oldAttemptToken) { replacementObservations.add("awaiting") }
                    if (processed[0] && processed[3] != oldAttemptToken) { replacementObservations.add("processed") }
                    let mainLedger = GatewayS5StrictLedger(stableDependencies.eventsPath, expectedDeliveries, expectedWritebacks)
                    let feishuLedger = GatewayS5StrictLedger(stableFeishuDependencies.eventsPath, expectedDeliveries, expectedWritebacks)
                    processed[0] && processed[1] == "processed" && processed[2] == "completed" &&
                        processed[3] != oldAttemptToken && gatewayS5RegularFileCount(queuePath.join("pending")) == 0 &&
                        gatewayS5RegularFileCount(queuePath.join("awaiting-host")) == 0 &&
                        gatewayS5RegularFileCount(receiptRoot) == 0 && mainLedger.valid() && feishuLedger.valid() &&
                        mainLedger.exactOnce("model_response", expectedDeliveries) &&
                        mainLedger.exactWritebacks(expectedWritebacks, expectedDeliveries) &&
                        mainLedger.exactOnce("telegram_send", expectedDeliveries) &&
                        feishuLedger.exactOnce("feishu_send", expectedDeliveries)
                })
                let replacementProcessedProof = gatewayS5QueueDeliveryProof(processedPath, deliveryId)
                let replacementAwaitingProof = gatewayS5QueueDeliveryProof(awaitingPath, deliveryId)
                let replacementReceiptProof = gatewayS5ReceiptProof(receiptRoot, deliveryId)
                let replacementPendingCount = gatewayS5RegularFileCount(queuePath.join("pending"))
                let replacementProcessingCount = gatewayS5RegularFileCount(queuePath.join("processing"))
                let replacementAwaitingCount = gatewayS5RegularFileCount(queuePath.join("awaiting-host"))
                let replacementProcessedCount = gatewayS5RegularFileCount(queuePath.join("processed"))
                let replacementMainLedger = GatewayS5StrictLedger(
                    stableDependencies.eventsPath, expectedDeliveries, expectedWritebacks
                )
                let replacementFeishuLedger = GatewayS5StrictLedger(
                    stableFeishuDependencies.eventsPath, expectedDeliveries, expectedWritebacks
                )
                replacementOwner.refresh(readyzUrl)
                replacementCapture.refreshLease(home, replacementGcmPid, replacementGatewayPid, webhookPort)
                let replacementSchedulerSettled = replacementPendingCount == 0 && replacementProcessingCount == 0 &&
                    replacementAwaitingCount == 0 && replacementProcessedCount == 1 && replacementReceiptProof[1] == 0
                let replacementReceiptTokenMatchesQueue = if (!replacementReceiptProof[0]) {
                    replacementReceiptProof[1] == 0
                } else if (replacementAwaitingProof[0]) {
                    replacementReceiptProof[3] == replacementAwaitingProof[3]
                } else if (replacementProcessedProof[0]) {
                    replacementReceiptProof[3] == replacementProcessedProof[3]
                } else {
                    false
                }
                @Expect(replacementObservations.contains("awaiting") || replacementObservations.contains("processed"), true)
                @Expect(replacementProcessedProof[0], true)
                @Expect(replacementProcessedProof[1], "processed")
                @Expect(replacementProcessedProof[2], "completed")
                @Expect(replacementProcessedProof[3] == oldAttemptToken, false)
                @Expect(replacementPendingCount, 0)
                @Expect(replacementProcessingCount, 0)
                @Expect(replacementAwaitingCount, 0)
                @Expect(replacementProcessedCount, 1)
                @Expect(replacementReceiptProof[1], 0)
                @Expect(replacementReceiptProof[4].isEmpty(), true)
                @Expect(replacementReceiptTokenMatchesQueue, true)
                @Expect(replacementMainLedger.valid(), true)
                @Expect(replacementFeishuLedger.valid(), true)
                @Expect(replacementMainLedger.exactOnce("model_response", expectedDeliveries), true)
                @Expect(replacementMainLedger.exactWritebacks(expectedWritebacks, expectedDeliveries), true)
                @Expect(replacementMainLedger.exactOnce("telegram_send", expectedDeliveries), true)
                @Expect(replacementFeishuLedger.exactOnce("feishu_send", expectedDeliveries), true)
                @Expect(replacementReady, true)
                @Expect(replacementOwner.httpStatus == 200 && replacementOwner.running && replacementOwner.ownerCount >= 1, true)
                @Expect(replacementCapture.leaseIdentityMatches, true)
                @Expect(replacementCapture.leasePidMatches, true)
                @Expect(replacementCapture.leasePortMatches, true)
                @Expect(replacementCapture.leaseRunning, true)
                @Expect(replacementSchedulerSettled, true)
                @Expect(replacementProcessed, true)
                if (!replacementProcessed) { return }
                let processed = gatewayS5QueueDeliveryProof(processedPath, deliveryId)
                @Expect(processed[0], true)
                @Expect(processed[1], "processed")
                @Expect(processed[2], "completed")
                @Expect(processed[3] == oldAttemptToken, false)
                @Expect(gatewayS5RegularFileCount(queuePath.join("processed")), 1)
                @Expect(gatewayS5RegularFileCount(queuePath.join("pending")), 0)
                @Expect(gatewayS5RegularFileCount(queuePath.join("awaiting-host")), 0)
                @Expect(gatewayS5RegularFileCount(receiptRoot), 0)
                let finalMainLedger = GatewayS5StrictLedger(stableDependencies.eventsPath, expectedDeliveries, expectedWritebacks)
                let finalFeishuLedger = GatewayS5StrictLedger(stableFeishuDependencies.eventsPath, expectedDeliveries, expectedWritebacks)
                @Expect(finalMainLedger.valid(), true)
                @Expect(finalFeishuLedger.valid(), true)
                @Expect(finalMainLedger.exactOnce("model_response", expectedDeliveries), true)
                @Expect(finalMainLedger.exactWritebacks(expectedWritebacks, expectedDeliveries), true)
                @Expect(finalMainLedger.exactOnce("telegram_send", expectedDeliveries), true)
                @Expect(finalFeishuLedger.exactOnce("feishu_send", expectedDeliveries), true)
                @Expect(gatewayS5DropMarkerProof(admissionSeen, "broker_written", deliveryId)[2] == oldAttemptToken, true)
                @Expect(gatewayS5DropMarkerProof(completionDropped, "owner_written_synthesized", deliveryId)[2] == oldAttemptToken, true)

                setGatewayStopOutputForTest(Some({ line => stopOutput.add(line) }))
                let replacementStopExit = gatewayExecuteStopServe()
                setGatewayStopOutputForTest(None<(String) -> Unit>)
                @Expect(replacementStopExit, 0)
                let replacementCompletionPath = home.join("gateway-serve.stop-complete")
                let replacementCompletion = try { String.fromUtf8(File.readFrom(replacementCompletionPath)) } catch (_: Exception) { "" }
                @Expect(gatewayServeStopCompletionField(replacementCompletion, "status"), "graceful")
                @Expect(gatewayServeStopCompletionField(replacementCompletion, "fullTerminal"), "1")
                @Expect(gatewayServeStopCompletionField(replacementCompletion, "servicePluginDispatchStatus"), "drained")
                @Expect(gatewayServeStopCompletionField(replacementCompletion, "servicePluginOwnerStatus"), "graceful_exited")
                @Expect(gatewayServeStopCompletionField(replacementCompletion, "servicePluginLeaseStatus"), "stopped")
                @Expect(gatewayServeStopCompletionField(replacementCompletion, "servicePluginPortStatus"), "released")
                @Expect(gatewayServeStopCompletionField(replacementCompletion, "servicePluginPendingCount"), "0")
                @Expect(gatewayServeStopCompletionField(replacementCompletion, "channelsStatus"), "stopped")
                @Expect(gatewayServeStopCompletionField(replacementCompletion, "brokerStatus"), "stopped")
                let replacementStopTerminal = replacementStopExit == 0 &&
                    gatewayServeStopCompletionField(replacementCompletion, "status") == "graceful" &&
                    gatewayServeStopCompletionField(replacementCompletion, "fullTerminal") == "1"
                if (!replacementStopTerminal) { return }
                @Expect(gatewayServeStopReapCompletedOwnedProcess(replacementGatewayProcess), true)
                replacementGatewayProcess = None<SubProcess>
                @Expect(gatewayServeStopWaitUntil(5000, { => !gatewayServeStopPidAlive(stableReplacementGatewayPid) }), true)
                @Expect(gatewayServeStopWaitUntil(5000, { => !gatewayServeStopPidAlive(replacementBrokerPid) }), true)
                @Expect(gatewayServeStopWaitUntil(5000, { => gatewayServeStopGroupGone(replacementGcmPgid) }), true)
                @Expect(gatewayServeStopPortListening(gatewayPort), false)
                @Expect(gatewayServeStopPortListening(webhookPort), false)
                replacementCapture.refreshLease(home, replacementGcmPid, replacementGatewayPid, webhookPort)
                @Expect(replacementCapture.leaseStopped, true)
                @Expect(gatewayServeStopRuntimeOwnerCount(home.join("gateway-runtime-state.json")), 0)
                @Expect(gatewayS5StopDependencies(dependencies), true)
                @Expect(gatewayS5StopDependencies(feishuDependencies), true)
                @Expect(gatewayServeStopPortListening(stableDependencies.port), false)
                @Expect(gatewayServeStopPortListening(stableFeishuDependencies.port), false)
            } finally {
                setGatewayStopOutputForTest(None<(String) -> Unit>)
                if (replacementGatewayIdentity.isSome()) {
                    try { gatewayServeStopReapOwnedGateway(replacementGatewayIdentity, metisBinary, home) } catch (_: Exception) { () }
                }
                try { gatewayServeStopReapOwnedHandle(replacementGatewayProcess, metisBinary) } catch (_: Exception) { () }
                if (oldGatewayIdentity.isSome()) {
                    try { gatewayServeStopReapOwnedGateway(oldGatewayIdentity, metisBinary, home) } catch (_: Exception) { () }
                }
                try { gatewayServeStopReapOwnedHandle(oldGatewayProcess, metisBinary) } catch (_: Exception) { () }
                let _ = gatewayS5StopDependencies(dependencies)
                let _ = gatewayS5StopDependencies(feishuDependencies)
                try { let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000) } catch (_: Exception) { () }
                match (oldHome) { case Some(value) => setVariable("METIS_HOME", value) case None => setVariable("METIS_HOME", "") }
                match (oldRoot) { case Some(value) => setVariable("METIS_CJPM_ROOT", value) case None => setVariable("METIS_CJPM_ROOT", "") }
                for ((key, value) in oldProxyEnvironment) {
                    match (value) { case Some(previous) => setVariable(key, previous) case None => setVariable(key, "") }
                }
                for ((key, value) in oldProviderEnvironment) {
                    match (value) { case Some(previous) => setVariable(key, previous) case None => setVariable(key, "") }
                }
                CliConfig._model = oldPrimaryModel
                CliConfig.fallbackModels = oldFallbackModels
                CliConfig._imageModel = oldImageModel
                CliConfig.imageFallbackModels = oldImageFallbackModels
                CliConfig._pdfModel = oldPdfModel
                CliConfig.pdfFallbackModels = oldPdfFallbackModels
                CliConfig.pdfMaxBytesMb = oldPdfMaxBytesMb
                CliConfig.pdfMaxPages = oldPdfMaxPages
                CliConfig._fastModel = oldFastModel
                CliConfig.temperature = oldTemperature
                CliConfig.defaultModelInputLimit = oldDefaultModelInputLimit
                CliConfig.defaultModelOutputLimit = oldDefaultModelOutputLimit
                CliConfig.workspaceDirOverride = oldWorkspaceDirOverride
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                try { remove(home, recursive: true) } catch (_: Exception) { () }
            }
        }
    }

    @TestCase
    public func s5N1FormalGatewayWriterFailureReapsOldGenerationAndReplacementNeverReplays(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let suffix = DateTime.now().toUnixTimeStamp().toNanoseconds()
            let oldHome = Path("/tmp/metis-s5-n1-old-${suffix}")
            let replacementHome = Path("/tmp/metis-s5-n1-new-${suffix}")
            let previousHome = getVariable("METIS_HOME")
            let previousRoot = getVariable("METIS_CJPM_ROOT")
            let environmentKeys = [
                "METIS_STDIO_BROKER_NODE_COMMAND", "METIS_S5_BROKER_PROXY_READY",
                "METIS_S5_BROKER_PROXY_FAIL", "METIS_S5_BROKER_PROXY_WRITER_CLOSED",
                "METIS_S5_BROKER_PROXY_CLEANUP", "METIS_S5_BROKER_PROXY_DROP_DELIVERY_ID",
                "METIS_S5_BROKER_PROXY_ADMISSION_SEEN", "METIS_S5_BROKER_PROXY_COMPLETION_DROPPED",
                "METIS_S5_BROKER_PROXY_HOLD_ENTERED", "METIS_S5_BROKER_PROXY_HOLD_RELEASE",
                "METIS_S5_BROKER_PROXY_HOLD_RELEASED", "METIS_STDIO_BROKER_TEST_MODE",
                "METIS_STDIO_BROKER_DIAGNOSTIC_MARKER", "METIS_TEST_SERVICE_PLUGIN_DISPATCH_FENCED_MARKER",
                "METIS_TEST_SERVICE_PLUGIN_DISPATCH_FENCED_SERVICE_ID",
                "METIS_TEST_SERVICE_PLUGIN_DISPATCH_FENCED_NONCE",
                "METIS_TEST_GATEWAY_SHUTDOWN_PHASE_MARKER", "METIS_TEST_GATEWAY_SHUTDOWN_PHASE_NONCE",
                "GCM_S5_READY_PATH",
                "GCM_S5_STOP_SEEN_PATH", "GCM_S5_CHILD_DYLD_LIBRARY_PATH"
            ]
            let previousEnvironment = ArrayList<(String, Option<String>)>()
            for (key in environmentKeys) { previousEnvironment.add((key, getVariable(key))) }
            let providerEnvironment = ArrayList<(String, Option<String>)>()
            let apiKeyAliases = cliProviderApiKeyEnvAliases("openai")
            let baseUrlAliases = cliProviderBaseUrlEnvAliases("openai")
            for (key in apiKeyAliases) { providerEnvironment.add((key, getVariable(key))) }
            for (key in baseUrlAliases) { providerEnvironment.add((key, getVariable(key))) }
            let brokerScript = Path(managedStdioResolveBrokerScriptPath())
            let project = brokerScript.parent.parent
            let metisBinaryValue = gatewayFormalMetisBinary(project)
            @Expect(metisBinaryValue.isSome(), true)
            if (metisBinaryValue.isNone()) { return }
            let metisBinary = metisBinaryValue.getOrThrow()
            let dependencyScript = brokerScript.parent.join("metis-s5-loopback-dependencies.mjs")
            let proxySource = brokerScript.parent.join("metis-s5-broker-writer-failure-proxy.mjs")
            let gcmRoot = gatewayS5GcmRoot()
            let gcmSource = gatewayS5GcmBinary()
            let wrapperSource = gcmRoot.join("test").join("fixtures").join("gcm-s5-blocked-wrapper.mjs")
            var oldDependencies = None<GatewayS5DependencyProcess>
            var replacementDependencies = None<GatewayS5DependencyProcess>
            var oldProcess = None<SubProcess>
            var replacementProcess = None<SubProcess>
            var holdReleaser = None<Future<Bool>>
            var oldIdentity = None<GatewayServeIdentity>
            var replacementIdentity = None<GatewayServeIdentity>
            var oldGatewaySettled = false
            var oldGatewayGone = false
            var oldProxyGone = false
            var oldWrapperGone = false
            var oldGcmGone = false
            var oldDescendantGone = false
            var oldGatewayFinalSettled = false
            var oldGatewayFinalGone = false
            var oldProxyFinalGone = false
            var replacementGatewaySettled = false
            var oldBrokerGone = false
            var oldGroupGone = false
            var replacementBrokerGone = false
            var replacementGcmGone = false
            var replacementGroupGone = false
            var oldGatewayPid: Int64 = 0
            var oldProxyPid: Int64 = 0
            var oldBrokerPid: Int64 = 0
            var oldWrapperPid: Int64 = 0
            var oldGcmPid: Int64 = 0
            var oldDescendantPid: Int64 = 0
            var oldPgid: Int64 = 0
            var replacementGatewayPid: Int64 = 0
            var replacementBrokerPid: Int64 = 0
            var replacementGcmPid: Int64 = 0
            var replacementPgid: Int64 = 0
            var parentBrokerGeneration: Int64 = 0
            var parentBrokerPid: Int64 = 0
            var oldBusinessTruth = false
            var replacementBusinessTruth = false
            var parentBrokerDiagnosticTruth = false
            let output = ArrayList<String>()
            try {
                let parentSetupReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                @Expect(parentSetupReset.ok, true)
                if (!parentSetupReset.ok) { return }
                Directory.create(oldHome, recursive: true)
                Directory.create(replacementHome, recursive: true)
                @Expect(exists(metisBinary), true)
                @Expect(exists(gcmSource), true)
                @Expect(exists(wrapperSource), true)
                @Expect(exists(proxySource), true)
                let oldGcm = oldHome.join("gitcodemonitor")
                let oldWrapper = oldHome.join("gcm-s5-blocked-wrapper.mjs")
                let proxy = oldHome.join("metis-s5-broker-writer-failure-proxy.mjs")
                for ((source, destination) in [(gcmSource, oldGcm), (wrapperSource, oldWrapper), (proxySource, proxy)]) {
                    @Expect(executeWithOutput("/bin/cp", [source.toString(), destination.toString()])[0], 0)
                    @Expect(executeWithOutput("/bin/chmod", ["700", destination.toString()])[0], 0)
                }
                let oldGatewayPort = gatewayServeStopTemporaryPort()
                let oldWebhookPort = gatewayServeStopTemporaryPort()
                @Expect(oldGatewayPort > 0 && oldWebhookPort > 0 && oldGatewayPort != oldWebhookPort, true)
                let processorEntered = oldHome.join("processor.entered")
                let processorRelease = oldHome.join("processor.release")
                let wrapperReady = oldHome.join("wrapper.ready.json")
                let stopSeen = oldHome.join("wrapper.stop-seen")
                let proxyReady = oldHome.join("broker-proxy.ready.json")
                let proxyFail = oldHome.join("broker-proxy.fail")
                let writerClosed = oldHome.join("broker-proxy.writer-closed")
                let proxyCleanup = oldHome.join("broker-proxy.cleanup")
                let holdEntered = oldHome.join("broker-proxy.hold-entered")
                let holdRelease = oldHome.join("broker-proxy.hold-release")
                let holdReleased = oldHome.join("broker-proxy.hold-released")
                let parentBrokerDiagnosticPath = oldHome.join("parent-broker-diagnostic")
                let dispatchFencedMarker = oldHome.join("service-plugin.dispatch-fenced.json")
                let dispatchFencedNonce = "s5-n1-fence-${suffix}"
                let shutdownPhaseMarker = oldHome.join("gateway-shutdown-phase")
                let shutdownPhaseNonce = "s5-n1-shutdown-${suffix}"
                let oldLockPath = oldHome.join("gateway-serve.lock")
                let oldStopRequestPath = oldHome.join("gateway-serve.stop-request")
                let oldCompletionPath = oldHome.join("gateway-serve.stop-complete")

                setVariable("METIS_HOME", oldHome.toString())
                setVariable("METIS_CJPM_ROOT", project.toString())
                setVariable("METIS_STDIO_BROKER_NODE_COMMAND", proxy.toString())
                setVariable("METIS_S5_BROKER_PROXY_READY", proxyReady.toString())
                setVariable("METIS_S5_BROKER_PROXY_FAIL", proxyFail.toString())
                setVariable("METIS_S5_BROKER_PROXY_WRITER_CLOSED", writerClosed.toString())
                setVariable("METIS_S5_BROKER_PROXY_CLEANUP", proxyCleanup.toString())
                setVariable("METIS_S5_BROKER_PROXY_HOLD_ENTERED", holdEntered.toString())
                setVariable("METIS_S5_BROKER_PROXY_HOLD_RELEASE", holdRelease.toString())
                setVariable("METIS_S5_BROKER_PROXY_HOLD_RELEASED", holdReleased.toString())
                setVariable("METIS_TEST_SERVICE_PLUGIN_DISPATCH_FENCED_MARKER", dispatchFencedMarker.toString())
                setVariable("METIS_TEST_SERVICE_PLUGIN_DISPATCH_FENCED_SERVICE_ID", "gitcode-monitor")
                setVariable("METIS_TEST_SERVICE_PLUGIN_DISPATCH_FENCED_NONCE", dispatchFencedNonce)
                setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_MARKER", shutdownPhaseMarker.toString())
                setVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_NONCE", shutdownPhaseNonce)
                setVariable("METIS_S5_BROKER_PROXY_DROP_DELIVERY_ID", "")
                setVariable("METIS_S5_BROKER_PROXY_ADMISSION_SEEN", "")
                setVariable("METIS_S5_BROKER_PROXY_COMPLETION_DROPPED", "")
                setVariable("GCM_S5_READY_PATH", wrapperReady.toString())
                setVariable("GCM_S5_STOP_SEEN_PATH", stopSeen.toString())
                setVariable("GCM_S5_CHILD_DYLD_LIBRARY_PATH", getVariable("DYLD_LIBRARY_PATH").getOrDefault { "" })
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                oldDependencies = Some(gatewayS5StartDependencies(
                    oldHome,
                    dependencyScript,
                    processorEntered: Some(processorEntered),
                    processorRelease: Some(processorRelease)
                ))
                let oldDependencyPort = oldDependencies.getOrThrow().port
                @Expect(oldDependencyPort > 0, true)
                for (key in apiKeyAliases) { setVariable(key, "fake-s5-openai-key") }
                for (key in baseUrlAliases) { setVariable(key, "http://127.0.0.1:${oldDependencyPort}/v1") }
                let configured = gatewayS5ConfigureFormalGateway(
                    oldHome, oldGatewayPort, oldWebhookPort, oldDependencyPort, oldGcm
                )
                gatewayS5WriteBlockedGcmManifest(configured[2], oldWrapper, oldGcm)
                @Expect(loadServicePluginManifest(configured[2].toString()).ok, true)
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                @Expect(exists(oldLockPath), false)
                @Expect(exists(oldStopRequestPath), false)
                @Expect(exists(oldCompletionPath), false)
                let parentHeapBeforeOldLaunch = getVariable("cjHeapSize")
                let launchedOld = gatewayS5LaunchGateway(metisBinary)
                @Expect(gatewayS5HeapEnvironmentMatches(parentHeapBeforeOldLaunch), true)
                oldGatewayPid = launchedOld.pid
                oldProcess = Some(launchedOld)
                oldIdentity = gatewayServeStopCaptureOwnedIdentity(oldHome, oldGatewayPid, metisBinary, 5000)
                @Expect(oldIdentity.isSome(), true)
                if (oldIdentity.isNone()) { return }
                @Expect(gatewayServeStopWaitUntil(15000, { =>
                    exists(proxyReady) && exists(wrapperReady) && gatewayServeStopPortListening(oldGatewayPort) &&
                        gatewayServeStopPortListening(oldWebhookPort)
                }), true)
                oldBrokerPid = gatewayS5JsonInt(proxyReady, "brokerPid")
                @Expect(gatewayServeStopWaitUntil(5000, { =>
                    !gatewayS5JsonString(proxyReady, "gcmOwnerId").isEmpty() &&
                        gatewayS5JsonInt(proxyReady, "generation") > 0
                }), true)
                let oldServiceOwnerId = gatewayS5JsonString(proxyReady, "gcmOwnerId")
                let oldServiceGeneration = gatewayS5JsonInt(proxyReady, "generation")
                oldProxyPid = gatewayS5JsonInt(proxyReady, "wrapperPid")
                oldWrapperPid = gatewayS5JsonInt(wrapperReady, "wrapperPid")
                oldGcmPid = gatewayS5JsonInt(wrapperReady, "gcmPid")
                oldDescendantPid = gatewayS5JsonInt(wrapperReady, "descendantPid")
                oldPgid = gatewayS5JsonInt(wrapperReady, "pgid")
                @Expect(oldProxyPid > 1 && gatewayServeStopParentPid(oldProxyPid) == oldGatewayPid, true)
                @Expect(gatewayServeStopCommandContains(oldProxyPid, proxy.toString()), true)
                @Expect(oldBrokerPid > 1 && gatewayServeStopParentPid(oldBrokerPid) == oldProxyPid, true)
                @Expect(oldServiceOwnerId.isEmpty(), false)
                @Expect(oldServiceGeneration > 0, true)
                @Expect(gatewayServeStopCommandContains(oldBrokerPid, brokerScript.toString()), true)
                @Expect(oldWrapperPid > 1 && oldGcmPid > 1 && oldDescendantPid > 1 && oldPgid > 1, true)
                @Expect(gatewayServeStopProcessGroup(oldWrapperPid), oldPgid)
                @Expect(gatewayServeStopProcessGroup(oldGcmPid), oldPgid)
                @Expect(gatewayServeStopProcessGroup(oldDescendantPid), oldPgid)
                let oldOwnerProof = GatewayServeStopLiveOwnerProof()
                let oldReadyz = "http://127.0.0.1:${oldGatewayPort}/readyz"
                @Expect(gatewayServeStopWaitUntil(15000, { =>
                    oldOwnerProof.refresh(oldReadyz)
                    oldOwnerProof.httpStatus == 200 && oldOwnerProof.running && oldOwnerProof.ownerCount >= 1
                }), true)
                let oldDelivery = "s5-n1-old"
                let oldWebhookStatus = gatewayS5PostWebhook(oldWebhookPort, oldDelivery)
                @Expect(oldWebhookStatus >= 200 && oldWebhookStatus < 300, true)
                @Expect(gatewayServeStopWaitUntil(10000, { => exists(processorEntered) }), true)
                File.writeTo(proxyFail, "fail\n".toArray())
                @Expect(gatewayServeStopWaitUntil(5000, { => exists(writerClosed) }), true)
                @Expect(gatewayServeStopWaitUntil(5000, { => exists(holdEntered) }), true)
                for ((key, value) in previousEnvironment) {
                    match (value) {
                        case Some(previous) => setVariable(key, previous)
                        case None => setVariable(key, "")
                    }
                }
                setVariable("METIS_STDIO_BROKER_NODE_COMMAND", "")
                Directory.create(parentBrokerDiagnosticPath, recursive: true)
                let freshParentBrokerDirectory = GatewayHeartbeatBrokerDirectoryProof(parentBrokerDiagnosticPath)
                @Expect(freshParentBrokerDirectory.status, "valid")
                @Expect(freshParentBrokerDirectory.identityCount, 0)
                @Expect(freshParentBrokerDirectory.slotCount, 0)
                @Expect(freshParentBrokerDirectory.tempCount, 0)
                @Expect(freshParentBrokerDirectory.overflow, false)
                if (freshParentBrokerDirectory.status != "valid" ||
                    freshParentBrokerDirectory.identityCount != 0 || freshParentBrokerDirectory.slotCount != 0 ||
                    freshParentBrokerDirectory.tempCount != 0 || freshParentBrokerDirectory.overflow) {
                    return
                }
                setVariable("METIS_STDIO_BROKER_TEST_MODE", "1")
                setVariable("METIS_STDIO_BROKER_DIAGNOSTIC_MARKER", parentBrokerDiagnosticPath.toString())
                let parentBrokerReady = gatewayStdioBrokerReady(timeoutMs: 5000)
                @Expect(parentBrokerReady.ok, true)
                @Expect(parentBrokerReady.status, "ready")
                @Expect(parentBrokerReady.generation > 0, true)
                @Expect(parentBrokerReady.pid > 0, true)
                let parentBrokerBeforeStop = managedStdioBroker().snapshot()
                parentBrokerGeneration = parentBrokerBeforeStop.generation
                parentBrokerPid = parentBrokerBeforeStop.brokerPid
                @Expect(parentBrokerBeforeStop.running, true)
                @Expect(parentBrokerBeforeStop.responsive, true)
                @Expect(parentBrokerBeforeStop.status, "ready")
                @Expect(parentBrokerBeforeStop.generation, parentBrokerReady.generation)
                @Expect(parentBrokerBeforeStop.brokerPid, parentBrokerReady.pid)
                @Expect(parentBrokerBeforeStop.ownerCount, 0)
                let stableParentBrokerGeneration = parentBrokerBeforeStop.generation
                let stableParentBrokerPid = parentBrokerBeforeStop.brokerPid
                let parentBrokerMarkerReady = gatewayServeStopWaitUntil(5000, { =>
                    let directory = GatewayHeartbeatBrokerDirectoryProof(parentBrokerDiagnosticPath)
                    let marker = gatewayHeartbeatBrokerDiagnosticForPid(
                        parentBrokerDiagnosticPath,
                        stableParentBrokerPid
                    )
                    directory.status == "valid" && directory.identityCount == 1 && directory.slotCount == 1 &&
                        directory.tempCount == 0 && !directory.overflow && match (marker) {
                            case Some(value) => value.valid && value.filenameMatches && value.firstEventBrokerStarted &&
                                value.generation == stableParentBrokerGeneration && value.brokerPid == stableParentBrokerPid
                            case None => false
                        }
                })
                @Expect(parentBrokerMarkerReady, true)
                if (!parentBrokerReady.ok || parentBrokerReady.status != "ready" ||
                    parentBrokerReady.generation <= 0 || parentBrokerReady.pid <= 0 ||
                    !parentBrokerBeforeStop.running || !parentBrokerBeforeStop.responsive ||
                    parentBrokerBeforeStop.status != "ready" || parentBrokerBeforeStop.ownerCount != 0 ||
                    !parentBrokerMarkerReady) {
                    return
                }
                setGatewayStopOutputForTest(Some({ line => output.add(line) }))
                let expectedOldIdentity = oldIdentity.getOrThrow()
                let expectedStopRequestPath = oldStopRequestPath
                let expectedHoldRelease = holdRelease
                let expectedHoldReleased = holdReleased
                let expectedProcessorRelease = processorRelease
                let expectedFencedMarker = dispatchFencedMarker
                let expectedFencedNonce = dispatchFencedNonce
                let expectedServiceOwnerId = oldServiceOwnerId
                let expectedServiceGeneration = oldServiceGeneration
                holdReleaser = Some(spawn {
                    let requestReady = gatewayServeStopWaitUntil(15000, { =>
                        try {
                            gatewayParseServeStopRequestIdentity(
                                String.fromUtf8(File.readFrom(expectedStopRequestPath))
                            ).getOrThrow().matches(expectedOldIdentity)
                        } catch (_: Exception) {
                            false
                        }
                    })
                    if (!requestReady) { return false }
                    let fencedReady = gatewayServeStopWaitUntil(15000, { =>
                        try {
                            let marker = JsonValue.fromStr(
                                String.fromUtf8(File.readFrom(expectedFencedMarker))
                            ).asObject()
                            marker.get("schema").getOrThrow().asString().getValue() ==
                                "metis.servicePlugin.dispatchFenced.v1" &&
                                marker.get("serviceId").getOrThrow().asString().getValue() == "gitcode-monitor" &&
                                marker.get("ownerId").getOrThrow().asString().getValue() == expectedServiceOwnerId &&
                                marker.get("generation").getOrThrow().asInt().getValue() == expectedServiceGeneration &&
                                marker.get("testNonce").getOrThrow().asString().getValue() == expectedFencedNonce &&
                                marker.get("fenced").getOrThrow().asBool().getValue()
                        } catch (_: Exception) {
                            false
                        }
                    })
                    if (!fencedReady) { return false }
                    try { File.writeTo(expectedProcessorRelease, "release\n".toArray()) } catch (_: Exception) { return false }
                    try { File.writeTo(expectedHoldRelease, "release\n".toArray()) } catch (_: Exception) { return false }
                    gatewayServeStopWaitUntil(5000, { => exists(expectedHoldReleased) })
                })
                let stopStarted = MonoTime.now()
                let oldStopExit = gatewayExecuteStopServe()
                let stopElapsedMs = (MonoTime.now() - stopStarted).toMilliseconds()
                let holdReleasedOk = try {
                    holdReleaser.getOrThrow().get(Duration.second * 25)
                } catch (_: Exception) {
                    false
                }
                holdReleaser = None<Future<Bool>>
                let oldOutput = String.join(output.toArray(), delimiter: "\n")
                @Expect(oldStopExit, 1)
                @Expect(holdReleasedOk, true)
                @Expect(exists(holdReleased), true)
                @Expect(stopElapsedMs < 55000, true)
                let parentBrokerAfterStop = managedStdioBroker().snapshot()
                @Expect(parentBrokerAfterStop.running, true)
                @Expect(parentBrokerAfterStop.responsive, true)
                @Expect(parentBrokerAfterStop.status, "ready")
                @Expect(parentBrokerAfterStop.generation, parentBrokerBeforeStop.generation)
                @Expect(parentBrokerAfterStop.brokerPid, parentBrokerBeforeStop.brokerPid)
                @Expect(parentBrokerAfterStop.ownerCount, 0)
                @Expect(oldOutput.contains("子进程清理未完成"), true)
                @Expect(oldOutput.contains("\"ok\""), false)
                let oldLogPath = oldHome.join("s5-gateway.log")
                @Expect(exists(oldLogPath), true)
                let oldLog = try { String.fromUtf8(File.readFrom(oldLogPath)) } catch (_: Exception) { "" }
                @Expect(oldLog.isEmpty(), false)
                for ((label, sensitive) in [
                    ("home", oldHome.toString()), ("queue", configured[1].toString()),
                    ("manifest", configured[2].toString()), ("config", configured[3].toString()),
                    ("proxy", proxy.toString()), ("openai_key", "fake-s5-openai-key"),
                    ("gitcode_token", "fake-s5-gitcode-token"), ("webhook_token", "fake-s5-webhook-token"),
                    ("telegram_token", "123456:FAKE-S5"), ("object_kind", "object_kind"),
                    ("repository", "cangjie/compiler"), ("payload_text", "S5 正式链路 中文🙂")
                ]) {
                    @Expect(if (oldOutput.contains(sensitive)) { "output_leak:${label}" } else { "output_clean:${label}" }, "output_clean:${label}")
                    @Expect(if (oldLog.contains(sensitive)) { "log_leak:${label}" } else { "log_clean:${label}" }, "log_clean:${label}")
                }
                @Expect(oldIdentity.isSome(), true)
                if (oldIdentity.isNone()) { return }
                @Expect(exists(writerClosed), true)
                @Expect(exists(stopSeen), false)
                @Expect(exists(dispatchFencedMarker), true)
                @Expect(gatewayS5EventCount(oldDependencies.getOrThrow().eventsPath, "model_response", oldDelivery), 0)
                @Expect(gatewayS5EventCount(oldDependencies.getOrThrow().eventsPath, "gitcode_writeback", oldDelivery), 0)
                @Expect(gatewayS5EventCount(oldDependencies.getOrThrow().eventsPath, "telegram_send", oldDelivery), 0)
                @Expect(gatewayS5EventCount(oldDependencies.getOrThrow().eventsPath, "feishu_send", oldDelivery), 0)
                let stableOldBrokerPid = oldBrokerPid
                let stableOldGatewayPid = oldGatewayPid
                let stableOldProxyPid = oldProxyPid
                let stableOldPgid = oldPgid
                oldGatewaySettled = gatewayServeStopReapCompletedOwnedProcess(oldProcess)
                @Expect(oldGatewaySettled, true)
                if (oldGatewaySettled) { oldProcess = None<SubProcess> }
                oldGatewayGone = gatewayServeStopWaitUntil(5000, { => !gatewayServeStopPidAlive(stableOldGatewayPid) })
                oldProxyGone = gatewayServeStopWaitUntil(5000, { => !gatewayServeStopPidAlive(stableOldProxyPid) })
                oldBrokerGone = gatewayServeStopWaitUntil(10000, { => !gatewayServeStopPidAlive(stableOldBrokerPid) })
                let stableOldWrapperPid = oldWrapperPid
                let stableOldGcmPid = oldGcmPid
                let stableOldDescendantPid = oldDescendantPid
                oldWrapperGone = gatewayServeStopWaitUntil(10000, { => !gatewayServeStopPidAlive(stableOldWrapperPid) })
                oldGcmGone = gatewayServeStopWaitUntil(10000, { => !gatewayServeStopPidAlive(stableOldGcmPid) })
                oldDescendantGone = gatewayServeStopWaitUntil(10000, { => !gatewayServeStopPidAlive(stableOldDescendantPid) })
                oldGroupGone = gatewayServeStopWaitUntil(10000, { => gatewayServeStopGroupGone(stableOldPgid) })
                @Expect(oldGatewayGone, true)
                @Expect(oldProxyGone, true)
                @Expect(oldBrokerGone, true)
                @Expect(oldWrapperGone, true)
                @Expect(oldGcmGone, true)
                @Expect(oldDescendantGone, true)
                @Expect(oldGroupGone, true)
                @Expect(gatewayServeStopPortListening(oldGatewayPort), false)
                @Expect(gatewayServeStopPortListening(oldWebhookPort), false)
                @Expect(gatewayServeStopRuntimeOwnerCount(oldHome.join("gateway-runtime-state.json")), 0)
                var firstPhaseObservedMs: Int64 = -1
                var previousPhaseObservedMs: Int64 = -1
                var httpCloseReturnedObservedMs: Int64 = -1
                var httpProbeDoneObservedMs: Int64 = -1
                for ((sequence, phase) in [
                    (Int64(1), "stop_request_observed"),
                    (Int64(2), "canvas_done"),
                    (Int64(3), "http_close_enter"),
                    (Int64(4), "http_close_returned"),
                    (Int64(5), "http_probe_done"),
                    (Int64(6), "gateway_stop_enter"),
                    (Int64(7), "owners_enter"),
                    (Int64(8), "owners_done"),
                    (Int64(9), "channels_enter"),
                    (Int64(10), "channels_done"),
                    (Int64(11), "broker_enter"),
                    (Int64(12), "broker_done"),
                    (Int64(13), "gateway_stop_returned"),
                    (Int64(14), "completion_written")
                ]) {
                    let phasePath = Path("${shutdownPhaseMarker.toString()}.${sequence}.json")
                    let phaseProof = try {
                        let phaseValue = JsonValue.fromStr(String.fromUtf8(File.readFrom(phasePath))).asObject()
                        (phaseValue.get("schema").getOrThrow().asString().getValue() ==
                            "metis.gateway.shutdownPhase.v1" &&
                            phaseValue.get("phase").getOrThrow().asString().getValue() == phase &&
                            phaseValue.get("sequence").getOrThrow().asInt().getValue() == sequence &&
                            phaseValue.get("pid").getOrThrow().asInt().getValue() == expectedOldIdentity.pid &&
                            phaseValue.get("startedAtMs").getOrThrow().asInt().getValue() ==
                                expectedOldIdentity.startedAtMs &&
                            phaseValue.get("nonce").getOrThrow().asString().getValue() == expectedOldIdentity.nonce &&
                            phaseValue.get("processIdentity").getOrThrow().asString().getValue() ==
                                expectedOldIdentity.processIdentity.getOrThrow().serialize() &&
                            phaseValue.get("testNonce").getOrThrow().asString().getValue() == shutdownPhaseNonce,
                            phaseValue.get("observedMonotonicMs").getOrThrow().asInt().getValue())
                    } catch (_: Exception) {
                        (false, Int64(-1))
                    }
                    @Expect(phaseProof[0], true)
                    @Expect(phaseProof[1] >= 0, true)
                    if (sequence == 1) { firstPhaseObservedMs = phaseProof[1] }
                    if (sequence == 4) { httpCloseReturnedObservedMs = phaseProof[1] }
                    if (sequence == 5) { httpProbeDoneObservedMs = phaseProof[1] }
                    if (previousPhaseObservedMs >= 0) { @Expect(phaseProof[1] >= previousPhaseObservedMs, true) }
                    let relativeElapsedMs = if (firstPhaseObservedMs >= 0 && phaseProof[1] >= firstPhaseObservedMs) {
                        phaseProof[1] - firstPhaseObservedMs
                    } else {
                        Int64(-1)
                    }
                    println("HB-BR-SHUTDOWN phase=${phase} elapsedMs=${relativeElapsedMs}")
                    previousPhaseObservedMs = phaseProof[1]
                    let phaseMode = executeWithOutput("/usr/bin/stat", ["-f", "%Lp", phasePath.toString()])
                    @Expect(phaseMode[0], 0)
                    let phaseModeText = try { String.fromUtf8(phaseMode[1]).trimAscii() } catch (_: Exception) { "" }
                    @Expect(phaseModeText, "600")
                }
                let httpProbeElapsedMs = if (httpCloseReturnedObservedMs >= 0 &&
                    httpProbeDoneObservedMs >= httpCloseReturnedObservedMs) {
                    httpProbeDoneObservedMs - httpCloseReturnedObservedMs
                } else {
                    Int64(-1)
                }
                @Expect(httpProbeElapsedMs >= 0, true)
                @Expect(httpProbeElapsedMs <= 3000, true)
                let oldCompletionExists = exists(oldCompletionPath)
                @Expect(oldCompletionExists, true)
                if (!oldCompletionExists) { return }
                let oldCompletion = try {
                    String.fromUtf8(File.readFrom(oldCompletionPath))
                } catch (_: Exception) {
                    ""
                }
                @Expect(gatewayParseServeIdentity(oldCompletion).getOrThrow().matches(oldIdentity.getOrThrow()), true)
                @Expect(gatewayServeStopCompletionField(oldCompletion, "status"), "cleanup_pending")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "fullTerminal"), "0")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "servicePluginDispatchStatus"), "cleanup_pending")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "servicePluginOwnerStatus"), "cleanup_pending")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "servicePluginLeaseStatus"), "cleanup_pending")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "servicePluginPendingCount"), "1")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "channelsStatus"), "stopped")
                @Expect(gatewayServeStopCompletionField(oldCompletion, "brokerStatus"), "broker_close_write_failed")
                let historical = gatewayHistoricalServeCompletionRecoveryStatus()
                @Expect(historical.ok, false)
                @Expect(historical.status, "resources_not_terminal")
                @Expect(gatewayPendingServeCompletionStatus(), "cleanup_pending")
                @Expect(exists(oldLockPath), false)
                @Expect(exists(oldStopRequestPath), false)
                oldBusinessTruth = true

                setGatewayStopOutputForTest(None<(String) -> Unit>)
                output.clear()
                setVariable("METIS_STDIO_BROKER_NODE_COMMAND", "")
                for (key in ["METIS_S5_BROKER_PROXY_READY", "METIS_S5_BROKER_PROXY_FAIL",
                    "METIS_S5_BROKER_PROXY_WRITER_CLOSED", "METIS_S5_BROKER_PROXY_CLEANUP",
                    "METIS_S5_BROKER_PROXY_DROP_DELIVERY_ID", "METIS_S5_BROKER_PROXY_ADMISSION_SEEN",
                    "METIS_S5_BROKER_PROXY_COMPLETION_DROPPED", "METIS_S5_BROKER_PROXY_HOLD_ENTERED",
                    "METIS_S5_BROKER_PROXY_HOLD_RELEASE", "METIS_S5_BROKER_PROXY_HOLD_RELEASED",
                    "METIS_STDIO_BROKER_TEST_MODE", "METIS_STDIO_BROKER_DIAGNOSTIC_MARKER",
                    "METIS_TEST_SERVICE_PLUGIN_DISPATCH_FENCED_MARKER",
                    "METIS_TEST_SERVICE_PLUGIN_DISPATCH_FENCED_SERVICE_ID",
                    "METIS_TEST_SERVICE_PLUGIN_DISPATCH_FENCED_NONCE",
                    "METIS_TEST_GATEWAY_SHUTDOWN_PHASE_MARKER", "METIS_TEST_GATEWAY_SHUTDOWN_PHASE_NONCE",
                    "GCM_S5_READY_PATH", "GCM_S5_STOP_SEEN_PATH", "GCM_S5_CHILD_DYLD_LIBRARY_PATH"]) {
                    setVariable(key, "")
                }
                let replacementGcm = replacementHome.join("gitcodemonitor")
                @Expect(executeWithOutput("/bin/cp", [gcmSource.toString(), replacementGcm.toString()])[0], 0)
                @Expect(executeWithOutput("/bin/chmod", ["700", replacementGcm.toString()])[0], 0)
                let replacementGatewayPort = gatewayServeStopTemporaryPort()
                let replacementWebhookPort = gatewayServeStopTemporaryPort()
                setVariable("METIS_HOME", replacementHome.toString())
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                replacementDependencies = Some(gatewayS5StartDependencies(
                    replacementHome, dependencyScript, replyMarker: "s5-n1-replacement"
                ))
                let replacementDependencyPort = replacementDependencies.getOrThrow().port
                for (key in apiKeyAliases) { setVariable(key, "fake-s5-openai-key") }
                for (key in baseUrlAliases) { setVariable(key, "http://127.0.0.1:${replacementDependencyPort}/v1") }
                let replacementConfigured = gatewayS5ConfigureFormalGateway(
                    replacementHome, replacementGatewayPort, replacementWebhookPort,
                    replacementDependencyPort, replacementGcm
                )
                let parentHeapBeforeReplacementLaunch = getVariable("cjHeapSize")
                let launchedReplacement = gatewayS5LaunchGateway(metisBinary)
                @Expect(gatewayS5HeapEnvironmentMatches(parentHeapBeforeReplacementLaunch), true)
                replacementGatewayPid = launchedReplacement.pid
                replacementProcess = Some(launchedReplacement)
                replacementIdentity = gatewayServeStopCaptureOwnedIdentity(
                    replacementHome, replacementGatewayPid, metisBinary, 5000
                )
                @Expect(replacementIdentity.isSome(), true)
                let replacementCapture = GatewayS5P1Capture()
                let replacementOwnerProof = GatewayServeStopLiveOwnerProof()
                let replacementReadyz = "http://127.0.0.1:${replacementGatewayPort}/readyz"
                let stableReplacementGatewayPid = replacementGatewayPid
                @Expect(gatewayServeStopWaitUntil(15000, { =>
                    replacementCapture.brokerPid = gatewayServeStopChildPid(stableReplacementGatewayPid, brokerScript.toString())
                    replacementCapture.gcmPid = gatewayServeStopChildPid(replacementCapture.brokerPid, replacementGcm.toString())
                    replacementCapture.gcmPgid = gatewayServeStopProcessGroup(replacementCapture.gcmPid)
                    replacementOwnerProof.refresh(replacementReadyz)
                    replacementCapture.brokerPid > 1 && replacementCapture.gcmPid > 1 &&
                        replacementCapture.gcmPgid > 1 && gatewayServeStopPortListening(replacementGatewayPort) &&
                        gatewayServeStopPortListening(replacementWebhookPort) && replacementOwnerProof.httpStatus == 200 &&
                        replacementOwnerProof.running && replacementOwnerProof.ownerCount >= 1
                }), true)
                replacementBrokerPid = replacementCapture.brokerPid
                replacementGcmPid = replacementCapture.gcmPid
                replacementPgid = replacementCapture.gcmPgid
                @Expect(replacementBrokerPid != oldBrokerPid, true)
                @Expect(replacementGcmPid != oldGcmPid, true)
                @Expect(gatewayS5FileContains(replacementConfigured[0], oldDelivery), false)
                let replacementDelivery = "s5-n1-replacement"
                let replacementProcessedPath = replacementConfigured[1].join("processed")
                    .join("${replacementDelivery}.json")
                let replacementEventsPath = replacementDependencies.getOrThrow().eventsPath
                let replacementWebhookStatus = gatewayS5PostWebhook(replacementWebhookPort, replacementDelivery)
                @Expect(replacementWebhookStatus >= 200 && replacementWebhookStatus < 300, true)
                @Expect(gatewayServeStopWaitUntil(15000, { =>
                    gatewayS5FileContains(
                        replacementProcessedPath,
                        replacementDelivery
                    ) && gatewayS5EventCount(replacementEventsPath, "model_response") == 1 &&
                        gatewayS5EventCount(replacementEventsPath, "telegram_send", replacementDelivery) == 1
                }), true)
                @Expect(gatewayS5FileContains(replacementConfigured[0], oldDelivery), false)
                @Expect(gatewayS5EventCount(replacementDependencies.getOrThrow().eventsPath, "telegram_send", oldDelivery), 0)
                @Expect(gatewayS5EventCount(replacementDependencies.getOrThrow().eventsPath, "model_response"), 1)
                @Expect(gatewayS5EventCount(
                    replacementDependencies.getOrThrow().eventsPath, "telegram_send", replacementDelivery
                ), 1)
                @Expect(gatewayS5FileContains(
                    replacementDependencies.getOrThrow().eventsPath,
                    "S5 本地模型回复 中文🙂 ${replacementDelivery}"
                ), true)
                @Expect(gatewayS5FileContains(replacementDependencies.getOrThrow().eventsPath, "_answer_"), false)
                @Expect(gatewayS5FileContains(replacementDependencies.getOrThrow().eventsPath, "<answer>"), false)
                @Expect(gatewayS5FileContains(replacementDependencies.getOrThrow().eventsPath, "taskKind"), false)
                @Expect(gatewayS5FileContains(replacementDependencies.getOrThrow().eventsPath, "replyBody"), false)
                setGatewayStopOutputForTest(Some({ line => output.add(line) }))
                let replacementExit = gatewayExecuteStopServe()
                @Expect(replacementExit, 0)
                @Expect(String.join(output.toArray(), delimiter: "\n").contains("已正常停止"), true)
                let replacementCompletionPath = replacementHome.join("gateway-serve.stop-complete")
                let replacementCompletion = try {
                    String.fromUtf8(File.readFrom(replacementCompletionPath))
                } catch (_: Exception) {
                    ""
                }
                @Expect(gatewayServeStopCompletionField(replacementCompletion, "status"), "graceful")
                @Expect(gatewayServeStopCompletionField(replacementCompletion, "fullTerminal"), "1")
                replacementBusinessTruth = true
            } finally {
                setGatewayStopOutputForTest(None<(String) -> Unit>)
                try { File.writeTo(oldHome.join("processor.release"), "release\n".toArray()) } catch (_: Exception) { () }
                try { File.writeTo(oldHome.join("broker-proxy.hold-release"), "release\n".toArray()) } catch (_: Exception) { () }
                match (holdReleaser) {
                    case Some(value) => try { let _ = value.get(Duration.second * 35) } catch (_: Exception) { () }
                    case None => ()
                }
                holdReleaser = None<Future<Bool>>
                if (!exists(oldHome.join("processor.release"))) {
                    try { File.writeTo(oldHome.join("processor.release"), "release\n".toArray()) } catch (_: Exception) { () }
                }
                if (!exists(oldHome.join("broker-proxy.cleanup"))) {
                    try { File.writeTo(oldHome.join("broker-proxy.cleanup"), "cleanup\n".toArray()) } catch (_: Exception) { () }
                }
                if (replacementIdentity.isSome()) {
                    try { gatewayServeStopReapOwnedGateway(replacementIdentity, metisBinary, replacementHome) } catch (_: Exception) { () }
                }
                try { gatewayServeStopReapOwnedHandle(replacementProcess, metisBinary) } catch (_: Exception) { () }
                replacementGatewaySettled = try { gatewayServeStopWaitOwnedProcess(replacementProcess) } catch (_: Exception) { false }
                if (oldIdentity.isSome()) {
                    try { gatewayServeStopReapOwnedGateway(oldIdentity, metisBinary, oldHome) } catch (_: Exception) { () }
                }
                try { gatewayServeStopReapOwnedHandle(oldProcess, metisBinary) } catch (_: Exception) { () }
                oldGatewayFinalSettled = if (oldGatewaySettled) {
                    true
                } else {
                    try { gatewayServeStopWaitOwnedProcess(oldProcess) } catch (_: Exception) { false }
                }
                let stableReplacementBrokerPid = replacementBrokerPid
                let stableReplacementGcmPid = replacementGcmPid
                let stableReplacementPgid = replacementPgid
                let stableOldGatewayPid = oldGatewayPid
                let stableOldProxyPid = oldProxyPid
                oldGatewayFinalGone = oldGatewayPid > 1 && gatewayServeStopWaitUntil(5000, { =>
                    !gatewayServeStopPidAlive(stableOldGatewayPid)
                })
                oldProxyFinalGone = oldProxyPid > 1 && gatewayServeStopWaitUntil(5000, { =>
                    !gatewayServeStopPidAlive(stableOldProxyPid)
                })
                replacementBrokerGone = replacementBrokerPid > 1 && gatewayServeStopWaitUntil(5000, { =>
                    !gatewayServeStopPidAlive(stableReplacementBrokerPid)
                })
                replacementGcmGone = replacementGcmPid > 1 && gatewayServeStopWaitUntil(5000, { =>
                    !gatewayServeStopPidAlive(stableReplacementGcmPid)
                })
                replacementGroupGone = replacementPgid > 1 && gatewayServeStopWaitUntil(5000, { =>
                    gatewayServeStopGroupGone(stableReplacementPgid)
                })
                let oldDependenciesSettled = gatewayS5StopDependencies(oldDependencies)
                let replacementDependenciesSettled = gatewayS5StopDependencies(replacementDependencies)
                let parentFinalReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                let parentFinalBroker = managedStdioBroker().snapshot()
                let parentBrokerDirectory = GatewayHeartbeatBrokerDirectoryProof(
                    oldHome.join("parent-broker-diagnostic")
                )
                let parentBrokerDiagnostics = gatewayHeartbeatBrokerDiagnostics(
                    oldHome.join("parent-broker-diagnostic")
                )
                @Expect(parentFinalReset.status, "stopped")
                @Expect(parentBrokerDirectory.status, "valid")
                @Expect(parentBrokerDirectory.identityCount, 1)
                @Expect(parentBrokerDirectory.slotCount, 1)
                @Expect(parentBrokerDirectory.tempCount, 0)
                @Expect(parentBrokerDirectory.overflow, false)
                @Expect(parentBrokerDiagnostics.size, 1)
                if (parentBrokerDirectory.status == "valid" && parentBrokerDirectory.identityCount == 1 &&
                    parentBrokerDirectory.slotCount == 1 && parentBrokerDirectory.tempCount == 0 &&
                    parentBrokerDiagnostics.size == 1) {
                    let diagnostic = parentBrokerDiagnostics[0]
                    let parentTestPid = Int64(getProcessId())
                    println("HB-BR-PARENT ${diagnostic.safeSummary("parent", parentTestPid)}")
                    @Expect(diagnostic.valid, true)
                    @Expect(diagnostic.parseStatus, "schema_valid")
                    @Expect(diagnostic.filenameMatches, true)
                    @Expect(diagnostic.firstEventBrokerStarted, true)
                    @Expect(diagnostic.parentStatus(parentTestPid), "original_parent")
                    @Expect(diagnostic.closeEntryCount, 1)
                    @Expect(diagnostic.closeEntryOwnerCount, 0)
                    @Expect(diagnostic.brokerClosedEnqueuedCount, 1)
                    @Expect(diagnostic.brokerClosedCallbackCount, 1)
                    @Expect(diagnostic.closeAckCallbackSeen, true)
                    @Expect(diagnostic.classifiedOwnerTerminalCount, diagnostic.ownerTerminalCount)
                    @Expect(diagnostic.ownerCount, 0)
                    @Expect(diagnostic.generation, parentBrokerGeneration)
                    @Expect(diagnostic.brokerPid, parentBrokerPid)
                    @Expect(diagnostic.writerFailureKind, "")
                    @Expect(diagnostic.writerFailurePhase, "")
                    @Expect(diagnostic.exitScheduledCount, 1)
                    @Expect(diagnostic.lastExitScheduledCode, 0)
                    parentBrokerDiagnosticTruth = diagnostic.valid && diagnostic.filenameMatches &&
                        diagnostic.parentStatus(parentTestPid) == "original_parent" &&
                        diagnostic.closeEntryCount == 1 && diagnostic.closeEntryOwnerCount == 0 &&
                        diagnostic.brokerClosedEnqueuedCount == 1 && diagnostic.brokerClosedCallbackCount == 1 &&
                        diagnostic.closeAckCallbackSeen &&
                        diagnostic.classifiedOwnerTerminalCount == diagnostic.ownerTerminalCount &&
                        diagnostic.ownerCount == 0 && diagnostic.exitScheduledCount == 1 &&
                        diagnostic.lastExitScheduledCode == 0 && diagnostic.generation == parentBrokerGeneration &&
                        diagnostic.brokerPid == parentBrokerPid && diagnostic.writerFailureKind.isEmpty() &&
                        diagnostic.writerFailurePhase.isEmpty()
                }
                for ((key, value) in previousEnvironment) {
                    match (value) {
                        case Some(previous) => setVariable(key, previous)
                        case None => setVariable(key, "")
                    }
                }
                for ((key, value) in providerEnvironment) {
                    match (value) {
                        case Some(previous) => setVariable(key, previous)
                        case None => setVariable(key, "")
                    }
                }
                match (previousHome) {
                    case Some(value) => setVariable("METIS_HOME", value)
                    case None => setVariable("METIS_HOME", "")
                }
                match (previousRoot) {
                    case Some(value) => setVariable("METIS_CJPM_ROOT", value)
                    case None => setVariable("METIS_CJPM_ROOT", "")
                }
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                try { remove(oldHome, recursive: true) } catch (_: Exception) { () }
                try { remove(replacementHome, recursive: true) } catch (_: Exception) { () }
                @Expect(oldBusinessTruth, true)
                @Expect(replacementBusinessTruth, true)
                @Expect(oldGatewaySettled, true)
                @Expect(oldGatewayGone, true)
                @Expect(oldProxyGone, true)
                @Expect(oldWrapperGone, true)
                @Expect(oldGcmGone, true)
                @Expect(oldDescendantGone, true)
                @Expect(oldGatewayFinalSettled, true)
                @Expect(oldGatewayFinalGone, true)
                @Expect(oldProxyFinalGone, true)
                @Expect(replacementGatewaySettled, true)
                @Expect(oldBrokerGone, true)
                @Expect(oldGroupGone, true)
                @Expect(replacementBrokerGone, true)
                @Expect(replacementGcmGone, true)
                @Expect(replacementGroupGone, true)
                @Expect(oldDependenciesSettled, true)
                @Expect(replacementDependenciesSettled, true)
                @Expect(parentFinalReset.ok, true)
                @Expect(parentFinalBroker.running, false)
                @Expect(parentBrokerDiagnosticTruth, true)
                @Expect(parentFinalBroker.brokerPid, 0)
                @Expect(parentFinalBroker.ownerCount, 0)
                @Expect(parentFinalBroker.readerCount, 0)
                @Expect(parentFinalBroker.dispatcherCount, 0)
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
            let binaryValue = gatewayFormalMetisBinary(project)
            @Expect(binaryValue.isSome(), true)
            if (binaryValue.isNone()) { return }
            let binary = binaryValue.getOrThrow()
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
