package metis.gateway.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*

import metis.core.{gatewayCurrentToolRuntimeContext, gatewayMarkCurrentToolRuntimeVisibleReplyDelivered, gatewayMessagePayloadPreview, gatewaySpeechResolveDeliveryPrefs, gatewaySpeechResolveTtsConfig, gatewaySpeechTtsSynthesize, parseGatewayPollParts, renderGatewayAudioText, renderGatewayChatActionText, renderGatewayDeleteText, renderGatewayDocumentText, renderGatewayEditText, renderGatewayPhotoText, renderGatewayPinText, renderGatewayPollTextAdvanced, renderGatewayReactionText, renderGatewayTopicCreateText, renderGatewayTopicEditText, renderGatewayUnpinText, renderGatewayVideoNoteText, renderGatewayVideoText, renderGatewayVoiceText}
import metis.core.config.{CliConfig, CliSettingManager, MetisPaths}
import metis.io.PrintUtils

import std.fs.{Directory, File, Path, exists}
import std.process.executeWithOutput

import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

private var gatewayMessageToolCallRunnerForTest: Option<(String, JsonObject) -> JsonObject> = None<(String, JsonObject) -> JsonObject>

public func debugSetGatewayMessageToolCallRunnerForTest(runner: Option<(String, JsonObject) -> JsonObject>): Unit {
    gatewayMessageToolCallRunnerForTest = runner
}

private func gatewayMessageToolIsInternalDirective(tag: String): Bool {
    let normalized = tag.trimAscii().toAsciiLower().replace(" ", "")
    normalized == "reply_to_current" ||
        normalized.startsWith("reply_to:") ||
        normalized == "tts" ||
        normalized == "tts:text" ||
        normalized == "/tts" ||
        normalized == "/tts:text" ||
        normalized == "audio_as_voice"
}

private func gatewayMessageToolStripInternalDirectives(raw: String): String {
    var cursor: Int64 = 0
    let out = StringBuilder()
    while (cursor < raw.size) {
        match (raw.indexOf("[[", cursor)) {
            case Some(start) =>
                out.append(raw[cursor..start])
                match (raw.indexOf("]]", start + 2)) {
                    case Some(end) =>
                        let tag = raw[start + 2..end]
                        if (!gatewayMessageToolIsInternalDirective(tag)) {
                            out.append(raw[start..end + 2])
                        }
                        cursor = end + 2
                    case None =>
                        out.append(raw[start..])
                        cursor = raw.size
                }
            case None =>
                out.append(raw[cursor..])
                cursor = raw.size
        }
    }
    out.toString().trimAscii()
}

@toolset
public class GatewayMessageToolset {
    private func gatewayMessageBinaryCommand(): (String, Option<Path>) {
        match (MetisPaths.projectRoot()) {
            case Some(root) =>
                let devBinary = root.join("target").join("release").join("bin").join("metis")
                if (exists(devBinary)) {
                    return (devBinary.toString(), Some(root))
                }
                return ("metis", Some(root))
            case None => ("metis", None<Path>)
        }
    }

    private func invokeGatewaySend(payload: JsonObject): JsonObject {
        match (gatewayMessageToolCallRunnerForTest) {
            case Some(runner) => return runner("channels.send", payload)
            case None => ()
        }
        let (command, workDir) = this.gatewayMessageBinaryCommand()
        let args = ["gateway", "call", "channels.send", payload.toJsonString()]
        let (exitCode, stdoutBytes, stderrBytes) = executeWithOutput(command, args, workingDirectory: workDir)
        let stdout = try { String.fromUtf8(stdoutBytes).trimAscii() } catch (_: Exception) { "" }
        let stderr = try { String.fromUtf8(stderrBytes).trimAscii() } catch (_: Exception) { "" }
        if (!stdout.isEmpty()) {
            try {
                let obj = JsonValue.fromStr(stdout).asObject()
                obj.put("exitCode", exitCode.toJsonValue())
                if (!stderr.isEmpty()) {
                    obj.put("stderr", JsonString(stderr))
                }
                return obj
            } catch (_: Exception) {
                ()
            }
        }
        let out = JsonObject()
        out.put("ok", JsonBool(exitCode == 0))
        out.put("exitCode", exitCode.toJsonValue())
        out.put("stdout", JsonString(stdout))
        out.put("stderr", JsonString(stderr))
        return out
    }

    private func jsonBool(obj: JsonObject, key: String, fallback: Bool): Bool {
        match (obj.get(key)) {
            case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { fallback }
            case None => fallback
        }
    }

    private func telegramTtsDir(): Path {
        let dir = CliConfig.dotDir.join("gateway-telegram").join("tts")
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        dir
    }

    private func telegramReadTtsState(): JsonObject {
        let path = this.telegramTtsDir().join("state.json")
        if (!exists(path)) {
            let out = JsonObject()
            out.put("enabled", JsonBool(true))
            out.put("provider", JsonString(""))
            out.put("limit", JsonInt(4000))
            return out
        }
        try {
            JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
        } catch (_: Exception) {
            JsonObject()
        }
    }

    private func telegramSpeakableText(text: String): String {
        var out = text.trimAscii()
        if (out.startsWith("[[")) {
            var end: Int64 = -1
            for (i in 0..(out.size - 1)) {
                if (out[i] == 93u8 && out[i + 1] == 93u8) {
                    end = i + 2
                    break
                }
            }
            if (end > 0 && end <= out.size) {
                out = out[end..].trimAscii()
            }
        }
        out
    }

    private func telegramVoiceInputContext(): Bool {
        match (gatewayCurrentToolRuntimeContext()) {
            case Some(context) =>
                if (context.channelName != "telegram") {
                    return false
                }
                let prompt = context.prompt
                prompt.startsWith("[voice]") ||
                    prompt.startsWith("[audio]") ||
                    prompt.contains("\nmediaKind=voice") ||
                    prompt.contains("\nmediaKind=audio") ||
                    prompt.contains("\nmimeType=audio/")
            case None => false
        }
    }

    private func maybeSynthesizeTelegramAutoVoiceText(channel: String, payloadKind: String, text: String): String {
        if (channel.trimAscii().toAsciiLower() != "telegram") {
            return text
        }
        if (!(payloadKind == "text" || payloadKind == "threaded-text")) {
            return text
        }
        if (text.trimAscii().startsWith("[voice]") || text.trimAscii().startsWith("[audio]")) {
            return text
        }
        let voiceInput = this.telegramVoiceInputContext()
        if (!voiceInput) {
            return text
        }
        let user = CliSettingManager.readGatewaySettings()
        let prefs = gatewaySpeechResolveDeliveryPrefs(user, channel: "telegram")
        if (!this.jsonBool(prefs, "audioAsVoice", false)) {
            return text
        }
        if (!this.jsonBool(prefs, "autoReplyToVoice", false)) {
            return text
        }
        let speakable = this.telegramSpeakableText(text)
        if (speakable.isEmpty()) {
            return text
        }
        let result = gatewaySpeechTtsSynthesize(
            gatewaySpeechResolveTtsConfig(user, channel: "telegram"),
            prefs,
            this.telegramReadTtsState(),
            speakable,
            outputRoot: this.telegramTtsDir()
        )
        match (result.get("payload")) {
            case Some(v) =>
                try {
                    let payload = v.asString().getValue().trimAscii()
                    if (!payload.isEmpty()) {
                        return payload
                    }
                } catch (_: Exception) {
                    ()
                }
            case None => ()
        }
        text
    }

    private func messageToolActionDeliveredVisibleReply(action: String): Bool {
        action == "send" ||
            action == "reply" ||
            action == "thread" ||
            action == "poll" ||
            action == "photo" ||
            action == "document" ||
            action == "audio" ||
            action == "voice" ||
            action == "video" ||
            action == "video-note"
    }

    public func debugMessageForTest(action: String, channel: String, to: String, message: String): String {
        this.__tool_impl_of_message(
            action,
            Some(channel),
            Some(to),
            Some(message),
            None<String>,
            None<String>,
            None<String>,
            None<String>,
            None<String>,
            None<Bool>,
            None<Int64>,
            None<Bool>,
            None<Bool>
        )
    }

    @tool[
        description: "Send one Gateway-backed message through the unified channels.send RPC surface. Supports action=send, reply, thread, reaction, chat-action, poll, delete, edit, pin, unpin, topic-create, topic-edit, photo, document, audio, voice, video, and video-note.",
        parameters: {
            action: "Message action. Supported now: send, reply, thread, reaction, chat-action, poll, delete, edit, pin, unpin, topic-create, topic-edit, photo, document, audio, voice, video, video-note.",
            channel: "Gateway channel id, such as feishu or qq.",
            to: "Target peer/chat id.",
            message: "Message text to send.",
            replyTo: "Reply target message id for action=reply.",
            threadId: "Thread root or anchor message id for action=thread.",
            reaction: "For action=reaction, the reaction token or short text to send, such as +1, thumbs_up, or acknowledged.",
            poll: "For action=poll, a pipe-delimited poll payload such as 'Lunch?|Rice|Noodles|Salad'. It is encoded into a structured text payload.",
            caption: "Optional caption for media actions.",
            forceDocument: "When true for Telegram media, route image/GIF media through document payload.",
            durationSeconds: "Optional Telegram poll duration in seconds, 5-600.",
            allowMultiselect: "Optional Telegram poll multi-select flag.",
            isAnonymous: "Optional Telegram poll anonymous flag."
        }
    ]
    public func message(
        action: String,
        channel: Option<String>,
        to: Option<String>,
        message: Option<String>,
        replyTo: Option<String>,
        threadId: Option<String>,
        reaction: Option<String>,
        poll: Option<String>,
        caption: Option<String>,
        forceDocument: Option<Bool>,
        durationSeconds: Option<Int64>,
        allowMultiselect: Option<Bool>,
        isAnonymous: Option<Bool>
    ): String {
        let act = action.trimAscii().toAsciiLower()
        PrintUtils.printTool("message", shortMessage: act)

        if (!(act == "send" || act == "reply" || act == "thread" || act == "reaction" || act == "chat-action" || act == "poll" || act == "delete" || act == "edit" || act == "pin" || act == "unpin" || act == "topic-create" || act == "topic-edit" || act == "photo" || act == "document" || act == "audio" || act == "voice" || act == "video" || act == "video-note")) {
            let unsupported = JsonObject()
            unsupported.put("ok", JsonBool(false))
            unsupported.put("status", JsonString("unsupported"))
            unsupported.put("action", JsonString(act))
            unsupported.put("error", JsonString("Unsupported message action in current gateway implementation: ${act}"))
            let out = unsupported.toJsonString()
            PrintUtils.printToolResult(out)
            return out
        }

        let ch = match (channel) {
            case Some(v) => v.trimAscii().toAsciiLower()
            case None => ""
        }
        let target = match (to) {
            case Some(v) => v.trimAscii()
            case None => ""
        }
        var text = match (message) {
            case Some(v) => v.trimAscii()
            case None => ""
        }
        var payloadKind = "text"
        if (act == "reaction") {
            payloadKind = "reaction"
            text = match (reaction) {
                case Some(v) =>
                    let t = v.trimAscii()
                    if (t.isEmpty()) { "" } else { renderGatewayReactionText(t) }
                case None => ""
            }
        } else if (act == "chat-action") {
            payloadKind = "chat-action"
            text = renderGatewayChatActionText(text)
        } else if (act == "poll") {
            payloadKind = "poll"
            text = renderGatewayPollTextAdvanced(match (poll) {
                case Some(v) => v
                case None => ""
            }, durationSeconds: durationSeconds, allowMultiselect: allowMultiselect, isAnonymous: isAnonymous)
        } else if (act == "delete") {
            payloadKind = "delete"
            text = renderGatewayDeleteText()
        } else if (act == "pin") {
            payloadKind = "pin"
            text = renderGatewayPinText()
        } else if (act == "unpin") {
            payloadKind = "unpin"
            text = renderGatewayUnpinText()
        } else if (act == "edit") {
            payloadKind = "edit"
            text = renderGatewayEditText(text)
        } else if (act == "topic-create") {
            payloadKind = "topic-create"
            text = renderGatewayTopicCreateText(text)
        } else if (act == "topic-edit") {
            payloadKind = "topic-edit"
            text = renderGatewayTopicEditText(text)
        } else if (act == "photo") {
            payloadKind = "photo"
            text = if (match (forceDocument) { case Some(v) => v case None => false }) {
                renderGatewayDocumentText(text, caption: match (caption) { case Some(v) => v case None => "" })
            } else {
                renderGatewayPhotoText(text, caption: match (caption) { case Some(v) => v case None => "" })
            }
        } else if (act == "document") {
            payloadKind = "document"
            text = renderGatewayDocumentText(text, caption: match (caption) { case Some(v) => v case None => "" })
        } else if (act == "audio") {
            payloadKind = "audio"
            text = renderGatewayAudioText(text, caption: match (caption) { case Some(v) => v case None => "" })
        } else if (act == "voice") {
            payloadKind = "voice"
            text = renderGatewayVoiceText(text, caption: match (caption) { case Some(v) => v case None => "" })
        } else if (act == "video") {
            payloadKind = "video"
            text = renderGatewayVideoText(text, caption: match (caption) { case Some(v) => v case None => "" })
        } else if (act == "video-note") {
            payloadKind = "video-note"
            text = renderGatewayVideoNoteText(text)
        } else if (act == "reply" || act == "thread") {
            payloadKind = "threaded-text"
        }
        text = gatewayMessageToolStripInternalDirectives(text)
        let synthesizedText = this.maybeSynthesizeTelegramAutoVoiceText(ch, payloadKind, text)
        if (synthesizedText.trimAscii().startsWith("[voice]")) {
            payloadKind = "voice"
        } else if (synthesizedText.trimAscii().startsWith("[audio]")) {
            payloadKind = "audio"
        }
        text = synthesizedText
        if (ch.isEmpty() || target.isEmpty() || text.isEmpty()) {
            let err = JsonObject()
            err.put("ok", JsonBool(false))
            err.put("status", JsonString("error"))
            err.put("action", JsonString(act))
            err.put("error", JsonString(if (act == "reaction") {
                "reaction requires channel, to, and reaction"
            } else if (act == "chat-action") {
                "chat-action requires channel, to, and message"
            } else if (act == "poll") {
                "poll requires channel, to, and poll"
            } else if (act == "delete" || act == "pin" || act == "unpin") {
                "${act} requires channel and to"
            } else {
                "${act} requires channel, to, and message"
            }))
            let out = err.toJsonString()
            PrintUtils.printToolResult(out)
            return out
        }

        let replyAnchor = if (act == "reply" || act == "edit" || act == "delete" || act == "pin" || act == "unpin" || act == "topic-edit") {
            match (replyTo) {
                case Some(v) => v.trimAscii()
                case None => ""
            }
        } else if (act == "thread") {
            match (threadId) {
                case Some(v) => v.trimAscii()
                case None => ""
            }
        } else {
            ""
        }
        if ((act == "reply" || act == "thread" || act == "edit" || act == "delete" || act == "pin" || act == "unpin" || act == "topic-edit") && replyAnchor.isEmpty()) {
            let err = JsonObject()
            err.put("ok", JsonBool(false))
            err.put("status", JsonString("error"))
            err.put("action", JsonString(act))
            err.put("error", JsonString(
                if (act == "reply") {
                    "reply requires replyTo"
                } else if (act == "thread") {
                    "thread requires threadId"
                } else if (act == "edit") {
                    "edit requires replyTo"
                } else if (act == "topic-edit") {
                    "topic-edit requires replyTo"
                } else if (act == "pin" || act == "unpin") {
                    "${act} requires replyTo"
                } else {
                    "delete requires replyTo"
                }
            ))
            let out = err.toJsonString()
            PrintUtils.printToolResult(out)
            return out
        }

        let payload = JsonObject()
        payload.put("id", JsonString(ch))
        payload.put("channel", JsonString(ch))
        payload.put("peerId", JsonString(target))
        payload.put("to", JsonString(target))
        payload.put("text", JsonString(text))
        payload.put("message", JsonString(text))
        if (!replyAnchor.isEmpty()) {
            payload.put("replyTo", JsonString(replyAnchor))
            payload.put("replyToMessageId", JsonString(replyAnchor))
        }
        if (act == "thread") {
            payload.put("replyInThread", JsonBool(true))
        }

        let sent = this.invokeGatewaySend(payload)
        let ok = match (sent.get("ok")) {
            case Some(v) =>
                try { v.asBool().getValue() } catch (_: Exception) { false }
            case None => false
        }
        if (ok && this.messageToolActionDeliveredVisibleReply(act)) {
            gatewayMarkCurrentToolRuntimeVisibleReplyDelivered()
        }
        let result = JsonObject()
        result.put("ok", JsonBool(ok))
        result.put("status", JsonString(if (ok) { "accepted" } else { "error" }))
        result.put("action", JsonString(act))
        result.put("channel", JsonString(ch))
        result.put("to", JsonString(target))
        result.put("message", JsonString(text))
        result.put("payloadKind", JsonString(payloadKind))
        result.put("payloadPreview", JsonString(gatewayMessagePayloadPreview(text)))
        if (!replyAnchor.isEmpty()) {
            if (act == "reply") {
                result.put("replyTo", JsonString(replyAnchor))
            } else {
                result.put("threadId", JsonString(replyAnchor))
            }
        }
        if (act == "reaction") {
            match (reaction) {
                case Some(v) =>
                    let t = v.trimAscii()
                    if (!t.isEmpty()) { result.put("reaction", JsonString(t)) }
                case None => ()
            }
        }
        if (act == "poll") {
            match (poll) {
                case Some(v) =>
                    let t = v.trimAscii()
                    if (!t.isEmpty()) {
                        result.put("poll", JsonString(t))
                        let parsed = parseGatewayPollParts(t)
                        if (!parsed[0].isEmpty()) {
                            result.put("pollTitle", JsonString(parsed[0]))
                        }
                    }
                case None => ()
            }
        }
        result.put("gateway", sent)
        let out = result.toJsonString()
        PrintUtils.printToolResult(out)
        return out
    }
}
