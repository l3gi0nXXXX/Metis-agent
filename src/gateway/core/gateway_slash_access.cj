package metis.gateway.core

import metis.gateway.model.ChannelPolicyConfig

public class GatewaySlashAccessDecision {
    public let allowed: Bool
    public let reason: String
    public let command: String
    public let senderId: String
    public let admin: Bool

    public init(
        allowed: Bool,
        reason!: String = "",
        command!: String = "",
        senderId!: String = "",
        admin!: Bool = false
    ) {
        this.allowed = allowed
        this.reason = reason.trimAscii()
        this.command = command.trimAscii()
        this.senderId = senderId.trimAscii()
        this.admin = admin
    }
}

private func gatewaySlashCommandName(command: String): String {
    var clean = command.trimAscii().toAsciiLower()
    if (clean.startsWith("/")) {
        clean = clean[1..]
    }
    for (part in clean.split(" ")) {
        let token = part.trimAscii()
        if (!token.isEmpty()) {
            return token.replace("_", "-")
        }
    }
    ""
}

private func gatewaySlashIsGroupChat(chatType: String): Bool {
    let clean = chatType.trimAscii().toAsciiLower()
    clean == "group" || clean == "room" || clean == "channel" || clean == "supergroup"
}

private func gatewaySlashContains(list: Array<String>, value: String): Bool {
    let target = value.trimAscii()
    for (item in list) {
        let clean = item.trimAscii()
        if (clean == "*" || clean == target) {
            return true
        }
    }
    false
}

private func gatewaySlashCommandAllowed(list: Array<String>, command: String): Bool {
    let cleanCommand = gatewaySlashCommandName(command)
    for (item in list) {
        let clean = gatewaySlashCommandName(item)
        if (clean == "*" || clean == cleanCommand) {
            return true
        }
    }
    false
}

private func gatewaySlashAlwaysAllowed(command: String): Bool {
    let clean = gatewaySlashCommandName(command)
    clean == "help" || clean == "whoami"
}

private func gatewaySlashAdminList(policy: ChannelPolicyConfig, chatType: String): Array<String> {
    if (gatewaySlashIsGroupChat(chatType)) {
        return policy.groupAllowAdminFrom
    }
    policy.allowAdminFrom
}

private func gatewaySlashUserCommandList(policy: ChannelPolicyConfig, chatType: String): Array<String> {
    if (gatewaySlashIsGroupChat(chatType)) {
        return policy.groupUserAllowedCommands
    }
    if (!policy.userAllowedCommands.isEmpty()) {
        return policy.userAllowedCommands
    }
    // Match Hermes slash access: DM user commands may fall back to group user commands,
    // while admin lists remain scope-specific.
    policy.groupUserAllowedCommands
}

public func gatewayCheckSlashAccess(
    policy: ChannelPolicyConfig,
    chatType: String,
    senderId: String,
    command: String
): GatewaySlashAccessDecision {
    let cleanCommand = gatewaySlashCommandName(command)
    let cleanSender = senderId.trimAscii()
    if (gatewaySlashAlwaysAllowed(cleanCommand)) {
        return GatewaySlashAccessDecision(true, reason: "always-allowed", command: cleanCommand, senderId: cleanSender)
    }

    let adminList = gatewaySlashAdminList(policy, chatType)
    let userCommandList = gatewaySlashUserCommandList(policy, chatType)
    if (adminList.isEmpty() && userCommandList.isEmpty()) {
        return GatewaySlashAccessDecision(true, reason: "access-policy-disabled", command: cleanCommand, senderId: cleanSender)
    }
    if (cleanSender.isEmpty()) {
        return GatewaySlashAccessDecision(false, reason: "missing-identity", command: cleanCommand, senderId: cleanSender)
    }
    if (gatewaySlashContains(adminList, cleanSender)) {
        return GatewaySlashAccessDecision(true, reason: "admin", command: cleanCommand, senderId: cleanSender, admin: true)
    }
    if (gatewaySlashCommandAllowed(userCommandList, cleanCommand)) {
        return GatewaySlashAccessDecision(true, reason: "user-command-allowed", command: cleanCommand, senderId: cleanSender)
    }
    GatewaySlashAccessDecision(false, reason: "denied", command: cleanCommand, senderId: cleanSender)
}

public func gatewaySlashAccessDeniedMessage(decision: GatewaySlashAccessDecision): String {
    if (decision.allowed) {
        return ""
    }
    if (decision.reason == "missing-identity") {
        return "Cannot run /${decision.command}: sender identity is required."
    }
    "Cannot run /${decision.command}: sender is not allowed by Gateway slash access policy."
}
