package metis.gateway.channels.feishu

import metis.core.{renderGatewayAudioText, renderGatewayDeleteText, renderGatewayDocumentText, renderGatewayPhotoText, renderGatewayReactionText, renderGatewayVideoText}
import metis.gateway.model.{ChannelType, FeishuConfig, FeishuMediaConfig, OutboundMessage, SendResult}
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*

@Test
public class FeishuOutboundActionsTest {
    private func tempRoot(suffix: String): Path {
        Path("/tmp/metis-feishu-outbound-${suffix}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
    }

    @TestCase
    public func localPhotoPayloadUploadsAndSendsImageWithoutTextFallback(): Unit {
        let root = this.tempRoot("photo")
        try { remove(root, recursive: true) } catch (_e: Exception) { () }
        let imagePath = root.join("diagram.png")
        Directory.create(root, recursive: true)
        File.writeTo(imagePath, "fake-image".toArray())
        try {
            let client = FeishuFakeApiClient()
            let adapter = FeishuAdapter(
                config: FeishuConfig(
                    enabled: true,
                    streaming: "text",
                    media: FeishuMediaConfig(mediaMaxBytes: 1024, allowedMimes: ["image/*"])
                ),
                apiClient: client
            )
            adapter.start()

            let messageId = adapter.sendWithMessageId(OutboundMessage(
                ChannelType.Feishu,
                "oc_media",
                renderGatewayPhotoText(imagePath.toString(), caption: "diagram"),
                replyToMessageId: Some("om_source"),
                accountId: "tenant-a"
            ))

            @Expect(messageId, "fake-feishu-image-1")
            @Expect(client.textSendCount(), 0)
            @Expect(client.uploadedMediaCount(), 1)
            @Expect(client.mediaSendCount(), 1)
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func localFileAudioAndVideoPayloadsUseFeishuMediaMessagesWithoutTextFallback(): Unit {
        let root = this.tempRoot("multi-media")
        try { remove(root, recursive: true) } catch (_e: Exception) { () }
        let documentPath = root.join("report.pdf")
        let audioPath = root.join("voice.ogg")
        let videoPath = root.join("clip.mp4")
        Directory.create(root, recursive: true)
        File.writeTo(documentPath, "fake-pdf".toArray())
        File.writeTo(audioPath, "fake-audio".toArray())
        File.writeTo(videoPath, "fake-video".toArray())
        try {
            let client = FeishuFakeApiClient()
            let adapter = FeishuAdapter(
                config: FeishuConfig(
                    enabled: true,
                    streaming: "text",
                    media: FeishuMediaConfig(
                        mediaMaxBytes: 1024,
                        allowedMimes: ["application/pdf", "audio/*", "video/*"]
                    )
                ),
                apiClient: client
            )
            adapter.start()

            let documentId = adapter.sendWithMessageId(OutboundMessage(
                ChannelType.Feishu,
                "oc_media",
                renderGatewayDocumentText(documentPath.toString(), caption: "report"),
                accountId: "tenant-a"
            ))
            let audioId = adapter.sendWithMessageId(OutboundMessage(
                ChannelType.Feishu,
                "oc_media",
                renderGatewayAudioText(audioPath.toString(), caption: "voice"),
                accountId: "tenant-a"
            ))
            let videoId = adapter.sendWithMessageId(OutboundMessage(
                ChannelType.Feishu,
                "oc_media",
                renderGatewayVideoText(videoPath.toString(), caption: "clip"),
                accountId: "tenant-a"
            ))

            @Expect(documentId, "fake-feishu-file-1")
            @Expect(audioId, "fake-feishu-audio-2")
            @Expect(videoId, "fake-feishu-media-3")
            @Expect(client.textSendCount(), 0)
            @Expect(client.uploadedMediaCount(), 3)
            @Expect(client.mediaSendCount(), 3)
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func reactionAndDeletePayloadsUseMessageActionsWithoutTextFallback(): Unit {
        let client = FeishuFakeApiClient()
        let adapter = FeishuAdapter(config: FeishuConfig(enabled: true, streaming: "text"), apiClient: client)
        adapter.start()

        let addId = adapter.sendWithMessageId(OutboundMessage(
            ChannelType.Feishu,
            "oc_actions",
            renderGatewayReactionText("+1"),
            replyToMessageId: Some("om_target"),
            accountId: "tenant-a"
        ))
        let afterAdd = client.listMessageReactions("tenant-a", "om_target")
        let removeId = adapter.sendWithMessageId(OutboundMessage(
            ChannelType.Feishu,
            "oc_actions",
            renderGatewayReactionText("remove"),
            replyToMessageId: Some("om_target"),
            accountId: "tenant-a"
        ))
        let deleteId = adapter.sendWithMessageId(OutboundMessage(
            ChannelType.Feishu,
            "oc_actions",
            renderGatewayDeleteText(),
            replyToMessageId: Some("om_delete"),
            accountId: "tenant-a"
        ))

        @Expect(addId, "om_target")
        @Expect(afterAdd.size, 1)
        @Expect(afterAdd[0], "THUMBSUP")
        @Expect(removeId, "om_target")
        @Expect(deleteId, "om_delete")
        @Expect(client.listMessageReactions("tenant-a", "om_target").size, 0)
        @Expect(client.deletedMessageCount(), 1)
        @Expect(client.textSendCount(), 0)
    }

    @TestCase
    public func remoteMediaUrlIsRejectedBeforeTextFallback(): Unit {
        let client = FeishuFakeApiClient()
        let adapter = FeishuAdapter(config: FeishuConfig(enabled: true, streaming: "text"), apiClient: client)
        adapter.start()

        match (adapter.send(OutboundMessage(
            ChannelType.Feishu,
            "oc_media",
            renderGatewayPhotoText("http://169.254.169.254/latest/meta-data", caption: "blocked"),
            accountId: "tenant-a"
        ))) {
            case SendResult.Success => @Expect(false, true)
            case SendResult.Failed(reason) =>
                @Expect(reason.contains("remote media URL is not supported"), true)
        }
        @Expect(client.textSendCount(), 0)
    }

    @TestCase
    public func mediaUploadFailureReturnsHumanReadableRedactedFailure(): Unit {
        let root = this.tempRoot("redacted-failure")
        try { remove(root, recursive: true) } catch (_e: Exception) { () }
        let imagePath = root.join("diagram.png")
        Directory.create(root, recursive: true)
        File.writeTo(imagePath, "fake-image".toArray())
        try {
            let client = FeishuFakeApiClient()
            client.failNextMediaUpload("api_error", error: "{\"ok\":false,\"Authorization\":\"Bearer live-token\",\"tenant_secret\":\"secret\"}")
            let adapter = FeishuAdapter(
                config: FeishuConfig(
                    enabled: true,
                    streaming: "text",
                    media: FeishuMediaConfig(mediaMaxBytes: 1024, allowedMimes: ["image/*"])
                ),
                apiClient: client
            )
            adapter.start()

            match (adapter.send(OutboundMessage(
                ChannelType.Feishu,
                "oc_media",
                renderGatewayPhotoText(imagePath.toString(), caption: "diagram"),
                accountId: "tenant-a"
            ))) {
                case SendResult.Success => @Expect(false, true)
                case SendResult.Failed(reason) =>
                    @Expect(reason.contains("api_error"), true)
                    @Expect(reason.contains("Bearer"), false)
                    @Expect(reason.contains("live-token"), false)
                    @Expect(reason.contains("\"ok\""), false)
                    @Expect(reason.contains("tenant_secret"), false)
            }
            @Expect(client.textSendCount(), 0)
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func localPhotoPayloadReportsSizeLimitBeforeTextFallback(): Unit {
        let root = this.tempRoot("size")
        try { remove(root, recursive: true) } catch (_e: Exception) { () }
        let imagePath = root.join("large.png")
        let textPath = root.join("note.txt")
        Directory.create(root, recursive: true)
        File.writeTo(imagePath, "fake-image-too-large".toArray())
        File.writeTo(textPath, "not-an-image".toArray())
        try {
            let client = FeishuFakeApiClient()
            let adapter = FeishuAdapter(
                config: FeishuConfig(
                    enabled: true,
                    streaming: "text",
                    media: FeishuMediaConfig(mediaMaxBytes: 4, allowedMimes: ["image/*"])
                ),
                apiClient: client
            )
            adapter.start()

            match (adapter.send(OutboundMessage(
                ChannelType.Feishu,
                "oc_media",
                renderGatewayPhotoText(imagePath.toString(), caption: "large"),
                accountId: "tenant-a"
            ))) {
                case SendResult.Success => @Expect(false, true)
                case SendResult.Failed(reason) =>
                    @Expect(reason.contains("size_limit_exceeded"), true)
            }
            @Expect(client.textSendCount(), 0)

            let mimeClient = FeishuFakeApiClient()
            let mimeAdapter = FeishuAdapter(
                config: FeishuConfig(
                    enabled: true,
                    streaming: "text",
                    media: FeishuMediaConfig(mediaMaxBytes: 1024, allowedMimes: ["image/png"])
                ),
                apiClient: mimeClient
            )
            mimeAdapter.start()
            match (mimeAdapter.send(OutboundMessage(
                ChannelType.Feishu,
                "oc_media",
                renderGatewayPhotoText(textPath.toString(), caption: "wrong-mime"),
                accountId: "tenant-a"
            ))) {
                case SendResult.Success => @Expect(false, true)
                case SendResult.Failed(reason) =>
                    @Expect(reason.contains("mime_not_allowed"), true)
            }
            @Expect(mimeClient.textSendCount(), 0)
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }
}
