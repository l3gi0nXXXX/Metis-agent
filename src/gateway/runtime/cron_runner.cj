package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager}
import metis.core.memory.DreamingPhaseRuntime
import metis.core.{cronShellExecutionBlockedDiagnosticFromText, metisSafeRuneEllipsis}
import metis.gateway.core.{
    AgentBridge,
    GatewayCronSessionReaperState,
    GatewayService,
    gatewayBridgeForSessionRequest,
    gatewayLogEventError,
    gatewayLogEventInfo,
    gatewayLogEventWarn,
    gatewayLogMeta,
    gatewayListPersistedAgentIdsForUser,
    gatewayResolveSessionContextWithAgentRoute,
    gatewaySessionStoreForUserWithAgentId
}
import metis.gateway.session.{GatewayIngressSource, GatewaySessionRequest, GatewayTurnContext}
import metis.cron.{
    CronJob,
    CronDeliveryResolved,
    CronFailureResolved,
    appendCronRunLog,
    buildCronWebhookFailureBody,
    buildCronWebhookSuccessBody,
    computeJobNextRun,
    cronPromptScanMeta,
    cronExecutionConversationKey,
    cronShouldRouteThroughDreaming,
    cronWebhookTimeoutMs,
    cronLoadOrEmpty,
    cronSave,
    cronStorePath,
    isCronDue,
    isTransientCronError,
    cronErrorBackoffMs,
    postCronWebhookJson,
    cronEffectiveAnnounceChannel,
    resolveCronDeliveryPlan,
    resolveCronFailurePlan,
    scanCronPromptAssembled,
    cronNormalizeScriptMode,
    runCronJobScriptForJob,
    CronScriptRunResult
}
import metis.gateway.logging.gatewayLogRedactText

import magic.prelude.*

import std.collection.{ArrayList, HashMap}
import std.core.Duration
import std.fs.Path
import std.sort.sort
import std.sync.Mutex
import std.time.DateTime
import stdx.encoding.json.{JsonBool, JsonObject, JsonString}

/** 最小重触发间隔。 */
private let MIN_REFIRE_GAP_MS: Int64 = 2000

/** 运行卡住判定阈值（约 2h）。 */
private let STUCK_RUN_MS: Int64 = 2 * 60 * 60 * 1000

/** 每次启动最多立即补跑的积压任务数。 */
private let MAX_STARTUP_IMMEDIATE_RUNS: Int64 = 5

/** 启动补跑时的错峰间隔。 */
private let STARTUP_MISSED_STAGGER_MS: Int64 = 5000

/** 一次性任务的瞬时错误重试上限。 */
private let MAX_AT_TRANSIENT_RETRIES: Int64 = 3

/** 调度错误上限。 */
private let MAX_SCHEDULE_ERRORS: Int64 = 3

/** 单次 arm sleep 的最大时长。 */
private let MAX_TIMER_DELAY_MS: Int64 = 60_000

public struct CronSessionExecutionOptions {
    public let modelOverride: String
    public let thinkingLevel: String
    public let lightContext: Bool
    public let timeoutMs: Int64
    public let timeoutSeconds: Int64
    public let bestEffortDeliver: Bool

    public init(
        modelOverride!: String = "",
        thinkingLevel!: String = "",
        lightContext!: Bool = false,
        timeoutMs!: Int64 = 0,
        timeoutSeconds!: Int64 = 0,
        bestEffortDeliver!: Bool = false
    ) {
        this.modelOverride = modelOverride.trimAscii()
        this.thinkingLevel = thinkingLevel.trimAscii().toAsciiLower()
        this.lightContext = lightContext
        this.timeoutMs = timeoutMs
        this.timeoutSeconds = timeoutSeconds
        this.bestEffortDeliver = bestEffortDeliver
    }
}

private func cronTimeoutSecondsFromMs(timeoutMs: Int64): Int64 {
    if (timeoutMs <= 0) {
        return 0
    }
    (timeoutMs + 999) / 1000
}

public func cronBuildSessionExecutionOptions(job: CronJob): CronSessionExecutionOptions {
    CronSessionExecutionOptions(
        modelOverride: job.modelOverride,
        thinkingLevel: job.thinkingLevel,
        lightContext: job.lightContext,
        timeoutMs: job.timeoutMs,
        timeoutSeconds: cronTimeoutSecondsFromMs(job.timeoutMs),
        bestEffortDeliver: job.bestEffortDeliver
    )
}

public func cronTurnContextWithExecutionOptions(
    context: GatewayTurnContext,
    options: CronSessionExecutionOptions
): GatewayTurnContext {
    GatewayTurnContext(
        context.agentId,
        workspaceDir: context.workspaceDir,
        agentDir: context.agentDir,
        modelsJsonPath: context.modelsJsonPath,
        authProfilesPath: context.authProfilesPath,
        legacyAuthPath: context.legacyAuthPath,
        sessionsDir: context.sessionsDir,
        sessionKey: context.sessionKey,
        mainSessionKey: context.mainSessionKey,
        matchedBy: context.matchedBy,
        lastRoutePolicy: context.lastRoutePolicy,
        modelRef: context.modelRef,
        channelName: context.channelName,
        accountId: context.accountId,
        peerId: context.peerId,
        threadId: context.threadId,
        senderId: context.senderId,
        operatorScopes: context.operatorScopes,
        chatType: context.chatType,
        route: context.route,
        agentScope: context.agentScope,
        modelRefOverride: options.modelOverride,
        thinkingLevel: options.thinkingLevel,
        lightContext: options.lightContext
    )
}

private func epochMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

private func computeCronArmDelayMs(jobs: ArrayList<CronJob>, nowMs: Int64): Int64 {
    var nextAt: Int64 = Int64.Max
    for (j in jobs) {
        if (!j.enabled) {
            continue
        }
        let n = j.state.nextRunAtMs
        if (n > 0 && n < nextAt) {
            nextAt = n
        }
    }
    if (nextAt == Int64.Max) {
        return MAX_TIMER_DELAY_MS
    }
    var delay = nextAt - nowMs
    if (delay < 0) {
        delay = 0
    }
    let floored = if (delay == 0) {
        MIN_REFIRE_GAP_MS
    } else {
        delay
    }
    min(floored, MAX_TIMER_DELAY_MS)
}

private func backoffDelayMs(job: CronJob, attempt: Int64): Int64 {
    let base = if (job.retryBackoffMs > 0) {
        job.retryBackoffMs
    } else {
        1000
    }
    let factor = if (attempt <= 0) {
        1
    } else {
        attempt + 1
    }
    base * factor
}

private let cronRunnerTestHookLock = Mutex()
private var cronRunnerReplyForTest: Option<(CronJob, GatewaySessionRequest) -> String> =
    None<(CronJob, GatewaySessionRequest) -> String>
private var cronRunnerBeforeExecuteForTest: Option<(CronJob) -> Unit> = None<(CronJob) -> Unit>
private var cronRunnerRunLogAppendForTest: Option<() -> Unit> = None<() -> Unit>

public func debugSetCronRunnerReplyForTest(hook: Option<(CronJob, GatewaySessionRequest) -> String>): Unit {
    synchronized(cronRunnerTestHookLock) {
        cronRunnerReplyForTest = hook
    }
}

public func debugSetCronRunnerBeforeExecuteForTest(hook: Option<(CronJob) -> Unit>): Unit {
    synchronized(cronRunnerTestHookLock) {
        cronRunnerBeforeExecuteForTest = hook
    }
}

public func debugSetCronRunnerRunLogAppendForTest(hook: Option<() -> Unit>): Unit {
    synchronized(cronRunnerTestHookLock) {
        cronRunnerRunLogAppendForTest = hook
    }
}

private func cronRunnerReplyHookForTest(): Option<(CronJob, GatewaySessionRequest) -> String> {
    synchronized(cronRunnerTestHookLock) {
        cronRunnerReplyForTest
    }
}

private func cronRunnerBeforeExecuteHookForTest(): Option<(CronJob) -> Unit> {
    synchronized(cronRunnerTestHookLock) {
        cronRunnerBeforeExecuteForTest
    }
}

private func cronRunnerRunLogAppendHookForTest(): Option<() -> Unit> {
    synchronized(cronRunnerTestHookLock) {
        cronRunnerRunLogAppendForTest
    }
}

/**
 * 网关进程内定时任务执行器：提供锁、启动错峰、running 标记、错误退避等核心语义。
 */
public class CronRunner {
    private let gatewayOpt: Option<GatewayService>
    private let storePath: Path
    private let cronEnabled: Bool
    private let jobs: ArrayList<CronJob>
    private let lastFireWallMs: HashMap<String, Int64> = HashMap<String, Int64>()
    private let tickLock: Mutex = Mutex()
    private var startupCatchupDone: Bool = false
    /** 早于该时刻跳过 `tickInner`，减少 200ms 轮询下的空转。 */
    private var nextCronArmAtMs: Int64 = 0
    private let cronReaper: GatewayCronSessionReaperState = GatewayCronSessionReaperState()

    public init(
        gatewayOpt!: Option<GatewayService> = None,
        storePath!: Path = cronStorePath(CliConfig.dotDir),
        cronEnabled!: Bool = true
    ) {
        this.gatewayOpt = gatewayOpt
        this.storePath = storePath
        this.cronEnabled = cronEnabled
        this.jobs = ArrayList<CronJob>()
        for (j in cronLoadOrEmpty(storePath)) {
            this.jobs.add(j)
        }
    }

    public func storeFilePath(): Path {
        this.storePath
    }

    public static func loadJobsForDisplay(path: Path): Array<CronJob> {
        cronLoadOrEmpty(path)
    }

    private func recordScheduleComputeFailure(j: CronJob): Unit {
        j.state.scheduleErrorCount += 1
        j.state.nextRunAtMs = 0
        gatewayLogEventWarn(
            "gateway/cron",
            "cron.failed",
            "cron schedule compute failed",
            meta: gatewayLogMeta()
                .string("jobId", j.id)
                .int("scheduleErrorCount", j.state.scheduleErrorCount)
                .object()
        )
        if (j.state.scheduleErrorCount >= MAX_SCHEDULE_ERRORS) {
            j.enabled = false
            gatewayLogEventError(
                "gateway/cron",
                "cron.disabled",
                "cron job auto-disabled after repeated schedule errors",
                meta: gatewayLogMeta().string("jobId", j.id).object()
            )
        }
    }

    private func clearStuckRunningMarkers(now: Int64): Bool {
        var changed = false
        for (j in this.jobs) {
            let r = j.state.runningAtMs
            if (r > 0 && now - r > STUCK_RUN_MS) {
                gatewayLogEventInfo(
                    "gateway/cron",
                    "cron.skipped",
                    "cleared stale cron running marker",
                    meta: gatewayLogMeta().string("jobId", j.id).int("runningAtMs", r).object()
                )
                j.state.runningAtMs = 0
                changed = true
            }
        }
        changed
    }

    private func jobExecutionInFlight(j: CronJob, now: Int64): Bool {
        let r = j.state.runningAtMs
        if (r <= 0) {
            return false
        }
        if (now - r > STUCK_RUN_MS) {
            return false
        }
        true
    }

    /**
     * 启动后首轮：若积压到期任务过多，只立即跑前 N 个，其余按当前错峰策略推迟 `nextRunAtMs`。
     */
    private func applyStartupMissedJobStaggerIfNeeded(now: Int64): Bool {
        if (this.startupCatchupDone) {
            return false
        }
        this.startupCatchupDone = true
        var due = ArrayList<CronJob>()
        for (j in this.jobs) {
            if (!j.enabled) {
                continue
            }
            if (this.jobExecutionInFlight(j, now)) {
                continue
            }
            if (j.state.nextRunAtMs > 0 && j.state.nextRunAtMs <= now) {
                due.add(j)
            }
        }
        if (due.size <= MAX_STARTUP_IMMEDIATE_RUNS) {
            return false
        }
        let arr = due.toArray()
        sort(
            arr,
            by: {
                a, b => a.state.nextRunAtMs.compare(b.state.nextRunAtMs)
            },
            stable: true
        )
        var changed = false
        var off = STARTUP_MISSED_STAGGER_MS
        var idx = MAX_STARTUP_IMMEDIATE_RUNS
        while (idx < arr.size) {
            arr[idx].state.nextRunAtMs = now + off
            off += STARTUP_MISSED_STAGGER_MS
            idx += 1
            changed = true
        }
        if (changed) {
            gatewayLogEventInfo(
                "gateway/cron",
                "cron.scheduled",
                "staggered missed cron jobs",
                meta: gatewayLogMeta()
                    .int("deferred", arr.size - MAX_STARTUP_IMMEDIATE_RUNS)
                    .int("due", arr.size)
                    .object()
            )
        }
        changed
    }

    private func persist(): Unit {
        let fresh = cronLoadOrEmpty(this.storePath)
        if (fresh.size == 0) {
            if (this.jobs.size == 0) {
                return
            }
            cronSave(this.storePath, Array<CronJob>())
            this.jobs.clear()
            return
        }
        let memById = HashMap<String, CronJob>()
        for (j in this.jobs) {
            memById[j.id] = j
        }
        let out = ArrayList<CronJob>()
        for (d in fresh) {
            if (let Some(m) <- memById.get(d.id)) {
                d.state.nextRunAtMs = m.state.nextRunAtMs
                d.state.lastRunAtMs = m.state.lastRunAtMs
                d.state.lastError = m.state.lastError
                d.state.lastStatus = m.state.lastStatus
                d.state.consecutiveErrors = m.state.consecutiveErrors
                d.state.runningAtMs = m.state.runningAtMs
                d.state.scheduleErrorCount = m.state.scheduleErrorCount
                d.state.lastFailureAlertAtMs = m.state.lastFailureAlertAtMs
                if (m.createdAtMs > 0) {
                    d.createdAtMs = m.createdAtMs
                }
                let sk = m.schedule.kind.trimAscii().toAsciiLower()
                if (sk == "at" && !m.enabled) {
                    d.enabled = false
                }
                if (!m.enabled) {
                    d.enabled = false
                }
                out.add(d)
            } else {
                out.add(d)
            }
        }
        cronSave(this.storePath, out.toArray())
        this.jobs.clear()
        for (j in out) {
            this.jobs.add(j)
        }
    }

    private func executeJobReply(
        j: CronJob,
        bridge: AgentBridge,
        request: GatewaySessionRequest,
        prompt: String,
        options: CronSessionExecutionOptions,
        turnContextOverride: Option<GatewayTurnContext>
    ): String {
        let startedAt = epochMs()
        match (cronRunnerReplyHookForTest()) {
            case Some(hook) =>
                let answer = hook(j, request)
                this.logCronWebOutcome(j, answer, epochMs() - startedAt)
                return answer
            case None => ()
        }
        if (cronShouldRouteThroughDreaming(j)) {
            match (DreamingPhaseRuntime.handleSystemEvent(j.systemEvent)) {
                case Some(result) =>
                    gatewayLogEventInfo(
                        "gateway/cron",
                        "cron.succeeded",
                        "handled managed cron system event",
                        meta: gatewayLogMeta()
                            .string("jobId", j.id)
                            .string("systemEvent", j.systemEvent)
                            .object()
                    )
                    this.logCronWebOutcome(j, result, epochMs() - startedAt)
                    return result
                case None =>
                    let answer = cronBridgeReply(bridge, request, prompt, options, turnContextOverride: turnContextOverride)
                    this.logCronWebOutcome(j, answer, epochMs() - startedAt)
                    return answer
            }
        }
        let answer = cronBridgeReply(bridge, request, prompt, options, turnContextOverride: turnContextOverride)
        this.logCronWebOutcome(j, answer, epochMs() - startedAt)
        answer
    }

    private func cronWebProviderIdFromAnswer(answer: String): String {
        let parts = answer.split("Provider:", 2)
        if (parts.size < 2) {
            return ""
        }
        metisSafeRuneEllipsis(gatewayLogRedactText(parts[1].split("\n", 2)[0].trimAscii()), 80)
    }

    private func logCronWebOutcome(j: CronJob, answer: String, durationMs: Int64): Unit {
        let providerId = this.cronWebProviderIdFromAnswer(answer)
        let safeDurationMs = if (durationMs >= 0) { durationMs } else { 0 }
        match (cronWebDiagnosticFromText(answer)) {
            case Some(diagnostic) =>
                try {
                    gatewayLogEventWarn(
                        "gateway/cron",
                        "cron.web_tool_unavailable",
                        "cron web tool returned diagnostic",
                        meta: gatewayLogMeta()
                            .string("jobId", j.id)
                            .string("diagnosticCode", diagnostic.code)
                            .string("providerId", providerId)
                            .int("durationMs", safeDurationMs)
                            .object()
                    )
                } catch (_: Exception) {
                    ()
                }
            case None =>
                if (answer.contains("Tool: web_search") || answer.contains("Tool: web_fetch") || answer.contains("Tool: web_extract")) {
                    try {
                        gatewayLogEventInfo(
                            "gateway/cron",
                            "cron.web_tool_used",
                            "cron web tool returned content",
                            meta: gatewayLogMeta()
                                .string("jobId", j.id)
                                .string("providerId", providerId)
                                .int("durationMs", safeDurationMs)
                                .object()
                        )
                    } catch (_: Exception) {
                        ()
                    }
                }
        }
    }

    private func appendRunLogIsolated(
        j: CronJob,
        status: String,
        startedAtMs: Int64,
        endedAtMs: Int64,
        errMsg: String,
        answer: String,
        deliveryStatus: String,
        deliveryError: String,
        diagnosticCode!: String = "",
        diagnosticMessage!: String = ""
    ): Unit {
        try {
            match (cronRunnerRunLogAppendHookForTest()) {
                case Some(hook) =>
                    hook()
                    return
                case None => ()
            }
            appendCronRunLog(
                this.storePath,
                j.id,
                status,
                startedAtMs,
                endedAtMs,
                errorMessage: errMsg,
                sessionTarget: j.sessionTarget,
                summary: answer,
                runAtMs: startedAtMs,
                nextRunAtMs: j.state.nextRunAtMs,
                deliveryStatus: deliveryStatus,
                deliveryError: deliveryError,
                diagnosticCode: diagnosticCode,
                diagnosticMessage: diagnosticMessage
            )
        } catch (logError: Exception) {
            gatewayLogEventError(
                "gateway/cron",
                "cron.run_log_failed",
                "cron run log append failed",
                meta: gatewayLogMeta()
                    .string("jobId", j.id)
                    .string("status", status)
                    .int("durationMs", if (endedAtMs >= startedAtMs) { endedAtMs - startedAtMs } else { 0 })
                    .rawString("error", logError.message)
                    .object()
            )
        }
    }

    private func cronShellRunDiagnosticCode(answer: String, errMsg: String): String {
        match (cronShellExecutionBlockedDiagnosticFromText(answer + "\n" + errMsg)) {
            case Some(diagnostic) => diagnostic.code
            case None => ""
        }
    }

    private func cronShellRunDiagnosticMessage(answer: String, errMsg: String): String {
        match (cronShellExecutionBlockedDiagnosticFromText(answer + "\n" + errMsg)) {
            case Some(diagnostic) => diagnostic.message
            case None => ""
        }
    }

    private func cronDerivedRunDiagnosticCode(answer: String, errMsg: String): String {
        let shellCode = cronShellRunDiagnosticCode(answer, errMsg)
        if (!shellCode.isEmpty()) {
            return shellCode
        }
        match (cronWebDiagnosticFromText(answer + "\n" + errMsg)) {
            case Some(diagnostic) => diagnostic.code
            case None => ""
        }
    }

    private func cronDerivedRunDiagnosticMessage(answer: String, errMsg: String): String {
        let shellMessage = cronShellRunDiagnosticMessage(answer, errMsg)
        if (!shellMessage.isEmpty()) {
            return shellMessage
        }
        match (cronWebDiagnosticFromText(answer + "\n" + errMsg)) {
            case Some(diagnostic) => diagnostic.message
            case None => ""
        }
    }

    private func cronScriptFailureMessage(result: CronScriptRunResult): String {
        let code = if (result.errorCode.trimAscii().isEmpty()) { result.status } else { result.errorCode }
        let detail = if (!result.message.trimAscii().isEmpty()) {
            result.message
        } else if (!result.stderr.trimAscii().isEmpty()) {
            result.stderr
        } else {
            result.status
        }
        "cron_script_failed:${code}: ${detail}"
    }

    private func cronPromptWithScriptOutput(scriptOutput: String, prompt: String): String {
        "## Script Output\n${scriptOutput}\n\n## Cron Prompt\n${prompt}"
    }

    private func deliveryFailureMessage(kind: String, raw: String): String {
        let trimmed = gatewayLogRedactText(raw).trimAscii()
        if (trimmed.isEmpty()) {
            return "${kind} delivery failed"
        }
        "${kind} delivery failed: ${trimmed}"
    }

    private func markDeliveryFailure(
        j: CronJob,
        channel: String,
        accountId: String,
        peerId: String,
        deliveryStatus: String,
        errorKind: String,
        error: String
    ): Unit {
        gatewayLogEventError(
            "gateway/cron",
            "cron.delivery_failed",
            "cron delivery failed",
            meta: gatewayLogMeta()
                .string("jobId", j.id)
                .string("channel", channel)
                .string("accountId", accountId)
                .identityHash("peerHash", peerId)
                .string("deliveryStatus", deliveryStatus)
                .string("errorKind", errorKind)
                .rawString("error", error)
                .object()
        )
    }

    private func sendSuccessDelivery(
        j: CronJob,
        dplan: CronDeliveryResolved,
        answer: String,
        startedAtMs: Int64
    ): (String, String) {
        let dm = dplan.mode.trimAscii().toAsciiLower()
        if (dm == "announce") {
            let dc = cronEffectiveAnnounceChannel(dplan.channel, j.deliveryChannel)
            let dt = dplan.to.trimAscii()
            if (dc.isEmpty() || dt.isEmpty()) {
                return ("not-delivered", "announce delivery target is empty")
            }
            if (let Some(gw) <- this.gatewayOpt) {
                try {
                    let body = if (j.deliveryAnnounce) {
                        "[cron:${j.id}]\n${answer}"
                    } else {
                        answer
                    }
                    let messageId = gw.sendTextToPeerDetailed(dc, dt, body, accountId: dplan.accountId)
                    return (if (messageId.trimAscii().isEmpty()) { "unknown" } else { "delivered" }, "")
                } catch (sendError: Exception) {
                    this.markDeliveryFailure(j, dc, dplan.accountId, dt, "not-delivered", "send_failed", sendError.message)
                    return ("not-delivered", this.deliveryFailureMessage("announce", sendError.message))
                }
            }
            this.markDeliveryFailure(j, dc, dplan.accountId, dt, "not-delivered", "gateway_unavailable", "GatewayService is not available")
            return ("not-delivered", this.deliveryFailureMessage("announce", "GatewayService is not available"))
        }
        if (dm == "webhook") {
            let url = dplan.to.trimAscii()
            let body = buildCronWebhookSuccessBody(
                j.id,
                "ok",
                answer,
                startedAtMs,
                j.sessionTarget
            )
            if (postCronWebhookJson(url, body, timeoutMs: cronWebhookTimeoutMs(j.timeoutMs))) {
                return ("delivered", "")
            }
            this.markDeliveryFailure(j, "webhook", dplan.accountId, url, "not-delivered", "webhook_failed", "webhook post returned false")
            return ("not-delivered", this.deliveryFailureMessage("webhook", "webhook post returned false"))
        }
        ("not-requested", "")
    }

    private func shouldSendFailureAlert(j: CronJob, fplan: CronFailureResolved, nowMs: Int64): Bool {
        if (fplan.alertAfter > 0 && j.state.consecutiveErrors < fplan.alertAfter) {
            return false
        }
        if (fplan.alertCooldownMs > 0 && j.state.lastFailureAlertAtMs > 0) {
            if (nowMs - j.state.lastFailureAlertAtMs < fplan.alertCooldownMs) {
                return false
            }
        }
        true
    }

    private func sendFailureAlert(j: CronJob, fplan: CronFailureResolved, errMsg: String, startedAtMs: Int64): Bool {
        let fm = fplan.mode.trimAscii().toAsciiLower()
        if (fm == "announce") {
            let fc = cronEffectiveAnnounceChannel(fplan.channel, j.failureChannel)
            let ft = fplan.to.trimAscii()
            if (fc.isEmpty() || ft.isEmpty()) {
                return false
            }
            if (let Some(gw) <- this.gatewayOpt) {
                try {
                    let body = if (j.failureAnnounce) {
                        "[cron-failure:${j.id}] ${errMsg}"
                    } else {
                        errMsg
                    }
                    let messageId = gw.sendTextToPeerDetailed(fc, ft, body, accountId: fplan.accountId)
                    return !messageId.trimAscii().isEmpty()
                } catch (sendError: Exception) {
                    this.markDeliveryFailure(j, fc, fplan.accountId, ft, "not-delivered", "failure_alert_send_failed", sendError.message)
                    return false
                }
            }
            this.markDeliveryFailure(j, fc, fplan.accountId, ft, "not-delivered", "gateway_unavailable", "GatewayService is not available")
            return false
        }
        if (fm == "webhook") {
            let fu = fplan.to.trimAscii()
            let fb = buildCronWebhookFailureBody(j.id, errMsg, startedAtMs, j.sessionTarget)
            let delivered = postCronWebhookJson(fu, fb, timeoutMs: cronWebhookTimeoutMs(j.timeoutMs))
            if (!delivered) {
                this.markDeliveryFailure(j, "webhook", fplan.accountId, fu, "not-delivered", "failure_webhook_failed", "webhook post returned false")
            }
            return delivered
        }
        false
    }

    private func reloadJobsFromDisk(): Unit {
        this.jobs.clear()
        for (j in cronLoadOrEmpty(this.storePath)) {
            this.jobs.add(j)
        }
    }

    private func ensureSchedulesSeeded(now: Int64): Bool {
        var changed = false
        for (j in this.jobs) {
            if (!j.enabled) {
                continue
            }
            if (j.state.nextRunAtMs > 0) {
                continue
            }
            match (computeJobNextRun(j, now)) {
                case Some(nxt) =>
                    j.state.nextRunAtMs = nxt
                    j.state.scheduleErrorCount = 0
                    changed = true
                case None =>
                    j.state.nextRunAtMs = 0
                    this.recordScheduleComputeFailure(j)
                    changed = true
            }
        }
        changed
    }

    private func finalizeSuccess(j: CronJob, startedAtMs: Int64, afterRun: Int64): Unit {
        j.state.runningAtMs = 0
        j.state.lastRunAtMs = startedAtMs
        j.state.lastError = ""
        j.state.lastStatus = "success"
        j.state.consecutiveErrors = 0
        j.state.scheduleErrorCount = 0
        let sk = j.schedule.kind.trimAscii().toAsciiLower()
        if (sk == "at") {
            j.enabled = false
            j.state.nextRunAtMs = 0
            return
        }
        match (computeJobNextRun(j, afterRun)) {
            case Some(nxt) =>
                var nn = nxt
                if (sk == "cron") {
                    let minNext = afterRun + MIN_REFIRE_GAP_MS
                    if (nn < minNext) {
                        nn = minNext
                    }
                }
                j.state.nextRunAtMs = nn
            case None =>
                j.state.nextRunAtMs = 0
                this.recordScheduleComputeFailure(j)
        }
    }

    /**
     * 执行单任务一次（Agent + 投递 + finalize + run log），供 tick 与手动 run 共用。
     * 调用前须已设置 `j.state.runningAtMs = startedAtMs`。
     */
    private func fireSingleJob(j: CronJob, wallNowMs: Int64, startedAtMs: Int64): Unit {
        let dplan = resolveCronDeliveryPlan(j)
        var status = "success"
        var errMsg = ""
        var answer = ""
        var deliveryStatus = "not-requested"
        var deliveryError = ""
        var diagnosticCode = ""
        var diagnosticMessage = ""
        var attempt: Int64 = 0
        let maxAttempts = max(1, j.maxRetries + 1)

        try {
            let promptScan = scanCronPromptAssembled(j.prompt)
            if (!promptScan.ok) {
                let afterRun = epochMs()
                status = "error"
                errMsg = "cron_prompt_blocked:${promptScan.threatId}"
                try {
                    gatewayLogEventWarn(
                        "gateway/cron",
                        "cron.prompt_blocked",
                        "cron prompt blocked",
                        meta: cronPromptScanMeta(j.id, promptScan, j.prompt, "runtime")
                    )
                } catch (_: Exception) {
                    ()
                }
                this.finalizeError(j, startedAtMs, afterRun, errMsg)
                match (resolveCronFailurePlan(j, dplan)) {
                    case Some(fplan) =>
                        if (this.shouldSendFailureAlert(j, fplan, afterRun)) {
                            if (this.sendFailureAlert(j, fplan, errMsg, startedAtMs)) {
                                j.state.lastFailureAlertAtMs = afterRun
                            }
                        }
                    case None => ()
                }
                this.appendRunLogIsolated(j, status, startedAtMs, afterRun, errMsg, answer, deliveryStatus, deliveryError)
                return
            }
            var effectivePrompt = j.prompt
            var skipAgent = false
            var skipSuccessDelivery = false
            let scriptMode = cronNormalizeScriptMode(j.scriptMode)
            if (scriptMode != "none") {
                let scriptResult = runCronJobScriptForJob(CliConfig.dotDir, j)
                if (!scriptResult.ok) {
                    let afterRun = epochMs()
                    status = "error"
                    errMsg = this.cronScriptFailureMessage(scriptResult)
                    diagnosticCode = scriptResult.errorCode
                    diagnosticMessage = errMsg
                    this.finalizeError(j, startedAtMs, afterRun, errMsg)
                    match (resolveCronFailurePlan(j, dplan)) {
                        case Some(fplan) =>
                            if (this.shouldSendFailureAlert(j, fplan, afterRun)) {
                                if (this.sendFailureAlert(j, fplan, errMsg, startedAtMs)) {
                                    j.state.lastFailureAlertAtMs = afterRun
                                }
                            }
                        case None => ()
                    }
                    this.appendRunLogIsolated(
                        j,
                        status,
                        startedAtMs,
                        afterRun,
                        errMsg,
                        answer,
                        deliveryStatus,
                        deliveryError,
                        diagnosticCode: diagnosticCode,
                        diagnosticMessage: diagnosticMessage
                    )
                    return
                }
                if (scriptResult.output.trimAscii().isEmpty()) {
                    answer = ""
                    skipAgent = true
                    skipSuccessDelivery = true
                } else if (scriptMode == "noAgent") {
                    answer = scriptResult.output
                    skipAgent = true
                } else {
                    effectivePrompt = this.cronPromptWithScriptOutput(scriptResult.output, j.prompt)
                }
            }
            if (!skipAgent) {
                match (cronRunnerBeforeExecuteHookForTest()) {
                    case Some(hook) => hook(j)
                    case None => ()
                }
            }
            let jobRequest = cronBuildSessionRequestWithPrompt(j, startedAtMs, effectivePrompt)
            let options = cronBuildSessionExecutionOptions(j)
            let turnContextOverride = Some(
                cronTurnContextWithExecutionOptions(
                    gatewayResolveSessionContextWithAgentRoute(jobRequest).turnContext,
                    options
                )
            )
            if (!skipAgent) {
                let jobBridge = gatewayBridgeForSessionRequest(CliSettingManager.readGatewaySettings(), jobRequest)
                while (attempt < maxAttempts) {
                    try {
                        answer = this.executeJobReply(j, jobBridge, jobRequest, effectivePrompt, options, turnContextOverride)
                        status = "success"
                        errMsg = ""
                        break
                    } catch (e: Exception) {
                        status = "error"
                        errMsg = e.message
                        gatewayLogEventError(
                            "gateway/cron",
                            "cron.failed",
                            "cron job attempt failed",
                            meta: gatewayLogMeta()
                                .string("jobId", j.id)
                                .int("attempt", attempt + 1)
                                .int("maxAttempts", maxAttempts)
                                .rawString("error", e.message)
                                .object()
                        )
                        if (attempt + 1 >= maxAttempts) {
                            break
                        }
                        sleep(Duration.millisecond * backoffDelayMs(j, attempt))
                    }
                    attempt += 1
                }
            }

            if (status == "success" && dplan.requested && !skipSuccessDelivery) {
                let deliveryResult = this.sendSuccessDelivery(j, dplan, answer, startedAtMs)
                deliveryStatus = deliveryResult[0]
                deliveryError = deliveryResult[1]
                if (deliveryStatus == "not-delivered" && !dplan.bestEffortDeliver) {
                    status = "error"
                    errMsg = deliveryError
                }
            } else if (!dplan.requested) {
                deliveryStatus = "not-requested"
            }

            let afterRun = epochMs()
            if (status == "success") {
                this.finalizeSuccess(j, startedAtMs, afterRun)
            } else {
                this.finalizeError(j, startedAtMs, afterRun, errMsg)
                match (resolveCronFailurePlan(j, dplan)) {
                    case Some(fplan) =>
                        if (this.shouldSendFailureAlert(j, fplan, afterRun)) {
                            if (this.sendFailureAlert(j, fplan, errMsg, startedAtMs)) {
                                j.state.lastFailureAlertAtMs = afterRun
                            }
                        }
                    case None => ()
                }
            }

            this.appendRunLogIsolated(
                j,
                status,
                startedAtMs,
                afterRun,
                errMsg,
                answer,
                deliveryStatus,
                deliveryError,
                diagnosticCode: if (diagnosticCode.isEmpty()) { this.cronDerivedRunDiagnosticCode(answer, errMsg) } else { diagnosticCode },
                diagnosticMessage: if (diagnosticMessage.isEmpty()) { this.cronDerivedRunDiagnosticMessage(answer, errMsg) } else { diagnosticMessage }
            )
        } catch (fatal: Exception) {
            let afterRun = epochMs()
            status = "error"
            errMsg = fatal.message
            this.finalizeError(j, startedAtMs, afterRun, errMsg)
            this.appendRunLogIsolated(
                j,
                status,
                startedAtMs,
                afterRun,
                errMsg,
                answer,
                deliveryStatus,
                deliveryError,
                diagnosticCode: this.cronDerivedRunDiagnosticCode(answer, errMsg),
                diagnosticMessage: this.cronDerivedRunDiagnosticMessage(answer, errMsg)
            )
            gatewayLogEventError(
                "gateway/cron",
                "cron.failed",
                "unexpected cron job failure",
                meta: gatewayLogMeta()
                    .string("jobId", j.id)
                    .string("status", status)
                    .int("durationMs", if (afterRun >= startedAtMs) { afterRun - startedAtMs } else { 0 })
                    .rawString("error", fatal.message)
                    .object()
            )
        }
    }

    /**
     * 手动执行一次（对齐当前 `cron.run` force/due 语义）：从磁盘加载、可选到期检查、执行并持久化。
     */
    public func runJobManual(jobId: String, force: Bool): JsonObject {
        let out = JsonObject()
        synchronized(this.tickLock) {
            this.reloadJobsFromDisk()
            var now = epochMs()
            let _cleared = this.clearStuckRunningMarkers(now)
            if (_cleared) {
                this.persist()
                this.reloadJobsFromDisk()
            }
            now = epochMs()
            var target: Option<CronJob> = None<CronJob>
            for (x in this.jobs) {
                if (x.id == jobId) {
                    target = Some(x)
                }
            }
            match (target) {
                case None =>
                    out.put("ok", JsonBool(false))
                    out.put("error", JsonString("unknown job id"))
                    return out
                case Some(j) =>
                    if (!j.enabled) {
                        out.put("ok", JsonBool(false))
                        out.put("error", JsonString("job disabled"))
                        return out
                    }
                    if (this.jobExecutionInFlight(j, now)) {
                        out.put("ok", JsonBool(true))
                        out.put("ran", JsonBool(false))
                        out.put("reason", JsonString("already-running"))
                        return out
                    }
                    if (!force && !isCronDue(j.state, now, j.schedule)) {
                        out.put("ok", JsonBool(true))
                        out.put("ran", JsonBool(false))
                        out.put("reason", JsonString("not-due"))
                        return out
                    }
                    let startedAtMs = epochMs()
                    let wallNow = now
                    this.lastFireWallMs[j.id] = wallNow
                    j.state.runningAtMs = startedAtMs
                    this.fireSingleJob(j, wallNow, startedAtMs)
                    if (j.deleteAfterRun && j.state.lastStatus.trimAscii().toAsciiLower() == "success") {
                        let filtered = ArrayList<CronJob>()
                        for (x in this.jobs) {
                            if (x.id != jobId) {
                                filtered.add(x)
                            }
                        }
                        this.jobs.clear()
                        for (x in filtered) {
                            this.jobs.add(x)
                        }
                    }
                    this.persist()
                    out.put("ok", JsonBool(true))
                    out.put("ran", JsonBool(true))
                    out.put("jobId", JsonString(jobId))
                    return out
            }
        }
        out
    }

    public static func runJobOnceFromStore(
        gatewayOpt: Option<GatewayService>,
        storePath: Path,
        jobId: String,
        force: Bool,
        cronEnabled!: Bool = true
    ): JsonObject {
        let runner = CronRunner(gatewayOpt: gatewayOpt, storePath: storePath, cronEnabled: cronEnabled)
        runner.runJobManual(jobId, force)
    }

    private func finalizeError(j: CronJob, startedAtMs: Int64, afterRun: Int64, errMsg: String): Unit {
        j.state.runningAtMs = 0
        j.state.lastRunAtMs = startedAtMs
        j.state.lastStatus = "error"
        j.state.lastError = errMsg
        j.state.consecutiveErrors += 1
        let sk = j.schedule.kind.trimAscii().toAsciiLower()
        if (sk == "at") {
            if (isTransientCronError(errMsg) && j.state.consecutiveErrors <= MAX_AT_TRANSIENT_RETRIES) {
                let bo = afterRun + cronErrorBackoffMs(j.state.consecutiveErrors)
                j.state.nextRunAtMs = bo
                gatewayLogEventWarn(
                    "gateway/cron",
                    "cron.failed",
                    "transient one-shot cron error scheduled retry",
                    meta: gatewayLogMeta()
                        .string("jobId", j.id)
                        .int("retryDelayMs", bo - afterRun)
                        .rawString("error", errMsg)
                        .object()
                )
            } else {
                j.enabled = false
                j.state.nextRunAtMs = 0
                gatewayLogEventWarn(
                    "gateway/cron",
                    "cron.disabled",
                    "one-shot cron job disabled after error",
                    meta: gatewayLogMeta()
                        .string("jobId", j.id)
                        .rawString("error", errMsg)
                        .object()
                )
            }
            return
        }
        match (computeJobNextRun(j, afterRun)) {
            case Some(natural) =>
                let bo = afterRun + cronErrorBackoffMs(j.state.consecutiveErrors)
                j.state.nextRunAtMs = max(natural, bo)
            case None =>
                j.state.scheduleErrorCount += 1
                if (j.state.scheduleErrorCount >= MAX_SCHEDULE_ERRORS) {
                    j.enabled = false
                    j.state.nextRunAtMs = 0
                    gatewayLogEventError(
                        "gateway/cron",
                        "cron.disabled",
                        "recurring cron job auto-disabled after schedule errors",
                        meta: gatewayLogMeta()
                            .string("jobId", j.id)
                            .int("scheduleErrorCount", j.state.scheduleErrorCount)
                            .rawString("error", errMsg)
                            .object()
                    )
                } else {
                    j.state.nextRunAtMs = afterRun + cronErrorBackoffMs(j.state.consecutiveErrors)
                }
        }
    }

    public func tick(nowOverride!: Option<Int64> = None): Unit {
        let nowPeek = match (nowOverride) {
            case Some(t) => t
            case None => epochMs()
        }
        if (this.cronEnabled && nowPeek < this.nextCronArmAtMs) {
            return
        }
        synchronized(this.tickLock) {
            let nowGate = match (nowOverride) {
                case Some(t) => t
                case None => epochMs()
            }
            if (this.cronEnabled && nowGate < this.nextCronArmAtMs) {
                return
            }
            this.tickInner(nowOverride)
            let after = epochMs()
            if (this.cronEnabled) {
                this.nextCronArmAtMs = after + computeCronArmDelayMs(this.jobs, after)
            } else {
                this.nextCronArmAtMs = after + MAX_TIMER_DELAY_MS
            }
        }
    }

    private func tickInner(nowOverride: Option<Int64>): Unit {
        if (!this.cronEnabled) {
            return
        }
        let now = match (nowOverride) {
            case Some(t) => t
            case None => epochMs()
        }
        this.reloadJobsFromDisk()
        var preChanged = this.clearStuckRunningMarkers(now)
        if (this.applyStartupMissedJobStaggerIfNeeded(now)) {
            preChanged = true
        }
        if (preChanged) {
            this.persist()
            this.reloadJobsFromDisk()
        }

        let seeded = this.ensureSchedulesSeeded(now)
        if (seeded) {
            this.persist()
            this.reloadJobsFromDisk()
        }

        var needPersistAfterFire = false
        let removeAfterRun = ArrayList<String>()
        for (j in this.jobs) {
            if (!j.enabled) {
                continue
            }
            if (this.jobExecutionInFlight(j, now)) {
                continue
            }
            if (j.state.nextRunAtMs <= 0) {
                continue
            }
            if (j.state.nextRunAtMs > now) {
                continue
            }
            if (!isCronDue(j.state, now, j.schedule)) {
                continue
            }
            if (let Some(lastWall) <- this.lastFireWallMs.get(j.id)) {
                if (now - lastWall < MIN_REFIRE_GAP_MS) {
                    continue
                }
            }

            let startedAtMs = epochMs()
            let conv = cronExecutionConversationKey(j, startedAtMs)
            gatewayLogEventInfo(
                "gateway/cron",
                "cron.started",
                "cron job firing",
                meta: gatewayLogMeta()
                    .string("jobId", j.id)
                    .identityHash("conversationHash", conv)
                    .object()
            )
            this.lastFireWallMs[j.id] = now

            j.state.runningAtMs = startedAtMs
            this.fireSingleJob(j, now, startedAtMs)
            if (j.deleteAfterRun && j.state.lastStatus.trimAscii().toAsciiLower() == "success") {
                removeAfterRun.add(j.id)
            }
            needPersistAfterFire = true
        }
        if (!removeAfterRun.isEmpty()) {
            let nextJobs = ArrayList<CronJob>()
            for (x in this.jobs) {
                var drop = false
                for (rid in removeAfterRun) {
                    if (x.id == rid) {
                        drop = true
                    }
                }
                if (!drop) {
                    nextJobs.add(x)
                }
            }
            this.jobs.clear()
            for (x in nextJobs) {
                this.jobs.add(x)
            }
        }
        if (needPersistAfterFire) {
            this.persist()
        }
        let user = CliSettingManager.readGatewaySettings()
        let retentionH = user.cronRunSessionRetentionHours
        for (agentId in gatewayListPersistedAgentIdsForUser(user)) {
            this.cronReaper.sweepIfDue(gatewaySessionStoreForUserWithAgentId(user, agentId), retentionH)
        }
    }
}

public func cronBuildSessionRequest(job: CronJob, startedAtMs: Int64): GatewaySessionRequest {
    cronBuildSessionRequestWithPrompt(job, startedAtMs, job.prompt)
}

public func cronBuildSessionRequestWithPrompt(job: CronJob, startedAtMs: Int64, prompt: String): GatewaySessionRequest {
    let dplan = resolveCronDeliveryPlan(job)
    let dm = dplan.mode.trimAscii().toAsciiLower()
    let deliver = dplan.requested && dm == "announce"
    let replyChannel = if (deliver) {
        cronEffectiveAnnounceChannel(dplan.channel, job.deliveryChannel)
    } else {
        ""
    }
    let replyTo = if (deliver) {
        dplan.to
    } else {
        ""
    }
    GatewaySessionRequest(
        GatewayIngressSource.Cron,
        channelName: "cron",
        sessionHint: cronExecutionConversationKey(job, startedAtMs),
        agentId: job.agentId,
        text: prompt,
        replyChannel: replyChannel,
        replyTo: replyTo,
        replyAccountId: if (deliver) { dplan.accountId } else { "" },
        deliver: deliver,
        cronJobId: job.id,
        toolExecMode: job.toolExecMode,
        toolExecAllowlist: job.toolExecAllowlist
    )
}
