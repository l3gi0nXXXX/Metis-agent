package metis.gateway.core

import metis.gateway.model.{ChannelType, ChatType, FeishuAckConfig, InboundMessage}

import std.time.DateTime
import std.unittest.testmacro.*

private func feishuAckPolicyInbound(
    messageId!: String = "om_1",
    systemEvent!: Bool = false
): InboundMessage {
    InboundMessage(
        ChannelType.Feishu,
        messageId,
        "oc_1",
        "ou_1",
        ChatType.Direct,
        "你好",
        true,
        DateTime.now(),
        systemEvent: systemEvent
    )
}

@Test
public class GatewayFeishuAckPolicyTest {
    @TestCase
    public func defaultFeishuAckIsDisabled(): Unit {
        let config = FeishuAckConfig()

        @Expect(gatewayFeishuAckEnabled(config), false)
        @Expect(gatewayFeishuAckReaction(config), "Typing")
        @Expect(gatewayFeishuShouldAckInbound(config, feishuAckPolicyInbound()), false)
    }

    @TestCase
    public func feishuAckTypingAliasesNormalizeToTyping(): Unit {
        let keyboard = FeishuAckConfig(enabled: true, reaction: "keyboard")
        let chinese = FeishuAckConfig(enabled: true, reaction: "敲键盘")

        @Expect(gatewayFeishuAckEnabled(keyboard), true)
        @Expect(gatewayFeishuAckReaction(keyboard), "Typing")
        @Expect(gatewayFeishuAckReaction(chinese), "Typing")
        @Expect(gatewayFeishuShouldAckInbound(chinese, feishuAckPolicyInbound()), true)
    }

    @TestCase
    public func feishuAckDisabledScopeOverridesEnabled(): Unit {
        let config = FeishuAckConfig(enabled: true, scope: "disabled")

        @Expect(gatewayFeishuAckEnabled(config), false)
        @Expect(gatewayFeishuShouldAckInbound(config, feishuAckPolicyInbound()), false)
    }

    @TestCase
    public func feishuAckRequiresRealHandledMessage(): Unit {
        let config = FeishuAckConfig(enabled: true)

        @Expect(gatewayFeishuShouldAckInbound(config, feishuAckPolicyInbound(messageId: "")), false)
        @Expect(gatewayFeishuShouldAckInbound(config, feishuAckPolicyInbound(systemEvent: true)), false)
    }
}
