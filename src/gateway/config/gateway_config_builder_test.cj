package metis.gateway.config

import metis.core.config.GatewayUserSettings

import magic.jsonable.*
import std.collection.HashMap
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString, JsonValue}

@Test
public class GatewayConfigBuilderTest {
    @TestCase
    public func mergedGatewayUserSettingsStillMapBuiltinChannelConfigs(): Unit {
        var user = GatewayUserSettings()
        user.feishu.enabled = true
        user.feishu.appId = "cli-feishu-app"
        user.qq.enabled = true
        user.qq.appId = "cli-qq-app"

        let (feishu, qq, telegram) = mergeGatewayUserSettings(user)
        @Expect(feishu.enabled, true)
        @Expect(feishu.appId, "cli-feishu-app")
        @Expect(qq.enabled, true)
        @Expect(qq.appId, "cli-qq-app")
        @Expect(telegram.enabled, false)
    }

    @TestCase
    public func gatewayConfigBuilderStillProducesRuntimeConfigOutsideGatewayRuntimePackage(): Unit {
        var user = GatewayUserSettings()
        user.enabled = true
        user.port = 18080
        user.webchat.chatHistoryMaxChars = 4321
        user.telegram.enabled = true
        user.telegram.botToken = "telegram-token"

        let cfg = buildGatewayConfigFromUserSettings(user)
        @Expect(cfg.enabled, true)
        @Expect(cfg.port, 18080)
        @Expect(cfg.webchat.chatHistoryMaxChars, 4321)
        @Expect(cfg.policyByChannel.contains("feishu"), true)
        @Expect(cfg.policyByChannel.contains("qq"), true)
        @Expect(cfg.telegram.enabled, true)
        @Expect(cfg.telegram.botToken, "telegram-token")
    }

    @TestCase
    public func metis3CkbAdminDefaultsRemainDisabled(): Unit {
        // METIS3-UT-001
        let cfg = buildGatewayConfigFromUserSettings(GatewayUserSettings())
        @Expect(cfg.ckbAdmin.enabled, false)
        @Expect(cfg.ckbAdmin.endpoint, "")
        @Expect(cfg.ckbAdmin.adminTokenFile, "")
        @Expect(cfg.ckbAdmin.timeoutMs, 5000)
        @Expect(cfg.ckbAdmin.telegramEnabled, true)
        @Expect(cfg.ckbAdmin.feishuEnabled, true)
        @Expect(cfg.ckbAdmin.allowedTasks.contains("community_repo_discovery_30d"), true)
        @Expect(cfg.ckbAdmin.allowedTasks.contains("active_repo_fetch_on_merge"), false)
    }

    @TestCase
    public func telegramTypedParityConfigMapsIntoRuntimeConfig(): Unit {
        var user = GatewayUserSettings()
        user.telegram.enabled = true
        user.telegram.defaultAccount = "work"
        user.telegram.inlineButtons.scope = "group"
        user.telegram.inlineButtons.allowlist = ["tg:group:-1001"]
        user.telegram.execApprovals.enabled = "true"
        user.telegram.execApprovals.approvers = ["8734062810"]
        user.telegram.execApprovals.agentFilter = ["reviewer"]
        user.telegram.execApprovals.sessionFilter = ["telegram:group"]
        user.telegram.execApprovals.target = "both"
        user.telegram.errorPolicy.policy = "once"
        user.telegram.errorPolicy.cooldownMs = 12345
        user.telegram.errorPolicy.silentErrorReplies = true
        user.telegram.autoTopicLabel.enabled = true
        user.telegram.autoTopicLabel.strategy = "model"
        user.telegram.autoTopicLabel.prompt = "short label"

        let (_, _, telegram) = mergeGatewayUserSettings(user)
        @Expect(telegram.accountId, "work")
        @Expect(telegram.defaultAccount, "work")
        @Expect(telegram.inlineButtons.scope, "group")
        @Expect(telegram.inlineButtons.allowlist[0], "tg:group:-1001")
        @Expect(telegram.execApprovals.enabled, "true")
        @Expect(telegram.execApprovals.approvers[0], "8734062810")
        @Expect(telegram.execApprovals.agentFilter[0], "reviewer")
        @Expect(telegram.execApprovals.sessionFilter[0], "telegram:group")
        @Expect(telegram.execApprovals.target, "both")
        @Expect(telegram.errorPolicy.policy, "once")
        @Expect(telegram.errorPolicy.cooldownMs, 12345)
        @Expect(telegram.errorPolicy.silentErrorReplies, true)
        @Expect(telegram.autoTopicLabel.enabled, true)
        @Expect(telegram.autoTopicLabel.strategy, "model")
        @Expect(telegram.autoTopicLabel.prompt, "short label")
    }

    @TestCase
    public func feishuTypedParityConfigMapsIntoRuntimeConfig(): Unit {
        var user = GatewayUserSettings()
        user.feishu.enabled = true
        user.feishu.defaultAccount = "tenant-a"
        user.feishu.appId = "legacy-app"
        user.feishu.appSecret = "legacy-secret"
        user.feishu.threadSession = true
        user.feishu.groupPolicy = "allowlist"
        user.feishu.groupAllowFrom = ["oc_team"]
        user.feishu.requireMention = true
        user.feishu.allowBots = false
        user.feishu.media.downloadEnabled = true
        user.feishu.media.mediaMaxBytes = 1024
        user.feishu.media.downloadRoot = "/tmp/metis-feishu-test-media"
        user.feishu.media.outboundAllowLocalPath = true
        user.feishu.media.outboundLocalRoots = ["/tmp/metis-feishu-outbound"]
        user.feishu.media.trustedLocalFileRoots = ["/tmp/metis-feishu-trusted"]
        let groups = JsonObject()
        let groupRule = JsonObject()
        groupRule.put("requireMention", true.toJsonValue())
        groups.put("oc_team", groupRule)
        user.feishu.groups = Some(groups)
        let accounts = JsonObject()
        let tenantAccount = JsonObject()
        tenantAccount.put("appId", JsonString("tenant-app"))
        tenantAccount.put("appSecret", JsonString("tenant-secret"))
        tenantAccount.put("enabled", true.toJsonValue())
        accounts.put("tenant-a", tenantAccount)
        user.feishu.accounts = Some(accounts)

        let (feishu, _, _) = mergeGatewayUserSettings(user)
        @Expect(feishu.accountId, "tenant-a")
        @Expect(feishu.defaultAccount, "tenant-a")
        @Expect(feishu.appId, "legacy-app")
        @Expect(feishu.appSecret, "legacy-secret")
        @Expect(feishu.threadSession, true)
        @Expect(feishu.groupPolicy, "allowlist")
        @Expect(feishu.groupAllowFrom[0], "oc_team")
        @Expect(feishu.requireMention, true)
        @Expect(feishu.allowBots, false)
        @Expect(feishu.groups.isSome(), true)
        @Expect(feishu.accounts.isSome(), true)
        @Expect(feishu.media.downloadEnabled, true)
        @Expect(feishu.media.mediaMaxBytes, 1024)
        @Expect(feishu.media.downloadRoot, "/tmp/metis-feishu-test-media")
        @Expect(feishu.media.outboundAllowLocalPath, true)
        @Expect(feishu.media.outboundLocalRoots[0], "/tmp/metis-feishu-outbound")
        @Expect(feishu.media.trustedLocalFileRoots[0], "/tmp/metis-feishu-trusted")
    }

    @TestCase
    public func feishuMediaDownloadDefaultsToEnabledWhenUserConfigOmitsMedia(): Unit {
        var user = GatewayUserSettings()
        user.feishu.enabled = true

        let (feishu, _, _) = mergeGatewayUserSettings(user)

        @Expect(feishu.media.downloadEnabled, true)
        @Expect(feishu.media.mediaMaxBytes, 20 * 1024 * 1024)
        @Expect(feishu.media.downloadRoot, "")
        @Expect(feishu.media.outboundAllowLocalPath, true)
        @Expect(feishu.media.outboundLocalRoots.isEmpty(), true)
        @Expect(feishu.media.trustedLocalFileRoots.isEmpty(), true)
    }

    @TestCase
    public func feishuTransportModeDefaultsToSidecarAndNormalizesExplicitNativeLegacy(): Unit {
        var user = GatewayUserSettings()

        let (defaultFeishu, _, _) = mergeGatewayUserSettings(user)
        @Expect(defaultFeishu.receiveMode, "long_connect")
        @Expect(defaultFeishu.transportMode, "sidecar")

        user.feishu.transportMode = "native-legacy"
        let (nativeFeishu, _, _) = mergeGatewayUserSettings(user)
        @Expect(nativeFeishu.transportMode, "native-legacy")

        user.feishu.transportMode = "native"
        let (normalizedFeishu, _, _) = mergeGatewayUserSettings(user)
        @Expect(normalizedFeishu.transportMode, "sidecar")

        user.feishu.receiveMode = "webhook"
        let (webhookFeishu, _, _) = mergeGatewayUserSettings(user)
        @Expect(webhookFeishu.receiveMode, "webhook")
        @Expect(webhookFeishu.transportMode, "sidecar")
    }

    @TestCase
    public func feishuAckDefaultsRemainDisabled(): Unit {
        var user = GatewayUserSettings()

        let (feishu, _, _) = mergeGatewayUserSettings(user)

        @Expect(feishu.ack.enabled, false)
        @Expect(feishu.ack.reaction, "Typing")
        @Expect(feishu.ack.removeAfterReply, true)
        @Expect(feishu.ack.scope, "handled")
        @Expect(feishu.media.downloadEnabled, true)
    }

    @TestCase
    public func feishuAckExplicitConfigBuildsRuntimeConfig(): Unit {
        var user = GatewayUserSettings()
        user.feishu.ack.enabled = true
        user.feishu.ack.reaction = "敲键盘"
        user.feishu.ack.removeAfterReply = false
        user.feishu.ack.scope = "handled"

        let (feishu, _, _) = mergeGatewayUserSettings(user)

        @Expect(feishu.ack.enabled, true)
        @Expect(feishu.ack.reaction, "敲键盘")
        @Expect(feishu.ack.removeAfterReply, false)
        @Expect(feishu.ack.scope, "handled")
    }

    @TestCase
    public func feishuAckBlankValuesFallback(): Unit {
        var user = GatewayUserSettings()
        user.feishu.ack.enabled = true
        user.feishu.ack.reaction = "   "
        user.feishu.ack.scope = "   "

        let (feishu, _, _) = mergeGatewayUserSettings(user)

        @Expect(feishu.ack.enabled, true)
        @Expect(feishu.ack.reaction, "Typing")
        @Expect(feishu.ack.scope, "handled")
    }

    @TestCase
    public func qqPerAccountConfigMapsIntoRuntimeConfigWithoutDroppingTopLevelCompatibility(): Unit {
        var user = GatewayUserSettings()
        user.qq.enabled = true
        user.qq.defaultAccount = "work"
        user.qq.appId = "legacy-qq-app"
        user.qq.appSecret = "legacy-qq-secret"
        let accounts = JsonObject()
        let work = JsonObject()
        work.put("appId", JsonString("work-qq-app"))
        work.put("appSecret", JsonString("work-qq-secret"))
        accounts.put("work", work)
        user.qq.accounts = Some(accounts)

        let (_, qq, _) = mergeGatewayUserSettings(user)

        @Expect(qq.accountId, "work")
        @Expect(qq.defaultAccount, "work")
        @Expect(qq.appId, "legacy-qq-app")
        @Expect(qq.appSecret, "legacy-qq-secret")
        @Expect(qq.accounts.isSome(), true)
    }

    @TestCase
    public func pluginConfigPresenceUsesSharedGatewayConfigHelper(): Unit {
        var user = GatewayUserSettings()
        let root = JsonObject(HashMap<String, JsonValue>())
        let pluginCfg = JsonObject()
        pluginCfg.put("token", JsonString("demo-token"))
        root.put("dingtalk", pluginCfg)
        user.channelsExtra = Some(root)

        @Expect(gatewayPluginConfigPresent(user.channelsExtra, "dingtalk"), true)
        @Expect(gatewayPluginConfigPresent(user.channelsExtra, "slack"), false)
    }
}
