package metis.gateway.service_plugin

import std.unittest.testmacro.*

@Test
public class ServicePluginBackpressureDiagnosticTest {
    @TestCase
    public func bpS2B3CapacityDiagnosticsOnlyForwardBoundedNeutralFields(): Unit {
        let safe = "{\"limitKind\":\"owner_bytes\",\"queuedBytes\":4194304,\"regularQueued\":12,\"regularDispatchPending\":0,\"attemptedBytes\":1024}"
        let diagnostic = servicePluginCapacityDiagnostic(safe).getOrThrow()
        @Expect(diagnostic.get("limitKind").getOrThrow().asString().getValue(), "owner_bytes")
        @Expect(diagnostic.get("queuedBytes").getOrThrow().asInt().getValue(), 4194304)
        let extra = safe.replace("}", ",\"reason\":\"中文🙂 Authorization: Bearer synthetic-secret /private/synthetic/path\",\"payload\":\"synthetic-body\"}")
        let filtered = servicePluginCapacityDiagnostic(extra).getOrThrow().toJsonString()
        @Expect(filtered.contains("synthetic"), false)
        @Expect(filtered.contains("Authorization"), false)
        @Expect(filtered.contains("/private/"), false)
        @Expect(filtered.contains("中文"), false)
        @Expect(servicePluginCapacityDiagnostic(safe.replace("owner_bytes", "中文🙂synthetic-secret")).isNone(), true)
        @Expect(servicePluginCapacityDiagnostic(safe.replace("4194304", "-1")).isNone(), true)
        @Expect(servicePluginCapacityDiagnostic(safe.replace("4194304", "1099511627777")).isNone(), true)
        @Expect(servicePluginCapacityDiagnostic(safe.replace("4194304", "\"binary\\u0000\"")).isNone(), true)
        @Expect(servicePluginCapacityDiagnostic("{malformed").isNone(), true)
        @Expect(servicePluginCapacityDiagnostic("\u{0}\u{1}中文🙂").isNone(), true)
        let longText = StringBuilder()
        for (_ in 0..1024) { longText.append("中文🙂") }
        @Expect(servicePluginCapacityDiagnostic(longText.toString()).isNone(), true)
    }
}
