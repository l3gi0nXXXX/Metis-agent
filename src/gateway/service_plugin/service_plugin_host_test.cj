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
}
