package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, MetisProcessEnvironmentLock}
import metis.gateway.config.buildGatewayConfigFromUserSettings
import metis.core.config.GatewayUserSettings
import metis.gateway.core.{resetGatewayChannelRuntimeObservationForTest, setGatewayChannelRuntimeDiagnosticForTest}
import std.env.{getVariable, setVariable, removeVariable}
import std.fs.{Directory, File, Path, remove}
import std.sync.AtomicInt64
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue

private func heartbeatPersistenceHome(block: () -> Unit): Unit {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Directory.createTemp("/tmp")
        let keys = ["METIS_HOME", "METIS_LOG_FILE", "METIS_CONSOLE_LEVEL"]
        let previous = keys.map({ key => getVariable(key) })
        try {
            setVariable("METIS_HOME", home.toString())
            setVariable("METIS_LOG_FILE", home.join("owned.jsonl").toString())
            setVariable("METIS_CONSOLE_LEVEL", "silent")
            CliConfig.invalidatePathCache()
            CliSettingManager.invalidate()
            block()
        } finally {
            setGatewayPlatformHeartbeatWriterForTest(None)
            resetGatewayChannelRuntimeObservationForTest()
            for (index in 0..keys.size) {
                match (previous[index]) {
                    case Some(value) => setVariable(keys[index], value)
                    case None => removeVariable(keys[index])
                }
            }
            CliConfig.invalidatePathCache()
            CliSettingManager.invalidate()
            remove(home, recursive: true)
        }
    }
}

@Test
public class GatewayPlatformHeartbeatPersistenceTest {
    @TestCase
    public func fdS1U2HeartbeatWriterAndDiagnosticFailuresAreIsolated(): Unit {
        heartbeatPersistenceHome {
            let cfg = buildGatewayConfigFromUserSettings(GatewayUserSettings())
            File.writeTo(gatewayNodeRegistryPath(), "{}".toArray())
            File.writeTo(gatewayPlatformStatePath(), "{}".toArray())
            setGatewayPlatformHeartbeatWriterForTest(Some({ _, _ => throw Exception("owned-emfile 中文😀") }))
            setGatewayChannelRuntimeDiagnosticForTest(Some({ => throw Exception("owned-diagnostic") }))
            let outcome = gatewayPlatformTryHeartbeat(cfg)
            @Expect(outcome.persisted, false)
            @Expect(outcome.status, "state_write_failed")
            gatewayPlatformHeartbeat(cfg)
            @Expect(File.readFrom(gatewayNodeRegistryPath()), "{}".toArray())
            @Expect(File.readFrom(gatewayPlatformStatePath()), "{}".toArray())
        }
    }

    @TestCase
    public func fdS1U3HeartbeatRecoveryPreservesExistingDeviceAndRemoteNode(): Unit {
        heartbeatPersistenceHome {
            let cfg = buildGatewayConfigFromUserSettings(GatewayUserSettings())
            File.writeTo(gatewayNodeRegistryPath(),
                "{\"nodes\":{\"items\":[{\"id\":\"owned-remote\",\"kind\":\"remote\",\"denyCommands\":[\"中文😀\"]}]}}".toArray())
            File.writeTo(gatewayPlatformStatePath(),
                "{\"devices\":{\"sentinel\":\"中文😀\",\"items\":[]}}".toArray())
            let outcome = gatewayPlatformTryHeartbeat(cfg)
            @Expect(outcome.status, "ok")
            @Expect(outcome.persisted, true)
            let text = try { String.fromUtf8(File.readFrom(gatewayPlatformStatePath())) }
                catch (_: Exception) { throw Exception("owned_state_encoding_failed") }
            let platform = JsonValue.fromStr(text).asObject()
            @Expect(platform.get("devices").getOrThrow().asObject().get("sentinel").getOrThrow().asString().getValue(), "中文😀")
            let registryText = try { String.fromUtf8(File.readFrom(gatewayNodeRegistryPath())) }
                catch (_: Exception) { throw Exception("owned_state_encoding_failed") }
            @Expect(registryText.contains("owned-remote"), true)
            @Expect(registryText.contains("中文😀"), true)
        }
    }

    @TestCase
    public func fdS1B2InvalidHeartbeatStateNeverBecomesEmptyReplacement(): Unit {
        heartbeatPersistenceHome {
            let cfg = buildGatewayConfigFromUserSettings(GatewayUserSettings())
            let invalid: Array<Array<Byte>> = [[0xffu8], "{".toArray(),
                "{\"nodes\":{\"items\":[3]}}".toArray()]
            for (bytes in invalid) {
                File.writeTo(gatewayNodeRegistryPath(), bytes)
                File.writeTo(gatewayPlatformStatePath(), "{}".toArray())
                let outcome = gatewayPlatformTryHeartbeat(cfg)
                @Expect(outcome.persisted, false)
                @Expect(["invalid_response_encoding", "malformed_json"].contains(outcome.status), true)
                @Expect(File.readFrom(gatewayNodeRegistryPath()), bytes)
                @Expect(File.readFrom(gatewayPlatformStatePath()), "{}".toArray())
            }
            File.writeTo(gatewayNodeRegistryPath(), "{}".toArray())
            File.writeTo(gatewayPlatformStatePath(), [0xffu8])
            @Expect(gatewayPlatformTryHeartbeat(cfg).status, "invalid_response_encoding")
            @Expect(File.readFrom(gatewayNodeRegistryPath()), "{}".toArray())
            @Expect(File.readFrom(gatewayPlatformStatePath()), [0xffu8])
        }
    }

    @TestCase
    public func fdS1N3SecondHeartbeatWriteFailureCannotReportSuccess(): Unit {
        heartbeatPersistenceHome {
            let cfg = buildGatewayConfigFromUserSettings(GatewayUserSettings())
            File.writeTo(gatewayNodeRegistryPath(), "{}".toArray())
            File.writeTo(gatewayPlatformStatePath(), "{}".toArray())
            let writes = AtomicInt64(0)
            setGatewayPlatformHeartbeatWriterForTest(Some({ path: Path, bytes: Array<Byte> =>
                if (writes.fetchAdd(1) == 1) { throw Exception("owned-second-write-failure") }
                File.writeTo(path, bytes)
            }))
            @Expect(gatewayPlatformTryHeartbeat(cfg).status, "state_write_failed")
            @Expect(writes.load(), 2)
            @Expect(File.readFrom(gatewayPlatformStatePath()), "{}".toArray())
            setGatewayPlatformHeartbeatWriterForTest(None)
            @Expect(gatewayPlatformTryHeartbeat(cfg).persisted, true)
        }
    }
}
