package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.core.{DuckDuckGoSearchHttpRequest, DuckDuckGoSearchHttpResponse, TavilySearchHttpRequest, TavilySearchHttpResponse, setDuckDuckGoSearchHttpRunnerForTest, setTavilySearchHttpRunnerForTest}
import metis.gateway.tools.{
    GatewayWebProviderResolution,
    GatewayWebToolset,
    debugGatewayShellExecuteForTest,
    setGatewayWebProviderResolverForTest
}
import metis.cron.{
    CronJob,
    CronExecutionJournalEntry,
    CronDeliveryReceipt,
    CronDeliveryIntentArtifact,
    CronStoreEnvelope,
    CronJobState,
    CronSchedule,
    CronWebhookHttpRequest,
    CronWebhookHttpResponse,
    appendCronRunLog,
    cronLoadOrEmpty,
    cronLoadStoreOrEmpty,
    saveCronDeliveryIntentArtifact,
    cronScriptsDir,
    cronRunLogPathFromStore,
    cronSave,
    cronSaveStoreAtomic,
    cronStorePath,
    readCronRunLogEntriesForJob,
    setCronWebhookHttpRunnerForTest
}
import metis.gateway.core.{
    ChannelAdapter,
    GatewayAgentReplyOutcome,
    GatewayRouter,
    GatewayService,
    gatewayLogEventInfo,
    gatewayLogMeta,
    setGatewayAgentBridgeReplyRunnerForTest
}
import metis.gateway.logging.gatewayLoggingResetForTest
import metis.gateway.model.{ChannelPolicyConfig, ChannelType, ChatType, InboundMessage, OutboundMessage, SendResult}
import metis.gateway.session.{GatewayIngressSource, GatewaySessionRequest, GatewayTurnContext, gatewayIngressSourceLabel}

import std.collection.{ArrayList, HashMap}
import std.core.Duration
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.process.launch
import std.sync.{AtomicBool, AtomicInt64, Condition, Mutex}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonInt, JsonObject, JsonString, JsonValue}

private func withCronRunnerTestHome<T>(block: (Path) -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = "/tmp/metis-cron-runner-test-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
        try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        let oldTavilyKey = getVariable("TAVILY_API_KEY")
        setVariable("METIS_HOME", home)
        setVariable("TAVILY_API_KEY", "")
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        try {
            return block(cronStorePath(CliConfig.dotDir))
        } finally {
            debugSetCronRunnerReplyForTest(None<(CronJob, GatewaySessionRequest) -> String>)
            debugSetCronRunnerOutcomeForTest(None<(CronJob, GatewaySessionRequest) -> GatewayAgentReplyOutcome>)
            debugSetCronRunnerBeforeExecuteForTest(None<(CronJob) -> Unit>)
            debugSetCronRunnerRunLogAppendForTest(None<() -> Unit>)
            debugSetCronRunnerReservePersistForTest(None<() -> Unit>)
            debugSetCronRunnerSubmitForTest(None<() -> Unit>)
            debugSetCronRunnerDeliveryForTest(None<() -> Unit>)
            debugSetCronRunnerDeliveryStageForTest(None<(String) -> Unit>)
            debugSetCronRunnerCommitForTest(None<(String) -> Unit>)
            setGatewayAgentBridgeReplyRunnerForTest(None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>)
            setGatewayWebProviderResolverForTest(None<(String) -> GatewayWebProviderResolution>)
            setDuckDuckGoSearchHttpRunnerForTest(None<(DuckDuckGoSearchHttpRequest) -> DuckDuckGoSearchHttpResponse>)
            setTavilySearchHttpRunnerForTest(None<(TavilySearchHttpRequest) -> TavilySearchHttpResponse>)
            setCronWebhookHttpRunnerForTest(None<(CronWebhookHttpRequest) -> CronWebhookHttpResponse>)
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            match (oldTavilyKey) {
                case Some(value) => setVariable("TAVILY_API_KEY", value)
                case None => setVariable("TAVILY_API_KEY", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        }
    }
}

@Test
public class CronRunnerManualIdentityTest {
    @TestCase
    public func m4N1StartupRecoveryNeverBlindlyReplaysClaimedOneShotAndBacksOffRecurring(): Unit {
        withCronRunnerTestHome({ storePath =>
            let one = cronRunnerTestJob("recover-one")
            one.schedule = CronSchedule.at(100)
            one.state.runningAtMs = 100
            one.state.executionId = "recover-one:100:100"
            one.state.executionHeartbeatAtMs = 100
            let recurring = cronRunnerTestJob("recover-recurring")
            recurring.state.runningAtMs = 100
            recurring.state.executionId = "recover-recurring:100:100"
            recurring.state.executionHeartbeatAtMs = 100
            cronSaveStoreAtomic(storePath, CronStoreEnvelope(
                jobs: [one, recurring],
                journal: [
                    CronExecutionJournalEntry("recover-one:100:100", one.id, phase: "reserved", reservedAtMs: 100),
                    CronExecutionJournalEntry("recover-recurring:100:100", recurring.id, phase: "executing", reservedAtMs: 100)
                ]
            ))
            let runner = CronRunner(storePath: storePath, cronEnabled: false)
            runner.start()
            let after = cronLoadStoreOrEmpty(storePath)
            @Expect(after.jobs[0].enabled, false)
            @Expect(after.jobs[0].state.nextRunAtMs, 0)
            @Expect(after.jobs[0].state.lastStatus, "interrupted")
            @Expect(after.jobs[1].enabled, true)
            @Expect(after.jobs[1].state.nextRunAtMs > DateTime.now().toUnixTimeStamp().toMilliseconds(), true)
            @Expect(after.journal[0].terminalKind, "interrupted")
            @Expect(after.journal[1].terminalKind, "interrupted")
        })
    }

    @TestCase
    public func m4B1RunnerStopFencesLateNonCooperativeCompletion(): Unit {
        withCronRunnerTestHome({ storePath =>
            cronSave(storePath, [cronRunnerTestJob("m4-late-fence")])
            let release = AtomicBool(false)
            let entered = AtomicBool(false)
            debugSetCronRunnerBeforeExecuteForTest(Some({ _job =>
                entered.store(true)
                while (!release.load()) { sleep(Duration.millisecond * 2) }
            }))
            debugSetCronRunnerReplyForTest(Some({ _job, _request => "late-success-must-not-commit" }))
            let runner = CronRunner(storePath: storePath)
            @Expect(runner.enqueueJobManual("m4-late-fence", true).get("enqueued").getOrThrow().asBool().getValue(), true)
            let began = DateTime.now().toUnixTimeStamp().toMilliseconds()
            while (!entered.load() && DateTime.now().toUnixTimeStamp().toMilliseconds() - began < 2000) {
                sleep(Duration.millisecond * 2)
            }
            @Expect(entered.load(), true)
            let stopped = runner.stop(drainTimeoutMs: 10)
            @Expect(stopped.timedOut, true)
            @Expect(stopped.activeCount, 1)
            let fenced = cronLoadOrEmpty(storePath)[0]
            @Expect(fenced.state.lastStatus, "interrupted")
            @Expect(fenced.state.executionId, "")
            release.store(true)
            @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
            runner.tick()
            let after = cronLoadOrEmpty(storePath)[0]
            @Expect(after.state.lastStatus, "interrupted")
            @Expect(after.state.executionId, "")
            let runs = readCronRunLogEntriesForJob(storePath, "m4-late-fence")
            @Expect(runs.get("total").getOrThrow().asInt().getValue(), 1)
            @Expect(
                runs.get("entries").getOrThrow().asArray()[0].asObject().get("status").getOrThrow().asString().getValue(),
                "interrupted"
            )
        })
    }

    @TestCase
    public func m4P1RunnerStopTerminatesRealTempScriptChildPidWithoutLateMarker(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let scripts = cronScriptsDir(CliConfig.dotDir)
            Directory.create(scripts, recursive: true)
            let pidFile = scripts.join("m4-child.pid")
            let lateFile = scripts.join("m4-late-marker")
            File.writeTo(
                scripts.join("m4-child.sh"),
                "printf '%s' $$ > '${pidFile.toString()}'\nsleep 30\nprintf late > '${lateFile.toString()}'\n".toArray()
            )
            let job = cronRunnerTestJob("m4-real-child")
            job.scriptPath = "m4-child.sh"
            job.scriptMode = "noAgent"
            job.timeoutMs = 60000
            cronSave(storePath, [job])
            let runner = CronRunner(storePath: storePath)
            @Expect(runner.enqueueJobManual(job.id, true).get("enqueued").getOrThrow().asBool().getValue(), true)
            let began = DateTime.now().toUnixTimeStamp().toMilliseconds()
            while (!exists(pidFile) && DateTime.now().toUnixTimeStamp().toMilliseconds() - began < 2000) {
                sleep(Duration.millisecond * 5)
            }
            @Expect(exists(pidFile), true)
            let childPid = String.fromUtf8(File.readFrom(pidFile)).trimAscii()
            @Expect(childPid.isEmpty(), false)
            let stopped = runner.stop(drainTimeoutMs: 2000)
            @Expect(stopped.drained, true)
            @Expect(stopped.activeCount, 0)
            let probe = launch("/bin/sh", ["-c", "kill -0 ${childPid} >/dev/null 2>&1"])
            @Expect(probe.wait(), 1)
            @Expect(exists(lateFile), false)
            @Expect(runner.activeExecutionCount(), 0)
        })
    }

    @TestCase
    public func m4B2EveryJournalPhaseRecoversMonotonicallyAcrossTwoRestarts(): Unit {
        for (phase in ["reserved", "executing", "result_committed", "delivery_pending", "delivery_settled", "logged"]) {
            withCronRunnerTestHome({ storePath =>
                let job = cronRunnerTestJob("m4-phase-${phase}")
                job.state.lastStatus = if (phase == "reserved" || phase == "executing") { "" } else { "success" }
                if (phase == "reserved" || phase == "executing") {
                    job.state.runningAtMs = 100
                    job.state.executionId = "${job.id}:100:100"
                    job.state.executionHeartbeatAtMs = 100
                }
                if (phase == "logged") {
                    appendCronRunLog(
                        storePath,
                        job.id,
                        "success",
                        100,
                        200,
                        executionId: "${job.id}:100:100"
                    )
                }
                cronSaveStoreAtomic(storePath, CronStoreEnvelope(
                    jobs: [job],
                    journal: [CronExecutionJournalEntry(
                        "${job.id}:100:100",
                        job.id,
                        phase: phase,
                        reservedAtMs: 100,
                        updatedAtMs: 200,
                        runLogRecorded: phase == "logged"
                    )]
                ))
                CronRunner(storePath: storePath, cronEnabled: false).tick()
                CronRunner(storePath: storePath, cronEnabled: false).tick()
                let after = cronLoadStoreOrEmpty(storePath)
                @Expect(after.journal[0].phase, "logged")
                @Expect(after.journal[0].runLogRecorded, true)
                @Expect(readCronRunLogEntriesForJob(storePath, job.id).get("total").getOrThrow().asInt().getValue(), 1)
            })
        }
    }

    @TestCase
    public func m4P2ResultCommittedRunLogCompensationWritesExactlyOnce(): Unit {
        withCronRunnerTestHome({ storePath =>
            let job = cronRunnerTestJob("m4-runlog-compensate")
            job.state.lastStatus = "success"
            cronSaveStoreAtomic(storePath, CronStoreEnvelope(
                jobs: [job],
                journal: [CronExecutionJournalEntry(
                    "m4-runlog-compensate:1:2", job.id,
                    phase: "result_committed", reservedAtMs: 1, updatedAtMs: 2
                )]
            ))
            CronRunner(storePath: storePath, cronEnabled: false).tick()
            @Expect(readCronRunLogEntriesForJob(storePath, job.id).get("total").getOrThrow().asInt().getValue(), 1)
            CronRunner(storePath: storePath, cronEnabled: false).tick()
            @Expect(readCronRunLogEntriesForJob(storePath, job.id).get("total").getOrThrow().asInt().getValue(), 1)
            @Expect(cronLoadStoreOrEmpty(storePath).journal[0].phase, "logged")
        })
    }

    @TestCase
    public func m4N2RunLogFailureKeepsBusinessTerminalAndRemainsRecoverable(): Unit {
        withCronRunnerTestHome({ storePath =>
            let job = cronRunnerTestJob("m4-runlog-failure")
            job.state.lastStatus = "success"
            cronSaveStoreAtomic(storePath, CronStoreEnvelope(
                jobs: [job],
                journal: [CronExecutionJournalEntry(
                    "m4-runlog-failure:1:2", job.id,
                    phase: "result_committed", reservedAtMs: 1, updatedAtMs: 2
                )]
            ))
            debugSetCronRunnerRunLogAppendForTest(Some({ => throw Exception("Authorization: Bearer hidden") }))
            CronRunner(storePath: storePath, cronEnabled: false).tick()
            let failed = cronLoadStoreOrEmpty(storePath)
            @Expect(failed.jobs[0].state.lastStatus, "success")
            @Expect(failed.journal[0].runLogRecorded, false)
            debugSetCronRunnerRunLogAppendForTest(None<() -> Unit>)
            CronRunner(storePath: storePath, cronEnabled: false).tick()
            @Expect(cronLoadStoreOrEmpty(storePath).journal[0].runLogRecorded, true)
        })
    }

    @TestCase
    public func m4N3UnknownDeliveryNeverResendsAndHumanStatusIsNotRawJson(): Unit {
        withCronRunnerTestHome({ storePath =>
            let job = cronRunnerTestJob("m4-delivery-unknown")
            cronSaveStoreAtomic(storePath, CronStoreEnvelope(
                jobs: [job],
                journal: [
                    CronExecutionJournalEntry(
                        "m4-flight", job.id, phase: "delivery_pending",
                        deliveryReceipts: [CronDeliveryReceipt("feishu", status: "in_flight")]
                    ),
                    CronExecutionJournalEntry(
                        "m4-unknown", job.id, phase: "delivery_pending",
                        deliveryReceipts: [CronDeliveryReceipt("telegram", status: "unknown")]
                    )
                ]
            ))
            let sends = JsonObject()
            sends.put("count", JsonInt(0))
            debugSetCronRunnerDeliveryForTest(Some({ =>
                sends.put("count", JsonInt(sends.get("count").getOrThrow().asInt().getValue() + 1))
            }))
            CronRunner(storePath: storePath, cronEnabled: false).tick()
            @Expect(sends.get("count").getOrThrow().asInt().getValue(), 0)
            let after = cronLoadStoreOrEmpty(storePath)
            @Expect(after.journal[0].deliveryReceipts[0].status, "unknown")
            @Expect(after.journal[1].deliveryReceipts[0].status, "unknown")
            let rendered = gatewayFormatCommandOutput(
                "{\"ok\":true,\"method\":\"cron.status\",\"result\":{\"running\":0,\"delivery\":\"unknown\"}}"
            )
            @Expect(rendered.startsWith("{"), false)
            @Expect(rendered.contains("\"delivery\""), false)
        })
    }

    @TestCase
    public func m4LoggingMatrixIsJsonlRedactedRuneSafeAndMetaAllowlisted(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let logPath = storePath.parent.join("m4-cron-events.jsonl")
            let oldLevel = getVariable("METIS_LOG_LEVEL")
            let oldFile = getVariable("METIS_LOG_FILE")
            try {
                setVariable("METIS_LOG_LEVEL", "info")
                setVariable("METIS_LOG_FILE", logPath.toString())
                gatewayLoggingResetForTest()
                let secret = "Authorization: Bearer sk-or-v1-secret /Users/private/secret " +
                    "中文😀中文😀中文😀中文😀"
                for (event in cronLifecycleLogEventNames()) {
                    gatewayLogEventInfo(
                        "gateway/cron",
                        event,
                        "cron lifecycle event",
                        meta: gatewayLogMeta()
                            .string("jobId", "任务-😀")
                            .string("executionHash", "hash-only")
                            .string("status", "cancelled")
                            .int("durationMs", 1)
                            .int("timeoutMs", 2)
                            .int("queueCount", 0)
                            .int("activeCount", 0)
                            .rawString("errorKind", secret)
                            .object()
                    )
                }
                let text = String.fromUtf8(File.readFrom(logPath))
                @Expect(text.contains("sk-or-v1-secret"), false)
                @Expect(text.contains("/Users/private/secret"), false)
                @Expect(text.contains("中文"), true)
                let seen = ArrayList<String>()
                for (line in text.split("\n")) {
                    let trimmed = line.trimAscii()
                    if (trimmed.isEmpty()) { continue }
                    let row = JsonValue.fromStr(trimmed).asObject()
                    @Expect(row.get("subsystem").getOrThrow().asString().getValue(), "gateway/cron")
                    let event = row.get("event").getOrThrow().asString().getValue()
                    @Expect(cronLifecycleLogEventNames().contains(event), true)
                    seen.add(event)
                    for (key in row.getFields().keys()) {
                        let baseField = key == "time" || key == "level" || key == "subsystem" ||
                            key == "event" || key == "message"
                        @Expect(baseField || cronLifecycleLogAllowedMetaFields().contains(key), true)
                    }
                }
                @Expect(seen.size, cronLifecycleLogEventNames().size)
                for (event in cronLifecycleLogEventNames()) {
                    @Expect(seen.contains(event), true)
                }
                for (field in cronLifecycleLogAllowedMetaFields()) {
                    @Expect(text.contains("\"${field}\":"), true)
                }
            } finally {
                match (oldLevel) {
                    case Some(value) => setVariable("METIS_LOG_LEVEL", value)
                    case None => setVariable("METIS_LOG_LEVEL", "")
                }
                match (oldFile) {
                    case Some(value) => setVariable("METIS_LOG_FILE", value)
                    case None => setVariable("METIS_LOG_FILE", "")
                }
                gatewayLoggingResetForTest()
            }
        })
    }

    @TestCase
    public func m2U1TimerAndManualReservationShareExecutionIdentity(): Unit {
        withCronRunnerTestHome({ storePath =>
            cronSave(storePath, [cronRunnerTestJob("race-中文-😀")])
            let release = AtomicBool(false)
            let calls = AtomicBool(false)
            debugSetCronRunnerReplyForTest(Some({ _job, _request =>
                calls.store(true)
                while (!release.load()) { sleep(Duration.millisecond * 2) }
                "完成-😀"
            }))
            let runner = CronRunner(storePath: storePath, maxConcurrentRuns: 2)
            let first = runner.reserveExecution("race-中文-😀", "timer", true, false)
            @Expect(first.status, "reserved")
            @Expect(runner.submitReservedExecution(first), "submitted")
            let competing = runner.reserveExecution("race-中文-😀", "manual", true, false)
            @Expect(competing.status, "already-running")
            @Expect(competing.executionId, first.executionId)
            release.store(true)
            @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
            runner.tick()
            @Expect(calls.load(), true)
            @Expect(readCronRunLogEntriesForJob(storePath, "race-中文-😀").get("total").getOrThrow().asInt().getValue(), 1)
        })
    }

    @TestCase
    public func m2N1ReservationRejectsWithoutLeakingRunningState(): Unit {
        withCronRunnerTestHome({ storePath =>
            let disabled = cronRunnerTestJob("disabled")
            disabled.enabled = false
            let future = cronRunnerTestJob("future")
            future.state.nextRunAtMs = DateTime.now().toUnixTimeStamp().toMilliseconds() + 60000
            let active = cronRunnerTestJob("active")
            cronSave(storePath, [disabled, future, active])
            let runner = CronRunner(storePath: storePath, maxConcurrentRuns: 1)
            @Expect(runner.reserveExecution("missing", "manual", true, false).status, "not-found")
            @Expect(runner.reserveExecution("disabled", "manual", true, false).status, "disabled")
            @Expect(runner.reserveExecution("future", "manual", false, true).status, "not-due")
            for (job in cronLoadOrEmpty(storePath)) {
                @Expect(job.state.runningAtMs, 0)
                @Expect(job.state.executionId, "")
            }
            let release = AtomicBool(false)
            debugSetCronRunnerReplyForTest(Some({ _job, _request =>
                while (!release.load()) { sleep(Duration.millisecond * 2) }
                "done"
            }))
            let occupied = runner.reserveExecution("active", "manual", true, false)
            @Expect(runner.submitReservedExecution(occupied), "submitted")
            @Expect(runner.reserveExecution("future", "manual", true, false).status, "deferred")
            let stillFuture = cronLoadOrEmpty(storePath)[1]
            @Expect(stillFuture.state.runningAtMs, 0)
            @Expect(stillFuture.state.executionId, "")
            release.store(true)
            @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
            runner.tick()
        })
    }

    @TestCase
    public func m2B1CompletionDoesNotRecreateRemovedJob(): Unit {
        withCronRunnerTestHome({ storePath =>
            cronSave(storePath, [cronRunnerTestJob("removed-while-running")])
            let release = AtomicBool(false)
            debugSetCronRunnerReplyForTest(Some({ _job, _request =>
                while (!release.load()) { sleep(Duration.millisecond * 2) }
                "late"
            }))
            let runner = CronRunner(storePath: storePath)
            let reservation = runner.reserveExecution("removed-while-running", "manual", true, false)
            @Expect(runner.submitReservedExecution(reservation), "submitted")
            cronSave(storePath, Array<CronJob>())
            release.store(true)
            @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
            runner.tick()
            @Expect(cronLoadOrEmpty(storePath).size, 0)
        })
    }

    @TestCase
    public func m2B1CompletionPreservesConcurrentEditAndDisable(): Unit {
        withCronRunnerTestHome({ storePath =>
            cronSave(storePath, [cronRunnerTestJob("edited-while-running")])
            let release = AtomicBool(false)
            debugSetCronRunnerReplyForTest(Some({ _job, _request =>
                while (!release.load()) { sleep(Duration.millisecond * 2) }
                "late"
            }))
            let runner = CronRunner(storePath: storePath)
            let reservation = runner.reserveExecution("edited-while-running", "manual", true, false)
            @Expect(runner.submitReservedExecution(reservation), "submitted")
            let edited = cronLoadOrEmpty(storePath)[0]
            edited.prompt = "编辑后的中文😀"
            edited.deliveryChannel = "feishu"
            edited.deliveryTo = "oc_edited"
            edited.enabled = false
            cronSave(storePath, [edited])
            release.store(true)
            @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
            runner.tick()
            let after = cronLoadOrEmpty(storePath)[0]
            @Expect(after.prompt, "编辑后的中文😀")
            @Expect(after.deliveryChannel, "feishu")
            @Expect(after.deliveryTo, "oc_edited")
            @Expect(after.enabled, false)
            @Expect(after.state.executionId, "")
        })
    }

    @TestCase
    public func m3B1N1AgentLateSuccessAtDeadlineCannotDeliverOrOverwriteTimeout(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = cronRunnerTestJob("agent-late-timeout")
            job.timeoutMs = 1
            job.deliveryMode = "webhook"
            job.deliveryTo = "https://example.com/hook"
            cronSave(storePath, [job])
            debugSetCronRunnerReplyForTest(Some({ _job, _request =>
                sleep(Duration.millisecond * 25)
                "late-success-中文🙂"
            }))
            let sends = JsonObject()
            sends.put("count", JsonInt(0))
            setCronWebhookHttpRunnerForTest(Some({ _request: CronWebhookHttpRequest =>
                let count = sends.get("count").getOrThrow().asInt().getValue()
                sends.put("count", JsonInt(count + 1))
                CronWebhookHttpResponse(true, statusCode: 200)
            }))
            try {
                let runner = CronRunner(storePath: storePath)
                let accepted = runner.enqueueJobManual(job.id, true)
                @Expect(accepted.get("enqueued").getOrThrow().asBool().getValue(), true)
                @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
                runner.tick()
                runner.tick()
            } finally {
                setCronWebhookHttpRunnerForTest(None<(CronWebhookHttpRequest) -> CronWebhookHttpResponse>)
            }
            @Expect(sends.get("count").getOrThrow().asInt().getValue(), 0)
            let after = cronLoadStoreOrEmpty(storePath)
            @Expect(after.jobs[0].state.lastStatus, "timeout")
            @Expect(after.journal[0].deliveryArtifactRef, "")
            let runs = readCronRunLogEntriesForJob(storePath, job.id)
            @Expect(runs.get("total").getOrThrow().asInt().getValue(), 1)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "timeout")
            @Expect(row.toJsonString().contains("late-success"), false)
        })
    }

    @TestCase
    public func m2B2RunLogExecutionIdMakesCrashReplayIdempotent(): Unit {
        withCronRunnerTestHome({ storePath =>
            appendCronRunLog(storePath, "journal-job", "success", 1, 2, summary: "中文😀", executionId: "run-唯一-😀")
            // 模拟 jsonl append 成功但 journal marker 尚未落盘，恢复会重放同一 append。
            appendCronRunLog(storePath, "journal-job", "success", 1, 2, summary: "中文😀", executionId: "run-唯一-😀")
            let runs = readCronRunLogEntriesForJob(storePath, "journal-job")
            @Expect(runs.get("total").getOrThrow().asInt().getValue(), 1)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("executionId").getOrThrow().asString().getValue(), "run-唯一-😀")
        })
    }

    @TestCase
    public func m2B2RecoveryAtEveryCommittedCrashPointIsIdempotentAcrossTwoRestarts(): Unit {
        for (phase in ["result_committed", "delivery_pending", "delivery_settled"]) {
            withCronRunnerTestHome({ storePath =>
                let job = cronRunnerTestJob("recover-${phase}")
                job.state.lastStatus = "success"
                job.state.lastRunAtMs = 100
                cronSaveStoreAtomic(
                    storePath,
                    CronStoreEnvelope(
                        jobs: [job],
                        journal: [CronExecutionJournalEntry(
                            "recover-${phase}:1:100",
                            job.id,
                            phase: phase,
                            reservedAtMs: 100,
                            updatedAtMs: 200
                        )]
                    )
                )
                // 两次新 runner 等价于 crash 后连续恢复两次。
                CronRunner(storePath: storePath, cronEnabled: false).tick()
                CronRunner(storePath: storePath, cronEnabled: false).tick()
                let envelope = cronLoadStoreOrEmpty(storePath)
                @Expect(envelope.journal[0].phase, "logged")
                @Expect(envelope.journal[0].runLogRecorded, true)
                @Expect(readCronRunLogEntriesForJob(storePath, job.id).get("total").getOrThrow().asInt().getValue(), 1)
            })
        }
    }

    @TestCase
    public func m3B2N3RecoveryRetriesOnlyNotStartedAndTurnsInFlightUnknown(): Unit {
        withCronRunnerTestHome({ storePath =>
            let job = cronRunnerTestJob("delivery-recover")
            job.deliveryMode = "webhook"
            job.deliveryTo = "https://example.com/hook"
            job.state.lastStatus = "success"
            cronSave(storePath, [job])
            let notStartedId = "delivery-recover:1:100"
            let inFlightId = "delivery-recover:2:200"
            let ref = saveCronDeliveryIntentArtifact(
                storePath,
                CronDeliveryIntentArtifact(
                    notStartedId,
                    job.id,
                    "恢复投递中文🙂",
                    "webhook",
                    "",
                    "https://example.com/hook",
                    "",
                    100,
                    false
                )
            )
            cronSaveStoreAtomic(storePath, CronStoreEnvelope(
                jobs: [job],
                journal: [
                    CronExecutionJournalEntry(
                        notStartedId,
                        job.id,
                        phase: "delivery_pending",
                        reservedAtMs: 100,
                        updatedAtMs: 100,
                        deliveryReceipts: [CronDeliveryReceipt("webhook", status: "not_started")],
                        deliveryArtifactRef: ref
                    ),
                    CronExecutionJournalEntry(
                        inFlightId,
                        job.id,
                        phase: "delivery_pending",
                        reservedAtMs: 200,
                        updatedAtMs: 200,
                        deliveryReceipts: [CronDeliveryReceipt("webhook", status: "in_flight")]
                    )
                ]
            ))
            let calls = JsonObject()
            calls.put("count", JsonInt(0))
            debugSetCronRunnerDeliveryForTest(Some({ =>
                let count = calls.get("count").getOrThrow().asInt().getValue()
                calls.put("count", JsonInt(count + 1))
            }))
            setCronWebhookHttpRunnerForTest(Some({ _request: CronWebhookHttpRequest =>
                CronWebhookHttpResponse(true, statusCode: 200)
            }))
            try {
                CronRunner(storePath: storePath, cronEnabled: false).tick()
                CronRunner(storePath: storePath, cronEnabled: false).tick()
            } finally {
                debugSetCronRunnerDeliveryForTest(None<() -> Unit>)
                setCronWebhookHttpRunnerForTest(None<(CronWebhookHttpRequest) -> CronWebhookHttpResponse>)
            }
            @Expect(calls.get("count").getOrThrow().asInt().getValue(), 1)
            let after = cronLoadStoreOrEmpty(storePath)
            @Expect(after.journal[0].deliveryReceipts[0].status, "succeeded")
            @Expect(after.journal[1].deliveryReceipts[0].status, "unknown")
        })
    }

    @TestCase
    public func m3N3SensitiveArtifactKeepsBusinessSuccessAndNeverSendsOrRetries(): Unit {
        withCronRunnerTestHome({ storePath =>
            let job = cronRunnerTestJob("sensitive-delivery")
            job.deliveryMode = "webhook"
            job.deliveryTo = "https://example.com/hook"
            cronSave(storePath, [job])
            debugSetCronRunnerReplyForTest(Some({ _job, _request =>
                "Authorization: Bearer secret-value"
            }))
            let calls = JsonObject()
            calls.put("count", JsonInt(0))
            debugSetCronRunnerDeliveryForTest(Some({ =>
                let count = calls.get("count").getOrThrow().asInt().getValue()
                calls.put("count", JsonInt(count + 1))
            }))
            try {
                let runner = CronRunner(storePath: storePath)
                let accepted = runner.enqueueJobManual(job.id, true)
                @Expect(accepted.get("enqueued").getOrThrow().asBool().getValue(), true)
                @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
                runner.tick()
                runner.tick()
            } finally {
                debugSetCronRunnerDeliveryForTest(None<() -> Unit>)
            }
            @Expect(calls.get("count").getOrThrow().asInt().getValue(), 0)
            let after = cronLoadStoreOrEmpty(storePath)
            @Expect(after.jobs[0].state.lastStatus, "success")
            @Expect(after.journal[0].deliveryReceipts[0].status, "unknown")
            @Expect(after.journal[0].deliveryReceipts[0].errorCode, "artifact_redacted")
            @Expect(after.journal[0].deliveryArtifactRef, "")
        })
    }

    @TestCase
    public func m3B2SendReturnedAndReceiptPersistedCrashPointsNeverDoubleSend(): Unit {
        for (crashPoint in ["send-returned", "receipt-persisted"]) {
            withCronRunnerTestHome({ storePath =>
                let job = cronRunnerTestJob("delivery-${crashPoint}")
                job.deliveryMode = "webhook"
                job.deliveryTo = "https://example.com/hook"
                cronSave(storePath, [job])
                debugSetCronRunnerReplyForTest(Some({ _job, _request => "正常投递🙂" }))
                let calls = JsonObject()
                calls.put("count", JsonInt(0))
                setCronWebhookHttpRunnerForTest(Some({ _request: CronWebhookHttpRequest =>
                    let count = calls.get("count").getOrThrow().asInt().getValue()
                    calls.put("count", JsonInt(count + 1))
                    CronWebhookHttpResponse(true, statusCode: 200)
                }))
                let crashed = AtomicBool(false)
                debugSetCronRunnerDeliveryStageForTest(Some({ stage =>
                    if (stage == crashPoint && !crashed.load()) {
                        crashed.store(true)
                        throw Exception("simulated-${stage}")
                    }
                }))
                try {
                    let first = CronRunner(storePath: storePath)
                    let _ = first.enqueueJobManual(job.id, true)
                    @Expect(first.waitUntilIdle(timeoutMs: 2000), true)
                    first.tick()
                    debugSetCronRunnerDeliveryStageForTest(None<(String) -> Unit>)
                    CronRunner(storePath: storePath, cronEnabled: false).tick()
                    CronRunner(storePath: storePath, cronEnabled: false).tick()
                } finally {
                    debugSetCronRunnerDeliveryStageForTest(None<(String) -> Unit>)
                    setCronWebhookHttpRunnerForTest(None<(CronWebhookHttpRequest) -> CronWebhookHttpResponse>)
                }
                @Expect(crashed.load(), true)
                @Expect(calls.get("count").getOrThrow().asInt().getValue(), 1)
                let status = cronLoadStoreOrEmpty(storePath).journal[0].deliveryReceipts[0].status
                @Expect(
                    status,
                    if (crashPoint == "send-returned") { "unknown" } else { "succeeded" }
                )
            })
        }
    }

    @TestCase
    public func m2B2ResultCommitFailpointsRetryWithoutDuplicateTerminal(): Unit {
        for (point in ["before-result-commit", "after-result-commit"]) {
            withCronRunnerTestHome({ storePath =>
                cronSave(storePath, [cronRunnerTestJob("commit-${point}")])
                debugSetCronRunnerReplyForTest(Some({ _job, _request => "business-once" }))
                let failed = AtomicBool(false)
                debugSetCronRunnerCommitForTest(Some({ actual =>
                    if (actual == point && !failed.load()) {
                        failed.store(true)
                        throw Exception("simulated crash ${point}")
                    }
                }))
                let runner = CronRunner(storePath: storePath)
                let accepted = runner.enqueueJobManual("commit-${point}", true)
                @Expect(accepted.get("enqueued").getOrThrow().asBool().getValue(), true)
                @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
                runner.tick()
                debugSetCronRunnerCommitForTest(None<(String) -> Unit>)
                runner.tick()
                runner.tick()
                @Expect(failed.load(), true)
                @Expect(cronLoadOrEmpty(storePath)[0].state.lastStatus, "success")
                @Expect(readCronRunLogEntriesForJob(storePath, "commit-${point}").get("total").getOrThrow().asInt().getValue(), 1)
            })
        }
    }

    @TestCase
    public func m2N3WaiterTimeoutDoesNotCancelExecutionOrLeakLock(): Unit {
        withCronRunnerTestHome({ storePath =>
            cronSave(storePath, [cronRunnerTestJob("waiter-timeout")])
            let release = AtomicBool(false)
            debugSetCronRunnerReplyForTest(Some({ _job, _request =>
                while (!release.load()) { sleep(Duration.millisecond * 2) }
                "eventual"
            }))
            let runner = CronRunner(storePath: storePath, maxConcurrentRuns: 2)
            let timedOut = runner.runJobManual("waiter-timeout", true, waitTimeoutMs: 20)
            @Expect(timedOut.get("ok").getOrThrow().asBool().getValue(), false)
            @Expect(timedOut.get("error").getOrThrow().asString().getValue().contains("timed out"), true)
            let duplicate = runner.enqueueJobManual("waiter-timeout", true)
            @Expect(duplicate.get("reason").getOrThrow().asString().getValue(), "already-running")
            release.store(true)
            @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
            runner.tick()
            @Expect(readCronRunLogEntriesForJob(storePath, "waiter-timeout").get("total").getOrThrow().asInt().getValue(), 1)
            // 锁未泄漏：终态后可再次 reserve。
            let again = runner.enqueueJobManual("waiter-timeout", true)
            @Expect(again.get("enqueued").getOrThrow().asBool().getValue(), true)
            @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
            runner.tick()
        })
    }
}

private func cronRunnerTestJob(id: String): CronJob {
    CronJob(
        id,
        "hello cron",
        CronSchedule.every(60000),
        state: CronJobState(nextRunAtMs: 1),
        sessionTarget: "main",
        agentId: "general"
    )
}

// C0 keeps this fixture test-only until the production typed outcome contract
// is introduced by C4/C5.
private class CronRunnerC0OutcomeFixture {
    public let status: String
    public let text: String
    public var attempts: Int64 = 0
    public var successDeliveries: Int64 = 0
    public var failureAlerts: Int64 = 0
    public var runLogStatus: String = ""

    public init(status: String, text!: String = "") {
        this.status = status
        this.text = text
    }

    public func recordAttempt(): Unit { this.attempts += 1 }
    public func recordSuccessDelivery(): Unit { this.successDeliveries += 1 }
    public func recordFailureAlert(): Unit { this.failureAlerts += 1 }
    public func recordRunLog(status: String): Unit { this.runLogStatus = status }
}

@Test
public class CronRunnerC0ContractTest {
    @TestCase
    public func c0U01TypedOutcomeFixtureKeepsStatusAndSideEffectCountersIndependent(): Unit {
        let incomplete = CronRunnerC0OutcomeFixture(
            "incomplete_tool_protocol",
            text: "[\"web_fetch\"]"
        )
        incomplete.recordAttempt()
        incomplete.recordAttempt()
        incomplete.recordFailureAlert()
        incomplete.recordRunLog("error")

        @Expect(incomplete.status, "incomplete_tool_protocol")
        @Expect(incomplete.text, "[\"web_fetch\"]")
        @Expect(incomplete.attempts, 2)
        @Expect(incomplete.successDeliveries, 0)
        @Expect(incomplete.failureAlerts, 1)
        @Expect(incomplete.runLogStatus, "error")
    }
}

private class CronRunnerTestChannelAdapter <: ChannelAdapter {
    private let adapterName: String
    private let messageId: String
    private let failSend: Bool
    private let failMessage: String
    public var sendCount: Int64 = 0
    public var lastAccountId: String = ""
    public var lastPeerId: String = ""
    public var lastText: String = ""
    private let inbound = ArrayList<InboundMessage>()
    private let sentTexts = ArrayList<String>()

    public init(
        adapterName: String,
        messageId!: String = "fake-message",
        failSend!: Bool = false,
        failMessage!: String = "fake send failed"
    ) {
        this.adapterName = adapterName
        this.messageId = messageId
        this.failSend = failSend
        this.failMessage = failMessage
    }

    public prop name: String {
        get() { this.adapterName }
    }

    public func start(): Unit {}

    public func stop(): Unit {}

    public func pullInbound(): Array<InboundMessage> {
        let out = this.inbound.toArray()
        this.inbound.clear()
        out
    }

    public func queueInbound(text: String): Unit {
        let channel = if (this.adapterName == "telegram") {
            ChannelType.Telegram
        } else {
            ChannelType.Feishu
        }
        this.inbound.add(InboundMessage(
            channel,
            "${this.adapterName}-message-${this.inbound.size}",
            "${this.adapterName}-peer",
            "${this.adapterName}-sender",
            ChatType.Direct,
            text,
            true,
            DateTime.now()
        ))
    }

    public func send(message: OutboundMessage): SendResult {
        this.capture(message)
        if (this.failSend) {
            return SendResult.Failed(this.failMessage)
        }
        SendResult.Success
    }

    public func sendWithMessageId(message: OutboundMessage): String {
        this.capture(message)
        if (this.failSend) {
            throw Exception(this.failMessage)
        }
        this.messageId
    }

    private func capture(message: OutboundMessage): Unit {
        this.sendCount += 1
        this.lastAccountId = message.accountId
        this.lastPeerId = message.peerId
        this.lastText = message.text
        this.sentTexts.add(message.text)
    }

    public func sentContains(text: String): Bool {
        for (value in this.sentTexts) {
            if (value == text) {
                return true
            }
        }
        false
    }
}

private func cronRunnerTestGateway(adapter: CronRunnerTestChannelAdapter, channelId: String, accountId: String): GatewayService {
    let service = GatewayService(GatewayRouter(HashMap<String, ChannelPolicyConfig>()))
    service.registerAdapter(adapter, channelId: channelId, accountId: accountId)
    service
}

private func cronRunnerRepeatedText(text: String, count: Int64): String {
    let out = StringBuilder()
    for (_ in 0..count) {
        out.append(text)
    }
    out.toString()
}

private func awaitCronConditionForTest(
    lock: Mutex,
    condition: Condition,
    predicate: () -> Bool,
    timeoutMs: Int64
): Bool {
    let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
    synchronized(lock) {
        while (!predicate()) {
            let remaining = deadline - DateTime.now().toUnixTimeStamp().toMilliseconds()
            if (remaining <= 0) {
                return false
            }
            let _ = condition.wait(timeout: Duration.millisecond * remaining)
        }
        true
    }
}

private class ControllableCronReply {
    private let lock = Mutex()
    private var condition: Condition
    private var started: Bool = false
    private var released: Bool = false
    private var completed: Bool = false
    private let answer: String

    public init(answer: String) {
        synchronized(this.lock) {
            this.condition = this.lock.condition()
        }
        this.answer = answer
    }

    public func reply(): String {
        synchronized(this.lock) {
            this.started = true
            this.condition.notifyAll()
            while (!this.released) {
                this.condition.wait()
            }
            this.completed = true
            this.condition.notifyAll()
        }
        this.answer
    }

    public func awaitStarted(timeoutMs: Int64): Bool {
        awaitCronConditionForTest(this.lock, this.condition, { => this.started }, timeoutMs)
    }

    public func release(): Unit {
        synchronized(this.lock) {
            this.released = true
            this.condition.notifyAll()
        }
    }

    public func isCompleted(): Bool {
        synchronized(this.lock) {
            this.completed
        }
    }
}

private class CronRunnerOneShotFault {
    private var injected = false

    public func failOnce(message: String): Unit {
        if (!this.injected) {
            this.injected = true
            throw Exception(message)
        }
    }
}

private class CronRunnerPersistCounter {
    private let lock = Mutex()
    private var value: Int64 = 0

    public func increment(): Unit {
        synchronized(this.lock) {
            this.value += 1
        }
    }

    public func count(): Int64 {
        synchronized(this.lock) {
            this.value
        }
    }
}

private func cronRunnerInstallFakeTavilyProvider(): Unit {
    setVariable("TAVILY_API_KEY", "fake-tavily-key")
    setGatewayWebProviderResolverForTest(Some({ _capability: String =>
        GatewayWebProviderResolution(providerId: "tavily", available: true, status: "ok", supportsSearch: true)
    }))
    setTavilySearchHttpRunnerForTest(Some({ request: TavilySearchHttpRequest =>
        @Expect(request.body.get("query").getOrThrow().asString().getValue(), "today huawei news")
        TavilySearchHttpResponse(
            200,
            body: "{\"query\":\"today huawei news\",\"answer\":\"brief\",\"response_time\":0.5,\"results\":[{\"title\":\"Fake News A\",\"url\":\"https://example.com/a\",\"content\":\"A current fake summary\",\"score\":0.9},{\"title\":\"Fake News B\",\"url\":\"https://example.com/b\",\"content\":\"B current fake summary\",\"score\":0.8}]}"
        )
    }))
}

private func cronRunnerFakeWebBrief(): String {
    "每日国际新闻简报\n" +
        GatewayWebToolset().webSearchForTest("today huawei news", Some(2), Some("news"), Some("day"))
}

private func cronRunnerInstallFakeDuckDuckGoProvider(): Unit {
    setVariable("TAVILY_API_KEY", "")
    setDuckDuckGoSearchHttpRunnerForTest(Some({ request: DuckDuckGoSearchHttpRequest =>
        @Expect(request.url.contains("q=today+huawei+news"), true)
        let html =
            "<html><body>" +
            "<a class=\"result__a\" href=\"https://example.com/2026-06-23-a\">2026-06-23 source marker 华为新闻 A</a>" +
            "<a class=\"result__snippet\">来自 fake DuckDuckGo 的实时来源 A。</a>" +
            "<a class=\"result__a\" href=\"https://example.com/2026-06-23-b\">2026-06-23 source marker 国际新闻 B</a>" +
            "<a class=\"result__snippet\">来自 fake DuckDuckGo 的实时来源 B。</a>" +
            "</body></html>"
        DuckDuckGoSearchHttpResponse(200, bodyBytes: html.toArray())
    }))
}

private func cronRunnerFakeDuckDuckGoWebBrief(): String {
    "每日国际新闻简报\n" +
        GatewayWebToolset().webSearchForTest("today huawei news", Some(2), Some("news"), Some("day"))
}

@Test
public class CronRunnerTest {
    @TestCase
    public func m0u1FinalizeStateMachinePreservesRecurringAndOneShotContracts(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let recurringSuccess = CronJob(
                "m0-recurring-success",
                "success",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1)
            )
            let recurringError = CronJob(
                "m0-recurring-error",
                "error",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1)
            )
            let oneShotSuccess = CronJob(
                "m0-at-success",
                "success",
                CronSchedule.at(1),
                state: CronJobState(nextRunAtMs: 1)
            )
            let oneShotError = CronJob(
                "m0-at-error",
                "error",
                CronSchedule.at(1),
                state: CronJobState(nextRunAtMs: 1)
            )
            cronSave(storePath, [recurringSuccess, recurringError, oneShotSuccess, oneShotError])
            debugSetCronRunnerReplyForTest(Some({ job: CronJob, _request: GatewaySessionRequest =>
                if (job.prompt == "error") {
                    throw Exception("permanent baseline failure")
                }
                "baseline success"
            }))

            for (jobId in ["m0-recurring-success", "m0-recurring-error", "m0-at-success", "m0-at-error"]) {
                let result = CronRunner.runJobOnceFromStore(None<GatewayService>, storePath, jobId, true)
                @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
                @Expect(result.get("ran").getOrThrow().asBool().getValue(), true)
            }

            let jobs = cronLoadOrEmpty(storePath)
            let byId = HashMap<String, CronJob>()
            for (job in jobs) {
                byId[job.id] = job
            }
            let recurringOk = byId.get("m0-recurring-success").getOrThrow()
            @Expect(recurringOk.enabled, true)
            @Expect(recurringOk.state.lastStatus, "success")
            @Expect(recurringOk.state.consecutiveErrors, 0)
            @Expect(recurringOk.state.runningAtMs, 0)
            @Expect(recurringOk.state.nextRunAtMs > recurringOk.state.lastRunAtMs, true)

            let recurringFailed = byId.get("m0-recurring-error").getOrThrow()
            @Expect(recurringFailed.enabled, true)
            @Expect(recurringFailed.state.lastStatus, "error")
            @Expect(recurringFailed.state.consecutiveErrors, 1)
            @Expect(recurringFailed.state.runningAtMs, 0)
            @Expect(recurringFailed.state.nextRunAtMs > recurringFailed.state.lastRunAtMs, true)

            let atOk = byId.get("m0-at-success").getOrThrow()
            @Expect(atOk.enabled, false)
            @Expect(atOk.state.lastStatus, "success")
            @Expect(atOk.state.nextRunAtMs, 0)
            @Expect(atOk.state.runningAtMs, 0)

            let atFailed = byId.get("m0-at-error").getOrThrow()
            @Expect(atFailed.enabled, false)
            @Expect(atFailed.state.lastStatus, "error")
            @Expect(atFailed.state.consecutiveErrors, 1)
            @Expect(atFailed.state.nextRunAtMs, 0)
            @Expect(atFailed.state.runningAtMs, 0)
        })
    }

    @TestCase
    public func m0b1CorruptUtf8AndMalformedJsonStayInsideTemporaryCronFiles(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            Directory.create(storePath.parent, recursive: true)
            File.writeTo(storePath, Array<Byte>(4, { i => if (i == 1) { 40 } else { 195 } }))
            @Expect(cronLoadOrEmpty(storePath).size, 0)

            File.writeTo(storePath, "{\"version\":1,\"jobs\":[".toArray())
            @Expect(cronLoadOrEmpty(storePath).size, 0)

            let recovery = CronJob(
                "m0-recovery-中文-🙂",
                "恢复任务🙂",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1)
            )
            cronSave(storePath, [recovery])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "恢复成功🙂"
            }))
            let result = CronRunner.runJobOnceFromStore(None<GatewayService>, storePath, recovery.id, true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(cronLoadOrEmpty(storePath)[0].state.lastStatus, "success")

            let runLogPath = cronRunLogPathFromStore(storePath, recovery.id)
            File.writeTo(runLogPath, Array<Byte>(4, { i => if (i == 2) { 40 } else { 195 } }))
            let invalidUtf8Runs = readCronRunLogEntriesForJob(storePath, recovery.id, limit: 10)
            @Expect(invalidUtf8Runs.get("total").getOrThrow().asInt().getValue(), 0)

            File.writeTo(runLogPath, "{\"status\":\"ok\"\nnot-json\n".toArray())
            let malformedRuns = readCronRunLogEntriesForJob(storePath, recovery.id, limit: 10)
            @Expect(malformedRuns.get("total").getOrThrow().asInt().getValue(), 0)
        })
    }

    @TestCase
    public func m0p1DueTickReturnsBeforeControlledUtf8ReplyThenDeliversOnce(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let answer = cronRunnerRepeatedText("仓颉社区🙂", 1200)
            let controlled = ControllableCronReply(answer)
            let job = CronJob(
                "m0-controlled-due",
                "生成社区通知",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "feishu",
                deliveryTo: "fake-chat",
                deliveryMode: "announce",
                deliveryAccountId: "fake-tenant"
            )
            cronSave(storePath, [job])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                controlled.reply()
            }))
            let adapter = CronRunnerTestChannelAdapter("feishu", messageId: "fake-message")
            let service = cronRunnerTestGateway(adapter, "feishu", "fake-tenant")
            let runner = CronRunner(gatewayOpt: Some(service), storePath: storePath, cronEnabled: true)

            let tickFuture = spawn {
                runner.tick(nowOverride: Some<Int64>(2000))
            }
            @Expect(controlled.awaitStarted(2000), true)
            @Expect(controlled.isCompleted(), false)
            @Expect(adapter.sendCount, 0)
            tickFuture.get()

            controlled.release()
            @Expect(runner.waitUntilIdle(), true)
            runner.tick()

            @Expect(controlled.isCompleted(), true)
            @Expect(adapter.sendCount, 1)
            @Expect(adapter.lastText.contains("仓颉社区🙂"), true)
            @Expect(adapter.lastText.size > 4000, true)
            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs[0].state.lastStatus, "success")
            let runs = readCronRunLogEntriesForJob(storePath, job.id, limit: 10)
            @Expect(runs.get("total").getOrThrow().asInt().getValue(), 1)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "ok")
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "delivered")
            @Expect(row.get("summary").getOrThrow().asString().getValue(), answer)
        })
    }

    @TestCase
    public func m0n1DeliveryAndRunLogFailuresPreserveHistoricalIsolation(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let strict = CronJob(
                "m0-strict",
                "strict",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "feishu",
                deliveryTo: "fake-chat",
                deliveryMode: "announce",
                deliveryAccountId: "fake-tenant"
            )
            let bestEffort = CronJob(
                "m0-best-effort",
                "best-effort",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "feishu",
                deliveryTo: "fake-chat",
                deliveryMode: "announce",
                deliveryAccountId: "fake-tenant",
                bestEffortDeliver: true
            )
            let logFailure = cronRunnerTestJob("m0-log-failure")
            cronSave(storePath, [strict, bestEffort, logFailure])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "业务结果🙂"
            }))
            let adapter = CronRunnerTestChannelAdapter(
                "feishu",
                failSend: true,
                failMessage: "send failed Authorization: Bearer secret-m0 token=private-m0"
            )
            let service = cronRunnerTestGateway(adapter, "feishu", "fake-tenant")

            let _strictResult = CronRunner.runJobOnceFromStore(Some(service), storePath, strict.id, true)
            let _bestEffortResult = CronRunner.runJobOnceFromStore(Some(service), storePath, bestEffort.id, true)
            debugSetCronRunnerRunLogAppendForTest(Some({ =>
                throw Exception("run-log-unavailable")
            }))
            let _logResult = CronRunner.runJobOnceFromStore(Some(service), storePath, logFailure.id, true)

            let jobs = cronLoadOrEmpty(storePath)
            let byId = HashMap<String, CronJob>()
            for (job in jobs) {
                byId[job.id] = job
            }
            let strictAfter = byId.get(strict.id).getOrThrow()
            @Expect(strictAfter.state.lastStatus, "error")
            @Expect(strictAfter.state.lastError.contains("secret-m0"), false)
            @Expect(strictAfter.state.lastError.contains("private-m0"), false)
            @Expect(strictAfter.state.lastError.contains("redacted"), true)

            let bestEffortAfter = byId.get(bestEffort.id).getOrThrow()
            @Expect(bestEffortAfter.state.lastStatus, "success")
            @Expect(bestEffortAfter.state.lastError, "")

            let logFailureAfter = byId.get(logFailure.id).getOrThrow()
            @Expect(logFailureAfter.state.lastStatus, "success")
            @Expect(logFailureAfter.state.lastError, "")
            let logFailureRuns = readCronRunLogEntriesForJob(storePath, logFailure.id, limit: 10)
            @Expect(logFailureRuns.get("total").getOrThrow().asInt().getValue(), 0)
        })
    }

    @TestCase
    public func cronBuildSessionRequestPreservesUnifiedIngressSemantics(): Unit {
        let job = CronJob(
            "job-1",
            "hello cron",
            CronSchedule.every(60000),
            sessionTarget: "main",
            agentId: "general"
        )
        let request = cronBuildSessionRequest(job, 12345)
        @Expect(gatewayIngressSourceLabel(request.source), "cron")
        @Expect(request.channelName, "cron")
        @Expect(request.agentId, "general")
        @Expect(request.text, "hello cron")
        @Expect(request.sessionHint.contains("cron"), true)
    }

    @TestCase
    public func cronRunParserAcceptsLegacyDueOnlyFlag(): Unit {
        let (jobIdOpt, dueOnly) = debugGatewayParseCronRunJobIdAndDueForTest([
            "cron", "run", "legacy-job", "--due-only"
        ])
        @Expect(jobIdOpt.getOrThrow(), "legacy-job")
        @Expect(dueOnly, true)
    }

    @TestCase
    public func runJobManualFatalBeforeExecuteFinalizesErrorAndRunLog(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            cronSave(storePath, [cronRunnerTestJob("fatal-before-execute")])
            debugSetCronRunnerBeforeExecuteForTest(Some({ _job: CronJob =>
                throw Exception("fatal-p2")
            }))

            let result = CronRunner.runJobOnceFromStore(
                None<GatewayService>,
                storePath,
                "fatal-before-execute",
                true
            )
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("ran").getOrThrow().asBool().getValue(), true)

            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs.size, 1)
            @Expect(jobs[0].state.lastStatus, "error")
            @Expect(jobs[0].state.runningAtMs, 0)
            @Expect(jobs[0].state.lastError.contains("fatal-p2"), true)

            let runs = readCronRunLogEntriesForJob(storePath, "fatal-before-execute", limit: 10)
            @Expect(runs.get("total").getOrThrow().asInt().getValue(), 1)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "error")
            @Expect(row.get("summary").getOrThrow().asString().getValue().contains("fatal-p2"), true)
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "not-requested")
        })
    }

    @TestCase
    public func runJobManualBlocksUnsafeStorePromptBeforeAgentExecution(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "runtime-blocked",
                "system prompt override",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                sessionTarget: "main",
                agentId: "general"
            )
            cronSave(storePath, [job])
            let calls = JsonObject()
            debugSetCronRunnerBeforeExecuteForTest(Some({ _job: CronJob =>
                calls.put("before", JsonString("called"))
            }))
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                calls.put("reply", JsonString("called"))
                "should-not-run"
            }))

            let result = CronRunner.runJobOnceFromStore(
                None<GatewayService>,
                storePath,
                "runtime-blocked",
                true
            )

            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("ran").getOrThrow().asBool().getValue(), true)
            @Expect(calls.get("before").isNone(), true)
            @Expect(calls.get("reply").isNone(), true)

            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs.size, 1)
            @Expect(jobs[0].state.lastStatus, "error")
            @Expect(jobs[0].state.runningAtMs, 0)
            @Expect(jobs[0].state.lastError, "cron_prompt_blocked:sys_prompt_override")

            let runs = readCronRunLogEntriesForJob(storePath, "runtime-blocked", limit: 10)
            @Expect(runs.get("total").getOrThrow().asInt().getValue(), 1)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "error")
            @Expect(row.get("summary").getOrThrow().asString().getValue(), "cron_prompt_blocked:sys_prompt_override")
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "not-requested")
        })
    }

    @TestCase
    public func runLogAppendFailureDoesNotRewriteBusinessState(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            cronSave(storePath, [cronRunnerTestJob("run-log-fails")])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "ok answer"
            }))
            debugSetCronRunnerRunLogAppendForTest(Some({ =>
                throw Exception("run-log-offline")
            }))

            let result = CronRunner.runJobOnceFromStore(
                None<GatewayService>,
                storePath,
                "run-log-fails",
                true
            )
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("ran").getOrThrow().asBool().getValue(), true)

            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs.size, 1)
            @Expect(jobs[0].state.lastStatus, "success")
            @Expect(jobs[0].state.runningAtMs, 0)
            @Expect(jobs[0].state.lastError, "")

            let runs = readCronRunLogEntriesForJob(storePath, "run-log-fails", limit: 10)
            @Expect(runs.get("total").getOrThrow().asInt().getValue(), 0)
        })
    }

    @TestCase
    public func tickAndManualRunUseSameRunLogShape(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            cronSave(storePath, [cronRunnerTestJob("shared-runner")])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "ok answer"
            }))

            let runner = CronRunner(gatewayOpt: None<GatewayService>, storePath: storePath, cronEnabled: true)
            runner.tick(nowOverride: Some<Int64>(2000))
            @Expect(runner.waitUntilIdle(), true)
            runner.tick()
            let result = runner.runJobManual("shared-runner", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("ran").getOrThrow().asBool().getValue(), true)

            let runs = readCronRunLogEntriesForJob(storePath, "shared-runner", limit: 10)
            @Expect(runs.get("total").getOrThrow().asInt().getValue(), 2)
            let entries = runs.get("entries").getOrThrow().asArray()
            var idx: Int64 = 0
            while (idx < entries.size()) {
                let row = entries[idx].asObject()
                @Expect(row.get("action").getOrThrow().asString().getValue(), "finished")
                @Expect(row.get("status").getOrThrow().asString().getValue(), "ok")
                @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "not-requested")
                @Expect(row.get("summary").getOrThrow().asString().getValue(), "ok answer")
                @Expect(row.get("durationMs").getOrThrow().asInt().getValue() >= 0, true)
                idx += 1
            }
        })
    }

    @TestCase
    public func noAgentScriptUsesStdoutAsAnswerAndSkipsAgent(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            Directory.create(cronScriptsDir(CliConfig.dotDir), recursive: true)
            File.writeTo(cronScriptsDir(CliConfig.dotDir).join("daily.sh"), "printf '脚本结果 🙂'\n".toArray())
            let job = CronJob(
                "script-no-agent",
                "agent should not run",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "telegram",
                deliveryTo: "chat-1",
                deliveryMode: "announce",
                scriptPath: "daily.sh",
                scriptMode: "noAgent"
            )
            cronSave(storePath, [job])
            let driftHome = CliConfig.dotDir.join("drift-home").toString()
            Directory.create(driftHome, recursive: true)
            setVariable("METIS_HOME", driftHome)
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            let calls = JsonObject()
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                calls.put("agent", JsonString("called"))
                "agent answer"
            }))
            let adapter = CronRunnerTestChannelAdapter("telegram")
            let gateway = cronRunnerTestGateway(adapter, "telegram", "")

            let result = CronRunner.runJobOnceFromStore(Some(gateway), storePath, "script-no-agent", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(calls.get("agent").isNone(), true)
            @Expect(adapter.sendCount, 1)
            @Expect(adapter.lastText.contains("脚本结果"), true)
            @Expect(adapter.lastText.contains("🙂"), true)

            let runs = readCronRunLogEntriesForJob(storePath, "script-no-agent", limit: 10)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "ok")
            @Expect(row.get("summary").getOrThrow().asString().getValue().contains("脚本结果"), true)
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "delivered")
        })
    }

    @TestCase
    public func injectScriptOutputBuildsEffectivePromptWithoutMutatingJobPrompt(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            Directory.create(cronScriptsDir(CliConfig.dotDir), recursive: true)
            File.writeTo(cronScriptsDir(CliConfig.dotDir).join("inject.sh"), "printf '事实: 今日无事故'\n".toArray())
            let job = CronJob(
                "script-inject",
                "请总结脚本内容",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                scriptPath: "inject.sh",
                scriptMode: "inject"
            )
            cronSave(storePath, [job])
            let capture = JsonObject()
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, request: GatewaySessionRequest =>
                capture.put("text", JsonString(request.text))
                "agent ok"
            }))

            let result = CronRunner.runJobOnceFromStore(None<GatewayService>, storePath, "script-inject", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            let text = capture.get("text").getOrThrow().asString().getValue()
            @Expect(text.contains("## Script Output"), true)
            @Expect(text.contains("事实: 今日无事故"), true)
            @Expect(text.contains("## Cron Prompt"), true)
            @Expect(text.contains("请总结脚本内容"), true)

            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs.size, 1)
            @Expect(jobs[0].prompt, "请总结脚本内容")
            @Expect(jobs[0].scriptMode, "inject")
        })
    }

    @TestCase
    public func emptyNoAgentScriptIsSilentSuccessAndDoesNotDeliver(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            Directory.create(cronScriptsDir(CliConfig.dotDir), recursive: true)
            File.writeTo(cronScriptsDir(CliConfig.dotDir).join("empty.sh"), "exit 0\n".toArray())
            let job = CronJob(
                "script-empty",
                "agent should not run",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "telegram",
                deliveryTo: "chat-1",
                deliveryMode: "announce",
                scriptPath: "empty.sh",
                scriptMode: "noAgent"
            )
            cronSave(storePath, [job])
            let adapter = CronRunnerTestChannelAdapter("telegram")
            let gateway = cronRunnerTestGateway(adapter, "telegram", "")

            let result = CronRunner.runJobOnceFromStore(Some(gateway), storePath, "script-empty", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(adapter.sendCount, 0)
            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs[0].state.lastStatus, "success")

            let runs = readCronRunLogEntriesForJob(storePath, "script-empty", limit: 10)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "ok")
            let summary = row.get("summary").getOrThrow().asString().getValue()
            @Expect(summary.contains("[\"web_fetch\"]"), false)
            @Expect(summary.contains("模型返回了工具调用协议"), false)
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "not-requested")
        })
    }

    @TestCase
    public func scriptFailureFinalizesErrorAndRunLogDiagnostic(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            Directory.create(cronScriptsDir(CliConfig.dotDir), recursive: true)
            File.writeTo(cronScriptsDir(CliConfig.dotDir).join("bad.txt"), "printf should-not-run\n".toArray())
            let job = CronJob(
                "script-fails",
                "agent should not run",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                scriptPath: "bad.txt",
                scriptMode: "inject"
            )
            cronSave(storePath, [job])

            let result = CronRunner.runJobOnceFromStore(None<GatewayService>, storePath, "script-fails", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs[0].state.lastStatus, "error")
            @Expect(jobs[0].state.lastError.contains("cron_script_unsupported_extension"), true)
            @Expect(jobs[0].state.runningAtMs, 0)

            let runs = readCronRunLogEntriesForJob(storePath, "script-fails", limit: 10)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "error")
            @Expect(row.get("diagnosticCode").getOrThrow().asString().getValue(), "cron_script_unsupported_extension")
            @Expect(row.get("summary").getOrThrow().asString().getValue().contains("cron_script_unsupported_extension"), true)
        })
    }

    @TestCase
    public func m1B2P2FullSlotDoesNotReserveSiblingAndCursorEventuallyDispatchesIt(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let blocked = ControllableCronReply("first done")
            let jobs = ArrayList<CronJob>()
            jobs.add(CronJob(
                "a-first",
                "hello cron",
                CronSchedule.at(1),
                state: CronJobState(nextRunAtMs: 1)
            ))
            for (id in [
                "b-sibling", "c-sibling", "d-sibling", "e-sibling", "f-sibling",
                "g-sibling", "h-sibling", "i-sibling", "j-sibling", "k-sibling"
            ]) {
                jobs.add(CronJob(
                    id,
                    "hello cron",
                    CronSchedule.at(1),
                    state: CronJobState(nextRunAtMs: 1)
                ))
            }
            cronSave(storePath, jobs.toArray())
            let persistCount = CronRunnerPersistCounter()
            debugSetCronRunnerReservePersistForTest(Some({ => persistCount.increment() }))
            debugSetCronRunnerReplyForTest(Some({ job: CronJob, _request: GatewaySessionRequest =>
                if (job.id == "a-first") { blocked.reply() } else { "second done" }
            }))
            let runner = CronRunner(
                gatewayOpt: None<GatewayService>,
                storePath: storePath,
                cronEnabled: true,
                maxConcurrentRuns: 1
            )
            runner.tick(nowOverride: Some<Int64>(2000))
            @Expect(blocked.awaitStarted(2000), true)
            var repeated: Int64 = 0
            while (repeated < 100) {
                runner.tick(nowOverride: Some<Int64>(2000))
                repeated += 1
            }
            let whileFull = cronLoadOrEmpty(storePath)
            @Expect(whileFull[0].state.executionId.isEmpty(), false)
            for (idx in 1..whileFull.size) {
                @Expect(whileFull[idx].state.executionId, "")
            }
            @Expect(persistCount.count(), 1)

            blocked.release()
            let dispatchNow = DateTime.now().toUnixTimeStamp().toMilliseconds() + 60000
            var completed: Int64 = 0
            while (completed < 11) {
                @Expect(runner.waitUntilIdle(), true)
                runner.tick(nowOverride: Some<Int64>(dispatchNow))
                completed += 1
            }
            let after = cronLoadOrEmpty(storePath)
            @Expect(persistCount.count(), 11)
            for (job in after) {
                @Expect(job.state.lastStatus, "success")
                @Expect(job.state.executionId, "")
            }
        })
    }

    @TestCase
    public func m1P1BlockingCronDoesNotStarveFeishuOrTelegramProcessOnce(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let blocked = ControllableCronReply("cron completed")
            cronSave(storePath, [cronRunnerTestJob("m1-p1-blocked")])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                blocked.reply()
            }))
            setGatewayAgentBridgeReplyRunnerForTest(Some({
                _sessionKey: String,
                prompt: String,
                channelName: String,
                _agentId: String,
                _streamingEnabled: Bool,
                _streamChunkHook: Option<(String) -> Unit> =>
                    "${channelName} reply: ${prompt}"
            }))

            let feishu = CronRunnerTestChannelAdapter("feishu")
            let telegram = CronRunnerTestChannelAdapter("telegram")
            let service = GatewayService(GatewayRouter(HashMap<String, ChannelPolicyConfig>()))
            service.registerAdapter(feishu, channelId: "feishu", accountId: "tenant-p1")
            service.registerAdapter(telegram, channelId: "telegram", accountId: "telegram-p1")
            service.start()
            try {
                let runner = CronRunner(
                    gatewayOpt: Some(service),
                    storePath: storePath,
                    cronEnabled: true
                )
                runner.tick(nowOverride: Some<Int64>(2000))
                @Expect(blocked.awaitStarted(2000), true)
                @Expect(blocked.isCompleted(), false)

                feishu.queueInbound("飞书消息🙂")
                telegram.queueInbound("Telegram message")
                service.processOnce()

                @Expect(feishu.sendCount, 1)
                @Expect(feishu.lastText, "feishu reply: 飞书消息🙂")
                @Expect(telegram.sendCount >= 1, true)
                @Expect(telegram.sentContains("telegram reply: Telegram message"), true)
                @Expect(blocked.isCompleted(), false)

                blocked.release()
                @Expect(runner.waitUntilIdle(), true)
                runner.tick()
                @Expect(cronLoadOrEmpty(storePath)[0].state.lastStatus, "success")
            } finally {
                blocked.release()
                service.stop()
            }
        })
    }

    @TestCase
    public func m1N2ReservePersistFailureReleasesPermitAndDispatchesSibling(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            cronSave(storePath, [
                cronRunnerTestJob("a-reserve-fails"),
                cronRunnerTestJob("b-reserve-sibling")
            ])
            let fault = CronRunnerOneShotFault()
            debugSetCronRunnerReservePersistForTest(Some({ =>
                fault.failOnce("fake reserve persist failure")
            }))
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "sibling completed"
            }))
            let runner = CronRunner(storePath: storePath, maxConcurrentRuns: 1)

            runner.tick(nowOverride: Some<Int64>(2000))
            let reserved = cronLoadStoreOrEmpty(storePath)
            @Expect(reserved.jobs[0].state.executionId, "")
            @Expect(reserved.jobs[1].state.executionId.isEmpty(), false)
            @Expect(reserved.journal.size, 1)
            @Expect(reserved.journal[0].jobId, "b-reserve-sibling")

            @Expect(runner.waitUntilIdle(), true)
            runner.stopAccepting()
            runner.tick()
            let after = cronLoadStoreOrEmpty(storePath)
            @Expect(runner.activeExecutionCount(), 0)
            @Expect(after.jobs[0].state.executionId, "")
            @Expect(after.jobs[1].state.executionId, "")
            @Expect(after.jobs[1].state.lastStatus, "success")
            for (entry in after.journal) {
                @Expect(entry.jobId == "a-reserve-fails", false)
            }
        })
    }

    @TestCase
    public func m1N2SubmitFailureRollsBackReservationAndDispatchesSibling(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            cronSave(storePath, [
                cronRunnerTestJob("a-submit-fails"),
                cronRunnerTestJob("b-submit-sibling")
            ])
            let fault = CronRunnerOneShotFault()
            debugSetCronRunnerSubmitForTest(Some({ =>
                fault.failOnce("fake submit failure")
            }))
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "sibling completed"
            }))
            let runner = CronRunner(storePath: storePath, maxConcurrentRuns: 1)

            runner.tick(nowOverride: Some<Int64>(2000))
            let reserved = cronLoadStoreOrEmpty(storePath)
            @Expect(reserved.jobs[0].state.executionId, "")
            @Expect(reserved.jobs[1].state.executionId.isEmpty(), false)
            @Expect(reserved.journal.size, 1)
            @Expect(reserved.journal[0].jobId, "b-submit-sibling")

            @Expect(runner.waitUntilIdle(), true)
            runner.stopAccepting()
            runner.tick()
            let after = cronLoadStoreOrEmpty(storePath)
            @Expect(runner.activeExecutionCount(), 0)
            @Expect(after.jobs[0].state.executionId, "")
            @Expect(after.jobs[1].state.executionId, "")
            @Expect(after.jobs[1].state.lastStatus, "success")
            for (entry in after.journal) {
                @Expect(entry.jobId == "a-submit-fails", false)
            }
        })
    }

    @TestCase
    public func m1ScheduledStrictDeliveryFailureMergesErrorWhileBestEffortStaysSuccess(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let strict = CronJob(
                "a-strict-scheduled",
                "strict",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "feishu",
                deliveryTo: "fake-chat",
                deliveryMode: "announce",
                deliveryAccountId: "fake-tenant"
            )
            let bestEffort = CronJob(
                "b-best-effort-scheduled",
                "best effort",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "feishu",
                deliveryTo: "fake-chat",
                deliveryMode: "announce",
                deliveryAccountId: "fake-tenant",
                bestEffortDeliver: true
            )
            cronSave(storePath, [strict, bestEffort])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "business success"
            }))
            let adapter = CronRunnerTestChannelAdapter("feishu", failSend: true)
            let service = cronRunnerTestGateway(adapter, "feishu", "fake-tenant")
            let runner = CronRunner(gatewayOpt: Some(service), storePath: storePath)

            runner.tick(nowOverride: Some<Int64>(2000))
            @Expect(runner.waitUntilIdle(), true)
            runner.tick()
            @Expect(runner.waitUntilIdle(), true)
            runner.stopAccepting()
            runner.tick()

            let byId = HashMap<String, CronJob>()
            for (job in cronLoadOrEmpty(storePath)) {
                byId[job.id] = job
            }
            let strictAfter = byId.get(strict.id).getOrThrow()
            @Expect(strictAfter.state.lastStatus, "error")
            @Expect(strictAfter.state.lastError.contains("announce delivery failed"), true)
            let bestEffortAfter = byId.get(bestEffort.id).getOrThrow()
            @Expect(bestEffortAfter.state.lastStatus, "success")
            @Expect(bestEffortAfter.state.lastError, "")

            let strictRun = readCronRunLogEntriesForJob(storePath, strict.id, limit: 10)
                .get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(strictRun.get("status").getOrThrow().asString().getValue(), "error")
            @Expect(strictRun.get("deliveryStatus").getOrThrow().asString().getValue(), "not-delivered")
            let bestRun = readCronRunLogEntriesForJob(storePath, bestEffort.id, limit: 10)
                .get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(bestRun.get("status").getOrThrow().asString().getValue(), "ok")
            @Expect(bestRun.get("deliveryStatus").getOrThrow().asString().getValue(), "not-delivered")
        })
    }

    @TestCase
    public func m1RunLogAppendFailureKeepsJournalRetryableAndUnlogged(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = cronRunnerTestJob("m1-runlog-retryable")
            cronSave(storePath, [job])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "business success"
            }))
            debugSetCronRunnerRunLogAppendForTest(Some({ =>
                throw Exception("run-log-temporarily-unavailable")
            }))
            let runner = CronRunner(storePath: storePath)

            runner.tick(nowOverride: Some<Int64>(2000))
            @Expect(runner.waitUntilIdle(), true)
            runner.stopAccepting()
            runner.tick()

            let envelope = cronLoadStoreOrEmpty(storePath)
            @Expect(envelope.jobs[0].state.lastStatus, "success")
            @Expect(envelope.journal.size, 1)
            @Expect(envelope.journal[0].runLogRecorded, false)
            @Expect(envelope.journal[0].phase, "delivery_settled")
            @Expect(
                readCronRunLogEntriesForJob(storePath, job.id, limit: 10)
                    .get("total").getOrThrow().asInt().getValue(),
                0
            )
        })
    }

    @TestCase
    public func m1DeliveryExceptionStillSettlesReceiptAndAppendsRunLog(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "m1-delivery-throws",
                "delivery throws",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "feishu",
                deliveryTo: "fake-chat",
                deliveryMode: "announce",
                deliveryAccountId: "fake-tenant",
                bestEffortDeliver: true
            )
            cronSave(storePath, [job])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "business success"
            }))
            debugSetCronRunnerDeliveryForTest(Some({ =>
                throw Exception("unexpected delivery exception")
            }))
            let runner = CronRunner(storePath: storePath)

            runner.tick(nowOverride: Some<Int64>(2000))
            @Expect(runner.waitUntilIdle(), true)
            runner.stopAccepting()
            runner.tick()

            let envelope = cronLoadStoreOrEmpty(storePath)
            @Expect(envelope.jobs[0].state.lastStatus, "success")
            @Expect(envelope.journal[0].phase, "logged")
            @Expect(envelope.journal[0].runLogRecorded, true)
            @Expect(envelope.journal[0].deliveryReceipts[0].status, "failed")
            let runs = readCronRunLogEntriesForJob(storePath, job.id, limit: 10)
            @Expect(runs.get("total").getOrThrow().asInt().getValue(), 1)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "ok")
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "not-delivered")
            @Expect(
                row.get("deliveryError").getOrThrow().asString().getValue()
                    .contains("unexpected delivery exception"),
                true
            )
        })
    }

}

@Test
public class CronRunnerDeliveryTest {
    @TestCase
    public func cronExecutionOptionsConvertTimeoutAndTurnContextOverrides(): Unit {
        let job = CronJob(
            "options",
            "hello cron",
            CronSchedule.every(60000),
            timeoutMs: 2501,
            modelOverride: "openai:gpt-4o-mini",
            thinkingLevel: "high",
            lightContext: true,
            bestEffortDeliver: true
        )
        let options = cronBuildSessionExecutionOptions(job)
        @Expect(options.timeoutMs, 2501)
        @Expect(options.timeoutSeconds, 3)
        @Expect(options.modelOverride, "openai:gpt-4o-mini")
        @Expect(options.thinkingLevel, "high")
        @Expect(options.lightContext, true)
        @Expect(options.bestEffortDeliver, true)

        let base = GatewayTurnContext(
            "general",
            workspaceDir: "/tmp/metis-cron-options",
            sessionKey: "agent:general:main",
            channelName: "cron",
            agentScope: JsonObject()
        )
        let overridden = cronTurnContextWithExecutionOptions(base, options)
        @Expect(overridden.agentId, "general")
        @Expect(overridden.workspaceDir, "/tmp/metis-cron-options")
        @Expect(overridden.modelRefOverride, "openai:gpt-4o-mini")
        @Expect(overridden.thinkingLevel, "high")
        @Expect(overridden.lightContext, true)
    }

    @TestCase
    public func cronBuildSessionRequestCarriesAnnounceDeliveryTarget(): Unit {
        let job = CronJob(
            "job-deliver",
            "hello cron",
            CronSchedule.every(60000),
            deliveryChannel: "feishu",
            deliveryTo: "chat-1",
            deliveryAccountId: "tenant-a",
            deliveryMode: "announce",
            toolExecMode: "allowlist",
            toolExecAllowlist: ["curl"]
        )
        let request = cronBuildSessionRequest(job, 12345)
        @Expect(request.deliver, true)
        @Expect(request.replyChannel, "feishu")
        @Expect(request.replyTo, "chat-1")
        @Expect(request.replyAccountId, "tenant-a")
        @Expect(request.cronJobId, "job-deliver")
        @Expect(request.toolExecMode, "allowlist")
        @Expect(request.toolExecAllowlist.size, 1)
        @Expect(request.toolExecAllowlist[0], "curl")
    }

    @TestCase
    public func cronAnnounceDeliveryDoesNotUseSessionLayerDeliverForBridgeReply(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "single-delivery",
                "hello cron",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "feishu",
                deliveryTo: "chat-1",
                deliveryAnnounce: true,
                deliveryMode: "announce",
                deliveryAccountId: "tenant-a"
            )
            cronSave(storePath, [job])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "ok answer"
            }))
            let adapter = CronRunnerTestChannelAdapter("feishu", messageId: "msg-1")
            let service = cronRunnerTestGateway(adapter, "feishu", "tenant-a")

            let result = CronRunner.runJobOnceFromStore(Some(service), storePath, "single-delivery", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("ran").getOrThrow().asBool().getValue(), true)
            @Expect(adapter.sendCount, 1)

            let runs = readCronRunLogEntriesForJob(storePath, "single-delivery", limit: 10)
            @Expect(runs.get("total").getOrThrow().asInt().getValue(), 1)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "delivered")
        })
    }

    @TestCase
    public func deliveryUsesConfiguredAccountIdAndRecordsDelivered(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "delivery-account",
                "hello cron",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "feishu",
                deliveryTo: "chat-1",
                deliveryAnnounce: true,
                deliveryMode: "announce",
                deliveryAccountId: "tenant-a"
            )
            cronSave(storePath, [job])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "ok answer"
            }))
            let adapter = CronRunnerTestChannelAdapter("feishu", messageId: "msg-1")
            let service = cronRunnerTestGateway(adapter, "feishu", "tenant-a")

            let result = CronRunner.runJobOnceFromStore(Some(service), storePath, "delivery-account", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(adapter.sendCount, 1)
            @Expect(adapter.lastAccountId, "tenant-a")
            @Expect(adapter.lastPeerId, "chat-1")
            @Expect(adapter.lastText.contains("[cron:delivery-account]"), true)

            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs[0].state.lastStatus, "success")
            let runs = readCronRunLogEntriesForJob(storePath, "delivery-account", limit: 10)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "delivered")
        })
    }

    @TestCase
    public func deliveryFailureBestEffortKeepsAgentSuccess(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "best-effort-delivery",
                "hello cron",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "feishu",
                deliveryTo: "chat-1",
                deliveryMode: "announce",
                deliveryAccountId: "tenant-a",
                bestEffortDeliver: true
            )
            cronSave(storePath, [job])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "ok answer"
            }))
            let adapter = CronRunnerTestChannelAdapter("feishu", failSend: true)
            let service = cronRunnerTestGateway(adapter, "feishu", "tenant-a")

            let result = CronRunner.runJobOnceFromStore(Some(service), storePath, "best-effort-delivery", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs[0].state.lastStatus, "success")
            @Expect(jobs[0].state.lastError, "")
            let runs = readCronRunLogEntriesForJob(storePath, "best-effort-delivery", limit: 10)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "not-delivered")
            @Expect(row.get("deliveryError").getOrThrow().asString().getValue().contains("announce delivery failed"), true)
            @Expect(row.get("deliveryError").getOrThrow().asString().getValue().contains("fake send failed"), true)
            @Expect(row.get("diagnosticCode").getOrThrow().asString().getValue(), "")
        })
    }

    @TestCase
    public func m5p1ManualCronRunDeliversFakeWebBriefThroughGatewayLoop(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "m5-web-manual",
                "create a current web brief",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "telegram",
                deliveryTo: "chat-1",
                deliveryMode: "announce"
            )
            cronSave(storePath, [job])
            cronRunnerInstallFakeTavilyProvider()
            setGatewayAgentBridgeReplyRunnerForTest(Some({
                _conversationKey: String,
                _prompt: String,
                _channelName: String,
                _agentId: String,
                _streamingEnabled: Bool,
                _streamChunkHook: Option<(String) -> Unit> =>
                    cronRunnerFakeWebBrief()
            }))
            let adapter = CronRunnerTestChannelAdapter("telegram", messageId: "tg-m5")
            let service = cronRunnerTestGateway(adapter, "telegram", "")

            let result = CronRunner.runJobOnceFromStore(Some(service), storePath, "m5-web-manual", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("ran").getOrThrow().asBool().getValue(), true)
            @Expect(adapter.sendCount, 1)
            @Expect(adapter.lastText.contains("每日国际新闻简报"), true)
            @Expect(adapter.lastText.contains("Fake News A"), true)
            @Expect(adapter.lastText.contains("Tool: web_search"), true)

            let runs = readCronRunLogEntriesForJob(storePath, "m5-web-manual", limit: 10)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "ok")
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "delivered")
            @Expect(row.get("diagnosticCode").getOrThrow().asString().getValue(), "")
        })
    }

    @TestCase
    public func cronManualTriggerUsesWebSearchFallbackAndDeliversDuckDuckGoMarker(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "p5-duckduckgo-fallback",
                "create a current web brief",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "telegram",
                deliveryTo: "chat-1",
                deliveryMode: "announce"
            )
            cronSave(storePath, [job])
            cronRunnerInstallFakeDuckDuckGoProvider()
            setGatewayAgentBridgeReplyRunnerForTest(Some({
                _conversationKey: String,
                _prompt: String,
                _channelName: String,
                _agentId: String,
                _streamingEnabled: Bool,
                _streamChunkHook: Option<(String) -> Unit> =>
                    cronRunnerFakeDuckDuckGoWebBrief()
            }))
            let adapter = CronRunnerTestChannelAdapter("telegram", messageId: "tg-ddg")
            let service = cronRunnerTestGateway(adapter, "telegram", "")

            let result = CronRunner.runJobOnceFromStore(Some(service), storePath, "p5-duckduckgo-fallback", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("ran").getOrThrow().asBool().getValue(), true)
            @Expect(adapter.sendCount, 1)
            @Expect(adapter.lastText.contains("Provider: duckduckgo"), true)
            @Expect(adapter.lastText.contains("2026-06-23 source marker"), true)
            @Expect(adapter.lastText.contains("web_provider_unavailable"), false)

            let runs = readCronRunLogEntriesForJob(storePath, "p5-duckduckgo-fallback", limit: 10)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "ok")
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "delivered")
            @Expect(row.get("diagnosticCode").getOrThrow().asString().getValue(), "")
            @Expect(row.get("summary").getOrThrow().asString().getValue().contains("2026-06-23 source marker"), true)
        })
    }

    @TestCase
    public func m5n1UnavailableWebProviderIsDeliveredAndRecordedAsBusinessDiagnostic(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "m5-web-unavailable",
                "create a current web brief",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "telegram",
                deliveryTo: "chat-1",
                deliveryMode: "announce"
            )
            cronSave(storePath, [job])
            setGatewayWebProviderResolverForTest(Some({ _capability: String =>
                GatewayWebProviderResolution(
                    providerId: "tavily",
                    available: false,
                    status: "web_provider_unavailable",
                    message: "Real-time web search is unavailable because Tavily API key is not configured.",
                    supportsSearch: true
                )
            }))
            setGatewayAgentBridgeReplyRunnerForTest(Some({
                _conversationKey: String,
                _prompt: String,
                _channelName: String,
                _agentId: String,
                _streamingEnabled: Bool,
                _streamChunkHook: Option<(String) -> Unit> =>
                    "无法生成实时新闻。\n" + GatewayWebToolset().webSearchForTest("today huawei news", Some(2), Some("news"), Some("day"))
            }))
            let adapter = CronRunnerTestChannelAdapter("telegram", messageId: "tg-m5")
            let service = cronRunnerTestGateway(adapter, "telegram", "")

            let result = CronRunner.runJobOnceFromStore(Some(service), storePath, "m5-web-unavailable", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(adapter.sendCount, 1)
            @Expect(adapter.lastText.contains("web_provider_unavailable"), true)
            @Expect(adapter.lastText.contains("Fake News"), false)

            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs[0].state.lastStatus, "success")
            let runs = readCronRunLogEntriesForJob(storePath, "m5-web-unavailable", limit: 10)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "ok")
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "delivered")
            @Expect(row.get("diagnosticCode").getOrThrow().asString().getValue(), "web_provider_unavailable")
            @Expect(row.get("diagnosticMessage").getOrThrow().asString().getValue().contains("Real-time web search"), true)
        })
    }

    @TestCase
    public func cronWebProxyDiagnosticIsDeliveredAndRecordedAsBusinessDiagnostic(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "m5-web-proxy-diagnostic",
                "fetch a current RSS brief",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "telegram",
                deliveryTo: "chat-1",
                deliveryMode: "announce"
            )
            cronSave(storePath, [job])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "本轮未获取实时来源。\nStatus: error\nDiagnostic: code=web_fetch_proxy_connect_failed message=provider HTTP proxy CONNECT failed: HTTP/1.1 407 Proxy Authentication Required"
            }))
            let adapter = CronRunnerTestChannelAdapter("telegram", messageId: "tg-m5-proxy")
            let service = cronRunnerTestGateway(adapter, "telegram", "")

            let result = CronRunner.runJobOnceFromStore(Some(service), storePath, "m5-web-proxy-diagnostic", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(adapter.sendCount, 1)
            @Expect(adapter.lastText.contains("web_fetch_proxy_connect_failed"), true)

            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs[0].state.lastStatus, "success")
            let runs = readCronRunLogEntriesForJob(storePath, "m5-web-proxy-diagnostic", limit: 10)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "ok")
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "delivered")
            @Expect(row.get("diagnosticCode").getOrThrow().asString().getValue(), "web_fetch_proxy_connect_failed")
            let diagnosticMessage = row.get("diagnosticMessage").getOrThrow().asString().getValue()
            @Expect(diagnosticMessage.contains("407"), true)
            @Expect(diagnosticMessage.contains("password="), false)
        })
    }

    @TestCase
    public func cronNewsBriefDoesNotInventRealtimeWhenAllSourcesFail(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "p5-all-sources-fail",
                "create a current web brief",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "telegram",
                deliveryTo: "chat-1",
                deliveryMode: "announce"
            )
            cronSave(storePath, [job])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "本轮未获取实时来源，未生成新闻正文。\nStatus: error\nDiagnostic: code=web_search_provider_challenge message=DuckDuckGo returned a bot challenge"
            }))
            let adapter = CronRunnerTestChannelAdapter("telegram", messageId: "tg-all-fail")
            let service = cronRunnerTestGateway(adapter, "telegram", "")

            let result = CronRunner.runJobOnceFromStore(Some(service), storePath, "p5-all-sources-fail", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(adapter.sendCount, 1)
            @Expect(adapter.lastText.contains("本轮未获取实时来源"), true)
            @Expect(adapter.lastText.contains("未生成新闻正文"), true)
            @Expect(adapter.lastText.contains("Fake News"), false)
            @Expect(adapter.lastText.contains("2026-06-23 source marker"), false)

            let runs = readCronRunLogEntriesForJob(storePath, "p5-all-sources-fail", limit: 10)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "ok")
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "delivered")
            @Expect(row.get("diagnosticCode").getOrThrow().asString().getValue(), "web_search_provider_challenge")
        })
    }

    @TestCase
    public func m5b1ShellDiagnosticKeepsPriorityAndDeliveryErrorStaysRedacted(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "m5-shell-web-boundary",
                "create a current web brief",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "feishu",
                deliveryTo: "chat-1",
                deliveryMode: "announce",
                deliveryAccountId: "tenant-a",
                bestEffortDeliver: true
            )
            cronSave(storePath, [job])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "Cron/headless shell execution blocked: cron cannot wait for interactive approval. " +
                    "Diagnostic: code=cron_tool_exec_blocked reason=cron_headless_approval_required mode=deny allowlistCount=0.\n" +
                    "Status: error\nDiagnostic: code=web_provider_unavailable message=token=raw-lower-secret 中文🙂"
            }))
            let secretError = "send failed Authorization: Bearer secret-delivery-token-never-visible token=raw-lower-secret https://user:pass@example.com/hook"
            let adapter = CronRunnerTestChannelAdapter("feishu", failSend: true, failMessage: secretError)
            let service = cronRunnerTestGateway(adapter, "feishu", "tenant-a")

            let result = CronRunner.runJobOnceFromStore(Some(service), storePath, "m5-shell-web-boundary", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs[0].state.lastStatus, "success")
            let runs = readCronRunLogEntriesForJob(storePath, "m5-shell-web-boundary", limit: 10)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            // M3-N3: 诊断正文包含凭据形态时必须在 adapter 调用前隔离。
            @Expect(adapter.sendCount, 0)
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "unknown")
            @Expect(row.get("diagnosticCode").getOrThrow().asString().getValue(), "cron_tool_exec_blocked")
            @Expect(row.get("diagnosticMessage").getOrThrow().asString().getValue().contains("cron_tool_exec_blocked"), true)
            let deliveryError = row.get("deliveryError").getOrThrow().asString().getValue()
            @Expect(deliveryError.contains("secret-delivery-token-never-visible"), false)
            @Expect(deliveryError.contains("raw-lower-secret"), false)
            @Expect(deliveryError.contains("user:pass"), false)
            @Expect(deliveryError.contains("redacted"), true)
        })
    }

    @TestCase
    public func m5e2e1DueCronTickDeliversFakeWebBriefWithoutManualRunBypass(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "m5-web-due",
                "create a current web brief",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "telegram",
                deliveryTo: "chat-1",
                deliveryMode: "announce"
            )
            cronSave(storePath, [job])
            cronRunnerInstallFakeTavilyProvider()
            setGatewayAgentBridgeReplyRunnerForTest(Some({
                _conversationKey: String,
                _prompt: String,
                _channelName: String,
                _agentId: String,
                _streamingEnabled: Bool,
                _streamChunkHook: Option<(String) -> Unit> =>
                    cronRunnerFakeWebBrief()
            }))
            let adapter = CronRunnerTestChannelAdapter("telegram", messageId: "tg-m5")
            let service = cronRunnerTestGateway(adapter, "telegram", "")
            let runner = CronRunner(gatewayOpt: Some(service), storePath: storePath, cronEnabled: true)

            runner.tick(nowOverride: Some<Int64>(2000))
            @Expect(runner.waitUntilIdle(), true)
            runner.tick()

            @Expect(adapter.sendCount, 1)
            @Expect(adapter.lastText.contains("Fake News A"), true)
            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs[0].state.lastStatus, "success")
            @Expect(jobs[0].state.nextRunAtMs > 2000, true)
            let runs = readCronRunLogEntriesForJob(storePath, "m5-web-due", limit: 10)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "ok")
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "delivered")
            @Expect(row.get("summary").getOrThrow().asString().getValue().contains("Fake News B"), true)
        })
    }

    @TestCase
    public func cronDefaultGuardedShellToolFeedsSafeDeliveryThroughSessionLoop(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "m6-guarded-tool-delivery",
                "collect news through shell",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "telegram",
                deliveryTo: "user:8734062810",
                deliveryMode: "announce"
            )
            cronSave(storePath, [job])
            setGatewayAgentBridgeReplyRunnerForTest(Some({
                _conversationKey: String,
                _prompt: String,
                _channelName: String,
                _agentId: String,
                _streamingEnabled: Bool,
                _streamChunkHook: Option<(String) -> Unit> =>
                    debugGatewayShellExecuteForTest(
                        CliConfig.cwd.toString(),
                        "printf guarded-fresh-news",
                        None<String>,
                        Some(false)
                    )
            }))
            try {
                let adapter = CronRunnerTestChannelAdapter("telegram", messageId: "tg-1")
                let service = cronRunnerTestGateway(adapter, "telegram", "")

                let result = CronRunner.runJobOnceFromStore(Some(service), storePath, "m6-guarded-tool-delivery", true)
                @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
                @Expect(adapter.sendCount, 1)
                @Expect(adapter.lastText.contains("Command executed successfully"), true)
                @Expect(adapter.lastText.contains("Cron/headless shell execution blocked"), false)

                let jobs = cronLoadOrEmpty(storePath)
                @Expect(jobs[0].toolExecMode, "guarded")
                @Expect(jobs[0].state.lastStatus, "success")
                let runs = readCronRunLogEntriesForJob(storePath, "m6-guarded-tool-delivery", limit: 10)
                let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
                @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "delivered")
                @Expect(row.get("diagnosticCode").getOrThrow().asString().getValue(), "")
            } finally {
                setGatewayAgentBridgeReplyRunnerForTest(None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>)
            }
        })
    }

    @TestCase
    public func cronAllowlistShellToolFeedsLongUtf8DeliveryThroughSessionLoop(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "p5-allowlist-tool-delivery",
                "collect news through shell",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "telegram",
                deliveryTo: "user:8734062810",
                deliveryMode: "announce",
                toolExecMode: "allowlist",
                toolExecAllowlist: ["printf"]
            )
            cronSave(storePath, [job])
            setGatewayAgentBridgeReplyRunnerForTest(Some({
                _conversationKey: String,
                _prompt: String,
                _channelName: String,
                _agentId: String,
                _streamingEnabled: Bool,
                _streamChunkHook: Option<(String) -> Unit> =>
                    debugGatewayShellExecuteForTest(
                        CliConfig.cwd.toString(),
                        "printf '%05000d新闻🙂中文段落' 0",
                        None<String>,
                        Some(false)
                    )
            }))
            try {
                let adapter = CronRunnerTestChannelAdapter("telegram", messageId: "tg-1")
                let service = cronRunnerTestGateway(adapter, "telegram", "")

                let result = CronRunner.runJobOnceFromStore(Some(service), storePath, "p5-allowlist-tool-delivery", true)
                @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
                @Expect(adapter.sendCount, 1)
                @Expect(adapter.lastText.contains("Command executed successfully"), true)
                @Expect(adapter.lastText.contains("新闻🙂中文段落"), true)
                @Expect(adapter.lastText.size > 4000, true)

                let jobs = cronLoadOrEmpty(storePath)
                @Expect(jobs[0].state.lastStatus, "success")
                let runs = readCronRunLogEntriesForJob(storePath, "p5-allowlist-tool-delivery", limit: 10)
                let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
                @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "delivered")
            } finally {
                setGatewayAgentBridgeReplyRunnerForTest(None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>)
            }
        })
    }

    @TestCase
    public func cronExplicitDenyShellToolReturnsBlockedWithoutWaitingForApproval(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "p5-deny-tool",
                "collect news through shell",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "telegram",
                deliveryTo: "user:8734062810",
                deliveryMode: "announce",
                toolExecMode: "deny"
            )
            cronSave(storePath, [job])
            setGatewayAgentBridgeReplyRunnerForTest(Some({
                _conversationKey: String,
                _prompt: String,
                _channelName: String,
                _agentId: String,
                _streamingEnabled: Bool,
                _streamChunkHook: Option<(String) -> Unit> =>
                    debugGatewayShellExecuteForTest(
                        CliConfig.cwd.toString(),
                        "printf should-not-run",
                        None<String>,
                        Some(false)
                    )
            }))
            try {
                let adapter = CronRunnerTestChannelAdapter("telegram", messageId: "tg-1")
                let service = cronRunnerTestGateway(adapter, "telegram", "")

                let result = CronRunner.runJobOnceFromStore(Some(service), storePath, "p5-deny-tool", true)
                @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
                @Expect(adapter.sendCount, 1)
                @Expect(adapter.lastText.contains("Cron/headless shell execution blocked"), true)
                @Expect(adapter.lastText.contains("cron cannot wait for interactive approval"), true)
                @Expect(adapter.lastText.contains("Diagnostic: code=cron_tool_exec_blocked reason=cron_headless_approval_required mode=deny allowlistCount=0."), true)
                @Expect(adapter.lastText.contains("should-not-run"), true)
                @Expect(adapter.lastText.contains("Command executed successfully"), false)

                let jobs = cronLoadOrEmpty(storePath)
                @Expect(jobs[0].state.lastStatus, "success")
                let runs = readCronRunLogEntriesForJob(storePath, "p5-deny-tool", limit: 10)
                let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
                @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "delivered")
                @Expect(row.get("diagnosticCode").getOrThrow().asString().getValue(), "cron_tool_exec_blocked")
                @Expect(row.get("diagnosticMessage").getOrThrow().asString().getValue().contains("mode=deny"), true)
            } finally {
                setGatewayAgentBridgeReplyRunnerForTest(None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>)
            }
        })
    }

    @TestCase
    public func deliveryFailureStrictMarksJobErrorAndRecordsLastError(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "strict-delivery",
                "hello cron",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "feishu",
                deliveryTo: "chat-1",
                deliveryMode: "announce",
                deliveryAccountId: "tenant-a",
                bestEffortDeliver: false
            )
            cronSave(storePath, [job])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "ok answer"
            }))
            let adapter = CronRunnerTestChannelAdapter("feishu", failSend: true)
            let service = cronRunnerTestGateway(adapter, "feishu", "tenant-a")

            let result = CronRunner.runJobOnceFromStore(Some(service), storePath, "strict-delivery", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs[0].state.lastStatus, "error")
            @Expect(jobs[0].state.lastError.contains("announce delivery failed"), true)
            @Expect(jobs[0].state.lastError.contains("fake send failed"), true)
            let runs = readCronRunLogEntriesForJob(storePath, "strict-delivery", limit: 10)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "error")
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "not-delivered")
            @Expect(row.get("deliveryError").getOrThrow().asString().getValue().contains("fake send failed"), true)
        })
    }

    @TestCase
    public func deliveryFailureErrorIsRedactedBeforeStateAndRunLog(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "redacted-delivery",
                "hello cron",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                deliveryChannel: "feishu",
                deliveryTo: "chat-1",
                deliveryMode: "announce",
                deliveryAccountId: "tenant-a",
                bestEffortDeliver: false
            )
            cronSave(storePath, [job])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "ok answer"
            }))
            let secretError = "send failed Authorization: Bearer secret-delivery-token-never-visible token=raw-lower-secret https://user:pass@example.com/hook"
            let adapter = CronRunnerTestChannelAdapter("feishu", failSend: true, failMessage: secretError)
            let service = cronRunnerTestGateway(adapter, "feishu", "tenant-a")

            let result = CronRunner.runJobOnceFromStore(Some(service), storePath, "redacted-delivery", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs[0].state.lastStatus, "error")
            @Expect(jobs[0].state.lastError.contains("secret-delivery-token-never-visible"), false)
            @Expect(jobs[0].state.lastError.contains("raw-lower-secret"), false)
            @Expect(jobs[0].state.lastError.contains("user:pass"), false)
            @Expect(jobs[0].state.lastError.contains("redacted"), true)

            let runs = readCronRunLogEntriesForJob(storePath, "redacted-delivery", limit: 10)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            let deliveryError = row.get("deliveryError").getOrThrow().asString().getValue()
            @Expect(deliveryError.contains("secret-delivery-token-never-visible"), false)
            @Expect(deliveryError.contains("raw-lower-secret"), false)
            @Expect(deliveryError.contains("user:pass"), false)
            @Expect(deliveryError.contains("redacted"), true)
            @Expect(row.get("diagnosticCode").getOrThrow().asString().getValue(), "")

            let rawRunLog = String.fromUtf8(File.readFrom(cronRunLogPathFromStore(storePath, "redacted-delivery")))
            @Expect(rawRunLog.contains("secret-delivery-token-never-visible"), false)
            @Expect(rawRunLog.contains("raw-lower-secret"), false)
            @Expect(rawRunLog.contains("user:pass"), false)
        })
    }

    @TestCase
    public func failureAlertHonorsThresholdAndCooldown(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "failure-alert",
                "hello cron",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                failureChannel: "feishu",
                failureTo: "chat-1",
                failureDestMode: "announce",
                failureAccountId: "tenant-a",
                failureAlertAfter: 2,
                failureAlertCooldownMs: 60_000
            )
            cronSave(storePath, [job])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                throw Exception("agent failed")
            }))
            let adapter = CronRunnerTestChannelAdapter("feishu", messageId: "fail-msg-1")
            let service = cronRunnerTestGateway(adapter, "feishu", "tenant-a")

            let _first = CronRunner.runJobOnceFromStore(Some(service), storePath, "failure-alert", true)
            @Expect(adapter.sendCount, 0)

            let _second = CronRunner.runJobOnceFromStore(Some(service), storePath, "failure-alert", true)
            @Expect(adapter.sendCount, 1)
            let afterSecond = cronLoadOrEmpty(storePath)[0]
            @Expect(afterSecond.state.consecutiveErrors, 2)
            @Expect(afterSecond.state.lastFailureAlertAtMs > 0, true)
            @Expect(adapter.lastAccountId, "tenant-a")

            let _third = CronRunner.runJobOnceFromStore(Some(service), storePath, "failure-alert", true)
            @Expect(adapter.sendCount, 1)
            let afterThird = cronLoadOrEmpty(storePath)[0]
            @Expect(afterThird.state.consecutiveErrors, 3)
        })
    }
}

@Test
public class CronRunnerTypedOutcomeGateTest {
    @TestCase
    public func c5U01BlockedOutcomeRetriesAndNeverUsesProtocolAsSuccessBody(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = cronRunnerTestJob("c5-u-01")
            job.maxRetries = 1
            job.failureDestMode = "announce"
            job.failureChannel = "feishu"
            job.failureTo = "failure-chat"
            job.failureAccountId = "default"
            cronSave(storePath, [job])
            let attempts = AtomicInt64(0)
            debugSetCronRunnerOutcomeForTest(Some({ _job, _request =>
                attempts.fetchAdd(1)
                GatewayAgentReplyOutcome(
                    "incomplete_tool_protocol",
                    diagnosticCode: "incomplete_tool_protocol"
                )
            }))
            let adapter = CronRunnerTestChannelAdapter("feishu")
            let service = cronRunnerTestGateway(adapter, "feishu", "default")
            let _ = CronRunner.runJobOnceFromStore(Some(service), storePath, job.id, true)
            @Expect(attempts.load(), 2)
            @Expect(adapter.sendCount, 1)
            @Expect(adapter.lastText.contains("[\"web_fetch\"]"), false)
            let after = cronLoadOrEmpty(storePath)[0]
            @Expect(after.state.lastStatus, "error")
            @Expect(after.state.lastError.contains("incomplete_tool_protocol"), true)
            @Expect(after.state.lastError.contains("[\"web_fetch\"]"), false)
            let row = readCronRunLogEntriesForJob(storePath, job.id)
                .get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "error")
            @Expect(row.get("diagnosticCode").getOrThrow().asString().getValue(), "incomplete_tool_protocol")
            let summary = row.get("summary").getOrThrow().asString().getValue()
            @Expect(summary.contains("[\"web_fetch\"]"), false)
            @Expect(summary.contains("模型返回了工具调用协议"), false)
        })
    }

    @TestCase
    public func c5B01EmptySilentCancellationAndBestEffortStayInsideTypedGate(): Unit {
        // valid_text with an empty body is never success.
        withCronRunnerTestHome({ storePath: Path =>
            let job = cronRunnerTestJob("c5-b-empty")
            cronSave(storePath, [job])
            debugSetCronRunnerOutcomeForTest(Some({ _job, _request =>
                GatewayAgentReplyOutcome("valid_text", text: "")
            }))
            let _ = CronRunner.runJobOnceFromStore(None<GatewayService>, storePath, job.id, true)
            @Expect(cronLoadOrEmpty(storePath)[0].state.lastStatus, "error")
        })
        // Explicit silent is allowed only when no visible delivery was requested.
        withCronRunnerTestHome({ storePath: Path =>
            let silent = cronRunnerTestJob("c5-b-silent")
            cronSave(storePath, [silent])
            debugSetCronRunnerOutcomeForTest(Some({ _job, _request =>
                GatewayAgentReplyOutcome("explicit_silent", explicitSilent: true)
            }))
            let _ = CronRunner.runJobOnceFromStore(None<GatewayService>, storePath, silent.id, true)
            @Expect(cronLoadOrEmpty(storePath)[0].state.lastStatus, "success")
        })
        withCronRunnerTestHome({ storePath: Path =>
            let requested = cronRunnerTestJob("c5-b-silent-requested")
            requested.deliveryMode = "announce"
            requested.deliveryChannel = "feishu"
            requested.deliveryTo = "chat-1"
            cronSave(storePath, [requested])
            debugSetCronRunnerOutcomeForTest(Some({ _job, _request =>
                GatewayAgentReplyOutcome("explicit_silent", explicitSilent: true)
            }))
            let adapter = CronRunnerTestChannelAdapter("feishu")
            let service = cronRunnerTestGateway(adapter, "feishu", "default")
            let _ = CronRunner.runJobOnceFromStore(Some(service), storePath, requested.id, true)
            @Expect(cronLoadOrEmpty(storePath)[0].state.lastStatus, "error")
            @Expect(adapter.sendCount, 0)
        })
        // Deadline becomes cancelled after the outcome but before any delivery side effect.
        withCronRunnerTestHome({ storePath: Path =>
            let timed = cronRunnerTestJob("c5-b-cancel")
            timed.timeoutMs = 10
            timed.deliveryMode = "announce"
            timed.deliveryChannel = "feishu"
            timed.deliveryTo = "chat-1"
            cronSave(storePath, [timed])
            debugSetCronRunnerOutcomeForTest(Some({ _job, _request =>
                sleep(Duration.millisecond * 20)
                GatewayAgentReplyOutcome("valid_text", text: "不应投递🙂")
            }))
            let adapter = CronRunnerTestChannelAdapter("feishu")
            let service = cronRunnerTestGateway(adapter, "feishu", "default")
            let _ = CronRunner.runJobOnceFromStore(Some(service), storePath, timed.id, true)
            @Expect(adapter.sendCount, 0)
            @Expect(cronLoadOrEmpty(storePath)[0].state.lastStatus, "timeout")
        })
        // Best-effort changes delivery failure semantics, never typed outcome semantics.
        withCronRunnerTestHome({ storePath: Path =>
            let best = cronRunnerTestJob("c5-b-best-effort")
            best.deliveryMode = "announce"
            best.deliveryChannel = "feishu"
            best.deliveryTo = "chat-1"
            best.bestEffortDeliver = true
            cronSave(storePath, [best])
            debugSetCronRunnerOutcomeForTest(Some({ _job, _request =>
                GatewayAgentReplyOutcome("incomplete", diagnosticCode: "terminal_answer_empty")
            }))
            let adapter = CronRunnerTestChannelAdapter("feishu", failSend: true)
            let service = cronRunnerTestGateway(adapter, "feishu", "default")
            let _ = CronRunner.runJobOnceFromStore(Some(service), storePath, best.id, true)
            @Expect(cronLoadOrEmpty(storePath)[0].state.lastStatus, "error")
            @Expect(adapter.sendCount, 0)
        })
    }

    @TestCase
    public func c5P01SecondValidChineseOutcomeDeliversToFeishuExactlyOnce(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = cronRunnerTestJob("c5-p-01")
            job.maxRetries = 1
            job.deliveryMode = "announce"
            job.deliveryChannel = "feishu"
            job.deliveryTo = "chat-1"
            job.deliveryAccountId = "tenant-a"
            cronSave(storePath, [job])
            let attempts = AtomicInt64(0)
            debugSetCronRunnerOutcomeForTest(Some({ _job, _request =>
                if (attempts.fetchAdd(1) == 0) {
                    GatewayAgentReplyOutcome("incomplete", diagnosticCode: "terminal_answer_empty")
                } else {
                    GatewayAgentReplyOutcome("valid_text", text: "今日体育摘要🙂")
                }
            }))
            let adapter = CronRunnerTestChannelAdapter("feishu")
            let service = cronRunnerTestGateway(adapter, "feishu", "tenant-a")
            let _ = CronRunner.runJobOnceFromStore(Some(service), storePath, job.id, true)
            @Expect(attempts.load(), 2)
            @Expect(adapter.sendCount, 1)
            @Expect(adapter.lastText.contains("今日体育摘要🙂"), true)
            @Expect(cronLoadOrEmpty(storePath)[0].state.lastStatus, "success")
            let row = readCronRunLogEntriesForJob(storePath, job.id)
                .get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("status").getOrThrow().asString().getValue(), "ok")
        })
    }

    @TestCase
    public func c5N01AllBlockedCompletionSettlesErrorSideEffectsAtMostOnce(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = cronRunnerTestJob("c5-n-01")
            job.maxRetries = 1
            job.deliveryMode = "announce"
            job.deliveryChannel = "feishu"
            job.deliveryTo = "chat-1"
            job.failureDestMode = "announce"
            job.failureChannel = "feishu"
            job.failureTo = "failure-chat"
            cronSave(storePath, [job])
            debugSetCronRunnerOutcomeForTest(Some({ _job, _request =>
                GatewayAgentReplyOutcome("recoverable_tool_protocol", diagnosticCode: "tool_protocol", recoverable: true)
            }))
            let commits = AtomicInt64(0)
            debugSetCronRunnerCommitForTest(Some({ stage =>
                if (stage == "after-result-commit") { commits.fetchAdd(1) }
            }))
            let adapter = CronRunnerTestChannelAdapter("feishu")
            let service = cronRunnerTestGateway(adapter, "feishu", "default")
            let runner = CronRunner(gatewayOpt: Some(service), storePath: storePath)
            let _ = runner.enqueueJobManual(job.id, true)
            @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
            runner.tick()
            runner.tick()
            runner.tick()
            @Expect(adapter.sendCount, 1)
            @Expect(adapter.lastText.contains("[cron-failure:"), true)
            @Expect(adapter.lastText.contains("迟到结果不得投递"), false)
            @Expect(commits.load(), 1)
            @Expect(readCronRunLogEntriesForJob(storePath, job.id)
                .get("total").getOrThrow().asInt().getValue(), 1)
            let after = cronLoadStoreOrEmpty(storePath)
            @Expect(after.jobs[0].state.lastStatus, "error")
            @Expect(after.journal[0].runLogRecorded, true)
        })
        // A completion that arrives after shutdown fencing is stale and cannot settle again.
        withCronRunnerTestHome({ storePath: Path =>
            let job = cronRunnerTestJob("c5-n-late")
            job.deliveryMode = "announce"
            job.deliveryChannel = "feishu"
            job.deliveryTo = "chat-1"
            cronSave(storePath, [job])
            let entered = AtomicBool(false)
            let release = AtomicBool(false)
            debugSetCronRunnerOutcomeForTest(Some({ _job, _request =>
                entered.store(true)
                while (!release.load()) { sleep(Duration.millisecond * 2) }
                GatewayAgentReplyOutcome("valid_text", text: "迟到结果不得投递")
            }))
            let commits = AtomicInt64(0)
            debugSetCronRunnerCommitForTest(Some({ stage =>
                if (stage == "after-result-commit") { commits.fetchAdd(1) }
            }))
            let adapter = CronRunnerTestChannelAdapter("feishu")
            let service = cronRunnerTestGateway(adapter, "feishu", "default")
            let runner = CronRunner(gatewayOpt: Some(service), storePath: storePath)
            let _ = runner.enqueueJobManual(job.id, true)
            let began = DateTime.now().toUnixTimeStamp().toMilliseconds()
            while (!entered.load() && DateTime.now().toUnixTimeStamp().toMilliseconds() - began < 2000) {
                sleep(Duration.millisecond * 2)
            }
            @Expect(entered.load(), true)
            @Expect(runner.stop(drainTimeoutMs: 10).timedOut, true)
            release.store(true)
            @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
            runner.tick()
            runner.tick()
            @Expect(commits.load(), 0)
            @Expect(adapter.sendCount, 0)
            @Expect(cronLoadOrEmpty(storePath)[0].state.lastStatus, "interrupted")
            @Expect(readCronRunLogEntriesForJob(storePath, job.id)
                .get("total").getOrThrow().asInt().getValue(), 1)
        })
    }
}

@Test
public class CronRunnerWebhookDeliveryTest {
    @TestCase
    public func webhookDeliveryUsesConfiguredTimeoutAndBody(): Unit {
        withCronRunnerTestHome({ storePath: Path =>
            let job = CronJob(
                "webhook-delivery",
                "hello cron",
                CronSchedule.every(60000),
                state: CronJobState(nextRunAtMs: 1),
                sessionTarget: "main",
                agentId: "general",
                deliveryMode: "webhook",
                deliveryTo: "https://example.com/cron-hook?token=secret",
                timeoutMs: 2500
            )
            cronSave(storePath, [job])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "webhook answer"
            }))
            let captured = JsonObject()
            setCronWebhookHttpRunnerForTest(Some({ request: CronWebhookHttpRequest =>
                captured.put("url", JsonString(request.url))
                captured.put("timeoutMs", JsonInt(request.timeoutMs))
                captured.put("verifyTls", JsonString("${request.verifyTls}"))
                captured.put("jobId", request.body.get("jobId").getOrThrow())
                captured.put("summary", request.body.get("summary").getOrThrow())
                CronWebhookHttpResponse(true, statusCode: 200)
            }))

            let result = CronRunner.runJobOnceFromStore(None<GatewayService>, storePath, "webhook-delivery", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("ran").getOrThrow().asBool().getValue(), true)
            @Expect(captured.get("url").getOrThrow().asString().getValue(), "https://example.com/cron-hook?token=secret")
            let actualTimeoutMs = captured.get("timeoutMs").getOrThrow().asInt().getValue()
            @Expect(actualTimeoutMs > 0, true)
            @Expect(actualTimeoutMs <= 2500, true)
            @Expect(captured.get("verifyTls").getOrThrow().asString().getValue(), "true")
            @Expect(captured.get("jobId").getOrThrow().asString().getValue(), "webhook-delivery")
            @Expect(captured.get("summary").getOrThrow().asString().getValue(), "webhook answer")

            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs[0].state.lastStatus, "success")
            let runs = readCronRunLogEntriesForJob(storePath, "webhook-delivery", limit: 10)
            let row = runs.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "delivered")
        })
    }
}
