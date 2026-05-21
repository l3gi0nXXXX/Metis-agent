package metis.gateway.core

import metis.core.config.CliConfig
import metis.gateway.model.{ChannelPolicyConfig, ChannelType, ChatType, InboundMessage, OutboundMessage, SendResult}

import std.collection.{ArrayList, HashMap}
import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.time.DateTime
import std.core.Duration
import std.unittest.testmacro.*

private func withGatewayServiceStartupTestHome<T>(block: () -> T): T {
    let testHome = "/tmp/metis-gateway-service-startup-test-home"
    try {
        remove(Path(testHome), recursive: true)
    } catch (_: Exception) {
        ()
    }
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
    }
}

private class GatewayServiceStartupFakeAdapter <: ChannelAdapter {
    private let adapterName: String
    private let startDelayMs: Int64
    private let inbound = ArrayList<InboundMessage>()
    public var startCount: Int64 = 0
    public var stopCount: Int64 = 0
    public var pullCount: Int64 = 0
    public var sendCount: Int64 = 0

    public init(adapterName: String, startDelayMs!: Int64 = 0) {
        this.adapterName = adapterName
        this.startDelayMs = startDelayMs
    }

    public prop name: String {
        get() { this.adapterName }
    }

    public func start(): Unit {
        this.startCount += 1
        if (this.startDelayMs > 0) {
            sleep(Duration.millisecond * this.startDelayMs)
        }
    }

    public func stop(): Unit {
        this.stopCount += 1
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

@Test
public class GatewayServiceStartupTest {
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
            service.processOnce()

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
}
