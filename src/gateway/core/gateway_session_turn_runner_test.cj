package metis.gateway.core

import metis.core.gatewayCurrentToolRuntimeContext
import metis.core.config.GatewayUserSettings
import metis.gateway.session.{GatewayIngressSource, GatewaySessionRequest}

import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString}

@Test
public class GatewaySessionTurnRunnerTest {
    @TestCase
    public func executeSessionRequestTurnResolvesContextBeforeReply(): Unit {
        let store = GatewaySessionStore(Path("."), enabled: false, agentId: "general")
        let bridge = AgentBridge(sessionStore: store)
        let turn = gatewayExecuteSessionRequestTurn(
            bridge,
            GatewaySessionRequest(
                GatewayIngressSource.Cli,
                channelName: "cli",
                sessionHint: "main",
                agentId: "general"
            ),
            "/unknown"
        )
        @Expect(turn.context.channelName, "cli")
        @Expect(turn.context.sessionKey, "agent:general:main")
        @Expect(turn.context.agentId, "general")
        @Expect(turn.execution.delivered, false)
        @Expect(turn.execution.answer.contains("这不是一个有效的命令"), true)
    }

    @TestCase
    public func executeSessionRequestTurnForUserBuildsBridgeFromResolvedRequest(): Unit {
        let turn = gatewayExecuteSessionRequestTurnForUser(
            GatewayUserSettings(),
            GatewaySessionRequest(
                GatewayIngressSource.Cli,
                channelName: "cli",
                sessionHint: "agent:general:main",
                agentId: ""
            ),
            "/unknown"
        )
        @Expect(turn.context.channelName, "cli")
        @Expect(turn.context.sessionKey, "agent:general:main")
        @Expect(turn.context.agentId, "general")
        @Expect(turn.execution.answer.contains("这不是一个有效的命令"), true)
    }

    @TestCase
    public func executeSessionRequestTurnClearsToolRuntimeContextAfterReply(): Unit {
        let store = GatewaySessionStore(Path("."), enabled: false, agentId: "general")
        let bridge = AgentBridge(sessionStore: store)
        let turn = gatewayExecuteSessionRequestTurn(
            bridge,
            GatewaySessionRequest(
                GatewayIngressSource.ControlUi,
                channelName: "control-ui",
                sessionHint: "main",
                agentId: "general",
                senderId: "operator-1",
                text: "/unknown"
            ),
            "/unknown"
        )
        @Expect(turn.context.channelName, "control-ui")
        @Expect(gatewayCurrentToolRuntimeContext().isNone(), true)
    }

    @TestCase
    public func mediaContextPromptExposesMediaPathsAndTypes(): Unit {
        let media = JsonObject()
        let records = JsonArray([])
        let record = JsonObject()
        record.put("mediaId", JsonString("tg-default-user-101-photo"))
        record.put("mediaKind", JsonString("photo"))
        record.put("mimeType", JsonString("image/jpeg"))
        record.put("originalFileName", JsonString("file_1.jpg"))
        record.put("localPath", JsonString("/tmp/metis-media/file_1.jpg"))
        record.put("downloaded", JsonBool(true))
        records.add(record)
        media.put("records", records)

        let prompt = gatewayBuildMediaContextPrompt(media)
        @Expect(prompt.contains("MediaPath=/tmp/metis-media/file_1.jpg"), true)
        @Expect(prompt.contains("MediaType=photo"), true)
        @Expect(prompt.contains("MediaPaths=/tmp/metis-media/file_1.jpg"), true)
        @Expect(prompt.contains("MediaTypes=photo"), true)
        @Expect(prompt.contains("visionInputReady=true"), true)
        @Expect(prompt.contains("visionAction=use telegram_image_analyze"), true)
        @Expect(prompt.contains("call telegram_image_analyze before answering"), true)
        @Expect(prompt.contains("Do not claim that the image cannot be seen"), true)
    }

    @TestCase
    public func mediaContextPromptIncludesAudioTranscriptSidecar(): Unit {
        let root = Path("/tmp/metis-media-audio-context-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        Directory.create(root, recursive: true)
        let voice = root.join("voice.ogg")
        File.writeTo(voice, "fake-audio".toArray())
        File.writeTo(Path("${voice.toString()}.transcript.txt"), "hello from voice".toArray())
        try {
            let media = JsonObject()
            let records = JsonArray([])
            let record = JsonObject()
            record.put("mediaKind", JsonString("voice"))
            record.put("mimeType", JsonString("audio/ogg"))
            record.put("localPath", JsonString(voice.toString()))
            record.put("downloaded", JsonBool(true))
            records.add(record)
            media.put("records", records)
            let prompt = gatewayBuildMediaContextPrompt(media)
            @Expect(prompt.contains("AudioTranscript=hello from voice"), true)
            @Expect(prompt.contains("use AudioTranscript when present"), true)
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func mediaContextPromptIncludesReadableDocumentPreview(): Unit {
        let root = Path("/tmp/metis-media-doc-context-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        Directory.create(root, recursive: true)
        let doc = root.join("report.txt")
        File.writeTo(doc, "line one\nline two".toArray())
        try {
            let media = JsonObject()
            let records = JsonArray([])
            let record = JsonObject()
            record.put("mediaKind", JsonString("document"))
            record.put("mimeType", JsonString("text/plain"))
            record.put("originalFileName", JsonString("report.txt"))
            record.put("localPath", JsonString(doc.toString()))
            record.put("downloaded", JsonBool(true))
            records.add(record)
            media.put("records", records)
            let prompt = gatewayBuildMediaContextPrompt(media)
            @Expect(prompt.contains("FileContentPreview=line one\nline two"), true)
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func mediaContextPromptIncludesStructuredTelegramContextWithoutMediaRecords(): Unit {
        let media = JsonObject()
        let context = JsonObject()
        let location = JsonObject()
        location.put("latitude", JsonString("31.23"))
        location.put("longitude", JsonString("121.47"))
        context.put("location", location)
        let contact = JsonObject()
        contact.put("firstName", JsonString("Ada"))
        contact.put("phoneNumber", JsonString("123"))
        context.put("contact", contact)
        media.put("context", context)

        let prompt = gatewayBuildMediaContextPrompt(media)
        @Expect(prompt.contains("StructuredTelegramContext:"), true)
        @Expect(prompt.contains("Location="), true)
        @Expect(prompt.contains("31.23"), true)
        @Expect(prompt.contains("Contact="), true)
        @Expect(prompt.contains("Ada"), true)
    }

    @TestCase
    public func streamingDefaultsToOnButCanBeDisabledPerImChannel(): Unit {
        var defaults = GatewayUserSettings()
        defaults.telegram.enabled = true
        defaults.feishu.enabled = true
        defaults.qq.enabled = true
        @Expect(gatewayStreamingEnabledForUserChannel(defaults, "telegram"), true)
        @Expect(gatewayStreamingEnabledForUserChannel(defaults, "feishu"), true)
        @Expect(gatewayStreamingEnabledForUserChannel(defaults, "qq"), true)

        var disabled = GatewayUserSettings()
        disabled.telegram.enabled = true
        disabled.telegram.streaming = "off"
        @Expect(gatewayStreamingEnabledForUserChannel(disabled, "telegram"), false)

        var feishuDisabled = GatewayUserSettings()
        feishuDisabled.feishu.enabled = true
        feishuDisabled.feishu.streaming = "off"
        @Expect(gatewayStreamingEnabledForUserChannel(feishuDisabled, "feishu"), false)

        var qqDisabled = GatewayUserSettings()
        qqDisabled.qq.enabled = true
        qqDisabled.qq.streaming = "off"
        @Expect(gatewayStreamingEnabledForUserChannel(qqDisabled, "qq"), false)

        var blocked = GatewayUserSettings()
        blocked.telegram.enabled = true
        blocked.telegram.blockStreaming = true
        @Expect(gatewayStreamingEnabledForUserChannel(blocked, "telegram"), false)

        var feishuBlocked = GatewayUserSettings()
        feishuBlocked.feishu.enabled = true
        feishuBlocked.feishu.blockStreaming = true
        @Expect(gatewayStreamingEnabledForUserChannel(feishuBlocked, "feishu"), false)

        var qqBlocked = GatewayUserSettings()
        qqBlocked.qq.enabled = true
        qqBlocked.qq.blockStreaming = true
        @Expect(gatewayStreamingEnabledForUserChannel(qqBlocked, "qq"), false)
    }
}
