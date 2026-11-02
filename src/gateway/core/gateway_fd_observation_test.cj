package metis.gateway.core

import metis.process.ProcessFdSnapshot
import metis.core.config.{CliConfig, CliSettingManager}
import metis.gateway.logging.{gatewayLoggingResetForTest, gatewayLogEventIsKnown}
import std.env.{getVariable, setVariable, removeVariable}
import std.fs.{Directory, File, remove}
import std.sync.AtomicInt64
import std.time.MonoTime
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue

@Test
public class GatewayFdObservationTest {
    @TestCase
    public func fdS2P3PersistenceTransitionsCarryRegisteredFdEvidence(): Unit {
        let home = Directory.createTemp("/tmp")
        let keys = ["METIS_HOME", "METIS_LOG_FILE", "METIS_LOG_LEVEL", "METIS_CONSOLE_LEVEL"]
        let previous = keys.map({ key => getVariable(key) })
        let file = home.join("owned.jsonl")
        try {
            setVariable("METIS_HOME", home.toString())
            setVariable("METIS_LOG_FILE", file.toString())
            setVariable("METIS_LOG_LEVEL", "info")
            setVariable("METIS_CONSOLE_LEVEL", "silent")
            CliConfig.invalidatePathCache()
            CliSettingManager.invalidate()
            gatewayLoggingResetForTest()
            resetGatewayChannelRuntimeObservationForTest()
            setGatewayFdSnapshotProviderForTest(Some({ => ProcessFdSnapshot("ok", fdCount: 20, fdLimit: 64) }))
            for (_ in 0..1000) {
                gatewayChannelRuntimeReportPersistenceOutcome("owned", "中文😀account",
                    GatewayChannelRuntimeObservationResult(false, "state_write_failed"))
            }
            gatewayChannelRuntimeReportPersistenceOutcome("owned", "中文😀account",
                GatewayChannelRuntimeObservationResult(true, "ok"))
            let text = try { String.fromUtf8(File.readFrom(file)) }
                catch (_: Exception) { throw Exception("owned_log_encoding_failed") }
            let lines = text.trimAscii().split("\n")
            @Expect(lines.size, 2)
            for (index in 0..lines.size) {
                let row = JsonValue.fromStr(lines[index]).asObject()
                let event = row.get("event").getOrThrow().asString().getValue()
                @Expect(gatewayLogEventIsKnown(event), true)
                @Expect(event, if (index == 0) { "channel.runtime.persistence.degraded" } else { "channel.runtime.persistence.recovered" })
                let fd = row.get("fdObservation").getOrThrow().asObject()
                @Expect(fd.get("fdCount").getOrThrow().asInt().getValue(), 20)
                @Expect(fd.get("fdLimit").getOrThrow().asInt().getValue(), 64)
            }
            @Expect(text.contains("中文😀account"), false)
        } finally {
            resetGatewayChannelRuntimeObservationForTest()
            setGatewayFdSnapshotProviderForTest(None)
            for (index in 0..keys.size) {
                match (previous[index]) {
                    case Some(value) => setVariable(keys[index], value)
                    case None => removeVariable(keys[index])
                }
            }
            CliConfig.invalidatePathCache()
            CliSettingManager.invalidate()
            gatewayLoggingResetForTest()
            remove(home, recursive: true)
        }
    }

    @TestCase
    public func fdS2U1SnapshotMetadataIsCachedWithoutPayload(): Unit {
        let samples = AtomicInt64(0)
        setGatewayFdSnapshotProviderForTest(Some({ =>
            samples.fetchAdd(1)
            ProcessFdSnapshot("ok", fdCount: 20, fdLimit: 64, vnodeCount: 7,
                socketCount: 4, pipeCount: 3, otherCount: 6)
        }))
        try {
            let started = MonoTime.now()
            for (_ in 0..1000) {
                let row = gatewayObserveFdPressure("中文😀不应记录/Users/synthetic/private")
                @Expect(row.get("fdCount").getOrThrow().asInt().getValue(), 20)
                @Expect(row.toJsonString().contains("synthetic"), false)
            }
            let elapsedSeconds = (MonoTime.now() - started).toMilliseconds() / 1000
            @Expect(samples.load() <= elapsedSeconds + 1, true)
        } finally { setGatewayFdSnapshotProviderForTest(None) }
    }

    @TestCase
    public func fdS2N1ProbeFailureCannotEscapeOrBecomeZero(): Unit {
        setGatewayFdSnapshotProviderForTest(Some({ => throw Exception("synthetic-secret 中文😀") }))
        try {
            let row = gatewayObserveFdPressure("persist")
            @Expect(row.get("fdStatus").getOrThrow().asString().getValue(), "probe_failed")
            @Expect(row.get("fdCount").getOrThrow().asInt().getValue(), -1)
            @Expect(row.get("fdVnodeCount").getOrThrow().asInt().getValue(), -1)
            @Expect(row.get("fdSocketCount").getOrThrow().asInt().getValue(), -1)
            @Expect(row.get("fdPipeCount").getOrThrow().asInt().getValue(), -1)
            @Expect(row.get("fdOtherCount").getOrThrow().asInt().getValue(), -1)
            @Expect(row.toJsonString().contains("synthetic-secret"), false)
        } finally { setGatewayFdSnapshotProviderForTest(None) }
    }

    @TestCase
    public func fdS2B1UntrustedStatusIsNeverEchoed(): Unit {
        setGatewayFdSnapshotProviderForTest(Some({ => ProcessFdSnapshot("中文😀synthetic-secret") }))
        try {
            let row = gatewayObserveFdPressure("persist")
            @Expect(row.get("fdStatus").getOrThrow().asString().getValue(), "probe_failed")
            @Expect(row.toJsonString().contains("synthetic-secret"), false)
        } finally { setGatewayFdSnapshotProviderForTest(None) }
    }
}
