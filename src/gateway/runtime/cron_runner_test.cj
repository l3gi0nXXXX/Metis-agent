package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.tools.debugGatewayShellExecuteForTest
import metis.cron.{
    CronJob,
    CronJobState,
    CronSchedule,
    CronWebhookHttpRequest,
    CronWebhookHttpResponse,
    cronLoadOrEmpty,
    cronRunLogPathFromStore,
    cronSave,
    cronStorePath,
    readCronRunLogEntriesForJob,
    setCronWebhookHttpRunnerForTest
}
import metis.gateway.core.{ChannelAdapter, GatewayRouter, GatewayService, setGatewayAgentBridgeReplyRunnerForTest}
import metis.gateway.model.{ChannelPolicyConfig, InboundMessage, OutboundMessage, SendResult}
import metis.gateway.session.{GatewayIngressSource, GatewaySessionRequest, GatewayTurnContext, gatewayIngressSourceLabel}

import std.collection.HashMap
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString}

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
            setCronWebhookHttpRunnerForTest(None<(CronWebhookHttpRequest) -> CronWebhookHttpResponse>)
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

private class CronRunnerTestChannelAdapter <: ChannelAdapter {
    private let adapterName: String
    private let messageId: String
    private let failSend: Bool
    private let failMessage: String
    public var sendCount: Int64 = 0
    public var lastAccountId: String = ""
    public var lastPeerId: String = ""
    public var lastText: String = ""

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
        []
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
            let longNews = cronRunnerRepeatedText("新闻🙂中文段落；", 420)
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
                        "printf '${longNews}'",
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
                captured.put("timeoutMs", JsonString("${request.timeoutMs}"))
                captured.put("verifyTls", JsonString("${request.verifyTls}"))
                captured.put("jobId", request.body.get("jobId").getOrThrow())
                captured.put("summary", request.body.get("summary").getOrThrow())
                CronWebhookHttpResponse(true, statusCode: 200)
            }))

            let result = CronRunner.runJobOnceFromStore(None<GatewayService>, storePath, "webhook-delivery", true)
            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(result.get("ran").getOrThrow().asBool().getValue(), true)
            @Expect(captured.get("url").getOrThrow().asString().getValue(), "https://example.com/cron-hook?token=secret")
            @Expect(captured.get("timeoutMs").getOrThrow().asString().getValue(), "2500")
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
