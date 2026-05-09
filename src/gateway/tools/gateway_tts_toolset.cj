package metis.gateway.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*

import metis.core.{gatewayCurrentToolRuntimeContext, gatewayMarkCurrentToolRuntimeVisibleReplyDelivered, gatewayMessagePayloadPreview, gatewaySpeechResolveDeliveryPrefs, gatewaySpeechResolveTtsConfig, gatewaySpeechTtsSynthesize}
import metis.core.config.{CliConfig, CliSettingManager, MetisPaths}
import metis.io.PrintUtils

import std.fs.{Directory, Path, exists}
import std.process.executeWithOutput
import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

private var gatewayTtsToolCallRunnerForTest: Option<(String, JsonObject) -> JsonObject> = None<(String, JsonObject) -> JsonObject>

public func debugSetGatewayTtsToolCallRunnerForTest(runner: Option<(String, JsonObject) -> JsonObject>): Unit {
    gatewayTtsToolCallRunnerForTest = runner
}

private func gatewayTtsToolJsonBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayTtsToolJsonString(obj: JsonObject, key: String, fallback: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayTtsToolOutputRoot(): Path {
    let dir = CliConfig.dotDir.join("gateway-tts")
    if (!exists(dir)) {
        Directory.create(dir, recursive: true)
    }
    dir
}

private func gatewayTtsToolBinaryCommand(): (String, Option<Path>) {
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

private func gatewayTtsToolInvokeGatewaySend(payload: JsonObject): JsonObject {
    match (gatewayTtsToolCallRunnerForTest) {
        case Some(runner) => return runner("channels.send", payload)
        case None => ()
    }
    let (command, workDir) = gatewayTtsToolBinaryCommand()
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

private func gatewayTtsToolCurrentTarget(): (String, String, String) {
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

private func gatewayTtsToolBuildSendPayload(channel: String, target: String, payload: String): JsonObject {
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
public class GatewayTtsToolset {
    public func debugTtsForTest(text: String, channel: String, asVoice: Bool): String {
        this.__tool_impl_of_tts(text, Some(channel), Some(asVoice))
    }

    @tool[
        description: "Convert text to speech through the configured Metis Gateway TTS provider and deliver the generated voice/audio payload to the current IM conversation when possible. After a successful visible delivery, reply with <silent_reply> to avoid duplicate text.",
        parameters: {
            text: "Text to convert to speech.",
            channel: "Optional Gateway channel id, such as telegram. Defaults to the current runtime channel.",
            asVoice: "When true, prefer a voice-message payload if the channel supports it; when false, prefer audio."
        }
    ]
    public func tts(text: String, channel: Option<String>, asVoice: Option<Bool>): String {
        PrintUtils.printTool("tts", shortMessage: "speech")
        let speakable = text.trimAscii()
        let requestedChannel = match (channel) {
            case Some(v) => v.trimAscii().toAsciiLower()
            case None =>
                let current = gatewayTtsToolCurrentTarget()
                current[0]
        }
        let resolvedChannel = if (requestedChannel.isEmpty()) { "telegram" } else { requestedChannel }
        if (speakable.isEmpty()) {
            let err = JsonObject()
            err.put("ok", JsonBool(false))
            err.put("status", JsonString("error"))
            err.put("action", JsonString("tts"))
            err.put("channel", JsonString(resolvedChannel))
            err.put("error", JsonString("tts requires text"))
            let out = err.toJsonString()
            PrintUtils.printToolResult(out)
            return out
        }

        let user = CliSettingManager.readGatewaySettings()
        let prefs = gatewaySpeechResolveDeliveryPrefs(user, channel: resolvedChannel)
        match (asVoice) {
            case Some(value) => prefs.put("audioAsVoice", JsonBool(value))
            case None => ()
        }
        let result = gatewaySpeechTtsSynthesize(
            gatewaySpeechResolveTtsConfig(user, channel: resolvedChannel),
            prefs,
            JsonObject(),
            speakable,
            outputRoot: gatewayTtsToolOutputRoot()
        )
        result.put("action", JsonString("tts"))
        result.put("channel", JsonString(resolvedChannel))

        let payload = gatewayTtsToolJsonString(result, "payload", "")
        if (!payload.isEmpty()) {
            result.put("payloadPreview", JsonString(gatewayMessagePayloadPreview(payload)))
        }

        if (gatewayTtsToolJsonBool(result, "ok", false) && !payload.isEmpty()) {
            let current = gatewayTtsToolCurrentTarget()
            let currentChannel = current[0]
            let target = current[1]
            if (currentChannel == resolvedChannel && !target.isEmpty()) {
                let sent = gatewayTtsToolInvokeGatewaySend(gatewayTtsToolBuildSendPayload(resolvedChannel, target, payload))
                let delivered = gatewayTtsToolJsonBool(sent, "ok", false)
                result.put("delivered", JsonBool(delivered))
                if (delivered) {
                    gatewayMarkCurrentToolRuntimeVisibleReplyDelivered()
                } else {
                    result.put("delivery", JsonString("failed"))
                    result.put("deliveryResult", JsonString(sent.toJsonString()))
                }
            } else {
                result.put("delivered", JsonBool(false))
                result.put("delivery", JsonString("skipped_missing_context"))
            }
        }

        let out = result.toJsonString()
        PrintUtils.printToolResult(out)
        out
    }
}
