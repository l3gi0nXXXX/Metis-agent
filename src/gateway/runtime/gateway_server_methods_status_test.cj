package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, GatewayUserSettings, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.config.buildGatewayConfigFromUserSettings
import metis.gateway.core.{gatewayChannelRuntimeMarkFailure, gatewayChannelRuntimeMarkRunning, gatewayChannelRuntimeMarkStarting, gatewayChannelRuntimeRegisterAccount}

import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonValue}

private func gatewayStatusTestUser(): GatewayUserSettings {
    var user = GatewayUserSettings()
    user.auth.mode = "none"
    user.telegram.enabled = true
    user.telegram.botToken = "123456:status-test-token"
    return user
}

private func withGatewayStatusTestSettings<T>(name: String, block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let testHome = "/tmp/metis-gateway-status-test-${name}"
        try {
            remove(Path(testHome), recursive: true)
        } catch (_: Exception) {
            ()
        }
        Directory.create(testHome, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", testHome)
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        try {
            block()
        } finally {
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
        }
    }
}

private func statusTestObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func statusTestArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func statusTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func gatewayStatusPersistUser(user: GatewayUserSettings): Unit {
    let _ = MetisConfigManager.setGatewaySettings(user)
    CliSettingManager.invalidate()
}

@Test
public class GatewayServerMethodsStatusTest {
    @TestCase
    public func healthAndReadinessExposeSharedInspectContext(): Unit {
        let health = handleGatewayStatusFamily("health", GatewayUserSettings()).getOrThrow()
        let healthResult = health.result.toJsonString()
        @Expect(healthResult.contains("surfaces"), true)
        @Expect(healthResult.contains("platform"), true)
        @Expect(healthResult.contains("openclawCompatHost"), true)

        let readiness = handleGatewayStatusFamily("readiness", GatewayUserSettings()).getOrThrow()
        let readinessResult = readiness.result.toJsonString()
        @Expect(readinessResult.contains("surfaces"), true)
        @Expect(readinessResult.contains("platform"), true)
        @Expect(readinessResult.contains("openclawCompatHost"), true)
    }

    @TestCase
    public func failedChannelRuntimeAccountMatchesReadyzStatusHealthAndReadiness(): Unit {
        withGatewayStatusTestSettings<Unit>("failed-runtime", { =>
            let user = gatewayStatusTestUser()
            gatewayStatusPersistUser(user)
            let cfg = buildGatewayConfigFromUserSettings(user)
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkStarting("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkFailure("telegram", accountId: "default", error: "monitor-host-timeout", errorKind: "start_timeout")

            let readyz = JsonValue.fromStr(gatewayHttpReadyProbeJson(cfg)).asObject()
            let readyzReadiness = statusTestObject(readyz, "readiness")
            let status = buildGatewayRpcStatusJson(user)
            let statusReadiness = statusTestObject(status, "readiness")
            let statusChannelReadiness = statusTestObject(status, "channelReadiness")
            let health = handleGatewayStatusFamily("health", user).getOrThrow().result.asObject()
            let healthReadiness = statusTestObject(health, "ready")
            let rpcReadiness = handleGatewayStatusFamily("readiness", user).getOrThrow().result.asObject()
            let rpcReadinessReadiness = statusTestObject(rpcReadiness, "readiness")

            for (readiness in [readyzReadiness, statusReadiness, statusChannelReadiness, healthReadiness, rpcReadinessReadiness]) {
                @Expect(statusTestString(readiness, "status"), "degraded")
                @Expect(readiness.get("ready").getOrThrow().asBool().getValue(), false)
                @Expect(readiness.get("ok").getOrThrow().asBool().getValue(), false)
                @Expect(readiness.get("failedCount").getOrThrow().toJsonString(), "1")
                let accounts = statusTestArray(readiness, "accounts")
                @Expect(accounts.size(), 1)
                let row = accounts[0].asObject()
                @Expect(statusTestString(row, "channelId"), "telegram")
                @Expect(statusTestString(row, "accountId"), "default")
                @Expect(statusTestString(row, "lifecycleState"), "failed")
                @Expect(statusTestString(row, "lastError"), "monitor-host-timeout")
                @Expect(statusTestString(row, "errorKind"), "start_timeout")
            }
        })
    }

    @TestCase
    public func startingChannelRuntimeAccountIsNotReportedOk(): Unit {
        withGatewayStatusTestSettings<Unit>("starting-runtime", { =>
            let user = gatewayStatusTestUser()
            gatewayStatusPersistUser(user)
            let cfg = buildGatewayConfigFromUserSettings(user)
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkStarting("telegram", accountId: "default")

            let readyzReadiness = statusTestObject(JsonValue.fromStr(gatewayHttpReadyProbeJson(cfg)).asObject(), "readiness")
            let statusReadiness = statusTestObject(buildGatewayRpcStatusJson(user), "readiness")
            let rpcReadinessReadiness = statusTestObject(handleGatewayStatusFamily("readiness", user).getOrThrow().result.asObject(), "readiness")

            for (readiness in [readyzReadiness, statusReadiness, rpcReadinessReadiness]) {
                @Expect(statusTestString(readiness, "status"), "starting")
                @Expect(readiness.get("ready").getOrThrow().asBool().getValue(), false)
                @Expect(readiness.get("ok").getOrThrow().asBool().getValue(), false)
                @Expect(readiness.get("startingCount").getOrThrow().toJsonString(), "1")
            }
        })
    }

    @TestCase
    public func disabledAndUnconfiguredRuntimeAccountsDoNotFailReadiness(): Unit {
        withGatewayStatusTestSettings<Unit>("disabled-runtime", { =>
            let user = gatewayStatusTestUser()
            gatewayStatusPersistUser(user)
            let cfg = buildGatewayConfigFromUserSettings(user)
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkRunning("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "disabled", enabled: false, configured: true)
            let _ = gatewayChannelRuntimeMarkFailure("telegram", accountId: "disabled", error: "disabled", errorKind: "disabled")
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "unconfigured", enabled: true, configured: false)
            let _ = gatewayChannelRuntimeMarkFailure("telegram", accountId: "unconfigured", error: "account-not-configured", errorKind: "account_not_configured")

            let readyzReadiness = statusTestObject(JsonValue.fromStr(gatewayHttpReadyProbeJson(cfg)).asObject(), "readiness")
            let statusReadiness = statusTestObject(buildGatewayRpcStatusJson(user), "readiness")

            for (readiness in [readyzReadiness, statusReadiness]) {
                @Expect(statusTestString(readiness, "status"), "ready")
                @Expect(readiness.get("ready").getOrThrow().asBool().getValue(), true)
                @Expect(readiness.get("failedCount").getOrThrow().toJsonString(), "0")
                @Expect(statusTestArray(readiness, "accounts").size(), 0)
            }
        })
    }

    @TestCase
    public func readinessAccountDetailsRedactSecretLikeErrors(): Unit {
        withGatewayStatusTestSettings<Unit>("redacted-runtime", { =>
            let user = gatewayStatusTestUser()
            let secret = "appSecret=app-secret-never-visible Authorization: Bearer bearer-never-visible bot token=bot-token-never-visible proxy password=proxy-never-visible"
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkFailure("telegram", accountId: "default", error: secret, errorKind: "start_failed")

            let status = buildGatewayRpcStatusJson(user)
            let rendered = status.toJsonString()
            @Expect(rendered.contains("app-secret-never-visible"), false)
            @Expect(rendered.contains("bearer-never-visible"), false)
            @Expect(rendered.contains("bot-token-never-visible"), false)
            @Expect(rendered.contains("proxy-never-visible"), false)
            @Expect(rendered.contains("redacted"), true)

            let readiness = statusTestObject(status, "channelReadiness")
            let accounts = statusTestArray(readiness, "accounts")
            @Expect(accounts.size(), 1)
            let row = accounts[0].asObject()
            @Expect(statusTestString(row, "lastError").contains("redacted"), true)
            @Expect(statusTestString(row, "errorKind"), "start_failed")
        })
    }

    @TestCase
    public func runtimeConfigDriftReportsStaleAndNotStartedAccounts(): Unit {
        withGatewayStatusTestSettings<Unit>("runtime-config-drift", { =>
            var user = GatewayUserSettings()
            user.auth.mode = "none"
            user.feishu.enabled = true
            user.feishu.appId = "feishu-app"
            user.feishu.appSecret = "feishu-secret"
            let _ = gatewayChannelRuntimeRegisterAccount("feishu", accountId: "xiaohongshu-ceo")
            let _ = gatewayChannelRuntimeMarkRunning("feishu", accountId: "xiaohongshu-ceo")

            let status = buildGatewayRpcStatusJson(user)
            let readiness = statusTestObject(status, "channelReadiness")
            let drift = statusTestObject(readiness, "runtimeConfigDrift")
            let stale = statusTestArray(drift, "staleRunningAccounts")
            let notStarted = statusTestArray(drift, "notStartedConfiguredAccounts")

            @Expect(statusTestString(readiness, "status"), "degraded")
            @Expect(stale.size(), 1)
            @Expect(statusTestString(stale[0].asObject(), "accountId"), "xiaohongshu-ceo")
            @Expect(statusTestString(stale[0].asObject(), "reason"), "stale-runtime-account")
            @Expect(statusTestString(stale[0].asObject(), "suggestedAction"), "reload-channel:feishu")
            @Expect(notStarted.size(), 1)
            @Expect(statusTestString(notStarted[0].asObject(), "accountId"), "default")
            @Expect(statusTestString(notStarted[0].asObject(), "reason"), "configured-account-not-started")
        })
    }

    @TestCase
    public func driftDiagnosticsExposeCredentialAndSidecarActionsWithoutSecrets(): Unit {
        withGatewayStatusTestSettings<Unit>("runtime-config-actions", { =>
            var user = GatewayUserSettings()
            user.auth.mode = "none"
            user.feishu.enabled = true
            user.feishu.appId = "feishu-app"
            user.feishu.appSecret = "feishu-secret"
            let _ = gatewayChannelRuntimeRegisterAccount("feishu", accountId: "default")
            let _ = gatewayChannelRuntimeMarkFailure("feishu", accountId: "default", error: "transport-timeout appSecret=hidden-secret", errorKind: "start_timeout")

            let status = buildGatewayRpcStatusJson(user)
            let rendered = status.toJsonString()
            @Expect(rendered.contains("hidden-secret"), false)
            let readiness = statusTestObject(status, "channelReadiness")
            let accounts = statusTestArray(readiness, "accounts")
            @Expect(accounts.size(), 1)
            let row = accounts[0].asObject()
            @Expect(statusTestString(row, "reason"), "transport-start-timeout")
            @Expect(statusTestString(row, "suggestedAction"), "check-channel-transport")
            @Expect(statusTestString(row, "lastError").contains("redacted"), true)
        })
    }

    @TestCase
    public func doctorUsesRuntimeReadinessSnapshot(): Unit {
        withGatewayStatusTestSettings<Unit>("doctor-runtime", { =>
            let user = gatewayStatusTestUser()
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkFailure("telegram", accountId: "default", error: "doctor-start-failed", errorKind: "start_failed")

            let response = handleGatewayOpsFamily("doctor", user).getOrThrow()
            let doctor = statusTestObject(response.result.asObject(), "doctor")
            let readiness = statusTestObject(doctor, "readiness")
            @Expect(statusTestString(readiness, "status"), "degraded")
            @Expect(readiness.get("ready").getOrThrow().asBool().getValue(), false)
            @Expect(statusTestArray(readiness, "accounts").size(), 1)
        })
    }

    @TestCase
    public func humanCliStatusOutputDoesNotExposeRawJsonAfterChannelReadinessFields(): Unit {
        withGatewayStatusTestSettings<Unit>("human-cli", { =>
            let user = gatewayStatusTestUser()
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkFailure("telegram", accountId: "default", error: "cli-start-failed", errorKind: "start_failed")
            let response = GatewayRpcResponse(true, "status", result: buildGatewayRpcStatusJson(user)).toJson().toJsonString()
            let rendered = gatewayFormatCommandOutput(response)
            @Expect(rendered.contains("Gateway call: status"), true)
            @Expect(rendered.contains("\"ok\""), false)
            @Expect(rendered.contains("\"channelReadiness\""), false)
        })
    }
}
