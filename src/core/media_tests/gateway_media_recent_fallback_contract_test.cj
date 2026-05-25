package metis.core.media_tests

import metis.core.*

import std.unittest.*

@Test
public class GatewayMediaRecentFallbackContractTest {
    @TestCase
    public func recentFallbackReturnsLastAssetDescriptorForFollowUpTurns(): Unit {
        let root = mediaFakeAssetRoot("recent-contract")
        let assetStore = gatewayMediaAssetStoreForRoot(root)
        let recent = gatewayMediaRecentStateStoreForRoot(root)
        let key = GatewayMediaRecentStateKey("feishu", "default", "chat-1", sessionId: "session-1")
        let asset = assetStore.saveBytes("image".toArray(), channel: "feishu", accountId: "default", conversationId: "chat-1", messageId: "msg-1", kind: "image", mimeType: "image/png", fileName: "a.png")

        recent.remember(key, asset)
        let found = recent.lookup(key).getOrThrow()

        @Expect(found.assetId, asset.assetId)
        @Expect(found.absolutePath, asset.absolutePath)
        @Expect(found.kind, "image")
        @Expect(found.mimeType, "image/png")
    }
}
