package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.core.GatewayStopResult
import metis.gateway.service_plugin.{setServicePluginPidProbeCommandForTest, setServicePluginPortReleaseCommandForTest}
import metis.process.{ProcessInstanceIdentity, currentProcessInstanceIdentity, resetManagedStdioBrokerForTest}
import std.core.Duration
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, FileInfo, Path, exists, remove}
import std.net.{IPSocketAddress, TcpServerSocket}
import std.process.executeWithOutput
import std.sync.AtomicInt64
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*

func hrRuntimeHome(block: (Path, GatewayServeIdentity) -> Unit): Unit {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/tmp/metis-hr-runtime-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        let before = getVariable("METIS_HOME")
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home.toString())
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        var port: Int64 = 0
        try (socket = TcpServerSocket(bindAt: 0u16)) {
            socket.bind()
            port = Int64((socket.localAddress as IPSocketAddress)?.port ?? 0u16)
        }
        var settings = CliSettingManager.readGatewaySettings()
        settings.port = port
        let _ = MetisConfigManager.setGatewaySettings(settings)
        CliSettingManager.invalidate()
        setGatewayServePortProbeForTest(Some({ _, _ => (1, "", "") }))
        setServicePluginPidProbeCommandForTest(Some({ _, _ => (1, "", "No such process") }))
        setServicePluginPortReleaseCommandForTest(Some({ _, _, _ => (1, "", "") }))
        let current = currentProcessInstanceIdentity().getOrThrow()
        let identity = GatewayServeIdentity(987654321, 1000, "历史恢复-测试🧪",
            processIdentity: Some(ProcessInstanceIdentity(current.platform, 987654321)))
        try { block(home, identity) } finally {
            gatewayReleaseServeLockQuiet()
            let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
            setGatewayServePortProbeForTest(None)
            setServicePluginPidProbeCommandForTest(None)
            setServicePluginPortReleaseCommandForTest(None)
            setGatewayStopOutputForTest(None)
            setVariable("METIS_HOME", before.getOrDefault({ => "" }))
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            remove(home, recursive: true)
            @Expect(exists(home), false)
        }
    }
}

func hrRuntimeWriteMarker(identity: GatewayServeIdentity, legacy!: Bool = true,
    broker!: String = "broker_close_exit_nonzero", terminal!: Bool = true): String {
    let stop = GatewayStopResult(false, "cleanup_pending", inboundStatus: "stopped", compatStatus: "stopped",
        sidecarStatus: "disabled", servicePluginIngressStatus: "sent", servicePluginDispatchStatus: "cleanup_pending",
        servicePluginOwnerStatus: "terminated", servicePluginLeaseStatus: "cleanup_pending", servicePluginPortStatus: "cleanup_pending",
        servicePluginPendingCount: 1, channelsStatus: "stopped", brokerStatus: broker,
        brokerExternalTerminal: terminal, brokerTerminalBasis: if (terminal) { "closed_ack_exit_observed" } else { "unknown" })
    let written = gatewayWriteServeCompletionMarker(identity, stop, httpStatus: "stopped", canvasStatus: "stopped", gatewayServerStatus: "stopped")
    @Expect(written, true)
    let path = CliConfig.dotDir.join("gateway-serve.stop-complete")
    var text = String.fromUtf8(File.readFrom(path))
    if (legacy) {
        text = text.replace("recoveryEvidenceVersion:1\n", "")
            .replace("brokerExternalTerminal:${if (terminal) { 1 } else { 0 }}\n", "")
            .replace("brokerTerminalBasis:${if (terminal) { "closed_ack_exit_observed" } else { "unknown" }}\n", "")
        File.writeTo(path, text.toArray())
    }
    text
}

func hrRuntimeWriteLease(home: Path, identity: GatewayServeIdentity, state!: String = "stopped"): Path {
    let dir = home.join("service-plugin").join("runtime").join("test-plugin")
    if (!exists(dir)) { Directory.create(dir, recursive: true) }
    let path = dir.join("test-plugin-1.lease.json")
    File.writeTo(path, ("{\"pluginId\":\"test-plugin\",\"sessionId\":\"test-plugin-1\",\"state\":\"${state}\"," +
        "\"pid\":987654322,\"parentPid\":${identity.pid},\"startedAtMs\":2000,\"port\":0}").toArray())
    path
}

@Test
public class GatewayHistoricalRecoveryTest {
    @TestCase
    public func hrS2U1ClassifiesV4AndExplicitEvidenceWithoutRewritingHistory(): Unit {
        hrRuntimeHome({ home, identity =>
            let _ = hrRuntimeWriteLease(home, identity)
            for (legacy in [true, false]) {
                let original = hrRuntimeWriteMarker(identity, legacy: legacy)
                let evidence = gatewayCollectHistoricalRecoveryEvidence(MonoTime.now() + Duration.second)
                @Expect(evidence.parsed.ok, true)
                @Expect(evidence.parsed.completion.status, "cleanup_pending")
                @Expect(gatewayEvaluateHistoricalRecoveryEvidence(evidence).status, "recoverable")
                @Expect(String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))), original)
            }
            let aggregate = hrRuntimeWriteMarker(identity).replace("servicePluginIngressStatus:sent", "servicePluginIngressStatus:terminal")
                .replace("servicePluginDispatchStatus:cleanup_pending", "servicePluginDispatchStatus:cancelled")
                .replace("servicePluginOwnerStatus:terminated", "servicePluginOwnerStatus:graceful_exited")
                .replace("servicePluginLeaseStatus:cleanup_pending", "servicePluginLeaseStatus:terminal")
                .replace("servicePluginPortStatus:cleanup_pending", "servicePluginPortStatus:terminal")
            File.writeTo(home.join("gateway-serve.stop-complete"), aggregate.toArray())
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "recoverable")
            File.writeTo(home.join("gateway-serve.stop-complete"), aggregate.replace("sidecarStatus:disabled", "sidecarStatus:terminal").toArray())
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "resources_not_terminal")
            let explicit = hrRuntimeWriteMarker(identity, legacy: false)
            @Expect(gatewayParseHistoricalCompletionStrict(explicit.replace("recoveryEvidenceVersion:1", "recoveryEvidenceVersion:2")).status, "evidence_version_unsupported")
            @Expect(gatewayParseHistoricalCompletionStrict(explicit + "pid:${identity.pid}\n").status, "malformed")
            @Expect(gatewayParseHistoricalCompletionStrict(explicit.replace("servicePluginLeaseStatus:cleanup_pending\n", "")).status, "malformed")
            File.writeTo(home.join("gateway-serve.stop-complete"), explicit.replace("servicePluginLeaseStatus:cleanup_pending", "servicePluginLeaseStatus:not_checked").toArray())
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "resources_not_terminal")
        })
    }

    @TestCase
    public func hrS2B1StrictMarkerUnicodeEncodingAndIdentityLimits(): Unit {
        hrRuntimeHome({ home, identity =>
            let original = hrRuntimeWriteMarker(identity)
            @Expect(gatewayParseHistoricalCompletionStrict(original).identity.getOrThrow().nonce, "历史恢复-测试🧪")
            @Expect(gatewayParseHistoricalCompletionStrict(original.replace(identity.nonce, String(Array<Rune>(4097, repeat: r'中')))).status, "evidence_limit_exceeded")
            @Expect(gatewayParseHistoricalCompletionStrict(original.replace("pid:${identity.pid}\n", "pid:7\n")).status, "identity_mismatch")
            @Expect(gatewayParseHistoricalCompletionStrict("{").ok, false)
            File.writeTo(home.join("gateway-serve.stop-complete"), [0xffu8, 0xfeu8, 0x00u8])
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "invalid_response_encoding")
        })
    }

    @TestCase
    public func hrS2P1ArchivesAndReconcilesOnlyOwnedHistoricalMarker(): Unit {
        hrRuntimeHome({ home, identity =>
            @Expect(gatewayAcquireServeLockForRunningProcess(), true)
            let original = hrRuntimeWriteMarker(identity)
            let _ = hrRuntimeWriteLease(home, identity)
            let pending = home.join("pending-business.json")
            File.writeTo(pending, "待处理🧪".toArray())
            let evidence = gatewayCollectHistoricalRecoveryEvidence(MonoTime.now() + Duration.second)
            let result = gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second * 3)
            @Expect(result.status, "reconciled")
            @Expect(exists(home.join("gateway-serve.stop-complete")), false)
            @Expect(String.fromUtf8(File.readFrom(pending)), "待处理🧪")
            var originals: Int64 = 0
            for (entry in Directory.readFrom(home.join("gateway-serve.recovery-history"))) {
                if (entry.name.endsWith(".completion")) {
                    originals += 1
                    @Expect(String.fromUtf8(File.readFrom(entry.path)), original)
                    let permissions = executeWithOutput("/usr/bin/stat", ["-f", "%Lp", entry.path.toString()])
                    @Expect(try { String.fromUtf8(permissions[1]).trimAscii() } catch (_: Exception) { "invalid_response_encoding" }, "600")
                } else if (entry.name.endsWith(".evidence")) {
                    let summary = String.fromUtf8(File.readFrom(entry.path))
                    @Expect(summary.contains("leaseCount:1"), true)
                    @Expect(summary.contains("rawPortProbe:released"), true)
                    @Expect(summary.contains("brokerBasis:legacy_v4_broker_close_exit_nonzero"), true)
                    @Expect(summary.contains(home.toString()), false)
                    @Expect(summary.contains(identity.nonce), false)
                }
            }
            @Expect(originals, 1)
            @Expect(gatewayReconcileHistoricalServeCompletion().status, "missing")
        })
    }

    @TestCase
    public func hrS2N1CommitFailureAndChangedEvidenceKeepReplacementSafe(): Unit {
        hrRuntimeHome({ home, identity =>
            @Expect(gatewayAcquireServeLockForRunningProcess(), true)
            let original = hrRuntimeWriteMarker(identity)
            let _ = hrRuntimeWriteLease(home, identity)
            let evidence = gatewayCollectHistoricalRecoveryEvidence(MonoTime.now() + Duration.second)
            File.writeTo(home.join("gateway-serve.recovery-history"), "blocked".toArray())
            @Expect(gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second * 3).status, "archive_write_failed")
            @Expect(String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))), original)
            remove(home.join("gateway-serve.recovery-history"))
            File.writeTo(home.join("gateway-serve.stop-complete"), original.replace(identity.nonce, "replacement🧪").toArray())
            @Expect(gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second * 3).status, "identity_changed")
            @Expect(String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))).contains("replacement🧪"), true)
            setGatewayServePortProbeForTest(Some({ _, _ => (1, "partial output", "") }))
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().ok, false)
            setGatewayServePortProbeForTest(Some({ _, _ => (1, "", "") }))
            File.writeTo(home.join("gateway-serve.stop-complete"), original.toArray())
            let calls = AtomicInt64(0)
            let lease = home.join("service-plugin/runtime/test-plugin/test-plugin-1.lease.json")
            let leaseText = String.fromUtf8(File.readFrom(lease))
            setGatewayServePortProbeForTest(Some({ _, _ =>
                if (calls.fetchAdd(1) == 0) { File.writeTo(lease, leaseText.replace("2000", "2001").toArray()) }
                (1, "", "")
            }))
            @Expect(gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second * 3).status, "identity_changed")
            @Expect(String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))), original)
            File.writeTo(lease, leaseText.toArray())
            setGatewayServePortProbeForTest(Some({ _, _ => (1, "", "") }))
            // A symlink to identical content is no longer the exclusively published lock.
            let lock = home.join("gateway-serve.lock")
            let ownedText = String.fromUtf8(File.readFrom(lock))
            let replacement = home.join("replacement-lock")
            File.writeTo(replacement, ownedText.toArray())
            remove(lock)
            @Expect(executeWithOutput("/bin/ln", ["-s", replacement.toString(), lock.toString()])[0], 0)
            @Expect(gatewayOwnsCurrentServeLock(), false)
            @Expect(gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second).status, "lock_not_owned")
            remove(lock)
            File.writeTo(lock, ownedText.toArray())
            gatewayReleaseServeLockQuiet()
            @Expect(gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second).status, "lock_not_owned")
        })
    }

    @TestCase
    public func hrS2N2UnknownBrokerAndSurfaceFailuresRemainBlocked(): Unit {
        hrRuntimeHome({ home, identity =>
            let _ = hrRuntimeWriteLease(home, identity)
            for (broker in ["broker_close_write_failed", "broker_close_eof_before_ack", "broker_close_ack_timeout", "broker_close_exit_timeout"]) {
                let _ = hrRuntimeWriteMarker(identity, broker: broker, terminal: false)
                @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "resources_not_terminal")
            }
            let _ = hrRuntimeWriteMarker(identity, legacy: false, terminal: false)
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().ok, false)
            let original = hrRuntimeWriteMarker(identity)
            File.writeTo(home.join("gateway-serve.stop-complete"), original.replace("httpStatus:stopped", "httpStatus:close_failed").toArray())
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "resources_not_terminal")
        })
    }

    @TestCase
    public func hrS2B2ConcurrentStartersHaveOneRecoveryCommitOwner(): Unit {
        hrRuntimeHome({ home, identity =>
            let _ = hrRuntimeWriteMarker(identity)
            let _ = hrRuntimeWriteLease(home, identity)
            let ready = AtomicInt64(0)
            let starters = Array(2, { _ => spawn {
                ready.fetchAdd(1)
                while (ready.load() != 2) { sleep(Duration.millisecond) }
                gatewayAcquireServeLockForRunningProcess()
            } })
            var successful: Int64 = 0
            for (future in starters) { if (future.get(Duration.second * 10)) { successful += 1 } }
            @Expect(successful, 1)
            @Expect(exists(home.join("gateway-serve.stop-complete")), false)
            @Expect(gatewayOwnsCurrentServeLock(), true)
            var committed: Int64 = 0
            for (entry in Directory.readFrom(home.join("gateway-serve.recovery-history"))) {
                if (entry.name.endsWith(".completion")) { committed += 1 }
            }
            @Expect(committed, 1)
        })
    }
}
