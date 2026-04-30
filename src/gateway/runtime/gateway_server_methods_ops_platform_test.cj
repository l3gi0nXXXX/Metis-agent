package metis.gateway.runtime

import metis.core.config.GatewayUserSettings

import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject}

private func opsPlatformTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) =>
            try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

@Test
public class GatewayServerMethodsOpsPlatformTest {
    @TestCase
    public func nodesExecuteCarriesPlatformAndBacklogContext(): Unit {
        let response = handleGatewayOpsFamily("nodes.execute", GatewayUserSettings())
        @Expect(response.isSome(), true)
        let result = response.getOrThrow().result.asObject()
        @Expect(result.get("executor").isSome(), true)
        @Expect(result.get("pendingWork").isSome(), true)
        @Expect(result.get("scheduler").isSome(), true)
        @Expect(result.get("backlog").isSome(), true)
        @Expect(result.get("platform").isSome(), true)
        let platform = result.get("platform").getOrThrow().asObject()
        let health = platform.get("health").getOrThrow().asObject()
        @Expect(opsPlatformTestString(health, "executorState"), "idle")
    }

    @TestCase
    public func probeActionsCarryOperationalContext(): Unit {
        let response = handleGatewayOpsFamily("probe.actions", GatewayUserSettings())
        @Expect(response.isSome(), true)
        let result = response.getOrThrow().result.asObject()
        @Expect(result.get("transport").isSome(), true)
        @Expect(result.get("http").isSome(), true)
        @Expect(result.get("platform").isSome(), true)
        @Expect(result.get("controlUi").isSome(), true)
    }

    @TestCase
    public func doctorRemediationCarriesRuntimeAndOperationalContext(): Unit {
        let response = handleGatewayOpsFamily("doctor.remediation", GatewayUserSettings())
        @Expect(response.isSome(), true)
        let result = response.getOrThrow().result.asObject()
        @Expect(result.get("runtime").isSome(), true)
        @Expect(result.get("transport").isSome(), true)
        @Expect(result.get("http").isSome(), true)
        @Expect(result.get("platform").isSome(), true)
        @Expect(result.get("controlUi").isSome(), true)
    }

    @TestCase
    public func doctorExposesTelegramDiagnosticsAndActions(): Unit {
        var user = GatewayUserSettings()
        user.telegram.enabled = true

        let response = handleGatewayOpsFamily("doctor", user)
        @Expect(response.isSome(), true)
        let doctor = response.getOrThrow().result.asObject().get("doctor").getOrThrow().asObject()
        let diagnostics = doctor.get("telegramDiagnostics").getOrThrow().asObject()
        let findings = diagnostics.get("findings").getOrThrow().asArray().toJsonString()
        @Expect(findings.contains("telegram-token-missing"), true)
        let actions = doctor.get("actions").getOrThrow().asArray().toJsonString()
        @Expect(actions.contains("telegram-diagnostic-followup"), true)
        @Expect(actions.contains("telegram-token-missing"), true)
    }
}
