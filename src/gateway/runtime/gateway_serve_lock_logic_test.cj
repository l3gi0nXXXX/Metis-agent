package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, GatewayServicePluginUserSettings, MetisConfigManager, MetisProcessEnvironmentLock, cliProviderApiKeyEnvAliases, cliProviderBaseUrlEnvAliases}
import metis.gateway.process.gatewayStdioBrokerSnapshot
import metis.gateway.service_plugin.loadServicePluginManifest
import metis.gateway.core.GatewayStopResult
import metis.process.{currentProcessInstanceIdentity, managedStdioResolveBrokerScriptPath, probeProcessInstance, processInstanceKillSignal, processInstanceTermSignal, resetManagedStdioBrokerForTest, signalProcessInstance}
import std.collection.{ArrayList, HashMap, HashSet}
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
            let metisBinary = project.join("target").join("release").join("bin").join("metis")
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

                let launched = launch(
                    metisBinary.toString(),
                    ["gateway", "run"],
                    stdIn: ProcessRedirect.Discard,
                    stdOut: ProcessRedirect.Discard,
                    stdErr: ProcessRedirect.Discard
                )
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
                        gatewayS5FileContains(statePath, eventId)
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
            let metisBinary = project.join("target").join("release").join("bin").join("metis")
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

                let launched = launch(
                    metisBinary.toString(),
                    ["gateway", "run"],
                    stdIn: ProcessRedirect.Discard,
                    stdOut: ProcessRedirect.Discard,
                    stdErr: ProcessRedirect.Discard
                )
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
            let metisBinary = project.join("target").join("release").join("bin").join("metis")
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

                let launchedOld = launch(
                    metisBinary.toString(), ["gateway", "run"],
                    stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Discard, stdErr: ProcessRedirect.Discard
                )
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
                let launchedReplacement = launch(
                    metisBinary.toString(), ["gateway", "run"],
                    stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Discard, stdErr: ProcessRedirect.Discard
                )
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
                "METIS_S5_BROKER_PROXY_ADMISSION_SEEN", "METIS_S5_BROKER_PROXY_COMPLETION_DROPPED", "GCM_S5_READY_PATH",
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
            let metisBinary = project.join("target").join("release").join("bin").join("metis")
            let dependencyScript = brokerScript.parent.join("metis-s5-loopback-dependencies.mjs")
            let proxySource = brokerScript.parent.join("metis-s5-broker-writer-failure-proxy.mjs")
            let gcmRoot = gatewayS5GcmRoot()
            let gcmSource = gatewayS5GcmBinary()
            let wrapperSource = gcmRoot.join("test").join("fixtures").join("gcm-s5-blocked-wrapper.mjs")
            var oldDependencies = None<GatewayS5DependencyProcess>
            var replacementDependencies = None<GatewayS5DependencyProcess>
            var oldProcess = None<SubProcess>
            var replacementProcess = None<SubProcess>
            var oldIdentity = None<GatewayServeIdentity>
            var replacementIdentity = None<GatewayServeIdentity>
            var oldGatewaySettled = false
            var oldGatewayGone = false
            var oldProxyGone = false
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
            var oldBusinessTruth = false
            var replacementBusinessTruth = false
            let output = ArrayList<String>()
            try {
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

                setVariable("METIS_HOME", oldHome.toString())
                setVariable("METIS_CJPM_ROOT", project.toString())
                setVariable("METIS_STDIO_BROKER_NODE_COMMAND", proxy.toString())
                setVariable("METIS_S5_BROKER_PROXY_READY", proxyReady.toString())
                setVariable("METIS_S5_BROKER_PROXY_FAIL", proxyFail.toString())
                setVariable("METIS_S5_BROKER_PROXY_WRITER_CLOSED", writerClosed.toString())
                setVariable("METIS_S5_BROKER_PROXY_CLEANUP", proxyCleanup.toString())
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
                let launchedOld = launch(
                    metisBinary.toString(), ["gateway", "run"],
                    stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Discard, stdErr: ProcessRedirect.Discard
                )
                oldGatewayPid = launchedOld.pid
                oldProcess = Some(launchedOld)
                oldIdentity = gatewayServeStopCaptureOwnedIdentity(oldHome, oldGatewayPid, metisBinary, 5000)
                @Expect(oldIdentity.isSome(), true)
                @Expect(gatewayServeStopWaitUntil(15000, { =>
                    exists(proxyReady) && exists(wrapperReady) && gatewayServeStopPortListening(oldGatewayPort) &&
                        gatewayServeStopPortListening(oldWebhookPort)
                }), true)
                oldBrokerPid = gatewayS5JsonInt(proxyReady, "brokerPid")
                oldProxyPid = gatewayS5JsonInt(proxyReady, "wrapperPid")
                oldWrapperPid = gatewayS5JsonInt(wrapperReady, "wrapperPid")
                oldGcmPid = gatewayS5JsonInt(wrapperReady, "gcmPid")
                oldDescendantPid = gatewayS5JsonInt(wrapperReady, "descendantPid")
                oldPgid = gatewayS5JsonInt(wrapperReady, "pgid")
                @Expect(oldProxyPid > 1 && gatewayServeStopParentPid(oldProxyPid) == oldGatewayPid, true)
                @Expect(gatewayServeStopCommandContains(oldProxyPid, proxy.toString()), true)
                @Expect(oldBrokerPid > 1 && gatewayServeStopParentPid(oldBrokerPid) == oldProxyPid, true)
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
                for ((key, value) in previousEnvironment) {
                    match (value) {
                        case Some(previous) => setVariable(key, previous)
                        case None => setVariable(key, "")
                    }
                }
                setGatewayStopOutputForTest(Some({ line => output.add(line) }))
                let stopStarted = MonoTime.now()
                let oldStopExit = gatewayExecuteStopServe()
                let stopElapsedMs = (MonoTime.now() - stopStarted).toMilliseconds()
                let oldOutput = String.join(output.toArray(), delimiter: "\n")
                @Expect(oldStopExit, 1)
                @Expect(stopElapsedMs <= GATEWAY_SERVE_GRACEFUL_SHUTDOWN_TIMEOUT_MS + 5000, true)
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
                let oldCompletionPath = oldHome.join("gateway-serve.stop-complete")
                @Expect(exists(oldCompletionPath), false)
                @Expect(exists(writerClosed), true)
                @Expect(exists(stopSeen), false)
                @Expect(gatewayS5EventCount(oldDependencies.getOrThrow().eventsPath, "telegram_send", oldDelivery), 0)
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
                oldGroupGone = gatewayServeStopWaitUntil(10000, { => gatewayServeStopGroupGone(stableOldPgid) })
                @Expect(oldGatewayGone, true)
                @Expect(oldProxyGone, true)
                @Expect(oldBrokerGone, true)
                @Expect(oldGroupGone, true)
                @Expect(gatewayServeStopPortListening(oldGatewayPort), false)
                @Expect(gatewayServeStopPortListening(oldWebhookPort), false)
                @Expect(gatewayServeStopRuntimeOwnerCount(oldHome.join("gateway-runtime-state.json")), 0)
                oldBusinessTruth = true

                setGatewayStopOutputForTest(None<(String) -> Unit>)
                output.clear()
                setVariable("METIS_STDIO_BROKER_NODE_COMMAND", "")
                for (key in ["METIS_S5_BROKER_PROXY_READY", "METIS_S5_BROKER_PROXY_FAIL",
                    "METIS_S5_BROKER_PROXY_WRITER_CLOSED", "METIS_S5_BROKER_PROXY_CLEANUP",
                    "METIS_S5_BROKER_PROXY_DROP_DELIVERY_ID", "METIS_S5_BROKER_PROXY_ADMISSION_SEEN",
                    "METIS_S5_BROKER_PROXY_COMPLETION_DROPPED",
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
                let launchedReplacement = launch(
                    metisBinary.toString(), ["gateway", "run"],
                    stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Discard, stdErr: ProcessRedirect.Discard
                )
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
