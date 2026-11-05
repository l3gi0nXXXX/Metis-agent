package metis.gateway.core

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock, GatewayUserSettings}
import metis.gateway.service_plugin.*
import metis.gateway.gitcode_plugin.{GitCodeSubscriptionStore, GitCodeSubscriptionTarget, GitCodeSubscriptionScope, setGitCodeSubscriptionStore}
import metis.process.{resetManagedStdioBrokerForTest, managedStdioBroker}
import std.sync.Mutex
import metis.gateway.logging.{gatewayLoggingCaptureConsoleForTest, gatewayLoggingCapturedConsoleForTest, gatewayLoggingResetForTest}
import metis.gateway.model.{ChannelPolicyConfig, ChannelType, ChatType, InboundMessage, OutboundMessage, SendResult}
import magic.config.Config

import std.collection.{ArrayList, HashMap}
import std.env.{getVariable, removeVariable, setVariable, getProcessId}
import std.fs.{Directory, File, FileInfo, Path, canonicalize, exists, remove}
import std.time.{DateTime, MonoTime}
import std.core.Duration
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString}

private func withGatewayServiceStartupTestHome<T>(block: () -> T): T {
    let testHome = "/tmp/metis-gateway-service-startup-test-home"
    let home = Path(testHome)
    let parent = home.parent
    let identityOk = testHome == "/tmp/metis-gateway-service-startup-test-home" &&
        parent.toString() == "/tmp" && canonicalize(parent).toString() == "/private/tmp" &&
        home.fileName == "metis-gateway-service-startup-test-home"
    var existingIdentityOk = true
    let targetIsSymlink = try { FileInfo(home).isSymbolicLink() } catch (_: Exception) { false }
    if (exists(home)) {
        let info = FileInfo(home)
        existingIdentityOk = info.isDirectory() && !info.isSymbolicLink()
    }
    if (!identityOk || targetIsSymlink || !existingIdentityOk || exists(home)) {
        throw Exception("s3j_owned_home_identity_invalid")
    }
    let oldHome = getVariable("METIS_HOME")
    let oldLogFile = Config.logFile
    var homeCreated = false
    try {
        Directory.create(home, recursive: false)
        homeCreated = true
        setVariable("METIS_HOME", testHome)
        CliConfig.invalidatePathCache()
        return block()
    } finally {
        var cleanupFailure = ""
        try {
            try {
                match (oldHome) {
                    case Some(value) => setVariable("METIS_HOME", value)
                    case None => removeVariable("METIS_HOME")
                }
            } catch (_: Exception) {
                cleanupFailure = "s3j_env_restore_failed"
            }
        } finally {
            try {
                try {
                    CliConfig.invalidatePathCache()
                } catch (_: Exception) {
                    if (cleanupFailure.isEmpty()) { cleanupFailure = "s3j_cache_restore_failed" }
                }
            } finally {
                try {
                    try {
                        gatewayLoggingResetForTest()
                    } catch (_: Exception) {
                        if (cleanupFailure.isEmpty()) { cleanupFailure = "s3j_logging_reset_failed" }
                    }
                } finally {
                    try {
                        try {
                            Config.logFile = oldLogFile
                            @Expect(Config.logFile, oldLogFile)
                            if (Config.logFile != oldLogFile && cleanupFailure.isEmpty()) {
                                cleanupFailure = "s3j_config_restore_failed"
                            }
                        } catch (_: Exception) {
                            if (cleanupFailure.isEmpty()) { cleanupFailure = "s3j_config_restore_failed" }
                        }
                    } finally {
                        try {
                            if (homeCreated && exists(home)) { remove(home, recursive: true) }
                        } catch (_: Exception) {
                            if (cleanupFailure.isEmpty()) { cleanupFailure = "s3j_owned_home_remove_failed" }
                        }
                        let remains = homeCreated && (exists(home) ||
                            try { FileInfo(home).isSymbolicLink() } catch (_: Exception) { false })
                        @Expect(remains, false)
                        if (remains && cleanupFailure.isEmpty()) {
                            cleanupFailure = "s3j_owned_home_cleanup_failed"
                        }
                        if (!cleanupFailure.isEmpty()) { throw Exception(cleanupFailure) }
                    }
                }
            }
        }
    }
}

private class GatewayServiceStartupFakeAdapter <: ChannelAdapter {
    private let adapterName: String
    private let startDelayMs: Int64
    private let failMessage: String
    private let stopFailure: String
    private let onStart: Option<() -> Unit>
    private let inbound = ArrayList<InboundMessage>()
    public var startCount: Int64 = 0
    public var stopCount: Int64 = 0
    public var pullCount: Int64 = 0
    public var sendCount: Int64 = 0

    public init(
        adapterName: String,
        startDelayMs!: Int64 = 0,
        failMessage!: String = "",
        stopFailure!: String = "",
        onStart!: Option<() -> Unit> = None<() -> Unit>
    ) {
        this.adapterName = adapterName
        this.startDelayMs = startDelayMs
        this.failMessage = failMessage
        this.stopFailure = stopFailure
        this.onStart = onStart
    }

    public prop name: String {
        get() { this.adapterName }
    }

    public func start(): Unit {
        this.startCount += 1
        match (this.onStart) { case Some(callback) => callback() case None => () }
        if (this.startDelayMs > 0) {
            sleep(Duration.millisecond * this.startDelayMs)
        }
        if (!this.failMessage.isEmpty()) {
            throw Exception(this.failMessage)
        }
    }

    public func stop(): Unit {
        this.stopCount += 1
        if (!this.stopFailure.isEmpty()) {
            throw Exception(this.stopFailure)
        }
    }

    public func queue(text: String): Unit {
        this.inbound.add(InboundMessage(
            ChannelType.Telegram,
            "msg-${this.inbound.size}",
            "peer",
            "sender",
            ChatType.Direct,
            text,
            false,
            DateTime.now(),
            accountId: "default"
        ))
    }

    public func pullInbound(): Array<InboundMessage> {
        this.pullCount += 1
        let out = this.inbound.toArray()
        this.inbound.clear()
        out
    }

    public func send(_message: OutboundMessage): SendResult {
        this.sendCount += 1
        SendResult.Success
    }

    public func sendWithMessageId(_message: OutboundMessage): String {
        this.sendCount += 1
        "fake-message"
    }
}

private func withGatewayServiceStartupLogCapture<T>(name: String, block: (String) -> T): T {
    let oldLevel = Config.logLevel
    let oldFile = Config.logFile
    let oldMetisLevel = getVariable("METIS_LOG_LEVEL")
    let oldMetisFile = getVariable("METIS_LOG_FILE")
    let oldMetisConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
    let path = "/tmp/metis-gateway-service-startup-${name}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}.log"
    try { remove(Path(path), recursive: true) } catch (_: Exception) { () }
    Config.logLevel = "debug"
    Config.logFile = path
    setVariable("METIS_LOG_LEVEL", "debug")
    setVariable("METIS_LOG_FILE", path)
    setVariable("METIS_CONSOLE_LEVEL", "debug")
    gatewayLoggingResetForTest()
    gatewayLoggingCaptureConsoleForTest()
    try {
        return block(path)
    } finally {
        Config.logLevel = oldLevel
        Config.logFile = oldFile
        match (oldMetisLevel) {
            case Some(value) => setVariable("METIS_LOG_LEVEL", value)
            case None => setVariable("METIS_LOG_LEVEL", "")
        }
        match (oldMetisFile) {
            case Some(value) => setVariable("METIS_LOG_FILE", value)
            case None => setVariable("METIS_LOG_FILE", "")
        }
        match (oldMetisConsoleLevel) {
            case Some(value) => setVariable("METIS_CONSOLE_LEVEL", value)
            case None => setVariable("METIS_CONSOLE_LEVEL", "")
        }
        gatewayLoggingResetForTest()
        try { remove(Path(path), recursive: true) } catch (_: Exception) { () }
    }
}

private func gatewayServiceStartupReadLog(path: String): String {
    let captured = String.join(gatewayLoggingCapturedConsoleForTest(), delimiter: "\n")
    if (!exists(Path(path))) {
        return captured
    }
    String.fromUtf8(File.readFrom(Path(path))) + "\n" + captured
}

private func gatewayServiceStartupString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_e: Exception) { "" }
        case None => ""
    }
}

private func gatewayServiceStartupBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_e: Exception) { false }
        case None => false
    }
}

private func gatewayServiceStartupInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { v.asInt().getValue() } catch (_e: Exception) { -1 }
        case None => -1
    }
}

private func gatewayServiceStartupSummaryAccount(summary: JsonObject, accountId: String): JsonObject {
    let accounts = summary.get("accounts").getOrThrow().asArray()
    for (i in 0..accounts.size()) {
        let row = accounts[i].asObject()
        if (gatewayServiceStartupString(row, "accountId") == accountId) {
            return row
        }
    }
    JsonObject()
}

private func gatewayServiceStartupRuntimeAccount(channelId: String, accountId: String): JsonObject {
    let accounts = gatewayChannelRuntimeAccountsJson(channelId)
    for (i in 0..accounts.size()) {
        let row = accounts[i].asObject()
        if (gatewayServiceStartupString(row, "accountId") == accountId) {
            return row
        }
    }
    JsonObject()
}

@Test
public class GatewayServiceStartupTest {

    @TestCase
    public func startupInstallsSubscribersBeforeStartingChannelConsumer(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let home = Directory.createTemp("/private/tmp")
            let oldHome = getVariable("METIS_HOME")
            let oldLog = Config.logFile
            let services = ArrayList<GatewayService>()
            let errors = ArrayList<Exception>()
            let samples = ArrayList<Bool>()
            let sampleLock = Mutex()
            let attempt = { action: () -> Unit => try { action() } catch (error: Exception) { errors.add(error) } }
            let check = { value: Bool =>
                @Expect(value, true)
                if (!value) { throw Exception("startup_channel_order_failed") }
            }
            var bodyError = None<Exception>
            var formal = false
            try {
                File.writeTo(home.join("startup-dispatch.owner"),
                    "metis-startup-dispatch-v1\ntestPid:${getProcessId()}\nname:channel-order\n".toArray())
                setVariable("METIS_HOME", home.toString())
                CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
                resetServicePluginHostForTest()
                check(resetManagedStdioBrokerForTest(timeoutMs: 2000).ok)
                setServicePluginWebhookSubscribersProvider(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                var user = GatewayUserSettings()
                let root = JsonObject()
                let agents = JsonObject()
                let defaults = JsonObject()
                defaults.put("workspace", JsonString(home.join("workspace").toString()))
                agents.put("defaults", defaults)
                root.put("agents", agents)
                root.put("gateway", user.toJsonValue())
                File.writeTo(home.join("metis.json"), root.toJsonString().toArray())
                MetisConfigManager.invalidate(); CliSettingManager.invalidate()
                let subscriptions = home.join("service-plugin").join("gitcode")
                Directory.create(subscriptions, recursive: true)
                let expectedPeer = "channel-start中文😀"
                let subscriptionPath = subscriptions.join("subscriptions.jsonl").toString()
                let writerStore = GitCodeSubscriptionStore(subscriptionPath)
                let created = writerStore.createOrUpdate(GitCodeSubscriptionTarget("telegram", "default", expectedPeer),
                    scope: GitCodeSubscriptionScope(rawEvents: false, generatedReplies: true))
                check(created.ok && created.status == "created")
                let freshLocalStore = GitCodeSubscriptionStore(subscriptionPath)
                let loaded = freshLocalStore.load()
                check(loaded.ok && loaded.status == "ok" && loaded.diagnostic.isEmpty())
                let persisted = freshLocalStore.listActive()
                check(persisted.size == 1 && persisted[0].active &&
                    persisted[0].target.channel == "telegram" && persisted[0].target.accountId == "default" &&
                    persisted[0].target.peerId == expectedPeer && persisted[0].target.threadId.isEmpty() &&
                    !persisted[0].scope.rawEvents && persisted[0].scope.generatedReplies)
                let event = ServicePluginAcceptedGitCodeEvent(eventId: "channel-start-order", jobId: "webhook-channel-start-order",
                    repo: "cangjie/compiler", kind: "issue", number: "1", url: "https://example.invalid/issue/1")
                let adapter = GatewayServiceStartupFakeAdapter("telegram", onStart: Some({ =>
                    let targets = resolveGitCodeWebhookSubscribers(event)
                    let ready = targets.size == 1 && targets[0].channel == "telegram" && targets[0].peerId == expectedPeer
                    synchronized(sampleLock) { samples.add(ready) }
                }))
                let service = GatewayService(GatewayRouter(HashMap<String, ChannelPolicyConfig>()))
                services.add(service)
                service.registerAdapter(adapter, channelId: "telegram", accountId: "default")
                let observationDeadline = MonoTime.now() + Duration.second * 5
                service.start()
                check(MonoTime.now() < observationDeadline)
                check(adapter.startCount == 1 && synchronized(sampleLock) { samples.size == 1 && samples[0] })
                check(service.stop(deadline: observationDeadline).ok)
                check(adapter.stopCount == 1)
                let settled = managedStdioBroker().snapshot()
                check(!settled.running && settled.ownerCount == 0 && settled.readerCount == 0 && settled.dispatcherCount == 0)
                formal = true
            } catch (error: Exception) { bodyError = Some(error) } finally {
                let cleanupDeadline = MonoTime.now() + Duration.second * 3
                for (service in services) { attempt({ =>
                    if (!service.stop(deadline: cleanupDeadline).ok) { throw Exception("startup_channel_cleanup_pending") }
                }) }
                attempt({ => resetServicePluginHostForTest() })
                attempt({ =>
                    let remaining = (cleanupDeadline - MonoTime.now()).toMilliseconds()
                    if (remaining <= 0 || !resetManagedStdioBrokerForTest(timeoutMs: remaining).ok) { throw Exception("startup_channel_broker_pending") }
                })
                attempt({ => setServicePluginWebhookSubscribersProvider(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>) })
                attempt({ => setServicePluginEventDelivery(None<(ServicePluginDeliveryTarget, String) -> ServicePluginEventDeliveryResult>) })
                attempt({ => setServicePluginGeneratedReplyHandler(None<(ServicePluginPendingJob, ServicePluginAcceptedGitCodeEvent) -> ServicePluginGeneratedReplyResult>) })
                attempt({ => setServicePluginWebhookGeneratedReplyHandler(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>) })
                attempt({ => setGitCodeSubscriptionStore(None<GitCodeSubscriptionStore>) })
                attempt({ => match (oldHome) { case Some(value) => setVariable("METIS_HOME", value) case None => removeVariable("METIS_HOME") } })
                attempt({ => CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate() })
                attempt({ => gatewayLoggingResetForTest() })
                attempt({ => Config.logFile = oldLog })
                if (MonoTime.now() > cleanupDeadline) { errors.add(Exception("startup_channel_cleanup_deadline")) }
                if (formal && errors.isEmpty()) { attempt({ => remove(home, recursive: true) }) }
                else { let savedFormal = formal; attempt({ => println("STARTUP-DISPATCH retained=${home.fileName};formal=${savedFormal}") }) }
            }
            match (bodyError) { case Some(error) => throw error case None => () }
            if (!errors.isEmpty()) { throw errors[0] }
        }
    }
    @TestCase
    public func s3jU1FixedHomeRestoresStateAndRemovesOwnedDirectory(): Unit {
        let originalHome = getVariable("METIS_HOME")
        let originalLogFile = Config.logFile
        try {
            setVariable("METIS_HOME", "/tmp")
            CliConfig.invalidatePathCache()
            let expectedDotDir = CliConfig.dotDir.toString()
            let result = withGatewayServiceStartupTestHome<String>({ =>
                Config.logFile = CliConfig.logsDir.join("s3j-startup-inner.log").toString()
                "s3j-startup-ok"
            })
            @Expect(result, "s3j-startup-ok")
            @Expect(getVariable("METIS_HOME"), Some("/tmp"))
            @Expect(CliConfig.dotDir.toString(), expectedDotDir)
            @Expect(Config.logFile, originalLogFile)
            @Expect(exists(Path("/tmp/metis-gateway-service-startup-test-home")), false)
        } finally {
            match (originalHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => removeVariable("METIS_HOME")
            }
            CliConfig.invalidatePathCache()
            gatewayLoggingResetForTest()
            Config.logFile = originalLogFile
        }
    }

    @TestCase
    public func startupTimeoutDoesNotPreventPollLoopForHealthyAccount(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let router = GatewayRouter(HashMap<String, ChannelPolicyConfig>())
            let service = GatewayService(router, channelStartupAccountTimeoutMs: 30)
            let slow = GatewayServiceStartupFakeAdapter("telegram", startDelayMs: 160)
            let healthy = GatewayServiceStartupFakeAdapter("telegram")
            service.registerAdapter(slow, channelId: "telegram", accountId: "slow")
            service.registerAdapter(healthy, channelId: "telegram", accountId: "default")

            service.start()
            healthy.queue("")
            service.processOnceAndAwaitForTest()

            @Expect(slow.startCount, 1)
            @Expect(slow.stopCount, 1)
            @Expect(healthy.startCount, 1)
            @Expect(healthy.pullCount, 1)

            let slowAccounts = gatewayChannelRuntimeAccountsJson("telegram")
            var sawSlowFailure = false
            var sawHealthyRunning = false
            for (i in 0..slowAccounts.size()) {
                let row = slowAccounts[i].asObject()
                let accountId = row.get("accountId").getOrThrow().asString().getValue()
                let state = row.get("lifecycleState").getOrThrow().asString().getValue()
                if (accountId == "slow" && state == "failed") {
                    sawSlowFailure = true
                    @Expect(row.get("lastError").getOrThrow().asString().getValue().contains("timed out"), true)
                }
                if (accountId == "default" && state == "running") {
                    sawHealthyRunning = true
                }
            }
            @Expect(sawSlowFailure, true)
            @Expect(sawHealthyRunning, true)
        })
    }

    @TestCase
    public func startProbeTimeoutMarksAccountFailedNotRunning(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 20)
            let slow = GatewayServiceStartupFakeAdapter("telegram", startDelayMs: 120)
            manager.registerAdapter(slow, channelId: "telegram", accountId: "slow")

            let summary = manager.startChannels()

            @Expect(gatewayServiceStartupString(summary, "status"), "degraded")
            @Expect(gatewayServiceStartupInt(summary, "timedOutCount"), 1)
            let row = gatewayServiceStartupRuntimeAccount("telegram", "slow")
            @Expect(gatewayServiceStartupString(row, "lifecycleState"), "failed")
            @Expect(gatewayServiceStartupString(row, "errorKind"), "start_timeout")
            @Expect(gatewayServiceStartupBool(row, "running"), false)
            @Expect(gatewayServiceStartupBool(row, "connected"), false)
        })
    }

    @TestCase
    public func startTimeoutInvokesBestEffortStopOnce(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 20)
            let slow = GatewayServiceStartupFakeAdapter("telegram", startDelayMs: 120)
            manager.registerAdapter(slow, channelId: "telegram", accountId: "slow")

            manager.startChannels()
            sleep(Duration.millisecond * 180)

            @Expect(slow.stopCount, 1)
        })
    }

    @TestCase
    public func fastAccountStartDoesNotTriggerCleanup(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 1000)
            let fast = GatewayServiceStartupFakeAdapter("telegram")
            manager.registerAdapter(fast, channelId: "telegram", accountId: "default")

            let summary = manager.startChannels()

            @Expect(gatewayServiceStartupString(summary, "status"), "ok")
            @Expect(fast.startCount, 1)
            @Expect(fast.stopCount, 0)
        })
    }

    @TestCase
    public func startThrowMarksAccountFailedAndContinues(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 1000)
            let broken = GatewayServiceStartupFakeAdapter("telegram", failMessage: "boom")
            let later = GatewayServiceStartupFakeAdapter("telegram")
            manager.registerAdapter(broken, channelId: "telegram", accountId: "broken")
            manager.registerAdapter(later, channelId: "telegram", accountId: "later")

            let summary = manager.startChannels()

            @Expect(gatewayServiceStartupString(summary, "status"), "degraded")
            @Expect(gatewayServiceStartupInt(summary, "failedCount"), 1)
            @Expect(gatewayServiceStartupInt(summary, "okCount"), 1)
            @Expect(broken.stopCount, 1)
            @Expect(later.startCount, 1)
            let failed = gatewayServiceStartupSummaryAccount(summary, "broken")
            @Expect(gatewayServiceStartupString(failed, "channel"), "telegram")
            @Expect(gatewayServiceStartupString(failed, "accountId"), "broken")
            @Expect(gatewayServiceStartupString(failed, "errorKind"), "start_failed")
        })
    }

    @TestCase
    public func cleanupFailureIsLoggedButDoesNotBlockStartup(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            withGatewayServiceStartupLogCapture<Unit>("cleanup-failure", { path =>
                let manager = GatewayChannelManager(startupAccountTimeoutMs: 1000)
                let broken = GatewayServiceStartupFakeAdapter(
                    "telegram",
                    failMessage: "boom",
                    stopFailure: "cleanup exploded"
                )
                let later = GatewayServiceStartupFakeAdapter("telegram")
                manager.registerAdapter(broken, channelId: "telegram", accountId: "broken")
                manager.registerAdapter(later, channelId: "telegram", accountId: "later")

                let summary = manager.startChannels()
                let log = gatewayServiceStartupReadLog(path)

                @Expect(gatewayServiceStartupString(summary, "status"), "degraded")
                @Expect(gatewayServiceStartupInt(summary, "failedCount"), 1)
                @Expect(gatewayServiceStartupInt(summary, "okCount"), 1)
                @Expect(broken.stopCount, 1)
                @Expect(later.startCount, 1)
                @Expect(log.contains("channel.stop_cleanup_failed") || log.contains("cleanup_failed"), true)
            })
        })
    }

    @TestCase
    public func zeroTimeoutFailsImmediatelyWithCleanup(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 0)
            let slow = GatewayServiceStartupFakeAdapter("telegram", startDelayMs: 80)
            manager.registerAdapter(slow, channelId: "telegram", accountId: "slow")

            let summary = manager.startChannels()

            @Expect(gatewayServiceStartupString(summary, "status"), "degraded")
            @Expect(gatewayServiceStartupInt(summary, "timedOutCount"), 1)
            @Expect(slow.stopCount, 1)
            let row = gatewayServiceStartupRuntimeAccount("telegram", "slow")
            @Expect(gatewayServiceStartupString(row, "lifecycleState"), "failed")
            @Expect(gatewayServiceStartupString(row, "errorKind"), "start_timeout")
            @Expect(gatewayServiceStartupBool(row, "running"), false)
        })
    }

    @TestCase
    public func lateReadyAfterTimeoutDoesNotFlipRuntimeToRunning(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 20)
            let slow = GatewayServiceStartupFakeAdapter("telegram", startDelayMs: 80)
            manager.registerAdapter(slow, channelId: "telegram", accountId: "slow")

            manager.startChannels()
            sleep(Duration.millisecond * 140)

            let row = gatewayServiceStartupRuntimeAccount("telegram", "slow")
            @Expect(gatewayServiceStartupString(row, "lifecycleState"), "failed")
            @Expect(gatewayServiceStartupString(row, "errorKind"), "start_timeout")
            @Expect(gatewayServiceStartupBool(row, "running"), false)
            @Expect(gatewayServiceStartupBool(row, "connected"), false)
            @Expect(slow.stopCount, 1)
        })
    }

    @TestCase
    public func startChannelsReturnsSummaryWhenOneFeishuAccountTimesOut(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 20)
            let slow = GatewayServiceStartupFakeAdapter("feishu", startDelayMs: 120)
            let later = GatewayServiceStartupFakeAdapter("feishu")
            manager.registerAdapter(slow, channelId: "feishu", accountId: "tenant-a")
            manager.registerAdapter(later, channelId: "feishu", accountId: "tenant-b")

            let summary = manager.startChannels()

            @Expect(gatewayServiceStartupString(summary, "status"), "degraded")
            @Expect(gatewayServiceStartupBool(summary, "degraded"), true)
            @Expect(gatewayServiceStartupInt(summary, "accountCount"), 2)
            @Expect(gatewayServiceStartupInt(summary, "okCount"), 1)
            @Expect(gatewayServiceStartupInt(summary, "failedCount"), 0)
            @Expect(gatewayServiceStartupInt(summary, "timedOutCount"), 1)
            let failed = gatewayServiceStartupSummaryAccount(summary, "tenant-a")
            @Expect(gatewayServiceStartupString(failed, "channel"), "feishu")
            @Expect(gatewayServiceStartupString(failed, "accountId"), "tenant-a")
            @Expect(gatewayServiceStartupString(failed, "errorKind"), "start_timeout")
        })
    }

    @TestCase
    public func failedAccountDoesNotPreventLaterAccountStartup(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 1000)
            let broken = GatewayServiceStartupFakeAdapter("feishu", failMessage: "sidecar failed")
            let later = GatewayServiceStartupFakeAdapter("feishu")
            manager.registerAdapter(broken, channelId: "feishu", accountId: "tenant-a")
            manager.registerAdapter(later, channelId: "feishu", accountId: "tenant-b")

            let summary = manager.startChannels()

            @Expect(gatewayServiceStartupString(summary, "status"), "degraded")
            @Expect(gatewayServiceStartupInt(summary, "failedCount"), 1)
            @Expect(gatewayServiceStartupInt(summary, "okCount"), 1)
            @Expect(later.startCount, 1)
            @Expect(gatewayServiceStartupString(gatewayServiceStartupSummaryAccount(summary, "tenant-b"), "status"), "ok")
        })
    }

    @TestCase
    public func disabledAccountIsSkippedAndRecorded(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 1000)
            let disabled = GatewayServiceStartupFakeAdapter("feishu")
            let later = GatewayServiceStartupFakeAdapter("feishu")
            manager.registerAdapter(disabled, channelId: "feishu", accountId: "tenant-disabled", enabled: false)
            manager.registerAdapter(later, channelId: "feishu", accountId: "tenant-enabled")

            let summary = manager.startChannels()

            @Expect(gatewayServiceStartupString(summary, "status"), "ok")
            @Expect(gatewayServiceStartupInt(summary, "skippedCount"), 1)
            @Expect(gatewayServiceStartupInt(summary, "okCount"), 1)
            @Expect(disabled.startCount, 0)
            @Expect(disabled.stopCount, 0)
            @Expect(later.startCount, 1)
            let skipped = gatewayServiceStartupSummaryAccount(summary, "tenant-disabled")
            @Expect(gatewayServiceStartupString(skipped, "channel"), "feishu")
            @Expect(gatewayServiceStartupString(skipped, "status"), "skipped")
            @Expect(gatewayServiceStartupString(skipped, "errorKind"), "disabled")
        })
    }
}
