package metis.core.media_tests

import metis.core.*

import std.unittest.*

@Test
public class ProviderRequestPolicyTest {
    @TestCase
    public func redactsCredentialsFromUrlsAndMessages(): Unit {
        let url = "https://user:password@example.invalid/v1?api_key=secret&token=abc&Signature=sig"
        let redacted = redactProviderEndpoint(url)
        @Expect(redacted.contains("password"), false)
        @Expect(redacted.contains("secret"), false)
        @Expect(redacted.contains("abc"), false)
        @Expect(redacted.contains("sig"), false)
        @Expect(redacted.contains("[redacted]"), true)
    }

    @TestCase
    public func diagnosticsConstructorRedactsInputs(): Unit {
        let diagnostics = ProviderRequestDiagnostics(
            providerKind: "openai",
            model: "gpt-image-1",
            endpointClass: "openai-public",
            baseUrlRedacted: "https://api.openai.com/v1?api_key=secret",
            requestUrlRedacted: "https://api.openai.com/v1/images/generations?token=secret-token",
            message: "Authorization Bearer secret"
        )
        @Expect(diagnostics.baseUrlRedacted.contains("secret"), false)
        @Expect(diagnostics.requestUrlRedacted.contains("secret-token"), false)
        @Expect(diagnostics.message.contains("Bearer"), false)
    }
}
