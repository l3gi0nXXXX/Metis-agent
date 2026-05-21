package metis.gateway.channels.feishu

import stdx.encoding.json.JsonObject

private func feishuSidecarUnavailableMessage(): String {
    "Feishu openclaw-sidecar transport is selected, but the sidecar runtime is not available in this build"
}

public class FeishuSidecarTransport <: FeishuLongConnectTransport {
    public init() {}

    public func start(_spec: FeishuLongConnectStartSpec, _eventHandler: (JsonObject) -> Unit): FeishuLongConnectStartResult {
        FeishuLongConnectStartResult(status: "sidecar_not_available", error: feishuSidecarUnavailableMessage())
    }

    public func stop(): Unit {}
}

public class FeishuWebhookLongConnectTransport <: FeishuLongConnectTransport {
    public init() {}

    public func start(_spec: FeishuLongConnectStartSpec, _eventHandler: (JsonObject) -> Unit): FeishuLongConnectStartResult {
        FeishuLongConnectStartResult(status: "webhook_receive_mode", error: "Feishu receiveMode=webhook does not start long-connect transport")
    }

    public func stop(): Unit {}
}

public class FeishuSidecarApiClient <: FeishuApiClient {
    public init() {}

    private func sendUnavailable(): FeishuApiSendResult {
        FeishuApiSendResult(status: "sidecar_not_available", error: feishuSidecarUnavailableMessage())
    }

    public func isThreadCapableGroup(_chatId: String): Bool {
        false
    }

    public func fetchMessage(_accountId: String, _messageId: String): FeishuMessageFetchResult {
        FeishuMessageFetchResult(status: "sidecar_not_available", error: feishuSidecarUnavailableMessage())
    }

    public func listMergeForwardMessages(_accountId: String, _messageId: String): FeishuMergeForwardFetchResult {
        FeishuMergeForwardFetchResult(status: "sidecar_not_available", error: feishuSidecarUnavailableMessage())
    }

    public func fetchMessageResource(
        _accountId: String,
        _messageId: String,
        _fileKey: String,
        _resourceType: String
    ): FeishuResourceDownloadResult {
        FeishuResourceDownloadResult(status: "sidecar_not_available", error: feishuSidecarUnavailableMessage())
    }

    public func sendTextMessage(
        _accountId: String,
        _rawPeerId: String,
        _receiveId: String,
        _receiveIdType: String,
        _text: String,
        _replyToMessageId: Option<String>,
        _replyInThread: Bool
    ): FeishuApiSendResult {
        this.sendUnavailable()
    }

    public func sendInteractiveCard(
        _accountId: String,
        _rawPeerId: String,
        _receiveId: String,
        _receiveIdType: String,
        _card: FeishuInteractiveCard,
        _replyToMessageId: Option<String>,
        _replyInThread: Bool
    ): FeishuApiSendResult {
        this.sendUnavailable()
    }

    public func patchInteractiveCard(_accountId: String, _messageId: String, _card: FeishuInteractiveCard): FeishuApiSendResult {
        this.sendUnavailable()
    }

    public func uploadMedia(
        _accountId: String,
        _mediaType: String,
        _localPath: String,
        _bytes: Array<Byte>,
        _mimeType: String,
        _fileName: String
    ): FeishuApiSendResult {
        this.sendUnavailable()
    }

    public func sendMediaMessage(
        _accountId: String,
        _rawPeerId: String,
        _receiveId: String,
        _receiveIdType: String,
        _messageType: String,
        _mediaKey: String,
        _caption: String,
        _replyToMessageId: Option<String>,
        _replyInThread: Bool
    ): FeishuApiSendResult {
        this.sendUnavailable()
    }

    public func addMessageReaction(_accountId: String, _messageId: String, _reactionType: String): FeishuApiSendResult {
        this.sendUnavailable()
    }

    public func removeMessageReaction(_accountId: String, _messageId: String, _reactionType: String): FeishuApiSendResult {
        this.sendUnavailable()
    }

    public func listMessageReactions(_accountId: String, _messageId: String): Array<String> {
        []
    }

    public func deleteMessage(_accountId: String, _messageId: String): FeishuApiSendResult {
        this.sendUnavailable()
    }
}
