package metis.gateway.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*

import metis.core.{gatewayCurrentToolRuntimeContext, gatewayImageGenerationGenerate, gatewayImageGenerationResolveConfig, gatewayMarkCurrentToolRuntimeVisibleReplyDelivered, gatewayMessagePayloadPreview, renderGatewayPhotoText}
import metis.core.config.{CliConfig, CliSettingManager, MetisPaths}
import metis.io.PrintUtils

import std.fs.{Path, exists}
import std.process.executeWithOutput
import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

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

private func gatewayImageGenerationToolBinaryCommand(): (String, Option<Path>) {
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

private func gatewayImageGenerationToolInvokeGatewaySend(payload: JsonObject): JsonObject {
    match (gatewayImageGenerationToolCallRunnerForTest) {
        case Some(runner) => return runner("channels.send", payload)
        case None => ()
    }
    let (command, workDir) = gatewayImageGenerationToolBinaryCommand()
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
    out
}

private func gatewayImageGenerationToolCurrentTarget(): (String, String, String) {
    match (gatewayCurrentToolRuntimeContext()) {
        case Some(ctx) =>
            let channel = if (ctx.channelName.isEmpty()) { ctx.sourceLabel } else { ctx.channelName }
            let sessionKey = ctx.sessionKey.trimAscii()
            if (channel == "telegram" && sessionKey.startsWith("telegram:direct:")) {
                return ("telegram", sessionKey["telegram:direct:".size..], sessionKey)
            }
            if (channel == "telegram" && sessionKey.startsWith("telegram:group:")) {
                return ("telegram", sessionKey["telegram:group:".size..], sessionKey)
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
                        gatewayMarkCurrentToolRuntimeVisibleReplyDelivered()
                    } else {
                        result.put("delivery", JsonString("failed"))
                    }
                } else {
                    result.put("delivered", JsonBool(false))
                    result.put("delivery", JsonString("skipped_missing_context"))
                }
            }
        }

        let out = result.toJsonString()
        PrintUtils.printToolResult(out)
        out
    }
}
