package metis.gateway.runtime

import metis.cron.{CronJob, CronJobState, CronSchedule}
import metis.gateway.core.{GatewayExecutionCancelledException, GatewayExecutionControl}

import std.collection.{ArrayList, HashSet}
import std.core.Duration
import std.sync.Mutex
import std.time.DateTime

/** Cron 并发配置的安全上限；非法非正值回退为单 worker。 */
public let CRON_MAX_CONCURRENT_RUNS_HARD_LIMIT: Int64 = 32

public let CRON_DEFAULT_TIMEOUT_MS: Int64 = 10 * 60 * 1000
public let CRON_SAFETY_TIMEOUT_MS: Int64 = 30 * 60 * 1000
public let CRON_IDLE_TIMEOUT_MS: Int64 = 2 * 60 * 1000
public let CRON_TIMEOUT_HARD_LIMIT_MS: Int64 = 24 * 60 * 60 * 1000

private func cronExecutionNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

/** 一个执行共享的绝对墙钟、idle activity 与首次取消原因。 */
public class CronExecutionControl <: GatewayExecutionControl {
    private let stateLock = Mutex()
    private let absoluteDeadlineMs: Int64
    private let idleTimeoutMs: Int64
    private let nowMs: () -> Int64
    private var lastActivityAtMs: Int64
    private var cancelReason: String = ""

    public init(
        absoluteDeadlineMs: Int64,
        idleTimeoutMs!: Int64 = 0,
        nowMs!: () -> Int64 = cronExecutionNowMs
    ) {
        this.absoluteDeadlineMs = absoluteDeadlineMs
        this.idleTimeoutMs = max(0, idleTimeoutMs)
        this.nowMs = nowMs
        this.lastActivityAtMs = nowMs()
    }

    private func refreshTimeoutLocked(now: Int64): Unit {
        if (!this.cancelReason.isEmpty()) {
            return
        }
        if (this.absoluteDeadlineMs > 0 && now >= this.absoluteDeadlineMs) {
            this.cancelReason = "timed_out"
            return
        }
        if (this.idleTimeoutMs > 0 && now - this.lastActivityAtMs >= this.idleTimeoutMs) {
            this.cancelReason = "idle_timeout"
        }
    }

    public func remainingMs(): Int64 {
        synchronized(this.stateLock) {
            let now = this.nowMs()
            this.refreshTimeoutLocked(now)
            if (!this.cancelReason.isEmpty()) {
                return 0
            }
            if (this.absoluteDeadlineMs <= 0) {
                return Int64.Max
            }
            max(0, this.absoluteDeadlineMs - now)
        }
    }

    public func heartbeat(): Unit {
        synchronized(this.stateLock) {
            let now = this.nowMs()
            this.refreshTimeoutLocked(now)
            if (this.cancelReason.isEmpty()) {
                this.lastActivityAtMs = now
            }
        }
    }

    public func cancel(reason: String): Bool {
        synchronized(this.stateLock) {
            if (!this.cancelReason.isEmpty()) {
                return false
            }
            this.cancelReason = if (reason.trimAscii().isEmpty()) { "cancelled" } else { reason.trimAscii() }
            true
        }
    }

    public func reason(): String {
        synchronized(this.stateLock) {
            this.refreshTimeoutLocked(this.nowMs())
            this.cancelReason
        }
    }

    public func isCancelled(): Bool {
        !this.reason().isEmpty()
    }

    public func throwIfCancelled(): Unit {
        let current = this.reason()
        if (!current.isEmpty()) {
            throw GatewayExecutionCancelledException(current)
        }
    }
}

public struct CronExecutionDeadline {
    public let absoluteDeadlineMs: Int64
    public let idleTimeoutMs: Int64
    public let userWallTimeoutMs: Int64
    public let safetyTimeoutMs: Int64

    public init(absoluteDeadlineMs: Int64, idleTimeoutMs: Int64, userWallTimeoutMs: Int64, safetyTimeoutMs: Int64) {
        this.absoluteDeadlineMs = absoluteDeadlineMs
        this.idleTimeoutMs = idleTimeoutMs
        this.userWallTimeoutMs = userWallTimeoutMs
        this.safetyTimeoutMs = safetyTimeoutMs
    }
}

public struct CronCancellationProviderRow {
    public let provider: String
    public let mechanism: String
    public let lateFence: Bool
    public init(provider: String, mechanism: String, lateFence: Bool) {
        this.provider = provider
        this.mechanism = mechanism
        this.lateFence = lateFence
    }
}

/** M3-N5验收矩阵；每行必须映射到实际adapter而非空白声明。 */
public func cronCancellationProviderMatrix(): Array<CronCancellationProviderRow> {
    [
        CronCancellationProviderRow("chat-completions", "absolute-deadline+future-cancel", true),
        CronCancellationProviderRow("responses", "http-timeout+client-close", true),
        CronCancellationProviderRow("codex-app-server", "runTurn-timeout+interruptTurn+client-close", true),
        CronCancellationProviderRow("tool-child", "runtime-remaining+process-timeout", true),
        CronCancellationProviderRow("script", "process-wait-timeout+force-terminate+wait", true),
        CronCancellationProviderRow("webhook", "socket-timeout+client-close", true)
    ]
}

private func cronPositiveOrDefault(value: Int64, fallback: Int64): Int64 {
    min(if (value > 0) { value } else { fallback }, CRON_TIMEOUT_HARD_LIMIT_MS)
}

/**
 * job.timeoutMs=0 保持无用户 wall limit；最终 deadline 始终受 safety ceiling 约束。
 * `kind` 为 agent/script/noAgent；当前默认值由 Gateway 配置明确传入。
 */
public func resolveCronExecutionDeadline(
    job: CronJob,
    kind: String,
    nowMs: Int64,
    defaultTimeoutMs!: Int64 = CRON_DEFAULT_TIMEOUT_MS,
    safetyTimeoutMs!: Int64 = CRON_SAFETY_TIMEOUT_MS,
    idleTimeoutMs!: Int64 = CRON_IDLE_TIMEOUT_MS
): CronExecutionDeadline {
    let safety = cronPositiveOrDefault(safetyTimeoutMs, CRON_SAFETY_TIMEOUT_MS)
    let normalizedKind = kind.trimAscii().toAsciiLower()
    let resolvedDefault = cronPositiveOrDefault(defaultTimeoutMs, CRON_DEFAULT_TIMEOUT_MS)
    let userWall = if (job.timeoutMs > 0) {
        min(job.timeoutMs, safety)
    } else {
        0
    }
    // timeout=0 的兼容语义是不创建用户 wall limit；resolvedDefault 仅供诊断/后续
    // 未显式 timeout 的新建任务默认写入使用，不能在这里改变旧任务语义。
    let _ = normalizedKind
    let _ = resolvedDefault
    let effectiveWall = if (userWall > 0) { userWall } else { safety }
    let idle = if (idleTimeoutMs > 0) { min(idleTimeoutMs, effectiveWall) } else { 0 }
    CronExecutionDeadline(nowMs + effectiveWall, idle, userWall, safety)
}

/** 一次 Cron 执行的稳定身份，不依赖可变的 job state。 */
public struct CronExecutionId {
    CronExecutionId(
        public let jobId: String,
        public let scheduledAtMs: Int64,
        public let startedAtMs: Int64
    ) {}
}

public class CronExecutionArtifact {
    public var status: String
    public var error: String
    public var answer: String
    public var deliveryStatus: String
    public var deliveryError: String
    public var diagnosticCode: String
    public var diagnosticMessage: String
    public var endedAtMs: Int64

    public init(
        status!: String = "success",
        error!: String = "",
        answer!: String = "",
        deliveryStatus!: String = "not-requested",
        deliveryError!: String = "",
        diagnosticCode!: String = "",
        diagnosticMessage!: String = "",
        endedAtMs!: Int64 = 0
    ) {
        this.status = status
        this.error = error
        this.answer = answer
        this.deliveryStatus = deliveryStatus
        this.deliveryError = deliveryError
        this.diagnosticCode = diagnosticCode
        this.diagnosticMessage = diagnosticMessage
        this.endedAtMs = endedAtMs
    }
}

/** 已取得 executor slot、等待立即启动的执行快照。 */
public class CronExecutionTask {
    public let executionId: CronExecutionId
    public let job: CronJob
    public let absoluteDeadlineMs: Int64
    public let idleTimeoutMs: Int64
    public let executionControl: CronExecutionControl
    /** 共享 AgentBridge/session 的任务使用相同 key，避免 transcript/tool runtime 竞争。 */
    public let serialKey: String
    /** 修改进程级 env/workdir 的任务进入全局 lane。 */
    public let globalResource: Bool
    private let runTask: (CronJob) -> CronExecutionArtifact
    private let cleanupTask: () -> Unit

    public init(
        executionId: CronExecutionId,
        job: CronJob,
        runTask: (CronJob) -> CronExecutionArtifact,
        absoluteDeadlineMs!: Int64 = 0,
        idleTimeoutMs!: Int64 = 0,
        executionControl!: Option<CronExecutionControl> = None<CronExecutionControl>,
        serialKey!: String = "",
        globalResource!: Bool = false,
        cleanupTask!: () -> Unit = { => () }
    ) {
        this.executionId = executionId
        this.job = job
        this.runTask = runTask
        this.absoluteDeadlineMs = absoluteDeadlineMs
        this.idleTimeoutMs = idleTimeoutMs
        this.executionControl = match (executionControl) {
            case Some(control) => control
            case None => CronExecutionControl(absoluteDeadlineMs, idleTimeoutMs: idleTimeoutMs)
        }
        this.serialKey = serialKey.trimAscii()
        this.globalResource = globalResource
        this.cleanupTask = cleanupTask
    }

    public func run(): CronExecutionArtifact {
        try {
            this.runTask(this.job)
        } finally {
            this.cleanupTask()
        }
    }
}

/** worker 的终态结果；error 为空表示执行成功。 */
public class CronExecutionResult {
    public let executionId: CronExecutionId
    public let job: CronJob
    public let error: String
    public let startedAtMs: Int64
    public let endedAtMs: Int64
    public let artifact: CronExecutionArtifact
    public let executionControl: CronExecutionControl

    public init(
        executionId: CronExecutionId,
        job: CronJob,
        error!: String = "",
        startedAtMs!: Int64 = 0,
        endedAtMs!: Int64 = 0,
        artifact!: CronExecutionArtifact = CronExecutionArtifact(),
        executionControl!: Option<CronExecutionControl> = None<CronExecutionControl>
    ) {
        this.executionId = executionId
        this.job = job
        this.error = error
        this.startedAtMs = startedAtMs
        this.endedAtMs = endedAtMs
        this.artifact = artifact
        this.executionControl = match (executionControl) {
            case Some(control) => control
            case None => CronExecutionControl(Int64.Max)
        }
    }

    public func succeeded(): Bool {
        this.error.isEmpty()
    }
}

/** Executor 生命周期快照。executionIds 仅供进程内 fencing，不得直接写用户日志。 */
public class CronExecutionLifecycleSnapshot {
    public let accepting: Bool
    public let activeCount: Int64
    public let reservedCount: Int64
    public let executionIds: Array<String>

    public init(accepting: Bool, activeCount: Int64, reservedCount: Int64, executionIds: Array<String>) {
        this.accepting = accepting
        this.activeCount = activeCount
        this.reservedCount = reservedCount
        this.executionIds = executionIds
    }
}

public class CronExecutionDrainResult {
    public let drained: Bool
    public let timedOut: Bool
    public let activeExecutionIds: Array<String>

    public init(drained: Bool, activeExecutionIds: Array<String>) {
        this.drained = drained
        this.timedOut = !drained
        this.activeExecutionIds = activeExecutionIds
    }
}

private class CronExecutionActiveHandle {
    public let executionId: String
    public let control: CronExecutionControl

    public init(executionId: String, control: CronExecutionControl) {
        this.executionId = executionId
        this.control = control
    }
}

private func cronExecutorIdentity(id: CronExecutionId): String {
    "${id.jobId}:${id.scheduledAtMs}:${id.startedAtMs}"
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
        lastFailureAlertAtMs: job.state.lastFailureAlertAtMs,
        executionId: job.state.executionId,
        executionStartedAtMs: job.state.executionStartedAtMs,
        executionHeartbeatAtMs: job.state.executionHeartbeatAtMs
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
    private let activeHandles = ArrayList<CronExecutionActiveHandle>()
    private let activeSerialKeys = HashSet<String>()
    private var globalResourceActive: Bool = false

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
            this.activeHandles.add(CronExecutionActiveHandle(
                cronExecutorIdentity(task.executionId),
                task.executionControl
            ))
        }
        spawn {
            var error = ""
            var artifact = CronExecutionArtifact()
            var laneAcquired = false
            try {
                while (!laneAcquired) {
                    laneAcquired = synchronized(this.stateLock) {
                        let serialBusy = !task.serialKey.isEmpty() && this.activeSerialKeys.contains(task.serialKey)
                        let globalBusy = task.globalResource && this.globalResourceActive
                        if (!serialBusy && !globalBusy) {
                            if (!task.serialKey.isEmpty()) {
                                this.activeSerialKeys.add(task.serialKey)
                            }
                            if (task.globalResource) {
                                this.globalResourceActive = true
                            }
                            true
                        } else {
                            false
                        }
                    }
                    if (!laneAcquired) {
                        sleep(Duration.millisecond)
                    }
                }
                artifact = task.run()
            } catch (e: Exception) {
                error = e.message
            } finally {
                synchronized(this.stateLock) {
                    if (laneAcquired) {
                        if (!task.serialKey.isEmpty()) {
                            this.activeSerialKeys.remove(task.serialKey)
                        }
                        if (task.globalResource) {
                            this.globalResourceActive = false
                        }
                    }
                    this.completed.add(CronExecutionResult(
                        task.executionId,
                        task.job,
                        error: error,
                        startedAtMs: task.executionId.startedAtMs,
                        endedAtMs: artifact.endedAtMs,
                        artifact: artifact,
                        executionControl: Some(task.executionControl)
                    ))
                    let retained = ArrayList<CronExecutionActiveHandle>()
                    let identity = cronExecutorIdentity(task.executionId)
                    for (handle in this.activeHandles) {
                        if (handle.executionId != identity) {
                            retained.add(handle)
                        }
                    }
                    this.activeHandles.clear()
                    for (handle in retained) {
                        this.activeHandles.add(handle)
                    }
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

    public func completedCount(): Int64 {
        synchronized(this.stateLock) {
            this.completed.size
        }
    }

    public func lifecycleSnapshot(): CronExecutionLifecycleSnapshot {
        synchronized(this.stateLock) {
            let ids = ArrayList<String>()
            for (handle in this.activeHandles) {
                ids.add(handle.executionId)
            }
            CronExecutionLifecycleSnapshot(this.accepting, this.active, this.reserved, ids.toArray())
        }
    }

    /** 幂等停止接单，并返回停止瞬间的 active/queued 快照。 */
    public func stopAccepting(): CronExecutionLifecycleSnapshot {
        synchronized(this.stateLock) {
            this.accepting = false
            let ids = ArrayList<String>()
            for (handle in this.activeHandles) {
                ids.add(handle.executionId)
            }
            CronExecutionLifecycleSnapshot(false, this.active, this.reserved, ids.toArray())
        }
    }

    /** 协作取消所有已提交 execution；handle 只由 worker finally 移除。 */
    public func cancelAll(reason!: String = "gateway_shutdown"): CronExecutionLifecycleSnapshot {
        synchronized(this.stateLock) {
            this.accepting = false
            // reserved 尚未产生 worker，停止时可直接撤销 permit；对应 store reservation
            // 由 CronRunner 的 compare-and-fence 归一，不能让 awaitDrain 永久等待不存在的 handle。
            if (this.reserved > 0) {
                this.active -= this.reserved
                this.reserved = 0
            }
            let ids = ArrayList<String>()
            for (handle in this.activeHandles) {
                let _ = handle.control.cancel(reason)
                ids.add(handle.executionId)
            }
            CronExecutionLifecycleSnapshot(false, this.active, this.reserved, ids.toArray())
        }
    }

    /** 不持有 CronRunner.tickLock 的有界 drain。 */
    public func awaitDrain(timeoutMs: Int64): CronExecutionDrainResult {
        let began = cronExecutionNowMs()
        let bounded = max(0, timeoutMs)
        while (this.activeCount() > 0 && cronExecutionNowMs() - began < bounded) {
            sleep(Duration.millisecond * 5)
        }
        let snapshot = this.lifecycleSnapshot()
        CronExecutionDrainResult(snapshot.activeCount == 0, snapshot.executionIds)
    }
}
