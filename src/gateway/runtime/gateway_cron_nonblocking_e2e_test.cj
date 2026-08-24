package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.config.buildGatewayConfigFromUserSettings
import metis.cron.{
    CronJob,
    CronJobState,
    CronSchedule,
    cronLoadOrEmpty,
    cronSave,
    cronScriptDecodeBytesForTest,
    cronScriptsDir,
    cronStorePath,
    executeGatewayCronCommand,
    readCronRunLogEntriesForJob
}
import metis.gateway.core.{
    ChannelAdapter,
    GatewayAgentReplyOutcome,
    GatewayRouter,
    GatewayService,
    gatewayRunFinalAnswerCorrection,
    gatewayCronHeadlessToolDenied,
    setGatewayAgentBridgeReplyRunnerForTest
}
import metis.gateway.model.{ChannelPolicyConfig, ChannelType, ChatType, InboundMessage, OutboundMessage, SendResult}
import metis.gateway.session.GatewaySessionRequest
import metis.process.{managedStdioBroker, resetManagedStdioBrokerForTest}

import std.collection.{ArrayList, HashMap}
import std.core.Duration
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.net.*
import std.sync.{AtomicBool, AtomicInt64, Mutex}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue
import stdx.net.http.*

/**
 * M5 的跨模块门禁使用真实 GatewayService/processOnce、CronRunner、session reply hook
 * 和 ChannelAdapter 边界；fake 只替代模型、工具、webhook/IM 网络。
 */
private func withCronM5E2eHome<T>(body: (Path) -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = "/tmp/metis-cron-m5-e2e-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
        try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", home)
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        try {
            return body(cronStorePath(CliConfig.dotDir))
        } finally {
            debugSetCronRunnerReplyForTest(None<(CronJob, GatewaySessionRequest) -> String>)
            debugSetCronRunnerOutcomeForTest(None<(CronJob, GatewaySessionRequest) -> GatewayAgentReplyOutcome>)
            debugSetCronRunnerBeforeExecuteForTest(None<(CronJob) -> Unit>)
            debugSetCronRunnerDeliveryStageForTest(None<(String) -> Unit>)
            debugSetCronRunnerDeliveryForTest(None<() -> Unit>)
            debugSetCronRunnerCommitForTest(None<(String) -> Unit>)
            setGatewayAgentBridgeReplyRunnerForTest(
                None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>
            )
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

private class CronM5E2eAdapter <: ChannelAdapter {
    private let adapterName: String
    private let failSend: Bool
    private let inbound = ArrayList<InboundMessage>()
    private let sent = ArrayList<String>()
    public var started: Bool = false
    public var stopped: Bool = false

    public init(adapterName: String, failSend!: Bool = false) {
        this.adapterName = adapterName
        this.failSend = failSend
    }

    public prop name: String {
        get() { this.adapterName }
    }

    public func start(): Unit { this.started = true }
    public func stop(): Unit { this.stopped = true }

    public func pullInbound(): Array<InboundMessage> {
        let messages = this.inbound.toArray()
        this.inbound.clear()
        messages
    }

    public func enqueue(text: String): Unit {
        let channel = if (this.adapterName == "telegram") { ChannelType.Telegram } else { ChannelType.Feishu }
        this.inbound.add(InboundMessage(
            channel,
            "${this.adapterName}-${this.inbound.size}",
            "${this.adapterName}-peer",
            "${this.adapterName}-sender",
            ChatType.Direct,
            text,
            true,
            DateTime.now()
        ))
    }

    public func send(message: OutboundMessage): SendResult {
        this.sent.add(message.text)
        if (this.failSend) { return SendResult.Failed("fake isolated delivery failure") }
        SendResult.Success
    }

    public func sendWithMessageId(message: OutboundMessage): String {
        this.sent.add(message.text)
        if (this.failSend) { throw Exception("fake isolated delivery failure") }
        "${this.adapterName}-sent-${this.sent.size}"
    }

    public func sendCount(): Int64 { this.sent.size }

    public func hasText(fragment: String): Bool {
        for (text in this.sent) {
            if (text.contains(fragment)) { return true }
        }
        false
    }

    public func countText(fragment: String): Int64 {
        var count: Int64 = 0
        for (text in this.sent) {
            if (text.contains(fragment)) { count += 1 }
        }
        count
    }

    public func countExactText(expected: String): Int64 {
        var count: Int64 = 0
        for (text in this.sent) {
            if (text == expected) { count += 1 }
        }
        count
    }
}

private func cronM5Service(feishu: CronM5E2eAdapter, telegram: CronM5E2eAdapter): GatewayService {
    let policies = HashMap<String, ChannelPolicyConfig>()
    policies["feishu"] = ChannelPolicyConfig(enableDirect: true, enableGroup: true, requireMentionInGroup: false)
    policies["telegram"] = ChannelPolicyConfig(enableDirect: true, enableGroup: true, requireMentionInGroup: false)
    let service = GatewayService(GatewayRouter(policies))
    service.registerAdapter(feishu, channelId: "feishu", accountId: "m5-feishu")
    service.registerAdapter(telegram, channelId: "telegram", accountId: "m5-telegram")
    service
}

private func cronM5Job(
    id: String,
    sessionTarget!: String = "isolated",
    deliveryChannel!: String = "",
    deliveryTo!: String = ""
): CronJob {
    CronJob(
        id,
        "M5 fake model/tool/webhook prompt ${id}",
        CronSchedule.every(60000),
        sessionTarget: sessionTarget,
        state: CronJobState(nextRunAtMs: 1),
        deliveryChannel: deliveryChannel,
        deliveryTo: deliveryTo,
        deliveryMode: if (deliveryChannel.isEmpty()) { "none" } else { "announce" }
    )
}

private func cronM5Await(predicate: () -> Bool, timeoutMs!: Int64 = 3000): Bool {
    let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
    while (!predicate() && DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
        sleep(Duration.millisecond * 2)
    }
    predicate()
}

private class CronP3HealthProbeResult {
    let status: Int64
    let body: String

    init(status: Int64, body: String) {
        this.status = status
        this.body = body
    }
}

private func cronP3ReadHealthBody(response: HttpResponse): String {
    let out = ArrayList<Byte>()
    let buffer = Array<Byte>(1024, repeat: 0)
    while (out.size <= 64 * 1024) {
        let count = response.body.read(buffer)
        if (count <= 0) { break }
        out.add(all: buffer[..count])
    }
    try { String.fromUtf8(out.toArray()) } catch (_: Exception) { "invalid_response_encoding" }
}

private func cronP3FetchHealthz(url: String): CronP3HealthProbeResult {
    let builder = ClientBuilder()
    builder.readTimeout(Duration.millisecond * 500)
    let client = builder.build()
    try {
        let response = client.send(HttpRequestBuilder().url(url).get().build())
        CronP3HealthProbeResult(Int64(response.status), cronP3ReadHealthBody(response))
    } catch (_: Exception) {
        CronP3HealthProbeResult(0, "")
    } finally {
        client.close()
    }
}

private func cronP3AwaitHealthz(url: String, expectedPort: Int64): Bool {
    cronM5Await({ =>
        let result = cronP3FetchHealthz(url)
        if (result.status < 200 || result.status >= 300) {
            false
        } else {
            try {
                let body = JsonValue.fromStr(result.body).asObject()
                body.get("ok").getOrThrow().asBool().getValue() &&
                    body.get("status").getOrThrow().asString().getValue() == "live" &&
                    body.get("gateway").getOrThrow().asObject().get("port").getOrThrow().asInt().getValue() == expectedPort
            } catch (_: Exception) { false }
        }
    })
}

private func cronP3TemporaryHealthPort(): Int64 {
    var attempts: Int64 = 0
    while (attempts < 8) {
        attempts += 1
        try (socket = TcpServerSocket(bindAt: 0u16)) {
            socket.bind()
            let port = (socket.localAddress as IPSocketAddress)?.port ?? 0u16
            let value = Int64(port)
            if (value > 0 && value != 18788 && value != 60271) { return value }
        }
    }
    0
}

@Test
public class GatewayCronNonblockingE2eTest {
    /** E2E-01：阻塞 Cron worker 时，Feishu/TG 仍通过 Gateway processOnce 完整回复且不重复。 */
    @TestCase
    public func e2e01BlockingCronKeepsBothImPollRoutesResponsiveWithoutLossOrDuplicate(): Unit {
        withCronM5E2eHome({ storePath: Path =>
            cronSave(storePath, [cronM5Job("e2e-01")])
            let release = AtomicBool(false)
            let entered = AtomicBool(false)
            debugSetCronRunnerReplyForTest(Some({ _job, _request =>
                entered.store(true)
                // 三个有效 stream/activity 周期；期间保持 worker 活跃而不占用 poll 线程。
                for (_ in 0..3) {
                    sleep(Duration.millisecond * 5)
                }
                while (!release.load()) { sleep(Duration.millisecond * 2) }
                "cron-finished"
            }))
            setGatewayAgentBridgeReplyRunnerForTest(Some({
                _sessionKey, prompt, channel, _agentId, _streaming, _hook =>
                    "${channel}-reply:${prompt}"
            }))
            let feishu = CronM5E2eAdapter("feishu")
            let telegram = CronM5E2eAdapter("telegram")
            let gateway = cronM5Service(feishu, telegram)
            let runner = CronRunner(gatewayOpt: Some(gateway), storePath: storePath, maxConcurrentRuns: 2)
            gateway.start()
            try {
                runner.tick(nowOverride: Some<Int64>(2000))
                @Expect(cronM5Await({ => entered.load() }), true)
                @Expect(runner.activeExecutionCount() <= 2, true)
                for (idx in 0..4) {
                    feishu.enqueue("飞书-${idx}-中文🙂")
                    telegram.enqueue("telegram-${idx}-🙂")
                }
                let began = DateTime.now().toUnixTimeStamp().toMilliseconds()
                gateway.processOnce()
                let elapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - began
                @Expect(elapsed < 1000, true)
                @Expect(feishu.sendCount(), 4)
                // Telegram 的真实 Gateway route 还会发 typing/reaction 生命周期消息；
                // 业务 reply 仍必须恰好每个 inbound 一条。
                @Expect(telegram.countText("telegram-reply:telegram-"), 4)
                @Expect(feishu.hasText("飞书-3-中文🙂"), true)
                @Expect(telegram.hasText("telegram-3-🙂"), true)
                release.store(true)
                @Expect(runner.waitUntilIdle(), true)
                @Expect(runner.activeExecutionCount(), 0)
                runner.tick()
                @Expect(cronLoadOrEmpty(storePath)[0].state.lastStatus, "success")
            } finally {
                release.store(true)
                let _ = runner.stop(drainTimeoutMs: 2000)
                gateway.stop()
            }
        })
    }

    /** E2E-02：timer/manual 共享 reservation，且相同 session key 串行、独立 key 并发。 */
    @TestCase
    public func e2e02ReservationAndSerialLanesPreventDuplicateWhileIndependentJobRuns(): Unit {
        withCronM5E2eHome({ storePath: Path =>
            let sameA = cronM5Job("same-a", sessionTarget: "session:shared")
            let sameB = cronM5Job("same-b", sessionTarget: "session:shared")
            let independent = cronM5Job("independent", sessionTarget: "isolated")
            cronSave(storePath, [sameA, sameB, independent])
            let beforeReadonly = File.readFrom(storePath)
            let listed = executeGatewayCronCommand(["cron", "list"])
            let status = executeGatewayCronCommand(["cron", "status"])
            @Expect(listed[1], 0)
            @Expect(status[1], 0)
            @Expect(listed[0].contains("same-a"), true)
            let afterReadonly = File.readFrom(storePath)
            @Expect(afterReadonly.size, beforeReadonly.size)
            var readonlySame = afterReadonly.size == beforeReadonly.size
            if (readonlySame) {
                for (idx in 0..beforeReadonly.size) {
                    if (beforeReadonly[idx] != afterReadonly[idx]) { readonlySame = false }
                }
            }
            @Expect(readonlySame, true)
            let releaseA = AtomicBool(false)
            let enteredA = AtomicBool(false)
            let enteredB = AtomicBool(false)
            let enteredIndependent = AtomicBool(false)
            debugSetCronRunnerReplyForTest(Some({ job, _request =>
                if (job.id == "same-a") {
                    enteredA.store(true)
                    while (!releaseA.load()) { sleep(Duration.millisecond * 2) }
                } else if (job.id == "same-b") {
                    enteredB.store(true)
                } else {
                    enteredIndependent.store(true)
                }
                "ok-${job.id}"
            }))
            let runner = CronRunner(storePath: storePath, maxConcurrentRuns: 3)
            let timer = runner.reserveExecution("same-a", "timer", true, false)
            @Expect(timer.status, "reserved")
            @Expect(runner.submitReservedExecution(timer), "submitted")
            @Expect(cronM5Await({ => enteredA.load() }), true)
            @Expect(runner.reserveExecution("same-a", "manual", true, false).status, "already-running")
            let same = runner.reserveExecution("same-b", "timer", true, false)
            let other = runner.reserveExecution("independent", "timer", true, false)
            @Expect(runner.submitReservedExecution(same), "submitted")
            @Expect(runner.submitReservedExecution(other), "submitted")
            @Expect(cronM5Await({ => enteredIndependent.load() }), true)
            @Expect(enteredB.load(), false)
            releaseA.store(true)
            @Expect(cronM5Await({ => enteredB.load() }), true)
            @Expect(runner.waitUntilIdle(), true)
            runner.tick()
            for (job in cronLoadOrEmpty(storePath)) { @Expect(job.state.lastStatus, "success") }
            @Expect(readCronRunLogEntriesForJob(storePath, "same-a").get("total").getOrThrow().asInt().getValue(), 1)
        })
    }

    /** E2E-03：执行完成只能合并 runtime 字段，不能复活删除项或覆盖并发配置编辑。 */
    @TestCase
    public func e2e03EditDisableAndRemoveDuringExecutionSurviveCompletionMerge(): Unit {
        withCronM5E2eHome({ storePath: Path =>
            cronSave(storePath, [cronM5Job("edited"), cronM5Job("removed")])
            let release = AtomicBool(false)
            let editedEntered = AtomicBool(false)
            let removedEntered = AtomicBool(false)
            let editedCommitted = AtomicBool(false)
            debugSetCronRunnerCommitForTest(Some({ phase =>
                if (phase == "after-result-commit") {
                    editedCommitted.store(true)
                }
            }))
            debugSetCronRunnerReplyForTest(Some({ job, _request =>
                if (job.id == "edited") {
                    editedEntered.store(true)
                } else if (job.id == "removed") {
                    removedEntered.store(true)
                }
                while (!release.load()) { sleep(Duration.millisecond * 2) }
                "finished"
            }))
            let runner = CronRunner(storePath: storePath, maxConcurrentRuns: 2)
            try {
                let editReservation = runner.reserveExecution("edited", "manual", true, false)
                let removeReservation = runner.reserveExecution("removed", "manual", true, false)
                @Expect(runner.submitReservedExecution(editReservation), "submitted")
                @Expect(runner.submitReservedExecution(removeReservation), "submitted")
                @Expect(cronM5Await({ => editedEntered.load() && removedEntered.load() }), true)
                var editedJob = None<CronJob>
                for (job in cronLoadOrEmpty(storePath)) {
                    if (job.id == "edited") {
                        editedJob = Some(job)
                    }
                }
                @Expect(editedJob.isSome(), true)
                match (editedJob) {
                    case Some(job) =>
                        job.prompt = "并发编辑中文🙂"
                        job.enabled = false
                        cronSave(storePath, [job])
                    case None => ()
                }
                release.store(true)
                @Expect(runner.waitUntilIdle(), true)
                @Expect(cronM5Await({ =>
                    runner.tick()
                    editedCommitted.load()
                }), true)
                let after = cronLoadOrEmpty(storePath)
                @Expect(after.size, 1)
                var afterEdited = None<CronJob>
                for (job in after) {
                    if (job.id == "edited") {
                        afterEdited = Some(job)
                    }
                }
                @Expect(afterEdited.isSome(), true)
                match (afterEdited) {
                    case Some(job) =>
                        @Expect(job.prompt, "并发编辑中文🙂")
                        @Expect(job.enabled, false)
                        @Expect(job.state.lastStatus, "success")
                    case None => ()
                }
                let human = gatewayFormatCommandOutput(
                    "{\"ok\":true,\"method\":\"cron.status\",\"result\":{\"running\":0,\"delivery\":\"unknown\"}}"
                )
                @Expect(human.trimAscii().isEmpty(), false)
                @Expect(human.contains("\"result\""), false)
                @Expect(human.contains("{"), false)
            } finally {
                release.store(true)
                let _ = runner.stop(drainTimeoutMs: 2000)
            }
        })
    }

    /** E2E-04：model/tool/delivery 各阶段 shutdown 均停止接单、取消并 fence 晚结果。 */
    @TestCase
    public func e2e04ShutdownAtModelToolAndDeliveryStagesLeavesNoWorkerOrLateDelivery(): Unit {
        for (phase in ["model", "tool", "delivery"]) {
            withCronM5E2eHome({ storePath: Path =>
                let job = cronM5Job("shutdown-${phase}", deliveryChannel: "telegram", deliveryTo: "peer")
                job.deliveryAccountId = "m5-telegram"
                cronSave(storePath, [job])
                let phaseEntered = AtomicBool(false)
                let releasePhase = AtomicBool(false)
                if (phase == "model") {
                    debugSetCronRunnerReplyForTest(Some({ _job, _request =>
                        phaseEntered.store(true)
                        while (!releasePhase.load()) { sleep(Duration.millisecond * 2) }
                        "late"
                    }))
                } else if (phase == "tool") {
                    debugSetCronRunnerBeforeExecuteForTest(Some({ _job =>
                        phaseEntered.store(true)
                        while (!releasePhase.load()) { sleep(Duration.millisecond * 2) }
                    }))
                    debugSetCronRunnerReplyForTest(Some({ _job, _request => "late-tool-result" }))
                } else {
                    debugSetCronRunnerReplyForTest(Some({ _job, _request => "delivery-result" }))
                    debugSetCronRunnerDeliveryForTest(Some({ =>
                        phaseEntered.store(true)
                        while (!releasePhase.load()) { sleep(Duration.millisecond * 2) }
                    }))
                }
                let feishu = CronM5E2eAdapter("feishu")
                let telegram = CronM5E2eAdapter("telegram")
                let gateway = cronM5Service(feishu, telegram)
                let runner = CronRunner(gatewayOpt: Some(gateway), storePath: storePath)
                let accepted = runner.enqueueJobManual(job.id, true)
                @Expect(accepted.get("enqueued").getOrThrow().asBool().getValue(), true)
                if (phase == "delivery") {
                    @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
                    // completion side-effect 由 stop 调用线程 settle；另起调用线程才能在
                    // send 前的 in-flight hook 精确观察 shutdown，并由测试主线程释放 fake。
                    let stopFinished = AtomicBool(false)
                    spawn {
                        let _ = runner.stop(reason: "gateway_shutdown", drainTimeoutMs: 2000)
                        stopFinished.store(true)
                    }
                    @Expect(cronM5Await({ => phaseEntered.load() }), true)
                    @Expect(stopFinished.load(), false)
                    releasePhase.store(true)
                    @Expect(cronM5Await({ => stopFinished.load() }), true)
                } else {
                    @Expect(cronM5Await({ => phaseEntered.load() }), true)
                    let stopped = runner.stop(reason: "gateway_shutdown", drainTimeoutMs: 30)
                    // 非协作 fake 在 drain deadline 后必须被 fence；释放只用于回收测试 worker。
                    @Expect(stopped.drained, false)
                    @Expect(stopped.activeCount, 1)
                    releasePhase.store(true)
                    @Expect(runner.waitUntilIdle(timeoutMs: 2000), true)
                }
                @Expect(runner.activeExecutionCount(), 0)
                @Expect(runner.enqueueJobManual(job.id, true).get("enqueued").getOrThrow().asBool().getValue(), false)
                let sentAtStop = telegram.sendCount()
                sleep(Duration.millisecond * 20)
                @Expect(telegram.sendCount(), sentAtStop)
            })
        }
    }

    /** E2E-05：Unicode/超长输出与失败任务并行时，正常投递与 run-log 不受影响。 */
    @TestCase
    public func e2e05Utf8LongPayloadAndMalformedResultAreIsolatedAcrossJobsAndChannels(): Unit {
        withCronM5E2eHome({ storePath: Path =>
            let invalidUtf8 = Array<Byte>(2, { idx => if (idx == 0) { 195 } else { 40 } })
            let decoded = cronScriptDecodeBytesForTest(invalidUtf8)
            @Expect(decoded.ok, false)
            @Expect(decoded.status, "invalid_response_encoding")
            Directory.create(storePath.parent, recursive: true)
            File.writeTo(storePath, invalidUtf8)
            @Expect(cronLoadOrEmpty(storePath).size, 0)
            File.writeTo(storePath, "{\"version\":2,\"jobs\":[".toArray())
            @Expect(cronLoadOrEmpty(storePath).size, 0)

            let good = cronM5Job("utf8-good", deliveryChannel: "feishu", deliveryTo: "good")
            good.deliveryAccountId = "m5-feishu"
            let bad = cronM5Job("malformed-bad", deliveryChannel: "telegram", deliveryTo: "bad")
            bad.deliveryAccountId = "m5-telegram"
            cronSave(storePath, [good, bad])
            let longText = "中文🙂" + ("x" * 4096)
            debugSetCronRunnerReplyForTest(Some({ job, _request =>
                if (job.id == "malformed-bad") { throw Exception("malformed_json invalid_response_encoding") }
                longText
            }))
            let feishu = CronM5E2eAdapter("feishu")
            let telegram = CronM5E2eAdapter("telegram")
            let gateway = cronM5Service(feishu, telegram)
            let runner = CronRunner(gatewayOpt: Some(gateway), storePath: storePath, maxConcurrentRuns: 2)
            runner.tick(nowOverride: Some<Int64>(2000))
            @Expect(runner.waitUntilIdle(), true)
            runner.tick()
            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs[0].state.lastStatus, "success")
            @Expect(jobs[1].state.lastStatus, "error")
            @Expect(feishu.sendCount(), 1)
            @Expect(feishu.hasText("中文🙂"), true)
            @Expect(telegram.sendCount(), 0)
            @Expect(readCronRunLogEntriesForJob(storePath, "utf8-good").get("total").getOrThrow().asInt().getValue(), 1)
            @Expect(readCronRunLogEntriesForJob(storePath, "malformed-bad").get("total").getOrThrow().asInt().getValue(), 1)
        })
    }

    /** E2E-06：共享 session/global lane 串行，独立 lane 并行，cleanup 在失败路径仍执行。 */
    @TestCase
    public func e2e06SharedSessionAndGlobalResourceSerializeWithScopedRestore(): Unit {
        let executor = CronExecutionExecutor(maxConcurrentRuns: 3)
        let release = AtomicBool(false)
        let sharedEntered = AtomicBool(false)
        let secondSharedEntered = AtomicBool(false)
        let independentEntered = AtomicBool(false)
        let cleanupRan = AtomicBool(false)
        let envRestored = AtomicBool(false)
        let transcript = ArrayList<String>()
        let transcriptLock = Mutex()
        let originalEnv = getVariable("METIS_M5_EXECUTION_SCOPE")
        let originalCwd = CliConfig.cwd.toString()
        executor.start()
        let tasks = [
            CronExecutionTask(
                CronExecutionId("global-a", 1, 1),
                cronM5Job("global-a"),
                { _job =>
                    sharedEntered.store(true)
                    while (!release.load()) { sleep(Duration.millisecond * 2) }
                    setVariable("METIS_M5_EXECUTION_SCOPE", "global-a")
                    synchronized(transcriptLock) { transcript.add("shared-a") }
                    throw Exception("fake global failure")
                },
                serialKey: "shared-session",
                globalResource: true,
                cleanupTask: { =>
                    match (originalEnv) {
                        case Some(value) => setVariable("METIS_M5_EXECUTION_SCOPE", value)
                        case None => setVariable("METIS_M5_EXECUTION_SCOPE", "")
                    }
                    envRestored.store(match (originalEnv) {
                        case Some(value) =>
                            match (getVariable("METIS_M5_EXECUTION_SCOPE")) {
                                case Some(actual) => actual == value
                                case None => false
                            }
                        case None =>
                            match (getVariable("METIS_M5_EXECUTION_SCOPE")) {
                                case Some(actual) => actual.isEmpty()
                                case None => true
                            }
                    })
                    cleanupRan.store(true)
                }
            ),
            CronExecutionTask(
                CronExecutionId("shared-b", 1, 2),
                cronM5Job("shared-b"),
                { _job =>
                    secondSharedEntered.store(true)
                    synchronized(transcriptLock) { transcript.add("shared-b") }
                    CronExecutionArtifact(answer: "shared")
                },
                serialKey: "shared-session"
            ),
            CronExecutionTask(
                CronExecutionId("independent", 1, 3),
                cronM5Job("independent"),
                { _job =>
                    independentEntered.store(true)
                    synchronized(transcriptLock) { transcript.add("independent") }
                    CronExecutionArtifact(answer: "independent")
                },
                serialKey: "independent-session"
            )
        ]
        @Expect(executor.tryAcquireSlot(), true)
        @Expect(executor.submitReserved(tasks[0]), true)
        @Expect(cronM5Await({ => sharedEntered.load() }), true)
        for (idx in 1..tasks.size) {
            @Expect(executor.tryAcquireSlot(), true)
            @Expect(executor.submitReserved(tasks[idx]), true)
        }
        @Expect(cronM5Await({ => independentEntered.load() }), true)
        @Expect(secondSharedEntered.load(), false)
        release.store(true)
        @Expect(cronM5Await({ => secondSharedEntered.load() }), true)
        @Expect(cronM5Await({ => executor.activeCount() == 0 }), true)
        @Expect(cleanupRan.load(), true)
        @Expect(envRestored.load(), true)
        @Expect(CliConfig.cwd.toString(), originalCwd)
        let results = executor.drainCompleted()
        @Expect(results.size, 3)
        var failedGlobal: Int64 = 0
        for (result in results) {
            if (result.executionId.jobId == "global-a" && !result.succeeded()) { failedGlobal += 1 }
        }
        @Expect(failedGlobal, 1)
        @Expect(transcript.contains("shared-a"), true)
        @Expect(transcript.contains("shared-b"), true)
        @Expect(transcript.contains("independent"), true)
    }

    /** E2E-07：双 IM ingress 保持响应，Cron headless profile 拒绝递归/交互/生命周期工具。 */
    @TestCase
    public func e2e07BothImIngressStayLiveWhileCronProfileRejectsRecursiveAndInteractiveTools(): Unit {
        withCronM5E2eHome({ storePath: Path =>
            for (tool in ["cron", "gateway", "message", "clarify", "sessions_spawn", "sessions_batch_delegate", "process"]) {
                @Expect(gatewayCronHeadlessToolDenied(tool), true)
            }
            for (tool in ["web_search", "read", "memory"]) {
                @Expect(gatewayCronHeadlessToolDenied(tool), false)
            }
            setGatewayAgentBridgeReplyRunnerForTest(Some({
                _sessionKey, prompt, channel, _agentId, _streaming, _hook =>
                    let pair = executeGatewayCronCommand([
                        "cron", "add",
                        "--name", "from-${channel}",
                        "--every", "1h",
                        "--session", "isolated",
                        "--message", prompt
                    ])
                    @Expect(pair[1], 0)
                    "${channel}:created-cron:${prompt}"
            }))
            let feishu = CronM5E2eAdapter("feishu")
            let telegram = CronM5E2eAdapter("telegram")
            let gateway = cronM5Service(feishu, telegram)
            gateway.start()
            try {
                feishu.enqueue("创建定时任务：禁止递归 cron/clarify")
                telegram.enqueue("create cron; reject gateway/message")
                gateway.processOnce()
                @Expect(feishu.sendCount(), 1)
                @Expect(telegram.countText("telegram:created-cron:"), 1)
                @Expect(feishu.hasText("created-cron"), true)
                @Expect(telegram.hasText("created-cron"), true)
                let created = cronLoadOrEmpty(storePath)
                @Expect(created.size, 2)
                @Expect(created[0].id == "from-feishu" || created[1].id == "from-feishu", true)
                @Expect(created[0].id == "from-telegram" || created[1].id == "from-telegram", true)
            } finally {
                gateway.stop()
            }
            @Expect(feishu.stopped, true)
            @Expect(telegram.stopped, true)
        })
    }

    /** C6-E2E-03：修正后的 typed outcome 是唯一可投递正文，协议形状不进入投递和 run-log。 */
    @TestCase
    public func c6E2e03CorrectedTypedOutcomeDeliversChineseSummaryOnceWithoutProtocolLeak(): Unit {
        withCronM5E2eHome({ storePath: Path =>
            let job = cronM5Job(
                "c6-e2e-03",
                deliveryChannel: "feishu",
                deliveryTo: "sports-chat"
            )
            job.deliveryAccountId = "m5-feishu"
            cronSave(storePath, [job])
            let modelAttempts = AtomicInt64(0)
            let observedToolExecutions = AtomicInt64(0)
            debugSetCronRunnerOutcomeForTest(Some({ _job, _request =>
                // 模拟已经完成的一次 web tool，不允许 correction 重放它。
                observedToolExecutions.fetchAdd(1)
                modelAttempts.fetchAdd(1)
                gatewayRunFinalAnswerCorrection(
                    "[\"web_fetch\"]",
                    ["web_fetch"],
                    { correctionPrompt =>
                        @Expect(correctionPrompt.contains("禁止调用任何工具"), true)
                        modelAttempts.fetchAdd(1)
                        "今日体育摘要：中国队获胜🙂"
                    },
                    toolExecutionObserved: true,
                    existingContext: "web_fetch 已完成：体育赛果"
                )
            }))
            let feishu = CronM5E2eAdapter("feishu")
            let telegram = CronM5E2eAdapter("telegram")
            let gateway = cronM5Service(feishu, telegram)
            let _ = CronRunner.runJobOnceFromStore(Some(gateway), storePath, job.id, true)
            @Expect(modelAttempts.load(), 2)
            @Expect(observedToolExecutions.load(), 1)
            @Expect(feishu.sendCount(), 1)
            @Expect(feishu.hasText("今日体育摘要：中国队获胜🙂"), true)
            @Expect(feishu.hasText("[\"web_fetch\"]"), false)
            @Expect(telegram.sendCount(), 0)
            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs.size, 1)
            for (stored in jobs) {
                if (stored.id == job.id) { @Expect(stored.state.lastStatus, "success") }
            }
            let rows = readCronRunLogEntriesForJob(storePath, job.id)
                .get("entries").getOrThrow().asArray()
            @Expect(rows.size(), 1)
            if (rows.size() == 1) {
                let row = rows[0].asObject()
                @Expect(row.get("status").getOrThrow().asString().getValue(), "ok")
                @Expect(row.get("summary").getOrThrow().asString().getValue().contains("[\"web_fetch\"]"), false)
            }
        })
    }

    /** C6-E2E-04：两次协议形状均失败；失败告警按通道隔离且不会产生成功投递。 */
    @TestCase
    public func c6E2e04RepeatedProtocolFailureNeverFalseSucceedsAndIsolatesAlertChannels(): Unit {
        withCronM5E2eHome({ storePath: Path =>
            let feishuJob = cronM5Job("c6-e2e-04-feishu")
            feishuJob.maxRetries = 1
            feishuJob.failureDestMode = "announce"
            feishuJob.failureChannel = "feishu"
            feishuJob.failureTo = "failure-feishu"
            feishuJob.failureAccountId = "m5-feishu"
            let telegramJob = cronM5Job("c6-e2e-04-telegram")
            telegramJob.maxRetries = 1
            telegramJob.failureDestMode = "announce"
            telegramJob.failureChannel = "telegram"
            telegramJob.failureTo = "failure-telegram"
            telegramJob.failureAccountId = "m5-telegram"
            cronSave(storePath, [feishuJob, telegramJob])
            let attempts = AtomicInt64(0)
            let toolExecutions = AtomicInt64(0)
            debugSetCronRunnerOutcomeForTest(Some({ _job, _request =>
                attempts.fetchAdd(1)
                GatewayAgentReplyOutcome(
                    "incomplete_tool_protocol",
                    diagnosticCode: "incomplete_tool_protocol",
                    modelAttempts: 2,
                    toolExecutionObserved: toolExecutions.load() > 0
                )
            }))
            let feishu = CronM5E2eAdapter("feishu", failSend: true)
            let telegram = CronM5E2eAdapter("telegram")
            let gateway = cronM5Service(feishu, telegram)
            let _ = CronRunner.runJobOnceFromStore(Some(gateway), storePath, feishuJob.id, true)
            let _ = CronRunner.runJobOnceFromStore(Some(gateway), storePath, telegramJob.id, true)
            @Expect(attempts.load(), 4)
            @Expect(toolExecutions.load(), 0)
            // Gateway 对失败 adapter 依次尝试 message-id 与 direct fallback；两次均失败，
            // 不代表产生了两条用户可见告警。
            @Expect(feishu.sendCount(), 2)
            @Expect(telegram.sendCount(), 1)
            @Expect(feishu.hasText("[\"web_fetch\"]"), false)
            @Expect(telegram.hasText("[\"web_fetch\"]"), false)
            for (job in cronLoadOrEmpty(storePath)) {
                @Expect(job.state.lastStatus, "error")
                @Expect(job.state.lastError.contains("incomplete_tool_protocol"), true)
            }
            for (id in [feishuJob.id, telegramJob.id]) {
                let rows = readCronRunLogEntriesForJob(storePath, id)
                    .get("entries").getOrThrow().asArray()
                @Expect(rows.size(), 1)
                if (rows.size() == 1) {
                    let row = rows[0].asObject()
                    @Expect(row.get("status").getOrThrow().asString().getValue(), "error")
                    @Expect(row.get("diagnosticCode").getOrThrow().asString().getValue(), "incomplete_tool_protocol")
                    @Expect(row.get("summary").getOrThrow().asString().getValue().contains("[\"web_fetch\"]"), false)
                }
            }
        })
    }

    @TestCase
    public func p3P4SerialGatewayScriptHandoffKeepsPollAndRealHealthResponsive(): Unit {
        withCronM5E2eHome({ storePath: Path =>
            let scripts = cronScriptsDir(CliConfig.dotDir)
            Directory.create(scripts, recursive: true)
            let fixture = CliConfig.cwd.join("scripts").join("gateway-stdio-fake-cron-child.mjs").toString()
            let readyA = scripts.join("p3-p4-a.ready")
            let readyB = scripts.join("p3-p4-b.ready")
            let releaseA = scripts.join("p3-p4-a.release")
            let releaseB = scripts.join("p3-p4-b.release")
            File.writeTo(
                scripts.join("p3-p4-a.sh"),
                "exec node '${fixture}' 'wait-release' '${readyA.toString()}' '${releaseA.toString()}'\n".toArray()
            )
            File.writeTo(
                scripts.join("p3-p4-b.sh"),
                "exec node '${fixture}' 'wait-release' '${readyB.toString()}' '${releaseB.toString()}'\n".toArray()
            )
            let jobA = cronM5Job("p3-p4-a", sessionTarget: "session:p3-p4-a")
            jobA.scriptPath = "p3-p4-a.sh"
            jobA.scriptMode = "noAgent"
            let jobB = cronM5Job("p3-p4-b", sessionTarget: "session:p3-p4-b")
            jobB.scriptPath = "p3-p4-b.sh"
            jobB.scriptMode = "noAgent"
            cronSave(storePath, [jobA, jobB])

            setGatewayAgentBridgeReplyRunnerForTest(Some({
                _sessionKey, prompt, channel, _agentId, _streaming, _hook =>
                    "${channel}-reply:${prompt}"
            }))
            let feishu = CronM5E2eAdapter("feishu")
            let telegram = CronM5E2eAdapter("telegram")
            let gateway = cronM5Service(feishu, telegram)
            let runner = CronRunner(gatewayOpt: Some(gateway), storePath: storePath, maxConcurrentRuns: 2)
            var healthSettings = CliSettingManager.readGatewaySettings()
            healthSettings.bind = "loopback"
            healthSettings.customBindHost = ""
            healthSettings.http.endpoints.chatCompletions.enabled = true
            var healthUrl = ""
            var healthPort: Int64 = 0
            GatewayHttpSurface.stopIfRunning()
            try {
                gateway.start()
                for (_attempt in 0..5) {
                    let candidate = cronP3TemporaryHealthPort()
                    if (candidate <= 0) { continue }
                    healthSettings.port = candidate
                    let candidateCfg = buildGatewayConfigFromUserSettings(healthSettings)
                    let candidateUrl = "http://127.0.0.1:${candidate}/healthz"
                    GatewayHttpSurface.startIfNeeded(candidateCfg)
                    if (cronP3AwaitHealthz(candidateUrl, candidate)) {
                        healthPort = candidate
                        healthUrl = candidateUrl
                        break
                    }
                    GatewayHttpSurface.stopIfRunning()
                }
                @Expect(healthPort > 0, true)
                if (healthPort <= 0) { throw Exception("P3-P4 could not start isolated health surface") }
                let reservedA = runner.reserveExecution(jobA.id, "manual", true, false)
                let reservedB = runner.reserveExecution(jobB.id, "manual", true, false)
                @Expect(reservedA.status, "reserved")
                @Expect(reservedB.status, "reserved")
                @Expect(runner.submitReservedExecution(reservedA), "submitted")
                @Expect(runner.submitReservedExecution(reservedB), "submitted")
                @Expect(cronM5Await({ => exists(readyA) != exists(readyB) }), true)
                let firstIsA = exists(readyA)
                let firstReady = if (firstIsA) { readyA } else { readyB }
                let secondReady = if (firstIsA) { readyB } else { readyA }
                let firstRelease = if (firstIsA) { releaseA } else { releaseB }
                let secondRelease = if (firstIsA) { releaseB } else { releaseA }
                @Expect(exists(firstReady), true)
                @Expect(exists(secondReady), false)
                @Expect(cronM5Await({ => runner.activeExecutionCount() == 2 }), true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 1)
                let brokerPid = managedStdioBroker().snapshot().brokerPid
                for (index in 0..4) {
                    let feishuText = "飞书-p3-p4-${index}-中文🙂"
                    let telegramText = "telegram-p3-p4-${index}-🙂"
                    feishu.enqueue(feishuText)
                    telegram.enqueue(telegramText)
                    let beganAtMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
                    gateway.processOnce()
                    let response = cronP3FetchHealthz(healthUrl)
                    let healthz = JsonValue.fromStr(response.body).asObject()
                    let brokerHealth = managedStdioBroker().probeBroker(timeoutMs: 500)
                    @Expect(DateTime.now().toUnixTimeStamp().toMilliseconds() - beganAtMs < 1000, true)
                    @Expect(response.status >= 200 && response.status < 300, true)
                    @Expect(healthz.get("ok").getOrThrow().asBool().getValue(), true)
                    @Expect(healthz.get("status").getOrThrow().asString().getValue(), "live")
                    @Expect(healthz.get("gateway").isSome(), true)
                    @Expect(
                        healthz.get("gateway").getOrThrow().asObject().get("port").getOrThrow().asInt().getValue(),
                        healthPort
                    )
                    @Expect(brokerHealth.ok, true)
                    @Expect(managedStdioBroker().snapshot().brokerPid, brokerPid)
                    @Expect(feishu.countExactText("feishu-reply:${feishuText}"), 1)
                    @Expect(telegram.countExactText("telegram-reply:${telegramText}"), 1)
                }
                let firstPid = try { String.fromUtf8(File.readFrom(firstReady)).trimAscii() } catch (_: Exception) { "" }
                File.writeTo(firstRelease, "release".toArray())
                @Expect(cronM5Await({ => exists(secondReady) }), true)
                let secondPid = try { String.fromUtf8(File.readFrom(secondReady)).trimAscii() } catch (_: Exception) { "" }
                @Expect(firstPid.isEmpty(), false)
                @Expect(secondPid.isEmpty(), false)
                @Expect(secondPid == firstPid, false)
                @Expect(managedStdioBroker().snapshot().ownerCount, 1)
                @Expect(managedStdioBroker().snapshot().brokerPid, brokerPid)
                for (index in 4..8) {
                    let feishuText = "飞书-p3-p4-${index}-中文🙂"
                    let telegramText = "telegram-p3-p4-${index}-🙂"
                    feishu.enqueue(feishuText)
                    telegram.enqueue(telegramText)
                    let beganAtMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
                    gateway.processOnce()
                    let response = cronP3FetchHealthz(healthUrl)
                    let healthz = JsonValue.fromStr(response.body).asObject()
                    let brokerHealth = managedStdioBroker().probeBroker(timeoutMs: 500)
                    @Expect(DateTime.now().toUnixTimeStamp().toMilliseconds() - beganAtMs < 1000, true)
                    @Expect(response.status >= 200 && response.status < 300, true)
                    @Expect(healthz.get("ok").getOrThrow().asBool().getValue(), true)
                    @Expect(healthz.get("status").getOrThrow().asString().getValue(), "live")
                    @Expect(
                        healthz.get("gateway").getOrThrow().asObject().get("port").getOrThrow().asInt().getValue(),
                        healthPort
                    )
                    @Expect(brokerHealth.ok, true)
                    @Expect(managedStdioBroker().snapshot().brokerPid, brokerPid)
                    @Expect(feishu.countExactText("feishu-reply:${feishuText}"), 1)
                    @Expect(telegram.countExactText("telegram-reply:${telegramText}"), 1)
                }
                @Expect(feishu.sendCount(), 8)
                @Expect(feishu.countText("telegram-reply:"), 0)
                @Expect(telegram.countText("feishu-reply:"), 0)
                @Expect(telegram.countText("telegram-reply:telegram-p3-p4-"), 8)
                for (index in 0..8) {
                    @Expect(feishu.countExactText("feishu-reply:飞书-p3-p4-${index}-中文🙂"), 1)
                    @Expect(telegram.countExactText("telegram-reply:telegram-p3-p4-${index}-🙂"), 1)
                }
                @Expect(managedStdioBroker().snapshot().readerCount, 1)
                File.writeTo(secondRelease, "release".toArray())
                @Expect(runner.waitUntilIdle(timeoutMs: 5000), true)
                runner.tick()
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
                for (job in cronLoadOrEmpty(storePath)) { @Expect(job.state.lastStatus, "success") }
            } finally {
                try { File.writeTo(releaseA, "release".toArray()) } catch (_: Exception) { () }
                try { File.writeTo(releaseB, "release".toArray()) } catch (_: Exception) { () }
                try { let _ = runner.stop(drainTimeoutMs: 3000) } catch (_: Exception) { () }
                try { gateway.stop() } catch (_: Exception) { () }
                GatewayHttpSurface.stopIfRunning()
                if (managedStdioBroker().snapshot().ownerCount != 0) {
                    let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                }
            }
        })
    }
}
