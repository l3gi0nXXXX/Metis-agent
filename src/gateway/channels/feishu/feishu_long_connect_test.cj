package metis.gateway.channels.feishu

import metis.gateway.model.FeishuConfig
import std.collection.ArrayList
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
        let sender = JsonObject()
        sender.put("sender_id", this.idObject("ou_sender"))
        let message = JsonObject()
        message.put("message_id", JsonString("om_native"))
        message.put("chat_id", JsonString("oc_native"))
        message.put("chat_type", JsonString("group"))
        message.put("message_type", JsonString("text"))
        message.put("content", JsonString("{\"text\":\"@bot native hello\"}"))
        let event = JsonObject()
        event.put("sender", sender)
        event.put("message", message)
        this.eventRoot("im.message.receive_v1", event)
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
}
