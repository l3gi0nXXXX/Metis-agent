package metis.core.media_tests

import metis.core.*

import std.collection.ArrayList
import std.unittest.*
import stdx.encoding.json.JsonObject

@Test
public class GatewaySignedUrlDownloadTest {
    @TestCase
    public func protectsPercentEncodedPathAndQueryForHttpBuilder(): Unit {
        let raw = "https://dashscope-result.example.com/a%2Fb/out.mp4?Expires=1770000000&OSSAccessKeyId=LTAI***&Signature=QZRjXLzFI35dFadE7uUsWnVX%2BlM%3D"
        let protected = gatewaySignedUrlProtectPercentEncodingForHttpBuilder(raw)

        @Expect(protected.contains("/a%252Fb/out.mp4"), true)
        @Expect(protected.contains("Signature=QZRjXLzFI35dFadE7uUsWnVX%252BlM%253D"), true)
        @Expect(protected.contains("%2BlM%3D"), false)
    }

    @TestCase
    public func leavesPlainUrlWithoutPercentEncodingUnchanged(): Unit {
        let raw = "https://cdn.example.com/out/demo.mp4?Expires=1770000000&Signature=plain"
        @Expect(gatewaySignedUrlProtectPercentEncodingForHttpBuilder(raw), raw)
    }

    @TestCase
    public func preservesFragmentAfterProtectedRequestPart(): Unit {
        let raw = "https://cdn.example.com/out%2Fdemo.mp4?Signature=a%2Bb%3D#debug"
        let expected = "https://cdn.example.com/out%252Fdemo.mp4?Signature=a%252Bb%253D#debug"
        @Expect(gatewaySignedUrlProtectPercentEncodingForHttpBuilder(raw), expected)
    }

    @TestCase
    public func nativeDownloadPassesProtectedBuilderUrlToRunner(): Unit {
        let seenBuilder = ArrayList<String>()
        let seenOriginal = ArrayList<String>()
        setGatewaySignedUrlHttpSendForTest(Some({ builderUrl: String, originalUrl: String, timeoutMs: Int64, maxBytes: Int64, _providerConfig: JsonObject =>
            seenBuilder.add(builderUrl)
            seenOriginal.add(originalUrl)
            @Expect(timeoutMs, 3000)
            @Expect(maxBytes, 1024)
            GatewaySignedUrlDownloadResult(200, bodyBytes: "ok".toArray(), contentType: "video/mp4")
        }))
        try {
            let raw = "https://dashscope-result.example.com/a%2Fb/out.mp4?Signature=a%2Bb%3D"
            let result = gatewaySignedUrlDownload(raw, 3000, 1024, JsonObject())

            @Expect(result.statusCode, 200)
            @Expect(seenOriginal.size, 1)
            @Expect(seenOriginal[0], raw)
            @Expect(seenBuilder.size, 1)
            @Expect(seenBuilder[0].contains("/a%252Fb/out.mp4"), true)
            @Expect(seenBuilder[0].contains("Signature=a%252Bb%253D"), true)
        } finally {
            setGatewaySignedUrlHttpSendForTest(None<(String, String, Int64, Int64, JsonObject) -> GatewaySignedUrlDownloadResult>)
        }
    }

    @TestCase
    public func nativeDownloadKeepsPlainUrlUnchangedForRunner(): Unit {
        let seenBuilder = ArrayList<String>()
        let seenOriginal = ArrayList<String>()
        setGatewaySignedUrlHttpSendForTest(Some({ builderUrl: String, originalUrl: String, _timeoutMs: Int64, _maxBytes: Int64, _providerConfig: JsonObject =>
            seenBuilder.add(builderUrl)
            seenOriginal.add(originalUrl)
            GatewaySignedUrlDownloadResult(200, bodyBytes: "ok".toArray(), contentType: "image/png")
        }))
        try {
            let raw = "https://cdn.example.com/out/demo.png?Signature=plain"
            let result = gatewaySignedUrlDownload(raw, 1000, 1024, JsonObject())

            @Expect(result.statusCode, 200)
            @Expect(seenOriginal[0], raw)
            @Expect(seenBuilder[0], raw)
        } finally {
            setGatewaySignedUrlHttpSendForTest(None<(String, String, Int64, Int64, JsonObject) -> GatewaySignedUrlDownloadResult>)
        }
    }

    @TestCase
    public func nativeDownloadMapsOversizeAfterSuccessfulResponse(): Unit {
        setGatewaySignedUrlHttpSendForTest(Some({ _builderUrl: String, _originalUrl: String, _timeoutMs: Int64, _maxBytes: Int64, _providerConfig: JsonObject =>
            GatewaySignedUrlDownloadResult(200, bodyBytes: "too-large".toArray(), contentType: "video/mp4")
        }))
        try {
            let result = gatewaySignedUrlDownload("https://cdn.example.com/out.mp4", 1000, 3, JsonObject())

            @Expect(result.statusCode, 413)
            @Expect(result.error, "downloaded media exceeds maxBytes")
            @Expect(result.bodyBytes.size, 0)
        } finally {
            setGatewaySignedUrlHttpSendForTest(None<(String, String, Int64, Int64, JsonObject) -> GatewaySignedUrlDownloadResult>)
        }
    }

    @TestCase
    public func nativeDownloadDoesNotLeakQueryInErrorFields(): Unit {
        setGatewaySignedUrlHttpSendForTest(Some({ _builderUrl: String, _originalUrl: String, _timeoutMs: Int64, _maxBytes: Int64, _providerConfig: JsonObject =>
            GatewaySignedUrlDownloadResult(
                403,
                error: "failed https://cdn.example.com/out.mp4?Expires=1770000000&OSSAccessKeyId=LTAI&Signature=a%2Bb%3D&X-Amz-Credential=secret"
            )
        }))
        try {
            let result = gatewaySignedUrlDownload("https://cdn.example.com/out.mp4?Signature=a%2Bb%3D", 1000, 1024, JsonObject())

            @Expect(result.error.contains("Signature="), false)
            @Expect(result.error.contains("OSSAccessKeyId="), false)
            @Expect(result.error.contains("Expires="), false)
            @Expect(result.error.contains("X-Amz-Credential="), false)
            @Expect(result.error.contains("?"), false)
        } finally {
            setGatewaySignedUrlHttpSendForTest(None<(String, String, Int64, Int64, JsonObject) -> GatewaySignedUrlDownloadResult>)
        }
    }
}
