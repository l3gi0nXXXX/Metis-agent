package metis.gateway.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*

import metis.core.{MediaDiagnosticEvent, emitGatewayMediaDiagnostic, gatewayCurrentToolRuntimeContext, gatewayImageGenerationGenerate, gatewayImageGenerationResolveConfig, gatewayInvokeCurrentToolRuntimeGatewayCall, gatewayMarkCurrentToolRuntimeVisibleReplyDelivered, gatewayMessagePayloadPreview, mediaDiagnosticMergeMeta, mediaDiagnosticPathMeta, renderGatewayPhotoText}
import metis.core.config.CliSettingManager
import metis.io.PrintUtils

import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString}

private var gatewayImageGenerationToolCallRunnerForTest: Option<(String, JsonObject) -> JsonObject> =
    None<(String, JsonObject) -> JsonObject>

public func debugSetGatewayImageGenerationToolCallRunnerForTest(runner: Option<(String, JsonObject) -> JsonObject>): Unit {
    gatewayImageGenerationToolCallRunnerForTest = runner
}

private func gatewayImageGenerationToolJsonBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayImageGenerationToolJsonString(obj: JsonObject, key: String, fallback: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayImageGenerationToolFirstImagePath(result: JsonObject): String {
    let images = match (result.get("images")) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { return "" }
        case None => return ""
    }
    if (images.size() == 0) {
        return ""
    }
    let image = try { images[0].asObject() } catch (_: Exception) { return "" }
    gatewayImageGenerationToolJsonString(image, "path", "")
}

private func gatewayImageGenerationToolStripPerPeerSuffix(raw: String): String {
    let target = raw.trimAscii()
    match (target.indexOf(":u:")) {
        case Some(idx) => target[..idx].trimAscii()
        case None => target
    }
}

private func gatewayImageGenerationToolNormalizeTelegramDirectTarget(raw: String): String {
    let target = raw.trimAscii()
    if (target.isEmpty() || target.startsWith("user:") || target.startsWith("group:") || target.startsWith("@")) {
        return target
    }
    "user:${target}"
}

private func gatewayImageGenerationToolTargetFromSessionKey(channel: String, sessionKey: String): String {
    let key = sessionKey.trimAscii()
    if (channel == "telegram") {
        if (key.startsWith("telegram:direct:")) {
            return key["telegram:direct:".size..].trimAscii()
        }
        if (key.startsWith("telegram:dm:u:")) {
            return gatewayImageGenerationToolNormalizeTelegramDirectTarget(key["telegram:dm:u:".size..])
        }
        if (key.startsWith("telegram:group:")) {
            return gatewayImageGenerationToolStripPerPeerSuffix(key["telegram:group:".size..])
        }
    }
    if (channel == "feishu" && key.startsWith("feishu:direct:")) {
        return key["feishu:direct:".size..].trimAscii()
    }
    if (channel == "feishu" && key.startsWith("feishu:group:")) {
        return key["feishu:group:".size..].trimAscii()
    }
    ""
}

private func gatewayImageGenerationToolInvokeGatewaySend(payload: JsonObject): JsonObject {
    match (gatewayImageGenerationToolCallRunnerForTest) {
        case Some(runner) => return runner("channels.send", payload)
        case None => ()
    }
    match (gatewayInvokeCurrentToolRuntimeGatewayCall("channels.send", payload)) {
        case Some(result) => return result
        case None => ()
    }
    let out = JsonObject()
    out.put("ok", JsonBool(false))
    out.put("status", JsonString("gateway_call_unavailable"))
    out.put("method", JsonString("channels.send"))
    out.put("error", JsonString("Gateway runtime call hook is unavailable; skipped internal CLI/RPC self-call."))
    out
}

private func gatewayImageGenerationToolCurrentTarget(): (String, String, String) {
    match (gatewayCurrentToolRuntimeContext()) {
        case Some(ctx) =>
            let mediaChannel = gatewayImageGenerationToolJsonString(ctx.mediaContext, "channel", "").toAsciiLower()
            let channel = if (!ctx.channelName.isEmpty()) {
                ctx.channelName
            } else if (!mediaChannel.isEmpty()) {
                mediaChannel
            } else {
                ctx.sourceLabel
            }
            let sessionKey = ctx.sessionKey.trimAscii()
            let sessionTarget = gatewayImageGenerationToolTargetFromSessionKey(channel, sessionKey)
            if (!sessionTarget.isEmpty()) {
                return (channel, sessionTarget, sessionKey)
            }
            if (channel == "telegram" || mediaChannel == "telegram") {
                let peerId = gatewayImageGenerationToolStripPerPeerSuffix(gatewayImageGenerationToolJsonString(ctx.mediaContext, "peerId", ""))
                if (!peerId.isEmpty()) {
                    return ("telegram", peerId, sessionKey)
                }
                let to = gatewayImageGenerationToolStripPerPeerSuffix(gatewayImageGenerationToolJsonString(ctx.mediaContext, "to", ""))
                if (!to.isEmpty()) {
                    return ("telegram", to, sessionKey)
                }
                if (!ctx.senderId.isEmpty()) {
                    return ("telegram", gatewayImageGenerationToolNormalizeTelegramDirectTarget(ctx.senderId), sessionKey)
                }
                return ("telegram", "", sessionKey)
            }
            if (channel == "feishu" || mediaChannel == "feishu") {
                let peerId = gatewayImageGenerationToolJsonString(ctx.mediaContext, "peerId", "")
                if (!peerId.isEmpty()) {
                    return ("feishu", peerId, sessionKey)
                }
                let to = gatewayImageGenerationToolJsonString(ctx.mediaContext, "to", "")
                if (!to.isEmpty()) {
                    return ("feishu", to, sessionKey)
                }
                if (!ctx.senderId.isEmpty()) {
                    return ("feishu", ctx.senderId, sessionKey)
                }
                return ("feishu", "", sessionKey)
            }
            return (channel, "", sessionKey)
        case None => ("", "", "")
    }
}

private func gatewayImageGenerationToolBuildSendPayload(channel: String, target: String, payload: String): JsonObject {
    let out = JsonObject()
    out.put("id", JsonString(channel))
    out.put("channel", JsonString(channel))
    out.put("peerId", JsonString(target))
    out.put("to", JsonString(target))
    out.put("text", JsonString(payload))
    out.put("message", JsonString(payload))
    out
}

private func gatewayImageGenerationToolDiagnosticMeta(action: String, channel: String, status: String): JsonObject {
    let meta = JsonObject()
    meta.put("tool", JsonString(action.trimAscii()))
    meta.put("channel", JsonString(channel.trimAscii()))
    meta.put("capability", JsonString("image"))
    meta.put("generationKind", JsonString("image"))
    if (!status.trimAscii().isEmpty()) {
        meta.put("status", JsonString(status.trimAscii()))
    }
    meta
}

@toolset
public class GatewayImageGenerationToolset {
    public func debugGatewayImageGenerateForTest(prompt: String, channel: Option<String>, deliver: Bool): String {
        this.__tool_impl_of_gateway_image_generate(
            prompt,
            channel,
            None<String>,
            None<String>,
            None<String>,
            None<String>,
            None<Int64>,
            None<String>,
            Some(deliver)
        )
    }

    @tool[
        description: "Generate an image through the configured Metis Gateway image generation provider. When called from an IM runtime context, the first generated image is delivered through channels.send as a native photo payload when possible. After a successful visible delivery, reply with <silent_reply> to avoid duplicate JSON/text.",
        parameters: {
            prompt: "Image generation prompt.",
            channel: "Optional Gateway channel id, such as telegram. Defaults to the current runtime channel.",
            model: "Optional provider/model override.",
            filename: "Optional output filename hint.",
            size: "Optional provider size hint such as 1024x1024.",
            aspectRatio: "Optional aspect ratio hint for providers that support it.",
            count: "Optional number of images to generate. Defaults to 1.",
            referenceImage: "Optional local reference image path under an allowed Metis media/output root. Only works when provider supports image editing.",
            deliver: "When true, deliver the first generated image to the current IM conversation if a runtime target exists. Defaults to true."
        }
    ]
    public func gateway_image_generate(
        prompt: String,
        channel: Option<String>,
        model: Option<String>,
        filename: Option<String>,
        size: Option<String>,
        aspectRatio: Option<String>,
        count: Option<Int64>,
        referenceImage: Option<String>,
        deliver: Option<Bool>
    ): String {
        PrintUtils.printTool("gateway_image_generate", shortMessage: "image")
        let current = gatewayImageGenerationToolCurrentTarget()
        let requestedChannel = match (channel) {
            case Some(v) => v.trimAscii().toAsciiLower()
            case None => current[0]
        }
        let resolvedChannel = if (requestedChannel.isEmpty()) { "telegram" } else { requestedChannel }
        let shouldDeliver = match (deliver) {
            case Some(v) => v
            case None => true
        }
        var toolMeta = gatewayImageGenerationToolDiagnosticMeta("gateway_image_generate", resolvedChannel, "invoked")
        toolMeta.put("deliver", JsonBool(shouldDeliver))
        emitGatewayMediaDiagnostic("info", MediaDiagnosticEvent.mediaToolInvoked, "image generation tool invoked", meta: toolMeta)

        let request = JsonObject()
        request.put("prompt", JsonString(prompt.trimAscii()))
        match (model) {
            case Some(v) =>
                let t = v.trimAscii()
                if (!t.isEmpty()) { request.put("model", JsonString(t)) }
            case None => ()
        }
        match (filename) {
            case Some(v) =>
                let t = v.trimAscii()
                if (!t.isEmpty()) { request.put("filename", JsonString(t)) }
            case None => ()
        }
        match (size) {
            case Some(v) =>
                let t = v.trimAscii()
                if (!t.isEmpty()) { request.put("size", JsonString(t)) }
            case None => ()
        }
        match (aspectRatio) {
            case Some(v) =>
                let t = v.trimAscii()
                if (!t.isEmpty()) { request.put("aspectRatio", JsonString(t)) }
            case None => ()
        }
        match (count) {
            case Some(v) => request.put("count", JsonInt(v))
            case None => ()
        }
        match (referenceImage) {
            case Some(v) =>
                let t = v.trimAscii()
                if (!t.isEmpty()) { request.put("referenceImage", JsonString(t)) }
            case None => ()
        }

        let user = CliSettingManager.readGatewaySettings()
        let config = gatewayImageGenerationResolveConfig(user, channel: resolvedChannel)
        let result = gatewayImageGenerationGenerate(config, request)
        result.put("action", JsonString("gateway_image_generate"))
        result.put("channel", JsonString(resolvedChannel))
        if (!gatewayImageGenerationToolJsonBool(result, "ok", false) && result.get("error").isNone()) {
            let message = gatewayImageGenerationToolJsonString(result, "message", "")
            if (!message.isEmpty()) {
                result.put("error", JsonString(message))
            }
        }

        let imagePath = gatewayImageGenerationToolFirstImagePath(result)
        if (!imagePath.isEmpty()) {
            result.put("imagePath", JsonString(imagePath))
            toolMeta = gatewayImageGenerationToolDiagnosticMeta("gateway_image_generate", resolvedChannel, gatewayImageGenerationToolJsonString(result, "status", ""))
            toolMeta = mediaDiagnosticMergeMeta(toolMeta, mediaDiagnosticPathMeta(imagePath))
            emitGatewayMediaDiagnostic("debug", MediaDiagnosticEvent.mediaOutboundResolve, "image generation tool resolved output image", meta: toolMeta)
            result.put("payloadKind", JsonString("photo"))
            let payload = renderGatewayPhotoText(imagePath, caption: "Generated image")
            result.put("payloadPreview", JsonString(gatewayMessagePayloadPreview(payload)))
            if (gatewayImageGenerationToolJsonBool(result, "ok", false) && shouldDeliver) {
                if (resolvedChannel == "telegram" && !user.telegram.actions.photo) {
                    result.put("delivered", JsonBool(false))
                    result.put("delivery", JsonString("skipped_action_disabled"))
                    result.put("deliveryError", JsonString("telegram photo action is disabled"))
                } else if (current[0] == resolvedChannel && !current[1].isEmpty()) {
                    let sent = gatewayImageGenerationToolInvokeGatewaySend(
                        gatewayImageGenerationToolBuildSendPayload(resolvedChannel, current[1], payload)
                    )
                    let delivered = gatewayImageGenerationToolJsonBool(sent, "ok", false)
                    result.put("delivered", JsonBool(delivered))
                    result.put("deliveryResult", sent)
                    if (delivered) {
                        result.put("delivery", JsonString("accepted"))
                        let sendMeta = gatewayImageGenerationToolDiagnosticMeta("gateway_image_generate", resolvedChannel, "accepted")
                        emitGatewayMediaDiagnostic("info", MediaDiagnosticEvent.mediaOutboundSend, "image generation tool delivered media", meta: sendMeta)
                        gatewayMarkCurrentToolRuntimeVisibleReplyDelivered()
                    } else {
                        result.put("delivery", JsonString("failed"))
                        let sendMeta = gatewayImageGenerationToolDiagnosticMeta("gateway_image_generate", resolvedChannel, "failed")
                        emitGatewayMediaDiagnostic("warn", MediaDiagnosticEvent.mediaOutboundFailed, "image generation tool media delivery failed", meta: sendMeta)
                    }
                } else {
                    result.put("delivered", JsonBool(false))
                    result.put("delivery", JsonString("skipped_missing_context"))
                }
            }
        }

        let finalStatus = gatewayImageGenerationToolJsonString(result, "status", "")
        let finalMeta = gatewayImageGenerationToolDiagnosticMeta("gateway_image_generate", resolvedChannel, finalStatus)
        emitGatewayMediaDiagnostic(
            if (gatewayImageGenerationToolJsonBool(result, "ok", false)) { "info" } else { "warn" },
            if (gatewayImageGenerationToolJsonBool(result, "ok", false)) { MediaDiagnosticEvent.mediaToolResult } else { MediaDiagnosticEvent.mediaToolFailed },
            if (gatewayImageGenerationToolJsonBool(result, "ok", false)) { "image generation tool finished" } else { "image generation tool failed" },
            meta: finalMeta
        )
        let out = result.toJsonString()
        PrintUtils.printToolResult(out)
        out
    }
}
