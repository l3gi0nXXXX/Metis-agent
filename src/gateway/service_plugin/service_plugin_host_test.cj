package metis.gateway.service_plugin

import metis.gateway.logging.gatewayLoggingResetForTest
import metis.process.{ManagedStdioOwnerSpec, managedStdioBroker, managedStdioResolveBrokerScriptPath, resetManagedStdioBrokerForTest}
import std.collection.*
import std.convert.Parsable
import std.env.{getProcessId, getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.process.*
import std.sync.*
import std.time.*
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString}

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
    private func withIsolatedServicePluginHostTestHome<T>(label: String, block: (Path) -> T): T {
        resetServicePluginHostForTest()
        @Expect(resetManagedStdioBrokerForTest(timeoutMs: 2000).ok, true)
        withServicePluginHostTestHome(label, { home: Path =>
            try {
                block(home)
            } finally {
                resetServicePluginHostForTest()
                @Expect(resetManagedStdioBrokerForTest(timeoutMs: 2000).ok, true)
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
        if (retryLastOnQueueFull) { script += "; retry_pending=0" }
        script += "; while IFS= read -r request; do case \"$request\" in *emitCapabilityEvent*) printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_MARKER_PATH\""
        if (retryLastOnQueueFull && eventIds.size > 0) {
            let last = eventIds[eventIds.size - 1]
            script += "; case \"$request\" in *queue_full*) if [ \"$retry_pending\" = \"0\" ]; then retry_pending=1; fi;; *completed*) if [ \"$retry_pending\" = \"1\" ]; then printf '%s\\n' '${this.gitCodeAcceptedEventLine(eventId: last, frameId: "s1c-retry", deliveryId: "delivery-${eventIds.size}", attemptToken: "attempt-${eventIds.size}-2")}'; retry_pending=0; fi;; esac"
        }
        script += ";; *gitcode.writeback.apply_result*) printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH\"; corr=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"correlationId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'); printf '%s\\n' '${responseLine}';; *\\\"method\\\":\\\"stop\\\"*) break;; esac; done"
        script
    }

    private func gitCodeFirstLaunchAckBurstScript(eventIds: Array<String>, launchMarker: Path): String {
        var script = "printf '%s\\n' '${this.gitCodeInitLine()}'; launch_count=$(cat '${launchMarker.toString()}' 2>/dev/null || printf 0); launch_count=$((launch_count + 1)); printf '%s' \"$launch_count\" > '${launchMarker.toString()}'; if [ \"$launch_count\" = \"1\" ]; then"
        var sequence: Int64 = 0
        for (eventId in eventIds) {
            sequence++
            script += "; printf '%s\\n' '${this.gitCodeAcceptedEventLine(eventId: eventId, frameId: "s2-old-event-${sequence}", deliveryId: "s2-old-delivery-${sequence}", attemptToken: "s2-old-attempt-${sequence}")}'"
        }
        let responseLine = this.gitCodeWritebackResponseLine(correlationId: "__METIS_CORRELATION__").replace("__METIS_CORRELATION__", "'\"$corr\"'")
        script += "; fi; while IFS= read -r request; do case \"$request\" in *emitCapabilityEvent*) printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_MARKER_PATH\";; *gitcode.writeback.apply_result*) printf '%s\\n' \"$request\" >> \"$METIS_STDIO_FIXTURE_WRITEBACK_MARKER_PATH\"; corr=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"correlationId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'); printf '%s\\n' '${responseLine}';; *\\\"method\\\":\\\"stop\\\"*) break;; esac; done"
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
            if (!decoded.ok || decoded.frame.frameType != "response" || decoded.frame.method != "emitCapabilityEvent" ||
                decoded.frame.capabilityId != "gitcode.event.accepted") { invalid++; continue }
            let parsed = parseServiceEventAckPayload(decoded.frame.payload)
            if (!parsed.ok || parsed.ack.attemptToken != decoded.frame.correlationId) { invalid++; continue }
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
        "printf '%s\n' '${initLine}'; printf '%s\n' '${eventLine}'; trap '' TERM HUP; while true; do sleep 1; done"
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
        firstLaunchNoise!: Bool = false
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
        let capturePath = Path("/private/tmp/metis-service-plugin-env-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.txt")
        let initLine = "{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"stdio-service\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}"
        let script = "printf '%s\\n' \"$METIS_SERVICE_PLUGIN_SESSION_ID|$METIS_SERVICE_PLUGIN_LEASE_PATH|$METIS_SERVICE_PLUGIN_PARENT_PID\" > '${capturePath.toString()}'; printf '%s\\n' '${initLine}'; read ignored || true"
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
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(started.status, "running")
                @Expect(this.waitForFile(launchMarker, timeoutMillis: 1000), true)
            } finally {
                let _ = stopServicePlugin("gitcode-monitor", reason: "test", timeoutMillis: 1000)
                resetServicePluginHostForTest()
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
            this.registerGitCodeStdioScript(this.gitCodeCountingLeaseScript(counterPath, 18185, keepAlive: false))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForSnapshotReason("gitcode-monitor", "process_exited", timeoutMillis: 1500), true)

                let restarted = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(restarted.ok, true)
                @Expect(this.readCounterFile(counterPath), 2)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "running")
                        @Expect(snapshot.pid > 0, true)
                    case None => @Expect(true, false)
                }
            } finally {
                resetServicePluginHostForTest()
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
        // T4-U2.
        withIsolatedServicePluginHostTestHome("service-plugin-t4-event-pump-dead", { _home: Path =>
            this.registerGitCodeStdioScript(this.gitCodeLeaseScript(18189, keepAlive: false))
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForSnapshotReason("gitcode-monitor", "process_exited", timeoutMillis: 1500), true)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "degraded")
                        @Expect(snapshot.degradedReason, "process_exited")
                    case None => @Expect(true, false)
                }
            } finally {
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
            this.registerGitCodeStdioScript(this.gitCodeLeaseScript(18184, stopUpdatesLease: false))
            setServicePluginSupervisorConfigForTest(ServicePluginSupervisorConfig(enabled: true, intervalMs: 1000, healthTimeoutMs: 10, failureThreshold: 1, restartCooldownMs: 1000))
            setServicePluginHealthzProbeForTest(Some({ _url: String, _timeoutMs: Int64 =>
                ServicePluginHealthzProbeResult(false, statusCode: 0, durationMs: 10, diagnostic: "healthz_timeout")
            }))
            setServicePluginPortOwnerProbeForTest(Some({ _port: Int64, _pid: Int64 => true }))
            setServicePluginSupervisorAutoStartForTest(false)
            try {
                let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(started.ok, true)
                @Expect(this.waitForGitCodeLease(home), true)
                let firstPid = match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) => snapshot.pid
                    case None => 0
                }
                let tick = runServicePluginSupervisorTickForTest("gitcode-monitor", nowMs: 2000)
                @Expect(tick.classification.shouldRecover, true)
                @Expect(tick.recovered, false)
                @Expect(tick.diagnostic.contains("port_release_timeout"), true)
                @Expect(tick.diagnostic.contains("portOwnerAlive=true"), true)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.pid, firstPid)
                        @Expect(snapshot.supervisorRestartCount, 0)
                        @Expect(snapshot.status, "degraded")
                        @Expect(snapshot.degradedReason, "healthz_timeout")
                    case None => @Expect(true, false)
                }
            } finally {
                setServicePluginSupervisorAutoStartForTest(true)
                setServicePluginHealthzProbeForTest(None)
                setServicePluginPortOwnerProbeForTest(None)
                resetServicePluginHostForTest()
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
                @Expect(servicePluginCleanupPendingCountForTest(), 0)
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
                @Expect(servicePluginCleanupPendingCountForTest(), 1)

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
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                @Expect(servicePluginDispatchCountsForTest("gitcode-monitor").isNone(), true)
                activeGate = None<ServicePluginTestGate>
            } finally {
                match (activeGate) { case Some(gate) => gate.release() case None => () }
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
                probe.release(1)
                @Expect(probe.awaitEntered(3, 3000), true)
                @Expect(this.waitForAckMarkerCount(ackMarker, "admission", "accepted", 1, attemptToken: "attempt-131-2"), true)
                @Expect(this.ackMarkerCounts(ackMarker, "admission", "accepted")[1], 0)
                let retried = servicePluginDispatchSchedulerSnapshotForTest("gitcode-monitor").getOrThrow()
                @Expect(retried.active <= 2, true); @Expect(retried.queued <= 128, true); @Expect(retried.futures <= 2, true)
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
                let retried = stopServicePlugin("gitcode-monitor", reason: "s2-n1-cleanup-retry", timeoutMillis: 3000)
                @Expect(retried.ok, true)
                @Expect(retried.status, "stopped")
                @Expect(retried.dispatchStatus, "drained")
                @Expect(servicePluginCleanupPendingCountForTest(), 0)

                let replacement = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000)
                @Expect(replacement.ok, true)
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
                    setServicePluginDispatchRemainingForTest(Some({ => remaining }))
                    if (remaining == 101) {
                        setServicePluginBeforeDispatchWaitForTest(Some({ waitMs: Int64 =>
                            @Expect(waitMs, 1)
                            dispatchGate.release()
                            @Expect(settledGate.awaitEntered(1000), true)
                        }))
                    }
                    let stopped = stopServicePlugin("gitcode-monitor", reason: "边界中文🙂", timeoutMillis: 200)
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
                setServicePluginBeforeDispatchWaitForTest(Some({ _waitMs: Int64 =>
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
                setServicePluginBeforeDispatchWaitForTest(None<(Int64) -> Unit>)
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
                setServicePluginBeforeDispatchWaitForTest(None<(Int64) -> Unit>)
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
            try {
                let malformed = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
                @Expect(malformed.ok, false)
                @Expect(malformed.status, "frame_decode_failed")
            } finally {
                let cleanup = this.settleServiceOwnerCleanup("stdio-service")
                @Expect(if (cleanup[0]) { cleanup[1] == "stopped" } else { cleanup[1] == "not_needed" }, true)
                @Expect(cleanup[2], true)
                @Expect(cleanup[3], true)
                resetServicePluginHostForTest()
            }

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

    @TestCase
    public func p3N1CleanupDeadlineAndHostShutdownGateAreBounded(): Unit {
        withIsolatedServicePluginHostTestHome("p3-n1-cleanup-shutdown-gate", { home: Path =>
            let marker = home.join("dispatch.marker")
            let release = home.join("dispatch.release")
            let cancelled = home.join("claim.cancelled")
            let deliveryLock = Mutex()
            let deliveries = ArrayList<String>()
            let dispatchSettledGate = ServicePluginTestGate()
            var starter = None<Future<ServiceStartResult>>
            var shutdown = None<Future<ServicePluginHostShutdownResult>>
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
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 1000).ok, true)
                let explicitPid = match (getServicePluginSnapshot("gitcode-monitor")) { case Some(snapshot) => snapshot.pid case None => Int64(0) }
                let explicitPgid = this.processGroupId(explicitPid)
                @Expect(explicitPgid > 0, true)
                @Expect(this.waitForFile(marker, timeoutMillis: 3000), true)
                let explicitStop = stopServicePlugin("gitcode-monitor", reason: "p3-n1-explicit-cleanup", timeoutMillis: 1)
                @Expect(explicitStop.ok, false)
                @Expect(explicitStop.status, "cleanup_pending")
                @Expect(explicitStop.diagnostic.contains("dispatch_status=dispatch_pending"), true)
                @Expect(servicePluginCleanupPendingCountForTest(), 1)
                @Expect(managedStdioBroker().snapshot().ownerCount, 1)
                let (initialPendingPidExit, _, _) = executeWithOutput("kill", ["-0", "${explicitPid}"])
                @Expect(initialPendingPidExit, 0)
                @Expect(ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 500).status, "cleanup_pending")
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
                setServicePluginBeforeEventDispatchHookForTest(None<(String) -> Unit>)
                setServicePluginDispatchSettledHookForTest(None<() -> Unit>)
                setServicePluginBeforeSupervisorRegisterHookForTest(None<(String) -> Unit>)
                setServicePluginStartPhaseHookForTest(None<(String, String) -> Unit>)
                setServicePluginWebhookSubscribersProviderForTest(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                setServicePluginWebhookGeneratedReplyHandlerForTest(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
                setServicePluginEventDeliveryForTest(None)
                match (starter) { case Some(future) => try { let _ = future.get(Duration.second * 3) } catch (_: Exception) { try { future.cancel() } catch (_: Exception) { () } } case None => () }
                match (shutdown) { case Some(future) => try { let _ = future.get(Duration.second * 3) } catch (_: Exception) { try { future.cancel() } catch (_: Exception) { () } } case None => () }
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
