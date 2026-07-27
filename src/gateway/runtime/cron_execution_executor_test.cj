package metis.gateway.runtime

import metis.cron.{CronJob, CronSchedule}

import std.sync.AtomicBool
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

private func cronExecutorTestJob(id: String): CronJob {
    CronJob(id, "test", CronSchedule.every(60000))
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

private func cronExecutorTestTask(id: String, runTask: (CronJob) -> Unit): CronExecutionTask {
    CronExecutionTask(
        CronExecutionId(id, 1, 2),
        cronExecutorTestJob(id),
        { job =>
            runTask(job)
            CronExecutionArtifact()
        }
    )
}

@Test
public class CronExecutionExecutorTest {
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
