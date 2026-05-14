package metis.gateway.channels.feishu

import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

public class FeishuInteractiveCard {
    public let title: String
    public let text: String
    public let toolUseText: String
    public let footerText: String
    public let actionId: String

    public init(title!: String = "", text!: String = "", toolUseText!: String = "", footerText!: String = "", actionId!: String = "") {
        this.title = title.trimAscii()
        this.text = text.trimAscii()
        this.toolUseText = toolUseText.trimAscii()
        this.footerText = footerText.trimAscii()
        this.actionId = actionId.trimAscii()
    }

    public func fallbackText(): String {
        let parts = ArrayList<String>()
        if (!this.text.isEmpty()) {
            parts.add(this.text)
        }
        if (!this.toolUseText.isEmpty()) {
            parts.add(this.toolUseText)
        }
        if (!this.footerText.isEmpty()) {
            parts.add(this.footerText)
        }
        let body = String.join(parts.toArray(), delimiter: "\n\n")
        if (this.title.isEmpty()) {
            return body
        }
        if (body.isEmpty()) {
            return this.title
        }
        "${this.title}\n${body}"
    }

    public func toJson(): JsonObject {
        let root = JsonObject()
        let header = JsonObject()
        let titleObj = JsonObject()
        titleObj.put("tag", JsonString("plain_text"))
        titleObj.put("content", JsonString(this.title))
        header.put("title", titleObj)
        root.put("header", header)
        let elements = JsonArray([])
        let textNode = JsonObject()
        textNode.put("tag", JsonString("div"))
        let textObj = JsonObject()
        textObj.put("tag", JsonString("lark_md"))
        textObj.put("content", JsonString(this.text))
        textNode.put("text", textObj)
        elements.add(textNode)
        if (!this.toolUseText.isEmpty()) {
            let toolNode = JsonObject()
            toolNode.put("tag", JsonString("div"))
            let toolText = JsonObject()
            toolText.put("tag", JsonString("lark_md"))
            toolText.put("content", JsonString(this.toolUseText))
            toolNode.put("text", toolText)
            elements.add(toolNode)
        }
        if (!this.footerText.isEmpty()) {
            let footerNode = JsonObject()
            footerNode.put("tag", JsonString("div"))
            let footer = JsonObject()
            footer.put("tag", JsonString("lark_md"))
            footer.put("content", JsonString(this.footerText))
            footerNode.put("text", footer)
            elements.add(footerNode)
        }
        if (!this.actionId.isEmpty()) {
            let actionNode = JsonObject()
            actionNode.put("tag", JsonString("action"))
            let actions = JsonArray([])
            let button = JsonObject()
            button.put("tag", JsonString("button"))
            let buttonText = JsonObject()
            buttonText.put("tag", JsonString("plain_text"))
            buttonText.put("content", JsonString("Open"))
            button.put("text", buttonText)
            let value = JsonObject()
            value.put("action", JsonString(this.actionId))
            button.put("value", value)
            actions.add(button)
            actionNode.put("actions", actions)
            elements.add(actionNode)
        }
        root.put("elements", elements)
        root
    }
}

public class FeishuReplyFooterMetrics {
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheRead: Int64
    public let cacheWrite: Int64
    public let contextTokens: Int64
    public let model: String

    public init(
        inputTokens!: Int64 = 0,
        outputTokens!: Int64 = 0,
        cacheRead!: Int64 = 0,
        cacheWrite!: Int64 = 0,
        contextTokens!: Int64 = 0,
        model!: String = ""
    ) {
        this.inputTokens = inputTokens
        this.outputTokens = outputTokens
        this.cacheRead = cacheRead
        this.cacheWrite = cacheWrite
        this.contextTokens = contextTokens
        this.model = model.trimAscii()
    }

    public func toFooterText(): String {
        let parts = ArrayList<String>()
        if (this.inputTokens > 0) {
            parts.add("Tokens in: ${this.inputTokens}")
        }
        if (this.outputTokens > 0) {
            parts.add("Tokens out: ${this.outputTokens}")
        }
        if (this.cacheRead > 0) {
            parts.add("Cache read: ${this.cacheRead}")
        }
        if (this.cacheWrite > 0) {
            parts.add("Cache write: ${this.cacheWrite}")
        }
        if (this.contextTokens > 0) {
            parts.add("Context: ${this.contextTokens}")
        }
        if (!this.model.isEmpty()) {
            parts.add("Model: ${this.model}")
        }
        if (parts.isEmpty()) {
            return ""
        }
        "Metrics\n${String.join(parts.toArray(), delimiter: " | ")}"
    }
}

public class FeishuReplyCardDraft {
    private let title: String
    private let showToolUse: Bool
    private let textParts = ArrayList<String>()
    private let toolUseParts = ArrayList<String>()

    public init(title!: String = "Metis", showToolUse!: Bool = false) {
        this.title = title.trimAscii()
        this.showToolUse = showToolUse
    }

    public func appendText(text: String): Unit {
        let normalized = text.trimAscii()
        if (!normalized.isEmpty()) {
            this.textParts.add(normalized)
        }
    }

    public func appendToolUse(name: String, payload: String): Unit {
        if (!this.showToolUse) {
            return
        }
        let toolName = name.trimAscii()
        if (toolName.isEmpty()) {
            return
        }
        let preview = payload.trimAscii()
        if (preview.isEmpty()) {
            this.toolUseParts.add("- ${toolName}")
        } else {
            this.toolUseParts.add("- ${toolName}: ${preview}")
        }
    }

    public func toCard(): FeishuInteractiveCard {
        let text = String.join(this.textParts.toArray(), delimiter: "\n")
        let toolText = if (this.toolUseParts.isEmpty()) {
            ""
        } else {
            "Tool use\n${String.join(this.toolUseParts.toArray(), delimiter: "\n")}"
        }
        FeishuInteractiveCard(title: this.title, text: text, toolUseText: toolText)
    }
}

public class FeishuStreamingCardController {
    private let client: FeishuApiClient
    private let accountId: String
    private let rawPeerId: String
    private let receiveId: String
    private let receiveIdType: String
    private let replyToMessageId: Option<String>
    private let replyInThread: Bool
    private let showToolUse: Bool
    private var cardMessageId: String = ""
    private var currentText: String = ""
    private var toolUseText: String = ""
    private var aborted: Bool = false

    public init(
        client: FeishuApiClient,
        accountId!: String,
        rawPeerId!: String,
        receiveId!: String,
        receiveIdType!: String,
        replyToMessageId!: Option<String> = None<String>,
        replyInThread!: Bool = false,
        showToolUse!: Bool = false
    ) {
        this.client = client
        this.accountId = accountId.trimAscii()
        this.rawPeerId = rawPeerId.trimAscii()
        this.receiveId = receiveId.trimAscii()
        this.receiveIdType = receiveIdType.trimAscii()
        this.replyToMessageId = replyToMessageId
        this.replyInThread = replyInThread
        this.showToolUse = showToolUse
    }

    public func create(text: String): String {
        if (this.aborted) {
            return ""
        }
        this.currentText = text.trimAscii()
        let result = this.client.sendInteractiveCard(
            this.accountId,
            this.rawPeerId,
            this.receiveId,
            this.receiveIdType,
            this.buildCard(None<FeishuReplyFooterMetrics>),
            this.replyToMessageId,
            this.replyInThread
        )
        if (result.ok && !result.messageId.isEmpty()) {
            this.cardMessageId = result.messageId
            return result.messageId
        }
        let fallback = this.client.sendTextMessage(
            this.accountId,
            this.rawPeerId,
            this.receiveId,
            this.receiveIdType,
            this.buildCard(None<FeishuReplyFooterMetrics>).fallbackText(),
            this.replyToMessageId,
            this.replyInThread
        )
        if (fallback.ok) {
            return fallback.messageId
        }
        ""
    }

    public func patchChunk(text: String): Bool {
        if (this.aborted || this.cardMessageId.isEmpty()) {
            return false
        }
        this.currentText = text.trimAscii()
        this.patchCurrent(None<FeishuReplyFooterMetrics>)
    }

    public func updateToolPayload(name: String, payload: String): Bool {
        if (this.aborted || this.cardMessageId.isEmpty() || !this.showToolUse) {
            return false
        }
        let toolName = name.trimAscii()
        if (toolName.isEmpty()) {
            return false
        }
        let preview = payload.trimAscii()
        this.toolUseText = if (preview.isEmpty()) {
            "Tool use\n- ${toolName}"
        } else {
            "Tool use\n- ${toolName}: ${preview}"
        }
        this.patchCurrent(None<FeishuReplyFooterMetrics>)
    }

    public func finalize(text: String, footerMetrics!: Option<FeishuReplyFooterMetrics> = None<FeishuReplyFooterMetrics>): Bool {
        if (this.aborted || this.cardMessageId.isEmpty()) {
            return false
        }
        this.currentText = text.trimAscii()
        this.patchCurrent(footerMetrics)
    }

    public func abort(reason: String): Bool {
        if (this.cardMessageId.isEmpty()) {
            this.aborted = true
            return false
        }
        this.aborted = true
        let message = if (reason.trimAscii().isEmpty()) { "aborted" } else { reason.trimAscii() }
        let result = this.client.patchInteractiveCard(
            this.accountId,
            this.cardMessageId,
            FeishuInteractiveCard(title: "Metis", text: "Aborted: ${message}")
        )
        result.ok
    }

    private func patchCurrent(footerMetrics: Option<FeishuReplyFooterMetrics>): Bool {
        let result = this.client.patchInteractiveCard(this.accountId, this.cardMessageId, this.buildCard(footerMetrics))
        result.ok
    }

    private func buildCard(footerMetrics: Option<FeishuReplyFooterMetrics>): FeishuInteractiveCard {
        let footer = match (footerMetrics) {
            case Some(metrics) => metrics.toFooterText()
            case None => ""
        }
        FeishuInteractiveCard(title: "Metis", text: this.currentText, toolUseText: this.toolUseText, footerText: footer)
    }
}

public class FeishuApiSendResult {
    public let ok: Bool
    public let status: String
    public let messageId: String
    public let error: String

    public init(ok!: Bool = false, status!: String = "not_configured", messageId!: String = "", error!: String = "") {
        this.ok = ok
        this.status = if (status.trimAscii().isEmpty()) { if (ok) { "ok" } else { "error" } } else { status.trimAscii() }
        this.messageId = messageId.trimAscii()
        this.error = error.trimAscii()
    }
}
