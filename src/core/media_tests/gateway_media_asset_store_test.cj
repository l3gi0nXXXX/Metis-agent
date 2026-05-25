package metis.core.media_tests

import metis.core.*

import std.fs.{File, Path, exists}
import std.unittest.*

@Test
public class GatewayMediaAssetStoreTest {
    @TestCase
    public func saveBytesUsesManagedChannelAccountPath(): Unit {
        let root = mediaFakeAssetRoot("asset-save")
        let store = gatewayMediaAssetStoreForRoot(root)

        let asset = store.saveBytes(
            "fake-image".toArray(),
            channel: "feishu",
            accountId: "default",
            conversationId: "chat-1",
            messageId: "msg-1",
            kind: "image",
            mimeType: "image/png",
            fileName: "demo image.png",
            source: "inbound"
        )

        @Expect(asset.absolutePath.startsWith(root.toString()), true)
        @Expect(asset.absolutePath.contains("/feishu/default/chat-1/msg-1/image/"), true)
        @Expect(exists(Path(asset.absolutePath)), true)
        @Expect(File.readFrom(Path(asset.absolutePath)), "fake-image".toArray())
        @Expect(store.resolve(asset.assetId).isSome(), true)
    }

    @TestCase
    public func rejectsPathsOutsideManagedRoot(): Unit {
        let root = mediaFakeAssetRoot("asset-reject")
        let store = gatewayMediaAssetStoreForRoot(root)

        @Expect(store.assertPathAllowed(root.join("safe.bin")), true)
        @Expect(store.assertPathAllowed(Path("/tmp/metis.json")), false)
        @Expect(store.assertPathAllowed(Path("/Users/l3gi0n/.metis/metis.json")), false)
        @Expect(store.assertPathAllowed(Path("/Users/l3gi0n/secret.png")), false)
    }

    @TestCase
    public func importLocalPathRequiresManagedRoot(): Unit {
        let root = mediaFakeAssetRoot("asset-import")
        let store = gatewayMediaAssetStoreForRoot(root)
        let source = root.join("source.png")
        File.writeTo(source, "source-bytes".toArray())

        let asset = store.importLocalPath(source, channel: "telegram", accountId: "default", conversationId: "chat", messageId: "m", kind: "image", mimeType: "image/png")

        @Expect(asset.absolutePath.startsWith(root.toString()), true)
        @Expect(File.readFrom(Path(asset.absolutePath)), "source-bytes".toArray())
    }
}
