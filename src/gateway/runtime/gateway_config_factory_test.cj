package metis.gateway.runtime

import metis.core.config.{CliConfig, GatewayUserSettings, GatewayServicePluginUserSettings, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.core.GatewayService
import metis.gateway.service_plugin.*
import metis.gateway.gitcode_plugin.{GitCodeSubscriptionStore, GitCodeSubscriptionTarget, GitCodeSubscriptionScope, setGitCodeSubscriptionStore}
import metis.gateway.logging.gatewayLoggingResetForTest
import metis.process.{managedStdioBroker, resetManagedStdioBrokerForTest}
import magic.config.Config
import std.collection.ArrayList
import std.sync.Mutex
import std.time.MonoTime
import std.core.Duration
import metis.gateway.channels.feishu.FeishuAdapter
import metis.gateway.channels.qq.QQAdapter
import metis.gateway.channels.telegram.TelegramAdapter

import std.env.{getVariable, setVariable, removeVariable, getProcessId}
import std.fs.{Directory, File, Path, exists, remove}
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString}

private func withGatewayConfigFactoryTestHome<T>(block: () -> T): T {
    let testHome = "/tmp/metis-gateway-config-factory-test-home"
    @Expect(testHome, "/tmp/metis-gateway-config-factory-test-home")
    try {
        remove(Path(testHome), recursive: true)
    } catch (_: Exception) {
        ()
    }
    @Expect(exists(Path(testHome)), false)
    Directory.create(testHome, recursive: true)
    let oldHome = getVariable("METIS_HOME")
    setVariable("METIS_HOME", testHome)
    CliConfig.invalidatePathCache()
    try {
        return block()
    } finally {
        match (oldHome) {
            case Some(value) => setVariable("METIS_HOME", value)
            case None => setVariable("METIS_HOME", "")
        }
        CliConfig.invalidatePathCache()
        try {
            remove(Path(testHome), recursive: true)
        } catch (_: Exception) {
            ()
        }
        @Expect(exists(Path(testHome)), false)
    }
}

private func factorySnapshotAccounts(snapshot: JsonObject, channelId: String): JsonArray {
    let channelAccounts = (snapshot.get("channelAccounts") ?? JsonObject()).asObject()
    (channelAccounts.get(channelId) ?? JsonArray([])).asArray()
}

private func factorySnapshotHasAccount(snapshot: JsonObject, channelId: String, accountId: String): Bool {
    let accounts = factorySnapshotAccounts(snapshot, channelId)
    for (i in 0..accounts.size()) {
        let row = try { accounts[i].asObject() } catch (_: Exception) { JsonObject() }
        let id = try { (row.get("accountId") ?? JsonString("")).asString().getValue() } catch (_: Exception) { "" }
        if (id == accountId) {
            return true
        }
    }
    false
}

@Test
public class GatewayConfigFactoryTest {

    @TestCase
    public func buildDefersAutostartUntilGatewayStartInstallsSubscribers(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let home = Directory.createTemp("/private/tmp")
            let oldHome = getVariable("METIS_HOME")
            let oldLog = Config.logFile
            let services = ArrayList<GatewayService>()
            let errors = ArrayList<Exception>()
            let phases = ArrayList<Bool>()
            let phaseLock = Mutex()
            let attempt = { action: () -> Unit => try { action() } catch (error: Exception) { errors.add(error) } }
            let check = { value: Bool =>
                @Expect(value, true)
                if (!value) { throw Exception("startup_factory_order_failed") }
            }
            var bodyError = None<Exception>
            var formal = false
            try {
                File.writeTo(home.join("startup-dispatch.owner"),
                    "metis-startup-dispatch-v1\ntestPid:${getProcessId()}\nname:factory-order\n".toArray())
                setVariable("METIS_HOME", home.toString())
                CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
                resetServicePluginHostForTest()
                check(resetManagedStdioBrokerForTest(timeoutMs: 2000).ok)
                setServicePluginWebhookSubscribersProvider(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
                let launched = home.join("launched")
                let script = "printf 'launch\\n' >> '${launched.toString()}'; " +
                    "printf '%s\\n' '{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"gitcode-monitor\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}'; " +
                    "while IFS= read -r request; do exit 0; done"
                let manifest = home.join("plugin.json")
                let declaration = JsonObject()
                declaration.put("schema", JsonString("metis.servicePlugin.v1"))
                declaration.put("pluginId", JsonString("gitcode-monitor"))
                declaration.put("kind", JsonString("service"))
                declaration.put("protocolVersion", JsonString("1.0"))
                let entry = JsonObject()
                entry.put("command", JsonString("/bin/sh"))
                let args = JsonArray()
                for (value in ["-c", script, "startup", "参数中文😀"]) { args.add(JsonString(value)) }
                entry.put("args", args)
                declaration.put("entry", entry)
                let configSchema = JsonObject()
                configSchema.put("type", JsonString("object"))
                declaration.put("configSchema", configSchema)
                let capabilities = JsonArray()
                let capability = JsonObject()
                capability.put("capabilityId", JsonString("gitcode.monitor.status"))
                capability.put("kind", JsonString("controlAction"))
                capabilities.add(capability)
                declaration.put("capabilityDeclarations", capabilities)
                File.writeTo(manifest, declaration.toJsonString().toArray())
                var plugin = GatewayServicePluginUserSettings()
                plugin.pluginId = "gitcode-monitor"
                plugin.manifestPath = manifest.toString()
                plugin.autostart = true
                plugin.startupTimeoutMs = 1000
                var user = GatewayUserSettings()
                user.servicePlugins = [plugin]
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
                let expectedPeer = "startup-peer中文😀"
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
                let event = ServicePluginAcceptedGitCodeEvent(eventId: "startup-order", jobId: "webhook-startup-order",
                    repo: "cangjie/compiler", kind: "issue", number: "1", url: "https://example.invalid/issue/1")
                setServicePluginStartPhaseHookForTest(Some({ serviceId: String, phase: String =>
                    if (serviceId == "gitcode-monitor" && phase == "before_start") {
                        let targets = resolveGitCodeWebhookSubscribers(event)
                        let ready = targets.size == 1 && targets[0].peerId == expectedPeer && targets[0].channel == "telegram"
                        synchronized(phaseLock) { phases.add(ready) }
                    }
                }))
                let (gateway, _feishu) = buildGatewayServiceFromUserSettings(user)
                services.add(gateway)
                let deferred = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                check(deferred.status == "registered" && deferred.pid == 0 && !exists(launched))
                check(synchronized(phaseLock) { phases.isEmpty() })
                check(managedStdioBroker().snapshot().ownerCount == 0)
                let observationDeadline = MonoTime.now() + Duration.second * 5
                gateway.start()
                check(MonoTime.now() < observationDeadline)
                check(synchronized(phaseLock) { phases.size == 1 && phases[0] })
                let active = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                check(active.status == "running" && active.pid > 1)
                let marker = try { String.fromUtf8(File.readFrom(launched)) }
                    catch (_: Exception) { throw Exception("startup_factory_marker_invalid_encoding") }
                check(marker == "launch\n")
                check(gateway.stop(deadline: observationDeadline).ok)
                let resourceDeadline = MonoTime.now() + Duration.second * 2
                check(servicePluginCleanupPendingCountForTest() == 0)
                let resourceRemaining = (resourceDeadline - MonoTime.now()).toMilliseconds()
                check(resourceRemaining > 0)
                check(resetManagedStdioBrokerForTest(timeoutMs: resourceRemaining).ok)
                let settled = managedStdioBroker().snapshot()
                check(!settled.running && settled.ownerCount == 0 && settled.readerCount == 0 && settled.dispatcherCount == 0)
                formal = true
            } catch (error: Exception) { bodyError = Some(error) } finally {
                let cleanupDeadline = MonoTime.now() + Duration.second * 3
                attempt({ => setServicePluginStartPhaseHookForTest(None<(String, String) -> Unit>) })
                for (service in services) { attempt({ =>
                    if (!service.stop(deadline: cleanupDeadline).ok) { throw Exception("startup_factory_cleanup_pending") }
                }) }
                attempt({ => resetServicePluginHostForTest() })
                attempt({ =>
                    let remaining = (cleanupDeadline - MonoTime.now()).toMilliseconds()
                    if (remaining <= 0 || !resetManagedStdioBrokerForTest(timeoutMs: remaining).ok) { throw Exception("startup_factory_broker_pending") }
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
                if (MonoTime.now() > cleanupDeadline) { errors.add(Exception("startup_factory_cleanup_deadline")) }
                if (formal && errors.isEmpty()) { attempt({ => remove(home, recursive: true) }) }
                else { let savedFormal = formal; attempt({ => println("STARTUP-DISPATCH retained=${home.fileName};formal=${savedFormal}") }) }
            }
            match (bodyError) { case Some(error) => throw error case None => () }
            if (!errors.isEmpty()) { throw errors[0] }
        }
    }
    @TestCase
    public func gatewayShellReadySummaryFormatsHumanChannelSnapshot(): Unit {
        let snapshot = JsonObject()
        let channelAccounts = JsonObject()
        let telegramAccounts = JsonArray([])
        let running = JsonObject()
        running.put("accountId", JsonString("default"))
        running.put("configured", JsonBool(true))
        running.put("running", JsonBool(true))
        running.put("connected", JsonBool(true))
        running.put("lastError", JsonString(""))
        telegramAccounts.add(running)
        let waiting = JsonObject()
        waiting.put("accountId", JsonString("writer"))
        waiting.put("configured", JsonBool(true))
        waiting.put("running", JsonBool(false))
        waiting.put("connected", JsonBool(false))
        waiting.put("lastError", JsonString(""))
        telegramAccounts.add(waiting)
        channelAccounts.put("telegram", telegramAccounts)
        snapshot.put("channelAccounts", channelAccounts)

        let lines = gatewayShellReadySummaryLines(
            "qwen/test",
            "/tmp/metis.log",
            "http://127.0.0.1:8080",
            "http://127.0.0.1:8080/control",
            snapshot,
            42
        )
        let rendered = String.join(lines, delimiter: "\n")
        @Expect(rendered.contains("model: qwen/test"), true)
        @Expect(rendered.contains("log file: /tmp/metis.log"), true)
        @Expect(rendered.contains("Control UI: http://127.0.0.1:8080/control"), true)
        @Expect(rendered.contains("channel telegram/default running"), true)
        @Expect(rendered.contains("channel telegram/writer waiting"), true)
        @Expect(rendered.contains("{\""), false)
    }

    @TestCase
    public func buildGatewayServiceRegistersNativeTelegramAdapter(): Unit {
        var user = GatewayUserSettings()
        user.telegram.enabled = true
        user.telegram.botToken = "telegram-token"

        let (gateway, _feishu) = buildGatewayServiceFromUserSettings(user)
        let adapter = gateway.getAdapter("telegram")
        @Expect(adapter.isSome(), true)
        @Expect(adapter.getOrThrow() is TelegramAdapter, true)
    }

    @TestCase
    public func buildGatewayServiceRegistersConfiguredImAccountsWithPureAccountIds(): Unit {
        withGatewayConfigFactoryTestHome {
            var user = GatewayUserSettings()

            user.feishu.enabled = true
            let feishuAccounts = JsonObject()
            let feishuWriter = JsonObject()
            feishuWriter.put("appId", JsonString("feishu-writer-app"))
            feishuWriter.put("appSecret", JsonString("feishu-writer-secret"))
            feishuAccounts.put("feishu-writer", feishuWriter)
            user.feishu.accounts = Some(feishuAccounts)

            user.telegram.enabled = true
            let telegramAccounts = JsonObject()
            let tgWriter = JsonObject()
            tgWriter.put("botToken", JsonString("100001:writer"))
            telegramAccounts.put("tg-writer", tgWriter)
            user.telegram.accounts = Some(telegramAccounts)

            user.qq.enabled = true
            let qqAccounts = JsonObject()
            let qqWriter = JsonObject()
            qqWriter.put("appId", JsonString("qq-writer-app"))
            qqWriter.put("appSecret", JsonString("qq-writer-secret"))
            qqAccounts.put("qq-writer", qqWriter)
            user.qq.accounts = Some(qqAccounts)

            let (gateway, _feishu) = buildGatewayServiceFromUserSettings(user)
            let snapshot = gateway.liveChannelSnapshot()
            @Expect(factorySnapshotHasAccount(snapshot, "feishu", "feishu-writer"), true)
            @Expect(factorySnapshotHasAccount(snapshot, "telegram", "tg-writer"), true)
            @Expect(factorySnapshotHasAccount(snapshot, "qq", "qq-writer"), true)
            @Expect(factorySnapshotHasAccount(snapshot, "telegram", "telegram:tg-writer"), false)
            @Expect(factorySnapshotHasAccount(snapshot, "feishu", "default"), false)

            let feishuAdapter = gateway.getAdapter("feishu").getOrThrow()
            @Expect(feishuAdapter is FeishuAdapter, true)
            let telegramAdapter = gateway.getAdapter("telegram").getOrThrow()
            @Expect(telegramAdapter is TelegramAdapter, true)
            let qqAdapter = gateway.getAdapter("qq").getOrThrow()
            @Expect(qqAdapter is QQAdapter, true)
        }
    }

    @TestCase
    public func buildGatewayServiceSkipsDisabledOrUnconfiguredImProfilesAtAutostartRegistration(): Unit {
        withGatewayConfigFactoryTestHome {
            var user = GatewayUserSettings()
            user.telegram.enabled = true
            let telegramAccounts = JsonObject()
            let disabled = JsonObject()
            disabled.put("enabled", JsonBool(false))
            disabled.put("botToken", JsonString("100002:disabled"))
            telegramAccounts.put("tg-disabled", disabled)
            let unconfigured = JsonObject()
            telegramAccounts.put("tg-empty", unconfigured)
            user.telegram.accounts = Some(telegramAccounts)

            user.feishu.enabled = true
            user.feishu.receiveMode = "long_connect"
            let feishuAccounts = JsonObject()
            let missingCredentials = JsonObject()
            missingCredentials.put("appId", JsonString(""))
            missingCredentials.put("appSecret", JsonString(""))
            feishuAccounts.put("feishu-empty", missingCredentials)
            user.feishu.accounts = Some(feishuAccounts)

            let (gateway, _feishu) = buildGatewayServiceFromUserSettings(user)
            let snapshot = gateway.liveChannelSnapshot()
            @Expect(factorySnapshotHasAccount(snapshot, "telegram", "tg-disabled"), false)
            @Expect(factorySnapshotHasAccount(snapshot, "telegram", "tg-empty"), false)
            @Expect(factorySnapshotHasAccount(snapshot, "feishu", "feishu-empty"), false)
        }
    }
}
