package metis

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.process.{ManagedStdioOperationResult, managedStdioBroker, resetManagedStdioBrokerForTest, shutdownManagedStdioBroker}
import std.convert.Parsable
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.net.{IPSocketAddress, TcpServerSocket}
import std.process.executeWithOutput
import std.sync.AtomicInt64
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue

@Test
public class CliProgramLifecycleTest {
    @TestCase
    public func hrS3B1AllReturnAndThrowPathsCloseOnlyOwnedBroker(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
            let closes = AtomicInt64(0)
            for (code in [0, 2, 7]) {
                let returned = cliRunWithBrokerCleanup({ => code }, { => closes.fetchAdd(1); shutdownManagedStdioBroker() })
                @Expect(returned, code)
            }
            @Expect(closes.load(), 3)
            var thrown = false
            try {
                let _ = cliRunWithBrokerCleanup({ => throw Exception("primary-exception") }, { => closes.fetchAdd(1); shutdownManagedStdioBroker() })
            } catch (error: Exception) { thrown = error.message == "primary-exception" }
            @Expect(thrown, true)
            @Expect(closes.load(), 4)
            @Expect(shutdownManagedStdioBroker().generation, 0)
            let broker = managedStdioBroker()
            let ready = broker.ensureBrokerRunning(timeoutMs: 2000)
            @Expect(ready.ok, true)
            @Expect(cliRunWithBrokerCleanup({ => 0 }, { => shutdownManagedStdioBroker() }), 0)
            @Expect(broker.snapshot().running, false)
            @Expect(broker.snapshot().generation, ready.generation)
            @Expect(cliRunWithBrokerCleanup({ => 0 }, { => shutdownManagedStdioBroker() }), 0)
            @Expect(broker.snapshot().generation, ready.generation)
            @Expect(broker.snapshot().readerCount, 0)
            let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
        }
    }

    @TestCase
    public func hrS3N1CleanupFailurePreservesPrimaryFailure(): Unit {
        @Expect(cliRunWithBrokerCleanup({ => 0 }, { => ManagedStdioOperationResult(false, "broker_close_write_failed") }), 1)
        @Expect(cliRunWithBrokerCleanup({ => 7 }, { => ManagedStdioOperationResult(false, "broker_close_write_failed") }), 7)
        @Expect(cliRunWithBrokerCleanup({ => 8 }, { => throw Exception("cleanup-error") }), 8)
        var primary = false
        try {
            let _ = cliRunWithBrokerCleanup({ => throw Exception("primary-exception") }, { => throw Exception("cleanup-error") })
        } catch (error: Exception) { primary = error.message == "primary-exception" }
        @Expect(primary, true)
    }

    @TestCase
    public func hrS3P2ThirtyTwoShortLivedCommandsLeaveNoBroker(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let binary = Path(getVariable("METIS_TEST_BIN").getOrDefault({ => CliConfig.cwd.join("target/release/bin/metis").toString() }))
            @Expect(exists(binary), true)
            if (!exists(binary)) { return }
            let home = Path("/tmp/metis-hr-cli-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            let previous = getVariable("METIS_HOME")
            let previousMode = getVariable("METIS_STDIO_BROKER_TEST_MODE")
            let previousDiagnostics = getVariable("METIS_STDIO_BROKER_DIAGNOSTIC_MARKER")
            Directory.create(home, recursive: true)
            setVariable("METIS_STDIO_BROKER_TEST_MODE", "1")
            try {
                var observed: Int64 = 0
                for (index in 0..32) {
                    let round = home.join("${index}")
                    let diag = round.join("diagnostics")
                    Directory.create(diag, recursive: true)
                    setVariable("METIS_HOME", round.toString())
                    setVariable("METIS_STDIO_BROKER_DIAGNOSTIC_MARKER", diag.toString())
                    CliConfig.invalidatePathCache()
                    MetisConfigManager.invalidate()
                    CliSettingManager.invalidate()
                    var settings = CliSettingManager.readGatewaySettings()
                    try (socket = TcpServerSocket(bindAt: 0u16)) {
                        socket.bind()
                        settings.port = Int64((socket.localAddress as IPSocketAddress)?.port ?? 0u16)
                    }
                    settings.enabled = true
                    settings.servicePlugins = []
                    let _ = MetisConfigManager.setGatewaySettings(settings)
                    var roundObserved: Int64 = 0
                    for (command in ["stop", "status", "restart"]) {
                        if (command == "restart") { File.writeTo(round.join("metis.json"), "{".toArray()) }
                        let result = executeWithOutput(binary.toString(), ["gateway", command])
                        let stderr = try { String.fromUtf8(result[2]) } catch (_: Exception) { "invalid_response_encoding" }
                        @Expect(stderr.contains("protocol writer failed"), false)
                        @Expect(stderr == "invalid_response_encoding", false)
                        @Expect(result[0] == 0 || command == "restart", true)
                        if (exists(diag)) {
                            for (entry in Directory.readFrom(diag)) {
                                if (!entry.name.endsWith(".json")) { continue }
                                let row = JsonValue.fromStr(String.fromUtf8(File.readFrom(entry.path))).asObject()
                                if (let Some(value) <- row.get("brokerPid")) {
                                    observed += 1
                                    roundObserved += 1
                                    @Expect(row.get("writerFailureKind").getOrThrow().asString().getValue(), "")
                                    @Expect(row.get("closeAckCallbackSeen").getOrThrow().asBool().getValue(), true)
                                    let pid = value.asInt().getValue()
                                    @Expect(executeWithOutput("/bin/kill", ["-0", "${pid}"])[0] != 0, true)
                                }
                            }
                        }
                    }
                    @Expect(roundObserved > 0, true)
                }
                @Expect(observed > 0, true)
            } finally {
                setVariable("METIS_HOME", previous.getOrDefault({ => "" }))
                setVariable("METIS_STDIO_BROKER_TEST_MODE", previousMode.getOrDefault({ => "" }))
                setVariable("METIS_STDIO_BROKER_DIAGNOSTIC_MARKER", previousDiagnostics.getOrDefault({ => "" }))
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                remove(home, recursive: true)
                @Expect(exists(home), false)
            }
        }
    }
}
