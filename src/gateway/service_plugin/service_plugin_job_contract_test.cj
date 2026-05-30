package metis.gateway.service_plugin

import std.fs.{File, Path}
import std.unittest.testmacro.*

@Test
public class ServicePluginJobContractTest {
    private func fixture(name: String): String {
        String.fromUtf8(File.readFrom(Path("test").join("fixtures").join("service_plugin").join("job_protocol").join(name))).trimAscii()
    }

    @TestCase
    public func jobProtocolFixturesDecodeAndValidateAsyncScanLifecycle(): Unit {
        let doc = String.fromUtf8(File.readFrom(Path("docs").join("service-plugin-job-protocol.md")))
        @Expect(doc.contains("accepted -> running -> progress* -> completed|failed|cancelled|expired"), true)
        @Expect(doc.contains("raw JSON"), true)

        let startFrame = decodeServiceFrame(this.fixture("scan_start_async_request.jsonl"))
        @Expect(startFrame.ok, true)
        let start = parseServicePluginJobStartPayload(startFrame.frame.payload)
        @Expect(start.ok, true)
        @Expect(start.payload.mode, "async")
        @Expect(start.payload.jobId, "gcm-scan-20260530-095017-0001")
        @Expect(start.payload.deliveryTarget.channel, "telegram")
        @Expect(start.payload.deliveryTarget.peerId, "internal-peer-24")

        let acceptedFrame = decodeServiceFrame(this.fixture("scan_accepted_response.jsonl"))
        @Expect(acceptedFrame.ok, true)
        let accepted = parseServicePluginJobAcceptedPayload(acceptedFrame.frame.payload, expectedJobId: start.payload.jobId)
        @Expect(accepted.ok, true)
        @Expect(accepted.payload.status, "accepted")
        @Expect(accepted.payload.jobId, start.payload.jobId)

        let completedFrame = decodeServiceFrame(this.fixture("scan_completed_event.jsonl"))
        @Expect(completedFrame.ok, true)
        let completed = parseServicePluginJobEventPayload(completedFrame.frame.capabilityId, completedFrame.frame.payload)
        @Expect(completed.ok, true)
        @Expect(completed.payload.status, "completed")
        @Expect(completed.payload.accepted, 12)

        let failedFrame = decodeServiceFrame(this.fixture("scan_failed_event.jsonl"))
        @Expect(failedFrame.ok, true)
        let failed = parseServicePluginJobEventPayload(failedFrame.frame.capabilityId, failedFrame.frame.payload)
        @Expect(failed.ok, true)
        @Expect(failed.payload.status, "failed")
        @Expect(failed.payload.errorKind, "gitcode_timeout")
    }

    @TestCase
    public func jobPayloadValidationRejectsInvalidFieldsAndMismatchedCapability(): Unit {
        let missingJob = parseServicePluginJobStartPayload("{\"ok\":true,\"mode\":\"async\",\"jobId\":\"\",\"idempotencyKey\":\"k\",\"deliveryTarget\":{\"channel\":\"telegram\",\"accountId\":\"a\",\"peerId\":\"p\"}}")
        @Expect(missingJob.ok, false)
        @Expect(missingJob.status, "job_payload_invalid")

        let badPeerType = parseServicePluginJobStartPayload("{\"ok\":true,\"mode\":\"async\",\"jobId\":\"j\",\"idempotencyKey\":\"k\",\"deliveryTarget\":{\"channel\":\"telegram\",\"accountId\":\"a\",\"peerId\":42}}")
        @Expect(badPeerType.ok, false)
        @Expect(badPeerType.diagnostic.contains("peerId"), true)

        var longJob = ""
        for (_ in 0..129) { longJob += "x" }
        let tooLong = parseServicePluginJobAcceptedPayload("{\"ok\":true,\"status\":\"accepted\",\"jobId\":\"${longJob}\"}")
        @Expect(tooLong.ok, false)
        @Expect(tooLong.status, "job_payload_invalid")

        let mismatch = parseServicePluginJobEventPayload("gitcode.monitor.scan_failed", "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"j\"}")
        @Expect(mismatch.ok, false)
        @Expect(mismatch.status, "event_payload_invalid")

        let diagnostic = parseServicePluginJobEventPayload("gitcode.monitor.scan_failed", "{\"ok\":false,\"status\":\"failed\",\"jobId\":\"j\",\"diagnostic\":\"/Users/name/private token=secret\"}")
        @Expect(diagnostic.ok, true)
        let message = renderServicePluginJobEventMessage(diagnostic.payload)
        @Expect(message.contains("secret"), false)
        @Expect(message.contains("/Users/"), false)
    }
}
