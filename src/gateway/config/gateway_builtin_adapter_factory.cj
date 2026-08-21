package metis.gateway.config

import metis.gateway.channels.builtin.GenericBuiltinChannelAdapter
import metis.gateway.channels.feishu.{
    FeishuAdapter,
    FeishuApiClient,
    FeishuLongConnectTransport,
    FeishuNativeLongConnectTransport,
    FeishuNoopApiClient,
    FeishuSidecarApiClient,
    FeishuSidecarRequestAccount,
    FeishuSidecarSupervisorRequestRunner,
    FeishuSidecarStdioRunner,
    FeishuSidecarSupervisorRegistry,
    FeishuSidecarSupervisorTransport,
    FeishuSidecarTransport,
    FeishuSidecarTransportOptions,
    FeishuWebhookLongConnectTransport,
    gatewayFeishuResolveAccount
}
import metis.gateway.channels.qq.QQAdapter
import metis.gateway.channels.telegram.{TelegramAdapter, gatewayTelegramConfigForAccount}
import metis.gateway.core.{ChannelAdapter, gatewayCanonicalChannelAccountId}
import metis.gateway.model.{FeishuConfig, QQConfig, TelegramConfig}
import metis.core.config.GatewayUserSettings

import std.collection.ArrayList

public class GatewayPreparedAdapterRegistration {
    public let adapter: ChannelAdapter
    public let profile: GatewayAdapterRegistrationProfile

    public init(adapter: ChannelAdapter, profile: GatewayAdapterRegistrationProfile) {
        this.adapter = adapter
        this.profile = profile
    }
}

private func gatewayProfileRuntimeAccountId(profile: GatewayAdapterRegistrationProfile): String {
    gatewayCanonicalChannelAccountId(profile.channelId, profile.accountId)
}

private func telegramConfigForAccount(config: TelegramConfig, accountId: String): TelegramConfig {
    gatewayTelegramConfigForAccount(config, accountId)
}

private func qqConfigForAccount(config: QQConfig, accountId: String): QQConfig {
    QQConfig(
        accountId: accountId,
        defaultAccount: config.defaultAccount,
        enabled: config.enabled,
        streaming: config.streaming,
        blockStreaming: config.blockStreaming,
        mode: config.mode,
        webhookHost: config.webhookHost,
        webhookPort: config.webhookPort,
        webhookPath: config.webhookPath,
        accessToken: config.accessToken,
        requireAuthorizationHeader: config.requireAuthorizationHeader,
        onebotApiBaseUrl: config.onebotApiBaseUrl,
        sendApiMode: config.sendApiMode,
        botQQ: config.botQQ,
        dedupWindowSize: config.dedupWindowSize,
        appId: config.appId,
        appSecret: config.appSecret,
        accounts: config.accounts,
        officialBotToken: config.officialBotToken,
        officialTokenUrl: config.officialTokenUrl,
        officialGatewayUrl: config.officialGatewayUrl,
        officialWebsocketUrl: config.officialWebsocketUrl,
        officialAuthScheme: config.officialAuthScheme,
        officialIntents: config.officialIntents,
        officialSendPrivateUrlTemplate: config.officialSendPrivateUrlTemplate,
        officialSendGroupUrlTemplate: config.officialSendGroupUrlTemplate,
        policy: config.policy
    )
}

private func gatewayFeishuLongConnectTransportForConfig(
    config: FeishuConfig,
    supervisorRegistry!: Option<FeishuSidecarSupervisorRegistry> = None<FeishuSidecarSupervisorRegistry>
): FeishuLongConnectTransport {
    if (config.receiveMode == "webhook") {
        return FeishuWebhookLongConnectTransport()
    }
    if (config.transportMode == "sidecar") {
        if (let Some(registry) <- supervisorRegistry) {
            return FeishuSidecarSupervisorTransport(registry: registry)
        }
        return FeishuSidecarTransport(
            runner: FeishuSidecarStdioRunner(),
            options: FeishuSidecarTransportOptions(startBackgroundReader: true)
        )
    }
    FeishuNativeLongConnectTransport()
}

private func gatewayFeishuApiClientForConfig(
    config: FeishuConfig,
    supervisorRegistry: FeishuSidecarSupervisorRegistry
): FeishuApiClient {
    if (config.receiveMode == "long_connect" && config.transportMode == "sidecar") {
        return FeishuSidecarApiClient(
            runner: FeishuSidecarSupervisorRequestRunner(
                account: FeishuSidecarRequestAccount(
                    accountId: config.accountId,
                    appId: config.appId,
                    appSecret: config.appSecret,
                    domain: config.domain,
                    verificationToken: config.verificationToken,
                    encryptKey: config.encryptKey
                ),
                registry: supervisorRegistry
            )
        )
    }
    FeishuNoopApiClient()
}

public func gatewayFeishuAdapterForConfig(
    config: FeishuConfig,
    accountId: String,
    supervisorRegistry!: Option<FeishuSidecarSupervisorRegistry> = None<FeishuSidecarSupervisorRegistry>
): FeishuAdapter {
    let resolved = gatewayFeishuResolveAccount(config, accountId)
    let effectiveRegistry = match (supervisorRegistry) {
        case Some(registry) => registry
        case None => FeishuSidecarSupervisorRegistry(
            runner: FeishuSidecarStdioRunner(),
            options: FeishuSidecarTransportOptions(startBackgroundReader: true)
        )
    }
    FeishuAdapter(
        config: config,
        accountId: resolved.accountId,
        apiClient: gatewayFeishuApiClientForConfig(resolved.config, effectiveRegistry),
        longConnectTransport: gatewayFeishuLongConnectTransportForConfig(resolved.config, supervisorRegistry: Some(effectiveRegistry))
    )
}

private func gatewayAdapterForProfile(
    user: GatewayUserSettings,
    profile: GatewayAdapterRegistrationProfile,
    feishuSupervisorRegistry!: Option<FeishuSidecarSupervisorRegistry> = None<FeishuSidecarSupervisorRegistry>
): ChannelAdapter {
    let cfg = buildGatewayConfigFromUserSettings(user)
    let accountId = gatewayProfileRuntimeAccountId(profile)
    if (profile.channelId == "feishu") {
        return gatewayFeishuAdapterForConfig(cfg.feishu, accountId, supervisorRegistry: feishuSupervisorRegistry)
    }
    if (profile.channelId == "qq") {
        return QQAdapter(config: qqConfigForAccount(cfg.qq, accountId))
    }
    if (profile.channelId == "telegram") {
        return TelegramAdapter(
            config: telegramConfigForAccount(cfg.telegram, accountId),
            registerNativeCommandsOnStart: true
        )
    }
    GenericBuiltinChannelAdapter(
        profile.channelId,
        label: profile.label,
        configured: profile.configured
    )
}

public func gatewayPreparedBuiltinAdapterRegistrations(
    user: GatewayUserSettings,
    healthMonitorEnabled: Bool
): Array<GatewayPreparedAdapterRegistration> {
    let rows = ArrayList<GatewayPreparedAdapterRegistration>()
    let feishuSupervisorRegistry = FeishuSidecarSupervisorRegistry(
        runner: FeishuSidecarStdioRunner(),
        options: FeishuSidecarTransportOptions(startBackgroundReader: true)
    )
    for (profile in gatewayBuiltinAdapterRegistrationProfiles(user, healthMonitorEnabled)) {
        if (!profile.enabled || !profile.configured) {
            continue
        }
        let supervisor = if (profile.channelId == "feishu") {
            Some(feishuSupervisorRegistry)
        } else {
            None<FeishuSidecarSupervisorRegistry>
        }
        rows.add(GatewayPreparedAdapterRegistration(
            gatewayAdapterForProfile(user, profile, feishuSupervisorRegistry: supervisor),
            profile
        ))
    }
    rows.toArray()
}
