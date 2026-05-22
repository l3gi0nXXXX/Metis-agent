package metis.gateway.channels.feishu

import metis.gateway.model.FeishuConfig
import std.collection.ArrayList
import std.fs.{Directory, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonObject, JsonString}

private class FeishuFakeLongConnectTransport <: FeishuLongConnectTransport {
    private let events: Array<JsonObject>
    private let result: FeishuLongConnectStartResult
    public var startCount: Int64 = 0
    public var stopCount: Int64 = 0
    public var lastSpec: FeishuLongConnectStartSpec = FeishuLongConnectStartSpec()

    public init(events!: Array<JsonObject> = [], result!: FeishuLongConnectStartResult = FeishuLongConnectStartResult(ok: true, status: "started")) {
        this.events = events
        this.result = result
    }

    public func start(spec: FeishuLongConnectStartSpec, eventHandler: (JsonObject) -> Unit): FeishuLongConnectStartResult {
        this.startCount += 1
        this.lastSpec = spec
        for (event in this.events) {
            eventHandler(event)
        }
        this.result
    }

    public func stop(): Unit {
        this.stopCount += 1
    }
}

@Test
public class FeishuLongConnectTest {
    private func eventRoot(eventType: String, event: JsonObject, accountId!: String = "tenant-a"): JsonObject {
        let header = JsonObject()
        header.put("event_type", JsonString(eventType))
        if (!accountId.trimAscii().isEmpty()) {
            header.put("account_id", JsonString(accountId.trimAscii()))
        }
        let root = JsonObject()
        root.put("header", header)
        root.put("event", event)
        root
    }

    @TestCase
    public func pbbp2FrameCodecRoundTripsEventFrameAndBuildsAck(): Unit {
        let payload = "{\"header\":{\"event_type\":\"im.message.receive_v1\"},\"event\":{\"message\":{\"message_id\":\"om_codec\"}}}"
        let frame = FeishuLongConnectFrame(
            seqId: 7,
            logId: 9,
            service: 100,
            method: 1,
            headers: [
                FeishuLongConnectFrameHeader("type", "event"),
                FeishuLongConnectFrameHeader("message_id", "msg-1"),
                FeishuLongConnectFrameHeader("sum", "1"),
                FeishuLongConnectFrameHeader("seq", "0"),
                FeishuLongConnectFrameHeader("trace_id", "trace-1")
            ],
            payloadEncoding: "none",
            payloadType: "json",
            payload: payload.toArray(),
            logIdNew: "log-new"
        )

        let encoded = feishuLongConnectEncodeFrame(frame)
        let decoded = feishuLongConnectDecodeFrame(encoded)
        @Expect(decoded.seqId, 7)
        @Expect(decoded.logId, 9)
        @Expect(decoded.service, 100)
        @Expect(decoded.method, 1)
        @Expect(decoded.headerValue("type"), "event")
        @Expect(decoded.headerValue("trace_id"), "trace-1")
        @Expect(decoded.payloadType, "json")
        @Expect(String.fromUtf8(decoded.payload), payload)

        let session = FeishuLongConnectFrameSession()
        let result = session.handleBytes(encoded)
        @Expect(result.status, "event")
        @Expect(result.eventRoots.size, 1)
        @Expect(result.responseFrames.size, 1)
        @Expect(result.responseFrames[0].payload.size > 0, true)
        @Expect(String.fromUtf8(result.responseFrames[0].payload).contains("\"code\":200"), true)
    }

    @TestCase
    public func pbbp2FrameSessionMergesFragmentedEventPayload(): Unit {
        let left = "{\"header\":{\"event_type\":\"im.message.receive_v1\"},"
        let right = "\"event\":{\"message\":{\"message_id\":\"om_fragment\"}}}"
        let session = FeishuLongConnectFrameSession()
        let first = session.handleFrame(FeishuLongConnectFrame(
            method: 1,
            headers: [
                FeishuLongConnectFrameHeader("type", "event"),
                FeishuLongConnectFrameHeader("message_id", "frag-1"),
                FeishuLongConnectFrameHeader("sum", "2"),
                FeishuLongConnectFrameHeader("seq", "0")
            ],
            payload: left.toArray()
        ))
        @Expect(first.status, "fragment_pending")
        @Expect(first.eventRoots.size, 0)

        let second = session.handleFrame(FeishuLongConnectFrame(
            method: 1,
            headers: [
                FeishuLongConnectFrameHeader("type", "event"),
                FeishuLongConnectFrameHeader("message_id", "frag-1"),
                FeishuLongConnectFrameHeader("sum", "2"),
                FeishuLongConnectFrameHeader("seq", "1")
            ],
            payload: right.toArray()
        ))
        @Expect(second.status, "event")
        @Expect(second.eventRoots.size, 1)
        @Expect(second.eventRoots[0].get("event").isSome(), true)
        @Expect(second.responseFrames.size, 1)
    }

    private func idObject(openId: String): JsonObject {
        let out = JsonObject()
        out.put("open_id", JsonString(openId))
        out
    }

    private func messageReceiveRoot(): JsonObject {
        this.sidecarMessageRoot("om_native", "text", "{\"text\":\"@bot native hello\"}", chatId: "oc_native")
    }

    private func sidecarMessageRoot(
        messageId: String,
        messageType: String,
        content: String,
        accountId!: String = "tenant-a",
        chatId!: String = "oc_sidecar"
    ): JsonObject {
        let sender = JsonObject()
        sender.put("sender_id", this.idObject("ou_sender"))
        let message = JsonObject()
        message.put("message_id", JsonString(messageId))
        message.put("chat_id", JsonString(chatId))
        message.put("chat_type", JsonString("group"))
        message.put("message_type", JsonString(messageType))
        message.put("content", JsonString(content))
        let event = JsonObject()
        event.put("sender", sender)
        event.put("message", message)
        this.eventRoot("im.message.receive_v1", event, accountId: accountId)
    }

    private func botMenuRoot(): JsonObject {
        let event = JsonObject()
        event.put("event_key", JsonString("metis.status"))
        event.put("chat_id", JsonString("oc_menu_native"))
        event.put("operator_id", this.idObject("ou_menu_operator"))
        this.eventRoot("application.bot.menu_v6", event)
    }

    private func bitableFieldChangedRoot(): JsonObject {
        let event = JsonObject()
        event.put("app_token", JsonString("bascn_native"))
        event.put("table_id", JsonString("tbl_native"))
        event.put("field_id", JsonString("fld_native"))
        event.put("operator_id", this.idObject("ou_bitable_editor"))
        this.eventRoot("bitable.field.changed_v1", event)
    }

    private func sidecarDiagnosticRoot(error: String): JsonObject {
        let diagnostic = JsonObject()
        diagnostic.put("status", JsonString("failed"))
        diagnostic.put("phase", JsonString("background"))
        diagnostic.put("error", JsonString(error))
        let root = this.eventRoot("metis.feishu.sidecar.diagnostic", JsonObject())
        root.put("sidecar", diagnostic)
        root
    }

    private func tempRoot(label: String): Path {
        Path("/tmp/metis-feishu-sidecar-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    }

    private func cardActionRoot(): JsonObject {
        let context = JsonObject()
        context.put("open_message_id", JsonString("om_card_native"))
        context.put("open_chat_id", JsonString("oc_card_native"))
        let value = JsonObject()
        value.put("action", JsonString("feishu.auth.confirm"))
        let action = JsonObject()
        action.put("value", value)
        let event = JsonObject()
        event.put("operator", this.idObject("ou_operator"))
        event.put("context", context)
        event.put("action", action)
        this.eventRoot("card.action.trigger", event)
    }

    private func reactionRoot(eventType: String, messageId: String): JsonObject {
        let reactionType = JsonObject()
        reactionType.put("emoji_type", JsonString("THUMBSUP"))
        let event = JsonObject()
        event.put("message_id", JsonString(messageId))
        event.put("chat_id", JsonString("oc_react_native"))
        event.put("chat_type", JsonString("group"))
        event.put("thread_id", JsonString("omt_react_native"))
        event.put("reaction_type", reactionType)
        event.put("user_id", this.idObject("ou_reactor"))
        this.eventRoot(eventType, event)
    }

    private func botMembershipRoot(eventType: String): JsonObject {
        let event = JsonObject()
        event.put("chat_id", JsonString("oc_bot_native"))
        event.put("operator_id", this.idObject("ou_owner"))
        this.eventRoot(eventType, event)
    }

    private func vcBotInvitedRoot(): JsonObject {
        let meeting = JsonObject()
        meeting.put("meeting_no", JsonString("987654"))
        let event = JsonObject()
        event.put("event_id", JsonString("ev_vc_native"))
        event.put("meeting", meeting)
        event.put("operator_id", this.idObject("ou_inviter"))
        this.eventRoot("vc.bot.meeting_invited_v1", event)
    }

    private func driveNoticeCommentAddRoot(): JsonObject {
        let event = JsonObject()
        event.put("comment_id", JsonString("comment_native"))
        event.put("reply_id", JsonString("reply_native"))
        event.put("file_token", JsonString("doccn_native"))
        event.put("file_type", JsonString("doc"))
        event.put("user_id", this.idObject("ou_commenter"))
        event.put("content", JsonString("native drive comment"))
        event.put("is_mention", JsonBool(true))
        this.eventRoot("drive.notice.comment_add_v1", event)
    }

    @TestCase
    public func longConnectStartUsesNativeTransportWithoutSidecarDependency(): Unit {
        let transport = FeishuFakeLongConnectTransport()
        let adapter = FeishuAdapter(
            config: FeishuConfig(
                enabled: true,
                appId: "cli_native_app",
                appSecret: "native-secret-never-output",
                receiveMode: "long_connect"
            ),
            accountId: "tenant-a",
            longConnectTransport: transport
        )

        adapter.start()
        @Expect(adapter.debugIsRunningForTest(), true)
        @Expect(adapter.debugFeishuNativeLongConnectLastErrorForTest(), "")
        @Expect(transport.startCount, 1)
        @Expect(transport.lastSpec.accountId, "tenant-a")
        @Expect(transport.lastSpec.appId, "cli_native_app")
        @Expect(transport.lastSpec.appSecret, "native-secret-never-output")

        adapter.stop()
        @Expect(transport.stopCount, 1)
    }

    @TestCase
    public func disabledLongConnectDoesNotFailWhenTransportWouldFail(): Unit {
        let transport = FeishuFakeLongConnectTransport(
            result: FeishuLongConnectStartResult(ok: false, status: "missing_dependency", error: "sidecar sdk missing")
        )
        let adapter = FeishuAdapter(
            config: FeishuConfig(
                enabled: true,
                receiveMode: "webhook"
            ),
            accountId: "tenant-a",
            longConnectTransport: transport
        )

        adapter.start()

        @Expect(adapter.debugIsRunningForTest(), true)
        @Expect(adapter.debugFeishuNativeLongConnectLastErrorForTest(), "")
        @Expect(transport.startCount, 0)
    }

    @TestCase
    public func feishuAdapterThrowsWhenSidecarStartFails(): Unit {
        let transport = FeishuFakeLongConnectTransport(
            result: FeishuLongConnectStartResult(
                ok: false,
                status: "missing_dependency",
                error: "Feishu sidecar dependency missing: @larksuiteoapi/node-sdk under /tmp/metis-feishu-runtime"
            )
        )
        let adapter = FeishuAdapter(
            config: FeishuConfig(
                enabled: true,
                appId: "cli_sidecar_app",
                appSecret: "sidecar-secret-never-output",
                receiveMode: "long_connect"
            ),
            accountId: "tenant-a",
            longConnectTransport: transport
        )
        var threw = false
        var message = ""

        try {
            adapter.start()
        } catch (e: Exception) {
            threw = true
            message = e.message
        }

        @Expect(threw, true)
        @Expect(adapter.debugIsRunningForTest(), false)
        @Expect(adapter.debugFeishuNativeLongConnectLastErrorForTest().contains("missing_dependency"), true)
        @Expect(adapter.debugFeishuNativeLongConnectLastErrorForTest().contains("@larksuiteoapi/node-sdk"), true)
        @Expect(message.contains("Feishu long-connect transport failed to start"), true)
        @Expect(message.contains("missing_dependency"), true)
        @Expect(transport.startCount, 1)
    }

    @TestCase
    public func sidecarStartFailureIsRedactedBeforeAdapterPersistence(): Unit {
        let transport = FeishuFakeLongConnectTransport(
            result: FeishuLongConnectStartResult(
                ok: false,
                status: "missing_dependency",
                error: "Authorization: Bearer sidecar-token appSecret=sidecar-secret-never-output"
            )
        )
        let adapter = FeishuAdapter(
            config: FeishuConfig(
                enabled: true,
                appId: "cli_sidecar_app",
                appSecret: "sidecar-secret-never-output",
                receiveMode: "long_connect"
            ),
            accountId: "tenant-a",
            longConnectTransport: transport
        )
        var message = ""

        try {
            adapter.start()
        } catch (e: Exception) {
            message = e.message
        }

        let lastError = adapter.debugFeishuNativeLongConnectLastErrorForTest()
        @Expect(lastError.contains("[redacted]"), true)
        @Expect(message.contains("[redacted]"), true)
        @Expect(lastError.contains("sidecar-token"), false)
        @Expect(lastError.contains("sidecar-secret-never-output"), false)
        @Expect(message.contains("sidecar-token"), false)
        @Expect(message.contains("sidecar-secret-never-output"), false)
    }

    @TestCase
    public func nativeLongConnectEventsEnterSharedDispatchPath(): Unit {
        let transport = FeishuFakeLongConnectTransport(events: [
            this.messageReceiveRoot(),
            this.cardActionRoot(),
            this.reactionRoot("im.message.reaction.created_v1", "om_reaction_created"),
            this.reactionRoot("im.message.reaction.deleted_v1", "om_reaction_deleted"),
            this.botMembershipRoot("im.chat.member.bot.added_v1"),
            this.botMembershipRoot("im.chat.member.bot.deleted_v1"),
            this.vcBotInvitedRoot(),
            this.driveNoticeCommentAddRoot()
        ])
        let adapter = FeishuAdapter(
            config: FeishuConfig(
                enabled: true,
                appId: "cli_native_app",
                appSecret: "native-secret-never-output",
                receiveMode: "long_connect"
            ),
            accountId: "tenant-a",
            longConnectTransport: transport
        )

        adapter.start()
        let inbound = adapter.pullInbound()
        @Expect(inbound.size, 8)
        @Expect(inbound[0].messageId, "om_native")
        @Expect(inbound[1].systemEventKind, "feishu.card_action")
        @Expect(inbound[2].systemEventKind, "feishu.reaction")
        @Expect(inbound[2].raw.getOrThrow().contains("im.message.reaction.created_v1"), true)
        @Expect(inbound[3].systemEventKind, "feishu.reaction")
        @Expect(inbound[3].raw.getOrThrow().contains("im.message.reaction.deleted_v1"), true)
        @Expect(inbound[4].systemEventKind, "feishu.bot_membership")
        @Expect(inbound[5].systemEventKind, "feishu.bot_membership")
        @Expect(inbound[6].systemEventKind, "feishu.vc_invited")
        @Expect(inbound[6].text.contains("987654"), true)
        @Expect(inbound[7].systemEventKind, "feishu.drive_comment")
        @Expect(inbound[7].text.contains("comment_native"), true)
    }

    @TestCase
    public func sidecarInboundMessageTypesEnterFeishuAdapterWithoutRouteBypass(): Unit {
        let transport = FeishuFakeLongConnectTransport(events: [
            this.sidecarMessageRoot("om_sidecar_text", "text", "{\"text\":\"sidecar text\"}"),
            this.sidecarMessageRoot("om_sidecar_post", "post", "{\"zh_cn\":{\"content\":[[{\"tag\":\"text\",\"text\":\"sidecar post\"}]]}}"),
            this.sidecarMessageRoot("om_sidecar_image", "image", "{\"image_key\":\"img_sidecar\",\"file_name\":\"diagram.png\",\"mime_type\":\"image/png\"}"),
            this.sidecarMessageRoot("om_sidecar_file", "file", "{\"file_key\":\"file_sidecar\",\"file_name\":\"report.pdf\",\"mime_type\":\"application/pdf\"}"),
            this.sidecarMessageRoot("om_sidecar_audio", "audio", "{\"file_key\":\"audio_sidecar\",\"file_name\":\"voice.ogg\",\"mime_type\":\"audio/ogg\"}"),
            this.sidecarMessageRoot("om_sidecar_video", "video", "{\"file_key\":\"video_sidecar\",\"file_name\":\"demo.mp4\",\"mime_type\":\"video/mp4\"}"),
            this.sidecarMessageRoot("om_sidecar_sticker", "sticker", "{\"sticker_key\":\"stk_sidecar\"}")
        ])
        let adapter = FeishuAdapter(
            config: FeishuConfig(enabled: true, appId: "cli_sidecar_app", appSecret: "sidecar-secret-never-output", receiveMode: "long_connect"),
            accountId: "tenant-a",
            longConnectTransport: transport
        )

        adapter.start()
        let inbound = adapter.pullInbound()

        @Expect(inbound.size, 7)
        for (i in 0..inbound.size) {
            @Expect(inbound[i].accountId, "tenant-a")
            @Expect(inbound[i].conversationId.getOrThrow(), "oc_sidecar")
            @Expect(inbound[i].systemEvent, false)
            let context = inbound[i].mediaContext.get("context").getOrThrow().asObject()
            @Expect(context.get("imRoute").isSome(), true)
            @Expect(context.get("feishuGate").isSome(), true)
            @Expect(context.toJsonString().contains("sessionStore"), false)
            @Expect(context.toJsonString().contains("agentDispatch"), false)
        }
        @Expect(inbound[2].mediaContext.get("records").getOrThrow().asArray()[0].asObject().get("mediaKind").getOrThrow().asString().getValue(), "image")
        @Expect(inbound[3].mediaContext.get("records").getOrThrow().asArray()[0].asObject().get("mediaKind").getOrThrow().asString().getValue(), "file")
        @Expect(inbound[4].mediaContext.get("records").getOrThrow().asArray()[0].asObject().get("mediaKind").getOrThrow().asString().getValue(), "audio")
        @Expect(inbound[5].mediaContext.get("records").getOrThrow().asArray()[0].asObject().get("mediaKind").getOrThrow().asString().getValue(), "video")
    }

    @TestCase
    public func sidecarDuplicateEventsDoNotDispatchTwice(): Unit {
        let duplicated = this.sidecarMessageRoot("om_sidecar_dup", "text", "{\"text\":\"sidecar duplicate\"}")
        let transport = FeishuFakeLongConnectTransport(events: [duplicated, duplicated])
        let adapter = FeishuAdapter(
            config: FeishuConfig(enabled: true, appId: "cli_sidecar_app", appSecret: "sidecar-secret-never-output", receiveMode: "long_connect"),
            accountId: "tenant-a",
            longConnectTransport: transport
        )

        adapter.start()
        let inbound = adapter.pullInbound()

        @Expect(inbound.size, 1)
        @Expect(inbound[0].messageId, "om_sidecar_dup")
    }

    @TestCase
    public func sidecarMetadataEventsAreNormalizedByFeishuAdapter(): Unit {
        let transport = FeishuFakeLongConnectTransport(events: [
            this.botMenuRoot(),
            this.cardActionRoot(),
            this.reactionRoot("im.message.reaction.created_v1", "om_sidecar_reaction"),
            this.botMembershipRoot("im.chat.member.bot.added_v1"),
            this.botMembershipRoot("im.chat.member.bot.deleted_v1"),
            this.driveNoticeCommentAddRoot(),
            this.vcBotInvitedRoot(),
            this.bitableFieldChangedRoot()
        ])
        let adapter = FeishuAdapter(
            config: FeishuConfig(enabled: true, appId: "cli_sidecar_app", appSecret: "sidecar-secret-never-output", receiveMode: "long_connect"),
            accountId: "tenant-a",
            longConnectTransport: transport
        )

        adapter.start()
        let inbound = adapter.pullInbound()

        @Expect(inbound.size, 8)
        @Expect(inbound[0].systemEventKind, "feishu.bot_menu")
        @Expect(inbound[1].systemEventKind, "feishu.card_action")
        @Expect(inbound[2].systemEventKind, "feishu.reaction")
        @Expect(inbound[3].systemEventKind, "feishu.bot_membership")
        @Expect(inbound[4].systemEventKind, "feishu.bot_membership")
        @Expect(inbound[5].systemEventKind, "feishu.drive_comment")
        @Expect(inbound[6].systemEventKind, "feishu.vc_invited")
        @Expect(inbound[7].systemEventKind, "feishu.bitable_field_changed")
    }

    @TestCase
    public func sidecarBackgroundFailureUpdatesAdapterLastErrorAndRedactsDiagnostic(): Unit {
        let transport = FeishuFakeLongConnectTransport(events: [
            this.sidecarDiagnosticRoot("Authorization: Bearer sidecar-token appSecret=sidecar-secret-never-output")
        ])
        let adapter = FeishuAdapter(
            config: FeishuConfig(enabled: true, appId: "cli_sidecar_app", appSecret: "sidecar-secret-never-output", receiveMode: "long_connect"),
            accountId: "tenant-a",
            longConnectTransport: transport
        )

        adapter.start()

        @Expect(adapter.debugFeishuNativeLongConnectLastErrorForTest().contains("[redacted]"), true)
        @Expect(adapter.debugFeishuNativeLongConnectLastErrorForTest().contains("sidecar-token"), false)
        @Expect(adapter.debugFeishuNativeLongConnectLastErrorForTest().contains("sidecar-secret-never-output"), false)
    }

    @TestCase
    public func feishuSidecarDoesNotWriteSessionDirectly(): Unit {
        let root = this.tempRoot("session-boundary")
        try {
            Directory.create(root, recursive: true)
            let transport = FeishuFakeLongConnectTransport(events: [
                this.sidecarMessageRoot("om_sidecar_session_boundary", "text", "{\"text\":\"sidecar boundary\"}")
            ])
            let adapter = FeishuAdapter(
                config: FeishuConfig(enabled: true, appId: "cli_sidecar_app", appSecret: "sidecar-secret-never-output", receiveMode: "long_connect"),
                accountId: "tenant-a",
                pairingRoot: root,
                longConnectTransport: transport
            )

            adapter.start()
            @Expect(adapter.pullInbound().size, 1)
            @Expect(exists(root.join("agents")), false)
            @Expect(exists(root.join("sessions")), false)
        } finally {
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func feishuSidecarUsesOnlyMetisConfigStore(): Unit {
        let transport = FeishuFakeLongConnectTransport()
        let adapter = FeishuAdapter(
            config: FeishuConfig(enabled: true, appId: "metis_app_id", appSecret: "metis-secret-never-output", receiveMode: "long_connect"),
            accountId: "tenant-a",
            longConnectTransport: transport
        )

        adapter.start()

        @Expect(transport.lastSpec.appId, "metis_app_id")
        @Expect(transport.lastSpec.appSecret, "metis-secret-never-output")
        let forbidden = "open" + "claw"
        @Expect(transport.lastSpec.appId.contains(forbidden), false)
    }

    @TestCase
    public func feishuSidecarEventsEnterOnlyThroughFeishuAdapter(): Unit {
        let transport = FeishuFakeLongConnectTransport(events: [
            this.sidecarMessageRoot("om_sidecar_adapter_only", "text", "{\"text\":\"adapter only\"}")
        ])
        let adapter = FeishuAdapter(
            config: FeishuConfig(enabled: true, appId: "cli_sidecar_app", appSecret: "sidecar-secret-never-output", receiveMode: "long_connect"),
            accountId: "tenant-a",
            longConnectTransport: transport
        )

        adapter.start()
        let inbound = adapter.pullInbound()

        @Expect(transport.startCount, 1)
        @Expect(inbound.size, 1)
        @Expect(inbound[0].mediaContext.get("context").getOrThrow().asObject().get("imRoute").isSome(), true)
        @Expect(inbound[0].mediaContext.toJsonString().contains("vendorSession"), false)
        @Expect(inbound[0].mediaContext.toJsonString().contains("directAgent"), false)
    }
}
