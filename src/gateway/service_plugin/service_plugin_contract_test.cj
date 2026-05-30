package metis.gateway.service_plugin

import std.collection.ArrayList
import std.fs.{File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*

@Test
public class ServicePluginContractTest {
    private func stdioProtocolFixturePath(name: String): Path {
        Path("test").join("fixtures").join("service_plugin").join("stdio_protocol").join(name)
    }

    private func readStdioProtocolFixture(name: String): String {
        String.fromUtf8(File.readFrom(this.stdioProtocolFixturePath(name)))
    }

    private func repeatText(text: String, count: Int64): String {
        var out = ""
        for (_ in 0..count) {
            out += text
        }
        out
    }

    @TestCase
    public func servicePluginStdioProtocolFixturesDecodeGoldenFrames(): Unit {
        let docPath = Path("docs").join("service-plugin-stdio-protocol.md")
        @Expect(exists(docPath), true)
        let doc = String.fromUtf8(File.readFrom(docPath))
        @Expect(doc.contains("stdout_protocol_violation"), true)
        @Expect(doc.contains("payload_invalid"), true)

        let initLine = this.readStdioProtocolFixture("valid_initialize.jsonl").trimAscii()
        let initDecoded = decodeServiceFrame(initLine)
        @Expect(initDecoded.ok, true)
        @Expect(initDecoded.frame.frameType, "response")
        @Expect(initDecoded.frame.serviceId, "gitcode-monitor")
        @Expect(initDecoded.frame.method, "initialize")

        let scanLine = this.readStdioProtocolFixture("valid_scan_response.jsonl").trimAscii()
        let scanDecoded = decodeServiceFrame(scanLine)
        @Expect(scanDecoded.ok, true)
        @Expect(scanDecoded.frame.frameType, "response")
        @Expect(scanDecoded.frame.method, "invokeCapability")
        @Expect(scanDecoded.frame.capabilityId, "gitcode.monitor.scan_once")
        @Expect(scanDecoded.frame.correlationId, "corr-scan-1")

        let noisyLines = this.readStdioProtocolFixture("noisy_stdout_before_response.txt").trimAscii().split("\n")
        @Expect(noisyLines.size, 3)
        @Expect(decodeServiceFrame(noisyLines[0]).ok, true)
        @Expect(decodeServiceFrame(noisyLines[1]).ok, false)
        @Expect(decodeServiceFrame(noisyLines[2]).ok, true)

        for (name in ["valid_initialize.jsonl", "valid_scan_response.jsonl", "noisy_stdout_before_response.txt"]) {
            let raw = this.readStdioProtocolFixture(name)
            @Expect(raw.contains("Authorization"), false)
            @Expect(raw.contains("token"), false)
            @Expect(raw.contains("cookie"), false)
            @Expect(raw.contains("/Users/"), false)
        }
        let oversized = "{\"type\":\"response\",\"frameId\":\"huge\",\"serviceId\":\"gitcode-monitor\",\"payload\":\"${this.repeatText("x", 65537)}\"}"
        @Expect(decodeServiceFrame(oversized).errorKind, "frame_too_large")
    }

    @TestCase
    public func parseServicePluginManifestValidMinimal(): Unit {
        let raw = "{\"schema\":\"metis.servicePlugin.v1\",\"pluginId\":\"sample\",\"kind\":\"service\",\"protocolVersion\":\"1.0\",\"entry\":{\"command\":\"sample-plugin\",\"args\":[\"stdio\"]},\"configSchema\":{\"type\":\"object\"},\"capabilityDeclarations\":[{\"capabilityId\":\"release.monitor.scan\",\"kind\":\"controlAction\"}]}"
        let result = parseServicePluginManifest(raw)
        @Expect(result.ok, true)
        @Expect(result.manifest.pluginId, "sample")
        @Expect(result.manifest.kind, "service")
        @Expect(result.manifest.capabilityDeclarations[0].capabilityId, "release.monitor.scan")
    }

    @TestCase
    public func validateServicePluginManifestRequiresCoreFields(): Unit {
        let result = parseServicePluginManifest("{\"schema\":\"metis.servicePlugin.v1\",\"kind\":\"channel\"}")
        @Expect(result.ok, false)
        @Expect(result.status, "setup-required")
        @Expect(result.diagnostics.size > 0, true)
        @Expect(result.diagnostics.contains("missing field: pluginId"), true)
        @Expect(result.diagnostics.contains("kind must be service"), true)
    }

    @TestCase
    public func loadServicePluginManifestReportsMissingFile(): Unit {
        let result = loadServicePluginManifest("/tmp/metis-missing-service-plugin-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.json")
        @Expect(result.ok, false)
        @Expect(result.errorKind, "manifest_missing")
        @Expect(result.status, "setup-required")
    }

    @TestCase
    public func manifestRejectsSecretsAndLocalPaths(): Unit {
        let token = parseServicePluginManifest("{\"schema\":\"metis.servicePlugin.v1\",\"pluginId\":\"sample\",\"kind\":\"service\",\"protocolVersion\":\"1.0\",\"entry\":{\"command\":\"sample\"},\"configSchema\":{},\"capabilityDeclarations\":[],\"token\":\"secret\"}")
        @Expect(token.ok, false)
        @Expect(token.errorKind, "manifest_contains_secret")
        let path = parseServicePluginManifest("{\"schema\":\"metis.servicePlugin.v1\",\"pluginId\":\"sample\",\"kind\":\"service\",\"protocolVersion\":\"1.0\",\"entry\":{\"command\":\"/Users/name/plugin\"},\"configSchema\":{},\"capabilityDeclarations\":[]}")
        @Expect(path.ok, false)
        @Expect(path.errorKind, "manifest_contains_secret")
    }

    @TestCase
    public func validateCapabilityRecordAcceptsUnknownBusinessIdKnownKind(): Unit {
        let record = ServiceCapabilityRecord("release.monitor.scan", "controlAction", requiredHostApis: ["host.audit.append"])
        let validation = validateCapabilityRecord(record)
        @Expect(validation.ok, true)
        @Expect(record.capabilityId.startsWith("gitcode."), false)
    }

    @TestCase
    public func registerServiceCapabilitiesRejectsDuplicateAndUnknownKind(): Unit {
        let records = ArrayList<ServiceCapabilityRecord>()
        records.add(ServiceCapabilityRecord("release.monitor.scan", "controlAction"))
        records.add(ServiceCapabilityRecord("release.monitor.scan", "controlAction"))
        records.add(ServiceCapabilityRecord("release.event.accepted", "unknownKind"))
        let result = registerServiceCapabilities("release-monitor", records)
        @Expect(result.ok, false)
        @Expect(result.accepted.size, 1)
        @Expect(result.conflicts[0], "release.monitor.scan")
        @Expect(result.diagnostics[0].contains("unsupported kind"), true)
    }

    @TestCase
    public func encodeDecodeServiceFrameRoundTripAndCorrelation(): Unit {
        let frame = ServiceFrame("request", "frame-1", "sample", method: "invokeCapability", capabilityId: "release.monitor.scan", correlationId: "corr-1", payload: "{\"dryRun\":true}")
        let encoded = encodeServiceFrame(frame)
        @Expect(encoded.contains("\n"), true)
        let decoded = decodeServiceFrame(encoded.trimAscii())
        @Expect(decoded.ok, true)
        @Expect(decoded.frame.frameType, "request")
        @Expect(decoded.frame.capabilityId, "release.monitor.scan")
        let pending = PendingFrameStore()
        pending.add("corr-1")
        @Expect(correlateServiceFrame(decoded.frame, pending).matched, true)
        @Expect(correlateServiceFrame(decoded.frame, pending).errorKind, "correlation_unknown")
    }

    @TestCase
    public func decodeServiceFrameRejectsMalformedMissingOversizedAndUnknownMethod(): Unit {
        @Expect(decodeServiceFrame("{not-json").errorKind, "invalid_json")
        @Expect(decodeServiceFrame("{\"type\":\"request\",\"serviceId\":\"sample\"}").diagnostic.contains("frameId"), true)
        @Expect(decodeServiceFrame("{\"type\":\"request\",\"frameId\":\"f\",\"serviceId\":\"sample\",\"method\":\"unknown\"}").errorKind, "unknown_method")
        @Expect(decodeServiceFrame("{\"type\":\"request\",\"frameId\":\"f\",\"serviceId\":\"sample\"}\n{\"type\":\"event\"}").errorKind, "multiline_frame")
        @Expect(decodeServiceFrame("0123456789", maxBytes: 4).errorKind, "frame_too_large")
    }

    @TestCase
    public func redactServicePayloadMasksSecretsLocalPathsAndHandlesUnicodeLimit(): Unit {
        let secret = redactServicePayload("{\"Authorization\":\"Bearer secret\",\"path\":\"/Users/name/work\"}")
        @Expect(secret.text.contains("secret"), false)
        @Expect(secret.text.contains("/Users/name"), false)
        @Expect(secret.rawHash.startsWith("payload-"), true)
        let unicode = redactServicePayload("仓颉abcdef", policy: RedactionPolicy(maxPayloadBytes: 2))
        @Expect(unicode.truncated, true)
        @Expect(unicode.text.contains("仓颉"), true)
    }

    @TestCase
    public func parseServicePluginPayloadStatusCoversJsonAndTextStates(): Unit {
        let compact = parseServicePluginPayloadStatus("{\"ok\":true,\"status\":\"ok\"}")
        @Expect(compact.parsed, true)
        @Expect(compact.okPresent, true)
        @Expect(compact.ok, true)
        @Expect(compact.status, "ok")
        @Expect(compact.diagnostic, "")
        @Expect(compact.payloadKind, "json_object")

        let formatted = parseServicePluginPayloadStatus("{ \"ok\": true, \"status\": \"ok\" }")
        @Expect(formatted.parsed, true)
        @Expect(formatted.okPresent, true)
        @Expect(formatted.ok, true)
        @Expect(formatted.status, "ok")
        @Expect(formatted.diagnostic, "")
        @Expect(formatted.payloadKind, "json_object")

        let failed = parseServicePluginPayloadStatus("{ \"ok\": false, \"status\": \"runtime_required\", \"diagnostic\": \"runtime missing\" }")
        @Expect(failed.parsed, true)
        @Expect(failed.okPresent, true)
        @Expect(failed.ok, false)
        @Expect(failed.status, "runtime_required")
        @Expect(failed.diagnostic, "runtime missing")
        @Expect(failed.payloadKind, "json_object")

        let invalidOk = parseServicePluginPayloadStatus("{ \"ok\": \"true\", \"status\": \"ok\" }")
        @Expect(invalidOk.parsed, true)
        @Expect(invalidOk.okPresent, true)
        @Expect(invalidOk.ok, false)
        @Expect(invalidOk.status, "invalid_payload")
        @Expect(invalidOk.diagnostic.contains("ok field must be boolean"), true)
        @Expect(invalidOk.payloadKind, "json_object")

        let plain = parseServicePluginPayloadStatus("not json")
        @Expect(plain.parsed, false)
        @Expect(plain.okPresent, false)
        @Expect(plain.ok, false)
        @Expect(plain.status, "invalid_payload")
        @Expect(plain.diagnostic.contains("not valid JSON"), true)
        @Expect(plain.payloadKind, "plain_text")

        let missingStatus = parseServicePluginPayloadStatus("{ \"ok\": true }")
        @Expect(missingStatus.parsed, true)
        @Expect(missingStatus.okPresent, true)
        @Expect(missingStatus.ok, true)
        @Expect(missingStatus.status, "ok")
        @Expect(missingStatus.diagnostic.contains("missing field: status"), true)
        @Expect(missingStatus.payloadKind, "json_object")
    }

    @TestCase
    public func validateResponseRequiresExpectedResponseFrame(): Unit {
        let notResponse = validateServicePluginResponseFrame(
            ServiceFrame("request", "f", "sample", method: "invokeCapability", capabilityId: "sample.monitor.status", correlationId: "corr-1"),
            "sample",
            "invokeCapability",
            expectedCapabilityId: "sample.monitor.status",
            expectedCorrelationId: "corr-1"
        )
        @Expect(notResponse.ok, false)
        @Expect(notResponse.status, "unexpected_frame")

        let wrongCorrelation = validateServicePluginResponseFrame(
            ServiceFrame("response", "f", "sample", method: "invokeCapability", capabilityId: "sample.monitor.status", correlationId: "corr-other"),
            "sample",
            "invokeCapability",
            expectedCapabilityId: "sample.monitor.status",
            expectedCorrelationId: "corr-1"
        )
        @Expect(wrongCorrelation.ok, false)
        @Expect(wrongCorrelation.status, "correlation_mismatch")

        let wrongCapability = validateServicePluginResponseFrame(
            ServiceFrame("response", "f", "sample", method: "invokeCapability", capabilityId: "sample.monitor.other", correlationId: "corr-1"),
            "sample",
            "invokeCapability",
            expectedCapabilityId: "sample.monitor.status",
            expectedCorrelationId: "corr-1"
        )
        @Expect(wrongCapability.ok, false)
        @Expect(wrongCapability.status, "unexpected_frame")

        let ok = validateServicePluginResponseFrame(
            ServiceFrame("response", "f", "sample", method: "invokeCapability", capabilityId: "sample.monitor.status", correlationId: "corr-1"),
            "sample",
            "invokeCapability",
            expectedCapabilityId: "sample.monitor.status",
            expectedCorrelationId: "corr-1"
        )
        @Expect(ok.ok, true)
        @Expect(ok.status, "ok")
    }

    @TestCase
    public func validatePayloadObjectRequiresOkStatusAndDiagnosticTypes(): Unit {
        let ok = validateServicePluginPayloadObject("{\"ok\":true,\"status\":\"ok\",\"accepted\":0}")
        @Expect(ok.ok, true)
        @Expect(ok.status, "ok")

        let stringOk = validateServicePluginPayloadObject("{\"ok\":\"true\",\"status\":\"ok\"}")
        @Expect(stringOk.ok, false)
        @Expect(stringOk.status, "payload_invalid")
        @Expect(stringOk.diagnostic.contains("ok field must be boolean"), true)

        let nonObject = validateServicePluginPayloadObject("\"ok\"")
        @Expect(nonObject.ok, false)
        @Expect(nonObject.status, "payload_invalid")
        @Expect(nonObject.diagnostic.contains("JSON object"), true)

        let missingStatus = validateServicePluginPayloadObject("{\"ok\":true}")
        @Expect(missingStatus.ok, false)
        @Expect(missingStatus.status, "payload_invalid")
        @Expect(missingStatus.diagnostic.contains("missing field: status"), true)

        let badDiagnostic = validateServicePluginPayloadObject("{\"ok\":false,\"status\":\"failed\",\"diagnostic\":false}")
        @Expect(badDiagnostic.ok, false)
        @Expect(badDiagnostic.status, "payload_invalid")
        @Expect(badDiagnostic.diagnostic.contains("diagnostic field must be string"), true)

        let oversized = validateServicePluginPayloadObject("{\"ok\":true,\"status\":\"ok\",\"diagnostic\":\"${this.repeatText("x", 4097)}\"}")
        @Expect(oversized.ok, false)
        @Expect(oversized.status, "payload_invalid")
        @Expect(oversized.diagnostic.contains("diagnostic field too large"), true)
    }

    @TestCase
    public func enforceServiceFrameLimitsAcceptsBoundaryAndRejectsOversizedPayload(): Unit {
        let frame = ServiceFrame("event", "f", "sample", capabilityId: "release.event.accepted", payload: "12345")
        @Expect(enforceServiceFrameLimits(frame, limits: ServiceFrameLimits(maxPayloadBytes: 5)).ok, true)
        let tooLarge = enforceServiceFrameLimits(frame, limits: ServiceFrameLimits(maxPayloadBytes: 4))
        @Expect(tooLarge.ok, false)
        @Expect(tooLarge.reason, "payload_too_large")
        @Expect(tooLarge.payloadHash.startsWith("payload-"), true)
    }
}
