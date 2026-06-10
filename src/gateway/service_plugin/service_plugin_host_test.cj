package metis.gateway.service_plugin

import std.collection.ArrayList
import std.convert.Parsable
import std.env.getProcessId
import std.fs.{Directory, File, Path, exists, remove}
import std.sync.Mutex
import std.time.*
import std.unittest.testmacro.*

@Test
public class ServicePluginHostTest {
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
        var script = "printf '%s\\n' '${initLine}'; read ignored"
        for (line in invokeLines) {
            script += "; printf '%s\\n' '${line}'"
        }
        script += "; read ignored || true"
        script
    }

    private func stdioInvokeResponseLine(payload: String, serviceId!: String = "stdio-service", capabilityId!: String = "stdio.monitor.status", correlationId!: String = "corr-stdio-service-1-stdio.monitor.status"): String {
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

    private func gitCodeAcceptedEventLine(eventId!: String = "gitcode:Cangjie/community:issue:3", frameId!: String = "event-accepted-1"): String {
        "{\"type\":\"event\",\"frameId\":\"${frameId}\",\"serviceId\":\"gitcode-monitor\",\"method\":\"emitCapabilityEvent\",\"capabilityId\":\"gitcode.event.accepted\",\"payload\":{\"jobId\":\"webhook-${eventId}\",\"eventId\":\"${eventId}\",\"repo\":\"Cangjie/community\",\"kind\":\"issue\",\"number\":\"3\",\"title\":\"Issue 3\",\"url\":\"https://gitcode.com/Cangjie/community/issues/3\",\"author\":\"external-user\",\"content\":\"please review\"}}"
    }

    private func gitCodeWritebackResponseLine(
        frameId!: String = "writeback-response-1",
        correlationId!: String = "corr-gitcode-monitor-1-gitcode.writeback.apply_result",
        replyUrl!: String = "https://gitcode.com/Cangjie/community/issues/3#note_1"
    ): String {
        "{\"type\":\"response\",\"frameId\":\"${frameId}\",\"serviceId\":\"gitcode-monitor\",\"method\":\"invokeCapability\",\"capabilityId\":\"gitcode.writeback.apply_result\",\"correlationId\":\"${correlationId}\",\"payload\":{\"ok\":true,\"status\":\"posted\",\"posted\":true,\"replyUrl\":\"${replyUrl}\"}}"
    }

    private func gitCodeHeartbeatLine(frameId!: String = "heartbeat-1"): String {
        "{\"type\":\"heartbeat\",\"frameId\":\"${frameId}\",\"serviceId\":\"gitcode-monitor\",\"method\":\"heartbeat\",\"payload\":{\"ok\":true,\"status\":\"alive\"}}"
    }

    private func gitCodeReentrantWritebackScript(includeUnrelatedFrames!: Bool = false): String {
        let initLine = this.gitCodeInitLine()
        let eventLine = this.gitCodeAcceptedEventLine()
        let heartbeatLine = this.gitCodeHeartbeatLine()
        let unrelatedResponse = this.gitCodeWritebackResponseLine(frameId: "unrelated-response", correlationId: "corr-unrelated")
        let responseLine = this.gitCodeWritebackResponseLine()
        var script = "printf '%s\\n' '${initLine}'; printf '%s\\n' '${eventLine}'; read request"
        if (includeUnrelatedFrames) {
            script += "; printf '%s\\n' '${heartbeatLine}'; printf '%s\\n' '${unrelatedResponse}'"
        }
        script += "; printf '%s\\n' '${responseLine}'; read ignored || true"
        script
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
        withServicePluginHostTestHome("service-plugin-p5-gcm-env", { _home: Path =>
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
        withServicePluginHostTestHome("service-plugin-p4-stale-running-lease", { home: Path =>
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
        withServicePluginHostTestHome("service-plugin-orphan-live-lease", { home: Path =>
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
        withServicePluginHostTestHome("service-plugin-orphan-missing-pid", { home: Path =>
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
        withServicePluginHostTestHome("service-plugin-p4-stopped-old-lease", { home: Path =>
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
        withServicePluginHostTestHome("service-plugin-p4-graceful-stop", { _home: Path =>
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
        withServicePluginHostTestHome("service-plugin-p4-forced-stop-lease", { _home: Path =>
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
                @Expect(stopped.status, "degraded")
                @Expect(stopped.diagnostic.contains("lease_not_stopped_after_stop"), true)
                @Expect(stopped.diagnostic.contains("state=running"), true)
                @Expect(stopped.diagnostic.contains("pidAlive="), true)
                @Expect(stopped.diagnostic.contains("port=18080"), true)
                @Expect(stopped.diagnostic.contains("parentPid="), true)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "degraded")
                        @Expect(snapshot.degradedReason, "lease_not_stopped_after_stop")
                        @Expect(renderServicePluginDiagnostics(snapshot).contains("parentPid="), true)
                    case None => @Expect(true, false)
                }
            } finally {
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
        this.registerStdioScript(this.stdioScriptWithInvokeLines(initLine, [wrongService]))
        try {
            let result = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(result.ok, false)
            @Expect(result.status, "unexpected_frame")
        } finally {
            resetServicePluginHostForTest()
        }

        let wrongCapability = this.stdioInvokeResponseLine("{\"ok\":true,\"status\":\"ok\"}", capabilityId: "stdio.monitor.other")
        this.registerStdioScript(this.stdioScriptWithInvokeLines(initLine, [wrongCapability]))
        try {
            let result = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(result.ok, false)
            @Expect(result.status, "unexpected_frame")
        } finally {
            resetServicePluginHostForTest()
        }

        let wrongCorrelation = this.stdioInvokeResponseLine("{\"ok\":true,\"status\":\"ok\"}", correlationId: "corr-other")
        let correctResponse = this.stdioInvokeResponseLine("{\"ok\":true,\"status\":\"ok\"}")
        this.registerStdioScript(this.stdioScriptWithInvokeLines(initLine, [wrongCorrelation, correctResponse]))
        try {
            let result = invokeRegisteredCapability(CapabilityInvokeRequest("stdio.monitor.status", payload: "{}"))
            @Expect(result.ok, true)
            @Expect(result.status, "ok")
        } finally {
            resetServicePluginHostForTest()
        }
    }

    @TestCase
    public func tRoot001AsyncEventPumpAllowsSamePluginWritebackResponse(): Unit {
        // T-ROOT-001, T-ASYNC-001, T-E2E-SP-001 (Metis half-chain)
        withServicePluginHostTestHome("service-plugin-root-async-writeback", { _home: Path =>
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
                @Expect(this.waitForMessage(messages, lock, timeoutMillis: 6500), true)
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
    public func tRoot002AsyncWritebackIgnoresUnrelatedHeartbeatAndResponseFrames(): Unit {
        // T-ROOT-002, T-ASYNC-002, T-ASYNC-005
        withServicePluginHostTestHome("service-plugin-root-async-unrelated", { _home: Path =>
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
                @Expect(this.waitForMessage(messages, lock, timeoutMillis: 6500), true)
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
        withServicePluginHostTestHome("service-plugin-root-async-timeout", { _home: Path =>
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
