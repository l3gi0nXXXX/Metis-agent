package metis.gateway.core

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.model.{ChannelPolicyConfig, ChannelType, ChatType, InboundMessage, OutboundMessage, SendResult}

import std.collection.{ArrayList, HashMap}
import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString}

private class GatewayFeishuNativeTestAdapter <: ChannelAdapter {
    private let inbound = ArrayList<InboundMessage>()
    private let sent = ArrayList<OutboundMessage>()

    public prop name: String {
        get() { "feishu" }
    }

    public func start(): Unit {}

    public func stop(): Unit {}

    public func queueDirect(text: String): Unit {
        this.inbound.add(InboundMessage(
            ChannelType.Feishu,
            "om-${this.inbound.size}",
            "ou_peer",
            "ou_sender",
            ChatType.Direct,
            text,
            true,
            DateTime.now(),
            accountId: "default"
        ))
    }

    public func queueGroup(text: String): Unit {
        this.inbound.add(InboundMessage(
            ChannelType.Feishu,
            "om-group-${this.inbound.size}",
            "oc_group",
            "ou_sender",
            ChatType.Group,
            text,
            false,
            DateTime.now(),
            accountId: "default"
        ))
    }

    public func pullInbound(): Array<InboundMessage> {
        let out = this.inbound.toArray()
        this.inbound.clear()
        out
    }

    public func send(message: OutboundMessage): SendResult {
        this.sent.add(message)
        SendResult.Success
    }

    public func sendWithMessageId(message: OutboundMessage): String {
        this.sent.add(message)
        "feishu-native-${this.sent.size}"
    }

    public func sentText(index: Int64): String {
        match (this.sent.get(index)) {
            case Some(v) => v.text
            case None => ""
        }
    }

    public func sentCount(): Int64 {
        this.sent.size
    }
}

private func gatewayFeishuNativeTestRoot(appSecret!: String = ""): JsonObject {
    let root = JsonObject()
    let gateway = JsonObject()
    let feishu = JsonObject()
    feishu.put("enabled", JsonBool(true))
    feishu.put("defaultAccount", JsonString("default"))
    feishu.put("receiveMode", JsonString("long_connect"))
    feishu.put("domain", JsonString("https://open.feishu.cn"))
    feishu.put("appId", JsonString("cli_test_app"))
    feishu.put("appSecret", JsonString(appSecret))
    gateway.put("feishu", feishu)
    root.put("gateway", gateway)
    root.put("agents", JsonArray([]))
    root.put("bindings", JsonArray([]))
    root
}

private func withGatewayFeishuNativeTestHome<T>(label: String, root: JsonObject, block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let testHome = "/tmp/metis-gateway-feishu-native-${label}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}"
        try { remove(Path(testHome), recursive: true) } catch (_e: Exception) { () }
        Directory.create(testHome, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", testHome)
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        MetisConfigManager.writeRoot(root)
        CliSettingManager.applyPersistedFieldsToCliConfig()
        try {
            return block()
        } finally {
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            try { remove(Path(testHome), recursive: true) } catch (_e: Exception) { () }
        }
    }
}

private func gatewayFeishuNativeService(adapter: GatewayFeishuNativeTestAdapter, enableGroup!: Bool = true): GatewayService {
    let policies = HashMap<String, ChannelPolicyConfig>()
    policies["feishu"] = ChannelPolicyConfig(enableDirect: true, enableGroup: enableGroup, requireMentionInGroup: true)
    let service = GatewayService(GatewayRouter(policies))
    service.registerAdapter(adapter, channelId: "feishu", accountId: "default")
    service
}

@Test
public class GatewayServiceFeishuNativeTest {
    @TestCase
    public func feishuStartNativeCommandBypassesGroupGate(): Unit {
        withGatewayFeishuNativeTestHome("start", gatewayFeishuNativeTestRoot(), { =>
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter, enableGroup: false)
            service.start()
            try {
                adapter.queueGroup("/feishu start")
                service.processOnce()
                @Expect(adapter.sentCount(), 1)
                @Expect(adapter.sentText(0).contains("Metis Feishu start"), true)
                @Expect(adapter.sentText(0).contains("accountId: default"), true)
            } finally {
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuDoctorReportsMissingBindingsAndRedactsSecret(): Unit {
        withGatewayFeishuNativeTestHome("doctor", gatewayFeishuNativeTestRoot(appSecret: "top-secret"), { =>
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            service.start()
            try {
                adapter.queueDirect("/feishu doctor")
                service.processOnce()
                let reply = adapter.sentText(0)
                @Expect(adapter.sentCount(), 1)
                @Expect(reply.contains("Metis Feishu doctor"), true)
                @Expect(reply.contains("credentials: configured"), true)
                @Expect(reply.contains("bindings: missing"), true)
                @Expect(reply.contains("top-secret"), false)
            } finally {
                service.stop()
            }
        })
    }

    @TestCase
    public func feishuAuthCommandReturnsExplicitAuthorizationGuidance(): Unit {
        withGatewayFeishuNativeTestHome("auth", gatewayFeishuNativeTestRoot(), { =>
            let adapter = GatewayFeishuNativeTestAdapter()
            let service = gatewayFeishuNativeService(adapter)
            service.start()
            try {
                adapter.queueDirect("/feishu auth")
                service.processOnce()
                let reply = adapter.sentText(0)
                @Expect(adapter.sentCount(), 1)
                @Expect(reply.contains("Metis Feishu auth"), true)
                @Expect(reply.contains("OAuth/user authorization: not completed"), true)
            } finally {
                service.stop()
            }
        })
    }
}
