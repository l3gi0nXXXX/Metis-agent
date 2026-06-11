package metis.gateway.core

import metis.core.model.{CODEX_RUNTIME_APP_SERVER, CODEX_RUNTIME_AUTO, CodexAppServerBinaryCheck}
import metis.gateway.model.{ChannelPolicyConfig, ChatType}
import metis.gateway.session.GatewayTurnContext

import std.unittest.testmacro.*

@Test
public class GatewayRuntimeSwitchGuardTest {
    private func okBinary(): CodexAppServerBinaryCheck {
        CodexAppServerBinaryCheck(true, status: "ok", version: "0.130.0")
    }

    @TestCase
    public func slashAccessHonorsDirectGroupAdminAndAlwaysAllowedCommands(): Unit {
        let defaultPolicy = ChannelPolicyConfig()
        @Expect(gatewayCheckSlashAccess(defaultPolicy, "direct", "", "help").allowed, true)
        @Expect(gatewayCheckSlashAccess(defaultPolicy, "direct", "user", "codex-runtime").allowed, true)

        let directPolicy = ChannelPolicyConfig(
            allowAdminFrom: ["admin"],
            userAllowedCommands: ["status"]
        )
        @Expect(gatewayCheckSlashAccess(directPolicy, "direct", "admin", "codex-runtime").allowed, true)
        @Expect(gatewayCheckSlashAccess(directPolicy, "direct", "user", "status").allowed, true)
        @Expect(gatewayCheckSlashAccess(directPolicy, "direct", "user", "codex-runtime").allowed, false)

        let groupPolicy = ChannelPolicyConfig(groupAllowAdminFrom: ["group-admin"])
        @Expect(gatewayCheckSlashAccess(groupPolicy, "group", "group-admin", "codex-runtime").allowed, true)
        @Expect(gatewayCheckSlashAccess(groupPolicy, "group", "admin", "codex-runtime").allowed, false)

        let dmFallbackPolicy = ChannelPolicyConfig(
            groupAllowAdminFrom: ["group-admin"],
            groupUserAllowedCommands: ["codex-runtime"]
        )
        @Expect(gatewayCheckSlashAccess(dmFallbackPolicy, "direct", "user", "codex-runtime").allowed, true)
        @Expect(gatewayCheckSlashAccess(dmFallbackPolicy, "direct", "group-admin", "other-command").allowed, false)
    }

    @TestCase
    public func guardDeniesNonAdminNoIdentityReadOnlyAndRunningMutations(): Unit {
        let adminPolicy = ChannelPolicyConfig(allowAdminFrom: ["admin"])
        let nonAdmin = gatewayApplyRuntimeSwitchGuard(GatewayRuntimeSwitchGuardRequest(
            rawArgs: "on",
            channelPolicy: adminPolicy,
            senderId: "user",
            binaryCheck: this.okBinary()
        ))
        @Expect(nonAdmin.status, "slash-access-denied")

        let noIdentity = gatewayApplyRuntimeSwitchGuard(GatewayRuntimeSwitchGuardRequest(
            rawArgs: "on",
            senderId: "",
            binaryCheck: this.okBinary()
        ))
        @Expect(noIdentity.status, "missing-identity")

        let readOnly = gatewayApplyRuntimeSwitchGuard(GatewayRuntimeSwitchGuardRequest(
            rawArgs: "on",
            channelPolicy: adminPolicy,
            senderId: "admin",
            binaryCheck: this.okBinary(),
            readOnly: true
        ))
        @Expect(readOnly.status, "read-only")

        let running = gatewayApplyRuntimeSwitchGuard(GatewayRuntimeSwitchGuardRequest(
            rawArgs: "on",
            channelPolicy: adminPolicy,
            senderId: "admin",
            binaryCheck: this.okBinary(),
            running: true
        ))
        @Expect(running.status, "running")
    }

    @TestCase
    public func guardBlocksMissingBinaryAndInvalidatesCacheOnSuccessfulSwitch(): Unit {
        let adminPolicy = ChannelPolicyConfig(allowAdminFrom: ["admin"])
        let missing = gatewayApplyRuntimeSwitchGuard(GatewayRuntimeSwitchGuardRequest(
            rawArgs: "on",
            channelPolicy: adminPolicy,
            senderId: "admin",
            binaryCheck: CodexAppServerBinaryCheck(false, status: "not-found", message: "missing"),
            sessionKey: "telegram:direct:1"
        ))
        @Expect(missing.success, false)
        @Expect(missing.status, "binary-unavailable")
        @Expect(missing.mutated, false)
        @Expect(missing.cacheInvalidation.shouldInvalidate, false)

        let enabled = gatewayApplyRuntimeSwitchGuard(GatewayRuntimeSwitchGuardRequest(
            rawArgs: "on",
            channelPolicy: adminPolicy,
            senderId: "admin",
            binaryCheck: this.okBinary(),
            sessionKey: "telegram:direct:1"
        ))
        @Expect(enabled.success, true)
        @Expect(enabled.mutated, true)
        @Expect(enabled.newValue, CODEX_RUNTIME_APP_SERVER)
        @Expect(enabled.cacheInvalidation.shouldInvalidate, true)
        @Expect(enabled.cacheInvalidation.reason, "codex-runtime-switch")
    }

    @TestCase
    public func statusAndOffUseHumanOutputWithoutRawJsonKeys(): Unit {
        let adminPolicy = ChannelPolicyConfig(allowAdminFrom: ["admin"])
        let status = gatewayApplyRuntimeSwitchGuard(GatewayRuntimeSwitchGuardRequest(
            rawArgs: "status",
            channelPolicy: adminPolicy,
            senderId: "admin",
            currentRuntime: CODEX_RUNTIME_APP_SERVER,
            binaryCheck: this.okBinary()
        ))
        @Expect(status.success, true)
        @Expect(status.mutated, false)
        @Expect(status.message.contains("\"ok\""), false)
        @Expect(status.message.contains("\"result\""), false)
        @Expect(status.message.contains("\"sessions\""), false)

        let disabled = gatewayApplyRuntimeSwitchGuard(GatewayRuntimeSwitchGuardRequest(
            rawArgs: "off",
            channelPolicy: adminPolicy,
            senderId: "admin",
            currentRuntime: CODEX_RUNTIME_APP_SERVER,
            binaryCheck: CodexAppServerBinaryCheck(false, status: "not-found", message: "missing"),
            sessionKey: "telegram:direct:1"
        ))
        @Expect(disabled.success, true)
        @Expect(disabled.newValue, CODEX_RUNTIME_AUTO)
        @Expect(disabled.mutated, true)
        @Expect(disabled.cacheInvalidation.shouldInvalidate, true)
    }

    @TestCase
    public func gatewayTurnContextCarriesM4IdentityFields(): Unit {
        let ctx = GatewayTurnContext(
            "main",
            senderId: "sender-1",
            operatorScopes: ["gateway.admin"],
            chatType: Some(ChatType.Group)
        )
        @Expect(ctx.senderId, "sender-1")
        @Expect(ctx.operatorScopes.contains("gateway.admin"), true)
        @Expect(ctx.chatType.isSome(), true)
    }
}
