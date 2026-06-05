package metis.gateway.service_plugin

import std.collection.ArrayList
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
            @Expect(result.ok, false)
            @Expect(result.status, "correlation_mismatch")
        } finally {
            resetServicePluginHostForTest()
        }
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
