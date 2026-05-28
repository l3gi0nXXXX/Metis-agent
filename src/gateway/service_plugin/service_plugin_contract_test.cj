package metis.gateway.service_plugin

import std.collection.ArrayList
import std.fs.{File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*

@Test
public class ServicePluginContractTest {
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
    public func enforceServiceFrameLimitsAcceptsBoundaryAndRejectsOversizedPayload(): Unit {
        let frame = ServiceFrame("event", "f", "sample", capabilityId: "release.event.accepted", payload: "12345")
        @Expect(enforceServiceFrameLimits(frame, limits: ServiceFrameLimits(maxPayloadBytes: 5)).ok, true)
        let tooLarge = enforceServiceFrameLimits(frame, limits: ServiceFrameLimits(maxPayloadBytes: 4))
        @Expect(tooLarge.ok, false)
        @Expect(tooLarge.reason, "payload_too_large")
        @Expect(tooLarge.payloadHash.startsWith("payload-"), true)
    }
}
