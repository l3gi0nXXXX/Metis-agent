package metis.gateway.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*

import metis.core.{gatewayCurrentToolRuntimeContext, gatewayMarkCurrentToolRuntimeVisibleReplyDelivered, gatewayMessagePayloadPreview, gatewayVideoGenerationGenerate, gatewayVideoGenerationResolveConfig, renderGatewayVideoText}
import metis.core.config.{CliConfig, CliSettingManager, MetisPaths}
import metis.io.PrintUtils

import std.process.executeWithOutput
import std.fs.{Path, exists}
import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

private var gatewayVideoGenerationToolCallRunnerForTest: Option<(String, JsonObject) -> JsonObject> =
    None<(String, JsonObject) -> JsonObject>

public func debugSetGatewayVideoGenerationToolCallRunnerForTest(runner: Option<(String, JsonObject) -> JsonObject>): Unit {
    gatewayVideoGenerationToolCallRunnerForTest = runner
}

private func gatewayVideoGenerationToolJsonBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayVideoGenerationToolJsonString(obj: JsonObject, key: String, fallback: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayVideoGenerationToolFirstVideoPath(result: JsonObject): String {
    let videos = match (result.get("videos")) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { return "" }
        case None => return ""
    }
    if (videos.size() == 0) {
        return ""
    }
    let video = try { videos[0].asObject() } catch (_: Exception) { return "" }
    gatewayVideoGenerationToolJsonString(video, "path", "")
}

private func gatewayVideoGenerationToolBinaryCommand(): (String, Option<Path>) {
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

private func gatewayVideoGenerationToolInvokeGatewaySend(payload: JsonObject): JsonObject {
    match (gatewayVideoGenerationToolCallRunnerForTest) {
        case Some(runner) => return runner("channels.send", payload)
        case None => ()
    }
    let (command, workDir) = gatewayVideoGenerationToolBinaryCommand()
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

private func gatewayVideoGenerationToolCurrentTarget(): (String, String, String) {
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

private func gatewayVideoGenerationToolBuildSendPayload(channel: String, target: String, payload: String): JsonObject {
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
public class GatewayVideoGenerationToolset {
    public func debugGatewayVideoGenerateForTest(prompt: String, channel: Option<String>, deliver: Bool): String {
        this.__tool_impl_of_gateway_video_generate(
            prompt,
            channel,
            None<String>,
            None<String>,
            None<String>,
            None<Int64>,
            Some(deliver)
        )
    }

    @tool[
        description: "Generate a video through the configured Metis Gateway video generation provider. When called from an IM runtime context, the generated video is delivered through channels.send as a native video payload when possible. After a successful visible delivery, reply with <silent_reply> to avoid duplicate JSON/text.",
        parameters: {
            prompt: "Video generation prompt.",
            channel: "Optional Gateway channel id, such as telegram. Defaults to the current runtime channel.",
            model: "Optional provider/model override for future provider runtimes.",
            filename: "Optional output filename hint.",
            aspectRatio: "Optional aspect ratio hint such as 16:9 or 9:16.",
            durationSeconds: "Optional target duration in seconds.",
            deliver: "When true, deliver the first generated video to the current IM conversation if a runtime target exists. Defaults to true."
        }
    ]
    public func gateway_video_generate(
        prompt: String,
        channel: Option<String>,
        model: Option<String>,
        filename: Option<String>,
        aspectRatio: Option<String>,
        durationSeconds: Option<Int64>,
        deliver: Option<Bool>
    ): String {
        PrintUtils.printTool("gateway_video_generate", shortMessage: "video")
        let current = gatewayVideoGenerationToolCurrentTarget()
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
        match (aspectRatio) {
            case Some(v) =>
                let t = v.trimAscii()
                if (!t.isEmpty()) { request.put("aspectRatio", JsonString(t)) }
            case None => ()
        }
        match (durationSeconds) {
            case Some(v) => request.put("durationSeconds", v.toJsonValue())
            case None => ()
        }

        let user = CliSettingManager.readGatewaySettings()
        let config = gatewayVideoGenerationResolveConfig(user, channel: resolvedChannel)
        let result = gatewayVideoGenerationGenerate(config, request)
        result.put("action", JsonString("gateway_video_generate"))
        result.put("channel", JsonString(resolvedChannel))
        if (!gatewayVideoGenerationToolJsonBool(result, "ok", false) && result.get("error").isNone()) {
            let message = gatewayVideoGenerationToolJsonString(result, "message", "")
            if (!message.isEmpty()) {
                result.put("error", JsonString(message))
            }
        }

        let videoPath = gatewayVideoGenerationToolFirstVideoPath(result)
        if (!videoPath.isEmpty()) {
            result.put("videoPath", JsonString(videoPath))
            result.put("payloadKind", JsonString("video"))
            let payload = renderGatewayVideoText(videoPath, caption: "Generated video")
            result.put("payloadPreview", JsonString(gatewayMessagePayloadPreview(payload)))
            if (gatewayVideoGenerationToolJsonBool(result, "ok", false) && shouldDeliver) {
                if (resolvedChannel == "telegram" && !user.telegram.actions.video) {
                    result.put("delivered", JsonBool(false))
                    result.put("delivery", JsonString("skipped_action_disabled"))
                    result.put("deliveryError", JsonString("telegram video action is disabled"))
                } else if (current[0] == resolvedChannel && !current[1].isEmpty()) {
                    let sent = gatewayVideoGenerationToolInvokeGatewaySend(
                        gatewayVideoGenerationToolBuildSendPayload(resolvedChannel, current[1], payload)
                    )
                    let delivered = gatewayVideoGenerationToolJsonBool(sent, "ok", false)
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
