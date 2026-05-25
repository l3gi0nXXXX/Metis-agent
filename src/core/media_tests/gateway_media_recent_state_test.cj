package metis.core.media_tests

import metis.core.*

import std.unittest.*

@Test
public class GatewayMediaRecentStateTest {
    @TestCase
    public func recentStateIsIsolatedByChannelAccountConversationAndSession(): Unit {
        let root = mediaFakeAssetRoot("recent-isolated")
        let assetStore = gatewayMediaAssetStoreForRoot(root)
        let recent = gatewayMediaRecentStateStoreForRoot(root)
        let asset = assetStore.saveBytes("image".toArray(), channel: "feishu", accountId: "a1", conversationId: "c1", messageId: "m1", kind: "image", mimeType: "image/png", fileName: "a.png")

        recent.remember(GatewayMediaRecentStateKey("feishu", "a1", "c1", sessionId: "s1"), asset)

        @Expect(recent.lookup(GatewayMediaRecentStateKey("feishu", "a1", "c1", sessionId: "s1")).isSome(), true)
        @Expect(recent.lookup(GatewayMediaRecentStateKey("telegram", "a1", "c1", sessionId: "s1")).isSome(), false)
        @Expect(recent.lookup(GatewayMediaRecentStateKey("feishu", "a2", "c1", sessionId: "s1")).isSome(), false)
        @Expect(recent.lookup(GatewayMediaRecentStateKey("feishu", "a1", "c1", sessionId: "s2")).isSome(), false)
    }

    @TestCase
    public func recentStateCanExpireExplicitly(): Unit {
        let root = mediaFakeAssetRoot("recent-expire")
        let assetStore = gatewayMediaAssetStoreForRoot(root)
        let recent = gatewayMediaRecentStateStoreForRoot(root)
        let key = GatewayMediaRecentStateKey("feishu", "a1", "c1", sessionId: "s1")
        let asset = assetStore.saveBytes("image".toArray(), channel: "feishu", accountId: "a1", conversationId: "c1", messageId: "m1", kind: "image", mimeType: "image/png", fileName: "a.png")

        recent.remember(key, asset)
        @Expect(recent.lookup(key).isSome(), true)
        recent.expire(key)
        @Expect(recent.lookup(key).isSome(), false)
    }
}
