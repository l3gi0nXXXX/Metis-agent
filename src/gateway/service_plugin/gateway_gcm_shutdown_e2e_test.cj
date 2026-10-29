package metis.gateway.service_plugin

import magic.config.Config
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
import stdx.encoding.json.{JsonValue, JsonObject, JsonString, JsonInt}
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

private func s5GcmQueueProof(queuePath: Path, expected: HashSet<String>, terminal!: Bool = false): S5GcmQueueProof {
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
        for (path in bpFormalQueuePaths(queuePath, status, expected, terminal: terminal)) {
            let rootValue = bpFormalReadKnown(path)
            if (rootValue.isNone()) { continue }
            match (status) {
                case "pending" => pending++
                case "processing" => processing++
                case "awaiting-host" => awaiting++
                case "processed" => processed++
                case "dead-letter" => deadLetter++
                case "cancelled" => cancelled++
                case _ => ()
            }
            if (!path.fileName.endsWith(".json")) {
                invalid++
                continue
            }
            try {
                let root = rootValue.getOrThrow()
                let deliveryId = root.get("deliveryId").getOrThrow().asString().getValue()
                let storedStatus = root.get("status").getOrThrow().asString().getValue()
                let admissionAttempt = root.get("admissionAttempt").getOrThrow().asInt().getValue()
                let admissionState = root.get("admissionState").getOrThrow().asString().getValue()
                let hostEventId = root.get("hostEventId").getOrThrow().asString().getValue()
                let admissionToken = root.get("admissionToken").getOrThrow().asString().getValue()
                let processedEventId = root.get("processedEventId").getOrThrow().asString().getValue()
                let identityValid = expected.contains(deliveryId) && path.fileName == "${deliveryId}.json" &&
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
            } catch (e: Exception) {
                if (exists(path)) { throw e }
            }
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
            let oldLogFile = Config.logFile
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
                Config.logFile = oldLogFile
                @Expect(Config.logFile, oldLogFile)
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
            let oldLogFile = Config.logFile
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
                // Admission is now bounded by the shared sender rather than host queue saturation.
                @Expect(s5WaitUntil(15000, { =>
                    bpFormalCount(queuePath, "awaiting-host", expectedDeliveries) == 2 && bpFormalCount(queuePath, "pending", expectedDeliveries) == 138 &&
                        bpFormalCount(queuePath, "processing", expectedDeliveries) == 0 && gate.snapshot()[1] == 2
                }), true)
                @Expect(bpFormalCount(queuePath, "awaiting-host", expectedDeliveries), 2)
                @Expect(bpFormalCount(queuePath, "pending", expectedDeliveries), 138)
                @Expect(bpFormalCount(queuePath, "processing", expectedDeliveries), 0)
                @Expect(bpFormalCount(queuePath, "processed", expectedDeliveries), 0)
                @Expect(bpFormalCount(queuePath, "dead-letter", expectedDeliveries), 0)
                @Expect(bpFormalCount(queuePath, "cancelled", expectedDeliveries), 0)
                @Expect(bpFormalOutstandingBytes(queuePath, expectedDeliveries) <= 524288, true)
                let saturatedIdentities = bpFormalIdentityProof(queuePath, expectedDeliveries)
                @Expect(saturatedIdentities[0], 140)
                @Expect(saturatedIdentities[1], 0)
                let saturatedScheduler = servicePluginDispatchSchedulerSnapshotForTest("gitcode-monitor").getOrThrow()
                @Expect(saturatedScheduler.active, 2)
                @Expect(saturatedScheduler.queued, 0)
                @Expect(saturatedScheduler.futures, 2)
                @Expect(saturatedScheduler.queueFull, 0)
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
                // 140 sends at500ms require >=69.5s;100s includes durable/ACK margin.
                let allRetriesCompleted = s5WaitUntil(100000, { =>
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
                @Expect(drained.dispatch.highWater <= 2, true)
                @Expect(drained.dispatch.queueFull, 0)
                @Expect(drained.dispatch.admissionRetried, 0)
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
                let terminalTruth = stopped.ok && stopped.status == "stopped" && stopped.leaseStatus == "stopped" &&
                    stopped.portStatus == "released" && pidGone && groupGone && portReleased &&
                    managedStdioBroker().snapshot().ownerCount == 0
                if (!terminalTruth) { return }
                let terminalQueue = s5GcmQueueProof(queuePath, expectedDeliveries, terminal: true)
                @Expect(terminalQueue.processed, 140)
                @Expect(terminalQueue.unique, 140)
                @Expect(terminalQueue.invalid, 0)
                bpFormalExpectTerminalProof(queuePath, expectedDeliveries)
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
                Config.logFile = oldLogFile
                @Expect(Config.logFile, oldLogFile)
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
            let oldLogFile = Config.logFile
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
                gatewayLoggingResetForTest()
                Config.logFile = oldLogFile
                @Expect(Config.logFile, oldLogFile)
            }
        })
    }

    @TestCase
    public func s5N1LayeredHostTerminalFailureKeepsReplacementHealthy(): Unit {
        resetServicePluginHostForTest()
        @Expect(resetManagedStdioBrokerForTest(timeoutMs: 3000).ok, true)
        withServicePluginHostTestHome("s5-n1-layered-terminal-failure", { home: Path =>
            let oldLogFile = Config.logFile
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
                gatewayLoggingResetForTest()
                Config.logFile = oldLogFile
                @Expect(Config.logFile, oldLogFile)
            }
        })
    }
}

// Formal cases deliberately use the real native host, broker and rebuilt GCM.
// All durable payloads are synthetic; the helper never reads a user's queue.
private func bpFormalRead(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { "invalid_response_encoding" }
}

private func bpFormalArtifact(): Path {
    let root = getVariable("METIS_S5_GCM_ROOT").getOrDefault { "" }.trimAscii()
    let expectedCommit = getVariable("METIS_BP_GCM_COMMIT").getOrDefault { "" }.trimAscii()
    let expectedHash = getVariable("METIS_BP_GCM_ARTIFACT_SHA256").getOrDefault { "" }.trimAscii()
    if (root.isEmpty() || expectedCommit.isEmpty() || expectedHash.isEmpty()) {
        throw Exception("formal_gcm_artifact_identity_required")
    }
    let binary = Path(root).join("target/release/bin/gitcodemonitor")
    let head = executeWithOutput("git", ["-C", root, "rev-parse", "HEAD"])
    let hash = executeWithOutput("/usr/bin/shasum", ["-a", "256", binary.toString()])
    let stamp = executeWithOutput("/usr/bin/stat", ["-f", "%m", binary.toString()])
    let binaryMtime = try { Int64.parse(String.fromUtf8(stamp[1]).trimAscii()) } catch (_: Exception) { 0 }
    for (source in ["host_event_flow_control.cj", "host_event_sender.cj", "webhook_config.cj", "core.cj",
        "webhook_queue.cj", "webhook_processor.cj", "webhook_processor_loop.cj", "plugin_runtime.cj",
        "plugin_jobs.cj", "webhook_http_server.cj"]) {
        let sourceStamp = executeWithOutput("/usr/bin/stat", ["-f", "%m", Path(root).join("src").join(source).toString()])
        let sourceMtime = try { Int64.parse(String.fromUtf8(sourceStamp[1]).trimAscii()) } catch (_: Exception) { 0 }
        if (sourceStamp[0] != 0 || sourceMtime <= 0 || binaryMtime < sourceMtime) {
            throw Exception("formal_gcm_artifact_older_than_source")
        }
    }
    let headText = try { String.fromUtf8(head[1]).trimAscii() } catch (_: Exception) { "" }
    let hashText = try { String.fromUtf8(hash[1]).trimAscii() } catch (_: Exception) { "" }
    if (head[0] != 0 || hash[0] != 0 || stamp[0] != 0 || headText != expectedCommit ||
        !hashText.startsWith(expectedHash + " ")) {
        throw Exception("formal_gcm_artifact_identity_mismatch")
    }
    binary
}

// Healthz keeps its existing plain-text body; flow telemetry uses response headers.
private func bpFormalHealthWindow(port: Int64): (Int64, Int64, Int64) {
    let builder = ClientBuilder()
    builder.readTimeout(Duration.second)
    let client = builder.build()
    try {
        let response = client.send(HttpRequestBuilder().url("http://127.0.0.1:${port}/healthz").get().build())
        let count = Int64.parse(response.headers.getFirst("X-Gcm-Host-Window-Count") ?? "-1")
        let bytes = Int64.parse(response.headers.getFirst("X-Gcm-Host-Window-Bytes") ?? "-1")
        let _ = s5ReadBody(response)
        (Int64(response.status), count, bytes)
    } catch (_: Exception) {
        (0, -1, -1)
    } finally {
        client.close()
    }
}

private func bpFormalSeed(queue: Path, count: Int64): HashSet<String> {
    let expected = HashSet<String>()
    for (name in ["pending", "processing", "awaiting-host", "processed", "dead-letter", "cancelled", "payload", "host-frame"]) {
        Directory.create(queue.join(name), recursive: true)
    }
    for (index in 0..count) {
        let id = "bp-formal-${index}"
        expected.add(id)
        let eventId = "gitcode:synthetic/project:issue:${index}"
        let payload = JsonObject()
        for ((key, value) in [("jobId", "webhook-${id}"), ("eventId", eventId), ("deliveryId", id),
            ("attemptToken", "seed-${index}"), ("repo", "synthetic/project"), ("kind", "issue"),
            ("number", "${index}"), ("title", "历史中文🙂 ${index}"), ("content", "synthetic bounded event"),
            ("url", "https://example.invalid/issues/${index}"), ("author", "synthetic-user")]) {
            payload.put(key, JsonString(value))
        }
        let frame = ServiceFrame("event", "seed-${index}", "gitcode-monitor",
            method: "emitCapabilityEvent", capabilityId: "gitcode.event.accepted",
            correlationId: "seed-${index}", payload: payload.toJsonString())
        let framePath = queue.join("host-frame").join("${id}.jsonl")
        File.writeTo(framePath, encodeServiceFrame(frame).toArray())
        let metadata = JsonObject()
        for ((key, value) in [("deliveryId", id), ("endpointId", "main"), ("eventName", "Issue Hook"),
            ("bodyHash", "synthetic-hash"), ("payloadPath", ""), ("status", "pending"), ("lastError", "host_retry"),
            ("sourceIpHash", "synthetic-source"), ("processedEventId", ""), ("hostFramePath", framePath.toString()),
            ("hostEventId", eventId), ("admissionToken", "seed-${index}"), ("admissionState", "retry"), ("admittedSessionId", "")]) {
            metadata.put(key, JsonString(value))
        }
        for (key in ["receivedAtMs", "attempts", "nextAttemptAtMs", "admissionAttempt"]) { metadata.put(key, JsonInt(0)) }
        File.writeTo(queue.join("pending").join("${id}.json"), metadata.toJsonString().toArray())
    }
    expected
}

// Live observations use only fixture-authorized paths; directory enumeration is
// reserved for the strict proof after the native producer has formally stopped.
private func bpFormalQueuePaths(queue: Path, status: String, expected: HashSet<String>,
    terminal!: Bool = false): ArrayList<Path> {
    let paths = ArrayList<Path>()
    if (terminal) {
        for (entry in Directory.readFrom(queue.join(status))) { paths.add(entry.path) }
    } else {
        for (id in expected) { paths.add(queue.join(status).join("${id}.json")) }
    }
    paths
}

private func bpFormalReadKnown(path: Path): Option<JsonObject> {
    if (!exists(path)) { return None<JsonObject> }
    try {
        Some(JsonValue.fromStr(bpFormalRead(path)).asObject())
    } catch (e: Exception) {
        if (exists(path)) { throw e }
        None<JsonObject>
    }
}

private func bpFormalCount(queue: Path, status: String, expected: HashSet<String>): Int64 {
    var count: Int64 = 0
    for (id in expected) {
        if (exists(queue.join(status).join("${id}.json"))) { count++ }
    }
    count
}

// Both live known identities and the stable terminal scan reject duplicate IDs.
private func bpFormalIdentityProof(queue: Path, expected: HashSet<String>,
    terminal!: Bool = false): (Int64, Int64, Int64) {
    let seen = HashSet<String>()
    var invalid: Int64 = 0
    var unknown: Int64 = 0
    for (status in ["pending", "processing", "awaiting-host", "processed", "dead-letter", "cancelled"]) {
        for (path in bpFormalQueuePaths(queue, status, expected, terminal: terminal)) {
            let rowValue = bpFormalReadKnown(path)
            if (rowValue.isNone()) { continue }
            let row = rowValue.getOrThrow()
            let id = row.get("deliveryId").getOrThrow().asString().getValue()
            let storedStatus = row.get("status").getOrThrow().asString().getValue()
            if (!expected.contains(id)) { unknown++ }
            if (!expected.contains(id) || path.fileName != "${id}.json" || seen.contains(id) || storedStatus != status) {
                invalid++
            } else {
                seen.add(id)
            }
        }
    }
    (seen.size, invalid, unknown)
}

private func bpFormalExpectTerminalProof(queue: Path, expected: HashSet<String>): Unit {
    let proof = bpFormalIdentityProof(queue, expected, terminal: true)
    @Expect(proof[0], Int64(expected.size))
    @Expect(proof[1], 0)
    @Expect(proof[2], 0)
    println("BP_NATIVE_TERMINAL_IDENTITIES expected=${expected.size} unique=${proof[0]} invalid=${proof[1]} unknown=${proof[2]}")
}

private func bpFormalOutstandingBytes(queue: Path, expected: HashSet<String>): Int64 {
    var bytes: Int64 = 0
    for (id in expected) {
        let metadataPath = queue.join("awaiting-host").join("${id}.json")
        let metadata = bpFormalReadKnown(metadataPath)
        if (metadata.isNone()) { continue }
        let path = metadata.getOrThrow().get("hostFramePath").getOrThrow().asString().getValue()
        if (!path.startsWith(queue.join("host-frame").toString() + "/")) { throw Exception("foreign_frame_path") }
        try { bytes += File.readFrom(Path(path)).size } catch (e: Exception) {
            if (exists(metadataPath) || exists(Path(path))) { throw e }
        }
    }
    bytes
}

private func bpFormalCompletedReceiptCount(queue: Path, expected: HashSet<String>): Int64 {
    var count: Int64 = 0
    for (id in expected) {
        let rowValue = bpFormalReadKnown(queue.join("awaiting-host").join("${id}.json"))
        if (rowValue.isNone()) { continue }
        let eventId = rowValue.getOrThrow().get("hostEventId").getOrThrow().asString().getValue()
        if (servicePluginWebhookReceiptStore().state("gitcode-monitor", id, eventId) == "completed_unconfirmed") { count++ }
    }
    count
}

private class BpFormalEffects {
    private let lock = Mutex()
    private let seen = HashSet<String>()
    private var duplicates: Int64 = 0
    func record(id: String): Unit {
        synchronized(this.lock) {
            if (this.seen.contains(id)) { this.duplicates++ } else { this.seen.add(id) }
        }
    }
    func snapshot(): (Int64, Int64) { synchronized(this.lock) { (this.seen.size, this.duplicates) } }
}

private func bpFormalInstall(gate: S5GeneratedReplyGate, effects: BpFormalEffects): Unit {
    setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
        let rows = ArrayList<ServicePluginDeliveryTarget>()
        rows.add(ServicePluginDeliveryTarget("telegram", "bp-formal", "synthetic-peer"))
        rows
    }))
    setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
        gate.enterAndWait()
        effects.record(event.eventId)
        ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "bounded 中文🙂")
    }))
    setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String =>
        ServicePluginEventDeliveryResult(true, "sent")
    }))
}

private func bpFormalReset(gate: S5GeneratedReplyGate): Unit {
    gate.release()
    setServicePluginBeforeCompletionAckHookForTest(None<(String) -> Bool>)
    setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
    setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
    setServicePluginEventDeliveryForTest(None)
    resetServicePluginGeneratedReplyStateForTest()
}

@Test
public class ServicePluginFlowFormalTest {
    @TestCase
    public func bpS3B1E2E01E2E02TenThousandDurableEventsStayBoundedAndHttpSurvives(): Unit {
        resetServicePluginHostForTest()
        resetServicePluginGeneratedReplyStateForTest()
        @Expect(resetManagedStdioBrokerForTest(timeoutMs: 3000).ok, true)
        let ownedHomes = ArrayList<Path>()
        withServicePluginHostTestHome("s5-bp-ten-thousand", { home: Path =>
            ownedHomes.add(home)
            let oldLogFile = Config.logFile
            let gate = S5GeneratedReplyGate()
            let effects = BpFormalEffects()
            let queue = home.join("bp-queue")
            var pid: Int64 = 0
            var port: Int64 = 0
            var formallyStopped = false
            try {
                let binary = bpFormalArtifact()
                let expectedDeliveries = bpFormalSeed(queue, 10000)
                @Expect(bpFormalCount(queue, "pending", expectedDeliveries), 10000)
                port = s5TemporaryPort()
                let config = home.join("bp-config.json")
                s5WriteGcmConfig(config, home.join("bp-state.json"), queue, port, s5TemporaryPort())
                @Expect(registerServicePlugin(ServicePluginRegistration(s5GcmManifest(binary), configRef: ServicePluginConfigRef(
                    configPath: config.toString(), workingDirectory: binary.parent.toString()))).ok, true)
                bpFormalInstall(gate, effects)
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 5000).ok, true)
                pid = getServicePluginSnapshot("gitcode-monitor").getOrThrow().pid
                @Expect(s5WaitUntil(10000, { => gate.snapshot()[0] == 2 && bpFormalCount(queue, "awaiting-host", expectedDeliveries) == 2 }), true)
                @Expect(pid > 1, true)
                var healthyRequests: Int64 = 0
                for (_ in 0..100) {
                    let health = bpFormalHealthWindow(port)
                    if (health[0] == 200) { healthyRequests++ }
                    @Expect(health[0], 200)
                    @Expect(health[1], 2)
                    @Expect(health[2] > 0 && health[2] <= 524288, true)
                    @Expect(getServicePluginSnapshot("gitcode-monitor").getOrThrow().pid, pid)
                    @Expect(getServicePluginSnapshot("gitcode-monitor").getOrThrow().lastError.contains("subscriber_capacity_exceeded"), false)
                    @Expect(getServicePluginSnapshot("gitcode-monitor").getOrThrow().lastError.contains("stdout_protocol_violation"), false)
                    @Expect(bpFormalCount(queue, "awaiting-host", expectedDeliveries), 2)
                    @Expect(bpFormalOutstandingBytes(queue, expectedDeliveries) <= 524288, true)
                }
                var acceptedWebhooks: Int64 = 0
                for (index in 0..100) {
                    let deliveryId = "bp-new-${index}"
                    expectedDeliveries.add(deliveryId)
                    let posted = s5PostWebhook(port, deliveryId, 20000 + index)
                    if (posted.status == 202) { acceptedWebhooks++ }
                    @Expect(posted.status, 202)
                }
                sleep(Duration.second * 3)
                @Expect(gate.snapshot()[0], 2)
                @Expect(bpFormalCount(queue, "pending", expectedDeliveries), 10098)
                @Expect(bpFormalCount(queue, "processing", expectedDeliveries), 0)
                @Expect(bpFormalCount(queue, "awaiting-host", expectedDeliveries), 2)
                @Expect(bpFormalCount(queue, "dead-letter", expectedDeliveries), 0)
                @Expect(bpFormalCount(queue, "processed", expectedDeliveries), 0)
                @Expect(effects.snapshot()[0], 0)
                let saturatedIdentities = bpFormalIdentityProof(queue, expectedDeliveries)
                @Expect(saturatedIdentities[0], 10100)
                @Expect(saturatedIdentities[1], 0)
                let fullWindow = bpFormalHealthWindow(port)
                let currentPid = getServicePluginSnapshot("gitcode-monitor").getOrThrow().pid
                println("BP_NATIVE_WINDOW seeded=10000 healthz200=${healthyRequests} webhook202=${acceptedWebhooks} count=${fullWindow[1]} bytes=${fullWindow[2]} pending=${bpFormalCount(queue, "pending", expectedDeliveries)} awaiting=${bpFormalCount(queue, "awaiting-host", expectedDeliveries)} pid=${pid} pidStable=${currentPid == pid} effects=${effects.snapshot()[0]}")
                // Release blocked test business work, then use the real formal stop.
                gate.release()
                let stopped = stopServicePlugin("gitcode-monitor", reason: "bp-formal-complete", timeoutMillis: 5000)
                @Expect(stopped.ok, true)
                @Expect(stopped.status, "stopped")
                @Expect(stopped.portStatus, "released")
                @Expect(stopped.leaseStatus, "stopped")
                formallyStopped = stopped.ok
                let pidGone = s5PidGone(pid)
                let portReleased = s5CanBindPort(port)
                let remainingOwners = managedStdioBroker().snapshot().ownerCount
                println("BP_NATIVE_FORMAL_STOP ok=${stopped.ok} status=${stopped.status} port=${stopped.portStatus} lease=${stopped.leaseStatus} pidGone=${pidGone} portReleased=${portReleased} owners=${remainingOwners}")
                @Expect(pidGone, true)
                @Expect(portReleased, true)
                @Expect(remainingOwners, 0)
                if (!stopped.ok || stopped.status != "stopped" || stopped.leaseStatus != "stopped" ||
                    stopped.portStatus != "released" || !pidGone || !portReleased || remainingOwners != 0) { return }
                bpFormalExpectTerminalProof(queue, expectedDeliveries)
            } finally {
                bpFormalReset(gate)
                // Assertions above establish formal truth before any fallback cleanup.
                if (!formallyStopped) { let _ = stopServicePlugin("gitcode-monitor", reason: "bp-failure-cleanup", timeoutMillis: 5000) }
                resetServicePluginHostForTest()
                @Expect(resetManagedStdioBrokerForTest(timeoutMs: 3000).ok, true)
                gatewayLoggingResetForTest()
                Config.logFile = oldLogFile
            }
        })
        @Expect(s5RemoveOwnedTempHome(ownedHomes[0]), true)
    }

    @TestCase
    public func bpS3P1E2E03OneHundredResumeAfterLostCompletionWithoutDuplicateEffects(): Unit {
        resetServicePluginHostForTest()
        resetServicePluginGeneratedReplyStateForTest()
        @Expect(resetManagedStdioBrokerForTest(timeoutMs: 3000).ok, true)
        let ownedHomes = ArrayList<Path>()
        withServicePluginHostTestHome("s5-bp-receipt-restart", { home: Path =>
            ownedHomes.add(home)
            let oldLogFile = Config.logFile
            let gate = S5GeneratedReplyGate()
            let effects = BpFormalEffects()
            let queue = home.join("bp-queue")
            var formallyStopped = false
            var pid: Int64 = 0
            var port: Int64 = 0
            try {
                let binary = bpFormalArtifact()
                let expectedDeliveries = bpFormalSeed(queue, 100)
                port = s5TemporaryPort()
                let config = home.join("bp-config.json")
                s5WriteGcmConfig(config, home.join("bp-state.json"), queue, port, s5TemporaryPort())
                @Expect(registerServicePlugin(ServicePluginRegistration(s5GcmManifest(binary), configRef: ServicePluginConfigRef(
                    configPath: config.toString(), workingDirectory: binary.parent.toString()))).ok, true)
                bpFormalInstall(gate, effects)
                gate.release()
                setServicePluginBeforeCompletionAckHookForTest(Some({ _frameId: String => false }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 5000).ok, true)
                pid = getServicePluginSnapshot("gitcode-monitor").getOrThrow().pid
                @Expect(s5WaitUntil(10000, { => effects.snapshot()[0] == 2 }), true)
                sleep(Duration.second * 2)
                @Expect(effects.snapshot()[0], 2)
                @Expect(bpFormalCount(queue, "processed", expectedDeliveries), 0)
                @Expect(bpFormalCount(queue, "awaiting-host", expectedDeliveries), 2)
                @Expect(s5WaitUntil(5000, { => bpFormalCompletedReceiptCount(queue, expectedDeliveries) == 2 &&
                    servicePluginDispatchSchedulerSnapshotForTest("gitcode-monitor").getOrThrow().settled }), true)
                let firstStop = stopServicePlugin("gitcode-monitor", reason: "bp-lost-completion-restart", timeoutMillis: 5000)
                @Expect(firstStop.ok, true)
                @Expect(s5PidGone(pid), true)
                @Expect(s5CanBindPort(port), true)
                let firstTerminalTruth = firstStop.ok && firstStop.status == "stopped" &&
                    firstStop.leaseStatus == "stopped" && firstStop.portStatus == "released" &&
                    s5PidGone(pid) && s5CanBindPort(port) && managedStdioBroker().snapshot().ownerCount == 0
                @Expect(firstTerminalTruth, true)
                if (!firstTerminalTruth) { return }
                bpFormalExpectTerminalProof(queue, expectedDeliveries)
                // Preserve the external effect witness and disk receipts, but erase all
                // process-local dedupe so durable receipts alone prevent replay effects.
                resetServicePluginHostForTest()
                resetServicePluginGeneratedReplyStateForTest()
                let dedupeAfterRestart = servicePluginEventDedupeSizesForTest()
                @Expect(dedupeAfterRestart[0], 0)
                @Expect(dedupeAfterRestart[1], 0)
                @Expect(dedupeAfterRestart[2], 0)
                @Expect(dedupeAfterRestart[3], 0)
                @Expect(bpFormalCompletedReceiptCount(queue, expectedDeliveries), 2)
                @Expect(effects.snapshot()[0], 2)
                @Expect(effects.snapshot()[1], 0)
                println("BP_NATIVE_RESTART_ISOLATION dedupe=${dedupeAfterRestart[0]},${dedupeAfterRestart[1]},${dedupeAfterRestart[2]},${dedupeAfterRestart[3]} completedReceipts=${bpFormalCompletedReceiptCount(queue, expectedDeliveries)} effects=${effects.snapshot()[0]} duplicates=${effects.snapshot()[1]}")
                @Expect(resetManagedStdioBrokerForTest(timeoutMs: 3000).ok, true)
                @Expect(registerServicePlugin(ServicePluginRegistration(s5GcmManifest(binary), configRef: ServicePluginConfigRef(
                    configPath: config.toString(), workingDirectory: binary.parent.toString()))).ok, true)
                bpFormalInstall(gate, effects)
                setServicePluginBeforeCompletionAckHookForTest(None<(String) -> Bool>)
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 5000).ok, true)
                let newPid = getServicePluginSnapshot("gitcode-monitor").getOrThrow().pid
                @Expect(newPid > 1 && newPid != pid, true)
                pid = newPid
                // 100 messages require >=49.5s at the production500ms spacing.
                // 90s includes process startup, receipt reconciliation and disk IO margin.
                let boundsViolated = AtomicBool(false)
                let stablePort = port
                @Expect(s5WaitUntil(90000, { =>
                    let health = bpFormalHealthWindow(stablePort)
                    if (health[0] == 200 && (health[1] < 0 || health[1] > 2 || health[2] < 0 || health[2] > 524288)) {
                        boundsViolated.store(true)
                    }
                    bpFormalCount(queue, "processed", expectedDeliveries) == 100
                }), true)
                @Expect(boundsViolated.load(), false)
                @Expect(effects.snapshot()[0], 100)
                @Expect(effects.snapshot()[1], 0)
                @Expect(bpFormalCount(queue, "pending", expectedDeliveries), 0)
                @Expect(bpFormalCount(queue, "awaiting-host", expectedDeliveries), 0)
                @Expect(bpFormalCount(queue, "processing", expectedDeliveries), 0)
                @Expect(bpFormalCount(queue, "dead-letter", expectedDeliveries), 0)
                @Expect(s5Get("http://127.0.0.1:${port}/healthz").status, 200)
                let drainedWindow = bpFormalHealthWindow(port)
                let currentPid = getServicePluginSnapshot("gitcode-monitor").getOrThrow().pid
                @Expect(currentPid, pid)
                println("BP_NATIVE_RECOVERY processed=${bpFormalCount(queue, "processed", expectedDeliveries)} effects=${effects.snapshot()[0]} duplicates=${effects.snapshot()[1]} count=${drainedWindow[1]} bytes=${drainedWindow[2]} pid=${pid} pidStable=${currentPid == pid} boundsViolated=${boundsViolated.load()}")
                let stopped = stopServicePlugin("gitcode-monitor", reason: "bp-restart-drained", timeoutMillis: 5000)
                @Expect(stopped.ok, true)
                @Expect(stopped.status, "stopped")
                @Expect(stopped.leaseStatus, "stopped")
                @Expect(stopped.portStatus, "released")
                formallyStopped = stopped.ok
                let pidGone = s5PidGone(pid)
                let portReleased = s5CanBindPort(port)
                let remainingOwners = managedStdioBroker().snapshot().ownerCount
                println("BP_NATIVE_FORMAL_STOP ok=${stopped.ok} status=${stopped.status} port=${stopped.portStatus} lease=${stopped.leaseStatus} pidGone=${pidGone} portReleased=${portReleased} owners=${remainingOwners}")
                @Expect(pidGone, true)
                @Expect(portReleased, true)
                @Expect(remainingOwners, 0)
                if (!stopped.ok || stopped.status != "stopped" || stopped.leaseStatus != "stopped" ||
                    stopped.portStatus != "released" || !pidGone || !portReleased || remainingOwners != 0) { return }
                bpFormalExpectTerminalProof(queue, expectedDeliveries)
            } finally {
                bpFormalReset(gate)
                if (!formallyStopped) { let _ = stopServicePlugin("gitcode-monitor", reason: "bp-failure-cleanup", timeoutMillis: 5000) }
                resetServicePluginHostForTest()
                @Expect(resetManagedStdioBrokerForTest(timeoutMs: 3000).ok, true)
                gatewayLoggingResetForTest()
                Config.logFile = oldLogFile
            }
        })
        @Expect(s5RemoveOwnedTempHome(ownedHomes[0]), true)
    }
}

@Test
public class ServicePluginFlowArchitectureTest {
    @TestCase
    public func bpArch01AcceptedProducersUseSenderAndBrokerRemainsNeutral(): Unit {
        let root = Path(getVariable("METIS_S5_GCM_ROOT").getOrDefault { "" })
        let sender = bpFormalRead(root.join("src/host_event_sender.cj"))
        let jobs = bpFormalRead(root.join("src/plugin_jobs.cj"))
        let processor = bpFormalRead(root.join("src/webhook_processor.cj"))
        let runtime = bpFormalRead(root.join("src/plugin_runtime.cj"))
        @Expect(sender.contains("class GcmHostEventSender"), true)
        @Expect(processor.contains("writer.ensureHostSender"), true)
        @Expect(processor.contains("resumePending"), true)
        @Expect(processor.contains("stageAndTrySend"), true)
        @Expect(jobs.contains("sharedHostSender"), true)
        @Expect(jobs.contains("writer.writeFrame(gcmAcceptedScanEventFrame"), false)
        @Expect(processor.contains("writer.writeFrame(retryFrame)"), false)
        @Expect(processor.contains("writer.writeFrame(acceptedFrame)"), false)
        @Expect(runtime.contains("import metis."), false)
        @Expect(jobs.contains("import metis."), false)
        let metisRoot = Path(managedStdioResolveBrokerScriptPath()).parent.parent
        let broker = bpFormalRead(metisRoot.join("src/process/managed_stdio_broker.cj"))
        @Expect(broker.contains("gitcode.event.accepted"), false)
        @Expect(broker.contains("GcmHostEventSender"), false)
    }

    @TestCase
    public func bpArch03FormalFixturesAuthorizeTemporaryQueueAndRandomPortsOnly(): Unit {
        withServicePluginHostTestHome("s5-bp-path-audit", { home: Path =>
            @Expect(home.toString().startsWith("/tmp/metis-service-plugin-s5-bp-"), true)
            let queue = home.join("bp-path-audit")
            let expectedDeliveries = bpFormalSeed(queue, 3)
            @Expect(bpFormalCount(queue, "pending", expectedDeliveries), 3)
            for (id in expectedDeliveries) {
                let metadata = bpFormalReadKnown(queue.join("pending").join("${id}.json")).getOrThrow()
                let framePath = metadata.get("hostFramePath").getOrThrow().asString().getValue()
                @Expect(framePath.startsWith(queue.join("host-frame").toString() + "/"), true)
                let frame = JsonValue.fromStr(bpFormalRead(Path(framePath))).asObject()
                @Expect(frame.get("serviceId").getOrThrow().asString().getValue(), "gitcode-monitor")
                let payload = frame.get("payload").getOrThrow().asObject()
                @Expect(payload.get("url").getOrThrow().asString().getValue().startsWith("https://example.invalid/"), true)
            }
            let port = s5TemporaryPort()
            @Expect(port > 0 && port != 18080 && port != 18788 && port != 60271, true)
        })
    }
}

@Test
public class ServicePluginFlowUnexpectedExitTest {
    @TestCase
    public func bpS3N1NativeFullWindowUnexpectedExitRecoversWithoutRepeatedEffects(): Unit {
        resetServicePluginHostForTest()
        resetServicePluginGeneratedReplyStateForTest()
        @Expect(resetManagedStdioBrokerForTest(timeoutMs: 3000).ok, true)
        let ownedHomes = ArrayList<Path>()
        withServicePluginHostTestHome("s5-bp-native-unexpected-exit", { home: Path =>
            ownedHomes.add(home)
            let oldLogFile = Config.logFile
            let gate = S5GeneratedReplyGate()
            let effects = BpFormalEffects()
            let queue = home.join("bp-queue")
            var formallyStopped = false
            var pid: Int64 = 0
            var port: Int64 = 0
            try {
                let binary = bpFormalArtifact()
                let expectedDeliveries = bpFormalSeed(queue, 6)
                port = s5TemporaryPort()
                let stablePort = port
                let config = home.join("bp-config.json")
                s5WriteGcmConfig(config, home.join("bp-state.json"), queue, port, s5TemporaryPort())
                @Expect(registerServicePlugin(ServicePluginRegistration(s5GcmManifest(binary), configRef: ServicePluginConfigRef(
                    configPath: config.toString(), workingDirectory: binary.parent.toString()))).ok, true)
                setServicePluginSupervisorAutoStartForTest(false)
                bpFormalInstall(gate, effects)
                gate.release()
                setServicePluginBeforeCompletionAckHookForTest(Some({ _frameId: String => false }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 5000).ok, true)
                let initial = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                pid = initial.pid
                let capturedPid = pid
                let lease = home.join("service-plugin/runtime/gitcode-monitor").join("${initial.instanceId}.lease.json")
                @Expect(s5WaitUntil(10000, { => effects.snapshot()[0] == 2 && bpFormalCount(queue, "awaiting-host", expectedDeliveries) == 2 &&
                    bpFormalCompletedReceiptCount(queue, expectedDeliveries) == 2 &&
                    servicePluginDispatchSchedulerSnapshotForTest("gitcode-monitor").getOrThrow().settled }), true)
                let fullWindow = bpFormalHealthWindow(port)
                @Expect(fullWindow[0], 200)
                @Expect(fullWindow[1], 2)
                @Expect(fullWindow[2] > 0 && fullWindow[2] <= 524288, true)
                @Expect(bpFormalCount(queue, "pending", expectedDeliveries), 4)
                @Expect(bpFormalCount(queue, "processed", expectedDeliveries), 0)
                @Expect(effects.snapshot()[1], 0)
                // Ownership is checked immediately before signalling only this native child.
                let owned = capturedPid > 1 && getServicePluginSnapshot("gitcode-monitor").getOrThrow().pid == capturedPid &&
                    s5LeaseInt(lease, "pid") == capturedPid && s5LeaseInt(lease, "port") == port &&
                    s5LeaseString(lease, "state") == "running"
                @Expect(owned, true)
                if (!owned) { return }
                println("BP_NATIVE_CRASH_BEFORE count=${fullWindow[1]} bytes=${fullWindow[2]} pending=${bpFormalCount(queue, "pending", expectedDeliveries)} awaiting=${bpFormalCount(queue, "awaiting-host", expectedDeliveries)} receipts=${bpFormalCompletedReceiptCount(queue, expectedDeliveries)} effects=${effects.snapshot()[0]} duplicates=${effects.snapshot()[1]} pid=${capturedPid}")
                let killExit = executeWithOutput("kill", ["-KILL", "${capturedPid}"])[0]
                @Expect(killExit, 0)
                if (killExit != 0) { return }
                let childGone = s5WaitUntil(5000, { => s5PidGone(capturedPid) && s5CanBindPort(stablePort) })
                @Expect(childGone, true)
                if (!childGone) { return }
                // Let EOF ownership handling publish its actual state. Never race a
                // manual stop/reset against a still-running event-pump cleanup.
                let detachedPublished = s5WaitUntil(5000, { =>
                    let row = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                    managedStdioBroker().snapshot().ownerCount == 0 &&
                        servicePluginActiveIdentityForTest("gitcode-monitor").isNone() &&
                        row.status != "running" &&
                        (row.status == "cleanup_pending" || s5LeaseString(lease, "state") == "stopped")
                })
                let afterExit = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                println("BP_NATIVE_CRASH_OWNER_TERMINAL published=${detachedPublished} status=${afterExit.status} reason=${afterExit.degradedReason} leaseState=${s5LeaseString(lease, "state")} leasePidMatches=${s5LeaseInt(lease, "pid") == capturedPid} pidGone=${s5PidGone(capturedPid)} portReleased=${s5CanBindPort(port)} owners=${managedStdioBroker().snapshot().ownerCount} pendingCleanup=${servicePluginCleanupPendingCountForTest()}")
                @Expect(detachedPublished, true)
                if (!detachedPublished) { return }
                @Expect(s5LeaseInt(lease, "pid"), capturedPid)
                @Expect(s5LeaseString(lease, "sessionId"), initial.instanceId)
                let crashCleanup = stopServicePlugin("gitcode-monitor", reason: "bp-owned-unexpected-exit", timeoutMillis: 5000)
                println("BP_NATIVE_CRASH_FORMAL_CLEANUP ok=${crashCleanup.ok} status=${crashCleanup.status} port=${crashCleanup.portStatus} lease=${crashCleanup.leaseStatus} pidGone=${s5PidGone(capturedPid)} portReleased=${s5CanBindPort(port)} owners=${managedStdioBroker().snapshot().ownerCount}")
                // Record formal truth before reset/fallback. A stale lease must fail here.
                let cleanupTruth = crashCleanup.ok && crashCleanup.status == "stopped" &&
                    s5PidGone(capturedPid) && s5CanBindPort(port) &&
                    managedStdioBroker().snapshot().ownerCount == 0 && servicePluginCleanupPendingCountForTest() == 0 &&
                    s5LeaseString(lease, "state") == "stopped"
                @Expect(cleanupTruth, true)
                if (!cleanupTruth) { return }
                bpFormalExpectTerminalProof(queue, expectedDeliveries)
                // Keep the real host registry/broker so the next instance receives
                // a new session; only dispatcher memory dedupe is erased.
                resetServicePluginGeneratedReplyStateForTest()
                let dedupe = servicePluginEventDedupeSizesForTest()
                @Expect(dedupe[0], 0)
                @Expect(dedupe[1], 0)
                @Expect(dedupe[2], 0)
                @Expect(dedupe[3], 0)
                @Expect(bpFormalCompletedReceiptCount(queue, expectedDeliveries), 2)
                @Expect(effects.snapshot()[0], 2)
                bpFormalInstall(gate, effects)
                setServicePluginBeforeCompletionAckHookForTest(None<(String) -> Bool>)
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 5000).ok, true)
                let replacement = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                pid = replacement.pid
                @Expect(pid > 1 && pid != capturedPid, true)
                @Expect(replacement.instanceId != initial.instanceId, true)
                @Expect(s5LeaseString(lease, "state"), "stopped")
                let boundsViolated = AtomicBool(false)
                // Six sends need >=2.5s;15s includes startup/receipt/disk margins.
                @Expect(s5WaitUntil(15000, { =>
                    let health = bpFormalHealthWindow(stablePort)
                    if (health[0] == 200 && (health[1] < 0 || health[1] > 2 || health[2] < 0 || health[2] > 524288)) {
                        boundsViolated.store(true)
                    }
                    bpFormalCount(queue, "processed", expectedDeliveries) == 6
                }), true)
                @Expect(boundsViolated.load(), false)
                @Expect(effects.snapshot()[0], 6)
                @Expect(effects.snapshot()[1], 0)
                @Expect(bpFormalCount(queue, "pending", expectedDeliveries), 0)
                @Expect(bpFormalCount(queue, "processing", expectedDeliveries), 0)
                @Expect(bpFormalCount(queue, "awaiting-host", expectedDeliveries), 0)
                @Expect(bpFormalCount(queue, "dead-letter", expectedDeliveries), 0)
                let drained = bpFormalHealthWindow(port)
                println("BP_NATIVE_CRASH_RECOVERED processed=${bpFormalCount(queue, "processed", expectedDeliveries)} effects=${effects.snapshot()[0]} duplicates=${effects.snapshot()[1]} count=${drained[1]} bytes=${drained[2]} boundsViolated=${boundsViolated.load()}")
                let stopped = stopServicePlugin("gitcode-monitor", reason: "bp-unexpected-exit-recovered", timeoutMillis: 5000)
                @Expect(stopped.ok, true)
                @Expect(stopped.status, "stopped")
                @Expect(stopped.portStatus, "released")
                @Expect(stopped.leaseStatus, "stopped")
                let pidGone = s5PidGone(pid)
                let portReleased = s5CanBindPort(port)
                let owners = managedStdioBroker().snapshot().ownerCount
                println("BP_NATIVE_CRASH_FINAL_STOP ok=${stopped.ok} status=${stopped.status} pidGone=${pidGone} portReleased=${portReleased} owners=${owners}")
                let finalTruth = stopped.ok && stopped.status == "stopped" && stopped.portStatus == "released" &&
                    stopped.leaseStatus == "stopped" && pidGone && portReleased && owners == 0
                @Expect(finalTruth, true)
                formallyStopped = finalTruth
                if (!finalTruth) { return }
                bpFormalExpectTerminalProof(queue, expectedDeliveries)
            } finally {
                bpFormalReset(gate)
                if (!formallyStopped) { let _ = stopServicePlugin("gitcode-monitor", reason: "bp-unexpected-exit-fallback", timeoutMillis: 5000) }
                resetServicePluginHostForTest()
                @Expect(resetManagedStdioBrokerForTest(timeoutMs: 3000).ok, true)
                gatewayLoggingResetForTest()
                Config.logFile = oldLogFile
            }
        })
        @Expect(s5RemoveOwnedTempHome(ownedHomes[0]), true)
    }
}
