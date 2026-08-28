package metis.gateway.service_plugin

import metis.process.{managedStdioBroker, managedStdioResolveBrokerScriptPath, resetManagedStdioBrokerForTest}
import metis.gateway.logging.gatewayLoggingResetForTest
import std.collection.{ArrayList, HashSet}
import std.convert.Parsable
import std.core.Duration
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.net.*
import std.process.{ProcessRedirect, SubProcess, executeWithOutput, launch}
import std.sync.*
import std.time.MonoTime
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue
import stdx.net.http.*

private class S5HttpResult {
    let status: Int64
    let body: String

    init(status: Int64, body: String) {
        this.status = status
        this.body = body
    }
}

private func s5TemporaryPort(): Int64 {
    for (_ in 0..8) {
        try (socket = TcpServerSocket(bindAt: 0u16)) {
            socket.bind()
            let value = Int64((socket.localAddress as IPSocketAddress)?.port ?? 0u16)
            if (value > 0 && value != 18080 && value != 18788 && value != 60271) { return value }
        }
    }
    0
}

private func s5CanBindPort(port: Int64): Bool {
    if (port <= 0) { return false }
    var bound = false
    try (socket = TcpServerSocket(bindAt: UInt16(port))) {
        socket.bind()
        bound = true
    } catch (_: Exception) {
        bound = false
    }
    bound
}

private func s5WaitUntil(timeoutMs: Int64, predicate: () -> Bool): Bool {
    let started = MonoTime.now()
    while ((MonoTime.now() - started).toMilliseconds() < timeoutMs) {
        if (predicate()) { return true }
        sleep(Duration.millisecond * 10)
    }
    predicate()
}

private func s5RemoveOwnedTempHome(path: Path): Bool {
    let text = path.toString()
    if (!text.startsWith("/tmp/metis-service-plugin-s5-") || text.contains("..")) { return false }
    for (_ in 0..20) {
        try { remove(path, recursive: true) } catch (_: Exception) { () }
        if (!exists(path)) { return true }
        sleep(Duration.millisecond * 20)
    }
    !exists(path)
}

private func s5ReadBody(response: HttpResponse): String {
    let bytes = ArrayList<Byte>()
    let buffer = Array<Byte>(1024, repeat: 0)
    while (bytes.size <= 64 * 1024) {
        let count = response.body.read(buffer)
        if (count <= 0) { break }
        bytes.add(all: buffer[..count])
    }
    if (bytes.size > 64 * 1024) { return "response_too_large" }
    try { String.fromUtf8(bytes.toArray()) } catch (_: Exception) { "invalid_response_encoding" }
}

private func s5Get(url: String): S5HttpResult {
    let builder = ClientBuilder()
    builder.readTimeout(Duration.millisecond * 500)
    let client = builder.build()
    try {
        let response = client.send(HttpRequestBuilder().url(url).get().build())
        S5HttpResult(Int64(response.status), s5ReadBody(response))
    } catch (_: Exception) {
        S5HttpResult(0, "")
    } finally {
        client.close()
    }
}

private func s5PostWebhook(port: Int64, deliveryId: String, number: Int64): S5HttpResult {
    let body = "{" +
        "\"object_kind\":\"issue\"," +
        "\"project\":{\"path_with_namespace\":\"cangjie/compiler\"}," +
        "\"object_attributes\":{\"iid\":${number},\"action\":\"open\",\"title\":\"S5 中文🙂 ${deliveryId}\",\"description\":\"cross project\",\"url\":\"https://gitcode.com/cangjie/compiler/issues/${number}\"}," +
        "\"user\":{\"name\":\"alice\",\"username\":\"alice\"}" +
    "}"
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
        S5HttpResult(Int64(response.status), s5ReadBody(response))
    } catch (_: Exception) {
        S5HttpResult(0, "")
    } finally {
        client.close()
    }
}

private func s5ProcessGroupId(pid: Int64): Int64 {
    if (pid <= 0) { return 0 }
    let (exitCode, stdout, _) = executeWithOutput("ps", ["-o", "pgid=", "-p", "${pid}"])
    if (exitCode != 0) { return 0 }
    try { Int64.parse(String.fromUtf8(stdout).trimAscii()) } catch (_: Exception) { 0 }
}

private func s5PidGone(pid: Int64): Bool {
    if (pid <= 0) { return false }
    executeWithOutput("kill", ["-0", "${pid}"])[0] != 0
}

private func s5GroupGone(pgid: Int64): Bool {
    if (pgid <= 1) { return false }
    executeWithOutput("pgrep", ["-g", "${pgid}"])[0] != 0
}

private func s5ReapOwnedGroup(pgid: Int64, wrapperPid: Int64, gcmPid: Int64, descendantPid: Int64): Bool {
    if (pgid <= 1 || wrapperPid <= 1 || gcmPid <= 1 || descendantPid <= 1) { return false }
    var anyAlive = false
    for (pid in [wrapperPid, gcmPid, descendantPid]) {
        if (!s5PidGone(pid)) {
            anyAlive = true
            if (s5ProcessGroupId(pid) != pgid) { return false }
        }
    }
    if (!anyAlive) { return s5GroupGone(pgid) }
    let _ = executeWithOutput("kill", ["-TERM", "-${pgid}"])
    if (!s5WaitUntil(500, { => s5GroupGone(pgid) })) {
        let _ = executeWithOutput("kill", ["-KILL", "-${pgid}"])
    }
    s5WaitUntil(2000, { => s5GroupGone(pgid) })
}

private func s5LeaseString(path: Path, key: String): String {
    try {
        JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
            .get(key).getOrThrow().asString().getValue()
    } catch (_: Exception) {
        ""
    }
}

private func s5LeaseInt(path: Path, key: String): Int64 {
    try {
        JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
            .get(key).getOrThrow().asInt().getValue()
    } catch (_: Exception) {
        0
    }
}

private func s5GcmBinary(): Path {
    let root = getVariable("METIS_S5_GCM_ROOT").getOrDefault { "" }.trimAscii()
    if (root.isEmpty()) { return Path("") }
    Path(root).join("target").join("release").join("bin").join("gitcodemonitor")
}

private func s5GcmManifest(binary: Path): ServicePluginManifest {
    let caps = ArrayList<ServiceCapabilityRecord>()
    caps.add(ServiceCapabilityRecord("gitcode.monitor.status", "controlAction"))
    caps.add(ServiceCapabilityRecord("gitcode.event.accepted", "event"))
    caps.add(ServiceCapabilityRecord("gitcode.writeback.apply_result", "controlAction"))
    ServicePluginManifest(
        schema: METIS_SERVICE_PLUGIN_SCHEMA,
        pluginId: "gitcode-monitor",
        displayName: "GitCode Monitor S5",
        kind: "service",
        protocolVersion: "1.0",
        entryCommand: binary.toString(),
        entryArgs: ["plugin-stdio"],
        hasConfigSchema: true,
        capabilityDeclarations: caps
    )
}

private func s5WriteGcmConfig(path: Path, statePath: Path, queuePath: Path, gcmPort: Int64, dependencyPort: Int64): Unit {
    File.writeTo(
        path,
        ("{" +
            "\"monitor\":{\"fullScanIntervalMinutes\":10,\"dryRun\":true,\"statePath\":\"${statePath.toString()}\"}," +
            "\"gitcode\":{\"baseUrl\":\"http://127.0.0.1:${dependencyPort}/api/v5\",\"token\":\"fake-s5-gitcode-token\",\"webhook\":{" +
                "\"enabled\":true,\"bindHost\":\"127.0.0.1\",\"port\":${gcmPort},\"queueDir\":\"${queuePath.toString()}\"," +
                "\"processor\":{\"enabled\":true,\"maxBatchSize\":4}," +
                "\"endpoints\":[{\"id\":\"main\",\"path\":\"/webhooks/gitcode/main\",\"token\":\"fake-s5-webhook-token\",\"allowedEvents\":[\"Issue Hook\"]}]" +
            "}}}").toArray()
    )
}

private func s5StartDependencies(
    home: Path,
    processorEntered!: Option<Path> = None<Path>,
    processorRelease!: Option<Path> = None<Path>
): (SubProcess, Int64) {
    let script = Path(managedStdioResolveBrokerScriptPath()).parent.join("metis-s5-loopback-dependencies.mjs")
    let ready = home.join("s5-dependencies.ready.json")
    let events = home.join("s5-dependencies.events.jsonl")
    let args = ArrayList<String>()
    args.add("node")
    args.add(script.toString())
    args.add(ready.toString())
    args.add(events.toString())
    args.add("s5-service-plugin")
    match ((processorEntered, processorRelease)) {
        case (Some(entered), Some(release)) =>
            args.add(entered.toString())
            args.add(release.toString())
        case _ => ()
    }
    let process = launch(
        "/usr/bin/env",
        args.toArray(),
        stdIn: ProcessRedirect.Discard,
        stdOut: ProcessRedirect.Discard,
        stdErr: ProcessRedirect.Discard
    )
    let readyOk = s5WaitUntil(5000, { => exists(ready) })
    if (!readyOk) { return (process, 0) }
    let port = try {
        JsonValue.fromStr(String.fromUtf8(File.readFrom(ready))).asObject()
            .get("port").getOrThrow().asInt().getValue()
    } catch (_: Exception) {
        0
    }
    (process, port)
}

private func s5BlockedWrapperManifest(wrapper: Path, binary: Path): ServicePluginManifest {
    let caps = ArrayList<ServiceCapabilityRecord>()
    caps.add(ServiceCapabilityRecord("gitcode.monitor.status", "controlAction"))
    caps.add(ServiceCapabilityRecord("gitcode.event.accepted", "event"))
    caps.add(ServiceCapabilityRecord("gitcode.writeback.apply_result", "controlAction"))
    ServicePluginManifest(
        schema: METIS_SERVICE_PLUGIN_SCHEMA,
        pluginId: "gitcode-monitor",
        displayName: "GitCode Monitor S5 blocked",
        kind: "service",
        protocolVersion: "1.0",
        entryCommand: wrapper.toString(),
        entryArgs: [binary.toString(), "plugin-stdio"],
        hasConfigSchema: true,
        capabilityDeclarations: caps
    )
}

private func s5ReadJsonInt(path: Path, key: String): Int64 {
    try {
        JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
            .get(key).getOrThrow().asInt().getValue()
    } catch (_: Exception) {
        0
    }
}

private func s5StopOwnedProcess(process: Option<SubProcess>): Bool {
    match (process) {
        case Some(value) =>
            if (value.isAlive()) {
                try { value.terminate(force: false) } catch (_: Exception) { () }
            }
            try {
                let _ = value.wait(timeout: Some(Duration.second * 2))
                true
            } catch (_: Exception) {
                if (value.isAlive()) {
                    try { value.terminate(force: true) } catch (_: Exception) { () }
                }
                try {
                    let _ = value.wait(timeout: Some(Duration.second * 2))
                    true
                } catch (_: Exception) {
                    false
                }
            }
        case None => true
    }
}

private class S5DeliveryLog {
    private let lock = Mutex()
    private let rows = ArrayList<String>()

    func append(text: String): Unit { synchronized(this.lock) { this.rows.add(text) } }
    func size(): Int64 { synchronized(this.lock) { this.rows.size } }
    func count(fragment: String): Int64 {
        synchronized(this.lock) {
            var count: Int64 = 0
            for (row in this.rows) { if (row.contains(fragment)) { count++ } }
            count
        }
    }
}

private class S5GcmQueueProof {
    let pending: Int64
    let processing: Int64
    let awaiting: Int64
    let processed: Int64
    let deadLetter: Int64
    let cancelled: Int64
    let unique: Int64
    let attemptOne: Int64
    let invalid: Int64

    init(pending: Int64, processing: Int64, awaiting: Int64, processed: Int64,
        deadLetter: Int64, cancelled: Int64, unique: Int64, attemptOne: Int64, invalid: Int64) {
        this.pending = pending
        this.processing = processing
        this.awaiting = awaiting
        this.processed = processed
        this.deadLetter = deadLetter
        this.cancelled = cancelled
        this.unique = unique
        this.attemptOne = attemptOne
        this.invalid = invalid
    }
}

private func s5GcmQueueProof(queuePath: Path, expected: HashSet<String>): S5GcmQueueProof {
    var pending: Int64 = 0
    var processing: Int64 = 0
    var awaiting: Int64 = 0
    var processed: Int64 = 0
    var deadLetter: Int64 = 0
    var cancelled: Int64 = 0
    var attemptOne: Int64 = 0
    var invalid: Int64 = 0
    let seen = HashSet<String>()
    for (status in ["pending", "processing", "awaiting-host", "processed", "dead-letter", "cancelled"]) {
        let directory = queuePath.join(status)
        if (!exists(directory)) { continue }
        try {
            for (entry in Directory.readFrom(directory)) {
                if (!entry.isRegular()) { continue }
                match (status) {
                    case "pending" => pending++
                    case "processing" => processing++
                    case "awaiting-host" => awaiting++
                    case "processed" => processed++
                    case "dead-letter" => deadLetter++
                    case "cancelled" => cancelled++
                    case _ => ()
                }
                if (!entry.name.endsWith(".json")) {
                    invalid++
                    continue
                }
                try {
                    let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(entry.path))).asObject()
                    let deliveryId = root.get("deliveryId").getOrThrow().asString().getValue()
                    let storedStatus = root.get("status").getOrThrow().asString().getValue()
                    let admissionAttempt = root.get("admissionAttempt").getOrThrow().asInt().getValue()
                    let admissionState = root.get("admissionState").getOrThrow().asString().getValue()
                    let hostEventId = root.get("hostEventId").getOrThrow().asString().getValue()
                    let admissionToken = root.get("admissionToken").getOrThrow().asString().getValue()
                    let processedEventId = root.get("processedEventId").getOrThrow().asString().getValue()
                    let identityValid = expected.contains(deliveryId) && entry.name == "${deliveryId}.json" &&
                        !seen.contains(deliveryId)
                    let stateValid = admissionAttempt > 0 && match (status) {
                        case "pending" => storedStatus == "pending" && admissionState == "retry" &&
                            !hostEventId.isEmpty() && !admissionToken.isEmpty() && processedEventId.isEmpty()
                        case "processing" => storedStatus == "processing"
                        case "awaiting-host" => storedStatus == "awaiting-host" && admissionState == "admitted" &&
                            !hostEventId.isEmpty() && !admissionToken.isEmpty() && processedEventId.isEmpty()
                        case "processed" => storedStatus == "processed" && admissionState == "completed" &&
                            !hostEventId.isEmpty() && !admissionToken.isEmpty() && processedEventId == hostEventId
                        case "dead-letter" => storedStatus == "dead-letter"
                        case "cancelled" => storedStatus == "cancelled"
                        case _ => false
                    }
                    if (!identityValid || !stateValid) {
                        invalid++
                        continue
                    }
                    seen.add(deliveryId)
                    if (admissionAttempt == 1) { attemptOne++ }
                } catch (_: Exception) {
                    invalid++
                }
            }
        } catch (_: Exception) {
            invalid++
        }
    }
    S5GcmQueueProof(
        pending, processing, awaiting, processed, deadLetter, cancelled, Int64(seen.size), attemptOne, invalid
    )
}

private class S5GeneratedReplyGate {
    private let lock = Mutex()
    private var condition: Condition
    private var entered: Int64 = 0
    private var active: Int64 = 0
    private var maxActive: Int64 = 0
    private var released = false

    init() {
        synchronized(this.lock) { this.condition = this.lock.condition() }
    }

    func enterAndWait(): Unit {
        synchronized(this.lock) {
            this.entered++
            this.active++
            this.maxActive = max(this.maxActive, this.active)
            this.condition.notifyAll()
            while (!this.released) { this.condition.wait() }
            this.active--
            this.condition.notifyAll()
        }
    }

    func release(): Unit {
        synchronized(this.lock) {
            this.released = true
            this.condition.notifyAll()
        }
    }

    func snapshot(): (Int64, Int64, Int64) {
        synchronized(this.lock) { (this.entered, this.active, this.maxActive) }
    }
}

@Test
public class GatewayGcmShutdownE2eTest {
    @TestCase
    public func s5U1ArchitectureKeepsGcmIndependentAndMetisOwnsTheBroker(): Unit {
        let rootText = getVariable("METIS_S5_GCM_ROOT").getOrDefault { "" }.trimAscii()
        @Expect(rootText.isEmpty(), false)
        let gcmRoot = Path(rootText)
        let metisRoot = Path(managedStdioResolveBrokerScriptPath()).parent.parent
        let gcmManifest = try { String.fromUtf8(File.readFrom(gcmRoot.join("cjpm.toml"))) } catch (_: Exception) { "" }
        let gcmMain = try { String.fromUtf8(File.readFrom(gcmRoot.join("src").join("main.cj"))) } catch (_: Exception) { "" }
        let gcmRuntime = try { String.fromUtf8(File.readFrom(gcmRoot.join("src").join("plugin_runtime.cj"))) } catch (_: Exception) { "" }
        let metisHost = try {
            String.fromUtf8(File.readFrom(metisRoot.join("src").join("gateway").join("service_plugin").join("service_plugin_host.cj")))
        } catch (_: Exception) {
            ""
        }
        @Expect(gcmManifest.isEmpty(), false)
        @Expect(gcmManifest.contains("metis ="), false)
        @Expect(gcmManifest.contains("workspace_cangjie/Metis"), false)
        @Expect(gcmMain.contains("gcmPluginMain"), true)
        @Expect(gcmRuntime.contains("GcmStdoutLineSink"), true)
        @Expect(gcmRuntime.contains("stdout.writeln(line)"), true)
        @Expect(metisHost.contains("gatewayStdioBroker().startOwner"), true)
        @Expect(metisHost.contains("ProcessRedirect.Pipe"), false)
        let pipeBoundary = executeWithOutput(
            "/usr/bin/env",
            ["node", "--test", metisRoot.join("scripts").join("gateway-stdio-pipe-boundary.test.mjs").toString()]
        )
        let architectureBoundary = executeWithOutput(
            "/usr/bin/env",
            ["node", "--test", metisRoot.join("scripts").join("metis-s5-architecture-boundary.test.mjs").toString()]
        )
        let pipeBoundaryText = try {
            String.fromUtf8(pipeBoundary[1]) + String.fromUtf8(pipeBoundary[2])
        } catch (_: Exception) {
            "invalid_response_encoding"
        }
        let architectureBoundaryText = try {
            String.fromUtf8(architectureBoundary[1]) + String.fromUtf8(architectureBoundary[2])
        } catch (_: Exception) {
            "invalid_response_encoding"
        }
        @Expect(pipeBoundary[0], 0)
        @Expect(pipeBoundaryText.contains("pass 4"), true)
        @Expect(pipeBoundaryText.contains("fail 0"), true)
        @Expect(architectureBoundary[0], 0)
        @Expect(architectureBoundaryText.contains("pass 9"), true)
        @Expect(architectureBoundaryText.contains("fail 0"), true)
    }

    @TestCase
    public func s5B1ThirtyTwoFormalHostBrokerGcmCyclesStayConstantAndFullyReap(): Unit {
        resetServicePluginHostForTest()
        @Expect(resetManagedStdioBrokerForTest(timeoutMs: 3000).ok, true)
        let ownedHomes = ArrayList<Path>()
        withServicePluginHostTestHome("s5-b1-formal-gcm-32-cycles", { home: Path =>
            ownedHomes.add(home)
            let binary = s5GcmBinary()
            let configPath = home.join("gcm-s5-config.json")
            let deliveries = S5DeliveryLog()
            var dependencies = None<SubProcess>
            var dependencyPort: Int64 = 0
            var activePid: Int64 = 0
            var activePgid: Int64 = 0
            var activePort: Int64 = 0
            var activeCaptured = false
            var activePidGone = true
            var activeGroupGone = true
            var activePortReleased = true
            var allSettled = false
            try {
                @Expect(binary.toString().isEmpty(), false)
                @Expect(exists(binary), true)
                let startedDependencies = s5StartDependencies(home)
                dependencies = Some(startedDependencies[0])
                dependencyPort = startedDependencies[1]
                @Expect(dependencyPort > 0, true)
                @Expect(s5Get("http://127.0.0.1:${dependencyPort}/healthz").status, 200)

                let registered = registerServicePlugin(ServicePluginRegistration(
                    s5GcmManifest(binary),
                    configRef: ServicePluginConfigRef(
                        configPath: configPath.toString(),
                        workingDirectory: binary.parent.toString()
                    )
                ))
                @Expect(registered.ok, true)
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "s5-account", "s5-peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    ServicePluginGeneratedReplyResult(false, status: "s5_fake_model", draft: "S5 中文🙂", needsHumanReview: true)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    deliveries.append(text)
                    ServicePluginEventDeliveryResult(true, "sent", messageId: "s5-${deliveries.size()}")
                }))

                var previousGeneration: Int64 = 0
                var stableReaderCount: Int64 = -1
                var stableDispatcherCount: Int64 = -1
                let instanceIds = ArrayList<String>()
                for (round in 0..32) {
                    let gcmPort = s5TemporaryPort()
                    @Expect(gcmPort > 0 && gcmPort != dependencyPort, true)
                    let roundDir = home.join("round-${round}")
                    Directory.create(roundDir, recursive: true)
                    s5WriteGcmConfig(
                        configPath,
                        roundDir.join("state.json"),
                        roundDir.join("queue"),
                        gcmPort,
                        dependencyPort
                    )
                    let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 5000)
                    @Expect(started.ok, true)
                    let snapshot = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                    activePid = snapshot.pid
                    activePgid = s5ProcessGroupId(activePid)
                    activePort = gcmPort
                    activeCaptured = true
                    activePidGone = false
                    activeGroupGone = false
                    activePortReleased = false
                    @Expect(activePid > 0, true)
                    @Expect(activePgid > 0, true)
                    @Expect(instanceIds.contains(snapshot.instanceId), false)
                    instanceIds.add(snapshot.instanceId)
                    let leasePath = home.join("service-plugin").join("runtime").join("gitcode-monitor")
                        .join("${snapshot.instanceId}.lease.json")
                    @Expect(s5WaitUntil(5000, { => exists(leasePath) && s5LeaseString(leasePath, "state") == "running" }), true)
                    @Expect(s5LeaseString(leasePath, "sessionId"), snapshot.instanceId)
                    @Expect(s5LeaseInt(leasePath, "pid"), activePid)
                    @Expect(s5LeaseInt(leasePath, "port"), gcmPort)
                    let broker = managedStdioBroker().snapshot()
                    @Expect(broker.ownerCount, 1)
                    if (previousGeneration == 0) {
                        previousGeneration = broker.generation
                        stableReaderCount = broker.readerCount
                        stableDispatcherCount = broker.dispatcherCount
                    }
                    @Expect(broker.generation, previousGeneration)
                    @Expect(broker.readerCount, stableReaderCount)
                    @Expect(broker.dispatcherCount, stableDispatcherCount)
                    @Expect(stableReaderCount, 1)
                    @Expect(stableDispatcherCount, 0)

                    @Expect(s5WaitUntil(5000, { => s5Get("http://127.0.0.1:${gcmPort}/healthz").status == 200 }), true)
                    for (_ in 0..4) {
                        let health = s5Get("http://127.0.0.1:${gcmPort}/healthz")
                        @Expect(health.status, 200)
                        @Expect(health.body.trimAscii(), "ok")
                    }
                    let deliveryId = "s5-b1-${round}"
                    let before = deliveries.size()
                    let posted = s5PostWebhook(gcmPort, deliveryId, 5000 + round)
                    @Expect(posted.status >= 200 && posted.status < 300, true)
                    let duplicate = s5PostWebhook(gcmPort, deliveryId, 5000 + round)
                    @Expect(duplicate.status >= 200 && duplicate.status < 300, true)
                    @Expect(s5WaitUntil(5000, { => deliveries.size() == before + 1 }), true)
                    @Expect(deliveries.count(deliveryId), 1)

                    let stopped = stopServicePlugin("gitcode-monitor", reason: "s5-b1-${round}", timeoutMillis: 5000)
                    @Expect(stopped.ok, true)
                    @Expect(stopped.status, "stopped")
                    @Expect(stopped.ingressStopStatus, "sent")
                    @Expect(stopped.dispatchStatus, "drained")
                    @Expect(stopped.leaseStatus, "stopped")
                    @Expect(stopped.portStatus, "released")
                    let stoppedPid = activePid
                    let stoppedPgid = activePgid
                    let stoppedPort = activePort
                    activePidGone = s5WaitUntil(5000, { => s5PidGone(stoppedPid) })
                    activeGroupGone = s5WaitUntil(5000, { => s5GroupGone(stoppedPgid) })
                    activePortReleased = s5WaitUntil(5000, { => s5CanBindPort(stoppedPort) })
                    @Expect(activePidGone, true)
                    @Expect(activeGroupGone, true)
                    @Expect(activePortReleased, true)
                    @Expect(s5LeaseString(leasePath, "sessionId"), snapshot.instanceId)
                    @Expect(s5LeaseString(leasePath, "state"), "stopped")
                    @Expect(s5LeaseInt(leasePath, "pid"), activePid)
                    @Expect(s5LeaseInt(leasePath, "port"), gcmPort)
                    let after = managedStdioBroker().snapshot()
                    @Expect(after.ownerCount, 0)
                    @Expect(after.readerCount, stableReaderCount)
                    @Expect(after.dispatcherCount, stableDispatcherCount)
                    activeCaptured = false
                    activePid = 0
                    activePgid = 0
                    activePort = 0
                }
                @Expect(deliveries.size(), 32)
                @Expect(instanceIds.size, 32)
                allSettled = true
            } finally {
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()
                resetServicePluginHostForTest()
                let brokerReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                let dependencySettled = s5StopOwnedProcess(dependencies)
                let capturedActivePid = activePid
                let capturedActivePgid = activePgid
                let capturedActivePort = activePort
                if (activeCaptured) {
                    activePidGone = capturedActivePid > 1 && s5WaitUntil(3000, { => s5PidGone(capturedActivePid) })
                    activeGroupGone = capturedActivePgid > 1 && s5WaitUntil(3000, { => s5GroupGone(capturedActivePgid) })
                    activePortReleased = capturedActivePort > 0 && s5WaitUntil(3000, { => s5CanBindPort(capturedActivePort) })
                }
                let ownerGone = managedStdioBroker().snapshot().ownerCount == 0
                @Expect(brokerReset.ok, true)
                @Expect(dependencySettled, true)
                @Expect(activePidGone, true)
                @Expect(activeGroupGone, true)
                @Expect(activePortReleased, true)
                @Expect(ownerGone, true)
                @Expect(allSettled, true)
                gatewayLoggingResetForTest()
            }
        })
        let ownedHome = ownedHomes[0]
        @Expect(s5RemoveOwnedTempHome(ownedHome), true)
        @Expect(exists(ownedHome), false)
    }

    @TestCase
    public func s5B1Formal140WebhookBurstStaysBoundedAndHealthy(): Unit {
        resetServicePluginHostForTest()
        @Expect(resetManagedStdioBrokerForTest(timeoutMs: 3000).ok, true)
        let ownedHomes = ArrayList<Path>()
        withServicePluginHostTestHome("s5-b1-formal-gcm-140-burst", { home: Path =>
            ownedHomes.add(home)
            let binary = s5GcmBinary()
            let configPath = home.join("gcm-s5-config.json")
            let statePath = home.join("gcm-s5-state.json")
            let queuePath = home.join("gcm-s5-queue")
            let gate = S5GeneratedReplyGate()
            var dependencies = None<SubProcess>
            var gcmPid: Int64 = 0
            var gcmPgid: Int64 = 0
            var gcmPort: Int64 = 0
            var leasePath = Path("")
            var formallyStopped = false
            try {
                @Expect(binary.toString().isEmpty(), false)
                @Expect(exists(binary), true)
                let startedDependencies = s5StartDependencies(home)
                dependencies = Some(startedDependencies[0])
                let dependencyPort = startedDependencies[1]
                @Expect(dependencyPort > 0, true)
                @Expect(s5Get("http://127.0.0.1:${dependencyPort}/healthz").status, 200)

                gcmPort = s5TemporaryPort()
                @Expect(gcmPort > 0 && gcmPort != dependencyPort, true)
                s5WriteGcmConfig(configPath, statePath, queuePath, gcmPort, dependencyPort)
                let registered = registerServicePlugin(ServicePluginRegistration(
                    s5GcmManifest(binary),
                    configRef: ServicePluginConfigRef(
                        configPath: configPath.toString(),
                        workingDirectory: binary.parent.toString()
                    )
                ))
                @Expect(registered.ok, true)
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "s5-b1", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    gate.enterAndWait()
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "S5 bounded reply 中文🙂")
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String =>
                    ServicePluginEventDeliveryResult(true, "sent")
                }))

                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 5000).ok, true)
                let initial = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                gcmPid = initial.pid
                gcmPgid = s5ProcessGroupId(gcmPid)
                @Expect(gcmPid > 1 && gcmPgid > 1, true)
                leasePath = home.join("service-plugin").join("runtime").join("gitcode-monitor")
                    .join("${initial.instanceId}.lease.json")
                let stableLeasePath = leasePath
                let stableGcmPid = gcmPid
                let stableGcmPgid = gcmPgid
                let stableGcmPort = gcmPort
                let ownerReady = s5WaitUntil(5000, { =>
                    exists(stableLeasePath) && s5LeaseString(stableLeasePath, "state") == "running" &&
                        s5LeaseInt(stableLeasePath, "pid") == stableGcmPid &&
                        s5LeaseInt(stableLeasePath, "port") == stableGcmPort &&
                        s5Get("http://127.0.0.1:${stableGcmPort}/healthz").status == 200
                })
                @Expect(ownerReady, true)
                let brokerBefore = managedStdioBroker().snapshot()
                @Expect(brokerBefore.ownerCount, 1)

                let expectedDeliveries = HashSet<String>()
                for (index in 0..140) {
                    let deliveryId = "s5-b1-${"${index}".padStart(4, padding: "0")}-end"
                    expectedDeliveries.add(deliveryId)
                    let posted = s5PostWebhook(gcmPort, deliveryId, 6000 + index)
                    @Expect(posted.status >= 200 && posted.status < 300, true)
                }
                @Expect(expectedDeliveries.size, 140)
                @Expect(s5WaitUntil(15000, { =>
                    let queue = s5GcmQueueProof(queuePath, expectedDeliveries)
                    match (servicePluginDispatchSchedulerSnapshotForTest("gitcode-monitor")) {
                        case Some(row) => row.active == 2 && row.queued == 128 && row.accepted == 130 &&
                            row.futures == 2 && row.queueHighWatermark == 128 && row.queueFull >= 10 &&
                            queue.awaiting == 130 && queue.pending == 10 && queue.processing == 0 &&
                            queue.processed == 0 && queue.deadLetter == 0 && queue.cancelled == 0 &&
                            queue.unique == 140 && queue.attemptOne == 140 && queue.invalid == 0
                        case None => false
                    }
                }), true)
                let saturatedQueue = s5GcmQueueProof(queuePath, expectedDeliveries)
                @Expect(saturatedQueue.awaiting, 130)
                @Expect(saturatedQueue.pending, 10)
                @Expect(saturatedQueue.processing, 0)
                @Expect(saturatedQueue.processed, 0)
                @Expect(saturatedQueue.deadLetter, 0)
                @Expect(saturatedQueue.cancelled, 0)
                @Expect(saturatedQueue.unique, 140)
                @Expect(saturatedQueue.attemptOne, 140)
                @Expect(saturatedQueue.invalid, 0)
                let saturatedScheduler = servicePluginDispatchSchedulerSnapshotForTest("gitcode-monitor").getOrThrow()
                let saturated = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(saturatedScheduler.active, 2)
                @Expect(saturatedScheduler.queued, 128)
                @Expect(saturatedScheduler.futures, 2)
                @Expect(saturatedScheduler.queueHighWatermark, 128)
                @Expect(saturatedScheduler.queueFull >= 10, true)
                @Expect(saturated.dispatch.active, 2)
                @Expect(saturated.dispatch.queued, 128)
                @Expect(saturated.dispatch.highWater, 128)
                @Expect(saturated.dispatch.queueFull >= 10, true)
                @Expect(saturated.dispatch.admissionRetried >= 10, true)
                @Expect(gate.snapshot()[1], 2)
                @Expect(gate.snapshot()[2], 2)

                for (_ in 0..8) {
                    let current = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                    @Expect(current.pid, gcmPid)
                    @Expect(s5ProcessGroupId(current.pid), gcmPgid)
                    @Expect(s5LeaseString(leasePath, "state"), "running")
                    @Expect(s5LeaseInt(leasePath, "pid"), gcmPid)
                    @Expect(s5Get("http://127.0.0.1:${gcmPort}/healthz").status, 200)
                    let broker = managedStdioBroker().snapshot()
                    @Expect(broker.ownerCount, 1)
                    @Expect(broker.generation, brokerBefore.generation)
                }

                gate.release()
                let allRetriesCompleted = s5WaitUntil(60000, { =>
                    let queue = s5GcmQueueProof(queuePath, expectedDeliveries)
                    gate.snapshot()[0] == 140 && queue.pending == 0 && queue.processing == 0 &&
                        queue.awaiting == 0 && queue.processed == 140 && queue.deadLetter == 0 &&
                        queue.cancelled == 0 && queue.unique == 140 && queue.invalid == 0 &&
                        match ((getServicePluginSnapshot("gitcode-monitor"),
                            servicePluginDispatchSchedulerSnapshotForTest("gitcode-monitor"))) {
                        case (Some(snapshot), Some(scheduler)) =>
                            snapshot.dispatch.completionAck == 140 && scheduler.settled
                        case _ => false
                    }
                })
                @Expect(allRetriesCompleted, true)
                let drainedQueue = s5GcmQueueProof(queuePath, expectedDeliveries)
                @Expect(drainedQueue.pending, 0)
                @Expect(drainedQueue.processing, 0)
                @Expect(drainedQueue.awaiting, 0)
                @Expect(drainedQueue.processed, 140)
                @Expect(drainedQueue.deadLetter, 0)
                @Expect(drainedQueue.cancelled, 0)
                @Expect(drainedQueue.unique, 140)
                @Expect(drainedQueue.invalid, 0)
                let drained = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(drained.dispatch.active, 0)
                @Expect(drained.dispatch.queued, 0)
                @Expect(drained.dispatch.highWater, 128)
                @Expect(drained.dispatch.queueFull >= 10, true)
                @Expect(drained.dispatch.admissionRetried >= 10, true)
                @Expect(drained.dispatch.completionAck, 140)
                @Expect(gate.snapshot()[0], 140)
                @Expect(gate.snapshot()[1], 0)
                @Expect(gate.snapshot()[2], 2)

                let stopped = stopServicePlugin("gitcode-monitor", reason: "s5-b1-140-complete", timeoutMillis: 5000)
                @Expect(stopped.ok, true)
                @Expect(stopped.status, "stopped")
                @Expect(stopped.ingressStopStatus, "sent")
                @Expect(stopped.dispatchStatus, "drained")
                @Expect(stopped.leaseStatus, "stopped")
                @Expect(stopped.portStatus, "released")
                formallyStopped = true
                let pidGone = s5WaitUntil(5000, { => s5PidGone(stableGcmPid) })
                let groupGone = s5WaitUntil(5000, { => s5GroupGone(stableGcmPgid) })
                let portReleased = s5WaitUntil(5000, { => s5CanBindPort(stableGcmPort) })
                @Expect(pidGone, true)
                @Expect(groupGone, true)
                @Expect(portReleased, true)
                @Expect(s5LeaseString(leasePath, "state"), "stopped")
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            } finally {
                gate.release()
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()
                if (!formallyStopped) { let _ = stopServicePlugin("gitcode-monitor", reason: "s5-b1-cleanup", timeoutMillis: 5000) }
                resetServicePluginHostForTest()
                @Expect(resetManagedStdioBrokerForTest(timeoutMs: 3000).ok, true)
                @Expect(s5StopOwnedProcess(dependencies), true)
                gatewayLoggingResetForTest()
            }
        })
        let ownedHome = ownedHomes[0]
        @Expect(s5RemoveOwnedTempHome(ownedHome), true)
        @Expect(exists(ownedHome), false)
    }

    @TestCase
    public func s5N1InvalidUtf8OwnerIsRedactedAndHealthyReplacementSurvives(): Unit {
        resetServicePluginHostForTest()
        @Expect(resetManagedStdioBrokerForTest(timeoutMs: 3000).ok, true)
        withServicePluginHostTestHome("s5-n1-invalid-utf8-owner", { home: Path =>
            let gcmRoot = Path(getVariable("METIS_S5_GCM_ROOT").getOrDefault { "" }.trimAscii())
            let binary = s5GcmBinary()
            let wrapper = gcmRoot.join("test").join("fixtures").join("gcm-s5-blocked-wrapper.mjs")
            let configPath = home.join("gcm-s5-config.json")
            let statePath = home.join("gcm-s5-state.json")
            let queuePath = home.join("gcm-s5-queue")
            let wrapperReady = home.join("wrapper.ready.json")
            let stopSeen = home.join("wrapper.stop-seen")
            let oldReadyEnv = getVariable("GCM_S5_READY_PATH")
            let oldStopEnv = getVariable("GCM_S5_STOP_SEEN_PATH")
            let oldChildDyldEnv = getVariable("GCM_S5_CHILD_DYLD_LIBRARY_PATH")
            let oldInvalidEnv = getVariable("GCM_S5_INVALID_UTF8_STDOUT")
            var dependencies = None<SubProcess>
            var oldWrapperPid: Int64 = 0
            var oldGcmPid: Int64 = 0
            var oldDescendantPid: Int64 = 0
            var oldPgid: Int64 = 0
            var oldGroupCaptured = false
            var oldGroupGone = false
            var oldPort: Int64 = 0
            var oldPortReleased = false
            var replacementPid: Int64 = 0
            var replacementPort: Int64 = 0
            var replacementStopped = false
            var dependencySettled = false
            try {
                @Expect(exists(binary), true)
                @Expect(exists(wrapper), true)
                setVariable("GCM_S5_READY_PATH", wrapperReady.toString())
                setVariable("GCM_S5_STOP_SEEN_PATH", stopSeen.toString())
                setVariable(
                    "GCM_S5_CHILD_DYLD_LIBRARY_PATH",
                    getVariable("DYLD_LIBRARY_PATH").getOrDefault { "" }
                )
                setVariable("GCM_S5_INVALID_UTF8_STDOUT", "1")
                let startedDependencies = s5StartDependencies(home)
                dependencies = Some(startedDependencies[0])
                let dependencyPort = startedDependencies[1]
                @Expect(dependencyPort > 0, true)
                oldPort = s5TemporaryPort()
                @Expect(oldPort > 0 && oldPort != dependencyPort, true)
                s5WriteGcmConfig(configPath, statePath, queuePath, oldPort, dependencyPort)
                let registered = registerServicePlugin(ServicePluginRegistration(
                    s5BlockedWrapperManifest(wrapper, binary),
                    configRef: ServicePluginConfigRef(
                        configPath: configPath.toString(),
                        workingDirectory: binary.parent.toString()
                    )
                ))
                @Expect(registered.ok, true)
                let invalid = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 5000)
                @Expect(invalid.ok, false)
                @Expect(invalid.status, "invalid_response_encoding")
                @Expect(invalid.diagnostic.contains("invalid_response_encoding"), true)
                @Expect(invalid.diagnostic.contains("noiseLines=0"), true)
                @Expect(invalid.diagnostic.contains("noiseBytes=0"), true)
                @Expect(invalid.diagnostic.contains("fake-s5-webhook-token"), false)
                @Expect(invalid.diagnostic.contains(home.toString()), false)
                @Expect(invalid.diagnostic.contains(configPath.toString()), false)
                @Expect(invalid.diagnostic.contains("object_kind"), false)
                @Expect(invalid.diagnostic.contains("cangjie/compiler"), false)
                let invalidSnapshot = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(invalidSnapshot.status, "degraded")
                @Expect(invalidSnapshot.degradedReason, "invalid_response_encoding")
                @Expect(invalidSnapshot.lastError.contains("invalid_response_encoding"), true)
                @Expect(invalidSnapshot.lastError.contains("noiseLines=0"), true)
                @Expect(invalidSnapshot.lastError.contains("noiseBytes=0"), true)
                @Expect(invalidSnapshot.lastError.contains("fake-s5-webhook-token"), false)
                @Expect(invalidSnapshot.lastError.contains(home.toString()), false)
                @Expect(invalidSnapshot.lastError.contains(configPath.toString()), false)
                @Expect(invalidSnapshot.lastError.contains("object_kind"), false)
                @Expect(invalidSnapshot.lastError.contains("cangjie/compiler"), false)
                @Expect(s5WaitUntil(5000, { => exists(wrapperReady) }), true)
                oldWrapperPid = s5ReadJsonInt(wrapperReady, "wrapperPid")
                oldGcmPid = s5ReadJsonInt(wrapperReady, "gcmPid")
                oldDescendantPid = s5ReadJsonInt(wrapperReady, "descendantPid")
                oldPgid = s5ReadJsonInt(wrapperReady, "pgid")
                oldGroupCaptured = oldWrapperPid > 1 && oldGcmPid > 1 && oldDescendantPid > 1 && oldPgid > 1
                @Expect(oldGroupCaptured, true)
                let capturedOldPgid = oldPgid
                let capturedOldPort = oldPort
                oldGroupGone = s5WaitUntil(5000, { => s5GroupGone(capturedOldPgid) })
                oldPortReleased = s5WaitUntil(5000, { => s5CanBindPort(capturedOldPort) })
                @Expect(oldGroupGone, true)
                @Expect(oldPortReleased, true)
                @Expect(s5WaitUntil(5000, { => managedStdioBroker().snapshot().ownerCount == 0 }), true)
                let brokerAfterInvalid = managedStdioBroker().snapshot()
                @Expect(brokerAfterInvalid.generation > 0, true)
                @Expect(brokerAfterInvalid.readerCount, 1)
                @Expect(brokerAfterInvalid.dispatcherCount, 0)

                resetServicePluginHostForTest()
                setVariable("GCM_S5_INVALID_UTF8_STDOUT", "")
                setVariable("GCM_S5_READY_PATH", "")
                setVariable("GCM_S5_STOP_SEEN_PATH", "")
                replacementPort = s5TemporaryPort()
                @Expect(replacementPort > 0 && replacementPort != oldPort, true)
                s5WriteGcmConfig(configPath, statePath, queuePath, replacementPort, dependencyPort)
                let replacementRegistration = registerServicePlugin(ServicePluginRegistration(
                    s5GcmManifest(binary),
                    configRef: ServicePluginConfigRef(
                        configPath: configPath.toString(),
                        workingDirectory: binary.parent.toString()
                    )
                ))
                @Expect(replacementRegistration.ok, true)
                let replacement = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 5000)
                @Expect(replacement.ok, true)
                @Expect(replacement.status, "running")
                let replacementSnapshot = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                replacementPid = replacementSnapshot.pid
                @Expect(replacementPid > 1 && replacementPid != oldGcmPid, true)
                let brokerAfterReplacement = managedStdioBroker().snapshot()
                @Expect(brokerAfterReplacement.generation, brokerAfterInvalid.generation)
                @Expect(brokerAfterReplacement.readerCount, brokerAfterInvalid.readerCount)
                @Expect(brokerAfterReplacement.dispatcherCount, brokerAfterInvalid.dispatcherCount)
                @Expect(brokerAfterReplacement.ownerCount, 1)
                let capturedReplacementPort = replacementPort
                @Expect(s5WaitUntil(5000, { =>
                    s5Get("http://127.0.0.1:${capturedReplacementPort}/healthz").status == 200
                }), true)
                let stopped = stopServicePlugin(
                    "gitcode-monitor",
                    reason: "s5-n1-invalid-utf8-replacement",
                    timeoutMillis: 5000
                )
                @Expect(stopped.ok, true)
                @Expect(stopped.status, "stopped")
                @Expect(stopped.ingressStopStatus, "sent")
                @Expect(stopped.dispatchStatus, "drained")
                @Expect(stopped.leaseStatus, "stopped")
                @Expect(stopped.portStatus, "released")
                let capturedReplacementPid = replacementPid
                replacementStopped = s5WaitUntil(5000, { =>
                    s5PidGone(capturedReplacementPid) && s5CanBindPort(capturedReplacementPort) &&
                        managedStdioBroker().snapshot().ownerCount == 0
                })
                @Expect(replacementStopped, true)
            } finally {
                let _ = stopServicePlugin(
                    "gitcode-monitor",
                    reason: "s5-n1-invalid-utf8-finally",
                    timeoutMillis: 2000
                )
                resetServicePluginHostForTest()
                let brokerReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                if (!oldGroupGone && oldGroupCaptured) {
                    oldGroupGone = try {
                        s5ReapOwnedGroup(oldPgid, oldWrapperPid, oldGcmPid, oldDescendantPid)
                    } catch (_: Exception) {
                        false
                    }
                }
                if (!oldPortReleased && oldPort > 0) {
                    let capturedOldPort = oldPort
                    oldPortReleased = s5WaitUntil(3000, { => s5CanBindPort(capturedOldPort) })
                }
                if (!replacementStopped && replacementPid > 1 && replacementPort > 0) {
                    let capturedReplacementPid = replacementPid
                    let capturedReplacementPort = replacementPort
                    replacementStopped = s5WaitUntil(3000, { =>
                        s5PidGone(capturedReplacementPid) && s5CanBindPort(capturedReplacementPort)
                    })
                }
                dependencySettled = s5StopOwnedProcess(dependencies)
                match (oldReadyEnv) {
                    case Some(value) => setVariable("GCM_S5_READY_PATH", value)
                    case None => setVariable("GCM_S5_READY_PATH", "")
                }
                match (oldStopEnv) {
                    case Some(value) => setVariable("GCM_S5_STOP_SEEN_PATH", value)
                    case None => setVariable("GCM_S5_STOP_SEEN_PATH", "")
                }
                match (oldChildDyldEnv) {
                    case Some(value) => setVariable("GCM_S5_CHILD_DYLD_LIBRARY_PATH", value)
                    case None => setVariable("GCM_S5_CHILD_DYLD_LIBRARY_PATH", "")
                }
                match (oldInvalidEnv) {
                    case Some(value) => setVariable("GCM_S5_INVALID_UTF8_STDOUT", value)
                    case None => setVariable("GCM_S5_INVALID_UTF8_STDOUT", "")
                }
                @Expect(brokerReset.ok, true)
                @Expect(oldGroupGone, true)
                @Expect(oldPortReleased, true)
                @Expect(replacementStopped, true)
                @Expect(dependencySettled, true)
            }
        })
    }

    @TestCase
    public func s5N1LayeredHostTerminalFailureKeepsReplacementHealthy(): Unit {
        resetServicePluginHostForTest()
        @Expect(resetManagedStdioBrokerForTest(timeoutMs: 3000).ok, true)
        withServicePluginHostTestHome("s5-n1-layered-terminal-failure", { home: Path =>
            let gcmRoot = Path(getVariable("METIS_S5_GCM_ROOT").getOrDefault { "" }.trimAscii())
            let binary = s5GcmBinary()
            let wrapper = gcmRoot.join("test").join("fixtures").join("gcm-s5-blocked-wrapper.mjs")
            let configPath = home.join("gcm-s5-config.json")
            let statePath = home.join("gcm-s5-state.json")
            let queuePath = home.join("gcm-s5-queue")
            let wrapperReady = home.join("wrapper.ready.json")
            let stopSeen = home.join("wrapper.stop-seen")
            let oldReadyEnv = getVariable("GCM_S5_READY_PATH")
            let oldStopEnv = getVariable("GCM_S5_STOP_SEEN_PATH")
            let oldChildDyldEnv = getVariable("GCM_S5_CHILD_DYLD_LIBRARY_PATH")
            let deliveries = S5DeliveryLog()
            var dependencies = None<SubProcess>
            var stopper = None<Future<ServiceStopResult>>
            var oldWrapperPid: Int64 = 0
            var oldGcmPid: Int64 = 0
            var oldDescendantPid: Int64 = 0
            var oldPgid: Int64 = 0
            var oldGroupCaptured = false
            var oldGroupGone = false
            var oldPort: Int64 = 0
            var oldPortReleased = false
            var newPid: Int64 = 0
            var newPort: Int64 = 0
            var newStopped = false
            var dependencySettled = false
            var stopSettled = false
            try {
                @Expect(exists(binary), true)
                @Expect(exists(wrapper), true)
                setVariable("GCM_S5_READY_PATH", wrapperReady.toString())
                setVariable("GCM_S5_STOP_SEEN_PATH", stopSeen.toString())
                setVariable(
                    "GCM_S5_CHILD_DYLD_LIBRARY_PATH",
                    getVariable("DYLD_LIBRARY_PATH").getOrDefault { "" }
                )
                let startedDependencies = s5StartDependencies(home)
                dependencies = Some(startedDependencies[0])
                let dependencyPort = startedDependencies[1]
                @Expect(dependencyPort > 0, true)
                oldPort = s5TemporaryPort()
                @Expect(oldPort > 0 && oldPort != dependencyPort, true)
                s5WriteGcmConfig(configPath, statePath, queuePath, oldPort, dependencyPort)
                let registered = registerServicePlugin(ServicePluginRegistration(
                    s5BlockedWrapperManifest(wrapper, binary),
                    configRef: ServicePluginConfigRef(
                        configPath: configPath.toString(),
                        workingDirectory: binary.parent.toString()
                    )
                ))
                @Expect(registered.ok, true)
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "s5-account", "s5-peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    ServicePluginGeneratedReplyResult(false, status: "s5_fake_model", draft: event.eventId, needsHumanReview: true)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    deliveries.append(text)
                    ServicePluginEventDeliveryResult(true, "sent", messageId: "s5-${deliveries.size()}")
                }))

                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 5000)
                let startedRunning = started.status == "running"
                let startedInitializeTimeout = started.status == "initialize_timeout"
                let startedInitializeFailed = started.status == "initialize_failed"
                let startedStdioClosed = started.status == "stdio_closed"
                let startedProcessStartFailed = started.status == "process_start_failed"
                let startedKnown = startedRunning || startedInitializeTimeout || startedInitializeFailed ||
                    startedStdioClosed || startedProcessStartFailed
                @Expect(started.ok, true)
                @Expect(startedKnown, true)
                @Expect(startedRunning, true)
                @Expect(startedInitializeTimeout, false)
                @Expect(startedInitializeFailed, false)
                @Expect(startedStdioClosed, false)
                @Expect(startedProcessStartFailed, false)
                @Expect(exists(wrapperReady), true)
                let oldBroker = managedStdioBroker().snapshot()
                @Expect(oldBroker.ownerCount, 1)
                @Expect(s5WaitUntil(5000, { => exists(wrapperReady) }), true)
                oldWrapperPid = s5ReadJsonInt(wrapperReady, "wrapperPid")
                oldGcmPid = s5ReadJsonInt(wrapperReady, "gcmPid")
                oldDescendantPid = s5ReadJsonInt(wrapperReady, "descendantPid")
                oldPgid = s5ReadJsonInt(wrapperReady, "pgid")
                oldGroupCaptured = oldWrapperPid > 1 && oldGcmPid > 1 && oldDescendantPid > 1 && oldPgid > 1 &&
                    s5ProcessGroupId(oldWrapperPid) == oldPgid && s5ProcessGroupId(oldGcmPid) == oldPgid &&
                    s5ProcessGroupId(oldDescendantPid) == oldPgid
                @Expect(oldGroupCaptured, true)
                let capturedOldPort = oldPort
                @Expect(s5WaitUntil(5000, { => s5Get("http://127.0.0.1:${capturedOldPort}/healthz").status == 200 }), true)
                stopper = Some(spawn {
                    stopServicePlugin("gitcode-monitor", reason: "s5-n1-writer-failure", timeoutMillis: 5000)
                })
                @Expect(s5WaitUntil(1000, { => exists(stopSeen) }), true)
                managedStdioBroker().debugKillBrokerForTest()
                let failedStop = stopper.getOrThrow().get(Duration.second * 8)
                stopper = None<Future<ServiceStopResult>>
                stopSettled = true
                @Expect(failedStop.ok, false)
                @Expect(failedStop.status, "cleanup_pending")
                @Expect(failedStop.ingressStopStatus, "sent")
                @Expect(failedStop.dispatchStatus, "drained")
                @Expect(failedStop.ownerStopStatus == "terminated" || failedStop.ownerStopStatus == "force_terminated" ||
                    failedStop.ownerStopStatus == "already_stopped", true)
                @Expect(failedStop.leaseStatus, "identity_mismatch")
                @Expect(failedStop.portStatus, "not_checked")
                let capturedOldPgid = oldPgid
                oldGroupGone = s5WaitUntil(5000, { => s5GroupGone(capturedOldPgid) })
                oldPortReleased = s5WaitUntil(5000, { => s5CanBindPort(capturedOldPort) })
                @Expect(oldGroupGone, true)
                @Expect(oldPortReleased, true)
                @Expect(s5WaitUntil(5000, { => managedStdioBroker().snapshot().ownerCount == 0 }), true)
                resetServicePluginHostForTest()
                let brokerReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                @Expect(brokerReset.ok, true)
                newPort = s5TemporaryPort()
                @Expect(newPort > 0 && newPort != oldPort, true)
                s5WriteGcmConfig(configPath, statePath, queuePath, newPort, dependencyPort)
                let reregistered = registerServicePlugin(ServicePluginRegistration(
                    s5GcmManifest(binary),
                    configRef: ServicePluginConfigRef(
                        configPath: configPath.toString(),
                        workingDirectory: binary.parent.toString()
                    )
                ))
                @Expect(reregistered.ok, true)
                let restarted = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 5000)
                @Expect(restarted.ok, true)
                let newSnapshot = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                newPid = newSnapshot.pid
                let newBroker = managedStdioBroker().snapshot()
                @Expect(newBroker.generation > 0, true)
                @Expect(newBroker.brokerPid > 0 && newBroker.brokerPid != oldBroker.brokerPid, true)
                @Expect(newBroker.ownerCount, 1)
                @Expect(newBroker.readerCount, 1)
                @Expect(newBroker.dispatcherCount, 0)
                @Expect(newPid > 0 && newPid != oldGcmPid, true)
                let capturedNewPort = newPort
                @Expect(s5WaitUntil(5000, { => s5Get("http://127.0.0.1:${capturedNewPort}/healthz").status == 200 }), true)
                let newDelivery = "s5-n1-new-generation"
                let newPosted = s5PostWebhook(newPort, newDelivery, 9002)
                @Expect(newPosted.status >= 200 && newPosted.status < 300, true)
                @Expect(s5WaitUntil(5000, { => deliveries.count(newDelivery) == 1 }), true)
                let stoppedNew = stopServicePlugin("gitcode-monitor", reason: "s5-n1-new-generation", timeoutMillis: 5000)
                @Expect(stoppedNew.ok, true)
                @Expect(stoppedNew.status, "stopped")
                @Expect(stoppedNew.leaseStatus, "stopped")
                @Expect(stoppedNew.portStatus, "released")
                let capturedNewPid = newPid
                newStopped = s5WaitUntil(5000, { => s5PidGone(capturedNewPid) && s5CanBindPort(capturedNewPort) &&
                    managedStdioBroker().snapshot().ownerCount == 0 })
                @Expect(newStopped, true)
            } finally {
                if (!stopSettled && stopper.isSome()) {
                    try {
                        let _ = stopper.getOrThrow().get(Duration.second * 8)
                        stopSettled = true
                    } catch (_: Exception) { () }
                }
                resetServicePluginHostForTest()
                if (!stopSettled && stopper.isSome()) {
                    try {
                        let _ = stopper.getOrThrow().get(Duration.second * 2)
                        stopSettled = true
                    } catch (_: Exception) { () }
                }
                let brokerReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                if (!oldGroupGone && oldGroupCaptured) {
                    oldGroupGone = try {
                        s5ReapOwnedGroup(oldPgid, oldWrapperPid, oldGcmPid, oldDescendantPid)
                    } catch (_: Exception) { false }
                }
                if (!oldPortReleased && oldPort > 0) {
                    let finalOldPort = oldPort
                    oldPortReleased = s5WaitUntil(3000, { => s5CanBindPort(finalOldPort) })
                }
                if (!newStopped && newPid > 0) {
                    let finalNewPid = newPid
                    let finalNewPort = newPort
                    newStopped = s5WaitUntil(3000, { => s5PidGone(finalNewPid) && s5CanBindPort(finalNewPort) })
                }
                dependencySettled = s5StopOwnedProcess(dependencies)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()
                match (oldReadyEnv) {
                    case Some(value) => setVariable("GCM_S5_READY_PATH", value)
                    case None => setVariable("GCM_S5_READY_PATH", "")
                }
                match (oldStopEnv) {
                    case Some(value) => setVariable("GCM_S5_STOP_SEEN_PATH", value)
                    case None => setVariable("GCM_S5_STOP_SEEN_PATH", "")
                }
                match (oldChildDyldEnv) {
                    case Some(value) => setVariable("GCM_S5_CHILD_DYLD_LIBRARY_PATH", value)
                    case None => setVariable("GCM_S5_CHILD_DYLD_LIBRARY_PATH", "")
                }
                @Expect(brokerReset.ok, true)
                @Expect(stopSettled, true)
                @Expect(oldGroupCaptured, true)
                @Expect(oldGroupGone, true)
                @Expect(oldPortReleased, true)
                @Expect(newStopped, true)
                @Expect(dependencySettled, true)
            }
        })
    }
}
