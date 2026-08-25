package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, GatewayUserSettings, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.config.buildGatewayConfigFromUserSettings
import metis.gateway.core.{gatewayChannelRuntimeMarkFailure, gatewayChannelRuntimeMarkRunning, gatewayChannelRuntimeMarkStarting, gatewayChannelRuntimeRegisterAccount}
import metis.gateway.logging.{gatewayLoggingCaptureConsoleForTest, gatewayLoggingCapturedConsoleForTest, gatewayLoggingResetForTest}
import metis.process.{ManagedStdioBrokerClient, ManagedStdioBrokerSnapshot, ManagedStdioOwnerSpec}

import std.env.{getVariable, setVariable}
import std.convert.Parsable
import std.fs.{Directory, Path, remove}
import std.process.executeWithOutput
import std.time.*
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

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

private func statusTestInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { Int64.parse(v.toJsonString()) } catch (_: Exception) { 0 }
        case None => 0
    }
}

private func gatewayStatusPersistUser(user: GatewayUserSettings): Unit {
    let _ = MetisConfigManager.setGatewaySettings(user)
    CliSettingManager.invalidate()
}

private func gatewayStatusOperational(
    alive: Bool,
    responsive: Bool,
    status: String,
    pollLagMs!: Int64 = 0,
    queueDepth!: Int64 = 0,
    queueCapacity!: Int64 = 128
): JsonObject {
    let broker = JsonObject()
    broker.put("running", JsonBool(alive))
    broker.put("responsive", JsonBool(responsive))
    broker.put("status", JsonString(status))
    broker.put("generation", JsonInt(1))
    broker.put("ownerCount", JsonInt(0))
    let out = JsonObject()
    out.put("broker", broker)
    out.put("pollLagMs", JsonInt(pollLagMs))
    out.put("inboundQueueDepth", JsonInt(queueDepth))
    out.put("inboundQueueCapacity", JsonInt(queueCapacity))
    out
}

private func gatewayStatusOperationalFromBroker(snapshot: ManagedStdioBrokerSnapshot): JsonObject {
    let broker = JsonObject()
    broker.put("running", JsonBool(snapshot.running))
    broker.put("responsive", JsonBool(snapshot.responsive))
    broker.put("status", JsonString(snapshot.status))
    broker.put("generation", JsonInt(snapshot.generation))
    broker.put("ownerCount", JsonInt(snapshot.ownerCount))
    let out = JsonObject()
    out.put("broker", broker)
    out.put("pollLagMs", JsonInt(0))
    out.put("inboundQueueDepth", JsonInt(0))
    out.put("inboundQueueCapacity", JsonInt(128))
    out
}

private func gatewayStatusPidGone(pid: Int64): Bool {
    if (pid <= 0) { return true }
    let (exitCode, _, _) = executeWithOutput("/bin/kill", ["-0", "${pid}"])
    exitCode != 0
}

private func gatewayStatusPgidGone(pgid: Int64): Bool {
    if (pgid <= 0) { return true }
    let (exitCode, _, _) = executeWithOutput("/bin/kill", ["-0", "--", "-${pgid}"])
    exitCode != 0
}

private func gatewayStatusWaitForGone(pid: Int64, pgid: Int64, timeoutMs!: Int64 = 3000): Bool {
    let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
    while (DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
        if (gatewayStatusPidGone(pid) && gatewayStatusPgidGone(pgid)) { return true }
        sleep(Duration.millisecond * 20)
    }
    gatewayStatusPidGone(pid) && gatewayStatusPgidGone(pgid)
}

@Test
public class GatewayServerMethodsStatusTest {
    @TestCase
    public func p5P1BrokerUnresponsiveReadinessAndGenerationRecoveryAreExact(): Unit {
        withGatewayStatusTestSettings<Unit>("p5-broker-recovery", { =>
            let user = gatewayStatusTestUser()
            gatewayStatusPersistUser(user)
            let cfg = buildGatewayConfigFromUserSettings(user)
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkRunning("telegram", accountId: "default")
            let client = ManagedStdioBrokerClient(brokerTestMode: true)
            try {
                let old = client.startOwner(ManagedStdioOwnerSpec(
                    "p5-readiness-old",
                    "node",
                    args: ["-e", "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"],
                    stdinMode: "closed",
                    deadlineMs: 10000
                ))
                @Expect(old.ok, true)
                let initiallyReady = gatewayBuildRuntimeReadinessSnapshot(
                    cfg,
                    user,
                    operational: Some(gatewayStatusOperationalFromBroker(client.snapshot()))
                )
                @Expect(statusTestString(initiallyReady, "status"), "ready")

                @Expect(client.debugHangBrokerForTest(), true)
                let probe = client.probeBrokerForGeneration(old.generation, timeoutMs: 80)
                @Expect(probe.ok, false)
                @Expect(probe.status, "broker_unresponsive")
                let degraded = gatewayBuildRuntimeReadinessSnapshot(
                    cfg,
                    user,
                    operational: Some(gatewayStatusOperationalFromBroker(client.snapshot()))
                )
                @Expect(statusTestString(degraded, "status"), "degraded")
                @Expect(statusTestString(degraded, "reason"), "broker_unresponsive")
                @Expect(gatewayStatusWaitForGone(old.pid, old.pgid), true)
                @Expect(client.snapshot().ownerCount, 0)

                let replacement = client.startOwner(ManagedStdioOwnerSpec(
                    "p5-readiness-replacement",
                    "node",
                    args: ["-e", "console.log('恢复中文🙂')"],
                    stdinMode: "closed",
                    deadlineMs: 2000
                ))
                @Expect(replacement.ok, true)
                @Expect(replacement.generation > old.generation, true)
                var output = ""
                var terminal = false
                let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 3000
                while (!terminal && DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
                    match (client.readOwnerLine("p5-readiness-replacement", timeoutMs: 50)) {
                        case Some(event) =>
                            if (event.eventType == "owner.stdout") { output = event.text }
                            if (event.eventType == "owner.exit" || event.eventType == "owner.error") { terminal = true }
                        case None => ()
                    }
                }
                @Expect(terminal, true)
                @Expect(output, "恢复中文🙂")
                let recovered = gatewayBuildRuntimeReadinessSnapshot(
                    cfg,
                    user,
                    operational: Some(gatewayStatusOperationalFromBroker(client.snapshot()))
                )
                @Expect(statusTestString(recovered, "status"), "ready")
                @Expect(statusTestString(recovered, "reason"), "ok")
            } finally {
                let closed = client.close(timeoutMs: 3000)
                @Expect(closed.ok, true)
            }
        })
    }

    @TestCase
    public func p5N1OperationalTransitionLogsAreStableAndDoNotEchoDiagnostics(): Unit {
        withGatewayStatusTestSettings<Unit>("p5-operational-logs", { =>
            let user = gatewayStatusTestUser()
            gatewayStatusPersistUser(user)
            let cfg = buildGatewayConfigFromUserSettings(user)
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkRunning("telegram", accountId: "default")
            let secret = "Authorization: Bearer secret-never-visible 中文🙂 /Users/private/never-visible " + "长" * 300
            let failed = gatewayStatusOperational(true, false, secret)
            failed.put("diagnostic", JsonString(secret))

            gatewayLoggingResetForTest()
            gatewayLoggingCaptureConsoleForTest()
            let _ = gatewayBuildRuntimeReadinessSnapshot(cfg, user, operational: Some(failed))
            let _ = gatewayBuildRuntimeReadinessSnapshot(
                cfg,
                user,
                operational: Some(gatewayStatusOperational(true, true, "ready"))
            )
            var rendered = ""
            for (line in gatewayLoggingCapturedConsoleForTest()) { rendered += line + "\n" }
            @Expect(rendered.contains("event=stdio.broker.unresponsive"), true)
            @Expect(rendered.contains("event=gateway.poll.recovered"), true)
            @Expect(rendered.contains("secret-never-visible"), false)
            @Expect(rendered.contains("/Users/private/never-visible"), false)
            gatewayLoggingResetForTest()
        })
    }

    @TestCase
    public func p5U1PollCompletionUpdatesMemoryAndHeartbeatFields(): Unit {
        withGatewayStatusTestSettings<Unit>("p5-poll-snapshot", { =>
            gatewayRuntimeMarkStarting()
            try {
                let operational = gatewayStatusOperational(true, true, "ready", queueDepth: 7)
                gatewayRuntimeMarkPollCompleted(operational)
                let snapshot = gatewayRuntimeSnapshot()
                @Expect(statusTestInt(snapshot, "lastPollAtMs") > 0, true)
                @Expect(statusTestInt(snapshot, "pollLagMs") >= 0, true)
                @Expect(snapshot.get("brokerAlive").getOrThrow().asBool().getValue(), true)
                @Expect(snapshot.get("brokerResponsive").getOrThrow().asBool().getValue(), true)
                @Expect(statusTestInt(snapshot, "brokerGeneration"), 1)
                @Expect(statusTestInt(snapshot, "brokerOwnerCount"), 0)
                @Expect(statusTestInt(snapshot, "inboundQueueDepth"), 7)
            } finally {
                gatewayRuntimeMarkStopped(reason: "test-complete")
            }
        })
    }

    @TestCase
    public func p5U1ReadinessDistinguishesBrokerPollAndQueueFailures(): Unit {
        withGatewayStatusTestSettings<Unit>("p5-operational", { =>
            let user = gatewayStatusTestUser()
            gatewayStatusPersistUser(user)
            let cfg = buildGatewayConfigFromUserSettings(user)
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkRunning("telegram", accountId: "default")

            let healthy = gatewayBuildRuntimeReadinessSnapshot(
                cfg,
                user,
                operational: Some(gatewayStatusOperational(true, true, "ready", pollLagMs: 5000, queueDepth: 127))
            )
            @Expect(statusTestString(healthy, "status"), "ready")
            @Expect(statusTestString(healthy, "reason"), "ok")

            let cases = [
                (gatewayStatusOperational(true, false, "broker_unresponsive"), "broker_unresponsive"),
                (gatewayStatusOperational(false, false, "broker_exited"), "broker_dead"),
                (gatewayStatusOperational(false, false, "broker_unavailable"), "broker_unavailable"),
                (gatewayStatusOperational(true, true, "ready", pollLagMs: 5001), "poll_stale"),
                (gatewayStatusOperational(true, true, "ready", queueDepth: 128), "inbound_queue_full")
            ]
            for ((operational, expectedReason) in cases) {
                let readiness = gatewayBuildRuntimeReadinessSnapshot(cfg, user, operational: Some(operational))
                @Expect(statusTestString(readiness, "status"), "degraded")
                @Expect(statusTestString(readiness, "reason"), expectedReason)
                @Expect(readiness.get("ready").getOrThrow().asBool().getValue(), false)
            }

            let health = JsonValue.fromStr(gatewayHttpHealthProbeJson(cfg)).asObject()
            @Expect(statusTestString(health, "status"), "live")
            @Expect(health.get("ok").getOrThrow().asBool().getValue(), true)
        })
    }

    @TestCase
    public func healthAndReadinessExposeSharedInspectContext(): Unit {
        let health = handleGatewayStatusFamily("health", GatewayUserSettings()).getOrThrow()
        let healthResult = health.result.toJsonString()
        @Expect(healthResult.contains("surfaces"), true)
        @Expect(healthResult.contains("platform"), true)
        @Expect(healthResult.contains("openclawCompatHost"), true)
        @Expect(healthResult.contains("processIdentity"), true)

        let readiness = handleGatewayStatusFamily("readiness", GatewayUserSettings()).getOrThrow()
        let readinessResult = readiness.result.toJsonString()
        @Expect(readinessResult.contains("surfaces"), true)
        @Expect(readinessResult.contains("platform"), true)
        @Expect(readinessResult.contains("openclawCompatHost"), true)
        @Expect(readinessResult.contains("processIdentity"), true)

        let status = buildGatewayRpcStatusJson(GatewayUserSettings())
        let identity = statusTestObject(status, "processIdentity")
        @Expect(statusTestString(identity, "schema"), "metis.gateway.process.v1")
        @Expect(statusTestString(identity, "buildFingerprint"), gatewayBuildFingerprint())
    }

    @TestCase
    public func failedChannelRuntimeAccountMatchesReadyzStatusHealthAndReadiness(): Unit {
        withGatewayStatusTestSettings<Unit>("failed-runtime", { =>
            let user = gatewayStatusTestUser()
            gatewayStatusPersistUser(user)
            let cfg = buildGatewayConfigFromUserSettings(user)
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkStarting("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkFailure("telegram", accountId: "default", error: "transport-timeout", errorKind: "start_timeout")

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
                @Expect(statusTestString(row, "lastError"), "transport-timeout")
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
