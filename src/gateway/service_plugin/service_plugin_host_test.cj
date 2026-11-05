package metis.gateway.service_plugin

import std.runtime.{getThreadCount, getBlockingThreadCount}

import metis.core.config.cliModelProviderCatalogDescriptors

import std.core.Duration
import std.env.getVariables
import std.env.getCommand
import std.env.removeVariable
import std.fs.OpenMode
import std.fs.copy
import std.io.InputStream
import std.posix.chmod
import stdx.encoding.json.*
import metis.core.config.MetisProcessEnvironmentLock
import metis.process.ManagedOwnedChild
import metis.process.managedStdioResolveNodeCommand
import metis.process.parseProcessInstanceIdentity
import metis.process.ProcessBirthIdentity
import metis.core.config.CliConfig
import metis.process.currentProcessInstanceIdentity
import metis.process.launchManagedRawChild
import metis.process.managedRecoveryInitialize
import metis.process.managedRecoveryLaunchOwned
import metis.process.managedRecoveryExecuteWithOutput
import metis.process.managedRecoveryProbeRecords
import metis.process.managedRecoveryStopOwnedChildren
import metis.process.shutdownManagedStdioBroker
import metis.process.observeProcessBirthIdentity
import metis.process.probeProcessBirthIdentity

import magic.config.Config
import metis.gateway.logging.gatewayLoggingResetForTest
import metis.process.{ManagedStdioOwnerSpec, managedStdioBroker, managedStdioResolveBrokerScriptPath, resetManagedStdioBrokerForTest}
import std.collection.*
import std.convert.Parsable
import std.env.{getProcessId, getVariable, setVariable}
import std.fs.{Directory, File, FileInfo, Path, SymbolicLink, canonicalize, exists, remove}
import std.net.{IPSocketAddress, TcpServerSocket}
import std.process.*
import std.sync.*
import std.time.*
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString, JsonValue}

private class ServicePluginTestGate {
    private let lock = Mutex()
    private var condition: Condition
    private var entered = false
    private var released = false

    init() {
        synchronized(this.lock) { this.condition = this.lock.condition() }
    }

    func enterAndWait(): Unit {
        synchronized(this.lock) {
            this.entered = true
            this.condition.notifyAll()
            while (!this.released) { this.condition.wait() }
        }
    }

    func awaitEntered(timeoutMs: Int64): Bool {
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
        synchronized(this.lock) {
            while (!this.entered) {
                let remaining = deadline - DateTime.now().toUnixTimeStamp().toMilliseconds()
                if (remaining <= 0) { return false }
                let _ = this.condition.wait(timeout: Duration.millisecond * remaining)
            }
            true
        }
    }

    func release(): Unit {
        synchronized(this.lock) {
            this.released = true
            this.condition.notifyAll()
        }
    }

    func signal(): Unit {
        synchronized(this.lock) {
            this.entered = true
            this.condition.notifyAll()
        }
    }
}

private class ServicePluginTestOnce {
    private let lock = Mutex()
    private var pending = true

    func take(): Bool {
        synchronized(this.lock) {
            if (!this.pending) { return false }
            this.pending = false
            true
        }
    }
}

private class ServicePluginTestCounter {
    private let lock = Mutex()
    private var value: Int64 = 0

    func increment(): Unit { synchronized(this.lock) { this.value++ } }

    func get(): Int64 { synchronized(this.lock) { this.value } }
}

private class ServicePluginBurstProbe {
    private let lock = Mutex()
    private var condition: Condition
    private var entered: Int64 = 0
    private var completed: Int64 = 0
    private var active: Int64 = 0
    private var maxActive: Int64 = 0
    private var releasePermits: Int64 = 0
    private let callsByEventId = HashMap<String, Int64>()

    init() {
        synchronized(this.lock) { this.condition = this.lock.condition() }
    }

    func enterAndWait(eventId: String): Unit {
        synchronized(this.lock) {
            this.entered++
            this.active++
            this.maxActive = max(this.maxActive, this.active)
            let previous = match (this.callsByEventId.get(eventId)) { case Some(value) => value case None => Int64(0) }
            this.callsByEventId[eventId] = previous + 1
            this.condition.notifyAll()
            while (this.releasePermits == 0) { this.condition.wait() }
            this.releasePermits--
            this.active--
            this.completed++
            this.condition.notifyAll()
        }
    }

    func release(count: Int64): Unit {
        synchronized(this.lock) {
            this.releasePermits += max(0, count)
            this.condition.notifyAll()
        }
    }

    func awaitEntered(expected: Int64, timeoutMs: Int64): Bool {
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
        synchronized(this.lock) {
            while (this.entered < expected) {
                let remaining = deadline - DateTime.now().toUnixTimeStamp().toMilliseconds()
                if (remaining <= 0) { return false }
                let _ = this.condition.wait(timeout: Duration.millisecond * remaining)
            }
            true
        }
    }

    func awaitCompleted(expected: Int64, timeoutMs: Int64): Bool {
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
        synchronized(this.lock) {
            while (this.completed < expected) {
                let remaining = deadline - DateTime.now().toUnixTimeStamp().toMilliseconds()
                if (remaining <= 0) { return false }
                let _ = this.condition.wait(timeout: Duration.millisecond * remaining)
            }
            true
        }
    }

    func snapshot(): (Int64, Int64, Int64, Int64) {
        synchronized(this.lock) { (this.entered, this.completed, this.active, this.maxActive) }
    }

    func callsFor(eventId: String): Int64 {
        synchronized(this.lock) { match (this.callsByEventId.get(eventId)) { case Some(value) => value case None => Int64(0) } }
    }
}

private class ServicePluginEventLedger {
    private let lock = Mutex()
    private var condition: Condition
    private let counts = HashMap<String, Int64>()
    private var total: Int64 = 0

    init() {
        synchronized(this.lock) { this.condition = this.lock.condition() }
    }

    func record(eventId: String): Unit {
        synchronized(this.lock) {
            let previous = match (this.counts.get(eventId)) { case Some(value) => value case None => Int64(0) }
            this.counts[eventId] = previous + 1
            this.total++
            this.condition.notifyAll()
        }
    }

    func recordMatching(text: String, eventIds: Array<String>): Unit {
        for (eventId in eventIds) {
            if (text.contains(eventId)) {
                this.record(eventId)
                return
            }
        }
    }

    func awaitTotal(expected: Int64, timeoutMs: Int64): Bool {
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
        synchronized(this.lock) {
            while (this.total < expected) {
                let remaining = deadline - DateTime.now().toUnixTimeStamp().toMilliseconds()
                if (remaining <= 0) { return false }
                let _ = this.condition.wait(timeout: Duration.millisecond * remaining)
            }
            true
        }
    }

    func countFor(eventId: String): Int64 {
        synchronized(this.lock) { match (this.counts.get(eventId)) { case Some(value) => value case None => Int64(0) } }
    }

    func totalCount(): Int64 { synchronized(this.lock) { this.total } }
}

@Test
public class ServicePluginHostTest {
    @TestCase
    public func s3H1PressureAttemptRetriesWithoutCompletionAndRecoveredAttemptCompletesOnce(): Unit {
        withIsolatedServicePluginHostTestHome("s3-h1-pressure-retry", { home: Path =>
            let eventId = "gitcode:Cangjie/community:issue:s3-h1"
            let deliveryId = "s3-h1-delivery"
            let tokenA = "s3-h1-attempt-a"
            let tokenB = "s3-h1-attempt-b"
            let ackMarker = home.join("acks.marker")
            let writebackMarker = home.join("writebacks.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let oldWriteback = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
            let handlerAttempts = ServicePluginEventLedger()
            let pressureResults = ServicePluginEventLedger()
            let healthyResults = ServicePluginEventLedger()
            let deliveries = ServicePluginEventLedger()
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
            setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebackMarker.toString())
            try {
                let responseLine = this.gitCodeWritebackResponseLine(correlationId: "__METIS_CORRELATION__").replace("__METIS_CORRELATION__", "'\"$corr\"'")
                let script = "printf '%s\\n' '${this.gitCodeInitLine()}'; printf '%s\\n' '${this.gitCodeAcceptedEventLine(eventId: eventId, frameId: "s3-h1-a", deliveryId: deliveryId, attemptToken: tokenA)}'; retried=0; " +
                    "while IFS= read -r request; do case \"$request\" in *emitCapabilityEvent*) printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_MARKER_PATH\"; if printf '%s\\n' \"$request\" | grep -Eq '\"phase\"[[:space:]]*:[[:space:]]*\"admission\"' && printf '%s\\n' \"$request\" | grep -Eq '\"status\"[[:space:]]*:[[:space:]]*\"retry\"' && printf '%s\\n' \"$request\" | grep -Eq '\"attemptToken\"[[:space:]]*:[[:space:]]*\"${tokenA}\"'; then if [ \"$retried\" = \"0\" ]; then printf '%s\\n' '${this.gitCodeAcceptedEventLine(eventId: eventId, frameId: "s3-h1-b", deliveryId: deliveryId, attemptToken: tokenB)}'; retried=1; fi; fi; if printf '%s\\n' \"$request\" | grep -Eq '\"phase\"[[:space:]]*:[[:space:]]*\"completion\"'; then ${this.gitCodeCompletionConfirmShell(expectedAttempt: tokenB)}; fi;; " +
                    "*gitcode.writeback.apply_result*) printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH\"; corr=$(printf '%s\\n' \"$request\" | sed -n 's/.*\\\"correlationId\\\"[[:space:]]*:[[:space:]]*\\\"\\([^\\\"]*\\)\\\".*/\\1/p'); printf '%s\\n' '${responseLine}';; *\\\"method\\\":\\\"stop\\\"*) break;; esac; done"
                this.registerGitCodeStdioScript(script)
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "s3-h1", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    handlerAttempts.record(event.eventId)
                    if (handlerAttempts.totalCount() == 1) {
                        pressureResults.record(event.eventId)
                        ServicePluginGeneratedReplyResult(false, status: "model_memory_pressure")
                    } else {
                        healthyResults.record(event.eventId)
                        ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                    }
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    deliveries.recordMatching(text, [eventId])
                    ServicePluginEventDeliveryResult(true, "sent")
                }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForAckMarkerCount(ackMarker, "admission", "accepted", 1, attemptToken: tokenA), true)
                @Expect(this.waitForAckMarkerCount(ackMarker, "admission", "retry", 1, attemptToken: tokenA), true)
                @Expect(this.ackMarkerCounts(ackMarker, "completion", "completed", attemptToken: tokenA)[0], 0)
                @Expect(this.waitForAckMarkerCount(ackMarker, "admission", "accepted", 1, attemptToken: tokenB), true)
                @Expect(this.waitForAckMarkerCount(ackMarker, "completion", "completed", 1, attemptToken: tokenB, timeoutMillis: 5000), true)
                @Expect(deliveries.awaitTotal(1, 5000), true)
                @Expect(this.waitForDispatchCounts("gitcode-monitor", 0, 0, timeoutMillis: 3000), true)
                @Expect(this.ackMarkerCounts(ackMarker, "admission", "accepted", attemptToken: tokenA)[0], 1)
                @Expect(this.ackMarkerCounts(ackMarker, "admission", "retry", attemptToken: tokenA)[0], 1)
                @Expect(this.ackMarkerCounts(ackMarker, "admission", "accepted", attemptToken: tokenB)[0], 1)
                @Expect(this.ackMarkerCounts(ackMarker, "completion", "completed", attemptToken: tokenB)[0], 1)
                @Expect(this.ackMarkerCounts(ackMarker, "admission", "accepted", attemptToken: tokenA)[1], 0)
                @Expect(handlerAttempts.totalCount(), 2)
                @Expect(pressureResults.totalCount(), 1)
                @Expect(healthyResults.totalCount(), 1)
                @Expect(deliveries.countFor(eventId), 1)
                @Expect(this.textFileCount(writebackMarker, eventId), 1)
                @Expect(servicePluginWebhookReceiptStore().state("gitcode-monitor", deliveryId, eventId), "missing")
            } finally {
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                match (oldWriteback) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "") }
            }
        })
    }

    private func withIsolatedServicePluginHostTestHome<T>(label: String, block: (Path) -> T): T {
        resetServicePluginHostForTest()
        @Expect(resetManagedStdioBrokerForTest(timeoutMs: 2000).ok, true)
        withServicePluginHostTestHome(label, { home: Path =>
            let oldLogFile = Config.logFile
            try {
                block(home)
            } finally {
                resetServicePluginHostForTest()
                @Expect(resetManagedStdioBrokerForTest(timeoutMs: 2000).ok, true)
                gatewayLoggingResetForTest()
                Config.logFile = oldLogFile
                @Expect(Config.logFile, oldLogFile)
            }
        })
    }

    private func sampleManifest(): ServicePluginManifest {
        let caps = ArrayList<ServiceCapabilityRecord>()
        caps.add(ServiceCapabilityRecord("sample.monitor.status", "controlAction"))
        caps.add(ServiceCapabilityRecord("sample.monitor.scan_once", "controlAction"))
        caps.add(ServiceCapabilityRecord("sample.event.accepted", "event"))
        caps.add(ServiceCapabilityRecord("sample.agent.request", "agentRequest", requiredHostApis: ["host.agent.invoke"]))
        ServicePluginManifest(
            schema: METIS_SERVICE_PLUGIN_SCHEMA,
            pluginId: "sample-service",
            displayName: "Sample Service",
            kind: "service",
            protocolVersion: "1.0",
            entryCommand: "sample-plugin",
            hasConfigSchema: true,
            capabilityDeclarations: caps
        )
    }

    @TestCase
    public func hbBrN4DispatchFencedMarkerIsStrictOrderedAndFailureIsolated(): Unit {
        let markerKey = "METIS_TEST_SERVICE_PLUGIN_DISPATCH_FENCED_MARKER"
        let serviceKey = "METIS_TEST_SERVICE_PLUGIN_DISPATCH_FENCED_SERVICE_ID"
        let nonceKey = "METIS_TEST_SERVICE_PLUGIN_DISPATCH_FENCED_NONCE"
        let previous = [(markerKey, getVariable(markerKey)), (serviceKey, getVariable(serviceKey)),
            (nonceKey, getVariable(nonceKey))]
        try {
            this.withIsolatedServicePluginHostTestHome("hb-br-n4-default", { home: Path =>
                let marker = home.join("dispatch-fenced.json")
                setVariable(markerKey, "")
                setVariable(serviceKey, "")
                setVariable(nonceKey, "")
                this.registerStdio("{}")
                @Expect(ensureRegisteredServicePluginStarted("stdio-service", startupTimeoutMs: 1000).ok, true)
                let stopped = shutdownServicePluginHost(reason: "hb-br-n4-default", timeoutMillis: 3000)
                @Expect(stopped.ok, true)
                @Expect(exists(marker), false)
            })
            this.withIsolatedServicePluginHostTestHome("hb-br-n4-marker", { home: Path =>
                let marker = home.join("dispatch-fenced.json")
                let nonce = "hb-br-n4-marker"
                let counter = home.join("launch-count.txt")
                setVariable(markerKey, marker.toString())
                setVariable(serviceKey, "gitcode-monitor")
                setVariable(nonceKey, nonce)
                this.registerGitCodeStdioScript(this.gitCodeCountingLeaseScript(counter, 18184))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                let identity = servicePluginActiveIdentityForTest("gitcode-monitor")
                @Expect(identity.isSome(), true)
                @Expect(dropServicePluginActiveProcessForTest("gitcode-monitor", stopProcess: true), true)
                @Expect(this.waitForFile(marker, timeoutMillis: 3000), true)
                @Expect(servicePluginActiveIdentityForTest("gitcode-monitor").isNone(), true)
                let stopped = shutdownServicePluginHost(reason: "hb-br-n4-marker", timeoutMillis: 3000)
                @Expect(stopped.ok, true)
                @Expect(exists(marker), true)
                let root = try {
                    JsonValue.fromStr(String.fromUtf8(File.readFrom(marker))).asObject()
                } catch (_: Exception) {
                    JsonObject()
                }
                @Expect(root.get("schema").getOrThrow().asString().getValue(), "metis.servicePlugin.dispatchFenced.v1")
                @Expect(root.get("serviceId").getOrThrow().asString().getValue(), "gitcode-monitor")
                @Expect(root.get("ownerId").getOrThrow().asString().getValue(), identity.getOrThrow()[0])
                @Expect(root.get("generation").getOrThrow().asInt().getValue(), identity.getOrThrow()[1])
                @Expect(root.get("testNonce").getOrThrow().asString().getValue(), nonce)
                @Expect(root.get("fenced").getOrThrow().asBool().getValue(), true)
                let modeResult = executeWithOutput("/usr/bin/stat", ["-f", "%Lp", marker.toString()])
                let markerMode = try { String.fromUtf8(modeResult[1]).trimAscii() } catch (_: Exception) { "" }
                @Expect(modeResult[0], 0)
                @Expect(markerMode, "600")
            })
            this.withIsolatedServicePluginHostTestHome("hb-br-n4-invalid", { home: Path =>
                let parentFile = home.join("regular-file")
                File.writeTo(parentFile, "x".toArray())
                setVariable(markerKey, parentFile.join("dispatch-fenced.json").toString())
                setVariable(serviceKey, "stdio-service")
                setVariable(nonceKey, "hb-br-n4-invalid")
                this.registerStdio("{}")
                @Expect(ensureRegisteredServicePluginStarted("stdio-service", startupTimeoutMs: 1000).ok, true)
                let stopped = shutdownServicePluginHost(reason: "hb-br-n4-invalid", timeoutMillis: 3000)
                @Expect(stopped.ok, true)
            })
        } finally {
            for ((key, value) in previous) {
                match (value) {
                    case Some(text) => setVariable(key, text)
                    case None => setVariable(key, "")
                }
            }
        }
    }

    private func registerSample(grants!: Array<String> = ["host.agent.invoke", "host.audit.append"]): ServicePluginRegistrationResult {
        resetServicePluginHostForTest()
        registerServicePlugin(ServicePluginRegistration(
            sampleManifest(),
            configRef: ServicePluginConfigRef(configPath: "/redacted/config.json", secretRef: "gcm-token"),
            grants: grants
        ))
    }

    private func stdioManifest(responsePayload: String, initPayload!: String = "{ \"ok\": true, \"status\": \"ready\" }"): ServicePluginManifest {
        let caps = ArrayList<ServiceCapabilityRecord>()
        caps.add(ServiceCapabilityRecord("stdio.monitor.status", "controlAction"))
        this.stdioManifestFromScript(this.stdioScript(responsePayload, initPayload: initPayload), caps: caps)
    }

    private func stdioManifestFromScript(script: String, caps!: ArrayList<ServiceCapabilityRecord> = ArrayList<ServiceCapabilityRecord>()): ServicePluginManifest {
        if (caps.size == 0) {
            caps.add(ServiceCapabilityRecord("stdio.monitor.status", "controlAction"))
        }
        ServicePluginManifest(
            schema: METIS_SERVICE_PLUGIN_SCHEMA,
            pluginId: "stdio-service",
            displayName: "Stdio Service",
            kind: "service",
            protocolVersion: "1.0",
            entryCommand: "/bin/zsh",
            entryArgs: ["-lc", script],
            hasConfigSchema: true,
            capabilityDeclarations: caps
        )
    }

    private func stdioScript(responsePayload: String, initPayload!: String): String {
        let initLine = "{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"stdio-service\",\"method\":\"initialize\",\"payload\":${initPayload}}"
        let responseLine = this.stdioInvokeResponseLine(responsePayload)
        this.stdioScriptWithInvokeLines(initLine, [responseLine])
    }

    private func stdioScriptWithInvokeLines(initLine: String, invokeLines: Array<String>): String {
        var script = "printf '%s\\n' '${initLine}'; IFS= read -r request; corr=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"correlationId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p')"
        for (line in invokeLines) {
            let dynamicLine = line.replace("__METIS_CORRELATION__", "'\"$corr\"'")
            script += "; printf '%s\\n' '${dynamicLine}'"
        }
        script += "; read ignored || true"
        script
    }

    private func stdioScriptWithInvokeBatches(initLine: String, invokeBatches: Array<Array<String>>): String {
        var script = "printf '%s\\n' '${initLine}'"
        for (batch in invokeBatches) {
            script += "; IFS= read -r request; corr=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"correlationId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p')"
            for (line in batch) {
                let dynamicLine = line.replace("__METIS_CORRELATION__", "'\"$corr\"'")
                script += "; printf '%s\\n' '${dynamicLine}'"
            }
        }
        script += "; read ignored || true"
        script
    }

    private func stdioInvokeResponseLine(payload: String, serviceId!: String = "stdio-service", capabilityId!: String = "stdio.monitor.status", correlationId!: String = "__METIS_CORRELATION__"): String {
        "{\"type\":\"response\",\"frameId\":\"invoke-1\",\"serviceId\":\"${serviceId}\",\"method\":\"invokeCapability\",\"capabilityId\":\"${capabilityId}\",\"correlationId\":\"${correlationId}\",\"payload\":${payload}}"
    }

    private func gitCodeStdioManifestFromScript(script: String): ServicePluginManifest {
        let caps = ArrayList<ServiceCapabilityRecord>()
        caps.add(ServiceCapabilityRecord("gitcode.event.accepted", "event"))
        caps.add(ServiceCapabilityRecord("gitcode.writeback.apply_result", "controlAction"))
        ServicePluginManifest(
            schema: METIS_SERVICE_PLUGIN_SCHEMA,
            pluginId: "gitcode-monitor",
            displayName: "GitCode Monitor",
            kind: "service",
            protocolVersion: "1.0",
            entryCommand: "/bin/zsh",
            entryArgs: ["-lc", script],
            hasConfigSchema: true,
            capabilityDeclarations: caps
        )
    }

    private func registerGitCodeStdioScript(script: String): Unit {
        resetServicePluginHostForTest()
        let result = registerServicePlugin(ServicePluginRegistration(this.gitCodeStdioManifestFromScript(script)))
        @Expect(result.ok, true)
    }

    private func gitCodeInitLine(): String {
        "{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"gitcode-monitor\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}"
    }

    private func gitCodeAcceptedEventLine(eventId!: String = "gitcode:Cangjie/community:issue:3", frameId!: String = "event-accepted-1", deliveryId!: String = "", attemptToken!: String = "", frameCorrelationId!: String = ""): String {
        let effectiveCorrelation = if (!frameCorrelationId.isEmpty()) { frameCorrelationId } else { attemptToken }
        let correlation = if (effectiveCorrelation.isEmpty()) { "" } else { ",\"correlationId\":\"${effectiveCorrelation}\"" }
        let delivery = if (deliveryId.isEmpty()) { "" } else { ",\"deliveryId\":\"${deliveryId}\"" }
        let attempt = if (attemptToken.isEmpty()) { "" } else { ",\"attemptToken\":\"${attemptToken}\"" }
        "{\"type\":\"event\",\"frameId\":\"${frameId}\",\"serviceId\":\"gitcode-monitor\",\"method\":\"emitCapabilityEvent\",\"capabilityId\":\"gitcode.event.accepted\"${correlation},\"payload\":{\"jobId\":\"webhook-${eventId}\",\"eventId\":\"${eventId}\"${delivery}${attempt},\"repo\":\"Cangjie/community\",\"kind\":\"issue\",\"number\":\"3\",\"title\":\"Issue 3\",\"url\":\"https://gitcode.com/Cangjie/community/issues/3\",\"author\":\"external-user\",\"content\":\"please review\"}}"
    }

    private func gitCodeBurstEventIds(label: String, count: Int64): Array<String> {
        let rows = ArrayList<String>()
        for (index in 0..count) {
            rows.add("gitcode:Cangjie/community:issue:${label}-${index}:burst-end")
        }
        rows.toArray()
    }

    private func gitCodeCompletionConfirmShell(expectedAttempt!: String = "", successStatus!: String = "host_completed"): String {
        let condition = if (expectedAttempt.isEmpty()) { "true" } else { "[ \"$attempt\" = \"${expectedAttempt}\" ]" }
        "case \"$request\" in *completed*) corr=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"correlationId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'); delivery=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"deliveryId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'); event=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"eventId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'); attempt=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"attemptToken\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'); if ${condition}; then confirm_ok=true; confirm_status=${successStatus}; else confirm_ok=false; confirm_status=stale_attempt; fi; printf '{\"type\":\"response\",\"frameId\":\"confirm-response\",\"serviceId\":\"gitcode-monitor\",\"method\":\"emitCapabilityEvent\",\"capabilityId\":\"gitcode.event.accepted\",\"correlationId\":\"%s\",\"payload\":{\"ok\":%s,\"status\":\"%s\",\"protocolVersion\":\"1.0\",\"deliveryId\":\"%s\",\"eventId\":\"%s\",\"attemptToken\":\"%s\"}}\\n' \"$corr\" \"$confirm_ok\" \"$confirm_status\" \"$delivery\" \"$event\" \"$attempt\";; esac"
    }

    private func gitCodeBurstScript(eventIds: Array<String>, legacyCorrelation!: Bool = false): String {
        var script = "printf '%s\\n' '${this.gitCodeInitLine()}'"
        var frameSequence: Int64 = 0
        for (eventId in eventIds) {
            frameSequence++
            script += "; printf '%s\\n' '${this.gitCodeAcceptedEventLine(eventId: eventId, frameId: "s0-event-${frameSequence}", frameCorrelationId: if (legacyCorrelation) { "corr-webhook-${frameSequence}" } else { "" })}'"
        }
        let responseLine = this.gitCodeWritebackResponseLine(
            frameId: "s0-writeback-response",
            correlationId: "__METIS_CORRELATION__",
            replyUrl: "https://gitcode.com/Cangjie/community/issues/3#s0"
        ).replace("__METIS_CORRELATION__", "'\"$corr\"'")
        script += "; while IFS= read -r request; do case \"$request\" in *gitcode.writeback.apply_result*) corr=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"correlationId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'); case \"$request\" in"
        for (eventId in eventIds) {
            script += " *${eventId}*) printf '%s\\n' '${eventId}' >> \"$METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH\";;"
        }
        script += " esac; printf '%s\\n' '${responseLine}';; *\\\"method\\\":\\\"stop\\\"*) break;; esac; done"
        script
    }

    private func gitCodeAckBurstScript(eventIds: Array<String>, retryLastOnQueueFull!: Bool = false): String {
        var script = "printf '%s\\n' '${this.gitCodeInitLine()}'"
        var sequence: Int64 = 0
        for (eventId in eventIds) {
            sequence++
            script += "; printf '%s\\n' '${this.gitCodeAcceptedEventLine(eventId: eventId, frameId: "s1c-event-${sequence}", deliveryId: "delivery-${sequence}", attemptToken: "attempt-${sequence}-1")}'"
        }
        let responseLine = this.gitCodeWritebackResponseLine(correlationId: "__METIS_CORRELATION__").replace("__METIS_CORRELATION__", "'\"$corr\"'")
        if (retryLastOnQueueFull) { script += "; retry_pending=0; completion_count=0" }
        script += "; while IFS= read -r request; do case \"$request\" in *emitCapabilityEvent*) printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_MARKER_PATH\"; ${this.gitCodeCompletionConfirmShell()}"
        if (retryLastOnQueueFull && eventIds.size > 0) {
            let last = eventIds[eventIds.size - 1]
            script += "; case \"$request\" in *queue_full*) if [ \"$retry_pending\" = \"0\" ]; then retry_pending=1; fi;; *completed*) completion_count=$((completion_count + 1)); if [ \"$retry_pending\" = \"1\" ] && [ \"$completion_count\" = \"3\" ]; then printf '%s\\n' '${this.gitCodeAcceptedEventLine(eventId: last, frameId: "s1c-retry", deliveryId: "delivery-${eventIds.size}", attemptToken: "attempt-${eventIds.size}-2")}'; retry_pending=0; fi;; esac"
        }
        script += ";; *gitcode.writeback.apply_result*) printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH\"; corr=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"correlationId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'); printf '%s\\n' '${responseLine}';; *\\\"method\\\":\\\"stop\\\"*) break;; esac; done"
        script
    }

    private func gitCodeSingleAckScript(eventId: String, deliveryId: String, attemptToken: String, frameId: String): String {
        let responseLine = this.gitCodeWritebackResponseLine(correlationId: "__METIS_CORRELATION__").replace("__METIS_CORRELATION__", "'\"$corr\"'")
        "printf '%s\\n' '${this.gitCodeInitLine()}'; printf '%s\\n' '${this.gitCodeAcceptedEventLine(eventId: eventId, frameId: frameId, deliveryId: deliveryId, attemptToken: attemptToken)}'; " +
            "while IFS= read -r request; do case \"$request\" in *emitCapabilityEvent*) printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_MARKER_PATH\"; ${this.gitCodeCompletionConfirmShell(expectedAttempt: attemptToken)};; " +
            "*gitcode.writeback.apply_result*) printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH\"; corr=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"correlationId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'); printf '%s\\n' '${responseLine}';; " +
            "*\\\"method\\\":\\\"stop\\\"*) break;; esac; done"
    }

    private func gitCodeMissingAdmissionScript(eventId: String, deliveryId: String, attemptToken: String): String {
        let completion = this.gitCodeCompletionConfirmShell(expectedAttempt: attemptToken)
        let guarded = completion.replace("confirm_ok=true; confirm_status=host_completed;", "if [ \"$admission_count\" -ge 2 ]; then confirm_ok=true; confirm_status=host_completed; else confirm_ok=false; confirm_status=completion_before_admission; fi;")
        return this.gitCodeSingleAckScript(eventId, deliveryId, attemptToken, "bp-missing-admission")
            .replace("while IFS=", "admission_count=0; while IFS=")
            .replace(completion, "if printf '%s\\n' \"$request\" | grep -Eq '\"phase\"[[:space:]]*:[[:space:]]*\"admission\"'; then admission_count=$((admission_count + 1)); fi; ${guarded}")
    }

    private func gitCodeDropFirstCompletionResponseScript(eventId: String, deliveryId: String, attemptToken: String): String {
        let responseLine = this.gitCodeWritebackResponseLine(correlationId: "__METIS_CORRELATION__").replace("__METIS_CORRELATION__", "'\"$corr\"'")
        "printf '%s\\n' '${this.gitCodeInitLine()}'; printf '%s\\n' '${this.gitCodeAcceptedEventLine(eventId: eventId, frameId: "c05-event", deliveryId: deliveryId, attemptToken: attemptToken)}'; confirm_count=0; " +
            "while IFS= read -r request; do case \"$request\" in *emitCapabilityEvent*) printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_MARKER_PATH\"; case \"$request\" in *completed*) confirm_count=$((confirm_count + 1)); if [ \"$confirm_count\" -gt 1 ]; then ${this.gitCodeCompletionConfirmShell(expectedAttempt: attemptToken, successStatus: "already_completed")}; fi;; esac;; " +
            "*gitcode.writeback.apply_result*) printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH\"; corr=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"correlationId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'); printf '%s\\n' '${responseLine}';; " +
            "*\\\"method\\\":\\\"stop\\\"*) break;; esac; done"
    }

    private func gitCodeFirstLaunchAckBurstScript(eventIds: Array<String>, launchMarker: Path): String {
        var script = "printf '%s\\n' '${this.gitCodeInitLine()}'; launch_count=$(cat '${launchMarker.toString()}' 2>/dev/null || printf 0); launch_count=$((launch_count + 1)); printf '%s' \"$launch_count\" > '${launchMarker.toString()}'; if [ \"$launch_count\" = \"1\" ]; then"
        var sequence: Int64 = 0
        for (eventId in eventIds) {
            sequence++
            script += "; printf '%s\\n' '${this.gitCodeAcceptedEventLine(eventId: eventId, frameId: "s2-old-event-${sequence}", deliveryId: "s2-old-delivery-${sequence}", attemptToken: "s2-old-attempt-${sequence}")}'"
        }
        let responseLine = this.gitCodeWritebackResponseLine(correlationId: "__METIS_CORRELATION__").replace("__METIS_CORRELATION__", "'\"$corr\"'")
        script += "; fi; while IFS= read -r request; do case \"$request\" in *emitCapabilityEvent*) printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_MARKER_PATH\"; ${this.gitCodeCompletionConfirmShell()};; *gitcode.writeback.apply_result*) printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH\"; corr=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"correlationId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'); printf '%s\\n' '${responseLine}';; *\\\"method\\\":\\\"stop\\\"*) break;; esac; done"
        script
    }

    private func textFileCount(path: Path, text: String): Int64 {
        if (!exists(path)) { return 0 }
        var count: Int64 = 0
        for (line in this.readTextFile(path).split("\n")) { if (line.contains(text)) { count++ } }
        count
    }

    private func waitForTextFileCount(path: Path, text: String, expected: Int64, timeoutMillis!: Int64 = 3000): Bool {
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMillis
        while (DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
            if (this.textFileCount(path, text) >= expected) { return true }
            sleep(Duration.millisecond * 10)
        }
        this.textFileCount(path, text) >= expected
    }

    private func ackMarkerCounts(path: Path, phase: String, status: String, attemptToken!: String = ""): (Int64, Int64) {
        if (!exists(path)) { return (0, 0) }
        var matched: Int64 = 0
        var invalid: Int64 = 0
        for (line in this.readTextFile(path).split("\n")) {
            if (line.trimAscii().isEmpty()) { continue }
            let decoded = decodeServiceFrame(line)
            if (!decoded.ok || !(decoded.frame.frameType == "response" || decoded.frame.frameType == "request") || decoded.frame.method != "emitCapabilityEvent" ||
                decoded.frame.capabilityId != "gitcode.event.accepted") { invalid++; continue }
            let parsed = parseServiceEventAckPayload(decoded.frame.payload)
            if (!parsed.ok || (parsed.ack.phase == "admission" && parsed.ack.attemptToken != decoded.frame.correlationId) ||
                (parsed.ack.phase == "completion" && decoded.frame.correlationId.isEmpty())) { invalid++; continue }
            if (parsed.ack.phase == phase && parsed.ack.status == status && (attemptToken.isEmpty() || parsed.ack.attemptToken == attemptToken)) { matched++ }
        }
        (matched, invalid)
    }

    private func waitForAckMarkerCount(path: Path, phase: String, status: String, expected: Int64, attemptToken!: String = "", timeoutMillis!: Int64 = 3000): Bool {
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMillis
        while (DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
            if (this.ackMarkerCounts(path, phase, status, attemptToken: attemptToken)[0] >= expected) { return true }
            sleep(Duration.millisecond * 10)
        }
        this.ackMarkerCounts(path, phase, status, attemptToken: attemptToken)[0] >= expected
    }

    private func markerCountForEvent(path: Path, eventId: String): Int64 {
        if (!exists(path)) { return 0 }
        var count: Int64 = 0
        for (line in this.readTextFile(path).split("\n")) {
            if (line.trimAscii() == eventId) { count++ }
        }
        count
    }

    private func gitCodeWritebackResponseLine(
        frameId!: String = "writeback-response-1",
        correlationId!: String = "corr-gitcode-monitor-1-gitcode.writeback.apply_result",
        replyUrl!: String = "https://gitcode.com/Cangjie/community/issues/3#note_1"
    ): String {
        "{\"type\":\"response\",\"frameId\":\"${frameId}\",\"serviceId\":\"gitcode-monitor\",\"method\":\"invokeCapability\",\"capabilityId\":\"gitcode.writeback.apply_result\",\"correlationId\":\"${correlationId}\",\"payload\":{\"ok\":true,\"status\":\"posted\",\"posted\":true,\"replyUrl\":\"${replyUrl}\"}}"
    }

    private func gitCodeWritebackMaintainerEmailResponseLine(
        frameId!: String = "writeback-response-1",
        correlationId!: String = "corr-gitcode-monitor-1-gitcode.writeback.apply_result",
        replyUrl!: String = "https://gitcode.com/Cangjie/community/issues/3#note_1"
    ): String {
        "{\"type\":\"response\",\"frameId\":\"${frameId}\",\"serviceId\":\"gitcode-monitor\",\"method\":\"invokeCapability\",\"capabilityId\":\"gitcode.writeback.apply_result\",\"correlationId\":\"${correlationId}\",\"payload\":{\"ok\":true,\"status\":\"posted\",\"posted\":true,\"replyUrl\":\"${replyUrl}\",\"maintainerMentionAppended\":true,\"teamLeaderCount\":1,\"codeownerCount\":2,\"contextSource\":\"store\",\"emailNotificationStatus\":\"sent\",\"emailSentCount\":2}}"
    }

    private func gitCodeHeartbeatLine(frameId!: String = "heartbeat-1"): String {
        "{\"type\":\"heartbeat\",\"frameId\":\"${frameId}\",\"serviceId\":\"gitcode-monitor\",\"method\":\"heartbeat\",\"payload\":{\"ok\":true,\"status\":\"alive\"}}"
    }

    private func gitCodeWritebackResponderScript(responseLine: String, includeUnrelatedFrames!: Bool = false): String {
        let dynamicResponseLine = responseLine.replace("__METIS_CORRELATION__", "'\"$corr\"'")
        let heartbeatLine = this.gitCodeHeartbeatLine()
        let unrelatedResponse = this.gitCodeWritebackResponseLine(frameId: "unrelated-response", correlationId: "corr-unrelated")
        var script = "while IFS= read -r request; do case \"$request\" in *gitcode.writeback.apply_result*) corr=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"correlationId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'); "
        if (includeUnrelatedFrames) {
            script += "printf '%s\\n' '${heartbeatLine}'; printf '%s\\n' '${unrelatedResponse}'; "
        }
        script += "printf '%s\\n' '${dynamicResponseLine}'; break;; esac; done; read ignored || true"
        script
    }

    private func gitCodeReentrantWritebackScript(includeUnrelatedFrames!: Bool = false): String {
        let initLine = this.gitCodeInitLine()
        let eventLine = this.gitCodeAcceptedEventLine()
        let responseLine = this.gitCodeWritebackResponseLine(correlationId: "__METIS_CORRELATION__")
        "printf '%s\\n' '${initLine}'; printf '%s\\n' '${eventLine}'; ${this.gitCodeWritebackResponderScript(responseLine, includeUnrelatedFrames: includeUnrelatedFrames)}"
    }

    private func gitCodeWritebackThenNoiseScript(): String {
        let initLine = this.gitCodeInitLine()
        let eventLine = this.gitCodeAcceptedEventLine(eventId: "gitcode:Cangjie/community:issue:cleanup-fence")
        "printf '%s\\n' '${initLine}'; printf '%s\\n' '${eventLine}'; while [ ! -f \"$METIS_STDIO_FIXTURE_MARKER_PATH\" ]; do sleep 0.01; done; for i in 1 2 3 4 5 6 7 8 9; do printf 'WARN cleanup noise %s\\n' \"$i\"; done; trap '' TERM HUP; while true; do sleep 1; done"
    }

    private func gitCodeIgnoringTermDispatchScript(): String {
        let initLine = this.gitCodeInitLine()
        let eventLine = this.gitCodeAcceptedEventLine(eventId: "gitcode:Cangjie/community:issue:cleanup-retry")
        let leaseLine = "printf '{\"state\":\"running\",\"status\":\"running\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"%s\",\"pid\":%s,\"parentPid\":%s,\"bindHost\":\"127.0.0.1\",\"port\":18189,\"startedAtMs\":1000,\"lastHeartbeatMs\":1000}\\n' \"$METIS_SERVICE_PLUGIN_SESSION_ID\" \"$$\" \"$METIS_SERVICE_PLUGIN_PARENT_PID\" > \"$METIS_SERVICE_PLUGIN_LEASE_PATH\""
        "printf '%s\n' '${initLine}'; ${leaseLine}; printf '%s\n' '${eventLine}'; trap '' TERM HUP; while true; do sleep 1; done"
    }

    private func gitCodeMaintainerEmailWritebackScript(): String {
        let initLine = this.gitCodeInitLine()
        let eventLine = this.gitCodeAcceptedEventLine(eventId: "gitcode:Cangjie/community:issue:maintainer-email")
        let responseLine = this.gitCodeWritebackMaintainerEmailResponseLine(correlationId: "__METIS_CORRELATION__")
        "printf '%s\\n' '${initLine}'; printf '%s\\n' '${eventLine}'; ${this.gitCodeWritebackResponderScript(responseLine)}"
    }

    private func gitCodeNoWritebackResponseScript(): String {
        let initLine = this.gitCodeInitLine()
        let eventLine = this.gitCodeAcceptedEventLine(eventId: "gitcode:Cangjie/community:issue:timeout", frameId: "event-timeout")
        let heartbeatLine = this.gitCodeHeartbeatLine(frameId: "heartbeat-during-timeout")
        "printf '%s\\n' '${initLine}'; printf '%s\\n' '${eventLine}'; read request; printf '%s\\n' '${heartbeatLine}'; read ignored || true"
    }

    private func waitForMessage(messages: ArrayList<String>, lock: Mutex, timeoutMillis!: Int64 = 2000): Bool {
        var waited: Int64 = 0
        while (waited < timeoutMillis) {
            let hasMessage = synchronized(lock) { messages.size > 0 }
            if (hasMessage) {
                return true
            }
            sleep(Duration.millisecond * 25)
            waited += 25
        }
        synchronized(lock) { messages.size > 0 }
    }

    private func waitForDispatchCounts(serviceId: String, accepted: Int64, futures: Int64, timeoutMillis!: Int64 = 2000): Bool {
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMillis
        while (DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
            let matched = match (servicePluginDispatchCountsForTest(serviceId)) {
                case Some(counts) => counts[2] == accepted && counts[3] == futures
                case None => false
            }
            if (matched) { return true }
            sleep(Duration.millisecond * 10)
        }
        match (servicePluginDispatchCountsForTest(serviceId)) {
            case Some(counts) => counts[2] == accepted && counts[3] == futures
            case None => false
        }
    }

    private func waitForDispatchScheduler(serviceId: String, matches: (ServicePluginDispatchSchedulerSnapshotForTest) -> Bool, timeoutMillis!: Int64 = 3000): Option<ServicePluginDispatchSchedulerSnapshotForTest> {
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMillis
        while (DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
            match (servicePluginDispatchSchedulerSnapshotForTest(serviceId)) {
                case Some(snapshot) => if (matches(snapshot)) { return Some(snapshot) }
                case None => ()
            }
            sleep(Duration.millisecond * 10)
        }
        None<ServicePluginDispatchSchedulerSnapshotForTest>
    }

    private func firstMessage(messages: ArrayList<String>, lock: Mutex): String {
        synchronized(lock) {
            if (messages.size == 0) { "" } else { messages[0] }
        }
    }

    private func waitForHeartbeat(serviceId: String, timeoutMillis!: Int64 = 1000): Bool {
        var waited: Int64 = 0
        while (waited < timeoutMillis) {
            match (getServicePluginSnapshot(serviceId)) {
                case Some(snapshot) =>
                    if (snapshot.lastHeartbeatAtMillis >= 0) {
                        return true
                    }
                case None => ()
            }
            sleep(Duration.millisecond * 25)
            waited += 25
        }
        match (getServicePluginSnapshot(serviceId)) {
            case Some(snapshot) => snapshot.lastHeartbeatAtMillis >= 0
            case None => false
        }
    }

    private func waitForFile(path: Path, timeoutMillis!: Int64 = 1000): Bool {
        var waited: Int64 = 0
        while (waited < timeoutMillis) {
            if (exists(path)) {
                return true
            }
            sleep(Duration.millisecond * 25)
            waited += 25
        }
        exists(path)
    }

    private func waitForGitCodeLease(home: Path, instanceId!: String = "gitcode-monitor-1", timeoutMillis!: Int64 = 1000): Bool {
        this.waitForFile(
            home.join("service-plugin").join("runtime").join("gitcode-monitor").join("${instanceId}.lease.json"),
            timeoutMillis: timeoutMillis
        )
    }

    private func settleServiceOwnerCleanup(serviceId: String, timeoutMillis!: Int64 = 2000): (Bool, String, Bool, Bool) {
        var retryStatus = "not_needed"
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMillis
        var retryNeeded = false
        while (DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
            let pidCleared = match (getServicePluginSnapshot(serviceId)) {
                case Some(snapshot) => snapshot.pid == 0
                case None => true
            }
            if (pidCleared && managedStdioBroker().snapshot().ownerCount == 0) { return (retryNeeded, retryStatus, true, true) }
            if (!retryNeeded && servicePluginCleanupPendingCountForTest() > 0) {
                retryNeeded = true
                let remaining = max(1, deadline - DateTime.now().toUnixTimeStamp().toMilliseconds())
                retryStatus = stopServicePlugin(serviceId, reason: "test_cleanup_retry", timeoutMillis: remaining).status
            }
            sleep(Duration.millisecond * 10)
        }
        let pidCleared = match (getServicePluginSnapshot(serviceId)) {
            case Some(snapshot) => snapshot.pid == 0
            case None => true
        }
        (retryNeeded, retryStatus, pidCleared, managedStdioBroker().snapshot().ownerCount == 0)
    }

    private func waitForSupervisorRestart(serviceId: String, minRestartCount: Int64, timeoutMillis!: Int64 = 2000): Bool {
        var waited: Int64 = 0
        while (waited < timeoutMillis) {
            match (getServicePluginSnapshot(serviceId)) {
                case Some(snapshot) =>
                    if (snapshot.supervisorRestartCount >= minRestartCount) {
                        return true
                    }
                case None => ()
            }
            sleep(Duration.millisecond * 25)
            waited += 25
        }
        match (getServicePluginSnapshot(serviceId)) {
            case Some(snapshot) => snapshot.supervisorRestartCount >= minRestartCount
            case None => false
        }
    }

    private func waitForSnapshotReason(serviceId: String, reason: String, timeoutMillis!: Int64 = 2000): Bool {
        var waited: Int64 = 0
        while (waited < timeoutMillis) {
            match (getServicePluginSnapshot(serviceId)) {
                case Some(snapshot) =>
                    if (snapshot.degradedReason == reason || snapshot.lastError.contains(reason)) {
                        return true
                    }
                case None => ()
            }
            sleep(Duration.millisecond * 25)
            waited += 25
        }
        match (getServicePluginSnapshot(serviceId)) {
            case Some(snapshot) => snapshot.degradedReason == reason || snapshot.lastError.contains(reason)
            case None => false
        }
    }

    private func readCounterFile(path: Path): Int64 {
        try { Int64.parse(String.fromUtf8(File.readFrom(path)).trimAscii()) } catch (_: Exception) { 0 }
    }

    private func readTextFile(path: Path): String {
        try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { "" }
    }

    private func waitForPidGone(pid: Int64, timeoutMillis!: Int64 = 3000): Bool {
        var waited: Int64 = 0
        while (waited < timeoutMillis) {
            let (exitCode, _, _) = executeWithOutput("kill", ["-0", "${pid}"])
            if (exitCode != 0) { return true }
            sleep(Duration.millisecond * 25)
            waited += 25
        }
        let (exitCode, _, _) = executeWithOutput("kill", ["-0", "${pid}"])
        exitCode != 0
    }

    private func processGroupId(pid: Int64): Int64 {
        let (exitCode, stdout, _) = executeWithOutput("ps", ["-o", "pgid=", "-p", "${pid}"])
        if (exitCode != 0) { return 0 }
        try { Int64.parse(String.fromUtf8(stdout).trimAscii()) } catch (_: Exception) { 0 }
    }

    private func waitForProcessGroupGone(pgid: Int64, timeoutMillis!: Int64 = 3000): Bool {
        if (pgid <= 0) { return false }
        var waited: Int64 = 0
        while (waited < timeoutMillis) {
            let (exitCode, _, _) = executeWithOutput("kill", ["-0", "-${pgid}"])
            if (exitCode != 0) { return true }
            sleep(Duration.millisecond * 25)
            waited += 25
        }
        let (exitCode, _, _) = executeWithOutput("kill", ["-0", "-${pgid}"])
        exitCode != 0
    }

    private func gitCodeLeaseScript(port: Int64, includeEndpoint!: Bool = true, stopUpdatesLease!: Bool = true, keepAlive!: Bool = true): String {
        let endpoint = if (includeEndpoint) { ",\"bindHost\":\"127.0.0.1\",\"port\":${port}" } else { "" }
        var script = "printf '%s\\n' '${this.gitCodeInitLine()}'; printf '{\"state\":\"running\",\"status\":\"running\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"%s\",\"pid\":%s,\"parentPid\":%s${endpoint},\"startedAtMs\":1000,\"lastHeartbeatMs\":1000}\\n' \"$METIS_SERVICE_PLUGIN_SESSION_ID\" \"$$\" \"$METIS_SERVICE_PLUGIN_PARENT_PID\" > \"$METIS_SERVICE_PLUGIN_LEASE_PATH\""
        if (!keepAlive) {
            return script
        }
        if (stopUpdatesLease) {
            let stoppedLeaseWrite = "printf '{\"state\":\"stopped\",\"status\":\"stopped\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"%s\",\"pid\":%s,\"parentPid\":%s${endpoint},\"startedAtMs\":1000,\"lastHeartbeatMs\":1000}\\n' \"$METIS_SERVICE_PLUGIN_SESSION_ID\" \"$$\" \"$METIS_SERVICE_PLUGIN_PARENT_PID\" > \"$METIS_SERVICE_PLUGIN_LEASE_PATH\""
            script += "; metis_stop_lease() { ${stoppedLeaseWrite}; }; trap 'metis_stop_lease; exit 0' TERM HUP INT; while read line; do metis_stop_lease; exit 0; done"
        } else {
            script += "; trap '' TERM; while true; do read -t 1 ignored || true; done"
        }
        script
    }

    private func gitCodeCountingLeaseScript(
        counterPath: Path,
        port: Int64,
        includeEndpoint!: Bool = true,
        writeLease!: Bool = true,
        stopUpdatesLease!: Bool = true,
        keepAlive!: Bool = true,
        firstLaunchNoise!: Bool = false,
        firstLaunchExit!: Bool = false
    ): String {
        let endpoint = if (includeEndpoint) { ",\"bindHost\":\"127.0.0.1\",\"port\":${port}" } else { "" }
        let runningLease = "printf '{\"state\":\"running\",\"status\":\"running\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"%s\",\"pid\":%s,\"parentPid\":%s${endpoint},\"startedAtMs\":1000,\"lastHeartbeatMs\":1000}\\n' \"$METIS_SERVICE_PLUGIN_SESSION_ID\" \"$$\" \"$METIS_SERVICE_PLUGIN_PARENT_PID\" > \"$METIS_SERVICE_PLUGIN_LEASE_PATH\""
        let stoppedLease = "printf '{\"state\":\"stopped\",\"status\":\"stopped\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"%s\",\"pid\":%s,\"parentPid\":%s${endpoint},\"startedAtMs\":1000,\"lastHeartbeatMs\":1000}\\n' \"$METIS_SERVICE_PLUGIN_SESSION_ID\" \"$$\" \"$METIS_SERVICE_PLUGIN_PARENT_PID\" > \"$METIS_SERVICE_PLUGIN_LEASE_PATH\""
        var script = "count_file='${counterPath.toString()}'; count=$(cat \"$count_file\" 2>/dev/null || printf 0); count=$((count + 1)); printf '%s' \"$count\" > \"$count_file\"; printf '%s\\n' '${this.gitCodeInitLine()}'; "
        if (writeLease) {
            script += "${runningLease}; "
        }
        if (firstLaunchNoise) {
            script += "if [ \"$count\" = \"1\" ]; then for i in 1 2 3 4 5 6 7 8 9 10; do printf 'WARN noisy stdout %s Authorization: Bearer secret-value\\n' \"$i\"; done; exit 0; fi; "
        }
        if (firstLaunchExit) {
            script += "if [ \"$count\" = \"1\" ]; then exit 0; fi; "
        }
        if (!keepAlive) {
            return script + "exit 0"
        }
        if (stopUpdatesLease && writeLease) {
            script += "metis_stop_lease() { ${stoppedLease}; }; trap 'metis_stop_lease; exit 0' TERM HUP INT; while read line; do metis_stop_lease; exit 0; done"
        } else {
            script += "trap '' TERM; while true; do read -t 1 ignored || true; done"
        }
        script
    }

    private func gitCodeCountingRestartLeaseScript(
        counterPath: Path,
        firstPort: Int64,
        restartPort: Int64,
        restartWritesLease!: Bool = true,
        delayRestartLease!: Bool = false
    ): String {
        let firstEndpoint = ",\"bindHost\":\"127.0.0.1\",\"port\":${firstPort}"
        let restartEndpoint = ",\"bindHost\":\"127.0.0.1\",\"port\":${restartPort}"
        let firstRunningLease = "printf '{\"state\":\"running\",\"status\":\"running\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"%s\",\"pid\":%s,\"parentPid\":%s${firstEndpoint},\"startedAtMs\":1000,\"lastHeartbeatMs\":1000}\\n' \"$METIS_SERVICE_PLUGIN_SESSION_ID\" \"$$\" \"$METIS_SERVICE_PLUGIN_PARENT_PID\" > \"$METIS_SERVICE_PLUGIN_LEASE_PATH\""
        let restartRunningLease = "printf '{\"state\":\"running\",\"status\":\"running\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"%s\",\"pid\":%s,\"parentPid\":%s${restartEndpoint},\"startedAtMs\":1000,\"lastHeartbeatMs\":1000}\\n' \"$METIS_SERVICE_PLUGIN_SESSION_ID\" \"$$\" \"$METIS_SERVICE_PLUGIN_PARENT_PID\" > \"$METIS_SERVICE_PLUGIN_LEASE_PATH\""
        let stoppedLease = "printf '{\"state\":\"stopped\",\"status\":\"stopped\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"%s\",\"pid\":%s,\"parentPid\":%s${firstEndpoint},\"startedAtMs\":1000,\"lastHeartbeatMs\":1000}\\n' \"$METIS_SERVICE_PLUGIN_SESSION_ID\" \"$$\" \"$METIS_SERVICE_PLUGIN_PARENT_PID\" > \"$METIS_SERVICE_PLUGIN_LEASE_PATH\""
        var script = "count_file='${counterPath.toString()}'; count=$(cat \"$count_file\" 2>/dev/null || printf 0); count=$((count + 1)); printf '%s' \"$count\" > \"$count_file\"; printf '%s\\n' '${this.gitCodeInitLine()}'; "
        if (restartWritesLease) {
            let restartDelay = if (delayRestartLease) { "sleep 0.15; " } else { "" }
            script += "if [ \"$count\" = \"1\" ]; then ${firstRunningLease}; else ${restartDelay}${restartRunningLease}; fi; "
        } else {
            script += "if [ \"$count\" = \"1\" ]; then ${firstRunningLease}; fi; "
        }
        script += "metis_stop_lease() { ${stoppedLease}; }; trap 'metis_stop_lease; exit 0' TERM HUP INT; while read line; do metis_stop_lease; exit 0; done"
        script
    }

    private func writeGitCodeLease(home: Path, instanceId: String, state: String, pid: Int64): Path {
        this.writeGitCodeLeaseWithDetails(home, instanceId, state, pid, parentPid: getProcessId(), port: 18080)
    }

    private func writeGitCodeLeaseWithDetails(home: Path, instanceId: String, state: String, pid: Int64, parentPid!: Int64, port!: Int64): Path {
        let dir = home.join("service-plugin").join("runtime").join("gitcode-monitor")
        Directory.create(dir, recursive: true)
        let leasePath = dir.join("${instanceId}.lease.json")
        File.writeTo(
            leasePath,
            ("{\"state\":\"${state}\",\"status\":\"${state}\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"${instanceId}\",\"pid\":${pid},\"parentPid\":${parentPid},\"bindHost\":\"127.0.0.1\",\"port\":${port}}").toArray()
        )
        leasePath
    }

    private func registerStdio(responsePayload: String, initPayload!: String = "{ \"ok\": true, \"status\": \"ready\" }"): Unit {
        resetServicePluginHostForTest()
        let result = registerServicePlugin(ServicePluginRegistration(this.stdioManifest(responsePayload, initPayload: initPayload)))
        @Expect(result.ok, true)
    }

    private func registerStdioScript(script: String): Unit {
        resetServicePluginHostForTest()
        let result = registerServicePlugin(ServicePluginRegistration(this.stdioManifestFromScript(script)))
        @Expect(result.ok, true)
    }

    private func brokerServiceFixturePath(): String {
        Path(managedStdioResolveBrokerScriptPath()).parent.join("gateway-stdio-hanging-service.mjs").toString()
    }

    private func registerBrokerServiceFixture(
        mode: String,
        pluginId!: String = "stdio-service",
        capabilityId!: String = "stdio.monitor.status",
        resetHost!: Bool = true,
        enabled!: Bool = true
    ): Unit {
        if (resetHost) { resetServicePluginHostForTest() }
        let caps = ArrayList<ServiceCapabilityRecord>()
        caps.add(ServiceCapabilityRecord(capabilityId, "controlAction"))
        if (mode.startsWith("gcm")) {
            caps.add(ServiceCapabilityRecord(
                if (pluginId == "gitcode-monitor") { "gitcode.event.accepted" } else { "stdio.event.accepted" },
                "event"
            ))
        }
        let manifest = ServicePluginManifest(
            schema: METIS_SERVICE_PLUGIN_SCHEMA,
            pluginId: pluginId,
            displayName: "Broker Stdio Service",
            kind: "service",
            protocolVersion: "1.0",
            entryCommand: "node",
            entryArgs: [this.brokerServiceFixturePath(), mode],
            hasConfigSchema: true,
            capabilityDeclarations: caps
        )
        let result = registerServicePlugin(ServicePluginRegistration(manifest, enabled: enabled))
        @Expect(result.ok, true)
    }

    private func repeatText(text: String, count: Int64): String {
        var out = ""
        for (_ in 0..count) {
            out += text
        }
        out
    }

    @TestCase
    public func registerListAndGetServicePluginSnapshot(): Unit {
        let result = registerSample()
        @Expect(result.ok, true)
        @Expect(result.serviceId, "sample-service")
        let rows = listServicePlugins()
        @Expect(rows.size, 1)
        @Expect(rows[0].serviceId, "sample-service")
        @Expect(rows[0].configSummary.contains("present"), true)
        @Expect(rows[0].configSummary.contains("/redacted"), false)
        match (getServicePluginSnapshot("sample-service")) {
            case Some(snapshot) =>
                @Expect(snapshot.capabilityIds.size, 4)
                @Expect(renderServicePluginDiagnostics(snapshot).contains("sample.monitor.status"), true)
            case None => @Expect(true, false)
        }
    }

    @TestCase
    public func registerRejectsDuplicateAndInvalidManifest(): Unit {
        let result = registerSample()
        @Expect(result.ok, true)
        let duplicate = registerServicePlugin(ServicePluginRegistration(sampleManifest()))
        @Expect(duplicate.ok, false)
        @Expect(duplicate.status, "conflict")

        resetServicePluginHostForTest()
        let bad = registerServicePlugin(ServicePluginRegistration(ServicePluginManifest(pluginId: "bad", kind: "channel")))
        @Expect(bad.ok, false)
        @Expect(bad.status, "setup-required")
    }

    @TestCase
    public func capabilityRouteAcceptsUnknownBusinessIdAndRejectsMissingGrant(): Unit {
        let _ = registerSample()
        let extra = registerCapabilityRoute("sample-service", ServiceCapabilityRecord("release.monitor.scan", "controlAction"))
        @Expect(extra.ok, true)
        @Expect(resolveCapabilityRoute("release.monitor.scan", CapabilityCaller()).ok, true)

        let denied = resolveCapabilityRoute("sample.agent.request", CapabilityCaller(grantedHostApis: []))
        @Expect(denied.ok, false)
        @Expect(denied.status, "missing_grant")
        let allowed = resolveCapabilityRoute("sample.agent.request", CapabilityCaller(grantedHostApis: ["host.agent.invoke"]))
        @Expect(allowed.ok, true)
        @Expect(resolveCapabilityRoute("missing.capability", CapabilityCaller()).status, "capability_missing")
    }

    @TestCase
    public func invokeCapabilityReturnsQueuedRedactedPayloadAndLimitErrors(): Unit {
        let _ = registerSample()
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            CapabilityInvokeResult(true, "ok", serviceId: "sample-service", capabilityId: request.capabilityId, payload: redactServicePayload(request.payload).text)
        }))
        let ok = invokeRegisteredCapability(CapabilityInvokeRequest("sample.monitor.scan_once", payload: "{\"repo\":\"safe\"}"))
        @Expect(ok.ok, true)
        @Expect(ok.status, "ok")
        @Expect(ok.payload.contains("safe"), true)

        let secret = invokeRegisteredCapability(CapabilityInvokeRequest("sample.monitor.scan_once", payload: "{\"token\":\"secret\"}"))
        @Expect(secret.ok, true)
        @Expect(secret.payload.contains("secret"), false)

        let missing = invokeRegisteredCapability(CapabilityInvokeRequest("missing", payload: "{}"))
        @Expect(missing.ok, false)
        @Expect(missing.status, "capability_missing")
        setServicePluginCapabilityInvokerForTest(None)
    }

    @TestCase
    public func lifecycleStartStopRestartAndStatus(): Unit {
        let _ = registerSample()
        @Expect(queryServicePluginStatus("sample-service").running, false)
        let started = startServicePlugin("sample-service", context: ServiceStartContext(nowMillis: 7))
        @Expect(started.ok, true)
        @Expect(started.status, "registered")
        @Expect(queryServicePluginStatus("sample-service").running, false)
        let first = started.instanceId

        let stopped = stopServicePlugin("sample-service", reason: "test")
        @Expect(stopped.ok, true)
        @Expect(stopped.stateFlushed, true)
        @Expect(queryServicePluginStatus("sample-service").status, "stopped")

        let restarted = restartServicePlugin("sample-service", reason: "test")
        @Expect(restarted.ok, true)
        @Expect(restarted.previousInstanceId, first)
        @Expect(restarted.instanceId == first, false)
    }

    @TestCase
    public func stdioProcessReceivesLeaseEnvironmentAndTracksPid(): Unit {
        let stamp = DateTime.now().toUnixTimeStamp().toNanoseconds()
        let captureName = "metis-service-plugin-env-${stamp}.txt"
        let capturePath = Path("/private/tmp").join(captureName)
        let captureIsSymlink = try { FileInfo(capturePath).isSymbolicLink() } catch (_: Exception) { false }
        let captureOwned = stamp > 0 && !exists(capturePath) && !captureIsSymlink &&
            capturePath.toString() == "/private/tmp/${captureName}" && capturePath.fileName == captureName &&
            capturePath.parent.toString() == "/private/tmp" && canonicalize(capturePath.parent).toString() == "/private/tmp"
        @Expect(captureOwned, true)
        if (!captureOwned) { throw Exception("service plugin environment capture path is not an absent owned file") }
        let initLine = "{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"stdio-service\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}"
        let script = "printf '%s\\n' \"$METIS_SERVICE_PLUGIN_SESSION_ID|$METIS_SERVICE_PLUGIN_LEASE_PATH|$METIS_SERVICE_PLUGIN_PARENT_PID\" > '${capturePath.toString()}'; printf '%s\\n' '${initLine}'; read ignored || true"
        try {
            this.registerStdioScript(script)
            let started = ensureRegisteredServicePluginStarted("stdio-service", startupTimeoutMs: 2000)
            @Expect(started.ok, true)
            @Expect(this.waitForFile(capturePath, timeoutMillis: 2000), true)
            let captured = String.fromUtf8(File.readFrom(capturePath)).trimAscii()
            let parts = captured.split("|")
            @Expect(parts.size, 3)
            @Expect(parts[0], "stdio-service-1")
            @Expect(parts[1].contains("/service-plugin/runtime/stdio-service/stdio-service-1.lease.json"), true)
            @Expect(try { Int64.parse(parts[2]) > 0 } catch (_: Exception) { false }, true)
            match (getServicePluginSnapshot("stdio-service")) {
                case Some(snapshot) => @Expect(snapshot.pid > 0, true)
                case None => @Expect(true, false)
            }
            let stopped = stopServicePlugin("stdio-service", reason: "test")
            @Expect(stopped.ok, true)
        } finally {
            try {
                resetServicePluginHostForTest()
            } finally {
                let captureExists = exists(capturePath)
                let captureLink = try { FileInfo(capturePath).isSymbolicLink() } catch (_: Exception) { false }
                if (captureExists || captureLink) {
                    let captureInfo = FileInfo(capturePath)
                    let removable = captureExists && captureInfo.isRegular() && !captureInfo.isSymbolicLink() &&
                        canonicalize(capturePath).toString() == capturePath.normalize().toString()
                    @Expect(removable, true)
                    if (!removable) { throw Exception("service_plugin_environment_capture_cleanup_identity_invalid") }
                    remove(capturePath)
                }
                let remains = exists(capturePath) || try { FileInfo(capturePath).isSymbolicLink() } catch (_: Exception) { false }
                @Expect(remains, false)
                if (remains) { throw Exception("service_plugin_environment_capture_cleanup_failed") }
            }
        }
    }

    @TestCase
    public func tP5MetisEnvInjectionForGitCodeMonitorStartupPrerequisites(): Unit {
        // T-P5 Metis-side env injection coverage.
        withIsolatedServicePluginHostTestHome("service-plugin-p5-gcm-env", { _home: Path =>
            let capturePath = Path("/tmp/metis-gcm-service-plugin-env-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.txt")
            try { remove(capturePath, recursive: true) } catch (_: Exception) { () }
            let initLine = this.gitCodeInitLine()
            let script = "printf '%s\\n' \"$METIS_SERVICE_PLUGIN_SESSION_ID|$METIS_SERVICE_PLUGIN_LEASE_PATH|$METIS_SERVICE_PLUGIN_PARENT_PID\" > '${capturePath.toString()}'; printf '%s\\n' '${initLine}'; read ignored || true"
            this.registerGitCodeStdioScript(script)
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 2000)
                @Expect(started.ok, true)
                @Expect(this.waitForFile(capturePath, timeoutMillis: 2000), true)
                let captured = String.fromUtf8(File.readFrom(capturePath)).trimAscii()
                let parts = captured.split("|")
                @Expect(parts.size, 3)
                @Expect(parts[0], "gitcode-monitor-1")
                @Expect(parts[1].contains("/service-plugin/runtime/gitcode-monitor/gitcode-monitor-1.lease.json"), true)
                @Expect(try { Int64.parse(parts[2]) > 0 } catch (_: Exception) { false }, true)
            } finally {
                resetServicePluginHostForTest()
                try { remove(capturePath, recursive: true) } catch (_: Exception) { () }
            }
        })
    }

    @TestCase
    public func tP4N001StartupFailsFastWhenRunningLeaseOwnerIsAlive(): Unit {
        // METIS-ORPHAN-U-001, T-P4-N-001, T-P7-E2E-006 Metis-side prerequisite.
        withIsolatedServicePluginHostTestHome("service-plugin-p4-stale-running-lease", { home: Path =>
            let launchMarker = home.join("gcm-launch-marker.txt")
            let _ = this.writeGitCodeLease(home, "gitcode-monitor-old", "running", getProcessId())
            let script = "printf started > '${launchMarker.toString()}'; printf '%s\\n' '${this.gitCodeInitLine()}'; read ignored || true"
            this.registerGitCodeStdioScript(script)
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, false)
                @Expect(started.status, "stale_lease_before_start")
                @Expect(started.diagnostic.contains("stale_lease_before_start"), true)
                @Expect(exists(launchMarker), false)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "degraded")
                        @Expect(snapshot.degradedReason, "stale_lease_before_start")
                        @Expect(snapshot.pid, 0)
                    case None => @Expect(true, false)
                }
            } finally {
                resetServicePluginHostForTest()
            }

        })
    }

    @TestCase
    public func metisOrphanB001StartupFailsFastWhenOrphanLeaseOwnerIsAlive(): Unit {
        // METIS-ORPHAN-B-001.
        withIsolatedServicePluginHostTestHome("service-plugin-orphan-live-lease", { home: Path =>
            let launchMarker = home.join("gcm-launch-marker.txt")
            let _ = this.writeGitCodeLeaseWithDetails(home, "gitcode-monitor-orphan", "orphan_detected", getProcessId(), parentPid: getProcessId(), port: 18080)
            let script = "printf started > '${launchMarker.toString()}'; printf '%s\\n' '${this.gitCodeInitLine()}'; read ignored || true"
            this.registerGitCodeStdioScript(script)
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, false)
                @Expect(started.status, "orphan_lease_alive_before_start")
                @Expect(started.diagnostic.contains("orphan_lease_alive_before_start"), true)
                @Expect(started.diagnostic.contains("pid=${getProcessId()}"), true)
                @Expect(started.diagnostic.contains("port=18080"), true)
                @Expect(exists(launchMarker), false)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "degraded")
                        @Expect(snapshot.degradedReason, "orphan_lease_alive_before_start")
                        @Expect(snapshot.pid, 0)
                    case None => @Expect(true, false)
                }
            } finally {
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func metisOrphanB002OrphanLeaseWithMissingPidDoesNotBlockStart(): Unit {
        // METIS-ORPHAN-B-002.
        withIsolatedServicePluginHostTestHome("service-plugin-orphan-missing-pid", { home: Path =>
            let launchMarker = home.join("gcm-launch-marker.txt")
            let _ = this.writeGitCodeLeaseWithDetails(home, "gitcode-monitor-orphan", "orphan_detected", 0, parentPid: getProcessId(), port: 18080)
            let script = "printf started > '${launchMarker.toString()}'; printf '%s\\n' '${this.gitCodeInitLine()}'; read ignored || true"
            this.registerGitCodeStdioScript(script)
            let portOwnerProbeCalls = ServicePluginTestCounter()
            setServicePluginPortOwnerProbeForTest(Some({ port: Int64, pid: Int64 =>
                portOwnerProbeCalls.increment()
                @Expect(port, 18080)
                @Expect(pid, 0)
                false
            }))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(started.status, "running")
                @Expect(this.waitForFile(launchMarker, timeoutMillis: 1000), true)
                @Expect(portOwnerProbeCalls.get() > 0, true)
            } finally {
                try {
                    let _ = stopServicePlugin("gitcode-monitor", reason: "test", timeoutMillis: 1000)
                } finally {
                    setServicePluginPortOwnerProbeForTest(None)
                    resetServicePluginHostForTest()
                }
            }
        })
    }

    @TestCase
    public func tP4P001StoppedOldLeaseDoesNotBlockNewGitCodeMonitorStart(): Unit {
        // T-P4-P-001, T-P7-E2E-006 Metis-side restart prerequisite.
        withIsolatedServicePluginHostTestHome("service-plugin-p4-stopped-old-lease", { home: Path =>
            let launchMarker = home.join("gcm-launch-marker.txt")
            let _ = this.writeGitCodeLease(home, "gitcode-monitor-old", "stopped", getProcessId())
            let script = "printf started > '${launchMarker.toString()}'; printf '%s\\n' '${this.gitCodeInitLine()}'; read ignored || true"
            this.registerGitCodeStdioScript(script)
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForFile(launchMarker, timeoutMillis: 1000), true)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "running")
                        @Expect(snapshot.pid > 0, true)
                    case None => @Expect(true, false)
                }
            } finally {
                let _ = stopServicePlugin("gitcode-monitor", reason: "test", timeoutMillis: 1000)
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tP4U001GracefulStopReportsExitedAndVerifiesStoppedLease(): Unit {
        // T-P4-U-001.
        withIsolatedServicePluginHostTestHome("service-plugin-p4-graceful-stop", { _home: Path =>
            let script = "printf '%s\\n' '${this.gitCodeInitLine()}'; while read line; do printf '{\"state\":\"stopped\",\"status\":\"stopped\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"%s\",\"pid\":%s,\"parentPid\":%s}\\n' \"$METIS_SERVICE_PLUGIN_SESSION_ID\" \"$$\" \"$METIS_SERVICE_PLUGIN_PARENT_PID\" > \"$METIS_SERVICE_PLUGIN_LEASE_PATH\"; exit 0; done"
            this.registerGitCodeStdioScript(script)
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                let stopped = stopServicePlugin("gitcode-monitor", reason: "test", timeoutMillis: 3000)
                @Expect(stopped.ok, true)
                @Expect(stopped.status, "stopped")
                @Expect(stopped.diagnostic.contains("lease_stopped"), true)
                @Expect(stopped.diagnostic.contains("still_alive"), false)
                @Expect(stopped.diagnostic.contains("lease_not_stopped_after_stop"), false)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "stopped")
                        @Expect(snapshot.pid, 0)
                    case None => @Expect(true, false)
                }
            } finally {
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func bpS3N1SupervisorRetryAfterInitialFinalizeDeadlineWithoutFuture(): Unit {
        withIsolatedServicePluginHostTestHome("exited-r-s-retry", { home: Path =>
            let port = 20000 + DateTime.now().toUnixTimeStamp().toNanoseconds() % 30000
            let script = this.gitCodeLeaseScript(port).replace(
                "while read line; do metis_stop_lease; exit 0; done",
                "while IFS= read -r request; do case \"$request\" in *\\\"method\\\":\\\"stop\\\"*) metis_stop_lease; exit 0;; esac; done")
            this.registerGitCodeStdioScript(script)
            setServicePluginSupervisorAutoStartForTest(false)
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true, intervalMs: 1000,
                healthTimeoutMs: 100, failureThreshold: 1, restartCooldownMs: 1000))
            let firstFinalize = ServicePluginTestOnce()
            setServicePluginCleanupFinalizeHookForTest(Some({ _service: String, _token: Int64 =>
                if (firstFinalize.take()) { sleep(Duration.millisecond * 5) }
            }))
            setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeout: Int64 => (Int64(1), "", "") }))
            setServicePluginHealthzProbeForTest(Some({ _url: String, _timeout: Int64 => ServicePluginHealthzProbeResult(true, statusCode: 200) }))
            try {
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let before = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                let oldLeasePath = home.join("service-plugin").join("runtime").join("gitcode-monitor").join("${before.instanceId}.lease.json")
                let leaseDeadline = MonoTime.now() + Duration.second
                var leaseRead = servicePluginReadHistoricalLeaseStrict(oldLeasePath)
                while (leaseRead.evidence.isNone() && MonoTime.now() < leaseDeadline) {
                    sleep(Duration.millisecond * 5)
                    leaseRead = servicePluginReadHistoricalLeaseStrict(oldLeasePath)
                }
                @Expect(leaseRead.status, "ok")
                let lease = leaseRead.evidence.getOrThrow()
                @Expect(lease.pid, before.pid)
                @Expect(lease.parentPid, Int64(getProcessId()))
                @Expect(lease.state, "running")
                @Expect(executeWithOutput("/bin/kill", ["-KILL", before.pid.toString()])[0], 0)
                @Expect(this.waitForPidGone(before.pid), true)
                @Expect(this.waitForSnapshotReason("gitcode-monitor", "cleanup_pending", timeoutMillis: 5000), true)
                @Expect(servicePluginCleanupPendingCountForTest(), 1)
                @Expect(servicePluginReadHistoricalLeaseStrict(oldLeasePath).evidence.getOrThrow().state, "running")
                setServicePluginCleanupFinalizeHookForTest(None<(String, Int64) -> Unit>)
                let recovered = runServicePluginSupervisorTickForTest("gitcode-monitor")
                @Expect(recovered.recovered, true)
                let after = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(after.status, "running")
                @Expect(after.pid > 0 && after.pid != before.pid, true)
                @Expect(after.instanceId != before.instanceId, true)
                @Expect(after.supervisorRestartCount, 1)
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(servicePluginReadHistoricalLeaseStrict(oldLeasePath).evidence.getOrThrow().state, "stopped")
                @Expect(runServicePluginSupervisorTickForTest("gitcode-monitor").recovered, false)
                @Expect(getServicePluginSnapshot("gitcode-monitor").getOrThrow().pid, after.pid)
                let stopped = stopServicePlugin("gitcode-monitor", reason: "exited-r-s-complete", timeoutMillis: 3000)
                @Expect(stopped.ok, true)
                @Expect(this.waitForPidGone(after.pid), true)
            } finally {
                setServicePluginCleanupFinalizeHookForTest(None<(String, Int64) -> Unit>)
                setServicePluginPortReleaseCommandForTest(None<(Int64, Int64, Int64) -> (Int64, String, String)>)
                setServicePluginHealthzProbeForTest(None<(String, Int64) -> ServicePluginHealthzProbeResult>)
            }
        })
    }

    private func r2UnusedListenerPort(): Int64 {
        var port: Int64 = 0
        try (socket = TcpServerSocket(bindAt: 0u16)) {
            socket.bind()
            port = Int64((socket.localAddress as IPSocketAddress).getOrThrow().port)
        }
        port
    }

    private func r3StopPendingHandoff(expireDeadline: Bool, blockDispatch: Bool): Unit {
        withIsolatedServicePluginHostTestHome("r3-stop-late-pending-${expireDeadline}-${blockDispatch}", { home: Path =>
            let counter = home.join("launch-count")
            let release = home.join("exit.release")
            let waitForExit = "while [[ ! -f '${release.toString()}' ]]; do /bin/sleep 0.01; done"
            let event = this.gitCodeAcceptedEventLine(eventId: "gitcode:Cangjie/community:issue:r3-owned-dispatch")
            let beforeExit = if (blockDispatch) { "printf '%s\\n' '${event}'; ${waitForExit}" } else { waitForExit }
            this.registerGitCodeStdioScript(this.gitCodeCountingLeaseScript(counter,
                this.r2UnusedListenerPort(), keepAlive: false).replace("exit 0", beforeExit))
            setServicePluginSupervisorAutoStartForTest(false)
            let stopClaim = ServicePluginTestGate()
            let dispatchGate = ServicePluginTestGate()
            let settled = ServicePluginTestGate()
            let deliveries = ServicePluginTestCounter()
            let expireClock = ServicePluginTestCounter()
            let firstFinalize = ServicePluginTestOnce()
            var stopper = None<Future<ServiceStopResult>>
            setServicePluginBeforeStopClaimHookForTest(Some({ _sid: String => stopClaim.enterAndWait() }))
            setServicePluginCleanupFinalizeHookForTest(Some({ _sid: String, _token: Int64 =>
                if (firstFinalize.take()) { sleep(Duration.millisecond * 5) }
            }))
            if (blockDispatch) {
                setServicePluginBeforeEventDispatchHookForTest(Some({ _sid: String => dispatchGate.enterAndWait() }))
                setServicePluginDispatchWorkerSettledHookForTest(Some({ _frame: String => settled.signal() }))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let targets = ArrayList<ServicePluginDeliveryTarget>()
                    targets.add(ServicePluginDeliveryTarget("telegram", "fake", "fake-peer"))
                    targets
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "must stay fenced")
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String =>
                    deliveries.increment()
                    ServicePluginEventDeliveryResult(true, "sent")
                }))
            }
            try {
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                if (blockDispatch) { @Expect(dispatchGate.awaitEntered(2000), true) }
                let before = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                stopper = Some(spawn { stopServicePlugin("gitcode-monitor", reason: "r3-late-pending", timeoutMillis: 3000) })
                @Expect(stopClaim.awaitEntered(1000), true)
                File.writeTo(release, "release".toArray())
                @Expect(this.r2WaitPendingReadyIdle(), true)
                @Expect(servicePluginCleanupPendingCountForTest(), 1)
                @Expect(getServicePluginSnapshot("gitcode-monitor").getOrThrow().instanceId, before.instanceId)
                @Expect(this.waitForPidGone(before.pid), true)
                let leasePath = home.join("service-plugin").join("runtime").join("gitcode-monitor").join("${before.instanceId}.lease.json")
                @Expect(servicePluginReadHistoricalLeaseStrict(leasePath).evidence.getOrThrow().state, "running")
                if (expireDeadline) {
                    let baseline = servicePluginDeadlineNowMs()
                    let origin = MonoTime.now()
                    setServicePluginMonotonicNowForTest(Some({ =>
                        baseline + (MonoTime.now() - origin).toMilliseconds() +
                            if (expireClock.get() > 0) { Int64(1000000) } else { Int64(0) }
                    }))
                    expireClock.increment()
                }
                setServicePluginCleanupFinalizeHookForTest(None<(String, Int64) -> Unit>)
                setServicePluginBeforeStopClaimHookForTest(None<(String) -> Unit>)
                stopClaim.release()
                let stopped = stopper.getOrThrow().get(Duration.second * 4)
                stopper = None<Future<ServiceStopResult>>
                if (expireDeadline || blockDispatch) {
                    @Expect(stopped.ok, false)
                    @Expect(stopped.status, "cleanup_pending")
                    @Expect(stopped.stateFlushed, false)
                    @Expect(servicePluginCleanupPendingCountForTest(), 1)
                    @Expect(getServicePluginSnapshot("gitcode-monitor").getOrThrow().instanceId, before.instanceId)
                    @Expect(servicePluginReadHistoricalLeaseStrict(leasePath).evidence.getOrThrow().state, "running")
                    if (blockDispatch) {
                        let held = servicePluginCleanupDispatchSnapshotForTest("gitcode-monitor").getOrThrow()
                        @Expect(held.accepted > 0, true)
                        @Expect(held.futures > 0, true)
                    }
                } else {
                    @Expect(stopped.ok, true)
                    @Expect(stopped.status, "stopped")
                    @Expect(stopped.leaseStatus, "stopped")
                    @Expect(stopped.portStatus, "released")
                    @Expect(stopped.dispatchStatus, "drained")
                    @Expect(servicePluginCleanupPendingCountForTest(), 0)
                }
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                @Expect(this.readCounterFile(counter), 1)
            } finally {
                setServicePluginMonotonicNowForTest(None<() -> Int64>)
                File.writeTo(release, "release".toArray())
                stopClaim.release()
                dispatchGate.release()
                setServicePluginBeforeStopClaimHookForTest(None<(String) -> Unit>)
                setServicePluginCleanupFinalizeHookForTest(None<(String, Int64) -> Unit>)
                match (stopper) { case Some(future) => let _ = future.get(Duration.second * 4) case None => () }
                if (blockDispatch) { @Expect(settled.awaitEntered(3000), true) }
                let cleanup = stopServicePlugin("gitcode-monitor", reason: "r3-fixture-complete", timeoutMillis: 2500)
                @Expect(cleanup.ok, true)
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(deliveries.get(), 0)
                setServicePluginBeforeEventDispatchHookForTest(None<(String) -> Unit>)
                setServicePluginDispatchWorkerSettledHookForTest(None<(String) -> Unit>)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()
                resetServicePluginHostForTest()
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            }
        })
    }

    @TestCase
    public func r3StopJoinsCleanupPublishedAfterLookup(): Unit { this.r3StopPendingHandoff(false, false) }

    @TestCase
    public func r3StopLateCleanupKeepsOriginalCallerDeadline(): Unit { this.r3StopPendingHandoff(true, false) }

    @TestCase
    public func r3StopLateCleanupRetainsUnsettledDispatch(): Unit { this.r3StopPendingHandoff(false, true) }

    private func r2WaitPendingReadyIdle(): Bool {
        for (_ in 0..1500) {
            if (servicePluginCleanupReadyIdleForTest("gitcode-monitor")) { return true }
            sleep(Duration.millisecond)
        }
        servicePluginCleanupReadyIdleForTest("gitcode-monitor")
    }

    @TestCase
    public func r2EnsureExitedPendingSharesCallerDeadline(): Unit {
        for (expireDuringCleanup in [true, false]) {
            withIsolatedServicePluginHostTestHome("r2-ensure-deadline-${expireDuringCleanup}", { home: Path =>
                let counter = home.join("launch-count")
                this.registerGitCodeStdioScript(this.gitCodeCountingLeaseScript(counter,
                    this.r2UnusedListenerPort(), firstLaunchExit: true))
                setServicePluginSupervisorAutoStartForTest(false)
                let firstFinalize = ServicePluginTestOnce()
                let firstAttempt = ServicePluginTestGate()
                let expireClock = ServicePluginTestCounter()
                let startCalls = ServicePluginTestCounter()
                setServicePluginCleanupFinalizeHookForTest(Some({ _sid: String, _token: Int64 =>
                    if (firstFinalize.take()) { sleep(Duration.millisecond * 5); firstAttempt.signal() }
                }))
                try {
                    @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                    @Expect(firstAttempt.awaitEntered(1500), true)
                    @Expect(this.r2WaitPendingReadyIdle(), true)
                    let before = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                    @Expect(before.status, "cleanup_pending")
                    @Expect(this.readCounterFile(counter), 1)
                    let leasePath = home.join("service-plugin").join("runtime").join("gitcode-monitor").join("${before.instanceId}.lease.json")
                    setServicePluginMonotonicNowForTest(Some({ => if (expireClock.get() > 0) { Int64(1000000) } else { Int64(0) } }))
                    setServicePluginCleanupFinalizeHookForTest(Some({ _sid: String, _token: Int64 =>
                        if (expireDuringCleanup) { expireClock.increment() }
                    }))
                    setServicePluginStartPhaseHookForTest(Some({ _sid: String, phase: String =>
                        if (phase == "before_start") { startCalls.increment(); if (!expireDuringCleanup) { expireClock.increment() } }
                    }))
                    let result = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 500)
                    @Expect(result.ok, false)
                    @Expect(expireClock.get(), 1)
                    @Expect(this.readCounterFile(counter), 1)
                    @Expect(servicePluginStartClaimCountForTest(), 0)
                    @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                    if (expireDuringCleanup) {
                        @Expect(result.status, "cleanup_pending")
                        @Expect(servicePluginCleanupPendingCountForTest(), 1)
                        @Expect(getServicePluginSnapshot("gitcode-monitor").getOrThrow().instanceId, before.instanceId)
                        @Expect(startCalls.get(), 0)
                        @Expect(servicePluginReadHistoricalLeaseStrict(leasePath).evidence.getOrThrow().state, "running")
                    } else {
                        @Expect(result.status, "initialize_timeout")
                        @Expect(servicePluginCleanupPendingCountForTest(), 0)
                        @Expect(startCalls.get(), 1)
                        @Expect(servicePluginReadHistoricalLeaseStrict(leasePath).evidence.getOrThrow().state, "stopped")
                        @Expect(getServicePluginSnapshot("gitcode-monitor").getOrThrow().status == "running", false)
                    }
                } finally {
                    setServicePluginMonotonicNowForTest(None<() -> Int64>)
                    setServicePluginCleanupFinalizeHookForTest(None<(String, Int64) -> Unit>)
                    setServicePluginStartPhaseHookForTest(None<(String, String) -> Unit>)
                    let completed = stopServicePlugin("gitcode-monitor", reason: "deadline-fixture-complete", timeoutMillis: 2500)
                    @Expect(completed.ok, true)
                    @Expect(servicePluginCleanupPendingCountForTest(), 0)
                    resetServicePluginHostForTest()
                    @Expect(servicePluginCleanupPendingCountForTest(), 0)
                    @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                }
            })
        }
    }

    @TestCase
    public func r2StateStopPreservesOwnedCleanupPending(): Unit {
        withIsolatedServicePluginHostTestHome("r2-state-stop", { home: Path =>
            let counter = home.join("launch-count")
            this.registerGitCodeStdioScript(this.gitCodeCountingLeaseScript(counter,
                this.r2UnusedListenerPort(), stopUpdatesLease: false))
            setServicePluginSupervisorAutoStartForTest(false)
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true,
                healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
            setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeout: Int64 => (Int64(1), "", "") }))
            setServicePluginHealthzProbeForTest(Some({ _url: String, _timeout: Int64 =>
                ServicePluginHealthzProbeResult(false, durationMs: 10, diagnostic: "healthz_timeout")
            }))
            try {
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let before = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                let tick = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 2000)
                @Expect(tick.recovered, false)
                @Expect(servicePluginCleanupPendingCountForTest(), 1)
                let pending = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(pending.status, "cleanup_pending")
                @Expect(pending.instanceId, before.instanceId)
                @Expect(stopServicePlugin("gitcode-monitor", reason: "r2-state-stop-retry", timeoutMillis: 1).stateFlushed, false)
                @Expect(pending.supervisorRestartCount, 0)
                @Expect(this.readCounterFile(counter), 1)
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 500).status, "cleanup_pending")
                @Expect(this.waitForPidGone(before.pid), true)
            } finally {
                resetServicePluginHostForTest()
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            }
        })
    }

    @TestCase
    public func r2StateExitPreservesPendingUntilReaderSettles(): Unit {
        withIsolatedServicePluginHostTestHome("r2-state-exit", { home: Path =>
            let counter = home.join("launch-count")
            this.registerGitCodeStdioScript(this.gitCodeCountingLeaseScript(counter, this.r2UnusedListenerPort()))
            setServicePluginSupervisorAutoStartForTest(false)
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true,
                healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
            setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeout: Int64 => (Int64(1), "", "") }))
            setServicePluginHealthzProbeForTest(Some({ _url: String, _timeout: Int64 =>
                ServicePluginHealthzProbeResult(true, statusCode: 200)
            }))
            let readerGate = ServicePluginTestGate()
            try {
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let before = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                let owner = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()[0]
                setServicePluginBeforeReaderEndHookForTest(Some({ current: String, _settled: () -> Bool =>
                    if (current == owner) { readerGate.enterAndWait() }
                }))
                @Expect(executeWithOutput("/bin/kill", ["-KILL", before.pid.toString()])[0], 0)
                @Expect(readerGate.awaitEntered(2000), true)
                @Expect(this.waitForPidGone(before.pid), true)
                let tick = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 2000)
                @Expect(tick.recovered, false)
                @Expect(servicePluginCleanupPendingCountForTest(), 1)
                let pending = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(pending.status, "cleanup_pending")
                @Expect(pending.instanceId, before.instanceId)
                @Expect(stopServicePlugin("gitcode-monitor", reason: "r2-state-exit-retry", timeoutMillis: 1).stateFlushed, false)
                @Expect(pending.supervisorRestartCount, 0)
                @Expect(this.readCounterFile(counter), 1)
                readerGate.release()
                setServicePluginBeforeReaderEndHookForTest(None<(String, () -> Bool) -> Unit>)
                let recovered = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 4000)
                @Expect(recovered.recovered, true)
                @Expect(getServicePluginSnapshot("gitcode-monitor").getOrThrow().supervisorRestartCount, 1)
                @Expect(this.readCounterFile(counter), 2)
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(stopServicePlugin("gitcode-monitor", reason: "r2-state-exit-complete", timeoutMillis: 3000).ok, true)
            } finally {
                readerGate.release()
                setServicePluginBeforeReaderEndHookForTest(None<(String, () -> Bool) -> Unit>)
                resetServicePluginHostForTest()
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            }
        })
    }

    @TestCase
    public func r2LateSuccessorCannotPassDetachedCleanupOwner(): Unit {
        withIsolatedServicePluginHostTestHome("r2-late-successor", { home: Path =>
            let counter = home.join("launch-count")
            this.registerGitCodeStdioScript(this.gitCodeCountingLeaseScript(counter, this.r2UnusedListenerPort()))
            setServicePluginSupervisorAutoStartForTest(false)
            setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeout: Int64 => (Int64(1), "", "") }))
            let ownerStopped = ServicePluginTestGate()
            var dropper = None<Future<Bool>>
            try {
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let before = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                let owner = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()[0]
                setServicePluginAfterOwnerStopHookForTest(Some({ current: String, _ok: Bool, _status: String =>
                    if (current == owner) { ownerStopped.enterAndWait() }
                }))
                dropper = Some(spawn { dropServicePluginActiveProcessForTest("gitcode-monitor") })
                @Expect(ownerStopped.awaitEntered(2500), true)
                @Expect(servicePluginCleanupPendingCountForTest(), 1)
                let blocked = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 500)
                @Expect(blocked.ok, false)
                @Expect(blocked.status, "cleanup_pending")
                @Expect(getServicePluginSnapshot("gitcode-monitor").getOrThrow().instanceId, before.instanceId)
                @Expect(this.readCounterFile(counter), 1)
                ownerStopped.release()
                @Expect(dropper.getOrThrow().get(Duration.second * 3), true)
                dropper = None<Future<Bool>>
                setServicePluginAfterOwnerStopHookForTest(None<(String, Bool, String) -> Unit>)
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(this.waitForPidGone(before.pid), true)
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                @Expect(this.readCounterFile(counter), 2)
                @Expect(managedStdioBroker().snapshot().ownerCount, 1)
                @Expect(servicePluginStartClaimCountForTest(), 0)
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(stopServicePlugin("gitcode-monitor", reason: "r2-successor-complete", timeoutMillis: 3000).ok, true)
            } finally {
                ownerStopped.release()
                setServicePluginAfterOwnerStopHookForTest(None<(String, Bool, String) -> Unit>)
                match (dropper) { case Some(future) => let _ = future.get(Duration.second * 3) case None => () }
                resetServicePluginHostForTest()
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            }
        })
    }

    @TestCase
    public func r2LateResetObservesDetachedCleanupBeforeClearingRegistry(): Unit {
        withIsolatedServicePluginHostTestHome("r2-late-reset", { home: Path =>
            let counter = home.join("launch-count")
            this.registerGitCodeStdioScript(this.gitCodeCountingLeaseScript(counter, this.r2UnusedListenerPort()))
            setServicePluginSupervisorAutoStartForTest(false)
            setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeout: Int64 => (Int64(1), "", "") }))
            let oldStopGate = ServicePluginTestGate()
            let resetObserved = ServicePluginTestGate()
            let firstStop = ServicePluginTestOnce()
            var dropper = None<Future<Bool>>
            var resetter = None<Future<Unit>>
            try {
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let before = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                let owner = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()[0]
                setServicePluginAfterOwnerStopHookForTest(Some({ current: String, _ok: Bool, _status: String =>
                    if (current == owner) {
                        if (!firstStop.take()) { resetObserved.signal() }
                        oldStopGate.enterAndWait()
                    }
                }))
                dropper = Some(spawn { dropServicePluginActiveProcessForTest("gitcode-monitor") })
                @Expect(oldStopGate.awaitEntered(2500), true)
                @Expect(servicePluginCleanupPendingCountForTest(), 1)
                resetter = Some(spawn { resetServicePluginHostForTest() })
                @Expect(resetObserved.awaitEntered(1500), true)
                oldStopGate.release()
                let _ = resetter.getOrThrow().get(Duration.second * 4)
                resetter = None<Future<Unit>>
                @Expect(dropper.getOrThrow().get(Duration.second * 4), true)
                dropper = None<Future<Bool>>
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(this.waitForPidGone(before.pid), true)
                this.registerGitCodeStdioScript(this.gitCodeCountingLeaseScript(counter, this.r2UnusedListenerPort()))
                setServicePluginSupervisorAutoStartForTest(false)
                setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeout: Int64 => (Int64(1), "", "") }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let after = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(after.instanceId, before.instanceId)
                @Expect(after.pid != before.pid, true)
                @Expect(this.readCounterFile(counter), 2)
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(stopServicePlugin("gitcode-monitor", reason: "r2-reset-complete", timeoutMillis: 3000).ok, true)
            } finally {
                oldStopGate.release()
                setServicePluginAfterOwnerStopHookForTest(None<(String, Bool, String) -> Unit>)
                match (resetter) { case Some(future) => let _ = future.get(Duration.second * 4) case None => () }
                match (dropper) { case Some(future) => let _ = future.get(Duration.second * 4) case None => () }
                resetServicePluginHostForTest()
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            }
        })
    }

    private func r2BlockedDispatchCleanup(supervisor: Bool): Unit {
        withIsolatedServicePluginHostTestHome("r2-blocked-dispatch-${supervisor}", { home: Path =>
            let port = this.r2UnusedListenerPort()
            let event = this.gitCodeAcceptedEventLine(eventId: "gitcode:Cangjie/community:issue:r2-owned-dispatch")
            let script = this.gitCodeLeaseScript(port).replace("metis_stop_lease() {",
                "printf '%s\\n' '${event}'; metis_stop_lease() {")
            this.registerGitCodeStdioScript(script)
            setServicePluginSupervisorAutoStartForTest(false)
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true,
                healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
            setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeout: Int64 => (Int64(1), "", "") }))
            setServicePluginHealthzProbeForTest(Some({ _url: String, _timeout: Int64 =>
                ServicePluginHealthzProbeResult(false, durationMs: 10, diagnostic: "healthz_timeout")
            }))
            let dispatchGate = ServicePluginTestGate()
            let ownerStopGate = ServicePluginTestGate()
            let settled = ServicePluginTestGate()
            let retryEntered = ServicePluginTestGate()
            let deliveries = ServicePluginTestCounter()
            var dropper = None<Future<Bool>>
            var retry = None<Future<ServiceStopResult>>
            setServicePluginBeforeEventDispatchHookForTest(Some({ _sid: String => dispatchGate.enterAndWait() }))
            setServicePluginDispatchWorkerSettledHookForTest(Some({ _frame: String => settled.signal() }))
            setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                let targets = ArrayList<ServicePluginDeliveryTarget>()
                targets.add(ServicePluginDeliveryTarget("telegram", "fake", "fake-peer"))
                targets
            }))
            setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "must stay fenced")
            }))
            setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String =>
                deliveries.increment()
                ServicePluginEventDeliveryResult(true, "sent")
            }))
            try {
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                @Expect(dispatchGate.awaitEntered(2000), true)
                let before = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                let owner = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()[0]
                if (supervisor) {
                    @Expect(runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 2000).recovered, false)
                } else {
                    setServicePluginAfterOwnerStopHookForTest(Some({ current: String, _ok: Bool, _status: String =>
                        if (current == owner) { ownerStopGate.enterAndWait() }
                    }))
                    dropper = Some(spawn { dropServicePluginActiveProcessForTest("gitcode-monitor") })
                    @Expect(ownerStopGate.awaitEntered(2500), true)
                }
                @Expect(servicePluginCleanupPendingCountForTest(), 1)
                let held = servicePluginCleanupDispatchSnapshotForTest("gitcode-monitor").getOrThrow()
                @Expect(held.accepted > 0, true)
                @Expect(held.futures > 0, true)
                @Expect(getServicePluginSnapshot("gitcode-monitor").getOrThrow().status, "cleanup_pending")
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 500).status, "cleanup_pending")
                let leasePath = home.join("service-plugin").join("runtime").join("gitcode-monitor").join("${before.instanceId}.lease.json")
                @Expect(servicePluginReadHistoricalLeaseStrict(leasePath).evidence.getOrThrow().state, "stopped")
                setServicePluginCleanupFinalizeHookForTest(Some({ _sid: String, _token: Int64 => retryEntered.signal() }))
                retry = Some(spawn { stopServicePlugin("gitcode-monitor", reason: "r2-dispatch-complete", timeoutMillis: 2500) })
                ownerStopGate.release()
                @Expect(retryEntered.awaitEntered(2000), true)
                @Expect(servicePluginCleanupDispatchSnapshotForTest("gitcode-monitor").getOrThrow().futures > 0, true)
                dispatchGate.release()
                let completed = retry.getOrThrow().get(Duration.second * 3)
                retry = None<Future<ServiceStopResult>>
                match (dropper) { case Some(future) => @Expect(future.get(Duration.second * 3), true) case None => () }
                dropper = None<Future<Bool>>
                @Expect(settled.awaitEntered(3000), true)
                @Expect(completed.ok, true)
                @Expect(completed.status, "stopped")
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(this.waitForPidGone(before.pid), true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                @Expect(deliveries.get(), 0)
            } finally {
                dispatchGate.release()
                ownerStopGate.release()
                setServicePluginAfterOwnerStopHookForTest(None<(String, Bool, String) -> Unit>)
                setServicePluginBeforeEventDispatchHookForTest(None<(String) -> Unit>)
                setServicePluginDispatchWorkerSettledHookForTest(None<(String) -> Unit>)
                setServicePluginCleanupFinalizeHookForTest(None<(String, Int64) -> Unit>)
                match (retry) { case Some(future) => let _ = future.get(Duration.second * 3) case None => () }
                match (dropper) { case Some(future) => let _ = future.get(Duration.second * 3) case None => () }
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()
                resetServicePluginHostForTest()
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            }
        })
    }

    @TestCase
    public func r2StateStopRetryCompletesAfterOwnedDispatchRelease(): Unit { this.r2BlockedDispatchCleanup(true) }

    @TestCase
    public func r2LateDispatchRetainsFutureUntilOwnedRelease(): Unit { this.r2BlockedDispatchCleanup(false) }

    @TestCase
    public func r2OwnerGuardRejectsActualIdentityVariants(): Unit {
        withIsolatedServicePluginHostTestHome("r2-id-neg", { home: Path =>
            this.registerGitCodeStdioScript(this.gitCodeLeaseScript(this.r2UnusedListenerPort()))
            setServicePluginSupervisorAutoStartForTest(false)
            try {
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let before = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                let owner = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()
                @Expect(servicePluginSupervisorOwnerGuardForTest("gitcode-monitor", before.instanceId, owner[0], owner[1], owner[2]), true)
                for ((sid, session, ownerId, generation, claim, foreignRecord) in [
                    ("foreign-service", before.instanceId, owner[0], owner[1], owner[2], false),
                    ("gitcode-monitor", "foreign-session", owner[0], owner[1], owner[2], false),
                    ("gitcode-monitor", before.instanceId, "foreign-owner", owner[1], owner[2], false),
                    ("gitcode-monitor", before.instanceId, owner[0], owner[1] + 1, owner[2], false),
                    ("gitcode-monitor", before.instanceId, owner[0], owner[1], owner[2] + 1, false),
                    ("gitcode-monitor", before.instanceId, owner[0], owner[1], owner[2], true)
                ]) {
                    @Expect(servicePluginSupervisorOwnerGuardForTest(sid, session, ownerId, generation, claim, foreignRecord: foreignRecord), false)
                    let after = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                    @Expect(after.pid, before.pid)
                    @Expect(after.status, before.status)
                    @Expect(after.instanceId, before.instanceId)
                    @Expect(after.supervisorRestartCount, before.supervisorRestartCount)
                    @Expect(after.supervisorFailureCount, before.supervisorFailureCount)
                    @Expect(after.lastError, before.lastError)
                }
            } finally { resetServicePluginHostForTest() }
        })
    }

    @TestCase
    public func r2StaleProbeCannotStopSameRecordOrResetSuccessor(): Unit {
        for (replaceRecord in [false, true]) {
            withIsolatedServicePluginHostTestHome("r2-stale-probe-${replaceRecord}", { home: Path =>
                let counter = home.join("launch-count")
                let script = this.gitCodeCountingLeaseScript(counter, this.r2UnusedListenerPort())
                this.registerGitCodeStdioScript(script)
                setServicePluginSupervisorAutoStartForTest(false)
                setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true,
                    healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
                setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeout: Int64 => (Int64(1), "", "") }))
                setServicePluginHealthzProbeForTest(Some({ _url: String, _timeout: Int64 =>
                    ServicePluginHealthzProbeResult(false, durationMs: 10, diagnostic: "healthz_timeout")
                }))
                let probeGate = ServicePluginTestGate()
                var probe = None<Future<ServicePluginSupervisorTickResult>>
                try {
                    @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                    @Expect(this.waitForGitCodeLease(home), true)
                    let old = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                    setServicePluginBeforeSupervisorProbePublishHookForTest(Some({ _sid: String => probeGate.enterAndWait() }))
                    probe = Some(spawn { runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 2000) })
                    @Expect(probeGate.awaitEntered(2000), true)
                    @Expect(stopServicePlugin("gitcode-monitor", reason: "r2-successor", timeoutMillis: 2500).ok, true)
                    if (replaceRecord) { this.registerGitCodeStdioScript(script) }
                    setServicePluginSupervisorAutoStartForTest(false)
                    setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeout: Int64 => (Int64(1), "", "") }))
                    @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                    @Expect(this.waitForGitCodeLease(home), true)
                    let before = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                    @Expect(before.instanceId == old.instanceId, replaceRecord)
                    @Expect(before.pid != old.pid, true)
                    probeGate.release()
                    @Expect(probe.getOrThrow().get(Duration.second * 3).recovered, false)
                    probe = None<Future<ServicePluginSupervisorTickResult>>
                    let after = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                    @Expect(after.pid, before.pid)
                    @Expect(after.status, before.status)
                    @Expect(after.instanceId, before.instanceId)
                    @Expect(after.supervisorFailureCount, before.supervisorFailureCount)
                    @Expect(after.supervisorRestartCount, before.supervisorRestartCount)
                    @Expect(after.lastError, before.lastError)
                    @Expect(this.readCounterFile(counter), 2)
                    @Expect(servicePluginCleanupPendingCountForTest(), 0)
                } finally {
                    probeGate.release()
                    setServicePluginBeforeSupervisorProbePublishHookForTest(None<(String) -> Unit>)
                    match (probe) { case Some(future) => let _ = future.get(Duration.second * 3) case None => () }
                    resetServicePluginHostForTest()
                    @Expect(servicePluginCleanupPendingCountForTest(), 0)
                    @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                }
            })
        }
    }

    @TestCase
    public func tP4B001ForcedStopKeepsDiagnosticWhenLeaseNotStopped(): Unit {
        // METIS-ORPHAN-P-002, T-P4-B-001.
        withIsolatedServicePluginHostTestHome("service-plugin-p4-forced-stop-lease", { _home: Path =>
            let script = "printf '%s\\n' '${this.gitCodeInitLine()}'; printf '{\"state\":\"running\",\"status\":\"running\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"%s\",\"pid\":%s,\"parentPid\":%s,\"bindHost\":\"127.0.0.1\",\"port\":18080}\\n' \"$METIS_SERVICE_PLUGIN_SESSION_ID\" \"$$\" \"$METIS_SERVICE_PLUGIN_PARENT_PID\" > \"$METIS_SERVICE_PLUGIN_LEASE_PATH\"; trap '' TERM; while true; do read -t 1 ignored || true; done"
            this.registerGitCodeStdioScript(script)
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        let leasePath = Path("/tmp").join("unused")
                        @Expect(snapshot.pid > 0, true)
                    case None => @Expect(true, false)
                }
                let stopped = stopServicePlugin("gitcode-monitor", reason: "test", timeoutMillis: 200)
                @Expect(stopped.ok, false)
                @Expect(stopped.status, "cleanup_pending")
                @Expect(stopped.diagnostic.contains("lease_not_stopped_after_stop"), true)
                @Expect(stopped.diagnostic.contains("state=running"), true)
                @Expect(stopped.diagnostic.contains("pidAlive="), true)
                @Expect(stopped.diagnostic.contains("port=18080"), true)
                @Expect(stopped.diagnostic.contains("parentPid="), true)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "cleanup_pending")
                        @Expect(snapshot.degradedReason, "cleanup_pending")
                        @Expect(snapshot.lastError.contains("lease_not_stopped_after_stop"), true)
                        @Expect(renderServicePluginDiagnostics(snapshot).contains("parentPid="), true)
                    case None => @Expect(true, false)
                }
            } finally {
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tP3U001HealthyProbeDoesNotDegradeOrRecover(): Unit {
        // T-P3-U-001.
        let config = ServicePluginSupervisorConfig(enabled: true, intervalMs: 100, healthTimeoutMs: 50, failureThreshold: 2, restartCooldownMs: 1000)
        let probe = ServicePluginHealthProbeResult(
            pidAlive: true,
            stdioAlive: true,
            leaseState: "running",
            leaseAgeMs: 300000,
            healthzOk: true,
            healthzDurationMs: 3,
            port: 18080,
            diagnostic: "healthz_status=200"
        )
        let classified = classifyServicePluginHealth(probe, previousFailures: 1, config: config)
        @Expect(classified.status, "healthy")
        @Expect(classified.failureCount, 0)
        @Expect(classified.shouldRecover, false)
        @Expect(classified.reason, "")
    }

    @TestCase
    public func tP3U002HealthzTimeoutThresholdTriggersRecovery(): Unit {
        // T-P3-U-002.
        let config = ServicePluginSupervisorConfig(enabled: true, intervalMs: 100, healthTimeoutMs: 50, failureThreshold: 2, restartCooldownMs: 1000)
        let probe = ServicePluginHealthProbeResult(
            pidAlive: true,
            stdioAlive: true,
            leaseState: "running",
            leaseAgeMs: 300000,
            healthzOk: false,
            healthzDurationMs: 50,
            port: 18080,
            diagnostic: "healthz_timeout"
        )
        let classified = classifyServicePluginHealth(probe, previousFailures: 1, config: config)
        @Expect(classified.status, "degraded")
        @Expect(classified.reason, "healthz_timeout")
        @Expect(classified.failureCount, 2)
        @Expect(classified.shouldRecover, true)
    }

    @TestCase
    public func tP3U003ProcessDeadShortCircuitsHealthzProbe(): Unit {
        // T-P3-U-003.
        withIsolatedServicePluginHostTestHome("service-plugin-p3-process-dead", { _home: Path =>
            this.registerGitCodeStdioScript(this.gitCodeLeaseScript(18180, keepAlive: false))
            let callLock = Mutex()
            let healthzCalls = ArrayList<Int64>()
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true, intervalMs: 1000, healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
            setServicePluginHealthzProbeForTest(Some({ _url: String, _timeoutMs: Int64 =>
                synchronized(callLock) { healthzCalls.add(1) }
                ServicePluginHealthzProbeResult(false, statusCode: 0, durationMs: 10, diagnostic: "should_not_call")
            }))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForSnapshotReason("gitcode-monitor", "process_exited", timeoutMillis: 1000), true)
                let probe = probeServicePluginHealth("gitcode-monitor", nowMs: 2000)
                @Expect(probe.pidAlive, false)
                let classification = classifyServicePluginHealth(probe, previousFailures: 0, config: ServicePluginSupervisorConfig(enabled: true, intervalMs: 1000, healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
                @Expect(classification.reason, "process_exited")
                @Expect(synchronized(callLock) { Int64(healthzCalls.size) }, 0)
            } finally {
                setServicePluginHealthzProbeForTest(None)
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tP3B001MissingLeaseOrListenerEndpointIsDiagnosticOnly(): Unit {
        // T-P3-B-001.
        withIsolatedServicePluginHostTestHome("service-plugin-p3-missing-lease", { _home: Path =>
            let noLeaseScript = "printf '%s\\n' '${this.gitCodeInitLine()}'; while read line; do exit 0; done"
            this.registerGitCodeStdioScript(noLeaseScript)
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true, intervalMs: 1000, healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                let tick = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 2000)
                @Expect(tick.probe.diagnostic.contains("lease_missing"), true)
                @Expect(tick.classification.status, "healthy")
                @Expect(tick.recovered, false)
                @Expect(queryServicePluginStatus("gitcode-monitor").status, "running")
            } finally {
                resetServicePluginHostForTest()
            }
        })

        withIsolatedServicePluginHostTestHome("service-plugin-p3-missing-endpoint", { home: Path =>
            this.registerGitCodeStdioScript(this.gitCodeLeaseScript(0, includeEndpoint: false))
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true, intervalMs: 1000, healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let tick = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 2000)
                @Expect(tick.probe.diagnostic.contains("listener_endpoint_missing"), true)
                @Expect(tick.classification.status, "healthy")
                @Expect(tick.recovered, false)
                @Expect(queryServicePluginStatus("gitcode-monitor").status, "running")
            } finally {
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tP3B002SingleTimeoutThenHealthyClearsFailureWithoutRestart(): Unit {
        // T-P3-B-002.
        withIsolatedServicePluginHostTestHome("service-plugin-p3-timeout-recovers", { home: Path =>
            this.registerGitCodeStdioScript(this.gitCodeLeaseScript(18181))
            let callLock = Mutex()
            let healthzCalls = ArrayList<Int64>()
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true, intervalMs: 1000, healthTimeoutMs: 10, failureThreshold: 2, restartCooldownMs: 1000))
            setServicePluginHealthzProbeForTest(Some({ _url: String, _timeoutMs: Int64 =>
                let callCount = synchronized(callLock) {
                    healthzCalls.add(1)
                    Int64(healthzCalls.size)
                }
                if (callCount == 1) {
                    return ServicePluginHealthzProbeResult(false, statusCode: 0, durationMs: 10, diagnostic: "healthz_timeout")
                }
                ServicePluginHealthzProbeResult(true, statusCode: 200, durationMs: 1, diagnostic: "healthz_status=200")
            }))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let first = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 2000)
                @Expect(first.classification.reason, "healthz_timeout")
                @Expect(first.classification.shouldRecover, false)
                let second = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 3000)
                @Expect(second.classification.status, "healthy")
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.supervisorFailureCount, 0)
                        @Expect(snapshot.supervisorRestartCount, 0)
                    case None => @Expect(true, false)
                }
            } finally {
                setServicePluginHealthzProbeForTest(None)
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tP3P001HealthyFakeServiceKeepsFiveMinuteProbeHealthy(): Unit {
        // T-P3-P-001.
        withIsolatedServicePluginHostTestHome("service-plugin-p3-five-minute-healthy", { home: Path =>
            this.registerGitCodeStdioScript(this.gitCodeLeaseScript(18182))
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true, intervalMs: 1000, healthTimeoutMs: 10, failureThreshold: 2, restartCooldownMs: 1000))
            setServicePluginHealthzProbeForTest(Some({ _url: String, _timeoutMs: Int64 =>
                ServicePluginHealthzProbeResult(true, statusCode: 200, durationMs: 2, diagnostic: "healthz_status=200")
            }))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let tick = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 1000 + 300000)
                @Expect(tick.classification.status, "healthy")
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "running")
                        @Expect(snapshot.supervisorLastProbe.contains("status=healthy"), true)
                        @Expect(snapshot.supervisorRestartCount, 0)
                    case None => @Expect(true, false)
                }
            } finally {
                setServicePluginHealthzProbeForTest(None)
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tP3N001PersistentHealthzTimeoutMarksDegradedAndRestartsBounded(): Unit {
        // T-P3-N-001.
        withIsolatedServicePluginHostTestHome("service-plugin-p3-persistent-timeout", { home: Path =>
            this.registerGitCodeStdioScript(this.gitCodeLeaseScript(18183))
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true, intervalMs: 1000, healthTimeoutMs: 10, failureThreshold: 2, restartCooldownMs: 60000))
            setServicePluginHealthzProbeForTest(Some({ _url: String, _timeoutMs: Int64 =>
                ServicePluginHealthzProbeResult(false, statusCode: 0, durationMs: 10, diagnostic: "healthz_timeout")
            }))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let first = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 2000)
                @Expect(first.recovered, false)
                let second = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 3000)
                @Expect(second.classification.shouldRecover, true)
                @Expect(this.waitForSupervisorRestart("gitcode-monitor", 1, timeoutMillis: 2000), true)
                let third = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 4000)
                @Expect(third.recovered, false)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "degraded")
                        @Expect(snapshot.degradedReason, "healthz_timeout")
                        @Expect(snapshot.supervisorRestartCount, 1)
                        @Expect(renderServicePluginDiagnostics(snapshot).contains("healthz_timeout"), true)
                    case None => @Expect(true, false)
                }
            } finally {
                setServicePluginHealthzProbeForTest(None)
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tT0U2T4U1EnsureReplacesDeadActiveProcess(): Unit {
        // T0-U2 Metis-side baseline, T4-U1.
        withIsolatedServicePluginHostTestHome("service-plugin-t4-dead-active", { home: Path =>
            let counterPath = home.join("launch-count.txt")
            this.registerGitCodeStdioScript(this.gitCodeCountingLeaseScript(counterPath, this.r2UnusedListenerPort(), firstLaunchExit: true))
            setServicePluginSupervisorAutoStartForTest(false)
            let firstFinalize = ServicePluginTestOnce()
            let firstAttempt = ServicePluginTestGate()
            setServicePluginCleanupFinalizeHookForTest(Some({ _sid: String, _token: Int64 =>
                if (firstFinalize.take()) { sleep(Duration.millisecond * 5); firstAttempt.signal() }
            }))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForSnapshotReason("gitcode-monitor", "process_exited", timeoutMillis: 1500), true)
                @Expect(firstAttempt.awaitEntered(1500), true)
                @Expect(this.r2WaitPendingReadyIdle(), true)
                let previous = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(previous.status, "cleanup_pending")
                setServicePluginCleanupFinalizeHookForTest(None<(String, Int64) -> Unit>)
                let previousLease = home.join("service-plugin").join("runtime").join("gitcode-monitor").join("${previous.instanceId}.lease.json")

                let restarted = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(restarted.ok, true)
                @Expect(this.readCounterFile(counterPath), 2)
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(servicePluginReadHistoricalLeaseStrict(previousLease).evidence.getOrThrow().state, "stopped")
                @Expect(getServicePluginSnapshot("gitcode-monitor").getOrThrow().instanceId != previous.instanceId, true)
                let replacementDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 1000
                var replacementSnapshot = getServicePluginSnapshot("gitcode-monitor")
                var replacementRunning = match (replacementSnapshot) {
                    case Some(snapshot) => snapshot.status == "running" && snapshot.pid > 0
                    case None => false
                }
                while (DateTime.now().toUnixTimeStamp().toMilliseconds() < replacementDeadline && !replacementRunning) {
                    sleep(Duration.millisecond * 10)
                    replacementSnapshot = getServicePluginSnapshot("gitcode-monitor")
                    replacementRunning = match (replacementSnapshot) {
                        case Some(snapshot) => snapshot.status == "running" && snapshot.pid > 0
                        case None => false
                    }
                }
                match (replacementSnapshot) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "running")
                        @Expect(snapshot.pid > 0, true)
                        match (getServicePluginSnapshot("gitcode-monitor")) {
                            case Some(stableSnapshot) =>
                                @Expect(stableSnapshot.status, "running")
                                @Expect(stableSnapshot.pid, snapshot.pid)
                            case None => @Expect(true, false)
                        }
                    case None => @Expect(true, false)
                }
                @Expect(stopServicePlugin("gitcode-monitor", reason: "dead-active-complete", timeoutMillis: 3000).ok, true)
            } finally {
                setServicePluginCleanupFinalizeHookForTest(None<(String, Int64) -> Unit>)
                resetServicePluginHostForTest()
                let settled = this.settleServiceOwnerCleanup("gitcode-monitor", timeoutMillis: 3000)
                @Expect(settled[2], true)
                @Expect(settled[3], true)
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            }
        })
    }

    @TestCase
    public func tT4U1EnsureReplacesQueueOnlyAndProcessOnlyStaleState(): Unit {
        // T4-U1 queue-only stale and process-only stale coverage.
        withIsolatedServicePluginHostTestHome("service-plugin-t4-queue-only", { home: Path =>
            let counterPath = home.join("queue-only-count.txt")
            this.registerGitCodeStdioScript(this.gitCodeCountingLeaseScript(counterPath, 18186))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(dropServicePluginActiveProcessForTest("gitcode-monitor", stopProcess: true), true)

                let restarted = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(restarted.ok, true)
                @Expect(this.readCounterFile(counterPath), 2)
            } finally {
                resetServicePluginHostForTest()
            }
        })

        withIsolatedServicePluginHostTestHome("service-plugin-t4-process-only", { home: Path =>
            let counterPath = home.join("process-only-count.txt")
            this.registerGitCodeStdioScript(this.gitCodeCountingLeaseScript(counterPath, 18187))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(dropServicePluginResponseQueueForTest("gitcode-monitor"), true)

                let restarted = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(restarted.ok, true)
                @Expect(this.readCounterFile(counterPath), 2)
            } finally {
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tT4U1EnsureReplacesClosedResponseQueue(): Unit {
        // T4-U1 closed queue coverage.
        withIsolatedServicePluginHostTestHome("service-plugin-t4-closed-queue", { home: Path =>
            let counterPath = home.join("closed-queue-count.txt")
            this.registerGitCodeStdioScript(this.gitCodeCountingLeaseScript(counterPath, 18188))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(closeServicePluginResponseQueueForTest("gitcode-monitor", status: "test_closed"), true)

                let restarted = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(restarted.ok, true)
                @Expect(this.readCounterFile(counterPath), 2)
            } finally {
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tT4U2EventPumpClosesImmediatelyWhenProcessExits(): Unit {
        // T4-U2: discovering EOF and proving terminal resource cleanup are separate phases.
        withIsolatedServicePluginHostTestHome("service-plugin-t4-event-pump-dead", { home: Path =>
            this.registerGitCodeStdioScript(this.gitCodeLeaseScript(this.r2UnusedListenerPort(), keepAlive: false))
            setServicePluginSupervisorAutoStartForTest(false)
            let firstFinalize = ServicePluginTestOnce()
            let readySlot = ServicePluginTestGate()
            let readerLock = Mutex()
            let readerProbes = ArrayList<() -> Bool>()
            setServicePluginBeforeReaderEndHookForTest(Some({ _owner: String, settled: () -> Bool =>
                synchronized(readerLock) { readerProbes.add(settled) }
            }))
            setServicePluginCleanupFinalizeHookForTest(Some({ _sid: String, _token: Int64 =>
                if (firstFinalize.take()) { readySlot.enterAndWait() }
            }))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForSnapshotReason("gitcode-monitor", "process_exited", timeoutMillis: 1500), true)
                @Expect(readySlot.awaitEntered(1500), true)
                let pending = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                let leasePath = home.join("service-plugin").join("runtime").join("gitcode-monitor").join("${pending.instanceId}.lease.json")
                @Expect(pending.status, "cleanup_pending")
                @Expect(pending.degradedReason, "cleanup_pending")
                @Expect(servicePluginCleanupPendingCountForTest(), 1)
                @Expect(this.waitForPidGone(pending.pid), true)
                @Expect(synchronized(readerLock) { readerProbes.size > 0 && readerProbes[readerProbes.size - 1]() }, true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                let leaseBefore = servicePluginReadHistoricalLeaseStrict(leasePath).evidence.getOrThrow()
                @Expect(leaseBefore.sessionId, pending.instanceId)
                @Expect(leaseBefore.state, "running")
                // Only the fixture delays the original 1ms attempt; production budgets stay unchanged.
                sleep(Duration.millisecond * 5)
                setServicePluginCleanupFinalizeHookForTest(None<(String, Int64) -> Unit>)
                readySlot.release()
                let finalized = servicePluginFinalizeCleanupPendingForTest("gitcode-monitor", 1000)
                @Expect(finalized[0], true)
                @Expect(finalized[1], "stopped")
                @Expect(finalized[2], "released")
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "degraded")
                        @Expect(snapshot.degradedReason, "process_exited")
                        @Expect(snapshot.instanceId, pending.instanceId)
                    case None => @Expect(true, false)
                }
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(servicePluginReadHistoricalLeaseStrict(leasePath).evidence.getOrThrow().state, "stopped")
                @Expect(this.waitForPidGone(pending.pid), true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            } finally {
                readySlot.release()
                setServicePluginCleanupFinalizeHookForTest(None<(String, Int64) -> Unit>)
                setServicePluginBeforeReaderEndHookForTest(None<(String, () -> Bool) -> Unit>)
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tT4U3T4P1SupervisorRecoveryRequiresRestartHealthzSuccess(): Unit {
        // T4-U3, T4-P1.
        withIsolatedServicePluginHostTestHome("service-plugin-t4-recover-healthz-success", { home: Path =>
            let counterPath = home.join("healthz-success-count.txt")
            let callLock = Mutex()
            let healthzCalls = ArrayList<String>()
            this.registerGitCodeStdioScript(this.gitCodeCountingLeaseScript(counterPath, 18190))
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true, intervalMs: 1000, healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
            setServicePluginHealthzProbeForTest(Some({ url: String, _timeoutMs: Int64 =>
                let callCount = synchronized(callLock) {
                    healthzCalls.add(url)
                    Int64(healthzCalls.size)
                }
                if (callCount == 1) {
                    return ServicePluginHealthzProbeResult(false, statusCode: 0, durationMs: 10, diagnostic: "healthz_timeout")
                }
                ServicePluginHealthzProbeResult(true, statusCode: 200, durationMs: 1, diagnostic: "healthz_status=200")
            }))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let tick = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 2000)
                @Expect(tick.recovered, true)
                @Expect(this.readCounterFile(counterPath), 2)
                @Expect(synchronized(callLock) { Int64(healthzCalls.size) }, 2)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "running")
                        @Expect(snapshot.supervisorFailureCount, 0)
                        @Expect(snapshot.supervisorRestartCount, 1)
                        @Expect(snapshot.lastError.contains("recovery_success"), true)
                    case None => @Expect(true, false)
                }
            } finally {
                setServicePluginHealthzProbeForTest(None)
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tT4N1SupervisorRecoveryStaysDegradedWhenRestartHealthzFails(): Unit {
        // T4-N1.
        withIsolatedServicePluginHostTestHome("service-plugin-t4-recover-healthz-failed", { home: Path =>
            let counterPath = home.join("healthz-failed-count.txt")
            let callLock = Mutex()
            let healthzCalls = ArrayList<String>()
            this.registerGitCodeStdioScript(this.gitCodeCountingLeaseScript(counterPath, 18191))
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true, intervalMs: 1000, healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
            setServicePluginHealthzProbeForTest(Some({ url: String, _timeoutMs: Int64 =>
                synchronized(callLock) { healthzCalls.add(url) }
                ServicePluginHealthzProbeResult(false, statusCode: 0, durationMs: 10, diagnostic: "healthz_timeout")
            }))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let tick = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 2000)
                @Expect(tick.recovered, false)
                @Expect(this.readCounterFile(counterPath), 2)
                @Expect(synchronized(callLock) { Int64(healthzCalls.size) }, 2)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "degraded")
                        @Expect(snapshot.degradedReason, "restart_healthz_failed")
                        @Expect(snapshot.lastError.contains("restart_healthz_failed"), true)
                    case None => @Expect(true, false)
                }
            } finally {
                setServicePluginHealthzProbeForTest(None)
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tT4B1RestartMissingLeaseOrPortZeroDoesNotReportRunning(): Unit {
        // T4-B1.
        withIsolatedServicePluginHostTestHome("service-plugin-t4-recover-missing-lease", { home: Path =>
            let counterPath = home.join("missing-lease-count.txt")
            this.registerGitCodeStdioScript(this.gitCodeCountingRestartLeaseScript(counterPath, 18192, 18192, restartWritesLease: false))
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true, intervalMs: 1000, healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
            setServicePluginHealthzProbeForTest(Some({ _url: String, _timeoutMs: Int64 =>
                ServicePluginHealthzProbeResult(false, statusCode: 0, durationMs: 10, diagnostic: "healthz_timeout")
            }))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let tick = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 2000)
                @Expect(tick.recovered, false)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "degraded")
                        @Expect(snapshot.degradedReason, "restart_healthz_failed")
                        @Expect(snapshot.lastError.contains("lease_missing"), true)
                    case None => @Expect(true, false)
                }
            } finally {
                setServicePluginHealthzProbeForTest(None)
                resetServicePluginHostForTest()
            }
        })

        withIsolatedServicePluginHostTestHome("service-plugin-t4-recover-port-zero", { home: Path =>
            let counterPath = home.join("port-zero-count.txt")
            this.registerGitCodeStdioScript(this.gitCodeCountingRestartLeaseScript(counterPath, 18193, 0, delayRestartLease: true))
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true, intervalMs: 1000, healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
            setServicePluginHealthzProbeForTest(Some({ _url: String, _timeoutMs: Int64 =>
                ServicePluginHealthzProbeResult(false, statusCode: 0, durationMs: 10, diagnostic: "healthz_timeout")
            }))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let tick = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 2000)
                @Expect(tick.recovered, false)
                @Expect(this.readCounterFile(counterPath), 2)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "degraded")
                        @Expect(snapshot.degradedReason, "restart_healthz_failed")
                        @Expect(snapshot.lastError.contains("port=0"), true)
                    case None => @Expect(true, false)
                }
            } finally {
                setServicePluginHealthzProbeForTest(None)
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tT5P1T5N1ProcessStartDiagnosticIsLoggedAndRedacted(): Unit {
        // T5-P1, T5-N1.
        withIsolatedServicePluginHostTestHome("service-plugin-t5-start-diagnostic", { home: Path =>
            let oldLogLevel = getVariable("METIS_LOG_LEVEL")
            let oldLogFile = getVariable("METIS_LOG_FILE")
            let oldConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
            let logFile = home.join("logs").join("service-plugin-start.log")
            try {
                setVariable("METIS_LOG_LEVEL", "debug")
                setVariable("METIS_LOG_FILE", logFile.toString())
                setVariable("METIS_CONSOLE_LEVEL", "silent")
                gatewayLoggingResetForTest()
                resetServicePluginHostForTest()

                let script = "printf '%s\\n' '${this.gitCodeInitLine()}'; read ignored || true"
                let okRegistration = registerServicePlugin(ServicePluginRegistration(
                    this.gitCodeStdioManifestFromScript(script),
                    configRef: ServicePluginConfigRef(secretRef: "gcm-token", manifestPath: home.join("metis.service-plugin.json").toString())
                ))
                @Expect(okRegistration.ok, true)
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)

                let okLog = this.readTextFile(logFile)
                @Expect(okLog.contains("service_plugin.process.start"), true)
                @Expect(okLog.contains("entryCommand"), true)
                @Expect(okLog.contains("workingDirectory"), true)
                @Expect(okLog.contains("manifestPath"), true)
                @Expect(okLog.contains("configRef"), true)
                @Expect(okLog.contains("pid"), true)
                @Expect(okLog.contains("binaryMtime"), true)
                @Expect(okLog.contains("gcm-token"), false)
                @Expect(okLog.contains(home.toString()), false)
                @Expect(okLog.contains("[REDACTED_LOCAL_PATH]"), true)

                resetServicePluginHostForTest()
                let badCaps = ArrayList<ServiceCapabilityRecord>()
                badCaps.add(ServiceCapabilityRecord("gitcode.event.accepted", "event"))
                let badManifest = ServicePluginManifest(
                    schema: METIS_SERVICE_PLUGIN_SCHEMA,
                    pluginId: "gitcode-monitor",
                    displayName: "GitCode Monitor",
                    kind: "service",
                    protocolVersion: "1.0",
                    entryCommand: home.join("missing-plugin-binary").toString(),
                    hasConfigSchema: true,
                    capabilityDeclarations: badCaps
                )
                let badRegistration = registerServicePlugin(ServicePluginRegistration(
                    badManifest,
                    configRef: ServicePluginConfigRef(secretRef: "gcm-token", manifestPath: home.join("missing.service-plugin.json").toString())
                ))
                @Expect(badRegistration.ok, true)
                let failed = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(failed.ok, false)
                @Expect(failed.status, "process_start_failed")
                let failedLog = this.readTextFile(logFile)
                @Expect(failedLog.contains("process_start_failed"), true)
                @Expect(failedLog.contains("missing-plugin-binary"), false)
                @Expect(failedLog.contains("gcm-token"), false)
                @Expect(failedLog.contains(home.toString()), false)
                @Expect(failedLog.contains("[REDACTED_LOCAL_PATH]"), true)
            } finally {
                resetServicePluginHostForTest()
                match (oldLogLevel) {
                    case Some(value) => setVariable("METIS_LOG_LEVEL", value)
                    case None => setVariable("METIS_LOG_LEVEL", "")
                }
                match (oldLogFile) {
                    case Some(value) => setVariable("METIS_LOG_FILE", value)
                    case None => setVariable("METIS_LOG_FILE", "")
                }
                match (oldConsoleLevel) {
                    case Some(value) => setVariable("METIS_CONSOLE_LEVEL", value)
                    case None => setVariable("METIS_CONSOLE_LEVEL", "")
                }
                gatewayLoggingResetForTest()
            }
        })
    }

    @TestCase
    public func tT5N1SupervisorWorkerLogsTickAndCatchesException(): Unit {
        // T5-N1 supervisor exception coverage.
        withIsolatedServicePluginHostTestHome("service-plugin-t5-supervisor-exception", { home: Path =>
            let oldLogLevel = getVariable("METIS_LOG_LEVEL")
            let oldLogFile = getVariable("METIS_LOG_FILE")
            let oldConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
            let logFile = home.join("logs").join("service-plugin-supervisor.log")
            try {
                setVariable("METIS_LOG_LEVEL", "debug")
                setVariable("METIS_LOG_FILE", logFile.toString())
                setVariable("METIS_CONSOLE_LEVEL", "silent")
                gatewayLoggingResetForTest()

                this.registerGitCodeStdioScript(this.gitCodeLeaseScript(18194))
                setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true, intervalMs: 1000, healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
                setServicePluginHealthzProbeForTest(Some({ _url: String, _timeoutMs: Int64 =>
                    throw Exception("healthz boom Authorization: Bearer secret-value /Users/private/path")
                }))
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                runServicePluginSupervisorWorkerTickForTest("gitcode-monitor", nowMs: 2000)

                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "degraded")
                        @Expect(snapshot.degradedReason, "supervisor_exception")
                        @Expect(snapshot.lastError.contains("secret-value"), false)
                        @Expect(snapshot.lastError.contains("/Users/private"), false)
                    case None => @Expect(true, false)
                }
                let log = this.readTextFile(logFile)
                @Expect(log.contains("service_plugin.supervisor.exception"), true)
                @Expect(log.contains("secret-value"), false)
                @Expect(log.contains("/Users/private"), false)
            } finally {
                setServicePluginHealthzProbeForTest(None)
                resetServicePluginHostForTest()
                match (oldLogLevel) {
                    case Some(value) => setVariable("METIS_LOG_LEVEL", value)
                    case None => setVariable("METIS_LOG_LEVEL", "")
                }
                match (oldLogFile) {
                    case Some(value) => setVariable("METIS_LOG_FILE", value)
                    case None => setVariable("METIS_LOG_FILE", "")
                }
                match (oldConsoleLevel) {
                    case Some(value) => setVariable("METIS_CONSOLE_LEVEL", value)
                    case None => setVariable("METIS_CONSOLE_LEVEL", "")
                }
                gatewayLoggingResetForTest()
            }
        })
    }

    @TestCase
    public func tP3N002PortReleaseTimeoutBlocksSecondPluginStart(): Unit {
        // T-P3-N-002.
        withIsolatedServicePluginHostTestHome("service-plugin-p3-port-owned", { home: Path =>
            let port = this.r2UnusedListenerPort()
            this.registerGitCodeStdioScript(this.gitCodeLeaseScript(port))
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true, intervalMs: 1000, healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
            setServicePluginHealthzProbeForTest(Some({ _url: String, _timeoutMs: Int64 =>
                ServicePluginHealthzProbeResult(false, statusCode: 0, durationMs: 10, diagnostic: "healthz_timeout")
            }))
            setServicePluginSupervisorAutoStartForTest(false)
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let firstPid = match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) => snapshot.pid
                    case None => 0
                }
                let firstSession = getServicePluginSnapshot("gitcode-monitor").getOrThrow().instanceId
                let firstPgid = this.processGroupId(firstPid)
                @Expect(firstPid > 1, true)
                @Expect(firstPgid > 0, true)
                if (firstPid <= 1 || firstPgid <= 0) { return }
                let pidProbeCalls = ServicePluginTestCounter()
                let portOwnerProbeCalls = ServicePluginTestCounter()
                setServicePluginPidProbeCommandForTest(Some({ pid: Int64, timeoutMs: Int64 =>
                    pidProbeCalls.increment()
                    @Expect(pid, firstPid)
                    @Expect(timeoutMs > 0 && timeoutMs <= 1000, true)
                    (Int64(1), "", "kill: No such process")
                }))
                setServicePluginPortOwnerProbeForTest(Some({ actualPort: Int64, pid: Int64 =>
                    portOwnerProbeCalls.increment()
                    @Expect(actualPort, port)
                    @Expect(pid, firstPid)
                    true
                }))
                let tick = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 2000)
                @Expect(tick.classification.shouldRecover, true)
                @Expect(tick.recovered, false)
                @Expect(tick.diagnostic.contains("port_release_timeout"), true)
                @Expect(tick.classification.reason, "healthz_timeout")
                @Expect(pidProbeCalls.get() > 0, true)
                @Expect(portOwnerProbeCalls.get() > 0, true)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.pid, 0)
                        @Expect(snapshot.instanceId, firstSession)
                        @Expect(snapshot.supervisorRestartCount, 0)
                        @Expect(snapshot.status, "cleanup_pending")
                        @Expect(snapshot.degradedReason, "cleanup_pending")
                    case None => @Expect(true, false)
                }
                @Expect(this.waitForPidGone(firstPid), true)
                @Expect(this.waitForProcessGroupGone(firstPgid), true)
                @Expect(servicePluginActiveIdentityForTest("gitcode-monitor").isNone(), true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                @Expect(servicePluginDispatchCountsForTest("gitcode-monitor").isNone(), true)
                @Expect(servicePluginCleanupPendingCountForTest(), 1)
                @Expect(stopServicePlugin("gitcode-monitor", reason: "port-still-owned", timeoutMillis: 1).stateFlushed, false)
                let leasePath = home.join("service-plugin").join("runtime").join("gitcode-monitor").join("${firstSession}.lease.json")
                @Expect(servicePluginReadHistoricalLeaseStrict(leasePath).evidence.getOrThrow().state, "stopped")
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 500).status, "cleanup_pending")
                @Expect(servicePluginStartClaimCountForTest(), 0)
                setServicePluginPortOwnerProbeForTest(Some({ _port: Int64, _pid: Int64 => false }))
                setServicePluginPidProbeCommandForTest(None<(Int64, Int64) -> (Int64, String, String)>)
                let released = stopServicePlugin("gitcode-monitor", reason: "port-released", timeoutMillis: 2500)
                @Expect(released.ok, true)
                @Expect(released.status, "stopped")
                @Expect(released.portStatus, "released")
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            } finally {
                setServicePluginSupervisorAutoStartForTest(true)
                setServicePluginHealthzProbeForTest(None)
                try {
                    resetServicePluginHostForTest()
                } finally {
                    setServicePluginPidProbeCommandForTest(None<(Int64, Int64) -> (Int64, String, String)>)
                    setServicePluginPortOwnerProbeForTest(None)
                    let brokerReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                    @Expect(brokerReset.ok, true)
                    let brokerSnapshot = managedStdioBroker().snapshot()
                    @Expect(brokerSnapshot.running, false)
                    @Expect(brokerSnapshot.brokerPid, 0)
                    @Expect(brokerSnapshot.ownerCount, 0)
                    @Expect(brokerSnapshot.readerCount, 0)
                    @Expect(brokerSnapshot.dispatcherCount, 0)
                }
            }
        })
    }

    @TestCase
    public func heartbeatAndHealthAreScopedToService(): Unit {
        let _ = registerSample()
        let started = startServicePlugin("sample-service")
        @Expect(started.ok, true)
        let probe = sendServiceHeartbeatProbe("sample-service")
        @Expect(probe.ok, true)
        @Expect(probe.frame.method, "heartbeat")
        @Expect(handleServiceHeartbeat(ServiceFrame("heartbeat", "h1", "sample-service")).ok, true)
        markServiceHealth("sample-service", ServiceHealth("degraded", reason: "network token=secret"))
        let status = queryServicePluginStatus("sample-service")
        @Expect(status.status, "degraded")
        match (getServicePluginSnapshot("sample-service")) {
            case Some(snapshot) =>
                let diagnostic = renderServicePluginDiagnostics(snapshot)
                @Expect(diagnostic.contains("token=secret"), false)
                @Expect(diagnostic.contains("/Users/"), false)
            case None => @Expect(true, false)
        }
        markServiceHealth("sample-service", ServiceHealth("ok"))
        @Expect(queryServicePluginStatus("sample-service").status, "running")
    }

    @TestCase
    public func eventFramesAndHostApiRequestsAreValidated(): Unit {
        let _ = registerSample()
        enqueueServiceEventFrameForTest(ServiceFrame("event", "e1", "sample-service", capabilityId: "sample.event.accepted", payload: "{\"ok\":true}"))
        let read = readServiceEventFrame("sample-service")
        @Expect(read.ok, true)
        @Expect(read.frame.capabilityId, "sample.event.accepted")
        @Expect(readServiceEventFrame("sample-service").status, "timeout")

        let accepted = handleServiceCapabilityEvent(ServiceCapabilityEvent("sample-service", "sample.event.accepted", payload: "{\"url\":\"https://example.invalid\"}"))
        @Expect(accepted.ok, true)
        let notEvent = handleServiceCapabilityEvent(ServiceCapabilityEvent("sample-service", "sample.monitor.status"))
        @Expect(notEvent.ok, false)
        @Expect(notEvent.status, "not_event_capability")
        let missing = handleServiceCapabilityEvent(ServiceCapabilityEvent("sample-service", "missing.event"))
        @Expect(missing.status, "capability_missing")

        let hostOk = handleServiceHostApiRequest(ServiceHostApiRequest("sample-service", "host.agent.invoke", payload: "{\"query\":\"x\"}"))
        @Expect(hostOk.ok, true)
        let hostDenied = handleServiceHostApiRequest(ServiceHostApiRequest("sample-service", "host.notification.publish"))
        @Expect(hostDenied.ok, false)
        @Expect(hostDenied.status, "missing_grant")
    }

    @TestCase
    public func a4NoSubscribersDispatchStatusRemainsRuntimeDiagnosable(): Unit {
        // A4-DIAG-UT-002
        let _ = registerSample()
        let frame = ServiceFrame("event", "e-no-subs", "sample-service", capabilityId: "gitcode.event.accepted", payload: "{\"jobId\":\"webhook-d1\",\"eventId\":\"event-1\"}")
        let result = ServicePluginEventDispatchResult(true, "no_subscribers", diagnostic: "当前没有 GitCode Webhook 通知目标。")
        recordServicePluginRuntimeDispatchForTest("sample-service", frame, result)
        match (getServicePluginSnapshot("sample-service")) {
            case Some(snapshot) =>
                @Expect(snapshot.status, "running")
                @Expect(snapshot.lastError.contains("no_subscribers"), true)
                @Expect(snapshot.lastError.contains("当前没有 GitCode Webhook 通知目标"), false)
            case None => @Expect(true, false)
        }
    }

    @TestCase
    public func controlSurfaceStatusInvokeAndRestartRequireAuthorization(): Unit {
        let _ = registerSample()
        let status = handleServicePluginControlAction(ServicePluginControlAction("status", serviceId: "sample-service"))
        @Expect(status.ok, true)
        @Expect(status.snapshot.serviceId, "sample-service")
        let start = handleServicePluginControlAction(ServicePluginControlAction("start", serviceId: "sample-service"))
        @Expect(start.ok, true)
        setServicePluginCapabilityInvokerForTest(Some({ _registration: ServicePluginRegistration, request: CapabilityInvokeRequest =>
            CapabilityInvokeResult(true, "ok", serviceId: "sample-service", capabilityId: request.capabilityId, payload: "{\"ok\":true,\"status\":\"ok\"}")
        }))
        let invoke = handleServicePluginControlAction(ServicePluginControlAction("invoke", capabilityId: "sample.monitor.status", payload: "{}"))
        @Expect(invoke.ok, true)
        setServicePluginCapabilityInvokerForTest(None)

        let denied = handleServicePluginControlAction(ServicePluginControlAction("restart", serviceId: "sample-service", caller: CapabilityCaller(isOperator: false)))
        @Expect(denied.ok, false)
        @Expect(denied.status, "unauthorized")
        let allowed = handleServicePluginControlAction(ServicePluginControlAction("restart", serviceId: "sample-service", caller: CapabilityCaller(isOperator: true)))
        @Expect(allowed.ok, true)

        let snapshot = buildServicePluginControlSnapshot()
        @Expect(snapshot.plugins.size, 1)
        @Expect(renderServicePluginDiagnostics(snapshot.plugins[0]).contains("token"), false)
    }

    @TestCase
    public func stdioInvokeAcceptsFormattedInitializeAndOkPayload(): Unit {
        this.registerStdio("{ \"ok\": true, \"status\": \"ok\" }")
        try {
            let result = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(result.ok, true)
            @Expect(result.status, "ok")
        } finally {
            resetServicePluginHostForTest()
        }
    }

    @TestCase
    public func stdioSequentialInvokesUseUniqueCorrelationsAndMatchResponses(): Unit {
        withIsolatedServicePluginHostTestHome("stdio-unique-correlations", { home: Path =>
            let requestMarker = home.join("invoke-requests.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let initLine = "{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"stdio-service\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}"
            let responseLine = this.stdioInvokeResponseLine("{\"ok\":true,\"status\":\"ok\"}").replace("__METIS_CORRELATION__", "'\"$corr\"'")
            let script = "printf '%s\\n' '${initLine}'; for request_index in 1 2; do IFS= read -r request; printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_MARKER_PATH\"; corr=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"correlationId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'); printf '%s\\n' '${responseLine}'; done; read ignored || true"
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", requestMarker.toString())
            this.registerStdioScript(script)
            try {
                let first = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
                let second = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
                @Expect(first.ok, true)
                @Expect(first.status, "ok")
                @Expect(second.ok, true)
                @Expect(second.status, "ok")

                let correlations = ArrayList<String>()
                let frameIds = ArrayList<String>()
                for (line in this.readTextFile(requestMarker).split("\n")) {
                    if (line.trimAscii().isEmpty()) { continue }
                    let decoded = decodeServiceFrame(line)
                    @Expect(decoded.ok, true)
                    if (decoded.ok) {
                        @Expect(decoded.frame.method, "invokeCapability")
                        correlations.add(decoded.frame.correlationId)
                        frameIds.add(decoded.frame.frameId)
                    }
                }
                @Expect(correlations.size, 2)
                @Expect(frameIds.size, 2)
                if (correlations.size == 2 && frameIds.size == 2) {
                    @Expect(correlations[0].isEmpty(), false)
                    @Expect(correlations[1].isEmpty(), false)
                    @Expect(correlations[0] == correlations[1], false)
                    @Expect(frameIds[0] == frameIds[1], false)
                }
            } finally {
                match (oldMarker) {
                    case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value)
                    case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "")
                }
            }
        })
    }

    @TestCase
    public func stdioInvokeReturnsFormattedFailureStatus(): Unit {
        this.registerStdio("{ \"ok\": false, \"status\": \"runtime_required\", \"diagnostic\": \"runtime missing\" }")
        try {
            let result = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(result.ok, false)
            @Expect(result.status, "runtime_required")
            @Expect(result.diagnostic.contains("runtime missing"), true)
        } finally {
            resetServicePluginHostForTest()
        }
    }

    @TestCase
    public func stdioInvokeRejectsNonBooleanOkField(): Unit {
        this.registerStdio("{ \"ok\": \"true\", \"status\": \"ok\" }")
        try {
            let result = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(result.ok, false)
            @Expect(result.status, "payload_invalid")
            @Expect(result.diagnostic.contains("ok field must be boolean"), true)
        } finally {
            resetServicePluginHostForTest()
        }
    }

    @TestCase
    public func stdioInvokeRejectsLegacyPayloadWithoutOkForNewProtocol(): Unit {
        this.registerStdio("{ \"accepted\": 1, \"ignored\": 0 }")
        try {
            let result = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(result.ok, false)
            @Expect(result.status, "payload_invalid")
            @Expect(result.diagnostic.contains("missing field: ok"), true)
        } finally {
            resetServicePluginHostForTest()
        }
    }

    @TestCase
    public func stdioInvokeSkipsBoundedNonFrameNoiseBeforeResponse(): Unit {
        let initLine = "{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"stdio-service\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}"
        let warning = "2026-05-30T00:54:06.196142+08:00 WARN [HttpEngine1#connect] TLS handshake error"
        let responseLine = this.stdioInvokeResponseLine("{\"ok\":true,\"status\":\"ok\"}")
        this.registerStdioScript(this.stdioScriptWithInvokeLines(initLine, [warning, responseLine]))
        try {
            let result = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(result.ok, true)
            @Expect(result.status, "ok")
        } finally {
            resetServicePluginHostForTest()
        }
    }

    @TestCase
    public func p3U1BrokerSeparatesPluginStdoutFramesFromStderrBurst(): Unit {
        withIsolatedServicePluginHostTestHome("p3-u1-broker-stream-classification", { _home: Path =>
            let stderrBurstLines: Int64 = 16
            @Expect(stderrBurstLines > 8, true)
            this.registerBrokerServiceFixture("gcm-stderr-burst-${stderrBurstLines}")
            try {
                let result = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
                @Expect(result.ok, true)
                @Expect(result.status, "ok")
                @Expect(result.payload.contains("中文🙂"), true)
                let event = readServiceEventFrame("stdio-service")
                @Expect(event.ok, true)
                @Expect(event.frame.capabilityId, "stdio.event.accepted")
                @Expect(event.frame.payload.contains("事件中文🙂"), true)
                match (getServicePluginSnapshot("stdio-service")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "running")
                        @Expect(snapshot.degradedReason, "")
                    case None => @Expect(true, false)
                }
            } finally {
                let _ = stopServicePlugin("stdio-service", reason: "p3-u1")
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func p3B1NoiseBoundaryAndHealthBurstKeepOwnerScoped(): Unit {
        withIsolatedServicePluginHostTestHome("p3-b1-noise-boundary", { home: Path =>
            this.registerBrokerServiceFixture("noise-8")
            try {
                let atBudget = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
                @Expect(atBudget.ok, true)
                @Expect(atBudget.status, "ok")
            } finally {
                let _ = stopServicePlugin("stdio-service", reason: "p3-b1-at-budget")
                resetServicePluginHostForTest()
            }

            this.registerBrokerServiceFixture("noise-9")
            try {
                let overBudget = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
                @Expect(overBudget.ok, false)
                @Expect(overBudget.status, "stdout_protocol_violation")
                @Expect(overBudget.diagnostic.contains("Authorization"), false)
                @Expect(overBudget.diagnostic.contains("/Users/"), false)
                @Expect(overBudget.diagnostic.contains("payload-"), true)
            } finally {
                resetServicePluginHostForTest()
            }

            this.registerBrokerServiceFixture(
                "gcm",
                pluginId: "health-service",
                capabilityId: "health.monitor.status"
            )
            try {
                let started = ensureRegisteredServicePluginStarted("health-service", startupTimeoutMs: 3000)
                @Expect(started.ok, true)
                let healthLease = home.join("service-plugin").join("runtime").join("health-service").join("health-service-1.lease.json")
                @Expect(this.waitForFile(healthLease, timeoutMillis: 2000), true)
                let pid = match (getServicePluginSnapshot("health-service")) {
                    case Some(snapshot) => snapshot.pid
                    case None => Int64(0)
                }
                for (_ in 0..16) {
                    @Expect(probeServicePluginHealth("health-service").healthzOk, true)
                }
                match (getServicePluginSnapshot("health-service")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.pid, pid)
                        @Expect(snapshot.status, "running")
                    case None => @Expect(true, false)
                }
            } finally {
                let _ = stopServicePlugin("health-service", reason: "p3-b1-health-burst")
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func p3P1FakeGcmHealthEventResponseKeepsPidAndLease(): Unit {
        withIsolatedServicePluginHostTestHome("p3-p1-fake-gcm", { home: Path =>
            this.registerBrokerServiceFixture("gcm")
            try {
                let started = ensureRegisteredServicePluginStarted("stdio-service", startupTimeoutMs: 3000)
                @Expect(started.ok, true)
                let leasePath = home.join("service-plugin").join("runtime").join("stdio-service").join("stdio-service-1.lease.json")
                @Expect(this.waitForFile(leasePath, timeoutMillis: 2000), true)
                let initialPid = match (getServicePluginSnapshot("stdio-service")) {
                    case Some(snapshot) => snapshot.pid
                    case None => Int64(0)
                }
                @Expect(initialPid > 0, true)
                for (_ in 0..100) {
                    let health = probeServicePluginHealth("stdio-service")
                    @Expect(health.pidAlive, true)
                    @Expect(health.stdioAlive, true)
                    @Expect(health.healthzOk, true)
                }
                match (getServicePluginSnapshot("stdio-service")) {
                    case Some(snapshot) => @Expect(snapshot.pid, initialPid)
                    case None => @Expect(true, false)
                }
                let invoked = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
                @Expect(invoked.ok, true)
                @Expect(readServiceEventFrame("stdio-service").ok, true)
                let stopped = stopServicePlugin("stdio-service", reason: "p3-p1")
                @Expect(stopped.ok, true)
                @Expect(this.readTextFile(leasePath).contains("\"state\":\"stopped\""), true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            } finally {
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func s0U1SingleAcceptedEventPreservesBusinessAndOwnerIdentity(): Unit {
        withIsolatedServicePluginHostTestHome("s0-u1-single-event", { home: Path =>
            let eventIds = this.gitCodeBurstEventIds("s0-u1-中文🙂", 1)
            let writebackMarker = home.join("s0-u1-writebacks.marker")
            let oldWritebackMarker = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
            let probe = ServicePluginBurstProbe()
            let deliveries = ServicePluginEventLedger()
            setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebackMarker.toString())
            try {
                resetServicePluginGeneratedReplyStateForTest()
                this.registerGitCodeStdioScript(this.gitCodeBurstScript(eventIds, legacyCorrelation: true))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "s0-account", "s0-peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    probe.enterAndWait(event.eventId)
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "模型结果中文🙂 ${event.eventId}")
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    deliveries.recordMatching(text, eventIds)
                    ServicePluginEventDeliveryResult(true, "sent")
                }))

                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(probe.awaitEntered(1, 2000), true)
                let identity = servicePluginDispatchCountsForTest("gitcode-monitor").getOrThrow()
                @Expect(identity[0].isEmpty(), false)
                @Expect(identity[1] > 0, true)
                @Expect(identity[2], 1)
                @Expect(identity[3], 1)

                probe.release(1)
                @Expect(probe.awaitCompleted(1, 2000), true)
                @Expect(deliveries.awaitTotal(1, 5000), true)
                @Expect(this.waitForDispatchCounts("gitcode-monitor", 0, 0, timeoutMillis: 2000), true)
                let finalProbe = probe.snapshot()
                @Expect(finalProbe[0], 1)
                @Expect(finalProbe[1], 1)
                @Expect(probe.callsFor(eventIds[0]), 1)
                @Expect(this.markerCountForEvent(writebackMarker, eventIds[0]), 1)
                @Expect(deliveries.countFor(eventIds[0]), 1)
                let finalIdentity = servicePluginDispatchCountsForTest("gitcode-monitor").getOrThrow()
                @Expect(finalIdentity[0], identity[0])
                @Expect(finalIdentity[1], identity[1])
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "running")
                        @Expect(snapshot.lastError.contains("stdout_protocol_violation"), false)
                    case None => @Expect(true, false)
                }
            } finally {
                probe.release(8)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()
                match (oldWritebackMarker) {
                    case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value)
                    case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "")
                }
            }
        })
    }

    @TestCase
    public func s0B1ThirtyTwoBlockedGeneratedRepliesStayBounded(): Unit {
        withIsolatedServicePluginHostTestHome("s0-b1-bounded-fanout", { _home: Path =>
            let eventIds = this.gitCodeBurstEventIds("s0-b1-中文🙂", 32)
            let probe = ServicePluginBurstProbe()
            let deliveries = ServicePluginEventLedger()
            try {
                resetServicePluginGeneratedReplyStateForTest()
                this.registerGitCodeStdioScript(this.gitCodeBurstScript(eventIds))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("feishu", "s0-account", "s0-peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    probe.enterAndWait(event.eventId)
                    ServicePluginGeneratedReplyResult(
                        true,
                        status: "needs_human_review",
                        draft: "并发基线中文🙂 ${event.eventId}",
                        needsHumanReview: true
                    )
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    deliveries.recordMatching(text, eventIds)
                    ServicePluginEventDeliveryResult(true, "sent")
                }))

                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(probe.awaitEntered(2, 5000), true)
                let scheduler = this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest =>
                    row.active == 2 && row.queued == 30 && row.accepted == 32 && row.futures == 2
                }).getOrThrow()
                let proof = servicePluginDispatchCountsForTest("gitcode-monitor").getOrThrow()
                let probeSnapshot = probe.snapshot()
                @Expect(probeSnapshot[0], 2)
                @Expect(probeSnapshot[2], 2)
                @Expect(probeSnapshot[3], 2)
                @Expect(proof[2], 32)
                @Expect(proof[3], 2)
                @Expect(scheduler.queueHighWatermark, 30)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) => @Expect(snapshot.status, "running")
                    case None => @Expect(true, false)
                }
            } finally {
                probe.release(64)
                let _ = probe.awaitCompleted(32, 5000)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()
            }
        })
    }

    @TestCase
    public func s0P1FourUniqueEventsDrainExactlyOncePerId(): Unit {
        withIsolatedServicePluginHostTestHome("s0-p1-exact-once", { home: Path =>
            let eventIds = this.gitCodeBurstEventIds("s0-p1-中文🙂", 4)
            let writebackMarker = home.join("s0-p1-writebacks.marker")
            let oldWritebackMarker = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
            let probe = ServicePluginBurstProbe()
            let deliveries = ServicePluginEventLedger()
            setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebackMarker.toString())
            try {
                resetServicePluginGeneratedReplyStateForTest()
                this.registerGitCodeStdioScript(this.gitCodeBurstScript(eventIds))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "s0-account", "s0-peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    probe.enterAndWait(event.eventId)
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "分批结果中文🙂 ${event.eventId}")
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    deliveries.recordMatching(text, eventIds)
                    ServicePluginEventDeliveryResult(true, "sent")
                }))

                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(probe.awaitEntered(2, 3000), true)
                probe.release(2)
                @Expect(deliveries.awaitTotal(2, 5000), true)
                @Expect(probe.awaitEntered(4, 3000), true)
                probe.release(2)
                @Expect(probe.awaitCompleted(4, 3000), true)
                @Expect(deliveries.awaitTotal(4, 5000), true)
                @Expect(this.waitForDispatchCounts("gitcode-monitor", 0, 0, timeoutMillis: 2000), true)
                @Expect(probe.snapshot()[1], 4)
                @Expect(deliveries.totalCount(), 4)
                for (eventId in eventIds) {
                    @Expect(probe.callsFor(eventId), 1)
                    @Expect(this.markerCountForEvent(writebackMarker, eventId), 1)
                    @Expect(deliveries.countFor(eventId), 1)
                }
            } finally {
                probe.release(16)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()
                match (oldWritebackMarker) {
                    case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value)
                    case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "")
                }
            }
        })
    }

    @TestCase
    public func s0N1BlockedDispatchPreservesGracefulAndCleanupPendingStopTruth(): Unit {
        withIsolatedServicePluginHostTestHome("s0-n1-stop-truth", { _home: Path =>
            var activeGate = None<ServicePluginTestGate>
            var stopper = None<Future<ServiceStopResult>>
            try {
                let gracefulGate = ServicePluginTestGate()
                activeGate = Some(gracefulGate)
                this.registerBrokerServiceFixture(
                    "gcm-stderr-burst-16",
                    pluginId: "gitcode-monitor",
                    capabilityId: "gitcode.monitor.status"
                )
                setServicePluginBeforeEventDispatchHookForTest(Some({ _serviceId: String => gracefulGate.enterAndWait() }))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "s0-account", "s0-peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "停止基线中文🙂")
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String =>
                    ServicePluginEventDeliveryResult(true, "sent")
                }))
                @Expect(invokeRegisteredCapability(CapabilityInvokeRequest("gitcode.monitor.status", payload: "{}")).ok, true)
                @Expect(gracefulGate.awaitEntered(2000), true)
                let gracefulIdentity = servicePluginActiveIdentityForTest("gitcode-monitor")
                @Expect(gracefulIdentity.isSome(), true)
                if (gracefulIdentity.isNone()) { return }
                let gracefulPid = getServicePluginSnapshot("gitcode-monitor").getOrThrow().pid
                let gracefulPgid = this.processGroupId(gracefulPid)
                @Expect(gracefulPid > 1, true)
                @Expect(gracefulPgid > 0, true)
                if (gracefulPid <= 1 || gracefulPgid <= 0) { return }
                let gracefulPidProbeCalls = ServicePluginTestCounter()
                let gracefulPortProbeCalls = ServicePluginTestCounter()
                setServicePluginPidProbeCommandForTest(Some({ pid: Int64, timeoutMs: Int64 =>
                    gracefulPidProbeCalls.increment()
                    @Expect(pid, gracefulPid)
                    @Expect(timeoutMs > 0 && timeoutMs <= 2500, true)
                    (Int64(1), "", "kill: No such process")
                }))
                setServicePluginPortReleaseCommandForTest(Some({ port: Int64, pid: Int64, timeoutMs: Int64 =>
                    gracefulPortProbeCalls.increment()
                    @Expect(port > 0, true)
                    @Expect(pid, gracefulPid)
                    @Expect(timeoutMs > 0 && timeoutMs <= 500, true)
                    (Int64(1), "", "")
                }))
                stopper = Some(spawn { stopServicePlugin("gitcode-monitor", reason: "s0 graceful 中文🙂", timeoutMillis: 2500) })
                sleep(Duration.millisecond * 50)
                gracefulGate.release()
                let graceful = stopper.getOrThrow().get(Duration.second * 4)
                stopper = None<Future<ServiceStopResult>>
                @Expect(graceful.ok, true)
                @Expect(graceful.status, "stopped")
                @Expect(graceful.ingressStopStatus, "sent")
                @Expect(graceful.dispatchStatus, "drained")
                @Expect(graceful.ownerStopStatus, "graceful_exited")
                @Expect(graceful.leaseStatus, "stopped")
                @Expect(graceful.portStatus, "released")
                @Expect(gracefulPidProbeCalls.get() > 0, true)
                @Expect(gracefulPortProbeCalls.get() > 0, true)
                @Expect(this.waitForPidGone(gracefulPid), true)
                @Expect(this.waitForProcessGroupGone(gracefulPgid), true)
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(servicePluginActiveIdentityForTest("gitcode-monitor").isNone(), true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                @Expect(servicePluginDispatchCountsForTest("gitcode-monitor").isNone(), true)

                setServicePluginBeforeEventDispatchHookForTest(None<(String) -> Unit>)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()

                let pendingGate = ServicePluginTestGate()
                let pendingSettledGate = ServicePluginTestGate()
                activeGate = Some(pendingGate)
                this.registerBrokerServiceFixture(
                    "gcm-stderr-burst-16",
                    pluginId: "gitcode-monitor",
                    capabilityId: "gitcode.monitor.status"
                )
                setServicePluginBeforeEventDispatchHookForTest(Some({ _serviceId: String => pendingGate.enterAndWait() }))
                setServicePluginDispatchSettledHookForTest(Some({ => pendingSettledGate.signal() }))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("feishu", "s0-account", "s0-peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "挂起基线中文🙂")
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String =>
                    ServicePluginEventDeliveryResult(true, "sent")
                }))
                @Expect(invokeRegisteredCapability(CapabilityInvokeRequest("gitcode.monitor.status", payload: "{}")).ok, true)
                @Expect(pendingGate.awaitEntered(2000), true)
                let pendingIdentity = servicePluginActiveIdentityForTest("gitcode-monitor")
                @Expect(pendingIdentity.isSome(), true)
                if (pendingIdentity.isNone()) { return }
                let pendingPid = getServicePluginSnapshot("gitcode-monitor").getOrThrow().pid
                let pendingPgid = this.processGroupId(pendingPid)
                @Expect(pendingPid > 1, true)
                @Expect(pendingPgid > 0, true)
                if (pendingPid <= 1 || pendingPgid <= 0) { return }
                let pendingPidProbeCalls = ServicePluginTestCounter()
                let pendingPortProbeCalls = ServicePluginTestCounter()
                setServicePluginPidProbeCommandForTest(Some({ pid: Int64, timeoutMs: Int64 =>
                    pendingPidProbeCalls.increment()
                    @Expect(pid, pendingPid)
                    @Expect(timeoutMs > 0 && timeoutMs <= 2500, true)
                    (Int64(1), "", "kill: No such process")
                }))
                setServicePluginPortReleaseCommandForTest(Some({ port: Int64, pid: Int64, timeoutMs: Int64 =>
                    pendingPortProbeCalls.increment()
                    @Expect(port > 0, true)
                    @Expect(pid, pendingPid)
                    @Expect(timeoutMs > 0 && timeoutMs <= 500, true)
                    (Int64(1), "", "")
                }))
                setServicePluginDispatchRemainingForTest(Some({ => Int64(99) }))
                let pending = stopServicePlugin("gitcode-monitor", reason: "s0 pending 中文🙂", timeoutMillis: 200)
                @Expect(pending.ok, false)
                @Expect(pending.status, "cleanup_pending")
                @Expect(pending.stateFlushed, false)
                @Expect(pending.ingressStopStatus, "sent")
                @Expect(pending.dispatchStatus, "dispatch_pending")
                @Expect(pending.ownerStopStatus, "graceful_exited")
                @Expect(pending.leaseStatus, "stopped")
                @Expect(pending.portStatus, "released")
                @Expect(pendingPidProbeCalls.get() > 0, true)
                @Expect(pendingPortProbeCalls.get() > 0, true)
                @Expect(servicePluginCleanupPendingCountForTest(), 1)
                let cleanupIdentity = servicePluginCleanupPendingIdentityForTest("gitcode-monitor")
                @Expect(cleanupIdentity.isSome(), true)
                if (cleanupIdentity.isNone()) { return }
                @Expect(cleanupIdentity.getOrThrow()[0], pendingIdentity.getOrThrow()[0])
                @Expect(cleanupIdentity.getOrThrow()[1], pendingIdentity.getOrThrow()[1])
                @Expect(cleanupIdentity.getOrThrow()[2], pendingIdentity.getOrThrow()[2])
                @Expect(servicePluginActiveIdentityForTest("gitcode-monitor").isNone(), true)
                @Expect(this.waitForPidGone(pendingPid), true)
                @Expect(this.waitForProcessGroupGone(pendingPgid), true)

                pendingGate.release()
                @Expect(pendingSettledGate.awaitEntered(2000), true)
                setServicePluginDispatchRemainingForTest(None<() -> Int64>)
                let retried = stopServicePlugin("gitcode-monitor", reason: "s0 cleanup retry", timeoutMillis: 2000)
                @Expect(retried.ok, true)
                @Expect(retried.status, "stopped")
                @Expect(retried.ingressStopStatus, "sent")
                @Expect(retried.dispatchStatus, "drained")
                @Expect(retried.leaseStatus, "stopped")
                @Expect(retried.portStatus, "released")
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(servicePluginCleanupPendingIdentityForTest("gitcode-monitor").isNone(), true)
                @Expect(servicePluginActiveIdentityForTest("gitcode-monitor").isNone(), true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                @Expect(servicePluginDispatchCountsForTest("gitcode-monitor").isNone(), true)
                activeGate = None<ServicePluginTestGate>
            } finally {
                match (activeGate) { case Some(gate) => gate.release() case None => () }
                setServicePluginPidProbeCommandForTest(None<(Int64, Int64) -> (Int64, String, String)>)
                setServicePluginPortReleaseCommandForTest(None<(Int64, Int64, Int64) -> (Int64, String, String)>)
                setServicePluginDispatchRemainingForTest(None<() -> Int64>)
                setServicePluginDispatchSettledHookForTest(None<() -> Unit>)
                setServicePluginBeforeEventDispatchHookForTest(None<(String) -> Unit>)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (stopper) {
                    case Some(future) => try { let _ = future.get(Duration.second * 4) } catch (_: Exception) { () }
                    case None => ()
                }
                resetServicePluginGeneratedReplyStateForTest()
                resetServicePluginHostForTest()
                let brokerReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                @Expect(brokerReset.ok, true)
                let brokerSnapshot = managedStdioBroker().snapshot()
                @Expect(brokerSnapshot.running, false)
                @Expect(brokerSnapshot.brokerPid, 0)
                @Expect(brokerSnapshot.ownerCount, 0)
                @Expect(brokerSnapshot.readerCount, 0)
                @Expect(brokerSnapshot.dispatcherCount, 0)
            }
        })
    }

    @TestCase
    public func s1cU1ThirtyTwoAckEventsUseTwoActiveAndThirtyQueued(): Unit {
        withIsolatedServicePluginHostTestHome("s1c-u1-bounded", { home: Path =>
            let eventIds = this.gitCodeBurstEventIds("s1c-u1-中文🙂", 32)
            let ackMarker = home.join("acks.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let probe = ServicePluginBurstProbe()
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeAckBurstScript(eventIds))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>(); rows.add(ServicePluginDeliveryTarget("telegram", "s1c", "peer")); rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    probe.enterAndWait(event.eventId); ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String => ServicePluginEventDeliveryResult(true, "sent") }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(probe.awaitEntered(2, 3000), true)
                let snapshot = this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest => row.active == 2 && row.queued == 30 && row.accepted == 32 && row.futures == 2 }).getOrThrow()
                @Expect(snapshot.queueHighWatermark, 30)
                @Expect(this.waitForAckMarkerCount(ackMarker, "admission", "accepted", 32), true)
                @Expect(this.ackMarkerCounts(ackMarker, "admission", "accepted")[1], 0)
                @Expect(probe.snapshot()[3], 2)
            } finally {
                probe.release(64)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func s2U1MemorySnapshotMatchesActiveAndQueuedSchedulerScalars(): Unit {
        withIsolatedServicePluginHostTestHome("s2-u1-memory-snapshot", { home: Path =>
            let eventIds = this.gitCodeBurstEventIds("s2-u1", 32)
            let ackMarker = home.join("acks.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let probe = ServicePluginBurstProbe()
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeAckBurstScript(eventIds))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>(); rows.add(ServicePluginDeliveryTarget("telegram", "s2", "peer")); rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    probe.enterAndWait(event.eventId); ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String => ServicePluginEventDeliveryResult(true, "sent") }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(probe.awaitEntered(2, 3000), true)
                let scheduler = this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest =>
                    row.active == 2 && row.queued == 30 && row.accepted == 32 && row.futures == 2
                }).getOrThrow()
                let memory = servicePluginDispatchMemorySnapshot("gitcode-monitor").getOrThrow()
                @Expect(memory.active, scheduler.active)
                @Expect(memory.queued, scheduler.queued)
                @Expect(memory.accepted, scheduler.accepted)
                @Expect(memory.futures, scheduler.futures)
                @Expect(memory.highWater, scheduler.queueHighWatermark)
                @Expect(memory.queueFull, scheduler.queueFull)
                @Expect(memory.fenced, !scheduler.accepting)
            } finally {
                probe.release(64)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func s2B1ConcurrentMemorySnapshotsStayBoundedWhileWorkersAreHeld(): Unit {
        withIsolatedServicePluginHostTestHome("s2-b1-memory-snapshot", { home: Path =>
            let eventIds = this.gitCodeBurstEventIds("s2-b1", 4)
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let probe = ServicePluginBurstProbe()
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", home.join("acks.marker").toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeAckBurstScript(eventIds))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>(); rows.add(ServicePluginDeliveryTarget("telegram", "s2", "peer")); rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    probe.enterAndWait(event.eventId); ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String => ServicePluginEventDeliveryResult(true, "sent") }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(probe.awaitEntered(2, 3000), true)
                for (_ in 0..100) {
                    let row = servicePluginDispatchMemorySnapshot("gitcode-monitor").getOrThrow()
                    @Expect(row.active <= 2, true)
                    @Expect(row.queued <= 128, true)
                    @Expect(row.futures <= 2, true)
                }
            } finally {
                probe.release(16)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func s1cB1QueueFullAcksAndRetryContinuesPump(): Unit {
        withIsolatedServicePluginHostTestHome("s1c-b1-queue-full", { home: Path =>
            let eventIds = this.gitCodeBurstEventIds("s1c-b1-中文🙂", 131)
            let ackMarker = home.join("acks.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let probe = ServicePluginBurstProbe()
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeAckBurstScript(eventIds, retryLastOnQueueFull: true))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent => let rows = ArrayList<ServicePluginDeliveryTarget>(); rows.add(ServicePluginDeliveryTarget("telegram", "s1c", "peer")); rows }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget => probe.enterAndWait(event.eventId); ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId) }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String => ServicePluginEventDeliveryResult(true, "sent") }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                let full = this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest => row.active == 2 && row.queued == 128 && row.queueFull == 1 }).getOrThrow()
                @Expect(full.futures, 2)
                @Expect(this.waitForAckMarkerCount(ackMarker, "admission", "queue_full", 1), true)
                probe.release(3)
                @Expect(probe.awaitCompleted(3, 3000), true)
                @Expect(this.waitForAckMarkerCount(ackMarker, "admission", "accepted", 1, attemptToken: "attempt-131-2"), true)
                @Expect(this.ackMarkerCounts(ackMarker, "admission", "accepted", attemptToken: "attempt-131-2")[0], 1)
                @Expect(this.ackMarkerCounts(ackMarker, "admission", "queue_full", attemptToken: "attempt-131-2")[0], 0)
                @Expect(this.ackMarkerCounts(ackMarker, "admission", "accepted")[1], 0)
                let retried = servicePluginDispatchSchedulerSnapshotForTest("gitcode-monitor").getOrThrow()
                @Expect(retried.queueFull, 1)
                @Expect(retried.active <= 2, true); @Expect(retried.queued <= 128, true); @Expect(retried.futures <= 2, true)
                probe.release(256)
                @Expect(this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest => row.settled }, timeoutMillis: 15000).isSome(), true)
                @Expect(probe.callsFor(eventIds[eventIds.size - 1]), 1)
            } finally {
                probe.release(256)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func bpS2P1LostAdmissionRestoredBeforeCompletionWithoutRepeatedEffect(): Unit {
        withIsolatedServicePluginHostTestHome("bp-s2-p1-admission", { home: Path =>
            resetServicePluginGeneratedReplyStateForTest()
            let eventId = "gitcode:Cangjie/community:issue:bp-s2-p1-中文🙂"
            let deliveryId = "bp-s2-p1-delivery"
            let attemptToken = "bp-s2-p1-attempt"
            let marker = home.join("acks.marker")
            let writebacks = home.join("writebacks.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let oldWriteback = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
            let models = ServicePluginEventLedger()
            let deliveries = ServicePluginEventLedger()
            let store = ServicePluginWebhookReceiptStore(home.join("service-plugin").join("webhook-receipts").toString())
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", marker.toString())
            setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebacks.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeMissingAdmissionScript(eventId, deliveryId, attemptToken))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "bp-s2", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    models.record(event.eventId)
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    deliveries.recordMatching(text, [eventId])
                    ServicePluginEventDeliveryResult(true, "sent")
                }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForAckMarkerCount(marker, "completion", "completed", 2, timeoutMillis: 5000), true)
                @Expect(this.waitForDispatchCounts("gitcode-monitor", 0, 0, timeoutMillis: 5000), true)
                @Expect(this.ackMarkerCounts(marker, "admission", "accepted")[0], 2)
                @Expect(store.state("gitcode-monitor", deliveryId, eventId), "missing")
                @Expect(models.countFor(eventId), 1)
                @Expect(deliveries.countFor(eventId), 1)
                @Expect(this.textFileCount(writebacks, eventId), 1)
                @Expect(flushServicePluginUnconfirmedReceiptsForTest("gitcode-monitor"), 0)
                @Expect(stopServicePlugin("gitcode-monitor", reason: "bp-s2-p1-complete", timeoutMillis: 3000).ok, true)
            } finally {
                resetServicePluginGeneratedReplyStateForTest()
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                match (oldWriteback) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func bpS2N1OtherOrMalformedResponsesNeverReplayAdmission(): Unit {
        for (kind in ["other_status", "wrong_attempt", "wrong_protocol", "malformed_ok"]) {
        withIsolatedServicePluginHostTestHome("bp-s2-n1-response-${kind}", { home: Path =>
            resetServicePluginGeneratedReplyStateForTest()
            let eventId = "gitcode:Cangjie/community:issue:bp-s2-n1-${kind}-中文🙂"
            let deliveryId = "bp-s2-n1-${kind}-delivery"
            let attemptToken = "bp-s2-n1-${kind}-attempt"
            let marker = home.join("acks.marker")
            let writebacks = home.join("writebacks.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let oldWriteback = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
            let models = ServicePluginEventLedger()
            let deliveries = ServicePluginEventLedger()
            let store = ServicePluginWebhookReceiptStore(home.join("service-plugin").join("webhook-receipts").toString())
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", marker.toString())
            setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebacks.toString())
            try {
                let normal = this.gitCodeMissingAdmissionScript(eventId, deliveryId, attemptToken)
                let script = match (kind) {
                    case "other_status" => normal.replace("confirm_status=completion_before_admission", "confirm_status=retry")
                    case "wrong_attempt" => normal.replace("\"$attempt\"", "\"stale-attempt\"")
                    case "wrong_protocol" => normal.replace("1.0", "0.9")
                    case _ => normal.replace("\"ok\":%s", "\"ok\":\"%s\"")
                }
                this.registerGitCodeStdioScript(script)
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "bp-s2", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    models.record(event.eventId)
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    deliveries.recordMatching(text, [eventId])
                    ServicePluginEventDeliveryResult(true, "sent")
                }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForAckMarkerCount(marker, "completion", "completed", 1, timeoutMillis: 5000), true)
                @Expect(this.waitForDispatchCounts("gitcode-monitor", 0, 0, timeoutMillis: 5000), true)
                @Expect(this.ackMarkerCounts(marker, "admission", "accepted")[0], 1)
                @Expect(store.state("gitcode-monitor", deliveryId, eventId), "completed_unconfirmed")
                @Expect(models.countFor(eventId), 1)
                @Expect(deliveries.countFor(eventId), 1)
                @Expect(this.textFileCount(writebacks, eventId), 1)
                @Expect(flushServicePluginUnconfirmedReceiptsForTest("gitcode-monitor"), 0)
                @Expect(stopServicePlugin("gitcode-monitor", reason: "bp-s2-p1-complete", timeoutMillis: 3000).ok, true)
            } finally {
                resetServicePluginGeneratedReplyStateForTest()
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                match (oldWriteback) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "") }
            }
        })
        }
    }

    @TestCase
    public func bpS2N1ReplayFailureRetainsReceiptUntilConfirmed(): Unit {
        withIsolatedServicePluginHostTestHome("bp-s2-n1-admission", { home: Path =>
            resetServicePluginGeneratedReplyStateForTest()
            let eventId = "gitcode:Cangjie/community:issue:bp-s2-n1-中文🙂"
            let deliveryId = "bp-s2-n1-delivery"
            let attemptToken = "bp-s2-n1-attempt"
            let marker = home.join("acks.marker")
            let writebacks = home.join("writebacks.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let oldWriteback = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
            let models = ServicePluginEventLedger()
            let deliveries = ServicePluginEventLedger()
            let store = ServicePluginWebhookReceiptStore(home.join("service-plugin").join("webhook-receipts").toString())
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", marker.toString())
            setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebacks.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeMissingAdmissionScript(eventId, deliveryId, attemptToken))
                let admissions = ServicePluginTestCounter()
                setServicePluginEventAckWrittenHookForTest(Some({ _frameId: String, phase: String, _status: String, _snapshot: ServicePluginDispatchSchedulerSnapshotForTest =>
                    if (phase == "admission") {
                        admissions.increment()
                        if (admissions.get() == 2) { throw Exception("synthetic_replay_failure") }
                    }
                }))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "bp-s2", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    models.record(event.eventId)
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    deliveries.recordMatching(text, [eventId])
                    ServicePluginEventDeliveryResult(true, "sent")
                }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(deliveries.awaitTotal(1, 5000), true)
                @Expect(this.waitForDispatchCounts("gitcode-monitor", 0, 0, timeoutMillis: 5000), true)
                @Expect(admissions.get(), 2)
                @Expect(this.ackMarkerCounts(marker, "completion", "completed")[0], 1)
                @Expect(store.state("gitcode-monitor", deliveryId, eventId), "completed_unconfirmed")
                setServicePluginEventAckWrittenHookForTest(None<(String, String, String, ServicePluginDispatchSchedulerSnapshotForTest) -> Unit>)
                @Expect(flushServicePluginUnconfirmedReceiptsForTest("gitcode-monitor"), 1)
                @Expect(this.waitForAckMarkerCount(marker, "completion", "completed", 2, timeoutMillis: 3000), true)
                @Expect(store.state("gitcode-monitor", deliveryId, eventId), "missing")
                @Expect(models.countFor(eventId), 1)
                @Expect(deliveries.countFor(eventId), 1)
                @Expect(this.textFileCount(writebacks, eventId), 1)
                @Expect(flushServicePluginUnconfirmedReceiptsForTest("gitcode-monitor"), 0)
                @Expect(stopServicePlugin("gitcode-monitor", reason: "bp-s2-n1-complete", timeoutMillis: 3000).ok, true)
            } finally {
                resetServicePluginGeneratedReplyStateForTest()
                setServicePluginEventAckWrittenHookForTest(None<(String, String, String, ServicePluginDispatchSchedulerSnapshotForTest) -> Unit>)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                match (oldWriteback) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func c06StopRestartFlushesOutboxWithoutSideEffectReplay(): Unit {
        withIsolatedServicePluginHostTestHome("h-s5-n1-02", { home: Path =>
            let eventId = "gitcode:Cangjie/community:issue:h-s5-n1-02"
            let ackMarker = home.join("acks.marker")
            let writebackMarker = home.join("writebacks.marker")
            let receiptRoot = home.join("service-plugin").join("webhook-receipts")
            let receiptPath = ServicePluginWebhookReceiptStore(receiptRoot.toString()).receiptPathForTest("gitcode-monitor", "delivery-h-s5-n1-02", eventId)
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let oldWriteback = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
            let models = ServicePluginEventLedger()
            let deliveries = ServicePluginEventLedger()
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
            setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebackMarker.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeSingleAckScript(eventId, "delivery-h-s5-n1-02", "attempt-old", "receipt-old"))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent => let rows = ArrayList<ServicePluginDeliveryTarget>(); rows.add(ServicePluginDeliveryTarget("telegram", "receipt", "peer")); rows }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget => models.record(event.eventId); ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId) }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String => deliveries.recordMatching(text, [eventId]); ServicePluginEventDeliveryResult(true, "sent") }))
                setServicePluginBeforeCompletionAckHookForTest(Some({ _frameId: String => false }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(deliveries.awaitTotal(1, 5000), true)
                @Expect(this.waitForDispatchCounts("gitcode-monitor", 0, 0, timeoutMillis: 3000), true)
                let unconfirmedReceipt = JsonValue.fromStr(this.readTextFile(receiptPath)).asObject()
                @Expect(unconfirmedReceipt.get("state").getOrThrow().asString().getValue(), "completed_unconfirmed")
                @Expect(this.ackMarkerCounts(ackMarker, "completion", "completed")[0], 0)
                @Expect(stopServicePlugin("gitcode-monitor", reason: "receipt-owner-replacement", timeoutMillis: 3000).ok, true)

                resetServicePluginGeneratedReplyStateForTest()
                this.registerGitCodeStdioScript(this.gitCodeSingleAckScript(eventId, "delivery-h-s5-n1-02", "attempt-new", "receipt-new"))
                setServicePluginBeforeCompletionAckHookForTest(None<(String) -> Bool>)
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                let replacementIdentity = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()
                let replacementSnapshot = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(replacementSnapshot.status, "running")
                @Expect(replacementSnapshot.pid > 0, true)
                @Expect(this.waitForAckMarkerCount(ackMarker, "completion", "completed", 1, attemptToken: "attempt-new", timeoutMillis: 5000), true)
                @Expect(this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest => row.settled }, timeoutMillis: 5000).isSome(), true)
                let settledIdentity = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()
                let settledSnapshot = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(settledIdentity[0], replacementIdentity[0])
                @Expect(settledIdentity[1], replacementIdentity[1])
                @Expect(settledSnapshot.status, "running")
                @Expect(settledSnapshot.pid, replacementSnapshot.pid)
                let responseQueue = servicePluginResponseQueueCountsForTest("gitcode-monitor").getOrThrow()
                @Expect(responseQueue[0], 0)
                @Expect(responseQueue[1], 0)
                @Expect(exists(receiptPath), false)
                @Expect(models.countFor(eventId), 1)
                @Expect(deliveries.countFor(eventId), 1)
                @Expect(this.textFileCount(writebackMarker, eventId), 1)
                @Expect(stopServicePlugin("gitcode-monitor", reason: "receipt-replacement-complete", timeoutMillis: 3000).ok, true)
            } finally {
                setServicePluginBeforeCompletionAckHookForTest(None<(String) -> Bool>)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                match (oldWriteback) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func c04CompletionTimeoutAndWrongResponseCorrelationsDoNotLeakQueue(): Unit {
        let proof = servicePluginResponseQueueExpiryProofForTest()
        @Expect(proof[0], "timeout")
        @Expect(proof[1], 0)
        @Expect(proof[2], "unexpected_frame")
        @Expect(proof[3], 0)
        @Expect(proof[4], 0)
    }

    @TestCase
    public func c05DroppedProcessedResponseIsFlushedAsAlreadyCompleted(): Unit {
        withIsolatedServicePluginHostTestHome("c05-confirm-flush", { home: Path =>
            let eventId = "gitcode:Cangjie/community:issue:c05-confirm-flush"
            let deliveryId = "delivery-c05"
            let attemptToken = "attempt-c05"
            let ackMarker = home.join("acks.marker")
            let writebackMarker = home.join("writebacks.marker")
            let receiptPath = ServicePluginWebhookReceiptStore(home.join("service-plugin").join("webhook-receipts").toString()).receiptPathForTest("gitcode-monitor", deliveryId, eventId)
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let oldWriteback = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
            let models = ServicePluginEventLedger()
            let deliveries = ServicePluginEventLedger()
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
            setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebackMarker.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeDropFirstCompletionResponseScript(eventId, deliveryId, attemptToken))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "receipt", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    models.record(event.eventId)
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    deliveries.recordMatching(text, [eventId])
                    ServicePluginEventDeliveryResult(true, "sent")
                }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(deliveries.awaitTotal(1, 5000), true)
                @Expect(this.waitForDispatchCounts("gitcode-monitor", 0, 0, timeoutMillis: 6000), true)
                @Expect(exists(receiptPath), true)
                let unconfirmedReceipt = JsonValue.fromStr(this.readTextFile(receiptPath)).asObject()
                @Expect(unconfirmedReceipt.get("state").getOrThrow().asString().getValue(), "completed_unconfirmed")
                let beforeMarker = this.ackMarkerCounts(ackMarker, "completion", "completed")
                @Expect(beforeMarker[0], 1)
                @Expect(beforeMarker[1], 0)
                let beforeIdentity = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()
                let beforeSnapshot = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(beforeSnapshot.status, "running")
                @Expect(beforeSnapshot.pid > 0, true)
                let beforeQueue = servicePluginResponseQueueCountsForTest("gitcode-monitor").getOrThrow()
                @Expect(beforeQueue[0], 0)
                @Expect(beforeQueue[1], 0)
                @Expect(flushServicePluginUnconfirmedReceiptsForTest("gitcode-monitor"), 1)
                @Expect(exists(receiptPath), false)
                let afterIdentity = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()
                let afterSnapshot = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(afterIdentity[0], beforeIdentity[0])
                @Expect(afterIdentity[1], beforeIdentity[1])
                @Expect(afterSnapshot.status, "running")
                @Expect(afterSnapshot.pid, beforeSnapshot.pid)
                let afterMarker = this.ackMarkerCounts(ackMarker, "completion", "completed")
                @Expect(afterMarker[0], 2)
                @Expect(afterMarker[1], 0)
                let afterQueue = servicePluginResponseQueueCountsForTest("gitcode-monitor").getOrThrow()
                @Expect(afterQueue[0], 0)
                @Expect(afterQueue[1], 0)
                @Expect(models.countFor(eventId), 1)
                @Expect(deliveries.countFor(eventId), 1)
                @Expect(this.textFileCount(writebackMarker, eventId), 1)
            } finally {
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                match (oldWriteback) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func c11StopCancelsOnlyCompletionWaitAndRestartFlushesReceipt(): Unit {
        withIsolatedServicePluginHostTestHome("c11-stop-confirm", { home: Path =>
            let eventId = "gitcode:Cangjie/community:issue:c11-stop-confirm"
            let deliveryId = "delivery-c11"
            let oldAttempt = "attempt-c11-old"
            let ackMarker = home.join("acks.marker")
            let writebackMarker = home.join("writebacks.marker")
            let store = ServicePluginWebhookReceiptStore(home.join("service-plugin").join("webhook-receipts").toString())
            let receiptPath = store.receiptPathForTest("gitcode-monitor", deliveryId, eventId)
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let oldWriteback = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
            let models = ServicePluginEventLedger()
            let deliveries = ServicePluginEventLedger()
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
            setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebackMarker.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeDropFirstCompletionResponseScript(eventId, deliveryId, oldAttempt))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "receipt", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget => models.record(event.eventId); ServicePluginGeneratedReplyResult(true, draft: event.eventId) }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String => deliveries.recordMatching(text, [eventId]); ServicePluginEventDeliveryResult(true, "sent") }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForAckMarkerCount(ackMarker, "completion", "completed", 1, timeoutMillis: 5000), true)
                let stopStarted = DateTime.now().toUnixTimeStamp().toMilliseconds()
                let stopped = stopServicePlugin("gitcode-monitor", reason: "c11-stop-confirm", timeoutMillis: 1500)
                let stopElapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - stopStarted
                @Expect(stopped.ok, true)
                @Expect(stopElapsed < 1500, true)
                @Expect(exists(receiptPath), true)
                @Expect(store.state("gitcode-monitor", deliveryId, eventId), "completed_unconfirmed")
                @Expect(models.countFor(eventId), 1)
                @Expect(deliveries.countFor(eventId), 1)

                resetServicePluginGeneratedReplyStateForTest()
                this.registerGitCodeStdioScript(this.gitCodeSingleAckScript(eventId, deliveryId, "attempt-c11-new", "c11-replay"))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                let replacementIdentity = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()
                let replacementSnapshot = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(replacementSnapshot.status, "running")
                @Expect(replacementSnapshot.pid > 0, true)
                @Expect(this.waitForAckMarkerCount(ackMarker, "completion", "completed", 1, attemptToken: "attempt-c11-new", timeoutMillis: 5000), true)
                @Expect(this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest => row.settled }, timeoutMillis: 5000).isSome(), true)
                let oldMarkers = this.ackMarkerCounts(ackMarker, "completion", "completed", attemptToken: oldAttempt)
                let newMarkers = this.ackMarkerCounts(ackMarker, "completion", "completed", attemptToken: "attempt-c11-new")
                @Expect(oldMarkers[0] >= 1, true)
                @Expect(newMarkers[0] >= 1, true)
                @Expect(oldMarkers[1], 0)
                @Expect(newMarkers[1], 0)
                let settledIdentity = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()
                let settledSnapshot = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(settledIdentity[0], replacementIdentity[0])
                @Expect(settledIdentity[1], replacementIdentity[1])
                @Expect(settledSnapshot.status, "running")
                @Expect(settledSnapshot.pid, replacementSnapshot.pid)
                let responseQueue = servicePluginResponseQueueCountsForTest("gitcode-monitor").getOrThrow()
                @Expect(responseQueue[0], 0)
                @Expect(responseQueue[1], 0)
                @Expect(models.countFor(eventId), 1)
                @Expect(deliveries.countFor(eventId), 1)
                @Expect(this.textFileCount(writebackMarker, eventId), 1)
                @Expect(exists(receiptPath), false)
            } finally {
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                match (oldWriteback) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func s1cP1ThirtyTwoAckEventsDrainExactlyOnce(): Unit {
        withIsolatedServicePluginHostTestHome("s1c-p1-drain", { home: Path =>
            let eventIds = this.gitCodeBurstEventIds("s1c-p1-中文🙂", 32)
            let ackMarker = home.join("acks.marker")
            let writebackMarker = home.join("writebacks.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let oldWriteback = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
            let models = ServicePluginEventLedger()
            let deliveries = ServicePluginEventLedger()
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString()); setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebackMarker.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeAckBurstScript(eventIds))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent => let rows = ArrayList<ServicePluginDeliveryTarget>(); rows.add(ServicePluginDeliveryTarget("telegram", "s1c", "peer")); rows }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget => models.record(event.eventId); ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId) }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String => deliveries.recordMatching(text, eventIds); ServicePluginEventDeliveryResult(true, "sent") }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(deliveries.awaitTotal(32, 10000), true)
                @Expect(this.waitForAckMarkerCount(ackMarker, "completion", "completed", 32, timeoutMillis: 5000), true)
                @Expect(this.ackMarkerCounts(ackMarker, "completion", "completed")[1], 0)
                @Expect(this.waitForDispatchCounts("gitcode-monitor", 0, 0, timeoutMillis: 3000), true)
                for (eventId in eventIds) { @Expect(models.countFor(eventId), 1); @Expect(deliveries.countFor(eventId), 1); @Expect(this.textFileCount(writebackMarker, eventId), 1) }
            } finally {
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>); setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                match (oldWriteback) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func s3MemoryP1HundredUniqueGitCodeEventsDrainExactlyOnce(): Unit {
        withIsolatedServicePluginHostTestHome("s3-memory-p1-hundred", { home: Path =>
            let eventIds = this.gitCodeBurstEventIds("s3-memory-p1", 100)
            let ackMarker = home.join("acks.marker")
            let writebackMarker = home.join("writebacks.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let oldWriteback = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
            let models = ServicePluginEventLedger()
            let deliveries = ServicePluginEventLedger()
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
            setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebackMarker.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeAckBurstScript(eventIds))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "s3-memory", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    models.record(event.eventId)
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    deliveries.recordMatching(text, eventIds)
                    ServicePluginEventDeliveryResult(true, "sent")
                }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(deliveries.awaitTotal(100, 15000), true)
                @Expect(this.waitForAckMarkerCount(ackMarker, "completion", "completed", 100, timeoutMillis: 10000), true)
                @Expect(this.ackMarkerCounts(ackMarker, "completion", "completed")[1], 0)
                @Expect(this.waitForDispatchCounts("gitcode-monitor", 0, 0, timeoutMillis: 5000), true)
                let memory = servicePluginDispatchMemorySnapshot("gitcode-monitor").getOrThrow()
                @Expect(memory.active, 0)
                @Expect(memory.queued, 0)
                @Expect(memory.futures, 0)
                @Expect(memory.accepted, 0)
                @Expect(memory.highWater <= 128, true)
                @Expect(memory.queueFull, 0)
                for (eventId in eventIds) {
                    @Expect(models.countFor(eventId), 1)
                    @Expect(deliveries.countFor(eventId), 1)
                    @Expect(this.textFileCount(writebackMarker, eventId), 1)
                }
            } finally {
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                match (oldWriteback) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func s1cN1LaunchAndRegisterFailuresRollbackWithoutFutureLeak(): Unit {
        for (phase in ["launch", "register"]) {
            withIsolatedServicePluginHostTestHome("s1c-n1-${phase}", { home: Path =>
                let ackMarker = home.join("acks.marker")
                let writebackMarker = home.join("writebacks.marker")
                let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
                let oldWriteback = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
                let models = ServicePluginEventLedger()
                let deliveries = ServicePluginEventLedger()
                let settledWorkers = ServicePluginEventLedger()
                setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
                setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebackMarker.toString())
                try {
                    this.registerGitCodeStdioScript(this.gitCodeAckBurstScript(this.gitCodeBurstEventIds("s1c-n1-${phase}", 1)))
                    setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent => let rows = ArrayList<ServicePluginDeliveryTarget>(); rows.add(ServicePluginDeliveryTarget("telegram", "s1c", "peer")); rows }))
                    setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget => models.record(event.eventId); ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId) }))
                    setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String => deliveries.record(text); ServicePluginEventDeliveryResult(true, "sent") }))
                    if (phase == "launch") { setServicePluginDispatchLaunchHookForTest(Some({ _id: String => throw Exception("launch failed") })) }
                    else {
                        setServicePluginDispatchWorkerSettledHookForTest(Some({ id: String => settledWorkers.record(id) }))
                        setServicePluginDispatchRegisterHookForTest(Some({ _id: String => throw Exception("register failed") }))
                    }
                    @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                    @Expect(this.waitForAckMarkerCount(ackMarker, "admission", "retry", 1), true)
                    @Expect(this.ackMarkerCounts(ackMarker, "admission", "retry")[1], 0)
                    let settled = this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest => row.settled }).getOrThrow()
                    @Expect(settled.active, 0); @Expect(settled.accepted, 0); @Expect(settled.futures, 0)
                    @Expect(models.totalCount(), 0); @Expect(deliveries.totalCount(), 0); @Expect(exists(writebackMarker), false)
                    if (phase == "register") { @Expect(settledWorkers.totalCount(), 1) }
                } finally {
                    setServicePluginDispatchLaunchHookForTest(None<(String) -> Unit>); setServicePluginDispatchRegisterHookForTest(None<(String) -> Unit>)
                    setServicePluginDispatchWorkerSettledHookForTest(None<(String) -> Unit>)
                    setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                    setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>); setServicePluginEventDeliveryForTest(None)
                    match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                    match (oldWriteback) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "") }
                }
            })
        }
    }

    @TestCase
    public func s1cN3FenceDuringAcceptedAckPreventsLaunchAndSettlesReservation(): Unit {
        withIsolatedServicePluginHostTestHome("s1c-n3-ack-fence", { home: Path =>
            let eventIds = this.gitCodeBurstEventIds("s1c-n3-fence", 1)
            let ackMarker = home.join("acks.marker")
            let writebackMarker = home.join("writebacks.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let oldWriteback = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
            let acceptedGate = ServicePluginTestGate()
            let cancelledGate = ServicePluginTestGate()
            let models = ServicePluginEventLedger()
            let deliveries = ServicePluginEventLedger()
            let snapshotLock = Mutex()
            let cancelledSnapshots = ArrayList<ServicePluginDispatchSchedulerSnapshotForTest>()
            var stopper = None<Future<ServiceStopResult>>
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
            setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebackMarker.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeAckBurstScript(eventIds))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "s1c", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    models.record(event.eventId)
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    deliveries.record(text)
                    ServicePluginEventDeliveryResult(true, "sent")
                }))
                setServicePluginEventAckWrittenHookForTest(Some({ _frameId: String, phase: String, status: String, snapshot: ServicePluginDispatchSchedulerSnapshotForTest =>
                    if (phase == "admission" && status == "accepted") {
                        acceptedGate.enterAndWait()
                    } else if (phase == "admission" && status == "cancelled") {
                        synchronized(snapshotLock) { cancelledSnapshots.add(snapshot) }
                        cancelledGate.signal()
                    }
                }))

                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(acceptedGate.awaitEntered(2000), true)
                stopper = Some(spawn { stopServicePlugin("gitcode-monitor", reason: "s1c-n3-fence", timeoutMillis: 5000) })
                let fenced = this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest =>
                    !row.accepting && row.active == 1 && row.accepted == 1 && row.futures == 0
                }).getOrThrow()
                @Expect(fenced.queued, 0)
                acceptedGate.release()
                @Expect(cancelledGate.awaitEntered(2000), true)
                @Expect(synchronized(snapshotLock) { cancelledSnapshots.size }, 1)
                let settled = synchronized(snapshotLock) { cancelledSnapshots[0] }
                @Expect(settled.active, 0)
                @Expect(settled.queued, 0)
                @Expect(settled.accepted, 0)
                @Expect(settled.futures, 0)
                @Expect(settled.settled, true)
                let stopped = stopper.getOrThrow().get(Duration.second * 6)
                stopper = None<Future<ServiceStopResult>>
                @Expect(stopped.ok, true)
                @Expect(stopped.status, "stopped")
                @Expect(stopped.dispatchStatus, "drained")
                @Expect(this.waitForAckMarkerCount(ackMarker, "admission", "accepted", 1), true)
                @Expect(this.waitForAckMarkerCount(ackMarker, "admission", "cancelled", 1), true)
                @Expect(this.ackMarkerCounts(ackMarker, "admission", "accepted")[1], 0)
                @Expect(this.ackMarkerCounts(ackMarker, "admission", "cancelled")[1], 0)
                @Expect(models.totalCount(), 0)
                @Expect(deliveries.totalCount(), 0)
                @Expect(exists(writebackMarker), false)
            } finally {
                acceptedGate.release()
                setServicePluginEventAckWrittenHookForTest(None<(String, String, String, ServicePluginDispatchSchedulerSnapshotForTest) -> Unit>)
                match (stopper) {
                    case Some(future) => try { let _ = future.get(Duration.second * 6) } catch (_: Exception) { () }
                    case None => ()
                }
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                match (oldWriteback) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func s1cN2PartialAckMetadataIsRejectedWithoutSideEffects(): Unit {
        for (variant in [
            "delivery-missing", "attempt-missing", "delivery-empty", "delivery-null", "delivery-number",
            "attempt-empty", "attempt-null", "attempt-number"
        ]) {
            withIsolatedServicePluginHostTestHome("s1c-n2-${variant}", { home: Path =>
                let eventId = "gitcode:Cangjie/community:issue:s1c-n2-${variant}"
                let ackMarker = home.join("acks.marker")
                let writebackMarker = home.join("writebacks.marker")
                let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
                let oldWriteback = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
                let models = ServicePluginEventLedger()
                let deliveries = ServicePluginEventLedger()
                let valid = this.gitCodeAcceptedEventLine(
                    eventId: eventId, frameId: "s1c-${variant}", deliveryId: "delivery-valid",
                    attemptToken: "attempt-valid"
                )
                let invalid = match (variant) {
                    case "delivery-missing" => this.gitCodeAcceptedEventLine(
                        eventId: eventId, frameId: "s1c-${variant}", attemptToken: "attempt-valid"
                    )
                    case "attempt-missing" => this.gitCodeAcceptedEventLine(
                        eventId: eventId, frameId: "s1c-${variant}", deliveryId: "delivery-valid",
                        frameCorrelationId: "attempt-valid"
                    )
                    case "delivery-empty" => valid.replace("\"deliveryId\":\"delivery-valid\"", "\"deliveryId\":\"\"")
                    case "delivery-null" => valid.replace("\"deliveryId\":\"delivery-valid\"", "\"deliveryId\":null")
                    case "delivery-number" => valid.replace("\"deliveryId\":\"delivery-valid\"", "\"deliveryId\":7")
                    case "attempt-empty" => valid.replace("\"attemptToken\":\"attempt-valid\"", "\"attemptToken\":\"\"")
                    case "attempt-null" => valid.replace("\"attemptToken\":\"attempt-valid\"", "\"attemptToken\":null")
                    case "attempt-number" => valid.replace("\"attemptToken\":\"attempt-valid\"", "\"attemptToken\":7")
                    case _ => valid
                }
                let script = "printf '%s\\n' '${this.gitCodeInitLine()}'; printf '%s\\n' '${invalid}'; while IFS= read -r request; do case \"$request\" in *emitCapabilityEvent*) printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_MARKER_PATH\";; *stop*) break;; esac; done"
                setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
                setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebackMarker.toString())
                try {
                    this.registerGitCodeStdioScript(script)
                    setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                        let rows = ArrayList<ServicePluginDeliveryTarget>()
                        rows.add(ServicePluginDeliveryTarget("telegram", "s1c", "peer"))
                        rows
                    }))
                    setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                        models.record(event.eventId)
                        ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                    }))
                    setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                        deliveries.record(text)
                        ServicePluginEventDeliveryResult(true, "sent")
                    }))
                    @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                    @Expect(this.waitForSnapshotReason("gitcode-monitor", "invalid_event_ack_identity"), true)
                    let counts = servicePluginDispatchCountsForTest("gitcode-monitor").getOrThrow()
                    @Expect(counts[2], 0)
                    @Expect(counts[3], 0)
                    @Expect(models.totalCount(), 0)
                    @Expect(deliveries.totalCount(), 0)
                    @Expect(exists(writebackMarker), false)
                    @Expect(exists(ackMarker), false)
                    let snapshot = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                    @Expect(snapshot.status, "running")
                    @Expect(snapshot.lastError, "invalid_event_ack_identity")
                } finally {
                    setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                    setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                    setServicePluginEventDeliveryForTest(None)
                    match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                    match (oldWriteback) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "") }
                }
            })
        }
    }

    @TestCase
    public func s2U1FenceCancelsThirtyQueuedAndKeepsOnlyTwoActive(): Unit {
        withIsolatedServicePluginHostTestHome("s2-u1-fence-queued", { home: Path =>
            let eventIds = this.gitCodeBurstEventIds("s2-u1-fence", 32)
            let ackMarker = home.join("acks.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let probe = ServicePluginBurstProbe()
            let waitGate = ServicePluginTestGate()
            let snapshotLock = Mutex()
            let fencedSnapshots = ArrayList<ServicePluginDispatchSchedulerSnapshotForTest>()
            var stopper = None<Future<ServiceStopResult>>
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeAckBurstScript(eventIds))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "s2", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    probe.enterAndWait(event.eventId)
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String =>
                    ServicePluginEventDeliveryResult(true, "sent")
                }))
                setServicePluginBeforeDispatchWaitForTest(Some({ _waitMs: Int64 =>
                    match (servicePluginDispatchSchedulerSnapshotForTest("gitcode-monitor")) {
                        case Some(snapshot) => synchronized(snapshotLock) { fencedSnapshots.add(snapshot) }
                        case None => ()
                    }
                    waitGate.enterAndWait()
                }))

                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(probe.awaitEntered(2, 3000), true)
                let loaded = this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest =>
                    row.active == 2 && row.queued == 30 && row.accepted == 32 && row.futures == 2
                }).getOrThrow()
                @Expect(loaded.queueHighWatermark, 30)
                stopper = Some(spawn { stopServicePlugin("gitcode-monitor", reason: "s2-u1", timeoutMillis: 5000) })
                @Expect(waitGate.awaitEntered(2000), true)
                @Expect(synchronized(snapshotLock) { fencedSnapshots.size }, 1)
                let fenced = synchronized(snapshotLock) { fencedSnapshots[0] }
                @Expect(fenced.active, 2)
                @Expect(fenced.queued, 0)
                @Expect(fenced.accepted, 2)
                @Expect(fenced.futures, 2)
                @Expect(fenced.cancelled, 30)
                @Expect(fenced.accepting, false)
                @Expect(this.waitForAckMarkerCount(ackMarker, "admission", "cancelled", 30), true)
                @Expect(this.ackMarkerCounts(ackMarker, "admission", "cancelled")[1], 0)
                @Expect(probe.snapshot()[0], 2)
                probe.release(2)
                waitGate.release()
                let stopped = stopper.getOrThrow().get(Duration.second * 6)
                stopper = None<Future<ServiceStopResult>>
                @Expect(stopped.ok, true)
                @Expect(stopped.status, "stopped")
                @Expect(stopped.dispatchStatus, "drained")
            } finally {
                probe.release(64)
                waitGate.release()
                setServicePluginBeforeDispatchWaitForTest(None<(Int64) -> Unit>)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (stopper) { case Some(future) => try { let _ = future.get(Duration.second * 6) } catch (_: Exception) { () } case None => () }
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func s2B1DeadlineMinusEqualPlusOneKeepsInclusiveStopTruth(): Unit {
        this.s3B1DispatchPastReserveIsCleanupPendingUntilExactRetry()
    }

    @TestCase
    public func s2P1TwelveQueuedEventsDrainExactlyOnceBeforeFullTerminalStop(): Unit {
        withIsolatedServicePluginHostTestHome("s2-p1-drain-terminal", { home: Path =>
            let eventIds = this.gitCodeBurstEventIds("s2-p1-drain", 12)
            let ackMarker = home.join("acks.marker")
            let writebackMarker = home.join("writebacks.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let oldWriteback = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
            let probe = ServicePluginBurstProbe()
            let deliveries = ServicePluginEventLedger()
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
            setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebackMarker.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeAckBurstScript(eventIds))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("feishu", "s2", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    probe.enterAndWait(event.eventId)
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    deliveries.recordMatching(text, eventIds)
                    ServicePluginEventDeliveryResult(true, "sent")
                }))

                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(probe.awaitEntered(2, 3000), true)
                let loaded = this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest =>
                    row.active == 2 && row.queued == 10 && row.accepted == 12 && row.futures == 2
                }).getOrThrow()
                @Expect(loaded.queueHighWatermark, 10)
                probe.release(12)
                @Expect(probe.awaitCompleted(12, 8000), true)
                @Expect(deliveries.awaitTotal(12, 8000), true)
                @Expect(this.waitForAckMarkerCount(ackMarker, "completion", "completed", 12, timeoutMillis: 5000), true)
                @Expect(this.ackMarkerCounts(ackMarker, "completion", "completed")[1], 0)
                let settled = this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest => row.settled }).getOrThrow()
                @Expect(settled.active, 0)
                @Expect(settled.queued, 0)
                @Expect(settled.accepted, 0)
                @Expect(settled.futures, 0)
                for (eventId in eventIds) {
                    @Expect(probe.callsFor(eventId), 1)
                    @Expect(deliveries.countFor(eventId), 1)
                    @Expect(this.textFileCount(writebackMarker, eventId), 1)
                }
                let stopped = stopServicePlugin("gitcode-monitor", reason: "s2-p1-full-terminal", timeoutMillis: 3000)
                @Expect(stopped.ok, true)
                @Expect(stopped.status, "stopped")
                @Expect(stopped.ingressStopStatus, "sent")
                @Expect(stopped.dispatchStatus, "drained")
                @Expect(stopped.leaseStatus, "not_applicable")
                @Expect(stopped.portStatus, "not_applicable")
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            } finally {
                probe.release(32)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                match (oldWriteback) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func s2N1OldGenerationLateFinishCannotPolluteReplacement(): Unit {
        withIsolatedServicePluginHostTestHome("s2-n1-old-generation", { home: Path =>
            let eventIds = this.gitCodeBurstEventIds("s2-n1-old", 12)
            let launchMarker = home.join("launch-count.marker")
            let ackMarker = home.join("acks.marker")
            let writebackMarker = home.join("writebacks.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let oldWriteback = getVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH")
            let dispatchGate = ServicePluginTestGate()
            let settledGate = ServicePluginTestGate()
            let settledWorkers = ServicePluginEventLedger()
            let models = ServicePluginEventLedger()
            let deliveries = ServicePluginEventLedger()
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
            setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", writebackMarker.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeFirstLaunchAckBurstScript(eventIds, launchMarker))
                setServicePluginBeforeEventDispatchHookForTest(Some({ _serviceId: String => dispatchGate.enterAndWait() }))
                setServicePluginDispatchSettledHookForTest(Some({ => settledGate.enterAndWait() }))
                setServicePluginDispatchWorkerSettledHookForTest(Some({ frameId: String => settledWorkers.record(frameId) }))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "s2", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    models.record(event.eventId)
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    deliveries.record(text)
                    ServicePluginEventDeliveryResult(true, "sent")
                }))

                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                let loaded = this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest =>
                    row.active == 2 && row.queued == 10 && row.accepted == 12 && row.futures == 2
                }).getOrThrow()
                let oldIdentity = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()
                @Expect(loaded.ownerId, oldIdentity[0])
                @Expect(loaded.generation, oldIdentity[1])
                @Expect(dispatchGate.awaitEntered(2000), true)
                setServicePluginDispatchRemainingForTest(Some({ => Int64(99) }))
                let pending = stopServicePlugin("gitcode-monitor", reason: "s2-n1-timeout", timeoutMillis: 200)
                @Expect(pending.ok, false)
                @Expect(pending.status, "cleanup_pending")
                @Expect(pending.dispatchStatus, "dispatch_pending")
                @Expect(servicePluginCleanupPendingCountForTest(), 1)
                @Expect(this.waitForAckMarkerCount(ackMarker, "admission", "cancelled", 10), true)

                setServicePluginDispatchRemainingForTest(None<() -> Int64>)
                dispatchGate.release()
                @Expect(settledGate.awaitEntered(2000), true)
                let cleanupDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 5000
                var retried = stopServicePlugin("gitcode-monitor", reason: "s2-n1-cleanup-retry", timeoutMillis: 500)
                while (!retried.ok && retried.status == "cleanup_pending" &&
                    DateTime.now().toUnixTimeStamp().toMilliseconds() < cleanupDeadline) {
                    sleep(Duration.millisecond * 10)
                    retried = stopServicePlugin("gitcode-monitor", reason: "s2-n1-cleanup-retry", timeoutMillis: 500)
                }
                @Expect(retried.ok, true)
                @Expect(retried.status, "stopped")
                @Expect(retried.dispatchStatus, "drained")
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                if (!retried.ok) { return }

                let replacement = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(replacement.ok, true)
                if (!replacement.ok) { return }
                let replacementIdentity = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()
                @Expect(replacementIdentity[0] == oldIdentity[0], false)
                @Expect(replacementIdentity[1] >= oldIdentity[1], true)
                @Expect(replacementIdentity[2] == oldIdentity[2], false)
                let replacementScheduler = servicePluginDispatchSchedulerSnapshotForTest("gitcode-monitor").getOrThrow()
                @Expect(replacementScheduler.generation, replacementIdentity[1])
                @Expect(replacementScheduler.active, 0)
                @Expect(replacementScheduler.queued, 0)
                @Expect(replacementScheduler.accepted, 0)
                @Expect(replacementScheduler.futures, 0)
                @Expect(replacementScheduler.queueHighWatermark, 0)
                @Expect(replacementScheduler.queueFull, 0)
                @Expect(replacementScheduler.cancelled, 0)
                @Expect(replacementScheduler.settled, true)

                settledGate.release()
                @Expect(settledWorkers.awaitTotal(2, 3000), true)
                @Expect(this.ackMarkerCounts(ackMarker, "completion", "completed")[0], 0)
                @Expect(this.ackMarkerCounts(ackMarker, "admission", "retry")[0], 0)
                @Expect(models.totalCount(), 0)
                @Expect(deliveries.totalCount(), 0)
                @Expect(exists(writebackMarker), false)
                let afterLateFinish = servicePluginDispatchSchedulerSnapshotForTest("gitcode-monitor").getOrThrow()
                @Expect(afterLateFinish.ownerId, replacementScheduler.ownerId)
                @Expect(afterLateFinish.generation, replacementScheduler.generation)
                @Expect(afterLateFinish.settled, true)
                let identityAfterLateFinish = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()
                @Expect(identityAfterLateFinish[0], replacementIdentity[0])
                @Expect(identityAfterLateFinish[1], replacementIdentity[1])
                @Expect(identityAfterLateFinish[2], replacementIdentity[2])
                @Expect(stopServicePlugin("gitcode-monitor", reason: "s2-n1-replacement", timeoutMillis: 3000).ok, true)
            } finally {
                dispatchGate.release()
                settledGate.release()
                setServicePluginDispatchRemainingForTest(None<() -> Int64>)
                setServicePluginDispatchSettledHookForTest(None<() -> Unit>)
                setServicePluginDispatchWorkerSettledHookForTest(None<(String) -> Unit>)
                setServicePluginBeforeEventDispatchHookForTest(None<(String) -> Unit>)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                match (oldWriteback) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func s3ObservabilityU1SnapshotTracksFiveAcceptedEventsAndRedactsDiagnostics(): Unit {
        withIsolatedServicePluginHostTestHome("s3-observability-u1", { home: Path =>
            let eventIds = this.gitCodeBurstEventIds("s3-observability-u1-中文🙂", 5)
            let ackMarker = home.join("acks.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let probe = ServicePluginBurstProbe()
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeAckBurstScript(eventIds))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "s3", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    probe.enterAndWait(event.eventId)
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String =>
                    ServicePluginEventDeliveryResult(true, "sent")
                }))

                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                let scheduler = this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest =>
                    row.active == 2 && row.queued == 3 && row.accepted == 5 && row.futures == 2
                }).getOrThrow()
                @Expect(this.waitForAckMarkerCount(ackMarker, "admission", "accepted", 5), true)
                let snapshot = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(snapshot.dispatch.active, 2)
                @Expect(snapshot.dispatch.queued, 3)
                @Expect(snapshot.dispatch.highWater, 3)
                @Expect(snapshot.dispatch.queueFull, 0)
                @Expect(snapshot.dispatch.admissionAccepted, 5)
                @Expect(snapshot.dispatch.admissionRetried, 0)
                @Expect(snapshot.dispatch.completionAck, 0)
                @Expect(snapshot.dispatch.fenced, false)
                @Expect(snapshot.retainedEventFrames, 5)
                @Expect(snapshot.eventFrameEvictions, 0)
                @Expect(scheduler.active, snapshot.dispatch.active)
                @Expect(scheduler.queued, snapshot.dispatch.queued)

                let diagnostic = renderServicePluginDiagnostics(ServicePluginSnapshot(
                    snapshot.serviceId,
                    snapshot.displayName,
                    snapshot.status,
                    lastError: "token=s3-fake-secret /tmp/s3-fake-path 中文🙂",
                    dispatch: snapshot.dispatch,
                    retainedEventFrames: snapshot.retainedEventFrames,
                    eventFrameEvictions: snapshot.eventFrameEvictions
                ))
                @Expect(diagnostic.contains("s3-fake-secret"), false)
                @Expect(diagnostic.contains("/tmp/s3-fake-path"), false)
                @Expect(diagnostic.contains("dispatchActive=2"), true)
                @Expect(diagnostic.contains("dispatchQueued=3"), true)
            } finally {
                probe.release(16)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func s3ObservabilityB1RetainsLatestOneHundredTwentyEightUnicodeFrames(): Unit {
        let _ = registerSample()
        var text = "中文🙂"
        let baseRoot = JsonObject()
        baseRoot.put("text", JsonString(text))
        let basePayload = baseRoot.toJsonString()
        for (_ in 0..(ServiceFrameLimits().maxPayloadBytes - basePayload.size)) {
            text += "x"
        }
        let payloadRoot = JsonObject()
        payloadRoot.put("text", JsonString(text))
        let payload = payloadRoot.toJsonString()
        @Expect(payload.size, ServiceFrameLimits().maxPayloadBytes)
        let overLimitRoot = JsonObject()
        overLimitRoot.put("text", JsonString(text + "x"))
        @Expect(overLimitRoot.toJsonString().size > ServiceFrameLimits().maxPayloadBytes, true)
        for (index in 1..=129) {
            enqueueServiceEventFrameForTest(ServiceFrame(
                "event",
                "s3-retained-${index}",
                "sample-service",
                capabilityId: "sample.event.accepted",
                payload: payload
            ))
        }
        let full = getServicePluginSnapshot("sample-service").getOrThrow()
        @Expect(full.retainedEventFrames, 128)
        @Expect(full.eventFrameEvictions, 1)
        for (index in 2..=129) {
            let read = readServiceEventFrame("sample-service")
            @Expect(read.ok, true)
            @Expect(read.frame.frameId, "s3-retained-${index}")
            @Expect(read.frame.payload, payload)
        }
        @Expect(readServiceEventFrame("sample-service").status, "timeout")
        let drained = getServicePluginSnapshot("sample-service").getOrThrow()
        @Expect(drained.retainedEventFrames, 0)
        @Expect(drained.eventFrameEvictions, 1)
    }

    @TestCase
    public func s3ObservabilityP1QueueFullRetryDrainEmitsOnlyStateTransitions(): Unit {
        withIsolatedServicePluginHostTestHome("s3-observability-p1", { home: Path =>
            let eventIds = this.gitCodeBurstEventIds("s3-observability-p1-中文🙂", 140)
            let ackMarker = home.join("acks.marker")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let probe = ServicePluginBurstProbe()
            let diagnosticStates = ServicePluginEventLedger()
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", ackMarker.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeAckBurstScript(eventIds, retryLastOnQueueFull: true))
                setServicePluginDispatchDiagnosticHookForTest(Some({ serviceId: String, state: String, _snapshot: ServicePluginDispatchSnapshot =>
                    if (serviceId == "gitcode-monitor") { diagnosticStates.record(state) }
                }))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "s3", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    probe.enterAndWait(event.eventId)
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: event.eventId)
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String =>
                    ServicePluginEventDeliveryResult(true, "sent")
                }))

                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                let saturated = this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest =>
                    row.active == 2 && row.queued == 128 && row.queueFull >= 10
                }, timeoutMillis: 5000).getOrThrow()
                @Expect(saturated.queueHighWatermark, 128)
                @Expect(this.waitForAckMarkerCount(ackMarker, "admission", "queue_full", 10), true)
                let queueFullAcks = this.ackMarkerCounts(ackMarker, "admission", "queue_full")
                @Expect(queueFullAcks[0], 10)
                @Expect(queueFullAcks[1], 0)
                let full = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(full.dispatch.highWater, 128)
                @Expect(full.dispatch.queueFull, 10)
                @Expect(full.dispatch.admissionAccepted, 130)
                @Expect(full.dispatch.admissionRetried, 10)

                probe.release(256)
                @Expect(this.waitForDispatchScheduler("gitcode-monitor", { row: ServicePluginDispatchSchedulerSnapshotForTest => row.settled }, timeoutMillis: 15000).isSome(), true)
                let drained = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                @Expect(drained.dispatch.active, 0)
                @Expect(drained.dispatch.queued, 0)
                @Expect(drained.dispatch.highWater, 128)
                @Expect(drained.dispatch.queueFull, 10)
                @Expect(drained.dispatch.admissionAccepted, 131)
                @Expect(drained.dispatch.admissionRetried, 10)
                @Expect(drained.dispatch.completionAck, 131)
                @Expect(this.ackMarkerCounts(ackMarker, "admission", "accepted", attemptToken: "attempt-140-2")[0], 1)
                @Expect(this.ackMarkerCounts(ackMarker, "admission", "queue_full", attemptToken: "attempt-140-2")[0], 0)
                @Expect(probe.callsFor(eventIds[eventIds.size - 1]), 1)
                @Expect(diagnosticStates.countFor("high_water_entered"), 1)
                @Expect(diagnosticStates.countFor("high_water_exited"), 1)
                @Expect(diagnosticStates.countFor("queue_full_entered"), 1)
                @Expect(diagnosticStates.countFor("queue_full_exited"), 1)
                @Expect(diagnosticStates.totalCount(), 4)
            } finally {
                probe.release(256)
                setServicePluginDispatchDiagnosticHookForTest(None<(String, String, ServicePluginDispatchSnapshot) -> Unit>)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
            }
        })
    }

    @TestCase
    public func s3ObservabilityN1InvalidUtf8AndSensitivePayloadStayIsolated(): Unit {
        withIsolatedServicePluginHostTestHome("s3-observability-n1", { _home: Path =>
            this.registerBrokerServiceFixture("invalid-utf8")
            var payload = "token=s3-fake-secret /tmp/s3-fake-path 中文🙂"
            while (payload.size < ServiceFrameLimits().maxPayloadBytes) { payload += "x" }
            enqueueServiceEventFrameForTest(ServiceFrame(
                "event",
                "s3-sensitive-frame",
                "stdio-service",
                capabilityId: "stdio.event.accepted",
                payload: payload
            ))
            let diagnostic = renderServicePluginDiagnostics(getServicePluginSnapshot("stdio-service").getOrThrow())
            @Expect(diagnostic.contains("s3-fake-secret"), false)
            @Expect(diagnostic.contains("/tmp/s3-fake-path"), false)
            @Expect(diagnostic.contains(payload), false)

            let sentinelId = "s3-observability-sentinel-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
            let sentinel = managedStdioBroker().startOwner(ManagedStdioOwnerSpec(
                sentinelId,
                "node",
                args: ["-e", "process.stdout.write('s3-healthy-owner\\n')"],
                stdinMode: "closed",
                outputMode: "line",
                deadlineMs: 2000
            ))
            @Expect(sentinel.ok, true)
            try {
                let invalid = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
                @Expect(invalid.ok, false)
                @Expect(invalid.status, "invalid_response_encoding")
                var sentinelOutput = ""
                var sentinelDone = false
                while (!sentinelDone) {
                    match (managedStdioBroker().readOwnerLine(sentinelId, timeoutMs: 2000)) {
                        case Some(event) =>
                            if (event.eventType == "owner.stdout") { sentinelOutput = event.text }
                            if (event.eventType == "owner.exit" || event.eventType == "owner.error" || event.eventType == "owner.timeout") { sentinelDone = true }
                        case None => sentinelDone = true
                    }
                }
                @Expect(sentinelOutput, "s3-healthy-owner")
            } finally {
                let _ = managedStdioBroker().stopOwner(sentinelId)
            }
        })
    }

    @TestCase
    public func s3U1StopFrameAndListenerClosePrecedeBlockedDispatchRelease(): Unit {
        withIsolatedServicePluginHostTestHome("s3-u1-ingress-before-dispatch", { home: Path =>
            let dispatchMarker = home.join("dispatch-entered.marker")
            let dispatchRelease = home.join("dispatch.release")
            let stopFrameMarker = home.join("stop-frame.marker")
            let portClosedMarker = home.join("port-closed.marker")
            let oldStopFrameMarker = getVariable("METIS_STDIO_FIXTURE_STOP_FRAME_MARKER_PATH")
            let oldPortClosedMarker = getVariable("METIS_STDIO_FIXTURE_PORT_CLOSED_MARKER_PATH")
            var stopper = None<Future<ServiceStopResult>>
            setVariable("METIS_STDIO_FIXTURE_STOP_FRAME_MARKER_PATH", stopFrameMarker.toString())
            setVariable("METIS_STDIO_FIXTURE_PORT_CLOSED_MARKER_PATH", portClosedMarker.toString())
            try {
                this.registerBrokerServiceFixture(
                    "gcm-stderr-burst-16",
                    pluginId: "gitcode-monitor",
                    capabilityId: "gitcode.monitor.status"
                )
                setServicePluginBeforeEventDispatchHookForTest(Some({ _serviceId: String =>
                    File.writeTo(dispatchMarker, "dispatch-entered".toArray())
                    while (!exists(dispatchRelease)) { sleep(Duration.millisecond * 5) }
                }))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "s3-account", "s3-peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "停止中文🙂")
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String =>
                    ServicePluginEventDeliveryResult(true, "sent")
                }))
                let invoked = invokeRegisteredCapability(
                    CapabilityInvokeRequest("gitcode.monitor.status", payload: "{\"text\":\"停止中文🙂\"}")
                )
                @Expect(invoked.ok, true)
                @Expect(this.waitForFile(dispatchMarker, timeoutMillis: 2000), true)

                stopper = Some(spawn {
                    stopServicePlugin("gitcode-monitor", reason: "停止中文🙂", timeoutMillis: 2500)
                })
                @Expect(this.waitForFile(stopFrameMarker, timeoutMillis: 500), true)
                @Expect(this.waitForFile(portClosedMarker, timeoutMillis: 500), true)
                @Expect(exists(dispatchRelease), false)
                let completedBeforeDispatchRelease = try {
                    let _ = stopper.getOrThrow().get(Duration.millisecond * 10)
                    true
                } catch (_: Exception) {
                    false
                }
                @Expect(completedBeforeDispatchRelease, false)

                File.writeTo(dispatchRelease, "release".toArray())
                let stopped = stopper.getOrThrow().get(Duration.second * 4)
                stopper = None<Future<ServiceStopResult>>
                @Expect(stopped.ok, true)
                @Expect(stopped.status, "stopped")
                @Expect(stopped.ingressStopStatus, "sent")
                @Expect(stopped.dispatchStatus, "drained")
                @Expect(stopped.leaseStatus, "stopped")
                @Expect(stopped.portStatus, "released")
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            } finally {
                if (!exists(dispatchRelease)) {
                    try { File.writeTo(dispatchRelease, "release".toArray()) } catch (_: Exception) { () }
                }
                setServicePluginBeforeEventDispatchHookForTest(None<(String) -> Unit>)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (stopper) {
                    case Some(future) => try { let _ = future.get(Duration.second * 4) } catch (_: Exception) { () }
                    case None => ()
                }
                match (oldStopFrameMarker) {
                    case Some(value) => setVariable("METIS_STDIO_FIXTURE_STOP_FRAME_MARKER_PATH", value)
                    case None => setVariable("METIS_STDIO_FIXTURE_STOP_FRAME_MARKER_PATH", "")
                }
                match (oldPortClosedMarker) {
                    case Some(value) => setVariable("METIS_STDIO_FIXTURE_PORT_CLOSED_MARKER_PATH", value)
                    case None => setVariable("METIS_STDIO_FIXTURE_PORT_CLOSED_MARKER_PATH", "")
                }
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func s3B1DispatchPastReserveIsCleanupPendingUntilExactRetry(): Unit {
        withIsolatedServicePluginHostTestHome("s3-b1-dispatch-reserve", { home: Path =>
            let oldStopFrameMarker = getVariable("METIS_STDIO_FIXTURE_STOP_FRAME_MARKER_PATH")
            var activeGate = None<ServicePluginTestGate>
            try {
                @Expect(servicePluginDispatchBudgetForTest(99, 100), 0)
                @Expect(servicePluginDispatchBudgetForTest(100, 100), 0)
                @Expect(servicePluginDispatchBudgetForTest(101, 100), 1)
                for (remaining in [Int64(99), Int64(100), Int64(101)]) {
                    let stopFrameMarker = home.join("stop-frame-${remaining}.marker")
                    let dispatchGate = ServicePluginTestGate()
                    let settledGate = ServicePluginTestGate()
                    activeGate = Some(dispatchGate)
                    setVariable("METIS_STDIO_FIXTURE_STOP_FRAME_MARKER_PATH", stopFrameMarker.toString())
                    this.registerBrokerServiceFixture(
                        "gcm-stderr-burst-16",
                        pluginId: "gitcode-monitor",
                        capabilityId: "gitcode.monitor.status"
                    )
                    setServicePluginBeforeEventDispatchHookForTest(Some({ _serviceId: String => dispatchGate.enterAndWait() }))
                    setServicePluginDispatchSettledHookForTest(Some({ => settledGate.signal() }))
                    setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                        let rows = ArrayList<ServicePluginDeliveryTarget>()
                        rows.add(ServicePluginDeliveryTarget("feishu", "s3-account", "s3-peer"))
                        rows
                    }))
                    setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                        ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "边界中文🙂")
                    }))
                    setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String =>
                        ServicePluginEventDeliveryResult(true, "sent")
                    }))
                    @Expect(invokeRegisteredCapability(CapabilityInvokeRequest("gitcode.monitor.status", payload: "{}")).ok, true)
                    @Expect(dispatchGate.awaitEntered(2000), true)
                    servicePluginInstallNativeBoundaryProbesForTest(home)
                    setServicePluginDispatchRemainingForTest(Some({ => remaining }))
                    if (remaining == 101) {
                        setServicePluginBeforeDispatchWaitForTest(Some({ waitMs: Int64 =>
                            @Expect(waitMs, 1)
                            dispatchGate.release()
                            @Expect(settledGate.awaitEntered(1000), true)
                        }))
                    }
                    let stopStarted = MonoTime.now()
                    let stopped = stopServicePlugin("gitcode-monitor", reason: "边界中文🙂", timeoutMillis: 200)
                    let stopElapsedMs = (MonoTime.now() - stopStarted).toMilliseconds()
                    let fixedStage = { value: String =>
                        if (["stopped", "cleanup_pending", "drained", "dispatch_pending", "cancelled", "sent",
                            "write_failed", "deadline_exhausted", "not_started", "graceful_exited", "terminated",
                            "force_terminated", "already_stopped", "still_alive", "not_applicable", "not_checked",
                            "not_stopped", "invalid", "identity_mismatch", "released", "not_released",
                            "probe_timeout", "port_probe_timeout", "pid_probe_timeout", "deadline_exceeded"].contains(value)) {
                            value
                        } else { "unknown" }
                    }
                    let diagnosticKind = if (stopped.diagnostic == "cleanup_identity_changed") { "cleanup_identity_changed" }
                        else if (stopped.diagnostic.contains("lease_identity_mismatch_after_stop")) { "lease_identity_mismatch" }
                        else if (stopped.diagnostic.contains("lease_invalid_after_stop")) { "lease_invalid" }
                        else if (stopped.diagnostic.contains("lease_not_stopped_after_stop")) { "lease_not_stopped" }
                        else if (stopped.diagnostic.contains("pid_alive_after_stop")) { "pid_alive" }
                        else if (stopped.diagnostic.contains("pid_probe_timeout") || stopped.diagnostic.contains("terminal_probe_timeout")) { "probe_timeout" }
                        else if (stopped.diagnostic.contains("lease_stopped")) { "lease_stopped" }
                        else { "other_fixed_category" }
                    println("S3-DEADLINE remaining=${remaining};stopElapsedMs=${stopElapsedMs};ok=${stopped.ok};status=${fixedStage(stopped.status)};ingress=${fixedStage(stopped.ingressStopStatus)};dispatch=${fixedStage(stopped.dispatchStatus)};owner=${fixedStage(stopped.ownerStopStatus)};lease=${fixedStage(stopped.leaseStatus)};port=${fixedStage(stopped.portStatus)};diagnosticKind=${diagnosticKind};stateFlushed=${stopped.stateFlushed};pending=${servicePluginCleanupPendingCountForTest()};brokerOwners=${managedStdioBroker().snapshot().ownerCount}")
                    @Expect(this.waitForFile(stopFrameMarker, timeoutMillis: 100), true)
                    @Expect(stopped.ingressStopStatus, "sent")
                    if (remaining <= 100) {
                        @Expect(stopped.ok, false)
                        @Expect(stopped.status, "cleanup_pending")
                        @Expect(stopped.dispatchStatus, "dispatch_pending")
                        @Expect(servicePluginCleanupPendingCountForTest(), 1)
                        dispatchGate.release()
                        @Expect(settledGate.awaitEntered(2000), true)
                        setServicePluginDispatchRemainingForTest(None<() -> Int64>)
                        let retried = stopServicePlugin("gitcode-monitor", reason: "边界重试", timeoutMillis: 2000)
                        @Expect(retried.ok, true)
                        @Expect(retried.status, "stopped")
                        @Expect(retried.ingressStopStatus, "sent")
                        @Expect(retried.dispatchStatus, "drained")
                        @Expect(
                            retried.ownerStopStatus == "graceful_exited" ||
                            retried.ownerStopStatus == "terminated" ||
                            retried.ownerStopStatus == "force_terminated" ||
                            retried.ownerStopStatus == "already_stopped",
                            true
                        )
                        @Expect(retried.leaseStatus, "stopped")
                        @Expect(retried.portStatus, "released")
                    } else {
                        @Expect(stopped.ok, true)
                        @Expect(stopped.status, "stopped")
                        @Expect(stopped.dispatchStatus, "drained")
                    }
                    @Expect(servicePluginCleanupPendingCountForTest(), 0)
                    @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                    activeGate = None<ServicePluginTestGate>
                    setServicePluginDispatchRemainingForTest(None<() -> Int64>)
                    setServicePluginBeforeDispatchWaitForTest(None<(Int64) -> Unit>)
                    setServicePluginDispatchSettledHookForTest(None<() -> Unit>)
                    setServicePluginBeforeEventDispatchHookForTest(None<(String) -> Unit>)
                    setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                    setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                    setServicePluginEventDeliveryForTest(None)
                    setServicePluginPidProbeCommandForTest(None<(Int64, Int64) -> (Int64, String, String)>)
                    setServicePluginPortReleaseCommandForTest(None<(Int64, Int64, Int64) -> (Int64, String, String)>)
                    resetServicePluginHostForTest()
                }
            } finally {
                match (activeGate) { case Some(gate) => gate.release() case None => () }
                setServicePluginDispatchRemainingForTest(None<() -> Int64>)
                setServicePluginBeforeDispatchWaitForTest(None<(Int64) -> Unit>)
                setServicePluginDispatchSettledHookForTest(None<() -> Unit>)
                setServicePluginBeforeEventDispatchHookForTest(None<(String) -> Unit>)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (oldStopFrameMarker) {
                    case Some(value) => setVariable("METIS_STDIO_FIXTURE_STOP_FRAME_MARKER_PATH", value)
                    case None => setVariable("METIS_STDIO_FIXTURE_STOP_FRAME_MARKER_PATH", "")
                }
                setServicePluginPidProbeCommandForTest(None<(Int64, Int64) -> (Int64, String, String)>)
                setServicePluginPortReleaseCommandForTest(None<(Int64, Int64, Int64) -> (Int64, String, String)>)
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func s3P1GracefulStopRequiresIngressOwnerLeaseAndPortRelease(): Unit {
        withIsolatedServicePluginHostTestHome("s3-p1-terminal-contract", { home: Path =>
            this.registerBrokerServiceFixture(
                "gcm-stderr-burst-16",
                pluginId: "gitcode-monitor",
                capabilityId: "gitcode.monitor.status"
            )
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 3000)
                @Expect(started.ok, true)
                @Expect(this.waitForGitCodeLease(home, timeoutMillis: 2000), true)
                let pid = match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) => snapshot.pid
                    case None => Int64(0)
                }
                let pgid = this.processGroupId(pid)
                @Expect(pid > 0, true)
                @Expect(pgid > 0, true)

                let stopped = stopServicePlugin("gitcode-monitor", reason: "正常停止中文🙂", timeoutMillis: 3000)
                @Expect(stopped.ok, true)
                @Expect(stopped.status, "stopped")
                @Expect(stopped.ingressStopStatus, "sent")
                @Expect(stopped.dispatchStatus, "drained")
                @Expect(
                    stopped.ownerStopStatus == "graceful_exited" ||
                    stopped.ownerStopStatus == "terminated" ||
                    stopped.ownerStopStatus == "force_terminated",
                    true
                )
                @Expect(stopped.leaseStatus, "stopped")
                @Expect(stopped.portStatus, "released")
                @Expect(this.waitForPidGone(pid), true)
                @Expect(this.waitForProcessGroupGone(pgid), true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            } finally {
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func s3N1PortReleaseFailureStaysRetryableAndNeverReportsStopped(): Unit {
        withIsolatedServicePluginHostTestHome("s3-n1-port-retry", { home: Path =>
            let probeTimeouts = ArrayList<Int64>()
            this.registerBrokerServiceFixture(
                "gcm",
                pluginId: "gitcode-monitor",
                capabilityId: "gitcode.monitor.status"
            )
            try {
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 3000).ok, true)
                @Expect(this.waitForGitCodeLease(home, timeoutMillis: 2000), true)
                setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, timeoutMs: Int64 =>
                    probeTimeouts.add(timeoutMs)
                    (Int64(124), "", "probe timeout")
                }))
                let shutdown = shutdownServicePluginHost(reason: "listener-stuck", timeoutMillis: 2000)
                @Expect(shutdown.ok, false)
                @Expect(shutdown.status, "cleanup_pending")
                @Expect(shutdown.results.size, 1)
                let pending = shutdown.results[0]
                @Expect(pending.ok, false)
                @Expect(pending.status, "cleanup_pending")
                @Expect(pending.ingressStopStatus, "sent")
                @Expect(pending.leaseStatus, "stopped")
                @Expect(pending.portStatus, "port_probe_timeout")
                @Expect(probeTimeouts.size > 0, true)
                for (probeTimeout in probeTimeouts) {
                    @Expect(probeTimeout > 0 && probeTimeout <= 2000, true)
                }
                @Expect(servicePluginCleanupPendingCountForTest(), 1)

                setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeoutMs: Int64 =>
                    (Int64(125), "", "")
                }))
                let invalidEncoding = stopServicePlugin("gitcode-monitor", reason: "listener-invalid-encoding", timeoutMillis: 2000)
                @Expect(invalidEncoding.ok, false)
                @Expect(invalidEncoding.status, "cleanup_pending")
                @Expect(invalidEncoding.leaseStatus, "stopped")
                @Expect(invalidEncoding.portStatus, "invalid_response_encoding")

                setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeoutMs: Int64 =>
                    (Int64(127), "", "probe unavailable")
                }))
                let unavailable = stopServicePlugin("gitcode-monitor", reason: "listener-probe-unavailable", timeoutMillis: 2000)
                @Expect(unavailable.ok, false)
                @Expect(unavailable.status, "cleanup_pending")
                @Expect(unavailable.leaseStatus, "stopped")
                @Expect(unavailable.portStatus, "port_probe_unavailable")

                setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeoutMs: Int64 =>
                    (Int64(1), "", "")
                }))
                let retried = stopServicePlugin("gitcode-monitor", reason: "listener-released", timeoutMillis: 2000)
                @Expect(retried.ok, true)
                @Expect(retried.status, "stopped")
                @Expect(retried.ingressStopStatus, "sent")
                @Expect(retried.dispatchStatus, "drained")
                @Expect(
                    retried.ownerStopStatus == "terminated" || retried.ownerStopStatus == "force_terminated" ||
                    retried.ownerStopStatus == "already_stopped",
                    true
                )
                @Expect(retried.leaseStatus, "stopped")
                @Expect(retried.portStatus, "released")
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            } finally {
                setServicePluginPortReleaseCommandForTest(None<(Int64, Int64, Int64) -> (Int64, String, String)>)
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func s3N1LateCleanupFinalizerCannotOverwriteReplacementIdentity(): Unit {
        withIsolatedServicePluginHostTestHome("s3-n1-finalize-identity", { home: Path =>
            let finalizeGate = ServicePluginTestGate()
            let firstFinalize = ServicePluginTestOnce()
            let finalizeEntries = ServicePluginTestCounter()
            var lateRetry = None<Future<ServiceStopResult>>
            var concurrentRetry = None<Future<ServiceStopResult>>
            this.registerBrokerServiceFixture(
                "gcm",
                pluginId: "gitcode-monitor",
                capabilityId: "gitcode.monitor.status"
            )
            try {
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 3000).ok, true)
                @Expect(this.waitForGitCodeLease(home, timeoutMillis: 2000), true)
                setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeoutMs: Int64 =>
                    (Int64(124), "", "probe timeout")
                }))
                let pending = stopServicePlugin("gitcode-monitor", reason: "old-owner", timeoutMillis: 2000)
                @Expect(pending.status, "cleanup_pending")
                let oldIdentity = servicePluginCleanupPendingIdentityForTest("gitcode-monitor").getOrThrow()

                setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeoutMs: Int64 =>
                    (Int64(1), "", "")
                }))
                setServicePluginCleanupFinalizeHookForTest(Some({ _serviceId: String, _cleanupToken: Int64 =>
                    finalizeEntries.increment()
                    if (firstFinalize.take()) { finalizeGate.enterAndWait() }
                }))
                lateRetry = Some(spawn { stopServicePlugin("gitcode-monitor", reason: "late-old", timeoutMillis: 3000) })
                @Expect(finalizeGate.awaitEntered(2000), true)
                concurrentRetry = Some(spawn { stopServicePlugin("gitcode-monitor", reason: "current-old", timeoutMillis: 3000) })
                finalizeGate.release()
                let finalized = concurrentRetry.getOrThrow().get(Duration.second * 4)
                concurrentRetry = None<Future<ServiceStopResult>>
                @Expect(finalized.ok, true)
                @Expect(finalized.leaseStatus, "stopped")
                @Expect(finalized.portStatus, "released")
                let late = lateRetry.getOrThrow().get(Duration.second * 4)
                lateRetry = None<Future<ServiceStopResult>>
                @Expect(late.ok, true)
                @Expect(finalizeEntries.get(), 1)
                let replacement = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 3000)
                @Expect(replacement.ok, true)
                let replacementIdentity = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()
                let replacementPid = getServicePluginSnapshot("gitcode-monitor").getOrThrow().pid
                @Expect(replacementIdentity[0] == oldIdentity[0], false)
                @Expect(replacementIdentity[1] >= oldIdentity[1], true)
                @Expect(replacementIdentity[2] == oldIdentity[2], false)
                @Expect(replacementPid > 0, true)

                @Expect(servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()[0], replacementIdentity[0])
                @Expect(getServicePluginSnapshot("gitcode-monitor").getOrThrow().pid, replacementPid)
                @Expect(invokeRegisteredCapability(CapabilityInvokeRequest("gitcode.monitor.status", payload: "{}")).ok, true)
                @Expect(stopServicePlugin("gitcode-monitor", reason: "replacement-cleanup", timeoutMillis: 3000).ok, true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            } finally {
                finalizeGate.release()
                setServicePluginCleanupFinalizeHookForTest(None<(String, Int64) -> Unit>)
                setServicePluginPortReleaseCommandForTest(None<(Int64, Int64, Int64) -> (Int64, String, String)>)
                match (lateRetry) {
                    case Some(future) => try { let _ = future.get(Duration.second * 4) } catch (_: Exception) { () }
                    case None => ()
                }
                match (concurrentRetry) {
                    case Some(future) => try { let _ = future.get(Duration.second * 4) } catch (_: Exception) { () }
                    case None => ()
                }
                let _ = stopServicePlugin("gitcode-monitor", reason: "test-finally", timeoutMillis: 2000)
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func s3N1BoundedPidProbeAndMixedShutdownKeepTruthfulStatuses(): Unit {
        withIsolatedServicePluginHostTestHome("s3-n1-bounded-probe-shutdown", { home: Path =>
            setServicePluginPidProbeCommandForTest(Some({ _pid: Int64, _timeoutMs: Int64 =>
                (Int64(1), "", "")
            }))
            @Expect(servicePluginPidProbeStatusForTest(123, 100), "pid_probe_unavailable")
            setServicePluginPidProbeCommandForTest(Some({ _pid: Int64, _timeoutMs: Int64 =>
                (Int64(1), "", "kill: Operation not permitted")
            }))
            @Expect(servicePluginPidProbeStatusForTest(123, 100), "pid_probe_permission_denied")
            setServicePluginPidProbeCommandForTest(Some({ _pid: Int64, _timeoutMs: Int64 =>
                (Int64(125), "", "")
            }))
            @Expect(servicePluginPidProbeStatusForTest(123, 100), "invalid_response_encoding")
            setServicePluginPidProbeCommandForTest(Some({ _pid: Int64, _timeoutMs: Int64 =>
                (Int64(127), "", "command unavailable")
            }))
            @Expect(servicePluginPidProbeStatusForTest(123, 100), "pid_probe_unavailable")
            setServicePluginPidProbeCommandForTest(Some({ _pid: Int64, _timeoutMs: Int64 =>
                (Int64(1), "", "kill: No such process")
            }))
            @Expect(servicePluginPidProbeStatusForTest(123, 100), "gone")
            setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeoutMs: Int64 =>
                (Int64(1), "", "lsof failed")
            }))
            @Expect(servicePluginPortProbeStatusForTest(19081, 123, 100), "port_probe_unavailable")
            setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeoutMs: Int64 =>
                (Int64(1), "", "")
            }))
            @Expect(servicePluginPortProbeStatusForTest(19081, 123, 100), "released")
            let clockCalls = ServicePluginTestCounter()
            setServicePluginMonotonicNowForTest(Some({ =>
                clockCalls.increment()
                if (clockCalls.get() == 1) { Int64(100) } else if (clockCalls.get() == 2) { Int64(120) } else { Int64(90) }
            }))
            let monotonicRemaining = servicePluginDeadlineRemainingForTest(100)
            @Expect(monotonicRemaining[0], 80)
            @Expect(monotonicRemaining[1], 80)
            setServicePluginMonotonicNowForTest(None<() -> Int64>)
            setServicePluginPidProbeCommandForTest(None<(Int64, Int64) -> (Int64, String, String)>)
            setServicePluginPortReleaseCommandForTest(None<(Int64, Int64, Int64) -> (Int64, String, String)>)
            this.registerBrokerServiceFixture(
                "gcm",
                pluginId: "gitcode-monitor",
                capabilityId: "gitcode.monitor.status"
            )
            try {
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 3000).ok, true)
                @Expect(this.waitForGitCodeLease(home, timeoutMillis: 2000), true)
                setServicePluginPidProbeCommandForTest(Some({ _pid: Int64, timeoutMs: Int64 =>
                    @Expect(timeoutMs > 0 && timeoutMs <= 2000, true)
                    (Int64(124), "", "pid probe timeout")
                }))
                let pending = stopServicePlugin("gitcode-monitor", reason: "pid-probe-timeout", timeoutMillis: 2000)
                @Expect(pending.ok, false)
                @Expect(pending.status, "cleanup_pending")
                @Expect(pending.leaseStatus, "stopped")
                @Expect(pending.portStatus, "released")
                setServicePluginPidProbeCommandForTest(None<(Int64, Int64) -> (Int64, String, String)>)
                let retried = stopServicePlugin("gitcode-monitor", reason: "pid-probe-recovered", timeoutMillis: 2000)
                @Expect(retried.ok, true)
                @Expect(retried.dispatchStatus, "drained")
                @Expect(retried.leaseStatus, "stopped")
                @Expect(retried.portStatus, "released")

                resetServicePluginHostForTest()
                this.registerBrokerServiceFixture(
                    "noise-0",
                    pluginId: "disabled-service",
                    capabilityId: "disabled.monitor.status",
                    enabled: false
                )
                this.registerBrokerServiceFixture(
                    "noise-0",
                    pluginId: "degraded-service",
                    capabilityId: "degraded.monitor.status",
                    resetHost: false
                )
                this.registerBrokerServiceFixture(
                    "gcm",
                    pluginId: "running-service",
                    capabilityId: "running.monitor.status",
                    resetHost: false
                )
                markServicePluginDegraded("degraded-service", "test_degraded")
                @Expect(ensureRegisteredServicePluginStarted("running-service", startupTimeoutMs: 3000).ok, true)
                let shutdown = shutdownServicePluginHost(reason: "mixed-registry", timeoutMillis: 3000)
                @Expect(shutdown.ok, true)
                @Expect(shutdown.status, "stopped")
                @Expect(shutdown.results.size, 3)
                var sawDisabled = false
                var sawDegraded = false
                var sawRunning = false
                for (result in shutdown.results) {
                    if (result.serviceId == "disabled-service") {
                        sawDisabled = true
                        @Expect(result.ok, true)
                        @Expect(result.status, "not_applicable")
                        @Expect(result.ingressStopStatus, "not_applicable")
                        @Expect(result.dispatchStatus, "not_applicable")
                        @Expect(result.ownerStopStatus, "not_applicable")
                        @Expect(result.leaseStatus, "not_applicable")
                        @Expect(result.portStatus, "not_applicable")
                    } else if (result.serviceId == "degraded-service") {
                        sawDegraded = true
                        @Expect(result.ok, true)
                        @Expect(result.status, "not_applicable")
                        @Expect(result.ingressStopStatus, "not_applicable")
                        @Expect(result.dispatchStatus, "not_applicable")
                        @Expect(result.ownerStopStatus, "not_applicable")
                        @Expect(result.leaseStatus, "not_applicable")
                        @Expect(result.portStatus, "not_applicable")
                    } else if (result.serviceId == "running-service") {
                        sawRunning = true
                        @Expect(result.ok, true)
                        @Expect(result.status, "stopped")
                        @Expect(result.ingressStopStatus, "sent")
                        @Expect(result.dispatchStatus, "drained")
                        @Expect(
                            result.ownerStopStatus == "graceful_exited" ||
                            result.ownerStopStatus == "terminated" ||
                            result.ownerStopStatus == "force_terminated" ||
                            result.ownerStopStatus == "already_stopped",
                            true
                        )
                        @Expect(result.leaseStatus, "stopped")
                        @Expect(result.portStatus, "released")
                    }
                }
                @Expect(sawDisabled && sawDegraded && sawRunning, true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            } finally {
                setServicePluginMonotonicNowForTest(None<() -> Int64>)
                setServicePluginPidProbeCommandForTest(None<(Int64, Int64) -> (Int64, String, String)>)
                setServicePluginPortReleaseCommandForTest(None<(Int64, Int64, Int64) -> (Int64, String, String)>)
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func hbBrN5ServicePluginPortProbeCapsSingleExternalCall(): Unit {
        withIsolatedServicePluginHostTestHome("hb-br-n5-port-budget", { _home: Path =>
            let calls = ServicePluginTestCounter()
            setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, timeoutMs: Int64 =>
                calls.increment()
                @Expect(timeoutMs, 500)
                (Int64(124), "", "")
            }))
            try {
                @Expect(servicePluginPortProbeStatusForTest(19082, 124, 5000), "port_probe_timeout")
                @Expect(calls.get(), 1)
            } finally {
                setServicePluginPortReleaseCommandForTest(None<(Int64, Int64, Int64) -> (Int64, String, String)>)
            }
        })
    }

    @TestCase
    public func s3N1UnknownPreForceAndExpiredPostProbeStayCleanupPending(): Unit {
        withIsolatedServicePluginHostTestHome("s3-n1-preforce-unknown", { home: Path =>
            let expireClock = ServicePluginTestCounter()
            let pidProbeCalls = ServicePluginTestCounter()
            let portProbeCalls = ServicePluginTestCounter()
            let clockOrigin = MonoTime.now()
            this.registerBrokerServiceFixture(
                "ignore-term",
                pluginId: "gitcode-monitor",
                capabilityId: "gitcode.monitor.status"
            )
            try {
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 3000).ok, true)
                let pid = getServicePluginSnapshot("gitcode-monitor").getOrThrow().pid
                @Expect(pid > 0, true)
                setServicePluginAfterIngressStopHookForTest(Some({ =>
                    let leasePath = home.join("service-plugin").join("runtime").join("gitcode-monitor").join("gitcode-monitor-1.lease.json")
                    File.writeTo(
                        leasePath,
                        ("{\"state\":\"running\",\"status\":\"running\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"wrong-generation\",\"pid\":${pid},\"parentPid\":${getProcessId()},\"bindHost\":\"127.0.0.1\",\"port\":19081}").toArray()
                    )
                }))
                setServicePluginPidProbeCommandForTest(Some({ _pid: Int64, _timeoutMs: Int64 =>
                    pidProbeCalls.increment()
                    if (pidProbeCalls.get() == 2) { expireClock.increment() }
                    (Int64(127), "", "command unavailable")
                }))
                setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeoutMs: Int64 =>
                    portProbeCalls.increment()
                    (Int64(127), "", "command unavailable")
                }))
                setServicePluginMonotonicNowForTest(Some({ =>
                    if (expireClock.get() > 0) {
                        Int64(10000)
                    } else {
                        (MonoTime.now() - clockOrigin).toMilliseconds()
                    }
                }))

                let pending = stopServicePlugin("gitcode-monitor", reason: "preforce-unknown", timeoutMillis: 1000)
                @Expect(pending.ok, false)
                @Expect(pending.status, "cleanup_pending")
                @Expect(pending.leaseStatus, "identity_mismatch")
                @Expect(pending.portStatus, "not_checked")
                // ingress observation, pre-force evidence, then the bounded 1 ms auto-finalizer retry.
                @Expect(pidProbeCalls.get(), 3)
                @Expect(portProbeCalls.get(), 0)
                @Expect(servicePluginCleanupPendingCountForTest(), 1)

                setServicePluginMonotonicNowForTest(None<() -> Int64>)
                setServicePluginAfterIngressStopHookForTest(None<() -> Unit>)
                setServicePluginPidProbeCommandForTest(None<(Int64, Int64) -> (Int64, String, String)>)
                setServicePluginPortReleaseCommandForTest(None<(Int64, Int64, Int64) -> (Int64, String, String)>)
                let leasePath = home.join("service-plugin").join("runtime").join("gitcode-monitor").join("gitcode-monitor-1.lease.json")
                File.writeTo(
                    leasePath,
                    ("{\"state\":\"stopped\",\"status\":\"stopped\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"gitcode-monitor-1\",\"pid\":${pid},\"parentPid\":${getProcessId()},\"bindHost\":\"127.0.0.1\",\"port\":19081}").toArray()
                )
                let retried = stopServicePlugin("gitcode-monitor", reason: "preforce-retry", timeoutMillis: 3000)
                @Expect(retried.ok, true)
                @Expect(retried.status, "stopped")
                @Expect(retried.dispatchStatus, "drained")
                @Expect(retried.leaseStatus, "stopped")
                @Expect(retried.portStatus, "released")
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            } finally {
                setServicePluginMonotonicNowForTest(None<() -> Int64>)
                setServicePluginAfterIngressStopHookForTest(None<() -> Unit>)
                setServicePluginPidProbeCommandForTest(None<(Int64, Int64) -> (Int64, String, String)>)
                setServicePluginPortReleaseCommandForTest(None<(Int64, Int64, Int64) -> (Int64, String, String)>)
                let _ = stopServicePlugin("gitcode-monitor", reason: "test-finally", timeoutMillis: 2000)
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func p3N1MalformedEncodingCrashAndIgnoringTermStayBounded(): Unit {
        withIsolatedServicePluginHostTestHome("p3-n1-terminal-failures", { home: Path =>
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let oldRelease = getVariable("METIS_STDIO_FIXTURE_RELEASE_PATH")
            try {
            this.registerBrokerServiceFixture("malformed")
            var malformedPid = Int64(0)
            var malformedPgid = Int64(0)
            try {
                let started = ensureRegisteredServicePluginStarted("stdio-service", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                malformedPid = getServicePluginSnapshot("stdio-service").getOrThrow().pid
                malformedPgid = this.processGroupId(malformedPid)
                @Expect(malformedPid > 1, true)
                @Expect(malformedPgid > 0, true)
                if (malformedPid <= 1 || malformedPgid <= 0) {
                    throw Exception("malformed zero-budget fixture process identity is invalid")
                }
                setServicePluginDispatchRemainingForTest(Some({ => Int64(0) }))
                let malformed = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
                @Expect(malformed.ok, false)
                @Expect(malformed.status, "frame_decode_failed")
            } finally {
                setServicePluginDispatchRemainingForTest(None<() -> Int64>)
                let cleanup = this.settleServiceOwnerCleanup("stdio-service")
                @Expect(if (cleanup[0]) { cleanup[1] == "stopped" } else { cleanup[1] == "not_needed" }, true)
                @Expect(cleanup[2], true)
                @Expect(cleanup[3], true)
                resetServicePluginHostForTest()
            }
            @Expect(this.waitForPidGone(malformedPid), true)
            @Expect(this.waitForProcessGroupGone(malformedPgid), true)
            @Expect(managedStdioBroker().snapshot().ownerCount, 0)

            this.registerBrokerServiceFixture("invalid-utf8")
            let sentinelId = "p3-n1-sentinel-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
            let sentinel = managedStdioBroker().startOwner(ManagedStdioOwnerSpec(
                sentinelId,
                "node",
                args: ["-e", "process.stdout.write('other-owner-ok\\n')"],
                stdinMode: "closed",
                outputMode: "line",
                deadlineMs: 2000
            ))
            @Expect(sentinel.ok, true)
            try {
                let invalid = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
                @Expect(invalid.ok, false)
                @Expect(invalid.status, "invalid_response_encoding")
                var sentinelOutput = ""
                var sentinelDone = false
                while (!sentinelDone) {
                    match (managedStdioBroker().readOwnerLine(sentinelId, timeoutMs: 2000)) {
                        case Some(event) =>
                            if (event.eventType == "owner.stdout") { sentinelOutput = event.text }
                            if (event.eventType == "owner.exit" || event.eventType == "owner.error" || event.eventType == "owner.timeout") {
                                sentinelDone = true
                            }
                        case None => sentinelDone = true
                    }
                }
                @Expect(sentinelOutput, "other-owner-ok")
            } finally {
                let _ = managedStdioBroker().stopOwner(sentinelId)
                let cleanup = this.settleServiceOwnerCleanup("stdio-service")
                @Expect(if (cleanup[0]) { cleanup[1] == "stopped" } else { cleanup[1] == "not_needed" }, true)
                @Expect(cleanup[2], true)
                @Expect(cleanup[3], true)
                resetServicePluginHostForTest()
            }

            this.registerBrokerServiceFixture(
                "crash",
                pluginId: "crash-service",
                capabilityId: "crash.monitor.status"
            )
            try {
                let crashed = invokeRegisteredCapability(CapabilityInvokeRequest("crash.monitor.status", payload: "{}"))
                @Expect(crashed.ok, false)
                @Expect(crashed.status, "process_exited")
            } finally {
                let cleanup = this.settleServiceOwnerCleanup("crash-service")
                @Expect(if (cleanup[0]) { cleanup[1] == "stopped" } else { cleanup[1] == "not_needed" }, true)
                @Expect(cleanup[2], true)
                @Expect(cleanup[3], true)
                resetServicePluginHostForTest()
            }

            this.registerBrokerServiceFixture(
                "ignore-term",
                pluginId: "ignore-term-service",
                capabilityId: "ignore-term.monitor.status"
            )
            try {
                let started = ensureRegisteredServicePluginStarted("ignore-term-service", startupTimeoutMs: 3000)
                @Expect(started.ok, true)
                let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
                let stopped = stopServicePlugin("ignore-term-service", reason: "p3-n1", timeoutMillis: 2500)
                let elapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt
                @Expect(stopped.diagnostic.contains("stop_status=force_terminated"), true)
                @Expect(stopped.diagnostic.contains("lease_missing_after_stop"), true)
                @Expect(stopped.ok, true)
                @Expect(elapsed < 3000, true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                match (getServicePluginSnapshot("ignore-term-service")) {
                    case Some(snapshot) => @Expect(snapshot.pid, 0)
                    case None => @Expect(true, false)
                }
            } finally {
                resetServicePluginHostForTest()
            }

            for (index in 0..12) {
                let readyPath = home.join("exit-after-init-${index}.ready")
                let releasePath = home.join("exit-after-init-${index}.release")
                setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", readyPath.toString())
                setVariable("METIS_STDIO_FIXTURE_RELEASE_PATH", releasePath.toString())
                this.registerBrokerServiceFixture("exit-after-init")
                try {
                    let started = ensureRegisteredServicePluginStarted("stdio-service", startupTimeoutMs: 1000)
                    @Expect(started.ok, true)
                    @Expect(started.diagnostic.contains("duplicate_owner"), false)
                    @Expect(this.waitForFile(readyPath), true)
                    File.writeTo(releasePath, "release".toArray())
                    @Expect(this.waitForSnapshotReason("stdio-service", "process_exited", timeoutMillis: 1000), true)
                } finally {
                    if (!exists(releasePath)) { try { File.writeTo(releasePath, "release".toArray()) } catch (_: Exception) { () } }
                    let cleanup = this.settleServiceOwnerCleanup("stdio-service")
                    @Expect(if (cleanup[0]) { cleanup[1] == "stopped" } else { cleanup[1] == "not_needed" }, true)
                    @Expect(cleanup[2], true)
                    @Expect(cleanup[3], true)
                    resetServicePluginHostForTest()
                }
            }
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "")
            setVariable("METIS_STDIO_FIXTURE_RELEASE_PATH", "")

            this.registerBrokerServiceFixture("exit-after-delay")
            @Expect(ensureRegisteredServicePluginStarted("stdio-service", startupTimeoutMs: 1000).ok, true)
            @Expect(dropServicePluginActiveProcessForTest("stdio-service", stopProcess: false), true)
            resetServicePluginHostForTest()
            this.registerBrokerServiceFixture("noise-0")
            try {
                let replacementStart = ensureRegisteredServicePluginStarted("stdio-service", startupTimeoutMs: 1000)
                @Expect(replacementStart.status, "running")
                @Expect(replacementStart.ok, true)
                let replacementPid = match (getServicePluginSnapshot("stdio-service")) {
                    case Some(snapshot) => snapshot.pid
                    case None => Int64(0)
                }
                sleep(Duration.millisecond * 700)
                @Expect(probeServicePluginHealth("stdio-service").pidAlive, true)
                match (getServicePluginSnapshot("stdio-service")) {
                    case Some(snapshot) => @Expect(snapshot.pid, replacementPid)
                    case None => @Expect(true, false)
                }
                let replacementInvoke = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
                @Expect(replacementInvoke.status, "ok")
                @Expect(replacementInvoke.ok, true)
            } finally {
                let _ = stopServicePlugin("stdio-service", reason: "p3-n1-late-pump")
                resetServicePluginHostForTest()
            }

            this.registerBrokerServiceFixture(
                "ignore-term",
                pluginId: "slow-service",
                capabilityId: "slow.monitor.status"
            )
            this.registerBrokerServiceFixture(
                "noise-0",
                pluginId: "fast-service",
                capabilityId: "fast.monitor.status",
                resetHost: false
            )
            try {
                @Expect(ensureRegisteredServicePluginStarted("slow-service", startupTimeoutMs: 3000).ok, true)
                @Expect(ensureRegisteredServicePluginStarted("fast-service", startupTimeoutMs: 3000).ok, true)
                let slowCompletions = ArrayList<String>()
                let slowCompletionLock = Mutex()
                let slowStop = spawn {
                    let result = stopServicePlugin("slow-service", reason: "p3-n1-slow", timeoutMillis: 2500)
                    synchronized(slowCompletionLock) { slowCompletions.add(result.status) }
                    result
                }
                sleep(Duration.millisecond * 50)
                @Expect(synchronized(slowCompletionLock) { slowCompletions.size }, 0)
                let slowRestartAttempt = ensureRegisteredServicePluginStarted("slow-service", startupTimeoutMs: 500)
                @Expect(slowRestartAttempt.ok, false)
                @Expect(slowRestartAttempt.status, "stopping")
                let fastStop = stopServicePlugin("fast-service", reason: "p3-n1-fast", timeoutMillis: 1000)
                @Expect(fastStop.ok, true)
                @Expect(synchronized(slowCompletionLock) { slowCompletions.size }, 0)
                @Expect(slowStop.get().ok, true)
                @Expect(synchronized(slowCompletionLock) { slowCompletions.size }, 1)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            } finally {
                let _ = stopServicePlugin("slow-service", reason: "p3-n1-finally", timeoutMillis: 1000)
                let _ = stopServicePlugin("fast-service", reason: "p3-n1-finally", timeoutMillis: 1000)
                resetServicePluginHostForTest()
            }
            } finally {
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                match (oldRelease) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_RELEASE_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_RELEASE_PATH", "") }
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func p3N1StartClaimFollowersLeaseAndDispatchAreFenced(): Unit {
        withIsolatedServicePluginHostTestHome("p3-n1-claim-fences", { home: Path =>
            let marker = home.join("claim.marker")
            let release = home.join("claim.release")
            let cancelledMarker = home.join("claim.cancelled")
            let followerMarker = home.join("claim.follower")
            var starter = None<Future<ServiceStartResult>>
            var stopper = None<Future<ServiceStopResult>>
            var follower = None<Future<ServiceStartResult>>
            try {
                for (phase in ["before_start", "after_attach"]) {
                    try { remove(marker) } catch (_: Exception) { () }
                    try { remove(release) } catch (_: Exception) { () }
                    try { remove(cancelledMarker) } catch (_: Exception) { () }
                    this.registerBrokerServiceFixture("noise-0")
                    setServicePluginStartPhaseHookForTest(Some({ _serviceId: String, current: String =>
                        if (current == phase) {
                            File.writeTo(marker, current.toArray())
                            while (!exists(release)) { sleep(Duration.millisecond * 10) }
                        } else if (current == "claim_cancelled") {
                            File.writeTo(cancelledMarker, current.toArray())
                        }
                    }))
                    starter = Some(spawn { ensureRegisteredServicePluginStarted("stdio-service", startupTimeoutMs: 3000) })
                    @Expect(this.waitForFile(marker), true)
                    stopper = Some(spawn { stopServicePlugin("stdio-service", reason: "claim-${phase}", timeoutMillis: 2500) })
                    @Expect(this.waitForFile(cancelledMarker), true)
                    File.writeTo(release, "release".toArray())
                    @Expect(starter.getOrThrow().get().status, "stopping")
                    @Expect(stopper.getOrThrow().get().ok, true)
                    @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                    starter = None<Future<ServiceStartResult>>
                    stopper = None<Future<ServiceStopResult>>
                    setServicePluginStartPhaseHookForTest(None<(String, String) -> Unit>)
                    resetServicePluginHostForTest()
                }

                try { remove(marker) } catch (_: Exception) { () }
                try { remove(release) } catch (_: Exception) { () }
                try { remove(followerMarker) } catch (_: Exception) { () }
                this.registerBrokerServiceFixture("noise-0")
                setServicePluginStartPhaseHookForTest(Some({ _serviceId: String, phase: String =>
                    if (phase == "before_publish") {
                        File.writeTo(marker, phase.toArray())
                        while (!exists(release)) { sleep(Duration.millisecond * 10) }
                    } else if (phase == "follower_waiting") {
                        File.writeTo(followerMarker, phase.toArray())
                    }
                }))
                starter = Some(spawn { ensureRegisteredServicePluginStarted("stdio-service", startupTimeoutMs: 3000) })
                @Expect(this.waitForFile(marker), true)
                follower = Some(spawn { ensureRegisteredServicePluginStarted("stdio-service", startupTimeoutMs: 3000) })
                @Expect(this.waitForFile(followerMarker), true)
                File.writeTo(release, "release".toArray())
                @Expect(starter.getOrThrow().get().ok, true)
                @Expect(follower.getOrThrow().get().ok, true)
                starter = None<Future<ServiceStartResult>>
                follower = None<Future<ServiceStartResult>>
                setServicePluginStartPhaseHookForTest(None<(String, String) -> Unit>)
                @Expect(stopServicePlugin("stdio-service", reason: "follower", timeoutMillis: 1500).ok, true)

                resetServicePluginHostForTest()
                this.registerBrokerServiceFixture("ignore-term")
                @Expect(ensureRegisteredServicePluginStarted("stdio-service", startupTimeoutMs: 1000).ok, true)
                let currentPid = match (getServicePluginSnapshot("stdio-service")) { case Some(snapshot) => snapshot.pid case None => Int64(0) }
                let leaseDir = home.join("service-plugin").join("runtime").join("stdio-service")
                if (!exists(leaseDir)) { Directory.create(leaseDir, recursive: true) }
                File.writeTo(leaseDir.join("stdio-service-1.lease.json"), ("{\"state\":\"stopped\",\"status\":\"stopped\",\"pluginId\":\"stdio-service\",\"sessionId\":\"stdio-service-1\",\"pid\":${currentPid + 100000},\"parentPid\":0}").toArray())
                let mismatch = stopServicePlugin("stdio-service", reason: "wrong-pid", timeoutMillis: 2500)
                @Expect(mismatch.ok, false)
                @Expect(mismatch.diagnostic.contains("lease_identity_mismatch_after_stop"), true)
                @Expect(mismatch.diagnostic.contains("stop_status=force_terminated"), true)

                resetServicePluginHostForTest()
                try { remove(marker) } catch (_: Exception) { () }
                try { remove(release) } catch (_: Exception) { () }
                this.registerGitCodeStdioScript(this.gitCodeReentrantWritebackScript())
                let deliveryLock = Mutex()
                let deliveries = ArrayList<String>()
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "acct", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "dispatch fence")
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    File.writeTo(marker, "dispatch".toArray())
                    while (!exists(release)) { sleep(Duration.millisecond * 10) }
                    synchronized(deliveryLock) { deliveries.add(text) }
                    ServicePluginEventDeliveryResult(true, "sent")
                }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForFile(marker, timeoutMillis: 3000), true)
                stopper = Some(spawn { stopServicePlugin("gitcode-monitor", reason: "dispatch-fence", timeoutMillis: 2500) })
                sleep(Duration.millisecond * 75)
                @Expect(synchronized(deliveryLock) { deliveries.size }, 0)
                File.writeTo(release, "release".toArray())
                @Expect(stopper.getOrThrow().get().ok, true)
                stopper = None<Future<ServiceStopResult>>
                sleep(Duration.millisecond * 100)
                @Expect(synchronized(deliveryLock) { deliveries.size }, 1)
            } finally {
                if (!exists(release)) { try { File.writeTo(release, "release".toArray()) } catch (_: Exception) { () } }
                setServicePluginStartPhaseHookForTest(None<(String, String) -> Unit>)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (starter) { case Some(future) => try { let _ = future.get(Duration.second * 3) } catch (_: Exception) { try { future.cancel() } catch (_: Exception) { () } } case None => () }
                match (stopper) { case Some(future) => try { let _ = future.get(Duration.second * 3) } catch (_: Exception) { try { future.cancel() } catch (_: Exception) { () } } case None => () }
                match (follower) { case Some(future) => try { let _ = future.get(Duration.second * 3) } catch (_: Exception) { try { future.cancel() } catch (_: Exception) { () } } case None => () }
                resetServicePluginGeneratedReplyStateForTest()
                resetServicePluginHostForTest()
            }
        })
    }

    private func v7VerifyReaderSettlementAfterOwnerTerminal(releaseBeforeDeadline: Bool): Unit {
        let label = if (releaseBeforeDeadline) { "v7-reader-release" } else { "v7-reader-deadline" }
        withIsolatedServicePluginHostTestHome(label, { home: Path =>
            let dispatchGate = ServicePluginTestGate()
            let dispatchSettledGate = ServicePluginTestGate()
            let readerGate = ServicePluginTestGate()
            let ownerStoppedGate = ServicePluginTestGate()
            let probeLock = Mutex()
            let readerProbes = ArrayList<() -> Bool>()
            let heartbeatRelease = home.join("reader-heartbeat.release")
            var retry = None<Future<ServiceStopResult>>
            let sentinelId = "${label}-sentinel"
            var sentinelStarted = false
            let initLine = this.gitCodeInitLine()
            let eventLine = this.gitCodeAcceptedEventLine(eventId: "gitcode:Cangjie/community:issue:${label}")
            let heartbeatLine = this.gitCodeHeartbeatLine(frameId: "${label}-heartbeat")
            try {
                this.registerGitCodeStdioScript(
                    "printf '%s\\n' '${initLine}'; printf '%s\\n' '${eventLine}'; while [ ! -f '${heartbeatRelease.toString()}' ]; do sleep 0.01; done; printf '%s\\n' '${heartbeatLine}'; trap '' TERM HUP; while true; do sleep 1; done")
                setServicePluginBeforeEventDispatchHookForTest(Some({ _serviceId: String => dispatchGate.enterAndWait() }))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "v7-account", "v7-peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "fenced 中文🙂")
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String =>
                    throw Exception("fenced V7 dispatch must not deliver")
                }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                let dispatchEntered = dispatchGate.awaitEntered(2000)
                @Expect(dispatchEntered, true)
                if (!dispatchEntered) { throw Exception("V7 dispatch did not enter") }
                let identity = servicePluginActiveIdentityForTest("gitcode-monitor").getOrThrow()
                let pid = getServicePluginSnapshot("gitcode-monitor").getOrThrow().pid
                let pgid = this.processGroupId(pid)
                @Expect(pid > 1 && pgid > 0, true)
                let baseline = managedStdioBroker().snapshot()
                let sentinel = managedStdioBroker().startOwner(ManagedStdioOwnerSpec(
                    sentinelId, "node",
                    args: ["-e", "process.stdin.on('data',b=>process.stdout.write(b));setInterval(()=>{},1000)"],
                    outputMode: "line", deadlineMs: 15000
                ))
                sentinelStarted = sentinel.ok
                @Expect(sentinelStarted, true)
                if (!sentinelStarted) { throw Exception("V7 sentinel did not start") }
                setServicePluginBeforeReaderEndHookForTest(Some({ owner: String, probe: () -> Bool =>
                    if (owner == identity[0]) {
                        synchronized(probeLock) { readerProbes.add(probe) }
                        readerGate.enterAndWait()
                    }
                }))
                File.writeTo(heartbeatRelease, "release".toArray())
                let readerHeld = readerGate.awaitEntered(2000)
                @Expect(readerHeld, true)
                if (!readerHeld) { throw Exception("V7 heartbeat did not reach reader barrier") }
                setServicePluginDispatchSettledHookForTest(Some({ => dispatchSettledGate.enterAndWait() }))
                let pending = stopServicePlugin("gitcode-monitor", reason: label, timeoutMillis: 1)
                @Expect(pending.ok, false)
                @Expect(pending.status, "cleanup_pending")
                @Expect(servicePluginCleanupPendingCountForTest(), 1)
                setServicePluginAfterOwnerStopHookForTest(Some({ owner: String, ok: Bool, _status: String =>
                    if (owner == identity[0]) {
                        @Expect(ok, true)
                        let readerEntered = readerGate.awaitEntered(2000)
                        @Expect(readerEntered, true)
                        if (!readerEntered) { throw Exception("V7 reader did not reach endRead barrier") }
                        ownerStoppedGate.signal()
                    }
                }))
                dispatchGate.release()
                let dispatchSettled = dispatchSettledGate.awaitEntered(2000)
                @Expect(dispatchSettled, true)
                if (!dispatchSettled) { throw Exception("V7 dispatch did not settle") }
                let retryStarted = MonoTime.now()
                retry = Some(spawn { stopServicePlugin("gitcode-monitor", reason: "${label}-retry", timeoutMillis: 2500) })
                let ownerStopped = ownerStoppedGate.awaitEntered(2000)
                @Expect(ownerStopped, true)
                if (!ownerStopped) { throw Exception("V7 owner did not reach real terminal state") }
                let probe = synchronized(probeLock) { readerProbes[0] }
                @Expect(probe(), false)
                if (releaseBeforeDeadline) {
                    var finishedWhileReaderHeld = false
                    try {
                        let _ = retry.getOrThrow().get(Duration.millisecond * 50)
                        finishedWhileReaderHeld = true
                    } catch (_: Exception) { () }
                    @Expect(finishedWhileReaderHeld, false)
                    readerGate.release()
                }
                let result = retry.getOrThrow().get(Duration.second * 4)
                retry = None<Future<ServiceStopResult>>
                @Expect((MonoTime.now() - retryStarted).toMilliseconds() <= 3000, true)
                if (releaseBeforeDeadline) {
                    @Expect(result.ok, true)
                    @Expect(result.status, "stopped")
                    @Expect(probe(), true)
                } else {
                    @Expect(result.ok, false)
                    @Expect(result.status, "cleanup_pending")
                    @Expect(probe(), false)
                    @Expect(servicePluginCleanupPendingCountForTest(), 1)
                    readerGate.release()
                    let recovered = stopServicePlugin("gitcode-monitor", reason: "${label}-released", timeoutMillis: 2500)
                    @Expect(recovered.ok, true)
                    @Expect(recovered.status, "stopped")
                    @Expect(probe(), true)
                }
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(this.waitForPidGone(pid), true)
                @Expect(this.waitForProcessGroupGone(pgid), true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 1)
                @Expect(managedStdioBroker().snapshot().generation, baseline.generation)
                @Expect(managedStdioBroker().snapshot().brokerPid, baseline.brokerPid)
                @Expect(managedStdioBroker().writeOwnerLine(sentinelId, "v7-sentinel-alive", timeoutMs: 500).ok, true)
                let sentinelReply = managedStdioBroker().readOwnerLine(sentinelId, timeoutMs: 1000).getOrThrow()
                @Expect(sentinelReply.eventType, "owner.stdout")
                @Expect(sentinelReply.text, "v7-sentinel-alive")
                @Expect(managedStdioBroker().stopOwner(sentinelId, timeoutMs: 2000).ok, true)
                while (managedStdioBroker().readOwnerLine(sentinelId, timeoutMs: 25).isSome()) { () }
                sentinelStarted = false
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                @Expect(getServicePluginSnapshot("gitcode-monitor").getOrThrow().status, "stopped")
            } finally {
                readerGate.release()
                dispatchGate.release()
                dispatchSettledGate.release()
                setServicePluginBeforeReaderEndHookForTest(None<(String, () -> Bool) -> Unit>)
                setServicePluginAfterOwnerStopHookForTest(None<(String, Bool, String) -> Unit>)
                match (retry) { case Some(future) => try { let _ = future.get(Duration.second * 4) } catch (_: Exception) { () } case None => () }
                synchronized(probeLock) { readerProbes.clear() }
                if (sentinelStarted) {
                    let _ = managedStdioBroker().stopOwner(sentinelId, timeoutMs: 2000)
                    while (managedStdioBroker().readOwnerLine(sentinelId, timeoutMs: 25).isSome()) { () }
                }
                resetServicePluginGeneratedReplyStateForTest()
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func v7U1TerminalOwnerWaitsForExactReaderBeforeReportingStopped(): Unit {
        this.v7VerifyReaderSettlementAfterOwnerTerminal(true)
    }

    @TestCase
    public func v7B1HeldReaderUsesOriginalDeadlineAndRemainsCleanupPending(): Unit {
        this.v7VerifyReaderSettlementAfterOwnerTerminal(false)
    }

    @TestCase
    public func p3N1CleanupDeadlineAndHostShutdownGateAreBounded(): Unit {
        withIsolatedServicePluginHostTestHome("p3-n1-cleanup-shutdown-gate", { home: Path =>
            let marker = home.join("dispatch.marker")
            let release = home.join("dispatch.release")
            let cancelled = home.join("claim.cancelled")
            let deliveryLock = Mutex()
            let deliveries = ArrayList<String>()
            let dispatchSettledGate = ServicePluginTestGate()
            let staleProbeGate = ServicePluginTestGate()
            var starter = None<Future<ServiceStartResult>>
            var shutdown = None<Future<ServicePluginHostShutdownResult>>
            var staleProbe = None<Future<ServicePluginSupervisorTickResult>>
            var cleanupPid: Int64 = 0
            let oldFixtureMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", marker.toString())
            try {
                this.registerGitCodeStdioScript(this.gitCodeWritebackThenNoiseScript())
                setServicePluginBeforeEventDispatchHookForTest(Some({ _serviceId: String =>
                    File.writeTo(marker, "dispatch".toArray())
                    while (!exists(release)) { sleep(Duration.millisecond * 10) }
                }))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "acct", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "must not deliver late")
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    synchronized(deliveryLock) { deliveries.add(text) }
                    ServicePluginEventDeliveryResult(true, "sent")
                }))
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                cleanupPid = match (getServicePluginSnapshot("gitcode-monitor")) { case Some(snapshot) => snapshot.pid case None => Int64(0) }
                @Expect(cleanupPid > 0, true)
                @Expect(this.waitForFile(marker, timeoutMillis: 3000), true)
                @Expect(this.waitForSnapshotReason("gitcode-monitor", "stdout_protocol_violation", timeoutMillis: 3000), true)
                let ownerDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 3000
                while (managedStdioBroker().snapshot().ownerCount > 0 && DateTime.now().toUnixTimeStamp().toMilliseconds() < ownerDeadline) {
                    sleep(Duration.millisecond * 20)
                }
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                @Expect(this.waitForPidGone(cleanupPid), true)
                let cleanupPublishStarted = MonoTime.now()
                while (servicePluginCleanupPendingCountForTest() == 0 &&
                    (MonoTime.now() - cleanupPublishStarted).toMilliseconds() < 2000) {
                    sleep(Duration.millisecond * 20)
                }
                @Expect(servicePluginCleanupPendingCountForTest(), 1)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "cleanup_pending")
                        @Expect(snapshot.pid, cleanupPid)
                    case None => @Expect(true, false)
                }
                File.writeTo(release, "release".toArray())
                let cleanupDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 2000
                while (servicePluginCleanupPendingCountForTest() > 0 && DateTime.now().toUnixTimeStamp().toMilliseconds() < cleanupDeadline) {
                    sleep(Duration.millisecond * 20)
                }
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) => @Expect(snapshot.pid, 0)
                    case None => @Expect(true, false)
                }
                @Expect(synchronized(deliveryLock) { deliveries.size }, 0)

                setServicePluginBeforeEventDispatchHookForTest(None<(String) -> Unit>)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()
                resetServicePluginHostForTest()

                try { remove(marker) } catch (_: Exception) { () }
                try { remove(release) } catch (_: Exception) { () }
                this.registerGitCodeStdioScript(this.gitCodeIgnoringTermDispatchScript())
                setServicePluginBeforeEventDispatchHookForTest(Some({ _serviceId: String =>
                    File.writeTo(marker, "dispatch".toArray())
                    while (!exists(release)) { sleep(Duration.millisecond * 10) }
                }))
                setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                    let rows = ArrayList<ServicePluginDeliveryTarget>()
                    rows.add(ServicePluginDeliveryTarget("telegram", "acct", "peer"))
                    rows
                }))
                setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                    ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "must remain fenced")
                }))
                setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                    synchronized(deliveryLock) { deliveries.add(text) }
                    ServicePluginEventDeliveryResult(true, "sent")
                }))
                setServicePluginDispatchSettledHookForTest(Some({ => dispatchSettledGate.enterAndWait() }))
                setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true, intervalMs: 60000, healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
                setServicePluginHealthzProbeForTest(Some({ _url: String, _timeoutMs: Int64 =>
                    ServicePluginHealthzProbeResult(false, statusCode: 0, durationMs: 10, diagnostic: "healthz_timeout")
                }))
                let staleFixtureStarted = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(staleFixtureStarted.ok, true)
                if (!staleFixtureStarted.ok) { throw Exception("stale supervisor probe fixture did not start") }
                let beforeStaleProbe = match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) => snapshot
                    case None => throw Exception("stale supervisor probe fixture snapshot is missing")
                }
                @Expect(beforeStaleProbe.supervisorRestartCount, 0)
                let explicitPid = beforeStaleProbe.pid
                @Expect(explicitPid > 0, true)
                if (explicitPid <= 0) { throw Exception("stale supervisor probe fixture pid is missing") }
                let staleLease = home.join("service-plugin").join("runtime").join("gitcode-monitor").join("${beforeStaleProbe.instanceId}.lease.json")
                let explicitPgid = this.processGroupId(explicitPid)
                @Expect(explicitPgid > 0, true)
                @Expect(this.waitForFile(marker, timeoutMillis: 3000), true)
                setServicePluginBeforeSupervisorProbePublishHookForTest(Some({ serviceId: String =>
                    if (serviceId == "gitcode-monitor") { staleProbeGate.enterAndWait() }
                }))
                staleProbe = Some(spawn { runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 2000) })
                let staleProbeEntered = staleProbeGate.awaitEntered(2000)
                @Expect(staleProbeEntered, true)
                if (!staleProbeEntered) { throw Exception("stale supervisor probe did not reach the publish gate") }
                let staleLeaseExists = exists(staleLease)
                @Expect(staleLeaseExists, true)
                if (!staleLeaseExists) { throw Exception("stale supervisor probe lease is missing") }
                let staleLeaseInfo = FileInfo(staleLease)
                let expectedCanonicalLease = canonicalize(home).join("service-plugin").join("runtime").join("gitcode-monitor").join("${beforeStaleProbe.instanceId}.lease.json")
                let staleLeaseOwned = staleLeaseInfo.isRegular() && !staleLeaseInfo.isSymbolicLink() &&
                    canonicalize(staleLease).toString() == expectedCanonicalLease.normalize().toString()
                @Expect(staleLeaseOwned, true)
                if (!staleLeaseOwned) { throw Exception("stale supervisor probe lease identity is not owned by the fixture") }
                remove(staleLease)
                @Expect(exists(staleLease), false)
                if (exists(staleLease)) { throw Exception("stale supervisor probe lease was not removed") }
                let explicitStop = stopServicePlugin("gitcode-monitor", reason: "p3-n1-explicit-cleanup", timeoutMillis: 1)
                @Expect(explicitStop.ok, false)
                @Expect(explicitStop.status, "cleanup_pending")
                @Expect(explicitStop.diagnostic.contains("dispatch_status=dispatch_pending"), true)
                @Expect(servicePluginCleanupPendingCountForTest(), 1)
                @Expect(managedStdioBroker().snapshot().ownerCount, 1)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "cleanup_pending")
                        @Expect(snapshot.instanceId, beforeStaleProbe.instanceId)
                    case None => @Expect(true, false)
                }
                let (initialPendingPidExit, _, _) = executeWithOutput("kill", ["-0", "${explicitPid}"])
                @Expect(initialPendingPidExit, 0)
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 500).status, "cleanup_pending")
                staleProbeGate.release()
                let staleTick = staleProbe.getOrThrow().get(Duration.second * 3)
                staleProbe = None<Future<ServicePluginSupervisorTickResult>>
                @Expect(staleTick.classification.status, "degraded")
                @Expect(staleTick.classification.shouldRecover, true)
                @Expect(staleTick.recovered, false)
                @Expect(staleTick.status, "cleanup_pending")
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "cleanup_pending")
                        @Expect(snapshot.instanceId, beforeStaleProbe.instanceId)
                        @Expect(snapshot.pid, explicitPid)
                        @Expect(snapshot.supervisorRestartCount, 0)
                    case None => @Expect(true, false)
                }
                setServicePluginBeforeSupervisorProbePublishHookForTest(None<(String) -> Unit>)
                setServicePluginHealthzProbeForTest(None<(String, Int64) -> ServicePluginHealthzProbeResult>)
                File.writeTo(release, "release".toArray())
                @Expect(dispatchSettledGate.awaitEntered(2000), true)
                @Expect(synchronized(deliveryLock) { deliveries.size }, 0)
                let cleanupRetry = stopServicePlugin("gitcode-monitor", reason: "p3-n1-cleanup-retry", timeoutMillis: 2500)
                dispatchSettledGate.release()
                @Expect(cleanupRetry.ok, true)
                @Expect(cleanupRetry.status, "stopped")
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                @Expect(this.waitForPidGone(explicitPid), true)
                @Expect(this.processGroupId(explicitPid), 0)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) => @Expect(snapshot.status, "stopped")
                    case None => @Expect(true, false)
                }

                setServicePluginBeforeEventDispatchHookForTest(None<(String) -> Unit>)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                setServicePluginDispatchSettledHookForTest(None<() -> Unit>)
                resetServicePluginGeneratedReplyStateForTest()
                resetServicePluginHostForTest()

                try { remove(marker) } catch (_: Exception) { () }
                try { remove(release) } catch (_: Exception) { () }
                this.registerBrokerServiceFixture("noise-0", pluginId: "shutdown-supervisor", capabilityId: "shutdown-supervisor.monitor.status")
                setServicePluginBeforeSupervisorRegisterHookForTest(Some({ _serviceId: String =>
                    File.writeTo(marker, "before-supervisor-register".toArray())
                    while (!exists(release)) { sleep(Duration.millisecond * 10) }
                }))
                starter = Some(spawn { startServicePlugin("shutdown-supervisor") })
                @Expect(this.waitForFile(marker), true)
                shutdownServicePluginHost(reason: "p3-n1-supervisor-linearization", timeoutMillis: 1000)
                @Expect(servicePluginSupervisorWorkerCountForTest(), 0)
                match (getServicePluginSnapshot("shutdown-supervisor")) {
                    case Some(snapshot) => @Expect(snapshot.status, "stopped")
                    case None => @Expect(true, false)
                }
                File.writeTo(release, "release".toArray())
                @Expect(starter.getOrThrow().get().status, "stopping")
                starter = None<Future<ServiceStartResult>>
                @Expect(startServicePlugin("shutdown-supervisor").status, "stopping")
                @Expect(restartServicePlugin("shutdown-supervisor", reason: "shutdown-gate").status, "stopping")
                @Expect(ensureRegisteredServicePluginStarted("shutdown-supervisor", startupTimeoutMs: 500).status, "stopping")
                @Expect(servicePluginSupervisorWorkerCountForTest(), 0)
                setServicePluginBeforeSupervisorRegisterHookForTest(None<(String) -> Unit>)
                resetServicePluginHostForTest()

                for (phase in ["before_start", "after_attach"]) {
                    try { remove(marker) } catch (_: Exception) { () }
                    try { remove(release) } catch (_: Exception) { () }
                    try { remove(cancelled) } catch (_: Exception) { () }
                    this.registerBrokerServiceFixture("noise-0", pluginId: "shutdown-${phase}", capabilityId: "shutdown-${phase}.monitor.status")
                    setServicePluginStartPhaseHookForTest(Some({ _serviceId: String, current: String =>
                        if (current == phase) {
                            File.writeTo(marker, current.toArray())
                            while (!exists(release)) { sleep(Duration.millisecond * 10) }
                        } else if (current == "claim_cancelled") {
                            File.writeTo(cancelled, current.toArray())
                        }
                    }))
                    starter = Some(spawn { ensureRegisteredServicePluginStarted("shutdown-${phase}", startupTimeoutMs: 3000) })
                    @Expect(this.waitForFile(marker), true)
                    shutdown = Some(spawn { shutdownServicePluginHost(reason: "p3-n1-shutdown", timeoutMillis: 2500) })
                    @Expect(this.waitForFile(cancelled), true)
                    File.writeTo(release, "release".toArray())
                    @Expect(starter.getOrThrow().get().status, "stopping")
                    let _ = shutdown.getOrThrow().get()
                    starter = None<Future<ServiceStartResult>>
                    shutdown = None<Future<ServicePluginHostShutdownResult>>
                    @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                    match (getServicePluginSnapshot("shutdown-${phase}")) {
                        case Some(snapshot) => @Expect(snapshot.pid, 0)
                        case None => @Expect(true, false)
                    }
                    @Expect(ensureRegisteredServicePluginStarted("shutdown-${phase}", startupTimeoutMs: 500).status, "stopping")
                    let supervisorCount = servicePluginSupervisorWorkerCountForTest()
                    @Expect(startServicePlugin("shutdown-${phase}").status, "stopping")
                    @Expect(restartServicePlugin("shutdown-${phase}", reason: "shutdown-gate").status, "stopping")
                    @Expect(servicePluginSupervisorWorkerCountForTest(), supervisorCount)
                    @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                    setServicePluginStartPhaseHookForTest(None<(String, String) -> Unit>)
                    resetServicePluginHostForTest()
                }
            } finally {
                if (!exists(release)) { try { File.writeTo(release, "release".toArray()) } catch (_: Exception) { () } }
                dispatchSettledGate.release()
                staleProbeGate.release()
                setServicePluginBeforeEventDispatchHookForTest(None<(String) -> Unit>)
                setServicePluginDispatchSettledHookForTest(None<() -> Unit>)
                setServicePluginBeforeSupervisorProbePublishHookForTest(None<(String) -> Unit>)
                setServicePluginBeforeSupervisorRegisterHookForTest(None<(String) -> Unit>)
                setServicePluginStartPhaseHookForTest(None<(String, String) -> Unit>)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (starter) { case Some(future) => try { let _ = future.get(Duration.second * 3) } catch (_: Exception) { try { future.cancel() } catch (_: Exception) { () } } case None => () }
                match (shutdown) { case Some(future) => try { let _ = future.get(Duration.second * 3) } catch (_: Exception) { try { future.cancel() } catch (_: Exception) { () } } case None => () }
                match (staleProbe) { case Some(future) => try { let _ = future.get(Duration.second * 3) } catch (_: Exception) { try { future.cancel() } catch (_: Exception) { () } } case None => () }
                match (oldFixtureMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                resetServicePluginGeneratedReplyStateForTest()
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func p3N1SlowInitGracefulStopLatePumpAndDescendantAreOwnerScoped(): Unit {
        withIsolatedServicePluginHostTestHome("p3-n1-owner-scoped-lifecycle", { home: Path =>
            let markerPath = home.join("graceful.marker")
            let releasePath = home.join("release-old-pump")
            let rootPidPath = home.join("root.pid")
            let childPidPath = home.join("child.pid")
            let oldMarker = getVariable("METIS_STDIO_FIXTURE_MARKER_PATH")
            let oldRelease = getVariable("METIS_STDIO_FIXTURE_RELEASE_PATH")
            let oldRootPid = getVariable("METIS_STDIO_FIXTURE_ROOT_PID_PATH")
            let oldChildPid = getVariable("METIS_STDIO_FIXTURE_CHILD_PID_PATH")
            setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", markerPath.toString())
            setVariable("METIS_STDIO_FIXTURE_RELEASE_PATH", releasePath.toString())
            setVariable("METIS_STDIO_FIXTURE_ROOT_PID_PATH", rootPidPath.toString())
            setVariable("METIS_STDIO_FIXTURE_CHILD_PID_PATH", childPidPath.toString())
            var detachedOldPid: Int64 = 0
            var treeRootPid: Int64 = 0
            var treeChildPid: Int64 = 0
            try {
                this.registerBrokerServiceFixture("slow-init", pluginId: "slow-init-service", capabilityId: "slow-init.monitor.status")
                this.registerBrokerServiceFixture("gcm", pluginId: "fast-service", capabilityId: "fast.monitor.status", resetHost: false)
                let slowStarted = spawn { ensureRegisteredServicePluginStarted("slow-init-service", startupTimeoutMs: 2000) }
                sleep(Duration.millisecond * 75)
                let fastStartedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
                let fastStarted = ensureRegisteredServicePluginStarted("fast-service", startupTimeoutMs: 2000)
                let fastElapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - fastStartedAt
                @Expect(fastStarted.ok, true)
                @Expect(fastElapsed < 600, true)
                @Expect(probeServicePluginHealth("fast-service").healthzOk, true)
                @Expect(stopServicePlugin("fast-service", reason: "p3-n1-fast", timeoutMillis: 1500).ok, true)
                @Expect(slowStarted.get().ok, true)
                @Expect(stopServicePlugin("slow-init-service", reason: "p3-n1-slow", timeoutMillis: 1500).ok, true)

                resetServicePluginHostForTest()
                this.registerBrokerServiceFixture("delayed-graceful-stop", pluginId: "graceful-service", capabilityId: "graceful.monitor.status")
                @Expect(ensureRegisteredServicePluginStarted("graceful-service", startupTimeoutMs: 1000).ok, true)
                let graceful = stopServicePlugin("graceful-service", reason: "p3-n1-graceful", timeoutMillis: 1500)
                @Expect(graceful.ok, true)
                @Expect(graceful.diagnostic.contains("stop_status=graceful_exited"), true)
                @Expect(this.waitForFile(markerPath), true)
                @Expect(this.readTextFile(markerPath).contains("graceful"), true)
                @Expect(this.readTextFile(markerPath).contains("term"), false)

                resetServicePluginHostForTest()
                this.registerBrokerServiceFixture("latch-event", pluginId: "latch-service", capabilityId: "latch.monitor.status")
                @Expect(ensureRegisteredServicePluginStarted("latch-service", startupTimeoutMs: 1000).ok, true)
                detachedOldPid = match (getServicePluginSnapshot("latch-service")) {
                    case Some(snapshot) => snapshot.pid
                    case None => Int64(0)
                }
                @Expect(dropServicePluginActiveProcessForTest("latch-service", stopProcess: false), true)
                resetServicePluginHostForTest()
                this.registerBrokerServiceFixture("noise-0", pluginId: "latch-service", capabilityId: "latch.monitor.status")
                @Expect(ensureRegisteredServicePluginStarted("latch-service", startupTimeoutMs: 1000).ok, true)
                let replacementPid = match (getServicePluginSnapshot("latch-service")) {
                    case Some(snapshot) => snapshot.pid
                    case None => Int64(0)
                }
                File.writeTo(releasePath, "release".toArray())
                @Expect(this.waitForPidGone(detachedOldPid), true)
                sleep(Duration.millisecond * 100)
                match (getServicePluginSnapshot("latch-service")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "running")
                        @Expect(snapshot.pid, replacementPid)
                    case None => @Expect(true, false)
                }
                @Expect(invokeRegisteredCapability(CapabilityInvokeRequest("latch.monitor.status", payload: "{}")).ok, true)
                @Expect(stopServicePlugin("latch-service", reason: "p3-n1-replacement", timeoutMillis: 1500).ok, true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)

                resetServicePluginHostForTest()
                this.registerBrokerServiceFixture("ignore-term-tree", pluginId: "tree-service", capabilityId: "tree.monitor.status")
                @Expect(ensureRegisteredServicePluginStarted("tree-service", startupTimeoutMs: 1000).ok, true)
                @Expect(this.waitForFile(rootPidPath), true)
                @Expect(this.waitForFile(childPidPath), true)
                treeRootPid = this.readCounterFile(rootPidPath)
                treeChildPid = this.readCounterFile(childPidPath)
                @Expect(treeRootPid > 0, true)
                @Expect(treeChildPid > 0, true)
                @Expect(this.processGroupId(treeRootPid), treeRootPid)
                @Expect(this.processGroupId(treeChildPid), treeRootPid)
                let treeStopped = stopServicePlugin("tree-service", reason: "p3-n1-tree", timeoutMillis: 2500)
                @Expect(treeStopped.ok, true)
                @Expect(this.waitForPidGone(treeRootPid), true)
                @Expect(this.waitForPidGone(treeChildPid), true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            } finally {
                if (!exists(releasePath)) { try { File.writeTo(releasePath, "release".toArray()) } catch (_: Exception) { () } }
                let _ = stopServicePlugin("stdio-service", reason: "p3-n1-finally", timeoutMillis: 500)
                let _ = stopServicePlugin("graceful-service", reason: "p3-n1-finally", timeoutMillis: 500)
                let _ = stopServicePlugin("latch-service", reason: "p3-n1-finally", timeoutMillis: 500)
                let _ = stopServicePlugin("tree-service", reason: "p3-n1-finally", timeoutMillis: 500)
                let _ = stopServicePlugin("slow-init-service", reason: "p3-n1-finally", timeoutMillis: 500)
                let _ = stopServicePlugin("fast-service", reason: "p3-n1-finally", timeoutMillis: 500)
                if (detachedOldPid > 0) { let _ = executeWithOutput("kill", ["-KILL", "${detachedOldPid}"]) }
                if (treeRootPid > 0) { let _ = executeWithOutput("kill", ["-KILL", "-${treeRootPid}"]) }
                if (treeChildPid > 0) { let _ = executeWithOutput("kill", ["-KILL", "${treeChildPid}"]) }
                resetServicePluginHostForTest()
                match (oldMarker) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_MARKER_PATH", "") }
                match (oldRelease) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_RELEASE_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_RELEASE_PATH", "") }
                match (oldRootPid) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_ROOT_PID_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_ROOT_PID_PATH", "") }
                match (oldChildPid) { case Some(value) => setVariable("METIS_STDIO_FIXTURE_CHILD_PID_PATH", value) case None => setVariable("METIS_STDIO_FIXTURE_CHILD_PID_PATH", "") }
            }
        })
    }

    @TestCase
    public func stdioInvokeRejectsNoiseBudgetExceededWithRedactedDiagnostic(): Unit {
        let initLine = "{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"stdio-service\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}"
        let lines = ArrayList<String>()
        for (i in 0..9) {
            lines.add("WARN noisy stdout ${i} Authorization: Bearer secret-value path=/Users/name/private")
        }
        lines.add(this.stdioInvokeResponseLine("{\"ok\":true,\"status\":\"ok\"}"))
        this.registerStdioScript(this.stdioScriptWithInvokeLines(initLine, lines.toArray()))
        try {
            let result = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(result.ok, false)
            @Expect(result.status, "stdout_protocol_violation")
            @Expect(result.diagnostic.contains("secret-value"), false)
            @Expect(result.diagnostic.contains("/Users/name"), false)
            @Expect(result.diagnostic.contains("payload-"), true)
        } finally {
            resetServicePluginHostForTest()
        }
    }

    @TestCase
    public func stdioInvokeRejectsOversizedFrameImmediately(): Unit {
        let initLine = "{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"stdio-service\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}"
        let hugeFrame = "{\"type\":\"response\",\"frameId\":\"huge\",\"serviceId\":\"stdio-service\",\"payload\":\"${this.repeatText("x", 65537)}\"}"
        let responseLine = this.stdioInvokeResponseLine("{\"ok\":true,\"status\":\"ok\"}")
        this.registerStdioScript(this.stdioScriptWithInvokeLines(initLine, [hugeFrame, responseLine]))
        try {
            let result = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(result.ok, false)
            @Expect(result.status, "frame_too_large")
        } finally {
            resetServicePluginHostForTest()
        }
    }

    @TestCase
    public func stdioInvokeDoesNotTreatEventAuditOrHeartbeatAsResponse(): Unit {
        let initLine = "{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"stdio-service\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}"
        let eventLine = "{\"type\":\"event\",\"frameId\":\"event-1\",\"serviceId\":\"stdio-service\",\"method\":\"emitCapabilityEvent\",\"capabilityId\":\"stdio.monitor.status\",\"payload\":{\"ok\":true,\"status\":\"event\"}}"
        let auditLine = "{\"type\":\"audit\",\"frameId\":\"audit-1\",\"serviceId\":\"stdio-service\",\"method\":\"audit\",\"payload\":{\"ok\":true,\"status\":\"audit\"}}"
        let heartbeatLine = "{\"type\":\"heartbeat\",\"frameId\":\"heartbeat-1\",\"serviceId\":\"stdio-service\",\"method\":\"heartbeat\",\"payload\":{\"ok\":true,\"status\":\"alive\"}}"
        let responseLine = this.stdioInvokeResponseLine("{\"ok\":true,\"status\":\"ok\"}")
        this.registerStdioScript(this.stdioScriptWithInvokeLines(initLine, [eventLine, auditLine, heartbeatLine, responseLine]))
        try {
            let result = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(result.ok, true)
            @Expect(result.status, "ok")
        } finally {
            resetServicePluginHostForTest()
        }
    }

    @TestCase
    public func stdioInvokeRejectsWrongRequestIdentity(): Unit {
        let initLine = "{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"stdio-service\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}"
        let wrongService = this.stdioInvokeResponseLine("{\"ok\":true,\"status\":\"ok\"}", serviceId: "other-service")
        let wrongCapability = this.stdioInvokeResponseLine("{\"ok\":true,\"status\":\"ok\"}", capabilityId: "stdio.monitor.other")
        let wrongCorrelation = this.stdioInvokeResponseLine("{\"ok\":true,\"status\":\"ok\"}", correlationId: "corr-other")
        let correctResponse = this.stdioInvokeResponseLine("{\"ok\":true,\"status\":\"ok\"}")
        this.registerStdioScript(this.stdioScriptWithInvokeBatches(
            initLine,
            [[wrongService], [wrongCapability], [wrongCorrelation, correctResponse]]
        ))
        try {
            let wrongServiceResult = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(wrongServiceResult.ok, false)
            @Expect(wrongServiceResult.status, "unexpected_frame")

            let wrongCapabilityResult = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(wrongCapabilityResult.ok, false)
            @Expect(wrongCapabilityResult.status, "unexpected_frame")

            let correlatedResult = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(correlatedResult.ok, true)
            @Expect(correlatedResult.status, "ok")
        } finally {
            resetServicePluginHostForTest()
        }
    }

    @TestCase
    public func tRoot001AsyncEventPumpAllowsSamePluginWritebackResponse(): Unit {
        // T-ROOT-001, T-ASYNC-001, T-E2E-SP-001 (Metis half-chain)
        withIsolatedServicePluginHostTestHome("service-plugin-root-async-writeback", { _home: Path =>
            this.registerGitCodeStdioScript(this.gitCodeReentrantWritebackScript())
            let messages = ArrayList<String>()
            let lock = Mutex()
            setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                let rows = ArrayList<ServicePluginDeliveryTarget>()
                rows.add(ServicePluginDeliveryTarget("telegram", "acct", "peer"))
                rows
            }))
            setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充回归测试。")
            }))
            setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                synchronized(lock) { messages.add(text) }
                ServicePluginEventDeliveryResult(true, "sent")
            }))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForMessage(messages, lock, timeoutMillis: 15000), true)
                let message = this.firstMessage(messages, lock)
                @Expect(message.contains("GitCode 回复已写回"), true)
                @Expect(message.contains("写回状态未知/超时"), false)
                @Expect(message.contains("\"replyUrl\""), false)
            } finally {
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tMaintainerEmailT5E2EPos002HostFakeGcmResponseRendersReadableStatus(): Unit {
        // T5-E2E-POS-002.
        withIsolatedServicePluginHostTestHome("service-plugin-maintainer-email-writeback", { _home: Path =>
            this.registerGitCodeStdioScript(this.gitCodeMaintainerEmailWritebackScript())
            let messages = ArrayList<String>()
            let lock = Mutex()
            setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                let rows = ArrayList<ServicePluginDeliveryTarget>()
                rows.add(ServicePluginDeliveryTarget("telegram", "acct", "peer"))
                rows
            }))
            setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充回归测试。")
            }))
            setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                synchronized(lock) { messages.add(text) }
                ServicePluginEventDeliveryResult(true, "sent")
            }))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForMessage(messages, lock, timeoutMillis: 15000), true)
                let message = this.firstMessage(messages, lock)
                @Expect(message.contains("GitCode 回复已写回"), true)
                @Expect(message.contains("维护者提及: 已追加 teamLeader=1 codeowner=2"), true)
                @Expect(message.contains("维护者邮件: 已发送 2"), true)
                @Expect(message.contains("\"ok\""), false)
                @Expect(message.contains("\"emailNotificationStatus\""), false)
                @Expect(message.contains("GitCodeMonitor"), false)
                @Expect(message.contains("@Team Leader:"), false)
                @Expect(message.contains("@Codeowner:"), false)
            } finally {
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tRoot002AsyncWritebackIgnoresUnrelatedHeartbeatAndResponseFrames(): Unit {
        // T-ROOT-002, T-ASYNC-002, T-ASYNC-005
        withIsolatedServicePluginHostTestHome("service-plugin-root-async-unrelated", { _home: Path =>
            this.registerGitCodeStdioScript(this.gitCodeReentrantWritebackScript(includeUnrelatedFrames: true))
            let messages = ArrayList<String>()
            let lock = Mutex()
            setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                let rows = ArrayList<ServicePluginDeliveryTarget>()
                rows.add(ServicePluginDeliveryTarget("telegram", "acct", "peer"))
                rows
            }))
            setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "建议补充回归测试。")
            }))
            setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, text: String =>
                synchronized(lock) { messages.add(text) }
                ServicePluginEventDeliveryResult(true, "sent")
            }))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForMessage(messages, lock, timeoutMillis: 15000), true)
                let message = this.firstMessage(messages, lock)
                @Expect(message.contains("GitCode 回复已写回"), true)
                @Expect(message.contains("unexpected_frame"), false)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) => @Expect(snapshot.status, "running")
                    case None => @Expect(true, false)
                }
            } finally {
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func tAsync005PumpContinuesHeartbeatWhileWritebackWaits(): Unit {
        // T-ASYNC-003, T-ASYNC-005, T-E2E-SP-007
        withIsolatedServicePluginHostTestHome("service-plugin-root-async-timeout", { _home: Path =>
            this.registerGitCodeStdioScript(this.gitCodeNoWritebackResponseScript())
            setServicePluginWebhookSubscribersProviderForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent =>
                let rows = ArrayList<ServicePluginDeliveryTarget>()
                rows.add(ServicePluginDeliveryTarget("telegram", "acct", "peer"))
                rows
            }))
            setServicePluginWebhookGeneratedReplyHandlerForTest(Some({ _event: ServicePluginAcceptedGitCodeEvent, _target: ServicePluginDeliveryTarget =>
                ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "超时也要通知。")
            }))
            setServicePluginEventDeliveryForTest(Some({ _target: ServicePluginDeliveryTarget, _text: String =>
                ServicePluginEventDeliveryResult(true, "sent")
            }))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForHeartbeat("gitcode-monitor", timeoutMillis: 1000), true)
            } finally {
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                resetServicePluginGeneratedReplyStateForTest()
                resetServicePluginHostForTest()
            }
        })
    }

    @TestCase
    public func stdioInvokeRejectsNonObjectPayloadForNewProtocol(): Unit {
        this.registerStdio("\"ok\"")
        try {
            let result = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(result.ok, false)
            @Expect(result.status, "payload_invalid")
        } finally {
            resetServicePluginHostForTest()
        }
    }

    @TestCase
    public func stdioInitializeFalseReturnsInitializeFailedWithStatusDiagnostic(): Unit {
        this.registerStdio("{ \"ok\": true, \"status\": \"ok\" }", initPayload: "{ \"ok\": false, \"status\": \"config_missing\" }")
        try {
            let result = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(result.ok, false)
            @Expect(result.status, "initialize_failed")
            @Expect(result.diagnostic.contains("config_missing"), true)
            @Expect(result.diagnostic.contains("{"), false)
        } finally {
            resetServicePluginHostForTest()
        }
    }
}


// Isolate the dispatch-reserve boundary from unrelated diagnostic CLI startup.
// Both callbacks still require actual OS proof before reporting terminal state.
@When[os == "macOS"]
private func servicePluginInstallNativeBoundaryProbesForTest(home: Path): Unit {
    let binding = try {
        let snapshot = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
        let birth = observeProcessBirthIdentity(snapshot.pid).getOrThrow()
        let path = home.join("service-plugin").join("runtime").join("gitcode-monitor").join(snapshot.instanceId + ".lease.json")
        let lease = JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
        let port = lease.get("port").getOrThrow().asInt().getValue()
        if (snapshot.pid <= 1 || port <= 0 || port > 65535 ||
            lease.get("pid").getOrThrow().asInt().getValue() != snapshot.pid ||
            lease.get("parentPid").getOrThrow().asInt().getValue() != Int64(getProcessId()) ||
            lease.get("sessionId").getOrThrow().asString().getValue() != snapshot.instanceId ||
            lease.get("bindHost").getOrThrow().asString().getValue() != "127.0.0.1") {
            throw Exception("s3_boundary_fixture_binding_invalid")
        }
        (snapshot.pid, birth, port)
    } catch (_: Exception) { throw Exception("s3_boundary_fixture_binding_invalid") }
    setServicePluginPidProbeCommandForTest(Some({ pid: Int64, timeoutMs: Int64 =>
        if (pid != binding[0] || timeoutMs <= 0) { return (Int64(124), "", "") }
        let deadline = MonoTime.now() + Duration.millisecond * timeoutMs
        let probe = probeProcessBirthIdentity(binding[1], deadline)
        if (MonoTime.now() > deadline || !probe.conclusive) { return (Int64(124), "", "") }
        if (probe.alive && probe.status == "alive") { return (Int64(0), "", "") }
        if (!probe.alive && probe.status == "gone") { return (Int64(1), "", "ESRCH") }
        (Int64(124), "", "")
    }))
    setServicePluginPortReleaseCommandForTest(Some({ port: Int64, pid: Int64, timeoutMs: Int64 =>
        if (pid != binding[0] || port != binding[2] || timeoutMs <= 0) { return (Int64(124), "", "") }
        let deadline = MonoTime.now() + Duration.millisecond * timeoutMs
        try {
            try (socket = TcpServerSocket(bindAt: IPSocketAddress("127.0.0.1", UInt16(port)))) {
                socket.reuseAddress = false
                socket.reusePort = false
                socket.bind()
            }
            if (MonoTime.now() > deadline) { (Int64(124), "", "") }
            else { (Int64(1), "", "") }
        } catch (_: Exception) { (Int64(124), "", "") }
    }))
}

@When[os != "macOS"]
private func servicePluginInstallNativeBoundaryProbesForTest(_home: Path): Unit { () }

@When[os == "macOS"]
private enum MtimeThinCaseSelection { Input0 | Input1 | Input2 | Input3 }

@When[os == "macOS"]
private func mtimeThinSelections(): Array<MtimeThinCaseSelection> { [MtimeThinCaseSelection.Input0, MtimeThinCaseSelection.Input1, MtimeThinCaseSelection.Input2, MtimeThinCaseSelection.Input3] }

@When[os == "macOS"]
private func mtimeThinKey(selected: MtimeThinCaseSelection): String {
    match (selected) {
        case MtimeThinCaseSelection.Input0 => "darwin"
        case MtimeThinCaseSelection.Input1 => "fallback"
        case MtimeThinCaseSelection.Input2 => "failure"
        case MtimeThinCaseSelection.Input3 => "invalid"
    }
}

@When[os == "macOS"]
private func mtimeThinSelect(raw: Option<String>): MtimeThinCaseSelection {
    match (raw) {
        case Some(value) => match (value) {
            case "darwin" => MtimeThinCaseSelection.Input0
            case "fallback" => MtimeThinCaseSelection.Input1
            case "failure" => MtimeThinCaseSelection.Input2
            case "invalid" => MtimeThinCaseSelection.Input3
            case _ => throw Exception("thin_input_selector_invalid")
        }
        case None => throw Exception("thin_input_selector_invalid")
    }
}

// Scratch private-helper template. Instantiate once per package, not per test.
// Required imports are listed in manifest; no production/public test framework.
@When[os == "macOS"]
foreign {
    func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, size: Int32): Int32
}


@When[os == "macOS"]
private func mtimeThinText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("thin_fixture_invalid_encoding") }
}

@When[os == "macOS"]
private func mtimeThinThreadSnapshot(): (Int64, Int64, Int64) {
    (getThreadCount(), getBlockingThreadCount(), mtimeThinCount(6))
}

@When[os == "macOS"]
private func mtimeThinThreadsWithin(baseline: (Int64, Int64, Int64)): Bool {
    getThreadCount() <= baseline[0] && getBlockingThreadCount() <= baseline[1]
}

@When[os == "macOS"]
private func mtimeThinCount(flavor: Int32): Int64 {
    var slots = VArray<UInt64, $4096>(repeat: 0)
    let count = unsafe { proc_pidinfo(Int32(getProcessId()), flavor, 0, inout slots, 32768) }
    if (count <= 0 || count >= 32768 || count % 8 != 0) { throw Exception("thin_observation_failed") }
    Int64(count) / 8
}

@When[os == "macOS"]
private func mtimeThinRead(stream: InputStream): Array<Byte> {
    let bytes = ArrayList<Byte>(); let buffer = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = stream.read(buffer)
        if (count == 0) { return bytes.toArray() }
        for (index in 0..count) { bytes.add(buffer[index]) }
        if (bytes.size > 65536) { throw Exception("thin_diagnostic_oversize") }
    }
    bytes.toArray()
}

@When[os == "macOS"]
private func mtimeThinJoin(worker: Future<Array<Byte>>, deadline: MonoTime): Bool {
    let remaining = deadline - MonoTime.now()
    if (remaining <= Duration.Zero) { return false }
    try { let _ = worker.get(remaining); true }
    catch (_: TimeoutException) { false }
    catch (_: Exception) { true }
}

@When[os == "macOS"]
private class MtimeThinCase {
    let home: Path
    let actor: Path
    let journal: Path
    let parent: String
    let nonce: String
    let bound: Bool
    var failed = false
    var completed = false
    var auxiliaryJoined = true
    var selectedCase = ""
    var warmRounds: Int64 = 0
    var formalRounds: Int64 = 0
    var negativeRounds: Int64 = 0
    var roundDirectory = None<Path>
    let priorEnvironment = ArrayList<(String, Option<String>)>()
    init(home: Path, actor: Path, nonce: String, bound: Bool) {
        this.home = home; this.actor = actor; this.nonce = nonce; this.bound = bound
        this.journal = home.join("inventory")
        this.parent = currentProcessInstanceIdentity().getOrThrow().serialize()
        for (key in ["METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT",
            "METIS_PROCESS_RECOVERY_BROKER_KEY", "METIS_PROCESS_RECOVERY_OWNER_PID", "METIS_PROCESS_RECOVERY_OWNER_BIRTH",
            "METIS_THIN_ACTOR_DIRECTORY", "METIS_THIN_ACTOR_NONCE", "METIS_THIN_ACTOR_CASE", "METIS_CJPM_ROOT", "PATH"]) {
            priorEnvironment.add((key, getVariable(key)))
        }
        if (bound) { check(managedRecoveryInitialize(journal, parent, nonce)) }
        else {
            for (key in ["METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT",
                "METIS_PROCESS_RECOVERY_BROKER_KEY", "METIS_PROCESS_RECOVERY_OWNER_PID", "METIS_PROCESS_RECOVERY_OWNER_BIRTH"]) {
                removeVariable(key)
            }
        }
    }
    func check(value: Bool): Unit { failed = failed || !value; @Expect(value, true) }
    func begin(name: String, commands: Array<String>): Unit {
        let path = home.join(name); Directory.create(path); Directory.create(path.join("bin")); Directory.create(path.join("responses"))
        File.writeTo(path.join("binding"), nonce.toArray())
        for (command in commands) {
            copy(actor, to: path.join("bin").join(command))
            check(chmod(path.join("bin").join(command).toString(), 0o700u32) == 0)
        }
        roundDirectory = Some(path)
        setVariable("METIS_THIN_ACTOR_DIRECTORY", path.toString())
        setVariable("METIS_THIN_ACTOR_NONCE", nonce)
        setVariable("METIS_THIN_ACTOR_CASE", "raw_routes")
        // Only this controlled selfchild changes PATH; parent env is unchanged.
        setVariable("PATH", path.join("bin").toString())
    }
    func route(command: String, phase: String, stdout: Array<Byte>, stderr: Array<Byte>, code: Int64): Unit {
        let directory = roundDirectory.getOrThrow().join("responses")
        let prefix = command + "." + phase
        File.writeTo(directory.join(prefix + ".stdout.bin"), stdout)
        File.writeTo(directory.join(prefix + ".stderr.bin"), stderr)
        File.writeTo(directory.join(prefix + ".exit.txt"), code.toString().toArray())
    }
    func receipts(): Array<JsonObject> {
        let results = ArrayList<JsonObject>()
        for (entry in Directory.readFrom(roundDirectory.getOrThrow())) {
            if (entry.name.startsWith("receipt-") && entry.name.endsWith(".json")) {
                check(entry.isRegular() && !entry.isSymbolicLink())
                let receipt = JsonValue.fromStr(mtimeThinText(entry.path)).asObject()
                check(receipt.get("nonce").getOrThrow().asString().getValue() == nonce)
                check(receipt.get("pid").getOrThrow().asInt().getValue() > 1)
                results.add(receipt)
            }
        }
        results.toArray()
    }
    func sourceTerminal(): Bool {
        if (!bound) { return true }
        let source = managedRecoveryProbeRecords(journal, parent, nonce, MonoTime.now() + Duration.second * 2)
        source.ok && source.terminal
    }
    func terminal(): Bool { auxiliaryJoined && sourceTerminal() }
    func stable(fd: Int64, threadBaseline: (Int64, Int64, Int64)): Unit {
        let deadline = MonoTime.now() + Duration.second * 2
        while (MonoTime.now() < deadline && (!sourceTerminal() || mtimeThinCount(1) > fd || !mtimeThinThreadsWithin(threadBaseline))) {
            sleep(Duration.millisecond * 10)
        }
        check(sourceTerminal()); check(mtimeThinCount(1) == fd); check(mtimeThinThreadsWithin(threadBaseline))
        let currentThreads = mtimeThinThreadSnapshot()
        println("R-THREADS warmCjTasks=${threadBaseline[0]};finalCjTasks=${currentThreads[0]};warmCjBlocking=${threadBaseline[1]};finalCjBlocking=${currentThreads[1]};warmOsThreads=${threadBaseline[2]};finalOsThreads=${currentThreads[2]}")
    }
    func finish(): Unit { completed = !failed }
    func restore(): Unit {
        for ((key, prior) in priorEnvironment) {
            match (prior) { case Some(text) => setVariable(key, text) case None => removeVariable(key) }
        }
    }
}

@When[os == "macOS"]
private func mtimeThinCompileActor(home: Path,
    sourceFile!: String = "thin_process_output_fixture.cj", outputName!: String = "owned-thin-actor"): (Path, Bool) {
    if (!["thin_process_output_fixture.cj", "mcp_lifecycle_fixture.cj"].contains(sourceFile) ||
        !["owned-thin-actor", "owned-mcp-actor"].contains(outputName)) { throw Exception("thin_actor_source_invalid") }
    let source = canonicalize(Path("test/fixtures/service_plugin/stdio_protocol").join(sourceFile))
    let sdk = canonicalize(Path(getVariable("CANGJIE_HOME").getOrThrow()))
    let compilerPath = sdk.join("bin/cjc")
    let magic = canonicalize(Path(getVariable("MAGIC_PATH").getOrThrow()))
    let stdx = magic.join("libs/cangjie-stdx-mac-aarch64-1.0.0.1/darwin_aarch64_llvm/dynamic/stdx")
    let binary = home.join(outputName)
    let compiler = launchManagedRawChild(compilerPath.toString(), [source.toString(), "--import-path", stdx.toString(),
        "-L", stdx.toString(), "-lstdx.encoding.json", "--link-options", "-rpath ${stdx.toString()}", "-o", binary.toString()],
        newGeneration: true, stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
    var output = None<Future<Array<Byte>>>; var error = None<Future<Array<Byte>>>
    var original = None<Exception>; var joined = false; var reaped = false
    let operationDeadline = MonoTime.now() + Duration.second * 60
    try {
        output = Some(spawn { mtimeThinRead(compiler.stdOutPipe) }); error = Some(spawn { mtimeThinRead(compiler.stdErrPipe) })
        let code = compiler.wait(timeout: Some(max(Duration.Zero, operationDeadline - MonoTime.now()))); reaped = true
        let outputRemaining = operationDeadline - MonoTime.now()
        if (outputRemaining <= Duration.Zero) { throw Exception("thin_actor_compile_timeout") }
        let _ = output.getOrThrow().get(outputRemaining)
        let errorRemaining = operationDeadline - MonoTime.now()
        if (errorRemaining <= Duration.Zero) { throw Exception("thin_actor_compile_timeout") }
        let _ = error.getOrThrow().get(errorRemaining)
        if (code != 0 || !exists(binary) || !FileInfo(binary).isRegular()) { throw Exception("thin_actor_compile_failed") }
    } catch (failure: Exception) { original = Some(failure) }
    finally {
        let cleanupDeadline = MonoTime.now() + Duration.second * 3
        try {
            if (compiler.isAlive()) { compiler.terminate(force: true) }
            let _ = compiler.wait(timeout: Some(max(Duration.Zero, cleanupDeadline - MonoTime.now()))); reaped = true
        } catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
        finally {
            try { compiler.closeStreams() }
            catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            finally {
                let outputJoined = output.map({ worker => mtimeThinJoin(worker, cleanupDeadline) }) ?? true
                let errorJoined = error.map({ worker => mtimeThinJoin(worker, cleanupDeadline) }) ?? true
                joined = outputJoined && errorJoined && MonoTime.now() <= cleanupDeadline
                try { File.writeTo(home.join("compiler-proof"), "joined:${joined}\nreaped:${reaped}\n".toArray()) }
                catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            }
        }
    }
    if (let Some(failure) <- original) { throw failure }
    if (!joined || !reaped || !compiler.streamsAreClosed()) { throw Exception("thin_actor_compile_pending") }
    (binary, true)
}

@When[os == "macOS"]
private func mtimeThinRun(filter: String, action: (MtimeThinCase) -> Unit, stdin!: Array<Byte> = []): Unit {
    if (let Some(outerText) <- getVariable("METIS_THIN_OUTER")) {
        let outer = canonicalize(Path(outerText))
        let nonce = getVariable("METIS_THIN_OUTER_NONCE").getOrThrow()
        if (!outer.toString().startsWith("/private/tmp/") || mtimeThinText(outer.join("owned.marker")) != nonce) {
            throw Exception("thin_outer_binding_invalid")
        }
        let home = canonicalize(Path(getVariable("METIS_HOME").getOrThrow()))
        let actor = canonicalize(Path(getVariable("METIS_THIN_ACTOR_BINARY").getOrThrow()))
        if (!home.toString().startsWith(outer.toString() + "/") || actor != outer.join("owned-thin-actor")) {
            throw Exception("thin_actor_binding_invalid")
        }
        let selected = mtimeThinSelect(getVariable("METIS_THIN_INPUT_CASE"))
        let fixture = MtimeThinCase(home, actor, nonce, getVariable("METIS_THIN_BOUND") == Some("true"))
        fixture.selectedCase = mtimeThinKey(selected)
        var original = None<Exception>
        try { action(fixture) }
        catch (failure: Exception) { original = Some(failure) }
        finally {
            try {
                let terminal = fixture.terminal()
                let childFormal = fixture.completed && !fixture.failed && original.isNone() && terminal
                File.writeTo(home.join("formal-before-fallback.json"),
                    ("{\"formal\":${childFormal},\"terminal\":${terminal},\"recorded\":true," +
                        "\"case\":\"${fixture.selectedCase}\",\"nonce\":\"${nonce}\",\"bound\":${fixture.bound}," +
                        "\"warmRounds\":${fixture.warmRounds},\"formalRounds\":${fixture.formalRounds},\"negativeRounds\":${fixture.negativeRounds}}").toArray())
                if (!childFormal && original.isNone()) { original = Some(Exception("thin_input_child_formal_failed")) }
            } catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            finally {
                let cleanupDeadline = MonoTime.now() + Duration.second * 3
                try {
                    var terminal = fixture.auxiliaryJoined
                    if (fixture.bound) {
                        let stopped = managedRecoveryStopOwnedChildren((fixture.journal.toString(), fixture.parent), cleanupDeadline)
                        let source = managedRecoveryProbeRecords(fixture.journal, fixture.parent, fixture.nonce, cleanupDeadline)
                        terminal = terminal && stopped && source.ok && source.terminal
                    }
                    terminal = terminal && MonoTime.now() <= cleanupDeadline
                    if (terminal) { fixture.restore() }
                    else if (original.isNone()) { original = Some(Exception("thin_child_cleanup_pending_evidence_retained")) }
                } catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            }
        }
        if (let Some(failure) <- original) { throw failure }
        return
    }
    synchronized(MetisProcessEnvironmentLock) {
        let outer = Directory.createTemp("/private/tmp")
        let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
        File.writeTo(outer.join("owned.marker"), nonce.toArray())
        println("R-WRAP fixture=${outer.fileName};nonce=${nonce};kind=${filter}")
        var formal = false
        var compilerReady = false
        let aggregateDeadline = MonoTime.now() + Duration.second * 583
        var aggregateFormal: Int64 = 0
        var aggregateWarm: Int64 = 0
        var aggregateNegative: Int64 = 0
        let completedCases = HashMap<String, Int64>()
        try {
            let artifact = mtimeThinCompileActor(outer); compilerReady = artifact[1]
            let (_, nodeBytes, _) = managedRecoveryExecuteWithOutput("which", ["node"])
            let node = try { String.fromUtf8(nodeBytes).trimAscii() }
                catch (_: Exception) { throw Exception("thin_node_resolution_failed") }
            if (node.isEmpty() || !Path(node).isAbsolute() || !FileInfo(node).isRegular()) {
                throw Exception("thin_node_resolution_failed")
            }
            var allCases = true
            var selectorRejections: Int64 = 0
            let invalidSelections: Array<Option<String>> = [None, Some("unknown")]
            for (raw in invalidSelections) {
                try { let _ = mtimeThinSelect(raw) }
                catch (failure: Exception) { if (failure.message == "thin_input_selector_invalid") { selectorRejections += 1 } }
            }
            if (selectorRejections != 2) { throw Exception("thin_input_selector_validation_failed") }
            let selections = mtimeThinSelections()
            if (selections.size != 4) { throw Exception("thin_input_matrix_incomplete") }
            for (mode in ["absent", "bound"]) {
                for (selected in selections) {
                    let caseName = mtimeThinKey(selected)
                    let scheduleKey = mode + "-" + caseName
                    if (completedCases.contains(scheduleKey) || MonoTime.now() >= aggregateDeadline) { throw Exception("thin_input_schedule_invalid") }
                    let home = outer.join(scheduleKey); Directory.create(home)
                    File.writeTo(home.join("metis.json"), "{}".toArray())
                    File.writeTo(home.join("stdin"), stdin)
                    let environment = HashMap(getVariables())
                    let providerAliases = ArrayList<String>()
                    for (descriptor in cliModelProviderCatalogDescriptors()) {
                        for (alias in descriptor.apiKeyEnvAliases) { providerAliases.add(alias.toAsciiUpper()) }
                    }
                    for (name in environment.keys().toArray()) {
                        let upper = name.toAsciiUpper()
                        if (upper.contains("PROXY") || upper.endsWith("_TOKEN") || upper.endsWith("_API_KEY") ||
                            upper.contains("SECRET") || upper.contains("PASSWORD") || upper.contains("CREDENTIAL") ||
                            upper.endsWith("_ACCESS_KEY_ID") || providerAliases.contains(upper)) { environment.remove(name) }
                    }
                    environment["METIS_HOME"] = home.toString()
                    environment["CURL_HOME"] = home.toString(); environment["XDG_CONFIG_HOME"] = home.toString()
                    environment["METIS_LOG_FILE"] = home.join("child.log").toString()
                    environment["METIS_THIN_OUTER"] = outer.toString(); environment["METIS_THIN_OUTER_NONCE"] = nonce
                    environment["METIS_THIN_ACTOR_BINARY"] = artifact[0].toString()
                    environment["METIS_THIN_TEST_HOME"] = home.toString()
                    environment["METIS_THIN_BOUND"] = (mode == "bound").toString()
                    environment["METIS_THIN_INPUT_CASE"] = caseName
                    environment["METIS_PROCESS_RECOVERY_DIRECTORY"] = ""; environment["METIS_PROCESS_RECOVERY_PARENT"] = ""
                    environment["METIS_STDIO_BROKER_NODE_COMMAND"] = node
                    environment["METIS_STDIO_BROKER_SCRIPT"] = canonicalize(Path("scripts/metis-stdio-broker.mjs")).toString()
                    let driver = outer.join(scheduleKey + "-driver-inventory")
                    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
                    let binding = "thin-driver-" + scheduleKey + nonce
                    let prior = ArrayList<(String, Option<String>)>()
                    for (key in ["METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT", "METIS_STDIO_BROKER_SCRIPT",
                        "METIS_STDIO_BROKER_NODE_COMMAND"]) { prior.add((key, getVariable(key))) }
                    var child = None<ManagedOwnedChild>; var reaped = false; var terminal = false; var childFormal = false
                    var launchPending = false
                    var bodyFailure = None<Exception>
                    try {
                        setVariable("METIS_STDIO_BROKER_SCRIPT", environment["METIS_STDIO_BROKER_SCRIPT"])
                        setVariable("METIS_STDIO_BROKER_NODE_COMMAND", node)
                        if (!managedRecoveryInitialize(driver, parent, binding)) { throw Exception("thin_driver_inventory_failed") }
                        try (input = File(home.join("stdin"), OpenMode.Read), output = File(home.join("stdout"), OpenMode.Write), error = File(home.join("stderr"), OpenMode.Write)) {
                            launchPending = true
                            child = Some(managedRecoveryLaunchOwned(getCommand(), ["--filter=" + filter, "--parallel=1",
                                "--no-progress", "--no-color", "--no-capture-output"], environment: Some<Map<String, String>>(environment),
                                stdIn: ProcessRedirect.FromFile(input), stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error)))
                            launchPending = false
                        }
                        let remaining = aggregateDeadline - MonoTime.now()
                        if (remaining <= Duration.Zero) { throw Exception("thin_input_aggregate_deadline") }
                        let code = child.getOrThrow().wait(timeout: Some(min(Duration.second * 60, remaining))); reaped = true
                        child.getOrThrow().closeStreams()
                        let proof = JsonValue.fromStr(mtimeThinText(home.join("formal-before-fallback.json"))).asObject()
                        let source = managedRecoveryProbeRecords(driver, parent, binding, MonoTime.now() + Duration.second * 3)
                        terminal = source.ok && source.terminal
                        childFormal = code == 0 && terminal && proof.get("formal").getOrThrow().asBool().getValue() &&
                            proof.get("terminal").getOrThrow().asBool().getValue() && proof.get("recorded").getOrThrow().asBool().getValue() &&
                            proof.get("case").getOrThrow().asString().getValue() == caseName &&
                            proof.get("nonce").getOrThrow().asString().getValue() == nonce &&
                            proof.get("bound").getOrThrow().asBool().getValue() == (mode == "bound") &&
                            proof.get("warmRounds").getOrThrow().asInt().getValue() == 2 &&
                            proof.get("formalRounds").getOrThrow().asInt().getValue() == 32 &&
                            proof.get("negativeRounds").getOrThrow().asInt().getValue() == (if (caseName == "darwin") { 0 } else { 0 })
                        if (childFormal) {
                            completedCases[scheduleKey] = proof.get("formalRounds").getOrThrow().asInt().getValue()
                            aggregateFormal += proof.get("formalRounds").getOrThrow().asInt().getValue()
                            aggregateWarm += proof.get("warmRounds").getOrThrow().asInt().getValue()
                            aggregateNegative += proof.get("negativeRounds").getOrThrow().asInt().getValue()
                        }
                        allCases = allCases && childFormal
                        @Expect(childFormal, true)
                        if (!childFormal) { throw Exception("thin_input_child_formal_failed") }
                    } catch (failure: Exception) { bodyFailure = Some(failure) }
                    finally {
                        try {
                            File.writeTo(home.join("parent-formal-before-fallback"),
                                "formal:${childFormal}\nreaped:${reaped}\nterminal:${terminal}\ncase:${caseName}\n".toArray())
                        } catch (failure: Exception) { if (bodyFailure.isNone()) { bodyFailure = Some(failure) } }
                        finally {
                            let cleanupDeadline = MonoTime.now() + Duration.second * 3
                            if (let Some(handle) <- child) {
                                try {
                                    if (handle.isAlive()) { handle.terminate(force: true) }
                                    let left = max(Duration.Zero, cleanupDeadline - MonoTime.now())
                                    let _ = handle.wait(timeout: Some(left)); reaped = true
                                } catch (failure: Exception) { if (bodyFailure.isNone()) { bodyFailure = Some(failure) } }
                                finally {
                                    try { handle.closeStreams() }
                                    catch (failure: Exception) { if (bodyFailure.isNone()) { bodyFailure = Some(failure) } }
                                }
                            }
                            try {
                                let stopped = managedRecoveryStopOwnedChildren((driver.toString(), parent), cleanupDeadline)
                                let source = managedRecoveryProbeRecords(driver, parent, binding, cleanupDeadline)
                                terminal = !launchPending && stopped && source.ok && source.terminal && reaped &&
                                    child.isSome() && child.getOrThrow().streamsAreClosed() && MonoTime.now() <= cleanupDeadline
                                if (terminal) {
                                    for ((key, value) in prior) {
                                        match (value) { case Some(text) => setVariable(key, text) case None => removeVariable(key) }
                                    }
                                } else {
                                    allCases = false
                                    if (bodyFailure.isNone()) { bodyFailure = Some(Exception("thin_driver_cleanup_pending")) }
                                }
                            } catch (failure: Exception) { allCases = false; if (bodyFailure.isNone()) { bodyFailure = Some(failure) } }
                        }
                    }
                    if (let Some(failure) <- bodyFailure) { throw failure }
                }
            }
            for (mode in ["absent", "bound"]) {
                for (selected in selections) {
                    if (completedCases.get(mode + "-" + mtimeThinKey(selected)) != Some<Int64>(32)) { throw Exception("thin_input_matrix_incomplete") }
                }
            }
            if (completedCases.size != 8 || aggregateFormal != 256 || aggregateWarm != 16 || aggregateNegative != 0 ||
                MonoTime.now() > aggregateDeadline) { throw Exception("thin_input_matrix_incomplete") }
            File.writeTo(outer.join("aggregate-formal.json"),
                ("{\"children\":${completedCases.size},\"formalRounds\":${aggregateFormal},\"warmRounds\":${aggregateWarm}," +
                    "\"negativeRounds\":${aggregateNegative},\"selectorRejections\":${selectorRejections},\"parentScheduleSeconds\":583}").toArray())

            formal = allCases
        } finally {
            if (formal && compilerReady) { remove(outer, recursive: true) }
            else { eprintln("thin_interface_failure_evidence_retained") }
        }
    }
}

@When[os == "macOS"]
private func mtimeThinMtimeManifest(script: String): ServicePluginManifest {
    let caps = ArrayList<ServiceCapabilityRecord>()
    caps.add(ServiceCapabilityRecord("gitcode.event.accepted", "event"))
    caps.add(ServiceCapabilityRecord("gitcode.writeback.apply_result", "controlAction"))
    ServicePluginManifest(schema: METIS_SERVICE_PLUGIN_SCHEMA, pluginId: "gitcode-monitor",
        displayName: "Owned Mtime Fixture", kind: "service", protocolVersion: "1.0",
        entryCommand: "/bin/sh", entryArgs: ["-c", script], hasConfigSchema: true, capabilityDeclarations: caps)
}


@When[os == "macOS"]
private func mtimeThinExpectedMtime(path: String): String {
    // Absolute test-only CLI is an independent oracle, never the PATH actor.
    try {
        let result = managedRecoveryExecuteWithOutput("/usr/bin/stat", ["-L", "-f", "%m", path])
        if (result[0] != 0) { throw Exception("thin_mtime_oracle_failed") }
        let seconds = Int64.parse(String.fromUtf8(result[1]).trimAscii())
        if (seconds < 0) { throw Exception("thin_mtime_oracle_failed") }
        seconds.toString()
    } catch (_: Exception) {
        throw Exception("thin_mtime_oracle_failed")
    }
}

@When[os == "macOS"]
@Test
public class ThinServicePluginMtimeResourceTest {
    @TestCase
    public func rWrapServicePluginMtimeUsesNativeMetadata(): Unit {
        mtimeThinRun("ThinServicePluginMtimeResourceTest.rWrapServicePluginMtimeUsesNativeMetadata", { fixture =>
            let previous = ArrayList<(String, Option<String>)>()
            for (key in ["METIS_LOG_LEVEL", "METIS_LOG_FILE", "METIS_CONSOLE_LEVEL"]) { previous.add((key, getVariable(key))) }
            resetServicePluginHostForTest()
            fixture.check(shutdownManagedStdioBroker().ok)
            let expectedMtime = mtimeThinExpectedMtime("/bin/sh")
            let coldFd = mtimeThinCount(1); let coldThreadBaseline = mtimeThinThreadSnapshot()
            // These former stat branches are now poison inputs: none may execute.
            let cases: Array<(String, Array<Byte>, Int64)> = [
                ("darwin", "1234567890\n".toArray(), 0),
                ("fallback", [], 0),
                ("failure", [], 7),
                ("invalid", [255u8, 254u8, 128u8, 0u8], 0)]
            var completed: Int64 = 0
            var warmFd: Int64 = 0; var warmThreadBaseline: (Int64, Int64, Int64) = (0, 0, 0)
            try {
                for (index in 0..cases.size + 1) {
                    if (index > 0 && cases[index - 1][0] != fixture.selectedCase) { continue }
                    let item = if (index == 0) { cases[0] } else { cases[index - 1] }
                    let rounds = if (index == 0) { 2 } else { 32 }
                    for (round in 0..rounds) {
                        fixture.begin("mtime-${index}-${round}", ["stat"])
                        fixture.route("stat", "main", item[1], [], item[2])
                        if (item[0] == "fallback") { setVariable("METIS_THIN_ACTOR_CASE", "mtime_darwin_failure") }
                        let log = fixture.roundDirectory.getOrThrow().join("service.log")
                        setVariable("METIS_LOG_LEVEL", "debug"); setVariable("METIS_LOG_FILE", log.toString())
                        setVariable("METIS_CONSOLE_LEVEL", "silent"); gatewayLoggingResetForTest()
                        let initialize = "{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"gitcode-monitor\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}"
                        let script = "printf '%s\\n' '${initialize}'; read ignored || true"
                        fixture.check(registerServicePlugin(ServicePluginRegistration(mtimeThinMtimeManifest(script),
                            configRef: ServicePluginConfigRef(secretRef: "fixture-only-secret", manifestPath: fixture.home.join("owned-plugin.json").toString()))).ok)
                        fixture.check(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok)
                        let identity = servicePluginActiveIdentityForTest("gitcode-monitor")
                        fixture.check(identity.isSome())
                        let text = mtimeThinText(log)
                        fixture.check(!text.contains(fixture.home.toString()) && !text.contains("fixture-only-secret"))
                        var pid: Int64 = 0; var records: Int64 = 0
                        for (line in text.split("\n")) {
                            if (line.trimAscii().isEmpty()) { continue }
                            let row = JsonValue.fromStr(line).asObject()
                            if (row.get("binaryMtime").isSome()) {
                                fixture.check(row.get("binaryMtime").getOrThrow().asString().getValue() == expectedMtime)
                                pid = Int64.parse(row.get("pid").getOrThrow().asString().getValue()); records += 1
                            }
                        }
                        fixture.check(records == 1 && pid > 1)
                        let birth = observeProcessBirthIdentity(pid); fixture.check(birth.isSome())
                        let still = servicePluginActiveIdentityForTest("gitcode-monitor"); fixture.check(still.isSome())
                        if (identity.isSome() && still.isSome()) {
                            let first = identity.getOrThrow(); let second = still.getOrThrow()
                            fixture.check(first[0] == second[0] && first[1] == second[1] && first[2] == second[2])
                        }
                        fixture.check(fixture.receipts().size == 0)
                        resetServicePluginHostForTest()
                        fixture.check(servicePluginActiveIdentityForTest("gitcode-monitor").isNone())
                        fixture.check(servicePluginCleanupPendingCountForTest() == 0)
                        fixture.check(managedStdioBroker().snapshot().ownerCount == 0)
                        if (let Some(value) <- birth) {
                            let gone = probeProcessBirthIdentity(value, MonoTime.now() + Duration.second * 2)
                            fixture.check(gone.conclusive && !gone.alive)
                        }
                        if (index > 0) {
                            let deadline = MonoTime.now() + Duration.second * 2
                            while (MonoTime.now() < deadline && (mtimeThinCount(1) != warmFd || !mtimeThinThreadsWithin(warmThreadBaseline))) { sleep(Duration.millisecond * 10) }
                            fixture.check(mtimeThinCount(1) == warmFd && mtimeThinThreadsWithin(warmThreadBaseline))
                            let currentThreads = mtimeThinThreadSnapshot()
                            println("R-MTIME-THREADS warmCjTasks=${warmThreadBaseline[0]};finalCjTasks=${currentThreads[0]};warmCjBlocking=${warmThreadBaseline[1]};finalCjBlocking=${currentThreads[1]};warmOsThreads=${warmThreadBaseline[2]};finalOsThreads=${currentThreads[2]}")
                            completed += 1; fixture.formalRounds += 1
                        } else { fixture.warmRounds += 1 }
                    }
                    if (index == 0) { warmFd = mtimeThinCount(1); warmThreadBaseline = mtimeThinThreadSnapshot() }
                }
                fixture.check(shutdownManagedStdioBroker().ok)
                fixture.stable(coldFd, coldThreadBaseline)
                fixture.check(completed == 32 && fixture.formalRounds == 32 && fixture.warmRounds == 2 &&
                fixture.negativeRounds == (if (fixture.selectedCase == "darwin") { 0 } else { 0 }))
                println("R-WRAP-MTIME case=${fixture.selectedCase};actualRounds=${completed};bound=${fixture.bound};sourceTerminal=${fixture.terminal()};formal=${!fixture.failed}")
                fixture.finish()
            } finally {
                resetServicePluginHostForTest()
                let closed = shutdownManagedStdioBroker().ok
                if (closed && fixture.terminal()) {
                    for ((key, value) in previous) {
                        match (value) { case Some(text) => setVariable(key, text) case None => removeVariable(key) }
                    }
                    gatewayLoggingResetForTest()
                } else { fixture.check(false) }
            }
        })
    }

    @TestCase
    public func nativeBinaryMtimeGuardsMissingAndUnicodePaths(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let home = Directory.createTemp("/private/tmp")
            try {
                let target = home.join("中文😀-binary")
                let link = home.join("链接😀")
                let broken = home.join("失效链接😀")
                File.writeTo(target, "owned fixture".toArray())
                let touched = managedRecoveryExecuteWithOutput("/usr/bin/touch", ["-t", "200001010000.00", target.toString()])
                @Expect(touched[0], 0)
                SymbolicLink.create(link, to: target)
                SymbolicLink.create(broken, to: home.join("missing"))
                let expected = mtimeThinExpectedMtime(target.toString())
                @Expect(Int64.parse(expected) < 1000000000, true)
                @Expect(servicePluginBinaryMtimeDiagnostic(target.toString()), expected)
                @Expect(servicePluginBinaryMtimeDiagnostic(link.toString()), expected)
                @Expect(servicePluginBinaryMtimeDiagnostic("  " + target.toString() + "  "), expected)
                for (path in ["", " \t\n", home.join("不存在😀").toString(), broken.toString(),
                    home.join(String(Array<Rune>(16384, repeat: r'中'))).toString()]) {
                    @Expect(servicePluginBinaryMtimeDiagnostic(path), "unavailable")
                }
            } finally {
                remove(home, recursive: true)
            }
        }
    }

}


// These tests execute the actual supervisor loop in isolated selfchildren.
// Gates pause real publication/probes; no task, owner, wait or terminal is faked.
@When[os == "macOS"]
private class SupervisorOwnedFixture {
    let home: Path
    let nonce: String
    let journal: Path
    let parent: String
    let gates = ArrayList<ServicePluginTestGate>()
    let workers = ArrayList<Future<Unit>>()
    var failed = false
    let priorAttach: Option<(String) -> Unit>
    let priorEnvironment = ArrayList<(String, Option<String>)>()
    init(home: Path, nonce: String) {
        this.home = home
        this.nonce = nonce
        this.journal = home.join("inventory")
        this.parent = currentProcessInstanceIdentity().getOrThrow().serialize()
        this.priorAttach = setServicePluginBeforeSupervisorAttachForTest(None)
        for (key in ["METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT",
            "METIS_PROCESS_RECOVERY_BROKER_KEY", "METIS_PROCESS_RECOVERY_OWNER_PID", "METIS_PROCESS_RECOVERY_OWNER_BIRTH"]) {
            priorEnvironment.add((key, getVariable(key)))
        }
        check(managedRecoveryInitialize(journal, parent, nonce))
        File.writeTo(home.join("child-identity.json"),
            ("{\"nonce\":\"${nonce}\",\"parent\":\"${parent}\"}").toArray())
        CliConfig.invalidatePathCache()
        resetServicePluginHostForTest()
    }
    func check(value: Bool): Unit {
        failed = failed || !value
        @Expect(value, true)
        if (!value) { throw Exception("supervisor_fixture_formal_failed") }
    }
    func gate(): ServicePluginTestGate {
        let result = ServicePluginTestGate(); gates.add(result); result
    }
    func state(serviceId!: String = "gitcode-monitor"): ServicePluginSupervisorOwnershipForTest {
        servicePluginSupervisorOwnershipForTest(serviceId)
    }
    func awaitState(predicate: (ServicePluginSupervisorOwnershipForTest) -> Bool): Unit {
        let deadline = MonoTime.now() + Duration.second * 2
        while (MonoTime.now() < deadline) {
            if (predicate(state())) { return }
            sleep(Duration.millisecond * 5)
        }
        check(predicate(state()))
    }
    func register(config: ServicePluginSupervisorConfig, serviceId!: String = "gitcode-monitor", reset!: Bool = true): Unit {
        if (reset) { resetServicePluginHostForTest() }
        var port: Int64 = 0
        try (socket = TcpServerSocket(bindAt: 0u16)) {
            socket.bind()
            port = Int64((socket.localAddress as IPSocketAddress).getOrThrow().port)
        }
        let running = "printf '{\"state\":\"running\",\"status\":\"running\",\"pluginId\":\"gitcode-monitor\",\"sessionId\":\"%s\",\"pid\":%s,\"parentPid\":%s,\"bindHost\":\"127.0.0.1\",\"port\":${port},\"startedAtMs\":1000,\"lastHeartbeatMs\":1000}\\n' \"$METIS_SERVICE_PLUGIN_SESSION_ID\" \"$$\" \"$METIS_SERVICE_PLUGIN_PARENT_PID\" > \"$METIS_SERVICE_PLUGIN_LEASE_PATH\""
        let stopped = running.replace("running", "stopped")
        let initFrame = "{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"gitcode-monitor\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}"
        // initialize must be consumed without terminating the fake service.
        let script = "${running}; printf '%s\\n' '${initFrame}'; metis_stop() { ${stopped}; }; trap 'metis_stop; exit 0' TERM HUP INT; while IFS= read -r line; do case \"$line\" in *'\"method\":\"stop\"'*|*'\"method\": \"stop\"'*) metis_stop; exit 0;; esac; done"
        let manifest = if (serviceId == "gitcode-monitor") { mtimeThinMtimeManifest(script) }
        else {
            let capabilities = ArrayList<ServiceCapabilityRecord>()
            capabilities.add(ServiceCapabilityRecord(serviceId + ".monitor.status", "controlAction"))
            ServicePluginManifest(schema: METIS_SERVICE_PLUGIN_SCHEMA, pluginId: serviceId,
                displayName: "Owned Supervisor Fixture", kind: "service", protocolVersion: "1.0",
                entryCommand: "/bin/sh", entryArgs: ["-c", script.replace("gitcode-monitor", serviceId)],
                hasConfigSchema: true, capabilityDeclarations: capabilities)
        }
        check(registerServicePlugin(ServicePluginRegistration(manifest)).ok)
        setServicePluginSupervisorConfigForTest(config)
        setServicePluginHealthzProbeForTest(Some({ _url: String, _timeout: Int64 =>
            ServicePluginHealthzProbeResult(true, statusCode: 200) }))
        setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeout: Int64 => (Int64(1), "", "") }))
    }
    func start(): Unit {
        check(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 2000).ok)
        awaitState({ value => value.owned == 1 && value.awaitingAttach == 0 })
    }
    func stop(): Unit {
        check(stopServicePlugin("gitcode-monitor", reason: "supervisor_owned_test", timeoutMillis: 2000).ok)
        check(state().owned == 0 && state().currentToken == 0)
    }
    func proof(name: String): Unit {
        let value = state()
        File.writeTo(home.join(name + ".json"),
            ("{\"nonce\":\"${nonce}\",\"owned\":${value.owned},\"token\":${value.currentToken}," +
             "\"awaitingAttach\":${value.awaitingAttach},\"bodyFinished\":${value.bodyFinished},\"failed\":${failed}}").toArray())
    }
    func beforeGateRelease(name: String, serviceIds!: Array<String> = ["gitcode-monitor"]): Unit {
        // Only this diagnostic work is caught. A body's original exception is
        // never caught/replaced here, and failure still lets every gate release.
        try {
            let proof = JsonObject()
            proof.put("nonce", JsonString(nonce))
            proof.put("failed", JsonBool(failed))
            let services = JsonObject()
            for (serviceId in serviceIds) {
                let observed = state(serviceId: serviceId)
                let row = JsonObject()
                row.put("token", JsonInt(observed.currentToken))
                row.put("owned", JsonInt(observed.owned))
                row.put("awaitingAttach", JsonInt(observed.awaitingAttach))
                row.put("bodyFinished", JsonInt(observed.bodyFinished))
                services.put(serviceId, row)
            }
            proof.put("services", services)
            File.writeTo(home.join("before-release-" + name + ".json"), proof.toJsonString().toArray())
        } catch (_: Exception) { failed = true }
    }
    func sourceTerminal(deadline: MonoTime): Bool {
        let proof = managedRecoveryProbeRecords(journal, parent, nonce, deadline)
        proof.ok && proof.terminal
    }
    func stable(fd: Int64, tasks: (Int64, Int64, Int64)): Unit {
        let deadline = MonoTime.now() + Duration.second * 2
        while (MonoTime.now() < deadline &&
            (mtimeThinCount(1) != fd || !mtimeThinThreadsWithin(tasks) || state().owned != 0)) {
            sleep(Duration.millisecond * 5)
        }
        check(mtimeThinCount(1) == fd)
        check(mtimeThinThreadsWithin(tasks))
        check(state().owned == 0)
        let brokerRemaining = (deadline - MonoTime.now()).toMilliseconds()
        check(brokerRemaining > 0)
        check(shutdownManagedStdioBroker(timeoutMs: brokerRemaining).ok)
        check(sourceTerminal(deadline))
    }
    func finish(): Bool {
        // Called only after the formal proof. A failed proof must not skip gates,
        // worker joins, process/source cleanup, or restoration.
        let deadline = MonoTime.now() + Duration.second * 3
        var terminal = true
        for (value in gates) { try { value.release() } catch (_: Exception) { terminal = false } }
        for (worker in workers) {
            let remaining = deadline - MonoTime.now()
            if (remaining <= Duration.Zero) { terminal = false; continue }
            try { worker.get(remaining) }
            catch (_: TimeoutException) { terminal = false }
            catch (_: Exception) { () }
        }
        let remaining = (deadline - MonoTime.now()).toMilliseconds()
        if (remaining <= 0) { terminal = false }
        else {
            try { terminal = shutdownServicePluginHost(timeoutMillis: remaining).ok && terminal }
            catch (_: Exception) { terminal = false }
        }
        let brokerRemaining = (deadline - MonoTime.now()).toMilliseconds()
        if (brokerRemaining <= 0) { terminal = false }
        else {
            try { terminal = shutdownManagedStdioBroker(timeoutMs: brokerRemaining).ok && terminal }
            catch (_: Exception) { terminal = false }
        }
        try { terminal = managedRecoveryStopOwnedChildren((journal.toString(), parent), deadline) && terminal }
        catch (_: Exception) { terminal = false }
        try { terminal = sourceTerminal(deadline) && terminal }
        catch (_: Exception) { terminal = false }
        let _ = setServicePluginBeforeSupervisorAttachForTest(priorAttach)
        if (terminal) {
            for ((key, prior) in priorEnvironment) {
                try { match (prior) { case Some(value) => setVariable(key, value) case None => removeVariable(key) } }
                catch (_: Exception) { terminal = false }
            }
        }
        terminal && MonoTime.now() <= deadline
    }
}

@When[os == "macOS"]
private func supervisorOwnedRun(method: String, body: (SupervisorOwnedFixture) -> Unit): Unit {
    if (let Some(childHome) <- getVariable("METIS_SUPERVISOR_OWNED_HOME")) {
        let home = canonicalize(Path(childHome))
        let nonce = getVariable("METIS_SUPERVISOR_OWNED_NONCE").getOrThrow()
        if (!home.toString().startsWith("/private/tmp/") || mtimeThinText(home.join("binding")) != nonce) {
            throw Exception("supervisor_fixture_binding_invalid")
        }
        let fixture = SupervisorOwnedFixture(home, nonce)
        var original = None<Exception>
        var formal = false
        var proofSaved = false
        try {
            for (_ in 0..2) {
                fixture.register(ServicePluginSupervisorConfig())
                fixture.start(); fixture.stop()
            }
            let fd = mtimeThinCount(1)
            let tasks = mtimeThinThreadSnapshot()
            body(fixture)
            fixture.stable(fd, tasks)
            formal = !fixture.failed
        } catch (failure: Exception) { original = Some(failure) }
        finally {
            try {
                File.writeTo(home.join("formal-before-fallback.json"),
                    ("{\"nonce\":\"${nonce}\",\"formal\":${formal},\"failed\":${fixture.failed},\"recorded\":true}").toArray())
                proofSaved = true
            } catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            finally {
                let terminal = fixture.finish()
                if ((!terminal || !proofSaved || !formal) && original.isNone()) {
                    original = Some(Exception("supervisor_fixture_cleanup_or_formal_pending"))
                }
            }
        }
        if (let Some(failure) <- original) { throw failure }
        return
    }
    synchronized(MetisProcessEnvironmentLock) {
        let home = Directory.createTemp("/private/tmp")
        let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
        File.writeTo(home.join("binding"), nonce.toArray())
        File.writeTo(home.join("metis.json"), "{}".toArray())
        print("R-SUPERVISOR fixture=${home.fileName};nonce=${nonce};case=${method}\n", flush: true)
        let environment = HashMap(getVariables())
        let aliases = ArrayList<String>()
        for (descriptor in cliModelProviderCatalogDescriptors()) {
            for (alias in descriptor.apiKeyEnvAliases) { aliases.add(alias.toAsciiUpper()) }
        }
        for (key in environment.keys().toArray()) {
            let upper = key.toAsciiUpper()
            if (upper.contains("PROXY") || upper.endsWith("_TOKEN") || upper.endsWith("_API_KEY") ||
                upper.contains("SECRET") || upper.contains("PASSWORD") || upper.contains("CREDENTIAL") ||
                upper.endsWith("_ACCESS_KEY_ID") || aliases.contains(upper) || upper.startsWith("METIS_PROCESS_RECOVERY_")) {
                environment.remove(key)
            }
        }
        environment["METIS_HOME"] = home.toString()
        environment["HOME"] = home.toString(); environment["TMPDIR"] = home.toString()
        environment["CURL_HOME"] = home.toString(); environment["XDG_CONFIG_HOME"] = home.toString()
        environment["METIS_SUPERVISOR_OWNED_HOME"] = home.toString()
        environment["METIS_SUPERVISOR_OWNED_NONCE"] = nonce
        environment["METIS_LOG_FILE"] = home.join("child.log").toString()
        environment["METIS_STDIO_BROKER_NODE_COMMAND"] = managedStdioResolveNodeCommand()
        environment["METIS_STDIO_BROKER_SCRIPT"] = canonicalize(Path("scripts/metis-stdio-broker.mjs")).toString()
        var child = None<ManagedOwnedChild>
        var pendingLaunch = false
        var childBirth = None<ProcessBirthIdentity>
        var reaped = false
        var formal = false
        var terminal = false
        var original = None<Exception>
        try {
            try (output = File(home.join("stdout"), OpenMode.Write), error = File(home.join("stderr"), OpenMode.Write)) {
                pendingLaunch = true
                child = Some(launchManagedRawChild(getCommand(),
                    ["--filter=ServicePluginSupervisorOwnershipTest." + method, "--parallel=false", "--no-progress",
                     "--no-color", "--no-capture-output"],
                    newGeneration: true, environment: Some<Map<String, String>>(environment),
                    stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error)))
                pendingLaunch = false
            }
            let handle = child.getOrThrow()
            childBirth = observeProcessBirthIdentity(handle.pid)
            if (childBirth.isNone()) { throw Exception("supervisor_driver_birth_unknown") }
            let code = handle.wait(timeout: Some(Duration.second * 60)); reaped = true
            handle.closeStreams()
            let proof = JsonValue.fromStr(mtimeThinText(home.join("formal-before-fallback.json"))).asObject()
            formal = code == 0 && proof.get("nonce").getOrThrow().asString().getValue() == nonce &&
                proof.get("formal").getOrThrow().asBool().getValue() && proof.get("recorded").getOrThrow().asBool().getValue()
            if (!formal) { throw Exception("supervisor_child_formal_failed") }
        } catch (failure: Exception) { original = Some(failure) }
        finally {
            try { File.writeTo(home.join("parent-formal-before-fallback"),
                "formal:${formal}\nreaped:${reaped}\nlaunchPending:${pendingLaunch}\n".toArray()) }
            catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            finally {
                let deadline = MonoTime.now() + Duration.second * 3
                if (let Some(handle) <- child) {
                    try {
                        if (handle.isAlive()) { handle.terminate(force: true) }
                        let remaining = deadline - MonoTime.now()
                        if (remaining <= Duration.Zero) { throw Exception("supervisor_parent_cleanup_deadline") }
                        let _ = handle.wait(timeout: Some(remaining)); reaped = true
                    } catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
                    finally {
                        try { handle.closeStreams() }
                        catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
                    }
                    try {
                        let identity = JsonValue.fromStr(mtimeThinText(home.join("child-identity.json"))).asObject()
                        let originalParent = identity.get("parent").getOrThrow().asString().getValue()
                        let parsed = parseProcessInstanceIdentity(originalParent).getOrThrow()
                        let birth = childBirth.getOrThrow()
                        let bound = identity.get("nonce").getOrThrow().asString().getValue() == nonce &&
                            parsed.pid == handle.pid && birth.pid == handle.pid &&
                            parsed.value8 == birth.seconds && parsed.value9 == birth.microseconds
                        let source = managedRecoveryProbeRecords(home.join("inventory"), originalParent, nonce, deadline)
                        terminal = !pendingLaunch && bound && source.ok && source.terminal && reaped &&
                            !handle.isAlive() && handle.streamsAreClosed() && MonoTime.now() <= deadline
                    } catch (failure: Exception) {
                        terminal = false
                        if (original.isNone()) { original = Some(failure) }
                    }
                }
                if (!terminal && original.isNone()) { original = Some(Exception("supervisor_parent_cleanup_pending")) }
            }
        }
        @Expect(formal && terminal && original.isNone(), true)
        if (formal && terminal && original.isNone()) { remove(home, recursive: true) }
        if (let Some(failure) <- original) { throw failure }
    }
}

@When[os == "macOS"]
@Test
public class ServicePluginSupervisorOwnershipTest {
    @TestCase
    public func supervisorLongIntervalStopReallyJoins(): Unit {
        supervisorOwnedRun("supervisorLongIntervalStopReallyJoins", { fixture =>
            fixture.register(ServicePluginSupervisorConfig())
            fixture.start()
            fixture.awaitState({ value => value.waiting == 1 })
            fixture.stop()
        })
    }

    @TestCase
    public func supervisorStopBeforeFutureAttachRetainsPending(): Unit {
        supervisorOwnedRun("supervisorStopBeforeFutureAttachRetainsPending", { fixture =>
            fixture.register(ServicePluginSupervisorConfig())
            let gate = fixture.gate()
            let prior = setServicePluginBeforeSupervisorAttachForTest(Some({ _sid: String => gate.enterAndWait() }))
            try {
                fixture.workers.add(spawn { let _ = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 2000) })
                fixture.check(gate.awaitEntered(2000))
                fixture.check(fixture.state().awaitingAttach == 1)
                let first = stopServicePlugin("gitcode-monitor", timeoutMillis: 200)
                fixture.check(!first.ok && first.status == "cleanup_pending")
                fixture.check(fixture.state().owned == 1 && fixture.state().awaitingAttach == 1)
                fixture.proof("attach-pending")
            } finally {
                fixture.beforeGateRelease("attach-final")
                gate.release(); let _ = setServicePluginBeforeSupervisorAttachForTest(prior)
            }
            fixture.workers[0].get(Duration.second * 2)
            fixture.stop()
        })
    }

    private func recoverThree(fixture: SupervisorOwnedFixture, attachBarrier: Bool): Unit {
        fixture.register(ServicePluginSupervisorConfig(intervalMs: 200, healthTimeoutMs: 2000,
            failureThreshold: 1, restartCooldownMs: 0))
        fixture.start()
        for (round in 0..3) {
            let old = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
            let oldToken = fixture.state().currentToken
            let successorToken = Array<Int64>(1, repeat: 0)
            let gate = fixture.gate()
            let prior = setServicePluginBeforeSupervisorAttachForTest(
                if (attachBarrier) { Some({ _sid: String => gate.enterAndWait() }) } else { None<(String) -> Unit> })
            try {
                let oldBirth = observeProcessBirthIdentity(old.pid).getOrThrow()
                fixture.check(observeProcessBirthIdentity(old.pid)?.serialize() == Some(oldBirth.serialize()))
                let killed = managedRecoveryExecuteWithOutput("/bin/kill", ["-KILL", old.pid.toString()])
                fixture.check(killed[0] == 0)
                if (attachBarrier) {
                    fixture.check(gate.awaitEntered(2000))
                    let handoff = fixture.state()
                    fixture.check(handoff.owned == 2 && handoff.currentToken > 0 &&
                        handoff.currentToken != oldToken && handoff.awaitingAttach == 1)
                    successorToken[0] = handoff.currentToken
                    fixture.proof("handoff-${round}")
                    fixture.beforeGateRelease("handoff-open-${round}")
                    gate.release()
                }
                fixture.awaitState({ value => value.owned == 1 && value.awaitingAttach == 0 && value.currentToken > 0 &&
                    value.currentToken != oldToken && (!attachBarrier || value.currentToken == successorToken[0]) })
                let next = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                fixture.check(next.pid > 0 && next.pid != old.pid && next.instanceId != old.instanceId)
                fixture.check(next.supervisorRestartCount == round + 1)
                fixture.check(fixture.state().currentToken > 0 && fixture.state().currentToken != oldToken)
                if (attachBarrier) { fixture.check(fixture.state().currentToken == successorToken[0]) }
                fixture.proof("recovered-${round}")
            } finally {
                fixture.beforeGateRelease("handoff-final-${round}")
                gate.release(); let _ = setServicePluginBeforeSupervisorAttachForTest(prior)
            }
        }
        fixture.stop()
    }

    @TestCase
    public func supervisorOldCompletionNeverRemovesSuccessor(): Unit {
        supervisorOwnedRun("supervisorOldCompletionNeverRemovesSuccessor", { fixture => recoverThree(fixture, true) })
    }

    @TestCase
    public func supervisorSlowTickStaysOwnedUntilRetry(): Unit {
        supervisorOwnedRun("supervisorSlowTickStaysOwnedUntilRetry", { fixture =>
            fixture.register(ServicePluginSupervisorConfig(intervalMs: 200))
            let gate = fixture.gate()
            let calls = ServicePluginTestCounter()
            setServicePluginHealthzProbeForTest(Some({ _url: String, _timeout: Int64 =>
                calls.increment(); gate.enterAndWait(); ServicePluginHealthzProbeResult(true, statusCode: 200) }))
            fixture.start()
            try {
                fixture.check(gate.awaitEntered(2000))
                let stopped = stopServicePlugin("gitcode-monitor", timeoutMillis: 200)
                fixture.check(!stopped.ok && stopped.status == "cleanup_pending" && fixture.state().owned == 1)
                let before = calls.get()
                let manual = runServicePluginSupervisorTickForTest("gitcode-monitor")
                fixture.check(!manual.ok && manual.status == "cleanup_pending" && calls.get() == before)
                fixture.proof("slow-tick-pending")
            } finally {
                fixture.beforeGateRelease("slow-tick-final")
                gate.release()
            }
            fixture.stop()
        })
    }

    @TestCase
    public func supervisorSelfRecoveryNeverJoinsItsOwnFuture(): Unit {
        supervisorOwnedRun("supervisorSelfRecoveryNeverJoinsItsOwnFuture", { fixture => recoverThree(fixture, false) })
    }

    @TestCase
    public func hostShutdownAndResetRetainUnfinishedSupervisor(): Unit {
        supervisorOwnedRun("hostShutdownAndResetRetainUnfinishedSupervisor", { fixture =>
            for (slow in [false, true]) {
                let firstId = "sup-attach-a"
                let secondId = "sup-attach-b"
                if (slow) { fixture.register(ServicePluginSupervisorConfig(intervalMs: 200)) }
                else {
                    fixture.register(ServicePluginSupervisorConfig(), serviceId: firstId)
                    fixture.register(ServicePluginSupervisorConfig(), serviceId: secondId, reset: false)
                }
                let gate = fixture.gate()
                let secondGate = fixture.gate()
                let prior = setServicePluginBeforeSupervisorAttachForTest(
                    if (!slow) {
                        Some({ sid: String =>
                            if (sid == firstId) { gate.enterAndWait() }
                            else if (sid == secondId) { secondGate.enterAndWait() }
                            else { throw Exception("supervisor_attach_service_unexpected") }
                        })
                    } else { None<(String) -> Unit> })
                try {
                    if (slow) {
                        setServicePluginHealthzProbeForTest(Some({ _url: String, _timeout: Int64 =>
                            gate.enterAndWait(); ServicePluginHealthzProbeResult(true, statusCode: 200) }))
                        fixture.start()
                    } else {
                        fixture.workers.add(spawn { let _ = startServicePlugin(firstId) })
                        fixture.workers.add(spawn { let _ = startServicePlugin(secondId) })
                    }
                    fixture.check(gate.awaitEntered(2000))
                    if (!slow) {
                        fixture.check(secondGate.awaitEntered(2000))
                        fixture.check(servicePluginSupervisorWorkerCountForTest() == 2)
                    }
                    let stopped = shutdownServicePluginHost(timeoutMillis: 200)
                    fixture.check(!stopped.ok && stopped.status == "cleanup_pending")
                    if (!slow) {
                        fixture.check(fixture.state(serviceId: firstId).owned == 1 &&
                            fixture.state(serviceId: secondId).owned == 1 && servicePluginSupervisorWorkerCountForTest() == 2)
                        fixture.check(servicePluginActiveIdentityForTest(firstId).isNone() &&
                            servicePluginActiveIdentityForTest(secondId).isNone() && servicePluginCleanupPendingCountForTest() == 0)
                        let firstRecord = getServicePluginSnapshot(firstId).getOrThrow()
                        let secondRecord = getServicePluginSnapshot(secondId).getOrThrow()
                        fixture.check(firstRecord.pid == 0 && secondRecord.pid == 0 &&
                            firstRecord.status == "stopped" && secondRecord.status == "stopped")
                    }
                    let resetStarted = MonoTime.now()
                    var pending = false
                    try { resetServicePluginHostForTest() }
                    catch (failure: Exception) { pending = failure.message == "service_plugin_test_reset_supervisor_cleanup_pending" }
                    let resetElapsed = MonoTime.now() - resetStarted
                    if (slow) {
                        fixture.check(pending && fixture.state().owned > 0)
                        fixture.proof("reset-slow-pending")
                    } else {
                        let first = fixture.state(serviceId: firstId)
                        let second = fixture.state(serviceId: secondId)
                        fixture.check(pending && servicePluginSupervisorWorkerCountForTest() == 2)
                        fixture.check(first.owned == 1 && second.owned == 1 &&
                            first.awaitingAttach == 1 && second.awaitingAttach == 1)
                        fixture.check(first.currentToken > 0 && second.currentToken > 0 &&
                            first.currentToken != second.currentToken)
                        // Auxiliary discriminator only: the production phase remains
                        // one shared1000ms; this includes scheduler/metadata overhead.
                        fixture.check(resetElapsed < Duration.second * 2)
                        File.writeTo(fixture.home.join("reset-two-attach-pending.json"),
                            ("{\"nonce\":\"${fixture.nonce}\",\"resetElapsedMs\":${resetElapsed.toMilliseconds()}," +
                             "\"firstToken\":${first.currentToken},\"secondToken\":${second.currentToken}," +
                             "\"firstOwned\":${first.owned},\"secondOwned\":${second.owned}," +
                             "\"firstAwaitingAttach\":${first.awaitingAttach},\"secondAwaitingAttach\":${second.awaitingAttach}}").toArray())
                    }
                } finally {
                    fixture.beforeGateRelease(if (slow) { "reset-slow-final" } else { "reset-two-attach-final" },
                        serviceIds: if (slow) { ["gitcode-monitor"] } else { [firstId, secondId] })
                    gate.release(); secondGate.release()
                    let _ = setServicePluginBeforeSupervisorAttachForTest(prior)
                }
                for (worker in fixture.workers) { worker.get(Duration.second * 2) }
                if (slow) { fixture.stop() }
                resetServicePluginHostForTest()
                fixture.check(fixture.state().owned == 0 && servicePluginSupervisorWorkerCountForTest() == 0)
                if (!slow) {
                    fixture.check(fixture.state(serviceId: firstId).owned == 0 && fixture.state(serviceId: secondId).owned == 0)
                }
            }
        })
    }
}
