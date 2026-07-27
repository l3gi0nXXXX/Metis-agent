package metis.gateway.runtime

import metis.cron.{CronJob, CronJobState, CronSchedule}

import std.collection.ArrayList
import std.sync.Mutex

/** Cron 并发配置的安全上限；非法非正值回退为单 worker。 */
public let CRON_MAX_CONCURRENT_RUNS_HARD_LIMIT: Int64 = 32

/** 一次 Cron 执行的稳定身份，不依赖可变的 job state。 */
public struct CronExecutionId {
    CronExecutionId(
        public let jobId: String,
        public let scheduledAtMs: Int64,
        public let startedAtMs: Int64
    ) {}
}

/** 已取得 executor slot、等待立即启动的执行快照。 */
public class CronExecutionTask {
    public let executionId: CronExecutionId
    public let job: CronJob
    private let runTask: (CronJob) -> Unit

    public init(executionId: CronExecutionId, job: CronJob, runTask: (CronJob) -> Unit) {
        this.executionId = executionId
        this.job = job
        this.runTask = runTask
    }

    public func run(): Unit {
        this.runTask(this.job)
    }
}

/** worker 的终态结果；error 为空表示执行成功。 */
public class CronExecutionResult {
    public let executionId: CronExecutionId
    public let job: CronJob
    public let error: String

    public init(executionId: CronExecutionId, job: CronJob, error!: String = "") {
        this.executionId = executionId
        this.job = job
        this.error = error
    }

    public func succeeded(): Bool {
        this.error.isEmpty()
    }
}

/** 为 worker 创建与 store 中可变对象完全分离的任务快照。 */
public func cronCloneJobForExecution(job: CronJob): CronJob {
    let state = CronJobState(
        nextRunAtMs: job.state.nextRunAtMs,
        lastRunAtMs: job.state.lastRunAtMs,
        lastError: job.state.lastError,
        lastStatus: job.state.lastStatus,
        consecutiveErrors: job.state.consecutiveErrors,
        runningAtMs: job.state.runningAtMs,
        scheduleErrorCount: job.state.scheduleErrorCount,
        lastFailureAlertAtMs: job.state.lastFailureAlertAtMs
    )
    let schedule = if (job.schedule.kind == "every") {
        CronSchedule.every(job.schedule.everyMs, anchorMs: job.schedule.anchorMs)
    } else if (job.schedule.kind == "at") {
        CronSchedule.at(job.schedule.atMs)
    } else {
        CronSchedule.cron(
            job.schedule.cronExpr,
            job.schedule.timeZone,
            staggerMs: job.schedule.staggerMs
        )
    }
    let allowlist = ArrayList<String>()
    for (entry in job.toolExecAllowlist) {
        allowlist.add(entry)
    }
    CronJob(
        job.id,
        job.prompt,
        schedule,
        createdAtMs: job.createdAtMs,
        enabled: job.enabled,
        sessionTarget: job.sessionTarget,
        state: state,
        systemEvent: job.systemEvent,
        wakeMode: job.wakeMode,
        deliveryChannel: job.deliveryChannel,
        deliveryTo: job.deliveryTo,
        deliveryAnnounce: job.deliveryAnnounce,
        timeoutMs: job.timeoutMs,
        maxRetries: job.maxRetries,
        retryBackoffMs: job.retryBackoffMs,
        failureChannel: job.failureChannel,
        failureTo: job.failureTo,
        failureAnnounce: job.failureAnnounce,
        payloadKind: job.payloadKind,
        deliveryMode: job.deliveryMode,
        failureDestMode: job.failureDestMode,
        deleteAfterRun: job.deleteAfterRun,
        updatedAtMs: job.updatedAtMs,
        description: job.description,
        agentId: job.agentId,
        sessionKey: job.sessionKey,
        modelOverride: job.modelOverride,
        thinkingLevel: job.thinkingLevel,
        lightContext: job.lightContext,
        deliveryAccountId: job.deliveryAccountId,
        bestEffortDeliver: job.bestEffortDeliver,
        toolExecMode: job.toolExecMode,
        toolExecAllowlist: allowlist.toArray(),
        scriptPath: job.scriptPath,
        scriptMode: job.scriptMode,
        failureAccountId: job.failureAccountId,
        failureAlertAfter: job.failureAlertAfter,
        failureAlertCooldownMs: job.failureAlertCooldownMs
    )
}

/**
 * 无内部 pending queue 的有界 Cron executor。
 *
 * 调用方必须先 `tryAcquireSlot`，完成持久化 reservation 后立即调用
 * `submitReserved`；reservation 失败时调用 `releaseSlot`。
 */
public class CronExecutionExecutor {
    private let stateLock = Mutex()
    private let maxConcurrentRuns: Int64
    private let completed = ArrayList<CronExecutionResult>()
    private var accepting: Bool = false
    private var active: Int64 = 0
    private var reserved: Int64 = 0

    public init(maxConcurrentRuns!: Int64 = 1) {
        this.maxConcurrentRuns = if (maxConcurrentRuns <= 0) {
            1
        } else if (maxConcurrentRuns > CRON_MAX_CONCURRENT_RUNS_HARD_LIMIT) {
            CRON_MAX_CONCURRENT_RUNS_HARD_LIMIT
        } else {
            maxConcurrentRuns
        }
    }

    public func start(): Unit {
        synchronized(this.stateLock) {
            this.accepting = true
        }
    }

    public func tryAcquireSlot(): Bool {
        synchronized(this.stateLock) {
            if (!this.accepting || this.active >= this.maxConcurrentRuns) {
                return false
            }
            this.active += 1
            this.reserved += 1
            true
        }
    }

    public func releaseSlot(): Bool {
        synchronized(this.stateLock) {
            if (this.reserved <= 0) {
                return false
            }
            this.reserved -= 1
            this.active -= 1
            true
        }
    }

    public func submitReserved(task: CronExecutionTask): Bool {
        synchronized(this.stateLock) {
            if (!this.accepting || this.reserved <= 0) {
                return false
            }
            this.reserved -= 1
        }
        spawn {
            var error = ""
            try {
                task.run()
            } catch (e: Exception) {
                error = e.message
            } finally {
                synchronized(this.stateLock) {
                    this.completed.add(CronExecutionResult(task.executionId, task.job, error: error))
                    this.active -= 1
                }
            }
        }
        true
    }

    public func drainCompleted(): Array<CronExecutionResult> {
        synchronized(this.stateLock) {
            let out = this.completed.toArray()
            this.completed.clear()
            out
        }
    }

    public func activeCount(): Int64 {
        synchronized(this.stateLock) {
            this.active
        }
    }

    public func stopAccepting(): Unit {
        synchronized(this.stateLock) {
            this.accepting = false
        }
    }
}
