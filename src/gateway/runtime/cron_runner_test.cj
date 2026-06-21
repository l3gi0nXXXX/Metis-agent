package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.cron.{
    CronJob,
    CronJobState,
    CronSchedule,
    cronLoadOrEmpty,
    cronSave,
    cronStorePath,
    readCronRunLogEntriesForJob
}
import metis.gateway.core.GatewayService
import metis.gateway.session.{GatewayIngressSource, GatewaySessionRequest, gatewayIngressSourceLabel}

import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*

private func withCronRunnerTestHome<T>(block: (Path) -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = "/tmp/metis-cron-runner-test-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
        try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", home)
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        try {
            return block(cronStorePath(CliConfig.dotDir))
        } finally {
            debugSetCronRunnerReplyForTest(None<(CronJob, GatewaySessionRequest) -> String>)
            debugSetCronRunnerBeforeExecuteForTest(None<(CronJob) -> Unit>)
            debugSetCronRunnerRunLogAppendForTest(None<() -> Unit>)
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

@Test
public class CronRunnerTest {
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
        withCronRunnerTestHome({ storePath =>
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
    public func runLogAppendFailureDoesNotRewriteBusinessState(): Unit {
        withCronRunnerTestHome({ storePath =>
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
        withCronRunnerTestHome({ storePath =>
            cronSave(storePath, [cronRunnerTestJob("shared-runner")])
            debugSetCronRunnerReplyForTest(Some({ _job: CronJob, _request: GatewaySessionRequest =>
                "ok answer"
            }))

            let runner = CronRunner(gatewayOpt: None<GatewayService>, storePath: storePath, cronEnabled: true)
            runner.tick(nowOverride: Some<Int64>(2000))
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
}
