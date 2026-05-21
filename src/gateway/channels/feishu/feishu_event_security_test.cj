package metis.gateway.channels.feishu

import std.unittest.testmacro.*

@Test
public class FeishuEventSecurityTest {
    @TestCase
    public func signatureUsesFeishuSha256Fixture(): Unit {
        let payload = "{\"token\":\"verify-token\",\"type\":\"event_callback\"}"
        let signature = feishuEventSecuritySignature(
            timestamp: "1700000000",
            nonce: "nonce-1",
            encryptKey: "encrypt-key",
            payload: payload
        )

        @Expect(signature, "fb7b0695533b0820ad45e2d83935127376072c2103d8c8abdd5396e880f4e58e")
    }

    @TestCase
    public func validTimestampTokenAndSignaturePass(): Unit {
        let payload = "{\"token\":\"verify-token\",\"type\":\"event_callback\"}"
        let result = feishuValidateEventSecurity(
            timestamp: "1700000000",
            nonce: "nonce-1",
            signature: "fb7b0695533b0820ad45e2d83935127376072c2103d8c8abdd5396e880f4e58e",
            payload: payload,
            verificationToken: "verify-token",
            encryptKey: "encrypt-key",
            requireSignature: true,
            maxSkewSeconds: 10,
            nowSeconds: 1700000001
        )

        @Expect(result.ok, true)
        @Expect(result.reason, "ok")
        @Expect(result.payload, payload)
    }

    @TestCase
    public func invalidTokenSignatureAndTimestampAreRejected(): Unit {
        let token = feishuValidateEventSecurity(
            timestamp: "1700000000",
            nonce: "nonce-1",
            signature: "",
            payload: "{\"token\":\"wrong-token\"}",
            verificationToken: "verify-token",
            encryptKey: "",
            requireSignature: false,
            maxSkewSeconds: 10,
            nowSeconds: 1700000001
        )
        @Expect(token.ok, false)
        @Expect(token.reason, "invalid_token")

        let signature = feishuValidateEventSecurity(
            timestamp: "1700000000",
            nonce: "nonce-1",
            signature: "bad-signature",
            payload: "{\"token\":\"verify-token\",\"type\":\"event_callback\"}",
            verificationToken: "verify-token",
            encryptKey: "encrypt-key",
            requireSignature: true,
            maxSkewSeconds: 10,
            nowSeconds: 1700000001
        )
        @Expect(signature.ok, false)
        @Expect(signature.reason, "invalid_signature")

        let timestamp = feishuValidateEventSecurity(
            timestamp: "1700000000",
            nonce: "nonce-1",
            signature: "",
            payload: "{\"token\":\"verify-token\"}",
            verificationToken: "verify-token",
            encryptKey: "",
            requireSignature: false,
            maxSkewSeconds: 10,
            nowSeconds: 1700001000
        )
        @Expect(timestamp.ok, false)
        @Expect(timestamp.reason, "timestamp_skew")
    }

    @TestCase
    public func encryptedPayloadReturnsTypedDiagnosticUntilAesDecryptIsAvailable(): Unit {
        let result = feishuValidateEventSecurity(
            timestamp: "1700000000",
            nonce: "nonce-1",
            signature: "",
            payload: "{\"encrypt\":\"ciphertext\"}",
            verificationToken: "",
            encryptKey: "encrypt-key",
            requireSignature: false,
            maxSkewSeconds: 10,
            nowSeconds: 1700000001
        )

        @Expect(result.ok, false)
        @Expect(result.reason, "encrypted_payload_unsupported")
        @Expect(result.error.contains("AES"), true)

        let decrypt = feishuDecryptEncryptedEventPayload(encryptKey: "encrypt-key", encryptedPayload: "ciphertext")
        @Expect(decrypt.ok, false)
        @Expect(decrypt.status, "unsupported")
        @Expect(decrypt.error.contains("AES"), true)
    }
}
