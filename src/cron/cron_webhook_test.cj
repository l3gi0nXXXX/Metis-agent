package metis.cron

import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString}

private func cronWebhookTestBody(): JsonObject {
    let body = JsonObject()
    body.put("jobId", JsonString("job-webhook"))
    body.put("status", JsonString("ok"))
    body
}

@Test
public class CronWebhookUrlGuardTest {
    @TestCase
    public func rejectsUnsafeWebhookUrlsWithoutNetwork(): Unit {
        @Expect(validateCronWebhookUrl("").errorKind, "empty_url")
        @Expect(validateCronWebhookUrl("ftp://example.com/hook").errorKind, "unsupported_scheme")
        @Expect(validateCronWebhookUrl("http://127.0.0.1:8080/hook").errorKind, "private_ip")
        @Expect(validateCronWebhookUrl("http://169.254.169.254/latest/meta-data").errorKind, "private_ip")
        @Expect(validateCronWebhookUrl("http://localhost/hook").errorKind, "localhost")
        @Expect(validateCronWebhookUrl("https://user:secret@example.com/hook").errorKind, "userinfo_not_allowed")
    }

    @TestCase
    public func acceptsPublicHttpWebhookUrl(): Unit {
        let decision = validateCronWebhookUrl("https://example.com/hooks/cron?token=secret")
        @Expect(decision.ok, true)
        @Expect(decision.normalizedUrl, "https://example.com/hooks/cron?token=secret")
        @Expect(decision.redactedUrl.contains("secret"), false)
    }
}

@Test
public class CronWebhookPostTest {
    @TestCase
    public func postUsesFakeRunnerTimeoutAndTlsVerify(): Unit {
        let captured = JsonObject()
        setCronWebhookHttpRunnerForTest(Some({ request: CronWebhookHttpRequest =>
            captured.put("called", JsonBool(true))
            captured.put("timeoutMs", JsonInt(request.timeoutMs))
            captured.put("verifyTls", JsonBool(request.verifyTls))
            captured.put("jobId", request.body.get("jobId").getOrThrow())
            CronWebhookHttpResponse(true, statusCode: 200)
        }))
        try {
            let ok = postCronWebhookJson("https://example.com/hook", cronWebhookTestBody(), timeoutMs: 25)
            @Expect(ok, true)
            @Expect(captured.get("called").getOrThrow().asBool().getValue(), true)
            @Expect(captured.get("timeoutMs").getOrThrow().asInt().getValue(), 1000)
            @Expect(captured.get("verifyTls").getOrThrow().asBool().getValue(), true)
            @Expect(captured.get("jobId").getOrThrow().asString().getValue(), "job-webhook")
        } finally {
            setCronWebhookHttpRunnerForTest(None<(CronWebhookHttpRequest) -> CronWebhookHttpResponse>)
        }
    }

    @TestCase
    public func unsafeUrlDoesNotCallRunner(): Unit {
        let captured = JsonObject()
        setCronWebhookHttpRunnerForTest(Some({ _request: CronWebhookHttpRequest =>
            captured.put("called", JsonBool(true))
            CronWebhookHttpResponse(true, statusCode: 200)
        }))
        try {
            let ok = postCronWebhookJson("http://127.0.0.1:8080/hook", cronWebhookTestBody(), timeoutMs: 5000)
            @Expect(ok, false)
            @Expect(captured.get("called").isNone(), true)
        } finally {
            setCronWebhookHttpRunnerForTest(None<(CronWebhookHttpRequest) -> CronWebhookHttpResponse>)
        }
    }
}

@Test
public class CronWebhookRedactionTest {
    @TestCase
    public func redactedUrlDoesNotExposeUserinfoTokenOrQuery(): Unit {
        let redacted = redactCronWebhookUrlForLog("https://user:secret@example.com/hook/token-123?access_token=abc")
        @Expect(redacted.contains("user"), false)
        @Expect(redacted.contains("secret"), false)
        @Expect(redacted.contains("token-123"), false)
        @Expect(redacted.contains("access_token"), false)
        @Expect(redacted.contains("abc"), false)
    }

    @TestCase
    public func timeoutClampMatchesCronPolicy(): Unit {
        @Expect(cronWebhookTimeoutMs(0), 30000)
        @Expect(cronWebhookTimeoutMs(999), 1000)
        @Expect(cronWebhookTimeoutMs(5000), 5000)
        @Expect(cronWebhookTimeoutMs(121000), 120000)
    }
}
