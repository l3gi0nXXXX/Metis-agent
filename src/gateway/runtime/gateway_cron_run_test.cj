package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.cron.{
    CronJob,
    CronJobState,
    CronSchedule,
    clearGatewayCronRunHookForTest,
    cronSave,
    cronStorePath,
    executeGatewayCronCommand,
    readCronRunLogEntriesForJob,
    registerGatewayCronRunUnified
}
import metis.gateway.core.{ChannelAdapter, GatewayRouter, GatewayService}
import metis.gateway.model.{ChannelPolicyConfig, InboundMessage, OutboundMessage, SendResult}
import metis.gateway.session.GatewaySessionRequest
import metis.gateway.tools.GatewayCronToolset

import std.collection.HashMap
import std.core.Duration
import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.sync.AtomicBool
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

private func withGatewayCronRunTestHome<T>(block: (Path) -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = "/tmp/metis-gateway-cron-run-test-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
        try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", home)
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        clearGatewayCronRunHookForTest()
        try {
            return block(cronStorePath(CliConfig.dotDir))
        } finally {
            clearGatewayCronRunHookForTest()
            debugSetCronRunnerReplyForTest(None<(CronJob, GatewaySessionRequest) -> String>)
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        }
    }
}

private func cronRunTestResult(ok: Bool, ran: Bool): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(ok))
    out.put("ran", JsonBool(ran))
    out
}

private func cronRunTestError(message: String): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(false))
    out.put("error", JsonString(message))
    out
}

private func cronRunTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func cronRunTestBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

private class CronRunTestCallState {
    public var jobId: String = ""
    public var force: Bool = false
    public var calls: Int64 = 0
}

private func cronRunTestToolRun(jobId: String): String {
    GatewayCronToolset().cronForTest(
        "run",
        Some(jobId),
        None<String>,
        None<String>,
        None<String>,
        None<String>,
        None<String>,
        None<Bool>,
        None<String>,
        None<String>,
        None<String>,
        None<String>,
        None<String>,
        None<Bool>,
        None<Int64>,
        None<Int64>,
        None<Int64>,
        None<String>,
        None<String>,
        None<String>,
        None<String>,
        None<Int64>,
        None<Int64>,
        None<String>,
        None<String>,
        None<Bool>,
        None<String>,
        None<String>,
        None<Array<String>>,
        None<String>,
        None<String>,
        None<Bool>,
        None<String>,
        None<String>
    )
}

private func cronRunTestJob(id: String, deliveryChannel!: String = "", deliveryTo!: String = ""): CronJob {
    CronJob(
        id,
        "hello cron",
        CronSchedule.every(60000),
        state: CronJobState(nextRunAtMs: 1),
        sessionTarget: "main",
        agentId: "general",
        deliveryChannel: deliveryChannel,
        deliveryTo: deliveryTo
    )
}

private class GatewayCronRunTestAdapter <: ChannelAdapter {
    public var sendCount: Int64 = 0
    public var lastPeerId: String = ""
    public var lastText: String = ""

    public prop name: String {
        get() { "telegram" }
    }

    public func start(): Unit {}

    public func stop(): Unit {}

    public func pullInbound(): Array<InboundMessage> {
        []
    }

    public func send(message: OutboundMessage): SendResult {
        this.capture(message)
        SendResult.Success
    }

    public func sendWithMessageId(message: OutboundMessage): String {
        this.capture(message)
        "fake-message"
    }

    private func capture(message: OutboundMessage): Unit {
        this.sendCount += 1
        this.lastPeerId = message.peerId
        this.lastText = message.text
    }
}

private func cronRunTestGateway(adapter: GatewayCronRunTestAdapter): GatewayService {
    let service = GatewayService(GatewayRouter(HashMap<String, ChannelPolicyConfig>()))
    service.registerAdapter(adapter, channelId: "telegram", accountId: "")
    service
}

@Test
public class GatewayCronRunExecutorTest {
    @TestCase
    public func m3U1CronRunWithExecutorUsesParsedJobAndForce(): Unit {
        let capture = CronRunTestCallState()
        let pair = gatewayCronRunWithExecutor(["cron", "run", "--job-id", "j1"], { jobId: String, force: Bool =>
            capture.jobId = jobId
            capture.force = force
            cronRunTestResult(true, true)
        })

        @Expect(capture.jobId, "j1")
        @Expect(capture.force, true)
        @Expect(pair[1], 0)
        @Expect(pair[0].contains("Cron run"), true)
        @Expect(pair[0].contains("Ran: true"), true)
    }

    @TestCase
    public func m3B1CronRunWithExecutorPreservesMissingDueLegacyAndJsonSemantics(): Unit {
        let missing = gatewayCronRunWithExecutor(["cron", "run"], { _jobId: String, _force: Bool =>
            cronRunTestResult(true, true)
        })
        @Expect(missing[1], 1)
        @Expect(missing[0].contains("missing id"), true)

        let dueCapture = CronRunTestCallState()
        dueCapture.force = true
        let due = gatewayCronRunWithExecutor(["cron", "run", "--job-id", "due-job", "--due"], { _jobId: String, force: Bool =>
            dueCapture.force = force
            cronRunTestResult(true, false)
        })
        @Expect(dueCapture.force, false)
        @Expect(due[1], 1)

        let legacyCapture = CronRunTestCallState()
        legacyCapture.force = true
        let legacy = gatewayCronRunWithExecutor(["cron", "run", "legacy-job", "--due-only"], { _jobId: String, force: Bool =>
            legacyCapture.force = force
            cronRunTestResult(true, false)
        })
        @Expect(legacyCapture.force, false)
        @Expect(legacy[1], 1)

        let json = gatewayCronRunWithExecutor(["cron", "run", "--job-id", "json-job", "--json"], { _jobId: String, _force: Bool =>
            cronRunTestResult(true, true)
        })
        let obj = JsonValue.fromStr(json[0]).asObject()
        @Expect(json[1], 0)
        @Expect(cronRunTestBool(obj, "ok"), true)
        @Expect(cronRunTestBool(obj, "ran"), true)
    }

    @TestCase
    public func m3P1CronRunWithExecutorKeepsJsonAndHumanOutput(): Unit {
        let json = gatewayCronRunWithExecutor(["cron", "run", "j1", "--json"], { _jobId: String, _force: Bool =>
            cronRunTestResult(true, true)
        })
        @Expect(json[1], 0)
        @Expect(json[0].contains("\"ok\""), true)
        @Expect(json[0].contains("\"ran\""), true)
        let obj = JsonValue.fromStr(json[0]).asObject()
        @Expect(cronRunTestBool(obj, "ok"), true)
        @Expect(cronRunTestBool(obj, "ran"), true)

        let human = gatewayCronRunWithExecutor(["cron", "run", "j1"], { _jobId: String, _force: Bool =>
            cronRunTestResult(true, true)
        })
        @Expect(human[1], 0)
        @Expect(human[0].contains("Cron run"), true)
        @Expect(human[0].contains("Job: j1"), true)
        @Expect(human[0].contains("Ran: true"), true)
    }

    @TestCase
    public func m5e2e2CronRunHumanOutputShowsWebDiagnosticWithoutRawJson(): Unit {
        let human = gatewayCronRunWithExecutor(["cron", "run", "web-job"], { _jobId: String, _force: Bool =>
            let out = cronRunTestResult(true, true)
            out.put("diagnosticCode", JsonString("web_provider_unavailable"))
            out.put("diagnosticMessage", JsonString("Real-time web search unavailable token=raw-lower-secret"))
            out
        })

        @Expect(human[1], 0)
        @Expect(human[0].contains("Cron run"), true)
        @Expect(human[0].contains("Job: web-job"), true)
        @Expect(human[0].contains("Diagnostic: web_provider_unavailable"), true)
        @Expect(human[0].contains("raw-lower-secret"), false)
        @Expect(human[0].contains("\"ok\""), false)
        @Expect(human[0].contains("\"result\""), false)
    }

    @TestCase
    public func m3N1GatewayCronCliEnsureDoesNotOverwriteExistingLiveHook(): Unit {
        withGatewayCronRunTestHome({ _storePath: Path =>
            let liveHook = CronRunTestCallState()
            registerGatewayCronRunUnified({ _sub: Array<String> =>
                liveHook.calls += 1
                ("live hook result", 0)
            })

            let pair = gatewayExecuteCronWithUnifiedRun(["cron", "run", "--job-id", "j1"])
            @Expect(liveHook.calls, 1)
            @Expect(pair[1], 0)
            @Expect(pair[0], "live hook result")
        })
    }
}

@Test
public class GatewayCronRunLiveEntrypointsTest {
    @TestCase
    public func m2P2SyncRunKeepsHistoricPayloadAndEnqueueReturnsRunIdQuickly(): Unit {
        withGatewayCronRunTestHome({ storePath =>
            cronSave(storePath, [cronRunTestJob("m2-entry")])
            let release = AtomicBool(false)
            debugSetCronRunnerReplyForTest(Some({ _job, _request =>
                while (!release.load()) { sleep(Duration.millisecond * 2) }
                "entry-ok"
            }))
            let runner = CronRunner(storePath: storePath, maxConcurrentRuns: 2)
            registerGatewayCronRunHookForRunner(runner)
            let began = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let enqueued = executeGatewayCronCommand(["cron", "enqueue", "--job-id", "m2-entry"])
            let elapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - began
            @Expect(enqueued[1], 0)
            @Expect(enqueued[0].contains("Enqueued: true"), true)
            @Expect(enqueued[0].contains("Run ID:"), true)
            @Expect(enqueued[0].contains("\"ok\""), false)
            @Expect(elapsed < 250, true)
            let duplicate = executeGatewayCronCommand(["cron", "enqueue", "--job-id", "m2-entry"])
            @Expect(duplicate[0].contains("already-running"), true)
            release.store(true)
            @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
            runner.tick()

            let sync = executeGatewayCronCommand(["cron", "run", "--job-id", "m2-entry"])
            @Expect(sync[1], 0)
            @Expect(sync[0].contains("Ran: true"), true)
            @Expect(sync[0].contains("Enqueued:"), false)
            @Expect(sync[0].contains("\"result\""), false)
        })
    }

    @TestCase
    public func m4U1RegisteredRunnerHookExecutesCapturedRunnerViaCronCommand(): Unit {
        withGatewayCronRunTestHome({ storePath: Path =>
            let customStore = Path(storePath.toString() + ".custom")
            cronSave(customStore, [cronRunTestJob("runner-job")])
            let reply = CronRunTestCallState()
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                reply.calls += 1
                "runner ok"
            }))
            let runner = CronRunner(gatewayOpt: None<GatewayService>, storePath: customStore, cronEnabled: true)
            registerGatewayCronRunHookForRunner(runner)

            let pair = executeGatewayCronCommand(["cron", "run", "--job-id", "runner-job"])
            @Expect(pair[1], 0)
            @Expect(pair[0].contains("Ran: true"), true)
            @Expect(reply.calls, 1)
        })
    }

    @TestCase
    public func m4B1RegisteredHookOutcomeReportsMissingHookAndUnknownJob(): Unit {
        withGatewayCronRunTestHome({ _storePath: Path =>
            let missingHook = gatewayCronRunOnceOutcomeViaRegisteredHook("missing", true)
            @Expect(missingHook[0], false)
            @Expect(missingHook[1].contains("cron run 尚未注册网关执行器"), true)

            registerGatewayCronRunUnified({ sub: Array<String> =>
                gatewayCronRunWithExecutor(sub, { _jobId: String, _force: Bool =>
                    cronRunTestError("unknown job id")
                })
            })
            let unknown = gatewayCronRunOnceOutcomeViaRegisteredHook("missing", true)
            @Expect(unknown[0], false)
            @Expect(unknown[1].contains("unknown job id"), true)
        })
    }

    @TestCase
    public func m2P1LiveRunNowEntrypointsUseRegisteredRunnerAndDeliver(): Unit {
        withGatewayCronRunTestHome({ storePath: Path =>
            cronSave(storePath, [cronRunTestJob("live-job", deliveryChannel: "telegram", deliveryTo: "chat-1")])
            let reply = CronRunTestCallState()
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                reply.calls += 1
                "delivered ok"
            }))
            let adapter = GatewayCronRunTestAdapter()
            let service = cronRunTestGateway(adapter)
            let runner = CronRunner(gatewayOpt: Some(service), storePath: storePath, cronEnabled: true)
            registerGatewayCronRunHookForRunner(runner)

            let toolRaw = cronRunTestToolRun("live-job")
            @Expect(JsonValue.fromStr(toolRaw).asObject().get("ok").getOrThrow().asBool().getValue(), true)

            let control = runCronJobNow("live-job")
            @Expect(control[0], true)
            @Expect(control[1].contains("Enqueued: true"), true)
            @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
            runner.tick()

            let dashboard = dashboardRunCronJobNow("live-job")
            @Expect(dashboard[0], true)
            @Expect(dashboard[1].contains("Enqueued: true"), true)
            @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
            runner.tick()

            let dashboardApi = gatewayDashboardRunCronJobNow("live-job")
            @Expect(dashboardApi[0], true)
            @Expect(dashboardApi[1].contains("Enqueued: true"), true)
            @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
            runner.tick()

            let params = JsonObject()
            params.put("jobId", JsonString("live-job"))
            let rpc = handleGatewayCronFamily("cron.run", GatewayRpcRequest("cron.run", params: params)).getOrThrow()
            @Expect(rpc.ok, true)

            @Expect(reply.calls, 5)
            @Expect(adapter.sendCount, 5)
            @Expect(adapter.lastPeerId, "chat-1")
            @Expect(adapter.lastText.contains("delivered ok"), true)
            let runs = readCronRunLogEntriesForJob(storePath, "live-job", limit: 10)
            @Expect(runs.get("total").getOrThrow().asInt().getValue(), 5)
        })
    }

    @TestCase
    public func m4N1CronRpcAndCliRunKeepExistingLiveHook(): Unit {
        withGatewayCronRunTestHome({ _storePath: Path =>
            let liveHook = CronRunTestCallState()
            registerGatewayCronRunUnified({ _sub: Array<String> =>
                liveHook.calls += 1
                ("live rpc hook", 0)
            })

            let params = JsonObject()
            params.put("id", JsonString("rpc-job"))
            let rpc = handleGatewayCronFamily("cron.run", GatewayRpcRequest("cron.run", params: params)).getOrThrow()
            @Expect(rpc.ok, true)
            @Expect(cronRunTestString(rpc.result.asObject(), "output"), "live rpc hook")

            let pair = gatewayExecuteCronWithUnifiedRun(["cron", "run", "--job-id", "rpc-job"])
            @Expect(pair[1], 0)
            @Expect(pair[0], "live rpc hook")
            @Expect(liveHook.calls, 2)
        })
    }
}
