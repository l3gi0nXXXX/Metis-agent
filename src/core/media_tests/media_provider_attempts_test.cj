package metis.core.media_tests

import metis.core.*

import std.unittest.*
import stdx.encoding.json.JsonValue

@Test
public class MediaProviderAttemptsTest {
    @TestCase
    public func attemptJsonIsStructuredAndRedacted(): Unit {
        let attempt = MediaProviderAttempt(
            "openai-images",
            "openai-images",
            Failed,
            capability: "image.generate",
            endpointClass: "openai-public",
            requestUrlRedacted: "https://api.openai.com/v1/images/generations?token=secret",
            errorCode: "provider_error",
            message: "Authorization Bearer secret"
        )

        let json = mediaProviderAttemptToJson(attempt)
        @Expect(json.contains("openai-images"), true)
        @Expect(json.contains("secret"), false)
        @Expect(json.contains("provider_error"), true)
    }

    @TestCase
    public func summaryCarriesLastErrorAndAttemptList(): Unit {
        let summary = summarizeMediaProviderAttempts([
            MediaProviderAttempt("p1", "k1", Skipped, errorCode: "unsupported_capability", message: "not supported"),
            MediaProviderAttempt("p2", "k2", Failed, errorCode: "timeout", message: "request timed out token=secret")
        ])
        let obj = JsonValue.fromStr(summary).asObject()
        @Expect(obj.get("ok").getOrThrow().asBool().getValue(), false)
        @Expect(obj.get("lastErrorCode").getOrThrow().asString().getValue(), "timeout")
        @Expect(summary.contains("secret"), false)
    }
}
