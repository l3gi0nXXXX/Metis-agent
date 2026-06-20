package metis.gateway.core

import metis.gateway.model.{FeishuAckConfig, InboundMessage}

public func gatewayFeishuAckEnabled(config: FeishuAckConfig): Bool {
    if (!config.enabled) {
        return false
    }
    let scope = config.scope.trimAscii().toAsciiLower()
    !(scope == "off" || scope == "none" || scope == "false" || scope == "disabled")
}

public func gatewayFeishuAckReaction(config: FeishuAckConfig): String {
    let raw = config.reaction.trimAscii()
    if (raw.isEmpty()) {
        return "Typing"
    }
    let normalized = raw.toAsciiLower()
    if (normalized == "typing" ||
        normalized == "keyboard" ||
        normalized == "keystroke" ||
        normalized == "metis" ||
        normalized == "metis_ack" ||
        normalized == "metis-ack" ||
        raw == "敲键盘") {
        return "Typing"
    }
    raw
}

public func gatewayFeishuShouldAckInbound(config: FeishuAckConfig, message: InboundMessage): Bool {
    gatewayFeishuAckEnabled(config) &&
        !message.systemEvent &&
        !message.messageId.trimAscii().isEmpty()
}
