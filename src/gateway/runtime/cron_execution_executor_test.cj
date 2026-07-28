package metis.gateway.runtime

import metis.cron.{CronJob, CronSchedule}

import std.sync.AtomicBool
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

private func cronExecutorTestJob(id: String): CronJob {
    CronJob(id, "test", CronSchedule.every(60000))
}

private class CronExecutorFakeClock {
    public var now: Int64
    public init(now: Int64) { this.now = now }
}

private func awaitCronExecutorTest(
    predicate: () -> Bool,
    timeoutMs!: Int64 = 2000
): Bool {
    let started = DateTime.now().toUnixTimeStamp().toMilliseconds()
    while (DateTime.now().toUnixTimeStamp().toMilliseconds() - started < timeoutMs) {
        if (predicate()) {
            return true
        }
        sleep(Duration.millisecond * 5)
    }
    predicate()
}

private func cronExecutorTestTask(
    id: String,
    runTask: (CronJob) -> Unit,
    serialKey!: String = "",
    globalResource!: Bool = false,
    cleanupTask!: () -> Unit = { => () }
): CronExecutionTask {
    CronExecutionTask(
        CronExecutionId(id, 1, 2),
        cronExecutorTestJob(id),
        { job =>
            runTask(job)
            CronExecutionArtifact()
        },
        serialKey: serialKey,
        globalResource: globalResource,
        cleanupTask: cleanupTask
    )
}

@Test
public class CronExecutionExecutorTest {
    @TestCase
    public func m3U1RemainingHeartbeatAndFirstCancelReasonAreStable(): Unit {
        let clock = CronExecutorFakeClock(1000)
        let control = CronExecutionControl(2000, idleTimeoutMs: 200, nowMs: { => clock.now })
        @Expect(control.remainingMs(), 1000)
        clock.now = 1100
        control.heartbeat()
        clock.now = 1250
        @Expect(control.isCancelled(), false)
        clock.now = 1300
        @Expect(control.isCancelled(), true)
        @Expect(control.reason(), "idle_timeout")
        @Expect(control.cancel("later_cancel"), false)
        @Expect(control.reason(), "idle_timeout")
        @Expect(control.remainingMs(), 0)
    }

    @TestCase
    public func m3B1CompletionAtWallDeadlineProducesSingleTimeout(): Unit {
        let clock = CronExecutorFakeClock(100)
        let control = CronExecutionControl(101, nowMs: { => clock.now })
        @Expect(control.remainingMs(), 1)
        clock.now = 101
        @Expect(control.isCancelled(), true)
        @Expect(control.reason(), "timed_out")
        @Expect(control.cancel("second"), false)
    }

    @TestCase
    public func m3P1ValidProgressHeartbeatsMayOutliveIdleAndFinishBeforeWall(): Unit {
        let clock = CronExecutorFakeClock(0)
        let control = CronExecutionControl(1000, idleTimeoutMs: 100, nowMs: { => clock.now })
        for (step in [90, 180, 270, 360, 450]) {
            clock.now = step
            control.heartbeat()
            @Expect(control.isCancelled(), false)
        }
        clock.now = 500
        control.throwIfCancelled()
        @Expect(control.remainingMs(), 500)
        @Expect(control.reason(), "")
    }

    @TestCase
    public func m3B3TimeoutZeroKeepsSafetyAndIdleZeroOnlyDisablesIdle(): Unit {
        let zero = cronExecutorTestJob("zero")
        zero.timeoutMs = 0
        let resolved = resolveCronExecutionDeadline(
            zero,
            "agent",
            100,
            safetyTimeoutMs: 5000,
            idleTimeoutMs: 0
        )
        @Expect(resolved.userWallTimeoutMs, 0)
        @Expect(resolved.absoluteDeadlineMs, 5100)
        @Expect(resolved.idleTimeoutMs, 0)

        zero.timeoutMs = 2501
        let explicit = resolveCronExecutionDeadline(
            zero,
            "noAgent",
            100,
            safetyTimeoutMs: 5000,
            idleTimeoutMs: 3000
        )
        @Expect(explicit.absoluteDeadlineMs, 2601)
        @Expect(explicit.idleTimeoutMs, 2501)

        let clamped = resolveCronExecutionDeadline(
            zero,
            "script",
            0,
            defaultTimeoutMs: -1,
            safetyTimeoutMs: CRON_TIMEOUT_HARD_LIMIT_MS + 99,
            idleTimeoutMs: CRON_TIMEOUT_HARD_LIMIT_MS + 100
        )
        @Expect(clamped.safetyTimeoutMs, CRON_TIMEOUT_HARD_LIMIT_MS)
        @Expect(clamped.absoluteDeadlineMs, 2501)
        @Expect(clamped.idleTimeoutMs, 2501)
    }

    @TestCase
    public func m3N5ProviderCancellationMatrixHasNoEmptyAdapterOrLateFenceGap(): Unit {
        let rows = cronCancellationProviderMatrix()
        @Expect(rows.size, 6)
        for (row in rows) {
            @Expect(row.provider.trimAscii().isEmpty(), false)
            @Expect(row.mechanism.trimAscii().isEmpty(), false)
            @Expect(row.lateFence, true)
        }
    }

    @TestCase
    public func m2B3SharedSessionAndGlobalResourceSerializeWhileIndependentTaskRuns(): Unit {
        let executor = CronExecutionExecutor(maxConcurrentRuns: 3)
        let releaseShared = AtomicBool(false)
        let sharedEntered = AtomicBool(false)
        let sameSessionEntered = AtomicBool(false)
        let independentEntered = AtomicBool(false)
        executor.start()
        @Expect(executor.tryAcquireSlot(), true)
        @Expect(executor.submitReserved(cronExecutorTestTask("shared-a", { _job =>
            sharedEntered.store(true)
            while (!releaseShared.load()) { sleep(Duration.millisecond * 2) }
        }, serialKey: "会话-😀")), true)
        @Expect(awaitCronExecutorTest({ => sharedEntered.load() }), true)
        @Expect(executor.tryAcquireSlot(), true)
        @Expect(executor.submitReserved(cronExecutorTestTask("shared-b", { _job =>
            sameSessionEntered.store(true)
        }, serialKey: "会话-😀")), true)
        @Expect(executor.tryAcquireSlot(), true)
        @Expect(executor.submitReserved(cronExecutorTestTask("independent", { _job =>
            independentEntered.store(true)
        }, serialKey: "other")), true)
        @Expect(awaitCronExecutorTest({ => independentEntered.load() }), true)
        @Expect(sameSessionEntered.load(), false)
        releaseShared.store(true)
        @Expect(awaitCronExecutorTest({ => sameSessionEntered.load() }), true)
        @Expect(awaitCronExecutorTest({ => executor.activeCount() == 0 }), true)
    }

    @TestCase
    public func m2B3GlobalResourceFailureAlwaysRunsScopedRestore(): Unit {
        let executor = CronExecutionExecutor(maxConcurrentRuns: 2)
        let restoredEnv = AtomicBool(false)
        let restoredWorkdir = AtomicBool(false)
        executor.start()
        @Expect(executor.tryAcquireSlot(), true)
        @Expect(executor.submitReserved(cronExecutorTestTask(
            "global-failure",
            { _job => throw Exception("fake env/workdir failure") },
            serialKey: "global-session",
            globalResource: true,
            cleanupTask: { =>
                restoredEnv.store(true)
                restoredWorkdir.store(true)
            }
        )), true)
        @Expect(awaitCronExecutorTest({ => executor.activeCount() == 0 }), true)
        @Expect(restoredEnv.load(), true)
        @Expect(restoredWorkdir.load(), true)
        @Expect(executor.drainCompleted()[0].succeeded(), false)
    }

    @TestCase
    public func m1U1BlockingWorkerDoesNotBlockSubmitterAndKeepsSingleActive(): Unit {
        let executor = CronExecutionExecutor(maxConcurrentRuns: 1)
        let release = AtomicBool(false)
        let entered = AtomicBool(false)
        executor.start()

        @Expect(executor.tryAcquireSlot(), true)
        let started = DateTime.now().toUnixTimeStamp().toMilliseconds()
        @Expect(executor.submitReserved(cronExecutorTestTask("blocked", { _job =>
            entered.store(true)
            while (!release.load()) {
                sleep(Duration.millisecond * 5)
            }
        })), true)
        let elapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - started

        @Expect(elapsed < 250, true)
        @Expect(awaitCronExecutorTest({ => entered.load() }), true)
        @Expect(executor.activeCount(), 1)
        @Expect(executor.tryAcquireSlot(), false)
        release.store(true)
        @Expect(awaitCronExecutorTest({ => executor.activeCount() == 0 }), true)
        @Expect(executor.drainCompleted().size, 1)
    }

    @TestCase
    public func m1B1ConcurrencyLimitClampsInvalidAndOversizedValues(): Unit {
        for (configured in [0, -7]) {
            let executor = CronExecutionExecutor(maxConcurrentRuns: configured)
            executor.start()
            @Expect(executor.tryAcquireSlot(), true)
            @Expect(executor.tryAcquireSlot(), false)
            @Expect(executor.activeCount(), 1)
            @Expect(executor.releaseSlot(), true)
            @Expect(executor.activeCount(), 0)
        }

        let capped = CronExecutionExecutor(
            maxConcurrentRuns: CRON_MAX_CONCURRENT_RUNS_HARD_LIMIT + 100
        )
        capped.start()
        var acquired: Int64 = 0
        while (capped.tryAcquireSlot()) {
            acquired += 1
        }
        @Expect(acquired, CRON_MAX_CONCURRENT_RUNS_HARD_LIMIT)
        @Expect(capped.activeCount(), CRON_MAX_CONCURRENT_RUNS_HARD_LIMIT)
        var released: Int64 = 0
        while (capped.releaseSlot()) {
            released += 1
        }
        @Expect(released, CRON_MAX_CONCURRENT_RUNS_HARD_LIMIT)
        @Expect(capped.activeCount(), 0)
    }

    @TestCase
    public func m1N1WorkerExceptionReleasesPermitAndProducesErrorResult(): Unit {
        let executor = CronExecutionExecutor(maxConcurrentRuns: 1)
        executor.start()
        @Expect(executor.tryAcquireSlot(), true)
        @Expect(executor.submitReserved(cronExecutorTestTask("fails", { _job =>
            throw Exception("fake worker failure")
        })), true)

        @Expect(awaitCronExecutorTest({ => executor.activeCount() == 0 }), true)
        let failed = executor.drainCompleted()
        @Expect(failed.size, 1)
        @Expect(failed[0].succeeded(), false)
        @Expect(failed[0].error, "fake worker failure")

        @Expect(executor.tryAcquireSlot(), true)
        @Expect(executor.submitReserved(cronExecutorTestTask("sibling", { _job => () })), true)
        @Expect(awaitCronExecutorTest({ => executor.activeCount() == 0 }), true)
        let sibling = executor.drainCompleted()
        @Expect(sibling.size, 1)
        @Expect(sibling[0].executionId.jobId, "sibling")
        @Expect(sibling[0].succeeded(), true)
    }

    @TestCase
    public func m1N2NoSlotDoesNotCreatePendingTaskAndStopRejectsNewWork(): Unit {
        let executor = CronExecutionExecutor(maxConcurrentRuns: 1)
        let invoked = AtomicBool(false)
        executor.start()
        @Expect(executor.tryAcquireSlot(), true)
        @Expect(executor.tryAcquireSlot(), false)
        @Expect(executor.submitReserved(cronExecutorTestTask("only", { _job =>
            invoked.store(true)
        })), true)
        @Expect(awaitCronExecutorTest({ => executor.activeCount() == 0 }), true)
        @Expect(invoked.load(), true)
        @Expect(executor.drainCompleted().size, 1)
        @Expect(executor.drainCompleted().size, 0)

        executor.stopAccepting()
        @Expect(executor.tryAcquireSlot(), false)
        @Expect(executor.activeCount(), 0)
    }

    @TestCase
    public func cloneSeparatesMutableJobStateAndAllowlist(): Unit {
        let original = CronJob(
            "clone",
            "你好🙂",
            CronSchedule.cron("0 * * * *", "UTC", staggerMs: 10),
            toolExecAllowlist: ["git", "rg"]
        )
        original.state.lastError = "原始错误🙂"
        let cloned = cronCloneJobForExecution(original)

        cloned.state.lastError = "worker changed"
        cloned.toolExecAllowlist[0] = "changed"
        @Expect(original.state.lastError, "原始错误🙂")
        @Expect(original.toolExecAllowlist[0], "git")
        @Expect(cloned.prompt, "你好🙂")
        @Expect(cloned.schedule.staggerMs, 10)
    }
}
